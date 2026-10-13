package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList

/**
 * ChatMessageInteractiveMediaService — 媒体角标数据层
 *
 * 对应 iOS submodules/ChatMessageInteractiveMediaBadge/Sources/ChatMessageInteractiveMediaBadge.swift
 *
 * 职责：
 *   - 定义 ChatMessageInteractiveMediaDownloadState（下载状态枚举）
 *   - 定义 ChatMessageInteractiveMediaBadgeContent（角标内容联合类型）
 *   - 维护每条消息的角标状态 (messageId → BadgeState)
 *   - 暴露 updateBadge / getBadgeState / onDownloadTap 等接口
 *
 * iOS 原版依赖 RadialStatusNode（ASDisplayKit 节点）绘制圆形进度。
 * 鸿蒙端改为 ArkUI Stack + Progress 组件实现等价渲染，无 MTProto 方法。
 *
 * 说明：本 feature 无 TL 方法 (source_reference.tl_methods = [])。
 * 媒体角标的下载状态由 ChatRoomViewModel / FileDownloadService 外部注入，
 * 本 service 仅维护状态缓存并对 UI 层暴露只读查询接口。
 */

// ─── 枚举：下载状态 ───────────────────────────────────────────────────────────

/**
 * 媒体下载状态
 * 对应 iOS ChatMessageInteractiveMediaDownloadState
 */
public enum InteractiveMediaDownloadState {
    /** 未下载，显示云图标 */
    | Remote
    /** 正在下载，progress 为 0.0..1.0；None 表示不确定进度 */
    | Fetching(Float64)
    /** 精简下载图标（小角标模式） */
    | CompactRemote
    /** 精简下载进度（小角标模式，progress 为 0.0..1.0） */
    | CompactFetching(Float64)
    /** 已本地化，无需下载 */
    | Local
}

// ─── 联合类型：角标内容 ───────────────────────────────────────────────────────

/**
 * 角标内容：通用文本角标 or 媒体下载角标
 * 对应 iOS ChatMessageInteractiveMediaBadgeContent
 */
public enum InteractiveMediaBadgeContent {
    /**
     * 纯文本角标（如"已读"标记或自定义文案）
     *  - text: 显示文案
     *  - iconName: 可选图标 key（如 "mute"）
     */
    | TextBadge(String, String)
    /**
     * 媒体下载角标（时长 + 可选大小 + 静音图标 + 激活态）
     *  - duration: 时长文案，如 "0:32"
     *  - size:     文件大小文案，如 "2.4 MB"；空串表示不显示
     *  - muted:    视频是否静音
     *  - active:   是否展开（下载进度激活态，显示更大的圆形进度）
     */
    | MediaDownloadBadge(String, String, Bool, Bool)
    /** 无角标 */
    | NoBadge
}

// ─── 状态载体 ─────────────────────────────────────────────────────────────────

/**
 * 单条消息的角标完整状态
 */
public class MediaBadgeState {
    public var messageId: Int64
    public var content: InteractiveMediaBadgeContent
    public var downloadState: InteractiveMediaDownloadState

    public init(
        messageId: Int64,
        content: InteractiveMediaBadgeContent,
        downloadState: InteractiveMediaDownloadState
    ) {
        this.messageId = messageId
        this.content = content
        this.downloadState = downloadState
    }
}

// ─── 服务单例 ─────────────────────────────────────────────────────────────────

private var _interactiveMediaServiceInstance: Option<ChatMessageInteractiveMediaService> = None

/**
 * 获取 ChatMessageInteractiveMediaService 单例
 */
public func getChatMessageInteractiveMediaService(): ChatMessageInteractiveMediaService {
    match (_interactiveMediaServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ChatMessageInteractiveMediaService()
            _interactiveMediaServiceInstance = Some(inst)
            return inst
    }
}

// ─── ChatMessageInteractiveMediaService ──────────────────────────────────────

/**
 * 媒体角标数据服务
 *
 * 典型使用场景：
 *   1. ChatRoomViewModel 下载图片/视频时调用 updateBadge() 推送状态
 *   2. ChatMessageInteractiveMediaComponent 调用 getBadgeState() 读取渲染数据
 *   3. 用户点击下载箭头时，Component 调用 onDownloadTap(msgId)
 *   4. Service 通过已注册的 downloadCallback 将点击事件转发给 ViewModel
 */
public class ChatMessageInteractiveMediaService {

    // messageId → MediaBadgeState 缓存
    private var _stateMap: ArrayList<MediaBadgeState> = ArrayList<MediaBadgeState>()

    // 下载点击回调（由 ChatRoomPage 或 ViewModel 注入）
    private var _downloadCallback: (Int64) -> Unit = { _msgId: Int64 => }

    public init() {}

    // ─── 状态写入 ─────────────────────────────────────────────────────────────

