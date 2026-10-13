package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__

/**
 * story 环状态
 * None   = 不显示环（默认）
 * Unread = 未读 story，多色渐变环
 * Read   = 已读 story，灰色环
 */
public enum AvatarStoryState {
    | None
    | Unread
    | Read
}

/**
 * 特殊 peer 类型
 * Normal        = 普通 peer（默认）
 * SavedMessages = Saved Messages（自己），蓝渐变 + 书签
 * Replies       = Replies Bot，蓝渐变 + 回复
 * Anonymous     = Anonymous / Channel，蓝渐变 + 问号
 * Deleted       = 已删账号，灰色 + X
 */
public enum AvatarSpecialPeer {
    | Normal
    | SavedMessages
    | Replies
    | Anonymous
    | Deleted
}

func avatarPaletteColor(index: Int64): Int64 {
    let palette: Array<Int64> = [
        0xFFff516a,
        0xFFffa85c,
        0xFF665fff,
        0xFF54cb68,
        0xFF4acccd,
        0xFF2a9ef1,
        0xFFd669ed
    ]
    let idx = ((index % 7) + 7) % 7
    return palette[idx]
}

// F-4（diag-suite_settings_appearance-TC-0417-round5.md）：源侧 AvatarNode.gradientColors
// （AvatarNode.swift:318-326）是 7 个色对，而不是上面 avatarPaletteColor 的 7 个单色。
// 新增本函数返回完整色对；avatarPaletteColor 保留不动 —— 它被 components/MessageBubble.cj:2697
// 的 fontColor 取色调用（单色语义，不属于本 feature target_files，不得改动其签名）。
func avatarGradientColors(index: Int64): (Int64, Int64) {
    let palette: Array<(Int64, Int64)> = [
        (0xFFff516a, 0xFFff885e),
        (0xFFffa85c, 0xFFffcd6a),
        (0xFF665fff, 0xFF82b1ff),
        (0xFF54cb68, 0xFFa0de7e),
        (0xFF4acccd, 0xFF00fcfd),
        (0xFF2a9ef1, 0xFF72d5fd),
        (0xFFd669ed, 0xFFe0a2f3)
    ]
    let idx = ((index % 7) + 7) % 7
    return palette[idx]
}

func avatarColorIndex(peerId: Int64): Int64 {
    let absId = if (peerId < 0) { -peerId } else { peerId }
    return absId % 7
}

/**
 * Avatar — 通用头像原子组件 (P2-142 重构版)
 *
 * 对应 iOS AvatarNode 核心能力：
 * 1. story 环：unread 彩色渐变环 / read 灰色环
 * 2. premium 环（isPremium → 金色环）
 * 3. forum 圆角方形（isForum → borderRadius 25%）
 * 4. 双字母首字母 + peerId 派生渐变底色（iOS 7 色板）
 * 5. 特殊态：Deleted 灰、SavedMessages 蓝、Replies 蓝、Anonymous 蓝
 * 6. 图片加载淡入动画（opacity 0→1 + animation 250ms）
 * 7. 尺寸参数化
 *
 * 后向兼容：原有 6 个参数（avatarUrl/displayName/avatarSize/avatarColor/
 * isOnline/showOnlineIndicator）保留默认值，已有调用方无需修改。
 */
@Component
public class Avatar {
    public var avatarUrl: String = ""
    public var displayName: String = ""
    public var avatarSize: Int64 = 50
    public var avatarColor: Int64 = 0xFF5733
    public var isOnline: Bool = false
    public var showOnlineIndicator: Bool = false

    public var peerId: Int64 = 0
    public var isPremium: Bool = false
    public var isForum: Bool = false
    public var storyState: AvatarStoryState = AvatarStoryState.None
    public var specialPeer: AvatarSpecialPeer = AvatarSpecialPeer.Normal
    // F-4（OF-6b）：字母由调用方供给（对位源侧 AvatarNodeParameters.letters ← peer.displayLetters，
    // PeerUtils.swift:95-130，按 peer 结构化字段推导，不在视图层猜）。默认空串 ⇒ 未升级的调用点
    // 落到 getDoubleInitials() 兜底，行为逐像素不变。
    public var letters: String = ""

