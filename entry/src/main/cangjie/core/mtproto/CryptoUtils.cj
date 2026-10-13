package ohos_app_cangjie_entry.core.mtproto

import std.collection.ArrayList
import std.overflow.*

/**
 * UInt32 模 2^32 加法（wrapping addition）
 * Cangjie 没有 &+ 运算符，需要通过 UInt64 中间值避免溢出
 */
func wAdd(a: UInt32, b: UInt32): UInt32 {
    return UInt32((UInt64(a) + UInt64(b)) & 0xFFFFFFFF)
}

/**
 * UInt32 按位取反
 * Cangjie 没有 ~ 运算符，通过 XOR 0xFFFFFFFF 实现
 */
func bitwiseNot(v: UInt32): UInt32 {
    return v ^ UInt32(0xFFFFFFFF)
}

/**
 * SHA1 哈希
 * 
 * 对应 TelegramHarmony 的 CryptoUtils.ets SHA1 类
 * 纯 Cangjie 实现，不依赖外部库
 */
public class SHA1 {
    /**
     * 计算 SHA1 哈希（同步）
     */
    public static func hash(data: Array<Byte>): Array<Byte> {
        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0

        let msgLen = data.size
        let bitLen = UInt32(msgLen * 8)

        // 计算填充后的长度
        var paddedLen = msgLen + 1
        while (paddedLen % 64 != 56) {
            paddedLen++
        }
        paddedLen += 8

        let padded = Array<Byte>(paddedLen, repeat: 0)
        for (i in 0..msgLen) {
            padded[i] = data[i]
        }
        padded[msgLen] = UInt8(0x80u8)

        // 写入原始消息长度（大端序，64位）
        padded[paddedLen - 4] = UInt8((bitLen >> 24) & 0xFF)
        padded[paddedLen - 3] = UInt8((bitLen >> 16) & 0xFF)
        padded[paddedLen - 2] = UInt8((bitLen >> 8) & 0xFF)
        padded[paddedLen - 1] = UInt8(bitLen & 0xFF)

        // 处理每个64字节块
        var i: Int64 = 0
        while (i < paddedLen) {
            let w = Array<UInt32>(80, repeat: 0)

            // 读取16个32位字（大端序）
            for (j in 0..16) {
                let idx = i + j * 4
                w[j] = (UInt32(UInt8(padded[idx])) << 24) |
                        (UInt32(UInt8(padded[idx + 1])) << 16) |
                        (UInt32(UInt8(padded[idx + 2])) << 8) |
                        UInt32(UInt8(padded[idx + 3]))
            }

            // 扩展到80个字
            for (j in 16..80) {
                let temp = w[j - 3] ^ w[j - 8] ^ w[j - 14] ^ w[j - 16]
                w[j] = (temp << 1) | (temp >> 31)
            }

            var a = h0
            var b = h1
            var c = h2
            var d = h3
            var e = h4

            // 主循环
            for (j in 0..80) {
                var f: UInt32 = 0
                var k: UInt32 = 0
                if (j < 20) {
                    f = (b & c) | (bitwiseNot(b) & d)
                    k = 0x5A827999
                } else if (j < 40) {
                    f = b ^ c ^ d
                    k = 0x6ED9EBA1
                } else if (j < 60) {
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1BBCDC
                } else {
                    f = b ^ c ^ d
                    k = 0xCA62C1D6
                }

                let temp = wAdd(wAdd(wAdd(wAdd((a << 5) | (a >> 27), f), e), k), w[j])
                e = d
                d = c
                c = (b << 30) | (b >> 2)
                b = a
                a = temp
            }

            h0 = wAdd(h0, a)
            h1 = wAdd(h1, b)
            h2 = wAdd(h2, c)
            h3 = wAdd(h3, d)
            h4 = wAdd(h4, e)

            i += 64
        }

        // 生成输出（20字节）
        let result = Array<Byte>(20, repeat: 0)
        result[0] = UInt8((h0 >> 24) & 0xFF)
        result[1] = UInt8((h0 >> 16) & 0xFF)
        result[2] = UInt8((h0 >> 8) & 0xFF)
        result[3] = UInt8(h0 & 0xFF)
        result[4] = UInt8((h1 >> 24) & 0xFF)
        result[5] = UInt8((h1 >> 16) & 0xFF)
        result[6] = UInt8((h1 >> 8) & 0xFF)
        result[7] = UInt8(h1 & 0xFF)
        result[8] = UInt8((h2 >> 24) & 0xFF)
        result[9] = UInt8((h2 >> 16) & 0xFF)
        result[10] = UInt8((h2 >> 8) & 0xFF)
        result[11] = UInt8(h2 & 0xFF)
        result[12] = UInt8((h3 >> 24) & 0xFF)
        result[13] = UInt8((h3 >> 16) & 0xFF)
        result[14] = UInt8((h3 >> 8) & 0xFF)
        result[15] = UInt8(h3 & 0xFF)
        result[16] = UInt8((h4 >> 24) & 0xFF)
        result[17] = UInt8((h4 >> 16) & 0xFF)
        result[18] = UInt8((h4 >> 8) & 0xFF)
        result[19] = UInt8(h4 & 0xFF)
        return result
    }
}

