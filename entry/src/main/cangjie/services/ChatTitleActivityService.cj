package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.{getMTProtoClient, MessagesSetTyping, TLObject}
import std.time.DateTime

// ==================== 活动类型枚举 ====================

/**
 * 聊天标题活动类型
 *
 * 对应 iOS ChatTitleActivityNodeState，包含输入/录音/选贴纸等状态
 *
 * TL SendMessageAction 构造器 ID（对应 Telegram API layer 167）:
 *   typing           0x16bf744e  sendMessageTypingAction
 *   cancel           0xfd5ec8f5  sendMessageCancelAction
 *   recordAudio      0xd52f73f7  sendMessageRecordAudioAction
 *   recordVideo      0xa187d66f  sendMessageRecordVideoAction
 *   uploadDocument   0xaa0cd9e4  sendMessageUploadDocumentAction
 *   chooseSticker    0x243e1c66  sendMessageChooseStickerAction
 */
public enum ActivityType {
    | Idle
    | Typing
    | RecordingVoice
    | RecordingVideo
    | ChoosingSticker
    | Uploading
}

/**
 * 活动状态数据：类型 + 显示文案
 */
public class ActivityState {
    public var activityType: ActivityType = ActivityType.Idle
    public var displayText: String = ""

    public init() {}
}

// ==================== 单例 ====================

private var _chatTitleActivityServiceInstance: Option<ChatTitleActivityService> = None

public func getChatTitleActivityService(): ChatTitleActivityService {
    match (_chatTitleActivityServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ChatTitleActivityService()
            _chatTitleActivityServiceInstance = Some(inst)
            return inst
    }
}

// ==================== 服务主体 ====================

/**
 * 聊天标题活动指示服务（Phase CTAN）
 *
 * 对应 iOS ChatTitleActivityNode + ChatChoosingStickerActivityContentNode 等
 *
 * 职责:
 * 1. 订阅 UpdatesManager 的 typing 更新流，接收他人活动推送
 * 2. 将收到的 userId 事件映射为 ActivityState（默认 Typing）
 * 3. 5 秒超时自动清除活动状态
 * 4. 向上层 UI 分发 ActivityState 变更回调
 * 5. 封装 messages.setTyping TL 调用，支持多种 SendMessageAction 类型
 *
 * TL 调用链（接收侧）:
 *   UpdatesManager typing subscriber → handleIncomingTyping → notifyHandler → ChatTitleActivityComponent
 *
 * TL 调用链（发送侧）:
 *   sendTypingAction → sendSetTyping → MessagesSetTyping.serialize → getMTProtoClient().sendRequest()
 */
public class ChatTitleActivityService {
    // 当前活动状态
    private var _currentState: ActivityState = ActivityState()
    // 当前聊天的 peer 信息（由 ChatRoomPage 注入）
    private var _peerType: String = ""
    private var _peerId: Int64 = 0
    // UI 更新回调（由 ChatTitleActivityComponent 注册）
    private var _activityHandler: Option<(ActivityState) -> Unit> = None
    // 最后一次 typing 事件的时间戳（毫秒），用于超时清除
    private var _lastTypingTimestampMs: Int64 = 0
    // 超时清除协程是否已在运行
    private var _clearActive: Bool = false
    private var _typingSubscriptionToken: Int64 = -1

    public init() {}

    // ==================== 注册 ====================

    /**
     * 设置当前聊天的 peer 信息，供发送 setTyping 时使用
     * 由 ChatRoomPage.aboutToAppear 调用
     */
    public func setPeer(peerType: String, peerId: Int64): Unit {
        this._peerType = peerType
        this._peerId = peerId
    }

    /**
     * 注册活动状态变更回调（由 ChatTitleActivityComponent 调用）
     */
    public func setActivityHandler(handler: (ActivityState) -> Unit): Unit {
        this._activityHandler = Some(handler)
    }

    /**
     * 清除活动状态回调（离开聊天室时调用）
     */
    public func clearActivityHandler(): Unit {
        this._activityHandler = None
        if (this._typingSubscriptionToken >= 0) {
            getUpdatesManager().removeTypingSubscriber(this._typingSubscriptionToken)
            this._typingSubscriptionToken = -1
        }
    }

    /**
     * 注册到 UpdatesManager 的 typingHandler
     *
     * UpdatesManager 当前仅传递 userId；服务层统一视为 Typing 状态。
     * 5 秒内未收到新事件则自动清除。
     */
    public func registerWithUpdatesManager(): Unit {
        if (this._typingSubscriptionToken >= 0) { return }
        let updMgr = getUpdatesManager()
        this._typingSubscriptionToken = updMgr.addTypingSubscriber({ userId: Int64 =>
            this.handleIncomingTyping(userId, actionCtor: 0x16bf744e)
        })
    }

    /**
     * 扩展入口：由外部传入完整 (userId, actionCtor) 以支持更丰富的活动类型
     * 可由 UpdatesManager 未来扩展的 richTypingHandler 或直接调用
     */
    public func handleActionUpdate(userId: Int64, actionCtor: UInt32): Unit {
        this.handleIncomingTyping(userId, actionCtor: actionCtor)
    }

    // ==================== 接收活动状态 ====================

    private func handleIncomingTyping(userId: Int64, actionCtor!: UInt32): Unit {
        // sendMessageCancelAction → 立即清除
        if (actionCtor == 0xfd5ec8f5) {
            let empty = ActivityState()
            this._currentState = empty
            this.notifyHandler(empty)
            return
        }

        let actType = this.actionCtorToType(actionCtor)
        let text = this.activityText(actType)

        let state = ActivityState()
        state.activityType = actType
        state.displayText = text
        this._currentState = state

        Hilog.info(0, "CjTelegram", "[ChatTitleActivity] Incoming activity: userId=${userId}, text=${text}")

        this.notifyHandler(state)
        this.scheduleAutoClear()
    }

