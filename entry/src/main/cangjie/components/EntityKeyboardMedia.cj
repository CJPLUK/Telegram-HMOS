package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import kit.ImageKit.PixelMap
import kit.PerformanceAnalysisKit.Hilog
import std.collection.{ArrayList, HashSet, HashMap}
import std.sync.*
import std.time.*
import ohos_app_cangjie_entry.app.getAppState
import ohos_app_cangjie_entry.services.{
    StreamingLottiePlayer, StreamingVideoStickerPlayer,
    openAnimatedStickerFileStream, openVideoStickerFileStream,
    setKeyboardFrameClockStreamCount,
    CachedAnimationPlayer, openCachedAnimationPlayer, requestAnimationCacheBuild,
    resolveCustomEmojiDocument, ensureStickerLocalFile, storeStickerStaticFrame,
    StickerItem, loadStickerStaticFrameCached
}

/**
 * 表情/贴纸键盘的媒体加载调度器。
 *
 * 改成 LazyForEach 之后，一屏之外的格子确实不再建组件了，但**滚动本身**仍然
 * 很涩：每个新出现的 StickerGridCell / CustomEmojiImage 都各自 `spawn` 一条
 * 协程，协程里是 `FileIo.mkdir` / `FileIo.access`，未命中缓存时还会走
 * `downloadDocument` 这种阻塞式 RPC。用户快速划过几百个格子，就等于在一两秒内
 * 投放几百条阻塞协程，把运行时的工作线程占满 —— UI 线程随后拿不到调度机会。
 *
 * iOS 侧对应的是 MediaBox 的取数队列与 DirectAnimatedStickerNode 的
 * user-interactive 队列：**并发有界，且离屏订阅会被 dispose**。这里做同样的事：
 *   - 固定数量的 worker，永远不会因为格子多而增加；
 *   - LIFO 出队 —— 用户刚滚到的那一屏优先于早已划过去的；
 *   - 队列上限，超出即丢弃最旧的请求（对应的格子基本都离屏了）；
 *   - 格子 disappear 时 cancel，尚未开工的任务直接跳过。
 */
// 6 而不是 3：首开一个精选包时，每个格子都要「解析 RPC → 下载 → 解码」，
// 前两步是网络等待，3 条 worker 时格子肉眼可见地挨个蹦（iOS 的 MediaBox
// 对同包资源高并发预取）。解码侧另有 2 槽渲染闸兜底，worker 翻倍不会
// 把 CPU 打爆，只是让网络等待重叠起来。
private let KEYBOARD_MEDIA_WORKERS: Int64 = 6
// 160：拉驱动一次可提交 ~90 个起播任务，48 的上限会把最旧 46 个直接丢弃 ——
// 被丢任务的格子 loadStarted 永远卡 true，从此对一切驱动免疫（真机漏斗：
// pullStart 175 → try 95 的缺口）。LIFO 语义不变，仍是最新优先。
private let KEYBOARD_MEDIA_QUEUE_LIMIT: Int64 = 160

class KeyboardMediaTask {
    let token: Int64
    let work: () -> Unit

    init(token: Int64, work: () -> Unit) {
        this.token = token
        this.work = work
    }
}

public class KeyboardMediaScheduler {
    private let monitor: Monitor = Monitor()
    private var pending: ArrayList<KeyboardMediaTask> = ArrayList<KeyboardMediaTask>()
    private var cancelled: HashSet<Int64> = HashSet<Int64>()
    private var nextToken: Int64 = 1
    private var workersStarted: Bool = false
    private var droppedCount: Int64 = 0

    public init() {}

    /**
     * 登记一个加载任务，返回可用于取消的 token。
     * work 在 worker 协程里执行，内部若要写 @State 仍需自行 launch 回 UI 线程。
     */
    public func submit(work: () -> Unit): Int64 {
        return this.submitAt(work, false)
    }

    /**
     * 插队车道：起播任务用。首次驶入新窗口时，池的几十条起播若排在
     * 阶段二预取的数百个下载/解码任务后面，测量窗内一帧都流不出来
     //（真机：一遍冷窗恒 0、二遍预取排空后 4~14 —— 签名实锤）。
     */
    public func submitUrgent(work: () -> Unit): Int64 {
        return this.submitAt(work, true)
    }

    private func submitAt(work: () -> Unit, front: Bool): Int64 {
        var token: Int64 = 0
        var shouldStartWorkers = false
        synchronized(this.monitor) {
            token = this.nextToken
            this.nextToken = token + 1
            if (front) {
                this.pending.add(KeyboardMediaTask(token, work), at: 0)
            } else {
                this.pending.add(KeyboardMediaTask(token, work))
            }
            while (this.pending.size > KEYBOARD_MEDIA_QUEUE_LIMIT) {
                let dropped = this.pending.remove(at: 0)
                let _ = this.cancelled.add(dropped.token)
                this.droppedCount = this.droppedCount + 1
            }
            if (!this.workersStarted) {
                this.workersStarted = true
                shouldStartWorkers = true
            }
            this.monitor.notifyAll()
        }
        if (shouldStartWorkers) {
            this.startWorkers()
        }
        return token
    }

    public func cancel(token: Int64): Unit {
        if (token <= 0) { return }
        synchronized(this.monitor) {
            let _ = this.cancelled.add(token)
            this.pending.removeIf({ task: KeyboardMediaTask => task.token == token })
        }
    }

    private func startWorkers(): Unit {
        var index: Int64 = 0
        while (index < KEYBOARD_MEDIA_WORKERS) {
            let _ = spawn { this.workerLoop() }
            index = index + 1
        }
        Hilog.info(0, "CjTelegram",
            "[KeyboardMedia] workers started count=${KEYBOARD_MEDIA_WORKERS}")
    }

    /** LIFO：最后登记的（也就是用户刚滚到的）先做。 */
    private func takeNext(): Option<KeyboardMediaTask> {
        synchronized(this.monitor) {
            while (this.pending.size == 0) {
                let _ = this.monitor.wait(timeout: Duration.millisecond * 200)
            }
            let last = this.pending.size - 1
            let task = this.pending.remove(at: last)
            if (this.cancelled.contains(task.token)) {
                let _ = this.cancelled.remove(task.token)
                return None<KeyboardMediaTask>
            }
            return Some(task)
        }
    }

    private func workerLoop(): Unit {
        while (true) {
            match (this.takeNext()) {
                case Some(task) =>
                    try {
                        task.work()
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[KeyboardMedia] task failed: ${e}")
                    }
                case None => ()
            }
        }
    }
}

private let keyboardMediaSchedulerInstance: KeyboardMediaScheduler = KeyboardMediaScheduler()

public func getKeyboardMediaScheduler(): KeyboardMediaScheduler {
    return keyboardMediaSchedulerInstance
}

// ============================================================================
// 键盘格子的动画播放
// ============================================================================
//
// 排查「面板很卡 / 闪退」时在真机 hilog 里抓到的直接证据：
//
//   [TelegramLottieNative] stream opened frames=180 fps=60.000000 key=stickerstatic_...
//
// CustomEmojiImage 在 animationEpoch >= 0 时会调 ensureAnimatedStickerDocumentLoaded，
// 那条路径是 renderTgs(..., ANIMATED_EMOJI_SIZE=384) —— 把整支动画的 **每一帧**
// 都光栅成 PixelMap 常驻内存。一枚 180 帧的自定义表情就是
// 180 × 384 × 384 × 4B ≈ 106MB；「最近使用」里十几枚同时可见，直接把内存打爆。
// 再叠加 34ms 的全局 epoch 定时器逐帧换图，卡顿与闪退都源于此。
//
// iOS 从来不这么做：MultiAnimationRenderer 是按需解码 + 共享渲染，且只对可见项
// 播放。这里的等价物是：**表现帧恒定走静态缓存，动画走流式解码器，且并发有界**。
// 超出配额的格子保持代表帧不动，与 iOS 在低端机上的降级表现一致。

/**
 * 同时播放的格子上限。
 *
 * 14 那版的依据是上面那条**已经废弃**的路径（384px 全帧预光栅，一枚 ≈106MB）。
 * 现行流式解码每格只持有 current/next 两帧窗口（~100KB@105px raster）+ 一个
 * rlottie 会话，48 格 ≈ 5MB 像素缓冲 —— 内存不再是约束。iOS 的
 * EmojiPagerContentComponent 是**全部可见 itemLayer 都播**（isContentInFocus
 * 是键盘级判据，不是格子级配额），一屏 8×6 = 48 格全动。配额取 48 对齐它；
 * 解码吞吐不够时由帧钟的跳帧机制均匀降各格帧率，不是冻住其中 34 格。
 */
// 96：doc 池的可见集 ≈ 网格 8×8 + 导航 20 + trending 8 ≈ 70+，48 会让后到的
// 文档挂在等待队列。cached 流的边际成本只有 inflate + 28KB 状态缓冲，96 条
// 完全无压力；重资源的 live 解码另有 8 条独立限额把关。
private let KEYBOARD_PLAYBACK_SLOTS: Int64 = 96

/**
 * 顶部包导航条的**独立**播放配额。
 *
 * 导航封面此前和主网格共用那 14 个槽：一屏网格约 20 个格子 + 导航条约 8 个封面，
 * 28 个抢 14 个，谁先到谁播。表现是导航条动不动就整条静止——双端对照里
 * sticker_nav_motion 在 0.0 / 1.235 / 4.788 / 6.141 之间乱跳，iOS 稳定 8.4。
 *
 * iOS 没有这个竞争：EntityKeyboardAnimationTopPanelComponent 的顶部项与网格项
 * 同属一个 MultiAnimationRenderer，共享一条 displayLink，不存在配额。
 * 这里给导航条切一份自己的池——封面只有 36pt、总数十来个，代价很低，
 * 但能保证它不会被网格饿死。
 */
