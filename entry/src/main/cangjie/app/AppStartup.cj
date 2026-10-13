package ohos_app_cangjie_entry.app

// ============================================================================
// AppStartup — 混合工程应用级启动初始化（复刻原纯仓颉 MainAbility.onWindowStageCreate）
//
// 背景：迁移到 ArkTS 基底后，原 cangjie MainAbility 被 ArkTS EntryAbility 取代，
// 但 EntryAbility 只调 registerAllCapabilities()，丢失了原 onWindowStageCreate 里
// 的应用级 init（AuthStorage.initialize / setGlobalAbilityContext / 各服务 init）。
// 症状：设备上 "[AuthStorage] Preferences not initialized"，登录页无法推进。
//
// 机制（context 跨语言桥）：cangjie 无法自行获取 UIAbilityContext（SDK 无全局
// accessor，ability 现由 ArkTS 持有）。ArkTS EntryAbility 在 onWindowStageCreate
// 里把 this.context（UIAbilityContext）作为 JS 对象传入本模块导出的 appStartup 函数，
// cangjie 侧用 createUIAbilityContextFromJSValue(runtime, jsCtx) 还原为原生
// UIAbilityContext，再交给 getAuthStorage().initialize(ctx) 等。
//
// 导出方式：沿用 index.cj 的 JSModule.registerModule 模式（appStartup 经 .so 暴露给
// ArkTS，import { appStartup } from 'libohos_app_cangjie_entry.so'）。
// ============================================================================

import ohos.ark_interop.JSModule
import ohos.ark_interop.JSContext
import ohos.ark_interop.JSCallInfo
import ohos.ark_interop.JSValue
import ohos.app.ability.ui_ability.createUIAbilityContextFromJSValue
import kit.AbilityKit.UIAbilityContext
import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import std.collection.ArrayList
import std.convert.*
import ohos_app_cangjie_entry.interop.{callArkAsync, bindInteropContext, BGTASK_START, subscribe, EVT_FOREGROUND_CHANGED, EVT_EXTERNAL_URI, EVT_CONFIGURATION_CHANGED, EVT_SAFE_AREA_CHANGED, EVT_NOTIFICATION_CLICK}
import ohos_app_cangjie_entry.services.getNotificationClickRouter
import ohos_app_cangjie_entry.services.getUndoToastService
import ohos_app_cangjie_entry.services.JsonParser

import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.core.storage.setDefaultChatBgPath
import ohos_app_cangjie_entry.core.storage.StoredSessionData
import ohos_app_cangjie_entry.core.storage.{setSystemColorMode, setSystemFontScale, COLOR_MODE_NOT_SET}
import ohos_app_cangjie_entry.core.mtproto.{SessionManager, SessionData, getMainClientDcId, getMTProtoClient, ConnectionState, setAccountConnectionStateCallback}
import ohos_app_cangjie_entry.services.{setAppFilesDir, setGlobalAbilityContext, failedStoreLoad, getAccountUpdateCoordinator, getCallService, getBadgeAggregator, getChatListProjection}
import ohos_app_cangjie_entry.services.{getBrowserService, setWidgetStorageContext, getTelegramEngineItemCacheService, getPushTokenService}
import ohos_app_cangjie_entry.utils.{setAppBundleContext, readRawFileBytes}

// 一次性守卫：avoid double-init if ArkTS onWindowStageCreate 被多次触发。
var _appStartupDone: Bool = false

// TC-0025 M4（生产者侧）单例：ArkTS EntryAbility 经 EVT_SAFE_AREA_CHANGED 下发的安全区
// 量测（vp）。缺字段时默认 0（订阅注册前 / dispatch 前消费方读到的默认值，与
// EVT_CONFIGURATION_CHANGED 的 has() 判存在同一取舍）。逐页应用（padding）不在本
// feature 范围，页面级返修可直接读这四个 getter。
var _safeAreaTop: Float64 = 0.0
var _safeAreaBottom: Float64 = 0.0
var _safeAreaLeft: Float64 = 0.0
var _safeAreaRight: Float64 = 0.0

public func getSafeAreaTop(): Float64 {
    _safeAreaTop
}

public func getSafeAreaBottom(): Float64 {
    _safeAreaBottom
}

public func getSafeAreaLeft(): Float64 {
    _safeAreaLeft
}

public func getSafeAreaRight(): Float64 {
    _safeAreaRight
}

