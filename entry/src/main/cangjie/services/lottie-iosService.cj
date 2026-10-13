package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList

// =============================================================================
// Lottie 动画引擎服务 (lottie-ios → HarmonyOS 迁移)
//
// 平台说明：
//   HarmonyOS / 仓颉 无内置 Lottie 渲染引擎。
//   完整方案：真实解析 Lottie JSON（v, fr, ip, op, w, h, layers），
//   用 ohos.animator AnimatorResult 驱动逐帧 progress。
//   矢量路径实际渲染（bezier/shape/gradient/mask）需要 Canvas API 支持，
//   受限于当前平台 API，渲染层实现简化为逐帧 opacity/transform 插值驱动，
//   复杂矢量绘制路径 deferred（平台缺口说明：Canvas drawPath 在仓颉 API 22
//   暂无公开 bezier 路径 API，仅支持 arc/rect 基础形状）。
//
// 调用链：
//   getLottieService().parseLottieAnimation(jsonStr)
//     → LottieAnimation (数据模型)
//     → LottieAnimationState.play() / pause() / stop()
//     → LottieAnimationState.currentFrame (逐帧 progress)
//
// MTProto: N/A — Lottie 是本地动画库，无服务器 TL 方法调用。
// =============================================================================

// ── Lottie JSON 数据模型 ───────────────────────────────────────────────────

/**
 * Lottie Layer 类型枚举 (ty 字段)
 * 来源: Lottie spec https://airbnb.io/lottie/#/after-effects
 */
public enum LottieLayerType {
    | PRECOMP      // 0
    | SOLID        // 1
    | IMAGE        // 2
    | NULL_LAYER   // 3
    | SHAPE        // 4
    | TEXT         // 5
    | UNKNOWN
}

/**
 * Lottie 关键帧（简化）
 * 对应 Lottie JSON keyframe 对象中的 t/s/e 字段
 */
public class LottieKeyframe {
    public var time: Float64 = 0.0        // keyframe time (in frames)
    public var startVal: Float64 = 0.0    // start value
    public var endVal: Float64 = 1.0      // end value

    public init(time: Float64, startVal: Float64, endVal: Float64) {
        this.time = time
        this.startVal = startVal
        this.endVal = endVal
    }
}

/**
 * Lottie Layer 简化模型
 * 对应 Lottie JSON layers[] 中每个层对象
 */
public class LottieLayer {
    public var name: String = ""          // nm
    public var layerType: LottieLayerType = LottieLayerType.UNKNOWN  // ty
    public var inPoint: Float64 = 0.0     // ip — layer in-point (frames)
    public var outPoint: Float64 = 60.0   // op — layer out-point (frames)
    public var index: Int64 = 0           // ind
    public var autoOrient: Bool = false   // ao
    public var opacity: Float64 = 100.0   // ks.o — initial opacity
    public var opacityKeyframes: ArrayList<LottieKeyframe> = ArrayList<LottieKeyframe>()

    public init(name: String, layerType: LottieLayerType, inPoint: Float64, outPoint: Float64) {
        this.name = name
        this.layerType = layerType
        this.inPoint = inPoint
        this.outPoint = outPoint
    }

    /**
     * 计算给定帧时的 opacity 插值 (0.0..1.0)
     * 若无关键帧则返回初始 opacity / 100.0
     */
    public func getOpacityAt(frame: Float64): Float64 {
        if (this.opacityKeyframes.size == 0) {
            return this.opacity / 100.0
        }
        // 超出范围
        if (frame <= this.opacityKeyframes[0].time) {
            return this.opacityKeyframes[0].startVal / 100.0
        }
        let last = this.opacityKeyframes[this.opacityKeyframes.size - 1]
        if (frame >= last.time) {
            return last.endVal / 100.0
        }
        // 线性插值
        var i: Int64 = 0
        while (i + 1 < this.opacityKeyframes.size) {
            let kf0 = this.opacityKeyframes[i]
            let kf1 = this.opacityKeyframes[i + 1]
            if (frame >= kf0.time && frame < kf1.time) {
                let t = (frame - kf0.time) / (kf1.time - kf0.time)
                return (kf0.startVal + t * (kf0.endVal - kf0.startVal)) / 100.0
            }
            i = i + 1
        }
        return this.opacity / 100.0
    }

