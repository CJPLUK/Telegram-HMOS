package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.services.{GifItem, ensureGifLocalFile}
import std.time.*

/**
 * One visible GIF cell. External inline results stream their WebDocument URL;
 * internal/saved documents first reuse the shared media cache. Cells never show
 * an emoji/text fallback, matching iOS MediaBox's transparent loading state.
 */
@Component
public class GifGridCell {
    public var item: GifItem = GifItem()
    public var onTap: (GifItem) -> Unit = { _item: GifItem => }
    public var onLongPress: (GifItem) -> Unit = { _item: GifItem => }
    public var onVisible: () -> Unit = { => }

    @State var localPath: String = ""
    @State var failed: Bool = false
    // iOS GifVideoLayer.shouldBeAnimating 的等价物：只有拿到播放槽、且已经在原地
    // 停稳的格子才挂 Video 节点，其余一律只显示静态缩略图。
    //
    // 为什么必须门控：ArkUI 的 Video 是完整播放器（独立解码线程 + 每帧回主线程），
    // 而 iOS 的 GifVideoLayer 是 AVSampleBufferDisplayLayer——被动图层，全部 target
    // 共用 BatchVideoRenderingContext 里的**一条** displayLink。我们没有那条共享时钟，
    // 只能靠限制同时存在的播放器个数来逼近。
    //
    // 真机实测：不门控时下拉约 16 次即 THREAD_BLOCK_3S（"App main thread is not
    // response"），主线程卡在 ArkUIVideoUpdateMediaPlayer——那是 src 变化时重建播放器
    // 的任务。滚动中格子复用会让 src 不断变，所以除了限量还要等滚动停稳再挂。
    @State var animating: Bool = false
    private var settleGeneration: Int64 = 0
    private var holdsSlot: Bool = false
    // LazyForEach 会复用同一个组件承载另一支 GIF，而复用走的是 onAppear，**不是**
    // aboutToDisappear。释放逻辑只挂在后者上时槽会泄漏：真机实测 60 次快甩之后
    // 9 个槽只剩 1 个格子在播，帧间差掉到 0.064（几乎静止）。
    private var boundDocumentId: Int64 = 0
    // 拿到槽不等于真的在播。列表深处的 GIF 走远程 contentUrl，加载慢或失败时
    // 槽会被一个什么都不放的格子长期占着——真机实测 60 次快甩后 9 个槽只剩 1 个
    // 在出帧。iOS 用 GifVideoLayer.isReadyToRender 区分这两件事，这里用
    // onPrepared 确认 + 看门狗超时兜底。
    private var prepared: Bool = false
    private var generation: Int64 = 0
    private var loadStarted: Bool = false
    private var videoController: VideoController = VideoController()
    /** 有界调度器的取消凭据；离屏/复用时撤销还没开工的下载。 */
    private var loadToken: Int64 = 0

    protected override func aboutToAppear(): Unit {
        this.handleAppear()
    }

    /**
     * 创建与复用的共同入口。绑定的文档变了就先把上一支的槽还回去再重新走一遍，
     * 否则复用后的格子要么顶着旧 GIF 的播放状态，要么永远拿不到槽。
     */
    private func handleAppear(): Unit {
        if (this.boundDocumentId != this.item.documentId) {
            this.stopAnimating()
            if (this.loadToken > 0) {
                getKeyboardMediaScheduler().cancel(this.loadToken)
                this.loadToken = 0
            }
            this.boundDocumentId = this.item.documentId
            this.localPath = ""
            this.failed = false
            this.loadStarted = false
            this.generation = this.generation + 1
        }
        // 只有换了文档才推进 generation。此前每次 appear 都推进，而
        // aboutToAppear 与 .onAppear 会对同一个格子先后各触发一次——第一次的加载
        // 完成时 generation 已经变了，于是既不写 localPath 也**不复位 loadStarted**，
        // 格子就此永久卡在「正在加载」，videoSource() 一直是空，Video 节点建不出来。
        // 实测：反复开关面板后等 20 秒仍只有 1 个 Video 在播。
        this.onVisible()
        this.loadInternalDocument()
        this.scheduleSettle()
    }

    protected override func aboutToDisappear(): Unit {
        this.generation = this.generation + 1
        this.loadStarted = false
        this.stopAnimating()
        if (this.loadToken > 0) {
            getKeyboardMediaScheduler().cancel(this.loadToken)
            this.loadToken = 0
        }
    }

    /**
     * 停稳后再申请播放槽。快速滚动时格子的存活时间远短于这个延时，
     * settleGeneration 会把它作废，于是滚动过程中一个播放器都不会被创建。
     */
    private func scheduleSettle(): Unit {
        this.settleGeneration = this.settleGeneration + 1
        let token = this.settleGeneration
        let _ = spawn {
            sleep(Duration.millisecond * 260)
            if (this.settleGeneration != token) { return }
            launch {
                if (this.settleGeneration != token || this.animating) { return }
                if (this.videoSource().isEmpty()) { return }
                if (getKeyboardGifPlaybackLimiter().acquire()) {
                    this.holdsSlot = true
                    this.prepared = false
                    this.animating = true
                    this.startPrepareWatchdog(token)
                }
            }
        }
    }

