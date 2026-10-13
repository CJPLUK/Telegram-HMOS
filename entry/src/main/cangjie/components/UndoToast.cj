package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import kit.ImageKit.PixelMap
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.sync.*
import std.time.*
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.getUndoToastService
import ohos_app_cangjie_entry.app.getAppState
import ohos_app_cangjie_entry.interop.{callArkOnJSTask, UNDO_TOAST_REGION}

// ── 根叠加层宿主（core-acceptance W3 返修，取代 bindContentCover 回退）────────────
// 非受控 UndoToast 现在只挂一处：components/UndoToastOverlay.cj（@HybridComponentEntry），
// 由 ArkTS 根容器 pages/Home.ets 的 UndoToastOverlayHost 经 CJHybridComponent 挂在整个
// Navigation 栈之上（与 S7-59 InAppNotificationBanner 同位），因此在任何路由页上都可见，
// 不再需要 MainTabPage.shown/hidden 事件与 bindContentCover 模态层。
// 命中区：本组件把显隐 + 浮条矩形（vp，相对本组件根节点）经 UNDO_TOAST_REGION 推给 ArkTS 宿主。
// 宿主隐藏时 Visibility.None（不参与布局、没有帧矩形——S3-10：常驻全屏节点即使 enabled=false，
// 也会让系统相册选择器这类安全 UIExtension 判定"被覆盖"而拒绝点击）；显示且矩形已知时宿主外层
// 收缩到浮条矩形并 clip，内层保持整屏尺寸反向平移，本组件的布局输入不变；常驻
// HitTestMode.Transparent（永不阻塞下层 Navigation），矩形同时作内层 responseRegion；
// 浮条矩形内靠浮条自身的 onClick / Undo 的 onClick 赢得手势仲裁（对位 iOS
// UndoOverlayControllerNode.hitTest：面板外返回 nil 透传、面板内面板自己吃掉）。
// visible 在翻转的同一回合立即推送（不等测量，w/h 可为 0），矩形随 onAreaChange 补推；tick 里
// 兜底同步，按"值变化"去重。

