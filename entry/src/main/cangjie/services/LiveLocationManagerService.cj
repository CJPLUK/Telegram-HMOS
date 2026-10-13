package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.{
    getMTProtoClient,
    TLObject,
    TLSerializer,
    TLDeserializer,
    InputGeoPoint,
    InputPeerEmpty
}
import std.collection.ArrayList
import std.collection.HashMap
import std.sync.ReentrantMutex
import std.time.*

// P2-185/186: 无限期分享周期常量 (对应 iOS liveLocationIndefinitePeriod = 0x7fffffff)
public let LIVE_LOCATION_INDEFINITE_PERIOD: Int32 = 0x7fffffff

// ==================== TL 辅助类（仅在本文件内用） ====================

/**
 * messages.editMessage with media field — 用于实时位置坐标更新
 * Constructor: 0xdfd14005
 * flags: bit 14 = media present
 *
 * P2-186 fix: heading 字段现在从连续定位的 Location.direction 传入（非硬编码 0）
 * 对应 iOS engine.messages.requestEditLiveLocation(messageId, stop, coordinate, heading, ...)
 *
 * TL inputMediaGeoLive#971fa843:
 *   flags: bit0=stopped, bit1=period, bit2=heading, bit3=proximity_notification_radius
 */
private class LiveLocationEditRequest <: TLObject {
    public var peer: TLObject = InputPeerEmpty()
    public var msgId: Int32 = 0
    public var stopped: Bool = false
    public var lat: Float64 = 0.0
    public var lng: Float64 = 0.0
    // P2-186: real heading from Location.direction (degrees 0-360); -1 = no heading
    public var headingDegrees: Int32 = -1

    public func getConstructorId(): UInt32 { return 0xdfd14005 }

    public func serialize(serializer: TLSerializer) {
        // flags: bit 14 = media present
        let outerFlags: Int32 = (1 << 14)
        serializer.writeInt32(outerFlags)
        serializer.writeRawBytes(this.peer.toBytes())
        serializer.writeInt32(this.msgId)
        // inputMediaGeoLive constructor
        serializer.writeUInt32(0x971fa843)
        if (this.stopped) {
            // bit0 = stopped
            serializer.writeInt32(1)
            // geoPoint = inputGeoPointEmpty
            serializer.writeUInt32(0xe4c123d6)
        } else {
            // P2-186: encode heading when available (bit2=heading present)
            let hasHeading = this.headingDegrees >= 0
            // bit1 = period present (we always omit period on update — server infers from session)
            // bit2 = heading present
            let mediaFlags: Int32 = if (hasHeading) { 4 } else { 0 }
            serializer.writeInt32(mediaFlags)
            // geoPoint
            let geoPoint = InputGeoPoint()
            geoPoint.lat = this.lat
            geoPoint.long = this.lng
            serializer.writeRawBytes(geoPoint.toBytes())
            // heading (only if flag bit2 set)
            if (hasHeading) {
                serializer.writeInt32(this.headingDegrees)
            }
        }
    }
}

// ==================== 活跃实时位置会话 ====================

/**
 * 活跃实时位置会话记录
 */
public class LiveLocationSession {
    public var peerType: String = ""
    public var peerId: Int64 = 0
    public var messageId: Int32 = 0
    public var expireTime: Int64 = 0    // Unix 时间戳（秒）
    public var isActive: Bool = true

    public init(peerType: String, peerId: Int64, messageId: Int32, period: Int32) {
        this.peerType = peerType
        this.peerId = peerId
        this.messageId = messageId
        // P2-185: INDEFINITE_PERIOD never expires (set expireTime to far future)
        if (period == LIVE_LOCATION_INDEFINITE_PERIOD) {
            this.expireTime = Int64(9999999999)
        } else {
            let nowSec = DateTime.now().toUnixTimeStamp().toSeconds()
            this.expireTime = nowSec + Int64(period)
        }
        this.isActive = true
    }
}

// ==================== 服务单例 ====================

private var _liveLocationManagerServiceInstance: Option<LiveLocationManagerService> = None

public func getLiveLocationManagerService(): LiveLocationManagerService {
    match (_liveLocationManagerServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = LiveLocationManagerService()
            _liveLocationManagerServiceInstance = Some(inst)
            return inst
    }
}

