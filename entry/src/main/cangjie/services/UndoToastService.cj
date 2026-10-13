package ohos_app_cangjie_entry.services

import kit.ArkUI.*
import kit.ImageKit.PixelMap
import kit.PerformanceAnalysisKit.Hilog
import std.time.DateTime

/**
 * UndoToastService — 可撤销提示条（undo toast）管理器（单例）
 *
 * 对应 iOS Telegram-iOS submodules/UndoUI（UndoOverlayController）：
 *   破坏性操作（归档 / 删除会话、静音等）后在底部弹出一条
 *   "文案 + Undo 按钮 + 倒计时自动消失" 的浮条，倒计时内可撤销。
 *
 * 本服务只持有**纯状态 + 回调**，不含任何 UI；UI 由 UndoToast 组件
 * （components/UndoToast.cj）以叠加层方式消费（参考 RadialStatusService ←
 * RadialStatusComponent 的渲染分离范式）。
 *
 * 调用方（各 feature 的归档 / 删除动作）只需：
 *   getUndoToastService().showUndo(
 *       text: "Chat archived",
 *       onUndo: { => repository.unarchive(peerId) },
 *       onCommit: { => repository.commitArchive(peerId) }
 *   )
 *
 * 生命周期（一个 toast）：
 *   showUndo → isShowing()=true，记录 startedAtMs / durationMs / 回调
 *   → UndoToast 组件 tick 轮询 remainingMs()，渲染倒计时进度
 *   → 用户点 Undo  → triggerUndo()   → onUndo()  + 清除 → isShowing()=false
 *   → 超时（remaining<=0）→ triggerCommit() → onCommit() + 清除
 *   → 主动 dismiss()  → 视为 commit（与 iOS 一致：不撤销即提交）
 *
 * 后到的 showUndo 会替换前一条（前一条按 commit 收口），与 iOS 单条
 * overlay 语义一致。
 *
 * ── TC-0133 返修 (F-13, diag-suite_settings_privacy-TC-0133-E8.md RC-6) ──────
 *   源侧 `UndoOverlayController(content: .premiumPaywall(title:text:...:timeout:))`
 *   固定携带 title（semibold 白字）+ PremiumStar 图标 + `timeout: nil`（不自动
 *   消失），但本服务此前的 showUndo() 签名没有对应槽位——不是调用点漏传，是
 *   载体本身缺槽位。补齐 title!/iconRes!/persistent! 三个具名可选参数（均带
 *   默认值，全仓既有调用点行为逐字不变）：persistent=true 时 isExpired() 恒
 *   为 false，不会被 tick 轮询自动 commit（"不启动自动消失计时"）；title/
 *   iconRes 随 _text/_actionText 同路径经 notifyPresenter 同步下发给
 *   presenter（UndoToast 组件），也经 getTitle()/getIconRes() 供轮询路径读取。
 *   调用点（title="Premium Required" + iconRes + persistent:true）改动归
 *   set_selective_privacy（pages/SelectivePrivacySettingsPage.cj），与本轮并批。
 *
 * ── TC-0133 返修 (F-13b, diag-suite_settings_privacy-TC-0133-E9.md) ─────────
 *   F-13 把 iconRes! 声明成 String，收不下 `@r(app.media.xxx)` 求值出的
 *   AppResource（ohos.base 只 extend String <: ResourceStr，反向不成立）——
 *   槽位存在但对工程内图标资源永久不可达。本轮把 iconRes 整条通道（字段/
 *   presenter 闭包第 5 槽/setPresenter/clearPresenter/showUndo 形参/
 *   getIconRes）从 String 改成 ?ResourceStr，None=不渲染图标，与改前空串
 *   语义等价；6 个既有 showUndo 调用点均不传该参数，零回归。
 *
 * ── TC-0133 返修 (F-14, diag-suite_settings_privacy-TC-0133-S9.md RC-2/3/4/5) ──
 *   S9 复核发现 F-13 把源侧 `UndoOverlayContent` 逐 content 决策拍平成标量
 *   参数时漏了两项：(1) 是否挂线性倒计时视觉（源侧 `.linkCopied`/
 *   `.premiumPaywall` 均无对应节点，旧版 showProgress 恒为 true 且调用方无从
 *   关闭）；(2) 是否渲染动作按钮（对位源侧 `displayUndo`，旧版无门，
 *   `actionText` 无条件渲染）。本轮补齐 showProgress!/showAction! 两个具名
 *   可选参数（默认 true，行为与改前逐字一致），并新增 iconPixelMap! 并列
 *   图标槽（对位源侧 `.linkCopied` 的 Lottie 图标——挖空改色后的产物是
 *   PixelMap，装不进 `?ResourceStr` 槽，不与其合并，避免 E9 已明令禁止的
 *   "字符串路径兜底通道"式漂移）。另外 `persistent: true` 此前只在
 *   `isExpired()` 短路，`remainingFraction()` 未短路，导致常驻 toast 的进度
 *   条会走完归零却不退场——本轮补上 `remainingFraction()` 的短路。
 *
 * ── TC-0015 (uif_undoui 返修) 架构缺陷修复 ─────────────────────────────
 *   诊断报告（diag-suite_chat_list_folders-TC-0015.md）确认：全局唯一的
 *   UndoToast() 叠加层只挂载在 MainTabPage 的顶层 Stack；经 routerPush
 *   压入的独立路由页面（如 ChatFoldersPage）在导航栈顶时，MainTabPage 的
 *   组合树不再是当前可见/被合成的顶层内容，其中挂载的 UndoToast() 因此
 *   没有渲染机会（hilog 证实 showUndo 已调用，但设备截图与 dumpLayout
 *   全树搜索均无 toast 节点）。
 *
 *   修复方案：新增"presenter 直呼"路径（与 P2-405/TC-0012 DialogService
 *   的 setPresenter 同源范式）——showUndo() 命中时，若已有 presenter 注册
 *   （由 components/UndoToast.cj 在 aboutToAppear 注册），立即同步调用它。
 *   presenter 侧（UndoToast 组件）用 bindContentCover（同窗口全屏模态层，
 *   ModalTransition.None）在模态层渲染 toast 内容——模态层可覆盖
 *   NavDestination 页面栈、无论当前可见页面是谁都能正确显示，且不新开独立
 *   子窗口帧（避免 TC-0012 报告的子窗口 teardown 破坏主窗口/TabBar 的问题）。
 *   旧的 isShowing()/getEpoch() 等轮询查询接口原样保留（组件仍可选择
 *   轮询模式），presenter 路径是在此之上叠加的"保证可见"能力。
 *
 * ── TC-0449 round7 返修 (M2a, diag-suite_settings_notifications-TC-0449-round7.md C3/D3) ──
 *   图标槽此前只接单张静态 PixelMap（_iconPixelMap），renderTgs 已把动画栅格化成
 *   全部帧，但载体没有帧序列播放通道，调用点被迫只取末帧。新增并列的帧序列槽
 *   _iconFrames!/_iconFrameDurationMs!（与既有单帧槽并存，互不替代）。同 F-14 已立
 *   的规矩：新槽不走 presenter 六元组，由组件（UndoToast.cj）在收到推送的同一同步
 *   调用帧内直接调 getIconFrames()/getIconFrameDurationMs() 读取。
 */