/**
 * 应用级启动初始化。由 ArkTS EntryAbility.onWindowStageCreate 传入 UIAbilityContext 调用。
 *
 * 严格复刻原 MainAbility.onWindowStageCreate 的顺序与守卫：
 *   1. AuthStorage.initialize(ctx)         —— Preferences 持久化（必须最先，其余依赖登录态）
 *   2. setAppFilesDir / setGlobalAbilityContext / setAppBundleContext —— 全局 context 缓存
 *   3. BrowserService.initialize(ctx)      —— 浏览器持久化
 *   4. setWidgetStorageContext(ctx)        —— widget 跨进程 KVStore context
 *   5. ItemCacheService.initialize(ctx)    —— engine item cache 持久化
 *   6. extractDefaultChatBg(ctx)           —— rawfile 默认聊天背景落盘
 *   7. SessionManager load/persist 回调注入 —— 会话持久化桥
 *   8. AppState.initialize()               —— 全局账户上下文装配
 *   9. PushTokenService.initPushRegistration（spawn 后台）
 *
 * 说明（相对原 onWindowStageCreate 的差异）：
 *  - BackgroundPrivacyService.setMainWindow：原需 Window；混合工程下窗口隐私已反转由 ArkTS
 *    侧 (BackgroundPrivacyImpl.ets, window.getLastWindow(getContext())) 自持，故此处不注入。
 *  - notif-click / deeplink / share want 处理：原在 onCreate 消费 Want；混合工程下 Want 由
 *    ArkTS 持有，需单独 Want 管道传入。deeplink 一环已接线（EVT_EXTERNAL_URI，见下方
 *    最前置的 subscribe）；notif-click / share 仍未接线，留待相应能力域 feature 补齐。
 */
