package ohos_app_cangjie_entry.services

import std.collection.ArrayList
import kit.PerformanceAnalysisKit.Hilog

/**
 * TelegramCallsService — UI-level call management (TelegramCallsUI)
 *
 * 仅补充 CallService / CallsService 没有的 UI 层协调能力。
 * 不重复实现通话发起/接受/结束逻辑（由 CallService 负责）。
 * 不重复实现群组通话 API（由 CallsService 负责）。
 *
 * 职责：
 * - acceptCall / declineCall — 委托 CallService
 * - mute / speaker / video toggle — 委托 CallService
 * - Call feedback/rating — 委托 CallService.rateCallQuality
 * - Call route selection — 委托 CallService (toggleSpeaker 等)
 * - Group call join screen 数据 — 委托 CallsService.getGroupCall / getGroupParticipants
 * - Toast 通知协调（UI 层，无 TL）
 *
 * iOS 对照: PresentationCall (ringing/active/ended/reconnecting), CallController (accept/decline/mute/speaker/video)
 */
private var _telegramCallsServiceInstance: Option<TelegramCallsService> = None

public func getTelegramCallsService(): TelegramCallsService {
    match (_telegramCallsServiceInstance) {
        case Some(s) => s
        case None =>
            let s = TelegramCallsService()
            _telegramCallsServiceInstance = Some(s)
            s
    }
}

public class TelegramCallsService {

    /**
     * 提交通话评价反馈 (UI 层入口)
     * 委托 CallService.rateCallQuality 发送 phone.setCallRating
     */
    public func submitCallFeedback(callId: Int64, accessHash: Int64, rating: Int32, comment: String): Bool {
        let svc = getCallService()
        return svc.rateCallQuality(callId, accessHash, rating, comment)
    }

    /**
     * 获取群组通话信息 — 用于群组语音聊天加入界面
     * 委托 CallsService.getGroupCall
     */
    public func getGroupCallForJoinScreen(callId: Int64, accessHash: Int64): Option<GroupCallInfo> {
        let svc = getCallsService()
        return svc.getGroupCall(callId, accessHash)
    }

    /**
     * 获取群组通话参与者 — 用于加入界面显示
     * 委托 CallsService.getGroupParticipants
     */
    public func getGroupParticipantsForJoinScreen(callId: Int64, accessHash: Int64, offset: String, limit: Int32): ArrayList<GroupCallParticipantInfo> {
        let svc = getCallsService()
        return svc.getGroupParticipants(callId, accessHash, offset, limit)
    }

    /**
     * 设置扬声器模式 (call route selection)
     * 委托 CallService.setSpeakerMode
     */
    public func setCallRouteSpeaker(enabled: Bool): Unit {
        let svc = getCallService()
        match (svc.getCurrentCall()) {
            case Some(call) =>
                if (call.state == "active" && call.isSpeaker != enabled) {
                    svc.setSpeakerMode(enabled)
                }
            case None => ()
        }
    }

    /**
     * 接听来电 — 委托 CallService.acceptCall
     * 状态需为 ringing
     */
    public func acceptCall(): Bool {
        let svc = getCallService()
        match (svc.getCurrentCall()) {
            case Some(call) =>
                if (call.state == "ringing") {
                    svc.acceptCall()
                    return true
                }
                return false
            case None => return false
        }
    }

    /**
     * 拒绝来电 — 委托 CallService.rejectCall
     */
    public func declineCall(): Bool {
        let svc = getCallService()
        match (svc.getCurrentCall()) {
            case Some(call) =>
                if (call.state == "ringing") {
                    svc.rejectCall()
                    return true
                }
                return false
            case None => return false
        }
    }

    /**
     * 切换静音 — 委托 CallService.toggleMute
     */
    public func setMuted(muted: Bool): Unit {
        let svc = getCallService()
        match (svc.getCurrentCall()) {
            case Some(call) =>
                if (call.isMuted != muted) {
                    svc.toggleMute()
                }
            case None => ()
        }
    }

    /**
     * 切换视频开关 — 委托 CallService.toggleLocalVideo
     */
    public func setVideoEnabled(enabled: Bool): Unit {
        let svc = getCallService()
        match (svc.getCurrentCall()) {
            case Some(call) =>
                if (call.isLocalVideoEnabled != enabled) {
                    svc.toggleLocalVideo()
                }
            case None => ()
        }
    }

    // ==================== P2-161: Extended Group Call UI ====================

    /**
     * 加入群组通话（UI 层入口）
     * 委托 CallsService.joinGroupCall
     * joinAsPeerId=0 表示以自身账号加入
     */
    public func joinGroupCall(callId: Int64, accessHash: Int64,
                              joinPayload: String, joinAsPeerId: Int64,
                              joinAsPeerAccessHash: Int64, muted: Bool): Option<GroupCallJoinResult> {
        let svc = getCallsService()
        let result = svc.joinGroupCall(callId, accessHash, joinPayload,
                                        joinAsPeerId, joinAsPeerAccessHash,
                                        muted, false, "")
        match (result) {
            case Some(_) => Hilog.info(0, "CjTelegram", "[TelegramCallsService] joinGroupCall OK callId=${callId}")
            case None => Hilog.info(0, "CjTelegram", "[TelegramCallsService] joinGroupCall failed callId=${callId}")
        }
        return result
    }

