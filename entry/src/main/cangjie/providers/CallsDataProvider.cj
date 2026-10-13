package ohos_app_cangjie_entry.providers

import ohos_app_cangjie_entry.services.{getCallService, getCallsService}
import ohos_app_cangjie_entry.models.{CallRecord, CallSession}
import ohos_app_cangjie_entry.services.{GroupCallInfo, GroupCallParticipantInfo, GroupCallJoinResult, GroupCallStreamChannelInfo, GroupCallStreamRtmpCredentials}
import std.collection.ArrayList

/**
 * Calls 数据接口 — 整合 CallService + CallsService 供 UI 使用
 *
 * 将 API 层数据转为 ViewModel/UI 可用的统一接口：
 * - 1:1 通话、通话历史、rateCall → CallService
 * - 群组通话 (getGroupCall, createGroupCall, participants) → CallsService
 */
private var _callsDataProviderInstance: Option<CallsDataProvider> = None

public func getCallsDataProvider(): CallsDataProvider {
    match (_callsDataProviderInstance) {
        case Some(p) => p
        case None =>
            let p = CallsDataProvider()
            _callsDataProviderInstance = Some(p)
            p
    }
}

public class CallsDataProvider {
    private let callService = getCallService()
    private let callsService = getCallsService()

    // ==================== 1:1 通话 (CallService) ====================

    /**
     * 发起通话 — 委托 CallService.requestCall
     * iOS 对照: TelegramEngineCalls 通过 PresentationCallManager.requestCall
     */
    public func requestCall(peerId: Int64, accessHash: Int64, peerName: String, isVideo: Bool): CallSession {
        return this.callService.requestCall(peerId, accessHash, peerName, isVideo)
    }

    /**
     * 接听来电 — 委托 CallService.acceptCall
     */
    public func acceptCall(): Bool {
        match (this.callService.getCurrentCall()) {
            case Some(call) =>
                if (call.state == "ringing") {
                    this.callService.acceptCall()
                    return true
                }
                return false
            case None => return false
        }
    }

    /**
     * 挂断通话 — 委托 CallService.endCall
     */
    public func discardCall(): Unit {
        this.callService.endCall()
    }

    /**
     * 获取当前活跃通话
     */
    public func getCurrentCall(): Option<CallSession> {
        return this.callService.getCurrentCall()
    }

    /**
     * 是否有活跃通话
     */
    public func hasActiveCall(): Bool {
        return this.callService.hasActiveCall()
    }

    /**
     * 获取通话历史列表
     */
    public func getCallHistory(): ArrayList<CallRecord> {
        return this.callService.getCallHistory()
    }

    /**
     * 评价通话质量 (1-5 星)
     */
    public func rateCall(callId: Int64, accessHash: Int64, rating: Int32, comment: String): Bool {
        return this.callService.rateCallQuality(callId, accessHash, rating, comment)
    }

    // ==================== 群组通话 (CallsService) ====================

    /**
     * 获取群组通话信息
     */
    public func getGroupCallInfo(callId: Int64, accessHash: Int64): Option<GroupCallInfo> {
        return this.callsService.getGroupCall(callId, accessHash)
    }

    /**
     * 创建群组通话
     */
    public func createGroupCall(peerId: Int64, peerAccessHash: Int64, isChannel: Bool, title: String, scheduleDate: Int32): Option<GroupCallInfo> {
        return this.callsService.createGroupCall(peerId, peerAccessHash, isChannel, title, scheduleDate)
    }

    /**
     * 获取群组通话参与者
     */
    public func getGroupParticipants(callId: Int64, accessHash: Int64, offset: String, limit: Int32): ArrayList<GroupCallParticipantInfo> {
        return this.callsService.getGroupParticipants(callId, accessHash, offset, limit)
    }

    /**
     * 离开群组通话
     */
    public func leaveGroupCall(callId: Int64, accessHash: Int64, source: Int32): Bool {
        return this.callsService.leaveGroupCall(callId, accessHash, source)
    }

    /**
     * 结束群组通话（仅创建者可调用）
     */
    public func discardGroupCall(callId: Int64, accessHash: Int64): Bool {
        return this.callsService.discardGroupCall(callId, accessHash)
    }

    // ==================== P2-161: Extended Group Call Signaling ====================

    /**
     * 加入群组通话（发送 SDP offer, 获取服务器 SDP answer）
     * joinAsPeerId=0 → InputPeerSelf（以自身账号加入）
     */
    public func joinGroupCall(callId: Int64, accessHash: Int64,
                              joinPayload: String,
                              joinAsPeerId: Int64, joinAsPeerAccessHash: Int64,
                              muted: Bool, videoStopped: Bool,
                              inviteHash: String): Option<GroupCallJoinResult> {
        return this.callsService.joinGroupCall(callId, accessHash, joinPayload,
                                               joinAsPeerId, joinAsPeerAccessHash,
                                               muted, videoStopped, inviteHash)
    }

    /**
     * 加入群组通话屏幕共享（Screencast）
     */
    public func joinGroupCallPresentation(callId: Int64, accessHash: Int64,
                                          joinPayload: String): Option<GroupCallJoinResult> {
        return this.callsService.joinGroupCallPresentation(callId, accessHash, joinPayload)
    }

    /**
     * 邀请用户加入群组通话
     */
    public func inviteToGroupCall(callId: Int64, accessHash: Int64,
                                  userIds: ArrayList<Int64>,
                                  userAccessHashes: ArrayList<Int64>): Bool {
        return this.callsService.inviteToGroupCall(callId, accessHash, userIds, userAccessHashes)
    }

    /**
     * 修改群组通话标题
     */
    public func editGroupCallTitle(callId: Int64, accessHash: Int64, title: String): Bool {
        return this.callsService.editGroupCallTitle(callId, accessHash, title)
    }

    /**
     * 导出邀请链接（canSpeakerUnmute=true: speaker link; false: listener link）
     */
    public func exportGroupCallInvite(callId: Int64, accessHash: Int64,
                                      canSpeakerUnmute: Bool): Option<String> {
        return this.callsService.exportGroupCallInvite(callId, accessHash, canSpeakerUnmute)
    }

    /**
     * 开始已预约的群组通话
     */
    public func startScheduledGroupCall(callId: Int64, accessHash: Int64): Bool {
        return this.callsService.startScheduledGroupCall(callId, accessHash)
    }

    /**
     * 获取直播流频道列表
     */
    public func getGroupCallStreamChannels(callId: Int64, accessHash: Int64): ArrayList<GroupCallStreamChannelInfo> {
        return this.callsService.getGroupCallStreamChannels(callId, accessHash)
    }

    /**
     * 获取直播流 RTMP 推流地址和密钥
     */
    public func getGroupCallStreamRtmpUrl(peerId: Int64, peerAccessHash: Int64,
                                           isChannel: Bool, revoke: Bool): Option<GroupCallStreamRtmpCredentials> {
        return this.callsService.getGroupCallStreamRtmpUrl(peerId, peerAccessHash, isChannel, revoke)
    }
}