private let KEYBOARD_NAV_PLAYBACK_SLOTS: Int64 = 24

/**
 * GIF 网格的并发播放上限，**独立于贴纸**。9 ≈ 面板里能同时看见的格子数
 * （3 列 × 3 行），也就是「可见的都在播」，与 iOS 一致。
 *
 * 为什么必须有上限：GIF 只能用 ArkUI 的 Video 节点（native 解码器是 libvpx，
 * 只吃 WebM，啃不动 GIF 的 MP4/H.264），而 Video 是完整播放器。真机 hilog：
 *
 *   ScopedTimer:    name: CreatePlayer, time-taking: 5002 ms
 *   MediaReplyStub: timeout 5000 Ms for get subSystemAbility_
 *   PlayerImpl:     failed to init PlayerImpl
 *
 * CreatePlayer 是一次**同步 IPC**，在主线程上跑；媒体服务给不出实例时它会卡满
 * 5 秒然后超时，直接 THREAD_BLOCK_3S 白屏被杀。修前 16 次快甩内稳定复现，
 * 判定性实验（完全禁用 Video → 60 次快甩零崩溃）确认元凶就是 Video 节点本身。
 *
 * 注意别被 fault dump 里的 ArkUIVideoUpdateMediaPlayer 带偏——它只是**承载**
 * CreatePlayer 的那个任务，队列里一堆 ArkUIVideoCurrentTimeChange 也只是相关，
 * 不是因果。我曾据此写下「元凶是 Immediate 任务饿死了 Low 任务」，是错的。
 *
 * iOS 不需要这个上限：GifVideoLayer 是被动的 AVSampleBufferDisplayLayer，
 * 全部 target 共用 BatchVideoRenderingContext 里的一条 displayLink，
 * 无论几个格子在播，主线程每帧只被唤醒一次。ArkUI 没有等价物，只能限量 + 门控。
 */
private let KEYBOARD_GIF_PLAYBACK_SLOTS: Int64 = 9

public class KeyboardPlaybackLimiter {
    private let monitor: Monitor = Monitor()
    private var used: Int64 = 0
    /**
     * 拿不到槽的格子登记在这里，等别人释放时叫醒一个。
     *
     * 没有这个队列时，快甩会留下一个很难看的稳定态：滚动中先到的格子占满配额，
     * 它们随后滚出可视区释放槽位，而**此刻真正可见的那批格子早就被拒过一次、
     * 再也不会重试**，于是停下来满屏都是静止的首帧。
     * 真机实测：一轮压力滚动 76 次起播、27 次被拒，停下后帧间差只有 1.2
     *（iOS 同场景 11.5）。
     */
    private var waiters: ArrayList<() -> Unit> = ArrayList<() -> Unit>()

    private let capacity: Int64

    public init() {
        this.capacity = KEYBOARD_PLAYBACK_SLOTS
    }

    public init(capacity: Int64) {
        this.capacity = capacity
    }

    public func acquire(): Bool {
        synchronized(this.monitor) {
            if (this.used >= this.capacity) { return false }
            this.used = this.used + 1
            return true
        }
    }

    /** 拿不到槽时登记重试回调；回调里要自己确认格子仍然需要播放。 */
    public func acquireOrWait(retry: () -> Unit): Bool {
        synchronized(this.monitor) {
            if (this.used < this.capacity) {
                this.used = this.used + 1
                return true
            }
            Hilog.info(0, "CjTelegram",
                "[SlotDiag] reject used=${this.used}/${this.capacity} waiters=${this.waiters.size}")
            // 只留最近的一批等待者：更早登记的多半已经滚出可视区
            while (this.waiters.size >= this.capacity * 2) {
                this.waiters.remove(at: 0)
            }
            this.waiters.add(retry)
            return false
        }
    }

    public func release(): Unit {
        var next = None<() -> Unit>
        synchronized(this.monitor) {
            if (this.used > 0) { this.used = this.used - 1 }
            // 后进先出：最后登记的最可能还在屏幕上
            if (this.waiters.size > 0) {
                next = Some(this.waiters.remove(at: this.waiters.size - 1))
            }
        }
        match (next) {
            case Some(callback) => callback()
            case None => ()
        }
    }

    public func inUse(): Int64 {
        synchronized(this.monitor) { return this.used }
    }
}

private let keyboardPlaybackLimiterInstance: KeyboardPlaybackLimiter = KeyboardPlaybackLimiter()

public func getKeyboardPlaybackLimiter(): KeyboardPlaybackLimiter {
    return keyboardPlaybackLimiterInstance
}

/**
 * 聊天页动画贴纸的独立播放配额。
 *
 * 贴纸气泡 160vp 高，一屏最多 4~5 张整贴纸 —— 6 个槽位覆盖一屏 + 边缘半张。
 * 不与键盘面板共享（14 槽）：聊天与键盘可以同屏（键盘展开时上方还露着消息），
 * 共享一份会互相饿死。等待队列语义与键盘一致：拿不到槽的挂起，释放时唤醒。
 */
private let CHAT_STICKER_PLAYBACK_SLOTS: Int64 = 6

/**
 * 实时 rlottie 解码的并发上限（独立于播放槽）。
 *
 * 内存取证（2026-08-24 18:0x）：48 个格子各持一个活 rlottie 会话时，复杂 tgs
 * 的合成树每个 2~10MB，叠起来 +400MB RSS，滚动一冲就 OOM 闪退。iOS 从不
 * 同时持有几十个活合成 —— AnimationCache 播放的会话持有量是**零**。
 * 所以：缓存命中的流不受此限（便宜）；实时解码只放 8 条（过渡期，其余格子
 * 保持静帧等缓存建成）。
 */
// 8：试过 32（72px 光栅后单会话内存小了），滚动压力下仍然复现「重 GC 后
// 进程死亡」——live rlottie 的分配速率才是死因，不是驻留量。8 是实测稳定值；
// 过渡期覆盖不足由「加速 AnimationCache 构建」补（见 buildAnimationCacheFile
// 的放宽门槛），建成后全部走 cached，live 只剩新素材的首次过渡。
private let LIVE_DECODE_SLOTS: Int64 = 8

private let liveDecodeLimiterInstance: KeyboardPlaybackLimiter =
    KeyboardPlaybackLimiter(LIVE_DECODE_SLOTS)

public func getLiveDecodeLimiter(): KeyboardPlaybackLimiter {
    return liveDecodeLimiterInstance
}

private let chatStickerPlaybackLimiterInstance: KeyboardPlaybackLimiter =
    KeyboardPlaybackLimiter(CHAT_STICKER_PLAYBACK_SLOTS)

public func getChatStickerPlaybackLimiter(): KeyboardPlaybackLimiter {
    return chatStickerPlaybackLimiterInstance
}

// ============================================================================
// 共享帧钟 —— iOS MultiAnimationRenderer 的 ArkUI 对位
// ============================================================================
//
// 改造前每个在播格子各持有一只 Timer.repeat(33ms)：满负荷 14（网格）+ 10（导航）
// = 24 只定时器，每帧各自 `spawn(UIThread)` 提交一个 UI 任务、再各自 `spawn` 一个
// prepare 协程 —— 每秒 ~720 个 UI 任务 + ~720 个协程。UI 主循环被这批小任务灌爆，
// 布局和滚动手势拿不到调度机会，表现就是「面板动图一多就整体卡」。
//
// iOS 的做法（MultiAnimationRendererImpl）：**一个 displaylink 驱动所有 itemLayer**，
// 帧从后台解码，主线程一次性把这一拍所有层的 contents 换掉。这里照搬这个形状：
//   - 全局一只 33ms Timer（面板收起、无在播格子时自动停）；
//   - 每拍集中推进所有流（advanceTo 只是取已备好的帧，互斥锁开销级别）；
//   - 新帧合并成一批，**整拍只发一个** spawn(UIThread)；
//   - prepare（真正的解码）走两条专用 worker 协程，同一流未完成不重复排队。
//
// 顺带修一个正确性 bug：旧代码把 60fps 的 tgs 素材 clamp 到 33ms 后仍按 +1 帧
// 步进，**播放速度只剩一半**（观感又慢又卡）。现在按「步长 = round(拍长/帧长)」
// 跳帧推进，慢素材则按拍数攒够再走 —— 各种源帧率都保持真实速度。
// 钟本体走 16ms（60fps 上限）。每条流再按自己的 targetTickMs 节流：
// 键盘格子/聊天贴纸 33ms（30fps，解码量减半观感一致），聊天大表情 16ms
//（60fps——tap 重播是主角动画，iOS 全速）。钟自身每拍只是遍历 ≤24 条流
// 加个累计器，开销可忽略；真正的解码在流按预算放行后才发生。
private let KEYBOARD_CLOCK_TICK_MS: Int64 = 16

/** 默认节流目标：30fps。 */
public let KEYBOARD_STREAM_TICK_MS: Int64 = 33

