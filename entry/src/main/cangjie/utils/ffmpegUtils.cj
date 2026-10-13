package ohos_app_cangjie_entry.utils

/**
 * ffmpegUtils — FFmpeg 库上层工具调用接口
 *
 * 提供高层工具函数，供 VideoPlayer、AudioPlaybackService、SharedMediaPage 等调用。
 * 依赖 FfmpegBinding（bindings/ffmpegBinding.cj）中的接口契约。
 *
 * 函数列表：
 * - isContainerSupported(path)    检测文件格式是否被支持
 * - probeContainer(path)          探测容器元信息（格式/时长/码流数）
 * - getVideoStreamInfo(path)      获取第一条视频流信息
 * - getAudioStreamInfo(path)      获取第一条音频流信息
 * - extractThumbnail(path, tsMs)  提取指定时间点缩略图帧字节（deferred）
 * - formatDuration(durationMs)    毫秒转可读时长字符串（MM:SS 或 HH:MM:SS）
 * - formatBitrate(bps)            比特率转可读字符串（kbps/Mbps）
 * - getStreamCountSummary(info)   返回流数量摘要字符串
 * - buildFfmpegReader()           工厂方法，创建 FfmpegBinding 实例
 */

import ohos_app_cangjie_entry.bindings.{
    FfmpegBinding,
    FfmpegContainerInfo,
    FfmpegContainerFormat,
    FfmpegStreamInfo,
    FfmpegFrameData,
    FfmpegCodecType,
    FfmpegReader
}
import kit.PerformanceAnalysisKit.Hilog

// ============================================================
// 工厂方法
// ============================================================

/**
 * 创建 FfmpegBinding 实例（工厂方法）
 * 供调用方通过接口 FfmpegReader 访问，便于单测替换实现
 */
public func buildFfmpegReader(): FfmpegBinding {
    return FfmpegBinding()
}

// ============================================================
// 格式支持检测
// ============================================================

/**
 * 检测文件格式是否被平台支持（通过文件扩展名推断）
 *
 * 对应 iOS FFMpegAVFormatContext 的格式探测逻辑
 * HarmonyOS 支持的格式子集：mp4/fmp4/mkv/mpeg-ts/flv/avi/mp3/aac/flac/wav/ogg
 *
 * @param path 文件路径（本地或缓存路径）
 * @return true 表示格式已知且受 HarmonyOS 媒体系统支持
 */
public func isContainerSupported(path: String): Bool {
    if (path.size == 0) { return false }
    let ext = FfmpegBinding.extractExtension(path)
    if (ext.size == 0) { return false }
    let fmt = FfmpegBinding.extensionToFormat(ext)
    let supported = match (fmt) {
        case FfmpegContainerFormat.Unknown => false
        case _ => true
    }
    return supported
}

// ============================================================
// 容器探测
// ============================================================

/**
 * 探测容器元信息
 *
 * 对应 iOS FFMpegAVFormatContext 打开并读取 streamCodecDescriptions 的流程：
 * avformat_open_input → avformat_find_stream_info → 遍历 streams
 *
 * @param path 媒体文件路径
 * @return FfmpegContainerInfo，isValid=false 表示不支持或路径无效
 */
public func probeContainer(path: String): FfmpegContainerInfo {
    if (!isContainerSupported(path)) {
        Hilog.info(0, "CjTelegram", "[FfmpegUtils] probeContainer: unsupported format")
        return FfmpegContainerInfo()
    }
    let reader = buildFfmpegReader()
    let ok = reader.openContainer(path)
    if (!ok) {
        Hilog.info(0, "CjTelegram", "[FfmpegUtils] probeContainer: open failed")
        return FfmpegContainerInfo()
    }
    let info = reader.getContainerInfo()
    reader.close()
    return info
}

// ============================================================
// 码流信息提取
// ============================================================

/**
 * 获取第一条视频流信息
 *
 * 对应 iOS FFMpegAVFormatContext.streamCodecDescriptions 中找到 AVMEDIA_TYPE_VIDEO 的第一条
 *
 * @param path 媒体文件路径
 * @return Some(FfmpegStreamInfo) 若有视频流，None 若无
 */
public func getVideoStreamInfo(path: String): Option<FfmpegStreamInfo> {
    let info = probeContainer(path)
    if (!info.isValid) {
        return Option<FfmpegStreamInfo>.None
    }
    let n = info.streams.size
    var i: Int64 = 0
    while (i < n) {
        let s = info.streams[i]
        match (s.codecType) {
            case FfmpegCodecType.Video => return Option<FfmpegStreamInfo>.Some(s)
            case _ => i = i + 1
        }
    }
    return Option<FfmpegStreamInfo>.None
}

/**
 * 获取第一条音频流信息
 *
 * 对应 iOS FFMpegAVFormatContext.streamCodecDescriptions 中找到 AVMEDIA_TYPE_AUDIO 的第一条
 *
 * @param path 媒体文件路径
 * @return Some(FfmpegStreamInfo) 若有音频流，None 若无
 */
public func getAudioStreamInfo(path: String): Option<FfmpegStreamInfo> {
    let info = probeContainer(path)
    if (!info.isValid) {
        return Option<FfmpegStreamInfo>.None
    }
    let n = info.streams.size
    var i: Int64 = 0
    while (i < n) {
        let s = info.streams[i]
        match (s.codecType) {
            case FfmpegCodecType.Audio => return Option<FfmpegStreamInfo>.Some(s)
            case _ => i = i + 1
        }
    }
    return Option<FfmpegStreamInfo>.None
}

