package ohos_app_cangjie_entry.core.mtproto

import kit.PerformanceAnalysisKit.Hilog

/**
 * MTProto obfuscated2 传输混淆层（anti-DPI）。
 *
 * 对应 iOS MtProtoKit 的 MTTcpConnection.m（控制头构造）+ MTAes.m（MTAesCtr）。
 *
 * obfuscated2 在帧层（wrapFrame 产出的字节）与裸 socket 之间插入一层 AES-256-CTR
 * 流加密，使整条 TCP 流呈现为不可区分的随机字节，规避 DPI 特征封锁。
 *
 * 精确算法（与 iOS 源逐行核对）：
 *   1. 生成 64 字节随机 init（controlBytes），带约束：
 *        - init[0] != 0xef
 *        - 前 4 字节小端不等于禁止前缀集（HTTP HEAD/POST/GET /OPTI、0xeeeeeeee、0xdddddddd、0x00000000、0x16030102）
 *        - init[4:8]（小端 32 位）不为 0
 *   2. 协议 tag 写入 init[56:60]（小端 32 位）：
 *        - Abridged-over-obfs   → 0xefefefef
 *        - Intermediate         → 0xeeeeeeee
 *        - PaddedIntermediate   → 0xdddddddd
 *      datacenter tag 写入 init[60:62]（此处无 secret/dc-tag 需求，置 0）
 *   3. 从 init 导出双向 CTR：
 *        - 发送 key = init[8:40]（32B），发送 iv = init[40:56]（16B）
 *        - 接收 = 把整 64B init 反转后，key = reversed[8:40]，iv = reversed[40:56]
 *   4. 用发送 CTR 对整 64B init 做加密（推进发送流），取 encrypted[56:64]（8B）覆盖回
 *      明文 init 的尾部；上线字节 = init[0:56]（明文）+ encrypted[56:64]。
 *   5. 此后所有出站字节用发送 CTR 流连续加密、入站用接收 CTR 流连续解密，
 *      counter 不重置。
 *
 * 注意：iOS 的 MTAesCtr 底层用 `kCCAlgorithmAES128 + kCCOptionECBMode` 但 keyLength=32，
 * 即 AES-256-ECB 单块；keystream = AES256_ECB(counter)，counter 大端 +1 自增，
 * keystream 与数据逐字节 XOR。本实现复用工程内 AES256ECB.encryptBlock（纯仓颉 AES-256-ECB 单块）。
 */

/**
 * AES-256-CTR 单向流密码。
 *
 * keystream 由 AES256ECB.encryptBlock(counter, key) 产出，counter 16 字节大端，
 * 每消费一个 16 字节 keystream 块后 +1。num 记录当前块内已消费字节数，
 * 跨多次 process 调用保持连续（与 iOS MTAesCtr 的 _num / _ecount 语义一致）。
 */
public class AesCtr {
    private let key: Array<Byte>
    private var counter: Array<Byte>     // 16B 当前 counter（大端自增）
    private var ecount: Array<Byte>      // 16B 当前 keystream 块
    private var num: Int64               // 当前块内已消费字节数（0..15）

    /**
     * @param key 32 字节 AES-256 密钥
     * @param iv  16 字节初始 counter
     */
    public init(key: Array<Byte>, iv: Array<Byte>) {
        if (key.size != 32) {
            throw Exception("AesCtr: key must be 32 bytes, got ${key.size}")
        }
        if (iv.size != 16) {
            throw Exception("AesCtr: iv must be 16 bytes, got ${iv.size}")
        }
        this.key = ByteUtils.copy(key)
        this.counter = ByteUtils.copy(iv)
        this.ecount = Array<Byte>(16, repeat: 0)
        this.num = 0
    }

