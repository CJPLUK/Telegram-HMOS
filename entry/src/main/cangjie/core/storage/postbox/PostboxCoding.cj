package ohos_app_cangjie_entry.core.storage.postbox

import ohos_app_cangjie_entry.core.mtproto.ByteUtils

/**
 * Postbox 二进制编解码层 —— PostboxEncoder / PostboxDecoder（等价物）。
 *
 * iOS 标尺：Telegram-iOS/submodules/Postbox/Sources/Coding.swift。
 * 这是 Postbox 持久化 DB 的"字段级"序列化格式（区别于 MTProto 的 TL 线格式）：
 * 每个字段在缓冲里布局为
 *
 *     [keyLen:1][keyUtf8Bytes...][valueType:1][value...]
 *
 * 多个字段顺序排布，按 key 字符串线性扫描定位（positionOnKey）。
 *
 * 字节序约定（与 iOS 一致）：iOS `buffer.write(&v, length: 4)` 直接拷贝原生内存，
 * 在 ARM 上即小端序；本实现统一用 ByteUtils 的小端序读写。
 *
 * 范围：本单元只做标量 + Bytes 核心类型
 *   Int32 / Int64 / Bool / Double / String / Bytes / Nil。
 * 容器类型（Object / Int32Array / Int64Array / ObjectArray / ObjectDictionary /
 * StringArray / BytesArray）由后续单元扩展 —— 这里只把它们的字节标签保留在
 * ValueType 中，并让 skipValue 能跳过未知/未实现类型时安全失败，方便后续接续。
 */

/**
 * 值类型字节标签（对应 iOS enum ValueType: Int8）。
 * 数值必须与 iOS 完全一致，否则跨端/历史数据无法互读。
 */
public class ValueType {
    public static let INT32: Byte = 0
    public static let INT64: Byte = 1
    public static let BOOL: Byte = 2
    public static let DOUBLE: Byte = 3
    public static let STRING: Byte = 4
    public static let OBJECT: Byte = 5
    public static let INT32_ARRAY: Byte = 6
    public static let INT64_ARRAY: Byte = 7
    public static let OBJECT_ARRAY: Byte = 8
    public static let OBJECT_DICTIONARY: Byte = 9
    public static let BYTES: Byte = 10
    public static let NIL: Byte = 11
    public static let STRING_ARRAY: Byte = 12
    public static let BYTES_ARRAY: Byte = 13
}

/**
 * 编解码异常 —— 字段缺失/类型不符/格式损坏时抛出。
 */
public class PostboxCodingException <: Exception {
    public init(message: String) {
        super(message)
    }
}

/**
 * PostboxEncoder —— 按 key 把标量/Bytes 编码进字节缓冲。
 *
 * 对应 iOS PostboxEncoder：encodeKey 写 [len:1][utf8]，随后写 [valueType:1] 再写 value。
 */
public class PostboxEncoder {
    private let buffer: WriteBuffer

    public init() {
        this.buffer = WriteBuffer()
    }

    /**
     * 写 key 头：1 字节长度 + UTF-8 字节（对应 iOS encodeKey）。
     * iOS 用 Int8 存 key 长度，故 key 的 UTF-8 字节数不能超过 127。
     */
    private func encodeKey(key: String): Unit {
        let keyBytes = key.toArray()
        if (keyBytes.size > 127) {
            throw PostboxCodingException("Postbox key too long (>127 utf8 bytes): ${key}")
        }
        this.buffer.writeByte(UInt8(keyBytes.size))
        this.buffer.writeBytes(keyBytes)
    }

    /**
     * 显式 nil 标记（对应 iOS encodeNil(forKey:)）。
     */
    public func encodeNil(key!: String): Unit {
        encodeKey(key)
        this.buffer.writeByte(ValueType.NIL)
    }

    public func encodeInt32(value: Int32, key!: String): Unit {
        encodeKey(key)
        this.buffer.writeByte(ValueType.INT32)
        this.buffer.writeBytes(ByteUtils.int32ToBytes(value))
    }

    public func encodeInt64(value: Int64, key!: String): Unit {
        encodeKey(key)
        this.buffer.writeByte(ValueType.INT64)
        this.buffer.writeBytes(ByteUtils.int64ToBytes(value))
    }