    private func actionCtorToType(ctor: UInt32): ActivityType {
        if (ctor == 0x16bf744e) { return ActivityType.Typing }
        if (ctor == 0xd52f73f7) { return ActivityType.RecordingVoice }
        if (ctor == 0xa187d66f) { return ActivityType.RecordingVideo }
        if (ctor == 0x243e1c66) { return ActivityType.ChoosingSticker }
        if (ctor == 0xaa0cd9e4) { return ActivityType.Uploading }
        return ActivityType.Typing
    }

    private func activityText(actType: ActivityType): String {
        match (actType) {
            case Typing => return "typing..."
            case RecordingVoice => return "recording audio..."
            case RecordingVideo => return "recording video..."
            case ChoosingSticker => return "choosing a sticker..."
            case Uploading => return "sending file..."
            case Idle => return ""
        }
    }

    // ==================== 超时自动清除 ====================

    /**
     * 5 秒后自动清除活动状态
     * 若 5 秒内又收到新事件则时间戳刷新，旧协程检测到后静默退出
     */
    private func scheduleAutoClear(): Unit {
        let nowMs = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
        this._lastTypingTimestampMs = nowMs
        let stampAtSchedule = nowMs

        if (this._clearActive) { return }
        this._clearActive = true

        let _ = spawn {
            sleep(Duration.millisecond * 5000)
            if (this._lastTypingTimestampMs == stampAtSchedule) {
                let empty = ActivityState()
                this._currentState = empty
                this.notifyHandler(empty)
                Hilog.info(0, "CjTelegram", "[ChatTitleActivity] Auto-cleared activity after 5s")
            }
            this._clearActive = false
        }
    }

    // ==================== 发送本机活动状态 ====================

    /**
     * 发送"正在输入"状态到服务器
     *
     * 调用链: sendTypingAction
     *   → sendSetTyping(action=0x16bf744e)
     *   → getMTProtoClient().sendRequest(MessagesSetTyping{peer, action})
     *
     * 应在 spawn 内调用（网络请求）
     */
    public func sendTypingAction(): Unit {
        this.sendSetTyping(0x16bf744e)
    }

    /**
     * 发送"正在录制语音"状态到服务器
     * action constructor: sendMessageRecordAudioAction#d52f73f7
     */
    public func sendRecordAudioAction(): Unit {
        this.sendSetTyping(0xd52f73f7)
    }

    /**
     * 发送"正在选择贴纸"状态到服务器
     * action constructor: sendMessageChooseStickerAction#243e1c66
     */
    public func sendChooseStickerAction(): Unit {
        this.sendSetTyping(0x243e1c66)
    }

    /**
     * 发送"取消活动"状态到服务器
     * action constructor: sendMessageCancelAction#fd5ec8f5
     */
    public func sendCancelAction(): Unit {
        this.sendSetTyping(0xfd5ec8f5)
    }

    /** Send an indexed interactive-emoji animation using Telegram's input-activity channel. */
    public func sendEmojiInteraction(emoji: String, messageId: Int64, animationIndex: Int64): Unit {
        if (this._peerId == 0 || messageId <= 0 || animationIndex < 0) { return }
        try {
            let client = getMTProtoClient()
            let req = MessagesSetTyping()
            req.peer = getRealMessageService().buildInputPeer(this._peerType, this._peerId)
            req.action = 0x25972bcb
            req.actionEmoticon = emoji
            req.actionMessageId = Int32(messageId)
            req.actionInteractionJson = "{\"v\":1,\"a\":[{\"i\":${animationIndex},\"t\":0.0}]}"
            let _ = client.sendRequest(req.toBytes())
            Hilog.info(0, "CjTelegram", "[EmojiInteraction] sent msgId=${messageId} emoji=${emoji} index=${animationIndex}")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[EmojiInteraction] send failed: ${e}")
        }
    }

    /** Acknowledge that the remote emoji interaction was displayed. */
    public func sendEmojiInteractionSeen(emoji: String): Unit {
        if (this._peerId == 0) { return }
        try {
            let client = getMTProtoClient()
            let req = MessagesSetTyping()
            req.peer = getRealMessageService().buildInputPeer(this._peerType, this._peerId)
            req.action = 0xb665902e
            req.actionEmoticon = emoji
            let _ = client.sendRequest(req.toBytes())
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[EmojiInteraction] seen failed: ${e}")
        }
    }

    /**
     * 核心 TL 调用: messages.setTyping
     *
     * messages.setTyping constructor: 0x58943ee2
     * flags:# peer:InputPeer top_msg_id:flags.0?int action:SendMessageAction
     *
     * MessagesSetTyping.serialize 写入: flags(Int32=0) + peer(boxed) + action(UInt32)
     */
    private func sendSetTyping(actionCtor: UInt32): Unit {
        if (this._peerId == 0) { return }
        try {
            let client = getMTProtoClient()
            let req = MessagesSetTyping()
            req.peer = getRealMessageService().buildInputPeer(this._peerType, this._peerId)
            req.action = actionCtor
            let _ = client.sendRequest(req.toBytes())
            Hilog.info(0, "CjTelegram", "[ChatTitleActivity] Sent setTyping peer=${this._peerId}")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ChatTitleActivity] sendSetTyping failed: ${e}")
        }
    }

    // ==================== 通知 ====================

    private func notifyHandler(state: ActivityState): Unit {
        match (this._activityHandler) {
            case Some(handler) => handler(state)
            case None => ()
        }
    }

    // ==================== 状态查询 ====================

    public func getCurrentState(): ActivityState {
        return this._currentState
    }
}
