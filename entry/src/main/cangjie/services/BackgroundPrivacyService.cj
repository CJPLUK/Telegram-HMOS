package ohos_app_cangjie_entry.services

import kit.ArkUI.Window
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.interop.*

/**
 * BackgroundPrivacyService — 后台隐私保护服务
 *
 * P2-270: 进入后台时遮罩应用内容，防止任务切换器泄露聊天记录。
 *   onBackground → setWindowPrivacyMode(true)  → 系统快照为黑屏/遮罩，不显示内容
 *   onForeground → setWindowPrivacyMode(false) → 恢复正常显示
 *
 * P2-273: 截屏/录屏检测
 *   setWindowPrivacyMode(true) 同时阻止截屏（隐私窗口在截图时输出黑屏），
 *   对敏感页面（密码锁屏）常驻启用。
 *   全局录屏状态通过 isScreenCaptureActive 字段追踪，
 *   由 main_ability 在 onWindowStageCreate 后注册监听。
 *
 * 权限: ohos.permission.PRIVACY_WINDOW（在 module.json5 中声明）
 *
 * iOS 对应:
 *   applicationDidEnterBackground: UIApplication.shared.keyWindow → isHidden = false（使用 privacy overlay）
 *   ScreenCaptureDetection: UIScreen.main.isCaptured / UIApplication.userDidTakeScreenshotNotification
 */

private var _bgPrivacyServiceInstance: Option<BackgroundPrivacyService> = None

public func getBackgroundPrivacyService(): BackgroundPrivacyService {
    match (_bgPrivacyServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = BackgroundPrivacyService()
            _bgPrivacyServiceInstance = Some(inst)
            return inst
    }
}

public class BackgroundPrivacyService {
    // 主窗口引用（由 main_ability.onWindowStageCreate 注入）
    private var _mainWindow: Option<Window> = None

    // P2-273: 录屏状态追踪（由 display.on(ListenerTypeCaptureStatusChange) 更新）
    public var isScreenCaptureActive: Bool = false

    // P2-273: 截屏检测回调（UI 层注册，截屏发生时通知用户）
    private var _screenshotCallback: Option<() -> Unit> = None

    /**
     * 注入主窗口引用（由 MainAbility.onWindowStageCreate 调用）。
     *
     * Phase 3 反转后 ArkTS 侧（BackgroundPrivacyImpl）经 window.getLastWindow 自行解析顶层窗口，
     * 仓颉侧不再需要 Window 句柄；本方法保留公共签名以兼容既有 / 未来调用方，仅缓存引用不再使用。
     */
    public func setMainWindow(window: Window): Unit {
        this._mainWindow = Some(window)
        Hilog.info(0, "CjTelegram", "[BackgroundPrivacyService] Main window injected (retained for API compat; ArkTS resolves window itself)")
    }

    /**
     * 经 interop 反转调 ArkTS window.setWindowPrivacyMode。
     * argJson schema 与 ArkTS BackgroundPrivacyImpl 逐条对应 (D3): {"on": <bool>}
     */
    private func setPrivacyMode(on: Bool): Unit {
        let argJson = "{\"on\":${on}}"
        callArk(BGPRIVACY_SET, argJson)
    }

    /**
     * P2-273: 注册截屏发生时的回调（可选，UI 层使用）
     */
    public func setScreenshotCallback(cb: () -> Unit): Unit {
        this._screenshotCallback = Some(cb)
    }

    /**
     * P2-270: 进入后台时启用隐私模式（遮罩任务切换器快照）
     *
     * iOS 对应: applicationDidEnterBackground → 显示 privacy overlay（UIImageView/VisualEffect）
     * HarmonyOS: setWindowPrivacyMode(true) — 系统拍摄快照时输出黑屏而非应用内容
     */
    public func enablePrivacyOnBackground(): Unit {
        Hilog.info(0, "CjTelegram", "[BackgroundPrivacyService] Privacy mode ENABLE (background)")
        this.setPrivacyMode(true)
    }

    /**
     * P2-270: 进入前台时关闭隐私模式（恢复正常显示）
     *
     * iOS 对应: applicationDidBecomeActive → 移除 privacy overlay
     * HarmonyOS: setWindowPrivacyMode(false) — 恢复正常内容显示
     */
    public func disablePrivacyOnForeground(): Unit {
        Hilog.info(0, "CjTelegram", "[BackgroundPrivacyService] Privacy mode DISABLE (foreground)")
        this.setPrivacyMode(false)
    }

    /**
     * P2-273: 对敏感页面（密码锁屏/阅后即焚）常驻启用截屏防护
     *
     * 在密码输入页 aboutToAppear 调用，aboutToDisappear 调用 disableScreenshotProtection。
     * iOS 对应: SecretMediaPreviewController / AppLock → UIView.layer.allowsGroupOpacity = false
     * HarmonyOS: setWindowPrivacyMode(true) — 截屏时窗口内容输出黑屏
     */
    public func enableScreenshotProtection(): Unit {
        Hilog.info(0, "CjTelegram", "[BackgroundPrivacyService] Screenshot protection ENABLE (sensitive page)")
        this.setPrivacyMode(true)
    }

    /**
     * P2-273: 退出敏感页面时取消截屏防护
     */
    public func disableScreenshotProtection(): Unit {
        Hilog.info(0, "CjTelegram", "[BackgroundPrivacyService] Screenshot protection DISABLE (left sensitive page)")
        this.setPrivacyMode(false)
    }

    /**
     * P2-273: 录屏状态变化时由 display 监听器回调
     *
     * iOS 对应: UIScreen.main.isCaptured KVO / screenRecordingActive() Signal
     * HarmonyOS: display.on(ListenerTypeCaptureStatusChange, callback)
     *   — 当前 Cangjie SDK 中 display module 的 on(ListenerTypeCaptureStatusChange)
     *     通过 ArkTS interop 注册，此处提供状态更新入口供 main_ability 回调使用。
     *
     * N-A 说明: Cangjie SDK 6.0 的 ohos.display Cangjie 绑定中
     *   ListenerTypeCaptureStatusChange 枚举存在（见 KB 查询结果），但
     *   display.on(ListenerTypeCaptureStatusChange, Callback) 的具体 Cangjie 函数签名
     *   在 KB 中仅通过文档文本获知，未找到带参数类型的 CODE_EXAMPLE；
     *   实际调用通过 ArkTS interop（arkinterop JSRuntime）注册，
     *   状态更新通过此 notifyCaptureStatusChanged 入口回调。
     */
    public func notifyCaptureStatusChanged(isCapturing: Bool): Unit {
        this.isScreenCaptureActive = isCapturing
        let capStr = "${isCapturing}"
        Hilog.info(0, "CjTelegram", "[BackgroundPrivacyService] Screen capture status changed: %{public}s", [capStr])
        if (isCapturing) {
            match (this._screenshotCallback) {
                case Some(cb) =>
                    try { cb() } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[BackgroundPrivacyService] screenshotCallback error: ${e}")
                    }
                case None => ()
            }
        }
    }
}