/**
 * UndoToast — 可复用的"可撤销提示条"组件（undo toast）
 *
 * 对应 iOS Telegram-iOS submodules/UndoUI（UndoOverlayController）：
 *   底部圆角深色浮条 = 文案 + Undo 按钮 + 倒计时进度，倒计时内可撤销，
 *   到点未撤销 = 提交（commit）。
 *
 * 渲染分离范式参考 RadialStatusComponent ← RadialStatusService：
 *   本组件不持有业务状态，纯渲染；倒计时与回调由 UndoToastService（单例）
 *   维护，组件用 Timer.repeat tick 轮询服务状态并驱动 @State 重绘。
 *
 * 两种用法：
 *   1) 直接挂在 root 容器（自己读服务、自己显示/隐藏）：
 *        UndoToast()
 *      —— bound!=true 时整条由服务的 isShowing() 决定可见性。
 *   2) 作为受控展示条（父组件已用 if 控制可见性，仅渲染一条）：
 *        UndoToast(text: "Chat archived", actionText: "Undo", durationMs: 5000,
 *                  onUndo: { => ... }, onCommit: { => ... })
 *      —— 传入 text 即视为受控模式，不读服务。
 *
 * 计时与两条退场路径：
 *   - 自动 commit：tick 轮询，服务 isExpired() 为真 → finishAsCommit/onCommit → 隐藏
 *   - 手动 undo  ：点 Undo 按钮 → triggerUndo/onUndo → 立即隐藏
 *
 * S-64: aboutToAppear/aboutToDisappear 必须 public override func ... : Unit
 * R-69: Timer 回调内 @State 写必须包 launch{}
 *
 * @Component 基本类型参数用普通 var（非 @Prop）——见 CodeInputViewComponent 约定。
 *
 * ── TC-0015 (uif_undoui 返修) 架构缺陷修复 ─────────────────────────────
 * 诊断（diag-suite_chat_list_folders-TC-0015.md）：本组件此前只依赖"挂在
 * MainTabPage 顶层 Stack 内、build() 按 @State visible 条件渲染"这一种呈现
 * 方式。经 routerPush 压入的独立路由页面（如 ChatFoldersPage）位于导航栈顶时，
 * MainTabPage 的组合树不再是当前被合成的可见内容，其中的 UndoToast() 因此
 * 没有渲染机会——hilog 证实 showUndo 已调用，但设备截图与 dumpLayout 全树
 * 搜索均无 toast 节点。
 *
 * 修复：非受控模式下，本组件在 aboutToAppear 时向 UndoToastService 注册一个
 * "呈现器"（setPresenter，与 P2-405/TC-0012 DialogService 同源范式）。
 * showUndo()/triggerUndo()/finishAsCommit() 命中时会同步直调该呈现器。原有的
 * tick 轮询 + Stack 渲染路径保留（仍会渲染，作为呈现器不可用时——例如组件尚未
 * 挂载——的后备），两条路径共享同一份 @State，互不冲突。
 *
 * ── TC-0012 第二轮返修（P0：sub-window teardown 破坏主窗口）架构重设计 ──────
 * 诊断（diag-suite_chat_list_folders-TC-0012.md 归因分析 + 架构提示）确认：
 * TC-0012 第一轮修复（`openCustomDialog(showInSubWindow:true)` + 关闭时把
 * `this.visible` 置 false 做内容塌缩防御）仍不够——问题比"内容残留"更深：
 * `closeCustomDialog(id)` 关闭指令下达后，子窗口帧（独立 `Dialog` 窗口层）
 * 本身未必被销毁，且该残留窗口层会反过来挤压主窗口可用高度（2880→2432），
 * 导致 TabBar 布局损坏、应用不可用，需强制重启才能恢复——这是"新开一个独立
 * 窗口图层"这个方案本身的系统性风险，不是参数没调对。
 *
 * 官方文档明确不建议这类场景使用子窗口："以下几种场景不建议使用子窗口，建议
 * 优先考虑使用控件 overlay 能力实现……移动设备（手机）场景下子窗不能超出
 * 处于悬浮窗、分屏状态的主窗口范围"（cangjie-kb windowmanager 文档实证）。
 * 本轮改为彻底放弃 sub-window，改用 ArkUI **全屏模态转场**
 * `bindContentCover(isShow, builder, options)`（cangjie-kb 三份独立命中
 * 文档实证：模态转场/cj-universal-attribute-bindcontentcover/
 * cj-contentcover-page）——它是**同一窗口内**的模态图层（"其交互层级默认为
 * 应用内顶层"），不创建任何新的 OS 窗口帧，因此不存在"窗口未销毁挤压主窗口"
 * 这一类问题：`isShow=false` 时该模态内容与其占用的合成层级一起随 ArkUI
 * 正常组件树回收机制退场，没有独立于组件树生命周期之外的"窗口"需要额外销毁。
 * 呈现器改为只是切换 `this.visible`（驱动 `bindContentCover(this.visible,
 * ...)` 的 isShow 参数），不再调用任何 `openCustomDialog`/`closeCustomDialog`。
 *
 * `bindContentCover` 挂在本组件自身根节点上（`build()` 内）。真机实测
 * （见本文件末尾 review 记录 / featureX.md）确认：`showUndo()` 在
 * `MainTabPage` 本身可见时正常呈现/退场，且退场后主窗口高度与 TabBar
 * 完全正常，不再需要强制重启——彻底消除本轮诊断报告描述的 P0 症状。
 *
 * ── TC-0133 返修 (F-13, diag-suite_settings_privacy-TC-0133-E8.md RC-6) ──────
 * UndoToastService.showUndo() 新增 title!/iconRes!/persistent! 三个可选槽位
 * （详见该文件同批次注释）。本组件对应在 curText/curAction 之外新增
 * curTitle/curIconRes 两个 @State：非受控模式下随 presenter 回调
 * （presentAsContentCover）与轮询兜底路径（onTickFromService）两条通道同步；
 * 受控模式下随新增的 public var title/iconRes 在 aboutToAppear 时一次性灌入
 * （与既有 text/actionText 同型）。build() 侧：curTitle 非空 ⇒ 正文之上多渲
 * 一行 14sp FontWeight.Medium 白字标题（本仓 semibold 近似惯例，见
 * ArchiveInfoContent.cj 注释）；curIconRes 非 None ⇒ 最左侧渲一个 20x20
 * leading 图标（形状照 ContextMenu.cj 的 ?ResourceStr iconRes 用法）。
 * persistent 只影响 UndoToastService 侧的自动 commit 判定（isExpired()），
 * 组件侧无需感知。
 *
 * ── TC-0133 返修 (F-13b, diag-suite_settings_privacy-TC-0133-E9.md) ─────────
 * F-13 把 iconRes 声明成 String，收不下 @r(app.media.xxx) 求值出的
 * AppResource——槽位存在但对工程内图标资源永久不可达。本轮把 iconRes 整条
 * 通道（public var iconRes / @State curIconRes / presentAsContentCover 形参 /
 * 注册闭包形参）从 String 改成 ?ResourceStr，None=不渲染图标，与改前空串
 * 语义等价；渲染改用 isSome()/getOrThrow()（照 ContextMenu.cj:311-312），
 * 不再用 String 专属的 .size 判空。
 *
 * ── TC-0133 返修 (F-14, diag-suite_settings_privacy-TC-0133-S9.md RC-1/2/4/5) ──
 * S9 复核 4 项修法：
 *   1) RC-1 图标着色缺失：curIconRes 分支渲染的 Image 此前没有 .fillColor，
 *      本仓单色 SVG 图标（fill="#000000" 形状件）统一靠 .fillColor 上色，
 *      同资源在 PremiumPage.cj:266 已实拍验证白色正确；本轮补 .fillColor(0xFFFFFF)
 *      （两处 build 分支：buildBar() 受控 / buildContentCoverBar() 非受控）。
 *   2) RC-2 计时视觉：新增 @State curShowProgress，非受控分支
 *      buildContentCoverBar() 的 Progress 门控从 showProgress 改读 curShowProgress
 *      （随 presentAsContentCover/onTickFromService 两条通道同步）；受控分支
 *      buildBar() 继续读 public var showProgress 不变（F-13 起既有惯例）。
 *   3) RC-5 动作按钮门：新增 public var showAction（受控模式一次性灌入）+
 *      @State curShowAction（非受控模式随两条通道同步），buildBar()/
 *      buildContentCoverBar() 的 Text(this.curAction) 按钮块各包一层
 *      if (this.curShowAction)。
 *   4) RC-4 图标槽扩容：新增 public var iconPixelMap + @State curIconPixelMap，
 *      渲染优先级固定 curIconPixelMap 非 None ⇒ 渲图（不加 .fillColor，
 *      PixelMap 已是成品像素）；否则退回 curIconRes 分支（带 .fillColor）；
 *      否则不渲。presenter 闭包（setPresenter 注册的匿名函数）与
 *      presentAsContentCover 形参同步扩到 6 元组（新增 iconPixelMap 槽）；
 *      showProgress/showAction 不走该元组——presentAsContentCover 在收到推送
 *      的同一同步帧内直接调 getUndoToastService().getShowProgress()/
 *      getShowAction() 读取（此时 showUndo() 已把两者写入服务状态，读到的
 *      即当前这条 toast 的值），避免元组无限增长。
 *
 * ── TC-0449 round7 返修 (M1/M2, diag-suite_settings_notifications-TC-0449-round7.md) ──
 * C2：正文此前只有单个 Text(this.curText)，结构上不可能局部加粗（源侧 markdown 模板
 * `**bold**` 靠 UndoOverlayControllerNode 统一解析渲染）。新增 splitBoldSegments()
 * 按 `**` 定界符切分正文，buildBar()/buildContentCoverBar() 的正文节点改成
 * `Text(){ ForEach(segments){ Span } }`，形状照抄仓内既有实现 auth/SplashPage.cj
 * splitBoldSegments/slideSubtitleText（该实现本身是源侧 boldRanges 解析的仓颉移植）。
 * 粗体字重取 FontWeight.Medium（与本文件 F-13 标题行同惯例）。
 *
 * C3/D3：图标槽此前只接单张静态 PixelMap（curIconPixelMap），renderTgs 已把动画栅格化
 * 成全部帧，但载体没有帧序列播放通道，调用点被迫只取末帧。新增并列的帧序列槽
 * curIconFrames/curIconFrameIndex（渲染优先级最高，见 build() 分支），随
 * presentAsContentCover()/onTickFromService() 两条既有同步通道从服务读取
 * getIconFrames()/getIconFrameDurationMs()（不扩 presenter 六元组，同 F-14 已立规矩）。
 * 播放驱动形状照抄 components/ProfileMuteIcon.cj startPlayback()/stopPlayback()：
 * 起播延迟 200ms（对位源侧 UndoOverlayControllerNode.swift:2219-2224 的
 * Queue.mainQueue().after(0.2, play())），Timer.repeat 按帧间隔推进，播一遍停在末帧，
 * CatchupStyle.Skip，前台判定，aboutToDisappear/toast 退场路径均 stopIconPlayback()
 * 防定时器泄漏。取值器同 A-6 全函数化写法，索引越界走占位值不抛。
 * 现有 curIconPixelMap/curIconRes 单帧槽保留不动（SelectivePrivacySettingsPage.cj
 * 的 anim_linkcopied 调用点仍在用）。
 */
