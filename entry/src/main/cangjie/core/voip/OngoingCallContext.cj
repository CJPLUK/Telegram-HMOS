package ohos_app_cangjie_entry.core.voip

/**
 * OngoingCallContext — VoIP 通话控制器 (Phase K8)
 *
 * 对应 Telegram-iOS 的 OngoingCallContext.swift
 * 管理 tgcalls 实例的完整生命周期，协调信令与媒体层。
 *
 * 职责:
 * 1. 将 CallSession 的 connections + sharedKey 转换为 tgcalls 配置
 * 2. 创建 TgCallsBridge 实例
 * 3. 桥接 signaling data (MTProto ↔ tgcalls)
 * 4. 管理通话状态 (state callbacks)
 * 5. 控制 mute/volume/video
 */

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.models.CallSession
import ohos_app_cangjie_entry.models.ConnectionEndpoint
import std.collection.ArrayList

/**
 * OngoingCallContext — 通话控制器
 */
public class OngoingCallContext {
    private var _bridge: TgCallsBridge = TgCallsBridge()
    private var _session: CallSession
    private var _isTerminated: Bool = false

    // 回调
    private var _onStateChanged: Option<(VoipState) -> Unit> = None
    private var _onSignalBars: Option<(Int32) -> Unit> = None
    private var _onAudioLevel: Option<(Float32) -> Unit> = None

    // 信令数据发送回调 — 连接到 CallService.sendSignalingData
    private var _sendSignalingData: Option<(Array<Byte>) -> Unit> = None

    /**
     * 构造函数
     *
     * @param session 当前 CallSession（必须已处于 active 状态）
     * @param sendSignalingData 发送信令数据的回调（通过 MTProto）
     */
    public init(session: CallSession,
                sendSignalingData: (Array<Byte>) -> Unit) {
        this._session = session
        this._sendSignalingData = Some(sendSignalingData)
    }

    /**
     * 注册状态变化回调
     */
    public func onStateChanged(callback: (VoipState) -> Unit): Unit {
        this._onStateChanged = Some(callback)
    }

    /**
     * 注册信号强度回调
     */
    public func onSignalBars(callback: (Int32) -> Unit): Unit {
        this._onSignalBars = Some(callback)
    }

    /**
     * 注册音频电平回调 (P2-067)
     *
     * level: [0.0, 1.0] Float32，来自 tgcalls 引擎 audioLevel 回调。
     * 通常以约 10~30Hz 频率被调用（取决于 tgcalls 内部帧率）。
     * 调用者应在收到 level 后 spawn(UIThread)/launch 更新 @State 并驱动 blob 振幅。
     */
    public func onAudioLevel(callback: (Float32) -> Unit): Unit {
        this._onAudioLevel = Some(callback)
    }

    /**
     * 清除音频电平回调
     */
    public func clearAudioLevelCallback(): Unit {
        this._onAudioLevel = None
    }

