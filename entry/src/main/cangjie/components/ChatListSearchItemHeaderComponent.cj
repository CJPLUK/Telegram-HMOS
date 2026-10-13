package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.services.*

/**
 * 搜索结果分区头 UI 组件
 *
 * 对应 iOS ChatListSearchItemHeaderNode
 * 来源: input/Telegram-iOS/submodules/ChatListSearchItemHeader/Sources/ChatListSearchItemHeader.swift
 *
 * 显示分区标题（如 DIALOGS、GLOBAL），可选 action 按钮
 * 通过 ChatListSearchItemHeaderService 获取标题，非 mock/stub
 */
@Component
public class ChatListSearchItemHeaderComponent {
    var headerType: ChatListSearchHeaderType = ChatListSearchHeaderType.LocalPeers
    var customTitle: String = ""
    var actionTitle: String = ""
    public var onActionClick: () -> Unit = { => }

    private func getDisplayTitle(): String {
        if (this.customTitle.size > 0) {
            return this.customTitle
        }
        return getChatListSearchItemHeaderService().getTitleForType(this.headerType)
    }

    public func build() {
        Row {
            Text(this.getDisplayTitle().toAsciiUpper())
                .fontSize(13)
                .fontColor(0x8E8E93)
                .fontWeight(FontWeight.Medium)

            Blank()
                .layoutWeight(1)

            if (this.actionTitle.size > 0) {
                Text(this.actionTitle)
                    .fontSize(15)
                    .fontColor(0x317AFF)
                    .onClick({ _evt =>
                        this.onActionClick()
                    })
            }
        }
        .width(100.percent)
        .height(28)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(0xF2F2F7)
    }
}