@Component
public class UndoToast {
    // ==================== 受控模式参数（传 text 即受控，不读服务）====================

    // 提示文案；为空字符串表示"非受控"，改为读 UndoToastService。
    public var text: String = ""

    // 撤销按钮文字
    public var actionText: String = "Undo"

    // 倒计时总时长（毫秒）
    public var durationMs: Int64 = 5000

    // 是否显示进度条（线性倒计时）
    public var showProgress: Bool = true

    // F-13：可选标题 / 可选 leading 图标资源（受控模式下与 text/actionText 同型，
    // 一次性构造赋值；非受控模式下改读 curTitle/curIconRes，见下方 @State 字段）
    public var title: String = ""
    public var iconRes: ?ResourceStr = None<ResourceStr>

    // F-14：是否显示动作按钮（对位源侧 displayUndo）/ 并列图标槽（受控模式下
    // 与 title/iconRes 同型，一次性构造赋值；非受控模式下改读
    // curShowAction/curIconPixelMap，见下方 @State 字段）
    public var showAction: Bool = true
    public var iconPixelMap: ?PixelMap = None<PixelMap>

    // 受控模式回调
    public var onUndo: () -> Unit = { => }
    public var onCommit: () -> Unit = { => }
    public var onDismiss: () -> Unit = { => }

    // ==================== 渲染状态（@State 驱动重绘）====================

    // 当前是否可见
    @State var visible: Bool = false
    // 浮条在根容器内的矩形（vp）：既作本组件根节点的响应区，也经 UNDO_TOAST_REGION 推给
    // ArkTS 根叠加层宿主作 responseRegion，浮条以外的触摸落到下层页面
    @State var barX: Float64 = 0.0
    @State var barY: Float64 = 0.0
    @State var barW: Float64 = 0.0
    @State var barH: Float64 = 0.0

    // 当前文案 / 按钮文字（受控模式来自参数，非受控来自服务）
    @State var curText: String = ""
    @State var curAction: String = "Undo"

    // F-13：当前标题 / leading 图标资源（受控/非受控两路共用同一渲染逻辑）
    @State var curTitle: String = ""
    @State var curIconRes: ?ResourceStr = None<ResourceStr>

    // F-14：是否显示动作按钮 / 并列图标槽（受控/非受控两路共用同一渲染逻辑）
    @State var curShowAction: Bool = true
    @State var curIconPixelMap: ?PixelMap = None<PixelMap>

    // M2 (TC-0449 round7 C3/D3)：帧序列图标槽——与既有单帧 curIconPixelMap 并存，
    // 渲染优先级最高（见 build() 分支）。空数组=不占用，随
    // presentAsContentCover()/onTickFromService() 两条既有同步通道从服务同步。
    @State var curIconFrames: Array<PixelMap> = Array<PixelMap>()
    @State var curIconFrameIndex: Int64 = 0
    private var iconPlaybackTimer: Option<Timer> = None<Timer>
    private var curIconFrameDurationMs: Int32 = 17

    // F-14：是否显示线性倒计时进度条（仅非受控分支使用；受控分支
    // buildBar() 继续读 public var showProgress，见文件头注释）
    @State var curShowProgress: Bool = true

    // 剩余进度比例 [0,1]（1=刚弹出）
    @State var fraction: Float64 = 1.0

    // 受控模式：本条的起止时间戳（毫秒）
    private var ctrlStartedAtMs: Int64 = 0
    // 非受控模式：记录上次见到的服务 epoch（换条时重置计时）
    private var lastSeenEpoch: Int64 = -1

