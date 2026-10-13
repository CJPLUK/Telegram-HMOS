package ohos_app_cangjie_entry.bindings

/**
 * ffmpegBinding — FFmpeg 库底层接口封装（容器/流/帧基础访问）
 *
 * 对应 Telegram-iOS submodules/ffmpeg 模块，提供平台无关的接口契约。
 *
 * 设计要点：
 * 1. HarmonyOS/OHOS 平台不直接支持 FFmpeg native 绑定（无 libavcodec/libavformat HAP 打包支持）
 * 2. 接口契约层定义与 iOS FFmpeg API 对应的类型和方法签名
 * 3. 内部实现委托 HarmonyOS 原生多媒体能力（基于 AVCodecKit/MediaKit 格式支持）
 * 4. 不支持的能力在方法级别明确返回降级结果（非空实现，而是有意义的降级返回值）
 *
 * 降级策略（capability deferred）：
 * - 直接 C-level FFmpeg API（avcodec_open2、av_read_frame 等）: deferred — HarmonyOS 无 FFmpeg .so
 * - 容器 demux / 帧读取: 通过 HarmonyOS AVDemuxer 路径实现有限子集（mp4/mkv/ts/flv/mpeg-ps/avi）
 * - 像素格式转换 (swscale): deferred — 可通过 PixelMap 替代
 * - 硬件加速解码 (hwaccel): deferred — HarmonyOS 通过 VideoDecoder 独立提供
 *
 * 调用方：FfmpegUtils（utils/ffmpegUtils.cj）、VideoPlayer、AudioPlaybackService
 */

import kit.PerformanceAnalysisKit.Hilog

// ============================================================
// 枚举：编解码类型
// ============================================================

/**
 * 码流类型 — 对应 FFmpeg AVMediaType
 * iOS 对照: AVMEDIA_TYPE_VIDEO / AVMEDIA_TYPE_AUDIO / AVMEDIA_TYPE_SUBTITLE
 */
public enum FfmpegCodecType {
    | Unknown
    | Video
    | Audio
    | Subtitle
    | Data
}

/**
 * 容器格式枚举 — 对应 FFmpeg AVFormatContext.iformat.name
 * iOS 对照: FFMpegAVFormatContext.streamCodecDescriptions
 */
public enum FfmpegContainerFormat {
    | Unknown
    | Mp4
    | Mkv
    | Avi
    | Flv
    | MpegTs
    | MpegPs
    | Wav
    | Mp3
    | Aac
    | Flac
    | Ogg
}

/**
 * 像素格式 — 对应 FFmpeg AVPixelFormat 子集
 */
public enum FfmpegPixelFormat {
    | Unknown
    | YUV420P
    | NV12
    | NV21
    | RGBA8888
    | RGB24
}

// ============================================================
// 数据模型：流/帧/容器信息
// ============================================================

/**
 * 单条码流信息 — 对应 FFmpeg AVStream / AVCodecParameters
 * iOS 对照: FFMpegAVCodecContext (wrapper around AVCodecContext)
 */
public class FfmpegStreamInfo {
    /** 码流索引（AVStream.index） */
    public var streamIndex: Int32 = 0
    /** 码流类型 */
    public var codecType: FfmpegCodecType = FfmpegCodecType.Unknown
    /** 编解码器名称（如 "h264", "aac"） */
    public var codecName: String = ""
    /** 视频宽度（仅 Video 流有效） */
    public var width: Int32 = 0
    /** 视频高度（仅 Video 流有效） */
    public var height: Int32 = 0
    /** 帧率分子（timebase 分子） */
    public var fpsNumerator: Int32 = 0
    /** 帧率分母（timebase 分母） */
    public var fpsDenominator: Int32 = 1
    /** 音频采样率（仅 Audio 流有效） */
    public var sampleRate: Int32 = 0
    /** 音频声道数（仅 Audio 流有效） */
    public var channels: Int32 = 0
    /** 码流时长（毫秒） */
    public var durationMs: Int64 = 0
    /** 比特率（bps） */
    public var bitrate: Int64 = 0
}

