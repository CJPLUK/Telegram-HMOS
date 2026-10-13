package ohos_app_cangjie_entry.utils

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog

/**
 * UI 生命周期安全助手（Mate60 真机闪退修复,2026-07-20）
 *
 * 根因:onTouch/onClick 回调里的 `this.getUIContext().animateTo(...)` 在组件已随页面
 * 弹出/列表回收而脱离后仍可能被触发（真机侧滑返回产生的 TouchType.Cancel、转场中点击),
 * 此时 getUIContext() 内部对 None 解包 → 未捕获 NoneValueException → SIGABRT 闪退。
 * 模拟器上从未复现是因为脚本化点击不产生 Cancel/转场中触摸。
 *
 * 约定:所有回调内的隐式动画一律走 safeAnimateTo——异常时直接执行 action 落终态
 * （状态不卡、无动画降级),并打一条日志便于观测。
 */
public func safeAnimateTo(getCtx: () -> UIContext, param: AnimateParam, action: () -> Unit): Unit {
    try {
        getCtx().animateTo(param, action)
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[UiSafety] animateTo skipped (detached ctx): ${e}")
        try {
            action()
        } catch (_: Exception) {
            // 组件已亡,状态写入也失败——安全忽略
        }
    }
}
