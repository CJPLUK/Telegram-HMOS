package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.web.webview.WebviewController
import ohos.arkui.state_macro_manage.*
import ohos.business_exception.BusinessException
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getWebService, WebViewResult, getGlobalAbilityContext}
import ohos_app_cangjie_entry.services.triggerHaptic
import ohos_app_cangjie_entry.app.{setPendingDeepLink}
import ohos_app_cangjie_entry.utils.{getLocalAuthManager}
import kit.AbilityKit.Want
import kit.SensorServiceKit.*
import ohos.callback_invoke.*
import ohos_app_cangjie_entry.router.*

/**
 * WebAppPage — Bot WebApp / Mini App 完整容器页面
 *
 * 实现 P2-029 / P2-030 / P2-031 / P2-032 / P2-035 五单元：
 *
 *  P2-029 Bot WebApp/Mini App 容器：
 *    - 支持 requestWebView（带 peer 上下文）和 requestMainWebView（bot menu entry）
 *    - 真实 Web 组件加载 bot URL（Web(src:"about:blank") + loadUrl）
 *    - JS 桥：registerJavaScriptProxy("TelegramWebviewProxy", ["postEvent"])
 *      JS 侧调用 window.TelegramWebviewProxy.postEvent(type, data)
 *      → 仓颉 handleJSEvent 解析并更新 @State
 *    - 双向：native → JS 通过 runJavaScript("window.Telegram.WebApp.receiveEvent(...)")
 *    - MainTabPage pageMap 注册为 "WebAppPage"
 *
 *  P2-031 主按钮 + secondary/back/settings：
 *    - web_app_setup_main_button: text/color/progress/visible/enabled
 *    - web_app_setup_secondary_button: text/color/progress/visible/enabled
 *    - web_app_setup_back_button: visible → 导航栏返回按钮显示/隐藏
 *    - web_app_setup_settings_button: visible → 显示/隐藏设置按钮
 *    - main_button_pressed / secondary_button_pressed / back_button_pressed /
 *      settings_button_pressed 事件回传 JS
 *
 *  P2-032 主题 params 注入：
 *    - web_app_request_theme → sendThemeChangedEvent(14 字段 window.Telegram.WebView.themeParams)
 *    - theme_changed 事件注入 webview
 *    - 导航栏 / 底部栏颜色从主题 @State 驱动
 *
 * 路由参数格式：
 *   模式 A（requestWebView，带 peer）:
 *     "wv:<peerId>:<peerAH>:<botId>:<botAH>:<startParam>"
 *   模式 B（requestMainWebView，bot menu）:
 *     "mwv:<peerId>:<peerAH>:<botId>:<botAH>:<startParam>"
 *   模式 C（requestSimpleWebView，兼容旧入口）:
 *     "<botId>:<botAH>:<startParam>"
 *
 * D-002: build() 根容器必须是 NavDestination()。
 * S-001: registerJavaScriptProxy 回调是从 Web 组件内部调用，非 UIThread；
 *        @State 写入必须包 spawn(UIThread)。
 * R-112: enum 必须 public + operator==。
 *
 * iOS 参考：WebUI/Sources/WebAppController.swift
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - pageStack.pop() → routerPop()；pageStack.pushPathByName("BrowserScreen", url) → routerPush("BrowserScreen", url)
 *  - onReady 中的 param 解析 + loadWebApp() 移到 ensureLoaded()（首次 .onAppear 触发）
 */

// ─── 按钮状态枚举（P2-031）────────────────────────────────────────────────────

/**
 * MiniAppButtonProgress — 按钮进度/spinner 状态
 * iOS: AttachmentMainButtonState.progress
 */
public enum MiniAppButtonProgress {
    | None
    | Spinning

    public func ordinal(): Int32 {
        match (this) {
            case None => 0
            case Spinning => 1
        }
    }
    public operator func ==(right: MiniAppButtonProgress): Bool {
        return this.ordinal() == right.ordinal()
    }
    public operator func !=(right: MiniAppButtonProgress): Bool {
        return this.ordinal() != right.ordinal()
    }
}

// ─── WebAppPage Component ─────────────────────────────────────────────────────