private var _undoToastServiceInstance: Option<UndoToastService> = None<UndoToastService>

public func getUndoToastService(): UndoToastService {
    match (_undoToastServiceInstance) {
        case Some(s) => s
        case None =>
            let s = UndoToastService()
            _undoToastServiceInstance = Some(s)
            s
    }
}

public class UndoToastService {
    // 当前是否有 toast 在显示
    private var _showing: Bool = false

    // 当前 toast 的文案与按钮文字
    private var _text: String = ""
    private var _actionText: String = "Undo"

    // F-13：可选标题（如 "Premium Required"）/ 可选 leading 图标资源 /
    // 是否持久（不自动消失，对应源侧 timeout: nil）。三者均有默认值，
    // 空串/false 时行为与本轮修复前逐字一致。
    private var _title: String = ""
    private var _iconRes: ?ResourceStr = None<ResourceStr>
    private var _persistent: Bool = false

    // F-14：是否显示线性倒计时进度条 / 是否显示动作按钮（对位源侧
    // displayUndo）/ 并列图标槽（Lottie 挖空改色产物，装不进 ?ResourceStr）。
    // 三者均有默认值，与本轮修复前逐字一致。
    private var _showProgress: Bool = true
    private var _showAction: Bool = true
    private var _iconPixelMap: ?PixelMap = None<PixelMap>