public class KeyboardFrameClock {
    private let monitor: Monitor = Monitor()
    private var timer: Option<Timer> = None<Timer>
    /**
     * 上一拍的墙钟毫秒。tick 的时间记账必须用**真实流逝时间**，不能按名义
     * 16ms 数拍子：系统定时器的实际周期普遍比名义值粗（负载下 20ms+ 常见），
     * 名义记账会让所有动画等比变慢 —— 「比 iOS 播得慢」的两个根因之一。
     * iOS 的 displaylink 回调自带真实 timestamp，这里用 DateTime 差值对位。
     */
    private var lastTickAtMs: Int64 = 0
    /**
     * 键盘面板代际。面板挂载时领新代，流注册时盖当前代的章；面板卸载时只收割
     * **不高于自己代**的键盘流。直接全量收割会翻车：ArkUI 重建面板（切页签 /
     * 条件渲染）时旧实例的 aboutToDisappear 晚于新实例挂载，一刀把新面板的流
     * 全杀了 —— 表现为「面板打开但全部不动」。
     */
    private var keyboardEpoch: Int64 = 0
    private let streams: ArrayList<KeyboardAnimationStream> = ArrayList<KeyboardAnimationStream>()
    private var applyScheduled: Bool = false
    // 待上屏批次：平行数组 + 线性去重（在播上限 24，扫一遍可忽略）。
    private let pendingStreams: ArrayList<KeyboardAnimationStream> = ArrayList<KeyboardAnimationStream>()
    private let pendingFrames: ArrayList<PixelMap> = ArrayList<PixelMap>()
    // 解码队列（LIFO）：prepare 是真正花时间的活，放两条专用 worker 上做。
    private let decodeMonitor: Monitor = Monitor()
    private let decodeQueue: ArrayList<KeyboardAnimationStream> = ArrayList<KeyboardAnimationStream>()
    private var decodeWorkersStarted: Bool = false
    // ---- 诊断计数（每 ~5s 打一行）----
    private var statTicks: Int64 = 0
    private var statAdvances: Int64 = 0
    private var statMisses: Int64 = 0
    private var statApplies: Int64 = 0
    private var statDelivered: Int64 = 0

    public init() {}

    /** 当前挂在钟上的流数。预取的首帧预渲用它判断「前台是否空闲」。 */
    public func activeStreamCount(): Int64 {
        synchronized(this.monitor) { return Int64(this.streams.size) }
    }

    /**
     * 面板关闭时收割全部键盘流。R-146：本版本 ArkUI 拆面板不给格子任何销毁
     * 回调，僵尸流会挂在钟上空转（占播放槽、卡 streamCount>0 → 缓存构建器
     * 永远等不到空闲）。聊天页的流（chat 配额 / 领养模式）不在收割范围。
     */
    public func stopKeyboardStreams(upToEpoch: Int64): Unit {
        let snapshot = ArrayList<KeyboardAnimationStream>()
        synchronized(this.monitor) {
            for (stream in this.streams) { snapshot.add(stream) }
        }
        for (stream in snapshot) {
            if (!stream.isChatScoped() && stream.clockEpoch <= upToEpoch) { stream.stop() }
        }
    }

    /**
     * 推送给 services 的是**键盘域**流数（AnimationCache 构建器的空闲判据）。
     * 聊天页常驻的贴纸/大表情流不算：真机实测一条聊天流就能把构建器闸死，
     * 20 个排队任务一个都不出活。
     */
    private func pushKeyboardScopedCount(): Unit {
        var keyboardCount: Int64 = 0
        for (stream in this.streams) {
            if (!stream.isChatScoped()) { keyboardCount = keyboardCount + 1 }
        }
        setKeyboardFrameClockStreamCount(keyboardCount)
    }

    /** 面板挂载时调用：领一个新代，之后注册的流都属于这一代。 */
    public func bumpKeyboardEpoch(): Int64 {
        synchronized(this.monitor) {
            this.keyboardEpoch = this.keyboardEpoch + 1
            return this.keyboardEpoch
        }
    }

    public func register(stream: KeyboardAnimationStream): Unit {
        var startTimer = false
        synchronized(this.monitor) {
            stream.clockEpoch = this.keyboardEpoch
            this.streams.add(stream)
            this.pushKeyboardScopedCount()
            match (this.timer) {
                case Some(_) => ()
                case None => startTimer = true
            }
        }
        this.ensureDecodeWorkers()
        if (startTimer) {
            synchronized(this.monitor) {
                match (this.timer) {
                    case Some(_) => ()
                    case None =>
                        this.lastTickAtMs = 0
                        this.timer = Some(Timer.repeat(
                            Duration.millisecond * KEYBOARD_CLOCK_TICK_MS,
                            Duration.millisecond * KEYBOARD_CLOCK_TICK_MS,
                            { => this.tick() },
                            style: CatchupStyle.Skip
                        ))
                }
            }
        }
    }

    public func unregister(stream: KeyboardAnimationStream): Unit {
        synchronized(this.monitor) {
            this.streams.removeIf({ existing: KeyboardAnimationStream => refEq(existing, stream) })
            this.pushKeyboardScopedCount()
            var index = 0
            while (index < this.pendingStreams.size) {
                if (refEq(this.pendingStreams[index], stream)) {
                    let _ = this.pendingStreams.remove(at: index)
                    let _ = this.pendingFrames.remove(at: index)
                } else {
                    index = index + 1
                }
            }
            // 最后一个流走了就停表：面板收起后不留 30fps 的空转心跳。
            if (this.streams.size == 0) {
                match (this.timer) {
                    case Some(value) =>
                        value.cancel()
                        this.timer = None<Timer>
                    case None => ()
                }
            }
        }
        synchronized(this.decodeMonitor) {
            this.decodeQueue.removeIf({ existing: KeyboardAnimationStream => refEq(existing, stream) })
        }
    }

    private func tick(): Unit {
        let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        var elapsedMs = if (this.lastTickAtMs == 0) {
            KEYBOARD_CLOCK_TICK_MS
        } else {
            nowMs - this.lastTickAtMs
        }
        this.lastTickAtMs = nowMs
        // 时钟跳变 / 后台恢复的防护：单拍最多按 100ms 记，配合流侧的欠账封顶。
        if (elapsedMs < 1) { elapsedMs = 1 }
        if (elapsedMs > 100) { elapsedMs = 100 }
        let snapshot = ArrayList<KeyboardAnimationStream>()
        synchronized(this.monitor) {
            for (stream in this.streams) { snapshot.add(stream) }
        }
        if (snapshot.size == 0) { return }
        this.statTicks = this.statTicks + 1
        for (stream in snapshot) {
            match (stream.clockTick(elapsedMs)) {
                case Some(frame) =>
                    this.statAdvances = this.statAdvances + 1
                    this.addPending(stream, frame)
                case None => this.statMisses = this.statMisses + 1
            }
            // prepare 无条件补排：流内部对「已备好」是 O(1) 早退，排重靠 prepareQueued。
            this.enqueuePrepare(stream)
        }
        this.scheduleApply()
        if (this.statTicks % 300 == 0) {
            Hilog.info(0, "CjTelegram",
                "[FrameClock] ticks=${this.statTicks} streams=${snapshot.size} adv=${this.statAdvances} miss=${this.statMisses} applies=${this.statApplies} delivered=${this.statDelivered}")
        }
    }

    private func addPending(stream: KeyboardAnimationStream, frame: PixelMap): Unit {
        synchronized(this.monitor) {
            var index = 0
            while (index < this.pendingStreams.size) {
                if (refEq(this.pendingStreams[index], stream)) {
                    // 上一批还没上屏就来了新帧：只留最新的一帧。
                    this.pendingFrames[index] = frame
                    return
                }
                index = index + 1
            }
            this.pendingStreams.add(stream)
            this.pendingFrames.add(frame)
        }
    }

    /** 整拍一个 UI 任务，把这一批帧一次写完 —— 这是本次改造的核心收益。 */
    private func scheduleApply(): Unit {
        var run = false
        synchronized(this.monitor) {
            if (!this.applyScheduled && this.pendingStreams.size > 0) {
                this.applyScheduled = true
                run = true
            }
        }
        if (!run) { return }
        spawn(UIThread) {
            =>
            let batchStreams = ArrayList<KeyboardAnimationStream>()
            let batchFrames = ArrayList<PixelMap>()
            synchronized(this.monitor) {
                for (stream in this.pendingStreams) { batchStreams.add(stream) }
                for (frame in this.pendingFrames) { batchFrames.add(frame) }
                this.pendingStreams.clear()
                this.pendingFrames.clear()
                this.applyScheduled = false
            }
            this.statApplies = this.statApplies + 1
            var index = 0
            while (index < batchStreams.size) {
                batchStreams[index].deliverUi(batchFrames[index])
                this.statDelivered = this.statDelivered + 1
                index = index + 1
            }
        }
    }

    private func enqueuePrepare(stream: KeyboardAnimationStream): Unit {
        synchronized(this.decodeMonitor) {
            if (stream.prepareQueued) { return }
            stream.prepareQueued = true
            this.decodeQueue.add(stream)
            this.decodeMonitor.notifyAll()
        }
    }

    private func ensureDecodeWorkers(): Unit {
        var start = false
        synchronized(this.decodeMonitor) {
            if (!this.decodeWorkersStarted) {
                this.decodeWorkersStarted = true
                start = true
            }
        }
        if (!start) { return }
        var index = 0
        // 4 条：与渲染闸（streamingLottieRenderSlots=4）对齐。放开 48 播放槽后
        // 解码需求上限 ~1400 帧/s，2 条 worker 会把所有格子一起压到个位数帧率。
        while (index < 4) {
            let _ = spawn { this.decodeLoop() }
            index = index + 1
        }
    }

    private func decodeLoop(): Unit {
        while (true) {
            var task = Option<KeyboardAnimationStream>.None
            synchronized(this.decodeMonitor) {
                while (this.decodeQueue.size == 0) {
                    let _ = this.decodeMonitor.wait(timeout: Duration.millisecond * 200)
                }
                // FIFO。LIFO 在吞吐不足时会让每拍最后入队的固定几条流吃掉全部
                // 解码配额，其余全冻（真机实测：37 流只有一条带在动）。
                task = Some(this.decodeQueue.remove(at: 0))
            }
            match (task) {
                case Some(stream) =>
                    try {
                        stream.clockPrepare()
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[FrameClock] prepare failed: ${e}")
                    }
                    synchronized(this.decodeMonitor) { stream.prepareQueued = false }
                case None => ()
            }
        }
    }
}