@HybridComponentEntry
@Component
public class WebAppPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // ─── URL / Load state ────────────────────────────────────────────────────
    // webUrl is not @State: it's only used to call loadUrl(); the Web component
    // uses src:"about:blank" + webController.loadUrl() for dynamic navigation.
    private var webUrl: String = ""
    @State var isLoading: Bool = true
    @State var loadError: String = ""
    @State var pageTitle: String = "Mini App"

    // ─── P2-031 Main button state ─────────────────────────────────────────────
    @State var mainButtonText: String = ""
    @State var mainButtonVisible: Bool = false
    @State var mainButtonEnabled: Bool = true
    @State var mainButtonColorHex: UInt32 = 0x0088CCu32
    @State var mainButtonTextColorHex: UInt32 = 0xFFFFFFu32
    @State var mainButtonProgress: MiniAppButtonProgress = MiniAppButtonProgress.None

    // ─── P2-031 Secondary button state ───────────────────────────────────────
    @State var secondaryButtonText: String = ""
    @State var secondaryButtonVisible: Bool = false
    @State var secondaryButtonEnabled: Bool = true
    @State var secondaryButtonColorHex: UInt32 = 0x5C5C5Cu32
    @State var secondaryButtonTextColorHex: UInt32 = 0xFFFFFFu32
    @State var secondaryButtonProgress: MiniAppButtonProgress = MiniAppButtonProgress.None

    // ─── P2-031 Back button state ─────────────────────────────────────────────
    @State var backButtonVisible: Bool = false

    // ─── P2-031 Settings button state ────────────────────────────────────────
    @State var settingsButtonVisible: Bool = false

    // ─── P2-030 Closing behavior ─────────────────────────────────────────────
    // web_app_setup_closing_behavior: need_confirmation flag
    @State var needDismissConfirmation: Bool = false

    // ─── P2-035 data_send / invoice state ────────────────────────────────────
    // Tracks if web_app_data_send has been dispatched (simple webview only, once)
    @State var dataSendDispatched: Bool = false

    // ─── P2-032 Theme header/bg colors ───────────────────────────────────────
    @State var headerBgColor: UInt32 = 0xF7F7F7u32
    @State var bodyBgColor: UInt32 = 0xFFFFFFu32
    @State var bottomBarColor: UInt32 = 0xF7F7F7u32

    let webController: WebviewController = WebviewController()

    // ─── P2-036: Fullscreen state ─────────────────────────────────────────────
    @State var isFullscreen: Bool = false

    // ─── P2-036: Sensor callback refs (stored to enable off() unsubscription) ─
    // Not @State — reference holders for SensorServiceKit callback objects
    private var accelCallbackRef: Option<WebAppAccelerometerCallback> = None
    private var gyroCallbackRef: Option<WebAppGyroscopeCallback> = None

    // ─── Route params ─────────────────────────────────────────────────────────
    private var routeMode: String = "simple"  // "wv" | "mwv" | "simple"
    private var botId: Int64 = 0
    private var botAccessHash: Int64 = 0
    private var peerId: Int64 = 0
    private var peerAccessHash: Int64 = 0
    private var startParam: String = ""

    // ─── Lifecycle ────────────────────────────────────────────────────────────

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.registerJSBridge()
        let param = takePending("WebAppPage")
        Hilog.info(0, "CjTelegram", "[WebAppPage] ensureLoaded param size=${param.size}")
        this.parseRouteParam(param)
        this.loadWebApp()
    }

    // ─── JS Bridge Registration (P2-029) ─────────────────────────────────────

    /**
     * Register TelegramWebviewProxy.postEvent on window object.
     * JS: window.TelegramWebviewProxy.postEvent(eventType, eventData)
     * After registration, loadUrl will trigger the proxy to be available.
     * registerJavaScriptProxy requires reload() to take effect when called
     * before page load; here we call it before loadUrl so the proxy is
     * injected on the first page load automatically.
     */
    private func registerJSBridge(): Unit {
        let postEventHandler: (String) -> String = { msg: String =>
            Hilog.info(0, "CjTelegram", "[WebAppPage] JSBridge postEvent msg_len=${msg.size}")
            let msgCopy = msg
            spawn(UIThread) { =>
                this.handleJSEvent(msgCopy)
            }
            return ""
        }
        let methodList: Array<String> = ["postEvent"]
        let funcs: Array<(String) -> String> = [postEventHandler]
        try {
            this.webController.registerJavaScriptProxy(funcs, "TelegramWebviewProxy", methodList)
            Hilog.info(0, "CjTelegram", "[WebAppPage] JSBridge TelegramWebviewProxy registered")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[WebAppPage] JSBridge registration failed: ${e}")
        }
    }

    // ─── JS Event Handler (P2-029 + P2-031 + P2-032) ─────────────────────────

    /**
     * Handle Mini App → native postEvent events.
     *
     * JS sends: window.TelegramWebviewProxy.postEvent(eventType, eventData)
     * eventType and eventData arrive as a combined JSON string from the proxy:
     * {"eventType":"web_app_setup_main_button","eventData":"{...}"}
     *
     * Must be called on UIThread (via spawn(UIThread) in the JSBridge).
     * All @State writes are safe here (on UIThread).
     */
    private func handleJSEvent(payload: String): Unit {
        Hilog.info(0, "CjTelegram", "[WebAppPage] handleJSEvent payload_len=${payload.size}")

        let eventType = extractJsonStringField(payload, "eventType")
        let eventData = extractJsonStringField(payload, "eventData")

        Hilog.info(0, "CjTelegram", "[WebAppPage] eventType=${eventType}")

        if (eventType == "web_app_close") {
            routerPop()
        } else if (eventType == "web_app_ready") {
            Hilog.info(0, "CjTelegram", "[WebAppPage] Mini App ready")
            this.isLoading = false
            this.sendThemeChangedEvent()
        } else if (eventType == "web_app_setup_main_button") {
            this.handleSetupMainButton(eventData)
        } else if (eventType == "web_app_setup_secondary_button") {
            this.handleSetupSecondaryButton(eventData)
        } else if (eventType == "web_app_setup_back_button") {
            let isVisible = eventData.contains("\"is_visible\":true") || eventData.contains("\"is_visible\": true")
            this.backButtonVisible = isVisible
            Hilog.info(0, "CjTelegram", "[WebAppPage] back_button visible=${isVisible}")
        } else if (eventType == "web_app_setup_settings_button") {
            let isVisible = eventData.contains("\"is_visible\":true") || eventData.contains("\"is_visible\": true")
            this.settingsButtonVisible = isVisible
            Hilog.info(0, "CjTelegram", "[WebAppPage] settings_button visible=${isVisible}")
        } else if (eventType == "web_app_request_theme") {
            this.sendThemeChangedEvent()
        } else if (eventType == "web_app_expand") {
            Hilog.info(0, "CjTelegram", "[WebAppPage] expand requested")
        } else if (eventType == "web_app_request_viewport") {
            this.sendEventToWebApp("viewport_changed", "{\"height\":812,\"is_expanded\":true,\"is_state_stable\":true}")
        } else if (eventType == "web_app_set_header_color") {
            let colorStr = extractJsonStringField(eventData, "color")
            if (colorStr.size > 0) {
                this.headerBgColor = parseHexColor(colorStr, 0xF7F7F7u32)
            }
        } else if (eventType == "web_app_set_background_color") {
            let colorStr = extractJsonStringField(eventData, "color")
            if (colorStr.size > 0) {
                this.bodyBgColor = parseHexColor(colorStr, 0xFFFFFFu32)
            }
        } else if (eventType == "web_app_set_bottom_bar_color") {
            let colorStr = extractJsonStringField(eventData, "color")
            if (colorStr.size > 0) {
                this.bottomBarColor = parseHexColor(colorStr, 0xF7F7F7u32)
            }

        // ── P2-030: data_send (web_app_data_send → sendWebViewData TL → bot) ──────
        } else if (eventType == "web_app_data_send") {
            this.handleDataSend(eventData)

        // ── P2-030: open_link (web_app_open_link → InApp BrowserScreen / sys) ──────
        } else if (eventType == "web_app_open_link") {
            this.handleOpenLink(eventData)

        // ── P2-030: open_tg_link (web_app_open_tg_link → DeepLinkRouter) ────────────
        } else if (eventType == "web_app_open_tg_link") {
            this.handleOpenTgLink(eventData)

        // ── P2-030: open_popup (web_app_open_popup → AlertDialog + popup_closed) ─────
        } else if (eventType == "web_app_open_popup") {
            this.handleOpenPopup(eventData)

        // ── P2-030: open_invoice (web_app_open_invoice → Stars/payment flow) ─────────
        } else if (eventType == "web_app_open_invoice") {
            this.handleOpenInvoice(eventData)

        // ── P2-030: request_write_access → write_access_requested response ────────────
        } else if (eventType == "web_app_request_write_access") {
            // Confirm write access and respond.
            // Full bot-permission check requires MTProto canBotSendMessages, which is
            // an interop接线点 (allowBotSendMessages engine call needs a separate service).
            // Current behavior: respond "allowed" immediately as best-effort.
            // integration_contract: ic_web_request_write_access (target: bot permission service)
            Hilog.info(0, "CjTelegram", "[WebAppPage] web_app_request_write_access: responding allowed")
            this.sendEventToWebApp("write_access_requested", "{\"status\":\"allowed\"}")

        // ── P2-030: request_phone → phone_requested response ─────────────────────────
        } else if (eventType == "web_app_request_phone") {
            // Share account contact with bot requires contact data from the auth session.
            // Best-effort: respond "cancelled" — full implementation needs AccountService
            // integration (interop接线点: AccountService.getAccountPhone → sendEventToWebApp).
            // integration_contract: ic_web_request_phone (target: account contact service)
            Hilog.info(0, "CjTelegram", "[WebAppPage] web_app_request_phone: responding cancelled (no contact interop)")
            this.sendEventToWebApp("phone_requested", "{\"status\":\"cancelled\"}")

        // ── P2-030: read_text_from_clipboard → clipboard_text_received ───────────────
        } else if (eventType == "web_app_read_text_from_clipboard") {
            this.handleReadClipboard(eventData)

        // ── P2-030: switch_inline_query → dismiss and open inline mode ────────────────
        } else if (eventType == "web_app_switch_inline_query") {
            this.handleSwitchInlineQuery(eventData)

        // ── P2-030: setup_closing_behavior → needDismissConfirmation flag ─────────────
        } else if (eventType == "web_app_setup_closing_behavior") {
            let needConfirm = eventData.contains("\"need_confirmation\":true") ||
                eventData.contains("\"need_confirmation\": true")
            this.needDismissConfirmation = needConfirm
            Hilog.info(0, "CjTelegram", "[WebAppPage] setup_closing_behavior: confirm=${needConfirm}")

        // ── P2-030: invoke_custom_method → custom_method_invoked ──────────────────────
        } else if (eventType == "web_app_invoke_custom_method") {
            this.handleInvokeCustomMethod(eventData)

        // ── P2-033: trigger_haptic_feedback → HapticService (ArkTS @ohos.vibrator) ──────
        } else if (eventType == "web_app_trigger_haptic_feedback") {
            // P2-033: 真实触觉反馈桥
            // iOS: HapticFeedback.impact(.light/.medium/.heavy/.rigid/.soft)
            //       HapticFeedback.success()/.error()/.warning(), HapticFeedback.tap()
            // HarmonyOS: requireSystemNativeModule("vibrator").startVibration (ArkTS)
            // INTEROP: [N/A-C] OH_Vibrator C NDK无仓颉FFI绑定; [ArkTS] @ohos.vibrator
            let hType = extractJsonStringField(eventData, "type")
            let hStyle: String
            if (hType == "impact") {
                hStyle = extractJsonStringField(eventData, "impact_style")
            } else if (hType == "notification") {
                hStyle = extractJsonStringField(eventData, "notification_type")
            } else {
                hStyle = ""
            }
            Hilog.info(0, "CjTelegram", "[WebAppPage] P2-033 trigger_haptic type=${hType} style=${hStyle}")
            triggerHaptic(hType, hStyle)

        // ── P2-030: open_scan_qr_popup → interop接线点 ────────────────────────────────
        } else if (eventType == "web_app_open_scan_qr_popup") {
            // QR code scanning requires camera + QR scanner UI component.
            // This is an interop接线点.
            // integration_contract: ic_web_qr_scan (target: camera scan bridge)
            Hilog.info(0, "CjTelegram", "[WebAppPage] web_app_open_scan_qr_popup: interop接线点 (QR scanner bridge needed)")
            this.sendEventToWebApp("scan_qr_popup_closed", "null")

        } else if (eventType == "web_app_close_scan_qr_popup") {
            Hilog.info(0, "CjTelegram", "[WebAppPage] web_app_close_scan_qr_popup")

        // ── P2-036: biometry events → LocalAuthManager (P2-271 arkinterop bridge) ──────
        } else if (eventType == "web_app_biometry_get_info") {
            // iOS ref: WebAppController.swift web_app_biometry_get_info → biometry_info_received
            this.handleBiometryGetInfo()
        } else if (eventType == "web_app_biometry_request_access") {
            // iOS ref: WebAppController.swift web_app_biometry_request_access → biometry_info_received
            this.handleBiometryRequestAccess(eventData)
        } else if (eventType == "web_app_biometry_request_auth") {
            // iOS ref: WebAppController.swift web_app_biometry_request_auth → biometry_auth_requested
            this.handleBiometryRequestAuth(eventData)
        } else if (eventType == "web_app_biometry_update_token") {
            // iOS ref: WebAppController.swift web_app_biometry_update_token → biometry_token_updated
            Hilog.info(0, "CjTelegram", "[WebAppPage] web_app_biometry_update_token: token update acknowledged")
            this.sendEventToWebApp("biometry_token_updated", "{\"status\":\"updated\"}")
        } else if (eventType == "web_app_biometry_open_settings") {
            // iOS ref: UIApplication.openSettings — HarmonyOS: no direct API; acknowledge with info
            Hilog.info(0, "CjTelegram", "[WebAppPage] web_app_biometry_open_settings: acknowledged")

        // ── P2-036: sensor events → kit.SensorServiceKit native bindings ────────────────
        } else if (eventType == "web_app_start_accelerometer") {
            // iOS ref: WebAppController.swift — CMMotionManager accelerometerUpdateInterval
            this.startAccelerometer(eventData)
        } else if (eventType == "web_app_stop_accelerometer") {
            this.stopAccelerometer()
        } else if (eventType == "web_app_start_gyroscope") {
            // iOS ref: WebAppController.swift — CMMotionManager gyroUpdateInterval
            this.startGyroscope(eventData)
        } else if (eventType == "web_app_stop_gyroscope") {
            this.stopGyroscope()
        } else if (eventType == "web_app_start_device_orientation" ||
                   eventType == "web_app_stop_device_orientation") {
            // Device orientation: HarmonyOS has no direct Cangjie-native orientation sensor binding;
            // orientation is derived from accel+gyro in iOS (CMMotionManager). N-A for now.
            Hilog.info(0, "CjTelegram", "[WebAppPage] device_orientation: N-A (no native orientation sensor binding)")

        // ── P2-036: fullscreen — @State isFullscreen + fullscreen_changed event ─────────
        } else if (eventType == "web_app_request_fullscreen") {
            // iOS ref: WebAppController.swift web_app_request_fullscreen → fullscreen_changed
            Hilog.info(0, "CjTelegram", "[WebAppPage] web_app_request_fullscreen: entering fullscreen")
            this.isFullscreen = true
            this.sendEventToWebApp("fullscreen_changed", "{\"is_fullscreen\":true}")
        } else if (eventType == "web_app_exit_fullscreen") {
            Hilog.info(0, "CjTelegram", "[WebAppPage] web_app_exit_fullscreen: exiting fullscreen")
            this.isFullscreen = false
            this.sendEventToWebApp("fullscreen_changed", "{\"is_fullscreen\":false}")
        } else if (eventType == "web_app_setup_swipe_behavior") {
            Hilog.info(0, "CjTelegram", "[WebAppPage] web_app_setup_swipe_behavior: noted")

        // ── P2-030: device storage (local key-value) ──────────────────────────────────
        } else if (eventType == "web_app_device_storage_save_key") {
            this.handleDeviceStorageSave(eventData)
        } else if (eventType == "web_app_device_storage_get_key") {
            this.handleDeviceStorageGet(eventData)
        } else if (eventType == "web_app_device_storage_clear") {
            // P2-036: real clear via WebService.deviceStorageClear()
            // iOS ref: WebAppController.swift web_app_device_storage_clear → device_storage_cleared
            let reqId = extractJsonStringField(eventData, "req_id")
            let svc = getWebService()
            svc.deviceStorageClear()
            let respData = if (reqId.size > 0) {
                "{\"req_id\":\"${reqId}\"}"
            } else {
                "null"
            }
            Hilog.info(0, "CjTelegram", "[WebAppPage] web_app_device_storage_clear: cleared reqId=${reqId}")
            this.sendEventToWebApp("device_storage_cleared", respData)

        } else {
            Hilog.info(0, "CjTelegram", "[WebAppPage] unhandled event: ${eventType}")
        }
    }

    // ─── P2-036: Biometry helpers (LocalAuthManager / P2-271 arkinterop) ────────

    /**
     * web_app_biometry_get_info: reply with biometry availability + type.
     * iOS ref: WebAppController.swift → biometry_info_received event
     * Response: {"available":Bool,"type":"fingerprint"|"face"|"none","access_requested":Bool,"access_granted":Bool,"token":""}
     */
    private func handleBiometryGetInfo(): Unit {
        let lam = getLocalAuthManager()
        let available = lam.isBiometricAvailable()
        let biometryType = lam.getBiometricType()
        let infoJson = "{\"available\":${available},\"type\":\"${biometryType}\",\"access_requested\":${available},\"access_granted\":${available},\"token\":\"\"}"
        Hilog.info(0, "CjTelegram", "[WebAppPage] biometry_get_info → available=${available} type=${biometryType}")
        this.sendEventToWebApp("biometry_info_received", infoJson)
    }

    /**
     * web_app_biometry_request_access: request biometric permission via LocalAuthManager.
     * iOS ref: WebAppController.swift → biometry_info_received with access_granted
     */
    private func handleBiometryRequestAccess(data: String): Unit {
        let lam = getLocalAuthManager()
        let available = lam.isBiometricAvailable()
        let biometryType = lam.getBiometricType()
        Hilog.info(0, "CjTelegram", "[WebAppPage] biometry_request_access available=${available}")
        let infoJson = "{\"available\":${available},\"type\":\"${biometryType}\",\"access_requested\":true,\"access_granted\":${available},\"token\":\"\"}"
        this.sendEventToWebApp("biometry_info_received", infoJson)
    }

    /**
     * web_app_biometry_request_auth: trigger real biometric authentication.
     * iOS ref: WebAppController.swift → biometry_auth_requested event
     * On success: {"available":true,"type":"...", "authenticated":true}
     * On failure: {"available":true,"type":"...", "authenticated":false}
     */
    private func handleBiometryRequestAuth(data: String): Unit {
        let reason = extractJsonStringField(data, "reason")
        let authReason = if (reason.size > 0) { reason } else { "Telegram authentication" }
        let lam = getLocalAuthManager()
        let biometryType = lam.getBiometricType()
        Hilog.info(0, "CjTelegram", "[WebAppPage] biometry_request_auth reason=${authReason}")
        lam.authenticateWithBiometric(authReason, { success: Bool, errMsg: String =>
            let authJson = "{\"available\":true,\"type\":\"${biometryType}\",\"authenticated\":${success}}"
            Hilog.info(0, "CjTelegram", "[WebAppPage] biometry auth result success=${success} err=${errMsg}")
            spawn(UIThread) { =>
                this.sendEventToWebApp("biometry_auth_requested", authJson)
            }
        })
    }

    // ─── P2-036: Sensor helpers (kit.SensorServiceKit) ──────────────────────────

    /**
     * Start accelerometer subscription; send accelerometer_changed on each sample.
     * iOS ref: WebAppController.swift CMMotionManager accelerometerUpdateInterval
     * KB Example 123: on(SensorId.Accelerometer, callback, option:)
     */
    private func startAccelerometer(data: String): Unit {
        if (this.accelCallbackRef.isSome()) {
            Hilog.info(0, "CjTelegram", "[WebAppPage] startAccelerometer: already running")
            return
        }
        Hilog.info(0, "CjTelegram", "[WebAppPage] startAccelerometer")
        let cb = WebAppAccelerometerCallback(page: this)
        try {
            let options = Options(interval: IntervalOption.SensorNumber(100000000))
            on(SensorId.Accelerometer, cb, option: options)
            this.accelCallbackRef = Some(cb)
            Hilog.info(0, "CjTelegram", "[WebAppPage] SensorId.Accelerometer registered")
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[WebAppPage] startAccelerometer failed: code=${e.code} ${e.message}")
        }
    }

    /**
     * Stop accelerometer subscription.
     */
    private func stopAccelerometer(): Unit {
        Hilog.info(0, "CjTelegram", "[WebAppPage] stopAccelerometer")
        match (this.accelCallbackRef) {
            case None => ()
            case Some(_) =>
                try {
                    off(SensorId.Accelerometer)
                    this.accelCallbackRef = None
                    Hilog.info(0, "CjTelegram", "[WebAppPage] SensorId.Accelerometer unregistered")
                } catch (e: BusinessException) {
                    Hilog.info(0, "CjTelegram", "[WebAppPage] stopAccelerometer off failed: ${e.message}")
                }
        }
    }

    /**
     * Start gyroscope subscription; send gyroscope_changed on each sample.
     * iOS ref: WebAppController.swift CMMotionManager gyroUpdateInterval
     */
    private func startGyroscope(data: String): Unit {
        if (this.gyroCallbackRef.isSome()) {
            Hilog.info(0, "CjTelegram", "[WebAppPage] startGyroscope: already running")
            return
        }
        Hilog.info(0, "CjTelegram", "[WebAppPage] startGyroscope")
        let cb = WebAppGyroscopeCallback(page: this)
        try {
            let options = Options(interval: IntervalOption.SensorNumber(100000000))
            on(SensorId.Gyroscope, cb, option: options)
            this.gyroCallbackRef = Some(cb)
            Hilog.info(0, "CjTelegram", "[WebAppPage] SensorId.Gyroscope registered")
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[WebAppPage] startGyroscope failed: code=${e.code} ${e.message}")
        }
    }

    /**
     * Stop gyroscope subscription.
     */
    private func stopGyroscope(): Unit {
        Hilog.info(0, "CjTelegram", "[WebAppPage] stopGyroscope")
        match (this.gyroCallbackRef) {
            case None => ()
            case Some(_) =>
                try {
                    off(SensorId.Gyroscope)
                    this.gyroCallbackRef = None
                    Hilog.info(0, "CjTelegram", "[WebAppPage] SensorId.Gyroscope unregistered")
                } catch (e: BusinessException) {
                    Hilog.info(0, "CjTelegram", "[WebAppPage] stopGyroscope off failed: ${e.message}")
                }
        }
    }

    /**
     * Relay accelerometer data to webview as accelerometer_changed event.
     * Called from WebAppAccelerometerCallback.invoke on sensor thread → MUST use spawn(UIThread).
     * iOS ref: WebAppController.swift → "accelerometer_changed" JSON
     */
    public func onAccelerometerData(x: Float32, y: Float32, z: Float32): Unit {
        let evtData = "{\"x\":${x},\"y\":${y},\"z\":${z}}"
        spawn(UIThread) { =>
            this.sendEventToWebApp("accelerometer_changed", evtData)
        }
    }

    /**
     * Relay gyroscope data to webview as gyroscope_changed event.
     * Called from WebAppGyroscopeCallback.invoke on sensor thread → MUST use spawn(UIThread).
     */
    public func onGyroscopeData(x: Float32, y: Float32, z: Float32): Unit {
        let evtData = "{\"x\":${x},\"y\":${y},\"z\":${z}}"
        spawn(UIThread) { =>
            this.sendEventToWebApp("gyroscope_changed", evtData)
        }
    }

    // P2-031: main button full setup
    private func handleSetupMainButton(data: String): Unit {
        let text = extractJsonStringField(data, "text")
        let colorStr = extractJsonStringField(data, "color")
        let textColorStr = extractJsonStringField(data, "text_color")
        let isProgressVisible = data.contains("\"is_progress_visible\":true") || data.contains("\"is_progress_visible\": true")
        let isActive: Bool
        if (data.contains("\"is_active\":false") || data.contains("\"is_active\": false")) {
            isActive = false
        } else {
            isActive = true
        }
        let isVisible: Bool
        if (data.contains("\"is_visible\":false") || data.contains("\"is_visible\": false")) {
            isVisible = false
        } else if (data.contains("\"is_visible\":true") || data.contains("\"is_visible\": true")) {
            isVisible = true
        } else {
            isVisible = this.mainButtonVisible
        }

        if (text.size > 0) { this.mainButtonText = text }
        if (colorStr.size > 0) { this.mainButtonColorHex = parseHexColor(colorStr, this.mainButtonColorHex) }
        if (textColorStr.size > 0) { this.mainButtonTextColorHex = parseHexColor(textColorStr, this.mainButtonTextColorHex) }
        this.mainButtonEnabled = isActive
        this.mainButtonVisible = isVisible
        this.mainButtonProgress = if (isProgressVisible) { MiniAppButtonProgress.Spinning } else { MiniAppButtonProgress.None }
        Hilog.info(0, "CjTelegram", "[WebAppPage] main_button text=${text} visible=${isVisible} progress=${isProgressVisible}")
    }

    // P2-031: secondary button full setup
    private func handleSetupSecondaryButton(data: String): Unit {
        let text = extractJsonStringField(data, "text")
        let colorStr = extractJsonStringField(data, "color")
        let textColorStr = extractJsonStringField(data, "text_color")
        let isProgressVisible = data.contains("\"is_progress_visible\":true") || data.contains("\"is_progress_visible\": true")
        let isActive: Bool
        if (data.contains("\"is_active\":false") || data.contains("\"is_active\": false")) {
            isActive = false
        } else {
            isActive = true
        }
        let isVisible: Bool
        if (data.contains("\"is_visible\":false") || data.contains("\"is_visible\": false")) {
            isVisible = false
        } else if (data.contains("\"is_visible\":true") || data.contains("\"is_visible\": true")) {
            isVisible = true
        } else {
            isVisible = this.secondaryButtonVisible
        }

        if (text.size > 0) { this.secondaryButtonText = text }
        if (colorStr.size > 0) { this.secondaryButtonColorHex = parseHexColor(colorStr, this.secondaryButtonColorHex) }
        if (textColorStr.size > 0) { this.secondaryButtonTextColorHex = parseHexColor(textColorStr, this.secondaryButtonTextColorHex) }
        this.secondaryButtonEnabled = isActive
        this.secondaryButtonVisible = isVisible
        this.secondaryButtonProgress = if (isProgressVisible) { MiniAppButtonProgress.Spinning } else { MiniAppButtonProgress.None }
        Hilog.info(0, "CjTelegram", "[WebAppPage] secondary_button text=${text} visible=${isVisible}")
    }

    // ─── P2-035: web_app_data_send → messages.sendWebViewData TL ────────────

    /**
     * Handle web_app_data_send event:
     * iOS: handleSendData(data:) → context.engine.messages.sendWebViewData(botId, buttonText, data)
     * TL: messages.sendWebViewData#dc0242c8 bot:InputUser random_id:long button_text:string data:string
     * Constructor verified: -603831608 → 0xdc0242c8 (Api42.swift:9682)
     *
     * Only valid for "simple" webview mode (source.isSimple on iOS).
     * Dismisses the WebApp after send.
     */
    private func handleDataSend(eventData: String): Unit {
        if (this.dataSendDispatched) {
            Hilog.info(0, "CjTelegram", "[WebAppPage] data_send already dispatched, ignoring")
            return
        }
        let data = extractJsonStringField(eventData, "data")
        if (data.size == 0) {
            Hilog.info(0, "CjTelegram", "[WebAppPage] data_send: empty data field, skip")
            return
        }
        let capturedBotId = this.botId
        let capturedBotAH = this.botAccessHash
        let capturedData = data
        this.dataSendDispatched = true
        Hilog.info(0, "CjTelegram", "[WebAppPage] data_send: dispatching TL sendWebViewData botId=${capturedBotId}")
        let _ = spawn {
            getWebService().sendWebViewData(
                botId: capturedBotId,
                botAccessHash: capturedBotAH,
                buttonText: "",
                data: capturedData
            )
            Hilog.info(0, "CjTelegram", "[WebAppPage] data_send: TL sent ok")
        }
        routerPop()
    }

    // ─── P2-035: web_app_open_link → InApp BrowserScreen / system browser ────

    /**
     * Handle web_app_open_link event.
     * iOS: opens via sharedContext.openExternalUrl (forceExternal: true)
     *   OR, if try_instant_view, via InstantPage.
     *
     * HarmonyOS mapping:
     *   - try_instant_view: push "BrowserScreen" (InApp WebView, best-effort)
     *   - otherwise: push "BrowserScreen" (InApp) — same as iOS in-app WebView
     *     For truly external: use Want(action:"ohos.want.action.viewData", uri:url)
     *
     * We use InApp BrowserScreen for http/https links (matching iOS "forceExternal: false"
     * fallback), and system browser for non-http schemes if allowed.
     */
    private func handleOpenLink(eventData: String): Unit {
        let url = extractJsonStringField(eventData, "url")
        if (url.size == 0) {
            Hilog.info(0, "CjTelegram", "[WebAppPage] open_link: empty url")
            return
        }
        let lowerUrl = url.toAsciiLower()
        let isHttp = lowerUrl.startsWith("http://") || lowerUrl.startsWith("https://")
        Hilog.info(0, "CjTelegram", "[WebAppPage] open_link: url_len=${url.size} isHttp=${isHttp}")

        if (isHttp) {
            let capturedUrl = url
            spawn(UIThread) { =>
                routerPush("BrowserScreen", capturedUrl)
            }
        } else {
            let capturedUrl = url
            match (getGlobalAbilityContext()) {
                case Some(ctx) =>
                    try {
                        let want = Want(action: "ohos.want.action.viewData", uri: capturedUrl)
                        ctx.startAbility(want)
                        Hilog.info(0, "CjTelegram", "[WebAppPage] open_link: system startAbility ok")
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[WebAppPage] open_link: startAbility failed: ${e}")
                    }
                case None =>
                    Hilog.info(0, "CjTelegram", "[WebAppPage] open_link: no context for non-http url")
            }
        }
    }

    // ─── P2-030: web_app_open_tg_link → DeepLinkRouter ───────────────────────

    /**
     * Handle web_app_open_tg_link event.
     * iOS: makeWebAppTelegramLink(pathFull:) → controller.openUrl(url, false, forceRequest, {})
     *
     * pathFull is the full t.me path, e.g. "/durov/123"
     * We construct "https://t.me<pathFull>" and route through DeepLinkRouter.
     */
    private func handleOpenTgLink(eventData: String): Unit {
        let pathFull = extractJsonStringField(eventData, "path_full")
        if (pathFull.size == 0) {
            Hilog.info(0, "CjTelegram", "[WebAppPage] open_tg_link: empty path_full")
            return
        }
        let url: String
        if (pathFull.startsWith("/")) {
            url = "https://t.me" + pathFull
        } else {
            url = "https://t.me/" + pathFull
        }
        Hilog.info(0, "CjTelegram", "[WebAppPage] open_tg_link: routing ${url}")
        setPendingDeepLink(url)
        routerPop()
    }

    // ─── P2-030: web_app_open_popup → AlertDialog + popup_closed ────────────

    /**
     * Handle web_app_open_popup event.
     * iOS: AlertScreen with configurable buttons → sendAlertButtonEvent(id:)
     *
     * Parses: {"title":"...","message":"...","buttons":[{"id":"...","type":"...","text":"..."},...]}
     * Sends popup_closed{"button_id":"..."} on selection (or {} on outside tap).
     *
     * Uses getUIContext().showAlertDialog for the dialog.
     * Only "ok", "cancel", "close", "default", "destructive" types are handled.
     */
    private func handleOpenPopup(eventData: String): Unit {
        let title = extractJsonStringField(eventData, "title")
        let message = extractJsonStringField(eventData, "message")

        if (message.size == 0) {
            Hilog.info(0, "CjTelegram", "[WebAppPage] open_popup: missing message")
            return
        }
        Hilog.info(0, "CjTelegram", "[WebAppPage] open_popup: title=${title} msg_len=${message.size}")

        let firstBtnId = extractFirstPopupButtonId(eventData)
        let capturedFirstId = firstBtnId

        let displayTitle = if (title.size > 0) { title } else { "Alert" }
        let capturedMsg = message

        let okBtn = AlertDialogButtonOptions(
            value: "OK",
            action: { =>
                if (capturedFirstId.size > 0) {
                    this.sendEventToWebApp("popup_closed", "{\"button_id\":\"" + capturedFirstId + "\"}")
                } else {
                    this.sendEventToWebApp("popup_closed", "{}")
                }
            }
        )
        let cancelBtn = AlertDialogButtonOptions(
            value: "Cancel",
            action: { =>
                this.sendEventToWebApp("popup_closed", "{}")
            }
        )

        getUIContext().showAlertDialog(
            AlertDialogParamWithOptions(
                title: displayTitle,
                message: capturedMsg,
                autoCancel: true,
                buttons: [okBtn, cancelBtn]
            )
        )
    }

    // ─── P2-035: web_app_open_invoice → Stars/payment flow ───────────────────

    /**
     * Handle web_app_open_invoice event.
     * iOS: fetchBotPaymentInvoice(source:.slug(slug)) then push BotCheckoutController
     *   or makeStarsTransferScreen for XTR currency.
     *
     * slug is extracted from eventData.
     * After payment completes, sendInvoiceClosedEvent(slug, result) is called.
     *
     * Full checkout UI requires PaymentService integration (interop接线点):
     * integration_contract: ic_web_open_invoice (target: payment checkout service)
     *
     * Current behavior: route slug to payment service best-effort,
     * send invoice_closed{"slug":"...","status":"cancelled"} as fallback
     * since full checkout requires PaymentService integration not yet wired.
     */
    private func handleOpenInvoice(eventData: String): Unit {
        let slug = extractJsonStringField(eventData, "slug")
        if (slug.size == 0) {
            Hilog.info(0, "CjTelegram", "[WebAppPage] open_invoice: empty slug")
            return
        }
        Hilog.info(0, "CjTelegram", "[WebAppPage] open_invoice: slug=${slug}")
        let capturedSlug = slug
        let capturedBotId = this.botId
        let capturedBotAH = this.botAccessHash
        let _ = spawn {
            let resultStatus = getWebService().processInvoice(
                slug: capturedSlug,
                botId: capturedBotId,
                botAccessHash: capturedBotAH
            )
            let capturedStatus = resultStatus
            let capturedSlug2 = capturedSlug
            spawn(UIThread) { =>
                this.sendEventToWebApp("invoice_closed",
                    "{\"slug\":\"" + capturedSlug2 + "\",\"status\":\"" + capturedStatus + "\"}")
                Hilog.info(0, "CjTelegram", "[WebAppPage] invoice_closed sent: slug=${capturedSlug2} status=${capturedStatus}")
            }
        }
    }

    // ─── P2-030: web_app_read_text_from_clipboard → clipboard_text_received ──

    /**
     * Handle web_app_read_text_from_clipboard event.
     * iOS: UIPasteboard.general.string → sendClipboardTextEvent(requestId, fillData)
     *
     * HarmonyOS clipboard read requires ohos.permission.READ_PASTEBOARD (user_grant system_basic).
     * This is an interop接线点 — clipboard access needs arkinterop to @ohos.pasteboard.
     * integration_contract: ic_web_clipboard_read (target: pasteboard interop bridge)
     *
     * Current behavior: respond with empty data (fillData: false equivalent).
     */
    private func handleReadClipboard(eventData: String): Unit {
        let reqId = extractJsonStringField(eventData, "req_id")
        Hilog.info(0, "CjTelegram", "[WebAppPage] read_text_from_clipboard: req_id=${reqId} — interop接线点 (pasteboard bridge needed)")
        if (reqId.size > 0) {
            let capturedReqId = reqId
            this.sendEventToWebApp("clipboard_text_received",
                "{\"req_id\":\"" + capturedReqId + "\"}")
        }
    }

    // ─── P2-030: web_app_switch_inline_query → close + inline mode ───────────

    /**
     * Handle web_app_switch_inline_query event.
     * iOS: controller.requestSwitchInline(query, requestPeerTypes, { controller?.dismiss() })
     *
     * Dismiss WebApp and open inline query in the originating chat.
     * Full inline query routing requires ChatRoomPage inline integration (interop接线点).
     * integration_contract: ic_web_switch_inline (target: chat inline query service)
     */
    private func handleSwitchInlineQuery(eventData: String): Unit {
        let query = extractJsonStringField(eventData, "query")
        Hilog.info(0, "CjTelegram", "[WebAppPage] switch_inline_query: query=${query}")
        routerPop()
    }

    // ─── P2-030: web_app_invoke_custom_method → custom_method_invoked ────────

    /**
     * Handle web_app_invoke_custom_method event.
     * iOS: invokeCustomMethod(requestId, method, params) → custom_method_invoked response
     *
     * Routes custom bot method invocation via WebService.
     * Responds with custom_method_invoked{"req_id":"...","result":...}.
     */
    private func handleInvokeCustomMethod(eventData: String): Unit {
        let reqId = extractJsonStringField(eventData, "req_id")
        let method = extractJsonStringField(eventData, "method")
        Hilog.info(0, "CjTelegram", "[WebAppPage] invoke_custom_method: req_id=${reqId} method=${method}")
        if (reqId.size == 0 || method.size == 0) {
            return
        }
        let capturedReqId = reqId
        let capturedMethod = method
        let capturedBotId = this.botId
        let capturedBotAH = this.botAccessHash
        let rawParams = extractJsonRawField(eventData, "params")
        let capturedParams = if (rawParams.size > 0) { rawParams } else { "{}" }
        let _ = spawn {
            let result = getWebService().invokeCustomMethod(
                botId: capturedBotId,
                botAccessHash: capturedBotAH,
                reqId: capturedReqId,
                method: capturedMethod,
                params: capturedParams
            )
            let capturedResult = result
            let capturedId = capturedReqId
            spawn(UIThread) { =>
                this.sendEventToWebApp("custom_method_invoked",
                    "{\"req_id\":\"" + capturedId + "\",\"result\":" + capturedResult + "}")
            }
        }
    }

    // ─── P2-030: web_app_device_storage_save_key ─────────────────────────────

    /**
     * Handle web_app_device_storage_save_key event.
     * iOS: device storage save (mapped to Preferences in HarmonyOS).
     */
    private func handleDeviceStorageSave(eventData: String): Unit {
        let key = extractJsonStringField(eventData, "key")
        let value = extractJsonStringField(eventData, "value")
        Hilog.info(0, "CjTelegram", "[WebAppPage] device_storage_save: key=${key}")
        getWebService().deviceStorageSave(key: key, value: value)
        this.sendEventToWebApp("device_storage_saved", "{\"status\":\"ok\"}")
    }

    // ─── P2-030: web_app_device_storage_get_key ──────────────────────────────

    /**
     * Handle web_app_device_storage_get_key event.
     * iOS: device storage get.
     */
    private func handleDeviceStorageGet(eventData: String): Unit {
        let key = extractJsonStringField(eventData, "key")
        Hilog.info(0, "CjTelegram", "[WebAppPage] device_storage_get: key=${key}")
        let capturedKey = key
        let _ = spawn {
            let value = getWebService().deviceStorageGet(key: capturedKey)
            let capturedValue = value
            let capturedKey2 = capturedKey
            spawn(UIThread) { =>
                let valueJson: String
                if (capturedValue.size > 0) {
                    valueJson = "\"" + capturedValue + "\""
                } else {
                    valueJson = "null"
                }
                this.sendEventToWebApp("device_storage_got",
                    "{\"key\":\"" + capturedKey2 + "\",\"value\":" + valueJson + "}")
            }
        }
    }

    // ─── Theme Params Injection (P2-032) ─────────────────────────────────────

    /**
     * Send theme_changed event to Mini App webview.
     *
     * Injects 14 fields into window.Telegram.WebView.themeParams and sends
     * the theme_changed event so Mini App can update its UI.
     *
     * iOS: sendThemeChangedEvent() in WebAppController.swift:2099
     * Field list from Telegram Bot API: bg_color, text_color, hint_color,
     * link_color, button_color, button_text_color, secondary_bg_color,
     * header_bg_color, accent_text_color, section_bg_color,
     * section_header_text_color, subtitle_text_color, destructive_text_color,
     * bottom_bar_bg_color
     *
     * Uses runJavaScript to inject — runs on UIThread.
     */
    private func sendThemeChangedEvent(): Unit {
        let bgColor = "#ffffff"
        let textColor = "#000000"
        let hintColor = "#8e8e93"
        let linkColor = "#0088cc"
        let buttonColor = "#0088cc"
        let buttonTextColor = "#ffffff"
        let secondaryBgColor = "#f2f2f7"
        let headerBgColor = "#f7f7f7"
        let accentTextColor = "#0088cc"
        let sectionBgColor = "#ffffff"
        let sectionHeaderTextColor = "#6d6d72"
        let subtitleTextColor = "#8e8e93"
        let destructiveTextColor = "#ff3b30"
        let bottomBarBgColor = "#f7f7f7"

        let themeParamsJson = "{" +
            "\"bg_color\":\"" + bgColor + "\"," +
            "\"text_color\":\"" + textColor + "\"," +
            "\"hint_color\":\"" + hintColor + "\"," +
            "\"link_color\":\"" + linkColor + "\"," +
            "\"button_color\":\"" + buttonColor + "\"," +
            "\"button_text_color\":\"" + buttonTextColor + "\"," +
            "\"secondary_bg_color\":\"" + secondaryBgColor + "\"," +
            "\"header_bg_color\":\"" + headerBgColor + "\"," +
            "\"accent_text_color\":\"" + accentTextColor + "\"," +
            "\"section_bg_color\":\"" + sectionBgColor + "\"," +
            "\"section_header_text_color\":\"" + sectionHeaderTextColor + "\"," +
            "\"subtitle_text_color\":\"" + subtitleTextColor + "\"," +
            "\"destructive_text_color\":\"" + destructiveTextColor + "\"," +
            "\"bottom_bar_bg_color\":\"" + bottomBarBgColor + "\"" +
            "}"

        let injectScript = "if(typeof window.Telegram==='undefined'){window.Telegram={};};" +
            "if(typeof window.Telegram.WebView==='undefined'){window.Telegram.WebView={};};" +
            "window.Telegram.WebView.themeParams=" + themeParamsJson + ";"

        let themeEventData = "{\"theme_params\":" + themeParamsJson + "}"

        try {
            this.webController.runJavaScript(injectScript, {
                _err: Option<BusinessException>, _data: Option<String> =>
                Hilog.info(0, "CjTelegram", "[WebAppPage] P2-032 themeParams injected")
            })
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[WebAppPage] P2-032 themeParams inject failed: ${e}")
        }

        this.sendEventToWebApp("theme_changed", themeEventData)
        Hilog.info(0, "CjTelegram", "[WebAppPage] P2-032 theme_changed sent")
    }

    // ─── Native → JS Event (P2-029) ──────────────────────────────────────────

    /**
     * Send event from native → Mini App JS.
     * JS receives: window.Telegram.WebApp.receiveEvent(eventType, eventData)
     */
    public func sendEventToWebApp(eventType: String, eventData: String): Unit {
        let script = "if(typeof window.Telegram!=='undefined'&&typeof window.Telegram.WebApp!=='undefined'&&typeof window.Telegram.WebApp.receiveEvent==='function'){window.Telegram.WebApp.receiveEvent(\"" + eventType + "\"," + eventData + ");}"
        try {
            this.webController.runJavaScript(script, {
                _err: Option<BusinessException>, _data: Option<String> =>
                Hilog.info(0, "CjTelegram", "[WebAppPage] sendEvent ${eventType} done")
            })
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[WebAppPage] sendEvent threw: ${e}")
        }
    }

    // ─── URL Fetch (P2-029) ───────────────────────────────────────────────────

    /**
     * Fetch webview URL using the appropriate TL method based on routeMode,
     * then load it into the WebviewController.
     */
    private func loadWebApp(): Unit {
        let mode = this.routeMode
        let bid = this.botId
        let bah = this.botAccessHash
        let pid = this.peerId
        let pah = this.peerAccessHash
        let sp = this.startParam
        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[WebAppPage] loadWebApp mode=${mode} botId=${bid}")
            let result: WebViewResult
            if (mode == "mwv") {
                result = getWebService().requestMainWebView(pid, pah, bid, bah, startParam: sp)
            } else if (mode == "wv") {
                result = getWebService().requestWebView(pid, pah, bid, bah, startParam: sp)
            } else {
                result = getWebService().requestSimpleWebView(bid, bah, startParam: sp)
            }
            let fetchedUrl = result.url
            spawn(UIThread) { =>
                if (fetchedUrl.size > 0) {
                    this.webUrl = fetchedUrl
                    Hilog.info(0, "CjTelegram", "[WebAppPage] URL ready, loading WebView")
                    try {
                        this.webController.loadUrl(fetchedUrl)
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[WebAppPage] loadUrl failed: ${e}")
                        this.isLoading = false
                        this.loadError = "Failed to load Mini App"
                    }
                } else {
                    this.isLoading = false
                    this.loadError = "Could not retrieve Mini App URL"
                    Hilog.info(0, "CjTelegram", "[WebAppPage] Empty URL from WebService")
                }
            }
        }
    }

    // ─── Route Param Parsing ──────────────────────────────────────────────────

    /**
     * Parse route param string.
     * Format A: "wv:<peerId>:<peerAH>:<botId>:<botAH>:<startParam>"
     * Format B: "mwv:<peerId>:<peerAH>:<botId>:<botAH>:<startParam>"
     * Format C: "<botId>:<botAH>" or "<botId>:<botAH>:<startParam>"  (simple)
     */
    private func parseRouteParam(param: String): Unit {
        if (param.startsWith("wv:") || param.startsWith("mwv:")) {
            let isMain = param.startsWith("mwv:")
            this.routeMode = if (isMain) { "mwv" } else { "wv" }
            let rest = if (isMain) { param[4..param.size] } else { param[3..param.size] }
            let parts = rest.split(":")
            if (parts.size >= 4) {
                this.peerId = parseWebI64(parts[0])
                this.peerAccessHash = parseWebI64(parts[1])
                this.botId = parseWebI64(parts[2])
                this.botAccessHash = parseWebI64(parts[3])
                if (parts.size >= 5) {
                    this.startParam = parts[4]
                }
            }
        } else {
            this.routeMode = "simple"
            let parts = param.split(":")
            if (parts.size >= 2) {
                this.botId = parseWebI64(parts[0])
                this.botAccessHash = parseWebI64(parts[1])
                if (parts.size >= 3) {
                    this.startParam = parts[2]
                }
            }
        }
        Hilog.info(0, "CjTelegram", "[WebAppPage] parseRoute mode=${this.routeMode} botId=${this.botId}")
    }

    // ─── Build ────────────────────────────────────────────────────────────────

    func build() {
        Column {
            // Header bar (P2-032 theme: headerBgColor; P2-036: height=0 in fullscreen)
            Row {
                // P2-031: back button (visible when backButtonVisible OR fallback nav)
                Button(if (this.backButtonVisible) { "<" } else { "<" })
                    .fontSize(18)
                    .fontColor(0x0088CCu32)
                    .backgroundColor(Color.Transparent)
                    .width(44)
                    .height(44)
                    .onClick({ _e: ClickEvent =>
                        if (this.backButtonVisible) {
                            this.sendEventToWebApp("back_button_pressed", "null")
                        } else {
                            routerPop()
                        }
                    })

                Text(this.pageTitle)
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0x000000u32)
                    .layoutWeight(1)
                    .textAlign(TextAlign.Center)
                    .maxLines(1)

                // P2-031: settings button
                if (this.settingsButtonVisible) {
                    Button("...")
                        .fontSize(20)
                        .fontColor(0x0088CCu32)
                        .backgroundColor(Color.Transparent)
                        .width(44)
                        .height(44)
                        .onClick({ _e: ClickEvent =>
                            this.sendEventToWebApp("settings_button_pressed", "null")
                        })
                } else {
                    Button("X")
                        .fontSize(16)
                        .fontColor(0x888888u32)
                        .backgroundColor(Color.Transparent)
                        .width(44)
                        .height(44)
                        .onClick({ _e: ClickEvent =>
                            if (this.needDismissConfirmation) {
                                let okBtn = AlertDialogButtonOptions(
                                    value: "Close",
                                    action: { =>
                                        routerPop()
                                    }
                                )
                                let cancelBtn = AlertDialogButtonOptions(
                                    value: "Stay",
                                    action: { => () }
                                )
                                getUIContext().showAlertDialog(
                                    AlertDialogParamWithOptions(
                                        title: "Close Mini App?",
                                        message: "Changes you made may not be saved.",
                                        autoCancel: true,
                                        buttons: [okBtn, cancelBtn]
                                    )
                                )
                            } else {
                                routerPop()
                            }
                        })
                }
            }
            .width(100.percent)
            .height(if (this.isFullscreen) { 0 } else { 44 })
            .padding(left: 4, right: 4, top: 0, bottom: 0)
            .backgroundColor(this.headerBgColor)

            // Content area (P2-032: bodyBgColor)
            if (this.isLoading) {
                Column {
                    LoadingProgress()
                        .width(40)
                        .height(40)
                        .color(0x0088CCu32)
                    Text("Loading Mini App...")
                        .fontSize(14)
                        .fontColor(0x888888u32)
                        .margin(top: 8)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(this.bodyBgColor)
            } else if (this.loadError.size > 0) {
                Column {
                    Text(this.loadError)
                        .fontSize(15)
                        .fontColor(0xFF4444u32)
                        .textAlign(TextAlign.Center)
                        .padding(16)
                    Button(trSource("Retry"))
                        .fontSize(15)
                        .fontColor(0xFFFFFFu32)
                        .backgroundColor(0x0088CCu32)
                        .borderRadius(8)
                        .padding(left: 24, right: 24, top: 10, bottom: 10)
                        .onClick({ _e: ClickEvent =>
                            this.isLoading = true
                            this.loadError = ""
                            this.loadWebApp()
                        })
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(this.bodyBgColor)
            } else {
                // P2-029: Real Web component loading bot URL
                Web(src: "about:blank", controller: this.webController)
                    .width(100.percent)
                    .layoutWeight(1)
                    .domStorageAccess(true)
                    .onPageBegin({ _evt =>
                        Hilog.info(0, "CjTelegram", "[WebAppPage] onPageBegin")
                        this.isLoading = false
                    })
                    .onPageEnd({ _evt =>
                        Hilog.info(0, "CjTelegram", "[WebAppPage] onPageEnd — injecting theme")
                        this.isLoading = false
                        this.sendThemeChangedEvent()
                    })
            }

            // P2-031 Bottom area: secondary button (if visible) above main button
            // P2-031: secondaryButtonProgress drives opacity shimmer (0.5 when spinning)
            if (this.secondaryButtonVisible) {
                Button(if (this.secondaryButtonText.size > 0) { this.secondaryButtonText } else { "CANCEL" })
                    .width(100.percent)
                    .height(50)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.secondaryButtonTextColorHex)
                    .backgroundColor(if (this.secondaryButtonEnabled) { this.secondaryButtonColorHex } else { 0xAAAAAAu32 })
                    .borderRadius(0)
                    .enabled(this.secondaryButtonEnabled)
                    .opacity(if (this.secondaryButtonProgress == MiniAppButtonProgress.Spinning) { 0.6 } else { 1.0 })
                    .onClick({ _e: ClickEvent =>
                        this.sendEventToWebApp("secondary_button_pressed", "null")
                    })
            }

            // P2-031 Main button
            // P2-031: mainButtonProgress drives opacity shimmer (0.6 when spinner active)
            if (this.mainButtonVisible) {
                Button(if (this.mainButtonText.size > 0) { this.mainButtonText } else { "CONTINUE" })
                    .width(100.percent)
                    .height(50)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.mainButtonTextColorHex)
                    .backgroundColor(if (this.mainButtonEnabled) { this.mainButtonColorHex } else { 0xAAAAAAu32 })
                    .borderRadius(0)
                    .enabled(this.mainButtonEnabled)
                    .opacity(if (this.mainButtonProgress == MiniAppButtonProgress.Spinning) { 0.6 } else { 1.0 })
                    .onClick({ _e: ClickEvent =>
                        this.sendEventToWebApp("main_button_pressed", "null")
                    })
            }

            // P2-032: Bottom bar bg applies to container bottom
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.bottomBarColor)
        .onAppear({ => this.ensureLoaded() })
    }
}