    // tick 定时器
    var tickTimer: Option<Timer> = None<Timer>

    // ==================== 生命周期 ====================

    public override func aboutToAppear(): Unit {
        if (this.isControlled()) {
            // 受控模式：进场即开始本条计时
            this.ctrlStartedAtMs = this.nowMs()
            this.curText = this.text
            this.curAction = this.actionText
            this.curTitle = this.title
            this.curIconRes = this.iconRes
            this.curShowAction = this.showAction
            this.curIconPixelMap = this.iconPixelMap
            this.fraction = 1.0
            this.visible = true
        } else {
            // 非受控模式：注册呈现器（TC-0015 修复延续），保证 showUndo() 无论
            // 从哪个页面（含 routerPush 压入的独立路由页）调用都有可见宿主。
            // 呈现器不打开/关闭任何子窗口或模态层，只切换 `this.visible`——由 build()
            // 里根 Column 的 if (this.visible) 内联渲染驱动呈现/退场（本组件挂在
            // UndoToastOverlay 根叠加层，见文件头）。
            getUndoToastService().setPresenter(
                { vis: Bool, t: String, a: String, ti: String, ic: ?ResourceStr, ipm: ?PixelMap =>
                    this.presentAsContentCover(vis, t, a, ti, ic, ipm) }
            )
        }
        this.startTick()
        Hilog.info(0, "CjTelegram", "[UndoToast] aboutToAppear controlled=" + this.isControlled().toString())
    }

    public override func aboutToDisappear(): Unit {
        this.stopTick()
        this.stopIconPlayback()
        if (!this.isControlled()) {
            getUndoToastService().clearPresenter()
            launch { this.visible = false }
            // 宿主命中区归零，避免 ArkTS 侧残留一块吃触摸的响应区。
            this.pushOverlayRegion(false, 0.0, 0.0, 0.0, 0.0)
        }
    }

    // ==================== TC-0012 第二轮返修：bindContentCover 呈现器 ====================

    /**
     * UndoToastService 在 showUndo/triggerUndo/finishAsCommit 时同步直调。
     * vis=true  → 置位 this.visible=true，驱动 build() 内根 Column 的
     *             if (this.visible) 内联渲染浮条（根叠加层宿主之上，非模态，
     *             响应区只覆盖浮条）；内容读取 this.curText/this.curAction/this.fraction/
     *             this.curTitle/this.curIconRes（F-13）等 @State 字段，随 tick
     *             轮询驱动的状态更新而重绘。
     * vis=false → 置位 this.visible=false，`bindContentCover` 随之退场——
     *             这是 ArkUI 组件树自身的合成状态切换，不涉及任何独立窗口
     *             对象的创建/销毁，因此不存在 TC-0012 报告描述的"子窗口帧
     *             关闭指令下达但未被销毁、挤压主窗口布局"问题（该问题的
     *             根源正是"子窗口"这一独立窗口层机制本身，见文件头注释）。
     *
     * R-69: 本函数由 UndoToastService 同步调用（非 Timer 回调）也可能由
     * Timer tick 间接触发（finishAsCommit 路径），@State 写统一走 launch{}
     * 更安全（与旧版 presentInSubWindow 保持一致的线程安全策略）。
     *
     * F-14: showProgress/showAction 未随本函数形参推送（presenter 元组维持
     * 6 元不再增长）——vis=true 时本函数正处在 showUndo() 触发
     * notifyPresenter(true) 的同一同步调用帧内，此刻服务侧
     * _showProgress/_showAction 已被 showUndo() 写入本条 toast 的值，故直接
     * 调 getShowProgress()/getShowAction() 读取即为当前值，与随元组推送等价。
     */
    private func presentAsContentCover(
        vis: Bool, t: String, a: String, ti: String, ic: ?ResourceStr, ipm: ?PixelMap
    ): Unit {
        launch {
            if (vis) {
                this.curText = t
                this.curAction = a
                this.curTitle = ti
                this.curIconRes = ic
                this.curIconPixelMap = ipm
                this.curShowProgress = getUndoToastService().getShowProgress()
                this.curShowAction = getUndoToastService().getShowAction()
                // M2：帧序列不走 presenter 六元组（同 showProgress/showAction 的既定
                // 规矩）——此刻正处于 showUndo() 触发 notifyPresenter(true) 的同一
                // 同步调用帧内，服务侧 _iconFrames/_iconFrameDurationMs 已被写入本条
                // toast 的值，直接读取即为当前值。
                this.curIconFrames = getUndoToastService().getIconFrames()
                this.curIconFrameDurationMs = getUndoToastService().getIconFrameDurationMs()
                this.curIconFrameIndex = 0
                this.startIconPlayback()
            } else {
                this.stopIconPlayback()
            }
            this.visible = vis
            // 显隐同回合推给 ArkTS 宿主（隐藏态宿主 enabled=false 不参与命中，必须先亮起来
            // 浮条才可点；不等 onAreaChange 测量）。
            this.syncOverlayRegion()
        }
        Hilog.info(0, "CjTelegram",
            "[UndoToast] presentAsContentCover visible=" + vis.toString() + " text=" + t)
    }

    // ==================== 模式判定 ====================

    private func isControlled(): Bool {
        return this.text.size > 0
    }

    private func nowMs(): Int64 {
        return DateTime.now().toUnixTimeStamp().toMilliseconds()
    }

    // ==================== tick：轮询计时，驱动进度 + 自动 commit ====================

    private func startTick(): Unit {
        if (this.tickTimer.isSome()) {
            return
        }
        // 每 100ms tick 一次，进度平滑、到点及时
        this.tickTimer = Some(Timer.repeat(
            Duration.millisecond * 100,
            Duration.millisecond * 100,
            { => this.onTick() },
            style: CatchupStyle.Skip
        ))
    }

