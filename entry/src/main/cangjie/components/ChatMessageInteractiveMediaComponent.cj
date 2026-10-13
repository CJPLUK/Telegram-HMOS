package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    ChatMessageInteractiveMediaService,
    getChatMessageInteractiveMediaService,
    InteractiveMediaBadgeContent,
    InteractiveMediaDownloadState,
    MediaBadgeState
}

/**
 * ChatMessageInteractiveMediaComponent — 媒体角标渲染组件
 *
 * 对应 iOS submodules/ChatMessageInteractiveMediaBadge/Sources/ChatMessageInteractiveMediaBadge.swift
 *
 * 功能：
 *   - 在图片/视频缩略图上叠加半透明圆角角标
 *   - 显示时长文案（如 "0:32"）和可选文件大小（如 "2.4 MB"）
 *   - 当视频静音时显示静音图标（"🔇"）
 *   - 显示圆形下载进度（Fetching 态）或云下载图标（Remote 态）
 *   - 点击下载区域时调用 ChatMessageInteractiveMediaService.onDownloadTap()
 *   - 已读小角标（TextBadge 模式，右下角 "✓✓"）
 *   - 支持精简角标（compact）和完整角标（full）两种宽度
 *
 * 用法（在 MessageBubble 媒体缩略图叠加层中）：
 *   Stack() {
 *       Image(thumbnailPath)
 *       ChatMessageInteractiveMediaComponent(
 *           messageId: message.id,
 *           durationText: "0:32",
 *           sizeText: "2.4 MB",
 *           isMuted: false
 *       )
 *   }
 *
 * iOS 原版使用 ASDisplayNode + CoreGraphics 绘制圆角背景；
 * 鸿蒙端改为 Stack + Row + Text + Progress + ArkUI 通用属性实现等价渲染。
 */
@Component
public class ChatMessageInteractiveMediaComponent {

    /** 对应的消息 ID（用于查询 Service 状态） */
    public var messageId: Int64 = 0

    /** 时长文案，如 "0:32"（必填，空串则不显示时长行） */
    public var durationText: String = ""

    /** 文件大小文案，如 "2.4 MB"（空串则不显示大小行） */
    public var sizeText: String = ""

    /** 视频是否静音（控制静音图标显示） */
    public var isMuted: Bool = false

    /** 下载状态（由外部传入，也可通过 service 内部更新） */
    public var downloadState: InteractiveMediaDownloadState = InteractiveMediaDownloadState.Local

    /** 点击角标时额外回调（可选，默认交给 Service） */
    public var onBadgeTap: () -> Unit = { => }

    // ─── 辅助方法（不可在 build/@Builder 中使用 let）─────────────────────────

    /**
     * 判断是否为精简角标模式（compact：只有小圆形图标，无文本）
     */
    private func isCompactMode(): Bool {
        let svc = getChatMessageInteractiveMediaService()
        return svc.isCompact(this.downloadState)
    }

    /**
     * 判断当前角标是否处于激活态（下载进度展开）
     * 激活态时角标高度扩大，显示时长在上方、大小在下方
     */
    private func isActiveMode(): Bool {
        let svc = getChatMessageInteractiveMediaService()
        return svc.isDownloading(this.downloadState) || svc.shouldShowDownloadIcon(this.downloadState)
    }

    /**
     * 获取下载进度 0.0..1.0（用于 Progress 组件）
     */
    private func getDownloadProgress(): Float64 {
        let svc = getChatMessageInteractiveMediaService()
        return svc.getDownloadProgress(this.downloadState)
    }

    /**
     * 是否显示下载圆形图标区域（Remote / CompactRemote）
     */
    private func shouldShowDownloadIcon(): Bool {
        let svc = getChatMessageInteractiveMediaService()
        return svc.shouldShowDownloadIcon(this.downloadState)
    }

    /**
     * 是否显示圆形进度（Fetching / CompactFetching）
     */
    private func shouldShowProgress(): Bool {
        let svc = getChatMessageInteractiveMediaService()
        return svc.isDownloading(this.downloadState)
    }

    /**
     * 角标背景色：半透明黑色（iOS 原版 rgba(0,0,0,0.55)）
     */
    private func badgeBgColor(): Int64 {
        return 0x8C000000
    }

    /**
     * 文字颜色：纯白
     */
    private func badgeTextColor(): Int64 {
        return 0xFFFFFFFF
    }

    /**
     * 角标高度：普通 18vp，激活态（有下载）38vp（对应 iOS active=true 时 38.0pt）
     */
    private func badgeHeight(): Int64 {
        if (this.isActiveMode()) {
            return 38
        }
        return 18
    }

    /**
     * 下载状态文案（Remote → "↓"，无进度 Fetching → "↓"）
     */
    private func downloadIconText(): String {
        return "↓"
    }

    /**
     * 从 service 读取角标内容并覆盖本地属性（允许外部 service 推送更新）
     * 返回 true 表示使用 service 内容，false 表示使用本地属性
     */
    private func serviceHasBadge(): Bool {
        let svc = getChatMessageInteractiveMediaService()
        match (svc.getBadgeContent(this.messageId)) {
            case InteractiveMediaBadgeContent.NoBadge => return false
            case _ => return true
        }
    }