// ============================================================================
// 拉模式格子注册表 —— iOS EmojiPagerContentComponent 可见性驱动的对位
// ============================================================================
//
// 推模式（格子生命周期事件驱动起播）在本版本 ArkUI 三条路全灭（真机取证）：
// 滚动中起播的行被无回调拆毁成僵尸；复用节点第二遍经过时 onAppear /
// onVisibleAreaChange / aboutToAppear 一律不触发（ensurePlayback 调用数=0）。
// iOS 本来就是拉模式：content view 按 visibleBounds 集中决定哪些 itemLayer
// 播放。这里对位：格子挂载时注册（docIdOf 用闭包读**当前** documentId，
// 复用改档自然跟随），面板按可见行区间集中 start/stop —— 僵尸流也会因
// docId 不在可见集而被停掉，与格子生命周期完全解耦。
public class KeyboardCellEntry {
    public let docIdOf: () -> Int64
    public let startPlayback: () -> Unit
    public let stopPlayback: () -> Unit
    public init(docIdOf: () -> Int64, startPlayback: () -> Unit, stopPlayback: () -> Unit) {
        this.docIdOf = docIdOf
        this.startPlayback = startPlayback
        this.stopPlayback = stopPlayback
    }
}

public class KeyboardCellRegistry {
    private let monitor: Monitor = Monitor()
    private let entries: HashMap<Int64, KeyboardCellEntry> = HashMap<Int64, KeyboardCellEntry>()
    private var nextId: Int64 = 1

    public func register(entry: KeyboardCellEntry): Int64 {
        synchronized(this.monitor) {
            let id = this.nextId
            this.nextId = this.nextId + 1
            this.entries[id] = entry
            return id
        }
    }

    public func unregister(id: Int64): Unit {
        synchronized(this.monitor) { let _ = this.entries.remove(id) }
    }

    /** 可见集内的 start，集外的 stop。UI 线程调用；回调内部自做去重/退避。 */
    public func drive(visibleDocIds: HashSet<Int64>): Unit {
        let snapshot = ArrayList<KeyboardCellEntry>()
        synchronized(this.monitor) {
            for ((_, entry) in this.entries) { snapshot.add(entry) }
        }
        Hilog.info(0, "CjTelegram",
            "[PullDiag] drive visible=${visibleDocIds.size} entries=${snapshot.size}")
        for (entry in snapshot) {
            if (visibleDocIds.contains(entry.docIdOf())) {
                entry.startPlayback()
            } else {
                entry.stopPlayback()
            }
        }
    }
}

// ============================================================================
// KeyboardDocPlayback —— 播放按**文档**键控（iOS MultiAnimationRenderer 真形）
// ============================================================================
//
// 终局取证（2026-08-24 深夜）：以格子实例为播放归属时，LazyForEach 的复用与
// 重建混合会让同一 doc 的新旧实例并存 —— 旧实例的流占满全部播放槽向已拆卸的
// @State 送帧（屏幕 bit 级静止），新实例永远排队。实例身份在本版本 ArkUI 上
// 不可依赖。iOS 的 MultiAnimationRenderer 正因此按 itemId 键控、layer 只是
// 渲染目标。这里对位：
//   - 每个 docId 至多一条流，归池持有，与任何实例生死无关
//   - 格子只是订阅者：帧广播给该 doc 的全部订阅者（僵尸订阅死写无害，
//     真在屏上的实例照常上屏）；同 doc 出现在网格+导航时共享同一条流
//   - 可见性驱动：driveVisible(可见 doc 集) 起缺的、停多的
// 格子键含 documentId（稳定键），换档必然新建实例并重新订阅，身份洞闭合。
public class KeyboardDocPlayback {
    private let monitor: Monitor = Monitor()
    /** docId → 播放流。 */
    private let streams: HashMap<Int64, KeyboardAnimationStream> = HashMap<Int64, KeyboardAnimationStream>()
    /** docId → 起流请求在途（防重复 spawn）。 */
    private let starting: HashSet<Int64> = HashSet<Int64>()
    /** docId → 订阅者 (subId, cb)。cb 在 UI 线程收到原始帧。 */
    private let subscribers: HashMap<Int64, ArrayList<(Int64, (PixelMap) -> Unit)>> =
        HashMap<Int64, ArrayList<(Int64, (PixelMap) -> Unit)>>()
    private let subDocOf: HashMap<Int64, Int64> = HashMap<Int64, Int64>()
    private var nextSubId: Int64 = 1
    /** docId → 最新帧：新订阅者立即补上，首帧零等待。 */
    private let lastFrames: HashMap<Int64, PixelMap> = HashMap<Int64, PixelMap>()

    public func subscribe(docId: Int64, onFrame: (PixelMap) -> Unit): Int64 {
        var replay = Option<PixelMap>.None
        let subId: Int64
        synchronized(this.monitor) {
            subId = this.nextSubId
            this.nextSubId = this.nextSubId + 1
            if (!this.subscribers.contains(docId)) {
                this.subscribers[docId] = ArrayList<(Int64, (PixelMap) -> Unit)>()
            }
            let list = this.subscribers[docId]
            list.add((subId, onFrame))
            // 僵尸订阅无法检测（无销毁信号），按 doc 保最近 8 个封顶。
            while (list.size > 8) { let _ = list.remove(at: 0) }
            this.subDocOf[subId] = docId
            if (this.lastFrames.contains(docId)) { replay = Some(this.lastFrames[docId]) }
        }
        match (replay) {
            case Some(frame) => spawn(UIThread) { => onFrame(frame) }
            case None => ()
        }
        return subId
    }

    public func unsubscribe(subId: Int64): Unit {
        synchronized(this.monitor) {
            match (this.subDocOf.get(subId)) {
                case Some(docId) =>
                    Hilog.info(0, "CjTelegram", "[DocPool] unsub doc=${docId}")
                    let _ = this.subDocOf.remove(subId)
                    if (this.subscribers.contains(docId)) {
                        this.subscribers[docId].removeIf({ entry: (Int64, (PixelMap) -> Unit) =>
                            entry[0] == subId })
                    }
                case None => ()
            }
        }
    }

    /** Canvas 合成器接管中的 doc：广播只落 lastFrames，不投递订阅格子
     *（否则流的下一帧立刻覆盖挖洞用的透明帧，格子重新显形成双影）。 */
    private let canvasDocs: HashSet<Int64> = HashSet<Int64>()

    public func setCanvasDelegated(docIds: ArrayList<Int64>): Unit {
        synchronized(this.monitor) {
            this.canvasDocs.clear()
            for (d in docIds) { let _ = this.canvasDocs.add(d) }
        }
    }

    /** 帧钟 UI 线程整批回调进来（经流的 onFrame），广播给订阅者。 */
    private func broadcast(docId: Int64, frame: PixelMap): Unit {
        this.broadcastImpl(docId, frame, false)
    }

    private func broadcastImpl(docId: Int64, frame: PixelMap, force: Bool): Unit {
        let targets = ArrayList<(Int64, (PixelMap) -> Unit)>()
        synchronized(this.monitor) {
            this.lastFrames[docId] = frame
            // lastFrames 无界防护：跟随流集合清理（stop 时移除）。
            if (!force && this.canvasDocs.contains(docId)) { return }
            if (this.subscribers.contains(docId)) {
                for (entry in this.subscribers[docId]) { targets.add(entry) }
            }
        }
        for (entry in targets) { entry[1](frame) }
    }

    /** 可见 doc 集：缺的起、多的停。UI 线程调用（EmojiPicker 拉驱动）。
     *  ordered 为插入序（起播限速按此序消费，导航封面应排最前）。 */
    public func driveVisible(ordered: ArrayList<Int64>): Unit {
        this.driveCore(ordered, { docId: Int64 => this.startDoc(docId) })
    }

    /** A single non-keyboard surface, such as a profile avatar, owns playback
     * independently from the emoji keyboard's visible-set driver. */
    public func startStandalone(docId: Int64): Unit {
        if (docId == 0) { return }
        var shouldStart = false
        synchronized(this.monitor) {
            if (!this.streams.contains(docId) && !this.starting.contains(docId)) {
                let _ = this.starting.add(docId)
                shouldStart = true
            }
        }
        if (shouldStart) { this.startDoc(docId) }
    }

    public func stopStandalone(docId: Int64): Unit {
        var stopped = Option<KeyboardAnimationStream>.None
        synchronized(this.monitor) {
            match (this.streams.get(docId)) {
                case Some(stream) =>
                    stopped = Some(stream)
                    let _ = this.streams.remove(docId)
                    let _ = this.lastFrames.remove(docId)
                case None => ()
            }
            let _ = this.starting.remove(docId)
        }
        match (stopped) {
            case Some(stream) => stream.stop()
            case None => ()
        }
    }

    /**
     * 贴纸面板版：可见项带 StickerItem 与光栅（贴纸格 204、导航封面 84），
     * 起流不走 custom-emoji resolve，直接用面板手里的 item 取本地文件。
     * 与 emoji 面板共用同一 streams 账本 —— 切页签后第一次 drive 自然停掉
     * 对方页签的全部流。
     */
    public func driveVisibleItems(visibleItems: ArrayList<(StickerItem, Int32)>): Unit {
        let ordered = ArrayList<Int64>()
        let seen = HashSet<Int64>()
        let byDoc = HashMap<Int64, (StickerItem, Int32)>()
        for (entry in visibleItems) {
            if (entry[0].documentId != 0 && seen.add(entry[0].documentId)) {
                ordered.add(entry[0].documentId)
                byDoc[entry[0].documentId] = entry
            }
        }
        this.driveCore(ordered, { docId: Int64 =>
            match (byDoc.get(docId)) {
                case Some(entry) => this.startItem(entry[0], entry[1])
                case None => synchronized(this.monitor) { let _ = this.starting.remove(docId) }
            }
        })
    }