    /**
     * counter 大端 +1（对应 iOS ctr128_inc）。
     */
    private func incCounter(): Unit {
        var n = 16
        var c: Int64 = 1
        while (n > 0) {
            n -= 1
            c += Int64(UInt8(this.counter[n]))
            this.counter[n] = UInt8(c & 0xFF)
            c = c >> 8
        }
    }

    /**
     * 对 input 做 CTR 流加/解密（CTR 加解密同构）。
     * 连续推进内部流状态：num / counter / ecount 跨调用保持。
     */
    public func process(input: Array<Byte>): Array<Byte> {
        let len = input.size
        let out = Array<Byte>(len, repeat: 0)
        var n = this.num
        var i = 0
        while (i < len) {
            if (n == 0) {
                // 生成新 keystream 块
                this.ecount = AES256ECB.encryptBlock(this.counter, this.key)
                this.incCounter()
            }
            out[i] = UInt8(UInt8(input[i]) ^ UInt8(this.ecount[n]))
            i += 1
            n = (n + 1) % 16
        }
        this.num = n
        return out
    }
}

/**
 * obfuscated2 协议 tag（写入 init[56:60]，小端 32 位）。
 */
public class ObfuscationTag {
    // Abridged-over-obfuscated
    public static let ABRIDGED: UInt32 = 0xefefefefu32
    // Intermediate-over-obfuscated
    public static let INTERMEDIATE: UInt32 = 0xeeeeeeeeu32
    // PaddedIntermediate-over-obfuscated
    public static let PADDED: UInt32 = 0xddddddddu32
}

/**
 * obfuscated2 混淆层。
 *
 * 生命周期：
 *   1. handshakeBytes() —— 构造并返回 64 字节上线握手前缀（明文 56 + 加密 8），
 *      同时初始化发送/接收 CTR。必须在任何 encryptOutgoing/decryptIncoming 之前调用一次。
 *   2. encryptOutgoing(frameBytes) —— 帧层产出 → 出站 CTR 加密。
 *   3. decryptIncoming(socketBytes) —— 入站 socket 字节 → 接收 CTR 解密。
 *
 * 失败安全：未 handshake 即调用 encrypt/decrypt 抛 Exception（绝不静默旁路）。
 */
public class MTProtoObfuscation {
    private var outgoing: Option<AesCtr> = None
    private var incoming: Option<AesCtr> = None
    private var ready: Bool = false
    private let tag: UInt32

    /**
     * @param protocolTag 内层帧协议 tag（ObfuscationTag.ABRIDGED / INTERMEDIATE / PADDED）
     */
    public init(protocolTag: UInt32) {
        this.tag = protocolTag
    }

    public func isReady(): Bool {
        return this.ready
    }

