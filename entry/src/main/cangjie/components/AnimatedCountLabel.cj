package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog

/**
 * AnimatedCountLabel — 数字滚动 / 计数过渡标签（Phase P2-418）
 *
 * 对应 Telegram-iOS submodules/AnimatedCountLabelNode：
 *   未读数、"已选 N"、成员数等数字变化时，用滚动 / 翻牌过渡而非硬切。
 *   iOS 端做的是逐位 odometer 滚动；本实现做**整体数字的上滚 + 淡入过渡**
 *   （视觉上数字向上滚动并淡入新值），对齐"数字变化有动画"的功能要求，
 *   实现成本低且稳定。逐位拆位 odometer 在 ArkUI 声明式下成本高，故务实降级。
 *
 * 过渡范式（实证，对齐同目录 ShimmerView / SlotMachineAnimationComponent）：
 *   - 数字渲染为单个 Text，绑定 `@State translateY`（vp）与 `@State opacity`，
 *     两者后挂声明式 `.animation(AnimateParam(duration, curve: EaseOut))`：
 *     只要这两个可动画属性发生变化，框架自动补间（cangjie-kb
 *     cj-attribute-animation-apis："animation 只要检测到其绑定的可动画属性
 *     发生变化，就会自动添加属性动画"）。
 *   - 计数变化检测：`count` 是父组件传入的普通 var（@Component 基本类型参数
 *     约定不用 @Prop/@Watch；@Watch 仅能监听 @State/@Prop/@Link，无法监听普通
 *     var——cangjie-kb cj-macro-watch）。因此在 build() 开头调用
 *     `syncIfChanged()` 比较 count 与已显示值 displayedCount，发现不同就驱动一次
 *     上滚淡入：先把 translateY 抬到 -riseDistance、opacity 压到 0（旧值"滚出"），
 *     在 launch{} 中把 displayedCount 切到新值、translateY 复位 0、opacity 回 1
 *     （新值"滚入"）。
 *   - 也提供显式 `setCount()` 方法，供命令式调用方（参考
 *     SlotMachineAnimationComponent.setState 范式）。
 *
 * 坑规避：
 *   - @State 写一律包在 launch{} 中（R-69），尤其在 build() 阶段触发的状态写，
 *     避免在渲染过程中同步改 @State 造成重入。
 *   - custom @Component 实例化后不能直接链 .margin()/.width() 等内置属性
 *     （已知坑）；调用方需外边距请外包 Column/Row。
 *   - @Component 基本类型参数用普通 var + 默认值（参考 ShimmerView /
 *     SolidRoundedButton 约定），不用 @Prop。
 *   - aboutToAppear 必须 public override func ... : Unit（S-64）。
 *   - build() 内不写 let（S-41）；几何计算走私有辅助方法。
 *
 * 用法：
 *   AnimatedCountLabel(count: unreadCount)
 *   AnimatedCountLabel(count: selectedCount, fontSize: 17.0, color: 0xFF317AFF,
 *                      fontWeight: FontWeight.Bold)
 */
@Component
public class AnimatedCountLabel {
    // ==================== 参数（命名参数传入）====================

    // 要显示的计数。用 @State @Watch：
    //   - 父组件以命名参数传入并在重渲染时更新 → @Watch[onCountChanged] 回调触发过渡；
    //   - 也可由 setCount() 命令式驱动。
    // @Watch 仅能监听 @State/@Prop/@Link 装饰的变量（cangjie-kb cj-macro-watch），
    // 普通 var 监听不到，故此处用 @State 而非普通 var。
    @State @Watch[onCountChanged] var count: Int64 = 0

    // 字号（vp）
    public var fontSize: Float64 = 15.0

    // 文字颜色（ARGB）
    public var color: Int64 = 0xFF000000

    // 字重
    public var fontWeight: FontWeight = FontWeight.Medium

    // 单次过渡时长（毫秒）
    public var durationMs: Int64 = 220

    // 是否启用过渡动画；false → 数字硬切
    public var enabled: Bool = true

    // 计数前缀 / 后缀（如 "已选 " / " 项"），随数字一起显示但不参与滚动单独处理
    public var prefix: String = ""
    public var suffix: String = ""

    // ==================== 动画状态（@State 驱动重绘 + 补间）====================

    // 当前真正渲染的计数值（过渡的"落点"）
    @State var displayedCount: Int64 = 0

    // 文本垂直偏移（vp）；旧值滚出时抬到 -riseDistance，新值滚入时复位 0
    @State var translateY: Float32 = 0.0

    // 文本透明度；旧值滚出时压到 0，新值滚入时回 1
    @State var opacity: Float64 = 1.0

    // ==================== 生命周期 ====================

    public override func aboutToAppear(): Unit {
        // 首帧直接对齐传入的 count，不放过渡
        this.displayedCount = this.count
        this.translateY = 0.0
        this.opacity = 1.0
        Hilog.info(0, "CjTelegram",
            "[AnimatedCountLabel] aboutToAppear count=" + this.count.toString(), [])
    }

    // ==================== 计数变化检测 / 过渡驱动 ====================

    // 上滚距离（vp）：随字号缩放，至少 8vp
    private func riseDistance(): Float32 {
        let d = this.fontSize * 0.8
        if (d < 8.0) {
            return 8.0
        }
        return Float32(d)
    }