    /** 最近一次 drive 的可见集大小：起流按此选帧档（负载自适应）。 */
    private var lastVisibleCount: Int64 = 0
    /** 最近一次 drive 统计出的孤儿数（可见、流在跑、却零订阅 —— 瞬时跳转
     *  的复用格子丢订阅时的形态），宿主据此触发格子重生。 */
    public var lastOrphanCount: Int64 = 0

    private func driveCore(ordered: ArrayList<Int64>, starter: (Int64) -> Unit): Unit {
        this.lastVisibleCount = ordered.size
        let visibleDocIds = HashSet<Int64>()
        // 零订阅过滤：广播无人听的 doc 不驱动、在跑的按不可见收割 ——
        // 真机 trace 实锤 12 条 run 且 subd=0 的僵尸导航流按 20fps 空转
        //（订阅在格子 onAppear 才建立；本拍没订阅的下拍心跳自然补驱）。
        for (docId in ordered) {
            var subscribed = false
            synchronized(this.monitor) {
                subscribed = this.subscribers.contains(docId) && this.subscribers[docId].size > 0
            }
            if (subscribed) { let _ = visibleDocIds.add(docId) }
        }
        let toStart = ArrayList<Int64>()
        let toStop = ArrayList<Int64>()
        synchronized(this.monitor) {
            // 按插入序遍历（HashSet 迭代序不保序）——起播限速按此序消费。
            for (docId in ordered) {
                if (!visibleDocIds.contains(docId)) { continue }
                if (this.streams.contains(docId) && this.streams[docId].deniedDead) {
                    // 直播额度终态拒绝的死流：摘账，让下面按缺流重启（额度可能已空出）。
                    let _ = this.streams.remove(docId)
                }
                if (!this.streams.contains(docId) && !this.starting.contains(docId)) {
                    toStart.add(docId)
                    let _ = this.starting.add(docId)
                }
            }
            // 精确起停：并发 ≈ 可见集。滞后逐出版让 88 条含大量离屏的流
            // 齐跑，4 个解码 worker 被看不见的流吃光（miss 比 80%+），
            // 可见格反而出不了帧 —— 真机实锤后回归 iOS 可见性驱动语义。
            // 滚动闸挡住了滚动中的 churn，起停只发生在停稳后。
            for ((docId, _) in this.streams) {
                if (!visibleDocIds.contains(docId)) { toStop.add(docId) }
            }
        }
        for (docId in toStop) {
            var stopped = Option<KeyboardAnimationStream>.None
            synchronized(this.monitor) {
                match (this.streams.get(docId)) {
                    case Some(stream) =>
                        stopped = Some(stream)
                        let _ = this.streams.remove(docId)
                        let _ = this.lastFrames.remove(docId)
                    case None => ()
                }
            }
            match (stopped) {
                case Some(stream) => stream.stop()
                case None => ()
            }
        }
        for (docId in toStart) { starter(docId) }
        var subscribedDocs: Int64 = 0
        var running: Int64 = 0
        var orphans: Int64 = 0
        synchronized(this.monitor) {
            for (docId in ordered) {
                var hasSub = false
                if (this.subscribers.contains(docId) && this.subscribers[docId].size > 0) {
                    subscribedDocs = subscribedDocs + 1
                    hasSub = true
                }
                match (this.streams.get(docId)) {
                    case Some(stream) =>
                        if (stream.isRunning()) {
                            running = running + 1
                            if (!hasSub) { orphans = orphans + 1 }
                        }
                    case None => ()
                }
            }
        }
        this.lastOrphanCount = orphans
        if (orphans > 0) {
            var sample = ""
            var sc: Int64 = 0
            synchronized(this.monitor) {
                for (docId in ordered) {
                    if (sc >= 3) { break }
                    let hasSub = this.subscribers.contains(docId) && this.subscribers[docId].size > 0
                    var runningStream = false
                    match (this.streams.get(docId)) {
                        case Some(st) => runningStream = st.isRunning()
                        case None => ()
                    }
                    if (runningStream && !hasSub) {
                        sample = sample + "${docId},"
                        sc = sc + 1
                    }
                }
            }
            Hilog.info(0, "CjTelegram", "[DocPool] orphan sample: ${sample}")
        }
        Hilog.info(0, "CjTelegram",
            "[DocPool] drive visible=${visibleDocIds.size} start=${toStart.size} stop=${toStop.size} subd=${subscribedDocs} run=${running}")
        // （诊断期的心跳重播已撤：复用实例的失效订阅收不到任何广播，
        //  真正的自愈通道是 build 根节点 onAppear 的重订阅+重画。）
    }

    /** 贴纸项起流：item 在手，无需 resolve；光栅随调用方（帧 LRU 已按像素计费）。 */
    private func startItem(item: StickerItem, raster: Int32): Unit {
        let docId = item.documentId
        let _ = getKeyboardMediaScheduler().submitUrgent {
            let path = ensureStickerLocalFile(item)
            if (path.size == 0) {
                synchronized(this.monitor) { let _ = this.starting.remove(docId) }
                Hilog.info(0, "CjTelegram", "[DocPool] resource-missing doc=${docId}")
                return
            }
            let isVideo = item.mimeType.contains("webm")
            let stream = KeyboardAnimationStream()
            // 导航条封面（raster=126）恒 20fps：贴纸 Phase1 后帧钟只剩这
            // 12 条流，降频把最后一块 UI 线程帧压力再砍 40%（iOS 顶栏
            // 封面同样低频）。网格回退态（136+）维持 30fps。
            stream.targetTickMs = if (raster <= 126 || this.lastVisibleCount > 56) { 50 } else { 33 }
            // 贴纸重新启用 .acv3（历史事故的前提已变）：当年 204 光栅
            // 10MB/文件、全库转码写出 3.5GB；现在 136 光栅（2×）单文件
            // 1~4MB，预热封顶 150、其余只为可见格 urgent 建 —— 有界。
            // 纯直播方案的代价是 LIVE_DECODE_SLOTS=8 就是全场动画上限
            //（真机 duck 一屏 30 格恒 8 动 + 每拍 33 连败重试风暴），
            // cached 流不占该额度，缓存覆盖面才是「全都动」的正道。
            stream.cacheRasterSize = raster
            stream.liveRasterSize = raster
            let storedBox = Array<Bool>(1, repeat: false)
            let started = stream.start(docId, path, isVideo,
                { frame: PixelMap =>
                    if (!storedBox[0]) {
                        storedBox[0] = true
                        storeStickerStaticFrame(docId, raster, frame, representative: true)
                    }
                    this.broadcast(docId, frame)
                })
            synchronized(this.monitor) {
                let _ = this.starting.remove(docId)
                this.streams[docId] = stream
            }
            if (!started) {
                Hilog.info(0, "CjTelegram", "[DocPool] start-wait doc=${docId}")
            }
        }
    }

    private func startDoc(docId: Int64): Unit {
        let _ = getKeyboardMediaScheduler().submitUrgent {
            var path = ""
            var isVideo = false
            match (resolveCustomEmojiDocument(docId)) {
                case Some(doc) =>
                    path = ensureStickerLocalFile(doc)
                    isVideo = doc.mimeType.contains("webm")
                case None => ()
            }
            if (path.size == 0) {
                synchronized(this.monitor) { let _ = this.starting.remove(docId) }
                Hilog.info(0, "CjTelegram", "[DocPool] resource-missing doc=${docId}")
                return
            }
            let stream = KeyboardAnimationStream()
            // 负载自适应：可见流 >56 时新流按 20fps（50ms）——
            // 高压下 4 个解码 worker 的产能（~2400 帧/s）会被 30fps×80 流
            // 打穿，表现为全场随机丢帧；主动降档比被动 miss 平滑得多
            //（iOS MultiAnimationRenderer 同样按压力分档）。
            stream.targetTickMs = if (this.lastVisibleCount > 56) { 50 } else { 33 }
            stream.cacheRasterSize = 84
            // Cangjie 禁止逃逸 lambda 捕获可变局部量，用单元素数组当盒子。
            let storedBox = Array<Bool>(1, repeat: false)
            let started = stream.start(docId, path, isVideo,
                { frame: PixelMap =>
                    if (!storedBox[0]) {
                        storedBox[0] = true
                        storeStickerStaticFrame(docId, 84, frame, representative: true)
                    }
                    this.broadcast(docId, frame)
                })
            synchronized(this.monitor) {
                let _ = this.starting.remove(docId)
                // 无论立即起播还是进了限流器等待队列，流都**必须入账**：
                // 等待中的流重试成功后若不在账上，就是一条驱动停不掉、
                // 槽位对不上的野流（首版实测洞）。stop() 对等待态同样有效
                //（清 wanted，重试闭包自会放弃）。
                this.streams[docId] = stream
            }
            if (!started) {
                Hilog.info(0, "CjTelegram", "[DocPool] start-wait doc=${docId}")
            }
        }
    }

    /** Canvas 合成器取帧：doc 的最新广播帧（无流/未出帧时 None）。 */
    public func lastFrameFor(docId: Int64): Option<PixelMap> {
        synchronized(this.monitor) {
            if (this.lastFrames.contains(docId)) { return Some(this.lastFrames[docId]) }
            return Option<PixelMap>.None
        }
    }

