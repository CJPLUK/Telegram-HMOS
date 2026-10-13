package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import kit.ArkUI.launch
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.viewmodels.*
import ohos_app_cangjie_entry.services.{getRealAuthService, RealAuthState, getTelegramCore_NetworkService, getNetworkUsageService}
import ohos_app_cangjie_entry.services.{
    preloadAnimatedEmojiMetadata,
    preloadAnimatedEmojiEffectsMetadata,
    preloadPopularAnimatedEmojiResources
}
import ohos_app_cangjie_entry.components.preloadQuickReactionLottie
import ohos_app_cangjie_entry.core.mtproto.{getMTProtoClient, setActiveSlotProvider}
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.app.{initAccountSwitchBridge, getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.core.services.{
    addAccountSwitchListenerWithId, removeAccountSwitchListener,
    getTelegramCore_AccountManagerService
}

/**
 * AppRoot — 应用登录门控根页面（混合工程迁移 auth-flow）
 *
 * 复刻原 index.cj (EntryView) 的登录门控 + 启动序列职责：原 EntryView 在 aboutToAppear
 * 里跑完整 MTProto 启动（initializeClient / setActiveSlotProvider / wireReachabilityReconnect /
 * setMeteringRegistrar / tryRestoreLogin），再据结果决定挂主 tab 栈还是登录栈。混合工程中
 * 跨页 @Provide/@Consume 失效，改由：
 *  - app 级单例 getAuthViewModel().isLoggedIn / .authState 作为 SSOT；
 *  - 本页作为启动首帧（Home.ets 首推 "AppRoot"），.onAppear 一次性：
 *      1. 启动 MTProto（spawn 后台线程）；
 *      2. 注册 account-switch bridge + listener（切号后重载登录态）；
 *      3. init 解析完成后（launch 回 UI 线程）决定初始路由：
 *           restored              → routerReplace("MainTabPage")
 *           AwaitingAccountReset  → authState=AWAITING_ACCOUNT_RESET + routerReplace("AccountResetPage","<waitSecs>:")
 *           else                  → authState=WAIT_PHONE + routerReplace("SplashPage")
 *     （SplashPage 登录按钮 enabled 门控在 authState==WAIT_PHONE，故必须等 init 解析后再放行。）
 *  - 后续登录成功 / 登出由各 auth 页 routerReplace 维护（见 CodeInput/Password/Email/Qr、
 *    Settings/Debug/AccountReset）。
 *
 * 本页 UI 仅是过渡加载态（"正在连接 Telegram 服务器…"），决策后立即 routerReplace 离开。
 *
 * TODO(startup-applock): restore passcode-lock-on-launch gate (original EntryView showed lock UI
 * before route decision). 混合工程 AppRoot 尚无锁屏 UI/门控；本次只恢复登录关键的 MTProto 启动
 * + account-switch，锁屏门控留待后续单独补 lock UI 页。
 */
@HybridComponentEntry
@Component
public class AppRoot {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 一次性决策守卫（避免 .onAppear 重复触发导致多次启动 / routerReplace）
    @State var decided: Bool = false

    // P2-010: Account switch listener ID（.onDisAppear 时 deregister，避免悬挂回调）
    var _accountSwitchListenerId: Int64 = -1

    private func decideInitialRoute(): Unit {
        if (this.decided) { return }
        this.decided = true

        // P2-010: Initialize account switch bridge (AppStorage keys for root-rebuild signal)
        initAccountSwitchBridge()

        // P2-010: Register root-rebuild listener — switchAccount(slot) 完成后重载登录态。
        // Listener 从 core service 的 spawn{} 内调用，须 launch{} 回 UI 线程（S-001）。
        this._accountSwitchListenerId = addAccountSwitchListenerWithId({ _slot: Int32 =>
            launch {
                Hilog.info(0, "CjTelegram", "[AppRoot] Account switched to slot=${_slot}, reloading login state")
                getAuthViewModel().isLoggedIn = getAuthStorage().hasStoredLogin()
            }
        })

        // ── 立即路由（不阻塞 MTProto full init）──
        // 用快速同步的 getAuthStorage().hasStoredLogin() 决定首帧目标页：已登录 → MainTabPage，
        // 否则 → SplashPage 或 PhoneInputPage（见下）。full MTProto init 放到后台 spawn，
        // 不再让本页卡在 loading 上。
        //
        // QA-3 fix (Part 2): 若尚未登录，但用户此前已经离开过 Splash（点击过 Start Messaging，
        // onboardingStarted=true），说明用户中途退出了登录流程——此时不应重新展示 intro
        // （iOS 只把 intro 当作"未开始过认证"的入口，之后会恢复认证序列），而是直接恢复到
        // PhoneInputPage 继续登录。真正首次运行（onboardingStarted=false）才展示 Splash。
        let hasLogin = getAuthStorage().hasStoredLogin()
        let onboardingStarted = getAuthStorage().hasOnboardingStarted()
        Hilog.info(0, "CjTelegram", "[AppRoot] Immediate route decision, hasStoredLogin=${hasLogin}, onboardingStarted=${onboardingStarted}")
        if (hasLogin) {
            getAuthViewModel().isLoggedIn = true
            getAuthViewModel().authState = AUTH_STATE_READY
            Hilog.info(0, "CjTelegram", "[AppRoot] Stored login → MainTabPage (immediate)")
            routerReplace("MainTabPage", "{}")
        } else if (onboardingStarted) {
            // 先给一个可放行的 authState（登录按钮门控在 authState==WAIT_PHONE）。
            getAuthViewModel().authState = AUTH_STATE_WAIT_PHONE
            Hilog.info(0, "CjTelegram", "[AppRoot] Onboarding already started, not logged in → resume PhoneInputPage (immediate)")
            routerReplace("PhoneInputPage", "")
        } else {
            // 先给 SplashPage 一个可放行的 authState（登录按钮门控在 authState==WAIT_PHONE）。
            getAuthViewModel().authState = AUTH_STATE_WAIT_PHONE
            Hilog.info(0, "CjTelegram", "[AppRoot] First run, not logged in → SplashPage (immediate)")
            routerReplace("SplashPage", "{}")
        }

        // ── 后台 MTProto 客户端初始化 ──
        // 整段 try-catch 包裹：init 抛异常不得杀掉路由/UI（本页已提前 routerReplace 离开）。
        // 完成后若 tryRestoreLogin==true（迟到恢复登录），launch{} 回 UI 线程升级到 MainTabPage。
        spawn {
            try {
                Hilog.info(0, "CjTelegram", "[AppRoot] Starting MTProto initialization (background)...")
                let service = getRealAuthService()

                // P2-318c: 注入活跃 slot 解析器 → MTProtoRegistry._activeSlotProvider（激活多账号引擎）。
                setActiveSlotProvider({ => getAuthStorage().getActiveSlot() })

                service.initializeClient()

                // AccountRecord identity is verified by inputUserSelf, not by
                // locally cached names. Older multi-account builds could leave a
                // display record attached to another account's authorization;
                // migrate that state before restoring the in-memory user.
                let _ = getTelegramCore_AccountManagerService().repairActiveAuthorizationOwner()

                // P2-252b: ReachabilityService addListener → MTProtoClient.triggerReconnect（网络恢复即唤醒重连）。
                getTelegramCore_NetworkService().wireReachabilityReconnect()

                // P2-320c: 注入计量注册钩子 → TransportManager → TCPTransport.setMeteringHooks。
                getMTProtoClient().setMeteringRegistrar { t => getNetworkUsageService().registerTransport(t) }

                let restored = service.tryRestoreLogin()
                Hilog.info(0, "CjTelegram", "[AppRoot] MTProto initialization completed, restored=${restored}")

                if (restored) {
                    // iOS AccountContext keeps these sticker-set metadata views
                    // warm independently of a ChatController. Do the same once
                    // the correct account/DC is initialized, before the user
                    // enters a conversation. These workers never block routing.
                    // These are independent AccountContext-style warmups.
                    // Running them serially delayed availableReactions until
                    // both animated-emoji sticker-set RPCs completed (about
                    // five seconds on device), so an early long press still
                    // opened an empty reaction bar. Start each request on its
                    // own worker and let their service caches deduplicate later
                    // chat-level requests.
                    spawn {
                        preloadAnimatedEmojiMetadata()
                        preloadPopularAnimatedEmojiResources()
                    }
                    spawn { preloadAnimatedEmojiEffectsMetadata() }
                    spawn { preloadQuickReactionLottie() }
                    // AuthStorage restores a login-time snapshot of the self user; refresh it from
                    // the server so profile changes made elsewhere (username, name) are picked up.
                    spawn { let _ = service.refreshCurrentUserFromServer() }
                    launch {
                        // 迟到恢复登录：从 SplashPage 升级到 MainTabPage。
                        getAuthViewModel().isLoggedIn = true
                        getAuthViewModel().authState = AUTH_STATE_READY

                        // 仅当首帧**没有**直接路由到 MainTabPage 时才补这一次跳转。
                        //
                        // 原注释称此处"幂等，已在 MainTabPage 则无害"——该假设是错的：
                        // routerReplace 会无条件替换路由并**重挂整棵子树**，于是
                        // MainTabPage → ChatListPage 被销毁重建，全部初始化跑第二遍。
                        // 真机实证（单次冷启动）：
                        //   38.566 Stored login → MainTabPage (immediate)
                        //   38.731 Registered account switch listener id=1   ← 实例 A
                        //   38.731 Loading real dialogs...                   ← 实例 A 发起网络
                        //   38.828 cleanup: removed listener id=1            ← 实例 A 被销毁
                        //   38.863 Loading real dialogs...                   ← 实例 B 再发一次
                        // 实例 A 虽被 cleanup，其已 spawn 的 loadRealDialogs 仍在执行，
                        // 故 getDifference / getDialogs 等全部翻倍。
                        //
                        // hasLogin 为真时首帧已在 MainTabPage（见上方立即路由分支），
                        // 此处跳过即可；为假时说明当前在 Splash/PhoneInput，仍需升级。
                        if (hasLogin) {
                            Hilog.info(0, "CjTelegram",
                                "[AppRoot] Late-restored login: already on MainTabPage since first frame, skip re-route")
                        } else {
                            Hilog.info(0, "CjTelegram", "[AppRoot] Late-restored login → MainTabPage")
                            routerReplace("MainTabPage", "{}")
                        }
                    }
                } else {
                    launch {
                        // 未恢复登录：确保 SplashPage 登录按钮可放行（authState==WAIT_PHONE）。
                        getAuthViewModel().isLoggedIn = false
                        getAuthViewModel().authState = AUTH_STATE_WAIT_PHONE
                        let onboarding = getAuthStorage().hasOnboardingStarted()
                        Hilog.info(0, "CjTelegram", "[AppRoot] Background init: not logged in, authState=WAIT_PHONE, onboardingStarted=${onboarding}")
                        if (onboarding) {
                            routerReplace("PhoneInputPage", "")
                        } else {
                            routerReplace("SplashPage", "{}")
                        }
                    }
                }
            } catch (e: Exception) {
                Hilog.error(0, "CjTelegram", "[AppRoot] Background MTProto init failed: ${e}")
                launch {
                    // init 失败也要放行 SplashPage 登录按钮，避免用户卡死。
                    getAuthViewModel().authState = AUTH_STATE_WAIT_PHONE
                }
            }
        }
    }

    private func teardown(): Unit {
        // P2-010: Deregister account switch listener to avoid dangling callbacks
        if (this._accountSwitchListenerId >= 0) {
            removeAccountSwitchListener(this._accountSwitchListenerId)
            this._accountSwitchListenerId = -1
        }
    }

    func build() {
        Column {
            LoadingProgress()
                .width(48)
                .height(48)
                .color(0x317AFF)
            Text(trSource("Telegram"))
                .fontSize(18)
                .fontColor(0x8E8E93)
                .margin(top: 16)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFF)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onAppear({ => this.decideInitialRoute() })
        .onDisAppear({ => this.teardown() })
    }
}