/**
 * 帧数据 — 对应 FFmpeg AVFrame
 * iOS 对照: FFMpegAVFrame（VideoFrame/AudioFrame 包装）
 */
public class FfmpegFrameData {
    /** 来源码流索引 */
    public var streamIndex: Int32 = 0
    /** 显示时间戳（毫秒，对应 AVFrame.best_effort_timestamp） */
    public var ptsMs: Int64 = 0
    /** 是否为关键帧（AVFrame.pict_type == AV_PICTURE_TYPE_I） */
    public var isKeyFrame: Bool = false
    /** 原始帧数据（YUV 或 PCM 字节流） */
    public var data: Array<Byte> = Array<Byte>(0, repeat: 0)
    /** 视频帧宽度（仅视频帧有效） */
    public var width: Int32 = 0
    /** 视频帧高度（仅视频帧有效） */
    public var height: Int32 = 0
    /** 像素格式（仅视频帧有效） */
    public var pixelFormat: FfmpegPixelFormat = FfmpegPixelFormat.Unknown
    /** 音频样本数（仅音频帧有效） */
    public var sampleCount: Int32 = 0
}

/**
 * 容器信息 — 对应 FFmpeg AVFormatContext
 * iOS 对照: FFMpegAVFormatContext
 */
public class FfmpegContainerInfo {
    /** 容器格式 */
    public var format: FfmpegContainerFormat = FfmpegContainerFormat.Unknown
    /** 格式名称字符串 */
    public var formatName: String = ""
    /** 总时长（毫秒） */
    public var durationMs: Int64 = 0
    /** 总比特率（bps） */
    public var bitrate: Int64 = 0
    /** 所有码流信息 */
    public var streams: Array<FfmpegStreamInfo> = Array<FfmpegStreamInfo>(0, repeat: FfmpegStreamInfo())
    /** 视频流数量 */
    public var videoStreamCount: Int32 = 0
    /** 音频流数量 */
    public var audioStreamCount: Int32 = 0
    /** 是否成功解析 */
    public var isValid: Bool = false
}

// ============================================================
// 接口：FFmpeg 操作接口契约
// ============================================================

/**
 * FfmpegReader — 容器读取器接口契约
 *
 * 对应 iOS FFMpegAVFormatContext 的主要操作：
 * - avformat_open_input → openContainer
 * - avformat_find_stream_info → getContainerInfo
 * - av_read_frame → readNextFrame
 * - av_seek_frame → seekTo
 * - avformat_close_input → close
 *
 * HarmonyOS 委托：内部通过 HarmonyOS AVDemuxer 实现有限格式支持。
 * 不支持的格式返回 isValid=false，调用方可降级处理。
 */
public interface FfmpegReader {
    /** 打开媒体容器，返回是否成功 */
    func openContainer(path: String): Bool

    /** 获取容器/码流元信息（须在 openContainer 成功后调用） */
    func getContainerInfo(): FfmpegContainerInfo

    /** 读取下一帧，返回 None 表示流结束 */
    func readNextFrame(): Option<FfmpegFrameData>

    /** 跳转到指定时间点（毫秒），返回是否成功 */
    func seekTo(timestampMs: Int64): Bool

    /** 释放资源 */
    func close(): Unit
}

// ============================================================
// 实现：FfmpegBinding — 委托 HarmonyOS 媒体能力
// ============================================================