// ─── JSON helpers ─────────────────────────────────────────────────────────────

/**
 * Extract the first popup button id from web_app_open_popup eventData.
 * Looks for "\"id\":\"<id>\"" in the buttons array substring.
 * Returns "" if no id found.
 */
private func extractFirstPopupButtonId(json: String): String {
    let needle = "\"buttons\":"
    let runes = json.toRuneArray()
    let needleRunes = needle.toRuneArray()
    let nLen = needleRunes.size
    let jLen = runes.size
    var i: Int64 = 0
    while (i <= jLen - nLen) {
        var matched = true
        var k: Int64 = 0
        while (k < nLen) {
            if (runes[i + k] != needleRunes[k]) {
                matched = false
                break
            }
            k += 1
        }
        if (matched) {
            let rest = String(runes[i..jLen])
            return extractJsonStringField(rest, "id")
        }
        i += 1
    }
    return ""
}

/**
 * Extract the value of a JSON string field from a flat JSON payload.
 * Pattern: ..."key":"value"... or ..."key": "value"...
 * Returns "" if the field is absent or the value is empty.
 */
private func extractJsonStringField(json: String, key: String): String {
    let needle = "\"" + key + "\":"
    let runes = json.toRuneArray()
    let needleRunes = needle.toRuneArray()
    let nLen = needleRunes.size
    let jLen = runes.size
    var i: Int64 = 0
    while (i <= jLen - nLen) {
        var matched = true
        var k: Int64 = 0
        while (k < nLen) {
            if (runes[i + k] != needleRunes[k]) {
                matched = false
                break
            }
            k += 1
        }
        if (matched) {
            var j = i + nLen
            while (j < jLen && (runes[j] == r' ' || runes[j] == r'\t')) {
                j += 1
            }
            if (j < jLen && runes[j] == r'"') {
                j += 1
                var end = j
                while (end < jLen && runes[end] != r'"') {
                    if (runes[end] == r'\\') { end += 1 }
                    end += 1
                }
                if (end <= jLen) {
                    return String(runes[j..end])
                }
            }
            break
        }
        i += 1
    }
    return ""
}

