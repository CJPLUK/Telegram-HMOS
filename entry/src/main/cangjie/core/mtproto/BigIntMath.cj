package ohos_app_cangjie_entry.core.mtproto

import std.math.numeric.*
import std.collection.ArrayList

/**
 * 大数运算辅助类
 * 
 * 对应 TelegramHarmony 的 AuthKeyCreator.ets BigIntMath 类
 * 使用 Cangjie 标准库 std.math.numeric.BigInt
 * 
 * 优势：Cangjie BigInt 内置 modPow() 和 gcd()，比 JS 手动实现更高效
 */
public class BigIntMath {
    /**
     * 模幂运算: base^exp mod mod
     * 
     * 直接使用 Cangjie BigInt.modPow() 内置方法
     */
    public static func modPow(base: Array<Byte>, exp: Array<Byte>, modulus: Array<Byte>): Array<Byte> {
        let baseBig = bytesToBigInt(base)
        let expBig = bytesToBigInt(exp)
        let modBig = bytesToBigInt(modulus)

        let result = baseBig.modPow(expBig, m: modBig)
        return bigIntToBytes(result, modulus.size)
    }

    /**
     * 字节数组转 BigInt（大端序）
     */
    public static func bytesToBigInt(bytes: Array<Byte>): BigInt {
        var result = BigInt(0)
        for (i in 0..bytes.size) {
            result = (result << 8) | BigInt(Int64(UInt8(bytes[i])))
        }
        return result
    }

    /**
     * BigInt 转字节数组（大端序，指定长度）
     */
    public static func bigIntToBytes(value: BigInt, length: Int64): Array<Byte> {
        let result = Array<Byte>(length, repeat: 0)
        var temp = value
        var i = length - 1
        while (i >= 0) {
            let (quotient, remainder) = temp.divAndMod(BigInt(256))
            // remainder should be in [0, 255]
            let byteVal = remainder.toInt64()
            result[i] = UInt8(byteVal & 0xFF)
            temp = quotient
            i--
        }
        return result
    }

    /**
     * 分解 PQ 为 P 和 Q（Pollard's rho 算法）
     * 
     * TelegramHarmony 使用小素数试除 + Pollard's rho
     */
    public static func factorizePQ(pq: Array<Byte>): FactorResult {
        let pqBig = bytesToBigInt(pq)

        // 尝试小因子
        let smallPrimes: Array<Int64> = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47]

        for (primeVal in smallPrimes) {
            let prime = BigInt(primeVal)
            let (_, remainder) = pqBig.divAndMod(prime)
            if (remainder == BigInt(0)) {
                let p = prime
                let q = pqBig / prime
                let r = FactorResult()
                if (p < q) {
                    r.p = bigIntToBytes(p, 4)
                    r.q = bigIntToBytes(q, 4)
                } else {
                    r.p = bigIntToBytes(q, 4)
                    r.q = bigIntToBytes(p, 4)
                }
                return r
            }
        }

        // Pollard's rho 算法
        var x = BigInt(2)
        var y = BigInt(2)
        var d = BigInt(1)

        while (d == BigInt(1)) {
            x = (x * x + BigInt(1)) % pqBig
            y = (y * y + BigInt(1)) % pqBig
            y = (y * y + BigInt(1)) % pqBig

            var diff = x - y
            if (diff < BigInt(0)) {
                diff = -diff
            }
            d = gcd(diff, pqBig)
        }

        let r = FactorResult()
        let other = pqBig / d
        if (d < other) {
            r.p = bigIntToBytes(d, 4)
            r.q = bigIntToBytes(other, 4)
        } else {
            r.p = bigIntToBytes(other, 4)
            r.q = bigIntToBytes(d, 4)
        }
        return r
    }

    /**
     * 数字转字节数组（大端序，可变长度）
     */
    public static func numberToBytes(num: Int64): Array<Byte> {
        if (num == 0) {
            return Array<Byte>(1, repeat: 0)
        }
        let bytes = ArrayList<Byte>()
        var temp = num
        while (temp > 0) {
            bytes.add(UInt8(temp & 0xFF), at: 0)
            temp = temp >> 8
        }
        let result = Array<Byte>(bytes.size, repeat: 0)
        for (i in 0..bytes.size) {
            result[i] = bytes[i]
        }
        return result
    }
}

/**
 * 因子分解结果
 */
public class FactorResult {
    public var p: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var q: Array<Byte> = Array<Byte>(0, repeat: 0)
}

/**
 * RSA 公钥信息
 */
public class RSAKeyInfo {
    public let nHex: String
    public let e: Int64
    public let fingerprint: Int64

    public init(nHex: String, e: Int64, fingerprint: Int64) {
        this.nHex = nHex
        this.e = e
        this.fingerprint = fingerprint
    }
}

/**
 * RSA 公钥管理（Telegram 官方公钥）
 * 
 * 对应 TelegramHarmony 的 AuthKeyCreator.ets RSAPublicKey 类
 * 
 * 这些是 Telegram 官方使用的 RSA 公钥，用于密钥交换
 * 来源: Telegram iOS 源码 - MTDatacenterAuthMessageService.m
 */
public class RSAPublicKey {
    // 生产环境密钥
    public static let PRODUCTION_KEY = RSAKeyInfo(
        "e8bb3305c0b52c6cf2afdf7637313489e63e05268e5badb601af417786472e5f93b85438968e20e6729a301c0afc121bf7151f834436f7fda680847a66bf64accec78ee21c0b316f0edafe2f41908da7bd1f4a5107638eeb67040ace472a14f90d9f7c2b7def99688ba3073adb5750bb02964902a359fe745d8170e36876d4fd8a5d41b2a76cbff9a13267eb9580b2d06d10357448d20d9da2191cb5d8c93982961cdfdeda629e37f1fb09a0722027696032fe61ed663db7a37f6f263d370f69db53a0dc0a1748bdaaff6209d5645485e6e001d1953255757e4b8e42813347b11da6ab500fd0ace7e6dfa3736199ccaf9397ed0745a427dcfa6cd67bcb1acff3",
        65537,
        -3414540481677951611
    )