    /**
     * 加入群组通话屏幕共享 — 委托 CallsService.joinGroupCallPresentation
     */
    public func joinGroupCallPresentation(callId: Int64, accessHash: Int64,
                                          joinPayload: String): Option<GroupCallJoinResult> {
        let svc = getCallsService()
        let result = svc.joinGroupCallPresentation(callId, accessHash, joinPayload)
        match (result) {
            case Some(_) => Hilog.info(0, "CjTelegram", "[TelegramCallsService] joinGroupCallPresentation OK callId=${callId}")
            case None => Hilog.info(0, "CjTelegram", "[TelegramCallsService] joinGroupCallPresentation failed callId=${callId}")
        }
        return result
    }

    /**
     * 邀请用户列表加入群组通话 — 委托 CallsService.inviteToGroupCall
     */
    public func inviteUsersToGroupCall(callId: Int64, accessHash: Int64,
                                       userIds: ArrayList<Int64>,
                                       userAccessHashes: ArrayList<Int64>): Bool {
        let svc = getCallsService()
        return svc.inviteToGroupCall(callId, accessHash, userIds, userAccessHashes)
    }

    /**
     * 修改群组通话标题 — 委托 CallsService.editGroupCallTitle
     */
    public func editGroupCallTitle(callId: Int64, accessHash: Int64, title: String): Bool {
        let svc = getCallsService()
        return svc.editGroupCallTitle(callId, accessHash, title)
    }

    /**
     * 导出群组通话邀请链接（UI 层）
     * canSpeakerUnmute=true → speaker link; false → listener link
     * 委托 CallsService.exportGroupCallInvite
     */
    public func exportGroupCallInviteLink(callId: Int64, accessHash: Int64,
                                          canSpeakerUnmute: Bool): Option<String> {
        let svc = getCallsService()
        return svc.exportGroupCallInvite(callId, accessHash, canSpeakerUnmute)
    }

    /**
     * 开始已预约的群组通话 — 委托 CallsService.startScheduledGroupCall
     */
    public func startScheduledGroupCall(callId: Int64, accessHash: Int64): Bool {
        let svc = getCallsService()
        return svc.startScheduledGroupCall(callId, accessHash)
    }

    /**
     * 获取直播频道列表 — 委托 CallsService.getGroupCallStreamChannels
     */
    public func getStreamChannels(callId: Int64, accessHash: Int64): ArrayList<GroupCallStreamChannelInfo> {
        let svc = getCallsService()
        return svc.getGroupCallStreamChannels(callId, accessHash)
    }

    /**
     * 获取 RTMP 推流凭证 — 委托 CallsService.getGroupCallStreamRtmpUrl
     */
    public func getStreamRtmpCredentials(peerId: Int64, peerAccessHash: Int64,
                                          isChannel: Bool, revoke: Bool): Option<GroupCallStreamRtmpCredentials> {
        let svc = getCallsService()
        return svc.getGroupCallStreamRtmpUrl(peerId, peerAccessHash, isChannel, revoke)
    }

    // ==================== P2-061/063/064 Admin + Recording + Screencast ====================

    /**
     * P2-063: 开始/停止群组通话录制 — 委托 CallsService.toggleGroupCallRecord
     * start=true: 开始录制; start=false: 停止录制
     * iOS ref: PresentationGroupCall.swift line 2643
     */
    public func toggleGroupCallRecord(callId: Int64, accessHash: Int64,
                                      start: Bool, title: String): Bool {
        let svc = getCallsService()
        return svc.toggleGroupCallRecord(callId, accessHash, start, title)
    }

    /**
     * P2-061: Admin — 修改参与者属性 — 委托 CallsService.editGroupCallParticipant
     * iOS ref: GroupCalls.swift line 2489
     */
    public func editGroupCallParticipant(callId: Int64, accessHash: Int64,
                                          participantUserId: Int64, participantAccessHash: Int64,
                                          muted: Bool, hasMuted: Bool,
                                          volume: Int32, hasVolume: Bool): Bool {
        let svc = getCallsService()
        return svc.editGroupCallParticipant(callId, accessHash,
                                             participantUserId, participantAccessHash,
                                             muted, hasMuted, volume, hasVolume)
    }

    /**
     * P2-064: 停止屏幕共享 — 委托 CallsService.leaveGroupCallPresentation
     * iOS ref: GroupCalls.swift line 1102
     */
    public func leaveGroupCallPresentation(callId: Int64, accessHash: Int64): Bool {
        let svc = getCallsService()
        return svc.leaveGroupCallPresentation(callId, accessHash)
    }
}