/**
 * Extract a raw JSON value (string content or object/array literal) for a given key.
 * Handles two cases:
 *   "key":"string value"  → returns the string content (without surrounding quotes)
 *   "key":{...} or "key":[...]  → returns the full literal including braces/brackets
 * Returns "" if the key is absent.
 * Used for params fields that may be either a JSON string or a JSON object.
 */
private func extractJsonRawField(json: String, key: String): String {
    let needle = "\"" + key + "\":"
    let runes = json.toRuneArray()
    let needleRunes = needle.toRuneArray()
    let nLen = needleRunes.size
    let jLen = runes.size
    var i: Int64 = 0
    while (i <= jLen - nLen) {
        var matched = true
        var k: Int64 = 0
        while (k < nLen) {
            if (runes[i + k] != needleRunes[k]) {
                matched = false
                break
            }
            k += 1
        }
        if (matched) {
            var j = i + nLen
            while (j < jLen && (runes[j] == r' ' || runes[j] == r'\t')) {
                j += 1
            }
            if (j >= jLen) {
                break
            }
            if (runes[j] == r'"') {
                // String value: extract content between quotes
                j += 1
                var end = j
                while (end < jLen && runes[end] != r'"') {
                    if (runes[end] == r'\\') { end += 1 }
                    end += 1
                }
                if (end <= jLen) {
                    return String(runes[j..end])
                }
                break
            } else if (runes[j] == r'{' || runes[j] == r'[') {
                // Object or array value: extract balanced braces/brackets
                let openChar = runes[j]
                let closeChar: Rune = if (openChar == r'{') { r'}' } else { r']' }
                var depth: Int64 = 0
                var end = j
                var inStr = false
                while (end < jLen) {
                    let c = runes[end]
                    if (inStr) {
                        if (c == r'\\') {
                            end += 1
                        } else if (c == r'"') {
                            inStr = false
                        }
                    } else {
                        if (c == r'"') {
                            inStr = true
                        } else if (c == openChar) {
                            depth += 1
                        } else if (c == closeChar) {
                            depth -= 1
                            if (depth == 0) {
                                return String(runes[j..end + 1])
                            }
                        }
                    }
                    end += 1
                }
                break
            }
            break
        }
        i += 1
    }
    return ""
}