public func runAppStartup(context: UIAbilityContext): Unit {
    if (_appStartupDone) {
        Hilog.info(1, "Cangjie", "[AppStartup] already done, skip")
        return
    }
    _appStartupDone = true

    // 外部 URI（tg:// / t.me / telegram.me）订阅：必须在任何 init 之前完成注册。
    // handleWantUri 只写模块级变量 + 打日志，对存储/网络无任何依赖；runAppStartup
    // 被 try/catch 包着，若其间任一 init 抛异常，后面的订阅就不会注册，故放最前面最稳。
    subscribe(EVT_EXTERNAL_URI, { uri: String =>
        // handleWantUri 返回 Bool（是否识别为已知深链）；subscribe 的 handler 类型是
        // (String) -> Unit，用 `let _ = ` 丢弃返回值（仓内既有 spawn/service 调用惯用法）。
        let _ = getDeepLinkRouter().handleWantUri(uri)
    })

    // 系统色模式 / 字号缩放（TC-0402 F-A）：EntryAbility 在 onWindowStageCreate 里
    // appStartup() 返回后立即投一次冷启动读数，随后 onConfigurationUpdate 增量投递；
    // 与 EVT_EXTERNAL_URI 同理，订阅必须先于这次冷启动投递注册，故同样放最前面。
    // 取值直接透传 ConfigurationConstant.ColorMode 序数 / Configuration.fontSizeScale，
    // 不做翻译；AppTheme.cj 的 COLOR_MODE_NOT_SET 已按 light 处理，此处无需再加分支。
    // 字段用 JSON.stringify 生成，值为 undefined 时该 key 整个不出现在 payload 里
    // （JS 语义），故用 has() 判存在而非依赖 JsonObject 的数值型默认值（getInt 的默认
    // 0 恰好等于 COLOR_MODE_DARK，会把"缺字段"误读成"深色"）。
    subscribe(EVT_CONFIGURATION_CHANGED, { payload: String =>
        let obj = JsonParser.parseObject(payload)
        let mode = if (obj.has("colorMode")) { Int32(obj.getInt("colorMode")) } else { COLOR_MODE_NOT_SET }
        let scale = if (obj.has("fontSizeScale")) { obj.getFloat("fontSizeScale") } else { 1.0 }
        setSystemColorMode(mode)
        setSystemFontScale(scale)
    })

    // TC-0025 M4（生产者侧）：安全区量测下发通道的消费端。ArkTS
    // EntryAbility.dispatchSafeAreaChanged 冷启动投一次 + avoidAreaChange 增量投递；
    // 订阅同样必须先于冷启动投递注册，故放在同一批最前面。字段缺失按 0 处理（页面
    // 尚未接线时的安全默认值，等价于「不内缩」）。
    subscribe(EVT_SAFE_AREA_CHANGED, { payload: String =>
        let obj = JsonParser.parseObject(payload)
        _safeAreaTop = if (obj.has("top")) { obj.getFloat("top") } else { 0.0 }
        _safeAreaBottom = if (obj.has("bottom")) { obj.getFloat("bottom") } else { 0.0 }
        _safeAreaLeft = if (obj.has("left")) { obj.getFloat("left") } else { 0.0 }
        _safeAreaRight = if (obj.has("right")) { obj.getFloat("right") } else { 0.0 }
    })

    // 消息通知点击（冷启动 onCreate / 热启动 onNewWant 的 want.parameters）→ pending click，
    // 由 MainTabPage 的通知点击轮询打开对应会话。对齐 iOS AppDelegate
    // userNotificationCenter(_:didReceive:) → peerIdFromNotification → openChatWhenReady。
    // 冷启动投递时机与 EVT_EXTERNAL_URI 相同，订阅必须同样先于它注册。
    subscribe(EVT_NOTIFICATION_CLICK, { payload: String =>
        let obj = JsonParser.parseObject(payload)
        var peerId: Int64 = 0
        var msgId: Int64 = 0
        try { peerId = Int64.parse(obj.getString("peerId")) } catch (_e: Exception) {}
        try { msgId = Int64.parse(obj.getString("msgId")) } catch (_e: Exception) {}
        let peerType = if (obj.getString("peerType").size > 0) { obj.getString("peerType") } else { "user" }
        Hilog.info(1, "Cangjie", "[AppStartup] notification click peerId=${peerId} peerType=${peerType} msgId=${msgId}")
        getNotificationClickRouter().setDirectClick(peerId, Int32(msgId), peerType, obj.getString("peerName"))
    })

    // 1. 初始化持久化存储（必须最先）
    Hilog.info(1, "Cangjie", "[AppStartup] Initializing AuthStorage with Preferences...")
    let storage = getAuthStorage()
    storage.initialize(context)

    // 2. 全局 context 缓存
    setAppFilesDir(context.filesDir)
    setGlobalAbilityContext(context)
    setAppBundleContext(context)
    // 失败消息持久化恢复（对齐 iOS：杀 app 重启后未发出消息仍在）
    failedStoreLoad(context)

    // 3. BrowserService Preferences 持久化初始化
    getBrowserService().initialize(context)
    Hilog.info(1, "Cangjie", "[AppStartup] BrowserService initialized")

    // 4. WidgetStorageService 跨进程 KVStore context 注入
    setWidgetStorageContext(context)
    Hilog.info(1, "Cangjie", "[AppStartup] WidgetStorageService context injected")

    // 5. ItemCacheService Preferences 持久化初始化
    getTelegramEngineItemCacheService().initialize(context)
    Hilog.info(1, "Cangjie", "[AppStartup] ItemCacheService initialized")

    // 6. 从 rawfile 提取默认聊天背景到文件系统
    extractDefaultChatBg(context)

    // 7. SessionManager 回调：从持久化存储加载/保存会话
    SessionManager.setLoadCallback({=>
        let sd = storage.getSessionData()
        match (sd) {
            case Some(stored) =>
                let data = SessionData()
                data.dcId = stored.dcId
                if (!stored.authKey.isEmpty()) {
                    data.authKey = Some(stored.authKey)
                }
                if (!stored.authKeyId.isEmpty()) {
                    data.authKeyId = Some(stored.authKeyId)
                }
                if (!stored.serverSalt.isEmpty()) {
                    data.serverSalt = Some(stored.serverSalt)
                }
                data.authKeyState = stored.authKeyState
                return Some(data)
            case None => return None
        }
    })

    // ---- 前台恢复即主动重连（接收端；发送端在 EntryAbility.onForeground）----
    //
    // 熄屏/切后台期间 TCP 连接被系统断开，而回到前台时网络可达性并未变化，
    // ReachabilityService 的监听器不触发，故此前无人重连，"Connecting..." 要持续
    // 10~20 秒——直到下一次实际请求才被动重建连接。
    //
    // triggerReconnect 对健康连接是安全的：MTProtoClient.cj:2680 判断
    //   if (!transport.isConnected()) { attemptReconnect } else { reconnectCtrl.onSuccess() }
    // 连接正常时只重置退避计数，不会误断已有连接。
    //
    // 注意勿改用 wireReachabilityReconnect()：那是「注册可达性监听器」且带幂等守卫
    // （TelegramCore_NetworkService.cj:126 `if (_reachabilityWired) { return }`），
    // AppRoot 启动时已调用过，前台再调必然在第一行返回、什么都不做。
    // AppState.onForeground() 里正是这么写的，且该方法本身无任何调用方（整条链路未接通）。
    subscribe(EVT_FOREGROUND_CHANGED, { payload: String =>
        if (payload == "{\"foreground\":true}") {
            getAppState().onForeground()
            let client = getMTProtoClient()
            if (client.isInitialized()) {
                // Transport.connect is blocking.  A foreground lifecycle callback runs
                // on the UI thread, so resume the established account asynchronously.
                spawn {
                    try {
                        client.triggerReconnect()
                        Hilog.info(0, "CjTelegram", "[AppStartup] foreground → triggerReconnect")
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[AppStartup] foreground reconnect failed: ${e}")
                    }
                }
            } else {
                // Cold start: AppRoot.initializeClient owns the first connection and
                // restores the correct home DC.  Connecting here would waste a DC1 TCP
                // handshake and delay the first frame.
                Hilog.info(0, "CjTelegram", "[AppStartup] foreground before client init → skip reconnect")
            }
        } else {
            getAppState().onBackground()
            // iOS AppDelegate.applicationWillResignActive (AppDelegate.swift:1899-1924): every
            // pending UndoOverlayController is dismissed with its commit action, so a deletion
            // still inside its undo window is carried out when the app leaves the foreground.
            if (getUndoToastService().isShowing()) {
                Hilog.info(0, "CjTelegram", "[AppStartup] background → commit pending undo toast")
                getUndoToastService().finishAsCommit()
            }
            Hilog.info(0, "CjTelegram", "[AppStartup] background → pause UI frame producers")
        }
    })

    SessionManager.setPersistCallback({ session =>
        let exported = SessionManager.exportSessionData(session)

        let mainDc = getMainClientDcId()
        if (mainDc > 0 && exported.dcId != mainDc) {
            return
        }

        let storedSession = StoredSessionData()
        storedSession.dcId = exported.dcId
        match (exported.authKey) {
            case Some(ak) => storedSession.authKey = ak
            case None => ()
        }
        match (exported.authKeyId) {
            case Some(akId) => storedSession.authKeyId = akId
            case None => ()
        }
        match (exported.serverSalt) {
            case Some(ss) => storedSession.serverSalt = ss
            case None => ()
        }
        storedSession.authKeyState = exported.authKeyState
        storage.saveSessionData(storedSession)
    })

    Hilog.info(1, "Cangjie", "[AppStartup] AuthStorage + SessionManager callbacks initialized.")

    // 9. AppState 全局账户上下文装配
    getAppState().initialize()
    Hilog.info(1, "Cangjie", "[AppStartup] AppState initialized with current user context.")

    // 账号级 updates 必须早于页面创建接线。协调器是 MTProtoClient 的唯一 callback
    // 所有者；CallService 只是 token 化订阅者，不再反向拥有消息更新总线。
    getChatListProjection().bootstrapFromStore()
    setAccountConnectionStateCallback({ slot: Int32, state: ConnectionState =>
        if (slot != getAuthStorage().getActiveSlot()) { return }
        let status = match (state) {
            case ConnectionState.Connected => "online"
            case ConnectionState.Updating => "updating"
            case ConnectionState.Connecting => "connecting"
            case ConnectionState.Disconnected => "waiting"
        }
        getChatListProjection().applyConnectionStatus(status)
    })
    getAccountUpdateCoordinator().initialize()
    getCallService().ensureUpdateSubscription()
    getBadgeAggregator().initialize()
    Hilog.info(1, "Cangjie", "[AppStartup] Account update coordinator initialized")

    // 10. 推送注册。必须留在 ArkTS 主线程调用（ark_interop JSContext 绑定主线程,
    // 原 spawn 后台线程调用触发 34300004 Thread mismatch, 注册从未成功）。
    // token 获取本身是异步 ark 调用不阻塞; 重活(registerDevice RPC)在 token
    // 回调内 spawn 后台执行。
    let otherUids = ArrayList<Int64>()
    getPushTokenService().initPushRegistration(false, otherUids)
    Hilog.info(1, "Cangjie", "[AppStartup] Push registration initiated")

    // 10.5 长时任务保活（CALL-BG）：退后台不挂起、MTProto 连接不断 → 来电永远
    // 可达（iOS 用 PushKit VoIP 唤醒；鸿蒙第三方无该权益，用 voip 长时任务等价，
    // 失败自动回退 dataTransfer）。appStartup 在 ArkTS 主线程，直接 callArkAsync。
    callArkAsync(BGTASK_START, "{}") { res =>
        Hilog.info(1, "Cangjie", "[AppStartup] Continuous task result: ${res}")
    }

    Hilog.info(1, "Cangjie", "[AppStartup] App-level startup init complete.")
}