/**
 * SHA256 哈希
 * 
 * 对应 TelegramHarmony 的 CryptoUtils.ets SHA256 类
 * 纯 Cangjie 实现
 */
public class SHA256 {
    private static let K: Array<UInt32> = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    /**
     * 计算 SHA256 哈希（同步）
     */
    public static func hash(data: Array<Byte>): Array<Byte> {
        if (data.size > 0 && NativeCrypto.available()) {
            match (NativeCrypto.sha256(data)) {
                case Some(r) => return r
                case None => ()
            }
        }
        var H: Array<UInt32> = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]

        // 预处理：填充
        let ml: Int64 = data.size * 8
        let paddingLength = (64 - ((data.size + 9) % 64)) % 64
        let paddedSize = data.size + 1 + paddingLength + 8
        let padded = Array<Byte>(paddedSize, repeat: 0)
        for (i in 0..data.size) {
            padded[i] = data[i]
        }
        padded[data.size] = UInt8(0x80u8)
        // 写入长度（大端序64位）
        for (i in 0..8) {
            padded[paddedSize - 8 + i] = UInt8((ml >> ((7 - i) * 8)) & 0xFF)
        }

        // 处理每个512位块
        var pos: Int64 = 0
        while (pos < paddedSize) {
            let W = Array<UInt32>(64, repeat: 0)

            for (t in 0..16) {
                let idx = pos + t * 4
                W[t] = (UInt32(UInt8(padded[idx])) << 24) |
                        (UInt32(UInt8(padded[idx + 1])) << 16) |
                        (UInt32(UInt8(padded[idx + 2])) << 8) |
                        UInt32(UInt8(padded[idx + 3]))
            }

            for (t in 16..64) {
                let s0 = rotr(W[t - 15], 7) ^ rotr(W[t - 15], 18) ^ (W[t - 15] >> 3)
                let s1 = rotr(W[t - 2], 17) ^ rotr(W[t - 2], 19) ^ (W[t - 2] >> 10)
                W[t] = wAdd(wAdd(wAdd(W[t - 16], s0), W[t - 7]), s1)
            }

            var a = H[0]
            var b = H[1]
            var c = H[2]
            var d = H[3]
            var e = H[4]
            var f = H[5]
            var g = H[6]
            var h = H[7]

            for (t in 0..64) {
                let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (bitwiseNot(e) & g)
                let temp1 = wAdd(wAdd(wAdd(wAdd(h, S1), ch), K[t]), W[t])
                let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = wAdd(S0, maj)

                h = g
                g = f
                f = e
                e = wAdd(d, temp1)
                d = c
                c = b
                b = a
                a = wAdd(temp1, temp2)
            }

            H[0] = wAdd(H[0], a)
            H[1] = wAdd(H[1], b)
            H[2] = wAdd(H[2], c)
            H[3] = wAdd(H[3], d)
            H[4] = wAdd(H[4], e)
            H[5] = wAdd(H[5], f)
            H[6] = wAdd(H[6], g)
            H[7] = wAdd(H[7], h)

            pos += 64
        }

        let result = Array<Byte>(32, repeat: 0)
        for (i in 0..8) {
            result[i * 4] = UInt8((H[i] >> 24) & 0xFF)
            result[i * 4 + 1] = UInt8((H[i] >> 16) & 0xFF)
            result[i * 4 + 2] = UInt8((H[i] >> 8) & 0xFF)
            result[i * 4 + 3] = UInt8(H[i] & 0xFF)
        }
        return result
    }

    private static func rotr(x: UInt32, n: Int64): UInt32 {
        return (x >> UInt32(n)) | (x << UInt32(32 - n))
    }
}

/**
 * AES-IGE 加密模式（MTProto 使用）
 * 
 * 对应 TelegramHarmony 的 CryptoUtils.ets AESIGE 类
 * 
 * AES-IGE 使用 AES-256-ECB 作为底层块加密。
 * 加密公式: c = E(p XOR ivp) XOR iv2p
 * 解密公式: p = D(c XOR iv2p) XOR ivp
 * 更新规则: ivp = c, iv2p = p
 * 
 * 注意：此处使用 kit.CryptoArchitectureKit 进行 AES-ECB 块操作。
 * 如果 kit API 不可用，需要实现纯 Cangjie AES-256-ECB。
 */
