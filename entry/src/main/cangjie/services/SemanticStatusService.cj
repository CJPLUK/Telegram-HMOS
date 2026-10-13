package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.HashMap
import std.sync.ReentrantMutex

/**
 * SemanticStatusService — 语义状态节点数据层
 *
 * 对应 iOS SemanticStatusNode (SemanticStatusNode.swift)：
 *   管理媒体消息附件（文件、图片、视频、音频）的下载/上传进度和播放/暂停状态。
 *   本 feature 是纯渲染组件，不调用 TL 方法；状态由上层
 *   （如 ChatRoomViewModel / FileDownloadService / AudioPlaybackService）写入，
 *   SemanticStatusComponent 读取并渲染。
 *
 * 状态类型（SEMANTIC_STATUS_* 字符串常量）：
 *   none         — 无状态（不显示任何图标）
 *   download     — 下载箭头图标（待下载，无进度环）
 *   play         — 播放三角图标
 *   pause        — 暂停图标（两竖条）
 *   downloading  — 下载中进度环（带取消 X，显示 progress）
 *   uploading    — 上传中进度环（显示 progress）
 *
 * 调用链（纯渲染，无 TL 方法）：
 *   外部写入：getSemanticStatusService().setSemanticStatus(msgId: id, state: SEMANTIC_STATUS_DOWNLOADING, progress: 0.5)
 *   → SemanticStatusComponent.refreshStatus()
 *   → @State statusKey / progressVal → build() 渲染
 *
 * 内部实现复用 RadialStatusService 作为底层状态存储，
 * 在 Semantic 语义层之上做薄包装以便上层按语义调用。
 */

// ============================================================
// 语义状态值常量
// ============================================================

public let SEMANTIC_STATUS_NONE: String = "none"
public let SEMANTIC_STATUS_DOWNLOAD: String = "download"
public let SEMANTIC_STATUS_PLAY: String = "play"
public let SEMANTIC_STATUS_PAUSE: String = "pause"
public let SEMANTIC_STATUS_DOWNLOADING: String = "downloading"
public let SEMANTIC_STATUS_UPLOADING: String = "uploading"

// ============================================================
// 服务类
// ============================================================

/**
 * SemanticStatusService — 按消息 ID 管理语义状态
 *
 * 线程安全（ReentrantMutex 保护内部 HashMap）。
 *
 * 使用方式：
 *   import ohos_app_cangjie_entry.services.{SemanticStatusService, getSemanticStatusService, SEMANTIC_STATUS_DOWNLOADING}
 *
 *   // 开始下载（进度 0%）
 *   getSemanticStatusService().setSemanticStatus(msgId: 1234, state: SEMANTIC_STATUS_DOWNLOADING, progress: 0.0)
 *
 *   // 更新进度 (50%)
 *   getSemanticStatusService().setProgress(msgId: 1234, progress: 0.5)
 *
 *   // 下载完成，切换为播放图标
 *   getSemanticStatusService().setSemanticStatus(msgId: 1234, state: SEMANTIC_STATUS_PLAY)
 *
 *   // 清除状态
 *   getSemanticStatusService().clearStatus(msgId: 1234)
 */
public class SemanticStatusService {
    private var stateMap: HashMap<Int64, String> = HashMap<Int64, String>()
    private var progressMap: HashMap<Int64, Float64> = HashMap<Int64, Float64>()
    private let mutex: ReentrantMutex = ReentrantMutex()

    public init() {}

    /**
     * 设置消息的语义状态
     *
     * - msgId:    消息 ID
     * - state:    状态字符串（SEMANTIC_STATUS_* 常量）
     * - progress: 进度值 0.0~1.0（仅 downloading / uploading 有效）
     */
    public func setSemanticStatus(
        msgId: Int64,
        state: String,
        progress!: Float64 = 0.0
    ): Unit {
        synchronized (this.mutex) {
            if (state == SEMANTIC_STATUS_NONE) {
                let _ = this.stateMap.remove(msgId)
                let _ = this.progressMap.remove(msgId)
            } else {
                this.stateMap[msgId] = state
                if (state == SEMANTIC_STATUS_DOWNLOADING || state == SEMANTIC_STATUS_UPLOADING) {
                    this.progressMap[msgId] = progress
                }
            }
        }
        Hilog.info(0, "CjTelegram", "[SemanticStatusService] setSemanticStatus msgId=" + msgId.toString() + " state=" + state, [])
    }

    /**
     * 更新消息的下载/上传进度（不改变状态类型）
     * 仅在已处于 downloading / uploading 状态时有效
     */
    public func setProgress(msgId: Int64, progress: Float64): Unit {
        synchronized (this.mutex) {
            match (this.stateMap.get(msgId)) {
                case Some(s) =>
                    if (s == SEMANTIC_STATUS_DOWNLOADING || s == SEMANTIC_STATUS_UPLOADING) {
                        this.progressMap[msgId] = progress
                    }
                case None => ()
            }
        }
    }

    /**
     * 清除消息状态（等同于 setSemanticStatus(..., state: "none")）
     */
    public func clearStatus(msgId: Int64): Unit {
        synchronized (this.mutex) {
            let _ = this.stateMap.remove(msgId)
            let _ = this.progressMap.remove(msgId)
        }
        Hilog.info(0, "CjTelegram", "[SemanticStatusService] clearStatus msgId=" + msgId.toString(), [])
    }

    /**
     * 获取消息的状态字符串
     * 未设置时返回 SEMANTIC_STATUS_NONE
     */
    public func getState(msgId: Int64): String {
        synchronized (this.mutex) {
            match (this.stateMap.get(msgId)) {
                case Some(s) => s
                case None => SEMANTIC_STATUS_NONE
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
     * 获取状态+进度的复合 key，供 SemanticStatusComponent 快速比较是否需要重绘
     * 格式："{state}_{progress_int}" 如 "downloading_75"
     */
    public func getStatusKey(msgId: Int64): String {
        synchronized (this.mutex) {
            let sState = match (this.stateMap.get(msgId)) {
                case Some(s) => s
                case None => SEMANTIC_STATUS_NONE
            }
            let prog = match (this.progressMap.get(msgId)) {
                case Some(v) => v
                case None => 0.0
            }
            let progInt = Int64(prog * 100.0)
            sState + "_" + progInt.toString()
        }
    }

    /**
     * 清除所有消息状态（如退出聊天室时清理）
     */
    public func clearAll(): Unit {
        synchronized (this.mutex) {
            this.stateMap.clear()
            this.progressMap.clear()
        }
        Hilog.info(0, "CjTelegram", "[SemanticStatusService] clearAll", [])
    }
}

// ============================================================
// 全局单例访问器
// ============================================================

var g_semanticStatusService: Option<SemanticStatusService> = None<SemanticStatusService>

/**
 * 获取全局 SemanticStatusService 单例
 * 首次调用时懒惰初始化
 */
public func getSemanticStatusService(): SemanticStatusService {
    match (g_semanticStatusService) {
        case Some(svc) => svc
        case None =>
            let svc = SemanticStatusService()
            g_semanticStatusService = Some(svc)
            svc
    }
}