/**
 * JSModule 导出入口：ArkTS 传入 UIAbilityContext（JS 对象）。
 * callInfo[0] = ArkTS this.context；用 createUIAbilityContextFromJSValue 还原为原生 context。
 */
func appStartup(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    try {
        bindInteropContext(runtime) // callArk 的 scope 安全重投宿主（见 interop.cj）
        let ctx = createUIAbilityContextFromJSValue(runtime, callInfo[0])
        runAppStartup(ctx)
    } catch (e: Exception) {
        Hilog.error(1, "Cangjie", "[AppStartup] appStartup failed: ${e}")
    }
    return runtime.undefined().toJSValue()
}

let APP_STARTUP_MODULE = JSModule.registerModule {
    runtime, exports => exports["appStartup"] = runtime.function(appStartup).toJSValue()
}

/**
 * 从 rawfile 提取默认聊天背景到 filesDir（复刻原 MainAbility.extractDefaultChatBg）。
 *
 * @rawfile() 宏在 @Component build() 中会生成静态初始化代码调用 __GenerateResource__，
 * 该 native 符号在 CJ 运行时加载 .so 时无法解析，导致 SIGSEGV。
 * 改为在启动路径中通过 AppBundleUtils/ResourceManager 运行时读取并写入文件系统。
 */
