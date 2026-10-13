package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*

/**
 * 可选用户节点组件 (SelectablePeerNode)
 *
 * 仓颉 UI 组件：显示用户头像、名称，支持点击选择/取消。
 * 参考 iOS: Telegram-iOS/submodules/SelectablePeerNode/Sources/SelectablePeerNode.swift
 *
 * 布局 (compact=true, 用于 CreateGroupPage / ContactListPage 选择模式):
 * ┌─────────────────────────────────────────────────────┐
 * │  [●/○]  [头像]  显示名称                layoutWeight │
 * └─────────────────────────────────────────────────────┘
 *
 * 布局 (compact=false, 用于已选 chips 场景等纵向列表):
 * ┌───────┐
 * │ [头像] │
 * │  名称  │
 * └───────┘
 *
 * 选中态完全由父级通过 isSelected 属性控制（受控组件），
 * 点击时通过 onToggleSelection(peerId) 通知父级更新状态。
 *
 * 防死状态保证：isSelected / onToggleSelection 全部由父级注入，
 * 组件本身不持有选中状态，不会产生死状态。
 */
@Component
public class SelectablePeerComponent {
    var peerId: Int64 = 0
    var displayName: String = ""
    var avatarUrl: String = ""
    var avatarColor: Int64 = 0x317AFF
    var isOnline: Bool = false

    var isSelected: Bool = false

    /** 紧凑列表模式：横向布局 (勾选框|头像|名称)，用于 CreateGroupPage 等列表场景 */
    public var compact: Bool = false

    /** 点击时通知父级切换选中状态 */
    public var onToggleSelection: (Int64) -> Unit = { _: Int64 => }

    private func getInitials(): String {
        if (this.displayName.size == 0) { return "?" }
        let runes = this.displayName.toRuneArray()
        if (runes.size == 0) { return "?" }
        return runes[0].toString().toAsciiUpper()
    }

    private func handleTap(): Unit {
        let _ = this.onToggleSelection(this.peerId)
    }

    public func build() {
        if (this.compact) {
            // ==================== 紧凑模式：勾选框 + 头像 + 名称，横向 ====================
            Row {
                // 左侧圆形勾选框
                Row {
                    if (this.isSelected) {
                        Text("✓")
                            .fontSize(14)
                            .fontColor(0xFFFFFF)
                    }
                }
                .width(24)
                .height(24)
                .borderRadius(12)
                .backgroundColor(if (this.isSelected) { 0x317AFF } else { 0xE0E0E0 })
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)
                .margin(right: 12)

                // 头像
                if (this.avatarUrl.size > 0) {
                    Image(this.avatarUrl)
                        .width(40)
                        .height(40)
                        .borderRadius(20)
                        .objectFit(ImageFit.Cover)
                        .margin(right: 12)
                } else {
                    Column {
                        Text(this.getInitials())
                            .fontSize(16)
                            .fontColor(0xFFFFFF)
                    }
                    .width(40)
                    .height(40)
                    .borderRadius(20)
                    .backgroundColor(this.avatarColor)
                    .justifyContent(FlexAlign.Center)
                    .margin(right: 12)
                }

                // 名称
                Text(this.displayName)
                    .fontSize(16)
                    .fontColor(0x000000)
                    .layoutWeight(1)
            }
            .width(100.percent)
            .height(56)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .onClick({ _evt: ClickEvent =>
                this.handleTap()
            })
        } else {
            // ==================== 纵向模式：头像(含勾选徽章) + 名称，用于 chips strip ====================
            Column {
                Column {
                    Stack(alignContent: Alignment.BottomEnd) {
                        if (this.avatarUrl.size > 0) {
                            Image(this.avatarUrl)
                                .width(60)
                                .height(60)
                                .borderRadius(30)
                                .objectFit(ImageFit.Cover)
                        } else {
                            Column {
                                Text(this.getInitials())
                                    .fontSize(24)
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(0xFFFFFF)
                            }
                            .width(60)
                            .height(60)
                            .borderRadius(30)
                            .backgroundColor(this.avatarColor)
                            .justifyContent(FlexAlign.Center)
                        }

                        if (this.isSelected) {
                            Column {
                                Text("✓")
                                    .fontSize(14)
                                    .fontColor(0xFFFFFF)
                            }
                            .width(22)
                            .height(22)
                            .borderRadius(11)
                            .backgroundColor(0x007AFF)
                            .justifyContent(FlexAlign.Center)
                            .margin(right: -4, bottom: -4)
                        }
                    }
                    .width(60)
                    .height(60)

                    Text(this.displayName)
                        .fontSize(11)
                        .fontColor(if (this.isSelected) { 0x007AFF } else { 0x000000 })
                        .maxLines(2)
                        .textOverflow(TextOverflow.Ellipsis)
                        .textAlign(TextAlign.Center)
                        .margin(top: 4)
                        .width(80)
                }
                .onClick({ _evt: ClickEvent =>
                    this.handleTap()
                })
            }
            .width(80)
            .padding(8)
        }
    }
}