    @State var imageLoadFailed: Bool = false
    @State var imageOpacity: Float64 = 0.0

    private func shouldShowImage(): Bool {
        return this.avatarUrl.size > 0 && !this.imageLoadFailed
    }

    // F-4：优先级改为以 peerId 为先，对位源侧 calculateAvatarColors（AvatarNode.swift:75-88）——
    // 该路径上 explicitColorIndex 恒为 nil，普通 peer 一律走 peerId % 7；显式 avatarColor
    // 覆盖分支是目标侧自造入口，源侧无对应物，仅为 peerId == 0 的两个既有调用点
    // （ChatListSearchRecentPeersComponent.cj:74、ItemListPeerComponent.cj:84，均不传 peerId）
    // 保留现状行为，故降到第二优先级；不得提到第一优先级。
    private func derivedGradient(): (Int64, Int64) {
        if (this.peerId != 0) {
            return avatarGradientColors(avatarColorIndex(this.peerId))
        }
        if (this.avatarColor != 0xFF5733) {
            return (this.avatarColor, this.avatarColor)
        }
        return avatarGradientColors(0)
    }

    // `@Builder` 方法体只允许 UI 组件语法，不能在其顶层写 `let (a, b) = ...` 解构
    // 语句（S-XXX 新增，见 syntax_error.md）；故把 derivedGradient() 的两个分量各拆一个
    // 无参访问器，供 buildNormalInitialsInner() 的修饰符调用点直接取值。
    private func derivedGradientBase(): Int64 {
        let (base, _) = this.derivedGradient()
        return base
    }

    private func derivedGradientLight(): Int64 {
        let (_, light) = this.derivedGradient()
        return light
    }

    private func getDoubleInitials(): String {
        let name = this.displayName
        if (name.size == 0) {
            return "?"
        }
        let runes = name.toRuneArray()
        if (runes.size == 0) {
            return "?"
        }
        let firstStr = String(runes[0]).toAsciiUpper()
        let parts = name.split(" ")
        if (parts.size >= 2) {
            let secondPart = parts[1]
            let secondRunes = secondPart.toRuneArray()
            if (secondRunes.size > 0) {
                let secondStr = String(secondRunes[0]).toAsciiUpper()
                return firstStr + secondStr
            }
        }
        return firstStr
    }

    private func hasRing(): Bool {
        match (this.storyState) {
            case Unread => return true
            case Read => return true
            case None => return this.isPremium
        }
    }

    private func ringWidth(): Int64 {
        return this.avatarSize / 14 + 1
    }

    private func ringGap(): Int64 {
        return this.ringWidth()
    }

    private func outerSize(): Int64 {
        return this.avatarSize + (this.ringWidth() + this.ringGap()) * 2
    }

    private func innerBorderRadius(): Int64 {
        if (this.isForum) {
            return this.avatarSize * 25 / 100
        }
        return this.avatarSize / 2
    }

    private func outerBorderRadius(): Int64 {
        if (this.isForum) {
            return this.outerSize() * 25 / 100
        }
        return this.outerSize() / 2
    }

    private func isStoryUnread(): Bool {
        match (this.storyState) {
            case Unread => return true
            case _ => return false
        }
    }

    private func isStoryRead(): Bool {
        match (this.storyState) {
            case Read => return true
            case _ => return false
        }
    }

    private func isPremiumRing(): Bool {
        match (this.storyState) {
            case None => return this.isPremium
            case _ => return false
        }
    }

    private func isSpecialSavedMessages(): Bool {
        match (this.specialPeer) {
            case SavedMessages => return true
            case _ => return false
        }
    }