    public func encodeBool(value: Bool, key!: String): Unit {
        encodeKey(key)
        this.buffer.writeByte(ValueType.BOOL)
        let v: Byte = if (value) { 1 } else { 0 }
        this.buffer.writeByte(v)
    }

    public func encodeDouble(value: Float64, key!: String): Unit {
        encodeKey(key)
        this.buffer.writeByte(ValueType.DOUBLE)
        // 写 IEEE 754 位模式（小端序），与 iOS `write(&v, length: 8)` 一致
        this.buffer.writeBytes(ByteUtils.int64ToBytes(ByteUtils.float64ToBits(value)))
    }

    /**
     * 字符串：[type][len:Int32][utf8 bytes]（对应 iOS encodeString）。
     */
    public func encodeString(value: String, key!: String): Unit {
        encodeKey(key)
        this.buffer.writeByte(ValueType.STRING)
        let utf8 = value.toArray()
        this.buffer.writeBytes(ByteUtils.int32ToBytes(Int32(utf8.size)))
        this.buffer.writeBytes(utf8)
    }

    /**
     * 原始字节：[type][len:Int32][raw bytes]（对应 iOS encodeBytes/encodeData）。
     */
    public func encodeBytes(value: Array<Byte>, key!: String): Unit {
        encodeKey(key)
        this.buffer.writeByte(ValueType.BYTES)
        this.buffer.writeBytes(ByteUtils.int32ToBytes(Int32(value.size)))
        this.buffer.writeBytes(value)
    }

    /**
     * 已编码的完整字节流。
     */
    public func makeBytes(): Array<Byte> {
        return this.buffer.makeBytes()
    }

    /**
     * 构造一个对称的 PostboxDecoder。
     */
    public func makeDecoder(): PostboxDecoder {
        return PostboxDecoder(makeBytes())
    }
}

/**
 * PostboxDecoder —— 按 key 线性扫描定位字段并对称解码。
 *
 * 对应 iOS PostboxDecoder + positionOnKey + skipValue。
 * 扫描算法（positionOnKey）：从当前 offset 起逐字段读 [keyLen][key][valueType]，
 * key 匹配则定位成功；不匹配则 skipValue 跳过该字段的值继续。
 * iOS 实现支持从中途 offset 回绕到 0 再扫到起点（环形扫描）以加速相邻字段访问；
 * 本实现保留这一行为。
 */
public class PostboxDecoder {
    private let buffer: ReadBuffer

    public init(data: Array<Byte>) {
        this.buffer = ReadBuffer(data)
    }

    /**
     * 跳过一个值（不含已读掉的 key 头与 valueType 字节）。
     * 返回 false 表示遇到本单元尚未实现的容器类型 —— 调用方据此判定无法继续扫描。
     *
     * 对应 iOS skipValue。容器类型留待后续单元实现，这里遇到即安全失败。
     */
    private func skipValue(valueType: Byte): Bool {
        if (valueType == ValueType.INT32) {
            this.buffer.skip(4)
            return true
        } else if (valueType == ValueType.INT64) {
            this.buffer.skip(8)
            return true
        } else if (valueType == ValueType.BOOL) {
            this.buffer.skip(1)
            return true
        } else if (valueType == ValueType.DOUBLE) {
            this.buffer.skip(8)
            return true
        } else if (valueType == ValueType.STRING || valueType == ValueType.BYTES) {
            let length = Int64(ByteUtils.bytesToInt32(this.buffer.readBytes(4)))
            this.buffer.skip(length)
            return true
        } else if (valueType == ValueType.NIL) {
            return true
        } else {
            // 容器类型（Object/数组/字典等）由后续单元扩展。
            // 当前无法计算其长度，无法安全跳过 —— 返回 false 让扫描终止。
            return false
        }
    }

