package ohos_app_cangjie_entry.models

import kit.ArkUI.*
import std.collection.ArrayList

/**
 * 通话状态枚举 (Phase K3)
 * 
 * 对应 iOS CallSessionInternalState
 * 状态机：requesting → requested → confirming → active → dropping → terminated
 *        ringing → accepting → active → dropping → terminated
 */
public enum CallState {
    | Idle          // 空闲
    | Requesting    // 正在发起呼叫
    | Requested     // 已发送请求，等待对方响应
    | Ringing       // 收到来电，正在响铃
    | Accepting     // 正在接听
    | Confirming    // 正在确认 DH 密钥
    | Active        // 通话中
    | Dropping      // 正在挂断
    | Terminated    // 已结束
}

/**
 * 通话结束原因
 */
public enum CallEndReason {
    | Hangup        // 主动挂断
    | Busy          // 对方忙
    | Disconnect    // 连接断开
    | Missed        // 未接
    | Rejected      // 被拒绝
    | Error         // 错误
}

/**
 * 通话类型
 */
public enum CallMediaType {
    | Voice
    | Video
}

/**
 * 通话记录（用于通话历史页面）
 * 纯数据类，不使用 @Observed（在后台线程创建，@Publish 会触发主线程检查异常）
 */
public class CallRecord {
    public var id: Int64 = 0
    public var peerId: Int64 = 0
    public var peerName: String = ""
    public var peerAvatarPath: String = ""
    public var isOutgoing: Bool = false
    public var isMissed: Bool = false
    public var mediaType: String = "voice"
    public var timestamp: String = ""
    public var duration: String = ""
    public var date: Int32 = 0
    public var msgId: Int32 = 0
    // messageActionPhoneCall video flag (flags.2) and PhoneCallDiscardReason constructor (0 = none);
    // PeerInfo call list type text (ItemListCallListItem.swift:64-112 stringForCallType).
    public var isVideo: Bool = false
    public var discardReason: UInt32 = 0
    // iOS 合并组瞬态字段（CallHistoryPage.groupedVisibleCalls 每次渲染重算填充）：
    // groupCount=相邻同 peer 合并的条数（>1 时名字后显示 " (N)"）,groupMsgIds=组内全部 msgId。
    public var groupCount: Int64 = 1
    public var groupMsgIds: ArrayList<Int32> = ArrayList<Int32>()
}

/**
 * 通话会话模型 (Phase K3)
 * 
 * 对应 iOS CallSession + CallSessionInternalState
 * 纯数据类，不使用 @Observed（在后台线程创建，@Publish 会触发主线程检查异常）
 */
public class CallSession {
    public var callId: Int64 = 0
    public var accessHash: Int64 = 0
    public var state: String = "idle"
    public var isVideo: Bool = false
    public var isOutgoing: Bool = false
    public var peerId: Int64 = 0
    public var peerName: String = ""
    public var peerAccessHash: Int64 = 0
    public var peerAvatarPath: String = ""
    public var dhA: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var dhGA: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var dhGAHash: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var dhGB: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var sharedKey: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var keyFingerprint: Int64 = 0
    public var dhG: Int32 = 0
    public var dhP: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var startTime: Int64 = 0
    public var duration: Int64 = 0
    // tgcalls reports Reconnecting during its initial handshake as well as after a real drop.
    // Track whether media was ever established so UI can distinguish Connecting from Reconnecting.
    public var hasEverConnected: Bool = false
    public var isMuted: Bool = false
    public var isSpeaker: Bool = false
    public var isLocalVideoEnabled: Bool = false
    // Incremented on every explicit camera state change; delayed native retries only apply when
    // their captured generation is still current.
    public var localVideoGeneration: Int64 = 0
    public var isRemoteVideoEnabled: Bool = false
    // P2-060: 远端状态字段 — 由 VoIP 引擎 (P2-067) 接线后填充
    public var isRemoteCameraOff: Bool = false
    public var isRemoteMicOff: Bool = false
    public var isFrontCamera: Bool = true
    public var signalBars: Int32 = 4
    public var endReason: String = ""
    public var needRating: Bool = false
    public var keyEmoji: String = ""
    // 主叫 requested 态下对端已确认收到来电（phoneCallWaiting.receive_date 下发）。
    // iOS CallSessionManager .requested(remoteConfirmationTimestamp:) → CallSessionState.requesting(ringing:)，
    // UI 据此把 "Requesting" 换成 "Ringing"（CallControllerNodeV2.updateCallState）。
    public var remoteRinging: Bool = false
    public var remoteRingingSinceMs: Int64 = 0

    // 连接端点 (Phase K6) — 从 phoneCall(active) 响应中解析
    public var connections: ArrayList<ConnectionEndpoint> = ArrayList<ConnectionEndpoint>()

    // 协议版本 (Phase K6)
    public var protocolVersion: String = ""
    public var maxLayer: Int32 = 0
    public var minLayer: Int32 = 0
}

/**
 * 连接端点（中继服务器信息）(Phase K6)
 * 
 * 对应 Telegram-iOS CallSessionConnection (Reflector / WebRtcReflector)
 */
public class ConnectionEndpoint {
    public var id: Int64 = 0
    public var ip: String = ""
    public var ipv6: String = ""
    public var port: Int32 = 0
    // 标准反射器字段
    public var peerTag: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var isTcp: Bool = false
    // WebRTC 反射器字段
    public var isWebrtc: Bool = false
    public var username: String = ""
    public var password: String = ""
    public var hasTurn: Bool = false
    public var hasStun: Bool = false
}

/**
 * 获取通话状态的显示文字
 */
public func getCallStateText(state: String): String {
    if (state == "requesting") { return "Calling..." }
    if (state == "requested") { return "Ringing..." }
    if (state == "ringing") { return "Incoming call" }
    if (state == "accepting") { return "Connecting..." }
    if (state == "confirming") { return "Exchanging keys..." }
    if (state == "active") { return "Connected" }
    if (state == "reconnecting") { return "Reconnecting..." }
    if (state == "dropping") { return "Ending..." }
    if (state == "terminated") { return "Call ended" }
    return ""
}

/**
 * 格式化通话时长（秒 → MM:SS 或 HH:MM:SS）
 */
public func formatCallDuration(seconds: Int64): String {
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    let s = seconds % 60

    if (h > 0) {
        let hStr = if (h < 10) { "0${h}" } else { "${h}" }
        let mStr = if (m < 10) { "0${m}" } else { "${m}" }
        let sStr = if (s < 10) { "0${s}" } else { "${s}" }
        return "${hStr}:${mStr}:${sStr}"
    } else {
        let mStr = if (m < 10) { "0${m}" } else { "${m}" }
        let sStr = if (s < 10) { "0${s}" } else { "${s}" }
        return "${mStr}:${sStr}"
    }
}
