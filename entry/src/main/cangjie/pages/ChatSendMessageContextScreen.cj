package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.convert.*
import std.time.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*

/**
 * ChatSendMessageContextScreen
 *
 * 发送选项菜单的页面根容器（D-002：根容器必须是 NavDestination）。
 * 对应 iOS ChatSendMessageContextScreen（ViewControllerComponentContainer）。
 *
 * 路由参数（从 appStack.pushPathByName("ChatSendMessageContextScreen", param) 获取）：
 *   参数格式：peerType|peerId|messageText
 *   例如："user|123456789|Hello world"
 *
 * 菜单选项（对应 iOS ChatSendMessageActionSheetController.swift）：
 *   1. 定时发送 (Schedule Message) — TL flags bit 10 (0x400)
 *   2. 静默发送 (Send Without Sound) — TL flags bit 5 (0x20)
 *   3. 消息效果 (Message Effect, Premium) — TL flags bit 18 (0x40000)
 *
 * D-002: build() 根容器必须是 NavDestination()。
 * S-64: aboutToAppear/aboutToDisappear 必须是 public override func。
 */
// S2-63 / S2-70: the sheet only picks an option; the actual send goes through the
// chat page's normal pipeline (ChatRoomViewModel.sendMessage with silent /
// scheduleDate / effect), exactly like iOS ChatSendMessageActionSheetController
// calling back into ChatController.sendCurrentMessage(silently:) /
// scheduleCurrentMessage. Actions: "silent" | "schedule" | "effect" (value = effect id).
private var _sendContextActionHandler: Option<(String, Int64) -> Unit> = None

public func registerSendContextActionHandler(handler: (String, Int64) -> Unit): Unit {
    _sendContextActionHandler = Some(handler)
}

func fireSendContextAction(action: String, value: Int64): Unit {
    match (_sendContextActionHandler) {
        case Some(h) => h(action, value)
        case None => ()
    }
    _sendContextActionHandler = None
}

@HybridComponentEntry
@Component
public class ChatSendMessageContextScreen {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var peerType: String = "user"
    @State var peerId: Int64 = 0
    @State var messageText: String = ""

    @State var showEffectPanel: Bool = false
    @State var selectedEffectId: Int64 = 0
    @State var selectedEffectEmoji: String = ""
    @State var scheduleDateTs: Int32 = 0
    @State var statusMessage: String = ""
    @State var loaded: Bool = false