    /**
     * 定位到指定 key、且 valueType 匹配的字段，定位后读指针停在"值"的起点。
     * 返回 false 表示未找到（或类型不符/为 Nil）。
     *
     * 对应 iOS positionOnKey(key:valueType:)，含环形回绕扫描。
     */
    private func positionOnKey(key: String, expectedType: Byte): Bool {
        let keyBytes = key.toArray()
        let keyLength = keyBytes.size
        let startOffset = this.buffer.position()
        let maxOffset = this.buffer.length()

        if (scanRange(keyBytes, keyLength, expectedType, this.buffer.position(), maxOffset)) {
            return true
        }
        // 环形回绕：从 0 再扫到起点（对应 iOS startOffset != 0 分支）
        if (startOffset != 0) {
            this.buffer.setPosition(0)
            return scanRange(keyBytes, keyLength, expectedType, 0, startOffset)
        }
        return false
    }

    /**
     * 在 [from, limit) 范围内线性扫描定位 key。读指针在调用时应已位于 from。
     */
    private func scanRange(keyBytes: Array<Byte>, keyLength: Int64, expectedType: Byte, from: Int64,
        limit: Int64): Bool {
        while (this.buffer.position() < limit) {
            let readKeyLength = Int64(this.buffer.readByte())
            // 读 key 字节
            let candidate = this.buffer.readBytes(readKeyLength)
            let readValueType = this.buffer.readByte()

            if (readKeyLength == keyLength && bytesEqual(candidate, keyBytes)) {
                if (readValueType == expectedType) {
                    return true
                } else if (readValueType == ValueType.NIL) {
                    return false
                } else {
                    // key 命中但类型不符：跳过该值继续找（iOS 同样行为）
                    if (!skipValue(readValueType)) {
                        return false
                    }
                }
            } else {
                if (!skipValue(readValueType)) {
                    return false
                }
            }
        }
        return false
    }

    private func bytesEqual(a: Array<Byte>, b: Array<Byte>): Bool {
        if (a.size != b.size) {
            return false
        }
        for (i in 0..a.size) {
            if (a[i] != b[i]) {
                return false
            }
        }
        return true
    }

    /**
     * key 是否存在 Nil 标记（对应 iOS decodeNilForKey）。
     */
    public func decodeNil(key: String): Bool {
        return positionOnKey(key, ValueType.NIL)
    }

    public func decodeInt32(key: String, orElse!: Int32): Int32 {
        if (positionOnKey(key, ValueType.INT32)) {
            return ByteUtils.bytesToInt32(this.buffer.readBytes(4))
        }
        return orElse
    }

    public func decodeOptionalInt32(key: String): Option<Int32> {
        if (positionOnKey(key, ValueType.INT32)) {
            return Some(ByteUtils.bytesToInt32(this.buffer.readBytes(4)))
        }
        return None
    }

    public func decodeInt64(key: String, orElse!: Int64): Int64 {
        if (positionOnKey(key, ValueType.INT64)) {
            return ByteUtils.bytesToInt64(this.buffer.readBytes(8))
        }
        return orElse
    }

    public func decodeOptionalInt64(key: String): Option<Int64> {
        if (positionOnKey(key, ValueType.INT64)) {
            return Some(ByteUtils.bytesToInt64(this.buffer.readBytes(8)))
        }
        return None
    }

    public func decodeBool(key: String, orElse!: Bool): Bool {
        if (positionOnKey(key, ValueType.BOOL)) {
            return this.buffer.readByte() != 0
        }
        return orElse
    }

    public func decodeOptionalBool(key: String): Option<Bool> {
        if (positionOnKey(key, ValueType.BOOL)) {
            return Some(this.buffer.readByte() != 0)
        }
        return None
    }

    public func decodeDouble(key: String, orElse!: Float64): Float64 {
        if (positionOnKey(key, ValueType.DOUBLE)) {
            return ByteUtils.bitsToFloat64(ByteUtils.bytesToInt64(this.buffer.readBytes(8)))
        }
        return orElse
    }

    public func decodeOptionalDouble(key: String): Option<Float64> {
        if (positionOnKey(key, ValueType.DOUBLE)) {
            return Some(ByteUtils.bitsToFloat64(ByteUtils.bytesToInt64(this.buffer.readBytes(8))))
        }
        return None
    }

    public func decodeString(key: String, orElse!: String): String {
        if (positionOnKey(key, ValueType.STRING)) {
            let length = Int64(ByteUtils.bytesToInt32(this.buffer.readBytes(4)))
            return String.fromUtf8(this.buffer.readBytes(length))
        }
        return orElse
    }

