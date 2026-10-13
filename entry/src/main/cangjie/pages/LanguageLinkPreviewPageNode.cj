package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.components.LanguageLinkPreviewComponent

/**
 * LanguageLinkPreviewPageNode — 语言包链接预览页面内容节点
 *
 * 对应 iOS LanguageLinkPreviewControllerNode
 * 封装预览内容区域，供 LanguageLinkPreviewPage 使用
 */
@Component
public class LanguageLinkPreviewPageNode {
    public var identifier: String = ""
    public var onClose: () -> Unit = { => }
    public var onApply: (String) -> Bool = { _: String => false }
    public var onApplied: () -> Unit = { => }
    public var onOpenUrl: (String) -> Unit = { _: String => }

    public func build() {
        Column {
            LanguageLinkPreviewComponent(
                identifier: this.identifier,
                onClose: this.onClose,
                onApply: this.onApply,
                onApplied: this.onApplied,
                onOpenUrl: this.onOpenUrl
            )
        }
        .width(100.percent)
    }
}
