package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog

/**
 * Telegram 压缩动画格式解析器（P2-240 薄真层，真做）
 *
 * 对应 iOS AnimationCompressor.SharedContext.compress(...) 的输出格式
 * 及 CompressedImageRenderer 的解析输入格式：
 *
 * 文件格式（小端字节序，Int32 = 4 字节）:
 *   [0x543ee445] magic         (4 bytes, LE)
 *   [planeCount] always 4      (4 bytes, LE) — YUVA 4 planes
 *   [width]      frame width   (4 bytes, LE)
 *   [height]     frame height  (4 bytes, LE)
 *   Per-plane (4 planes: Y, U, V, A):
 *     [planeWidth]       (4 bytes, LE)
 *     [planeHeight]      (4 bytes, LE)
 *     [bytesPerRow]      (4 bytes, LE)
 *     [huffmanDataSize]  (4 bytes, LE)
 *     [huffmanData]      (huffmanDataSize bytes) — DCT 系数 Huffman 编码流
 *
 * 薄真层（真做）:
 *   - magic 字节验证（真检查，不假设）
 *   - 格式头字段解析（width / height / planeCount / per-plane 元信息）
 *   - per-plane Huffman 数据区的字节范围定位（提取供上层使用）
 *   - WriteBuffer / ReadBuffer：纯 Cangjie 字节序列化框架（小端 Int32 读写）
 *
 * deferred（P2-240 重平台算法，GPU 依赖）:
 *   - GPU Metal DCT compute-shader（鸿蒙无 Metal API，KB 查询 "Metal GPU compute shader DCT HarmonyOS"
 *     最高分 0.016 无命中）
 *   - Huffman DCT 系数解码（writeDCTBlocks / readDCTBlocks 为 C++ DctHuffman 库，iOS 专属）
 *   - IDCT 逆变换 + YUVA 平面合成渲染（依赖 GPU compute shader 性能，CPU 全帧 IDCT 不可行）
 *
 * KB 查询记录（已查询，均无 HarmonyOS Cangjie 等价 API 命中）:
 *   - "Metal GPU compute shader DCT HarmonyOS" → score 0.016，无命中
 */

// ---- 格式常量 ----

/** Telegram 压缩动画格式魔术字节（0x543ee445，小端 Int32） */
public let ANIMATION_COMPRESSION_MAGIC: Int32 = 0x543ee445

/** 格式头固定长度（magic + planeCount + width + height = 4 * 4 = 16 字节） */
public let ANIMATION_COMPRESSION_HEADER_SIZE: Int64 = 16

/** YUVA 平面数量（固定为 4） */
public let ANIMATION_COMPRESSION_PLANE_COUNT: Int32 = 4

/** per-plane 元信息固定长度（planeWidth + planeHeight + bytesPerRow + huffmanDataSize = 4 * 4 = 16 字节） */
public let ANIMATION_COMPRESSION_PLANE_META_SIZE: Int64 = 16

// ---- 数据模型 ----

/**
 * 单个 YUVA 平面元信息
 */
public class AnimationPlaneInfo {
    public var planeWidth: Int32 = 0
    public var planeHeight: Int32 = 0
    public var bytesPerRow: Int32 = 0
    public var huffmanDataOffset: Int64 = 0
    public var huffmanDataSize: Int32 = 0

    public init() {}
}

/**
 * 解析后的压缩动画帧头
 */
public class AnimationFrameHeader {
    public var magic: Int32 = 0
    public var planeCount: Int32 = 0
    public var width: Int32 = 0
    public var height: Int32 = 0
    public var planes: Array<AnimationPlaneInfo> = Array<AnimationPlaneInfo>(0, repeat: AnimationPlaneInfo())

    public init() {}
}

/**
 * 格式解析结果
 */
public enum AnimationParseStatus {
    | Success
    | InvalidMagic
    | TooShort
    | MalformedHeader
}

public class AnimationParseResult {
    public var status: AnimationParseStatus = AnimationParseStatus.TooShort
    public var header: Option<AnimationFrameHeader> = None
    public var errorMessage: String = ""

    public init() {}
}

// ---- 格式解析器 ----

/**
 * Telegram 压缩动画格式解析器
 *
 * 职责：验证 magic、解析头部字段、定位 per-plane Huffman 数据区偏移。
 * 不包含 DCT/Huffman 解码（deferred，需 GPU compute-shader）。
 */
public class AnimationCompressionParser {

    public init() {}

