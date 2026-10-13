package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import std.time.*
import std.sync.*
import std.math.*
import std.random.Random
import std.collection.ArrayList
import ohos.resource.__GenerateResource__
import ohos.resource.AppResource
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.utils.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * TwoFactorCreatePasswordPage — RC-2 `Create Password` 屏
 * (diag-suite_settings_privacy-TC-0141.md §6.3/§6.4/§6.5,
 *  diag-suite_settings_privacy-TC-0141-round3.md §6.1/§6.2,
 *  diag-suite_settings_privacy-TC-0141-round4.md §6.1/§6.2/§6.3/§6.4 — 本轮修法)
 *
 * 对位源侧 `TwoFactorAuthDataInputScreen.swift` 的 `.password` mode：顶部 136x136
 * 捂眼猴子动画 + 标题 `Create Password` + 两个密码框（首框带眼睛切换按钮，两框共用同一个
 * `textHidden` 标志位同步遮蔽/揭示，round4 修复，见下）+
 * 主按钮 `Create Password`。文案取自
 * `Telegram/Telegram-iOS/en.lproj/Localizable.strings:5017-5020`
 * （`TwoFactorSetup.Password.Title/PlaceholderPassword/PlaceholderConfirmPassword/Action`）。
 * 布局常量取自 `TwoFactorAuthDataInputScreen.swift:1878-1984`
 * （`iconSize=136x136`、`iconSpacing=2`、标题 `Font.bold(28.0)`、
 * `titleInputSpacing=26`（`.password` mode 正文为空串，跳过 `titleSpacing+text`）、
 * `rowSpacing=20`、`buttonSideInset=48`、`buttonHeight=50`、`buttonSpacing=20`）。
 * 字段底色 `freePlainInputField.backgroundColor=0xe9e9e9`
 * （`DefaultDayPresentationTheme.swift:518-524`）。
 *
 * 密码遮蔽（round2 修复，diag round2 §6.1）：
 * `TextInput` 绑定**真值**（`passwordReal`/`confirmReal`），不挂字符白名单过滤器——round1 曾把
 * `text:` 绑到遮罩串并用一个白名单为 `[^•]` 的过滤器拦截，而遮罩串本身全是 `•`，控件永远无法
 * 保住自己的绑定值（该处方已被 round2 诊断撤回，不再采用）。遮罩改在 `Stack` 底层一个只读
 * `Text(maskOf(...))` 上做纯展示，形态与 `pages/TwoFactorAuthPage.cj:558` 附近一致。
 * `maskOf()` 保留（遮罩展示仍需要）。
 *
 * 猴子动画（round3 重写，diag round3 §6.1，撤回 round1/round2 的整段循环贴纸子组件方案）：
 * round1/round2 曾用一个直接吃 `.tgs`（rlottie 桥）的贴纸子组件整段循环播放，按 `monkeyState`
 * 切换 `if/else-if` 分支重建节点实现状态切换。round3 独立复核（相位折叠周期 + 跨 record 姿态
 * 流形距离 + hilog 退出 id 三条互证）判定：该子组件的两个构造参数
 * (`documentId`/`localPath`) 是裸 `public var`（非 `@Prop`），且 `buildMonkey()` 把全部 7 个
 * `.tgs` 状态塞进**同一个** `else if` 分支——ArkUI 按 `if` 分支序号决定"销毁重建"还是"复用"
 * （`dev_pattern.md` D-127），分支序号不变 ⇒ 节点被复用 ⇒ 裸 `var` 不重新赋值（D-125）⇒
 * 猴子终身播放"节点被创建那一刻"的那支 `.tgs`，且整支无限回绕（无"播一段停在末帧"语义，
 * 也无倒放能力）。
 *
 * 本轮改为对位源侧 `ManagedMonkeyAnimationNode` 的"帧号驱动单节点 + 转移队列"结构：
 * - 6 支 `.tgs`（Idle/Idle1/Idle2/Close/CloseAndPeek/Peek）离线逐帧渲染成 151 张 136×136
 *   PNG（`resources/rawfile/twofactor_monkey_{idle,idle1,idle2,close,closepeek,peek}_NNN.png`，
 *   诊断报告 §6.1 A 给出的帧号范围表，含 CloseAndPeek 因源侧 `endFrame` 越界文件实际帧数而
 *   clamp 到 32 的处理），与 round2 已验证可行的 `twofactor_monkey_track_018..160.png`
 *   （tracking 态，143 张）同一条管线。
 * - 唯一渲染节点是 `Image(this.monkeyFramePath)`，`monkeyFramePath` 是裸 `@State` 字段，由
 *   一个 16ms tick 的播放引擎（`trackTo`/`tickPlayback`，对位源侧 `trackTo`/`updateAnimation`）
 *   按队列里的 `MonkeyItem{seq, startFrame, endFrame}` 每 0.3s 播一段、停在末帧、
 *   `startFrame > endFrame` 时自然产生倒放（对位源侧三处倒放：`eyesClosed→idle`/
 *   `peeking→idle`/`peeking→eyesClosed`）。
 * - 转移表（`applyMonkeyTransition`）逐格对位 `ManagedMonkeyAnimationNode.swift:113-168`
 *   的 `setState()`，`monkeyState` 只保留 6 个语义值（Idle 三子态 + EyesClosed + Peeking +
 *   Tracking，删除了 round1/round2 因"整段循环"局限引入的 `PEEK_FROM_CLOSED`/
 *   `PEEK_FROM_OPEN`/`SETTLING_TO_IDLE` 三个渲染态——源侧只有单一 `.peeking`，"进场用哪支
 *   动画"由转移弧自身决定，不需要落进状态本身；回落到 idle 现在由 `(close,41,0)`/
 *   `(closepeek,32,0)` 的真倒放表达，不再需要额外的"回落过渡态"）。
 *
 * Tracking 态（round2 修复，diag round2 §6.2，round3 沿用不动）：源侧 `tracking(CGFloat)` 按
 * 「确认框文本渲染宽度 / 框宽」连续计算 `frameIndex = 18 + Int(v*(160-18))` 并续接播放
 * （`ManagedMonkeyAnimationNode.swift:87-102`）。round2 改为：`TwoFactorSetupMonkeyTracking.tgs`
 * （180 帧 rlottie 动画）离线逐帧渲染出帧 18–160 共 143 张 136×136 PNG，运行时按同一
 * `frameIndex = 18 + Int64(v*142)` 公式选取对应 PNG 并入队播放，round3 把这套机制原样接入
 * 统一播放引擎（`SEQ_TRACK` 序列，下标换算沿用 `frame - TRACKING_FRAME_LO`）。`v` 的分子
 * （文本渲染宽度）仓颉侧无逐字符测量 API，用「字符数 × 17pt 平均字宽」单一公式估算（不做分档
 * 查表），分母（确认框内容区宽度）用本页布局常量推算的固定估算值——这两处近似只影响 `v` 的
 * 精确值，不改变结构（仍是连续量→帧号的线性映射，仍随文本增长单调递增并在 [0,1] 处 clamp，
 * 对位源侧 case D1/D2）。
 *
 * 内容块垂直定位（round3 修复，diag round3 §6.2）：源侧返回控件是**透明导航栏覆盖层**
 * （`scrollNode` 铺满整个 contentArea，原点在屏幕左上角），内容块在可用区内**垂直居中**、
 * 下限为状态栏高度（`containerLayoutUpdated:1932-1943`）。round1/round2 把返回行写成内容
 * `Column` 里一个占布局流的 `.height(56)` 的 `Row`，其后内容顶端对齐，与源侧结构不符（round3
 * 判定这是与猴子渲染节点身份冻结并列的第二条独立根因，RC-R2）。本轮改为 `Stack` 覆盖层：
 * 返回行浮在最上层（无背景色，与源侧透明导航栏一致），`Scroll` 铺满 contentArea 并测得
 * `availableHeightVp`，内容块自身测得 `contentBlockHeightVp`，`contentTopOffset =
 * max(0.0, (availableHeightVp − contentBlockHeightVp) / 2.0)` 对位源侧
 * `max(statusBarHeight, floor((areaHeight − calculatedContentHeight) / 2.0))`
 * （目标侧 `Stack` 起点已在状态栏之下，下限映射过来即为 0）。
 *
 * round4 修法（diag round4，四条根因合并一批，见 §5.4 排期约束）：
 * 1. RC-R4-1（§6.1，最高优先）：round3 的离线 `.tgs→PNG` 管线（python-lottie SVG 导出 +
 *    cairosvg 光栅化）把 Lottie 的 `parent`（只应继承变换）实现成了 SVG DOM 嵌套（DOM 嵌套
 *    连带决定绘制顺序），导致 `peek`（15 张）/`closepeek`（`_024.._032` 9 张受影响，其余为
 *    手在脸外的过渡帧一并重出）里头部图层盖住了手。管线修法：对每个非预合成图层，沿其
 *    `parent` 链在目标帧把祖先变换矩阵合成进自己的矩阵、再清空 `parent`，使 SVG 构建器把
 *    所有图层当作扁平同级渲染——绘制顺序自然回落到图层数组下标的正确语义（下标 0 最后画 /
 *    最上层）。`Close.tgs` 的手在预合成图层（`comp_0`）里、不受此问题影响，管线里**不**
 *    展开预合成内部结构，只对主合成非预合成图层生效，因而无需改动、且离线像素比对验证零回归
 *    （`idle`/`idle1`/`idle2`/`close`/`track` 共 246 帧全量重渲染，与仓内既有文件逐帧比对
 *    `diff>25` 像素数全部为 0）。此条只动 `resources/rawfile/twofactor_monkey_{peek,
 *    closepeek}_*.png` 这 48 张资源本体，不动本文件任何播放引擎代码（`applyMonkeyTransition`/
 *    `tickPlayback`/`trackTo`/`framePathForSeq`/`updateMonkeyDrivenState` 均已核实选帧正确，
 *    详见诊断报告 §2.1／§4.1）。
 * 2. RC-R4-2（§6.2，F-4，撤回 round2 §6.1 第 6 条「确认框恒遮蔽」）：`textHidden`
 *    （round4 由旧的"只管首框"字段重命名而来）是源侧 `:1654 var textHidden` 的对位——一屏一份，
 *    `toggleTextHidden()`
 *    对两个密码框**全体**生效（源侧 `:1780-1783` 对 `inputNodes` 全体调用
 *    `updateTextHidden`）。round2 报告误读为「确认框恒遮蔽」（把 `:1104
 *    hideButtonNode.isHidden=confirmation` 这条"只影响眼睛按钮是否存在"的规则，错读成了
 *    "确认框遮蔽范围恒为真"），本轮已撤回、确认框底层遮罩 `Text` 现在与首框同形（按
 *    `textHidden` 决定明文/圆点）。首框仍是唯一带眼睛按钮的框（源侧 `:1104`，不变）。
 * 3. RC-R4-3（§6.3，F-5 D-4）：源侧主按钮纵坐标是
 *    `max(contentHeight+buttonSpacing, maxButtonY)`，其中 `maxButtonY` 由屏高与安全区反推、
 *    **不在内容流内**（`containerLayoutUpdated:1969-1974`）。round3 只落地了该式的第一项
 *    （`.margin(top:20)` 留在内容 `Column` 内），本轮把按钮移出内容 `Column`、作为最外层
 *    `Stack` 的兄弟节点，用 `buttonTopOffset`（`recomputeButtonTop()` 按同一条规则算出）定位；
 *    同步纠正 `contentBlockHeightVp` 的构成（去掉误留的 `.margin(bottom:40)`，补回源侧
 *    `calculatedContentHeight` 里"含按钮高度+间距"的 70），否则移出按钮会让已修复的 RC-R2
 *    内容居中重新出现偏差（诊断报告 §4.3 已指出这是同一段居中数学的两半，不可分批修）。
 *    该规则在测试设备（816vp 高）上的推导值与源设备（874vp 高，Inspector 实测 130.3）不同，
 *    详见 `recomputeButtonTop()` 函数注释与诊断报告 §3.4/§6.3——**不得写死绝对值**。
 * 4. RC-R4-4（§6.4，F-5 D-1）：首框眼睛图标右缘内缩，源侧 `:1231 rightInset=38.0` /
 *    `:1240` 按钮盒 `[width-42,width]` 居中放 20 宽图标 ⇒ 内缩 11.0；目标原为 16.0，改为
 *    `Row.padding(right:11)` + `Image.margin(left:7)`，只改首框，不动确认框（确认框未被测量、
 *    无判据支撑，不顺手扩面）。
 */