    private func stopTick(): Unit {
        match (this.tickTimer) {
            case Some(t) =>
                t.cancel()
                this.tickTimer = None<Timer>
            case None => ()
        }
    }

    /**
     * 每个 tick 计算剩余时间 / 进度，并在到点时自动 commit。
     * R-69: @State 写必须包 launch{}。
     */
    private func onTick(): Unit {
        if (this.isControlled()) {
            this.onTickControlled()
        } else {
            this.onTickFromService()
        }
    }

    // 受控模式：用本条的起始时间戳算进度
    private func onTickControlled(): Unit {
        if (!this.visible) {
            return
        }
        let elapsed = this.nowMs() - this.ctrlStartedAtMs
        let dur = if (this.durationMs > 0) { this.durationMs } else { 5000 }
        let remain = dur - elapsed
        if (remain <= 0) {
            // 到点未撤销 = 提交
            let commitCb = this.onCommit
            let dismissCb = this.onDismiss
            launch {
                this.visible = false
                this.fraction = 0.0
            }
            commitCb()
            dismissCb()
            return
        }
        let frac = Float64(remain) / Float64(dur)
        launch { this.fraction = frac }
    }

    // ==================== 根叠加层宿主命中区推送 ====================

    // 上次推给 ArkTS 宿主的命中区（去重用）
    private var lastPushedRegion: String = ""

    private func pushOverlayRegion(visible: Bool, x: Float64, y: Float64, w: Float64, h: Float64): Unit {
        let json = "{\"visible\":${visible},\"x\":${x},\"y\":${y},\"w\":${w},\"h\":${h}}"
        if (json == this.lastPushedRegion) {
            return
        }
        this.lastPushedRegion = json
        callArkOnJSTask(UNDO_TOAST_REGION, json, { _ => () })
        Hilog.info(0, "CjTelegram", "[UndoToast] overlayRegion " + json)
    }

    /**
     * 按当前显隐 + 浮条几何推送给 ArkTS 宿主（值不变不发）。显隐翻转处与 onAreaChange 里直接调用，
     * tick 里兜底。可见但尚未测量时也推 visible=true（w/h=0）：宿主据 visible 切 enabled，矩形
     * 只影响宿主自身 responseRegion，等 onAreaChange 到了再补推真实矩形。
     */
    private func syncOverlayRegion(): Unit {
        if (this.visible) {
            this.pushOverlayRegion(true, this.barX, this.barY, this.barW, this.barH)
        } else {
            this.pushOverlayRegion(false, 0.0, 0.0, 0.0, 0.0)
        }
    }

    // 非受控模式：跟随 UndoToastService 状态
    private func onTickFromService(): Unit {
        this.syncOverlayRegion()
        let svc = getUndoToastService()
        let showing = svc.isShowing()
        if (!showing) {
            if (this.visible) {
                this.stopIconPlayback()
                launch {
                    this.visible = false
                    this.syncOverlayRegion()
                }
            }
            return
        }
        // 换了一条新 toast → 同步文案（F-13：连同 title/iconRes 一并同步，
        // presenter 未注册时的轮询兜底路径与 presentAsContentCover 同源保持一致；
        // F-14：showProgress/showAction/iconPixelMap 同批同步；M2：iconFrames/
        // iconFrameDurationMs 同批同步 + 起播，同 presentAsContentCover 的做法）
        let epoch = svc.getEpoch()
        if (epoch != this.lastSeenEpoch) {
            this.lastSeenEpoch = epoch
            let t = svc.getText()
            let a = svc.getActionText()
            let ti = svc.getTitle()
            let ic = svc.getIconRes()
            let ipm = svc.getIconPixelMap()
            let sp = svc.getShowProgress()
            let sa = svc.getShowAction()
            let iframes = svc.getIconFrames()
            let idur = svc.getIconFrameDurationMs()
            launch {
                this.curText = t
                this.curAction = a
                this.curTitle = ti
                this.curIconRes = ic
                this.curIconPixelMap = ipm
                this.curShowProgress = sp
                this.curShowAction = sa
                this.curIconFrames = iframes
                this.curIconFrameDurationMs = idur
                this.curIconFrameIndex = 0
                this.visible = true
                this.syncOverlayRegion()
                this.startIconPlayback()
            }
        }
        if (svc.isExpired()) {
            // 到点：让服务收口（触发 onCommit），组件随之隐藏
            svc.finishAsCommit()
            this.stopIconPlayback()
            launch {
                this.visible = false
                this.syncOverlayRegion()
            }
            return
        }
        let frac = svc.remainingFraction()
        launch { this.fraction = frac }
    }

    // ==================== 用户撤销 ====================

    private func handleUndo(): Unit {
        if (this.isControlled()) {
            let undoCb = this.onUndo
            let dismissCb = this.onDismiss
            this.stopIconPlayback()
            launch {
                this.visible = false
                this.fraction = 0.0
            }
            undoCb()
            dismissCb()
        } else {
            getUndoToastService().triggerUndo()
            this.stopIconPlayback()
            launch {
                this.visible = false
                this.syncOverlayRegion()
            }
        }
        Hilog.info(0, "CjTelegram", "[UndoToast] handleUndo")
    }

    // ==================== M1 (TC-0449 round7 C2)：正文粗体分段 ====================
    //
    // 把形如 "The sound **file.mp3** was added..." 的字符串拆成 (text, isBold) 有序
    // 分段，用 "**" 作为定界符——直接对应 iOS UndoOverlayControllerNode 的
    // parseMarkdownIntoAttributedString。形状照抄仓内既有实现
    // auth/SplashPage.cj:472-491 splitBoldSegments（该实现本身是源侧
    // RMIntroPageView.m boldRanges 解析的仓颉移植），不自造新算法。未成对的尾随
    // "**" 按普通文本原样保留。