    /** 当前帧 layer 是否可见 */
    public func isVisibleAt(frame: Float64): Bool {
        return frame >= this.inPoint && frame < this.outPoint
    }
}

/**
 * Lottie Animation 数据模型 — 对应 Lottie JSON 根对象
 *
 * 关键字段:
 *   v   — 版本字符串 (e.g. "5.9.0")
 *   fr  — 帧率 (frames per second)
 *   ip  — in-point (start frame)
 *   op  — out-point (end frame)
 *   w   — 宽度 (pixels)
 *   h   — 高度 (pixels)
 *   nm  — 名称
 *   layers — 图层数组
 */
public class LottieAnimation {
    public var version: String = "5.0.0"
    public var frameRate: Float64 = 30.0
    public var inPoint: Float64 = 0.0
    public var outPoint: Float64 = 60.0
    public var width: Int64 = 512
    public var height: Int64 = 512
    public var name: String = ""
    public var layers: ArrayList<LottieLayer> = ArrayList<LottieLayer>()

    /** 动画总帧数 */
    public func totalFrames(): Float64 {
        return this.outPoint - this.inPoint
    }

    /** 动画总时长（毫秒） */
    public func durationMs(): Int32 {
        if (this.frameRate <= 0.0) {
            return 1000
        }
        return Int32(this.totalFrames() / this.frameRate * 1000.0)
    }
}

// ── 解析函数 ───────────────────────────────────────────────────────────────

/**
 * 从 Lottie JSON 字符串解析 LottieAnimation
 *
 * 实现：使用项目已有的 JsonParser（services/JsonParser.cj），
 * 解析 v / fr / ip / op / w / h / nm / layers 字段。
 */
public func parseLottieAnimation(jsonStr: String): LottieAnimation {
    let anim = LottieAnimation()
    if (jsonStr.size == 0) {
        Hilog.info(0, "CjTelegram", "[LottieService] empty JSON input")
        return anim
    }
    let root = JsonParser.parseObject(jsonStr)
    if (!root.has("v")) {
        Hilog.info(0, "CjTelegram", "[LottieService] not a Lottie JSON (missing v field)")
        return anim
    }
    anim.version = root.getString("v")
    anim.frameRate = root.getFloat("fr")
    anim.inPoint = root.getFloat("ip")
    anim.outPoint = root.getFloat("op")
    anim.width = root.getInt("w")
    anim.height = root.getInt("h")
    anim.name = root.getString("nm")

    // 解析 layers 数组
    let layersArr = root.getArray("layers")
    var li: Int64 = 0
    while (li < layersArr.size()) {
        let layerObj = layersArr.getObject(li)
        let ty = layerObj.getInt("ty")
        let layerType = match (ty) {
            case 0 => LottieLayerType.PRECOMP
            case 1 => LottieLayerType.SOLID
            case 2 => LottieLayerType.IMAGE
            case 3 => LottieLayerType.NULL_LAYER
            case 4 => LottieLayerType.SHAPE
            case 5 => LottieLayerType.TEXT
            case _ => LottieLayerType.UNKNOWN
        }
        let layer = LottieLayer(
            layerObj.getString("nm"),
            layerType,
            layerObj.getFloat("ip"),
            layerObj.getFloat("op")
        )
        layer.index = layerObj.getInt("ind")
        // 解析 ks.o (opacity): k 可能是静态标量或关键帧数组
        let ks = layerObj.getObject("ks")
        let oObj = ks.getObject("o")
        let oKArr = oObj.getArray("k")
        if (oKArr.size() > 0) {
            // 关键帧数组: 每个元素是 {t: Number, s: [Number], e: [Number]}
            var ki: Int64 = 0
            while (ki < oKArr.size()) {
                let kfObj = oKArr.getObject(ki)
                let kfTime = kfObj.getFloat("t")
                let sArr = kfObj.getArray("s")
                let eArr = kfObj.getArray("e")
                // s[0] / e[0] は opacity value (0..100); JsonArray.getInt で取得
                let sVal = Float64(if (sArr.size() > 0) { sArr.getInt(0) } else { Int64(0) })
                let eVal = Float64(if (eArr.size() > 0) { eArr.getInt(0) } else { Int64(sVal) })
                layer.opacityKeyframes.add(LottieKeyframe(kfTime, sVal, eVal))
                ki = ki + 1
            }
            // 设置初始 opacity 为第一帧的 startVal
            if (layer.opacityKeyframes.size > 0) {
                layer.opacity = layer.opacityKeyframes[0].startVal
            }
        } else {
            // 静态标量 opacity
            let oVal = oObj.getFloat("k")
            if (oVal > 0.0) {
                layer.opacity = oVal
            }
        }
        anim.layers.add(layer)
        li = li + 1
    }
    Hilog.info(0, "CjTelegram", "[LottieService] parsed Lottie animation")
    return anim
}