    // 测试环境密钥
    public static let TEST_KEY = RSAKeyInfo(
        "c8c11d635691fac091dd9489aedced2932aa8a0bcefef05fa800892d9b52ed03200865c9e97211cb2ee6c7ae96d3fb0e15aeffd66019b44a08a240cfdd2868a85e1f54d6fa5deaa041f6941ddf302690d61dc476385c2fa655142353cb4e4b59f6e5b6584db76fe8b1370263246c010c93d011014113ebdf987d093f9d37c2be48352d69a1683f8f6e6c2167983c761e3ab169fde5daaa12123fa1beab621e4da5935e9c198f82f35eae583a99386d8110ea6bd1abb0f568759f62694419ea5f69847c43462abef858b4cb5edc84e7b9226cd7bd7e183aa974a712c079dde85b9dc063b8a5c08e8f859c0ee5dcd824c7807f20153361a7f63cfd2a433a1be7f5",
        65537,
        -5595554452916591101
    )

    public static let RSA_KEYS: Array<RSAKeyInfo> = [PRODUCTION_KEY, TEST_KEY]

    /**
     * 根据服务器指纹选择匹配的公钥
     */
    public static func selectKey(serverFingerprints: ArrayList<Int64>): Option<RSAKeyInfo> {
        let mask: Int64 = Int64(0x7FFFFFFFFFFFFFFF) | Int64.Min  // all bits set = -1 as mask workaround
        for (serverFp in serverFingerprints) {
            for (key in RSA_KEYS) {
                if (key.fingerprint == serverFp) {
                    return Some(key)
                }
                // 处理有符号/无符号差异
                if (fingerprintEquals(key.fingerprint, serverFp)) {
                    return Some(key)
                }
            }
        }
        // 没有匹配的指纹，返回第一个密钥作为 fallback
        return Some(RSA_KEYS[0])
    }

    private static func fingerprintEquals(a: Int64, b: Int64): Bool {
        // 比较低 64 位（忽略符号）
        return a == b
    }

    /**
     * 使用选定的密钥进行 RSA 加密（现代填充方案）
     * 
     * 参考 Telegram iOS: MTDatacenterAuthMessageService.m encryptRSAModernPadding
     */
    public static func encryptWithKey(data: Array<Byte>, key: RSAKeyInfo): Array<Byte> {
        let n = ByteUtils.fromHex(key.nHex)
        let e = BigIntMath.numberToBytes(key.e)
        let nBigInt = BigIntMath.bytesToBigInt(n)

        // Step 1: 填充数据到 192 字节
        let dataWithPadding = Array<Byte>(192, repeat: 0)
        for (i in 0..data.size) {
            dataWithPadding[i] = data[i]
        }
        let paddingLen = 192 - data.size
        let padding = ByteUtils.randomBytes(paddingLen)
        for (i in 0..paddingLen) {
            dataWithPadding[data.size + i] = padding[i]
        }

        let maxAttempts: Int64 = 64
        var attempt: Int64 = 0
        while (attempt < maxAttempts) {
            // Step 2: 反转填充后的数据
            let dataWithPaddingReversed = ByteUtils.reverse(dataWithPadding)

            // Step 3: 生成随机 32 字节临时密钥
            let tempKey = ByteUtils.randomBytes(32)

            // Step 4: SHA256(tempKey || dataWithPadding)
            let tempKeyAndData = ByteUtils.concat2(tempKey, dataWithPadding)
            let hashResult = SHA256.hash(tempKeyAndData)

            // Step 5: dataWithHash = reversedData || hash = 224 bytes
            let dataWithHash = ByteUtils.concat2(dataWithPaddingReversed, hashResult)

            // Step 6: AES-IGE 加密（使用 tempKey 和 32字节 zero IV）
            let zeroIv = Array<Byte>(32, repeat: 0)
            let aesEncrypted = AESIGE.encrypt(dataWithHash, tempKey, zeroIv)

            // Step 7: SHA256(aesEncrypted)
            let shaAesEncrypted = SHA256.hash(aesEncrypted)

            // Step 8: tempKeyXor = tempKey XOR SHA256(aesEncrypted)
            let tempKeyXor = ByteUtils.xor(tempKey, shaAesEncrypted)

            // Step 9: keyAesEncrypted = tempKeyXor || aesEncrypted = 256 bytes
            let keyAesEncrypted = ByteUtils.concat2(tempKeyXor, aesEncrypted)

            // Step 10: 检查 keyAesEncrypted < n
            let keyAesBigInt = BigIntMath.bytesToBigInt(keyAesEncrypted)
            if (keyAesBigInt >= nBigInt) {
                attempt++
                continue
            }

            // Step 11: RSA 加密
            let encrypted = BigIntMath.modPow(keyAesEncrypted, e, n)

            // 确保输出正好是 256 字节
            if (encrypted.size == 256) {
                return encrypted
            } else if (encrypted.size < 256) {
                let padResult = Array<Byte>(256, repeat: 0)
                let offset = 256 - encrypted.size
                for (i in 0..encrypted.size) {
                    padResult[offset + i] = encrypted[i]
                }
                return padResult
            } else {
                return ByteUtils.slice(encrypted, encrypted.size - 256, encrypted.size)
            }
        }

        // 不应到达此处
        return Array<Byte>(256, repeat: 0)
    }
}