public class AESIGE {
    /**
     * AES-IGE 加密
     */
    public static func encrypt(data: Array<Byte>, key: Array<Byte>, iv: Array<Byte>): Array<Byte> {
        let blockSize: Int64 = 16

        // 确保数据是 16 字节对齐
        var paddedLength = data.size
        if (paddedLength % blockSize != 0) {
            paddedLength = ((paddedLength / blockSize) + 1) * blockSize
        }
        let padded = Array<Byte>(paddedLength, repeat: 0)
        for (i in 0..data.size) {
            padded[i] = data[i]
        }

        // 原生 OpenSSL 快路径（NativeCrypto.cj）；不可用时走下面的纯仓颉实现
        if (NativeCrypto.available()) {
            match (NativeCrypto.igeEncrypt(padded, key, iv)) {
                case Some(r) => return r
                case None => ()
            }
        }

        let result = Array<Byte>(paddedLength, repeat: 0)

        // ivp = iv[0:16], iv2p = iv[16:32]
        var ivp = ByteUtils.slice(iv, 0, 16)
        var iv2p = ByteUtils.slice(iv, 16, 32)

        var i: Int64 = 0
        while (i < paddedLength) {
            let p = ByteUtils.slice(padded, i, i + blockSize)

            // c = E(p XOR ivp) XOR iv2p
            let step1 = ByteUtils.xor(p, ivp)
            let step2 = AES256ECB.encryptBlock(step1, key)
            let c = ByteUtils.xor(step2, iv2p)

            ByteUtils.copyTo(c, result, i)

            // 更新: ivp = c, iv2p = p
            ivp = ByteUtils.copy(c)
            iv2p = ByteUtils.copy(p)

            i += blockSize
        }

        return result
    }

    /**
     * AES-IGE 解密
     */
    public static func decrypt(data: Array<Byte>, key: Array<Byte>, iv: Array<Byte>): Array<Byte> {
        let blockSize: Int64 = 16

        if (data.size % blockSize == 0 && NativeCrypto.available()) {
            match (NativeCrypto.igeDecrypt(data, key, iv)) {
                case Some(r) => return r
                case None => ()
            }
        }

        let result = Array<Byte>(data.size, repeat: 0)

        var ivp = ByteUtils.slice(iv, 0, 16)
        var iv2p = ByteUtils.slice(iv, 16, 32)

        var i: Int64 = 0
        while (i < data.size) {
            let c = ByteUtils.slice(data, i, i + blockSize)

            // p = D(c XOR iv2p) XOR ivp
            let step1 = ByteUtils.xor(c, iv2p)
            let step2 = AES256ECB.decryptBlock(step1, key)
            let p = ByteUtils.xor(step2, ivp)

            ByteUtils.copyTo(p, result, i)

            // 更新: ivp = c, iv2p = p
            ivp = ByteUtils.copy(c)
            iv2p = ByteUtils.copy(p)

            i += blockSize
        }

        return result
    }
}

/**
 * AES-256-ECB 块加密/解密
 * 
 * 纯 Cangjie 实现 AES-256
 * 如果 kit.CryptoArchitectureKit 可用，可替换为原生实现以提高性能
 */
public class AES256ECB {
    // AES S-Box
    private static let SBOX: Array<UInt8> = [
        0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
        0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
        0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
        0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
        0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
        0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
        0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
        0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
        0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
        0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
        0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
        0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
        0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
        0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
        0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
        0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16
    ]

    // Inverse S-Box
    private static let INV_SBOX: Array<UInt8> = [
        0x52, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, 0xbf, 0x40, 0xa3, 0x9e, 0x81, 0xf3, 0xd7, 0xfb,
        0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87, 0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde, 0xe9, 0xcb,
        0x54, 0x7b, 0x94, 0x32, 0xa6, 0xc2, 0x23, 0x3d, 0xee, 0x4c, 0x95, 0x0b, 0x42, 0xfa, 0xc3, 0x4e,
        0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2, 0x76, 0x5b, 0xa2, 0x49, 0x6d, 0x8b, 0xd1, 0x25,
        0x72, 0xf8, 0xf6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xd4, 0xa4, 0x5c, 0xcc, 0x5d, 0x65, 0xb6, 0x92,
        0x6c, 0x70, 0x48, 0x50, 0xfd, 0xed, 0xb9, 0xda, 0x5e, 0x15, 0x46, 0x57, 0xa7, 0x8d, 0x9d, 0x84,
        0x90, 0xd8, 0xab, 0x00, 0x8c, 0xbc, 0xd3, 0x0a, 0xf7, 0xe4, 0x58, 0x05, 0xb8, 0xb3, 0x45, 0x06,
        0xd0, 0x2c, 0x1e, 0x8f, 0xca, 0x3f, 0x0f, 0x02, 0xc1, 0xaf, 0xbd, 0x03, 0x01, 0x13, 0x8a, 0x6b,
        0x3a, 0x91, 0x11, 0x41, 0x4f, 0x67, 0xdc, 0xea, 0x97, 0xf2, 0xcf, 0xce, 0xf0, 0xb4, 0xe6, 0x73,
        0x96, 0xac, 0x74, 0x22, 0xe7, 0xad, 0x35, 0x85, 0xe2, 0xf9, 0x37, 0xe8, 0x1c, 0x75, 0xdf, 0x6e,
        0x47, 0xf1, 0x1a, 0x71, 0x1d, 0x29, 0xc5, 0x89, 0x6f, 0xb7, 0x62, 0x0e, 0xaa, 0x18, 0xbe, 0x1b,
        0xfc, 0x56, 0x3e, 0x4b, 0xc6, 0xd2, 0x79, 0x20, 0x9a, 0xdb, 0xc0, 0xfe, 0x78, 0xcd, 0x5a, 0xf4,
        0x1f, 0xdd, 0xa8, 0x33, 0x88, 0x07, 0xc7, 0x31, 0xb1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xec, 0x5f,
        0x60, 0x51, 0x7f, 0xa9, 0x19, 0xb5, 0x4a, 0x0d, 0x2d, 0xe5, 0x7a, 0x9f, 0x93, 0xc9, 0x9c, 0xef,
        0xa0, 0xe0, 0x3b, 0x4d, 0xae, 0x2a, 0xf5, 0xb0, 0xc8, 0xeb, 0xbb, 0x3c, 0x83, 0x53, 0x99, 0x61,
        0x17, 0x2b, 0x04, 0x7e, 0xba, 0x77, 0xd6, 0x26, 0xe1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0c, 0x7d
    ]

