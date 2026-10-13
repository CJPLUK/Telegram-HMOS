package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.utils.safeAnimateTo
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation}
import std.sync.*
import std.time.*

/**
 * ContactsPeerComponent — 联系人项组件（可复用列表项）
 *
 * 对应 iOS ContactsPeerItem.swift
 * 布局: 头像(圆形) + 名字(加粗) + 上次在线(灰色) + 可选右侧操作
 *
 * 使用 ContactsPeerService 获取头像 URL，不重复实现联系人逻辑。
 */
@Component
public class ContactsPeerComponent {
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    // 联系人数据
    var contact: ContactDisplayData = ContactDisplayData()

    // 点击回调
    public var onClick: () -> Unit = { => }

    // 长按回调
    public var onLongPress: () -> Unit = { => }
    // 长按回调（带本行在屏幕上的顶 y 与高度，供上下文预览从行处弹出）
    public var onLongPressAt: (Float64, Float64) -> Unit = { _y: Float64, _h: Float64 => }
    private var rowTop: Float64 = 0.0
    private var rowHeight: Float64 = 49.0

    @State var isPressed: Bool = false

    // 长按识别 —— 与 ChatListItem / MessageBubble 同一套语义：按下即起定时器、
    // 手指移动超阈值取消、到时**按住即触发**（不再等抬手）。
    // 此前在 TouchType.Up 里回算时长，导致同一次抬手先派发 onClick 跳进会话、
    // 再回调 onLongPress 把底下页面的菜单置 true（人工反馈 #10：先进对话框、退回才见半屏面板）。
    private var pressGeneration: Int64 = 0
    private var pressActive: Bool = false
    private var touchStartX: Float64 = 0.0
    private var touchStartY: Float64 = 0.0
    // 长按已消费本次手势，随后的 onClick 不应再进会话
    private var suppressNextClick: Bool = false

    private func getAvatarUrl(): String {
        return getContactsPeerService().getAvatarUrl(this.contact.userId)
    }

    private func getAvatarColor(): UInt32 {
        return getContactsPeerService().getAvatarColor(this.contact.userId)
    }

    private func hasAvatarPhoto(): Bool {
        return this.getAvatarUrl().size > 0
    }

    public func build() {
        Row {
            // 头像区域
            Stack(alignContent: Alignment.BottomEnd) {
                if (this.hasAvatarPhoto()) {
                    Image(this.getAvatarUrl())
                        .width(40)
                        .height(40)
                        .borderRadius(20)
                        .objectFit(ImageFit.Cover)
                } else {
                    Column {
                        Text(this.contact.getAvatarInitials())
                            .fontSize(if (this.contact.getAvatarInitials().size > 1) { 15 } else { 18 })
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0xFFFFFF)
                    }
                    .width(40)
                    .height(40)
                    .borderRadius(20)
                    .backgroundColor(this.getAvatarColor())
                    .justifyContent(FlexAlign.Center)
                }
                // 源侧 ContactsPeerItem 无在线绿点（在线仅用蓝色 "online" 副标题表达，
                // 见 e2e/source_digest/peer_contacts_peer_item.md:272）；原目标侧自加的
                // 10×10 绿色角标已按人工反馈移除。
            }
            .width(40)
            .height(40)
            .margin(right: 14)

            // 名字 + 状态
            Column {
                // G-02: iOS lastFirst 显示——主排序名(姓)加粗前置,名常规字重跟随
                // (参考端实拍 "**Yuan** Hao" / "**Fawaz** Adam")
                Row {
                    Text(this.contact.getListPrimaryName())
                        .fontSize(17)
                        .fontColor(this.presentation.textColor)
                        .fontWeight(FontWeight.Medium)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                    if (this.contact.getListSecondaryName().size > 0) {
                        Text(" " + this.contact.getListSecondaryName())
                            .fontSize(17)
                            .fontColor(this.presentation.textColor)
                            .fontWeight(FontWeight.Regular)
                            .maxLines(1)
                            .textOverflow(TextOverflow.Ellipsis)
                    }
                }
                .alignItems(VerticalAlign.Center)
                Text(this.contact.getLastSeenText())
                    .fontSize(13)
                    .fontColor(if (this.contact.isOnline) { this.presentation.accentColor } else { this.presentation.secondaryTextColor })
                    .margin(top: 2)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
        }
        .width(100.percent)
        // G-06: iOS ContactsPeerItem 行高 49pt(原 54 逐行累计出 4% 锚点漂移)
        .height(49)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        // CTL-SHARED-002: iOS 行按压高亮
        .backgroundColor(if (this.isPressed) { this.presentation.itemHighlightedBackgroundColor } else { this.presentation.backgroundColor })
        .onClick({ _evt =>
            if (this.suppressNextClick) {
                this.suppressNextClick = false
                return
            }
            this.onClick()
        })
        .onTouch({ evt =>
                match (evt.eventType) {
                    case TouchType.Down =>
                        if (evt.touches.size > 0) {
                            this.touchStartX = evt.touches[0].x
                            this.touchStartY = evt.touches[0].y
                        }
                        this.isPressed = true
                        this.pressActive = true
                        this.pressGeneration += 1
                        let generation = this.pressGeneration
                        // 与 ChatListItem 的 320ms（iOS beginDelay + animator 合计）保持一致
                        spawn {
                            sleep(Duration.millisecond * 320)
                            launch {
                                if (this.pressActive && generation == this.pressGeneration) {
                                    this.pressActive = false
                                    this.suppressNextClick = true
                                    triggerHaptic("impact", "light")
                                    this.onLongPress()
                                    this.onLongPressAt(this.rowTop, this.rowHeight)
                                }
                            }
                        }
                    case TouchType.Move =>
                        if (this.pressActive && evt.touches.size > 0) {
                            // 尚未激活：滑动列表不应触发长按，位移超过 8vp 即放弃本次识别
                            let dx = evt.touches[0].x - this.touchStartX
                            let dy = evt.touches[0].y - this.touchStartY
                            if (dx * dx + dy * dy > 64.0) {
                                this.pressActive = false
                                this.pressGeneration += 1
                                this.isPressed = false
                            }
                        }
                    case TouchType.Up =>
                        this.pressActive = false
                        this.pressGeneration += 1
                        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 300, curve: Curve.EaseInOut), { =>
                            this.isPressed = false
                        })
                    case _ =>
                        this.pressActive = false
                        this.pressGeneration += 1
                        this.isPressed = false
                }
            })
            .onAreaChange({ _: Area, newArea: Area =>
                this.rowHeight = newArea.height.value
                match (newArea.globalPosition.y) {
                    case Some(top) => this.rowTop = top.value
                    case None => ()
                }
            })
    }
}