    private func isSpecialReplies(): Bool {
        match (this.specialPeer) {
            case Replies => return true
            case _ => return false
        }
    }

    private func isSpecialAnonymous(): Bool {
        match (this.specialPeer) {
            case Anonymous => return true
            case _ => return false
        }
    }

    private func isSpecialDeleted(): Bool {
        match (this.specialPeer) {
            case Deleted => return true
            case _ => return false
        }
    }

    private func isSpecialNormal(): Bool {
        match (this.specialPeer) {
            case Normal => return true
            case _ => return false
        }
    }

    @Builder
    func buildStoryUnreadRing() {
        Column {}
            .width(this.outerSize())
            .height(this.outerSize())
            .borderRadius(this.outerBorderRadius())
            .sweepGradient(
                (Float64(this.outerSize()) / 2.0, Float64(this.outerSize()) / 2.0),
                start: 0.0,
                end: 359.0,
                colors: [
                    (Color(0xFF33C9FF), 0.0),
                    (Color(0xFF8833FF), 0.3),
                    (Color(0xFFFF33C9), 0.7),
                    (Color(0xFFFF8833), 1.0)
                ],
                repeating: false
            )
    }

    @Builder
    func buildStoryReadRing() {
        Column {}
            .width(this.outerSize())
            .height(this.outerSize())
            .borderRadius(this.outerBorderRadius())
            .backgroundColor(0xFFaaaaaa)
    }

    @Builder
    func buildPremiumRing() {
        Column {}
            .width(this.outerSize())
            .height(this.outerSize())
            .borderRadius(this.outerBorderRadius())
            .linearGradient(
                angle: 135.0,
                colors: [(Color(0xFFFFD700), 0.0), (Color(0xFFFF8C00), 1.0)]
            )
    }

    @Builder
    func buildGapLayer() {
        Column {}
            .width(this.avatarSize + this.ringGap() * 2)
            .height(this.avatarSize + this.ringGap() * 2)
            .borderRadius(this.innerBorderRadius() + this.ringGap())
            .backgroundColor(0xFFFFFFFF)
    }

    @Builder
    func buildSavedMessagesInner() {
        Column {
            // 资源保真修复：真实矢量图标（Avatar/SavedMessagesIcon.imageset 转 SVG）替代 emoji 字形
            Image(@r(app.media.avatar_ic_savedmsg))
                .width(this.avatarSize * 4 / 10)
                .height(this.avatarSize * 4 / 10)
                .fillColor(0xFFFFFFFF)
        }
        .width(this.avatarSize)
        .height(this.avatarSize)
        .borderRadius(this.innerBorderRadius())
        .linearGradient(
            angle: 180.0,
            colors: [(Color(0xFF2a9ef1), 0.0), (Color(0xFF72d5fd), 1.0)]
        )
        .justifyContent(FlexAlign.Center)
    }

    @Builder
    func buildRepliesInner() {
        Column {
            Text("↩")
                .fontSize(this.avatarSize * 4 / 10)
                .fontColor(0xFFFFFFFF)
        }
        .width(this.avatarSize)
        .height(this.avatarSize)
        .borderRadius(this.innerBorderRadius())
        .linearGradient(
            angle: 180.0,
            colors: [(Color(0xFF2a9ef1), 0.0), (Color(0xFF72d5fd), 1.0)]
        )
        .justifyContent(FlexAlign.Center)
    }

    @Builder
    func buildAnonymousInner() {
        Column {
            Text("?")
                .fontSize(this.avatarSize * 4 / 10)
                .fontWeight(FontWeight.Bold)
                .fontColor(0xFFFFFFFF)
        }
        .width(this.avatarSize)
        .height(this.avatarSize)
        .borderRadius(this.innerBorderRadius())
        .linearGradient(
            angle: 180.0,
            colors: [(Color(0xFF2a9ef1), 0.0), (Color(0xFF72d5fd), 1.0)]
        )
        .justifyContent(FlexAlign.Center)
    }

