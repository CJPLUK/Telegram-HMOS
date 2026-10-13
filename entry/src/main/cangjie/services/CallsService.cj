package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.{getMTProtoClient, getGroupCallMessagesClient, skipMessageEntitiesVector, TLDeserializer, TLObject, MTProtoClient, InputPeerChannel, InputPeerChat, InputPeerSelf, InputPeerUser, PhoneGetGroupCall, PhoneToggleGroupCallMessagesEnabled, PhoneGetGroupCallJoinAs, PhoneToggleGroupCallStartSubscription, PhoneCreateGroupCall, PhoneGetGroupParticipants, PhoneLeaveGroupCall, PhoneDiscardGroupCall, PhoneJoinGroupCall, PhoneJoinGroupCallPresentation, PhoneInviteToGroupCall, PhoneEditGroupCallTitle, PhoneExportGroupCallInvite, PhoneStartScheduledGroupCall, PhoneGetGroupCallStreamChannels, PhoneGetGroupCallStreamRtmpUrl, PhoneToggleGroupCallRecord, PhoneEditGroupCallParticipant, PhoneLeaveGroupCallPresentation, PhoneCheckGroupCall, PhoneSendGroupCallMessage, PhoneCreateConferenceCall, UserResponse, ChatResponse, SOURCE_LAYER_GATE}
import std.collection.{ArrayList, HashMap}
import std.time.DateTime
import std.sync.ReentrantMutex
import std.random.Random

/**
 * 群组通话 API 服务 (TelegramEngine.Calls)
 *
 * 仅实现 CallService.cj 中不存在的 group call 管理功能。
 * 1:1 通话、通话历史、rateCall 等由 CallService 提供。
 *
 * 参考: Telegram-iOS TelegramEngineCalls.swift, GroupCalls.swift
 */
private var _callsServiceInstance: Option<CallsService> = None

public func getCallsService(): CallsService {
    match (_callsServiceInstance) {
        case Some(s) => s
        case None =>
            let s = CallsService()
            _callsServiceInstance = Some(s)
            s
    }
}

/**
 * 群组通话简要信息 — 供 UI 使用
 */
public class GroupCallInfo {
    public var callId: Int64 = 0
    public var accessHash: Int64 = 0
    public var participantCount: Int32 = 0
    public var participantsNextOffset: String = ""
    public var title: String = ""
    public var scheduleDate: Int32 = 0          // schedule_date:flags.7?int，>0 = 还没开始的预约通话
    public var scheduleStartSubscribed: Bool = false   // flags.8
}

/**
 * 群组通话参与者简要信息
 */
/** GroupCallParticipantVideo（iOS Participant.VideoDescription，GroupCalls.swift:1215） */
public class GroupCallVideoInfo {
    public var endpointId: String = ""
    public var isPaused: Bool = false
    public var audioSsrc: UInt32 = 0
    // 每组："SIM"/"FID" + ssrc 列表
    public var groupSemantics: ArrayList<String> = ArrayList<String>()
    public var groupSsrcs: ArrayList<ArrayList<UInt32>> = ArrayList<ArrayList<UInt32>>()

    public func toJsonGroups(): String {
        var out = "["
        var i: Int64 = 0
        while (i < groupSemantics.size) {
            if (i > 0) { out = out + "," }
            var ss = ""
            var j: Int64 = 0
            while (j < groupSsrcs[i].size) {
                if (j > 0) { ss = ss + "," }
                ss = ss + "${groupSsrcs[i][j]}"
                j = j + 1
            }
            out = out + "{\"semantics\":\"${groupSemantics[i]}\",\"ssrcs\":[${ss}]}"
            i = i + 1
        }
        return out + "]"
    }
}

/** "Display Me As" 的一个可选身份（iOS FoundPeer / cachedGroupCallDisplayAsAvailablePeers）。 */
public class GroupCallJoinAsPeer {
    public var peerType: String = "user"
    public var peerId: Int64 = 0
    public var accessHash: Int64 = 0
    public var name: String = ""
}

/** groupCall.flags 里的设置位（iOS GroupCalls.swift:161、801-802）；取不到时按群聊默认。 */
public class GroupCallSettingsFlags {
    public var messagesEnabled: Bool = true
    public var canChangeMessages: Bool = false
    public var joinMuted: Bool = false
    public var canChangeJoinMuted: Bool = false
}

public class GroupCallParticipantInfo {
    public var video: Option<GroupCallVideoInfo> = None
    public var presentation: Option<GroupCallVideoInfo> = None
    public var peerId: Int64 = 0
    public var isMuted: Bool = false
    public var isCurrentUser: Bool = false
    // —— 以下对位 iOS GroupCallParticipantsContext.Participant（GroupCalls.swift:1204）——
    public var peerType: String = "user"      // user / chat / channel
    public var source: UInt32 = 0             // 音频 ssrc（TL source:int 的位模式）
    public var left: Bool = false             // flags.1
    public var canSelfUnmute: Bool = false    // flags.2
    public var justJoined: Bool = false       // flags.4
    public var isMin: Bool = false            // flags.8
    public var mutedByYou: Bool = false       // flags.9
    public var videoJoined: Bool = false      // flags.15
    public var date: Int64 = 0
    public var activeDate: Int64 = 0
    public var volume: Int32 = 10000          // 10000 = 100%
    public var hasVolume: Bool = false
    public var about: String = ""
    public var raiseHandRating: Int64 = 0
    public var hasRaiseHand: Bool = false
    public var name: String = ""
}

/**
 * 群组通话加入结果 — joinGroupCall / joinGroupCallPresentation 响应
 * 服务器返回 Updates，内嵌 updateGroupCall，本结构提取关键信令字段
 */
public class GroupCallJoinResult {
    public var callId: Int64 = 0
    public var accessHash: Int64 = 0
    // SDP/ICE 参数 JSON — 由 tgcalls/WebRTC 使用
    public var joinResponsePayload: String = ""
    public var isScreencast: Bool = false
}

/**
 * 流直播频道信息 — getGroupCallStreamChannels 响应
 * groupCallStreamChannel#80eb48af channel:int scale:int last_timestamp_ms:long
 * TL codegen verified (ctor 0x80eb48af)
 */
public class GroupCallStreamChannelInfo {
    public var channel: Int32 = 0
    public var scale: Int32 = 0
    public var lastTimestampMs: Int64 = 0
}

/**
 * 流直播 RTMP URL — getGroupCallStreamRtmpUrl 响应
 * phone.groupCallStreamRtmpUrl#2dbf3432 url:string key:string
 * TL codegen verified (ctor 0x2dbf3432)
 */
public class GroupCallStreamRtmpCredentials {
    public var url: String = ""
    public var streamKey: String = ""
}

public class CallsService {

