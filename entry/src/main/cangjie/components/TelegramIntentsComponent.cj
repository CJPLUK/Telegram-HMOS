package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.services.*
import std.collection.ArrayList

/**
 * TelegramIntentsComponent — 快捷意图管理面板
 *
 * iOS 原型: submodules/TelegramIntents/Sources/TelegramIntents.swift
 *
 * 功能:
 * - 展示当前已注册的联系人快捷意图列表
 * - 支持通过"捐赠全部联系人"按钮批量添加意图
 * - 支持对单个条目执行"删除"
 * - 支持清空全部意图
 *
 * 调用链:
 *   TelegramIntentsComponent.aboutToAppear()
 *     → TelegramIntentsService.getActiveDonations()
 *   TelegramIntentsComponent.onDonateAll()
 *     → TelegramIntentsService.donateTopContacts()
 *       → getRealContactService().getContacts()
 *         → MTProtoClient.send()
 */
@Component
public class TelegramIntentsComponent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var donations: ArrayList<IntentDonation> = ArrayList<IntentDonation>()
    @State var isLoading: Bool = false
    @State var statusMessage: String = ""

    private func loadDonations(): Unit {
        let service = getTelegramIntentsService()
        let active = service.getActiveDonations()
        this.donations = active
        Hilog.info(0, "CjTelegram", "[TelegramIntentsComponent] loaded ${active.size} donations")
    }

    private func onDonateAll(): Unit {
        this.isLoading = true
        this.statusMessage = "Donating contacts..."
        let _ = spawn {
            let service = getTelegramIntentsService()
            let result = service.donateTopContacts()
            Hilog.info(0, "CjTelegram", "[TelegramIntentsComponent] donated ${result.size} contacts")
            launch {
                this.isLoading = false
                this.statusMessage = "Donated ${result.size} contacts as shortcuts"
                this.loadDonations()
            }
        }
    }

    private func onDeleteIntent(peerId: Int64): Unit {
        let service = getTelegramIntentsService()
        service.deleteSendMessageIntent(peerId)
        Hilog.info(0, "CjTelegram", "[TelegramIntentsComponent] deleted intent for peerId=${peerId}")
        this.loadDonations()
        this.statusMessage = "Shortcut removed"
    }

    private func onDeleteAll(): Unit {
        let service = getTelegramIntentsService()
        service.deleteAllSendMessageIntents()
        Hilog.info(0, "CjTelegram", "[TelegramIntentsComponent] deleted all intents")
        this.loadDonations()
        this.statusMessage = "All shortcuts removed"
    }

    private func getAvatarColor(peerId: Int64): Int64 {
        let colors: Array<Int64> = [
            0xFFE91E63,
            0xFF9C27B0,
            0xFF3F51B5,
            0xFF03A9F4,
            0xFF009688,
            0xFF4CAF50,
            0xFFFF9800,
            0xFFFF5722
        ]
        let idx = peerId % 8
        let index = if (idx < 0) { Int64(-idx) } else { Int64(idx) }
        return colors[index]
    }

    public override func aboutToAppear(): Unit {
        this.loadDonations()
    }

    public func build() {
        Column {
            // 标题栏
            Row {
                Text("Send Message Shortcuts")
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
                    .flexGrow(1)
                if (this.donations.size > 0) {
                    Button(trSource("Clear All"))
                        .fontSize(13)
                        .height(30)
                        .backgroundColor(0xFFEEEE)
                        .fontColor(0xFF3B30)
                        .borderRadius(6)
                        .padding(left: 10, right: 10, top: 4, bottom: 4)
                        .onClick({ evt => this.onDeleteAll() })
                }
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 16, bottom: 8)

            // 说明文字
            Text("Shortcuts let you quickly send messages to your contacts from the launcher.")
                .fontSize(12)
                .fontColor(0x8E8E93)
                .width(100.percent)
                .padding(left: 16, right: 16, bottom: 12)
                .textAlign(TextAlign.Start)

            // 状态消息
            if (this.statusMessage.size > 0) {
                Text(this.statusMessage)
                    .fontSize(13)
                    .fontColor(0x34C759)
                    .width(100.percent)
                    .padding(left: 16, right: 16, bottom: 8)
                    .textAlign(TextAlign.Start)
            }

            // 操作按钮行
            Row {
                Button(if (this.isLoading) { "Loading..." } else { "Donate All Contacts" })
                    .fontSize(14)
                    .height(40)
                    .flexGrow(1)
                    .backgroundColor(if (this.isLoading) { 0xCCCCCC } else { 0x007AFF })
                    .fontColor(0xFFFFFF)
                    .borderRadius(8)
                    .enabled(!this.isLoading)
                    .onClick({ evt => this.onDonateAll() })
            }
            .width(100.percent)
            .padding(left: 16, right: 16, bottom: 16)

            // 已注册意图列表
            if (this.donations.size == 0) {
                Column {
                    Text("No shortcuts registered")
                        .fontSize(15)
                        .fontColor(0x8E8E93)
                        .textAlign(TextAlign.Center)
                        .width(100.percent)
                        .margin(top: 32)
                    Text("Tap \"Donate All Contacts\" to register shortcuts for your contacts.")
                        .fontSize(13)
                        .fontColor(0xAAAAAA)
                        .textAlign(TextAlign.Center)
                        .width(100.percent)
                        .padding(left: 32, right: 32, top: 8, bottom: 0)
                }
            } else {
                List {
                    ForEach(this.donations.toArray(), itemGenerator: { item: IntentDonation, _idx: Int64 =>
                        ListItem {
                            Row {
                                // 头像
                                Column {
                                    Text(item.avatarInitials)
                                        .fontSize(16)
                                        .fontColor(0xFFFFFF)
                                        .fontWeight(FontWeight.Medium)
                                }
                                .width(42)
                                .height(42)
                                .borderRadius(21)
                                .backgroundColor(this.getAvatarColor(item.peerId))
                                .justifyContent(FlexAlign.Center)
                                .alignItems(HorizontalAlign.Center)
                                .margin(right: 12)

                                // 名称 + 主题
                                Column {
                                    Text(item.displayName)
                                        .fontSize(15)
                                        .fontColor(0x000000)
                                        .fontWeight(FontWeight.Medium)
                                        .maxLines(1)
                                        .textOverflow(TextOverflow.Ellipsis)
                                    Text(item.subjectLabel())
                                        .fontSize(12)
                                        .fontColor(0x8E8E93)
                                        .margin(top: 2)
                                }
                                .alignItems(HorizontalAlign.Start)
                                .flexGrow(1)

                                // 删除按钮
                                Button(trSource("Remove"))
                                    .fontSize(12)
                                    .height(28)
                                    .backgroundColor(0xFFEEEE)
                                    .fontColor(0xFF3B30)
                                    .borderRadius(6)
                                    .padding(left: 8, right: 8, top: 4, bottom: 4)
                                    .onClick({ evt =>
                                        let id = item.peerId
                                        this.onDeleteIntent(id)
                                    })
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 10, bottom: 10)
                        }
                    })
                }
                .width(100.percent)
                .divider(ListDividerOptions(strokeWidth: 1, color: 0xF0F0F0, startMargin: 70, endMargin: 0))
            }
        }
        .width(100.percent)
        .backgroundColor(0xFFFFFF)
    }
}
