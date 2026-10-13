package ohos_app_cangjie_entry.utils

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.bindings.{
    FileMediaResourceStatusBinding,
    FileMediaResourceStatus,
    FetchStatusType,
    PlaybackStatusType,
    MediaStatusKind,
    MediaStatus,
    FetchProgress,
    getFileMediaResourceStatusBinding
}

/**
 * FileMediaResourceStatusUtils — 文件媒体资源状态上层工具接口
 *
 * 对应 iOS FileMediaResourceStatus 模块公开的高层调用接口：
 * - messageFileMediaResourceStatus
 * - messageImageMediaResourceStatus
 * - messageFileMediaPlaybackStatus（播放状态查询辅助）
 *
 * 设计要点：
 *   - 不持有网络连接，不做实际 MTProto 调用；
 *     下载/上传进度由调用方（ViewModel / Service）注入
 *   - 提供便捷函数覆盖常见场景（已下载 / 下载中 / 发送中）
 *   - 供 MessageBubble、AttachmentPanel、SharedMediaPage 等 UI 层调用
 */

// ─────────────────────────────────────────────
// 输入参数数据类
// ─────────────────────────────────────────────

/**
 * 文件消息状态查询参数
 * 调用方填入已知信息，由工具函数组装成 FileMediaResourceStatus
 */
public class FileMessageStatusParams {
    /** 消息是否正在发送（出向上传中）*/
    public var isSending: Bool = false
    /** 上传进度 [0.0, 1.0]，仅 isSending=true 时有效 */
    public var uploadProgress: Float32 = 0.0
    /** 上传任务是否正在运行 */
    public var uploadIsRunning: Bool = false
    /** 本地文件路径（非空表示已下载） */
    public var localPath: String = ""
    /** 下载进度百分比 (-1 = 未开始, 0-99 = 下载中, 100 = 完成) */
    public var downloadPercent: Int32 = -1
    /** 是否有播放器活跃，true 时需提供 isPlaying */
    public var hasPlayback: Bool = false
    /** 播放器当前是否在播放 */
    public var isPlaying: Bool = false

    public init() {}
}

/**
 * 图片消息状态查询参数
 */
public class ImageMessageStatusParams {
    /** 消息是否正在发送 */
    public var isSending: Bool = false
    /** 上传进度 [0.0, 1.0] */
    public var uploadProgress: Float32 = 0.0
    /** 上传任务是否正在运行 */
    public var uploadIsRunning: Bool = false
    /** 本地文件路径（非空表示已下载）*/
    public var localPath: String = ""
    /** 下载进度百分比 */
    public var downloadPercent: Int32 = -1

    public init() {}
}

// ─────────────────────────────────────────────
// 工具函数
// ─────────────────────────────────────────────

/**
 * 计算文件消息的媒体资源状态
 *
 * 对应 iOS messageFileMediaResourceStatus()
 * 封装逻辑：
 *   1. 若 localPath 非空 → fetchStatus = Local
 *   2. 若 downloadPercent 有效 → 按百分比推断 fetchStatus
 *   3. 若 hasPlayback → playbackStatus = Playing/Paused
 *   4. 若 isSending → mediaStatus = 上传进度
 *   5. 否则 → mediaStatus = fetchStatus
 *
 * @param params 查询参数
 * @return FileMediaResourceStatus
 */
public func computeFileMessageStatus(params: FileMessageStatusParams): FileMediaResourceStatus {
    let binding = getFileMediaResourceStatusBinding()

    // 1. 确定资源抓取状态
    let fetchStatus: FetchStatusType
    if (params.localPath.size > 0) {
        fetchStatus = FetchStatusType.Local
    } else if (params.downloadPercent >= 0) {
        fetchStatus = binding.fetchStatusFromPercent(params.downloadPercent)
    } else {
        fetchStatus = FetchStatusType.Remote
    }

    // 2. 确定播放器状态
    let playbackOpt: Option<PlaybackStatusType>
    if (params.hasPlayback) {
        if (params.isPlaying) {
            playbackOpt = Some(PlaybackStatusType.Playing)
        } else {
            playbackOpt = Some(PlaybackStatusType.Paused)
        }
    } else {
        playbackOpt = None
    }

    return binding.computeFileStatus(
        fetchStatus,
        params.isSending,
        params.uploadProgress,
        params.uploadIsRunning,
        playbackOpt
    )
}

/**
 * 计算图片消息的媒体资源状态
 *
 * 对应 iOS messageImageMediaResourceStatus()
 *
 * @param params 查询参数
 * @return FileMediaResourceStatus
 */
