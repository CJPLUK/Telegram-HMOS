package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{VenueItemData, ItemListVenueService, getItemListVenueService}

/**
 * 场所候选行组件 (ItemListVenueItem)
 *
 * 对应 iOS ItemListVenueItemNode：
 *   - 左侧 40×40 场所图标（按类型着色的圆形 + 单字母标签）
 *   - 中部 场所名称（title）+ 地址（address）
 *   - 右侧 可选信息按钮（infoAction != nil 时显示）
 *   - 整行 onClick → onSelect 回调
 *
 * 布局:
 * ┌─────────────────────────────────────────────────────┐
 * │ [Icon]  场所名称                         [Info?]    │
 * │         地址文本                                    │
 * └─────────────────────────────────────────────────────┘
 *
 * 调用链: ItemListVenueComponent.onClick → onSelect(venue)
 * iOS 原版无 TL/MTProto，本组件同样无网络调用（iOS ItemListVenueItem.swift 确认）。
 */
@Component
public class ItemListVenueComponent {
    public var venue: VenueItemData = VenueItemData()
    public var showInfoButton: Bool = false
    public var onSelect: (VenueItemData) -> Unit = { _v: VenueItemData => }
    public var onInfoTap: (VenueItemData) -> Unit = { _v: VenueItemData => }

    @State var iconColor: Int64 = 0x317AFF
    @State var iconLabel: String = "L"
    @State var isPressed: Bool = false

    public override func aboutToAppear(): Unit {
        let service = getItemListVenueService()
        let color = service.venueIconColor(this.venue.type_)
        let label = service.venueIconLabel(this.venue.type_)
        launch {
            this.iconColor = color
            this.iconLabel = label
        }
    }

    private func getDisplayTitle(): String {
        if (this.venue.title.size > 0) {
            return this.venue.title
        }
        return " "
    }

    private func getDisplayAddress(): String {
        if (this.venue.address.size > 0) {
            return this.venue.address
        }
        return ""
    }

    public func build() {
        Row {
            Column {
                Text(this.iconLabel)
                    .fontSize(18)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0xFFFFFF)
                    .textAlign(TextAlign.Center)
            }
            .width(40)
            .height(40)
            .borderRadius(20)
            .backgroundColor(this.iconColor)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .margin(right: 12)

            Column {
                Text(this.getDisplayTitle())
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0xFF_000000)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                    .width(100.percent)

                if (this.getDisplayAddress().size > 0) {
                    Text(this.getDisplayAddress())
                        .fontSize(13)
                        .fontColor(0xFF_8E8E93)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                        .margin(top: 2)
                        .width(100.percent)
                }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .justifyContent(FlexAlign.Center)

            if (this.showInfoButton) {
                Column {
                    Text("i")
                        .fontSize(14)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(0xFF_317AFF)
                        .textAlign(TextAlign.Center)
                }
                .width(36)
                .height(36)
                .borderRadius(18)
                .border(width: 1, color: 0xFF_317AFF)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .margin(left: 8)
                .onClick({ _evt =>
                    let venueCopy = this.venue
                    let _ = getItemListVenueService().logVenueSelected(venueCopy)
                    this.onInfoTap(venueCopy)
                })
            }
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 10, bottom: 10)
        .backgroundColor(if (this.isPressed) { 0xF0F0F0 } else { 0xFFFFFF })
        .onClick({ _evt =>
            let venueCopy = this.venue
            let _ = getItemListVenueService().logVenueSelected(venueCopy)
            this.onSelect(venueCopy)
        })
        .onTouch({ evt =>
            match (evt.eventType) {
                case TouchType.Down =>
                    this.isPressed = true
                case TouchType.Up =>
                    this.isPressed = false
                case TouchType.Cancel =>
                    this.isPressed = false
                case _ => ()
            }
        })
    }
}