    private func splitBoldSegments(raw: String): ArrayList<(String, Bool)> {
        let segments = ArrayList<(String, Bool)>()
        var remaining = raw
        var bold = false
        while (remaining.size > 0) {
            let markerIdx = remaining.indexOf("**")
            match (markerIdx) {
                case None =>
                    segments.add((remaining, bold))
                    remaining = ""
                case Some(idx) =>
                    if (idx > 0) {
                        segments.add((remaining[0..idx], bold))
                    }
                    remaining = remaining[(idx + 2)..remaining.size]
                    bold = !bold
            }
        }
        return segments
    }

    // ==================== A-6 (diag-suite_settings_privacy-TC-0133-R4.md)：
    // 图标取值全函数化，消除叶子渲染闭包里的偏函数 ====================
    //
    // 根因：ArkUI 的 CustomView 局部更新按节点重跑各自的更新闭包，不是自顶向下
    // 重建整棵树。buildBar()/buildContentCoverBar() 里 `Image(...)` 这个叶子节点的
    // 更新闭包只包含取值那一句；守护它的 `isSome()` 属于祖先 IfElse 节点的闭包，
    // 在叶子闭包被单独重跑时不会被重新求值。跨变体切换 toast 时，上一变体渲染过的
    // 分支对应的 @State 槽位被切到 None（这是正确、必要的写），但该分支叶子节点若
    // 仍在脏集里，其更新闭包重跑时对 None 调用 getOrThrow() 直接抛
    // NoneValueException（无 catch）→ SIGABRT。
    //
    // 修法：把渲染路径上会抛的取值（`getOrThrow()`）换成不会抛的全函数取值器——
    // 判空与取值合并进同一次函数调用，不留下"仅取值、假设一定有值"的偏函数。
    // `isSome()` 门控字面一个字没删、优先级一个字没改；最坏情况下叶子闭包被
    // 携带过期分支判断重跑一次，取到的是安全占位值（1×1 占位 PixelMap /
    // 空字符串资源），画面自愈，不会崩溃。

    private func hasIconPixelMap(): Bool {
        match (this.curIconPixelMap) {
            case Some(_) => return true
            case None => return false
        }
    }

    private func iconPixelMapOrPlaceholder(): PixelMap {
        match (this.curIconPixelMap) {
            case Some(pm) => return pm
            case None => return createDummyThumbnailPixelMap()
        }
    }

    private func hasIconRes(): Bool {
        match (this.curIconRes) {
            case Some(_) => return true
            case None => return false
        }
    }

    private func iconResOrEmpty(): ResourceStr {
        match (this.curIconRes) {
            case Some(r) => return r
            case None => return ""
        }
    }

    // ==================== M2 (TC-0449 round7 C3/D3)：图标帧序列取值 + 播放驱动 ====
    //
    // 全函数取值器，形状同 A-6（判空与取值合并，索引越界同样走占位值不抛）。

    private func hasIconFrames(): Bool {
        return this.curIconFrames.size > 0
    }

    private func iconFrameOrPlaceholder(): PixelMap {
        let idx = this.curIconFrameIndex
        if (idx >= 0 && idx < this.curIconFrames.size) {
            return this.curIconFrames[idx]
        }
        return createDummyThumbnailPixelMap()
    }

    /**
     * 起播——形状照抄 components/ProfileMuteIcon.cj startPlayback()/stopPlayback()。
     * 源侧 `Queue.mainQueue().after(0.2, { animationNode.play() })`（在 animateIn 里，
     * UndoOverlayControllerNode.swift:2219-2224）：入场后延迟 200ms 起播，一次性
     * Timer.once 落地后交给 armIconFramePlayback() 起 Timer.repeat 按帧间隔推进。
     */
    private func startIconPlayback(): Unit {
        this.stopIconPlayback()
        let count = this.curIconFrames.size
        if (count <= 1) {
            return
        }
        var interval = this.curIconFrameDurationMs
        if (interval < 16) {
            interval = 16
        }
        let capturedInterval = interval
        this.iconPlaybackTimer = Some(Timer.once(Duration.millisecond * 200, { =>
            launch { this.armIconFramePlayback(capturedInterval) }
        }))
    }

    private func armIconFramePlayback(interval: Int32): Unit {
        let count = this.curIconFrames.size
        if (count <= 1) {
            return
        }
        this.iconPlaybackTimer = Some(Timer.repeat(
            Duration.millisecond * Int64(interval), Duration.millisecond * Int64(interval),
            { =>
                if (!getAppState().isInForeground()) {
                    return
                }
                launch {
                    if (this.curIconFrameIndex + 1 >= count) {
                        this.curIconFrameIndex = count - 1
                        this.stopIconPlayback()
                    } else {
                        this.curIconFrameIndex = this.curIconFrameIndex + 1
                    }
                }
            }, style: CatchupStyle.Skip
        ))
    }

    private func stopIconPlayback(): Unit {
        match (this.iconPlaybackTimer) {
            case Some(t) =>
                t.cancel()
                this.iconPlaybackTimer = None<Timer>
            case None => ()
        }
    }

    // ==================== UI ====================

