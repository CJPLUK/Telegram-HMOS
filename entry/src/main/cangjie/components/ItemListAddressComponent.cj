package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.sync.*
import ohos_app_cangjie_entry.services.*

/**
 * ItemListAddressComponent — 地址列表项组件（可复用）
 *
 * 对应 iOS ItemListAddressItem.swift
 * 用于 Passport、收货地址、账单地址等场景。
 *
 * 布局: 标签(可选) + 多行地址文本 + 可选编辑/复制按钮
 * 长按可复制地址到剪贴板
 */
@Component
public class ItemListAddressComponent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 地址数据
    var address: AddressData = AddressData()

    // 标签（如 "Shipping Address", "Billing Address"）
    var label: String = ""

    // 是否显示编辑按钮
    public var showEditButton: Bool = false

    // 是否显示复制按钮
    public var showCopyButton: Bool = true

    // 点击整行回调
    public var onClick: () -> Unit = { => }

    // 编辑按钮回调
    public var onEdit: () -> Unit = { => }

    // 长按回调（默认复制到剪贴板）
    public var onLongPress: () -> Unit = { => }

    @State var touchDownTime: Int64 = 0
    @State var showCopiedToast: Bool = false

    private func getFormattedAddress(): String {
        return getItemListAddressService().formatMultiLine(this.address)
    }

    private func hasLabel(): Bool {
        return this.label.size > 0
    }

    private func hasAddress(): Bool {
        return !this.address.isEmpty()
    }

    private func getCopyButtonText(): String {
        if (this.showCopiedToast) { return "Copied" }
        return "Copy"
    }

    private func handleCopy(): Unit {
        if (this.hasAddress()) {
            getItemListAddressService().copyToClipboard(this.address)
            this.showCopiedToast = true
            let _ = spawn {
                sleep(Duration.second * 2)
                launch { this.showCopiedToast = false }
            }
        }
    }

    private func handleLongPress(): Unit {
        this.handleCopy()
        this.onLongPress()
    }

    public func build() {
        Column {
            Row {
                Column {
                    if (this.hasLabel()) {
                        Text(this.label)
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .margin(bottom: 4)
                    }
                    if (this.hasAddress()) {
                        Text(this.getFormattedAddress())
                            .fontSize(17)
                            .fontColor(0x000000)
                            .maxLines(0)
                    } else {
                        Text("No address")
                            .fontSize(17)
                            .fontColor(0x8E8E93)
                    }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                if (this.showCopyButton && this.hasAddress()) {
                    Text(this.getCopyButtonText())
                        .fontSize(17)
                        .fontColor(0x317AFF)
                        .margin(left: 8)
                        .onClick({ _evt =>
                            this.handleCopy()
                        })
                }
                if (this.showEditButton) {
                    Text(trSource("Edit"))
                        .fontSize(17)
                        .fontColor(0x317AFF)
                        .margin(left: 8)
                        .onClick({ _evt =>
                            this.onEdit()
                        })
                }
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 12, bottom: 12)
            .alignItems(VerticalAlign.Center)
            .onClick({ _evt =>
                this.onClick()
            })
            .onTouch({ evt =>
                match (evt.eventType) {
                    case TouchType.Down =>
                        this.touchDownTime = evt.timestamp
                    case TouchType.Up =>
                        let duration = evt.timestamp - this.touchDownTime
                        if (duration > 500_000_000) {
                            this.handleLongPress()
                        }
                        this.touchDownTime = 0
                    case _ => ()
                }
            })

            Divider()
                .color(0xE5E5EA)
                .strokeWidth(1)
                .margin(left: 16)
        }
        .width(100.percent)
    }
}