// ── 动画状态机 ─────────────────────────────────────────────────────────────

/**
 * Lottie 动画播放状态
 */
public enum LottiePlayState {
    | IDLE
    | PLAYING
    | PAUSED
    | STOPPED

    public func ordinal(): Int32 {
        match (this) {
            case IDLE => 0
            case PLAYING => 1
            case PAUSED => 2
            case STOPPED => 3
        }
    }

    public operator func ==(rhs: LottiePlayState): Bool {
        return this.ordinal() == rhs.ordinal()
    }

    public operator func !=(rhs: LottiePlayState): Bool {
        return this.ordinal() != rhs.ordinal()
    }
}

/**
 * AnimatedStickerPlaybackMode — 动画贴纸播放模式
 *
 * 对应 iOS AnimatedStickerNode.swift AnimatedStickerPlaybackMode (P2-382):
 *   - once:  播放一次后停在最后一帧（如 reaction 触发动画）
 *   - loop:  无限循环播放（默认贴纸）
 *   - count: 播放指定次数后停止
 *   - still: 静止在指定帧（不播放）
 *
 * iOS ref: AnimatedStickerNode.swift:61
 *   public enum AnimatedStickerPlaybackMode {
 *       case once; case count(Int); case loop; case still(AnimatedStickerPlaybackPosition)
 *   }
 */
public enum AnimatedStickerPlaybackMode {
    // 播放一次后停止（停在最后一帧）— iOS: .once
    | PlayOnce
    // 无限循环播放 — iOS: .loop
    | PlayLoop
    // 播放指定次数 — iOS: .count(Int)
    | PlayCount(Int32)
    // 静止在帧 0 — iOS: .still
    | PlayStill

    public func ordinal(): Int32 {
        match (this) {
            case PlayOnce => 0
            case PlayLoop => 1
            case PlayCount(_) => 2
            case PlayStill => 3
        }
    }

    public operator func ==(rhs: AnimatedStickerPlaybackMode): Bool {
        return this.ordinal() == rhs.ordinal()
    }

    public operator func !=(rhs: AnimatedStickerPlaybackMode): Bool {
        return this.ordinal() != rhs.ordinal()
    }
}

/**
 * LottieAnimationState — 管理单个 Lottie 动画的播放状态
 *
 * 使用方式：
 *   let state = LottieAnimationState(anim)
 *   state.play()           // 开始播放
 *   state.pause()          // 暂停
 *   state.stop()           // 停止并重置到 inPoint
 *   state.seekToProgress(0.5)  // 跳到 50% 处
 *   state.getCurrentFrame()    // 当前帧号（UI 用于查询各层状态）
 */
public class LottieAnimationState {
    private var animation: LottieAnimation
    private var playState: LottiePlayState = LottiePlayState.IDLE
    private var currentProgress: Float64 = 0.0   // 0.0 .. 1.0
    private var loopCount: Int64 = 0
    private var maxLoops: Int64 = -1              // -1 = 无限循环
    // P2-382: playback mode — loop / once / count / still
    // 对应 iOS AnimatedStickerPlaybackMode; 影响 onAnimatorProgress 结束逻辑
    public var playbackMode: AnimatedStickerPlaybackMode = AnimatedStickerPlaybackMode.PlayLoop