    /**
     * 非受控模式：浮条直接画在本组件根 Column 里（根叠加层宿主 UndoToastOverlay 位于
     * 整个 Navigation 栈之上，任何页面都可见），根节点响应区只覆盖浮条矩形；真正保证
     * 浮条以外触摸透传 / 不遮挡的是 ArkTS 宿主的 Visibility.None（隐藏）/ 收缩到浮条矩形
     * + HitTestMode.Transparent（显示），见文件头与 impls/UndoToastOverlayImpl.ets。不再使用 bindContentCover /
     * openCustomDialog 任何模态或子窗口载体（二者分别会吃掉浮条以外的触摸 / 破坏主窗口，
     * 见文件头历史）。受控模式（父组件已用 if 控制可见性、显式传参的用法）保持组合树
     * 内联渲染完全不变。
     */
    func build() {
        if (this.isControlled()) {
            if (this.visible) {
                this.buildBar()
            }
        } else {
            Column {
                if (this.visible) {
                    this.buildContentCoverBar()
                }
            }
            .width(100.percent)
            .height(100.percent)
            .responseRegion(this.inlineResponseRegion())
        }
    }

    @Builder
    private func buildBar() {
        Column {
            // F-13：可选标题行——semibold 14sp 白字，仅 curTitle 非空时渲染；
            // 本仓 semibold 近似惯例用 FontWeight.Medium（见 ArchiveInfoContent.cj 注释）
            if (this.curTitle.size > 0) {
                Text(this.curTitle)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0xFFFFFF)
                    .width(100.percent)
                    .textAlign(TextAlign.Start)
                    .margin(bottom: 4)
            }
            Row {
                // F-14：图标槽优先级——curIconPixelMap 非 None 优先渲（成品像素，
                // 不加 .fillColor）；否则退回 curIconRes 分支（F-13b 起沿用，
                // 形状照 ContextMenu.cj:311-312，本轮补 .fillColor 修 RC-1）。
                // A-6：判空 + 取值合并进全函数取值器（hasIconPixelMap/
                // iconPixelMapOrPlaceholder/hasIconRes/iconResOrEmpty），不再用
                // isSome() + getOrThrow() 拆开写——后者在叶子节点被 ArkUI 局部
                // 更新单独重跑时可能读到过期的 None，见文件顶部 A-6 段注释。
                // M2：curIconFrames 非空优先级最高——帧序列播放（见文件头 M2 段）。
                if (this.hasIconFrames()) {
                    Image(this.iconFrameOrPlaceholder())
                        .width(20)
                        .height(20)
                        .objectFit(ImageFit.Contain)
                        .margin(right: 8)
                } else if (this.hasIconPixelMap()) {
                    Image(this.iconPixelMapOrPlaceholder())
                        .width(20)
                        .height(20)
                        .objectFit(ImageFit.Contain)
                        .margin(right: 8)
                } else if (this.hasIconRes()) {
                    Image(this.iconResOrEmpty())
                        .width(20)
                        .height(20)
                        .objectFit(ImageFit.Contain)
                        .fillColor(0xFFFFFF)
                        .margin(right: 8)
                }
                // 左：文案（M1：**bold** 分段渲染，见文件头 M1 段）
                Text() {
                    ForEach(this.splitBoldSegments(this.curText), itemGenerator: { seg: (String, Bool), _i: Int64 =>
                        Span(seg[0])
                            .fontSize(14)
                            .fontColor(0xFFFFFF)
                            .fontWeight(if (seg[1]) { FontWeight.Medium } else { FontWeight.Regular })
                    })
                }
                .layoutWeight(1)
                .maxLines(2)
                .textOverflow(TextOverflow.Ellipsis)

                // 右：Undo 按钮（F-14：仅 curShowAction 时渲染，对位源侧 displayUndo）
                if (this.curShowAction) {
                    Text(this.curAction)
                        .fontSize(15)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0x3E88F7)
                        .padding(left: 12, right: 4)
                        .onClick({ _ => this.handleUndo() })
                }
            }
            .width(100.percent)
            .alignItems(VerticalAlign.Center)