    // M2a (TC-0449 round7 C3/D3)：帧序列图标槽——与既有单帧 _iconPixelMap 并存
    // （空数组=不占用）。不走 presenter 六元组，同 showProgress/showAction 的既定
    // 规矩，由组件在收到推送的同一同步帧内直接调 getIconFrames()/
    // getIconFrameDurationMs() 读取。
    private var _iconFrames: Array<PixelMap> = Array<PixelMap>()
    private var _iconFrameDurationMs: Int32 = 17

    // 倒计时总时长（毫秒）与起始时刻（毫秒）
    private var _durationMs: Int64 = 5000
    private var _startedAtMs: Int64 = 0

    // 单调递增的"轮次"标记 —— 每次 showUndo 自增，供组件感知"换了一条 toast"
    private var _epoch: Int64 = 0

    // 撤销回调（用户点 Undo 时触发）
    private var _onUndo: () -> Unit = { => }

    // 提交回调（倒计时到点 / 主动 dismiss 时触发，语义=不撤销即提交）
    private var _onCommit: () -> Unit = { => }

    // 消失回调（无论 undo 还是 commit，toast 退场后都会调一次）
    private var _onDismiss: () -> Unit = { => }

    // TC-0015 修复：UndoToast 组件在 aboutToAppear 时注册的"呈现器"——收到
    // showUndo/triggerUndo/finishAsCommit 时同步直调，驱动 bindContentCover 模态层
    // 呈现/关闭，不依赖调用方页面是否与该组件共享同一组合树。
    // 参数：(visible, text, actionText, title, iconRes, iconPixelMap)。
    // visible=false 时表示应关闭当前 toast（此时其余参数仍按当前状态传入，
    // presenter 端不使用，仅 visible 生效）。F-13 追加 title/iconRes 两个槽位，
    // F-14 追加 iconPixelMap 第 6 槽位，形状同 DialogService.cj 的多槽位
    // presenter 先例。showProgress/showAction 不走这条推送通道——presenter
    // 侧（UndoToast 组件）在收到推送的同一同步调用帧内直接调
    // getShowProgress()/getShowAction() 读取（此时 showUndo() 已把两者写入
    // 服务状态），语义与随本元组推送等价，见 UndoToast.cj presentAsContentCover。
    private var _presenter: Option<(Bool, String, String, String, ?ResourceStr, ?PixelMap) -> Unit> =
        None<(Bool, String, String, String, ?ResourceStr, ?PixelMap) -> Unit>

    /**
     * 当前毫秒时间戳（单调用途足够：用系统墙钟差值算剩余时间）
     */
    private func nowMs(): Int64 {
        return DateTime.now().toUnixTimeStamp().toMilliseconds()
    }

    /**
     * UndoToast.aboutToAppear 注册自身的 bindContentCover 模态层呈现函数。
     */
    public func setPresenter(presenter: (Bool, String, String, String, ?ResourceStr, ?PixelMap) -> Unit): Unit {
        this._presenter = Some(presenter)
    }

    /**
     * UndoToast.aboutToDisappear 注销，避免持有已销毁组件的闭包。
     */
    public func clearPresenter(): Unit {
        this._presenter = None<(Bool, String, String, String, ?ResourceStr, ?PixelMap) -> Unit>
    }

    private func notifyPresenter(visible: Bool): Unit {
        match (this._presenter) {
            case Some(present) =>
                present(visible, this._text, this._actionText, this._title, this._iconRes, this._iconPixelMap)
            case None =>
                // 尚无 presenter 注册（组件未挂载）：仅记录，供排查；不静默假装成功。
                Hilog.info(0, "CjTelegram", "[UndoToastService] notifyPresenter dropped: no presenter registered")
        }
    }

