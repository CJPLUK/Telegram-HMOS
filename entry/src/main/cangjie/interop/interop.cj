package ohos_app_cangjie_entry.interop

import std.collection.{HashMap, ArrayList}
import ohos.ark_interop.*
import ohos.ark_interop_macro.*
import kit.PerformanceAnalysisKit.Hilog

// ============================================================================
// 跨语言 interop 收口层（仓颉侧）—— SSOT §3。全异步(D1)、双侧共享契约(D3)。
// 放在 .interop 子包（不放根包，避免 combined 模块与 pages 的循环依赖）。
// ============================================================================

// ---- 双侧共享契约清单（CJ 侧；ArkTS InteropContract.ets 必须逐条对应）----
public let ROUTER_PUSH = "router.push"
public let ROUTER_POP = "router.pop"
public let ROUTER_REPLACE = "router.replace"
// diag-suite_settings_root-TC-0083.md M-2-c：值必须与 ArkTS 侧 InteropRegistry.ets 里
// registerArkFunc 调用点使用的字面量 'router.replaceTop' 一字不差（InteropContract.ets
// 不在本 feature allowlist 内，故 ArkTS 侧未新增同名具名常量，改直接内联同值字符串字面量，
// 双侧仍按值对齐，不改契约登记机制本身）。
public let ROUTER_REPLACE_TOP = "router.replaceTop"
public let HAPTIC_VIBRATE = "haptic.vibrate"
// ---- Phase 3 能力反转契约（每能力 impls/<Cap>Impl.ets，两侧一字不差 D3）----
public let BADGE_SET = "badge.set"
public let GEOCODE_REVERSE = "geocode.reverse"
public let GEOCODE_FORWARD = "geocode.forward"
public let AUDIO_LIST_DEVICES = "audio.listDevices"
public let AUDIO_SET_ROUTE = "audio.setRoute"
public let NOTIF_PUBLISH = "notif.publish"
public let NOTIF_CANCEL_GROUP = "notif.cancelGroup"
public let BGPRIVACY_SET = "bgprivacy.set"
public let LOCALAUTH_AVAILABLE = "localauth.available"
public let LOCALAUTH_AUTHENTICATE = "localauth.authenticate"
// CG-01 passkeys：WebAuthn 注册 ceremony 走 ArkTS @kit.OnlineAuthenticationKit fido2.register
// （ets/interop/impls/PasskeyImpl.ets，与 InteropContract.ets PASSKEY_REGISTER 一字不差）。
//   argJson：{"optionsB64": <服务端 options JSON 的标准 base64>}
//   result ：{"ok":true,"id","rawId","clientDataB64","attestationB64"} 或
//            {"ok":false,"code","cancelled","msg"}
public let PASSKEY_REGISTER = "passkey.register"
public let PUSH_GET_TOKEN = "push.getToken"
public let BGTASK_START = "bgtask.start"
public let BGTASK_STOP = "bgtask.stop"
public let CAMERA_REC_PREPARE = "camera.rec.prepare"
public let CAMERA_REC_START = "camera.rec.start"
public let CAMERA_REC_PAUSE = "camera.rec.pause"
public let CAMERA_REC_RESUME = "camera.rec.resume"
public let CAMERA_REC_STOP = "camera.rec.stop"
public let SHARE_LINK = "share.link"
public let LANGUAGE_DISPLAY_NAMES = "language.displayNames"
public let IAP_RECEIPT = "iap.receipt"
public let SCAN_DECODE_FILE = "scan.decodeFile"
public let SCAN_PICK_ALBUM = "scan.pickAlbum"
public let PICK_PHOTO_ALBUM = "photo.pickAlbum"
public let PICK_CONTACTS = "contact.pick"
public let ADD_CONTACT_VIA_UI = "contact.addViaUi"
// diag-suite_settings_notifications-TC-0449-round5.md 改动3：这是 PICK_DOCUMENT 的
// 正主定义（唯一现有消费方 services/NotificationSoundSelectionService.cj 目前用同值
// 私有副本 NSND_PICK_DOCUMENT，该文件不在本 feature allowlist 内，故这里只新增正主
// 常量，不改消费方）。ArkTS 侧 ets/interop/InteropContract.ets 同样不在本 feature
// allowlist 内，故 impls/DocumentPickerImpl.ets 内联同值字面量，与 :17-20
// ROUTER_REPLACE_TOP 是同一条既有做法。
public let PICK_DOCUMENT = "document.pick"
// 附件面板 Location 页签整块由 ArkTS 渲染（AttachLocationView.ets）：
//   attachLocation.update  仓颉 → ArkTS：几何(px) + 定位/地点状态 JSON
//   attachLocation.action  ArkTS → 仓颉 dispatchEvent：{action, seconds?, id?, query?}
public let ATTACH_LOCATION_UPDATE = "attachLocation.update"
public let EVT_ATTACH_LOCATION_ACTION = "attachLocation.action"
// 应用内位置页（对位 iOS LocationViewController，ArkTS 整页 + 仓颉数据）
//   locationView.update  仓颉 → ArkTS：subject / user / ownShare / participants 状态 JSON
//   locationView.action  ArkTS → 仓颉 dispatchEvent：{action: close|share|stop|startLive|openIn, seconds?}
public let LOCATION_VIEW_UPDATE = "locationView.update"
public let EVT_LOCATION_VIEW_ACTION = "locationView.action"