    /**
     * 更新指定消息的角标状态
     * 由 ChatRoomViewModel / FileDownloadService 在下载进度变化时调用
     *
     * @param messageId  消息 ID
     * @param content    角标内容（时长/大小/文案等）
     * @param downloadState 下载状态
     */
    public func updateBadge(
        messageId: Int64,
        content: InteractiveMediaBadgeContent,
        downloadState: InteractiveMediaDownloadState
    ): Unit {
        var idx: Int64 = -1
        var i: Int64 = 0
        while (i < Int64(_stateMap.size)) {
            if (_stateMap[i].messageId == messageId) {
                idx = i
                break
            }
            i += 1
        }
        if (idx >= 0) {
            _stateMap[idx].content = content
            _stateMap[idx].downloadState = downloadState
        } else {
            let newState = MediaBadgeState(messageId, content, downloadState)
            _stateMap.add(newState)
        }
        Hilog.info(0, "CjTelegram", "[MediaBadge] updateBadge msgId updated")
    }

    // ─── 状态读取 ─────────────────────────────────────────────────────────────

    /**
     * 查询指定消息的角标状态
     * 返回 None 表示该消息没有注册过角标（应显示默认无角标）
     *
     * @param messageId 消息 ID
     */
    public func getBadgeState(messageId: Int64): Option<MediaBadgeState> {
        var i: Int64 = 0
        while (i < Int64(_stateMap.size)) {
            if (_stateMap[i].messageId == messageId) {
                return Some(_stateMap[i])
            }
            i += 1
        }
        return None
    }

    /**
     * 获取角标内容（带默认值，状态不存在时返回 NoBadge）
     */
    public func getBadgeContent(messageId: Int64): InteractiveMediaBadgeContent {
        match (getBadgeState(messageId)) {
            case Some(state) => return state.content
            case None => return InteractiveMediaBadgeContent.NoBadge
        }
    }

    /**
     * 获取下载状态（带默认值）
     */
    public func getDownloadState(messageId: Int64): InteractiveMediaDownloadState {
        match (getBadgeState(messageId)) {
            case Some(state) => return state.downloadState
            case None => return InteractiveMediaDownloadState.Local
        }
    }

    // ─── 下载触发 ─────────────────────────────────────────────────────────────

    /**
     * 注册下载点击回调
     * 由 ChatRoomPage.aboutToAppear() 或 ViewModel 初始化时注入
     *
     * @param callback (messageId) -> Unit  用户点击下载时的处理函数
     */
    public func registerDownloadCallback(callback: (Int64) -> Unit): Unit {
        _downloadCallback = callback
    }

    /**
     * 用户点击下载角标触发
     * 由 ChatMessageInteractiveMediaComponent.onClick 调用
     *
     * @param messageId 点击的消息 ID
     */
    public func onDownloadTap(messageId: Int64): Unit {
        Hilog.info(0, "CjTelegram", "[MediaBadge] onDownloadTap called")
        _downloadCallback(messageId)
    }

    // ─── 生命周期 ─────────────────────────────────────────────────────────────

    /**
     * 清除某条消息的角标状态（消息删除时调用）
     */
    public func clearBadge(messageId: Int64): Unit {
        var i: Int64 = 0
        while (i < Int64(_stateMap.size)) {
            if (_stateMap[i].messageId == messageId) {
                _stateMap.remove(i..i + 1)
                return
            }
            i += 1
        }
    }

    /**
     * 清除全部状态（切换聊天时调用）
     */
    public func clearAll(): Unit {
        _stateMap.clear()
    }

    // ─── 工具函数 ─────────────────────────────────────────────────────────────

    /**
     * 将下载状态转为下载进度值（0.0..1.0）
     * 用于 ArkUI Progress 组件的 value 参数
     */
    public func getDownloadProgress(state: InteractiveMediaDownloadState): Float64 {
        match (state) {
            case InteractiveMediaDownloadState.Fetching(p) => return p
            case InteractiveMediaDownloadState.CompactFetching(p) => return p
            case _ => return 0.0
        }
    }

    /**
     * 是否显示下载图标（Remote / CompactRemote 状态）
     */
    public func shouldShowDownloadIcon(state: InteractiveMediaDownloadState): Bool {
        match (state) {
            case InteractiveMediaDownloadState.Remote => return true
            case InteractiveMediaDownloadState.CompactRemote => return true
            case _ => return false
        }
    }

    /**
     * 是否正在下载（Fetching / CompactFetching 状态）
     */
    public func isDownloading(state: InteractiveMediaDownloadState): Bool {
        match (state) {
            case InteractiveMediaDownloadState.Fetching(_) => return true
            case InteractiveMediaDownloadState.CompactFetching(_) => return true
            case _ => return false
        }
    }

    /**
     * 是否为精简模式（compact）
     */
    public func isCompact(state: InteractiveMediaDownloadState): Bool {
        match (state) {
            case InteractiveMediaDownloadState.CompactRemote => return true
            case InteractiveMediaDownloadState.CompactFetching(_) => return true
            case _ => return false
        }
    }
}