    /**
     * 原生合成器接管的 doc：给全部订阅格子广播一张透明帧，把仓颉侧静帧
     * 「挖洞」，让 underlay surface 的原生帧透出（cells 位于 surface 之上）。
     */
    public func hideDocs(docIds: ArrayList<Int64>): Unit {
        let blank = getEmptyAnimatedEmojiPixelMap()
        let ids = ArrayList<Int64>()
        for (d in docIds) { ids.add(d) }
        spawn(UIThread) { =>
            for (docId in ids) {
                let targets = ArrayList<(Int64, (PixelMap) -> Unit)>()
                synchronized(this.monitor) {
                    if (this.subscribers.contains(docId)) {
                        for (entry in this.subscribers[docId]) { targets.add(entry) }
                    }
                }
                // 直投透明帧：不经 broadcast（不落 lastFrames、无视接管门）。
                for (entry in targets) { entry[1](blank) }
            }
        }
    }

    /** 合成器退位（滚动开始）：用磁盘代表帧把静帧还给格子。 */
    public func restoreDocs(docIds: ArrayList<Int64>): Unit {
        let targets = ArrayList<Int64>()
        for (d in docIds) { targets.add(d) }
        let _ = spawn {
            for (docId in targets) {
                match (loadStickerStaticFrameCached(docId, 84, representative: true)) {
                    case Some(frame) =>
                        launch { this.broadcast(docId, frame) }
                    case None => ()
                }
            }
        }
    }

    /** 面板关闭：全停。 */
    public func stopAll(): Unit {
        let all = ArrayList<KeyboardAnimationStream>()
        synchronized(this.monitor) {
            for ((_, stream) in this.streams) { all.add(stream) }
            this.streams.clear()
            this.lastFrames.clear()
        }
        for (stream in all) { stream.stop() }
    }
}

/**
 * 头像表情的独立播放器。
 *
 * iOS 的头像视图走 AvatarVideoNode，而编辑器预览走 AnimatedStickerNode；两者都
 * 不进入 EntityKeyboard 的可见格降帧池。这里同样为每个头像组件持有独立流，
 * 从而允许同一 document 在设置页循环、在编辑器预览只播一次。
 */
public class AvatarEmojiPlayback {
    private let monitor: Monitor = Monitor()
    private var stream: Option<KeyboardAnimationStream> = None<KeyboardAnimationStream>
    private var generation: Int64 = 0

    public func start(documentId: Int64, rasterSize: Int32, loop: Bool,
                      onFrame: (PixelMap) -> Unit): Unit {
        this.stop()
        synchronized(this.monitor) { this.generation = this.generation + 1 }
        let token = synchronized(this.monitor) { this.generation }
        let _ = getKeyboardMediaScheduler().submitUrgent {
            var path = ""
            var isVideo = false
            match (resolveCustomEmojiDocument(documentId)) {
                case Some(document) =>
                    path = ensureStickerLocalFile(document)
                    isVideo = document.mimeType.contains("webm")
                case None => ()
            }
            if (path.size == 0) { return }
            if (synchronized(this.monitor) { this.generation != token }) { return }
            let playback = KeyboardAnimationStream()
            playback.targetTickMs = 16
            playback.cacheRasterSize = rasterSize
            playback.liveRasterSize = rasterSize
            playback.requestedLoopPlayback = loop
            playback.preserveEveryFrame = true
            let started = playback.start(documentId, path, isVideo, onFrame)
            if (!started) { return }
            synchronized(this.monitor) {
                if (this.generation == token) {
                    this.stream = Some(playback)
                } else {
                    playback.stop()
                }
            }
        }
    }

    public func stop(): Unit {
        var previous = Option<KeyboardAnimationStream>.None
        synchronized(this.monitor) {
            this.generation = this.generation + 1
            previous = this.stream
            this.stream = None<KeyboardAnimationStream>
        }
        match (previous) {
            case Some(value) => value.stop()
            case None => ()
        }
    }
}

private let keyboardDocPlaybackInstance: KeyboardDocPlayback = KeyboardDocPlayback()

public func getKeyboardDocPlayback(): KeyboardDocPlayback {
    return keyboardDocPlaybackInstance
}

private let keyboardCellRegistryInstance: KeyboardCellRegistry = KeyboardCellRegistry()

public func getKeyboardCellRegistry(): KeyboardCellRegistry {
    return keyboardCellRegistryInstance
}

private let keyboardFrameClockInstance: KeyboardFrameClock = KeyboardFrameClock()

public func getKeyboardFrameClock(): KeyboardFrameClock {
    return keyboardFrameClockInstance
}

/**
 * 一个格子的流式动画。持有解码会话；帧推进由全局 KeyboardFrameClock 统一驱动
 *（见上），素材源帧率与 33ms 拍长的换算在 beginClock 里做，各种帧率都保持
 * 真实播放速度。
 *
 * 生命周期由调用方负责：可见时 start，disappear/复用时必须 stop，
 * 否则播放槽会泄漏，整个面板很快就再也没有格子能动。
 */
public class KeyboardAnimationStream {
    private var lottie: Option<StreamingLottiePlayer> = None<StreamingLottiePlayer>
    private var video: Option<StreamingVideoStickerPlayer> = None<StreamingVideoStickerPlayer>
    /** AnimationCache 命中时的播放器：inflate 即帧，不经 rlottie 渲染闸。 */
    private var cached: Option<CachedAnimationPlayer> = None<CachedAnimationPlayer>
    /**
     * >0 时 start() 先试 AnimationCache（键 = documentId@raster）；未命中则回退
     * 实时解码并把构建请求排进后台队列 —— 下次经过就走缓存了。
     */
    public var cacheRasterSize: Int32 = 0
    private var frameIndex: Int64 = 0
    private var holdsSlot: Bool = false
    private var generation: Int64 = 0
    /** 调用方是否仍然希望这一格播放（可见）。stop() 置 false。 */
    private var wanted: Bool = false
    // ---- 共享帧钟驱动的推进状态（只被钟的 tick 线程 / 解码 worker 触碰）----
    private var clockAttached: Bool = false
    private var totalFrames: Int64 = 0
    /** 每次推进跳过的源帧数：round(拍长 / 源帧长)，60fps 素材为 2。 */
    private var stepFrames: Int64 = 1
    /** 一步的时长预算 = 源帧长 × stepFrames；accMs 攒够才走一步。 */
    private var stepBudgetMs: Int64 = 33
    private var accMs: Int64 = 0
    private var clockOnFrame: (PixelMap) -> Unit = { _frame: PixelMap => }
    /** 归 KeyboardFrameClock 的 decodeMonitor 管：prepare 已排队未完成。 */
    public var prepareQueued: Bool = false
    /** 注册时由钟盖章的键盘代际（见 KeyboardFrameClock.keyboardEpoch）。 */
    public var clockEpoch: Int64 = 0
    /** 占用了实时解码额度（LIVE_DECODE_SLOTS）。 */
    private var holdsLiveSlot: Bool = false
    /**
     * 活性租约。运行中的流必然持续送帧 → 宿主格子 build() 必然重跑 → 调
     * pingAlive() 续租。被 ArkUI 无声销毁的格子（R-146）永远不再 build，
     * 其流 3 秒后被钟判定为僵尸并收割 —— 归还播放槽、live 额度和解码会话。
     * 这是对「本版本 ArkUI 没有可靠销毁信号」的总兜底。
     */
    public var lastPingMs: Int64 = 0

    public func pingAlive(): Unit {
        this.lastPingMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
    }

    public func isZombie(nowMs: Int64): Bool {
        if (!this.clockAttached) { return false }
        return nowMs - this.lastPingMs > 3000
    }
    /** 诊断用：最近一次 start 的 documentId。 */
    private var lastDocId: Int64 = 0

    public func lastDocIdForLog(): Int64 { return this.lastDocId }

    public init() {}

    /** 直播额度终态拒绝：无等待者、不会自愈，池侧按此摘账重试。 */
    public var deniedDead: Bool = false
    /** cacheRasterSize=0（不用帧缓存）时的直播解码光栅；0 = 用默认 384。 */
    public var liveRasterSize: Int32 = 0

    public func isRunning(): Bool {
        return this.clockAttached
    }

    /** 聊天页的流（贴纸气泡 / 领养的大表情）——面板收割时跳过。 */
    public func isChatScoped(): Bool {
        return this.useChatSlots || !this.ownsPlayers
    }

    /**
     * 尝试开始播放。返回 false 表示配额已满或素材打不开 —— 调用方保持代表帧即可。
     * onFrame 由共享帧钟在 **UI 线程** 整批回调，调用方直接写 @State 即可，
     * 不要再自行 spawn(UIThread)（那正是改造前每秒 700 个 UI 任务的来源）。
     */
    /** 用顶部导航条的独立配额，而不是与主网格共用的那份。 */
    public var useNavigationSlots: Bool = false
    /** 聊天页贴纸气泡：走 CHAT_STICKER_PLAYBACK_SLOTS 那份独立配额。 */
    public var useChatSlots: Bool = false
    /** 本流的节流目标（毫秒/步）。16 = 全速 60fps，33 = 30fps。 */
    public var targetTickMs: Int64 = KEYBOARD_STREAM_TICK_MS
    /** 一次性播放播到末帧后的完成回调（UI 线程送达）。特效覆盖层靠它自拆。 */
    public var onOneShotDone: () -> Unit = { => }
    /** false：播到末帧自动从钟上摘下并停在末帧（聊天大表情的一次性语义）。 */
    private var loopPlayback: Bool = true
    /** start() 前由头像播放器指定；普通键盘流保持默认循环。 */
    public var requestedLoopPlayback: Bool = true
    /** 头像播放器必须完整呈现素材帧；不能套键盘格子的追时跳帧策略。 */
    public var preserveEveryFrame: Bool = false
    /** false：播放器归调用方持有，stop() 不 close（领养模式）。 */
    private var ownsPlayers: Bool = true
    /**
     * 下一次要呈现的目标帧。**一经确定就不漂移**，直到 advance 成功 ——
     * prepare（解码 worker）与 advance（钟）之间必须指向同一帧，否则解码
     * 永远追不上一个移动的目标。
     */
    private var pendingTarget: Int64 = -1
    // ---- 一次性播放的诊断计数（只在 loopPlayback=false 时记录/打印）----
    private var perfStartedAtMs: Int64 = 0
    private var perfPresented: Int64 = 0
    private var perfMissed: Int64 = 0
    private var perfDecodeMsTotal: Int64 = 0
    private var perfDecodeCount: Int64 = 0