    // Rcon
    private static let RCON: Array<UInt8> = [
        0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36
    ]

    /**
     * AES-256-ECB 单块加密（16字节）
     */
    public static func encryptBlock(block: Array<Byte>, key: Array<Byte>): Array<Byte> {
        let roundKeys = keyExpansion(key)
        var state = Array<UInt8>(16, repeat: 0)
        for (i in 0..16) {
            state[i] = UInt8(block[i])
        }

        // Initial round key addition
        addRoundKey(state, roundKeys, 0)

        // 13 rounds (AES-256 has 14 rounds total)
        for (round in 1..14) {
            subBytes(state)
            shiftRows(state)
            mixColumns(state)
            addRoundKey(state, roundKeys, round)
        }

        // Final round (no MixColumns)
        subBytes(state)
        shiftRows(state)
        addRoundKey(state, roundKeys, 14)

        let result = Array<Byte>(16, repeat: 0)
        for (i in 0..16) {
            result[i] = UInt8(state[i])
        }
        return result
    }

    /**
     * AES-256-ECB 单块解密（16字节）
     */
    public static func decryptBlock(block: Array<Byte>, key: Array<Byte>): Array<Byte> {
        let roundKeys = keyExpansion(key)
        var state = Array<UInt8>(16, repeat: 0)
        for (i in 0..16) {
            state[i] = UInt8(block[i])
        }

        addRoundKey(state, roundKeys, 14)

        var round: Int64 = 13
        while (round >= 1) {
            invShiftRows(state)
            invSubBytes(state)
            addRoundKey(state, roundKeys, round)
            invMixColumns(state)
            round--
        }

        invShiftRows(state)
        invSubBytes(state)
        addRoundKey(state, roundKeys, 0)

        let result = Array<Byte>(16, repeat: 0)
        for (i in 0..16) {
            result[i] = UInt8(state[i])
        }
        return result
    }

    // ==================== AES Internal Operations ====================

    private static func keyExpansion(key: Array<Byte>): Array<UInt8> {
        // AES-256: 32 byte key, 15 round keys (60 words = 240 bytes)
        let expanded = Array<UInt8>(240, repeat: 0)
        for (i in 0..32) {
            expanded[i] = UInt8(key[i])
        }

        var i: Int64 = 8 // 8 words already
        while (i < 60) {
            var temp = Array<UInt8>(4, repeat: 0)
            let prev = (i - 1) * 4
            temp[0] = expanded[prev]
            temp[1] = expanded[prev + 1]
            temp[2] = expanded[prev + 2]
            temp[3] = expanded[prev + 3]

            if (i % 8 == 0) {
                // RotWord + SubWord + Rcon
                let t = temp[0]
                temp[0] = SBOX[Int64(temp[1])]
                temp[1] = SBOX[Int64(temp[2])]
                temp[2] = SBOX[Int64(temp[3])]
                temp[3] = SBOX[Int64(t)]
                temp[0] = temp[0] ^ RCON[(i / 8) - 1]
            } else if (i % 8 == 4) {
                // SubWord only
                temp[0] = SBOX[Int64(temp[0])]
                temp[1] = SBOX[Int64(temp[1])]
                temp[2] = SBOX[Int64(temp[2])]
                temp[3] = SBOX[Int64(temp[3])]
            }

            let base = (i - 8) * 4
            let target = i * 4
            expanded[target] = expanded[base] ^ temp[0]
            expanded[target + 1] = expanded[base + 1] ^ temp[1]
            expanded[target + 2] = expanded[base + 2] ^ temp[2]
            expanded[target + 3] = expanded[base + 3] ^ temp[3]

            i++
        }

        return expanded
    }