    public init(animation: LottieAnimation) {
        this.animation = animation
    }

    /**
     * P2-382: 设置播放模式并重置状态
     * 对应 iOS AnimatedStickerNode.setup(playbackMode:)
     */
    public func setPlaybackMode(mode: AnimatedStickerPlaybackMode) {
        this.playbackMode = mode
        match (mode) {
            case AnimatedStickerPlaybackMode.PlayLoop =>
                this.maxLoops = -1  // 无限循环
            case AnimatedStickerPlaybackMode.PlayOnce =>
                this.maxLoops = 0   // 最多 1 次（loopCount 从 0 开始，达到 0 时停）
            case AnimatedStickerPlaybackMode.PlayCount(n) =>
                this.maxLoops = Int64(n) - 1
            case AnimatedStickerPlaybackMode.PlayStill =>
                this.maxLoops = 0
                this.currentProgress = 0.0
        }
        Hilog.info(0, "CjTelegram", "[LottieState] setPlaybackMode")
    }

    /** 当前帧号 */
    public func getCurrentFrame(): Float64 {
        return this.animation.inPoint + this.currentProgress * this.animation.totalFrames()
    }

    /** 当前播放进度 0.0..1.0 */
    public func getProgress(): Float64 {
        return this.currentProgress
    }

    public func getPlayState(): LottiePlayState {
        return this.playState
    }

    /** 开始播放 */
    public func play() {
        let wasPaused = match (this.playState) {
            case LottiePlayState.PAUSED => true
            case _ => false
        }
        if (wasPaused) {
            this.playState = LottiePlayState.PLAYING
            Hilog.info(0, "CjTelegram", "[LottieState] resume")
        } else {
            this.currentProgress = 0.0
            this.loopCount = 0
            this.playState = LottiePlayState.PLAYING
            Hilog.info(0, "CjTelegram", "[LottieState] play start")
        }
    }

    /** 暂停 */
    public func pause() {
        let isPlaying = match (this.playState) {
            case LottiePlayState.PLAYING => true
            case _ => false
        }
        if (isPlaying) {
            this.playState = LottiePlayState.PAUSED
            Hilog.info(0, "CjTelegram", "[LottieState] paused")
        }
    }

    /** 停止并重置到起点 */
    public func stop() {
        this.currentProgress = 0.0
        this.playState = LottiePlayState.STOPPED
        Hilog.info(0, "CjTelegram", "[LottieState] stopped")
    }

    /**
     * 由帧动画回调驱动，传入 0.0..1.0 的 progress
     * 若动画结束：
     *   PlayLoop → 无限循环（progress 由外部 animator iterations:-1 处理）
     *   PlayOnce → 停止（playState → STOPPED），停在 progress=1.0
     *   PlayCount(n) → 循环 n 次后停止
     *   PlayStill → 不更新 progress（静止在初始帧）
     *
     * P2-382: 对应 iOS AnimatedStickerNode 播放状态机
     */
    public func onAnimatorProgress(progress: Float64) {
        let isPlaying = match (this.playState) {
            case LottiePlayState.PLAYING => true
            case _ => false
        }
        if (!isPlaying) {
            return
        }
        let isStill = match (this.playbackMode) {
            case AnimatedStickerPlaybackMode.PlayStill => true
            case _ => false
        }
        if (isStill) {
            return
        }
        this.currentProgress = progress
        if (progress >= 1.0) {
            let shouldLoop = match (this.playbackMode) {
                case AnimatedStickerPlaybackMode.PlayLoop => true
                case AnimatedStickerPlaybackMode.PlayCount(n) =>
                    this.loopCount < Int64(n) - 1
                case _ => false
            }
            if (shouldLoop) {
                this.loopCount = this.loopCount + 1
                // loop: progress resets naturally by external animator (iterations=-1)
            } else {
                this.playState = LottiePlayState.STOPPED
                Hilog.info(0, "CjTelegram", "[LottieState] playback ended (mode)")
            }
        }
    }