    /**
     * 解析压缩动画字节数组头部
     *
     * @param data 压缩动画数据（来自 iOS AnimationCompressor 输出或同格式数据）
     * @return AnimationParseResult，成功时 header 包含帧尺寸和 per-plane 元信息
     */
    public func parseHeader(data: Array<UInt8>): AnimationParseResult {
        let result = AnimationParseResult()

        if (Int64(data.size) < ANIMATION_COMPRESSION_HEADER_SIZE) {
            result.status = AnimationParseStatus.TooShort
            result.errorMessage = "Data too short: ${data.size} bytes"
            Hilog.info(0, "CjTelegram", "[AnimationParser] Too short: ${data.size}")
            return result
        }

        let magic = readInt32LE(data, 0)
        if (magic != ANIMATION_COMPRESSION_MAGIC) {
            result.status = AnimationParseStatus.InvalidMagic
            result.errorMessage = "Invalid magic: got ${magic}"
            Hilog.info(0, "CjTelegram", "[AnimationParser] Invalid magic")
            return result
        }

        let planeCount = readInt32LE(data, 4)
        let width = readInt32LE(data, 8)
        let height = readInt32LE(data, 12)

        if (planeCount <= 0 || width <= 0 || height <= 0 || planeCount > 8) {
            result.status = AnimationParseStatus.MalformedHeader
            result.errorMessage = "Malformed header: planeCount=${planeCount} w=${width} h=${height}"
            Hilog.info(0, "CjTelegram", "[AnimationParser] Malformed header")
            return result
        }

        let header = AnimationFrameHeader()
        header.magic = magic
        header.planeCount = planeCount
        header.width = width
        header.height = height

        var planes = Array<AnimationPlaneInfo>(Int64(planeCount), repeat: AnimationPlaneInfo())
        var byteOffset: Int64 = ANIMATION_COMPRESSION_HEADER_SIZE

        var i: Int32 = 0
        while (i < planeCount) {
            if (byteOffset + ANIMATION_COMPRESSION_PLANE_META_SIZE > Int64(data.size)) {
                result.status = AnimationParseStatus.TooShort
                result.errorMessage = "Data truncated at plane ${i} meta"
                return result
            }

            let planeInfo = AnimationPlaneInfo()
            planeInfo.planeWidth = readInt32LE(data, byteOffset)
            planeInfo.planeHeight = readInt32LE(data, byteOffset + 4)
            planeInfo.bytesPerRow = readInt32LE(data, byteOffset + 8)
            planeInfo.huffmanDataSize = readInt32LE(data, byteOffset + 12)
            byteOffset = byteOffset + ANIMATION_COMPRESSION_PLANE_META_SIZE

            if (planeInfo.huffmanDataSize < 0) {
                result.status = AnimationParseStatus.MalformedHeader
                result.errorMessage = "Negative huffmanDataSize at plane ${i}"
                return result
            }

            planeInfo.huffmanDataOffset = byteOffset
            byteOffset = byteOffset + Int64(planeInfo.huffmanDataSize)

            if (byteOffset > Int64(data.size)) {
                result.status = AnimationParseStatus.TooShort
                result.errorMessage = "Data truncated in Huffman data at plane ${i}"
                return result
            }

            planes[Int64(i)] = planeInfo
            i += 1
        }

        header.planes = planes
        result.status = AnimationParseStatus.Success
        result.header = Some(header)
        Hilog.info(0, "CjTelegram", "[AnimationParser] Parsed header: ${width}x${height} planes=${planeCount}")
        return result
    }

    /**
     * 提取指定平面的 Huffman 压缩数据切片
     *
     * @param data  完整压缩动画字节数组
     * @param plane 要提取的平面元信息（由 parseHeader 返回）
     * @return 该平面的 Huffman 编码字节数组（空数组表示失败）
     *
     * deferred: 取出的 Huffman 字节需要 readDCTBlocks (C++ DctHuffman 库) 解码 → GPU IDCT 渲染
     */
    public func extractPlaneHuffmanData(data: Array<UInt8>, plane: AnimationPlaneInfo): Array<UInt8> {
        let start = plane.huffmanDataOffset
        let size = Int64(plane.huffmanDataSize)
        if (start < 0 || size <= 0 || start + size > Int64(data.size)) {
            return Array<UInt8>(0, repeat: 0)
        }
        let result = Array<UInt8>(size, { idx => data[Int64(start) + idx] })
        return result
    }

    /**
     * 验证字节数组是否为有效的 Telegram 压缩动画格式
     */
    public func isValidAnimationData(data: Array<UInt8>): Bool {
        if (Int64(data.size) < 4) { return false }
        let magic = readInt32LE(data, 0)
        return magic == ANIMATION_COMPRESSION_MAGIC
    }

    // ---- 私有辅助：字节序列化 ----