    private static func addRoundKey(state: Array<UInt8>, roundKeys: Array<UInt8>, round: Int64) {
        let base = round * 16
        for (i in 0..16) {
            state[i] = state[i] ^ roundKeys[base + i]
        }
    }

    private static func subBytes(state: Array<UInt8>) {
        for (i in 0..16) {
            state[i] = SBOX[Int64(state[i])]
        }
    }

    private static func invSubBytes(state: Array<UInt8>) {
        for (i in 0..16) {
            state[i] = INV_SBOX[Int64(state[i])]
        }
    }

    private static func shiftRows(state: Array<UInt8>) {
        // Row 1: shift left by 1
        var t = state[1]
        state[1] = state[5]; state[5] = state[9]; state[9] = state[13]; state[13] = t
        // Row 2: shift left by 2
        t = state[2]; let t2 = state[6]
        state[2] = state[10]; state[6] = state[14]; state[10] = t; state[14] = t2
        // Row 3: shift left by 3
        t = state[15]
        state[15] = state[11]; state[11] = state[7]; state[7] = state[3]; state[3] = t
    }

    private static func invShiftRows(state: Array<UInt8>) {
        // Row 1: shift right by 1
        var t = state[13]
        state[13] = state[9]; state[9] = state[5]; state[5] = state[1]; state[1] = t
        // Row 2: shift right by 2
        t = state[2]; let t2 = state[6]
        state[2] = state[10]; state[6] = state[14]; state[10] = t; state[14] = t2
        // Row 3: shift right by 3
        t = state[3]
        state[3] = state[7]; state[7] = state[11]; state[11] = state[15]; state[15] = t
    }

    private static func gmul(a: UInt8, b: UInt8): UInt8 {
        var p: UInt8 = 0
        var aa = a
        var bb = b
        for (_i in 0..8) {
            if ((bb & 1) != 0) {
                p = p ^ aa
            }
            let hiBit = aa & 0x80
            aa = aa << 1
            if (hiBit != 0) {
                aa = aa ^ 0x1b
            }
            bb = bb >> 1
        }
        return p
    }

    private static func mixColumns(state: Array<UInt8>) {
        for (c in 0..4) {
            let i = c * 4
            let s0 = state[i]
            let s1 = state[i + 1]
            let s2 = state[i + 2]
            let s3 = state[i + 3]

            state[i] = gmul(s0, 2) ^ gmul(s1, 3) ^ s2 ^ s3
            state[i + 1] = s0 ^ gmul(s1, 2) ^ gmul(s2, 3) ^ s3
            state[i + 2] = s0 ^ s1 ^ gmul(s2, 2) ^ gmul(s3, 3)
            state[i + 3] = gmul(s0, 3) ^ s1 ^ s2 ^ gmul(s3, 2)
        }
    }

    private static func invMixColumns(state: Array<UInt8>) {
        for (c in 0..4) {
            let i = c * 4
            let s0 = state[i]
            let s1 = state[i + 1]
            let s2 = state[i + 2]
            let s3 = state[i + 3]

            state[i] = gmul(s0, 14) ^ gmul(s1, 11) ^ gmul(s2, 13) ^ gmul(s3, 9)
            state[i + 1] = gmul(s0, 9) ^ gmul(s1, 14) ^ gmul(s2, 11) ^ gmul(s3, 13)
            state[i + 2] = gmul(s0, 13) ^ gmul(s1, 9) ^ gmul(s2, 14) ^ gmul(s3, 11)
            state[i + 3] = gmul(s0, 11) ^ gmul(s1, 13) ^ gmul(s2, 9) ^ gmul(s3, 14)
        }
    }
}

/**
 * MTProto 消息加密辅助类
 * 
 * 对应 TelegramHarmony 的 CryptoUtils.ets MTProtoCrypto 类
 */
public class MTProtoCrypto {
    /**
     * 计算消息密钥 (MTProto 2.0)
     * msgKey = SHA256(authKey[88+x:120+x] || paddedData)[8:24]
     */
    public static func calcMsgKey(authKey: Array<Byte>, data: Array<Byte>, isOutgoing: Bool): Array<Byte> {
        let x: Int64 = if (isOutgoing) { 0 } else { 8 }
        let authKeyPart = ByteUtils.slice(authKey, 88 + x, 88 + x + 32)
        let msgKeyLargePlain = ByteUtils.concat2(authKeyPart, data)
        let msgKeyLarge = SHA256.hash(msgKeyLargePlain)
        return ByteUtils.slice(msgKeyLarge, 8, 24)
    }