public func computeImageMessageStatus(params: ImageMessageStatusParams): FileMediaResourceStatus {
    let binding = getFileMediaResourceStatusBinding()

    let fetchStatus: FetchStatusType
    if (params.localPath.size > 0) {
        fetchStatus = FetchStatusType.Local
    } else if (params.downloadPercent >= 0) {
        fetchStatus = binding.fetchStatusFromPercent(params.downloadPercent)
    } else {
        fetchStatus = FetchStatusType.Remote
    }

    return binding.computeImageStatus(
        fetchStatus,
        params.isSending,
        params.uploadProgress,
        params.uploadIsRunning
    )
}

/**
 * 快捷：从本地路径 + 是否发送状态创建文件资源状态
 *
 * 适用于不需要下载进度百分比的简单场景（MessageBubble 普通文档）。
 *
 * @param localPath    本地文件路径（空字符串表示未下载）
 * @param isSending    是否正在发送
 * @param uploadProgress 上传进度 [0.0, 1.0]
 * @return FileMediaResourceStatus
 */
public func fileStatusFromLocalPath(
    localPath: String,
    isSending: Bool,
    uploadProgress: Float32
): FileMediaResourceStatus {
    let params = FileMessageStatusParams()
    params.localPath = localPath
    params.isSending = isSending
    params.uploadProgress = uploadProgress
    params.uploadIsRunning = isSending
    return computeFileMessageStatus(params)
}

/**
 * 快捷：从本地路径创建图片资源状态
 *
 * @param localPath    本地文件路径
 * @param isSending    是否正在发送
 * @param uploadProgress 上传进度 [0.0, 1.0]
 * @return FileMediaResourceStatus
 */
public func imageStatusFromLocalPath(
    localPath: String,
    isSending: Bool,
    uploadProgress: Float32
): FileMediaResourceStatus {
    let params = ImageMessageStatusParams()
    params.localPath = localPath
    params.isSending = isSending
    params.uploadProgress = uploadProgress
    params.uploadIsRunning = isSending
    return computeImageMessageStatus(params)
}

/**
 * 判断是否应展示下载按钮
 * 供 MessageBubble/AttachmentPanel 决定 UI 控件可见性
 */
public func shouldShowDownloadButton(status: FileMediaResourceStatus): Bool {
    return getFileMediaResourceStatusBinding().canDownload(status)
}

/**
 * 判断是否应展示进度条
 */
public func shouldShowProgressBar(status: FileMediaResourceStatus): Bool {
    return getFileMediaResourceStatusBinding().showProgress(status)
}

/**
 * 获取展示进度值 [0.0, 1.0]
 * 不在下载中时返回 0.0
 */
public func getDisplayProgress(status: FileMediaResourceStatus): Float32 {
    return getFileMediaResourceStatusBinding().getDisplayProgress(status)
}

/**
 * 判断媒体文件是否已在本地可用
 */
public func isMediaAvailableLocally(status: FileMediaResourceStatus): Bool {
    match (status.fetchStatus) {
        case FetchStatusType.Local => return true
        case _ => return false
    }
}

/**
 * 判断是否正在播放
 */
public func isMediaPlaying(status: FileMediaResourceStatus): Bool {
    match (status.mediaStatus.kind) {
        case MediaStatusKind.PlaybackKind =>
            match (status.mediaStatus.playbackStatus) {
                case PlaybackStatusType.Playing => return true
                case _ => return false
            }
        case _ => return false
    }
}

/**
 * 获取人类可读的状态摘要（调试 / 测试用）
 */
public func describeFileMediaStatus(status: FileMediaResourceStatus): String {
    let fetchStr = match (status.fetchStatus) {
        case FetchStatusType.Local => "local"
        case FetchStatusType.Remote => "remote"
        case FetchStatusType.Fetching => "fetching"
        case FetchStatusType.Paused => "paused"
    }
    match (status.mediaStatus.kind) {
        case MediaStatusKind.PlaybackKind =>
            let psStr = match (status.mediaStatus.playbackStatus) {
                case PlaybackStatusType.Playing => "playing"
                case PlaybackStatusType.Paused => "playback-paused"
            }
            return "media:" + psStr + " fetch:" + fetchStr
        case MediaStatusKind.FetchKind =>
            let fsStr = match (status.mediaStatus.fetchStatus) {
                case FetchStatusType.Local => "local"
                case FetchStatusType.Remote => "remote"
                case FetchStatusType.Fetching => "fetching"
                case FetchStatusType.Paused => "paused"
            }
            return "media:" + fsStr + " fetch:" + fetchStr
    }
}