    /** 2.5s 内没 onPrepared 就把槽还回去，让还在屏幕上的其它格子有机会播。 */
    private func startPrepareWatchdog(token: Int64): Unit {
        let _ = spawn {
            sleep(Duration.millisecond * 2500)
            if (this.settleGeneration != token) { return }
            launch {
                if (this.settleGeneration != token || this.prepared) { return }
                this.stopAnimating()
            }
        }
    }

    private func stopAnimating(): Unit {
        this.settleGeneration = this.settleGeneration + 1
        this.prepared = false
        if (this.animating) {
            this.animating = false
            this.videoController.stop()
        }
        if (this.holdsSlot) {
            this.holdsSlot = false
            getKeyboardGifPlaybackLimiter().release()
        }
    }

    private func loadInternalDocument(): Unit {
        if (this.loadStarted || this.item.documentId == 0) { return }
        this.loadStarted = true
        let captured = this.item
        let token = this.generation
        // 有界调度器而非裸 spawn：点分类后几十个 mp4 同时开下载会把串行
        // MTProto 队列塞死，大部分格子永远等不到文件（「点分类后很多 gif
        // 加载不出来」的根因；贴纸格子同款教训）。
        this.loadToken = getKeyboardMediaScheduler().submit {
            let path = ensureGifLocalFile(captured)
            launch {
                // loadStarted **无条件**复位：它表达的是「这一次请求还在飞」，
                // 与结果是否过期无关。此前放在 generation 判断里，请求过期时
                // 就再也不复位，格子从此不会重试。
                this.loadStarted = false
                if (this.generation == token) {
                    this.localPath = path
                    this.failed = path.isEmpty()
                }
            }
        }
    }

    private func videoSource(): String {
        if (!this.localPath.isEmpty() &&
            (this.item.mimeType.contains("mp4") || this.item.mimeType.contains("video"))) {
            return this.localPath
        }
        if (!this.item.contentUrl.isEmpty() &&
            !this.item.mimeType.contains("gif") && !this.item.contentUrl.contains(".gif")) {
            return this.item.contentUrl
        }
        return ""
    }

    /**
     * 不播放时显示的静态图。localPath 可能是 mp4——Image 解不了视频，
     * 那种情况必须退到缩略图，否则门控之后整块变空白。
     */
    private func imageSource(): String {
        if (!this.localPath.isEmpty() && this.localPath != this.videoSource()) {
            return this.localPath
        }
        if (!this.item.thumbnailUrl.isEmpty()) { return this.item.thumbnailUrl }
        if (this.item.contentUrl != this.videoSource()) { return this.item.contentUrl }
        return ""
    }

    public func build() {
        Stack {
            if (this.animating && !this.videoSource().isEmpty()) {
                Video(src: this.videoSource(), controller: this.videoController)
                    .width(100.percent)
                    .height(100.percent)
                    .autoPlay(true)
                    .loop(true)
                    .muted(true)
                    .controls(false)
                    .objectFit(ImageFit.Cover)
                    .onPrepared({ _info: PreparedInfo => this.prepared = true })
                    .onError({ => this.stopAnimating() })
            } else if (!this.imageSource().isEmpty()) {
                Image(this.imageSource())
                    .width(100.percent)
                    .height(100.percent)
                    .objectFit(ImageFit.Cover)
            } else if (!this.failed) {
                LoadingProgress()
                    .width(22)
                    .height(22)
                    .color(0x8E8E93)
            }
            // Video 节点会吞掉触摸，父 Stack 收不到点击——透明层专门收手势。
            // 长按菜单已下线（用户要求移除；恢复时从 git 取回 handleTouch）。
            Column {}
                .width(100.percent)
                .height(100.percent)
                .onClick({ _evt => this.onTap(this.item) })
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xEBEDF0)
        .onAppear({ => this.handleAppear() })
        // 可见性驱动播/停，等价于 iOS GifVideoLayer 的 shouldBeAnimating。
        //
        // 这是**唯一能还槽的时机**：aboutToDisappear 在 LazyForEach 的 GridItem 被拆除时
        // 不触发；`.onDisappear` 在本版本 ArkUI 的 Stack 上不存在
        //（'onDisappear' is not a member of class 'Stack'）；面板级的 aboutToAppear /
        // aboutToDisappear 也都不触发——GifPanel 组件跨开关一直活着，churn 的只是格子。
        // 实测反复开关面板 15 轮：acquire 单调涨到 8，release 恒为 0，池子只有 9 个。
        .onVisibleAreaChange([0.01], { isVisible: Bool, _ratio: Float64 =>
            // **只在真的在播时才停**。曾经这里是「不可见就 stopAnimating、可见就
            // handleAppear」，结果更糟：布局期间可见性会短暂翻转，而 stopAnimating()
            // 会推进 settleGeneration，把还没落地的那次 settle 一并作废——
            // 实测 0 个 Video、帧间差 0.018，等于彻底不播。
            // 起播仍然只由 onAppear 触发，这里单纯负责归还。
            if (!isVisible && this.animating) {
                this.stopAnimating()
            }
        })
    }
}