    /**
     * 获取实际显示的时长文案（优先 service，fallback 本地属性）
     */
    private func getEffectiveDuration(): String {
        let svc = getChatMessageInteractiveMediaService()
        match (svc.getBadgeContent(this.messageId)) {
            case InteractiveMediaBadgeContent.MediaDownloadBadge(dur, _, _, _) => return dur
            case InteractiveMediaBadgeContent.TextBadge(text, _) => return text
            case _ => return this.durationText
        }
    }

    /**
     * 获取实际显示的大小文案（优先 service，fallback 本地属性）
     */
    private func getEffectiveSize(): String {
        let svc = getChatMessageInteractiveMediaService()
        match (svc.getBadgeContent(this.messageId)) {
            case InteractiveMediaBadgeContent.MediaDownloadBadge(_, sz, _, _) => return sz
            case _ => return this.sizeText
        }
    }

    /**
     * 获取实际静音状态（优先 service）
     */
    private func getEffectiveMuted(): Bool {
        let svc = getChatMessageInteractiveMediaService()
        match (svc.getBadgeContent(this.messageId)) {
            case InteractiveMediaBadgeContent.MediaDownloadBadge(_, _, muted, _) => return muted
            case _ => return this.isMuted
        }
    }

    /**
     * 处理角标点击（下载触发 + 外部回调）
     */
    private func handleBadgeTap(): Unit {
        let svc = getChatMessageInteractiveMediaService()
        svc.onDownloadTap(this.messageId)
        this.onBadgeTap()
    }

    // ─── build ────────────────────────────────────────────────────────────────

    func build() {
        // 精简角标：仅圆形图标，无文字
        if (this.isCompactMode()) {
            this.compactBadge()
        } else {
            this.fullBadge()
        }
    }

    /**
     * 精简角标：22x22 圆形，内含下载图标或进度环
     * 对应 iOS isCompact=true 的 20x20 mediaStatusFrame
     */
    @Builder
    func compactBadge() {
        Stack(alignContent: Alignment.Center) {
            // 半透明圆形背景
            Column() {}
                .width(22)
                .height(22)
                .borderRadius(11)
                .backgroundColor(this.badgeBgColor())

            // 下载图标或进度
            if (this.shouldShowProgress()) {
                Progress(value: this.getDownloadProgress() * 100.0, total: 100.0, progressType: ProgressType.Ring)
                    .width(16)
                    .height(16)
                    .color(0xFFFFFFFF)
                    .backgroundColor(0x40FFFFFF)
            } else {
                Text(this.downloadIconText())
                    .fontSize(12)
                    .fontColor(this.badgeTextColor())
                    .fontWeight(FontWeight.Bold)
            }
        }
        .onClick({ _e: ClickEvent => this.handleBadgeTap() })
    }

    /**
     * 完整角标：圆角胶囊，左侧可选下载进度圆形，右侧文本列
     * 对应 iOS full badge（active/inactive 两种高度）
     */
    @Builder
    func fullBadge() {
        Row() {
            // 左侧：下载状态区域（active 模式时显示 28x28 圆形进度/图标）
            if (this.isActiveMode()) {
                Stack(alignContent: Alignment.Center) {
                    if (this.shouldShowProgress()) {
                        Progress(value: this.getDownloadProgress() * 100.0, total: 100.0, progressType: ProgressType.Ring)
                            .width(24)
                            .height(24)
                            .color(0xFFFFFFFF)
                            .backgroundColor(0x40FFFFFF)
                    } else {
                        // 云下载图标
                        Text(this.downloadIconText())
                            .fontSize(14)
                            .fontColor(this.badgeTextColor())
                            .fontWeight(FontWeight.Bold)
                    }
                }
                .width(34)
                .height(34)
            }

            // 右侧：时长 + 大小 + 可选静音图标
            Column() {
                // 时长行
                if (this.getEffectiveDuration().size > 0) {
                    Row() {
                        Text(this.getEffectiveDuration())
                            .fontSize(11)
                            .fontColor(this.badgeTextColor())
                            .fontWeight(FontWeight.Normal)

                        // 静音图标（仅视频角标）
                        if (this.getEffectiveMuted()) {
                            Text("🔇")
                                .fontSize(9)
                                .fontColor(this.badgeTextColor())
                                .margin(left: 3)
                        }
                    }
                    .alignItems(VerticalAlign.Center)
                }

                // 大小行（active 时才显示，对应 iOS sizeFrame.y active ? 19.0 : 2.0）
                if (this.isActiveMode() && this.getEffectiveSize().size > 0) {
                    Text(this.getEffectiveSize())
                        .fontSize(11)
                        .fontColor(this.badgeTextColor())
                        .fontWeight(FontWeight.Normal)
                        .margin(top: 2)
                }
            }
            .alignItems(HorizontalAlign.Start)
            .padding(right: 4)
        }
        .alignItems(VerticalAlign.Center)
        .padding(left: 6, right: 6, top: 2, bottom: 2)
        .height(this.badgeHeight())
        .borderRadius(9)
        .backgroundColor(this.badgeBgColor())
        .onClick({ _e: ClickEvent => this.handleBadgeTap() })
    }
}