    // 预设效果的 emoji 名称和 effect_id（Telegram 官方消息效果）
    let effectEmojis: Array<String> = ["heart", "thumbsup", "fire", "party", "poo", "star"]
    let effectIds: Array<Int64> = [5046509860, 5107584773, 5459771352, 5948840990, 5046509895, 5107584881]

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        // 混合迁移：原 onReady 经 NavDestination param 取参，改为 takePending。
        let raw = takePending("ChatSendMessageContextScreen")
        if (raw.size > 0 && raw != "{}") {
            this.parseRouteParam(raw)
        }
    }

    public func build() {
        Stack() {
                // 半透明背景遮罩，点击可关闭菜单
                Column()
                    .width(100.percent)
                    .height(100.percent)
                    .backgroundColor(0x66000000)
                    .onClick({ _ =>
                        routerPop()
                    })

                // 菜单卡片（底部对齐）
                Column() {
                    this.buildMenuCard()
                }
                .width(100.percent)
                .justifyContent(FlexAlign.End)
                .alignItems(HorizontalAlign.Center)
                .height(100.percent)
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ => this.ensureLoaded() })
    }

    @Builder
    func buildMenuCard() {
        Column() {
            // 菜单标题
            Row() {
                Text(trSource("Send Message"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0xFF1C1C1E)
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 12, bottom: 8)

            // 选项 1: 定时发送
            this.buildScheduleOptionRow()

            // 选项 2: 静默发送
            this.buildSilentOptionRow()

            // 选项 3: 消息效果
            this.buildEffectOptionRow()

            // 效果选择面板
            if (this.showEffectPanel) {
                this.buildEffectPanel()
            }

            // 状态提示
            if (this.statusMessage.size > 0) {
                Row() {
                    Text(this.statusMessage)
                        .fontSize(13)
                        .fontColor(0xFF007AFF)
                        .maxLines(1)
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 4, bottom: 4)
            }
        }
        .width(100.percent)
        .backgroundColor(0xFFF2F2F7)
        .borderRadius(16)
        .margin(left: 8, right: 8, bottom: 32)
    }

    @Builder
    func buildScheduleOptionRow() {
        Row() {
            Column() {
                Text("Sched")
                    .fontSize(11)
                    .fontColor(0xFFFFFFFF)
            }
            .width(44)
            .height(44)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor(0xFF34AADC)
            .borderRadius(10)

            Column() {
                Text(trSource("Schedule Message"))
                    .fontSize(16)
                    .fontColor(0xFF1C1C1E)
                Text(if (this.scheduleDateTs > 0) { "Scheduled" } else { "Send at a specific time" })
                    .fontSize(13)
                    .fontColor(0xFF8E8E93)
            }
            .alignItems(HorizontalAlign.Start)
            .margin(left: 12)
            .layoutWeight(1)

            Text(">")
                .fontSize(16)
                .fontColor(0xFF8E8E93)
        }
        .width(100.percent)
        .height(60)
        .padding(left: 16, right: 16)
        .backgroundColor(0xFFFFFFFF)
        .margin(bottom: 1)
        .onClick({ _ =>
            this.onScheduleSelected()
        })
    }

    @Builder
    func buildSilentOptionRow() {
        Row() {
            Column() {
                Text(trSource("Mute"))
                    .fontSize(12)
                    .fontColor(0xFFFFFFFF)
            }
            .width(44)
            .height(44)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor(0xFF5856D6)
            .borderRadius(10)

            Column() {
                Text(trSource("Send Without Sound"))
                    .fontSize(16)
                    .fontColor(0xFF1C1C1E)
                Text("No notification for recipient")
                    .fontSize(13)
                    .fontColor(0xFF8E8E93)
            }
            .alignItems(HorizontalAlign.Start)
            .margin(left: 12)
            .layoutWeight(1)
        }
        .width(100.percent)
        .height(60)
        .padding(left: 16, right: 16)
        .backgroundColor(0xFFFFFFFF)
        .margin(bottom: 1)
        .onClick({ _ =>
            this.onSilentSelected()
        })
    }

    @Builder
    func buildEffectOptionRow() {
        Row() {
            Column() {
                Text("FX")
                    .fontSize(16)
                    .fontColor(0xFFFFFFFF)
            }
            .width(44)
            .height(44)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor(0xFFFF9500)
            .borderRadius(10)

            Column() {
                Text("Message Effect")
                    .fontSize(16)
                    .fontColor(0xFF1C1C1E)
                Text(if (this.selectedEffectEmoji.size > 0) {
                    "Effect selected"
                } else {
                    "Add animation to message"
                })
                    .fontSize(13)
                    .fontColor(0xFF8E8E93)
            }
            .alignItems(HorizontalAlign.Start)
            .margin(left: 12)
            .layoutWeight(1)

            Text(if (this.showEffectPanel) { "v" } else { ">" })
                .fontSize(16)
                .fontColor(0xFF8E8E93)
        }
        .width(100.percent)
        .height(60)
        .padding(left: 16, right: 16)
        .backgroundColor(0xFFFFFFFF)
        .onClick({ _ =>
            this.showEffectPanel = !this.showEffectPanel
        })
    }

    @Builder
    func buildEffectPanel() {
        Column() {
            Row() {
                Column() {
                    Text(this.effectEmojis[0])
                        .fontSize(14)
                        .fontColor(if (this.selectedEffectId == this.effectIds[0]) { 0xFF007AFF } else { 0xFF1C1C1E })
                        .textAlign(TextAlign.Center)
                }
                .width(44).height(44).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .borderRadius(22)
                .backgroundColor(if (this.selectedEffectId == this.effectIds[0]) { 0x33007AFF } else { 0x1A000000 })
                .margin(right: 8)
                .onClick({ _ =>
                    this.selectedEffectId = this.effectIds[0]
                    this.selectedEffectEmoji = this.effectEmojis[0]
                })

                Column() {
                    Text(this.effectEmojis[1])
                        .fontSize(14)
                        .fontColor(if (this.selectedEffectId == this.effectIds[1]) { 0xFF007AFF } else { 0xFF1C1C1E })
                        .textAlign(TextAlign.Center)
                }
                .width(44).height(44).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .borderRadius(22)
                .backgroundColor(if (this.selectedEffectId == this.effectIds[1]) { 0x33007AFF } else { 0x1A000000 })
                .margin(right: 8)
                .onClick({ _ =>
                    this.selectedEffectId = this.effectIds[1]
                    this.selectedEffectEmoji = this.effectEmojis[1]
                })

                Column() {
                    Text(this.effectEmojis[2])
                        .fontSize(14)
                        .fontColor(if (this.selectedEffectId == this.effectIds[2]) { 0xFF007AFF } else { 0xFF1C1C1E })
                        .textAlign(TextAlign.Center)
                }
                .width(44).height(44).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .borderRadius(22)
                .backgroundColor(if (this.selectedEffectId == this.effectIds[2]) { 0x33007AFF } else { 0x1A000000 })
                .margin(right: 8)
                .onClick({ _ =>
                    this.selectedEffectId = this.effectIds[2]
                    this.selectedEffectEmoji = this.effectEmojis[2]
                })

                Column() {
                    Text(this.effectEmojis[3])
                        .fontSize(14)
                        .fontColor(if (this.selectedEffectId == this.effectIds[3]) { 0xFF007AFF } else { 0xFF1C1C1E })
                        .textAlign(TextAlign.Center)
                }
                .width(44).height(44).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .borderRadius(22)
                .backgroundColor(if (this.selectedEffectId == this.effectIds[3]) { 0x33007AFF } else { 0x1A000000 })
                .margin(right: 8)
                .onClick({ _ =>
                    this.selectedEffectId = this.effectIds[3]
                    this.selectedEffectEmoji = this.effectEmojis[3]
                })

                Column() {
                    Text(this.effectEmojis[4])
                        .fontSize(14)
                        .fontColor(if (this.selectedEffectId == this.effectIds[4]) { 0xFF007AFF } else { 0xFF1C1C1E })
                        .textAlign(TextAlign.Center)
                }
                .width(44).height(44).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .borderRadius(22)
                .backgroundColor(if (this.selectedEffectId == this.effectIds[4]) { 0x33007AFF } else { 0x1A000000 })
                .margin(right: 8)
                .onClick({ _ =>
                    this.selectedEffectId = this.effectIds[4]
                    this.selectedEffectEmoji = this.effectEmojis[4]
                })

                Column() {
                    Text(this.effectEmojis[5])
                        .fontSize(14)
                        .fontColor(if (this.selectedEffectId == this.effectIds[5]) { 0xFF007AFF } else { 0xFF1C1C1E })
                        .textAlign(TextAlign.Center)
                }
                .width(44).height(44).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .borderRadius(22)
                .backgroundColor(if (this.selectedEffectId == this.effectIds[5]) { 0x33007AFF } else { 0x1A000000 })
                .onClick({ _ =>
                    this.selectedEffectId = this.effectIds[5]
                    this.selectedEffectEmoji = this.effectEmojis[5]
                })
            }
            .padding(left: 16, right: 16, top: 8, bottom: 8)
            .width(100.percent)
            .justifyContent(FlexAlign.Start)

            Row() {
                Text("Send with Effect")
                    .fontSize(16)
                    .fontColor(if (this.selectedEffectId != 0) { 0xFFFFFFFF } else { 0xFF8E8E93 })
                    .textAlign(TextAlign.Center)
                    .width(100.percent)
            }
            .width(100.percent)
            .height(44)
            .backgroundColor(
                if (this.selectedEffectId != 0) { 0xFF007AFF } else { 0xFFE5E5EA }
            )
            .borderRadius(10)
            .margin(left: 16, right: 16, bottom: 8)
            .onClick({ _ =>
                if (this.selectedEffectId != 0) {
                    this.onEffectSelected(this.selectedEffectId)
                }
            })
        }
        .width(100.percent)
        .backgroundColor(0xFFF9F9F9)
    }

    // ==================== 动作处理 ====================

    private func onSilentSelected() {
        Hilog.info(0, "CjTelegram", "[ChatSendMsgCtxScreen] Silent send: peerType=${this.peerType}, peerId=${this.peerId}")
        fireSendContextAction("silent", 0)
        routerPop()
    }

    private func onScheduleSelected() {
        Hilog.info(0, "CjTelegram", "[ChatSendMsgCtxScreen] Schedule: peerType=${this.peerType}, peerId=${this.peerId}")
        fireSendContextAction("schedule", 0)
        routerPop()
    }

    private func onEffectSelected(effectId: Int64) {
        Hilog.info(0, "CjTelegram", "[ChatSendMsgCtxScreen] Effect send: peerType=${this.peerType}, peerId=${this.peerId}, effectId=${effectId}")
        this.showEffectPanel = false
        fireSendContextAction("effect", effectId)
        routerPop()
    }

    private func parseRouteParam(param: String) {
        if (param.size == 0) { return }
        let parts = param.split("|")
        if (parts.size >= 1) {
            this.peerType = parts[0]
        }
        if (parts.size >= 2) {
            try {
                this.peerId = Int64.parse(parts[1])
            } catch (_: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatSendMsgCtxScreen] Failed to parse peerId from param")
            }
        }
        if (parts.size >= 3) {
            this.messageText = parts[2]
        }
        Hilog.info(0, "CjTelegram", "[ChatSendMsgCtxScreen] Parsed: peerType=${this.peerType}, peerId=${this.peerId}, text=${this.messageText}")
    }
}