    public func decodeOptionalString(key: String): Option<String> {
        if (positionOnKey(key, ValueType.STRING)) {
            let length = Int64(ByteUtils.bytesToInt32(this.buffer.readBytes(4)))
            return Some(String.fromUtf8(this.buffer.readBytes(length)))
        }
        return None
    }

    public func decodeBytes(key: String, orElse!: Array<Byte>): Array<Byte> {
        if (positionOnKey(key, ValueType.BYTES)) {
            let length = Int64(ByteUtils.bytesToInt32(this.buffer.readBytes(4)))
            return this.buffer.readBytes(length)
        }
        return orElse
    }

    public func decodeOptionalBytes(key: String): Option<Array<Byte>> {
        if (positionOnKey(key, ValueType.BYTES)) {
            let length = Int64(ByteUtils.bytesToInt32(this.buffer.readBytes(4)))
            return Some(this.buffer.readBytes(length))
        }
        return None
    }
}

/**
 * 往返一致性自检 —— 对每个标量/Bytes 类型，encode 后 decode 必须得回原值。
 *
 * 这是本单元的验收项②：结构上保证编解码对称。返回 true 表示全部往返一致。
 * 出现任何不一致即抛 PostboxCodingException，便于编译期外的运行验证捕获回归。
 */
public func roundTripSelfCheck(): Bool {
    let encoder = PostboxEncoder()
    encoder.encodeInt32(-12345, key: "i32")
    encoder.encodeInt64(9000000000000000000, key: "i64")
    encoder.encodeBool(true, key: "bt")
    encoder.encodeBool(false, key: "bf")
    encoder.encodeDouble(3.141592653589793, key: "dbl")
    encoder.encodeString("héllo-世界", key: "str")
    encoder.encodeBytes([0u8, 255u8, 1u8, 128u8, 7u8], key: "raw")
    encoder.encodeNil(key: "nul")

    let decoder = encoder.makeDecoder()

    // 注意：故意打乱解码顺序，验证按 key 定位（含环形扫描）而非顺序依赖
    if (decoder.decodeString("str", orElse: "") != "héllo-世界") {
        throw PostboxCodingException("roundTrip failed: String")
    }
    if (decoder.decodeInt32("i32", orElse: 0) != -12345) {
        throw PostboxCodingException("roundTrip failed: Int32")
    }
    if (decoder.decodeBool("bf", orElse: true) != false) {
        throw PostboxCodingException("roundTrip failed: Bool(false)")
    }
    if (decoder.decodeInt64("i64", orElse: 0) != 9000000000000000000) {
        throw PostboxCodingException("roundTrip failed: Int64")
    }
    if (decoder.decodeBool("bt", orElse: false) != true) {
        throw PostboxCodingException("roundTrip failed: Bool(true)")
    }
    let d = decoder.decodeDouble("dbl", orElse: 0.0)
    if (d != 3.141592653589793) {
        throw PostboxCodingException("roundTrip failed: Double got ${d}")
    }
    let raw = decoder.decodeBytes("raw", orElse: Array<Byte>(0, repeat: 0))
    if (raw.size != 5 || raw[0] != 0 || raw[1] != 255 || raw[3] != 128) {
        throw PostboxCodingException("roundTrip failed: Bytes")
    }
    if (!decoder.decodeNil("nul")) {
        throw PostboxCodingException("roundTrip failed: Nil")
    }

    // 缺失 key 应回落到 orElse
    if (decoder.decodeInt32("missing", orElse: 777) != 777) {
        throw PostboxCodingException("roundTrip failed: missing-key fallback")
    }
    // Optional 形式：存在 -> Some，缺失 -> None
    match (decoder.decodeOptionalInt64("i64")) {
        case Some(v) => if (v != 9000000000000000000) {
            throw PostboxCodingException("roundTrip failed: optional Int64 value")
        }
        case None => throw PostboxCodingException("roundTrip failed: optional Int64 None")
    }
    match (decoder.decodeOptionalString("missing")) {
        case Some(_) => throw PostboxCodingException("roundTrip failed: optional missing should be None")
        case None => ()
    }

    return true
}