    /**
     * 计算 AES 密钥和 IV (MTProto 2.0)
     */
    public static func calcAesKeyIv(authKey: Array<Byte>, msgKey: Array<Byte>, isOutgoing: Bool): AesKeyIv {
        let x: Int64 = if (isOutgoing) { 0 } else { 8 }

        let sha256a = SHA256.hash(ByteUtils.concat2(
            msgKey,
            ByteUtils.slice(authKey, x, x + 36)
        ))

        let sha256b = SHA256.hash(ByteUtils.concat2(
            ByteUtils.slice(authKey, 40 + x, 40 + x + 36),
            msgKey
        ))

        let aesKey = ByteUtils.concat3(
            ByteUtils.slice(sha256a, 0, 8),
            ByteUtils.slice(sha256b, 8, 24),
            ByteUtils.slice(sha256a, 24, 32)
        )

        let aesIv = ByteUtils.concat3(
            ByteUtils.slice(sha256b, 0, 8),
            ByteUtils.slice(sha256a, 8, 24),
            ByteUtils.slice(sha256b, 24, 32)
        )

        let r = AesKeyIv()
        r.key = aesKey
        r.iv = aesIv
        return r
    }

    /**
     * 加密消息
     */
    public static func encryptMessage(
        authKey: Array<Byte>,
        authKeyId: Array<Byte>,
        data: Array<Byte>,
        isOutgoing: Bool
    ): EncryptedMessage {
        // 添加填充：至少 12 字节随机数据，然后对齐到 16 字节
        var paddingNeeded: Int64 = 12
        let lengthAfterMinPadding = data.size + paddingNeeded
        let remainder = lengthAfterMinPadding % 16
        if (remainder != 0) {
            paddingNeeded += (16 - remainder)
        }
        let paddedData = ByteUtils.concat2(data, ByteUtils.randomBytes(paddingNeeded))

        // 计算消息密钥
        let msgKey = calcMsgKey(authKey, paddedData, isOutgoing)

        // 计算 AES 密钥和 IV
        let aesParams = calcAesKeyIv(authKey, msgKey, isOutgoing)

        // 加密
        let encryptedData = AESIGE.encrypt(paddedData, aesParams.key, aesParams.iv)

        let r = EncryptedMessage()
        r.authKeyId = authKeyId
        r.msgKey = msgKey
        r.encryptedData = encryptedData
        return r
    }

    /**
     * 解密消息
     */
    public static func decryptMessage(
        authKey: Array<Byte>,
        msgKey: Array<Byte>,
        encryptedData: Array<Byte>,
        isOutgoing: Bool
    ): Array<Byte> {
        let aesParams = calcAesKeyIv(authKey, msgKey, isOutgoing)
        return AESIGE.decrypt(encryptedData, aesParams.key, aesParams.iv)
    }
}

/**
 * AES 密钥和 IV 容器
 */
public class AesKeyIv {
    public var key: Array<Byte> = Array<Byte>(32, repeat: 0)
    public var iv: Array<Byte> = Array<Byte>(32, repeat: 0)
}

/**
 * 加密消息结果
 */
public class EncryptedMessage {
    public var authKeyId: Array<Byte> = Array<Byte>(8, repeat: 0)
    public var msgKey: Array<Byte> = Array<Byte>(16, repeat: 0)
    public var encryptedData: Array<Byte> = Array<Byte>(0, repeat: 0)

    /**
     * 序列化为字节数组: authKeyId || msgKey || encryptedData
     */
    public func toBytes(): Array<Byte> {
        return ByteUtils.concat3(this.authKeyId, this.msgKey, this.encryptedData)
    }
}

// ==================== SHA512 ====================

/**
 * UInt64 wrapping addition (模 2^64 加法)
 * 使用 std.overflow 的 wrappingAdd 方法
 */
func wAdd64(a: UInt64, b: UInt64): UInt64 {
    return a.wrappingAdd(b)
}

/**
 * SHA512 哈希
 * 
 * 用于 SRP 6a (PBKDF2-HMAC-SHA512) 中的 2FA 密码验证
 * 纯 Cangjie 实现
 */
public class SHA512 {
    private static let K: Array<UInt64> = [
        0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc,
        0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118,
        0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
        0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694,
        0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
        0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
        0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4,
        0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70,
        0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
        0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
        0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30,
        0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
        0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8,
        0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3,
        0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
        0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b,
        0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178,
        0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
        0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c,
        0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817
    ]