// ==================== 猴子状态机状态常量 ====================
// 对位 ManagedMonkeyAnimationNode.swift `enum ManagedMonkeyAnimationState`：
// Idle(Still/Blink/Ear) 三个可见子态 + EyesClosed + Peeking + Tracking。
// round3：删除 round1/round2 因"整段循环渲染"局限引入的 PEEK_FROM_CLOSED/PEEK_FROM_OPEN/
// SETTLING_TO_IDLE——源侧只有单一 .peeking，进场动画由转移弧决定，不落进状态本身；回落到
// idle 由真倒放表达，不需要额外过渡态（diag round3 §6.1 E）。
private let MONKEY_IDLE_STILL: Int64 = 0
private let MONKEY_IDLE_BLINK: Int64 = 1
private let MONKEY_IDLE_EAR: Int64 = 2
private let MONKEY_EYES_CLOSED: Int64 = 3
private let MONKEY_PEEKING: Int64 = 4
private let MONKEY_TRACKING: Int64 = 5

// ==================== 播放引擎序列标识（round3 新增） ====================
// 对位源侧 8 支本地 .tgs 资源里在本页仍使用的 7 支（第 8 支"回落到 idle 的定长补间"资源
// 随 SETTLING_TO_IDLE 状态一并删除，见 diag round3 §6.1 E）。
private let SEQ_IDLE: Int64 = 0
private let SEQ_IDLE1: Int64 = 1
private let SEQ_IDLE2: Int64 = 2
private let SEQ_CLOSE: Int64 = 3
private let SEQ_CLOSEPEEK: Int64 = 4
private let SEQ_PEEK: Int64 = 5
private let SEQ_TRACK: Int64 = 6

// ==================== RC-P2 tracking 帧号线性映射常量（round2，round3 沿用不动） ====================
// 对位源侧 frameIndex = 18 + Int(v*(160-18))（ManagedMonkeyAnimationNode.swift:87-102）。
private let TRACKING_FRAME_LO: Int64 = 18
private let TRACKING_FRAME_HI: Int64 = 160
private let TRACKING_FRAME_SPAN: Float64 = 142.0 // 160 - 18
// 确认框字号 17pt 下的单字符平均渲染宽度估算（仓颉侧无逐字符渲染宽度测量 API，
// diag round2 §6.2 B 明确授权「字符数 × 平均字宽」单一公式，不做分档查表）。
private let TRACKING_AVG_CHAR_WIDTH: Float64 = 9.5
// 确认框内容区宽度估算：页面宽度基准 390 - 外层 Column padding(48*2) - Row padding(16*2)
// = 262（:543-544/:584-585 的 padding 常量都是本页固定值，仅设备总宽度未知，用常见基准宽度）。
private let TRACKING_FIELD_CONTENT_WIDTH: Float64 = 262.0