// ==================== LiveLocationManagerService ====================

/**
 * LiveLocationManagerService — 实时位置共享管理服务
 *
 * 对应 iOS LiveLocationManagerImpl：
 * - 维护活跃实时位置会话（broadcastToMessageIds）
 * - 后台周期上报设备坐标（updateDeviceCoordinate → messages.editMessage with inputMediaGeoLive）
 * - 停止会话（messages.editMessage with stopped=true）
 * - 取消特定 peer 的实时位置（cancelLiveLocation）
 *
 * 调用链：
 *   LiveLocationManagerService
 *     → DeviceLocationManagerService.requestLocation()
 *     → updateLiveLocationCoordinate()
 *       → MTProtoClient.sendRequest(LiveLocationEditRequest)   [messages.editMessage + media]
 */
public class LiveLocationManagerService {

    // 活跃会话表 msgId → LiveLocationSession
    private var _sessions: HashMap<Int32, LiveLocationSession> = HashMap<Int32, LiveLocationSession>()
    private let _sessionsMutex: ReentrantMutex = ReentrantMutex()

    // 广播循环运行标志
    private var _broadcastRunning: Bool = false
    private let _broadcastMutex: ReentrantMutex = ReentrantMutex()

    // 定位服务
    private var _locationService: DeviceLocationManagerService = getDeviceLocationManagerService()
    // 消息服务（用于 buildInputPeer）
    private var _msgService: RealMessageService = getRealMessageService()

    // 上报间隔（秒），对应 iOS 约 4 秒节流
    private let _updateIntervalSeconds: Int64 = 4

    // ==================== 公开 API ====================

    /**
     * 开始实时位置广播会话
     *
     * 对应 iOS update(broadcastToMessageIds:stopMessageIds:) 中新增条目 + rescheduleTimer
     *
     * @param peerType 对话类型 (user/chat/channel)
     * @param peerId   对话 ID
     * @param messageId 已发送实时位置消息的 msgId（由 RealMessageService.sendLiveLocation 返回）
     * @param period   分享持续时间（秒）
     */
    public func startLiveLocationBroadcast(
        peerType: String,
        peerId: Int64,
        messageId: Int32,
        period: Int32
    ): Unit {
        Hilog.info(0, "CjTelegram", "[LiveLocationMgr] startBroadcast: peer=${peerType}/${peerId}, msgId=${messageId}, period=${period}s")
        let session = LiveLocationSession(peerType, peerId, messageId, period)
        synchronized (_sessionsMutex) {
            this._sessions[messageId] = session
        }
        this.ensureBroadcastLoopRunning()
    }

