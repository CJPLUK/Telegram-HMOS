package ohos_app_cangjie_entry.utils

/**
 * FFMpegBindingUtils — FFmpeg 绑定上层工具接口
 *
 * 提供高层媒体操作函数，供 MediaPlayer、VideoPlayer、AudioService 等调用。
 * 不重复底层类型定义，复用 bindings/FFMpegBindingBinding.cj 中的类型。
 *
 * 提供：
 * - probeMediaInfo: 探测媒体文件基础信息（时长、流数）
 * - remuxFile: 媒体容器格式转换（passthrough 降级）
 * - trimOpusFile: Opus 文件修剪（deferred，返回 false）
 * - isCodecSupportedOnOHOS: 检查 codec ID 是否可在 HarmonyOS 解码
 * - createVideoWriter: 创建视频编码写入器
 * - createAudioResampler: 创建音频重采样器
 * - openMediaFile: 打开媒体文件并返回解析上下文
 *
 * 降级说明同 FFMpegBindingBinding.cj（deferred 能力有明确日志说明）。
 */

import ohos_app_cangjie_entry.bindings.{
    FFMpegAVFormatContext,
    FFMpegAVCodec,
    FFMpegAVCodecContext,
    FFMpegAVFrame,
    FFMpegSWResample,
    FFMpegRemuxer,
    FFMpegLiveMuxer,
    FFMpegOpusTrimmer,
    FFMpegVideoWriter,
    FFMpegAVSampleFormat,
    FFMpegStreamType,
    FFMpegCodecIdH264,
    FFMpegCodecIdHEVC,
    FFMpegCodecIdMPEG4,
    FFMpegCodecIdVP8,
    FFMpegCodecIdVP9,
    FFMpegCodecIdAV1,
    initializeFFMpegGlobals
}
import kit.PerformanceAnalysisKit.Hilog

// ─────────────────────────────────────────────────────────────────────────────
// 媒体信息结构
// ─────────────────────────────────────────────────────────────────────────────

/** 媒体文件基础探测信息 */
public class FFMpegMediaInfo {
    /** 文件是否可打开 */
    public var isValid: Bool = false
    /** 容器时长（秒），0 表示未知 */
    public var durationSeconds: Float64 = 0.0
    /** 视频流数量 */
    public var videoStreamCount: Int32 = 0
    /** 音频流数量 */
    public var audioStreamCount: Int32 = 0
    /** 主视频流 codec ID（0 表示无视频流）*/
    public var primaryVideoCodecId: Int32 = 0
    /** 主音频流 codec ID（0 表示无音频流）*/
    public var primaryAudioCodecId: Int32 = 0
    /** 视频宽度（像素）*/
    public var videoWidth: Int32 = 0
    /** 视频高度（像素）*/
    public var videoHeight: Int32 = 0
    /** 是否能在 HarmonyOS 上解码视频 */
    public var videoDecodableOnOHOS: Bool = false
    /** 是否能在 HarmonyOS 上解码音频 */
    public var audioDecodableOnOHOS: Bool = false

    public init() {}
}

// ─────────────────────────────────────────────────────────────────────────────
// 全局初始化
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 初始化 FFMpeg 绑定层（对应 iOS 中的 FFMpegGlobals.initializeGlobals()）
 * HarmonyOS 上为 no-op，调用方可安全调用。
 */
public func ffmpegInitialize(): Unit {
    initializeFFMpegGlobals()
}

// ─────────────────────────────────────────────────────────────────────────────
// Codec 支持查询
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 检查 codec ID 是否可在 HarmonyOS 上解码
 * 支持：H.264、H.265/HEVC（硬解），MPEG-4（软解）
 * 不支持：VP8、VP9、AV1（deferred）
 * @param codecId FFMpegCodecId* 常量
 * @return true 表示 HarmonyOS AVCodec 可处理
 */
public func isCodecSupportedOnOHOS(codecId: Int32): Bool {
    if (codecId == FFMpegCodecIdH264) { return true }
    if (codecId == FFMpegCodecIdHEVC) { return true }
    if (codecId == FFMpegCodecIdMPEG4) { return true }
    return false
}

/**
 * 获取 codec 名称字符串（供日志/UI 展示）
 */
public func getCodecName(codecId: Int32): String {
    if (codecId == FFMpegCodecIdH264) { return "H.264/AVC" }
    if (codecId == FFMpegCodecIdHEVC) { return "H.265/HEVC" }
    if (codecId == FFMpegCodecIdMPEG4) { return "MPEG-4" }
    if (codecId == FFMpegCodecIdVP8) { return "VP8 (deferred)" }
    if (codecId == FFMpegCodecIdVP9) { return "VP9 (deferred)" }
    if (codecId == FFMpegCodecIdAV1) { return "AV1 (deferred)" }
    return "Unknown(" + codecId.toString() + ")"
}

