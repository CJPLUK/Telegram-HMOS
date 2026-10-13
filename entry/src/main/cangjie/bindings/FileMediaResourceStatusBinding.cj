package ohos_app_cangjie_entry.bindings

import kit.PerformanceAnalysisKit.Hilog

/**
 * FileMediaResourceStatusBinding — 文件媒体资源状态平台封装层
 *
 * 对应 iOS submodules/FileMediaResourceStatus/Sources/FileMediaResourceStatus.swift
 *
 * 提供平台无关的文件资源下载/上传状态计算接口：
 * - FetchStatusType: 资源抓取状态（本地已有 / 远端未下 / 下载中 / 暂停）
 * - PlaybackStatusType: 媒体播放状态（播放中 / 暂停）
 * - MediaStatusKind: 综合媒体状态类型（抓取状态 / 播放状态）
 * - FileMediaResourceStatus: 聚合状态对象（mediaStatus + fetchStatus）
 * - FileMediaResourceStatusBinding: 状态计算服务
 */

// ─────────────────────────────────────────────
// 枚举定义
// ─────────────────────────────────────────────

/**
 * 资源抓取状态
 * 对应 iOS EngineMediaResource.FetchStatus
 */
public enum FetchStatusType {
    /** 资源已在本地 */
    | Local
    /** 资源在远端，尚未下载 */
    | Remote
    /** 正在下载（isActive=true：主动；false：后台排队） */
    | Fetching
    /** 下载已暂停 */
    | Paused
}

/**
 * 媒体播放状态
 * 对应 iOS MediaPlayerPlaybackStatus (.playing / .paused / .buffering)
 */
public enum PlaybackStatusType {
    | Playing
    | Paused
}

/**
 * 媒体综合状态类型 — 区分"当前处于播放态"还是"当前处于抓取态"
 * 对应 iOS FileMediaResourceMediaStatus (.playbackStatus / .fetchStatus)
 */
public enum MediaStatusKind {
    | PlaybackKind
    | FetchKind
}

// ─────────────────────────────────────────────
// 数据类
// ─────────────────────────────────────────────

/**
 * 下载进度快照
 */
public class FetchProgress {
    /** 当前下载进度 [0.0, 1.0] */
    public var progress: Float32 = 0.0
    /** 是否正在主动下载（false = 后台排队） */
    public var isActive: Bool = false

    public init() {}

    public init(progress: Float32, isActive: Bool) {
        this.progress = progress
        this.isActive = isActive
    }
}

/**
 * 聚合媒体状态 — 对应 iOS FileMediaResourceMediaStatus
 *
 * 语义：
 *   - kind = PlaybackKind → playbackStatus 有效
 *   - kind = FetchKind    → fetchStatus 有效
 */
public class MediaStatus {
    public var kind: MediaStatusKind = MediaStatusKind.FetchKind
    public var playbackStatus: PlaybackStatusType = PlaybackStatusType.Paused
    public var fetchStatus: FetchStatusType = FetchStatusType.Remote
    public var fetchProgress: FetchProgress = FetchProgress()

    public init() {}
}

/**
 * 文件媒体资源状态 — 对应 iOS FileMediaResourceStatus
 *
 * 字段：
 *   - mediaStatus：当前展示态（播放状态 或 抓取状态）
 *   - fetchStatus：始终记录资源实际下载状态（供进度条用）
 */
public class FileMediaResourceStatus {
    public var mediaStatus: MediaStatus = MediaStatus()
    public var fetchStatus: FetchStatusType = FetchStatusType.Remote

    public init() {}

    public init(mediaStatus: MediaStatus, fetchStatus: FetchStatusType) {
        this.mediaStatus = mediaStatus
        this.fetchStatus = fetchStatus
    }
}

// ─────────────────────────────────────────────
// 绑定服务
// ─────────────────────────────────────────────

private var _fileMediaResourceStatusBindingInstance: Option<FileMediaResourceStatusBinding> = None

/**
 * 获取 FileMediaResourceStatusBinding 单例
 */
public func getFileMediaResourceStatusBinding(): FileMediaResourceStatusBinding {
    match (_fileMediaResourceStatusBindingInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = FileMediaResourceStatusBinding()
            _fileMediaResourceStatusBindingInstance = Some(inst)
            return inst
    }
}

/**
 * 文件媒体资源状态计算服务
 *
 * 复刻 iOS messageFileMediaResourceStatus / messageImageMediaResourceStatus 逻辑：
 * 1. 若当前有播放器状态 → mediaStatus = 播放/暂停
 * 2. 若消息正在发送（isSending）且有挂起上传 → mediaStatus = 抓取中（上传进度）
 * 3. 否则 → mediaStatus = 资源下载状态
 */
public class FileMediaResourceStatusBinding {