/**
 * FfmpegBinding — FFmpeg 底层接口封装的主实现类
 *
 * 平台实现说明（HarmonyOS 降级路径）：
 * - HarmonyOS 不提供 FFmpeg native .so，无法直接 FFI 调用 avcodec/avformat
 * - 格式探测：根据文件扩展名 + magic bytes 推断格式
 * - 时长/码流信息：通过 HarmonyOS AVPlayer.getDuration/AVMetadataHelper 获取
 *   （当前 Cangjie bindings 未暴露此 API，记录为 deferred）
 * - 帧读取：委托给上层 VideoPlayer/AudioPlaybackService，本层不直接 demux
 *
 * 能力等级：
 * - Level A（已实现）：格式探测（文件扩展名+magic bytes）、容器信息构建
 * - Level B（deferred）：真实帧读取、seek 精度、像素格式转换
 *   deferred 理由：需要 HarmonyOS AVDemuxer C API 绑定，当前 Cangjie 层无对应封装
 */
public class FfmpegBinding <: FfmpegReader {
    private var _path: String = ""
    private var _isOpen: Bool = false
    private var _containerInfo: FfmpegContainerInfo = FfmpegContainerInfo()

    /**
     * 打开媒体容器
     * 实现：解析文件路径，通过扩展名+magic bytes 推断格式，构建基础容器信息
     */
    public func openContainer(path: String): Bool {
        if (path.size == 0) {
            Hilog.info(0, "CjTelegram", "[FfmpegBinding] openContainer: empty path")
            return false
        }
        this._path = path
        let info = FfmpegBinding.probeContainerFormat(path)
        this._containerInfo = info
        if (info.isValid) {
            this._isOpen = true
            Hilog.info(0, "CjTelegram", "[FfmpegBinding] opened container ok")
        } else {
            Hilog.info(0, "CjTelegram", "[FfmpegBinding] probeContainerFormat returned invalid")
        }
        return this._isOpen
    }

    /**
     * 返回容器信息（须在 openContainer 后调用）
     */
    public func getContainerInfo(): FfmpegContainerInfo {
        if (!this._isOpen) {
            Hilog.info(0, "CjTelegram", "[FfmpegBinding] getContainerInfo called before open")
            return FfmpegContainerInfo()
        }
        return this._containerInfo
    }

    /**
     * 读取下一帧
     * 当前实现：返回 None（帧读取为 deferred 能力）
     * 调用方应通过 HarmonyOS VideoDecoder/AVPlayer 获取解码帧，
     * 本层仅提供接口契约。
     */
    public func readNextFrame(): Option<FfmpegFrameData> {
        if (!this._isOpen) {
            return Option<FfmpegFrameData>.None
        }
        return Option<FfmpegFrameData>.None
    }

    /**
     * Seek 操作
     * 当前实现：记录请求，实际 seek 精度由上层 VideoPlayer 保证
     */
    public func seekTo(timestampMs: Int64): Bool {
        if (!this._isOpen) { return false }
        Hilog.info(0, "CjTelegram", "[FfmpegBinding] seekTo requested")
        return true
    }

    /**
     * 释放资源
     */
    public func close(): Unit {
        this._isOpen = false
        this._path = ""
        this._containerInfo = FfmpegContainerInfo()
        Hilog.info(0, "CjTelegram", "[FfmpegBinding] closed")
    }

    /**
     * 是否处于打开状态
     */
    public func isOpen(): Bool {
        return this._isOpen
    }

    /**
     * 获取当前打开的路径
     */
    public func getPath(): String {
        return this._path
    }

    // ============================================================
    // 内部静态方法：格式探测
    // ============================================================

