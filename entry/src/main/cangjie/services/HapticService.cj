package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.interop.*

/**
 * HapticService — Mini App 触觉反馈桥 (P2-033)
 *
 * 对应 iOS: HapticFeedback.impact(.light/.medium/.heavy/.rigid/.soft)
 *           HapticFeedback.success() / .error() / .warning()
 *           HapticFeedback.tap() (selection_change)
 *
 * 互操作方针 (Phase 3 反转模式, SSOT §5):
 *   能力实现搬到 ArkTS 侧 (ets/interop/impls/HapticImpl.ets)，启动时 registerArkFunc 注册进仓颉。
 *   仓颉服务只负责 type/style → 时长映射，然后 callArk(HAPTIC_VIBRATE, argJson) 发给 ArkTS。
 *   ArkTS 侧调真实 @ohos.vibrator.startVibration；线程 hop 由 interop 层负责。
 *   振动失败不崩 (ArkTS onResult ack ok=false)，事件仍 ack。
 *
 * INTEROP 契约 (D3, 双侧签名一致):
 *   method = HAPTIC_VIBRATE ("haptic.vibrate")
 *   argJson (CJ→ArkTS): {"ms": <duration>}     时长(ms)在仓颉侧算好
 *   result (ArkTS→CJ):  {"ok": <bool>}         best-effort，仅可选日志
 *
 * 调用链:
 *   WebAppPage.handleJSEvent("web_app_trigger_haptic_feedback")
 *     → parseHapticType/Style
 *     → triggerHaptic(hapticType, styleOrNotif)
 *     → callArk(HAPTIC_VIBRATE, "{\"ms\":<duration>}")
 *     → [ArkTS] HapticImpl.registerHaptic → vibrator.startVibration
 *
 * 振动时长映射 (ms):
 *   impact.light    → VibrateTime 15ms
 *   impact.medium   → VibrateTime 25ms
 *   impact.heavy    → VibrateTime 50ms
 *   impact.rigid    → VibrateTime 35ms
 *   impact.soft     → VibrateTime 12ms
 *   notification.success  → VibrateTime 30ms
 *   notification.warning  → VibrateTime 40ms
 *   notification.error    → VibrateTime 50ms
 *   selection_change      → VibrateTime 8ms
 */

/**
 * 触觉反馈类型
 * 对应 web_app_trigger_haptic_feedback eventData 的 type 字段
 */
public enum HapticType {
    | Impact
    | Notification
    | SelectionChange

    public func ordinal(): Int32 {
        match (this) {
            case Impact => 0
            case Notification => 1
            case SelectionChange => 2
        }
    }
    public operator func ==(right: HapticType): Bool { return this.ordinal() == right.ordinal() }
    public operator func !=(right: HapticType): Bool { return this.ordinal() != right.ordinal() }
}

/**
 * triggerHaptic — 经 interop 反转调 ArkTS @ohos.vibrator 触发振动
 *
 * @param hapticType   "impact" | "notification" | "selection_change"
 * @param styleOrNotif 对于 impact: "light"/"medium"/"heavy"/"rigid"/"soft"
 *                     对于 notification: "success"/"warning"/"error"
 *                     对于 selection_change: ""
 *
 * fire-and-forget：仓颉侧算好时长 → callArk(HAPTIC_VIBRATE, {"ms":...}) → ArkTS 异步振动。
 * 线程 hop / 振动失败处理都在 ArkTS 侧（HapticImpl.ets），此处不再触碰 JSRuntime。
 * 公共签名保持不变，WebAppPage 调用方无需改动。
 */
public func triggerHaptic(hapticType: String, styleOrNotif: String): Unit {
    let durationMs: Float64 = hapticDurationMs(hapticType, styleOrNotif)
    Hilog.info(0, "CjTelegram", "[HapticService] triggerHaptic type=${hapticType} style=${styleOrNotif} duration=${durationMs}ms")
    // argJson schema 与 ArkTS HapticImpl 逐条对应 (D3): {"ms": <duration>}
    let argJson = "{\"ms\":${durationMs}}"
    callArk(HAPTIC_VIBRATE, argJson)
}

/**
 * hapticDurationMs — 将触觉类型/样式映射到振动持续时间(ms)
 * 对应 iOS UIImpactFeedbackGenerator / UINotificationFeedbackGenerator 行为近似值
 */
func hapticDurationMs(hapticType: String, styleOrNotif: String): Float64 {
    if (hapticType == "impact") {
        if (styleOrNotif == "light") { return 15.0 }
        if (styleOrNotif == "medium") { return 25.0 }
        if (styleOrNotif == "heavy") { return 50.0 }
        if (styleOrNotif == "rigid") { return 35.0 }
        if (styleOrNotif == "soft") { return 12.0 }
        return 25.0
    } else if (hapticType == "notification") {
        if (styleOrNotif == "success") { return 30.0 }
        if (styleOrNotif == "warning") { return 40.0 }
        if (styleOrNotif == "error") { return 50.0 }
        return 30.0
    } else if (hapticType == "selection_change") {
        return 8.0
    }
    return 15.0
}
