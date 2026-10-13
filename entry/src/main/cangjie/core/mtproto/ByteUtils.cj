package ohos_app_cangjie_entry.core.mtproto

import std.collection.ArrayList
import std.random.Random

/**
 * 字节工具类 — MTProto 协议的基础字节操作
 * 
 * 对应 TelegramHarmony 的 CryptoUtils.ets ByteUtils 类
 * 使用 Cangjie 的 Array<Byte> 作为字节数组类型
 */
public class ByteUtils {
    private static let _rand = Random()

    /**
     * 创建随机字节数组
     */
    public static func randomBytes(length: Int64): Array<Byte> {
        let result = Array<Byte>(length, repeat: 0)
        for (i in 0..length) {
            result[i] = UInt8(_rand.nextUInt32() % 256)
        }
        return result
    }

    /**
     * 连接多个字节数组
     */
    public static func concat(arrays: ArrayList<Array<Byte>>): Array<Byte> {
        var totalLength: Int64 = 0
        for (arr in arrays) {
            totalLength += arr.size
        }

        let result = Array<Byte>(totalLength, repeat: 0)
        var offset: Int64 = 0
        for (arr in arrays) {
            for (i in 0..arr.size) {
                result[offset + i] = arr[i]
            }
            offset += arr.size
        }
        return result
    }

    /**
     * 连接两个字节数组
     */
    public static func concat2(a: Array<Byte>, b: Array<Byte>): Array<Byte> {
        let result = Array<Byte>(a.size + b.size, repeat: 0)
        for (i in 0..a.size) {
            result[i] = a[i]
        }
        for (i in 0..b.size) {
            result[a.size + i] = b[i]
        }
        return result
    }

    /**
     * 连接三个字节数组
     */
    public static func concat3(a: Array<Byte>, b: Array<Byte>, c: Array<Byte>): Array<Byte> {
        let result = Array<Byte>(a.size + b.size + c.size, repeat: 0)
        var offset: Int64 = 0
        for (i in 0..a.size) {
            result[offset + i] = a[i]
        }
        offset += a.size
        for (i in 0..b.size) {
            result[offset + i] = b[i]
        }
        offset += b.size
        for (i in 0..c.size) {
            result[offset + i] = c[i]
        }
        return result
    }