    /**
     * 计算文件消息的媒体资源状态
     *
     * @param fetchStatus      资源当前下载状态
     * @param isSending        消息是否正在发送（出向上传中）
     * @param uploadProgress   上传进度 [0.0, 1.0]，仅 isSending=true 时有效
     * @param uploadIsRunning  上传任务是否正在运行
     * @param playbackStatus   当前播放器状态（None = 未在播放）
     * @return FileMediaResourceStatus 聚合状态
     */
    public func computeFileStatus(
        fetchStatus: FetchStatusType,
        isSending: Bool,
        uploadProgress: Float32,
        uploadIsRunning: Bool,
        playbackStatus: Option<PlaybackStatusType>
    ): FileMediaResourceStatus {
        let result = FileMediaResourceStatus()
        result.fetchStatus = fetchStatus

        let ms = MediaStatus()

        // 优先：有播放器状态
        match (playbackStatus) {
            case Some(ps) =>
                ms.kind = MediaStatusKind.PlaybackKind
                ms.playbackStatus = ps
            case None =>
                ms.kind = MediaStatusKind.FetchKind
                // 消息发送中且有上传进度
                if (isSending) {
                    ms.fetchStatus = FetchStatusType.Fetching
                    ms.fetchProgress = FetchProgress(uploadProgress, uploadIsRunning)
                } else {
                    ms.fetchStatus = fetchStatus
                    match (fetchStatus) {
                        case FetchStatusType.Fetching =>
                            ms.fetchProgress = FetchProgress(0.0, true)
                        case _ =>
                            ms.fetchProgress = FetchProgress()
                    }
                }
        }

        result.mediaStatus = ms
        return result
    }

    /**
     * 计算图片消息的媒体资源状态
     *
     * 图片无播放器逻辑，仅考虑发送状态 + 下载状态。
     *
     * @param fetchStatus      资源当前下载状态
     * @param isSending        消息是否正在发送
     * @param uploadProgress   上传进度 [0.0, 1.0]
     * @param uploadIsRunning  上传任务是否正在运行
     * @return FileMediaResourceStatus 聚合状态
     */
    public func computeImageStatus(
        fetchStatus: FetchStatusType,
        isSending: Bool,
        uploadProgress: Float32,
        uploadIsRunning: Bool
    ): FileMediaResourceStatus {
        return this.computeFileStatus(
            fetchStatus,
            isSending,
            uploadProgress,
            uploadIsRunning,
            None
        )
    }

    /**
     * 将下载百分比（整数，0-100）映射为 FetchStatusType
     *
     * 映射规则：
     *   -1   → Remote（未开始）
     *   0~99 → Fetching（下载中）
     *   100  → Local（已下载完成）
     */
    public func fetchStatusFromPercent(percent: Int32): FetchStatusType {
        if (percent < 0) {
            return FetchStatusType.Remote
        } else if (percent >= 100) {
            return FetchStatusType.Local
        } else {
            return FetchStatusType.Fetching
        }
    }

    /**
     * 将本地文件路径映射为 FetchStatusType
     *
     * 若路径非空则视为本地已有；否则视为远端未下载。
     */
    public func fetchStatusFromLocalPath(localPath: String): FetchStatusType {
        if (localPath.size > 0) {
            return FetchStatusType.Local
        } else {
            return FetchStatusType.Remote
        }
    }

    /**
     * 判断状态是否可以展示下载按钮
     */
    public func canDownload(status: FileMediaResourceStatus): Bool {
        match (status.fetchStatus) {
            case FetchStatusType.Remote => return true
            case FetchStatusType.Paused => return true
            case _ => return false
        }
    }

    /**
     * 判断状态是否展示进度条
     */
    public func showProgress(status: FileMediaResourceStatus): Bool {
        match (status.mediaStatus.kind) {
            case MediaStatusKind.FetchKind =>
                match (status.mediaStatus.fetchStatus) {
                    case FetchStatusType.Fetching => return true
                    case _ => return false
                }
            case _ => return false
        }
    }

    /**
     * 获取展示进度值 [0.0, 1.0]
     * 若不在下载中返回 0.0
     */
    public func getDisplayProgress(status: FileMediaResourceStatus): Float32 {
        match (status.mediaStatus.kind) {
            case MediaStatusKind.FetchKind =>
                match (status.mediaStatus.fetchStatus) {
                    case FetchStatusType.Fetching =>
                        return status.mediaStatus.fetchProgress.progress
                    case _ => return 0.0
                }
            case _ => return 0.0
        }
    }

    /**
     * 日志输出状态摘要（调试用）
     */
    public func logStatus(tag: String, status: FileMediaResourceStatus): Unit {
        let fetchStr = match (status.fetchStatus) {
            case FetchStatusType.Local => "Local"
            case FetchStatusType.Remote => "Remote"
            case FetchStatusType.Fetching => "Fetching"
            case FetchStatusType.Paused => "Paused"
        }
        let kindStr = match (status.mediaStatus.kind) {
            case MediaStatusKind.PlaybackKind => "Playback"
            case MediaStatusKind.FetchKind => "Fetch"
        }
        Hilog.info(0, "CjTelegram", "[FileMediaStatusBinding] tag=${tag}, fetch=${fetchStr}, mediaKind=${kindStr}")
    }
}
