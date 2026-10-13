package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.services.*
import std.collection.ArrayList

/**
 * AnimatedAvatarSetComponent — 动画头像堆叠组件
 *
 * 对应 iOS AnimatedAvatarSetNode / AnimatedAvatarSetView
 * (AnimatedAvatarSetNode.swift)
 *
 * 功能:
 * - 将多个头像以重叠方式水平排列（iOS 10px spacing，后一个叠在前一个右侧）
 * - 头像进入时：透明度 0→1 + scale 0.1→1.0（约 200ms）
 * - 头像离开时：透明度 1→0 + scale 1.0→0.1（约 200ms）
 * - 靠后的头像 zIndex 更高（与 iOS contentNodes zPosition = 100 - i 一致）
 * - 每个头像：有图片时圆形图片，无图片时彩色文字缩写
 * - 最多显示 maxVisible 个头像，超出部分显示 "+N" 徽章
 *
 * 使用方式（直接传 items）:
 *   AnimatedAvatarSetComponent(items: avatarItemArray, avatarSize: 30, spacing: 10)
 *
 * 使用方式（绑定 contextId + userIds，由组件自驱动从 AnimatedAvatarSetService 获取数据）:
 *   AnimatedAvatarSetComponent(contextId: msgId, userIds: readerIds)
 */
@Component
public class AnimatedAvatarSetComponent {
    // Direct item input (caller pre-builds via AnimatedAvatarSetService.buildItems)
    var items: Array<AvatarItem> = []
    // Avatar diameter in vp
    var avatarSize: Int64 = 30
    // Overlap offset in vp: how much each subsequent avatar shifts right
    var spacing: Int64 = 10
    // Max number of visible avatars; 0 = unlimited
    var maxVisible: Int64 = 5
    // Optional: context ID for service-driven mode (set along with userIds)
    var contextId: Int64 = 0
    // Optional: user ID list for service-driven mode
    var userIds: Array<Int64> = []

    // Internal state managed by the component
    @State var serviceItems: Array<AvatarItem> = []
    @State var refreshTick: Int64 = 0

    public override func aboutToAppear(): Unit {
        if (this.contextId != 0 && this.userIds.size > 0) {
            let service = getAnimatedAvatarSetService()
            let uidList = ArrayList<Int64>()
            for (uid in this.userIds) {
                uidList.add(uid)
            }
            let fetched = service.update(this.contextId, uidList)
            let arr = Array<AvatarItem>(fetched.size, { i: Int64 => fetched[i] })
            this.serviceItems = arr
            let _ = spawn {
                getAnimatedAvatarSetService().requestFullPhotos(this.contextId)
            }
            Hilog.info(0, "CjTelegram", "[AvatarSetComp] aboutToAppear ctx=${this.contextId} count=${this.serviceItems.size}")
        }
    }

    private func getEffectiveItems(): Array<AvatarItem> {
        if (this.serviceItems.size > 0) {
            return this.serviceItems
        }
        return this.items
    }

    private func getVisibleCount(): Int64 {
        let total = Int64(this.getEffectiveItems().size)
        if (this.maxVisible > 0 && total > this.maxVisible) {
            return this.maxVisible
        }
        return total
    }

    private func getOverflowCount(): Int64 {
        let total = Int64(this.getEffectiveItems().size)
        return total - this.getVisibleCount()
    }

    private func getInitialsAt(i: Int64): String {
        let eff = this.getEffectiveItems()
        if (i < 0 || i >= Int64(eff.size)) { return "?" }
        let name = eff[i].displayName
        if (name.size == 0) { return "?" }
        let runes = name.toRuneArray()
        return String(runes[0]).toAsciiUpper()
    }

    private func leftMarginAt(i: Int64): Int64 {
        if (i == 0) { return 0 }
        return -(this.spacing)
    }

    func build() {
        Row() {
            ForEach(Array<Int64>(this.getVisibleCount(), { i: Int64 => i }),
                itemGenerator: { idx: Int64, _unused: Int64 =>
                    Stack() {
                        if (this.getEffectiveItems()[idx].photoUrl.size > 0) {
                            Image(this.getEffectiveItems()[idx].photoUrl)
                                .width(this.avatarSize)
                                .height(this.avatarSize)
                                .borderRadius(this.avatarSize / 2)
                                .objectFit(ImageFit.Cover)
                                .border(width: 2, color: 0xFFFFFFFF)
                        } else {
                            Column() {
                                Text(this.getInitialsAt(idx))
                                    .fontSize(this.avatarSize * 4 / 10)
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(0xFFFFFF)
                            }
                            .width(this.avatarSize)
                            .height(this.avatarSize)
                            .borderRadius(this.avatarSize / 2)
                            .backgroundColor(this.getEffectiveItems()[idx].avatarColor)
                            .justifyContent(FlexAlign.Center)
                            .border(width: 2, color: 0xFFFFFFFF)
                        }
                    }
                    .width(this.avatarSize)
                    .height(this.avatarSize)
                    .margin(left: this.leftMarginAt(idx))
                    .zIndex(Int32(100 - idx))
                    .transition(
                        TransitionEffect.asymmetric(
                            TransitionEffect.OPACITY.combine(
                                TransitionEffect.scale(ScaleOptions(x: 0.1, y: 0.1))
                            ).animation(AnimateParam(duration: 200, curve: Curve.EaseOut)),
                            TransitionEffect.OPACITY.combine(
                                TransitionEffect.scale(ScaleOptions(x: 0.1, y: 0.1))
                            ).animation(AnimateParam(duration: 200, curve: Curve.EaseIn))
                        )
                    )
                }
            )

            if (this.getOverflowCount() > 0) {
                Stack() {
                    Column() {
                        Text("+" + this.getOverflowCount().toString())
                            .fontSize(this.avatarSize * 3 / 10)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0xFFFFFF)
                    }
                    .width(this.avatarSize)
                    .height(this.avatarSize)
                    .borderRadius(this.avatarSize / 2)
                    .backgroundColor(0xFF8A8A8E)
                    .justifyContent(FlexAlign.Center)
                    .border(width: 2, color: 0xFFFFFFFF)
                }
                .width(this.avatarSize)
                .height(this.avatarSize)
                .margin(left: -(this.spacing))
                .zIndex(0)
            }
        }
        .height(this.avatarSize)
        .clip(false)
    }
}