// 群 Video Chat 页（对位 iOS VideoChatScreenV2Impl）：UI 全在 ArkTS，仓颉推状态 / 收动作。
public let GROUP_CALL_UPDATE = "groupCall.update"
public let EVT_GROUP_CALL_ACTION = "groupCall.action"
// HMS Map Kit 反转能力（ets/interop/impls/MapKitImpl.ets）
public let MAP_STATIC_IMAGE = "map.staticImage"
public let MAP_NEARBY_SEARCH = "map.nearbySearch"
public let MAP_QUERY_LOCATION = "map.queryLocation"
public let COMPONENT_SNAPSHOT_CAPTURE = "componentSnapshot.capture"
public let COMPONENT_SNAPSHOT_RELEASE = "componentSnapshot.release"
public let EVT_FOREGROUND_CHANGED = "app.foregroundChanged"
// payload 是原始 Want.uri 字符串本身，不是 JSON：URI 含 "://"、"?"、"&"，
// 仓内 services/JsonParser.cj 是简化版解析器，包一层 JSON 反而引入解析风险。
public let EVT_EXTERNAL_URI = "app.externalUri"
// payload 是 JSON，{colorMode, fontSizeScale}，字段值直接透传
// ConfigurationConstant.ColorMode 序数 / Configuration.fontSizeScale，不做翻译。
public let EVT_CONFIGURATION_CHANGED = "app.configurationChanged"
// TC-0025 M4（生产者侧）：payload 是 JSON，{top, bottom, left, right}（vp），来自
// window.getWindowAvoidArea(TYPE_SYSTEM) 与 TYPE_NAVIGATION_INDICATOR 取较大者合并。
// 冷启动投一次 + avoidAreaChange 增量投递（ArkTS 侧 EntryAbility.dispatchSafeAreaChanged）。
public let EVT_SAFE_AREA_CHANGED = "app.safeAreaChanged"
// 消息通知点击：payload 是 JSON {peerId, peerType, peerName, msgId}（均为字符串），
// 来自通知 wantAgent 的 want.parameters（ArkTS EntryAbility.notificationClickPayload）。
public let EVT_NOTIFICATION_CLICK = "app.notificationClick"
// S7-59 应用内消息横幅（iOS ChatMessageNotificationItem / NotificationContainerController）：
// 仓颉 → ArkTS，payload JSON {title, text, avatarPath, avatarLetter, avatarColor, peerId, peerType,
// peerName, msgId}；ArkTS 根容器 Home.ets 渲染，点按经 EVT_NOTIFICATION_CLICK 回投打开会话。
public let INAPP_BANNER_SHOW = "inappBanner.show"
// UndoToast 根叠加层命中区（仓颉 → ArkTS）：payload JSON {visible, x, y, w, h}（vp）。ArkTS 根容器
// Home.ets 里承载 UndoToastOverlay 的 CJHybridComponent 用它设置 responseRegion，浮条以外的触摸
// 落到下层 Navigation 页面（iOS UndoOverlayController 非模态）。见 impls/UndoToastOverlayImpl.ets。
public let UNDO_TOAST_REGION = "undoToast.region"
// 后台来电上报系统通话界面（Call Service Kit voipCall，iOS CallKit 等价；ArkTS impls/VoipCallImpl.ets）
public let VOIP_REPORT_INCOMING = "voip.reportIncoming"
public let VOIP_REPORT_STATE = "voip.reportState"
// 系统来电界面上的用户操作：payload JSON {callId, event}（event = voipCall.VoipCallUiEvent 序数）
public let EVT_VOIP_UI_EVENT = "voip.uiEvent"

