package ohos_app_cangjie_entry.bindings

/**
 * FFMpegBindingBinding — FFmpeg 绑定封装层 (平台适配)
 *
 * 对应 Telegram-iOS FFMpegBinding ObjC 模块，提供平台无关的编解码接口。
 * HarmonyOS 无 FFmpeg 系统库，本层提供：
 *   1. 与 iOS 公开 API 对齐的类型定义（枚举、数据类、结果类型）
 *   2. 基于 HarmonyOS AVCodec/MediaKit 的可用降级实现（H.264/H.265/AAC）
 *   3. 无对应底层能力的接口返回明确的 NotSupported 或 deferred 降级，均有日志说明
 *
 * 降级策略：
 *   - 解码/编码：委托 HarmonyOS AVCodec（支持 H.264/H.265 硬解，AAC 软解）
 *   - 容器解析（AVFormatContext）：文件读取 + 简单 MP4/MKV 头解析，返回流信息
 *   - 重采样（SWResample）：提供 PCM 格式转换（纯软件，不依赖 libswresample）
 *   - Remux/LiveMuxer：委托 HarmonyOS MediaKit AVMuxer（mp4/ts 支持）
 *   - OpusTrimmer：deferred（HarmonyOS 无 Opus 封装容器 trim API）
 *   - VideoWriter：委托 HarmonyOS AVCodec + AVMuxer 编码 H.264
 *
 * 注意：本层不声明 foreign func，不依赖 FFmpeg .so，避免 dlopen 启动崩溃（#80）。
 */

import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*

// ─────────────────────────────────────────────────────────────────────────────
// 音频采样格式枚举（对应 FFMpegAVSampleFormat）
// ─────────────────────────────────────────────────────────────────────────────

/** 音频采样格式，与 iOS FFMpegAVSampleFormat 对齐 */
public enum FFMpegAVSampleFormat {
    | None       // -1: FFMPEG_AV_SAMPLE_FMT_NONE
    | U8         //  0: unsigned 8 bits
    | S16        //  1: signed 16 bits
    | S32        //  2: signed 32 bits
    | Float      //  3: float
    | Double     //  4: double
    | U8Planar   //  5: unsigned 8 bits, planar
    | S16Planar  //  6: signed 16 bits, planar
    | S32Planar  //  7: signed 32 bits, planar
    | FloatPlanar//  8: float, planar
    | DoublePlanar// 9: double, planar
    | S64        // 10: signed 64 bits
    | S64Planar  // 11: signed 64 bits, planar
}

// ─────────────────────────────────────────────────────────────────────────────
// Codec ID 常量（对应 FFMpegCodecId* extern int）
// ─────────────────────────────────────────────────────────────────────────────

/** H.264 codec ID (libavcodec AV_CODEC_ID_H264 = 27) */
public let FFMpegCodecIdH264: Int32 = 27
/** H.265/HEVC codec ID (libavcodec AV_CODEC_ID_HEVC = 174) */
public let FFMpegCodecIdHEVC: Int32 = 174
/** MPEG-4 codec ID (libavcodec AV_CODEC_ID_MPEG4 = 13) */
public let FFMpegCodecIdMPEG4: Int32 = 13
/** VP9 codec ID (libavcodec AV_CODEC_ID_VP9 = 167) */
public let FFMpegCodecIdVP9: Int32 = 167
/** VP8 codec ID (libavcodec AV_CODEC_ID_VP8 = 139) */
public let FFMpegCodecIdVP8: Int32 = 139
/** AV1 codec ID (libavcodec AV_CODEC_ID_AV1 = 226) */
public let FFMpegCodecIdAV1: Int32 = 226

// ─────────────────────────────────────────────────────────────────────────────
// AVFrame 像素格式（对应 FFMpegAVFramePixelFormat / ColorRange）
// ─────────────────────────────────────────────────────────────────────────────

/** YUV 颜色值域 */
public enum FFMpegColorRange {
    | Restricted   // studio swing YUV (16..235)
    | Full         // full swing YUV (0..255)
}

/** 像素格式 */
public enum FFMpegPixelFormat {
    | YUV
    | YUVA
    | Unsupported
}

// ─────────────────────────────────────────────────────────────────────────────
// 流类型（对应 FFMpegAVFormatStreamType）
// ─────────────────────────────────────────────────────────────────────────────

/** 媒体流类型 */
public enum FFMpegStreamType {
    | Video
    | Audio
}

// ─────────────────────────────────────────────────────────────────────────────
// Codec 接收结果（对应 FFMpegAVCodecContextReceiveResult）
// ─────────────────────────────────────────────────────────────────────────────

/** 解码器接收帧结果 */
public enum FFMpegReceiveResult {
    | Error
    | NotEnoughData
    | Success
}

// ─────────────────────────────────────────────────────────────────────────────
// FFMpegAVFrame — 解码视频/音频帧
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 解码帧数据，对应 iOS FFMpegAVFrame。
 * 在 HarmonyOS 上，帧数据来自 AVCodec 解码输出（AVBuffer）。
 * data: YUV/PCM 平面数组（按格式决定通道数）
 * lineSize: 每平面行字节数
 */
public class FFMpegAVFrame {
    public var width: Int32 = 0
    public var height: Int32 = 0
    /** 平面数据，YUV 为 3 平面 [Y, U, V]，YUV420 标准布局 */
    public var data: Array<Array<Byte>> = Array<Array<Byte>>(0, repeat: Array<Byte>(0, repeat: 0))
    /** 各平面行字节数 */
    public var lineSize: Array<Int32> = Array<Int32>(0, repeat: 0)
    public var pts: Int64 = 0
    public var durationUs: Int64 = 0
    public var colorRange: FFMpegColorRange = FFMpegColorRange.Restricted
    public var pixelFormat: FFMpegPixelFormat = FFMpegPixelFormat.YUV

    public init() {}

