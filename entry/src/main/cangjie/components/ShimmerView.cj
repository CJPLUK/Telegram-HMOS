package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog

/**
 * ShimmerView — 骨架屏微光占位（skeleton shimmer loading block）
 *
 * 对应 iOS Telegram-iOS submodules/ShimmerEffect（ShimmerEffectForegroundView）：
 *   列表 / 媒体加载态先铺一块灰色圆角占位块，再叠一道从左向右横扫的高光，
 *   高光是三段式线性渐变（透明 → 半透明白 → 透明），无限循环平移划过占位块。
 *
 * 渲染方式（纯 ArkUI，无 Canvas）：
 *   - 底层：灰色圆角 Column（backgroundColor + borderRadius），即占位形状本身。
 *   - 高光：一条比占位块更宽的 Column，铺 `.linearGradient(angle: 90)` 三段高光，
 *     用 `@State highlightOffset`（Float32 vp）驱动 `.translate(x:)`，
 *     配合声明式 `.animation(AnimateParam(iterations: -1, playMode: Normal))`
 *     做无限循环横扫（左 → 右，到头瞬回重来）。
 *   - 外层 Stack `.clip(true)` 把高光裁进占位块的圆角矩形内，扫出框外的部分不可见。
 *
 * 动画 API 实证（cangjie-kb / cj-animation-animation）：
 *   AnimateParam(duration, curve, iterations: -1, playMode: PlayMode.Normal)
 *   —— iterations=-1 表示无限循环；声明式 `.animation()` 绑在可动画属性 `.translate` 上，
 *   `@State` 在 aboutToAppear 中从起点改到终点即触发首段动画，之后由 iterations 续跑。
 *
 * 用法：
 *   if (loading) {
 *       ShimmerView(width: 200.0, height: 16.0, cornerRadius: 4.0)
 *   } else {
 *       // 真内容
 *   }
 *
 * 关闭动画（仅显示静态灰块）：
 *   ShimmerView(width: 200.0, height: 16.0, enabled: false)
 *
 * 常见骨架行（头像 + 两行文字占位）见同文件 SkeletonRow。
 *
 * S-64: aboutToAppear 必须 public override func ... : Unit
 * @Component 基本类型参数用普通 var（非 @Prop）——见 CodeInputViewComponent / UndoToast 约定。
 */
@Component
public class ShimmerView {
    // ==================== 参数（plain var，命名参数传入）====================

    // 占位块宽度（vp）
    public var width: Float64 = 120.0

    // 占位块高度（vp）
    public var height: Float64 = 16.0

    // 圆角半径（vp）
    public var cornerRadius: Float64 = 4.0

    // 占位块底色（灰）
    public var baseColor: Int64 = 0xFFE0E0E0

    // 高光峰值颜色（半透明白）
    public var highlightColor: Int64 = 0x80FFFFFF

    // 单次横扫时长（毫秒）
    public var durationMs: Int64 = 1200

    // 是否启用扫光动画；false 时只显示静态灰块
    public var enabled: Bool = true

    // ==================== 动画状态 ====================

    // 高光带相对占位块的水平偏移（vp）；从 -bandWidth 扫到 width
    @State var highlightOffset: Float32 = 0.0

    public override func aboutToAppear(): Unit {
        if (this.enabled) {
            // aboutToAppear 内把 offset 从起点改到终点，触发声明式 .animation 首段动画，
            // 之后由 iterations:-1 续跑无限循环。
            this.highlightOffset = this.endOffset()
        }
        Hilog.info(0, "CjTelegram",
            "[ShimmerView] aboutToAppear enabled=" + this.enabled.toString(), [])
    }

    // ==================== 几何辅助（不能在 build/@Builder 中 let）====================

    // 高光带宽度：取占位块宽度的一半，至少 48vp，扫光更自然
    private func bandWidth(): Float64 {
        let half = this.width / 2.0
        if (half < 48.0) {
            return 48.0
        }
        return half
    }

    // 横扫起点（高光带完全在占位块左侧外）
    private func startOffset(): Float32 {
        return Float32(-this.bandWidth())
    }

