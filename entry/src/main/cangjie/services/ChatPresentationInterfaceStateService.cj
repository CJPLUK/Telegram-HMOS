package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.sync.*

/**
 * 编辑消息的媒体选项位掩码
 * 对应 iOS MessageMediaEditingOptions (OptionSet, rawValue: Int32)
 */
public class MessageMediaEditingOptions {
    public static let imageOrVideo: Int32 = 1
    public static let file: Int32 = 2

    public var rawValue: Int32 = 0

    public init(rawVal: Int32) {
        this.rawValue = rawVal
    }

    public func contains(option: Int32): Bool {
        return (this.rawValue & option) != 0
    }
}

/**
 * 编辑消息内容类型
 * 对应 iOS ChatEditInterfaceMessageStateContent enum
 */
public enum ChatEditInterfaceMessageStateContent {
    | Plaintext
    | Media(Int32)
}

/**
 * 编辑消息状态
 * 对应 iOS ChatEditInterfaceMessageState (class)
 * 携带内容类型（纯文本 or 含媒体）以及可选的媒体引用 key
 */
public class ChatEditInterfaceMessageState {
    public var content: ChatEditInterfaceMessageStateContent = ChatEditInterfaceMessageStateContent.Plaintext
    public var mediaReferenceKey: String = ""

    public init(content: ChatEditInterfaceMessageStateContent, mediaReferenceKey: String) {
        this.content = content
        this.mediaReferenceKey = mediaReferenceKey
    }
}

/**
 * 文本输入面板媒体录制状态
 * 对应 iOS ChatTextInputPanelMediaRecordingState enum
 */
public enum ChatTextInputPanelMediaRecordingState {
    | Audio(Bool)
    | Video(Bool, Bool)
    | WaitingForPreview
}

/**
 * 视频录制状态
 * 对应 iOS ChatVideoRecordingStatus enum (recording / editing)
 */
public enum ChatVideoRecordingStatus {
    | Recording
    | Editing
}

/**
 * 即时视频控制器录制状态
 * 对应 iOS InstantVideoControllerRecordingStatus (micLevel + duration)
 * iOS 版本通过 Signal<T, NoError> 实时推送；仓颉端使用 var 字段聚合
 */
public class InstantVideoControllerRecordingStatus {
    public var micLevel: Float64 = 0.0
    public var durationSeconds: Float64 = 0.0

    public init(micLevel: Float64, durationSeconds: Float64) {
        this.micLevel = micLevel
        this.durationSeconds = durationSeconds
    }

    public func withMicLevel(level: Float64): InstantVideoControllerRecordingStatus {
        return InstantVideoControllerRecordingStatus(level, this.durationSeconds)
    }

    public func withDuration(duration: Float64): InstantVideoControllerRecordingStatus {
        return InstantVideoControllerRecordingStatus(this.micLevel, duration)
    }
}

/**
 * 聊天展示层界面状态聚合
 *
 * 对应 iOS ChatPresentationInterfaceState（子集）:
 *  - 编辑消息状态 (interfaceState.editMessage)
 *  - 回复消息状态 (interfaceState.replyMessageSubject)
 *  - 录制状态 (inputTextPanelState.mediaRecordingState / ChatVideoRecordingStatus)
 *  - 即时视频录制细节 (InstantVideoControllerRecordingStatus)
 *
 * 本 feature 为纯本地呈现状态聚合，无 MTProto/TL 调用。
 * iOS 原版 ChatPresentationInterfaceState 是本地 UI 状态 struct，同样无 TL 方法。
 * 草稿/回复持久化由 ChatInterfaceStateService 负责；本服务只管当前呈现状态。
 */
public class ChatPresentationInterfaceStateService {
    private var mutex: ReentrantMutex = ReentrantMutex()

    // ========== 编辑消息状态 ==========

    private var _editState: Option<ChatEditInterfaceMessageState> = None

    /**
     * 进入编辑消息模式
     */
    public func enterEditMode(msgId: Int64, content: ChatEditInterfaceMessageStateContent, mediaKey: String): Unit {
        synchronized (this.mutex) {
            this._editState = Some(ChatEditInterfaceMessageState(content, mediaKey))
            Hilog.info(0, "CjTelegram", "[CPISvc] enterEditMode msgId=${msgId}")
        }
    }

    /**
     * 退出编辑模式
     */
    public func clearEditMode(): Unit {
        synchronized (this.mutex) {
            this._editState = None
            Hilog.info(0, "CjTelegram", "[CPISvc] clearEditMode")
        }
    }

    /**
     * 当前是否处于编辑模式
     */
    public func isEditing(): Bool {
        synchronized (this.mutex) {
            match (this._editState) {
                case Some(_) => return true
                case None => return false
            }
        }
    }

    /**
     * 获取当前编辑消息状态（None = 非编辑模式）
     */
    public func getEditState(): Option<ChatEditInterfaceMessageState> {
        synchronized (this.mutex) {
            return this._editState
        }
    }

    // ========== 回复消息状态 ==========

    private var _replyMsgId: Int64 = 0
    private var _replySenderName: String = ""
    private var _replyText: String = ""

    /**
     * 设置回复状态
     */
    public func setReplyPresentation(msgId: Int64, senderName: String, previewText: String): Unit {
        synchronized (this.mutex) {
            this._replyMsgId = msgId
            this._replySenderName = senderName
            this._replyText = previewText
            Hilog.info(0, "CjTelegram", "[CPISvc] setReplyPresentation msgId=${msgId}")
        }
    }

