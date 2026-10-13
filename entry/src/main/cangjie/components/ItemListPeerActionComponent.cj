package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*

/**
 * 用户操作列表项组件 (ItemListPeerActionItem)
 *
 * 对应 iOS ItemListPeerActionItem.swift：
 * - 图标 + 标题的列表项
 * - 支持 accent / destructive / disabled 颜色
 * - 点击时执行 onClick 回调（调用方通过 onClick 调用 ItemListPeerActionService）
 *
 * 使用示例（ChatListPage 等）:
 *   ItemListPeerActionComponent(icon: "🗑", title: "Delete", color: "destructive",
 *     onClick: { => let _ = getItemListPeerActionService().deleteDialog(peerType, peerId) })
 */
@Component
public class ItemListPeerActionComponent {
    // 图标（emoji 或空）
    var icon: String = ""

    // 标题
    var title: String = ""

    // 颜色: "accent" | "destructive" | "disabled"
    var color: String = "accent"

    // 点击回调（调用方传入，内部调用 ItemListPeerActionService）
    public var onClick: () -> Unit = { => }

    private func getTextColor(): Int64 {
        match (this.color) {
            case "destructive" => return 0xDD4B39
            case "disabled" => return 0x8E8E93
            case _ => return 0x317AFF
        }
    }

    public func build() {
        Row {
            if (this.icon.size > 0) {
                Text(this.icon)
                    .fontSize(20)
                    .margin(right: 12)
            }

            Text(this.title)
                .fontSize(16)
                .fontColor(this.getTextColor())
                .maxLines(1)
                .textOverflow(TextOverflow.Ellipsis)
                .layoutWeight(1)
        }
        .width(100.percent)
        .height(56)
        .padding(left: 16, right: 16)
        .backgroundColor(0xFFFFFF)
        .alignItems(VerticalAlign.Center)
        .onClick({ evt =>
            this.onClick()
        })
    }
}