    /**
     * P2-382: seek 到帧索引（绝对帧号）
     * 对应 iOS AnimatedStickerNode.seekTo(_ position: AnimatedStickerPlaybackPosition)
     */
    public func seekToFrame(frame: Float64) {
        let total = this.animation.totalFrames()
        if (total <= 0.0) {
            return
        }
        let relFrame = frame - this.animation.inPoint
        let clamped = if (relFrame < 0.0) { 0.0 } else if (relFrame > total) { total } else { relFrame }
        this.currentProgress = clamped / total
    }

    /** 跳到指定进度 (0.0..1.0) */
    public func seekToProgress(p: Float64) {
        let clamped = if (p < 0.0) { 0.0 } else if (p > 1.0) { 1.0 } else { p }
        this.currentProgress = clamped
    }

    /** 获取动画宽度（px） */
    public func getWidth(): Int64 {
        return this.animation.width
    }

    /** 获取动画高度（px） */
    public func getHeight(): Int64 {
        return this.animation.height
    }

    /** 获取动画时长（ms） */
    public func getDurationMs(): Int32 {
        return this.animation.durationMs()
    }

    /** 获取帧率 */
    public func getFrameRate(): Float64 {
        return this.animation.frameRate
    }

    /** 获取 layers（供 UI 逐层查询 opacity/visibility） */
    public func getLayers(): ArrayList<LottieLayer> {
        return this.animation.layers
    }

    /** 获取动画名称 */
    public func getAnimationName(): String {
        return this.animation.name
    }
}

// ── 服务单例 ───────────────────────────────────────────────────────────────

/**
 * LottieService — Lottie 动画引擎服务（单例）
 *
 * 职责：
 *   1. 解析 Lottie JSON → LottieAnimation
 *   2. 创建并持有 LottieAnimationState 实例
 *   3. 缓存已解析的动画（按 name/id 缓存）
 */
public class LottieService {
    private var animationCache: ArrayList<LottieAnimation> = ArrayList<LottieAnimation>()
    private var cacheKeys: ArrayList<String> = ArrayList<String>()

    /**
     * 解析并缓存一个 Lottie 动画
     * 若同一 key 已缓存则直接返回，避免重复解析
     */
    public func loadAnimation(key: String, jsonStr: String): LottieAnimation {
        // 查缓存
        var i: Int64 = 0
        while (i < this.cacheKeys.size) {
            if (this.cacheKeys[i] == key) {
                Hilog.info(0, "CjTelegram", "[LottieService] cache hit")
                return this.animationCache[i]
            }
            i = i + 1
        }
        // 解析并存入缓存
        let anim = parseLottieAnimation(jsonStr)
        this.cacheKeys.add(key)
        this.animationCache.add(anim)
        return anim
    }

    /**
     * 为指定 Lottie JSON 创建新的播放状态实例
     * 调用方持有并驱动该状态（绑定 AnimatorResult.onFrame）
     */
    public func createAnimationState(key: String, jsonStr: String): LottieAnimationState {
        let anim = this.loadAnimation(key, jsonStr)
        return LottieAnimationState(anim)
    }

    /** 清除缓存 */
    public func clearCache() {
        this.animationCache = ArrayList<LottieAnimation>()
        this.cacheKeys = ArrayList<String>()
        Hilog.info(0, "CjTelegram", "[LottieService] cache cleared")
    }

    /** 缓存大小 */
    public func cacheSize(): Int64 {
        return this.cacheKeys.size
    }
}

// 全局单例
var _lottieServiceInstance: ?LottieService = None

/**
 * 获取 LottieService 全局单例
 */
public func getLottieService(): LottieService {
    if (_lottieServiceInstance.isNone()) {
        _lottieServiceInstance = LottieService()
    }
    return _lottieServiceInstance.getOrThrow()
}
