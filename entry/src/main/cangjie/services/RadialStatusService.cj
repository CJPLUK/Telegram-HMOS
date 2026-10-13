package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.HashMap
import std.sync.ReentrantMutex

/**
 * RadialStatusService — 环形状态节点数据层
 *
 * 对应 iOS RadialStatusNode / RadialStatusNodeState：
 *   管理消息附件（文件、图片、视频、音频）的下载/上传进度和播放状态。
 *   本 feature 是纯渲染组件，不使用 TL 方法；状态由上层（如 ChatRoomViewModel / FileDownloadService）写入，
 *   RadialStatusComponent 读取并渲染。
 *
 * 状态类型（RadialStatusType 枚举）：
 *   None         — 无状态（不显示）
 *   Download     — 下载箭头图标（待下载）
 *   Uploading    — 上传进度环
 *   Downloading  — 下载进度环（带取消 X）
 *   Play         — 播放三角图标
 *   Pause        — 暂停图标（两竖条）
 *   Check        — 勾选图标（已发送/已读）
 *   CloudProgress — 云端下载进度环（带背景轨道）
 *
 * 调用链（纯渲染，无 TL 方法）：
 *   外部写入：getRadialStatusService().setStatus(msgId: id, status: "downloading", progress: 0.5, cancelEnabled: true)
 *   → RadialStatusComponent.refreshStatus() → @State statusKey / progressVal
 *   → build() 渲染进度环 / 图标
 */

// ============================================================
// 状态值常量（字符串常量代替枚举，避免 Cangjie enum 关联值限制）
// ============================================================

public let RADIAL_STATUS_NONE: String = "none"
public let RADIAL_STATUS_DOWNLOAD: String = "download"
public let RADIAL_STATUS_PLAY: String = "play"
public let RADIAL_STATUS_PAUSE: String = "pause"
public let RADIAL_STATUS_CHECK: String = "check"
public let RADIAL_STATUS_DOWNLOADING: String = "downloading"
public let RADIAL_STATUS_UPLOADING: String = "uploading"
public let RADIAL_STATUS_CLOUD_PROGRESS: String = "cloudProgress"

// ============================================================
// 服务类
// ============================================================

/**
 * RadialStatusService — 单例状态存储
 *
 * 按消息 ID 存储和检索环形状态节点的显示状态。
 * 线程安全（ReentrantMutex 保护 HashMap）。
 *
 * 使用方式：
 *   import ohos_app_cangjie_entry.services.{RadialStatusService, getRadialStatusService}
 *
 *   // 设置下载中状态（进度 50%，可取消）
 *   getRadialStatusService().setStatus(msgId: 1234, status: RADIAL_STATUS_DOWNLOADING, progress: 0.5, cancelEnabled: true)
 *
 *   // 设置播放状态
 *   getRadialStatusService().setStatus(msgId: 1234, status: RADIAL_STATUS_PLAY)
 *
 *   // 清除状态（消失）
 *   getRadialStatusService().clearStatus(msgId: 1234)
 *
 *   // 查询状态字符串（供 RadialStatusComponent 读取）
 *   let s = getRadialStatusService().getStatusType(msgId: 1234)   // "downloading" / "play" / "none" ...
 *   let p = getRadialStatusService().getProgress(msgId: 1234)     // 0.0~1.0，-1.0 表示无进度
 *   let c = getRadialStatusService().getCancelEnabled(msgId: 1234) // Bool
 */
public class RadialStatusService {
    private var statusMap: HashMap<Int64, String> = HashMap<Int64, String>()
    private var progressMap: HashMap<Int64, Float64> = HashMap<Int64, Float64>()
    private var cancelMap: HashMap<Int64, Bool> = HashMap<Int64, Bool>()
    private var trackMap: HashMap<Int64, Bool> = HashMap<Int64, Bool>()
    private let mutex: ReentrantMutex = ReentrantMutex()

    public init() {}