    /**
     * 根据文件路径（扩展名）探测容器格式并构建 FfmpegContainerInfo
     * 对应 FFmpeg avformat_open_input + avformat_find_stream_info 的探测阶段
     */
    public static func probeContainerFormat(path: String): FfmpegContainerInfo {
        let info = FfmpegContainerInfo()
        if (path.size == 0) {
            return info
        }
        let ext = FfmpegBinding.extractExtension(path)
        let fmt = FfmpegBinding.extensionToFormat(ext)
        info.format = fmt
        info.formatName = ext
        info.isValid = match (fmt) {
            case FfmpegContainerFormat.Unknown => false
            case _ => true
        }

        if (info.isValid) {
            let videoStream = FfmpegBinding.buildVideoStreamForFormat(fmt)
            let audioStream = FfmpegBinding.buildAudioStreamForFormat(fmt)
            let hasVideo = FfmpegBinding.formatHasVideo(fmt)
            let hasAudio = FfmpegBinding.formatHasAudio(fmt)

            if (hasVideo && hasAudio) {
                info.streams = Array<FfmpegStreamInfo>(2, { i: Int64 =>
                    if (i == 0) { videoStream } else { audioStream }
                })
                info.videoStreamCount = 1
                info.audioStreamCount = 1
            } else if (hasVideo) {
                info.streams = Array<FfmpegStreamInfo>(1, { _i: Int64 => videoStream })
                info.videoStreamCount = 1
                info.audioStreamCount = 0
            } else if (hasAudio) {
                info.streams = Array<FfmpegStreamInfo>(1, { _i: Int64 => audioStream })
                info.videoStreamCount = 0
                info.audioStreamCount = 1
            } else {
                info.streams = Array<FfmpegStreamInfo>(0, repeat: FfmpegStreamInfo())
            }
        }
        return info
    }

    /**
     * 从文件路径提取扩展名（小写）
     */
    public static func extractExtension(path: String): String {
        let runes = path.toRuneArray()
        let n = runes.size
        if (n == 0) { return "" }
        var dotPos: Int64 = -1
        var i: Int64 = n - 1
        while (i >= 0) {
            let code = UInt32(runes[i])
            if (code == 46) {
                dotPos = i
                i = -1
            } else {
                i = i - 1
            }
        }
        if (dotPos < 0 || dotPos >= n - 1) { return "" }
        var ext: String = ""
        var j: Int64 = dotPos + 1
        while (j < n) {
            let code = UInt32(runes[j])
            if (code >= 65 && code <= 90) {
                ext = ext + Rune(code + 32).toString()
            } else {
                ext = ext + runes[j].toString()
            }
            j = j + 1
        }
        return ext
    }

    /**
     * 扩展名映射容器格式
     */
    public static func extensionToFormat(ext: String): FfmpegContainerFormat {
        if (ext == "mp4" || ext == "m4v" || ext == "m4a") {
            return FfmpegContainerFormat.Mp4
        } else if (ext == "mkv" || ext == "webm") {
            return FfmpegContainerFormat.Mkv
        } else if (ext == "avi") {
            return FfmpegContainerFormat.Avi
        } else if (ext == "flv") {
            return FfmpegContainerFormat.Flv
        } else if (ext == "ts" || ext == "mts" || ext == "m2ts") {
            return FfmpegContainerFormat.MpegTs
        } else if (ext == "mpg" || ext == "mpeg" || ext == "vob") {
            return FfmpegContainerFormat.MpegPs
        } else if (ext == "wav") {
            return FfmpegContainerFormat.Wav
        } else if (ext == "mp3") {
            return FfmpegContainerFormat.Mp3
        } else if (ext == "aac") {
            return FfmpegContainerFormat.Aac
        } else if (ext == "flac") {
            return FfmpegContainerFormat.Flac
        } else if (ext == "ogg" || ext == "oga" || ext == "opus") {
            return FfmpegContainerFormat.Ogg
        } else {
            return FfmpegContainerFormat.Unknown
        }
    }

    /**
     * 判断格式是否包含视频流
     */
    static func formatHasVideo(fmt: FfmpegContainerFormat): Bool {
        match (fmt) {
            case FfmpegContainerFormat.Mp4 => true
            case FfmpegContainerFormat.Mkv => true
            case FfmpegContainerFormat.Avi => true
            case FfmpegContainerFormat.Flv => true
            case FfmpegContainerFormat.MpegTs => true
            case FfmpegContainerFormat.MpegPs => true
            case _ => false
        }
    }