    // 横扫终点（高光带完全扫出占位块右侧外）
    private func endOffset(): Float32 {
        return Float32(this.width)
    }

    // 高光峰值色（ARGB），转成 Color 接受的 UInt32
    private func peakColor(): Color {
        return Color(UInt32(this.highlightColor))
    }

    // 高光两端的透明色：保留 RGB、alpha 为 0。必须走 RGB+alpha 构造器——
    // 顶字节为 0 的 UInt32 字面量会被 alphaAdapt 强制补成不透明（dev_pattern D-144）。
    private func edgeColor(): Color {
        let rgb = UInt32(this.highlightColor)
        return Color(UInt8((rgb >> 16) & 0xFF), UInt8((rgb >> 8) & 0xFF), UInt8(rgb & 0xFF), alpha: 0.0)
    }

    // ==================== UI ====================

    func build() {
        Stack(alignContent: Alignment.Start) {
            // 底层：灰色圆角占位块
            Column {}
                .width(this.width)
                .height(this.height)
                .borderRadius(this.cornerRadius)
                .backgroundColor(this.baseColor)

            // 高光带（仅 enabled 时叠加并做循环平移）
            if (this.enabled) {
                Column {}
                    .width(this.bandWidth())
                    .height(this.height)
                    .linearGradient(
                        angle: 90.0,
                        colors: [
                            (this.edgeColor(), 0.0),
                            (this.peakColor(), 0.5),
                            (this.edgeColor(), 1.0)
                        ]
                    )
                    .translate(x: Float64(this.highlightOffset))
                    .animation(
                        AnimateParam(
                            duration: Int32(this.durationMs),
                            curve: Curve.Linear,
                            iterations: -1,
                            playMode: PlayMode.Normal
                        )
                    )
            }
        }
        .width(this.width)
        .height(this.height)
        .borderRadius(this.cornerRadius)
        .clip(true)
    }
}

/**
 * SkeletonRow — 常见骨架行：圆形头像占位 + 两行文字占位条。
 *
 * 给会话列表 / 联系人列表加载态用，整行由 ShimmerView 拼成。
 *
 * 用法：
 *   if (loading) {
 *       Column {
 *           SkeletonRow()
 *           SkeletonRow()
 *           SkeletonRow()
 *       }
 *   } else {
 *       // 真列表
 *   }
 */
@Component
public class SkeletonRow {
    // 头像直径（vp）
    public var avatarSize: Float64 = 48.0

    // 行内边距（vp）
    public var rowPadding: Float64 = 12.0

    // 文字占位条颜色 / 高光（透传给 ShimmerView）
    public var baseColor: Int64 = 0xFFE0E0E0
    public var highlightColor: Int64 = 0x80FFFFFF

    // 是否启用扫光动画
    public var enabled: Bool = true

    func build() {
        Row {
            // 圆形头像占位（cornerRadius = 半径 → 圆形）
            ShimmerView(
                width: this.avatarSize,
                height: this.avatarSize,
                cornerRadius: this.avatarSize / 2.0,
                baseColor: this.baseColor,
                highlightColor: this.highlightColor,
                enabled: this.enabled
            )

            // 右侧两行文字占位条
            Column {
                ShimmerView(
                    width: 160.0,
                    height: 14.0,
                    cornerRadius: 4.0,
                    baseColor: this.baseColor,
                    highlightColor: this.highlightColor,
                    enabled: this.enabled
                )

                // 第二行外包一层 Column 承载行间距（custom @Component 调用不支持直接链 .margin）
                Column {
                    ShimmerView(
                        width: 220.0,
                        height: 12.0,
                        cornerRadius: 4.0,
                        baseColor: this.baseColor,
                        highlightColor: this.highlightColor,
                        enabled: this.enabled
                    )
                }
                .margin(top: 8)
            }
            .alignItems(HorizontalAlign.Start)
            .margin(left: 12)
            .layoutWeight(1)
        }
        .width(100.percent)
        .alignItems(VerticalAlign.Center)
        .padding(this.rowPadding)
    }
}