    // @Watch 回调：count 变化时驱动一次过渡（父组件重渲染或 setCount 都会触发）。
    // 在 launch{} 中改 @State，避免渲染期同步重入。
    func onCountChanged(): Unit {
        if (this.count == this.displayedCount) {
            return
        }
        let newCount = this.count
        if (!this.enabled) {
            // 关闭动画：硬切
            launch {
                this.displayedCount = newCount
                this.translateY = 0.0
                this.opacity = 1.0
            }
            return
        }
        let rise = this.riseDistance()
        // 旧值上滚淡出 → 切到新值 → 新值复位淡入。
        // translateY / opacity 后挂 .animation，自动补间这两步变化。
        launch {
            this.translateY = -rise
            this.opacity = 0.0
            this.displayedCount = newCount
            this.translateY = 0.0
            this.opacity = 1.0
        }
    }

    // 命令式入口：供调用方主动设置计数（参考 SlotMachine.setState）。
    // 写 count（@State）会触发 @Watch[onCountChanged] 驱动过渡。
    public func setCount(value: Int64): Unit {
        launch { this.count = value }
    }

    // 合成显示文案：prefix + 数字 + suffix
    private func displayText(): String {
        return this.prefix + this.displayedCount.toString() + this.suffix
    }

    // ==================== UI ====================

    func build() {
        // 容器根：build 根节点须为容器组件（非自定义、非裸内容组件），
        // 把动画 Text 包进 Column，并把 translate/opacity 动画挂在容器上裁出滚动效果。
        Column {
            Text(this.displayText())
                .fontSize(this.fontSize)
                .fontColor(this.color)
                .fontWeight(this.fontWeight)
                .maxLines(1)
        }
        .clip(true)
        .translate(y: Float64(this.translateY))
        .opacity(this.opacity)
        .animation(
            AnimateParam(
                duration: Int32(this.durationMs),
                curve: Curve.EaseOut
            )
        )
    }
}

/**
 * CounterTitle — 标题 + 计数（Phase P2-418）
 *
 * 对应 Telegram-iOS submodules/CounterControllerTitleView：
 *   导航栏 / 头部标题区显示主标题，多选等场景在标题旁附带计数副标题
 *   （如 "已选 N"）。计数部分复用 AnimatedCountLabel，数字变化带上滚淡入过渡。
 *
 * 显示规则：
 *   - showCount == false → 仅显示 title。
 *   - showCount == true  → 标题下方（或右侧）显示计数行。
 *     · countLabel 非空（如 "已选"）→ "已选 N"（label + 动画数字）。
 *     · countLabel 为空            → 主标题 + "(N)" 形式（title 旁动画数字括号）。
 *
 * 布局：标题与计数纵向排布（导航栏双行标题范式），整体居中。
 *   多选模式典型用法：CounterTitle(title: "选择消息", count: n, showCount: true,
 *                                  countLabel: "已选")
 *
 * 坑规避同 AnimatedCountLabel：@Component 基本类型参数普通 var；custom
 * @Component 不直接链内置属性，需外边距外包容器。
 */
@Component
public class CounterTitle {
    // 主标题
    public var title: String = ""

    // 计数值（透传给 AnimatedCountLabel，变化带过渡）
    public var count: Int64 = 0

    // 是否显示计数副标题
    public var showCount: Bool = false

    // 计数前缀标签（如 "已选"）；空串 → 用 "(N)" 括号形式贴在标题旁
    public var countLabel: String = ""

    // 标题字号 / 颜色
    public var titleFontSize: Float64 = 17.0
    public var titleColor: Int64 = 0xFF000000

    // 计数字号 / 颜色（默认偏小、次要灰）
    public var countFontSize: Float64 = 13.0
    public var countColor: Int64 = 0xFF8E8E93

    // 计数过渡时长
    public var countDurationMs: Int64 = 220

    // 计数副标题是否带 "已选 N" 中的尾部（默认无后缀）
    public var countSuffix: String = ""

    // 计数标签与数字之间是否留空格（"已选 N" 形式时为 true）
    private func labelPrefix(): String {
        if (this.countLabel.size > 0) {
            return this.countLabel + " "
        }
        return "("
    }

    private func labelSuffix(): String {
        if (this.countLabel.size > 0) {
            return this.countSuffix
        }
        return ")"
    }

    func build() {
        Column {
            // 主标题行
            Text(this.title)
                .fontSize(this.titleFontSize)
                .fontColor(this.titleColor)
                .fontWeight(FontWeight.Medium)
                .maxLines(1)

            // 计数副标题行（仅 showCount 时显示，数字带上滚淡入过渡）
            if (this.showCount) {
                // 外包 Column 承载与主标题的行间距
                // （custom @Component 调用不支持直接链 .margin）
                Column {
                    AnimatedCountLabel(
                        count: this.count,
                        fontSize: this.countFontSize,
                        color: this.countColor,
                        fontWeight: FontWeight.Regular,
                        durationMs: this.countDurationMs,
                        prefix: this.labelPrefix(),
                        suffix: this.labelSuffix()
                    )
                }
                .margin(top: 2)
            }
        }
        .alignItems(HorizontalAlign.Center)
    }
}