/**
 * 已选 peer 的 chip 组件（用于 CreateGroupPage 顶部已选横向条）
 *
 * 显示：小头像 + 短名 + "×"关闭按钮
 * 点击整个 chip 或 × 号均触发 onRemove
 *
 * 参考 iOS: CreateGroupController 顶部 selectedPeerView 横向滚动条
 */
@Component
public class SelectedPeerChip {
    var peerId: Int64 = 0
    var displayName: String = ""
    var avatarUrl: String = ""
    var avatarColor: Int64 = 0x317AFF
    public var onRemove: (Int64) -> Unit = { _: Int64 => }

    private func getInitials(): String {
        if (this.displayName.size == 0) { return "?" }
        let runes = this.displayName.toRuneArray()
        if (runes.size == 0) { return "?" }
        return runes[0].toString().toAsciiUpper()
    }

    private func shortName(): String {
        let runes = this.displayName.toRuneArray()
        if (runes.size <= 7) { return this.displayName }
        var result = ""
        var i: Int64 = 0
        while (i < 7) {
            result = result + runes[i].toString()
            i = i + 1
        }
        return result + "…"
    }

    public func build() {
        Column {
            Stack(alignContent: Alignment.TopEnd) {
                // 头像
                if (this.avatarUrl.size > 0) {
                    Image(this.avatarUrl)
                        .width(48)
                        .height(48)
                        .borderRadius(24)
                        .objectFit(ImageFit.Cover)
                } else {
                    Column {
                        Text(this.getInitials())
                            .fontSize(18)
                            .fontColor(0xFFFFFF)
                            .fontWeight(FontWeight.Medium)
                    }
                    .width(48)
                    .height(48)
                    .borderRadius(24)
                    .backgroundColor(this.avatarColor)
                    .justifyContent(FlexAlign.Center)
                }

                // × 关闭徽章
                Column {
                    Text("×")
                        .fontSize(12)
                        .fontColor(0xFFFFFF)
                        .fontWeight(FontWeight.Bold)
                }
                .width(18)
                .height(18)
                .borderRadius(9)
                .backgroundColor(0x8E8E93)
                .justifyContent(FlexAlign.Center)
                .margin(top: -2, right: -2)
            }
            .width(48)
            .height(48)

            Text(this.shortName())
                .fontSize(11)
                .fontColor(0x000000)
                .maxLines(1)
                .textOverflow(TextOverflow.Ellipsis)
                .textAlign(TextAlign.Center)
                .width(64)
                .margin(top: 4)
        }
        .width(72)
        .alignItems(HorizontalAlign.Center)
        .padding(top: 4, bottom: 4)
        .onClick({ _evt: ClickEvent =>
            let _ = this.onRemove(this.peerId)
        })
    }
}