    /**
     * 显示一条 undo toast。
     *
     * @param text       提示文案，如 "Chat archived"
     * @param actionText 撤销按钮文字，默认 "Undo"
     * @param durationMs 自动提交前的倒计时（毫秒），默认 5000；persistent=true 时不生效
     * @param title        可选标题（如 "Premium Required"），空串=不渲染标题行（F-13）
     * @param iconRes      可选 leading 图标资源（@r(app.media.xxx)），None=不渲染图标（F-13b）
     * @param persistent   是否不自动消失（对应源侧 timeout: nil），默认 false（F-13）
     * @param showProgress 是否显示线性倒计时进度条，默认 true（F-14，对位源侧逐 content 决策）
     * @param showAction   是否显示动作按钮，默认 true（F-14，对位源侧 displayUndo）
     * @param iconPixelMap 可选并列图标槽（Lottie 渲染出的成品 PixelMap）；当前唯一调用点
     *                     `anim_linkcopied`（pages/SelectivePrivacySettingsPage.cj）R-140 起
     *                     已确认不做颜色替换，原样渲染，此处不再统称"挖空改色产物"，
     *                     None=不占用（F-14，与 iconRes 互斥优先）
     * @param iconFrames         可选帧序列图标槽（renderTgs 全帧栅格化产物），空数组=不占用；
     *                           非空时渲染优先级高于 iconPixelMap（M2a，对位源侧 AnimationNode
     *                           播放而非取末帧静态展示）
     * @param iconFrameDurationMs 帧间隔（毫秒），默认 17（约 60fps），随 iconFrames 一起生效（M2a）
     * @param onUndo     用户点撤销时调用
     * @param onCommit   倒计时结束未撤销（=提交）时调用
     * @param onDismiss  toast 退场（无论哪条路径）后调用
     */
    public func showUndo(
        text: String,
        title!: String = "",
        actionText!: String = "Undo",
        durationMs!: Int64 = 5000,
        iconRes!: ?ResourceStr = None<ResourceStr>,
        persistent!: Bool = false,
        showProgress!: Bool = true,
        showAction!: Bool = true,
        iconPixelMap!: ?PixelMap = None<PixelMap>,
        iconFrames!: Array<PixelMap> = Array<PixelMap>(),
        iconFrameDurationMs!: Int32 = 17,
        onUndo!: () -> Unit = { => },
        onCommit!: () -> Unit = { => },
        onDismiss!: () -> Unit = { => }
    ): Unit {
        // 若已有 toast 在显示，先把它按 commit 收口（不撤销即提交）
        if (this._showing) {
            this.finishAsCommit()
        }
        this._text = text
        this._title = title
        this._actionText = actionText
        this._iconRes = iconRes
        this._persistent = persistent
        this._showProgress = showProgress
        this._showAction = showAction
        this._iconPixelMap = iconPixelMap
        this._iconFrames = iconFrames
        this._iconFrameDurationMs = iconFrameDurationMs
        // F-13：persistent 分支不套用"durationMs<=0 ⇒ 5000"重写——该分支不依赖
        // durationMs 触发自动消失（isExpired() 已按 _persistent 短路），非 persistent
        // 分支保留原有重写逻辑。
        this._durationMs = if (this._persistent) {
            durationMs
        } else if (durationMs > 0) {
            durationMs
        } else {
            5000
        }
        this._startedAtMs = this.nowMs()
        this._onUndo = onUndo
        this._onCommit = onCommit
        this._onDismiss = onDismiss
        this._epoch = this._epoch + 1
        this._showing = true
        Hilog.info(0, "CjTelegram",
            "[UndoToastService] showUndo text=" + text + " durationMs=" + this._durationMs.toString())
        // TC-0015: 立即同步通知 presenter 弹出 toast（bindContentCover 模态层，
        // 不依赖调用方页面是否挂载了 UndoToast() 组件本身，解决 routerPush 页面遮挡问题）。
        this.notifyPresenter(true)
        // iOS UndoOverlayController 的超时提交由控制器自身计时，不依赖某个页面是否在
        // 渲染。组件 tick 只挂在 MainTabPage 上，此处补一个服务级兜底：到点后若仍是
        // 同一轮 toast 且未收口，就按 commit 收口（finishAsCommit 以 _showing 防重入）。
        if (!this._persistent) {
            let epoch = this._epoch
            let waitMs = this._durationMs + 400
            spawn {
                sleep(Duration.millisecond * waitMs)
                launch {
                    if (this._epoch == epoch && this.isExpired()) {
                        Hilog.info(0, "CjTelegram", "[UndoToastService] fallback commit epoch=${epoch}")
                        this.finishAsCommit()
                    }
                }
            }
        }
    }

    // ==================== 状态查询（供 UndoToast 组件 tick 轮询）====================

    public func isShowing(): Bool {
        return this._showing
    }