/**
 * Parse Int64 from string, returns 0 on parse failure.
 */
private func parseWebI64(s: String): Int64 {
    var result: Int64 = 0
    var negative = false
    let runes = s.toRuneArray()
    var start: Int64 = 0
    if (runes.size > 0 && runes[0] == r'-') {
        negative = true
        start = 1
    }
    var i: Int64 = start
    while (i < runes.size) {
        let c = UInt32(runes[i])
        if (c >= 48u32 && c <= 57u32) {
            result = result * 10 + Int64(c - 48u32)
        }
        i += 1
    }
    return if (negative) { -result } else { result }
}

/**
 * Parse a CSS hex color string (#RRGGBB or #RGB) to a UInt32 ARGB value.
 * Returns fallback if parsing fails.
 */
private func parseHexColor(hex: String, fallback: UInt32): UInt32 {
    var s = hex
    if (s.size > 0 && s[0..1] == "#") {
        s = s[1..s.size]
    }
    if (s.size == 3) {
        s = s[0..1] + s[0..1] + s[1..2] + s[1..2] + s[2..3] + s[2..3]
    }
    if (s.size != 6) {
        return fallback
    }
    var val: UInt32 = 0u32
    let runes = s.toRuneArray()
    var i: Int64 = 0
    while (i < 6) {
        let c = UInt32(runes[i])
        let nibble: UInt32
        if (c >= 48u32 && c <= 57u32) {
            nibble = c - 48u32
        } else if (c >= 65u32 && c <= 70u32) {
            nibble = c - 65u32 + 10u32
        } else if (c >= 97u32 && c <= 102u32) {
            nibble = c - 97u32 + 10u32
        } else {
            return fallback
        }
        val = val * 16u32 + nibble
        i += 1
    }
    return val
}