            // 倒计时线性进度（可选，受控模式继续读 public var showProgress 不变）
            if (this.showProgress) {
                Progress(value: this.fraction * 100.0, total: 100.0, progressType: ProgressType.Linear)
                    .width(100.percent)
                    .height(3)
                    .color(0x3E88F7)
                    .backgroundColor(0x33FFFFFF)
                    .margin(top: 8)
            }
        }
        .width(92.percent)
        .padding(top: 12, bottom: 12, left: 16, right: 16)
        .borderRadius(12)
        .backgroundColor(0xF0202020)
        .margin(bottom: 80)
    }

    /**
     * TC-0012 第二轮返修：`bindContentCover` 内容 builder（取代原
     * `buildSubWindowBar`/`openCustomDialog` 路径）。
     *
     * 外层 Column 撑满全屏（`bindContentCover` 本身是全屏模态），用
     * `justifyContent(FlexAlign.End)` 把实际浮条对齐到底部，视觉效果与旧版
     * `DialogAlignment.Bottom` 一致。
     *
     * 注：`hitTestBehavior`/`HitTestMode` 概念在 ArkTS 文档中存在，但本工程
     * 当前 Cangjie ArkUI 绑定的"通用属性"清单（cangjie-kb 命中的
     * cj-universal-attributes 索引）未见该链式方法，`Column` 编译期报
     * `'hitTestBehavior' is not a member of class 'Column'`（已实测确认，
     * 非猜测）——本版本不做透明区域触摸穿透优化，浮条之外区域按
     * `ModalTransition.None` + 透明背景的默认全屏模态行为处理；验收标准
     * （toast 出现/自动消失/可点 Undo/主窗口不受损）不依赖该项。
     *
     * 内容整体门控在 `this.visible` 之下（`if` 分支，空 else 分支为 0 尺寸
     * 占位）——`bindContentCover` 的 `isShow` 参数已经控制了整体显隐，这里
     * 双重门控是防御性写法：`isShow` 从 true→false 的退场动画期间，内容
     * 立即随 `this.visible` 塌缩为空，不依赖退场动画完成时机。
     */
    @Builder
    private func buildContentCoverBar() {
        Column {
            if (this.visible) {
                Column {
                    // F-13：可选标题行——semibold 14sp 白字，仅 curTitle 非空时渲染
                    if (this.curTitle.size > 0) {
                        Text(this.curTitle)
                            .fontSize(14)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0xFFFFFF)
                            .width(100.percent)
                            .textAlign(TextAlign.Start)
                            .margin(bottom: 4)
                    }
                    Row {
                        // F-14：图标槽优先级——curIconPixelMap 非 None 优先渲（成品像素，
                        // 不加 .fillColor）；否则退回 curIconRes 分支（F-13b 起沿用，
                        // 形状照 ContextMenu.cj:311-312，本轮补 .fillColor 修 RC-1）。
                        // A-6（diag-suite_settings_privacy-TC-0133-R4.md ①，阻断级崩溃修复）：
                        // 原 isSome() + getOrThrow() 写法在跨变体切换 toast 时必崩——ArkUI
                        // 按节点做局部更新，这个 Image 叶子节点的更新闭包只含 getOrThrow()
                        // 那一句，守护它的 isSome() 属于祖先 IfElse 闭包、不会随叶子闭包重跑
                        // 被重新求值；上一变体渲染过的分支在其 @State 槽位被切成 None 后，
                        // 叶子闭包仍可能被单独重跑并对 None 解引用 → NoneValueException →
                        // SIGABRT（3/3 复现，见诊断报告）。改为全函数取值器（判空与取值合并
                        // 进同一次调用，不返回会抛的值），即便闭包带着过期分支判断被重跑，
                        // 最坏结果只是画一帧占位图标，随后画面随分支判断刷新而自愈。
                        // M2：curIconFrames 非空优先级最高——帧序列播放（见文件头 M2 段）。
                        if (this.hasIconFrames()) {
                            Image(this.iconFrameOrPlaceholder())
                                .width(20)
                                .height(20)
                                .objectFit(ImageFit.Contain)
                                .margin(right: 8)
                        } else if (this.hasIconPixelMap()) {
                            Image(this.iconPixelMapOrPlaceholder())
                                .width(20)
                                .height(20)
                                .objectFit(ImageFit.Contain)
                                .margin(right: 8)
                        } else if (this.hasIconRes()) {
                            Image(this.iconResOrEmpty())
                                .width(20)
                                .height(20)
                                .objectFit(ImageFit.Contain)
                                .fillColor(0xFFFFFF)
                                .margin(right: 8)
                        }
                        // 左：文案（M1：**bold** 分段渲染，见文件头 M1 段）
                        Text() {
                            ForEach(this.splitBoldSegments(this.curText), itemGenerator: { seg: (String, Bool), _i: Int64 =>
                                Span(seg[0])
                                    .fontSize(14)
                                    .fontColor(0xFFFFFF)
                                    .fontWeight(if (seg[1]) { FontWeight.Medium } else { FontWeight.Regular })
                            })
                        }
                        .layoutWeight(1)
                        .maxLines(2)
                        .textOverflow(TextOverflow.Ellipsis)

                        // 右：Undo 按钮（F-14：仅 curShowAction 时渲染，对位源侧 displayUndo）
                        if (this.curShowAction) {
                            Text(this.curAction)
                                .fontSize(15)
                                .fontWeight(FontWeight.Bold)
                                .fontColor(0x3E88F7)
                                .padding(left: 12, right: 4)
                                .onClick({ _ => this.handleUndo() })
                        }
                    }
                    .width(100.percent)
                    .alignItems(VerticalAlign.Center)

                    // 倒计时线性进度（可选，F-14：非受控分支改读 curShowProgress）
                    if (this.curShowProgress) {
                        Progress(value: this.fraction * 100.0, total: 100.0, progressType: ProgressType.Linear)
                            .width(100.percent)
                            .height(3)
                            .color(0x3E88F7)
                            .backgroundColor(0x33FFFFFF)
                            .margin(top: 8)
                    }
                }
                .width(92.percent)
                .padding(top: 12, bottom: 12, left: 16, right: 16)
                .borderRadius(12)
                .backgroundColor(0xF0202020)
                .margin(bottom: 24)
                // 浮条自己吃掉矩形内的点击（对位 iOS UndoOverlayControllerNode.hitTest：面板内
                // super.hitTest 返回面板本身，不落到下层）。宿主是 HitTestMode.Transparent，
                // 下层页面的手势也会被收集，靠本节点的点击识别器排在前面赢得仲裁；Undo 的
                // onClick 是子节点，优先于本处。
                .onClick({ _ => () })
                .onAreaChange({ _: Area, newArea: Area =>
                    match (newArea.position.x) {
                        case Some(x) => this.barX = x.value
                        case None => ()
                    }
                    match (newArea.position.y) {
                        case Some(y) => this.barY = y.value
                        case None => ()
                    }
                    this.barW = newArea.width.value
                    this.barH = newArea.height.value
                    // 测量完成立即补推真实矩形，不等下一个 tick。
                    this.syncOverlayRegion()
                })
            } else {
                Column {}
                    .width(0)
                    .height(0)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .justifyContent(FlexAlign.End)
        .alignItems(HorizontalAlign.Center)
        .responseRegion(this.inlineResponseRegion())
    }

    /** 只有浮条本身接收触摸；未显示或尚未测量时零面积，整块区域对下层透明。 */
    private func inlineResponseRegion(): ?Rectangle {
        if (!this.visible || this.barW <= 0.0 || this.barH <= 0.0) {
            return Rectangle(x: 0.0, y: 0.0, width: 0.0, height: 0.0)
        }
        return Rectangle(x: this.barX, y: this.barY, width: this.barW, height: this.barH)
    }
}
