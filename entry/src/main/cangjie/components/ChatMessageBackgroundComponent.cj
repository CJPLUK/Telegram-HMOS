package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.services.{
    ChatMessageBgType,
    ChatMessageMergeType,
    TailSize,
    BubbleRadii,
    BubbleColors,
    getChatMessageBackgroundService
}

/**
 * ChatMessageBackgroundComponent — 消息气泡背景渲染组件
 *
 * 对应 iOS ChatMessageBackground（ASDisplayNode 子类）的 ArkUI 等价实现。
 *
 * 功能：
 * - 按 ChatMessageBgType (incoming / outgoing / none) 渲染气泡背景
 * - 根据 ChatMessageMergeType 自适应调整四角圆角半径（模拟合并态收缩）
 * - 绘制消息尾巴（Path SVG 三角形，MergeNone / MergeBottom 时可见）
 * - 支持高亮态（长按选中）和壁纸模式（有描边）
 *
 * iOS 原版使用预烘焙图片实现尾巴形状（graphics.chatMessageBackgroundIncomingImage 等）；
 * 鸿蒙端改为 Path SVG 路径绘制，无 MTProto 依赖（标记 N/A）。
 *
 * 用法：
 *   ChatMessageBackgroundComponent(
 *       bgType: ChatMessageBgType.BgOutgoing(ChatMessageMergeType.MergeNone),
 *       isHighlighted: false,
 *       hasWallpaper: false
 *   )
 */
@Component
public class ChatMessageBackgroundComponent {
    /** 气泡背景类型（incoming/outgoing/none + 合并态） */
    public var bgType: ChatMessageBgType = ChatMessageBgType.BgNone
    /** 是否高亮（长按选中态） */
    public var isHighlighted: Bool = false
    /** 是否存在壁纸（影响描边是否显示） */
    public var hasWallpaper: Bool = false

    // ==================== 辅助方法（不可在 build/@Builder 中使用 let）====================

    private func isNone(): Bool {
        match (this.bgType) {
            case ChatMessageBgType.BgNone => return true
            case _ => return false
        }
    }

    private func isIncoming(): Bool {
        match (this.bgType) {
            case ChatMessageBgType.BgIncoming(_) => return true
            case _ => return false
        }
    }

    private func getColors(): BubbleColors {
        return getChatMessageBackgroundService().getBubbleColors(
            this.bgType,
            this.isHighlighted,
            this.hasWallpaper
        )
    }

    private func getRadii(): BubbleRadii {
        return getChatMessageBackgroundService().getBubbleRadii(this.bgType)
    }

    private func getFillColor(): UInt32 {
        return this.getColors().fillColor
    }

    private func getStrokeColor(): UInt32 {
        return this.getColors().strokeColor
    }

    private func getTopLeftRadius(): Int64 {
        return this.getRadii().topLeft
    }

    private func getTopRightRadius(): Int64 {
        return this.getRadii().topRight
    }

    private func getBottomLeftRadius(): Int64 {
        return this.getRadii().bottomLeft
    }

    private func getBottomRightRadius(): Int64 {
        return this.getRadii().bottomRight
    }

    private func hasTail(): Bool {
        return getChatMessageBackgroundService().shouldShowTail(this.bgType)
    }

    private func tailWidth(): Int64 {
        return getChatMessageBackgroundService().getTailSize().tailWidth
    }

    private func tailHeight(): Int64 {
        return getChatMessageBackgroundService().getTailSize().tailHeight
    }

    private func hasStroke(): Bool {
        return this.getStrokeColor() != 0x00000000
    }

    /**
     * 生成 SVG Path commands 字符串（尾巴三角形）。
     * incoming（左侧尾巴）：右上→右下→左下 → 闭合
     * outgoing（右侧尾巴）：左上→左下→右下 → 闭合
     */
    private func tailPathCommands(): String {
        let w = this.tailWidth()
        let h = this.tailHeight()
        if (this.isIncoming()) {
            return "M ${w} 0 L ${w} ${h} L 0 ${h} Z"
        } else {
            return "M 0 0 L 0 ${h} L ${w} ${h} Z"
        }
    }

    // ==================== build ====================

    public func build() {
        Stack(alignContent: Alignment.BottomStart) {
            if (!this.isNone()) {
                // ---- 主气泡体：圆角矩形背景 ----
                Column {}
                    .width(100.percent)
                    .height(100.percent)
                    .backgroundColor(this.getFillColor())
                    .borderRadius(
                        topLeft: this.getTopLeftRadius(),
                        topRight: this.getTopRightRadius(),
                        bottomLeft: this.getBottomLeftRadius(),
                        bottomRight: this.getBottomRightRadius()
                    )

                // ---- 描边（有壁纸时显示轮廓线）----
                if (this.hasStroke()) {
                    Column {}
                        .width(100.percent)
                        .height(100.percent)
                        .borderRadius(
                            topLeft: this.getTopLeftRadius(),
                            topRight: this.getTopRightRadius(),
                            bottomLeft: this.getBottomLeftRadius(),
                            bottomRight: this.getBottomRightRadius()
                        )
                        .border(
                            width: 1,
                            color: this.getStrokeColor()
                        )

                }

                // ---- 消息尾巴（Path SVG 三角形）----
                if (this.hasTail()) {
                    Path()
                        .width(this.tailWidth())
                        .height(this.tailHeight())
                        .commands(this.tailPathCommands())
                        .fill(this.getFillColor())
                        .offset(
                            x: if (this.isIncoming()) { -this.tailWidth() } else { 100.percent },
                            y: 0
                        )
                }
            }
        }
        .width(100.percent)
        .height(100.percent)
    }
}