    /**
     * 停止特定消息的实时位置广播（发送 stop 信号到服务器）
     *
     * 对应 iOS update() 中将 msgId 移入 stopMessageIds → editMessageDisposables 发送 stop=true
     *
     * @param messageId 要停止的消息 ID
     */
    public func stopLiveLocationBroadcast(messageId: Int32): Unit {
        Hilog.info(0, "CjTelegram", "[LiveLocationMgr] stopBroadcast: msgId=${messageId}")
        var session: Option<LiveLocationSession> = None
        synchronized (_sessionsMutex) {
            if (this._sessions.contains(messageId)) {
                let s = this._sessions[messageId]
                s.isActive = false
                session = Some(s)
                let _ = this._sessions.remove(messageId)
            }
        }
        match (session) {
            case Some(s) =>
                let _ = spawn {
                    let _ = this.sendStopSignal(s.peerType, s.peerId, messageId)
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[LiveLocationMgr] stopBroadcast: session not found for msgId=${messageId}")
        }
    }

    /**
     * 取消特定 peer 的所有活跃实时位置（对应 iOS cancelLiveLocation(peerId:)）
     *
     * @param peerId 对话 ID
     */
    public func cancelLiveLocation(peerId: Int64): Unit {
        Hilog.info(0, "CjTelegram", "[LiveLocationMgr] cancelLiveLocation: peerId=${peerId}")
        var toStop: ArrayList<LiveLocationSession> = ArrayList<LiveLocationSession>()
        synchronized (_sessionsMutex) {
            var keysToRemove: ArrayList<Int32> = ArrayList<Int32>()
            for ((msgId, session) in this._sessions) {
                if (session.peerId == peerId) {
                    session.isActive = false
                    toStop.add(session)
                    keysToRemove.add(msgId)
                }
            }
            for (k in keysToRemove) {
                let _ = this._sessions.remove(k)
            }
        }
        for (s in toStop) {
            let capturedSession = s
            let _ = spawn {
                let _ = this.sendStopSignal(capturedSession.peerType, capturedSession.peerId, capturedSession.messageId)
            }
        }
    }

    /**
     * 查询特定 peer 的活跃实时位置消息 ID（对应 iOS internalMessageForPeerId）
     *
     * @return Some(messageId) 若有活跃会话，否则 None
     */
    public func getActiveMessageId(peerId: Int64): Option<Int32> {
        synchronized (_sessionsMutex) {
            for ((_msgId, session) in this._sessions) {
                if (session.peerId == peerId && session.isActive) {
                    return Some(session.messageId)
                }
            }
        }
        return None
    }

    /**
     * 查询是否有任何活跃广播会话（对应 iOS hasActiveMessagesToBroadcast）
     */
    public func hasActiveBroadcasts(): Bool {
        synchronized (_sessionsMutex) {
            return this._sessions.size > 0
        }
    }

    /**
     * 立即触发一次坐标上报（对应 iOS pollOnce 场景）
     * 对所有活跃会话上报当前位置。
     */
    public func pollOnce(): Unit {
        let _ = spawn {
            this.doCoordinateUpdate()
        }
    }

    // ==================== 内部实现 ====================

    /**
     * 确保后台广播循环已启动
     * 对应 iOS 的 updateCoordinateDisposable + throttledDeviceLocation 机制
     */
    private func ensureBroadcastLoopRunning(): Unit {
        synchronized (_broadcastMutex) {
            if (this._broadcastRunning) { return }
            this._broadcastRunning = true
        }
        let _ = spawn {
            this.broadcastLoop()
        }
        Hilog.info(0, "CjTelegram", "[LiveLocationMgr] broadcast loop started")
    }

    /**
     * 后台周期广播循环
     * 每 _updateIntervalSeconds 秒上报一次坐标；无活跃会话时退出
     */
    private func broadcastLoop(): Unit {
        while (true) {
            let hasActive = this.hasActiveBroadcasts()
            if (!hasActive) {
                synchronized (_broadcastMutex) {
                    this._broadcastRunning = false
                }
                Hilog.info(0, "CjTelegram", "[LiveLocationMgr] no active sessions, broadcast loop stopped")
                return
            }
            this.doCoordinateUpdate()
            sleep(Duration.second * this._updateIntervalSeconds)
        }
    }

    /**
     * P2-180 gap fix: 获取当前坐标 + 设备 heading（via SingleLocationRequest + Location.direction）
     *
     * 使用 DeviceLocationManagerService.requestLocation() 统一位置获取，
     * 并从 LocationResult.directionDegrees 读取 Location.direction（0-360°，-1 无有效方向）。
     * 对应 iOS effectiveHeading = heading ?? location.course
     */
    private func doCoordinateUpdate(): Unit {
        let lat: Float64
        let lng: Float64
        let headingDeg: Int32
        let locResult = this._locationService.requestLocation(LocationAccuracyLevel.High)
        if (!locResult.success) {
            Hilog.info(0, "CjTelegram", "[LiveLocationMgr] doCoordinateUpdate: location unavailable")
            return
        }
        lat = locResult.latitude
        lng = locResult.longitude
        // P2-180: 使用 Location.direction（通过 LocationResult.directionDegrees）
        let dir = locResult.directionDegrees
        headingDeg = if (dir >= 0.0 && dir <= 360.0) { Int32(dir) } else { -1 }
        Hilog.info(0, "CjTelegram", "[LiveLocationMgr] doCoordinateUpdate: lat=${lat} lng=${lng} dir=${dir}")
        let nowSec = DateTime.now().toUnixTimeStamp().toSeconds()

        var sessionsSnapshot: ArrayList<LiveLocationSession> = ArrayList<LiveLocationSession>()
        var expiredIds: ArrayList<Int32> = ArrayList<Int32>()
        synchronized (_sessionsMutex) {
            for ((_msgId, session) in this._sessions) {
                if (!session.isActive) {
                    expiredIds.add(session.messageId)
                } else if (nowSec >= session.expireTime) {
                    // Period expired — mark for stop
                    session.isActive = false
                    expiredIds.add(session.messageId)
                } else {
                    sessionsSnapshot.add(session)
                }
            }
            for (k in expiredIds) {
                let _ = this._sessions.remove(k)
            }
        }

        // Stop expired sessions
        for (expId in expiredIds) {
            Hilog.info(0, "CjTelegram", "[LiveLocationMgr] session expired: msgId=${expId}")
        }

        // Update active sessions with real heading
        for (s in sessionsSnapshot) {
            let capturedHeading = headingDeg
            let ok = this.updateLiveLocationCoordinate(s.peerType, s.peerId, s.messageId, lat, lng, heading: capturedHeading)
            let okStr = if (ok) { "ok" } else { "fail" }
            Hilog.info(0, "CjTelegram", "[LiveLocationMgr] coordinate update msgId=${s.messageId} heading=${capturedHeading}: " + okStr)
        }
    }

    /**
     * P2-186 fix: 发送单次坐标更新到服务器（含真实 heading）
     *
     * TL: messages.editMessage (0xdfd14005)
     *   flags: bit 14 (media present)
     *   peer: InputPeer
     *   id: messageId
     *   media: inputMediaGeoLive (0x971fa843)
     *     flags: bit2 = heading (when heading >= 0)
     *     geo_point: inputGeoPoint
     *
     * P2-186: heading parameter comes from Location.direction (HarmonyOS equivalent of iOS CLLocation.course)
     * heading=-1 means no heading data available (direction arrow not shown)
     *
     * 调用链: LiveLocationManagerService → MTProtoClient.sendRequest()
     */
    public func updateLiveLocationCoordinate(
        peerType: String,
        peerId: Int64,
        messageId: Int32,
        lat: Float64,
        lng: Float64,
        heading!: Int32 = -1
    ): Bool {
        let client = getMTProtoClient()
        let req = LiveLocationEditRequest()
        req.peer = this._msgService.buildInputPeer(peerType, peerId)
        req.msgId = messageId
        req.stopped = false
        req.lat = lat
        req.lng = lng
        req.headingDegrees = heading
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[LiveLocationMgr] updateCoordinate msgId=${messageId}: empty response")
            return false
        }
        let d = TLDeserializer(responseData)
        let cid = d.readUInt32()
        // 0x2144ca19 = rpc_error, 0x74ae4240 = updates, 0x725b04c3 = updatesCombined
        if (cid == 0x2144ca19) {
            let code = d.readInt32()
            let msg = d.readString()
            Hilog.info(0, "CjTelegram", "[LiveLocationMgr] updateCoordinate RPC error ${code}: " + msg)
            return false
        }
        return true
    }

    /**
     * 发送 stop 信号到服务器（inputMediaGeoLive with stopped flag）
     *
     * TL: messages.editMessage
     *   media: inputMediaGeoLive, flags bit 1 (stopped=true)
     */
    private func sendStopSignal(peerType: String, peerId: Int64, messageId: Int32): Bool {
        Hilog.info(0, "CjTelegram", "[LiveLocationMgr] sendStopSignal: msgId=${messageId}")
        let client = getMTProtoClient()
        let req = LiveLocationEditRequest()
        req.peer = this._msgService.buildInputPeer(peerType, peerId)
        req.msgId = messageId
        req.stopped = true
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[LiveLocationMgr] sendStopSignal msgId=${messageId}: empty response")
            return false
        }
        let d = TLDeserializer(responseData)
        let cid = d.readUInt32()
        if (cid == 0x2144ca19) {
            let code = d.readInt32()
            let msg = d.readString()
            Hilog.info(0, "CjTelegram", "[LiveLocationMgr] sendStopSignal RPC error ${code}: " + msg)
            return false
        }
        Hilog.info(0, "CjTelegram", "[LiveLocationMgr] sendStopSignal msgId=${messageId}: ok")
        return true
    }
}