// ============================================================
// 缩略图提取（deferred）
// ============================================================

/**
 * 从视频文件提取指定时间点的缩略图帧数据
 *
 * 对应 iOS FFMpegAVFormatContext + FFMpegAVFrame 帧读取链路：
 * av_read_frame → avcodec_send_packet → avcodec_receive_frame → sws_scale
 *
 * 当前状态：deferred — 需要 HarmonyOS AVDemuxer + VideoDecoder C API Cangjie 绑定
 * 降级：返回空数组，调用方可用 ArkUI Image 组件的 .preview 属性替代
 *
 * @param videoPath 视频文件路径
 * @param timestampMs 时间戳（毫秒）
 * @return RGBA 字节数组（deferred 时返回空数组）
 */
public func extractThumbnail(videoPath: String, timestampMs: Int64): Array<Byte> {
    if (!isContainerSupported(videoPath)) {
        Hilog.info(0, "CjTelegram", "[FfmpegUtils] extractThumbnail: unsupported format")
        return Array<Byte>(0, repeat: 0)
    }
    Hilog.info(0, "CjTelegram", "[FfmpegUtils] extractThumbnail: deferred, use AVPlayer preview")
    return Array<Byte>(0, repeat: 0)
}

// ============================================================
// 格式化工具函数
// ============================================================

/**
 * 毫秒时长转可读字符串
 *
 * 规则：
 * - < 3600_000ms (1h): MM:SS 格式
 * - >= 3600_000ms     : HH:MM:SS 格式
 *
 * 对应 iOS Telegram 消息气泡中的视频/语音时长显示格式
 *
 * @param durationMs 时长（毫秒）
 * @return 如 "03:42" 或 "1:23:45"
 */
public func formatDuration(durationMs: Int64): String {
    if (durationMs <= 0) { return "0:00" }
    let totalSec = durationMs / 1000
    let hours = totalSec / 3600
    let minutes = (totalSec % 3600) / 60
    let seconds = totalSec % 60
    if (hours > 0) {
        return intToString(hours) + ":" + padTwoDigits(minutes) + ":" + padTwoDigits(seconds)
    } else {
        return intToString(minutes) + ":" + padTwoDigits(seconds)
    }
}

/**
 * 比特率转可读字符串
 *
 * @param bps 比特率（bits per second）
 * @return 如 "320 kbps"、"2.5 Mbps"
 */
public func formatBitrate(bps: Int64): String {
    if (bps <= 0) { return "0 kbps" }
    if (bps >= 1000000) {
        let mbps = bps / 100000
        let intPart = mbps / 10
        let fracPart = mbps % 10
        return intToString(intPart) + "." + intToString(fracPart) + " Mbps"
    } else {
        let kbps = bps / 1000
        return intToString(kbps) + " kbps"
    }
}

/**
 * 容器流数量摘要字符串
 *
 * 用于日志/调试显示，如 "video:1 audio:2"
 *
 * @param info FfmpegContainerInfo
 * @return 摘要字符串
 */
public func getStreamCountSummary(info: FfmpegContainerInfo): String {
    if (!info.isValid) { return "invalid" }
    return "video:" + intToString(Int64(info.videoStreamCount)) +
           " audio:" + intToString(Int64(info.audioStreamCount))
}

/**
 * FfmpegContainerFormat 转可读名称字符串
 *
 * @param fmt 格式枚举
 * @return 如 "mp4"、"mkv"、"unknown"
 */
public func containerFormatName(fmt: FfmpegContainerFormat): String {
    match (fmt) {
        case FfmpegContainerFormat.Mp4 => "mp4"
        case FfmpegContainerFormat.Mkv => "mkv"
        case FfmpegContainerFormat.Avi => "avi"
        case FfmpegContainerFormat.Flv => "flv"
        case FfmpegContainerFormat.MpegTs => "mpeg-ts"
        case FfmpegContainerFormat.MpegPs => "mpeg-ps"
        case FfmpegContainerFormat.Wav => "wav"
        case FfmpegContainerFormat.Mp3 => "mp3"
        case FfmpegContainerFormat.Aac => "aac"
        case FfmpegContainerFormat.Flac => "flac"
        case FfmpegContainerFormat.Ogg => "ogg"
        case FfmpegContainerFormat.Unknown => "unknown"
    }
}

/**
 * FfmpegCodecType 转可读名称字符串
 *
 * @param t 编解码类型
 * @return 如 "video"、"audio"
 */
public func codecTypeName(t: FfmpegCodecType): String {
    match (t) {
        case FfmpegCodecType.Video => "video"
        case FfmpegCodecType.Audio => "audio"
        case FfmpegCodecType.Subtitle => "subtitle"
        case FfmpegCodecType.Data => "data"
        case FfmpegCodecType.Unknown => "unknown"
    }
}

// ============================================================
// 私有辅助函数
// ============================================================

/**
 * 整数转字符串（不依赖标准库 toString 重载）
 */
private func intToString(n: Int64): String {
    if (n == 0) { return "0" }
    var val: Int64 = n
    let negative = val < 0
    if (negative) { val = -val }
    var digits: String = ""
    while (val > 0) {
        let d = val % 10
        let ch = Rune(UInt32(48) + UInt32(d))
        digits = ch.toString() + digits
        val = val / 10
    }
    if (negative) { return "-" + digits }
    return digits
}

/**
 * 两位数字补零（如 5 → "05"，42 → "42"）
 */
private func padTwoDigits(n: Int64): String {
    if (n < 10) {
        return "0" + intToString(n)
    }
    return intToString(n)
}