// 播放引擎队列项：对位源侧 ManagedAnimationItem(source:, frames: .range(startFrame:endFrame:),
// duration: 0.3) —— 一段有界帧区间，播 0.3s，停在 endFrame（startFrame > endFrame 时天然倒放）。
public struct MonkeyItem {
    public var seq: Int64
    public var startFrame: Int64
    public var endFrame: Int64

    public init(seq!: Int64, startFrame!: Int64, endFrame!: Int64) {
        this.seq = seq
        this.startFrame = startFrame
        this.endFrame = endFrame
    }
}

@HybridComponentEntry
@Component
public class TwoFactorCreatePasswordPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var passwordReal: String = ""
    // round4（diag round4 §6.2 RC-R4-2）：本字段 round3 曾只管首框的遮蔽状态，round4
    // 重命名并纠正语义，对位源侧 :1654 `var textHidden`——一屏一份，切换时对 `inputNodes`
    // 全体生效（两个密码框都遮蔽/都揭示）。旧的"只管首框"语义正是 round2 §6.1 第 6 条误读
    // （"确认框恒遮蔽"）的载体，本轮撤回该条并连带纠正命名。
    @State var textHidden: Bool = true
    @State var confirmReal: String = ""
    @State var passwordFocused: Bool = false
    @State var confirmFocused: Bool = false
    @State var isSaving: Bool = false
    @State var errorMessage: String = ""
    @State var monkeyState: Int64 = 0

    // round3：唯一渲染节点绑定的裸 @State 字段（对位 D-125 的"正确"形态：调用点是父组件自己
    // 的裸字段引用，且 Image 是内置组件，构造参数变化即时生效）。由播放引擎逐 tick 写入。
    @State var monkeyFramePath: String = ""

    // round3：内容块垂直定位（diag round3 §6.2 RC-R2）。
    @State var availableHeightVp: Float64 = 0.0
    @State var contentBlockHeightVp: Float64 = 0.0
    @State var contentTopOffset: Float64 = 0.0

    // round4（diag round4 §6.3 RC-R4-3）：主按钮"贴底锚定"定位，对位源侧
    // containerLayoutUpdated:1969-1974。maxAvailableHeightVp 是 availableHeightVp 的历史
    // 最大值（近似源侧"无键盘时的可用高"，对位 layout.size.height 参与的那一项，不随软键盘
    // 弹出而收缩）；contentBottomVp 是第二个输入框底相对 `Scroll` 顶的位置（=
    // contentTopOffset + (contentBlockHeightVp − 70.0)，70 = buttonHeight(50)+buttonSpacing(20)，
    // 见 updateContentBlockHeight() 注释）；buttonTopOffset 是按钮实际使用的
    // `.margin(top:)` 值，由 recomputeButtonTop() 按源式算出，不得写死。
    @State var maxAvailableHeightVp: Float64 = 0.0
    @State var buttonTopOffset: Float64 = 0.0
    @State var contentBottomVp: Float64 = 0.0

    // 6 个非 tracking 猴子序列提取到沙箱后的路径数组，aboutToAppear() 内一次性同步填充
    // （形状照抄 pages/ChangePhoneIntroPage.cj extractIntroAnimation()）。首次 build() 前
    // 已就绪，不需要 @State（数组本身不随运行时变化，内容由 @State monkeyFramePath 驱动展示）。
    private var idlePaths: ArrayList<String> = ArrayList<String>()
    private var idle1Paths: ArrayList<String> = ArrayList<String>()
    private var idle2Paths: ArrayList<String> = ArrayList<String>()
    private var closePaths: ArrayList<String> = ArrayList<String>()
    private var closepeekPaths: ArrayList<String> = ArrayList<String>()
    private var peekPaths: ArrayList<String> = ArrayList<String>()
    // RC-P2（round2）：帧 18..160 共 143 张 tracking PNG 提取到沙箱后的路径，下标 0 对应帧 18
    // （framePathForSeq() 做 frameIndex -> 下标换算）。
    private var trackFramePaths: ArrayList<String> = ArrayList<String>()

    private var idleTimer: Option<Timer> = None<Timer>

    // round3：播放引擎状态（对位源侧 trackStack + state）。
    private var trackQueue: ArrayList<MonkeyItem> = ArrayList<MonkeyItem>()
    private var currentItem: Option<MonkeyItem> = None<MonkeyItem>
    private var currentFrame: Int64 = 0
    private var playStartMs: Int64 = 0
    private var playTimer: Option<Timer> = None<Timer>
    // 最近一次请求的 tracking 目标帧号（防抖，对位源侧 abs(旧-新) > ulpOfOne 才入队，case C7）。
    private var trackingFrame: Int64 = TRACKING_FRAME_LO

    public override func aboutToAppear(): Unit {
        this.extractMonkeyAnimations()
        // 对位源侧 init()：立即入队 Idle 静止帧作为首帧，避免播放引擎就绪前猴子区空白。
        this.trackTo(MonkeyItem(seq: SEQ_IDLE, startFrame: 0, endFrame: 0))
        this.armIdleTimer()
    }

    public override func aboutToDisappear(): Unit {
        this.cancelIdleTimer()
        this.cancelPlayTimer()
    }

    private func extractMonkeyAnimations(): Unit {
        match (getGlobalAbilityContext()) {
            case None => return
            case Some(ctx) =>
                let filesDir = ctx.filesDir
                let dir = filesDir + "/two_factor_monkey"
                try { FileIo.mkdir(dir) } catch (_e: Exception) {}
                this.extractSeqFrames(dir, this.idlePaths, "twofactor_monkey_idle", 0, 0)
                this.extractSeqFrames(dir, this.idle1Paths, "twofactor_monkey_idle1", 0, 29)
                this.extractSeqFrames(dir, this.idle2Paths, "twofactor_monkey_idle2", 0, 29)
                this.extractSeqFrames(dir, this.closePaths, "twofactor_monkey_close", 0, 41)
                this.extractSeqFrames(dir, this.closepeekPaths, "twofactor_monkey_closepeek", 0, 32)
                this.extractSeqFrames(dir, this.peekPaths, "twofactor_monkey_peek", 0, 14)
                this.extractTrackFrames(dir)
        }
    }

    // 通用逐帧提取：frameLo..frameHi 闭区间，文件名 "<prefix>_<NNN>.png"，下标 0 对应 frameLo。
    private func extractSeqFrames(dir: String, target: ArrayList<String>, prefix: String, frameLo: Int64, frameHi: Int64): Unit {
        var i = frameLo
        while (i <= frameHi) {
            target.add(this.extractMonkeyOne(dir, prefix + "_" + this.threeDigit(i) + ".png"))
            i += 1
        }
    }

    // RC-P2：逐帧提取 18..160 共 143 张 tracking PNG，下标 0 对应帧 18（与
    // framePathForSeq() 的换算约定一致）。
    private func extractTrackFrames(dir: String): Unit {
        var i: Int64 = TRACKING_FRAME_LO
        while (i <= TRACKING_FRAME_HI) {
            this.trackFramePaths.add(this.extractMonkeyOne(dir, "twofactor_monkey_track_" + this.threeDigit(i) + ".png"))
            i += 1
        }
    }

    // "018" 形态的 3 位零填充帧号。
    private func threeDigit(frameIndex: Int64): String {
        var digits = frameIndex.toString()
        while (digits.size < 3) {
            digits = "0" + digits
        }
        return digits
    }

    // 形状照抄 pages/ChangePhoneIntroPage.cj:118-150 extractIntroAnimation()。
    private func extractMonkeyOne(dir: String, name: String): String {
        let targetPath = dir + "/" + name
        match (readRawFileBytes(name)) {
            case None =>
                Hilog.info(0, "CjTelegram",
                    "[TwoFactorCreatePasswordPage] extractMonkeyOne: readRawFileBytes returned None for ${name}")
                return ""
            case Some(data) =>
                if (data.size == 0) { return "" }
                try {
                    let file = FileIo.open(targetPath, mode: 0o1101)
                    let _ = FileIo.write(file.fd, data)
                    FileIo.close(file)
                    return "file://" + targetPath
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram",
                        "[TwoFactorCreatePasswordPage] extractMonkeyOne: write failed for ${name}")
                    return ""
                }
        }
    }

    // ==================== 猴子播放引擎（round3 新增，对位 ManagedAnimationNode） ====================

    private func pathsForSeq(seq: Int64): ArrayList<String> {
        if (seq == SEQ_TRACK) { return this.trackFramePaths }
        if (seq == SEQ_IDLE) { return this.idlePaths }
        if (seq == SEQ_IDLE1) { return this.idle1Paths }
        if (seq == SEQ_IDLE2) { return this.idle2Paths }
        if (seq == SEQ_CLOSE) { return this.closePaths }
        if (seq == SEQ_CLOSEPEEK) { return this.closepeekPaths }
        return this.peekPaths
    }

    // ==================== 序列帧域（round5，TC-0141 S11 修复）====================
    // 「序列真实覆盖的帧号闭区间」在本文件只声明这一处：track 序列的 PNG 只离线渲染了
    // 18..160（TRACKING_FRAME_LO..HI），其余序列从 0 起。framePathForSeq() 的下标换算与
    // clampItemToSeqRange() 的入队归一化都从这里取值，不再各自散写 18 这个常量。
    private func seqFirstFrame(seq: Int64): Int64 {
        if (seq == SEQ_TRACK) { return TRACKING_FRAME_LO }
        return 0
    }

    // 序列真实覆盖的末帧号；该序列一帧都没提取到（资源缺失）时返回 seqFirstFrame - 1，
    // 即空帧域，调用方据 hi < lo 判定"无帧可放"，与"帧号越界"区分开。
    private func seqLastFrame(seq: Int64): Int64 {
        return this.seqFirstFrame(seq) + this.pathsForSeq(seq).size - 1
    }

    // frame 是序列内的绝对帧号（起点见 seqFirstFrame）。越界一律返回空串（Image 分支不渲染，
    // 与 round2 既有 tracking 兜底一致，不新增兜底动画）——但经 trackTo() 入队的播放段现已
    // 被夹进帧域，正常播放路径不会再命中这个分支；它只剩"该序列一帧都没提取到"这一种成因。
    private func framePathForSeq(seq: Int64, frame: Int64): String {
        let arr = this.pathsForSeq(seq)
        let idx = frame - this.seqFirstFrame(seq)
        if (idx < 0 || idx >= arr.size) { return "" }
        return arr[idx]
    }

    // 把一个帧号夹进 [lo,hi]。
    private func clampFrame(frame: Int64, lo: Int64, hi: Int64): Int64 {
        if (frame < lo) { return lo }
        if (frame > hi) { return hi }
        return frame
    }

    // round5（TC-0141 S11）：把入队项的起止帧夹进该序列真实覆盖的帧域。
    // 播放引擎在 [startFrame,endFrame] 之间线性插值，两端都在域内 ⇒ 插出的每一帧都在域内
    // ⇒ framePathForSeq() 不可能对播放中的帧返回空串、猴子区不可能空白。
    // 源侧 enqueueTracking()/enqueueClearTracking() 里的字面值 0 表示"tracking 序列的开头"，
    // 本仓该序列的开头是帧 18；这个换算在此统一完成，而不是逐调用点手工写 18
    // （逐点手写正是 S11 的成因：applyMonkeyTransition() 的 prevState==TRACKING 分支 :612
    // 换算了，enterTrackingFresh() :634 漏了）。
    // 帧域为空（该序列一帧都没提取到）时原样放行——那是资源缺失，不是帧号越界。
    private func clampItemToSeqRange(item: MonkeyItem): MonkeyItem {
        let lo = this.seqFirstFrame(item.seq)
        let hi = this.seqLastFrame(item.seq)
        if (hi < lo) { return item }
        return MonkeyItem(
            seq: item.seq,
            startFrame: this.clampFrame(item.startFrame, lo, hi),
            endFrame: this.clampFrame(item.endFrame, lo, hi)
        )
    }

    // 入队一段播放；若当前空闲立即开播。对位源侧 trackTo(item:)。
    // 入队是所有播放段进入引擎的唯一口子，帧域归一化放在这里一次做完（见
    // clampItemToSeqRange 注释），此后 startNextInQueue()/tickPlayback() 拿到的帧号必在域内。
    private func trackTo(item: MonkeyItem): Unit {
        this.trackQueue.add(this.clampItemToSeqRange(item))
        if (this.currentItem.isNone()) {
            this.startNextInQueue()
        }
    }

    // 队列里滤掉所有 track 序列的残留项——对位源侧 enqueueTracking() 的"非续接"分支
    // （trackStack = trackStack.filter { $0.source != Tracking }）。
    private func removeQueuedTrackItems(): Unit {
        let filtered = ArrayList<MonkeyItem>()
        var i: Int64 = 0
        while (i < this.trackQueue.size) {
            let item = this.trackQueue[i]
            if (item.seq != SEQ_TRACK) {
                filtered.add(item)
            }
            i += 1
        }
        this.trackQueue = filtered
    }

    private func startNextInQueue(): Unit {
        if (this.trackQueue.size == 0) {
            this.currentItem = None<MonkeyItem>
            this.cancelPlayTimer()
            return
        }
        let item = this.trackQueue[0]
        this.trackQueue.remove(0..1)
        this.currentItem = Some(item)
        this.currentFrame = item.startFrame
        this.playStartMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let path = this.framePathForSeq(item.seq, item.startFrame)
        if (path != this.monkeyFramePath) {
            this.monkeyFramePath = path
        }
        this.cancelPlayTimer()
        this.playTimer = Some(Timer.repeat(Duration.millisecond * 16, Duration.millisecond * 16, {
            =>
            launch {
                this.tickPlayback()
            }
        }, style: CatchupStyle.Skip))
    }

    private func cancelPlayTimer(): Unit {
        match (this.playTimer) {
            case Some(t) => t.cancel()
            case None => ()
        }
        this.playTimer = None<Timer>
    }

    // 每 16ms 一 tick：按 0.3s 固定时长在 [startFrame,endFrame] 间线性插值出当前帧号
    // （startFrame > endFrame 时该式自然给出倒放）。到达末帧后停表、停在末帧（不回绕），
    // 续播队列下一项；队列清空且仍是 idle 大类则重新武装 idle 定时器（对位源侧
    // advanceState() 的 trackStack.isEmpty 条件）。
    private func tickPlayback(): Unit {
        match (this.currentItem) {
            case None => this.cancelPlayTimer()
            case Some(item) =>
                let now = DateTime.now().toUnixTimeStamp().toMilliseconds()
                var t = Float64(now - this.playStartMs) / 300.0
                if (t < 0.0) { t = 0.0 }
                if (t > 1.0) { t = 1.0 }
                let frame = item.startFrame + Int64(Float64(item.endFrame - item.startFrame) * t)
                this.currentFrame = frame
                let path = this.framePathForSeq(item.seq, frame)
                if (path != this.monkeyFramePath) {
                    this.monkeyFramePath = path
                }
                if (t >= 1.0) {
                    this.currentFrame = item.endFrame
                    this.cancelPlayTimer()
                    if (this.trackQueue.size > 0) {
                        this.startNextInQueue()
                    } else {
                        this.currentItem = None<MonkeyItem>
                        if (this.isIdleCategory(this.monkeyState)) {
                            this.armIdleTimer()
                        }
                    }
                }
        }
    }

    // ==================== 猴子状态机：定时器 ====================

    private func isIdleCategory(state: Int64): Bool {
        return state == MONKEY_IDLE_STILL || state == MONKEY_IDLE_BLINK || state == MONKEY_IDLE_EAR
    }

    private func cancelIdleTimer(): Unit {
        match (this.idleTimer) {
            case Some(t) => t.cancel()
            case None => ()
        }
        this.idleTimer = None<Timer>
    }

    // 入队 idle 子态对应的播放段，对位源侧 enqueueIdle()。Idle1/Idle2 源侧写 endFrame=30，
    // 但两支 .tgs 各自只有 30 帧（合法下标 0..29），round3 §6.1 A 已按此 clamp 提取 PNG，
    // 这里同步取 29。
    private func enqueueIdleVariant(idleVariant: Int64): Unit {
        if (idleVariant == MONKEY_IDLE_BLINK) {
            this.trackTo(MonkeyItem(seq: SEQ_IDLE1, startFrame: 0, endFrame: 29))
        } else if (idleVariant == MONKEY_IDLE_EAR) {
            this.trackTo(MonkeyItem(seq: SEQ_IDLE2, startFrame: 0, endFrame: 29))
        } else {
            this.trackTo(MonkeyItem(seq: SEQ_IDLE, startFrame: 0, endFrame: 0))
        }
    }

    // 对位源侧 startIdleTimer()：一次性定时器，超时 [1.0,1.5)s，触发时仅当当前仍是
    // Idle 大类才从 {Still,Blink,Ear} 随机取一个并播放——即便随机到与当前相同的子态也照常
    // 重新入队播放（源侧 setState 无条件执行，不做"值未变则跳过"的短路）。重新武装的时机
    // 已改为播放队列清空时（tickPlayback()），本函数不再递归重新武装自己。
    private func armIdleTimer(): Unit {
        this.cancelIdleTimer()
        let ms: Int64 = 1000 + Int64(Random().nextInt32(500))
        let t = Timer.once(Duration.millisecond * ms, {
            =>
            launch {
                if (this.isIdleCategory(this.monkeyState)) {
                    let picked = Int64(Random().nextInt32(3))
                    this.monkeyState = picked
                    this.enqueueIdleVariant(picked)
                }
            }
        })
        this.idleTimer = Some(t)
    }

    // ==================== 猴子状态机：驱动 ====================
    // 对位源侧 TwoFactorAuthDataInputScreen.swift:1654-1700 updateAnimations()
    // 的 .password 分支决策树：确认框聚焦⇒Tracking；首框聚焦+无文本⇒Idle(Still)；
    // 首框聚焦+有文本+遮蔽中⇒EyesClosed；首框聚焦+有文本+已揭示⇒Peeking；
    // 两框都不聚焦⇒Idle(Still)。每次聚焦变化/文本变化/遮蔽切换都要重算一次
    // （对位源侧 focusUpdated 与 updated 双回调都会调用 updateAnimations()）。
    private func updateMonkeyDrivenState(): Unit {
        if (this.confirmFocused) {
            this.cancelIdleTimer()
            if (this.monkeyState != MONKEY_TRACKING) {
                this.transitionTo(MONKEY_TRACKING)
            } else {
                this.updateTrackingFrame(this.trackingFrameIndex())
            }
            return
        }
        if (this.passwordFocused) {
            if (this.passwordReal.size == 0) {
                this.driveToIdleIfNeeded()
                return
            }
            this.cancelIdleTimer()
            if (this.textHidden) {
                this.transitionTo(MONKEY_EYES_CLOSED)
            } else {
                this.transitionTo(MONKEY_PEEKING)
            }
            return
        }
        this.driveToIdleIfNeeded()
    }

    private func driveToIdleIfNeeded(): Unit {
        if (this.isIdleCategory(this.monkeyState)) { return }
        this.transitionTo(MONKEY_IDLE_STILL)
    }

    // 状态迁移的唯一入口：写 monkeyState 前记下 prevState，写完按 (prevState, newState)
    // 转移表入队对应播放段。相同值不触发（对位源侧 case .eyesClosed/.peeking: break，
    // case C8）；idle 自循环走 armIdleTimer() 的独立路径，不经过这里（见其函数注释）。
    private func transitionTo(newState: Int64): Unit {
        let prevState = this.monkeyState
        if (prevState == newState) { return }
        this.monkeyState = newState
        this.applyMonkeyTransition(prevState, newState)
    }

    // 转移表（把源 setState() 的 4×4 switch 逐格誊过来，diag round3 §6.1 D）。
    private func applyMonkeyTransition(prevState: Int64, newState: Int64): Unit {
        if (this.isIdleCategory(prevState)) {
            if (this.isIdleCategory(newState)) {
                this.enqueueIdleVariant(newState)
            } else if (newState == MONKEY_EYES_CLOSED) {
                this.trackTo(MonkeyItem(seq: SEQ_CLOSE, startFrame: 0, endFrame: 41))
            } else if (newState == MONKEY_PEEKING) {
                this.trackTo(MonkeyItem(seq: SEQ_CLOSEPEEK, startFrame: 0, endFrame: 32))
            } else if (newState == MONKEY_TRACKING) {
                this.enterTrackingFresh()
            }
            return
        }
        if (prevState == MONKEY_EYES_CLOSED) {
            if (this.isIdleCategory(newState)) {
                this.trackTo(MonkeyItem(seq: SEQ_CLOSE, startFrame: 41, endFrame: 0))
                this.enqueueIdleVariant(newState)
            } else if (newState == MONKEY_PEEKING) {
                this.trackTo(MonkeyItem(seq: SEQ_PEEK, startFrame: 0, endFrame: 14))
            } else if (newState == MONKEY_TRACKING) {
                this.trackTo(MonkeyItem(seq: SEQ_CLOSE, startFrame: 41, endFrame: 0))
                this.enterTrackingFresh()
            }
            return
        }
        if (prevState == MONKEY_PEEKING) {
            if (this.isIdleCategory(newState)) {
                this.trackTo(MonkeyItem(seq: SEQ_CLOSEPEEK, startFrame: 32, endFrame: 0))
                this.enqueueIdleVariant(newState)
            } else if (newState == MONKEY_EYES_CLOSED) {
                this.trackTo(MonkeyItem(seq: SEQ_PEEK, startFrame: 14, endFrame: 0))
            } else if (newState == MONKEY_TRACKING) {
                this.trackTo(MonkeyItem(seq: SEQ_CLOSEPEEK, startFrame: 32, endFrame: 0))
                this.enterTrackingFresh()
            }
            return
        }
        if (prevState == MONKEY_TRACKING) {
            // 对位源侧 enqueueClearTracking()：续接播到本仓 track 序列的起点帧 18
            // （源侧写 0，本仓 track 序列只覆盖 [18,160]，故写 18，diag round3 §6.1 D footnote）。
            this.trackTo(MonkeyItem(seq: SEQ_TRACK, startFrame: this.currentFrame, endFrame: TRACKING_FRAME_LO))
            if (this.isIdleCategory(newState)) {
                // 源侧 tracking→idle 额外入队一帧 Idle 静止帧作为落地过渡，再入队真正的目标子态
                // （ManagedMonkeyAnimationNode.swift:154-156）。
                this.trackTo(MonkeyItem(seq: SEQ_IDLE, startFrame: 0, endFrame: 0))
                this.enqueueIdleVariant(newState)
            } else if (newState == MONKEY_EYES_CLOSED) {
                this.trackTo(MonkeyItem(seq: SEQ_CLOSE, startFrame: 0, endFrame: 41))
            } else if (newState == MONKEY_PEEKING) {
                this.trackTo(MonkeyItem(seq: SEQ_CLOSEPEEK, startFrame: 0, endFrame: 32))
            }
        }
    }

    // 从非 tracking 状态首次进入 tracking：滤掉队列里残留的 track 项，入队全新一段
    // （对位源侧 enqueueTracking() 的"非续接"分支）。
    // startFrame 保留源侧字面值 0（语义是"从 tracking 序列的开头起播"）；本仓该序列的开头
    // 是帧 18，换算由 trackTo() 的帧域归一化统一完成，不在此处手工写 18（TC-0141 S11）。
    private func enterTrackingFresh(): Unit {
        this.removeQueuedTrackItems()
        let target = this.trackingFrameIndex()
        this.trackingFrame = target
        this.trackTo(MonkeyItem(seq: SEQ_TRACK, startFrame: 0, endFrame: target))
    }

    // 已在 tracking 态时文本/焦点变化触发的续接（对位源侧 enqueueTracking() 的"续接"分支）：
    // 仅当目标帧号变化才入队，从当前实际播放帧连续过渡（case C7 防抖）。
    private func updateTrackingFrame(targetFrame: Int64): Unit {
        if (targetFrame == this.trackingFrame) { return }
        this.trackTo(MonkeyItem(seq: SEQ_TRACK, startFrame: this.currentFrame, endFrame: targetFrame))
        this.trackingFrame = targetFrame
    }

    // ==================== RC-P2：tracking 线性映射（round2，round3 沿用不动） ====================
    // 对位源侧 tracking(CGFloat) 的 v = clamp(确认框文本渲染宽度 / 框宽, 0, 1)
    // （ManagedMonkeyAnimationNode.swift:87-102）。见文件头注释与 TRACKING_* 常量注释
    // 关于分子/分母估算方式的说明。
    private func trackingOffset(): Float64 {
        let charCount = Float64(this.confirmReal.toRuneArray().size)
        let textWidth = charCount * TRACKING_AVG_CHAR_WIDTH
        var v = textWidth / TRACKING_FIELD_CONTENT_WIDTH
        if (v < 0.0) { v = 0.0 }
        if (v > 1.0) { v = 1.0 }
        return v
    }

    // frameIndex = 18 + Int(v*(160-18))，对位源侧公式，clamp 上界随 trackingOffset() 保证。
    private func trackingFrameIndex(): Int64 {
        return TRACKING_FRAME_LO + Int64(this.trackingOffset() * TRACKING_FRAME_SPAN)
    }

    // ==================== 密码遮蔽（RC-P1 round2 修复，diag round2 §6.1） ====================
    // TextInput 绑真值，不挂字符过滤器；maskOf() 只用于底层只读 Text 的展示遮罩。

    private func maskOf(s: String): String {
        var result = ""
        var i: Int64 = 0
        let count = s.toRuneArray().size
        while (i < count) {
            result += "•"
            i += 1
        }
        return result
    }

    // round4：重命名自 togglePasswordHidden()，对位源侧 toggleTextHidden()——语义是"切换整屏
    // 的遮蔽标志位"，不是"只切首框"（diag round4 §6.2）。
    private func toggleTextHidden(): Unit {
        this.textHidden = !this.textHidden
        this.updateMonkeyDrivenState()
    }

    // 对位 TwoFactorDataInputTextNode.hideButtonNode 图形：generateTextHiddenImage
    // 底图 PasswordSetup/TextHidden 经 PyMuPDF 矢量提取 + 手工加斜杠合成
    // （resources/base/media/twofactor_ic_text_{hidden,visible}.svg，二者共用同一
    // controlColor=0xbcbcc0，与 DefaultDayPresentationTheme.swift:524 一致）。
    private func passwordEyeIcon(): AppResource {
        if (this.textHidden) { return @r(app.media.twofactor_ic_text_hidden) }
        return @r(app.media.twofactor_ic_text_visible)
    }

    // RC-P3（diag round2 §6.3）：返回控件图形，与 app/TelegramNavBar.cj:194 的
    // .legacy 分支同一资源。`@r(...)` 必须包在普通方法里，不能直接写在 build() 的
    // Image(...) 实参位（同一约束见 TelegramNavBar.cj:82-87 注释）；`navBackArrowLegacyRes()`
    // 是 app 包的包内可见函数（非 public），跨包不可访问，故本页独立持有一份同值访问器。
    private func navBackArrowIcon(): AppResource {
        return @r(app.media.nav_back_arrow_legacy)
    }

    // ==================== RC-R2：内容块垂直定位（round3，diag round3 §6.2） ====================
    // 对位源侧 containerLayoutUpdated 的 contentVerticalOrigin =
    // max(statusBarHeight, floor((areaHeight − calculatedContentHeight)/2))；目标侧 Stack
    // 起点已在状态栏之下，下限映射过来即为 0（见文件头注释）。

    private func updateAvailableHeight(area: Area): Unit {
        let h = area.height.value
        // round4（RC-R4-3）：maxAvailableHeightVp 是历史最大值（近似"无键盘时"的可用高，
        // 对位源式里不随键盘变化的 layout.size.height 那一项），不受下面 0.5vp 抖动闸门约束——
        // 软键盘弹出会使 h 变小，不应把 maxAvailableHeightVp 拉低。
        if (h > this.maxAvailableHeightVp) { this.maxAvailableHeightVp = h }
        if (abs(h - this.availableHeightVp) > 0.5) {
            this.availableHeightVp = h
            this.recomputeContentTopOffset()
        }
        this.recomputeButtonTop()
    }

    private func updateContentBlockHeight(area: Area): Unit {
        // round4（RC-R4-3，diag round4 §6.3 第 5 项）：主按钮已移出内容 Column（见 build()），
        // area 实测高不再含按钮本体；此处补回源侧 calculatedContentHeight 里"含按钮高度+间距"
        // 的 70.0（= buttonHeight 50 + buttonSpacing 20，TwoFactorAuthDataInputScreen.swift
        // :1915-1924），否则内容居中会因为少算这 70 而整体下移。
        let h = area.height.value
        if (abs((h + 70.0) - this.contentBlockHeightVp) > 0.5) {
            this.contentBlockHeightVp = h + 70.0
            this.recomputeContentTopOffset()
        }
        this.recomputeButtonTop()
    }

    private func recomputeContentTopOffset(): Unit {
        var offset = (this.availableHeightVp - this.contentBlockHeightVp) / 2.0
        if (offset < 0.0) { offset = 0.0 }
        if (abs(offset - this.contentTopOffset) > 0.5) {
            this.contentTopOffset = offset
        }
        this.recomputeButtonTop()
    }

    // round4（diag round4 §6.3 RC-R4-3）：对位源侧 containerLayoutUpdated:1969-1974
    // ```
    // let buttonBottomInset = layout.intrinsicInsets.bottom + 74.0
    // let maxButtonY = min(areaHeight - buttonSpacing,
    //                      layout.size.height - buttonBottomInset) - buttonHeight * 2.0
    // buttonFrame.origin.y = max(contentHeight + buttonSpacing, maxButtonY)
    // ```
    // 坐标换算（已换算完毕，勿再自行换算一次）：目标侧 `Scroll` 原点已经在安全区上边界之下
    // （最外层 Stack 已 `.padding(top:getSafeAreaTop(), bottom:getSafeAreaBottom())`，M4 消费点，
    // 见文件头「同文件禁触区」）。安全区下边界换到 `Scroll` 局部坐标就等于
    // maxAvailableHeightVp——因此源式里的 `layout.size.height − (intrinsicInsets.bottom+74)`
    // 在局部坐标里就是 `maxAvailableHeightVp − 74.0`，不需要也不得再加一次
    // `getSafeAreaBottom()`；同理 `areaHeight − buttonSpacing` 就是 `availableHeightVp − 20.0`。
    // 本机（816vp 高设备）预期值见诊断报告 §6.3 表：contentBottomVp≈497.9、
    // anchored=675.0、buttonTopOffset≈575.0（间距≈77vp）——这是式子的产物，不是常量，
    // **不得写死绝对值**。
    private func recomputeButtonTop(): Unit {
        this.contentBottomVp = this.contentTopOffset + (this.contentBlockHeightVp - 70.0)
        var anchored = this.maxAvailableHeightVp - 74.0
        let byArea = this.availableHeightVp - 20.0
        if (byArea < anchored) { anchored = byArea }
        var top = anchored - 100.0
        let byContent = this.contentBottomVp + 20.0
        if (byContent > top) { top = byContent }
        if (abs(top - this.buttonTopOffset) > 0.5) {
            this.buttonTopOffset = top
        }
    }

    // ==================== 提交 ====================
    // 对位源侧按钮回调 push 下一步（hint/邮箱屏，不在本轮范围，diag §6.3）；本页只调用
    // 现有 saveNewPassword 等价通路：AccountUpdatePasswordSettings(setNewPassword=true)，
    // 与 pages/SetupPassportPasswordPage.cj:88-133 同一 RPC 范式（NotSet 态无需
    // currentPasswordSRP）。成功后 routerPop() 回到 Splash 屏（下一步向导本体不在本轮
    // 范围，见交付报告「已知限制」）。
    private func onCreatePasswordTap(): Unit {
        if (this.isSaving) { return }
        if (this.passwordReal.size == 0) {
            this.errorMessage = "Please enter a password"
            return
        }
        if (this.passwordReal != this.confirmReal) {
            this.errorMessage = "Passwords don't match. Please try again"
            return
        }
        this.isSaving = true
        this.errorMessage = ""
        let newPass = this.passwordReal

        let _ = spawn {
            var errMsg = ""
            var success = false
            try {
                let authSvc = getRealAuthService()
                let info = authSvc.getPasswordInfo()
                // passwordUpdateKDF (Account.swift:661-695): nextSalt1 = salt1 + 32B random
                // every submit; hash and returned new_algo.salt1 must be that same nextSalt1.
                if (info.algoP.size == 0) {
                    Hilog.info(0, "CjTelegram",
                        "[TwoFactorCreatePasswordPage] empty algoP; skip hash")
                    errMsg = "Failed to create password. Please try again"
                } else {
                    let nextSalt1 = ByteUtils.concat2(info.algoSalt1, ByteUtils.randomBytes(32))
                    let newHash = authSvc.computeNewPasswordHash(
                        newPass, info.algoG, info.algoP, nextSalt1, info.algoSalt2)

                    let client = getMTProtoClient()
                    let req = AccountUpdatePasswordSettings()
                    req.setNewPassword = true
                    req.algoSalt1 = nextSalt1
                    req.algoSalt2 = info.algoSalt2
                    req.algoG = info.algoG
                    req.algoP = info.algoP
                    req.newPasswordHash = newHash
                    req.hint = ""

                    let respData = client.sendRequest(req.toBytes())
                    if (respData.size >= 4) {
                        let checkD = TLDeserializer(respData)
                        let checkCtor = checkD.readUInt32()
                        if (checkCtor == 0x2144ca19) {
                            let errorCode = checkD.readInt32()
                            let errorMsg = checkD.readString()
                            Hilog.info(0, "CjTelegram",
                                "[TwoFactorCreatePasswordPage] RPC error: ${errorCode} ${errorMsg}")
                            errMsg = this.formatError(errorMsg)
                        } else {
                            success = true
                            Hilog.info(0, "CjTelegram", "[TwoFactorCreatePasswordPage] password created")
                        }
                    } else {
                        errMsg = "Unexpected server response"
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[TwoFactorCreatePasswordPage] exception: ${e}")
                errMsg = "Failed to create password. Please try again"
            }
            let finalSuccess = success
            let finalErr = errMsg
            launch {
                this.isSaving = false
                if (finalSuccess) {
                    routerPop()
                } else {
                    this.errorMessage = finalErr
                }
            }
        }
    }

    private func formatError(rpcError: String): String {
        if (rpcError == "NEW_SALT_INVALID") { return "Server rejected the password. Please try again" }
        if (rpcError == "NEW_SETTINGS_INVALID") { return "Invalid settings. Please try again" }
        if (rpcError == "PASSWORD_EMPTY") { return "Password cannot be empty" }
        if (rpcError == "PASSWORD_TOO_SIMPLE") { return "This password is too simple. Please choose a stronger one" }
        if (rpcError.startsWith("FLOOD_WAIT")) { return "Too many attempts. Please try again later" }
        return rpcError
    }

    // ==================== UI ====================

    @Builder
    func buildMonkey() {
        Stack(alignContent: Alignment.Center) {
            if (this.monkeyFramePath.size > 0) {
                Image(this.monkeyFramePath)
                    .width(136)
                    .height(136)
            }
        }
        .width(136)
        .height(136)
    }

    public func build() {
        // RC-R2（round3）：返回行改为覆盖层（先例 pages/SettingsPage.cj:1017-1021
        // pinnedNavButtons()），与源侧透明导航栏 + 内容垂直居中的结构对位（文件头注释）。
        Stack(alignContent: Alignment.TopStart) {
            Scroll {
                Column {
                    this.buildMonkey()

                    // iconSpacing=2（TwoFactorAuthDataInputScreen.swift:1883-1888，
                    // .password 分支恒为 2.0）。
                    // TwoFactorSetup.Password.Title (Localizable.strings:5017)
                    Text(trSource("Create Password"))
                        .fontSize(28)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0x000000)
                        .textAlign(TextAlign.Center)
                        .margin(top: 2)
                        .padding(left: 32, right: 32)
                        .width(100.percent)

                    // titleInputSpacing=26（.password 正文为空串，跳过 titleSpacing+text）。
                    // D-165（clip(true) 卡片形态）：水平内缩改由外层无 clip 的 Column .padding 承载，
                    // Row 自身只留 width(100%)（相对外层已 padding 收窄的内容区解析）+ 纵向 margin，
                    // 避免 width(100%) 与横向 margin 叠加在同一 clip 节点上摞出贴边溢出盒。
                    Column {
                        Row {
                            Stack(alignContent: Alignment.Start) {
                                if (!this.passwordReal.isEmpty()) {
                                    Text(if (this.textHidden) { this.maskOf(this.passwordReal) } else { this.passwordReal })
                                        .fontSize(17)
                                        .fontColor(0x000000)
                                }
                                // RC-P1（diag round2 §6.1）：绑真值，不挂字符过滤器——round1 绑遮罩串
                                // 又用一个排除遮罩字符的过滤器，控件永远无法保住自己的绑定值。
                                TextInput(text: this.passwordReal, placeholder: trSource("Password"))
                                    // E9（diag TC-0141-E9 修法 F-E9-1a/1b）：TextInput 默认内容内缩
                                    // 16vp，与同 Stack 内覆盖层 Text 的原点（64.0vp）分叉，导致占位符/
                                    // 光标落在 80.0vp 而非 64.0vp。四参 padding 归零 + 字号对齐源侧
                                    // Font.regular(17.0)，让两个原点重新收敛到同一个 64.0vp。
                                    .padding(left: 0, right: 0, top: 0, bottom: 0)
                                    .fontSize(17)
                                    .fontColor(Color.Transparent)
                                    .placeholderColor(0x8E8D92)
                                    .caretColor(0x000000)
                                    .backgroundColor(Color.Transparent)
                                    .onChange({ value: String =>
                                        this.passwordReal = value
                                        this.errorMessage = ""
                                        this.updateMonkeyDrivenState()
                                    })
                                    .onFocus({ =>
                                        this.passwordFocused = true
                                        this.updateMonkeyDrivenState()
                                    })
                                    .onBlur({ =>
                                        this.passwordFocused = false
                                        this.updateMonkeyDrivenState()
                                    })
                                    // RC-P2 A（diag round2 §6.2 A）：与 onFocus/onBlur 并行的第二条驱动边，
                                    // 不依赖对"onFocus 为何未生效"的分辨；长期保留的可观测点，非占位标记。
                                    .onEditChange({ editing: Bool =>
                                        this.passwordFocused = editing
                                        this.updateMonkeyDrivenState()
                                        Hilog.info(0, "CjTelegram",
                                            "[TwoFactorCreatePasswordPage] focus pw=${this.passwordFocused} cf=${this.confirmFocused}")
                                    })
                            }
                            .layoutWeight(1)

                            // round4（diag round4 §6.4 RC-R4-4）：右内缩改为 16→11、图标
                            // margin(left) 改为 8→7，使图标右缘距 pill 右缘 = 11.0（对位源侧
                            // :1240 42 宽按钮盒居中放 20 宽图标）；输入区右边界随之变为
                            // 11+20+7=38.0（对位源侧 :1231 rightInset=38.0）。只改首框，
                            // 确认框 padding(right:16) 不动（无判据支撑，见文件头注释）。
                            Image(this.passwordEyeIcon())
                                .width(20)
                                .height(18)
                                .margin(left: 7)
                                .onClick({ evt => this.toggleTextHidden() })
                        }
                        .width(100.percent)
                        .height(50)
                        .padding(left: 16, right: 11)
                        .backgroundColor(0xE9E9E9)
                        .borderRadius(10)
                        .clip(true)
                        .alignItems(VerticalAlign.Center)
                    }
                    .width(100.percent)
                    .padding(left: 48, right: 48)
                    .margin(top: 26)

                    // rowSpacing=20（两个输入行之间）。次框无眼睛按钮（源侧仅首框有
                    // hideButtonNode，case A4 判据），但遮蔽状态跟随同一个 textHidden
                    // 标志位与首框同步（round4 修复，diag round4 §6.2 RC-R4-2，撤回
                    // round2 §6.1 第 6 条「确认框恒遮蔽」的误读）。
                    // D-165（clip(true) 卡片形态）：同上，横向内缩下沉到外层 Column .padding。
                    Column {
                        Row {
                            Stack(alignContent: Alignment.Start) {
                                if (!this.confirmReal.isEmpty()) {
                                    Text(if (this.textHidden) { this.maskOf(this.confirmReal) } else { this.confirmReal })
                                        .fontSize(17)
                                        .fontColor(0x000000)
                                }
                                // round4（diag round4 §6.2/§3.3 RC-R4-2，撤回 round2 §6.1 第 6 条
                                // 「确认框恒遮蔽」）：确认框与首框共用同一个 textHidden 标志位，遮蔽/揭示
                                // 同步切换（对位源侧 :1780-1783 toggleTextHidden 对 inputNodes 全体生效）。
                                // 首框独占的只是眼睛按钮（源侧 :1104 hideButtonNode.isHidden=confirmation，
                                // 只影响按钮是否存在，不影响遮蔽范围）——确认框仍无按钮，但会跟随首框的
                                // 切换结果一起显/隐。RC-P1（diag round2 §6.1）：绑真值，不挂字符过滤器。
                                TextInput(text: this.confirmReal, placeholder: trSource("Re-enter Password"))
                                    // E9（diag TC-0141-E9 修法 F-E9-1a/1b）：见密码框同名注释。
                                    .padding(left: 0, right: 0, top: 0, bottom: 0)
                                    .fontSize(17)
                                    .fontColor(Color.Transparent)
                                    .placeholderColor(0x8E8D92)
                                    .caretColor(0x000000)
                                    .backgroundColor(Color.Transparent)
                                    .onChange({ value: String =>
                                        this.confirmReal = value
                                        this.errorMessage = ""
                                        this.updateMonkeyDrivenState()
                                    })
                                    .onFocus({ =>
                                        this.confirmFocused = true
                                        this.updateMonkeyDrivenState()
                                    })
                                    .onBlur({ =>
                                        this.confirmFocused = false
                                        this.updateMonkeyDrivenState()
                                    })
                                    // RC-P2 A（diag round2 §6.2 A）：见密码框同名回调注释。
                                    .onEditChange({ editing: Bool =>
                                        this.confirmFocused = editing
                                        this.updateMonkeyDrivenState()
                                        Hilog.info(0, "CjTelegram",
                                            "[TwoFactorCreatePasswordPage] focus pw=${this.passwordFocused} cf=${this.confirmFocused}")
                                    })
                            }
                            .layoutWeight(1)
                        }
                        .width(100.percent)
                        .height(50)
                        .padding(left: 16, right: 16)
                        .backgroundColor(0xE9E9E9)
                        .borderRadius(10)
                        .clip(true)
                        .alignItems(VerticalAlign.Center)
                    }
                    .width(100.percent)
                    .padding(left: 48, right: 48)
                    .margin(top: 20)

                    if (this.errorMessage.size > 0) {
                        Text(this.errorMessage)
                            .fontSize(14)
                            .fontColor(0xFF3B30)
                            .textAlign(TextAlign.Center)
                            .margin(top: 16)
                            .padding(left: 32, right: 32)
                            .width(100.percent)
                    }
                }
                .width(100.percent)
                .alignItems(HorizontalAlign.Center)
                .margin(top: this.contentTopOffset)
                .onAreaChange({ _: Area, newArea: Area => this.updateContentBlockHeight(newArea) })
            }
            .align(Alignment.Top)
            .width(100.percent)
            .height(100.percent)
            .onAreaChange({ _: Area, newArea: Area => this.updateAvailableHeight(newArea) })

            // round4（diag round4 §6.3 RC-R4-3）：主按钮移出内容 Column，作为最外层 Stack
            // 的兄弟节点，按源侧「贴底锚定」规则用 buttonTopOffset 定位（recomputeButtonTop()，
            // 不在内容居中流内，对位 containerLayoutUpdated:1969-1974）。buttonSpacing=20 /
            // buttonHeight=50 / buttonSideInset=48 三个常量随式子参与计算，本身不再是固定
            // margin（round3 §6.2/§4.2 的"块内间距常量一致"判定只覆盖了这三个值本身，不覆盖
            // 位置——位置缺口正是 RC-R4-3，见诊断报告 §3.4）。
            Column {
                Button(if (this.isSaving) { "Creating..." } else { "Create Password" })
                    .width(100.percent)
                    .height(50)
                    .fontSize(17)
                    .fontColor(0xFFFFFF)
                    .backgroundColor(0x007AFF)
                    .borderRadius(11)
                    .clip(true)
                    .enabled(!this.isSaving)
                    .onClick({ evt => this.onCreatePasswordTap() })
            }
            .width(100.percent)
            .padding(left: 48, right: 48)
            .margin(top: this.buttonTopOffset)

            // RC-P3（diag round2 §6.3）：图形+文字同为热区，数值与
            // app/TelegramNavBar.cj:194-200 的 .legacy 分支逐值一致（13×22、margin(left:6)、17pt）。
            // RC-R2（round3）：无背景色的覆盖层，与源侧透明导航栏一致（猴子/内容与 Back 行
            // 允许垂直重叠，见 diag round3 §6.2 引用的 step_02 源侧参照）。
            Row {
                Row {
                    Image(this.navBackArrowIcon())
                        .width(13)
                        .height(22)
                        .fillColor(0x007AFF)
                    Text(trSource("Back"))
                        .fontSize(17)
                        .fontColor(0x007AFF)
                        .margin(left: 6)
                }
                .onClick({ evt => routerPop() })
                Blank().layoutWeight(1)
            }
            .width(100.percent)
            .height(56)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFF)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
    }
}