func extractDefaultChatBg(context: UIAbilityContext): Unit {
    let filesDir = context.filesDir
    let bgDir = filesDir + "/chat_bg"
    let defaultPath = bgDir + "/default.png"

    Hilog.info(0, "CjTelegram", "[AppStartup] extractDefaultChatBg: filesDir=${filesDir}, target=${defaultPath}")

    try {
        let exists = FileIo.access(defaultPath)
        if (exists) {
            let st = FileIo.stat(defaultPath)
            if (st.size > 1000) {
                setDefaultChatBgPath(defaultPath)
                Hilog.info(0, "CjTelegram", "[AppStartup] Default chat bg cached: ${defaultPath} (${st.size} bytes)")
                return
            }
            Hilog.info(0, "CjTelegram", "[AppStartup] Stale bg file (${st.size} bytes), re-extracting")
            try { FileIo.unlink(defaultPath) } catch (_e2: Exception) {}
        }
    } catch (_e: Exception) {
        Hilog.info(0, "CjTelegram", "[AppStartup] access/stat check: file not found, will extract")
    }

    try { FileIo.mkdir(bgDir) } catch (_e: Exception) {}

    Hilog.info(0, "CjTelegram", "[AppStartup] Reading rawfile chat_bg_default.png via AppBundleUtils...")
    match (readRawFileBytes("chat_bg_default.png")) {
        case None =>
            Hilog.info(0, "CjTelegram", "[AppStartup] readRawFileBytes returned None for chat_bg_default.png")
        case Some(data) =>
            Hilog.info(0, "CjTelegram", "[AppStartup] Rawfile read: ${data.size} bytes")
            if (data.size > 0) {
                try {
                    let file = FileIo.open(defaultPath, mode: 0o1101)
                    let written = FileIo.write(file.fd, data)
                    FileIo.close(file)
                    Hilog.info(0, "CjTelegram", "[AppStartup] Wrote ${written} / ${data.size} bytes to ${defaultPath}")

                    let verifyStat = FileIo.stat(defaultPath)
                    Hilog.info(0, "CjTelegram", "[AppStartup] Verify: file size on disk = ${verifyStat.size}")

                    if (verifyStat.size > 0) {
                        setDefaultChatBgPath(defaultPath)
                        Hilog.info(0, "CjTelegram", "[AppStartup] Default chat bg ready: ${defaultPath}")
                    } else {
                        Hilog.info(0, "CjTelegram", "[AppStartup] WARNING: file on disk is 0 bytes after write!")
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AppStartup] Extract default chat bg FAILED: ${e}")
                }
            } else {
                Hilog.info(0, "CjTelegram", "[AppStartup] Rawfile chat_bg_default.png returned 0 bytes")
            }
    }
}
