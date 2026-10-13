package ohos_app_cangjie_entry.services

/**
 * AudioBlobService — 音频波形球（AudioBlob）数据服务
 *
 * 提供动态声波 "blob" 动画所需的音频电平数据。
 * 纯本地动画/状态管理，无 MTProto 调用（录音 blob 不涉及任何 TL 方法）。
 *
 * 设计：
 *   - setLevel / getLevel：外部（录音/播放控制器）注入当前音频电平 [0.0, 1.0]
 *   - presentationLevel：指数平滑后的显示电平（与 iOS 端 VoiceBlobView 一致）
 *   - isAnimating：动画运行状态
 *   - 通过回调通知 UI 组件刷新
 */

import kit.PerformanceAnalysisKit.Hilog

/** 电平范围常量 */
let BLOB_LEVEL_MIN: Float64 = 0.0
let BLOB_LEVEL_MAX: Float64 = 1.0
/** 平滑系数（每帧：prev * 0.9 + new * 0.1，与 iOS 保持一致） */
let BLOB_SMOOTH_ALPHA: Float64 = 0.1

private var _blobServiceInstance: Option<AudioBlobService> = None

/** 获取全局单例 AudioBlobService */
public func getAudioBlobService(): AudioBlobService {
    match (_blobServiceInstance) {
        case Some(svc) => return svc
        case None =>
            let svc = AudioBlobService()
            _blobServiceInstance = Some(svc)
            return svc
    }
}

/**
 * AudioBlobService
 *
 * 提供录音波形球所需的音频电平与动画状态管理。
 * 与 AudioCaptureService 配合：调用方在录音回调中调用 setLevel()，
 * 组件通过 getPresentationLevel() 获取平滑值驱动绘制。
 */
public class AudioBlobService {
    /** 原始电平 [0.0, 1.0] */
    private var _audioLevel: Float64 = 0.0
    /** 指数平滑后的显示电平 */
    private var _presentationLevel: Float64 = 0.0
    /** 是否正在动画 */
    private var _isAnimating: Bool = false
    /** 帧回调 — 每次 tick 时通知 UI 重绘 */
    private var _onFrame: Option<() -> Unit> = None
    /** 动画循环活跃标志 */
    private var _loopActive: Bool = false

    public init() {}

    // ---- 公开读写 API ----

    /**
     * 注入当前音频电平（由录音/播放层调用）。
     * level 已归一化 [0.0, 1.0]。
     */
    public func setLevel(level: Float64): Unit {
        let clamped = if (level < BLOB_LEVEL_MIN) {
            BLOB_LEVEL_MIN
        } else if (level > BLOB_LEVEL_MAX) {
            BLOB_LEVEL_MAX
        } else {
            level
        }
        this._audioLevel = clamped
    }

    /** 获取原始电平 */
    public func getLevel(): Float64 {
        return this._audioLevel
    }

    /**
     * 更新指数平滑显示电平（animationTick 内部调用）。
     * presentationLevel = presentationLevel * 0.9 + audioLevel * 0.1
     */
    public func tickSmooth(): Unit {
        this._presentationLevel = this._presentationLevel * (1.0 - BLOB_SMOOTH_ALPHA) + this._audioLevel * BLOB_SMOOTH_ALPHA
    }

    /** 获取平滑后的显示电平（供 UI 绘制层使用） */
    public func getPresentationLevel(): Float64 {
        return this._presentationLevel
    }

    /** 是否正在播放动画 */
    public func isAnimating(): Bool {
        return this._isAnimating
    }

    /**
     * 注册帧回调 — 每帧动画时调用（UI 组件通过此触发 Canvas 重绘）。
     */
    public func setOnFrame(cb: () -> Unit): Unit {
        this._onFrame = Some(cb)
    }

    /** 移除帧回调 */
    public func clearOnFrame(): Unit {
        this._onFrame = None
    }

    /**
     * 启动动画循环（约 60fps，16ms 间隔）。
     * 每帧调用 tickSmooth()，再触发 _onFrame 回调。
     */
    public func startAnimation(): Unit {
        if (this._isAnimating) { return }
        this._isAnimating = true
        this._loopActive = true
        Hilog.info(0, "CjTelegram", "[AudioBlobService] Animation started")
        let _ = spawn {
            while (this._loopActive) {
                sleep(Duration.millisecond * 16)
                if (!this._loopActive) { break }
                this.tickSmooth()
                match (this._onFrame) {
                    case Some(cb) => cb()
                    case None => ()
                }
            }
            Hilog.info(0, "CjTelegram", "[AudioBlobService] Animation loop stopped")
        }
    }

    /**
     * 停止动画循环，重置电平。
     */
    public func stopAnimation(): Unit {
        if (!this._isAnimating) { return }
        this._isAnimating = false
        this._loopActive = false
        this._audioLevel = 0.0
        this._presentationLevel = 0.0
        Hilog.info(0, "CjTelegram", "[AudioBlobService] Animation stopped")
    }

    /**
     * 同步注入一帧电平并立即触发平滑更新（供回调驱动模式使用）。
     * 等价于 setLevel + tickSmooth。
     */
    public func pushLevel(level: Float64): Unit {
        this.setLevel(level)
        this.tickSmooth()
    }

    /**
     * 重置所有状态（动画停止后调用）。
     */
    public func reset(): Unit {
        this._audioLevel = 0.0
        this._presentationLevel = 0.0
        this._isAnimating = false
        this._loopActive = false
    }
}