    /**
     * 启动 VoIP 引擎
     *
     * 参考: Telegram-iOS OngoingCallContext.init
     * 1. 将 CallSession 数据转换为 VoipConfig
     * 2. 创建 TgCallsBridge 实例
     * 3. 注册所有回调
     */
    public func start(): Bool {
        if (this._isTerminated) {
            Hilog.info(0, "CjTelegram", "[OngoingCallContext] Cannot start: already terminated")
            return false
        }

        Hilog.info(0, "CjTelegram", "[OngoingCallContext] Starting VoIP engine...")

        // 构建配置
        let config = buildConfig()

        // 创建实例
        let success = this._bridge.create(
            config,
            { state: Int32 =>
                try {
                    let voipState = voipStateFromInt(state)
                    Hilog.info(0, "CjTelegram", "[OngoingCallContext] State: ${state}")
                    match (this._onStateChanged) {
                        case Some(cb) => cb(voipState)
                        case None => ()
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[OngoingCallContext] EXCEPTION in state handler: ${e}")
                }
            },
            { bars: Int32 =>
                Hilog.info(0, "CjTelegram", "[OngoingCallContext] Signal bars: ${bars}")
                this._session.signalBars = bars
                match (this._onSignalBars) {
                    case Some(cb) => cb(bars)
                    case None => ()
                }
            },
            { level: Float32 =>
                // P2-067: 音频电平回调 — 分发给注册的订阅者 (CallService → CallScreen → AudioBlobComponent)
                match (this._onAudioLevel) {
                    case Some(cb) => cb(level)
                    case None => ()
                }
            },
            { data: Array<Byte> =>
                // 信令数据输出 → 通过 MTProto 发送
                try {
                    Hilog.info(0, "CjTelegram", "[OngoingCallContext] Signaling data emitted: ${data.size} bytes")
                    match (this._sendSignalingData) {
                        case Some(send) =>
                            Hilog.info(0, "CjTelegram", "[OngoingCallContext] Calling sendSignalingData...")
                            send(data)
                            Hilog.info(0, "CjTelegram", "[OngoingCallContext] sendSignalingData returned")
                        case None =>
                            Hilog.info(0, "CjTelegram", "[OngoingCallContext] WARNING: _sendSignalingData is None!")
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[OngoingCallContext] EXCEPTION in signaling emit: ${e}")
                }
            }
        )

        if (!success) {
            Hilog.info(0, "CjTelegram", "[OngoingCallContext] Failed to create tgcalls instance")
            return false
        }

        Hilog.info(0, "CjTelegram", "[OngoingCallContext] VoIP engine started successfully")
        return true
    }

    /**
     * 接收信令数据（来自 MTProto）
     */
    public func receiveSignaling(data: Array<Byte>): Unit {
        if (this._isTerminated) { return }
        this._bridge.receiveSignaling(data)
    }

    /**
     * 设置静音
     */
    public func setMuted(muted: Bool): Unit {
        if (this._isTerminated) { return }
        this._bridge.setMuted(muted)
        this._session.isMuted = muted
    }

    /**
     * 切换扬声器/听筒
     */
    public func setSpeaker(speaker: Bool): Unit {
        this._bridge.setSpeaker(speaker)
        this._session.isSpeaker = speaker
    }

    /**
     * 停止通话并销毁实例
     */
    public func stop(): Unit {
        if (this._isTerminated) { return }
        this._isTerminated = true
        this._bridge.stop()
        this._bridge.destroy()
        Hilog.info(0, "CjTelegram", "[OngoingCallContext] Stopped and destroyed")
    }

    /**
     * 启用/禁用视频
     */
    public func setVideoEnabled(enabled: Bool): Unit {
        if (this._isTerminated) { return }
        this._bridge.setVideoEnabled(enabled)
        this._session.isLocalVideoEnabled = enabled
        if (enabled) { this._session.isVideo = true }
    }

    /**
     * 切换前后摄像头
     */
    public func switchCamera(deviceId: String): Unit {
        if (this._isTerminated) { return }
        this._bridge.switchCamera(deviceId)
    }

    /**
     * 设置视频宽高比
     */
    public func setVideoAspect(aspect: Float32): Unit {
        if (this._isTerminated) { return }
        this._bridge.setVideoAspect(aspect)
    }

    /**
     * Phase P6-9: 设置远端视频帧输出回调
     */
    public func setVideoOutput(onFrame: (Array<Byte>, Int32, Int32) -> Unit): Unit {
        if (this._isTerminated) { return }
        this._bridge.setVideoOutput(onFrame)
    }

    /**
     * 设置本地视频帧输出回调（用于 PiP 预览）
     */
    public func setLocalVideoOutput(onFrame: (Array<Byte>, Int32, Int32) -> Unit): Unit {
        if (this._isTerminated) { return }
        this._bridge.setLocalVideoOutput(onFrame)
    }

    /**
     * Phase P6-9: 设置远端媒体状态回调
     */
    public func setRemoteMediaStateCallback(cb: (Int32, Int32) -> Unit): Unit {
        if (this._isTerminated) { return }
        this._bridge.setRemoteMediaStateCallback(cb)
    }

    /**
     * 检查是否仍然活跃
     */
    public func isActive(): Bool {
        return !this._isTerminated && this._bridge.isActive()
    }

    /* ==================== Private Helpers ==================== */

    /**
     * 将 CallSession 数据转换为 VoipConfig
     *
     * 参考: OngoingCallThreadLocalContext.mm initWithVersion:
     */
    private func buildConfig(): VoipConfig {
        let config = VoipConfig()

        // 加密密钥
        config.encryptionKey = this._session.sharedKey
        config.isOutgoing = this._session.isOutgoing
        config.isVideo = this._session.isVideo

        // 协议版本
        config.version = if (this._session.protocolVersion.size > 0) {
            this._session.protocolVersion
        } else {
            "12.0.0"
        }
        config.maxLayer = if (this._session.maxLayer > 0) {
            this._session.maxLayer
        } else {
            92
        }

        // 转换 connections → VoipRtcServer / VoipEndpoint
        var rtcServers = ArrayList<VoipRtcServer>()
        var endpoints = ArrayList<VoipEndpoint>()

        var connIdx: Int64 = 0
        for (conn in this._session.connections) {
            if (conn.isWebrtc) {
                Hilog.info(0, "CjTelegram", "[buildConfig] WebRTC conn[${connIdx}]: ip='${conn.ip}' ipv6='${conn.ipv6}' port=${conn.port} user='${conn.username}' pass=${conn.password.size}ch turn=${conn.hasTurn}")

                // UDP variant (original)
                let server = VoipRtcServer()
                server.id = conn.id
                server.host = conn.ip
                server.port = UInt16(conn.port)
                server.username = conn.username
                server.password = conn.password
                server.isTurn = conn.hasTurn
                server.isTcp = false
                rtcServers.add(server)

                // TCP variant — emulator may block UDP; TCP TURN provides fallback
                // Telegram-iOS also supports TCP relay through the reflector protocol
                if (conn.hasTurn && conn.ip.size > 0) {
                    let serverTcp = VoipRtcServer()
                    serverTcp.id = conn.id
                    serverTcp.host = conn.ip
                    serverTcp.port = UInt16(conn.port)
                    serverTcp.username = conn.username
                    serverTcp.password = conn.password
                    serverTcp.isTurn = true
                    serverTcp.isTcp = true
                    rtcServers.add(serverTcp)
                }

                // IPv6 UDP variant
                if (conn.ipv6.size > 0) {
                    let server6 = VoipRtcServer()
                    server6.id = conn.id
                    server6.host = conn.ipv6
                    server6.port = UInt16(conn.port)
                    server6.username = conn.username
                    server6.password = conn.password
                    server6.isTurn = conn.hasTurn
                    server6.isTcp = false
                    rtcServers.add(server6)

                    // IPv6 TCP variant
                    if (conn.hasTurn) {
                        let server6Tcp = VoipRtcServer()
                        server6Tcp.id = conn.id
                        server6Tcp.host = conn.ipv6
                        server6Tcp.port = UInt16(conn.port)
                        server6Tcp.username = conn.username
                        server6Tcp.password = conn.password
                        server6Tcp.isTurn = true
                        server6Tcp.isTcp = true
                        rtcServers.add(server6Tcp)
                    }
                }
            } else {
                Hilog.info(0, "CjTelegram", "[buildConfig] Legacy conn[${connIdx}]: ip='${conn.ip}' ipv6='${conn.ipv6}' port=${conn.port} peerTag=${conn.peerTag.size}B")
                let ep = VoipEndpoint()
                ep.id = conn.id
                ep.ip = conn.ip
                ep.ipv6 = conn.ipv6
                ep.port = UInt16(conn.port)
                // 复制 peerTag (16 bytes)
                var pi: Int64 = 0
                while (pi < 16 && pi < conn.peerTag.size) {
                    ep.peerTag[pi] = conn.peerTag[pi]
                    pi = pi + 1
                }
                endpoints.add(ep)
            }
            connIdx = connIdx + 1
        }

        // ArrayList → Array (使用临时 let 变量避免 lambda 捕获 mutable 变量)
        let rtcArr = rtcServers
        let epArr = endpoints
        config.rtcServers = Array<VoipRtcServer>(rtcArr.size, { i: Int64 => rtcArr[i] })
        config.endpoints = Array<VoipEndpoint>(epArr.size, { i: Int64 => epArr[i] })

        Hilog.info(0, "CjTelegram", "[OngoingCallContext] Config: key=${config.encryptionKey.size}B, " +
            "rtcServers=${config.rtcServers.size}, endpoints=${config.endpoints.size}, " +
            "version=${config.version}, maxLayer=${config.maxLayer}")

        return config
    }
}