    public static func hash(data: Array<Byte>): Array<Byte> {
        var H: Array<UInt64> = [
            0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
            0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179
        ]

        let ml: Int64 = data.size * 8
        let paddingLength = (128 - ((data.size + 17) % 128)) % 128
        let paddedSize = data.size + 1 + paddingLength + 16
        let padded = Array<Byte>(paddedSize, repeat: 0)
        for (i in 0..data.size) {
            padded[i] = data[i]
        }
        padded[data.size] = UInt8(0x80)
        // Write length as big-endian 128-bit (we only use lower 64 bits)
        for (i in 0..8) {
            padded[paddedSize - 8 + i] = UInt8((ml >> ((7 - i) * 8)) & 0xFF)
        }

        var pos: Int64 = 0
        while (pos < paddedSize) {
            let W = Array<UInt64>(80, repeat: 0)
            for (t in 0..16) {
                let idx = pos + t * 8
                W[t] = (UInt64(UInt8(padded[idx])) << 56) |
                        (UInt64(UInt8(padded[idx + 1])) << 48) |
                        (UInt64(UInt8(padded[idx + 2])) << 40) |
                        (UInt64(UInt8(padded[idx + 3])) << 32) |
                        (UInt64(UInt8(padded[idx + 4])) << 24) |
                        (UInt64(UInt8(padded[idx + 5])) << 16) |
                        (UInt64(UInt8(padded[idx + 6])) << 8) |
                        UInt64(UInt8(padded[idx + 7]))
            }
            for (t in 16..80) {
                let s0 = rotr64(W[t - 15], 1) ^ rotr64(W[t - 15], 8) ^ (W[t - 15] >> 7)
                let s1 = rotr64(W[t - 2], 19) ^ rotr64(W[t - 2], 61) ^ (W[t - 2] >> 6)
                W[t] = wAdd64(wAdd64(wAdd64(W[t - 16], s0), W[t - 7]), s1)
            }

            var a = H[0]; var b = H[1]; var c = H[2]; var d = H[3]
            var e = H[4]; var f = H[5]; var g = H[6]; var h = H[7]

            for (t in 0..80) {
                let S1 = rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41)
                let ch = (e & f) ^ (bitwiseNot64(e) & g)
                let temp1 = wAdd64(wAdd64(wAdd64(wAdd64(h, S1), ch), K[t]), W[t])
                let S0 = rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = wAdd64(S0, maj)

                h = g; g = f; f = e
                e = wAdd64(d, temp1)
                d = c; c = b; b = a
                a = wAdd64(temp1, temp2)
            }

            H[0] = wAdd64(H[0], a); H[1] = wAdd64(H[1], b)
            H[2] = wAdd64(H[2], c); H[3] = wAdd64(H[3], d)
            H[4] = wAdd64(H[4], e); H[5] = wAdd64(H[5], f)
            H[6] = wAdd64(H[6], g); H[7] = wAdd64(H[7], h)

            pos += 128
        }

        let result = Array<Byte>(64, repeat: 0)
        for (i in 0..8) {
            result[i * 8]     = UInt8((H[i] >> 56) & 0xFF)
            result[i * 8 + 1] = UInt8((H[i] >> 48) & 0xFF)
            result[i * 8 + 2] = UInt8((H[i] >> 40) & 0xFF)
            result[i * 8 + 3] = UInt8((H[i] >> 32) & 0xFF)
            result[i * 8 + 4] = UInt8((H[i] >> 24) & 0xFF)
            result[i * 8 + 5] = UInt8((H[i] >> 16) & 0xFF)
            result[i * 8 + 6] = UInt8((H[i] >> 8) & 0xFF)
            result[i * 8 + 7] = UInt8(H[i] & 0xFF)
        }
        return result
    }

    private static func rotr64(x: UInt64, n: Int64): UInt64 {
        return (x >> UInt64(n)) | (x << UInt64(64 - n))
    }

    private static func bitwiseNot64(v: UInt64): UInt64 {
        let hi = UInt64(0xFFFFFFFF) << 32
        let lo = UInt64(0xFFFFFFFF)
        return v ^ (hi | lo)
    }
}

// ==================== HMAC-SHA512 ====================

/**
 * HMAC-SHA512
 * 用于 PBKDF2 中的 PRF (Pseudo-Random Function)
 */
public class HMACSHA512 {
    public static func mac(key: Array<Byte>, message: Array<Byte>): Array<Byte> {
        let blockSize: Int64 = 128
        var realKey = key
        if (realKey.size > blockSize) {
            realKey = SHA512.hash(realKey)
        }
        if (realKey.size < blockSize) {
            let padded = Array<Byte>(blockSize, repeat: 0)
            for (i in 0..realKey.size) {
                padded[i] = realKey[i]
            }
            realKey = padded
        }

        let keyRef = realKey
        let ipad = Array<Byte>(blockSize, { i: Int64 => UInt8(UInt8(keyRef[i]) ^ UInt8(0x36)) })
        let opad = Array<Byte>(blockSize, { i: Int64 => UInt8(UInt8(keyRef[i]) ^ UInt8(0x5c)) })

        let innerData = ByteUtils.concat2(ipad, message)
        let innerHash = SHA512.hash(innerData)

        let outerData = ByteUtils.concat2(opad, innerHash)
        return SHA512.hash(outerData)
    }
}

// ==================== PBKDF2-HMAC-SHA512 ====================

/**
 * PBKDF2 with HMAC-SHA512
 * 用于 Telegram SRP 6a 中的密码派生
 * passwordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow
 */