    private func limiter(): KeyboardPlaybackLimiter {
        if (this.useChatSlots) { return getChatStickerPlaybackLimiter() }
        if (this.useNavigationSlots) { return getKeyboardNavPlaybackLimiter() }
        return getKeyboardPlaybackLimiter()
    }

    public func start(
        documentId: Int64,
        localPath: String,
        isVideo: Bool,
        onFrame: (PixelMap) -> Unit
    ): Bool {
        if (this.isRunning() || documentId == 0 || localPath.size == 0) {
            if (localPath.size == 0 && documentId != 0) {
                Hilog.info(0, "CjTelegram", "[StartDiag] no-local id=${documentId}")
            }
            return false
        }
        // 标记「本格子想播」；释放槽位后的重试要靠它判断格子是否还在屏幕上
        this.wanted = true
        this.lastDocId = documentId
        this.ownsPlayers = true
        this.loopPlayback = this.requestedLoopPlayback
        let wantToken = this.generation
        if (!this.limiter().acquireOrWait({ =>
            // 有槽了再回来试一次。stop() 会清 wanted 并推进 generation，
            // 所以已经滚走或被复用的格子不会被叫醒。
            if (this.wanted && this.generation == wantToken && !this.isRunning()) {
                let _ = this.start(documentId, localPath, isVideo, onFrame)
            }
        })) {
            return false
        }
        this.holdsSlot = true
        this.generation = this.generation + 1
        if (this.cacheRasterSize > 0) {
            match (openCachedAnimationPlayer(documentId, this.cacheRasterSize)) {
                case Some(player) =>
                    this.cached = Some(player)
                    // 帧率跟随调用方分档，**不强制 60fps**。上一版在这里强制 16ms，
                    // 结果 48 格 × 60fps = 每秒 2880 次 @State 写 + 组件重渲 +
                    // PixelMap 分配 —— ArkUI 的 Image 更新走组件 diff，不是 iOS 的
                    // CALayer.contents 直换，UI 线程直接被打满（真机反馈「很卡」）。
                    // iOS 的 MultiAnimationRenderer 同样按显示尺寸分档：网格小格子
                    // 30fps，大表情/预览才 60fps。缓存文件仍存 60fps 全帧，
                    // 大尺寸调用方（targetTickMs=16）可全速播。
                    return this.beginClock(player.getFrameCount(),
                        Int64(player.getFrameDurationMs()), onFrame)
                case None =>
                    Hilog.info(0, "CjTelegram",
                        "[StartDiag] cache-miss id=${documentId} raster=${this.cacheRasterSize}")
                    // 回退实时解码，同时排队后台构建（构建器自带前台让路）。
                    requestAnimationCacheBuild(documentId, localPath, isVideo,
                        this.cacheRasterSize, urgent: true)
            }
        }
        // 实时解码限量：拿不到额度就保持静帧（缓存建成后自动走上面的 cached 分支）。
        // 导航条豁免：全局至多 10 条（自带 nav 池），却总被网格抢光 live 额度，
        // 真机表现为导航整条冻死 + 起播失败重试风暴。
        if (!this.useNavigationSlots) {
            if (!getLiveDecodeLimiter().acquire()) {
                Hilog.info(0, "CjTelegram", "[StartDiag] live-denied id=${documentId}")
                // 直播额度拒绝是**终态**（不注册等待者）：标记出来让 doc 池
                // 下一轮 drive 摘账重试，否则该 doc 永久死在账上。
                this.deniedDead = true
                this.releaseSlot()
                return false
            }
            this.holdsLiveSlot = true
        }
        if (isVideo) {
            match (openVideoStickerFileStream(documentId, localPath,
                rasterSize: if (this.cacheRasterSize > 0) { this.cacheRasterSize }
                    else if (this.liveRasterSize > 0) { this.liveRasterSize } else { 384 })) {
                case Some(player) =>
                    this.video = Some(player)
                    return this.beginClock(player.getFrameCount(),
                        Int64(player.getFrameDurationMs()), onFrame)
                case None =>
                    if (this.holdsLiveSlot) {
                        this.holdsLiveSlot = false
                        getLiveDecodeLimiter().release()
                    }
                    this.releaseSlot()
                    return false
            }
        }
        match (openAnimatedStickerFileStream(documentId, localPath,
            rasterSize: if (this.cacheRasterSize > 0) { this.cacheRasterSize }
                else if (this.liveRasterSize > 0) { this.liveRasterSize } else { 384 })) {
            case Some(player) =>
                this.lottie = Some(player)
                let started = this.beginClock(player.getFrameCount(),
                    Int64(player.getFrameDurationMs()), onFrame)
                return started
            case None =>
                Hilog.info(0, "CjTelegram", "[KeyboardAnim] open failed id=${documentId}")
                if (this.holdsLiveSlot) {
                    this.holdsLiveSlot = false
                    getLiveDecodeLimiter().release()
                }
                this.releaseSlot()
                return false
        }
    }

    /**
     * 接到共享帧钟上。步长换算：
     *   step = round(拍长 33ms / 源帧长)   —— 60fps(16ms) 素材 step=2，不再半速
     *   budget = 源帧长 × step             —— 20fps(50ms) 素材攒两拍才走一步
     * 初始 prepare 在这里同步做一次（本方法运行在媒体调度器 worker 上，不占 UI）。
     */
    private func beginClock(frameCount: Int64, rawDurationMs: Int64,
                            onFrame: (PixelMap) -> Unit): Bool {
        if (frameCount <= 1) {
            this.stop()
            return false
        }
        var raw = rawDurationMs
        if (raw < 1) { raw = 16 }
        var step = (this.targetTickMs + raw / 2) / raw
        if (step < 1) { step = 1 }
        this.totalFrames = frameCount
        this.stepFrames = step
        this.stepBudgetMs = raw * step
        this.accMs = 0
        this.frameIndex = 0
        this.clockOnFrame = onFrame
        this.pendingTarget = this.targetFrom(0, 1)
        let _ = this.playerPrepare(this.pendingTarget)
        this.pingAlive()
        this.clockAttached = true
        getKeyboardFrameClock().register(this)
        return true
    }

    /** 帧钟每拍调用。返回 Some(新帧) 表示这一拍推进成功。 */
    public func clockTick(tickMs: Int64): Option<PixelMap> {
        if (!this.clockAttached || !getAppState().isInForeground()) {
            return Option<PixelMap>.None
        }
        this.accMs = this.accMs + tickMs
        if (this.accMs < this.stepBudgetMs) { return Option<PixelMap>.None }
        if (!this.loopPlayback && this.frameIndex >= this.totalFrames - 1) {
            // 一次性动画播完：从钟上摘下，画面停在末帧。播放器留给调用方
            //（领养模式下调用方还要 tap 重播）。
            this.clockAttached = false
            getKeyboardFrameClock().unregister(this)
            let elapsed = DateTime.now().toUnixTimeStamp().toMilliseconds() - this.perfStartedAtMs
            let avgDecode = if (this.perfDecodeCount > 0) {
                this.perfDecodeMsTotal / this.perfDecodeCount
            } else { 0 }
            Hilog.info(0, "CjTelegram",
                "[OneShotPerf] done elapsedMs=${elapsed} frames=${this.totalFrames} step=${this.stepFrames} budget=${this.stepBudgetMs} presented=${this.perfPresented} missed=${this.perfMissed} avgDecodeMs=${avgDecode} decodes=${this.perfDecodeCount}")
            let done = this.onOneShotDone
            spawn(UIThread) { => done() }
            return Option<PixelMap>.None
        }
        if (this.pendingTarget < 0) { this.pendingTarget = this.targetFrom(this.frameIndex, 1) }
        if (this.playerAdvance(this.pendingTarget)) {
            this.frameIndex = this.pendingTarget
            // 落后跳帧（对位 iOS：displaylink 驱动下丢帧不拖时长）。
            // 欠了几个预算就把下一个目标多跳几步：384px 的 rlottie 单帧解码
            // 超过 16ms 预算是常态，重试同一帧的旧逻辑会把 3 秒的动画拖成
            // 慢动作 —— 「比 iOS 播得慢」的另一个根因。封顶 4 步防跳穿。
            var owed = if (this.preserveEveryFrame) { 1 } else {
                this.accMs / this.stepBudgetMs
            }
            if (owed < 1) { owed = 1 }
            if (owed > 4) { owed = 4 }
            this.accMs = this.accMs - owed * this.stepBudgetMs
            if (this.accMs < 0) { this.accMs = 0 }
            if (this.accMs > this.stepBudgetMs) { this.accMs = this.stepBudgetMs }
            this.pendingTarget = this.targetFrom(this.frameIndex, owed)
            if (!this.loopPlayback) { this.perfPresented = this.perfPresented + 1 }
            return this.playerCurrent()
        }
        // 解码没赶上：欠账继续累计（这是跳帧的弹药），封顶 4 步。
        if (!this.loopPlayback) { this.perfMissed = this.perfMissed + 1 }
        let debtLimit = if (this.preserveEveryFrame) {
            this.stepBudgetMs
        } else {
            this.stepBudgetMs * 4
        }
        if (this.accMs > debtLimit) { this.accMs = debtLimit }
        return Option<PixelMap>.None
    }