    /**
     * phone.getGroupCall — 获取群组通话信息
     * 参考: GroupCalls.swift _internal_getCurrentGroupCall
     */
    public func getGroupCall(callId: Int64, accessHash: Int64): Option<GroupCallInfo> {
        if (callId == 0 || accessHash == 0) { return None }
        try {
            let client = getMTProtoClient()
            let req = PhoneGetGroupCall()
            req.callId = callId
            req.callAccessHash = accessHash
            req.limit = 4
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size < 4) { return None }
            let info = parseGroupCallResponse(responseData)
            return Some(info)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] getGroupCall failed")
            return None
        }
    }

    /**
     * phone.createGroupCall — 创建群组通话
     * peerId: 群组/频道 ID
     * isChannel: true=频道, false=群组
     * 参考: GroupCalls.swift _internal_createGroupCall
     */
    public func createGroupCall(peerId: Int64, peerAccessHash: Int64, isChannel: Bool, title: String, scheduleDate: Int32): Option<GroupCallInfo> {
        if (peerId <= 0) { return None }
        try {
            let client = getMTProtoClient()
            let req = PhoneCreateGroupCall()
            if (isChannel) {
                let peer = InputPeerChannel()
                peer.channelId = peerId
                peer.accessHash = peerAccessHash
                req.peer = peer
            } else {
                let peer = InputPeerChat()
                peer.chatId = peerId
                req.peer = peer
            }
            req.randomId = Int32(DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() % 2147483647)
            req.title = title
            req.scheduleDate = scheduleDate
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size < 4) { return None }
            let info = parseCreateGroupCallResponse(responseData)
            return Some(info)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] createGroupCall failed")
            return None
        }
    }

    /**
     * phone.getGroupParticipants — 获取群组通话参与者列表
     * 参考: GroupCalls.swift getGroupCallParticipants
     */
    public func getGroupParticipants(callId: Int64, accessHash: Int64, offset: String, limit: Int32): ArrayList<GroupCallParticipantInfo> {
        let (result, _) = this.getGroupParticipantsVersioned(callId, accessHash, offset, limit)
        return result
    }

    /**
     * 同 getGroupParticipants，另返回 phone.groupParticipants.version（iOS GroupCalls.swift:563-565，
     * 作为 updateGroupCallParticipants 的版本基线）；version 读不到时为 0。
     */
    public func getGroupParticipantsVersioned(callId: Int64, accessHash: Int64, offset: String, limit: Int32): (ArrayList<GroupCallParticipantInfo>, Int32) {
        let result = ArrayList<GroupCallParticipantInfo>()
        if (callId == 0 || accessHash == 0) { return (result, 0) }
        try {
            let client = getMTProtoClient()
            let req = PhoneGetGroupParticipants()
            req.callId = callId
            req.callAccessHash = accessHash
            req.offset = offset
            req.limit = if (limit > 0) { limit } else { 50 }
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size < 4) { return (result, 0) }
            let version = parseGroupParticipantsResponse(responseData, result)
            return (result, version)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] getGroupParticipants failed")
            return (result, 0)
        }
    }

    /**
     * 按音频 ssrc 反查参与者（iOS ensureHaveParticipants → getGroupCallParticipants(ssrcs:)，
     * GroupCalls.swift:2145-2170）。
     */
    public func getGroupParticipantsBySources(callId: Int64, accessHash: Int64, sources: ArrayList<UInt32>): ArrayList<GroupCallParticipantInfo> {
        let result = ArrayList<GroupCallParticipantInfo>()
        if (callId == 0 || accessHash == 0 || sources.size == 0) { return result }
        try {
            let req = PhoneGetGroupParticipants()
            req.callId = callId
            req.callAccessHash = accessHash
            req.offset = ""
            req.limit = 100
            let arr = Array<Int32>(sources.size, repeat: 0)
            var i: Int64 = 0
            while (i < sources.size) { arr[i] = ssrcToInt32(sources[i]); i = i + 1 }
            req.sources = arr
            let responseData = getMTProtoClient().sendRequest(req.toBytes())
            if (responseData.size < 4) { return result }
            let _ = parseGroupParticipantsResponse(responseData, result)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] getGroupParticipantsBySources failed: ${e}")
        }
        return result
    }

    /**
     * phone.checkGroupCall — 返回服务端仍认的 ssrc。None = 请求失败（不据此重连）。
     */
    public func checkGroupCall(callId: Int64, accessHash: Int64, source: UInt32): Option<Bool> {
        if (callId == 0 || accessHash == 0) { return None }
        try {
            let req = PhoneCheckGroupCall()
            req.callId = callId
            req.callAccessHash = accessHash
            req.sources = [ssrcToInt32(source)]
            let data = getMTProtoClient().sendRequest(req.toBytes())
            if (data.size < 8) { return None }
            let d = TLDeserializer(data)
            let head = d.readUInt32()
            if (head == 0x2144ca19) {
                // rpc_error error_code:int error_message:string
                let _ = d.readInt32()
                let message = d.readString()
                // 服务器已不认这次入会（媒体连接没在时限内建立、或被顶掉）。iOS 把
                // checkGroupCall 的错误一律当作"ssrc 不在"→ 重新入会；之前这里返回 None，
                // 页面就永远停在 Connecting（真机实锤）。
                if (message.contains("GROUPCALL_JOIN_MISSING") || message.contains("GROUPCALL_SSRC")) {
                    Hilog.info(0, "CjTelegram", "[CallsService] checkGroupCall: ${message} → treat as not joined")
                    return Some(false)
                }
                return None
            }
            if (head != 0x1cb5c415) { return None }
            let n = d.readInt32()
            var i: Int64 = 0
            while (i < Int64(n)) {
                if (UInt32(d.readUInt32()) == source) { return Some(true) }
                i = i + 1
            }
            return Some(false)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] checkGroupCall failed: ${e}")
            return None
        }
    }

    /**
     * 自己的静音 / 举手（participant = inputPeerSelf）。
     * iOS GroupCallParticipantsContext.updateMuteState:2426 / raiseHand:2621。
     */
    public func editSelfParticipant(callId: Int64, accessHash: Int64,
                                    muted: Bool, hasMuted: Bool,
                                    raiseHand: Bool, hasRaiseHand: Bool): Bool {
        if (callId == 0 || accessHash == 0) { return false }
        try {
            let req = PhoneEditGroupCallParticipant()
            req.callId = callId
            req.callAccessHash = accessHash
            req.participantIsSelf = true
            req.participantPeerBytes = this.joinAsInputPeerBytes()
            req.muted = muted
            req.hasMuted = hasMuted
            req.raiseHand = raiseHand
            req.hasRaiseHand = hasRaiseHand
            let _ = getMTProtoClient().sendRequest(req.toBytes())
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] editSelfParticipant failed: ${e}")
            return false
        }
    }

    /** layer-228 派生会话（见 getGroupCallMessagesClient）。只许经 onLayer228 使用。 */
    private func groupCallMessagesClient(): MTProtoClient {
        return getGroupCallMessagesClient({ data: Array<Byte> => this.scanForGroupCallMessages(data) })
    }

    /**
     * 在 layer 228 上发一条请求，然后立刻把 auth key 的 layer 声明回 214。
     * 串行化：两个 228 操作交错的话，前一个的 reassert 会落在后一个的请求之前。
     */
    private func onLayer228(request: Array<Byte>): Array<Byte> {
        synchronized(SOURCE_LAYER_GATE) {
            var data = Array<Byte>()
            try {
                let client = this.groupCallMessagesClient()
                client.requireInitOnNextRequest()
                data = client.sendRequest(request)
            } finally {
                try {
                    getMTProtoClient().reassertLayer()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CallsService] layer re-assert failed: ${e}")
                }
            }
            return data
        }
    }

    /**
     * 其它服务借用同一条 layer-228 通道（串行、发完即 reassert）。
     * 当前用途：PeerInfoService 取 userFull.note（该字段只在 layer ≥ 222 的编码里，主会话 214 拿不到）。
     */
    public func sendOnLayer228(request: Array<Byte>): Array<Byte> {
        return this.onLayer228(request)
    }

    /**
     * 入会后调用：在派生会话上取一次 phone.getGroupCall(limit 0)。一举两得——首个请求自带
     * invokeWithLayer+initConnection 把会话建起来；layer 228 的 groupCall.flags 才带
     * messages_enabled(bit17) / can_change_messages_enabled(bit18)（GroupCalls.swift:801-802）。
     * 返回 (messagesEnabled, canChange)；取不到时按 iOS 群聊默认值 (true, false)。
     */
    public func warmUpGroupCallMessages(callId: Int64, accessHash: Int64): GroupCallSettingsFlags {
        try {
            let req = PhoneGetGroupCall()
            req.callId = callId
            req.callAccessHash = accessHash
            req.limit = 0
            let data = this.onLayer228(req.toBytes())
            if (data.size >= 12) {
                let d = TLDeserializer(data)
                let outer = d.readUInt32()
                let inner = d.readUInt32()
                let flags = d.readInt32()
                // phone.groupCall#9e727aad → groupCall（discarded 形态没有这两个位）
                if (outer == 0x9e727aad && inner != 0x7780bcb4) {
                    let out = GroupCallSettingsFlags()
                    out.messagesEnabled = (flags & (1 << 17)) != 0
                    out.canChangeMessages = (flags & (1 << 18)) != 0
                    out.joinMuted = (flags & (1 << 1)) != 0
                    out.canChangeJoinMuted = (flags & (1 << 2)) != 0
                    Hilog.info(0, "CjTelegram",
                        "[CallsService] groupCall settings (layer 228): messagesEnabled=${out.messagesEnabled} canChange=${out.canChangeMessages} joinMuted=${out.joinMuted} canChangeJoinMuted=${out.canChangeJoinMuted}")
                    return out
                }
            }
            Hilog.info(0, "CjTelegram", "[CallsService] group-call messages session warmed up (${data.size} bytes, flags unreadable)")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] group-call messages session warm-up failed: ${e}")
        }
        return GroupCallSettingsFlags()
    }

    /**
     * 可用的 "Display Me As" 身份（自己 + 自己管理的频道/群）。
     * iOS 只在数量 > 1 时才显示该菜单项（VideoChatScreenMoreMenu.swift:167）。
     */
    public func getGroupCallJoinAs(chatPeerType: String, chatPeerId: Int64, chatAccessHash: Int64): ArrayList<GroupCallJoinAsPeer> {
        let out = ArrayList<GroupCallJoinAsPeer>()
        if (chatPeerId == 0) { return out }
        try {
            let req = PhoneGetGroupCallJoinAs()
            if (chatPeerType == "channel") {
                let p = InputPeerChannel()
                p.channelId = chatPeerId
                p.accessHash = chatAccessHash
                req.peer = p
            } else {
                let p = InputPeerChat()
                p.chatId = chatPeerId
                req.peer = p
            }
            let data = getMTProtoClient().sendRequest(req.toBytes())
            if (data.size < 12) { return out }
            let d = TLDeserializer(data)
            let head = d.readUInt32()
            if (head == 0x2144ca19) {
                let code = d.readInt32()
                let message = d.readString()
                Hilog.info(0, "CjTelegram", "[CallsService] getGroupCallJoinAs rejected: ${code} ${message}")
                return out
            }
            if (head != 0xafe5623f || d.readUInt32() != 0x1cb5c415) { return out }
            let n = Int64(d.readInt32())
            for (_ in 0..n) {
                let ctor = d.readUInt32()
                let item = GroupCallJoinAsPeer()
                item.peerId = d.readInt64()
                item.peerType = if (ctor == 0x59511722) { "user" } else if (ctor == 0x36c6019a) { "chat" } else { "channel" }
                out.add(item)
            }
            // chats / users：补名字和 accessHash；解析失败不影响 peers 本身
            try {
                if (d.readUInt32() == 0x1cb5c415) {
                    let cn = Int64(d.readInt32())
                    for (_ in 0..cn) {
                        let c = ChatResponse.deserializeBoxed(d)
                        for (item in out) {
                            if (item.peerType != "user" && item.peerId == c.id) {
                                item.name = c.title
                                item.accessHash = c.accessHash
                            }
                        }
                    }
                }
                if (d.readUInt32() == 0x1cb5c415) {
                    let un = Int64(d.readInt32())
                    for (_ in 0..un) {
                        let u = UserResponse.deserializeBoxed(d)
                        for (item in out) {
                            if (item.peerType == "user" && item.peerId == u.id) {
                                item.name = if (u.lastName.size > 0) { "${u.firstName} ${u.lastName}" } else { u.firstName }
                                item.accessHash = u.accessHash
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[CallsService] getGroupCallJoinAs: names partially parsed: ${e}")
            }
            var summary = ""
            for (item in out) { summary = summary + " ${item.peerType}:${item.name}" }
            Hilog.info(0, "CjTelegram", "[CallsService] getGroupCallJoinAs: ${out.size} peers:${summary}")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] getGroupCallJoinAs failed: ${e}")
        }
        return out
    }

    // ---- 当前以谁的身份在通话里（None = 自己）。入会、改自己的静音/举手/视频都要用它。----
    private var joinAsPeer: Option<GroupCallJoinAsPeer> = None

    public func setJoinAsPeer(peer: Option<GroupCallJoinAsPeer>): Unit {
        this.joinAsPeer = peer
    }

    /** 空数组 = inputPeerSelf */
    private func joinAsInputPeerBytes(): Array<Byte> {
        match (this.joinAsPeer) {
            case Some(p) =>
                if (p.peerType == "channel") {
                    let ip = InputPeerChannel()
                    ip.channelId = p.peerId
                    ip.accessHash = p.accessHash
                    return ip.toBytes()
                }
                if (p.peerType == "chat") {
                    let ip = InputPeerChat()
                    ip.chatId = p.peerId
                    return ip.toBytes()
                }
                return Array<Byte>()
            case None => return Array<Byte>()
        }
    }

    /** 预约通话开始时提醒我 / 取消提醒。 */
    public func toggleGroupCallStartSubscription(callId: Int64, accessHash: Int64, subscribed: Bool): Bool {
        if (callId == 0 || accessHash == 0) { return false }
        try {
            let req = PhoneToggleGroupCallStartSubscription()
            req.callId = callId
            req.callAccessHash = accessHash
            req.subscribed = subscribed
            let data = getMTProtoClient().sendRequest(req.toBytes())
            if (data.size >= 4) {
                let d = TLDeserializer(data)
                if (d.readUInt32() == 0x2144ca19) {
                    let code = d.readInt32()
                    let message = d.readString()
                    Hilog.info(0, "CjTelegram", "[CallsService] start subscription=${subscribed} rejected: ${code} ${message}")
                    return false
                }
                Hilog.info(0, "CjTelegram", "[CallsService] start subscription=${subscribed} OK")
                return true
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] start subscription failed: ${e}")
        }
        return false
    }

    /** iOS updateDefaultParticipantsAreMuted（GroupCalls.swift:2650）。 */
    public func setGroupCallJoinMuted(callId: Int64, accessHash: Int64, muted: Bool): Bool {
        if (callId == 0 || accessHash == 0) { return false }
        try {
            let req = PhoneToggleGroupCallMessagesEnabled()
            req.callId = callId
            req.callAccessHash = accessHash
            req.enabled = muted
            req.isJoinMuted = true
            let data = this.onLayer228(req.toBytes())
            if (data.size >= 4) {
                let d = TLDeserializer(data)
                if (d.readUInt32() == 0x2144ca19) {
                    let code = d.readInt32()
                    let message = d.readString()
                    Hilog.info(0, "CjTelegram", "[CallsService] toggle joinMuted=${muted} rejected: ${code} ${message}")
                    return false
                }
                Hilog.info(0, "CjTelegram", "[CallsService] toggle joinMuted=${muted} OK (${data.size} bytes)")
                return true
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] toggle joinMuted failed: ${e}")
        }
        return false
    }

    /** iOS updateMessagesEnabled（GroupCalls.swift:2667）。返回服务器是否接受。 */
    public func setGroupCallMessagesEnabled(callId: Int64, accessHash: Int64, enabled: Bool): Bool {
        if (callId == 0 || accessHash == 0) { return false }
        try {
            let req = PhoneToggleGroupCallMessagesEnabled()
            req.callId = callId
            req.callAccessHash = accessHash
            req.enabled = enabled
            let data = this.onLayer228(req.toBytes())
            if (data.size >= 4) {
                let d = TLDeserializer(data)
                if (d.readUInt32() == 0x2144ca19) {
                    let code = d.readInt32()
                    let message = d.readString()
                    Hilog.info(0, "CjTelegram", "[CallsService] toggle messagesEnabled=${enabled} rejected: ${code} ${message}")
                    return false
                }
                Hilog.info(0, "CjTelegram", "[CallsService] toggle messagesEnabled=${enabled} OK (${data.size} bytes)")
                return true
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] toggle messagesEnabled failed: ${e}")
        }
        return false
    }

    /**
     * 这条会话按 layer 228 收 update，其它类型的结构与本工程 214 的解析器不一定一致，
     * 所以不做逐条解析：只在字节流里找 updateGroupCallMessage#d8326f0d，从那里按固定结构读。
     */
    private func scanForGroupCallMessages(data: Array<Byte>): Unit {
        Hilog.info(0, "CjTelegram", "[CallsService] layer-228 session update, ${data.size} bytes")
        var pos: Int64 = 0
        while (pos + 4 <= data.size) {
            if (data[pos] == 0x0D && data[pos + 1] == 0x6F && data[pos + 2] == 0x32 && data[pos + 3] == 0xD8) {
                try {
                    let base = pos + 4
                    let tail = Array<Byte>(data.size - base, { i: Int64 => data[base + i] })
                    let d = TLDeserializer(tail)
                    if (d.readUInt32() == 0xd8aa840f) {
                        let callId = d.readInt64()
                        let _ = d.readInt64()
                        if (d.readUInt32() == 0x1a8afc7e) {
                            let mflags = d.readInt32()
                            let msgId = Int64(d.readInt32())
                            let peerCtor = d.readUInt32()
                            if (peerCtor == 0x59511722 || peerCtor == 0x36c6019a || peerCtor == 0xa2a5371e) {
                                let fromId = d.readInt64()
                                let date = Int64(d.readInt32())
                                if (d.readUInt32() == 0x751f3146) {
                                    let text = d.readString()
                                    let _ = mflags
                                    Hilog.info(0, "CjTelegram", "[CallsService] updateGroupCallMessage (layer-228 session) from=${fromId} len=${text.size}")
                                    getGroupCallSession().onIncomingMessage(callId, msgId, fromId, text, date)
                                }
                            }
                        }
                    }
                } catch (_: Exception) {}
            }
            // groupCall（layer 228，ctor 见 warmUp 日志 0xefb2b617）：flags:# … id:long —— 别人改了
            // messages_enabled 时靠它同步（主会话 layer 214 的 updateGroupCall 没有这一位）。
            // 其后 access_hash:long participants_count:int 同 iOS Api8.parse_groupCall，人数交给名单收敛。
            if (data[pos] == 0x17 && data[pos + 1] == 0xB6 && data[pos + 2] == 0xB2 && data[pos + 3] == 0xEF
                && pos + 16 <= data.size) {
                try {
                    let base = pos + 4
                    let tailSize = if (pos + 28 <= data.size) { 24 } else { 12 }
                    let tail = Array<Byte>(tailSize, { i: Int64 => data[base + i] })
                    let d = TLDeserializer(tail)
                    let flags = d.readInt32()
                    let callId = d.readInt64()
                    getGroupCallSession().onMessagesSettings(callId, (flags & (1 << 17)) != 0, (flags & (1 << 18)) != 0)
                    if (tailSize == 24) {
                        let _ = d.readInt64()
                        let count = Int64(d.readInt32())
                        getGroupCallSession().onParticipantsCount(callId, count)
                    }
                } catch (_: Exception) {}
            }
            // updateGroupCallParticipants#f2ebdb4e call:InputGroupCall participants:Vector<GroupCallParticipant> version:int
            // （iOS Api29.parse_updateGroupCallParticipants）。同一 auth key 的派生会话也订阅了推送，
            // 服务器可能只把成员变化投到这条会话上；与主会话重复到达时由版本号去重。
            if (data[pos] == 0x4E && data[pos + 1] == 0xDB && data[pos + 2] == 0xEB && data[pos + 3] == 0xF2) {
                try {
                    let base = pos + 4
                    let tail = Array<Byte>(data.size - base, { i: Int64 => data[base + i] })
                    let d = TLDeserializer(tail)
                    if (d.readUInt32() == 0xd8aa840f) {
                        let callId = d.readInt64()
                        let _ = d.readInt64()
                        if (d.readUInt32() == 0x1cb5c415) {
                            let n = d.readInt32()
                            let list = ArrayList<GroupCallParticipantInfo>()
                            var ok = n >= 0
                            var i: Int64 = 0
                            while (ok && i < Int64(n)) {
                                match (this.parseGroupCallParticipant(d)) {
                                    case Some(p) => list.add(p)
                                    case None => ok = false
                                }
                                i = i + 1
                            }
                            if (ok) {
                                let version = d.readInt32()
                                Hilog.info(0, "CjTelegram", "[CallsService] updateGroupCallParticipants (layer-228 session) n=${n} version=${version}")
                                getGroupCallSession().applyParticipantUpdates(callId, list, version)
                            }
                        }
                    }
                } catch (_: Exception) {}
            }
            pos = pos + 1
        }
    }

    /**
     * 通话内消息。返回 (是否成功, 服务器错误文本)。iOS 对发送错误静默（GroupCalls.swift:4297-4426）。
     */
    public func sendGroupCallMessage(callId: Int64, accessHash: Int64, randomId: Int64, text: String): (Bool, String) {
        if (callId == 0 || accessHash == 0 || text.size == 0) { return (false, "invalid") }
        try {
            let req = PhoneSendGroupCallMessage()
            req.callId = callId
            req.callAccessHash = accessHash
            req.randomId = randomId
            req.text = text
            let data = this.onLayer228(req.toBytes())
            if (data.size >= 4) {
                let d = TLDeserializer(data)
                let head = d.readUInt32()
                if (head == 0x2144ca19) {
                    let code = d.readInt32()
                    let message = d.readString()
                    Hilog.info(0, "CjTelegram", "[CallsService] sendGroupCallMessage rejected: ${code} ${message}")
                    return (false, message)
                }
                Hilog.info(0, "CjTelegram", "[CallsService] sendGroupCallMessage OK response=${data.size} bytes ctor=${head}")
                return (true, "")
            }
            return (false, "empty response")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] sendGroupCallMessage failed: ${e}")
            return (false, "${e}")
        }
    }

    /**
     * 自己的视频开关（iOS updateVideoState:2533 → editGroupCallParticipant video_stopped bit3 / video_paused bit4）。
     */
    public func editSelfVideoState(callId: Int64, accessHash: Int64, videoStopped: Bool, videoPaused: Bool): Bool {
        if (callId == 0 || accessHash == 0) { return false }
        try {
            let req = PhoneEditGroupCallParticipant()
            req.callId = callId
            req.callAccessHash = accessHash
            req.participantIsSelf = true
            req.participantPeerBytes = this.joinAsInputPeerBytes()
            req.videoStopped = videoStopped
            req.hasVideoStopped = true
            req.videoPaused = videoPaused
            req.hasVideoPaused = true
            let _ = getMTProtoClient().sendRequest(req.toBytes())
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] editSelfVideoState failed: ${e}")
            return false
        }
    }

    /**
     * phone.leaveGroupCall — 离开群组通话
     * source: 离开来源标识，通常传 0
     */
    public func leaveGroupCall(callId: Int64, accessHash: Int64, source: Int32): Bool {
        if (callId == 0 || accessHash == 0) { return false }
        try {
            let client = getMTProtoClient()
            let req = PhoneLeaveGroupCall()
            req.callId = callId
            req.callAccessHash = accessHash
            req.source = source
            let _ = client.sendRequest(req.toBytes())
            Hilog.info(0, "CjTelegram", "[CallsService] leaveGroupCall OK")
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] leaveGroupCall failed")
            return false
        }
    }

    /**
     * phone.discardGroupCall — 结束群组通话（仅创建者可调用）
     */
    public func discardGroupCall(callId: Int64, accessHash: Int64): Bool {
        if (callId == 0 || accessHash == 0) { return false }
        try {
            let client = getMTProtoClient()
            let req = PhoneDiscardGroupCall()
            req.callId = callId
            req.callAccessHash = accessHash
            let _ = client.sendRequest(req.toBytes())
            Hilog.info(0, "CjTelegram", "[CallsService] discardGroupCall OK")
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] discardGroupCall failed")
            return false
        }
    }

    /**
     * 解析 phone.getGroupCall 响应
     * phone.groupCall#9e727aad call:GroupCall participants:Vector<GroupCallParticipant>
     *   participants_next_offset:string chats:Vector<Chat> users:Vector<User>
     * groupCall#553b0ba1 flags:# ... id:long access_hash:long participants_count:int
     *   title:flags.3?string stream_dc_id:flags.4?int record_start_date:flags.5?int
     *   schedule_date:flags.7?int unmuted_video_count:flags.10?int
     *   unmuted_video_limit:int version:int invite_link:flags.16?string
     */
    private func parseGroupCallResponse(data: Array<Byte>): GroupCallInfo {
        let info = GroupCallInfo()
        try {
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == 0x9e727aad) {
                let innerCtor = d.readUInt32()
                if (innerCtor == 0x553b0ba1) {
                    let flags = d.readInt32()
                    info.callId = d.readInt64()
                    info.accessHash = d.readInt64()
                    info.participantCount = d.readInt32()
                    info.scheduleStartSubscribed = (flags & (1 << 8)) != 0
                    if ((flags & (1 << 3)) != 0) { info.title = d.readString() }
                    if ((flags & (1 << 4)) != 0) { let _ = d.readInt32() }
                    if ((flags & (1 << 5)) != 0) { let _ = d.readInt32() }
                    if ((flags & (1 << 7)) != 0) { info.scheduleDate = d.readInt32() }
                    if ((flags & (1 << 10)) != 0) { let _ = d.readInt32() }
                    let _ = d.readInt32()
                    let _ = d.readInt32()
                    if ((flags & (1 << 16)) != 0) { let _ = d.readString() }
                }
            }
        } catch (_e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] parseGroupCallResponse failed")
        }
        return info
    }

    private func skipPeer(d: TLDeserializer): Unit {
        let ctor = d.readUInt32()
        if (ctor == 0x59511722) { let _ = d.readInt64() }
        else if (ctor == 0x36c6019a) { let _ = d.readInt64() }
        else if (ctor == 0xa2a5371e) { let _ = d.readInt64() }
    }

    /**
     * 解析 phone.createGroupCall 响应 — 返回 Updates
     * updates#74ae4240 updates:Vector<Update> users chats date seq
     * updateGroupCall#97d64341 flags:# chat_id:flags.0?long call:GroupCall
     * groupCall#553b0ba1 flags:# ... id:long access_hash:long participants_count:int
     *   title:flags.3?string stream_dc_id:flags.4?int record_start_date:flags.5?int
     *   schedule_date:flags.7?int unmuted_video_count:flags.10?int
     *   unmuted_video_limit:int version:int invite_link:flags.16?string
     */
    private func parseCreateGroupCallResponse(data: Array<Byte>): GroupCallInfo {
        let info = GroupCallInfo()
        try {
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == 0x74ae4240) {
                let vecCtor = d.readUInt32()
                if (vecCtor == 0x1cb5c415) {
                    let updateCount = d.readInt32()
                    var i: Int64 = 0
                    while (i < Int64(updateCount)) {
                        let updateCtor = d.readUInt32()
                        if (updateCtor == 0x97d64341) {
                            let updateFlags = d.readInt32()
                            if ((updateFlags & 1) != 0) { let _ = d.readInt64() }
                            let innerCtor = d.readUInt32()
                            if (innerCtor == 0x553b0ba1) {
                                let flags = d.readInt32()
                                info.callId = d.readInt64()
                                info.accessHash = d.readInt64()
                                info.participantCount = d.readInt32()
                                if ((flags & (1 << 3)) != 0) { info.title = d.readString() }
                                if ((flags & (1 << 4)) != 0) { let _ = d.readInt32() }
                                if ((flags & (1 << 5)) != 0) { let _ = d.readInt32() }
                                if ((flags & (1 << 7)) != 0) { info.scheduleDate = d.readInt32() }
                                if ((flags & (1 << 10)) != 0) { let _ = d.readInt32() }
                                let _ = d.readInt32()
                                let _ = d.readInt32()
                                if ((flags & (1 << 16)) != 0) { let _ = d.readString() }
                                break
                            }
                        }
                        i = i + 1
                    }
                }
            }
        } catch (_e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] parseCreateGroupCallResponse failed")
        }
        return info
    }

    /**
     * 解析 phone.getGroupParticipants 响应
     * phone.groupParticipants#f47751b6 count:int participants:Vector<GroupCallParticipant>
     *   next_offset:string chats:Vector<Chat> users:Vector<User> version:int
     * groupCallParticipant#eba636fe flags:# muted:flags.0?true left:flags.1?true
     *   can_self_unmute:flags.2?true just_joined:flags.4?true versioned:flags.5?true
     *   min:flags.8?true muted_by_you:flags.9?true volume_by_admin:flags.10?true
     *   self:flags.12?true video_joined:flags.15?true
     *   peer:Peer date:int active_date:flags.3?int source:int volume:flags.7?int
     *   about:flags.11?string raise_hand_rating:flags.13?long
     *   video:flags.6?GroupCallParticipantVideo presentation:flags.14?GroupCallParticipantVideo
     */
    /** 返回 version（users/chats 未能完整解析时为 0）。 */
    private func parseGroupParticipantsResponse(data: Array<Byte>, out: ArrayList<GroupCallParticipantInfo>): Int32 {
        var version: Int32 = 0
        try {
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor != 0xf47751b6) {
                Hilog.info(0, "CjTelegram", "[CallsService] groupParticipants unexpected ctor=${ctor}")
                return 0
            }
            let _count = d.readInt32()
            let vecCtor = d.readUInt32()
            if (vecCtor != 0x1cb5c415) { return 0 }
            let partCount = d.readInt32()
            var i: Int64 = 0
            while (i < Int64(partCount)) {
                match (parseGroupCallParticipant(d)) {
                    case Some(p) => out.add(p)
                    case None => return 0   // 未知构造器：后续偏移不可信，保留已解析部分
                }
                i = i + 1
            }
            // next_offset:string chats:Vector<Chat> users:Vector<User> version:int
            let _nextOffset = d.readString()
            let names = HashMap<Int64, String>()
            try {
                if (d.readUInt32() == 0x1cb5c415) {
                    let n = d.readInt32()
                    var c: Int64 = 0
                    while (c < Int64(n)) {
                        let chat = ChatResponse.deserializeBoxed(d)
                        if (chat.id != 0 && chat.title.size > 0) { names[chat.id] = chat.title }
                        c = c + 1
                    }
                }
                if (d.readUInt32() == 0x1cb5c415) {
                    let n = d.readInt32()
                    let users = ArrayList<UserResponse>()
                    var u: Int64 = 0
                    while (u < Int64(n)) {
                        let user = UserResponse.deserializeBoxed(d)
                        users.add(user)
                        var display = user.firstName
                        if (user.lastName.size > 0) {
                            display = if (display.size > 0) { "${display} ${user.lastName}" } else { user.lastName }
                        }
                        if (user.id != 0 && display.size > 0) { names[user.id] = display }
                        u = u + 1
                    }
                    getUserPhotoService().cacheUsers(users)
                    version = d.readInt32()
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[CallsService] groupParticipants users/chats parse stopped: ${e}")
            }
            for (p in out) {
                if (names.contains(p.peerId)) { p.name = names[p.peerId] }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] parseGroupParticipantsResponse failed: ${e}")
        }
        return version
    }

    /**
     * groupCallParticipant#eba636fe（layer 214）/ #2a3dc7ac（新层，尾部多 paid_stars_total:flags.16?long）。
     * 供 phone.getGroupParticipants 与 updateGroupCallParticipants 共用。
     */
    public func parseGroupCallParticipant(d: TLDeserializer): Option<GroupCallParticipantInfo> {
        let partCtor = d.readUInt32()
        if (partCtor != 0xeba636fe && partCtor != 0x2a3dc7ac) {
            Hilog.info(0, "CjTelegram", "[CallsService] unknown groupCallParticipant ctor=${partCtor}")
            return None
        }
        let flags = d.readInt32()
        let p = GroupCallParticipantInfo()
        let peerCtor = d.readUInt32()
        if (peerCtor == 0x59511722) { p.peerType = "user"; p.peerId = d.readInt64() }
        else if (peerCtor == 0x36c6019a) { p.peerType = "chat"; p.peerId = d.readInt64() }
        else if (peerCtor == 0xa2a5371e) { p.peerType = "channel"; p.peerId = d.readInt64() }
        p.date = Int64(d.readInt32())
        if ((flags & (1 << 3)) != 0) { p.activeDate = Int64(d.readInt32()) }
        p.source = UInt32(d.readUInt32())
        if ((flags & (1 << 7)) != 0) { p.volume = d.readInt32(); p.hasVolume = true }
        if ((flags & (1 << 11)) != 0) { p.about = d.readString() }
        if ((flags & (1 << 13)) != 0) { p.raiseHandRating = d.readInt64(); p.hasRaiseHand = true }
        if ((flags & (1 << 6)) != 0) { p.video = parseGroupCallParticipantVideo(d) }
        if ((flags & (1 << 14)) != 0) { p.presentation = parseGroupCallParticipantVideo(d) }
        if (partCtor == 0x2a3dc7ac && (flags & (1 << 16)) != 0) { let _ = d.readInt64() }
        p.isMuted = (flags & 1) != 0
        p.left = (flags & (1 << 1)) != 0
        p.canSelfUnmute = (flags & (1 << 2)) != 0
        p.justJoined = (flags & (1 << 4)) != 0
        p.isMin = (flags & (1 << 8)) != 0
        p.mutedByYou = (flags & (1 << 9)) != 0
        p.isCurrentUser = (flags & (1 << 12)) != 0
        p.videoJoined = (flags & (1 << 15)) != 0
        return Some(p)
    }

    /**
     * groupCallParticipantVideo#67753ac8 flags:# paused:flags.0?true endpoint:string
     *   source_groups:Vector<groupCallParticipantVideoSourceGroup#dcb118b7 semantics:string sources:Vector<int>>
     *   audio_source:flags.1?int
     */
    private func parseGroupCallParticipantVideo(d: TLDeserializer): Option<GroupCallVideoInfo> {
        let ctor = d.readUInt32()
        if (ctor != 0x67753ac8) { return None }
        let v = GroupCallVideoInfo()
        let flags = d.readInt32()
        v.isPaused = (flags & 1) != 0
        v.endpointId = d.readString()
        if (d.readUInt32() == 0x1cb5c415) {
            let n = d.readInt32()
            var j: Int64 = 0
            while (j < Int64(n)) {
                let _ = d.readUInt32()
                v.groupSemantics.add(d.readString())
                let list = ArrayList<UInt32>()
                let _ = d.readUInt32()
                let m = d.readInt32()
                var k: Int64 = 0
                while (k < Int64(m)) { list.add(UInt32(d.readUInt32())); k = k + 1 }
                v.groupSsrcs.add(list)
                j = j + 1
            }
        }
        if ((flags & 2) != 0) { v.audioSsrc = UInt32(d.readUInt32()) }
        return Some(v)
    }

    private func skipGroupCallParticipantVideo(d: TLDeserializer): Unit {
        let ctor = d.readUInt32()
        if (ctor == 0x67753ac8) {
            let flags = d.readInt32()
            let _ = d.readString()
            let vecCtor = d.readUInt32()
            if (vecCtor == 0x1cb5c415) {
                let n = d.readInt32()
                var j: Int64 = 0
                while (j < Int64(n)) {
                    let _ = d.readUInt32()
                    let _ = d.readString()
                    let _ = d.readUInt32()
                    let m = d.readInt32()
                    var k: Int64 = 0
                    while (k < Int64(m)) { let _ = d.readInt32(); k = k + 1 }
                    j = j + 1
                }
            }
            if ((flags & 2) != 0) { let _ = d.readInt32() }
        }
    }

    // ==================== P2-161: Extended Group Call Signaling ====================

    /**
     * phone.joinGroupCall — 加入群组通话
     * TL: phone.joinGroupCall#8fb53057 flags muted video_stopped call join_as invite_hash params = Updates
     * joinPayload: SDP/ICE JSON offer string produced by tgcalls/WebRTC layer
     * joinAsPeerId/joinAsPeerAccessHash: the "join as" InputPeer (0,0 = InputPeerSelf)
     * Returns GroupCallJoinResult with callId and server's joinResponsePayload
     * iOS ref: GroupCalls.swift _internal_joinGroupCall line 655/703
     */
    public func joinGroupCall(callId: Int64, accessHash: Int64,
                              joinPayload: String,
                              joinAsPeerId: Int64, joinAsPeerAccessHash: Int64,
                              muted: Bool, videoStopped: Bool,
                              inviteHash: String): Option<GroupCallJoinResult> {
        if (callId == 0 || accessHash == 0) { return None }
        if (joinPayload.size == 0) { return None }
        try {
            let client = getMTProtoClient()
            let req = PhoneJoinGroupCall()
            req.callId = callId
            req.callAccessHash = accessHash
            req.muted = muted
            req.videoStopped = videoStopped
            req.joinPayload = joinPayload
            req.inviteHash = inviteHash
            if (joinAsPeerId > 0) {
                let peer = InputPeerUser()
                peer.userId = joinAsPeerId
                peer.accessHash = joinAsPeerAccessHash
                req.joinAsPeer = peer
            } else {
                match (this.joinAsPeer) {
                    case Some(p) =>
                        if (p.peerType == "channel") {
                            let ip = InputPeerChannel()
                            ip.channelId = p.peerId
                            ip.accessHash = p.accessHash
                            req.joinAsPeer = ip
                        } else if (p.peerType == "chat") {
                            let ip = InputPeerChat()
                            ip.chatId = p.peerId
                            req.joinAsPeer = ip
                        } else {
                            req.joinAsPeer = InputPeerSelf()
                        }
                    case None => req.joinAsPeer = InputPeerSelf()
                }
            }
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size < 4) { return None }
            let result = parseJoinGroupCallResponse(responseData, false)
            return Some(result)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] joinGroupCall failed")
            return None
        }
    }

    /**
     * phone.joinGroupCallPresentation — 加入群组通话屏幕共享（Screencast）
     * TL: phone.joinGroupCallPresentation#cbea6bc4 call:InputGroupCall params:DataJSON = Updates
     * joinPayload: SDP offer JSON string from screencast encoder
     * iOS ref: GroupCalls.swift _internal_joinGroupCallAsScreencast line 1052
     */
    public func joinGroupCallPresentation(callId: Int64, accessHash: Int64,
                                          joinPayload: String): Option<GroupCallJoinResult> {
        if (callId == 0 || accessHash == 0) { return None }
        if (joinPayload.size == 0) { return None }
        try {
            let client = getMTProtoClient()
            let req = PhoneJoinGroupCallPresentation()
            req.callId = callId
            req.callAccessHash = accessHash
            req.joinPayload = joinPayload
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size < 4) { return None }
            let result = parseJoinGroupCallResponse(responseData, true)
            return Some(result)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] joinGroupCallPresentation failed")
            return None
        }
    }

    /**
     * phone.inviteToGroupCall — 邀请用户加入群组通话
     * TL: phone.inviteToGroupCall#7b393160 call:InputGroupCall users:Vector<InputUser> = Updates
     * Vector wrapped with VECTOR ctor 0x1cb5c415 + count + InputUser#f21158c6 items
     * iOS ref: GroupCalls.swift _internal_inviteToGroupCall line 2826
     */
    public func inviteToGroupCall(callId: Int64, accessHash: Int64,
                                  userIds: ArrayList<Int64>,
                                  userAccessHashes: ArrayList<Int64>): Bool {
        if (callId == 0 || accessHash == 0) { return false }
        if (userIds.size == 0) { return false }
        try {
            let client = getMTProtoClient()
            let req = PhoneInviteToGroupCall()
            req.callId = callId
            req.callAccessHash = accessHash
            req.userIds = userIds
            req.userAccessHashes = userAccessHashes
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size < 4) { return false }
            let d = TLDeserializer(responseData)
            if (d.readUInt32() == 0x2144ca19) {
                let code = d.readInt32()
                let message = d.readString()
                Hilog.info(0, "CjTelegram", "[CallsService] inviteToGroupCall rejected: ${code} ${message}")
                return false
            }
            Hilog.info(0, "CjTelegram", "[CallsService] inviteToGroupCall OK (${responseData.size} bytes)")
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] inviteToGroupCall failed")
            return false
        }
    }

    /**
     * phone.editGroupCallTitle — 修改群组通话标题
     * TL: phone.editGroupCallTitle#1ca6ac0a call:InputGroupCall title:string = Updates
     * iOS ref: GroupCalls.swift _internal_editGroupCallTitle line 2902
     */
    public func editGroupCallTitle(callId: Int64, accessHash: Int64, title: String): Bool {
        if (callId == 0 || accessHash == 0) { return false }
        if (title.size == 0) { return false }
        try {
            let client = getMTProtoClient()
            let req = PhoneEditGroupCallTitle()
            req.callId = callId
            req.callAccessHash = accessHash
            req.title = title
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size < 4) { return false }
            Hilog.info(0, "CjTelegram", "[CallsService] editGroupCallTitle OK")
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] editGroupCallTitle failed")
            return false
        }
    }

    /**
     * phone.exportGroupCallInvite — 导出群组通话邀请链接
     * TL: phone.exportGroupCallInvite#e6aa647f flags:# can_self_unmute:flags.0?true call = phone.ExportedGroupCallInvite
     * Response: phone.exportedGroupCallInvite#204bd158 link:string
     * canSpeakerUnmute=true: 邀请连接可发言（speaker link）; false: 仅听众
     * iOS ref: GroupCalls.swift line 2850/2863
     */
    public func exportGroupCallInvite(callId: Int64, accessHash: Int64,
                                      canSpeakerUnmute: Bool): Option<String> {
        if (callId == 0 || accessHash == 0) { return None }
        try {
            let client = getMTProtoClient()
            let req = PhoneExportGroupCallInvite()
            req.callId = callId
            req.callAccessHash = accessHash
            req.canSelfUnmute = canSpeakerUnmute
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size < 8) { return None }
            return parseExportedGroupCallInviteResponse(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] exportGroupCallInvite failed")
            return None
        }
    }

    /**
     * phone.startScheduledGroupCall — 开始已预约的群组通话
     * TL: phone.startScheduledGroupCall#5680e342 call:InputGroupCall = Updates
     * iOS ref: GroupCalls.swift _internal_startScheduledGroupCall line 381
     */
    public func startScheduledGroupCall(callId: Int64, accessHash: Int64): Bool {
        if (callId == 0 || accessHash == 0) { return false }
        try {
            let client = getMTProtoClient()
            let req = PhoneStartScheduledGroupCall()
            req.callId = callId
            req.callAccessHash = accessHash
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size < 4) { return false }
            Hilog.info(0, "CjTelegram", "[CallsService] startScheduledGroupCall OK")
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] startScheduledGroupCall failed")
            return false
        }
    }

    /**
     * phone.getGroupCallStreamChannels — 获取直播流频道列表
     * TL: phone.getGroupCallStreamChannels#1ab21940 call:InputGroupCall = phone.GroupCallStreamChannels
     * Response outer: phone.groupCallStreamChannels#d0e482b2 channels:Vector<GroupCallStreamChannel>
     * Response inner item: groupCallStreamChannel#80eb48af channel:int scale:int last_timestamp_ms:long
     * Vector: 先读 VECTOR ctor 0x1cb5c415, 再读 count, 再读 items
     * TL codegen verified (all 3 ctors from telegram_api.tl)
     */
    public func getGroupCallStreamChannels(callId: Int64, accessHash: Int64): ArrayList<GroupCallStreamChannelInfo> {
        let result = ArrayList<GroupCallStreamChannelInfo>()
        if (callId == 0 || accessHash == 0) { return result }
        try {
            let client = getMTProtoClient()
            let req = PhoneGetGroupCallStreamChannels()
            req.callId = callId
            req.callAccessHash = accessHash
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size < 4) { return result }
            parseGroupCallStreamChannelsResponse(responseData, result)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] getGroupCallStreamChannels failed")
        }
        return result
    }

    /**
     * phone.getGroupCallStreamRtmpUrl — 获取直播流 RTMP 推流地址和密钥
     * TL: phone.getGroupCallStreamRtmpUrl#deb3abbf peer:InputPeer revoke:Bool = phone.GroupCallStreamRtmpUrl
     * Response: phone.groupCallStreamRtmpUrl#2dbf3432 url:string key:string
     * revoke=true: 吊销旧 key 并生成新 key
     * iOS ref: GroupCalls.swift line 3317
     */
    public func getGroupCallStreamRtmpUrl(peerId: Int64, peerAccessHash: Int64,
                                           isChannel: Bool, revoke: Bool): Option<GroupCallStreamRtmpCredentials> {
        if (peerId <= 0) { return None }
        try {
            let client = getMTProtoClient()
            let req = PhoneGetGroupCallStreamRtmpUrl()
            if (isChannel) {
                let peer = InputPeerChannel()
                peer.channelId = peerId
                peer.accessHash = peerAccessHash
                req.peer = peer
            } else {
                let peer = InputPeerChat()
                peer.chatId = peerId
                req.peer = peer
            }
            req.revoke = revoke
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size < 8) { return None }
            return parseGroupCallStreamRtmpUrlResponse(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] getGroupCallStreamRtmpUrl failed")
            return None
        }
    }

    // ==================== P2-161 Response Parsers ====================

    /**
     * 解析 joinGroupCall / joinGroupCallPresentation 响应
     * 服务器返回 Updates (updates#74ae4240 / updateShort#78d4dec1)
     * 内嵌 updateGroupCallConnection#b4afcfb0 params:DataJSON presentation:flags.0?true
     * 从 DataJSON 中提取 server 返回的 SDP answer/ICE candidates
     *
     * 外层 wrapper: updates#74ae4240 (scan for updateGroupCallConnection)
     * updateGroupCallConnection#b4afcfb0: flags params:DataJSON#7d748d04 data:string
     */
    private func parseJoinGroupCallResponse(data: Array<Byte>, isScreencast: Bool): GroupCallJoinResult {
        let result = GroupCallJoinResult()
        result.isScreencast = isScreencast
        try {
            let responsePayload = extractDataJsonFromUpdates(data)
            result.joinResponsePayload = responsePayload
            let headCtor = if (data.size >= 4) { TLDeserializer(data).readUInt32() } else { UInt32(0) }
            Hilog.info(0, "CjTelegram", "[CallsService] joinGroupCall response=${data.size} bytes ctor=${headCtor} payload=${responsePayload.size} bytes")
        } catch (_e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] parseJoinGroupCallResponse failed")
        }
        return result
    }

    /**
     * 从 Updates 响应中提取 updateGroupCallConnection#b783982 的 DataJSON 字符串
     * updateGroupCallConnection#b783982 flags:# presentation:flags.0?true params:DataJSON
     * DataJSON#7d748d04 data:string
     *
     * 策略: 字节扫描 updateGroupCallConnection ctor (0x0b783982 小端: 82 39 78 0b)
     * 再扫描 DataJSON ctor (0x7d748d04 小端: 04 d7 48 7d)
     */
    private func extractDataJsonFromUpdates(data: Array<Byte>): String {
        // 0x0b783982 小端: 82 39 78 0B
        let t0: UInt8 = 0x82
        let t1: UInt8 = 0x39
        let t2: UInt8 = 0x78
        let t3: UInt8 = 0x0B

        var pos: Int64 = 0
        while (pos + 4 <= data.size) {
            if (UInt8(data[pos]) == t0 && UInt8(data[pos + 1]) == t1 &&
                UInt8(data[pos + 2]) == t2 && UInt8(data[pos + 3]) == t3) {
                // found updateGroupCallConnection
                // next: flags:int32, then DataJSON
                if (pos + 8 <= data.size) {
                    let afterFlags = pos + 4 + 4  // skip ctor(4) + flags(4)
                    // expect DataJSON#7d748d04
                    if (afterFlags + 4 <= data.size) {
                        let dj0: UInt8 = 0x04
                        // dataJSON#7d748d04 小端字节序：04 8D 74 7D
                        let dj1: UInt8 = 0x8D
                        let dj2: UInt8 = 0x74
                        let dj3: UInt8 = 0x7D
                        if (UInt8(data[afterFlags]) == dj0 && UInt8(data[afterFlags + 1]) == dj1 &&
                            UInt8(data[afterFlags + 2]) == dj2 && UInt8(data[afterFlags + 3]) == dj3) {
                            let remaining = extractSlice(data, afterFlags + 4, data.size)
                            let d2 = TLDeserializer(remaining)
                            return d2.readString()
                        }
                    }
                }
            }
            pos = pos + 1
        }
        return ""
    }

    private func extractSlice(data: Array<Byte>, start: Int64, end: Int64): Array<Byte> {
        let len = end - start
        if (len <= 0) { return Array<Byte>(0, repeat: 0) }
        let result = Array<Byte>(len, repeat: 0)
        var i: Int64 = 0
        while (i < len) { result[i] = data[start + i]; i = i + 1 }
        return result
    }

    /**
     * 解析 phone.exportedGroupCallInvite#204bd158 link:string
     * TL codegen verified: ctor 0x204bd158
     */
    private func parseExportedGroupCallInviteResponse(data: Array<Byte>): Option<String> {
        try {
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == 0x204bd158) {
                let link = d.readString()
                return Some(link)
            }
        } catch (_e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] parseExportedGroupCallInviteResponse failed")
        }
        return None
    }

    /**
     * 解析 phone.groupCallStreamChannels#d0e482b2 channels:Vector<GroupCallStreamChannel>
     * groupCallStreamChannel#80eb48af channel:int scale:int last_timestamp_ms:long
     *
     * 外层 ctor: 0xd0e482b2
     * Vector: 先读 VECTOR ctor 0x1cb5c415, 再读 count, 再读 items
     * item ctor: 0x80eb48af
     * TL codegen verified: all 3 ctors from telegram_api.tl
     */
    private func parseGroupCallStreamChannelsResponse(data: Array<Byte>, out: ArrayList<GroupCallStreamChannelInfo>): Unit {
        try {
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == 0xd0e482b2) {
                // channels: Vector<GroupCallStreamChannel>
                let vecCtor = d.readUInt32()
                if (vecCtor == 0x1cb5c415) {
                    let count = d.readInt32()
                    var i: Int64 = 0
                    while (i < Int64(count)) {
                        let itemCtor = d.readUInt32()
                        if (itemCtor == 0x80eb48af) {
                            let ch = GroupCallStreamChannelInfo()
                            ch.channel = d.readInt32()
                            ch.scale = d.readInt32()
                            ch.lastTimestampMs = d.readInt64()
                            out.add(ch)
                        }
                        i = i + 1
                    }
                }
            }
        } catch (_e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] parseGroupCallStreamChannelsResponse failed")
        }
    }

    /**
     * 解析 phone.groupCallStreamRtmpUrl#2dbf3432 url:string key:string
     * TL codegen verified: ctor 0x2dbf3432
     */
    private func parseGroupCallStreamRtmpUrlResponse(data: Array<Byte>): Option<GroupCallStreamRtmpCredentials> {
        try {
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == 0x2dbf3432) {
                let cred = GroupCallStreamRtmpCredentials()
                cred.url = d.readString()
                cred.streamKey = d.readString()
                return Some(cred)
            }
        } catch (_e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] parseGroupCallStreamRtmpUrlResponse failed")
        }
        return None
    }

    // ==================== P2-063: Group Call Recording ====================

    /**
     * phone.toggleGroupCallRecord#f128c708 — 开始/停止群组通话录制
     * TL: phone.toggleGroupCallRecord flags:# start:flags.0?true
     *     call:InputGroupCall title:flags.1?string = Updates
     * iOS ref: PresentationGroupCall.swift line 2643
     * start=true: 开始录制; start=false: 停止录制
     * title: 录制文件标题（可选）
     */
    public func toggleGroupCallRecord(callId: Int64, accessHash: Int64,
                                      start: Bool, title: String): Bool {
        if (callId == 0 || accessHash == 0) { return false }
        try {
            let client = getMTProtoClient()
            let req = PhoneToggleGroupCallRecord()
            req.callId = callId
            req.callAccessHash = accessHash
            req.start = start
            req.title = title
            req.hasTitle = title.size > 0
            let _ = client.sendRequest(req.toBytes())
            Hilog.info(0, "CjTelegram", "[CallsService] toggleGroupCallRecord start=${start} OK")
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] toggleGroupCallRecord failed")
            return false
        }
    }

    // ==================== P2-061: Admin Participant Controls ====================

    /**
     * phone.editGroupCallParticipant#a5273abf — 修改参与者属性（admin 操作）
     * TL: phone.editGroupCallParticipant flags:# call:InputGroupCall participant:InputPeer
     *     muted:flags.0?Bool volume:flags.1?int raiseHand:flags.2?Bool = Updates
     * iOS ref: GroupCalls.swift line 2489
     * 用于: admin 静音参与者、调整音量、允许/禁止举手
     */
    public func editGroupCallParticipant(callId: Int64, accessHash: Int64,
                                          participantUserId: Int64, participantAccessHash: Int64,
                                          muted: Bool, hasMuted: Bool,
                                          volume: Int32, hasVolume: Bool): Bool {
        if (callId == 0 || accessHash == 0) { return false }
        if (participantUserId <= 0) { return false }
        try {
            let client = getMTProtoClient()
            let req = PhoneEditGroupCallParticipant()
            req.callId = callId
            req.callAccessHash = accessHash
            req.participantUserId = participantUserId
            req.participantAccessHash = participantAccessHash
            req.muted = muted
            req.hasMuted = hasMuted
            req.volume = volume
            req.hasVolume = hasVolume
            let _ = client.sendRequest(req.toBytes())
            Hilog.info(0, "CjTelegram", "[CallsService] editGroupCallParticipant peerId=${participantUserId} OK")
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] editGroupCallParticipant failed")
            return false
        }
    }

    // ==================== P2-064: Screencast Leave ====================

    /**
     * phone.leaveGroupCallPresentation#1c50d144 — 停止屏幕共享（screencast）
     * TL: phone.leaveGroupCallPresentation#1c50d144 call:InputGroupCall = Updates
     * iOS ref: GroupCalls.swift line 1102
     */
    public func leaveGroupCallPresentation(callId: Int64, accessHash: Int64): Bool {
        if (callId == 0 || accessHash == 0) { return false }
        try {
            let client = getMTProtoClient()
            let req = PhoneLeaveGroupCallPresentation()
            req.callId = callId
            req.callAccessHash = accessHash
            let _ = client.sendRequest(req.toBytes())
            Hilog.info(0, "CjTelegram", "[CallsService] leaveGroupCallPresentation OK")
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] leaveGroupCallPresentation failed")
            return false
        }
    }

    /**
     * Calls tab "Create Call Link" — iOS GroupCalls.swift:3347 _internal_createConferenceCall:
     * phone.createConferenceCall(flags 0, random_id) → take the GroupCall carried by the returned
     * updateGroupCall → phone.exportGroupCallInvite(flags 1<<0 can_self_unmute) → link.
     * Returns (callId, accessHash, link); None on any failure (iOS maps every error to .generic).
     */
    public func createConferenceCallLink(): Option<(Int64, Int64, String)> {
        try {
            let client = getMTProtoClient()
            let req = PhoneCreateConferenceCall()
            req.randomId = Random().nextInt32()
            let data = client.sendRequest(req.toBytes())
            if (data.size < 8) { return None }
            let head = TLDeserializer(data)
            if (head.readUInt32() == 0x2144ca19) {
                let code = head.readInt32()
                let msg = head.readString()
                Hilog.info(0, "CjTelegram", "[CallsService] createConferenceCall rpc error ${code} ${msg}")
                return None
            }
            // groupCall flags:# id:long access_hash:long ...：主会话 layer 214 为 #553b0ba1，
            // 当前层（iOS Api0.swift:324 dict[-273500649]）为 #efb2b617，字段前缀相同（Api8.swift:340）。
            var pos: Int64 = 0
            while (pos + 24 <= data.size) {
                let oldCtor = data[pos] == 0xa1 && data[pos + 1] == 0x0b && data[pos + 2] == 0x3b && data[pos + 3] == 0x55
                let newCtor = data[pos] == 0x17 && data[pos + 1] == 0xb6 && data[pos + 2] == 0xb2 && data[pos + 3] == 0xef
                if (oldCtor || newCtor) {
                    let d = TLDeserializer(this.extractSlice(data, pos + 4, data.size))
                    let _ = d.readInt32()
                    let callId = d.readInt64()
                    let accessHash = d.readInt64()
                    if (callId == 0 || accessHash == 0) { return None }
                    match (this.exportGroupCallInvite(callId, accessHash, true)) {
                        case Some(link) => return Some((callId, accessHash, link))
                        case None => return None
                    }
                }
                pos = pos + 1
            }
            Hilog.info(0, "CjTelegram", "[CallsService] createConferenceCall: no groupCall in updates")
            return None
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallsService] createConferenceCall failed: ${e}")
            return None
        }
    }
}


/** TL source:int 是 ssrc 的 Int32 位模式（iOS Int32(bitPattern:)）。 */
public func ssrcToInt32(ssrc: UInt32): Int32 {
    if (ssrc > 0x7FFFFFFF) {
        return Int32(Int64(ssrc) - 4294967296)
    }
    return Int32(ssrc)
}