// ─────────────────────────────────────────────────────────────────────────────
// 媒体文件探测
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 探测媒体文件基础信息（对应 iOS 中读取 AVFormatContext 后组合结果的工具模式）
 * HarmonyOS 降级：通过 FFMpegAVFormatContext.findStreamInfo 保守探测。
 * @param filePath 媒体文件绝对路径
 * @return 探测结果，isValid=false 表示文件不可用
 */
public func probeMediaInfo(filePath: String): FFMpegMediaInfo {
    let info = FFMpegMediaInfo()
    let ctx = FFMpegAVFormatContext()
    let opened = ctx.openInputWithDirectFilePath(filePath)
    if (!opened) {
        Hilog.info(0, "CjTelegram", "[FFMpegBindingUtils] probeMediaInfo: cannot open file")
        return info
    }
    if (!ctx.findStreamInfo()) {
        Hilog.info(0, "CjTelegram", "[FFMpegBindingUtils] probeMediaInfo: findStreamInfo failed")
        return info
    }
    info.isValid = true
    info.durationSeconds = ctx.duration()
    let videoIdxs = ctx.streamIndicesForType(FFMpegStreamType.Video)
    let audioIdxs = ctx.streamIndicesForType(FFMpegStreamType.Audio)
    info.videoStreamCount = Int32(videoIdxs.size)
    info.audioStreamCount = Int32(audioIdxs.size)
    if (videoIdxs.size > 0) {
        let vid = videoIdxs[0]
        info.primaryVideoCodecId = ctx.codecIdAtStreamIndex(vid)
        let metrics = ctx.metricsForStreamAtIndex(vid)
        info.videoWidth = metrics.width
        info.videoHeight = metrics.height
        info.videoDecodableOnOHOS = isCodecSupportedOnOHOS(info.primaryVideoCodecId)
    }
    if (audioIdxs.size > 0) {
        let aud = audioIdxs[0]
        info.primaryAudioCodecId = ctx.codecIdAtStreamIndex(aud)
        // AAC (86018) および MP3 (86017) は OHOS でサポート
        let ac = info.primaryAudioCodecId
        info.audioDecodableOnOHOS = (ac == 86018 || ac == 86017 || ac == 86021)
    }
    return info
}

// ─────────────────────────────────────────────────────────────────────────────
// 文件操作工具
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Remux 媒体文件（容器格式转换）
 * HarmonyOS 降级：passthrough 文件复制（保持原编码不变）。
 * @param srcPath 输入文件路径
 * @param dstPath 输出文件路径
 * @return 操作成功则 true
 */
public func remuxFile(srcPath: String, dstPath: String): Bool {
    return FFMpegRemuxer.remux(srcPath, dstPath)
}

/**
 * Remux 直播流文件（带时间偏移）
 * HarmonyOS 降级：passthrough copy，offsetSeconds 被忽略。
 * @param srcPath 输入文件路径
 * @param dstPath 输出文件路径
 * @param offsetSeconds 时间偏移（秒，OHOS 上忽略）
 * @return 操作成功则 true
 */
public func remuxLiveFile(srcPath: String, dstPath: String, offsetSeconds: Float64): Bool {
    return FFMpegLiveMuxer.remux(srcPath, dstPath, offsetSeconds)
}

/**
 * 修剪 Opus 音频文件（deferred）
 * HarmonyOS 上 Opus 容器 trim 需要 FFmpeg 库，当前不支持。
 * @param srcPath 输入 ogg/opus 文件路径
 * @param dstPath 输出文件路径
 * @param startSeconds 起始时间（秒）
 * @param endSeconds 结束时间（秒）
 * @return 始终 false（capability deferred）
 */
public func trimOpusFile(srcPath: String, dstPath: String, startSeconds: Float64, endSeconds: Float64): Bool {
    return FFMpegOpusTrimmer.trim(srcPath, dstPath, startSeconds, endSeconds)
}

// ─────────────────────────────────────────────────────────────────────────────
// 音频重采样工厂
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 创建音频重采样器（对应 iOS FFMpegSWResample init）
 * 常用于 Opus/Vorbis 解码输出（float planar 44100 2ch）→ S16 interleaved 16kHz mono
 * @param srcChannels 源通道数
 * @param srcSampleRate 源采样率
 * @param srcFormat 源格式
 * @param dstChannels 目标通道数
 * @param dstSampleRate 目标采样率（采样率转换 deferred）
 * @param dstFormat 目标格式
 * @return 配置好的重采样器实例
 */
