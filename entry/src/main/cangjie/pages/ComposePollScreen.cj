package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.router.*

/**
 * ComposePollScreen — 创建投票页面（混合工程迁移版）
 * 对应 Telegram-iOS ComposePollScreen（全屏创建投票页面）
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry（供 CJHybridComponent 按裸类名嵌入）
 *  - 去掉 @Consume NavPathStack（混合工程仓颉不持栈）
 *  - build() 根去掉 NavDestination 包裹（由 ArkTS 壳提供 NavDestination），只留内容
 *  - pageStack.pop(animated) → routerPop()
 *  - 去掉 aboutToAppear/aboutToDisappear（混合仓颉页无完整生命周期）
 */
@HybridComponentEntry
@Component
public class ComposePollScreen {
    public func build() {
        Column {
            ComposePollScreenComponent(
                onSendSuccess: { =>
                    Hilog.info(0, "CjTelegram", "[ComposePollScreen] Poll sent, popping")
                    routerPop()
                },
                onCancel: { =>
                    routerPop()
                }
            )
        }
        .width(100.percent)
        .height(100.percent)
    }
}