    /**
     * 清除回复状态
     */
    public func clearReplyPresentation(): Unit {
        synchronized (this.mutex) {
            this._replyMsgId = 0
            this._replySenderName = ""
            this._replyText = ""
            Hilog.info(0, "CjTelegram", "[CPISvc] clearReplyPresentation")
        }
    }

    /**
     * 当前是否处于回复模式
     */
    public func isReplying(): Bool {
        synchronized (this.mutex) {
            return this._replyMsgId > 0
        }
    }

    public func getReplyMsgId(): Int64 {
        synchronized (this.mutex) {
            return this._replyMsgId
        }
    }

    public func getReplySenderName(): String {
        synchronized (this.mutex) {
            return this._replySenderName
        }
    }

    public func getReplyPreviewText(): String {
        synchronized (this.mutex) {
            return this._replyText
        }
    }

    // ========== 录制状态（文本输入面板媒体录制态） ==========

    private var _recordingState: Option<ChatTextInputPanelMediaRecordingState> = None

    /**
     * 开始音频录制
     */
    public func startAudioRecording(isLocked: Bool): Unit {
        synchronized (this.mutex) {
            this._recordingState = Some(ChatTextInputPanelMediaRecordingState.Audio(isLocked))
            Hilog.info(0, "CjTelegram", "[CPISvc] startAudioRecording isLocked=${isLocked}")
        }
    }

    /**
     * 开始视频录制
     */
    public func startVideoRecording(isEditing: Bool, isLocked: Bool): Unit {
        synchronized (this.mutex) {
            this._recordingState = Some(ChatTextInputPanelMediaRecordingState.Video(isEditing, isLocked))
            Hilog.info(0, "CjTelegram", "[CPISvc] startVideoRecording isEditing=${isEditing}")
        }
    }

    /**
     * 设置等待预览态（录制完成、等待确认发送）
     */
    public func setWaitingForPreview(): Unit {
        synchronized (this.mutex) {
            this._recordingState = Some(ChatTextInputPanelMediaRecordingState.WaitingForPreview)
            Hilog.info(0, "CjTelegram", "[CPISvc] setWaitingForPreview")
        }
    }

    /**
     * 停止录制
     */
    public func stopRecording(): Unit {
        synchronized (this.mutex) {
            this._recordingState = None
            Hilog.info(0, "CjTelegram", "[CPISvc] stopRecording")
        }
    }

    /**
     * 获取当前录制状态（None = 非录制模式）
     */
    public func getRecordingState(): Option<ChatTextInputPanelMediaRecordingState> {
        synchronized (this.mutex) {
            return this._recordingState
        }
    }

    /**
     * 当前是否处于录制模式
     */
    public func isRecording(): Bool {
        synchronized (this.mutex) {
            match (this._recordingState) {
                case Some(_) => return true
                case None => return false
            }
        }
    }

    // ========== 即时视频录制细节 ==========

    private var _instantVideoStatus: Option<InstantVideoControllerRecordingStatus> = None

    /**
     * 更新即时视频录制状态（麦克风电平 + 时长）
     * 对应 iOS InstantVideoControllerRecordingStatus.micLevel / duration
     */
    public func updateInstantVideoStatus(micLevel: Float64, durationSeconds: Float64): Unit {
        synchronized (this.mutex) {
            this._instantVideoStatus = Some(InstantVideoControllerRecordingStatus(micLevel, durationSeconds))
        }
    }

    /**
     * 清除即时视频录制状态
     */
    public func clearInstantVideoStatus(): Unit {
        synchronized (this.mutex) {
            this._instantVideoStatus = None
        }
    }

    /**
     * 获取当前即时视频录制状态
     */
    public func getInstantVideoStatus(): Option<InstantVideoControllerRecordingStatus> {
        synchronized (this.mutex) {
            return this._instantVideoStatus
        }
    }

    // ========== 综合状态查询 ==========

    /**
     * 返回当前模式描述字符串（便于 UI 展示和测试断言）
     * 返回值: "none" | "editing" | "replying" | "recording_audio" | "recording_video" | "waiting_preview"
     */
    public func getCurrentMode(): String {
        synchronized (this.mutex) {
            match (this._recordingState) {
                case Some(state) =>
                    match (state) {
                        case ChatTextInputPanelMediaRecordingState.Audio(_) => return "recording_audio"
                        case ChatTextInputPanelMediaRecordingState.Video(_, _) => return "recording_video"
                        case ChatTextInputPanelMediaRecordingState.WaitingForPreview => return "waiting_preview"
                        case _ => ()
                    }
                case None => ()
            }
            match (this._editState) {
                case Some(_) => return "editing"
                case None => ()
            }
            if (this._replyMsgId > 0) {
                return "replying"
            }
            return "none"
        }
    }

    /**
     * 重置所有呈现状态（例如切换聊天时）
     */
    public func resetAllState(): Unit {
        synchronized (this.mutex) {
            this._editState = None
            this._replyMsgId = 0
            this._replySenderName = ""
            this._replyText = ""
            this._recordingState = None
            this._instantVideoStatus = None
            Hilog.info(0, "CjTelegram", "[CPISvc] resetAllState")
        }
    }
}

// ==================== 单例 ====================

private var _cpisServiceInstance: Option<ChatPresentationInterfaceStateService> = None

public func getChatPresentationInterfaceStateService(): ChatPresentationInterfaceStateService {
    match (_cpisServiceInstance) {
        case Some(svc) => return svc
        case None =>
            let svc = ChatPresentationInterfaceStateService()
            _cpisServiceInstance = Some(svc)
            return svc
    }
}