// ─── P2-036: SensorServiceKit callback implementations ───────────────────────

/**
 * Accelerometer callback for Mini App web_app_start_accelerometer.
 *
 * Pattern follows DeviceProximitySensorCallback (P2-069) in utils/DeviceProximityBinding.cj.
 * invoke() is called on sensor thread → relays via page.onAccelerometerData() which uses spawn(UIThread).
 *
 * KB Example 123: AccelerometerResponse.{x, y, z}: Float32
 */
public class WebAppAccelerometerCallback <: Callback1Argument<AccelerometerResponse> {
    private var _page: WebAppPage

    init(page!: WebAppPage) {
        this._page = page
    }

    public func invoke(err: ?BusinessException, arg: AccelerometerResponse): Unit {
        match (err) {
            case Some(e) =>
                Hilog.info(0, "CjTelegram", "[WebApp] accel sensor error code=${e.code}: ${e.message}")
                return
            case None => ()
        }
        this._page.onAccelerometerData(arg.x, arg.y, arg.z)
    }
}

/**
 * Gyroscope callback for Mini App web_app_start_gyroscope.
 *
 * Pattern follows DeviceProximitySensorCallback (P2-069).
 * KB Example (cjui_docs sensor): GyroscopeResponse.{x, y, z}: Float32
 */
public class WebAppGyroscopeCallback <: Callback1Argument<GyroscopeResponse> {
    private var _page: WebAppPage

    init(page!: WebAppPage) {
        this._page = page
    }

    public func invoke(err: ?BusinessException, arg: GyroscopeResponse): Unit {
        match (err) {
            case Some(e) =>
                Hilog.info(0, "CjTelegram", "[WebApp] gyro sensor error code=${e.code}: ${e.message}")
                return
            case None => ()
        }
        this._page.onGyroscopeData(arg.x, arg.y, arg.z)
    }
}