public class PBKDF2SHA512 {
    /**
     * 派生密钥
     * password: 密码字节
     * salt: 盐值
     * iterations: 迭代次数 (Telegram 使用 100000)
     * dkLen: 输出密钥长度 (64 for SHA512)
     */
    public static func derive(password: Array<Byte>, salt: Array<Byte>, iterations: Int64, dkLen: Int64): Array<Byte> {
        let hLen: Int64 = 64
        let numBlocks = (dkLen + hLen - 1) / hLen
        let result = Array<Byte>(dkLen, repeat: 0)

        var blockIdx: Int64 = 1
        while (blockIdx <= numBlocks) {
            // U_1 = HMAC(password, salt || INT_32_BE(blockIdx))
            let blockIdxBytes = Array<Byte>(4, repeat: 0)
            blockIdxBytes[0] = UInt8((blockIdx >> 24) & 0xFF)
            blockIdxBytes[1] = UInt8((blockIdx >> 16) & 0xFF)
            blockIdxBytes[2] = UInt8((blockIdx >> 8) & 0xFF)
            blockIdxBytes[3] = UInt8(blockIdx & 0xFF)
            let saltAndIdx = ByteUtils.concat2(salt, blockIdxBytes)
            var u = HMACSHA512.mac(password, saltAndIdx)
            let t = Array<Byte>(hLen, repeat: 0)
            for (j in 0..hLen) {
                t[j] = u[j]
            }

            // U_2 .. U_c
            var iter: Int64 = 1
            while (iter < iterations) {
                u = HMACSHA512.mac(password, u)
                for (j in 0..hLen) {
                    t[j] = UInt8(UInt8(t[j]) ^ UInt8(u[j]))
                }
                iter++
            }

            // Copy T_blockIdx to result
            let offset = (blockIdx - 1) * hLen
            let toCopy = if (dkLen - offset < hLen) { dkLen - offset } else { hLen }
            for (j in 0..toCopy) {
                result[offset + j] = t[j]
            }
            blockIdx++
        }
        return result
    }
}

// ==================== AES-256-CBC (Telegram Passport file encryption) ====================

/**
 * AES256CBC — Telegram Passport uses AES-256-CBC with no padding for file data.
 *
 * iOS reference: EncryptedValueData in AccessSecureId.swift
 * The file data is padded to a 16-byte boundary with random bytes before encryption.
 * key: 32 bytes, iv: 16 bytes.
 *
 * Built on top of the existing AES256ECB.encryptBlock / decryptBlock primitive.
 */
public class AES256CBC {
    /**
     * encrypt — AES-256-CBC encrypt.
     * data must be a multiple of 16 bytes (pad before calling).
     * key: 32 bytes, iv: 16 bytes.
     */
    public static func encrypt(data: Array<Byte>, key: Array<Byte>, iv: Array<Byte>): Array<Byte> {
        let blockSize: Int64 = 16
        let result = Array<Byte>(data.size, repeat: 0)
        var prev = ByteUtils.slice(iv, 0, 16)
        var i: Int64 = 0
        while (i < data.size) {
            let block = ByteUtils.slice(data, i, i + blockSize)
            let xored = ByteUtils.xor(block, prev)
            let enc = AES256ECB.encryptBlock(xored, key)
            ByteUtils.copyTo(enc, result, i)
            prev = enc
            i += blockSize
        }
        return result
    }

    /**
     * decrypt — AES-256-CBC decrypt.
     * data must be a multiple of 16 bytes.
     * key: 32 bytes, iv: 16 bytes.
     */
    public static func decrypt(data: Array<Byte>, key: Array<Byte>, iv: Array<Byte>): Array<Byte> {
        let blockSize: Int64 = 16
        let result = Array<Byte>(data.size, repeat: 0)
        var prev = ByteUtils.slice(iv, 0, 16)
        var i: Int64 = 0
        while (i < data.size) {
            let block = ByteUtils.slice(data, i, i + blockSize)
            let dec = AES256ECB.decryptBlock(block, key)
            let plain = ByteUtils.xor(dec, prev)
            ByteUtils.copyTo(plain, result, i)
            prev = block
            i += blockSize
        }
        return result
    }

    /**
     * padToBlockSize — pad data with random bytes to a 16-byte multiple.
     * iOS: SecureId padding uses random bytes (not PKCS#7).
     */
    public static func padToBlockSize(data: Array<Byte>): Array<Byte> {
        let blockSize: Int64 = 16
        let rem = data.size % blockSize
        if (rem == 0) {
            return data
        }
        let padLen = blockSize - rem
        let padded = Array<Byte>(data.size + padLen, repeat: 0)
        for (i in 0..data.size) {
            padded[i] = data[i]
        }
        let randomPad = ByteUtils.randomBytes(padLen)
        for (i in 0..padLen) {
            padded[data.size + i] = randomPad[i]
        }
        return padded
    }
}