// ---- 反转调用：ArkTS 实现能力并注册，仓颉 callArkAsync 调用 ----
// 契约形态：arkFn(argJson: String, onResult: (String)->Unit)
let ARK_FUNCS = HashMap<String, (String, (String) -> Unit) -> Unit>()

@Interop[ArkTS]
public func registerArkFunc(name: String, fn: (String, (String) -> Unit) -> Unit): Unit {
    ARK_FUNCS[name] = fn
}

// ---- scope 安全化：@Interop 包装闭包内部要做 String→JSValue 转换，必须有
// 活跃的 JSValueScope。`launch` 回主线程的 FFI 回调没有 scope（BusinessException
// 34300003 "Without any scope"，真机：emoji 行表 gen 推送全灭 → 面板白屏）。
// 内联快路径失败时经 postJSTask 带 scope 重投 —— 转换在任何 JS 副作用之前
// 就抛，重投无重复效应。
var interopMainContext: Option<JSContext> = None

/** AppStartup 在 ArkTS 主线程注入主 JSContext（postJSTask 的宿主）。 */
public func bindInteropContext(ctx: JSContext): Unit {
    interopMainContext = Some(ctx)
}

public func callArkAsync(name: String, argJson: String, onResult: (String) -> Unit): Unit {
    match (ARK_FUNCS.get(name)) {
        case Some(fn) =>
            try {
                fn(argJson, onResult)
            } catch (e: Exception) {
                match (interopMainContext) {
                    case Some(ctx) =>
                        ctx.postJSTask {
                            try {
                                fn(argJson, onResult)
                            } catch (e2: Exception) {
                                Hilog.error(0, "CjTelegram",
                                    "[Interop] callArk ${name} failed on JS task: ${e2}")
                            }
                        }
                    case None =>
                        Hilog.error(0, "CjTelegram",
                            "[Interop] callArk ${name} failed (no context bound): ${e}")
                }
            }
        case None => onResult("{\"error\":\"no ark func: ${name}\"}")
    }
}

/**
 * 对延迟敏感的 fire-and-forget 命令直接投递到主 JSContext。
 * ArkUI 的仓颉事件回调没有 JSValueScope；通用 callArkAsync 会先触发一次异常再回退，
 * 媒体播放会因此把一次点击拖慢数百毫秒。音频控制不需要内联返回值，直接投递即可。
 */
public func callArkOnJSTask(name: String, argJson: String, onResult: (String) -> Unit): Unit {
    match (ARK_FUNCS.get(name)) {
        case Some(fn) =>
            match (interopMainContext) {
                case Some(ctx) =>
                    ctx.postJSTask {
                        try {
                            fn(argJson, onResult)
                        } catch (e: Exception) {
                            Hilog.error(0, "CjTelegram",
                                "[Interop] JS task ${name} failed: ${e}")
                        }
                    }
                case None => callArkAsync(name, argJson, onResult)
            }
        case None => onResult("{\"error\":\"no ark func: ${name}\"}")
    }
}

// 不关心结果的调用（如 router 操作）
public func callArk(name: String, argJson: String): Unit {
    callArkAsync(name, argJson, { _ => () })
}

// ---- 事件订阅通道：ArkTS 触发 dispatchEvent，仓颉本地 handlers fan-out ----
let EVENT_HANDLERS = HashMap<String, ArrayList<(String) -> Unit>>()

public func subscribe(event: String, handler: (String) -> Unit): Unit {
    match (EVENT_HANDLERS.get(event)) {
        case Some(hs) => hs.add(handler)
        case None =>
            let hs = ArrayList<(String) -> Unit>()
            hs.add(handler)
            EVENT_HANDLERS[event] = hs
    }
}

@Interop[ArkTS]
public func dispatchEvent(event: String, payloadJson: String): Unit {
    match (EVENT_HANDLERS.get(event)) {
        case Some(hs) => for (h in hs) { h(payloadJson) }
        case None => ()
    }
}