    public func getText(): String {
        return this._text
    }

    /**
     * 可选加粗标题行；非空时 UndoToast 组件应在正文上方渲染一行加粗标题
     * （TC-0133 §6.3/§6.12 Premium 付费墙提示场景）。F-13：title/iconRes/persistent
     * 只读访问器，形状照 getText()/getActionText() 同型。
     */
    public func getTitle(): String {
        return this._title
    }

    public func getActionText(): String {
        return this._actionText
    }

    public func getIconRes(): ?ResourceStr {
        return this._iconRes
    }

    public func isPersistent(): Bool {
        return this._persistent
    }

    // F-14：showProgress/showAction/iconPixelMap 只读访问器，形状照
    // getTitle()/getIconRes() 同型。
    public func getShowProgress(): Bool {
        return this._showProgress
    }

    public func getShowAction(): Bool {
        return this._showAction
    }

    public func getIconPixelMap(): ?PixelMap {
        return this._iconPixelMap
    }

    // M2a：帧序列图标槽只读访问器，形状照 getIconPixelMap() 同型。
    public func getIconFrames(): Array<PixelMap> {
        return this._iconFrames
    }

    public func getIconFrameDurationMs(): Int32 {
        return this._iconFrameDurationMs
    }

    public func getDurationMs(): Int64 {
        return this._durationMs
    }

    public func getEpoch(): Int64 {
        return this._epoch
    }

    /**
     * 剩余毫秒（已过时间从总时长里扣）；不显示时返回 0。
     */
    public func remainingMs(): Int64 {
        if (!this._showing) {
            return 0
        }
        let elapsed = this.nowMs() - this._startedAtMs
        let remain = this._durationMs - elapsed
        if (remain < 0) {
            return 0
        }
        return remain
    }

    /**
     * 进度比例 [0.0, 1.0]：1.0=刚弹出，0.0=即将提交。供进度条渲染。
     * F-14：persistent 短路——源侧 `timeout: nil` 表示"不启动倒计时"，不是
     * "倒计时走完但不退场"。返回 1.0（而非 0.0）让万一仍被渲染的进度条呈现
     * "满格不动"而非"空格"，与"没有在倒数"一致。isExpired() 的
     * `!this._persistent` 短路不受影响，两处各自独立短路。
     */
    public func remainingFraction(): Float64 {
        if (!this._showing || this._durationMs <= 0) {
            return 0.0
        }
        if (this._persistent) {
            return 1.0
        }
        let frac = Float64(this.remainingMs()) / Float64(this._durationMs)
        if (frac < 0.0) {
            return 0.0
        }
        if (frac > 1.0) {
            return 1.0
        }
        return frac
    }

    /**
     * 倒计时是否已耗尽（供组件 tick 判断该自动 commit）。
     * F-13：persistent 恒为 false——"不启动自动消失计时"落在这一处短路，
     * 组件轮询 isExpired() 永远拿不到 true，不会触发 finishAsCommit()。
     */
    public func isExpired(): Bool {
        return this._showing && !this._persistent && this.remainingMs() <= 0
    }

    // ==================== 收口路径 ====================

    private func clearState(): Unit {
        this._showing = false
        this._onUndo = { => }
        this._onCommit = { => }
        this._onDismiss = { => }
    }

    /**
     * 用户点 Undo：调 onUndo + 立即退场。
     */
    public func triggerUndo(): Unit {
        if (!this._showing) {
            return
        }
        let undoCb = this._onUndo
        let dismissCb = this._onDismiss
        this.clearState()
        this.notifyPresenter(false)
        undoCb()
        dismissCb()
        Hilog.info(0, "CjTelegram", "[UndoToastService] triggerUndo")
    }

    /**
     * 倒计时到点（或被新 toast 顶替）：调 onCommit + 退场。
     */
    public func finishAsCommit(): Unit {
        if (!this._showing) {
            return
        }
        let commitCb = this._onCommit
        let dismissCb = this._onDismiss
        this.clearState()
        this.notifyPresenter(false)
        commitCb()
        dismissCb()
        Hilog.info(0, "CjTelegram", "[UndoToastService] finishAsCommit")
    }

    /**
     * 主动消失：语义同 commit（与 iOS 一致：不撤销即提交）。
     */
    public func dismiss(): Unit {
        this.finishAsCommit()
    }
}