    /**
     * 比较两个字节数组是否相等
     */
    public static func equals(a: Array<Byte>, b: Array<Byte>): Bool {
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
     * 字节数组转十六进制字符串
     */
    public static func toHex(bytes: Array<Byte>): String {
        var hex = ""
        for (i in 0..bytes.size) {
            let b = UInt8(bytes[i])
            let hi = b >> 4
            let lo = b & 0x0F
            hex += hexChar(hi)
            hex += hexChar(lo)
        }
        return hex
    }

    private static func hexChar(nibble: UInt8): String {
        if (nibble < 10) {
            return String(Rune(UInt32(nibble) + 48)) // '0' = 48
        } else {
            return String(Rune(UInt32(nibble) - 10 + 97)) // 'a' = 97
        }
    }

    /**
     * 十六进制字符串转字节数组
     */
    public static func fromHex(hex: String): Array<Byte> {
        let chars = hex.toRuneArray()
        let length = chars.size / 2
        let result = Array<Byte>(length, repeat: 0)
        for (i in 0..length) {
            let hi = hexValue(chars[i * 2])
            let lo = hexValue(chars[i * 2 + 1])
            result[i] = UInt8((hi << 4) | lo)
        }
        return result
    }

    private static func hexValue(c: Rune): UInt8 {
        let code = UInt32(c)
        if (code >= 48 && code <= 57) {       // '0'-'9'
            return UInt8(code - 48)
        } else if (code >= 97 && code <= 102) { // 'a'-'f'
            return UInt8(code - 97 + 10)
        } else if (code >= 65 && code <= 70) {  // 'A'-'F'
            return UInt8(code - 65 + 10)
        }
        return 0
    }

    /**
     * 字符串转 UTF-8 字节数组
     */
    public static func stringToBytes(str: String): Array<Byte> {
        return str.toArray()
    }

    /**
     * UTF-8 字节数组转字符串
     */
    public static func bytesToString(bytes: Array<Byte>): String {
        return String.fromUtf8(bytes)
    }

    /**
     * 32位整数转字节数组（小端序）
     */
    public static func int32ToBytes(value: Int32): Array<Byte> {
        let result = Array<Byte>(4, repeat: 0)
        result[0] = UInt8(value & 0xFF)
        result[1] = UInt8((value >> 8) & 0xFF)
        result[2] = UInt8((value >> 16) & 0xFF)
        result[3] = UInt8((value >> 24) & 0xFF)
        return result
    }

    /**
     * 32位无符号整数转字节数组（小端序）
     */
    public static func uint32ToBytes(value: UInt32): Array<Byte> {
        let result = Array<Byte>(4, repeat: 0)
        result[0] = UInt8(value & 0xFF)
        result[1] = UInt8((value >> 8) & 0xFF)
        result[2] = UInt8((value >> 16) & 0xFF)
        result[3] = UInt8((value >> 24) & 0xFF)
        return result
    }

    /**
     * 字节数组转32位整数（小端序）
     * 
     * 重要：使用 Int64 中间值避免 OverflowException。
     * 直接用 Int32 算术时，当最高字节 >= 0x80 时 `b3 << 24` 会溢出 Int32.Max。
     * 参见 CANGJIE_SYNTAX_FIXES.md §12: UInt32 → Int32 OverflowException
     */
    public static func bytesToInt32(bytes: Array<Byte>, offset!: Int64 = 0): Int32 {
        let b0 = Int64(UInt8(bytes[offset]))
        let b1 = Int64(UInt8(bytes[offset + 1]))
        let b2 = Int64(UInt8(bytes[offset + 2]))
        let b3 = Int64(UInt8(bytes[offset + 3]))
        let unsigned = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
        // 将无符号 32 位值转为有符号 Int32：> 0x7FFFFFFF 表示负数
        if (unsigned > 0x7FFFFFFF) {
            return Int32(unsigned - 0x100000000)  // 转为负 Int64 再截断
        }
        return Int32(unsigned)
    }

    /**
     * 字节数组转32位无符号整数（小端序）
     */
    public static func bytesToUInt32(bytes: Array<Byte>, offset!: Int64 = 0): UInt32 {
        let b0 = UInt32(UInt8(bytes[offset]))
        let b1 = UInt32(UInt8(bytes[offset + 1]))
        let b2 = UInt32(UInt8(bytes[offset + 2]))
        let b3 = UInt32(UInt8(bytes[offset + 3]))
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    /**
     * 64位整数转字节数组（小端序）
     */
    public static func int64ToBytes(value: Int64): Array<Byte> {
        let result = Array<Byte>(8, repeat: 0)
        for (i in 0..8) {
            result[i] = UInt8((value >> (i * 8)) & 0xFF)
        }
        return result
    }

    /**
     * 字节数组转64位整数（小端序）
     * 
     * 重要：使用低位 UInt32 + 高位 Int32 的分段方式避免 OverflowException。
     * 直接用 `Int64(byte) << 56` 当 byte >= 128 时会溢出 Int64.Max。
     */
    public static func bytesToInt64(bytes: Array<Byte>, offset!: Int64 = 0): Int64 {
        // 低 4 字节作为 UInt32（无符号，不会溢出）
        let lo = bytesToUInt32(bytes, offset: offset)
        // 高 4 字节作为 Int32（已修复，支持负值）
        let hi = bytesToInt32(bytes, offset: offset + 4)
        // 组合：高位左移32 OR 低位
        return (Int64(hi) << 32) | Int64(lo)
    }

    /**
     * 将 Int64 位模式重新解释为 IEEE 754 Float64
     * 
     * 对应 TelegramHarmony 的 `new DataView(buf).getFloat64(0, true)`
     * Cangjie 不提供 Float64.fromBits()，所以手动解析 IEEE 754 结构:
     *   sign(1 bit) | exponent(11 bits) | mantissa(52 bits)
     */
    public static func bitsToFloat64(bits: Int64): Float64 {
        // 全零 = +0.0
        if (bits == 0) { return 0.0 }

        // 提取符号位（bit 63）
        let negative = bits < 0

        // 清除符号位得到 bits[62:0]（始终为正 Int64）
        let absBits = bits & 0x7FFFFFFFFFFFFFFF

        // 提取指数（bits[62:52]，11位）
        let rawExp = Int32((absBits >> 52) & 0x7FF)

        // 提取尾数（bits[51:0]，52位）
        let mantissa = absBits & 0xFFFFFFFFFFFFF

        // 特殊值：Infinity / NaN
        if (rawExp == 0x7FF) {
            if (mantissa == 0) {
                return if (negative) { -1.0 / 0.0 } else { 1.0 / 0.0 }
            }
            return 0.0 / 0.0  // NaN
        }

        var result: Float64

        if (rawExp == 0) {
            // 非规格化数（subnormal）：value = 2^(-1022) * mantissa / 2^52
            // 对于 Telegram 协议数据，几乎不会遇到
            if (mantissa == 0) { return if (negative) { -0.0 } else { 0.0 } }
            result = Float64(mantissa) / 4503599627370496.0  // 除以 2^52
            result = result * pow2Helper(-1022)
        } else {
            // 规格化数：value = 2^(rawExp-1023) * (1 + mantissa / 2^52)
            let significand = 1.0 + Float64(mantissa) / 4503599627370496.0
            result = significand * pow2Helper(rawExp - 1023)
        }

        return if (negative) { -result } else { result }
    }

    /**
     * 计算 2^exp（使用快速幂法，O(log|exp|)）
     */
    private static func pow2Helper(exp: Int32): Float64 {
        if (exp == 0) { return 1.0 }
        if (exp > 0) {
            var r = 1.0
            var base = 2.0
            var e = exp
            while (e > 0) {
                if ((e & 1) != 0) { r = r * base }
                base = base * base
                e = e >> 1
            }
            return r
        } else {
            var r = 1.0
            var base = 0.5
            var e = -exp
            while (e > 0) {
                if ((e & 1) != 0) { r = r * base }
                base = base * base
                e = e >> 1
            }
            return r
        }
    }

    /**
     * 将 Float64 转换为 IEEE 754 Int64 位模式（bitsToFloat64 的逆操作）
     * 
     * 对应 TelegramHarmony 的 `new DataView(buf).setFloat64(0, value, true)`
     */
    public static func float64ToBits(value: Float64): Int64 {
        // 处理零
        if (value == 0.0) {
            // 不区分 +0 / -0（Telegram 不需要）
            return 0
        }

        // 处理特殊值
        if (value != value) {
            // NaN: 标准 quiet NaN
            return 0x7FF8000000000000
        }

        var v = value
        var sign: Int64 = 0
        if (v < 0.0) {
            sign = 1
            v = -v
        }

        // 找到指数：v = significand * 2^exp, 1.0 <= significand < 2.0
        var exp = 0
        var temp = v
        if (temp >= 2.0) {
            while (temp >= 2.0) {
                temp = temp / 2.0
                exp = exp + 1
            }
        } else if (temp < 1.0) {
            while (temp < 1.0 && exp > -1074) {
                temp = temp * 2.0
                exp = exp - 1
            }
        }
        // temp 现在在 [1.0, 2.0) 范围内，exp 是未偏移的指数

        let biasedExp = exp + 1023
        if (biasedExp >= 0x7FF) {
            // 溢出为 Infinity
            return (sign << 63) | 0x7FF0000000000000
        }

        if (biasedExp <= 0) {
            // 非规格化数
            let mantissa = Int64((temp * pow2Helper(Int32(52 + biasedExp - 1))) + 0.5)
            return (sign << 63) | (mantissa & 0xFFFFFFFFFFFFF)
        }

        // 规格化数：提取 52 位尾数
        let mantissa = Int64((temp - 1.0) * 4503599627370496.0 + 0.5)  // * 2^52
        return (sign << 63) | (biasedExp << 52) | (mantissa & 0xFFFFFFFFFFFFF)
    }

    /**
     * XOR 两个字节数组
     */
    public static func xor(a: Array<Byte>, b: Array<Byte>): Array<Byte> {
        let length = if (a.size < b.size) { a.size } else { b.size }
        let result = Array<Byte>(length, repeat: 0)
        for (i in 0..length) {
            result[i] = UInt8(UInt8(a[i]) ^ UInt8(b[i]))
        }
        return result
    }

    /**
     * 检查字节数组是否全为零
     */
    public static func isZero(bytes: Array<Byte>): Bool {
        for (i in 0..bytes.size) {
            if (bytes[i] != 0) {
                return false
            }
        }
        return true
    }

    /**
     * 反转字节数组
     */
    public static func reverse(bytes: Array<Byte>): Array<Byte> {
        let result = Array<Byte>(bytes.size, repeat: 0)
        for (i in 0..bytes.size) {
            result[i] = bytes[bytes.size - 1 - i]
        }
        return result
    }

    /**
     * 截取字节数组的子数组
     */
    public static func slice(bytes: Array<Byte>, start: Int64, end: Int64): Array<Byte> {
        let actualEnd = if (end > bytes.size) { bytes.size } else { end }
        let length = actualEnd - start
        if (length <= 0) {
            return Array<Byte>(0, repeat: 0)
        }
        let result = Array<Byte>(length, repeat: 0)
        for (i in 0..length) {
            result[i] = bytes[start + i]
        }
        return result
    }

    /**
     * 复制字节数组
     */
    public static func copy(bytes: Array<Byte>): Array<Byte> {
        let result = Array<Byte>(bytes.size, repeat: 0)
        for (i in 0..bytes.size) {
            result[i] = bytes[i]
        }
        return result
    }

    /**
     * 将源数组复制到目标数组的指定位置
     */
    public static func copyTo(src: Array<Byte>, dst: Array<Byte>, dstOffset: Int64) {
        for (i in 0..src.size) {
            dst[dstOffset + i] = src[i]
        }
    }
}