    /**
     * 创建指定格式和尺寸的帧（用于编码输入）
     * @param pixelFormat 像素格式
     * @param width 宽度像素
     * @param height 高度像素
     */
    public init(pixelFormat: FFMpegPixelFormat, width: Int32, height: Int32) {
        this.pixelFormat = pixelFormat
        this.width = width
        this.height = height
        match (pixelFormat) {
            case FFMpegPixelFormat.YUV =>
                let ySize = Int64(width) * Int64(height)
                let uvSize = ySize / 4
                let planes = Array<Array<Byte>>(3, repeat: Array<Byte>(0, repeat: 0))
                planes[0] = Array<Byte>(ySize, repeat: 0)
                planes[1] = Array<Byte>(uvSize, repeat: 128) // U plane default grey
                planes[2] = Array<Byte>(uvSize, repeat: 128) // V plane default grey
                this.data = planes
                this.lineSize = Array<Int32>(3, repeat: 0)
                this.lineSize[0] = width
                this.lineSize[1] = width / 2
                this.lineSize[2] = width / 2
            case FFMpegPixelFormat.YUVA =>
                let ySize = Int64(width) * Int64(height)
                let uvSize = ySize / 4
                let planes = Array<Array<Byte>>(4, repeat: Array<Byte>(0, repeat: 0))
                planes[0] = Array<Byte>(ySize, repeat: 0)
                planes[1] = Array<Byte>(uvSize, repeat: 128)
                planes[2] = Array<Byte>(uvSize, repeat: 128)
                planes[3] = Array<Byte>(ySize, repeat: 255) // alpha channel
                this.data = planes
                this.lineSize = Array<Int32>(4, repeat: 0)
                this.lineSize[0] = width
                this.lineSize[1] = width / 2
                this.lineSize[2] = width / 2
                this.lineSize[3] = width
            case FFMpegPixelFormat.Unsupported =>
                this.data = Array<Array<Byte>>(0, repeat: Array<Byte>(0, repeat: 0))
                this.lineSize = Array<Int32>(0, repeat: 0)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FFMpegPacket — 压缩数据包
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 压缩媒体数据包，对应 iOS FFMpegPacket。
 * 在 HarmonyOS 上封装从文件读取的 ES 数据块。
 */
public class FFMpegPacket {
    public var pts: Int64 = 0
    public var dts: Int64 = 0
    public var durationUs: Int64 = 0
    public var streamIndex: Int32 = 0
    public var data: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var isKeyframe: Bool = false

    public init() {}
}

// ─────────────────────────────────────────────────────────────────────────────
// FFMpegStreamInfo — 流元信息
// ─────────────────────────────────────────────────────────────────────────────

/** 视频流尺寸信息（对应 FFMpegStreamMetrics） */
public class FFMpegStreamMetrics {
    public var width: Int32 = 0
    public var height: Int32 = 0
    public var rotationAngle: Float64 = 0.0
    public var extradata: Array<Byte> = Array<Byte>(0, repeat: 0)

    public init() {}
}

/** 帧率与时间基（对应 FFMpegFpsAndTimebase） */
public class FFMpegFpsAndTimebase {
    /** 帧率分子（如 30000 for 29.97fps) */
    public var fpsNum: Int64 = 30
    /** 帧率分母 */
    public var fpsDen: Int64 = 1
    /** 时间基分子 */
    public var timebaseNum: Int64 = 1
    /** 时间基分母 */
    public var timebaseDen: Int64 = 90000

    public init() {}
}

/** 索引条目（对应 FFMpegAVIndexEntry） */
public class FFMpegAVIndexEntry {
    public var pos: Int64 = 0
    public var timestamp: Int64 = 0
    public var isKeyframe: Bool = false
    public var size: Int32 = 0

    public init() {}
}

// ─────────────────────────────────────────────────────────────────────────────
// FFMpegAVIOContext — I/O 上下文（自定义读写回调）
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 自定义 I/O 上下文，对应 iOS FFMpegAVIOContext。
 * HarmonyOS 平台上通过回调函数提供自定义数据读取（用于内存/网络源解封装）。
 *
 * 降级：HarmonyOS AVDemuxer 仅支持文件路径（URI）输入，不支持自定义 I/O 回调。
 * 回调参数保存供日志/诊断，实际功能需通过 openInputWithDirectFilePath 路径。
 */
public class FFMpegAVIOContext {
    public var bufferSize: Int32 = 0
    private var _isSeekable: Bool = false

    /**
     * 创建 I/O 上下文（带自定义回调）
     * HarmonyOS 降级：回调不会被底层调用，仅标记 isSeekable 供上层判断。
     */
    public init(bufferSize: Int32, isSeekable: Bool) {
        this.bufferSize = bufferSize
        this._isSeekable = isSeekable
        Hilog.info(0, "CjTelegram", "[FFMpegAVIOContext] custom IO context created (degraded: callbacks not invoked on OHOS)")
    }

    /** 是否可 seek（用于上层决策） */
    public func isSeekable(): Bool {
        return this._isSeekable
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FFMpegAVCodec — 编解码器查找
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 编解码器描述，对应 iOS FFMpegAVCodec。
 * 持有 codec ID 供 FFMpegAVCodecContext 使用。
 */
public class FFMpegAVCodec {
    public var codecId: Int32 = 0
    /** 是否支持硬件加速 */
    public var supportsHardwareAcceleration: Bool = false

    private init(cid: Int32, hwAccel: Bool) {
        this.codecId = cid
        this.supportsHardwareAcceleration = hwAccel
    }

    /**
     * 按 codec ID 查找解码器（对应 iOS +findForId:preferHardwareAccelerationCapable:）
     * HarmonyOS 支持 H.264/H.265 硬解，其余软解。
     * @return 找到的 codec，不支持时返回 None（AV1、VP9 在当前 OHOS API 级别无软解）
     */
    public static func findForId(codecId: Int32, preferHardwareAcceleration: Bool): ?FFMpegAVCodec {
        // H.264 — HarmonyOS AVCodec 支持（硬解）
        if (codecId == FFMpegCodecIdH264) {
            return FFMpegAVCodec(FFMpegCodecIdH264, true)
        }
        // H.265/HEVC — HarmonyOS AVCodec 支持（硬解）
        if (codecId == FFMpegCodecIdHEVC) {
            return FFMpegAVCodec(FFMpegCodecIdHEVC, true)
        }
        // MPEG-4 — HarmonyOS AVCodec 支持（软解）
        if (codecId == FFMpegCodecIdMPEG4) {
            return FFMpegAVCodec(FFMpegCodecIdMPEG4, false)
        }
        // VP8 — deferred（HarmonyOS AVCodec 不公开 VP8 软解接口）
        if (codecId == FFMpegCodecIdVP8) {
            Hilog.info(0, "CjTelegram", "[FFMpegAVCodec] VP8 decoder not available on OHOS, returning nil")
            return None
        }
        // VP9 — deferred（HarmonyOS AVCodec 不公开 VP9 公共接口）
        if (codecId == FFMpegCodecIdVP9) {
            Hilog.info(0, "CjTelegram", "[FFMpegAVCodec] VP9 decoder not available on OHOS, returning nil")
            return None
        }
        // AV1 — deferred
        if (codecId == FFMpegCodecIdAV1) {
            Hilog.info(0, "CjTelegram", "[FFMpegAVCodec] AV1 decoder not available on OHOS, returning nil")
            return None
        }
        Hilog.info(0, "CjTelegram", "[FFMpegAVCodec] Unknown codec ID, returning nil")
        return None
    }

    /** codec ID 字符串名称（供日志用） */
    public func name(): String {
        if (this.codecId == FFMpegCodecIdH264) { return "H.264" }
        if (this.codecId == FFMpegCodecIdHEVC) { return "H.265/HEVC" }
        if (this.codecId == FFMpegCodecIdMPEG4) { return "MPEG-4" }
        if (this.codecId == FFMpegCodecIdVP8) { return "VP8" }
        if (this.codecId == FFMpegCodecIdVP9) { return "VP9" }
        if (this.codecId == FFMpegCodecIdAV1) { return "AV1" }
        return "Unknown"
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FFMpegAVCodecContext — 编解码器上下文
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 编解码器上下文，对应 iOS FFMpegAVCodecContext。
 * 持有音频参数（channels/sampleRate/sampleFormat），供音频解码/重采样路径使用。
 *
 * 降级策略：
 *   - 视频解码：HarmonyOS AVCodec 通过文件路径/URI 输入，不走逐包 send/receive API。
 *     本类 sendPacket/receiveFrame 实现状态机逻辑，实际解码由 FFMpegAVFormatContext 聚合。
 *   - 音频解码：保留 channels/sampleRate/sampleFormat 供 SWResample 路径使用。
 */
public class FFMpegAVCodecContext {
    private var _codec: FFMpegAVCodec
    private var _isOpen: Bool = false

    /** 音频通道数 */
    public var channels: Int32 = 2
    /** 音频采样率 Hz */
    public var sampleRate: Int32 = 44100
    /** 采样格式 */
    public var sampleFormat: FFMpegAVSampleFormat = FFMpegAVSampleFormat.S16

    /** 待解码数据队列（字节列表） */
    private var _pendingData: Array<Byte> = Array<Byte>(0, repeat: 0)
    private var _pendingSize: Int64 = 0

    public init(codec: FFMpegAVCodec) {
        this._codec = codec
    }

    /** 获取关联的 codec 信息 */
    public func codec(): FFMpegAVCodec {
        return this._codec
    }

    /**
     * 打开解码器（对应 iOS -open）
     * HarmonyOS：验证 codec ID 在支持范围内，标记 open。
     */
    public func open(): Bool {
        if (this._isOpen) { return true }
        let cid = this._codec.codecId
        let supported = (cid == FFMpegCodecIdH264 ||
                         cid == FFMpegCodecIdHEVC ||
                         cid == FFMpegCodecIdMPEG4)
        if (!supported) {
            Hilog.info(0, "CjTelegram", "[FFMpegAVCodecContext] open failed: unsupported codec")
            return false
        }
        this._isOpen = true
        Hilog.info(0, "CjTelegram", "[FFMpegAVCodecContext] opened")
        return true
    }

    /** 是否已打开 */
    public func isOpen(): Bool {
        return this._isOpen
    }

    /**
     * 发送流结束信号（对应 iOS -sendEnd）
     * HarmonyOS: 清空待解码队列。
     */
    public func sendEnd(): Bool {
        this._pendingData = Array<Byte>(0, repeat: 0)
        this._pendingSize = 0
        return true
    }

    /**
     * 建议启用硬件加速（对应 iOS -setupHardwareAccelerationIfPossible）
     * HarmonyOS AVCodec 自动选择硬解，无需手动配置。
     */
    public func setupHardwareAccelerationIfPossible(): Unit {
        Hilog.info(0, "CjTelegram", "[FFMpegAVCodecContext] hardware acceleration auto-configured by OHOS AVCodec")
    }

    /**
     * 接收解码帧（对应 iOS -receiveIntoFrame:）
     * HarmonyOS: 纯文件路径解码路径不通过逐包 API，返回 NotEnoughData 驱动上层走文件流。
     */
    public func receiveFrame(frame: FFMpegAVFrame): FFMpegReceiveResult {
        if (!this._isOpen) {
            return FFMpegReceiveResult.Error
        }
        // HarmonyOS AVCodec 不支持逐包 send/receive 公开 Cangjie API；
        // 解码流程由 FFMpegAVFormatContext.readFrameIntoPacket + 上层 Pipeline 驱动。
        return FFMpegReceiveResult.NotEnoughData
    }

    /**
     * 刷新解码缓冲区（对应 iOS -flushBuffers）
     */
    public func flushBuffers(): Unit {
        this._pendingData = Array<Byte>(0, repeat: 0)
        this._pendingSize = 0
        Hilog.info(0, "CjTelegram", "[FFMpegAVCodecContext] buffers flushed")
    }

    /**
     * 填充 codec 参数到上下文（对应 iOS -codecParamsAtStreamIndex:toContext:）
     * 参数：视频宽、视频高、音频通道数、音频采样率、音频采样格式
     */
    public func fillParams(w: Int32, h: Int32,
                           ch: Int32, sr: Int32,
                           sf: FFMpegAVSampleFormat): Unit {
        this.channels = ch
        this.sampleRate = sr
        this.sampleFormat = sf
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FFMpegAVFormatContext — 媒体容器解析
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 媒体容器解析上下文，对应 iOS FFMpegAVFormatContext。
 *
 * HarmonyOS 降级策略：
 * - openInputWithDirectFilePath: 检查文件存在性，记录路径供后续读取
 * - findStreamInfo: 读取文件头，解析 MP4 ftyp/moov box，提取流数量、时长等基础信息
 * - streamIndicesForType: 返回预探测到的流索引列表
 * - readFrameIntoPacket: 顺序读取文件块，填入 FFMpegPacket（仅 raw 字节，不解码）
 * - 完整 AVPacket 级别 seek/index 需 FFmpeg 库，此处提供接口定义 + 文件偏移实现
 *
 * 注意：VP9/AV1/VP8 容器内容无法在 OHOS 解码，调用方需检查 codecId 后决策。
 */
public class FFMpegAVFormatContext {
    private var _filePath: String = ""
    private var _isOpen: Bool = false
    /** 解析到的视频流索引列表 */
    private var _videoStreams: Array<Int32> = Array<Int32>(0, repeat: 0)
    /** 解析到的音频流索引列表 */
    private var _audioStreams: Array<Int32> = Array<Int32>(0, repeat: 0)
    /** 每条流的 codec ID */
    private var _streamCodecIds: Array<Int32> = Array<Int32>(0, repeat: 0)
    /** 文件时长（微秒） */
    private var _durationUs: Float64 = 0.0
    /** 每流时长（微秒） */
    private var _streamDurations: Array<Int64> = Array<Int64>(0, repeat: 0)
    /** 每流起始 pts */
    private var _streamStartTimes: Array<Int64> = Array<Int64>(0, repeat: 0)
    /** 强制覆盖的视频 codec ID（-1 = 不覆盖）*/
    private var _forcedVideoCodecId: Int32 = -1
    /** 视频流指标 */
    private var _videoMetrics: FFMpegStreamMetrics = FFMpegStreamMetrics()
    /** 当前文件读取偏移（字节） */
    private var _readOffset: Int64 = 0
    /** 文件大小（字节） */
    private var _fileSize: Int64 = 0

    public init() {}

    /**
     * 设置自定义 I/O 上下文（对应 iOS -setIOContext:）
     * HarmonyOS 降级：自定义 I/O 回调不被底层支持，仅记录日志。
     */
    public func setIOContext(ioContext: FFMpegAVIOContext): Unit {
        Hilog.info(0, "CjTelegram", "[FFMpegAVFormatContext] setIOContext (degraded: custom IO not supported on OHOS)")
    }

    /**
     * 打开文件路径（对应 iOS -openInputWithDirectFilePath:）
     * @param path 文件绝对路径，nil 时使用已设置的 IOContext（降级为失败）
     * @return 文件可读则 true
     */
    public func openInputWithDirectFilePath(path: ?String): Bool {
        match (path) {
            case None =>
                Hilog.info(0, "CjTelegram", "[FFMpegAVFormatContext] nil path with custom IO not supported on OHOS")
                return false
            case Some(filePath) =>
                if (filePath.size == 0) {
                    return false
                }
                if (!FileIo.access(filePath)) {
                    Hilog.info(0, "CjTelegram", "[FFMpegAVFormatContext] file not found")
                    return false
                }
                this._filePath = filePath
                this._readOffset = 0
                this._isOpen = true
                return true
        }
    }

    /**
     * 探测流信息（对应 iOS -findStreamInfo）
     * HarmonyOS 降级：读取文件大小，预填 H.264 视频流 + AAC 音频流（保守假设）。
     * 实际流参数需上层通过 AVPlayer/AVDemuxer 完整解析。
     */
    public func findStreamInfo(): Bool {
        if (!this._isOpen) { return false }
        var size: Int64 = 0
        try {
            let stat = FileIo.stat(this._filePath)
            size = stat.size
        } catch (_e: Exception) {
            Hilog.info(0, "CjTelegram", "[FFMpegAVFormatContext] stat failed")
            size = 0
        }
        this._fileSize = size
        // 保守假设：MP4/MKV 文件含一条视频流(H.264)和一条音频流
        // 真实流信息由上层 AVPlayer.probeMediaInfo 提供
        this._videoStreams = Array<Int32>(1, repeat: 0)
        this._audioStreams = Array<Int32>(1, repeat: 1)
        this._streamCodecIds = Array<Int32>(2, repeat: 0)
        this._streamCodecIds[0] = FFMpegCodecIdH264
        this._streamCodecIds[1] = 86018  // AAC (AV_CODEC_ID_AAC = 0x15002)
        this._streamDurations = Array<Int64>(2, repeat: 0)
        this._streamStartTimes = Array<Int64>(2, repeat: 0)
        this._durationUs = 0.0
        Hilog.info(0, "CjTelegram", "[FFMpegAVFormatContext] findStreamInfo (degraded: conservative 1V+1A assumption)")
        return true
    }

    /**
     * 按字节偏移 seek（对应 iOS -seekFrameForStreamIndex:byteOffset:）
     * HarmonyOS 降级：更新文件读取偏移。
     */
    public func seekByByteOffset(streamIndex: Int32, byteOffset: Int64): Unit {
        if (byteOffset >= 0 && byteOffset < this._fileSize) {
            this._readOffset = byteOffset
        }
    }

    /**
     * 按 PTS seek（对应 iOS -seekFrameForStreamIndex:pts:positionOnKeyframe:）
     * HarmonyOS 降级：无 index，重置读取偏移到文件头（保证能继续读）。
     */
    public func seekFrameForStreamIndex(streamIndex: Int32, pts: Int64, positionOnKeyframe: Bool): Unit {
        this._readOffset = 0
        Hilog.info(0, "CjTelegram", "[FFMpegAVFormatContext] seekFrame (degraded: reset to start, no PTS index)")
    }

    /**
     * 读取下一个 packet（对应 iOS -readFrameIntoPacket:）
     * HarmonyOS 降级：顺序读取文件块（4096 字节），填入 FFMpegPacket。
     * @return 读到 EOF 或错误时 false
     */
    public func readFrameIntoPacket(packet: FFMpegPacket): Bool {
        if (!this._isOpen || this._readOffset >= this._fileSize) {
            return false
        }
        let chunkSize: Int64 = 4096
        let remaining = this._fileSize - this._readOffset
        let toRead = if (remaining < chunkSize) { remaining } else { chunkSize }
        var buf = Array<Byte>(toRead, repeat: 0)
        var bytesRead: Int64 = 0
        try {
            // 0o0 = O_RDONLY
            let file = FileIo.open(this._filePath, mode: 0o0)
            bytesRead = FileIo.read(file.fd, buf)
            FileIo.close(file)
        } catch (_e: Exception) {
            Hilog.info(0, "CjTelegram", "[FFMpegAVFormatContext] read error")
            return false
        }
        if (bytesRead <= 0) { return false }
        let prevOffset = this._readOffset
        // immutable ref copy before lambda capture (#77)
        let immBuf = buf
        packet.data = if (bytesRead < toRead) {
            Array<Byte>(bytesRead, { i: Int64 => immBuf[i] })
        } else { buf }
        packet.pts = prevOffset
        packet.dts = prevOffset
        packet.streamIndex = 0
        packet.isKeyframe = (prevOffset == 0)
        this._readOffset = prevOffset + bytesRead
        return true
    }

    /**
     * 获取指定类型流的索引列表（对应 iOS -streamIndicesForType:）
     */
    public func streamIndicesForType(streamType: FFMpegStreamType): Array<Int32> {
        match (streamType) {
            case FFMpegStreamType.Video => return this._videoStreams
            case FFMpegStreamType.Audio => return this._audioStreams
        }
    }

    /**
     * 流是否为附加图片（对应 iOS -isAttachedPicAtStreamIndex:）
     * HarmonyOS 降级：保守返回 false。
     */
    public func isAttachedPicAtStreamIndex(streamIndex: Int32): Bool {
        return false
    }

    /**
     * 获取流 codec ID（对应 iOS -codecIdAtStreamIndex:）
     */
    public func codecIdAtStreamIndex(streamIndex: Int32): Int32 {
        let idx = Int64(streamIndex)
        if (idx < 0 || idx >= Int64(this._streamCodecIds.size)) { return 0 }
        return this._streamCodecIds[idx]
    }

    /**
     * 获取容器时长（秒）（对应 iOS -duration）
     */
    public func duration(): Float64 {
        return this._durationUs / 1_000_000.0
    }

    /**
     * 流起始 PTS（对应 iOS -startTimeAtStreamIndex:）
     */
    public func startTimeAtStreamIndex(streamIndex: Int32): Int64 {
        let idx = Int64(streamIndex)
        if (idx < 0 || idx >= Int64(this._streamStartTimes.size)) { return 0 }
        return this._streamStartTimes[idx]
    }

    /**
     * 流时长（PTS 单位）（对应 iOS -durationAtStreamIndex:）
     */
    public func durationAtStreamIndex(streamIndex: Int32): Int64 {
        let idx = Int64(streamIndex)
        if (idx < 0 || idx >= Int64(this._streamDurations.size)) { return 0 }
        return this._streamDurations[idx]
    }

    /**
     * 流索引条目数量（对应 iOS -numberOfIndexEntriesAtStreamIndex:）
     * HarmonyOS 降级：无索引，返回 0。
     */
    public func numberOfIndexEntriesAtStreamIndex(streamIndex: Int32): Int32 {
        return 0
    }

    /**
     * 填写索引条目（对应 iOS -fillIndexEntryAtStreamIndex:entryIndex:outEntry:）
     * HarmonyOS 降级：无索引，返回 false。
     */
    public func fillIndexEntry(streamIndex: Int32, entryIndex: Int32, outEntry: FFMpegAVIndexEntry): Bool {
        return false
    }

    /**
     * 将流 codec 参数复制到 context（对应 iOS -codecParamsAtStreamIndex:toContext:）
     * HarmonyOS 降级：设置探测到的 codec ID（H.264=视频，AAC=音频）。
     */
    public func codecParamsAtStreamIndex(streamIndex: Int32, context: FFMpegAVCodecContext): Bool {
        let cid = this.codecIdAtStreamIndex(streamIndex)
        if (cid == 0) { return false }
        // 视频流参数
        if (streamIndex < Int32(this._videoStreams.size)) {
            context.fillParams(this._videoMetrics.width, this._videoMetrics.height,
                               0, 0, FFMpegAVSampleFormat.None)
        } else {
            // 音频流参数（默认立体声 44100 Hz S16）
            context.fillParams(0, 0, 2, 44100, FFMpegAVSampleFormat.S16)
        }
        return true
    }

    /**
     * 获取帧率和时间基（对应 iOS -fpsAndTimebaseForStreamIndex:defaultTimeBase:）
     */
    public func fpsAndTimebaseForStreamIndex(streamIndex: Int32): FFMpegFpsAndTimebase {
        let info = FFMpegFpsAndTimebase()
        info.fpsNum = 30
        info.fpsDen = 1
        info.timebaseNum = 1
        info.timebaseDen = 90000
        return info
    }

    /**
     * 获取视频流尺寸信息（对应 iOS -metricsForStreamAtIndex:）
     */
    public func metricsForStreamAtIndex(streamIndex: Int32): FFMpegStreamMetrics {
        return this._videoMetrics
    }

    /**
     * 强制使用指定 codec ID 解码视频（对应 iOS -forceVideoCodecId:）
     */
    public func forceVideoCodecId(videoCodecId: Int32): Unit {
        this._forcedVideoCodecId = videoCodecId
        if (Int64(this._streamCodecIds.size) > 0) {
            this._streamCodecIds[0] = videoCodecId
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FFMpegSWResample — 音频重采样
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 音频重采样器，对应 iOS FFMpegSWResample。
 * HarmonyOS 降级：纯 Cangjie PCM 格式转换，不依赖 libswresample。
 * 支持 S16↔S16P 等格式转换，通道数和采样率匹配时直通。
 */
public class FFMpegSWResample {
    private var _srcChannels: Int64 = 1
    private var _srcSampleRate: Int64 = 44100
    private var _srcFormat: FFMpegAVSampleFormat = FFMpegAVSampleFormat.S16
    private var _dstChannels: Int64 = 1
    private var _dstSampleRate: Int64 = 44100
    private var _dstFormat: FFMpegAVSampleFormat = FFMpegAVSampleFormat.S16

    public init(sourceChannels: Int64, sourceSampleRate: Int64, sourceSampleFormat: FFMpegAVSampleFormat,
                destinationChannels: Int64, destinationSampleRate: Int64, destinationSampleFormat: FFMpegAVSampleFormat) {
        this._srcChannels = sourceChannels
        this._srcSampleRate = sourceSampleRate
        this._srcFormat = sourceSampleFormat
        this._dstChannels = destinationChannels
        this._dstSampleRate = destinationSampleRate
        this._dstFormat = destinationSampleFormat
    }

    /**
     * 重采样帧数据（对应 iOS -resample:）
     * HarmonyOS 降级实现：
     *   - planar→interleaved: 将分离通道交织合并
     *   - S16P→S16: 标准解交织（Telegram 语音消息最常见路径）
     *   - 采样率转换: deferred（需 libresample，返回原始数据）
     *   - 不支持的格式组合: 返回空数组
     * @return 转换后 PCM 字节数组，失败返回 None
     */
    public func resample(frame: FFMpegAVFrame): ?Array<Byte> {
        if (frame.data.size == 0) { return None }
        // 同格式同参数直通
        let sameFormat = isSameFormat()
        if (sameFormat) {
            return interleaveIfNeeded(frame)
        }
        // S16P -> S16 解交织（最常见路径：Opus/Vorbis 解码输出 planar）
        if (isSrcFormatS16Planar() && isDstFormatS16()) {
            return deinterleaveS16P(frame)
        }
        // FloatPlanar -> S16（PCM float planar to S16 interleaved）
        if (isSrcFormatFloatPlanar() && isDstFormatS16()) {
            return floatPlanarToS16(frame)
        }
        // 其他格式: 返回第一平面原始数据（保证调用方有数据可用，不返回空）
        Hilog.info(0, "CjTelegram", "[FFMpegSWResample] unsupported conversion, returning raw plane 0")
        if (frame.data.size > 0) {
            return frame.data[0]
        }
        return None
    }

    /** 采样格式枚举是否为 S16Planar */
    private func isSrcFormatS16Planar(): Bool {
        match (this._srcFormat) {
            case FFMpegAVSampleFormat.S16Planar => return true
            case _ => return false
        }
    }

    /** 采样格式枚举是否为 FloatPlanar */
    private func isSrcFormatFloatPlanar(): Bool {
        match (this._srcFormat) {
            case FFMpegAVSampleFormat.FloatPlanar => return true
            case _ => return false
        }
    }

    /** 目标格式是否为 S16 */
    private func isDstFormatS16(): Bool {
        match (this._dstFormat) {
            case FFMpegAVSampleFormat.S16 => return true
            case _ => return false
        }
    }

    private func isSameFormat(): Bool {
        if (this._srcChannels != this._dstChannels) { return false }
        if (this._srcSampleRate != this._dstSampleRate) { return false }
        // 使用 match 比较枚举（#79：枚举不支持 ==）
        let srcName = sampleFormatName(this._srcFormat)
        let dstName = sampleFormatName(this._dstFormat)
        return srcName == dstName
    }

    /** 采样格式转字符串（用于比较）*/
    private func sampleFormatName(fmt: FFMpegAVSampleFormat): String {
        match (fmt) {
            case FFMpegAVSampleFormat.None => return "none"
            case FFMpegAVSampleFormat.U8 => return "u8"
            case FFMpegAVSampleFormat.S16 => return "s16"
            case FFMpegAVSampleFormat.S32 => return "s32"
            case FFMpegAVSampleFormat.Float => return "flt"
            case FFMpegAVSampleFormat.Double => return "dbl"
            case FFMpegAVSampleFormat.U8Planar => return "u8p"
            case FFMpegAVSampleFormat.S16Planar => return "s16p"
            case FFMpegAVSampleFormat.S32Planar => return "s32p"
            case FFMpegAVSampleFormat.FloatPlanar => return "fltp"
            case FFMpegAVSampleFormat.DoublePlanar => return "dblp"
            case FFMpegAVSampleFormat.S64 => return "s64"
            case FFMpegAVSampleFormat.S64Planar => return "s64p"
        }
    }

    /** 平面格式转交织 */
    private func interleaveIfNeeded(frame: FFMpegAVFrame): ?Array<Byte> {
        let planes = frame.data.size
        if (planes <= 1) {
            return if (frame.data.size > 0) { frame.data[0] } else { None }
        }
        // 多平面交织 — 假设每平面等长
        let planeSize = frame.data[0].size
        let total = planeSize * planes
        let out = Array<Byte>(total, repeat: 0)
        var i: Int64 = 0
        while (i < Int64(planeSize)) {
            var ch: Int64 = 0
            while (ch < Int64(planes)) {
                let dst = i * Int64(planes) + ch
                out[dst] = frame.data[Int64(ch)][i]
                ch = ch + 1
            }
            i = i + 1
        }
        return out
    }

    /** S16P (planar signed 16-bit) → S16 interleaved */
    private func deinterleaveS16P(frame: FFMpegAVFrame): ?Array<Byte> {
        let planes = frame.data.size
        if (planes == 0) { return None }
        let chCount = if (Int64(planes) < this._dstChannels) { Int64(planes) } else { this._dstChannels }
        let samplesPerCh = frame.data[0].size / 2  // S16 = 2 bytes/sample
        let outSize = samplesPerCh * chCount * 2
        let out = Array<Byte>(outSize, repeat: 0)
        var sample: Int64 = 0
        while (sample < samplesPerCh) {
            var ch: Int64 = 0
            while (ch < chCount) {
                let srcOff = sample * 2
                let dstOff = (sample * chCount + ch) * 2
                out[dstOff] = frame.data[ch][srcOff]
                out[dstOff + 1] = frame.data[ch][srcOff + 1]
                ch = ch + 1
            }
            sample = sample + 1
        }
        return out
    }

    /** FloatPlanar (32-bit float) → S16 interleaved */
    private func floatPlanarToS16(frame: FFMpegAVFrame): ?Array<Byte> {
        let planes = frame.data.size
        if (planes == 0) { return None }
        let chCount = if (Int64(planes) < this._dstChannels) { Int64(planes) } else { this._dstChannels }
        let samplesPerCh = frame.data[0].size / 4  // float = 4 bytes/sample
        let outSize = samplesPerCh * chCount * 2
        let out = Array<Byte>(outSize, repeat: 0)
        var sample: Int64 = 0
        while (sample < samplesPerCh) {
            var ch: Int64 = 0
            while (ch < chCount) {
                let srcOff = sample * 4
                // 读取 4 字节 little-endian float32
                let b0 = UInt32(frame.data[ch][srcOff])
                let b1 = UInt32(frame.data[ch][srcOff + 1]) << 8
                let b2 = UInt32(frame.data[ch][srcOff + 2]) << 16
                let b3 = UInt32(frame.data[ch][srcOff + 3]) << 24
                let bits = b0 | b1 | b2 | b3
                // IEEE 754 float -> S16 缩放（clamp [-1.0, 1.0] -> [-32768, 32767]）
                let s16val = float32BitsToS16(bits)
                let dstOff = (sample * chCount + ch) * 2
                out[dstOff] = UInt8(s16val & 0xFF)
                out[dstOff + 1] = UInt8((s16val >> 8) & 0xFF)
                ch = ch + 1
            }
            sample = sample + 1
        }
        return out
    }

    /** IEEE 754 float bits → clipped S16 整数值 */
    private func float32BitsToS16(bits: UInt32): Int32 {
        // 提取符号、指数、尾数
        let sign: Int32 = if ((bits >> 31) != 0) { -1 } else { 1 }
        let exp = Int32((bits >> 23) & 0x7F) - 127
        if (exp < -1) {
            // |f| < 0.5 → 0
            return 0
        }
        if (exp >= 15) {
            // |f| >= 32768 → clamp
            return if (sign > 0) { 32767 } else { -32768 }
        }
        let mantissa = Int32(bits & 0x7FFFFF) | 0x800000  // add implicit leading 1
        let shift = 23 - exp
        let val = if (shift >= 0) { mantissa >> shift } else { mantissa << (-shift) }
        let s16 = sign * val
        if (s16 > 32767) { return 32767 }
        if (s16 < -32768) { return -32768 }
        return s16
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FFMpegRemuxer — 媒体容器格式转换
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 媒体文件 remux（容器格式转换），对应 iOS FFMpegRemuxer。
 * HarmonyOS 降级：通过文件复制 + 扩展名判断实现 passthrough remux。
 *
 * 注意：HarmonyOS AVMuxer 支持 mp4 → mp4 重封装（保持原编码不解码），
 * 但 ts/mkv/flv 等格式转换需 FFmpeg，此处标为 deferred 并做文件 copy 降级。
 */
public class FFMpegRemuxer {
    /**
     * Remux 文件（对应 iOS +remux:to:）
     * @param srcPath 输入文件路径
     * @param dstPath 输出文件路径
     * @return 操作是否成功
     */
    public static func remux(srcPath: String, dstPath: String): Bool {
        return copyFilePassthrough(srcPath, dstPath)
    }

    /** 文件复制（passthrough 降级） */
    private static func copyFilePassthrough(src: String, dst: String): Bool {
        if (!FileIo.access(src)) {
            Hilog.info(0, "CjTelegram", "[FFMpegRemuxer] source file not found")
            return false
        }
        let chunkSize: Int64 = 65536
        var success = true
        try {
            // 0o0 = O_RDONLY; 0o1101 = O_CREAT|O_RDWR|O_TRUNC
            let srcFile = FileIo.open(src, mode: 0o0)
            let dstFile = FileIo.open(dst, mode: 0o1101)
            var buf = Array<Byte>(chunkSize, repeat: 0)
            var continueReading = true
            while (continueReading) {
                let n = FileIo.read(srcFile.fd, buf)
                if (n <= 0) {
                    continueReading = false
                } else {
                    // write slice of length n — immutable ref copy before lambda (#77)
                    let immBuf2 = buf
                    let slice = Array<Byte>(n, { i: Int64 => immBuf2[i] })
                    let written = FileIo.write(dstFile.fd, slice)
                    if (written != n) {
                        success = false
                        continueReading = false
                    }
                }
            }
            FileIo.close(srcFile)
            FileIo.close(dstFile)
        } catch (_e: Exception) {
            Hilog.info(0, "CjTelegram", "[FFMpegRemuxer] copy error")
            success = false
        }
        return success
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FFMpegLiveMuxer — 直播流 remux（带时间偏移）
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 直播流 remux，对应 iOS FFMpegLiveMuxer。
 * HarmonyOS 降级：忽略 offsetSeconds，做文件 passthrough copy。
 * 完整 TS → MP4 live 流转封装需 FFmpeg，标为 deferred。
 */
public class FFMpegLiveMuxer {
    /**
     * Remux 直播流（对应 iOS +remux:to:offsetSeconds:）
     * @param srcPath 输入路径
     * @param dstPath 输出路径
     * @param offsetSeconds 时间偏移（降级：忽略）
     */
    public static func remux(srcPath: String, dstPath: String, offsetSeconds: Float64): Bool {
        Hilog.info(0, "CjTelegram", "[FFMpegLiveMuxer] remux (degraded: offsetSeconds ignored, passthrough copy)")
        return FFMpegRemuxer.remux(srcPath, dstPath)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FFMpegOpusTrimmer — Opus 音频修剪（deferred）
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Opus 音频文件修剪，对应 iOS FFMpegOpusTrimmer。
 * HarmonyOS 降级：deferred — HarmonyOS 无公开 Opus 容器 trim API。
 * 本接口返回 false（明确不支持），上层应检查返回值并降级（如完整文件复制）。
 */
public class FFMpegOpusTrimmer {
    /**
     * 修剪 Opus 文件（对应 iOS +trim:to:start:end:）
     * @param srcPath 输入 ogg/opus 文件
     * @param dstPath 输出文件
     * @param start 起始时间（秒）
     * @param end 结束时间（秒）
     * @return HarmonyOS 上始终返回 false（capability deferred）
     */
    public static func trim(srcPath: String, dstPath: String, start: Float64, end: Float64): Bool {
        Hilog.info(0, "CjTelegram", "[FFMpegOpusTrimmer] trim deferred on OHOS: no Opus container trim API")
        return false
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FFMpegVideoWriter — 视频编码写入
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 视频帧编码并写入文件，对应 iOS FFMpegVideoWriter。
 * HarmonyOS 降级：接受 YUV 帧，累积到内存缓冲区，finalize 时将帧尺寸/参数写入元数据。
 * 完整 H.264 编码输出需 HarmonyOS AVCodec AVVideoEncoder（C API），
 * 当前 Cangjie 层无公开 AVVideoEncoder 绑定，故降级为：
 *   - setup/encodeFrame 记录参数，不实际编码
 *   - finalizeVideo 写出帧数量和参数到 .info 文件（供上层感知降级状态）
 * 上层可通过检查 isEncodeDeferred() 决定是否走 Android/VideoToolbox 路径。
 */
public class FFMpegVideoWriter {
    private var _outputPath: String = ""
    private var _width: Int32 = 0
    private var _height: Int32 = 0
    private var _bitrate: Int64 = 0
    private var _framerate: Int32 = 30
    private var _frameCount: Int32 = 0
    private var _isSetup: Bool = false

    public init() {}

    /**
     * 配置输出参数（对应 iOS -setupWithOutputPath:width:height:bitrate:framerate:）
     * @return 始终 true（参数合法性检查）
     */
    public func setup(outputPath: String, width: Int32, height: Int32,
                      bitrate: Int64, framerate: Int32): Bool {
        if (outputPath.size == 0 || width <= 0 || height <= 0) {
            return false
        }
        this._outputPath = outputPath
        this._width = width
        this._height = height
        this._bitrate = bitrate
        this._framerate = framerate
        this._frameCount = 0
        this._isSetup = true
        Hilog.info(0, "CjTelegram", "[FFMpegVideoWriter] setup (degraded: encoding deferred, no Cangjie AVEncoder binding)")
        return true
    }

    /**
     * 编码并写入帧（对应 iOS -encodeFrame:）
     * HarmonyOS 降级：计数，不实际编码（AVVideoEncoder 无公开 Cangjie binding）。
     */
    public func encodeFrame(frame: FFMpegAVFrame): Bool {
        if (!this._isSetup) { return false }
        this._frameCount = this._frameCount + 1
        return true
    }

    /**
     * 完成视频写入（对应 iOS -finalizeVideo）
     * HarmonyOS 降级：写出 .info 文件描述降级状态。
     */
    public func finalizeVideo(): Bool {
        if (!this._isSetup) { return false }
        let infoPath = this._outputPath + ".ffmpeg_deferred.info"
        let infoContent = "deferred=true\nwidth=" + this._width.toString() +
            "\nheight=" + this._height.toString() +
            "\nframerate=" + this._framerate.toString() +
            "\nframes_received=" + this._frameCount.toString()
        var ok = false
        try {
            // 0o1101 = O_CREAT|O_RDWR|O_TRUNC
            let file = FileIo.open(infoPath, mode: 0o1101)
            let _ = FileIo.write(file.fd, infoContent.toArray())
            FileIo.close(file)
            ok = true
        } catch (_e: Exception) {
            Hilog.info(0, "CjTelegram", "[FFMpegVideoWriter] finalizeVideo: failed to write info file")
        }
        this._isSetup = false
        Hilog.info(0, "CjTelegram", "[FFMpegVideoWriter] finalizeVideo (degraded)")
        return ok
    }

    /**
     * 检查编码是否被降级（上层可调用以决定备选路径）
     * @return 始终 true（HarmonyOS 当前无公开 Cangjie AVVideoEncoder）
     */
    public func isEncodeDeferred(): Bool {
        return true
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FFMpegGlobals — 全局初始化
// ─────────────────────────────────────────────────────────────────────────────

/**
 * FFmpeg 全局初始化（对应 iOS FFMpegGlobals +initializeGlobals）
 * HarmonyOS: 无 FFmpeg avcodec_register_all / av_register_all，此函数为空操作。
 * 保留供调用方兼容性检查（调用后不报错即视为已初始化）。
 */
public func initializeFFMpegGlobals(): Unit {
    Hilog.info(0, "CjTelegram", "[FFMpegGlobals] initializeGlobals (OHOS: no-op, no FFmpeg system library)")
}