public func createAudioResampler(
    srcChannels: Int64,
    srcSampleRate: Int64,
    srcFormat: FFMpegAVSampleFormat,
    dstChannels: Int64,
    dstSampleRate: Int64,
    dstFormat: FFMpegAVSampleFormat
): FFMpegSWResample {
    // FFMpegSWResample init takes positional parameters
    return FFMpegSWResample(srcChannels, srcSampleRate, srcFormat,
                            dstChannels, dstSampleRate, dstFormat)
}

/**
 * 创建标准 Opus 解码输出重采样器
 * 将 FloatPlanar 48kHz 2ch（Opus 标准输出）→ S16 Interleaved 48kHz 2ch
 * （采样率匹配 OHOS OHAudio 默认输入）
 */
public func createOpusOutputResampler(): FFMpegSWResample {
    return createAudioResampler(2, 48000, FFMpegAVSampleFormat.FloatPlanar,
                                2, 48000, FFMpegAVSampleFormat.S16)
}

/**
 * 创建 AAC 解码输出重采样器
 * 将 FloatPlanar 44100 Hz 2ch → S16 Interleaved 44100 Hz 2ch
 */
public func createAACOutputResampler(): FFMpegSWResample {
    return createAudioResampler(2, 44100, FFMpegAVSampleFormat.FloatPlanar,
                                2, 44100, FFMpegAVSampleFormat.S16)
}

// ─────────────────────────────────────────────────────────────────────────────
// 视频编写器工厂
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 创建并配置视频写入器（对应 iOS FFMpegVideoWriter setup）
 * HarmonyOS 降级：编码 deferred，实际帧不被编码。
 * @param outputPath 输出 MP4 文件路径
 * @param width 视频宽度
 * @param height 视频高度
 * @param bitrate 目标比特率（bps）
 * @param framerate 帧率（fps）
 * @return 配置好的写入器，setup 失败时返回 None
 */
public func createVideoWriter(
    outputPath: String,
    width: Int32,
    height: Int32,
    bitrate: Int64,
    framerate: Int32
): ?FFMpegVideoWriter {
    let writer = FFMpegVideoWriter()
    if (!writer.setup(outputPath, width, height, bitrate, framerate)) {
        Hilog.info(0, "CjTelegram", "[FFMpegBindingUtils] createVideoWriter: setup failed")
        return None
    }
    return writer
}

// ─────────────────────────────────────────────────────────────────────────────
// 媒体文件打开工具
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 打开媒体文件并返回格式上下文（对应 iOS 中创建 AVFormatContext + openInput + findStreamInfo 组合模式）
 * @param filePath 媒体文件路径
 * @return 已初始化的 FFMpegAVFormatContext，失败时返回 None
 */
public func openMediaFile(filePath: String): ?FFMpegAVFormatContext {
    let ctx = FFMpegAVFormatContext()
    if (!ctx.openInputWithDirectFilePath(filePath)) {
        Hilog.info(0, "CjTelegram", "[FFMpegBindingUtils] openMediaFile: openInput failed")
        return None
    }
    if (!ctx.findStreamInfo()) {
        Hilog.info(0, "CjTelegram", "[FFMpegBindingUtils] openMediaFile: findStreamInfo failed")
        return None
    }
    return ctx
}

/**
 * 快速检查文件是否为有效的媒体文件（可打开且有流信息）
 * @param filePath 文件路径
 * @return true 表示文件可作为媒体容器打开
 */
public func isValidMediaFile(filePath: String): Bool {
    let info = probeMediaInfo(filePath)
    return info.isValid
}

// ─────────────────────────────────────────────────────────────────────────────
// 解码器查找工具
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 查找并打开解码器上下文（对应 iOS 中 +findForId + FFMpegAVCodecContext initWithCodec + open 组合模式）
 * @param codecId codec ID（FFMpegCodecId* 常量）
 * @param preferHardware 是否优先硬件加速
 * @return 打开的解码器上下文，不支持时返回 None
 */
public func openDecoderContext(codecId: Int32, preferHardware: Bool): ?FFMpegAVCodecContext {
    let codec = FFMpegAVCodec.findForId(codecId, preferHardware)
    match (codec) {
        case None =>
            Hilog.info(0, "CjTelegram", "[FFMpegBindingUtils] openDecoderContext: codec not found")
            return None
        case Some(c) =>
            let ctx = FFMpegAVCodecContext(c)
            if (!ctx.open()) {
                Hilog.info(0, "CjTelegram", "[FFMpegBindingUtils] openDecoderContext: open failed")
                return None
            }
            return ctx
    }
}