    @Builder
    func buildDeletedInner() {
        Column {
            Text("✕")
                .fontSize(this.avatarSize * 4 / 10)
                .fontColor(0xFFFFFFFF)
        }
        .width(this.avatarSize)
        .height(this.avatarSize)
        .borderRadius(this.innerBorderRadius())
        .linearGradient(
            angle: 180.0,
            colors: [(Color(0xFFb1b1b1), 0.0), (Color(0xFFcdcdcd), 1.0)]
        )
        .justifyContent(FlexAlign.Center)
    }

    @Builder
    func buildNormalInitialsInner() {
        Column {
            Text(if (this.letters.size > 0) { this.letters } else { this.getDoubleInitials() })
                .fontSize(this.avatarSize * 4 / 10)
                .fontWeight(FontWeight.Medium)
                .fontColor(0xFFFFFFFF)
        }
        .width(this.avatarSize)
        .height(this.avatarSize)
        .borderRadius(this.innerBorderRadius())
        // F-4（OF-6a）：纵向双色渐变替代平涂单色，对位源侧 ContentNode.draw()
        // （AvatarNode.swift:1002-1010，locations=[1.0,0.0]）：顶=色对第 2 色（light）、
        // 底=色对第 1 色（base）。angle: 180.0 的顶/底语义沿用同文件 buildSavedMessagesInner()
        // （:273-276 起，已在仓跑通）的既有写法：数组首项（fraction 0.0）在顶。
        .linearGradient(angle: 180.0, colors: [(Color(UInt32(this.derivedGradientLight())), 0.0), (Color(UInt32(this.derivedGradientBase())), 1.0)])
        .justifyContent(FlexAlign.Center)
    }

    @Builder
    func buildPhotoInner() {
        Image(this.avatarUrl)
            .width(this.avatarSize)
            .height(this.avatarSize)
            .borderRadius(this.innerBorderRadius())
            .objectFit(ImageFit.Cover)
            .opacity(this.imageOpacity)
            .animation(AnimateParam(duration: 250))
            .onComplete({ _msg: ImageLoadResult =>
                this.imageOpacity = 1.0
            })
            .onError({ _err: ImageError =>
                Hilog.info(0, "CjTelegram", "[AVT] onError name=${this.displayName}")
                this.imageLoadFailed = true
            })
    }

    @Builder
    func buildAvatarCore() {
        if (this.shouldShowImage()) {
            this.buildPhotoInner()
        } else if (this.isSpecialSavedMessages()) {
            this.buildSavedMessagesInner()
        } else if (this.isSpecialReplies()) {
            this.buildRepliesInner()
        } else if (this.isSpecialAnonymous()) {
            this.buildAnonymousInner()
        } else if (this.isSpecialDeleted()) {
            this.buildDeletedInner()
        } else {
            this.buildNormalInitialsInner()
        }
    }

    func build() {
        Stack(alignContent: Alignment.Center) {
            if (this.isStoryUnread()) {
                this.buildStoryUnreadRing()
            } else if (this.isStoryRead()) {
                this.buildStoryReadRing()
            } else if (this.isPremiumRing()) {
                this.buildPremiumRing()
            }

            if (this.hasRing()) {
                this.buildGapLayer()
            }

            Stack(alignContent: Alignment.BottomEnd) {
                this.buildAvatarCore()

                if (this.showOnlineIndicator && this.isOnline) {
                    Column {}
                        .width(this.avatarSize * 26 / 100)
                        .height(this.avatarSize * 26 / 100)
                        .borderRadius(this.avatarSize * 13 / 100)
                        .backgroundColor(0xFF4CD964)
                        .border(width: 2, color: 0xFFFFFFFF)
                }
            }
            .width(this.avatarSize)
            .height(this.avatarSize)
        }
        .width(if (this.hasRing()) { this.outerSize() } else { this.avatarSize })
        .height(if (this.hasRing()) { this.outerSize() } else { this.avatarSize })
    }
}