    /**
     * 从字节数组按小端字节序读取 Int32（对应 iOS WriteBuffer.writeInt32）
     */
    private func readInt32LE(data: Array<UInt8>, offset: Int64): Int32 {
        if (offset + 4 > Int64(data.size)) { return 0 }
        let b0 = Int32(data[offset])
        let b1 = Int32(data[offset + 1]) << 8
        let b2 = Int32(data[offset + 2]) << 16
        let b3 = Int32(data[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }
}

// ---- WriteBuffer：纯 Cangjie 字节序列化框架（P2-240 真做）----

/**
 * WriteBuffer — 对应 iOS Buffer.swift WriteBuffer
 *
 * 提供小端字节序的 Int32 写入，用于构造压缩动画容器格式头。
 * 真做：纯 Cangjie 实现，无平台依赖。
 *
 * 典型用法（构造 Telegram 压缩动画格式头）:
 *   let buf = AnimationWriteBuffer()
 *   buf.writeInt32(value: ANIMATION_COMPRESSION_MAGIC)
 *   buf.writeInt32(value: 4)           // planeCount
 *   buf.writeInt32(value: width)
 *   buf.writeInt32(value: height)
 *   // ... per-plane 元信息 ...
 *   let bytes = buf.makeData()
 */
public class AnimationWriteBuffer {
    private var buffer: Array<UInt8> = Array<UInt8>(0, repeat: 0)
    private var writeOffset: Int64 = 0

    public init() {}

    /**
     * 当前已写入字节数
     */
    public func length(): Int64 {
        return writeOffset
    }

    /**
     * 写入 Int32（小端字节序，对应 iOS WriteBuffer.writeInt32）
     */
    public func writeInt32(value: Int32): Unit {
        ensureCapacity(4)
        buffer[writeOffset] = UInt8(value & 0xFF)
        buffer[writeOffset + 1] = UInt8((value >> 8) & 0xFF)
        buffer[writeOffset + 2] = UInt8((value >> 16) & 0xFF)
        buffer[writeOffset + 3] = UInt8((value >> 24) & 0xFF)
        writeOffset = writeOffset + 4
    }

    /**
     * 写入字节数组
     */
    public func writeBytes(bytes: Array<UInt8>): Unit {
        let count = Int64(bytes.size)
        if (count <= 0) { return }
        ensureCapacity(count)
        var i: Int64 = 0
        while (i < count) {
            buffer[writeOffset + i] = bytes[i]
            i += 1
        }
        writeOffset = writeOffset + count
    }

    /**
     * 写入单个字节
     */
    public func writeByte(b: UInt8): Unit {
        ensureCapacity(1)
        buffer[writeOffset] = b
        writeOffset = writeOffset + 1
    }

    /**
     * 返回已写入数据的副本（对应 iOS WriteBuffer.makeData()）
     */
    public func makeData(): Array<UInt8> {
        let len = writeOffset
        let result = Array<UInt8>(len, { i => buffer[i] })
        return result
    }

    /**
     * 重置写入位置（对应 iOS WriteBuffer.reset()）
     */
    public func reset(): Unit {
        writeOffset = 0
    }

    private func ensureCapacity(needed: Int64): Unit {
        let required = writeOffset + needed
        if (required > Int64(buffer.size)) {
            let newSize = required + 256
            let newBuf = Array<UInt8>(newSize, repeat: 0)
            var i: Int64 = 0
            while (i < Int64(buffer.size)) {
                newBuf[i] = buffer[i]
                i += 1
            }
            buffer = newBuf
        }
    }
}

// ---- ReadBuffer：对应 iOS ReadBuffer ----

/**
 * ReadBuffer — 对应 iOS Buffer.swift ReadBuffer
 *
 * 提供小端字节序的 Int32 读取。
 * 真做：纯 Cangjie 实现，无平台依赖。
 */
public class AnimationReadBuffer {
    private var data: Array<UInt8>
    private var readOffset: Int64 = 0

    public init(data: Array<UInt8>) {
        this.data = data
    }

    public func currentOffset(): Int64 {
        return readOffset
    }

    public func remaining(): Int64 {
        return Int64(data.size) - readOffset
    }

    /**
     * 读取 Int32（小端字节序，对应 iOS ReadBuffer.readInt32）
     */
    public func readInt32(): Int32 {
        if (readOffset + 4 > Int64(data.size)) { return 0 }
        let b0 = Int32(data[readOffset])
        let b1 = Int32(data[readOffset + 1]) << 8
        let b2 = Int32(data[readOffset + 2]) << 16
        let b3 = Int32(data[readOffset + 3]) << 24
        readOffset = readOffset + 4
        return b0 | b1 | b2 | b3
    }

    /**
     * 读取指定长度字节数组
     */
    public func readBytes(length: Int64): Array<UInt8> {
        if (length <= 0 || readOffset + length > Int64(data.size)) {
            return Array<UInt8>(0, repeat: 0)
        }
        let result = Array<UInt8>(length, { i => data[readOffset + i] })
        readOffset = readOffset + length
        return result
    }

    /**
     * 跳过指定字节数（对应 iOS ReadBuffer.skip）
     */
    public func skip(length: Int64): Unit {
        readOffset = readOffset + length
        if (readOffset > Int64(data.size)) {
            readOffset = Int64(data.size)
        }
    }

    /**
     * 重置读取位置（对应 iOS ReadBuffer.reset）
     */
    public func reset(): Unit {
        readOffset = 0
    }
}

// ---- 单例访问器 ----

private var _animationCompressionParserInstance: Option<AnimationCompressionParser> = None

public func getAnimationCompressionParser(): AnimationCompressionParser {
    match (_animationCompressionParserInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = AnimationCompressionParser()
            _animationCompressionParserInstance = Some(inst)
            return inst
    }
}