    /**
     * 把 4 字节（offset..offset+4）按小端读成 UInt32。
     */
    private static func readU32LE(b: Array<Byte>, offset: Int64): UInt32 {
        let b0 = UInt32(UInt8(b[offset]))
        let b1 = UInt32(UInt8(b[offset + 1]))
        let b2 = UInt32(UInt8(b[offset + 2]))
        let b3 = UInt32(UInt8(b[offset + 3]))
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    /**
     * 把 UInt32 按小端写入 b[offset..offset+4]。
     */
    private static func writeU32LE(b: Array<Byte>, offset: Int64, v: UInt32): Unit {
        b[offset] = UInt8(v & 0xFFu32)
        b[offset + 1] = UInt8((v >> 8) & 0xFFu32)
        b[offset + 2] = UInt8((v >> 16) & 0xFFu32)
        b[offset + 3] = UInt8((v >> 24) & 0xFFu32)
    }

    /**
     * 校验 64 字节 init 的明文前缀约束（对应 iOS controlBytes 约束）。
     * 满足返回 true（可用），否则 false（需重抽）。
     */
    private static func plaintextInitValid(initBytes: Array<Byte>): Bool {
        // initBytes[0] != 0xef
        if (UInt8(initBytes[0]) == 0xefu8) {
            return false
        }
        // 前 4 字节小端不在禁止前缀集
        let head = readU32LE(initBytes, 0)
        if (head == 0x44414548u32 ||   // "HEAD"
            head == 0x54534f50u32 ||   // "POST"
            head == 0x20544547u32 ||   // "GET "
            head == 0x4954504fu32 ||   // "OPTI"
            head == 0xeeeeeeeeu32 ||
            head == 0xddddddddu32 ||
            head == 0x00000000u32 ||
            head == 0x16030102u32) {   // TLS record-ish 前缀
            return false
        }
        // initBytes[4:8]（小端）不为 0
        let second = readU32LE(initBytes, 4)
        if (second == 0x00000000u32) {
            return false
        }
        return true
    }

    /**
     * 校验加密后头 4 字节（encrypted[0:4] 小端）不落在禁止前缀集（对应 iOS retry intHeader 检查）。
     */
    private static func encryptedHeadValid(encHead: UInt32): Bool {
        if (encHead == 0x44414548u32 ||
            encHead == 0x54534f50u32 ||
            encHead == 0x20544547u32 ||
            encHead == 0x4954504fu32 ||
            encHead == 0xddddddddu32 ||
            encHead == 0xeeeeeeeeu32 ||
            encHead == 0x16030102u32) {
            return false
        }
        return true
    }

    /**
     * 构造握手字节并初始化双向 CTR。
     *
     * 返回 64 字节上线前缀：init[0:56]（明文）+ encrypted[56:64]（含嵌入 tag）。
     * 调用后 outgoing/incoming CTR 已就绪、发送流已推进过整 64B init。
     *
     * @param randomInit 可选注入的 64 字节随机源（仅 selfCheck 用确定性向量）；
     *                   传 None 时内部用 ByteUtils.randomBytes 生成并施加约束重抽。
     */
    public func handshakeBytes(randomInit!: Option<Array<Byte>> = None): Array<Byte> {
        var initBytes = Array<Byte>(64, repeat: 0)
        var ok = false

        match (randomInit) {
            case Some(provided) =>
                if (provided.size != 64) {
                    throw Exception("MTProtoObfuscation: injected init must be 64 bytes, got ${provided.size}")
                }
                initBytes = ByteUtils.copy(provided)
                // 注入向量仅供确定性 selfCheck；不强制约束（测试向量自负责），但仍写 tag。
                ok = true
            case None =>
                // 最多 64 轮重抽，直到明文约束 + 加密头约束都满足
                var attempt = 0
                while (attempt < 64) {
                    attempt += 1
                    let cand = ByteUtils.randomBytes(64)
                    if (!plaintextInitValid(cand)) {
                        continue
                    }
                    // 写 tag 后才能算 send key/iv → 试加密验证加密头约束
                    writeU32LE(cand, 56, this.tag)
                    // datacenter tag initBytes[60:62] 置 0（无 proxy secret 场景）
                    cand[60] = 0u8
                    cand[61] = 0u8

                    let sendKey = ByteUtils.slice(cand, 8, 40)
                    let sendIv = ByteUtils.slice(cand, 40, 56)
                    let probe = AesCtr(sendKey, sendIv)
                    let enc = probe.process(cand)
                    let encHead = readU32LE(enc, 0)
                    if (!encryptedHeadValid(encHead)) {
                        continue
                    }
                    initBytes = cand
                    ok = true
                    break
                }
        }

        if (!ok) {
            throw Exception("MTProtoObfuscation: failed to generate valid init after retries")
        }

        // 注入向量路径下也要写 tag（确定性 selfCheck 走这里）
        match (randomInit) {
            case Some(_) =>
                writeU32LE(initBytes, 56, this.tag)
                initBytes[60] = 0u8
                initBytes[61] = 0u8
            case None => ()
        }

        // 导出双向 key/iv
        let sendKey = ByteUtils.slice(initBytes, 8, 40)    // 32B
        let sendIv = ByteUtils.slice(initBytes, 40, 56)    // 16B
        let reversed = ByteUtils.reverse(initBytes)        // 64B
        let recvKey = ByteUtils.slice(reversed, 8, 40)
        let recvIv = ByteUtils.slice(reversed, 40, 56)

        let outCtr = AesCtr(sendKey, sendIv)
        let inCtr = AesCtr(recvKey, recvIv)

        // 用发送 CTR 加密整 64B init（推进发送流），取 encrypted[56:64]
        let encryptedInit = outCtr.process(initBytes)

        let wire = Array<Byte>(64, repeat: 0)
        // 明文 initBytes[0:56]
        ByteUtils.copyTo(ByteUtils.slice(initBytes, 0, 56), wire, 0)
        // 加密 encrypted[56:64]（含嵌入 tag）
        ByteUtils.copyTo(ByteUtils.slice(encryptedInit, 56, 64), wire, 56)

        this.outgoing = Some(outCtr)
        this.incoming = Some(inCtr)
        this.ready = true

        return wire
    }

    /**
     * 出站：帧字节 → CTR 加密。
     */
    public func encryptOutgoing(frameBytes: Array<Byte>): Array<Byte> {
        match (this.outgoing) {
            case Some(ctr) => return ctr.process(frameBytes)
            case None => throw Exception("MTProtoObfuscation: encryptOutgoing before handshake")
        }
    }

    /**
     * 入站：socket 字节 → CTR 解密（CTR 加解密同构）。
     */
    public func decryptIncoming(socketBytes: Array<Byte>): Array<Byte> {
        match (this.incoming) {
            case Some(ctr) => return ctr.process(socketBytes)
            case None => throw Exception("MTProtoObfuscation: decryptIncoming before handshake")
        }
    }

    /**
     * 根据 TransportScheme 选取内层协议 tag。
     */
    public static func tagForScheme(scheme: TransportScheme): UInt32 {
        match (scheme) {
            case Abridged => return ObfuscationTag.ABRIDGED
            case Intermediate => return ObfuscationTag.INTERMEDIATE
            case PaddedIntermediate => return ObfuscationTag.PADDED
        }
    }

    // -------------------------------------------------------------------------
    // selfCheck — 真断言：CTR 已知向量 keystream / 往返复原 / init 约束 / 握手布局。
    // 无需网络；任何断言失败抛 Exception。
    // -------------------------------------------------------------------------
    public static func selfCheck(): Unit {
        // ===== 1. CTR 往返复原（加密后用同 key/iv 解密复原） =====
        let key = Array<Byte>(32, repeat: 0)
        for (i in 0..32) {
            key[i] = UInt8(i + 1)
        }
        let iv = Array<Byte>(16, repeat: 0)
        for (i in 0..16) {
            iv[i] = UInt8(0xA0 + i)
        }
        let plain = Array<Byte>(70, repeat: 0)  // 跨多个 16B 块且非对齐，暴露 num 跨块状态
        for (i in 0..70) {
            plain[i] = UInt8((i * 7 + 3) % 256)
        }
        let enc = AesCtr(key, iv)
        let cipher = enc.process(plain)
        let dec = AesCtr(key, iv)
        let recovered = dec.process(cipher)
        for (i in 0..70) {
            if (recovered[i] != plain[i]) {
                throw Exception("Obfuscation selfCheck FAIL: CTR roundtrip mismatch at ${i}")
            }
        }

        // ===== 2. CTR 已知 keystream：第一块 keystream = AES256ECB(iv, key) =====
        // CTR(0...) ⊕ plain=0 → output = keystream。用全 0 明文取 keystream 块。
        let zero16 = Array<Byte>(16, repeat: 0)
        let ksCtr = AesCtr(key, iv)
        let ks = ksCtr.process(zero16)
        let expectedFirstBlock = AES256ECB.encryptBlock(iv, key)
        for (i in 0..16) {
            if (UInt8(ks[i]) != UInt8(expectedFirstBlock[i])) {
                throw Exception("Obfuscation selfCheck FAIL: keystream block0 != AES256ECB(iv) at ${i}")
            }
        }

        // ===== 3. CTR 流连续性：一次 process(32B) == 两次 process(16B) 拼接 =====
        let in32 = Array<Byte>(32, repeat: 0)
        for (i in 0..32) {
            in32[i] = UInt8((i * 13 + 1) % 256)
        }
        let single = AesCtr(key, iv)
        let oneShot = single.process(in32)
        let split = AesCtr(key, iv)
        let part1 = split.process(ByteUtils.slice(in32, 0, 7))   // 非对齐切点（跨块内）
        let part2 = split.process(ByteUtils.slice(in32, 7, 32))
        for (i in 0..7) {
            if (oneShot[i] != part1[i]) {
                throw Exception("Obfuscation selfCheck FAIL: stream continuity part1 mismatch at ${i}")
            }
        }
        for (i in 0..(32 - 7)) {
            if (oneShot[7 + i] != part2[i]) {
                throw Exception("Obfuscation selfCheck FAIL: stream continuity part2 mismatch at ${i}")
            }
        }

        // ===== 4. init 明文约束过滤 =====
        // 4a. 首字节 0xef 必须被拒
        let badEf = Array<Byte>(64, repeat: 0)
        for (i in 0..64) { badEf[i] = UInt8(i + 1) }
        badEf[0] = 0xefu8
        if (plaintextInitValid(badEf)) {
            throw Exception("Obfuscation selfCheck FAIL: init[0]=0xef should be rejected")
        }
        // 4b. 禁止前缀 "POST"（小端 0x54534f50 → 字节 0x50 0x4f 0x53 0x54）必须被拒
        let badPost = Array<Byte>(64, repeat: 0)
        for (i in 0..64) { badPost[i] = UInt8(i + 1) }
        badPost[0] = 0x50u8
        badPost[1] = 0x4fu8
        badPost[2] = 0x53u8
        badPost[3] = 0x54u8
        if (plaintextInitValid(badPost)) {
            throw Exception("Obfuscation selfCheck FAIL: 'POST' prefix should be rejected")
        }
        // 4c. init[4:8] 全 0 必须被拒
        let badZero = Array<Byte>(64, repeat: 0)
        for (i in 0..64) { badZero[i] = UInt8(i + 1) }
        badZero[0] = 0x01u8  // 确保前缀合法
        badZero[4] = 0u8
        badZero[5] = 0u8
        badZero[6] = 0u8
        badZero[7] = 0u8
        if (plaintextInitValid(badZero)) {
            throw Exception("Obfuscation selfCheck FAIL: init[4:8]=0 should be rejected")
        }
        // 4d. 一个满足全部约束的 init 必须被接受
        let goodInit = Array<Byte>(64, repeat: 0)
        for (i in 0..64) { goodInit[i] = UInt8((i * 5 + 17) % 256) }
        goodInit[0] = 0x11u8  // != 0xef，前缀非禁止
        goodInit[1] = 0x22u8
        goodInit[2] = 0x33u8
        goodInit[3] = 0x44u8
        goodInit[4] = 0x55u8  // init[4:8] 非 0
        if (!plaintextInitValid(goodInit)) {
            throw Exception("Obfuscation selfCheck FAIL: valid init should be accepted")
        }

        // ===== 5. 握手布局：wire 前 56B == 明文 init[0:56]，尾 8B == 加密结果[56:64] =====
        let detInit = Array<Byte>(64, repeat: 0)
        for (i in 0..64) { detInit[i] = UInt8((i * 3 + 9) % 256) }
        detInit[0] = 0x11u8  // 合法首字节（仅用于布局验证）
        let obf = MTProtoObfuscation(ObfuscationTag.INTERMEDIATE)
        let wire = obf.handshakeBytes(randomInit: detInit)
        if (wire.size != 64) {
            throw Exception("Obfuscation selfCheck FAIL: handshake wire size ${wire.size} != 64")
        }
        // tag 写入后的明文 init 前 56B
        let taggedInit = ByteUtils.copy(detInit)
        writeU32LE(taggedInit, 56, ObfuscationTag.INTERMEDIATE)
        taggedInit[60] = 0u8
        taggedInit[61] = 0u8
        for (i in 0..56) {
            if (UInt8(wire[i]) != UInt8(taggedInit[i])) {
                throw Exception("Obfuscation selfCheck FAIL: wire[0:56] != plaintext init at ${i}")
            }
        }
        // 尾 8B：用独立发送 CTR 复算 encrypted[56:64]
        let vSendKey = ByteUtils.slice(taggedInit, 8, 40)
        let vSendIv = ByteUtils.slice(taggedInit, 40, 56)
        let vCtr = AesCtr(vSendKey, vSendIv)
        let vEnc = vCtr.process(taggedInit)
        for (i in 0..8) {
            if (UInt8(wire[56 + i]) != UInt8(vEnc[56 + i])) {
                throw Exception("Obfuscation selfCheck FAIL: wire[56:64] != encrypted tag bytes at ${i}")
            }
        }

        // ===== 6. 端到端：发送侧 encryptOutgoing 经接收侧反向 CTR 解密复原 =====
        // 同一 init 下，A 的发送流 == B 的接收流（A.send key/iv == B.recv key/iv，因 reversed 对称）。
        let aInit = ByteUtils.copy(detInit)
        let bInit = ByteUtils.copy(detInit)
        let sideA = MTProtoObfuscation(ObfuscationTag.INTERMEDIATE)
        let sideB = MTProtoObfuscation(ObfuscationTag.INTERMEDIATE)
        sideA.handshakeBytes(randomInit: aInit)
        sideB.handshakeBytes(randomInit: bInit)
        // A 握手已推进 A.outgoing 整 64B；B 的 incoming 是「reversed」流，
        // 与 A.outgoing 用的 key/iv 不同（A.send vs B.recv），不能直接互通。
        // 此处验证「同侧」往返：A.encryptOutgoing 的密文用一个与 A.outgoing 同 key/iv 的全新 CTR 解出。
        let aSendKey = ByteUtils.slice(taggedInit, 8, 40)
        let aSendIv = ByteUtils.slice(taggedInit, 40, 56)
        // 复刻 A.outgoing 状态：先吃掉 64B init，再处理 payload
        let mirror = AesCtr(aSendKey, aSendIv)
        mirror.process(taggedInit)  // 对齐 handshake 已消费的 64B
        let payload = Array<Byte>(40, repeat: 0)
        for (i in 0..40) { payload[i] = UInt8((i * 11 + 5) % 256) }
        let outCipher = sideA.encryptOutgoing(payload)
        let mirrorPlain = mirror.process(outCipher)
        for (i in 0..40) {
            if (UInt8(mirrorPlain[i]) != UInt8(payload[i])) {
                throw Exception("Obfuscation selfCheck FAIL: outgoing roundtrip mismatch at ${i}")
            }
        }

        // ===== 7. 未握手即 encrypt 必须抛错（失败安全） =====
        let bare = MTProtoObfuscation(ObfuscationTag.ABRIDGED)
        var threw = false
        try {
            bare.encryptOutgoing(Array<Byte>(4, repeat: 0))
        } catch (_e: Exception) {
            threw = true
        }
        if (!threw) {
            throw Exception("Obfuscation selfCheck FAIL: encryptOutgoing before handshake should throw")
        }

        Hilog.info(0, "CjTelegram", "[Obfuscation] selfCheck PASS: CTR keystream/roundtrip/continuity, init constraints, handshake layout verified")
    }
}
