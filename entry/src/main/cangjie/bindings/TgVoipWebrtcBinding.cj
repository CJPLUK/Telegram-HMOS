package ohos_app_cangjie_entry.bindings

/**
 * TgVoipWebrtcBinding — WebRTC 引擎平台封装层 (tg_voip_webrtc)
 *
 * 对应 Telegram-iOS TgVoipWebrtc 模块，提供平台无关的 WebRTC 接口。
 * 不重复 TgCallsBridge.cj 已有的 FFI 功能，仅补充 WebRTC 特定抽象。
 *
 * 设计要点：
 * 1. TgVoipWebrtcEngine 委托 TgCallsBridge 实现底层能力
 * 2. 提供 WebRTC 专用类型（视频捕获预设、音频路由等）供上层使用
 * 3. 无 FFI 重复 — 所有 native 调用通过 TgCallsBridge
 *
 * 使用场景：OngoingCallContext、CallService 可通过本层获取统一 API。
 */

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.voip.{TgCallsBridge, VoipConfig, VoipRtcServer, VoipEndpoint}

/**
 * 视频捕获预设 — 用于未来扩展分辨率/帧率配置
 * 当前 tgcalls 使用默认配置，此枚举供上层语义化使用
 */
public enum VoipVideoCapturePreset {
    | Default
    | Low
    | Medium
    | High
}

/**
 * 音频输出路由 — 扬声器/听筒
 */
public enum VoipAudioRoute {
    | Earpiece
    | Speaker
}

/**
 * 网络类型 — 对应 tgcalls TgCallsNetworkType
 * iOS 对照: OngoingCallThreadLocalContext setNetworkType
 */
public enum VoipNetworkType {
    | Unknown
    | GPRS
    | Edge
    | ThreeG
    | HSPA
    | LTE
    | WiFi
}

/**
 * VoipNetworkType 转 Int32 (tgcalls C API)
 */
public func voipNetworkTypeToInt(t: VoipNetworkType): Int32 {
    match (t) {
        case VoipNetworkType.Unknown => 0
        case VoipNetworkType.GPRS => 1
        case VoipNetworkType.Edge => 2
        case VoipNetworkType.ThreeG => 3
        case VoipNetworkType.HSPA => 4
        case VoipNetworkType.LTE => 5
        case VoipNetworkType.WiFi => 6
    }
}

/**
 * WebRTC 引擎封装 — 委托 TgCallsBridge
 *
 * 提供平台无关的 TgVoipWebrtc API，内部委托 TgCallsBridge 实现。
 */
public class TgVoipWebrtcEngine {
    private var _bridge: TgCallsBridge = TgCallsBridge()
    private var _isActive: Bool = false

    /**
     * 创建并启动 WebRTC 实例
     * @return true 表示成功
     */
    public func create(config: VoipConfig,
                       onStateChanged: (Int32) -> Unit,
                       onSignalBars: (Int32) -> Unit,
                       onAudioLevel: (Float32) -> Unit,
                       onSignalingData: (Array<Byte>) -> Unit): Bool {
        if (this._isActive) {
            Hilog.info(0, "CjTelegram", "[TgVoipWebrtc] Already active, ignoring create")
            return false
        }
        let ok = this._bridge.create(config, onStateChanged, onSignalBars, onAudioLevel, onSignalingData)
        if (ok) {
            this._isActive = true
        }
        return ok
    }

    /**
     * 接收信令数据
     */
    public func receiveSignaling(data: Array<Byte>): Unit {
        this._bridge.receiveSignaling(data)
    }

    /**
     * 设置静音
     */
    public func setMuted(muted: Bool): Unit {
        this._bridge.setMuted(muted)
    }

    /**
     * 切换扬声器/听筒
     */
    public func setSpeaker(speaker: Bool): Unit {
        this._bridge.setSpeaker(speaker)
    }

    /**
     * 设置网络类型 — 对应 tgcalls setNetworkType
     * 用于网络切换时通知引擎（WiFi ↔ 蜂窝）
     */
    public func setNetworkType(networkType: VoipNetworkType): Unit {
        this._bridge.setNetworkType(voipNetworkTypeToInt(networkType))
    }

    /**
     * 停止通话
     */
    public func stop(): Unit {
        this._bridge.stop()
    }

    /**
     * 销毁实例
     */
    public func destroy(): Unit {
        if (!this._isActive) { return }
        this._bridge.destroy()
        this._isActive = false
    }

    /**
     * 启用/禁用视频
     */
    public func setVideoEnabled(enabled: Bool): Unit {
        this._bridge.setVideoEnabled(enabled)
    }

    /**
     * 设置远端视频帧输出回调
     */
    public func setVideoOutput(onFrame: (Array<Byte>, Int32, Int32) -> Unit): Unit {
        this._bridge.setVideoOutput(onFrame)
    }

    /**
     * 设置本地视频帧输出回调（PiP 预览）
     */
    public func setLocalVideoOutput(onFrame: (Array<Byte>, Int32, Int32) -> Unit): Unit {
        this._bridge.setLocalVideoOutput(onFrame)
    }

    /**
     * 切换前后摄像头
     */
    public func switchCamera(deviceId: String): Unit {
        this._bridge.switchCamera(deviceId)
    }

    /**
     * 设置远端媒体状态回调
     */
    public func setRemoteMediaStateCallback(cb: (Int32, Int32) -> Unit): Unit {
        this._bridge.setRemoteMediaStateCallback(cb)
    }

    /**
     * 设置视频宽高比
     */
    public func setVideoAspect(aspect: Float32): Unit {
        this._bridge.setVideoAspect(aspect)
    }

    /**
     * 是否活跃
     */
    public func isActive(): Bool {
        return this._isActive && this._bridge.isActive()
    }

    /**
     * 获取底层 TgCallsBridge（供 OngoingCallContext 等需要直接访问时使用）
     */
    public func getBridge(): TgCallsBridge {
        return this._bridge
    }
}

/**
 * 获取支持的 tgcalls 版本列表
 */
public func getSupportedVersions(): String {
    return TgCallsBridge.getVersions()
}

/**
 * 获取最大协议层
 */
public func getMaxLayer(): Int32 {
    return TgCallsBridge.getMaxLayer()
}