    /** 从 base 前进 steps × stepFrames 帧：循环取模；一次性钳在末帧。 */
    private func targetFrom(base: Int64, steps: Int64): Int64 {
        if (this.loopPlayback) {
            return (base + this.stepFrames * steps) % this.totalFrames
        }
        var target = base + this.stepFrames * steps
        if (target > this.totalFrames - 1) { target = this.totalFrames - 1 }
        return target
    }

    /** 帧钟的解码 worker 调用；对「已备好」是 O(1) 早退。 */
    public func clockPrepare(): Unit {
        if (!this.clockAttached) { return }
        if (this.pendingTarget < 0) { return }
        if (this.loopPlayback) {
            let _ = this.playerPrepare(this.pendingTarget)
            return
        }
        let before = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let _ = this.playerPrepare(this.pendingTarget)
        this.perfDecodeMsTotal = this.perfDecodeMsTotal +
            (DateTime.now().toUnixTimeStamp().toMilliseconds() - before)
        this.perfDecodeCount = this.perfDecodeCount + 1
    }

    /**
     * 领养调用方已打开并持有的 lottie 会话，一次性播完即从钟上摘下。
     * 聊天大表情用：会话按 emoji 打开、tap 重播时 seekTo(0) 复用，
     * 不能每次重播都付一遍 gunzip + lottie 解析。不占播放配额
     *（大表情一屏至多两三个，且播完即停）。
     */
    public func startAdoptedOneShot(player: StreamingLottiePlayer,
                                    onFrame: (PixelMap) -> Unit): Bool {
        if (this.isRunning()) { return false }
        this.wanted = true
        this.generation = this.generation + 1
        this.ownsPlayers = false
        this.loopPlayback = false
        this.lottie = Some(player)
        this.perfStartedAtMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        this.perfPresented = 0
        this.perfMissed = 0
        this.perfDecodeMsTotal = 0
        this.perfDecodeCount = 0
        Hilog.info(0, "CjTelegram",
            "[OneShotPerf] start frames=${player.getFrameCount()} rawMs=${player.getFrameDurationMs()}")
        return this.beginClock(player.getFrameCount(),
            Int64(player.getFrameDurationMs()), onFrame)
    }

    /** 帧钟在 UI 线程整批回调。 */
    public func deliverUi(frame: PixelMap): Unit {
        if (!this.clockAttached) { return }
        this.clockOnFrame(frame)
    }

    private func playerAdvance(index: Int64): Bool {
        match (this.cached) {
            case Some(player) => return player.advanceTo(index)
            case None => ()
        }
        match (this.lottie) {
            case Some(player) => return player.advanceTo(index)
            case None => ()
        }
        match (this.video) {
            case Some(player) => return player.advanceTo(index)
            case None => ()
        }
        return false
    }

    private func playerPrepare(index: Int64): Bool {
        match (this.cached) {
            case Some(player) => return player.prepareNextFrame(index)
            case None => ()
        }
        match (this.lottie) {
            case Some(player) => return player.prepareNextFrame(index)
            case None => ()
        }
        match (this.video) {
            case Some(player) => return player.prepareNextFrame(index)
            case None => ()
        }
        return false
    }

    private func playerCurrent(): Option<PixelMap> {
        match (this.cached) {
            case Some(player) => return player.getCurrentFrame()
            case None => ()
        }
        match (this.lottie) {
            case Some(player) => return player.getCurrentFrame()
            case None => ()
        }
        match (this.video) {
            case Some(player) => return player.getCurrentFrame()
            case None => ()
        }
        return Option<PixelMap>.None
    }

    private func releaseSlot(): Unit {
        if (this.holdsSlot) {
            this.holdsSlot = false
            this.limiter().release()
        }
    }

    public func stop(): Unit {
        this.wanted = false
        this.generation = this.generation + 1
        if (this.clockAttached) {
            this.clockAttached = false
            getKeyboardFrameClock().unregister(this)
            Hilog.info(0, "CjTelegram", "[KeyboardAnim] stop id=${this.lastDocId}")
        }
        this.pendingTarget = -1
        let oldCached = this.cached
        this.cached = None<CachedAnimationPlayer>
        match (oldCached) {
            case Some(player) => player.close()
            case None => ()
        }
        let oldLottie = this.lottie
        this.lottie = None<StreamingLottiePlayer>
        let oldVideo = this.video
        this.video = None<StreamingVideoStickerPlayer>
        if (this.ownsPlayers) {
            match (oldLottie) {
                case Some(player) => let _ = spawn { player.close() }
                case None => ()
            }
            match (oldVideo) {
                case Some(player) => let _ = spawn { player.close() }
                case None => ()
            }
        }
        if (this.holdsLiveSlot) {
            this.holdsLiveSlot = false
            getLiveDecodeLimiter().release()
        }
        this.releaseSlot()
    }
}

/**
 * 聊天消息里内联 GIF（Video 组件）的并发上限。
 *
 * 为什么必须有：Video 组件挂载即触发 CreatePlayer **同步 IPC**，真机抓到过单次
 * 5002ms（见本文件底部 GIF 面板注释）。聊天历史里几十条 GIF 消息在**普通 ForEach**
 * 下全部常驻组件树，没有这道闸时快速上划会在一两秒内并发创建几十个播放器，
 * 渲染服务过载 → 闪退。
 *
 * 容量 4 的依据：GIF 气泡最高 240vp，聊天可视区一屏最多摆下 3 条整 GIF + 两条
 * 半截 —— 4 个并发播放器足够覆盖「满屏都在动」的观感。
 *
 * 自愈规则与 KeyboardGifPlaybackLimiter 同一条证明：只有可见气泡会来申请，
 * 一屏装不下超过 4 条，所以「池满」只可能意味着计数里躺着死掉的持有者
 *（本版本 ArkUI 没有可靠的组件销毁信号，见下方 R-146 注释），归零后放行。
 */
private let CHAT_VIDEO_PLAYBACK_SLOTS: Int64 = 4

private let chatVideoPlaybackLimiterInstance = ChatVideoPlaybackLimiter()

public func getChatVideoPlaybackLimiter(): ChatVideoPlaybackLimiter {
    return chatVideoPlaybackLimiterInstance
}

public class ChatVideoPlaybackLimiter {
    private let monitor: Monitor = Monitor()
    private var used: Int64 = 0

    public init() {}

    public func acquire(): Bool {
        synchronized(this.monitor) {
            if (this.used >= CHAT_VIDEO_PLAYBACK_SLOTS) {
                Hilog.info(0, "CjTelegram",
                    "[ChatVideoSlot] 池满 used=${this.used}，判定为陈旧持有者，归零后放行")
                this.used = 0
            }
            this.used = this.used + 1
            return true
        }
    }

    public func release(): Unit {
        synchronized(this.monitor) {
            if (this.used > 0) { this.used = this.used - 1 }
        }
    }
}

/** GIF 专用播放槽，配额独立于贴纸（理由见 KEYBOARD_GIF_PLAYBACK_SLOTS）。 */
private let gifPlaybackLimiter = KeyboardGifPlaybackLimiter()

public func getKeyboardGifPlaybackLimiter(): KeyboardGifPlaybackLimiter {
    return gifPlaybackLimiter
}

public class KeyboardGifPlaybackLimiter {
    private let monitor: Monitor = Monitor()
    private var used: Int64 = 0

    public init() {}

    /**
     * 池满即视为持有者已失效，归零后放行。
     *
     * 这不是权宜之计，而是一条可证明成立的规则：GIF 网格 3 列、面板高 287vp，
     * **同时可见的格子最多 9 个**（= KEYBOARD_GIF_PLAYBACK_SLOTS），而只有可见格子
     * 会来申请。所以「池满」只可能意味着计数里躺着已经死掉的持有者。
     *
     * 之所以只能这样做：本版本 ArkUI **没有任何可用的格子级销毁信号**——
     *   - `aboutToDisappear`：LazyForEach 的 GridItem 被拆除时不触发
     *   - `.onDisappear`：Stack 上根本没有这个成员（编译期报错）
     *   - `onVisibleAreaChange`：面板拆除时同样不触发
     *   - 面板级 `aboutToAppear` / `aboutToDisappear`：GifPanel 跨开关一直活着，不触发
     * 实测反复开关面板：acquire 单调上涨、release 恒为 0，约两轮即耗干整池，
     * GIF 从此彻底不播且不会自行恢复（连等 10 秒也不恢复）。
     */
    public func acquire(): Bool {
        synchronized(this.monitor) {
            if (this.used >= KEYBOARD_GIF_PLAYBACK_SLOTS) {
                Hilog.info(0, "CjTelegram",
                    "[GifSlot] 池满 used=${this.used}，判定为陈旧持有者，归零后放行")
                this.used = 0
            }
            this.used = this.used + 1
            return true
        }
    }

    public func release(): Unit {
        synchronized(this.monitor) {
            if (this.used > 0) { this.used = this.used - 1 }
        }
    }

}

/** 顶部导航条的播放槽（理由见 KEYBOARD_NAV_PLAYBACK_SLOTS）。 */
private let navPlaybackLimiter = KeyboardPlaybackLimiter(KEYBOARD_NAV_PLAYBACK_SLOTS)

public func getKeyboardNavPlaybackLimiter(): KeyboardPlaybackLimiter {
    return navPlaybackLimiter
}