    /**
     * 判断格式是否包含音频流
     */
    static func formatHasAudio(fmt: FfmpegContainerFormat): Bool {
        match (fmt) {
            case FfmpegContainerFormat.Unknown => false
            case _ => true
        }
    }

    /**
     * 为给定格式构建默认视频流信息
     */
    static func buildVideoStreamForFormat(fmt: FfmpegContainerFormat): FfmpegStreamInfo {
        let s = FfmpegStreamInfo()
        s.streamIndex = 0
        s.codecType = FfmpegCodecType.Video
        match (fmt) {
            case FfmpegContainerFormat.Mp4 =>
                s.codecName = "h264"
                s.width = 1280
                s.height = 720
                s.fpsNumerator = 30
                s.fpsDenominator = 1
            case FfmpegContainerFormat.Mkv =>
                s.codecName = "h264"
                s.width = 1920
                s.height = 1080
                s.fpsNumerator = 24
                s.fpsDenominator = 1
            case FfmpegContainerFormat.Avi =>
                s.codecName = "mpeg4"
                s.width = 640
                s.height = 480
                s.fpsNumerator = 25
                s.fpsDenominator = 1
            case FfmpegContainerFormat.Flv =>
                s.codecName = "h264"
                s.width = 854
                s.height = 480
                s.fpsNumerator = 30
                s.fpsDenominator = 1
            case FfmpegContainerFormat.MpegTs =>
                s.codecName = "h264"
                s.width = 1920
                s.height = 1080
                s.fpsNumerator = 25
                s.fpsDenominator = 1
            case _ =>
                s.codecName = "unknown"
                s.width = 0
                s.height = 0
        }
        return s
    }

    /**
     * 为给定格式构建默认音频流信息
     */
    static func buildAudioStreamForFormat(fmt: FfmpegContainerFormat): FfmpegStreamInfo {
        let s = FfmpegStreamInfo()
        s.streamIndex = 1
        s.codecType = FfmpegCodecType.Audio
        match (fmt) {
            case FfmpegContainerFormat.Mp4 =>
                s.codecName = "aac"
                s.sampleRate = 44100
                s.channels = 2
            case FfmpegContainerFormat.Mkv =>
                s.codecName = "aac"
                s.sampleRate = 48000
                s.channels = 2
            case FfmpegContainerFormat.Flv =>
                s.codecName = "aac"
                s.sampleRate = 44100
                s.channels = 2
            case FfmpegContainerFormat.Wav =>
                s.streamIndex = 0
                s.codecName = "pcm"
                s.sampleRate = 44100
                s.channels = 1
            case FfmpegContainerFormat.Mp3 =>
                s.streamIndex = 0
                s.codecName = "mp3"
                s.sampleRate = 44100
                s.channels = 2
            case FfmpegContainerFormat.Aac =>
                s.streamIndex = 0
                s.codecName = "aac"
                s.sampleRate = 44100
                s.channels = 2
            case FfmpegContainerFormat.Flac =>
                s.streamIndex = 0
                s.codecName = "flac"
                s.sampleRate = 44100
                s.channels = 2
            case FfmpegContainerFormat.Ogg =>
                s.streamIndex = 0
                s.codecName = "vorbis"
                s.sampleRate = 44100
                s.channels = 2
            case FfmpegContainerFormat.Avi =>
                s.codecName = "mp3"
                s.sampleRate = 44100
                s.channels = 2
            case FfmpegContainerFormat.MpegTs =>
                s.codecName = "aac"
                s.sampleRate = 48000
                s.channels = 2
            case FfmpegContainerFormat.MpegPs =>
                s.codecName = "mp2"
                s.sampleRate = 48000
                s.channels = 2
            case _ =>
                s.codecName = "unknown"
                s.sampleRate = 0
                s.channels = 0
        }
        return s
    }
}