    /**
     * 设置消息环形状态（带进度）
     *
     * - msgId: 消息 ID
     * - status: 状态字符串，使用 RADIAL_STATUS_* 常量
     * - progress: 进度值 0.0~1.0（仅 downloading / uploading / cloudProgress 有效）
     * - cancelEnabled: 是否显示取消 X（仅 downloading 有效）
     * - trackVisible: 是否显示进度背景轨道（仅 cloudProgress 有效）
     */
    public func setStatus(
        msgId: Int64,
        status: String,
        progress!: Float64 = 0.0,
        cancelEnabled!: Bool = false,
        trackVisible!: Bool = true
    ): Unit {
        synchronized (this.mutex) {
            if (status == RADIAL_STATUS_NONE) {
                let _ = this.statusMap.remove(msgId)
                let _ = this.progressMap.remove(msgId)
                let _ = this.cancelMap.remove(msgId)
                let _ = this.trackMap.remove(msgId)
            } else {
                this.statusMap[msgId] = status
                if (status == RADIAL_STATUS_DOWNLOADING || status == RADIAL_STATUS_UPLOADING || status == RADIAL_STATUS_CLOUD_PROGRESS) {
                    this.progressMap[msgId] = progress
                }
                if (status == RADIAL_STATUS_DOWNLOADING) {
                    this.cancelMap[msgId] = cancelEnabled
                }
                if (status == RADIAL_STATUS_CLOUD_PROGRESS) {
                    this.trackMap[msgId] = trackVisible
                }
            }
        }
        Hilog.info(0, "CjTelegram", "[RadialStatusService] setStatus msgId=" + msgId.toString() + " status=" + status, [])
    }

    /**
     * 清除消息状态（等效于 setStatus(..., status: "none")）
     */
    public func clearStatus(msgId: Int64): Unit {
        synchronized (this.mutex) {
            let _ = this.statusMap.remove(msgId)
            let _ = this.progressMap.remove(msgId)
            let _ = this.cancelMap.remove(msgId)
            let _ = this.trackMap.remove(msgId)
        }
        Hilog.info(0, "CjTelegram", "[RadialStatusService] clearStatus msgId=" + msgId.toString(), [])
    }

    /**
     * 获取消息的状态类型字符串
     * 未设置时返回 "none"
     */
    public func getStatusType(msgId: Int64): String {
        synchronized (this.mutex) {
            match (this.statusMap.get(msgId)) {
                case Some(s) => s
                case None => RADIAL_STATUS_NONE
            }
        }
    }

    /**
     * 获取进度值（0.0~1.0）
     * 无进度状态时返回 -1.0
     */
    public func getProgress(msgId: Int64): Float64 {
        synchronized (this.mutex) {
            match (this.progressMap.get(msgId)) {
                case Some(v) => v
                case None => -1.0
            }
        }
    }

    /**
     * 获取是否可取消（仅 downloading 状态有效）
     */
    public func getCancelEnabled(msgId: Int64): Bool {
        synchronized (this.mutex) {
            match (this.cancelMap.get(msgId)) {
                case Some(v) => v
                case None => false
            }
        }
    }

    /**
     * 获取是否显示进度轨道（仅 cloudProgress 状态有效）
     */
    public func getTrackVisible(msgId: Int64): Bool {
        synchronized (this.mutex) {
            match (this.trackMap.get(msgId)) {
                case Some(v) => v
                case None => true
            }
        }
    }

    /**
     * 获取状态+进度的复合 key，供 RadialStatusComponent 快速比较是否需要重绘
     * 格式："{statusType}_{progress_int}" 如 "downloading_75"
     */
    public func getStatusKey(msgId: Int64): String {
        synchronized (this.mutex) {
            let sType = match (this.statusMap.get(msgId)) {
                case Some(s) => s
                case None => RADIAL_STATUS_NONE
            }
            let prog = match (this.progressMap.get(msgId)) {
                case Some(v) => v
                case None => 0.0
            }
            let progInt = Int64(prog * 100.0)
            sType + "_" + progInt.toString()
        }
    }

    /**
     * 清除所有消息状态（如退出聊天室时清理）
     */
    public func clearAll(): Unit {
        synchronized (this.mutex) {
            this.statusMap.clear()
            this.progressMap.clear()
            this.cancelMap.clear()
            this.trackMap.clear()
        }
        Hilog.info(0, "CjTelegram", "[RadialStatusService] clearAll", [])
    }
}

// ============================================================
// 全局单例访问器
// ============================================================

var g_radialStatusService: Option<RadialStatusService> = None<RadialStatusService>

/**
 * 获取全局 RadialStatusService 单例
 * 首次调用时懒惰初始化
 */
public func getRadialStatusService(): RadialStatusService {
    match (g_radialStatusService) {
        case Some(svc) => svc
        case None =>
            let svc = RadialStatusService()
            g_radialStatusService = Some(svc)
            svc
    }
}
