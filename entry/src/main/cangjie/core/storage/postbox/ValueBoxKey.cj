package ohos_app_cangjie_entry.core.storage.postbox

/**
 * 固定长度大端字节键 —— Postbox/RDB 持久层的范围扫描键底座。
 *
 * iOS 标尺：Telegram-iOS/submodules/Postbox/Sources/ValueBoxKey.swift。
 *
 * 设计要点（与 iOS 严格对齐）：
 *   - 键是「固定长度」的裸字节数组，长度在构造时确定、之后不变。
 *   - 多字节整数一律按「大端」(big-endian) 写入：高位字节存放在低地址
 *     (byte[offset] == 最高有效字节)。这样「字节字典序」恰好等于「逻辑数值序」，
 *     使得底层 RDB BLOB range 扫描（按字节比较 key）能得到正确的逻辑区间。
 *   - 比较语义等价 iOS 的 `mdb_cmp_memn`(memcmp + 短者为小)，供 range 边界排序。
 *   - successor / predecessor 用于从一个键生成 range 的上界 / 下界。
 *
 * iOS 版基于 malloc 裸内存 + memcpy；仓颉版用受管 Array<Byte>（Byte == UInt8）替代，
 * 语义对齐而无裸指针与手动释放。所有多字节读写都经 Int64 中间值 + `& 0xFF` 掩码后
 * `UInt8(...)`，避免 `Int32 << 24` / `Int64 << 56` 触发 OverflowException
 * （沿用 core.mtproto.ByteUtils 已验证的范式）。
 *
 * 注意：本类不复用 ByteUtils 的 int↔bytes —— 那是小端 (little-endian)；键必须大端。
 */
public class ValueBoxKey {
    // 键的字节存储；长度在构造时固定，逻辑上不可变长。
    private let memory: Array<Byte>

    /**
     * 构造一个长度为 length、全 0 的键（对应 iOS `init(length:)`）。
     */
    public init(length!: Int64) {
        if (length < 0) {
            throw ValueBoxKeyException("ValueBoxKey length must be >= 0: ${length}")
        }
        this.memory = Array<Byte>(length, repeat: 0)
    }

    /**
     * 由现成字节数组构造键（拷贝一份，长度即数组长度）。
     * 对应 iOS `init(_ buffer: MemoryBuffer)` —— 这里直接接收字节副本。
     */
    public init(bytes!: Array<Byte>) {
        let copy = Array<Byte>(bytes.size, repeat: 0)
        for (i in 0..bytes.size) {
            copy[i] = bytes[i]
        }
        this.memory = copy
    }

    /**
     * 键长度（字节数，对应 iOS `length`）。
     */
    public func length(): Int64 {
        return this.memory.size
    }

    /**
     * 取键底层字节的只读副本。
     */
    public func toBytes(): Array<Byte> {
        let result = Array<Byte>(this.memory.size, repeat: 0)
        for (i in 0..this.memory.size) {
            result[i] = this.memory[i]
        }
        return result
    }

    /**
     * 构造一个携带相同字节的 MemoryBuffer 视图（对应 iOS `toMemoryBuffer()`）。
     * 借用 WriteBuffer 承载字节（与 postbox 包内其它编解码路径一致）。
     */
    public func toMemoryBuffer(): WriteBuffer {
        let buffer = WriteBuffer(initialCapacity: this.memory.size)
        buffer.writeBytes(toBytes())
        return buffer
    }

    // ---- 边界校验 ----

    private func checkRange(offset: Int64, count: Int64): Unit {
        if (offset < 0 || count < 0 || offset + count > this.memory.size) {
            throw ValueBoxKeyException(
                "ValueBoxKey out of range: offset=${offset} count=${count} length=${this.memory.size}")
        }
    }

    // ---- 大端写入 ----

    /**
     * 在 offset 处写入一段原始字节（对应 iOS `setData`/`setBytes`）。
     */
    public func setData(offset: Int64, value: Array<Byte>): Unit {
        checkRange(offset, value.size)
        for (i in 0..value.size) {
            this.memory[offset + i] = value[i]
        }
    }

    /**
     * 在 offset 处写入一个无符号字节（对应 iOS `setUInt8`）。
     */
    public func setUInt8(offset: Int64, value: UInt8): Unit {
        checkRange(offset, 1)
        this.memory[offset] = value
    }

    /**
     * 在 offset 处写入一个有符号字节（对应 iOS `setInt8`）。
     * Int8 与 UInt8 共享同一位模式，按位重解释存储。
     */
    public func setInt8(offset: Int64, value: Int8): Unit {
        checkRange(offset, 1)
        // Int8 -> UInt8 位模式重解释（-128..-1 映射到 128..255）
        let v = Int64(value) & 0xFF
        this.memory[offset] = UInt8(v)
    }

    /**
     * 在 offset 处大端写入一个 Int32（4 字节，高位字节在前）。
     * 对应 iOS `setInt32`（其用 `Int32(bigEndian:)` + memcpy）。
     */
    public func setInt32(offset: Int64, value: Int32): Unit {
        checkRange(offset, 4)
        // 经 Int64 中间值避免 Int32 移位溢出
        let v = Int64(value) & 0xFFFFFFFF
        this.memory[offset + 0] = UInt8((v >> 24) & 0xFF)
        this.memory[offset + 1] = UInt8((v >> 16) & 0xFF)
        this.memory[offset + 2] = UInt8((v >> 8) & 0xFF)
        this.memory[offset + 3] = UInt8(v & 0xFF)
    }

    /**
     * 在 offset 处大端写入一个 UInt32（4 字节，高位字节在前）。
     * 对应 iOS `setUInt32`。
     */
    public func setUInt32(offset: Int64, value: UInt32): Unit {
        checkRange(offset, 4)
        let v = Int64(value) & 0xFFFFFFFF
        this.memory[offset + 0] = UInt8((v >> 24) & 0xFF)
        this.memory[offset + 1] = UInt8((v >> 16) & 0xFF)
        this.memory[offset + 2] = UInt8((v >> 8) & 0xFF)
        this.memory[offset + 3] = UInt8(v & 0xFF)
    }

    /**
     * 在 offset 处大端写入一个 Int64（8 字节，高位字节在前）。
     * 对应 iOS `setInt64`（其用 `Int64(bigEndian:)` + memcpy）。
     *
     * 关键：byte[offset] 必须是 value 的最高有效字节（bits 56..63）。
     * 用「逻辑右移」语义提取字节 —— 先 `& 掩码` 限制为正值，再移位，
     * 避免有符号 Int64 算术右移把符号位填进来污染高位字节。
     */
    public func setInt64(offset: Int64, value: Int64): Unit {
        checkRange(offset, 8)
        // 最高字节单独处理（>> 56 后只保留低 8 位；先掩掉符号扩展影响）
        this.memory[offset + 0] = UInt8(((value >> 56) & 0xFF))
        this.memory[offset + 1] = UInt8(((value >> 48) & 0xFF))
        this.memory[offset + 2] = UInt8(((value >> 40) & 0xFF))
        this.memory[offset + 3] = UInt8(((value >> 32) & 0xFF))
        this.memory[offset + 4] = UInt8(((value >> 24) & 0xFF))
        this.memory[offset + 5] = UInt8(((value >> 16) & 0xFF))
        this.memory[offset + 6] = UInt8(((value >> 8) & 0xFF))
        this.memory[offset + 7] = UInt8((value & 0xFF))
    }

    // ---- 大端读取（与写入对称） ----

    /**
     * 从 offset 处读取一段原始字节（对应 iOS `getData`）。
     */
    public func getData(offset: Int64, count: Int64): Array<Byte> {
        checkRange(offset, count)
        let result = Array<Byte>(count, repeat: 0)
        for (i in 0..count) {
            result[i] = this.memory[offset + i]
        }
        return result
    }

    /**
     * 从 offset 处读取一个无符号字节（对应 iOS `getUInt8`）。
     */
    public func getUInt8(offset: Int64): UInt8 {
        checkRange(offset, 1)
        return this.memory[offset]
    }

    /**
     * 从 offset 处读取一个有符号字节（对应 iOS `getInt8`）。
     */
    public func getInt8(offset: Int64): Int8 {
        checkRange(offset, 1)
        let u = Int64(this.memory[offset])
        // UInt8 -> Int8 位模式重解释（128..255 映射回 -128..-1）
        let signed = if (u >= 128) { u - 256 } else { u }
        return Int8(signed)
    }

    /**
     * 从 offset 处大端读取一个 Int32（对应 iOS `getInt32`）。
     * 经 Int64 中间值组装，再按需折回有符号 Int32（避免溢出，沿用 ByteUtils 范式）。
     */
    public func getInt32(offset: Int64): Int32 {
        checkRange(offset, 4)
        let b0 = Int64(this.memory[offset + 0])
        let b1 = Int64(this.memory[offset + 1])
        let b2 = Int64(this.memory[offset + 2])
        let b3 = Int64(this.memory[offset + 3])
        let unsigned = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        if (unsigned > 0x7FFFFFFF) {
            return Int32(unsigned - 0x100000000)
        }
        return Int32(unsigned)
    }

    /**
     * 从 offset 处大端读取一个 UInt32（对应 iOS `getUInt32`）。
     */
    public func getUInt32(offset: Int64): UInt32 {
        checkRange(offset, 4)
        let b0 = UInt32(this.memory[offset + 0])
        let b1 = UInt32(this.memory[offset + 1])
        let b2 = UInt32(this.memory[offset + 2])
        let b3 = UInt32(this.memory[offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    /**
     * 从 offset 处大端读取一个 Int64（对应 iOS `getInt64`）。
     * 高 4 字节经有符号 Int32、低 4 字节经 UInt32 组装，避免 `<< 56` 溢出
     * （沿用 ByteUtils.bytesToInt64 的分段范式，但这里是大端取字节）。
     */
    public func getInt64(offset: Int64): Int64 {
        checkRange(offset, 8)
        // 大端：前 4 字节是高位
        let hi = getInt32(offset)         // 高 32 位（有符号）
        let lo = getUInt32(offset + 4)    // 低 32 位（无符号）
        return (Int64(hi) << 32) | Int64(lo)
    }

    // ---- 键派生 ----

    /**
     * 取前 length 个字节构成的新键（对应 iOS `prefix(_:)`）。
     */
    public func prefix(length: Int64): ValueBoxKey {
        if (length < 0 || length > this.memory.size) {
            throw ValueBoxKeyException(
                "ValueBoxKey.prefix length out of range: ${length} (length=${this.memory.size})")
        }
        let key = ValueBoxKey(length: length)
        for (i in 0..length) {
            key.memory[i] = this.memory[i]
        }
        return key
    }

    /**
     * 判断本键是否为 other 的前缀（对应 iOS `isPrefix(to:)`）。
     * 空键是任意键的前缀；本键更长则不可能是前缀。
     */
    public func isPrefix(to!: ValueBoxKey): Bool {
        let selfLen = this.memory.size
        if (selfLen == 0) {
            return true
        }
        if (selfLen > to.memory.size) {
            return false
        }
        for (i in 0..selfLen) {
            if (this.memory[i] != to.memory[i]) {
                return false
            }
        }
        return true
    }

    /**
     * 逐字节反转（对应 iOS `reversed`）。
     */
    public func reversed(): ValueBoxKey {
        let n = this.memory.size
        let key = ValueBoxKey(length: n)
        for (i in 0..n) {
            key.memory[i] = this.memory[n - 1 - i]
        }
        return key
    }

    /**
     * 生成「后继键」（对应 iOS `successor`）：等长键，按大端把数值 +1（末字节进位）。
     * 用于把「>= key 的前缀扫描」转成「[key, key.successor) 的范围扫描」上界。
     *
     * 算法：从末字节往前找第一个非 0xFF 的字节 +1 即停；途经的 0xFF 归 0（进位）。
     * 全 0xFF 时回绕为全 0（与 iOS 一致 —— 它也只在末字节回绕，不扩长）。
     */
    public func successor(): ValueBoxKey {
        let n = this.memory.size
        let key = ValueBoxKey(length: n)
        for (i in 0..n) {
            key.memory[i] = this.memory[i]
        }
        var i = n - 1
        while (i >= 0) {
            let byte = key.memory[i]
            if (byte != UInt8(0xFF)) {
                key.memory[i] = byte + UInt8(1)
                break
            } else {
                key.memory[i] = UInt8(0)
            }
            i -= 1
        }
        return key
    }

    /**
     * 生成「前驱键」（对应 iOS `predecessor`）：等长键按大端数值 -1（末字节借位）。
     * 若首字节也需借位（即键形如 0x00...），iOS 会返回截短一字节的键；这里对齐。
     */
    public func predecessor(): ValueBoxKey {
        let n = this.memory.size
        let key = ValueBoxKey(length: n)
        for (i in 0..n) {
            key.memory[i] = this.memory[i]
        }
        var i = n - 1
        while (i >= 0) {
            let byte = key.memory[i]
            if (byte != UInt8(0x00)) {
                key.memory[i] = byte - UInt8(1)
                break
            } else {
                if (i == 0) {
                    // 首字节为 0 且需借位：返回截短一字节的键（对齐 iOS）
                    if (n <= 1) {
                        // 长度 1 的全 0 键无更小前驱，返回长度 0 键
                        return ValueBoxKey(length: 0)
                    }
                    let shorter = ValueBoxKey(length: n - 1)
                    for (j in 0..(n - 1)) {
                        shorter.memory[j] = this.memory[j]
                    }
                    return shorter
                } else {
                    key.memory[i] = UInt8(0xFF)
                }
            }
            i -= 1
        }
        return key
    }

    /**
     * 拼接两个键（对应 iOS `+`），左键字节在前。
     */
    public func append(other: ValueBoxKey): ValueBoxKey {
        let n = this.memory.size
        let m = other.memory.size
        let key = ValueBoxKey(length: n + m)
        for (i in 0..n) {
            key.memory[i] = this.memory[i]
        }
        for (i in 0..m) {
            key.memory[n + i] = other.memory[i]
        }
        return key
    }

    public operator func +(right: ValueBoxKey): ValueBoxKey {
        return append(right)
    }

    // ---- 字节序比较（等价 iOS `<` / `mdb_cmp_memn` / `==`） ----

    /**
     * 字节字典序比较（等价 iOS `mdb_cmp_memn`）：
     *   - 逐字节 memcmp；首个不同字节决定大小（按无符号字节比较）。
     *   - 公共前缀相同时，较短键判为更小。
     * 返回 <0 / 0 / >0。
     */
    public func compareTo(other: ValueBoxKey): Int64 {
        let aLen = this.memory.size
        let bLen = other.memory.size
        let minLen = if (aLen < bLen) { aLen } else { bLen }
        for (i in 0..minLen) {
            // Byte 即 UInt8，已是无符号比较
            let av = this.memory[i]
            let bv = other.memory[i]
            if (av < bv) {
                return -1
            } else if (av > bv) {
                return 1
            }
        }
        // 公共前缀相同：短者为小
        if (aLen < bLen) {
            return -1
        } else if (aLen > bLen) {
            return 1
        }
        return 0
    }

    public func equalsKey(other: ValueBoxKey): Bool {
        return compareTo(other) == 0
    }

    public operator func ==(right: ValueBoxKey): Bool {
        return compareTo(right) == 0
    }

    public operator func !=(right: ValueBoxKey): Bool {
        return compareTo(right) != 0
    }

    public operator func <(right: ValueBoxKey): Bool {
        return compareTo(right) < 0
    }

    public operator func <=(right: ValueBoxKey): Bool {
        return compareTo(right) <= 0
    }

    public operator func >(right: ValueBoxKey): Bool {
        return compareTo(right) > 0
    }

    public operator func >=(right: ValueBoxKey): Bool {
        return compareTo(right) >= 0
    }

    /**
     * 十六进制串表示（对应 iOS `description`），调试用。
     */
    public func description(): String {
        var s = ""
        for (i in 0..this.memory.size) {
            let b = this.memory[i]
            let hi = b >> 4
            let lo = b & UInt8(0x0F)
            s += hexChar(hi)
            s += hexChar(lo)
        }
        return s
    }

    private static func hexChar(nibble: UInt8): String {
        if (nibble < UInt8(10)) {
            return String(Rune(UInt32(nibble) + 48))      // '0'
        } else {
            return String(Rune(UInt32(nibble) - 10 + 97)) // 'a'
        }
    }

    /**
     * 自检：验证大端写入 / 往返一致 / successor / prefix / 比较 的正确性。
     * 返回 true 表示全部断言通过；任一不符返回 false。
     * 非常驻逻辑，供测试 / 启动诊断显式调用，不在 app 主流程自动运行。
     */
    public static func selfCheck(): Bool {
        // ① 大端写入：setInt64(0x0102030405060708) 后 byte[0] 应为 0x01（最高字节在前）
        let k = ValueBoxKey(length: 8)
        let v: Int64 = 0x0102030405060708
        k.setInt64(0, v)
        if (k.getUInt8(0) != UInt8(0x01)) { return false }
        if (k.getUInt8(1) != UInt8(0x02)) { return false }
        if (k.getUInt8(7) != UInt8(0x08)) { return false }
        // ② 往返一致
        if (k.getInt64(0) != v) { return false }

        // 负值与高位 0xFF 也要往返一致（验证逻辑右移取字节、不被符号扩展污染）
        let kn = ValueBoxKey(length: 8)
        let neg: Int64 = -2  // 0xFFFFFFFFFFFFFFFE
        kn.setInt64(0, neg)
        if (kn.getUInt8(0) != UInt8(0xFF)) { return false }
        if (kn.getInt64(0) != neg) { return false }

        // Int32 / UInt32 大端往返
        let k32 = ValueBoxKey(length: 4)
        k32.setInt32(0, Int32(0x0A0B0C0D))
        if (k32.getUInt8(0) != UInt8(0x0A)) { return false }
        if (k32.getInt32(0) != Int32(0x0A0B0C0D)) { return false }
        let k32n = ValueBoxKey(length: 4)
        k32n.setInt32(0, Int32(-1))
        if (k32n.getInt32(0) != Int32(-1)) { return false }

        // Int8 往返（含负值位模式重解释）
        let k8 = ValueBoxKey(length: 1)
        k8.setInt8(0, Int8(-1))
        if (k8.getUInt8(0) != UInt8(0xFF)) { return false }
        if (k8.getInt8(0) != Int8(-1)) { return false }

        // ③ successor 比原键大；prefix 是其前缀
        let succ = k.successor()
        if (!(k < succ)) { return false }
        if (!(succ > k)) { return false }
        // 末字节 0x08 -> 0x09，无进位
        if (succ.getUInt8(7) != UInt8(0x09)) { return false }

        let pre = k.prefix(4)
        if (!pre.isPrefix(to: k)) { return false }
        if (pre.length() != 4) { return false }

        // 进位：末字节 0xFF 的 successor 应向前进位
        let kff = ValueBoxKey(length: 2)
        kff.setUInt8(0, UInt8(0x01))
        kff.setUInt8(1, UInt8(0xFF))
        let kffSucc = kff.successor()  // 0x01FF -> 0x0200
        if (kffSucc.getUInt8(0) != UInt8(0x02)) { return false }
        if (kffSucc.getUInt8(1) != UInt8(0x00)) { return false }
        if (!(kff < kffSucc)) { return false }

        // 比较：字节序与逻辑序一致（大端保证），且短者为小
        let a = ValueBoxKey(length: 2)
        a.setUInt8(0, UInt8(0x00)); a.setUInt8(1, UInt8(0xFF))  // 0x00FF
        let b = ValueBoxKey(length: 2)
        b.setUInt8(0, UInt8(0x01)); b.setUInt8(1, UInt8(0x00))  // 0x0100
        if (!(a < b)) { return false }  // 255 < 256

        let shortKey = ValueBoxKey(length: 1)
        shortKey.setUInt8(0, UInt8(0x01))
        let longKey = ValueBoxKey(length: 2)
        longKey.setUInt8(0, UInt8(0x01)); longKey.setUInt8(1, UInt8(0x00))
        if (!(shortKey < longKey)) { return false }  // 公共前缀同，短者为小

        // predecessor：与 successor 互逆方向，且比原键小
        let predBase = ValueBoxKey(length: 2)
        predBase.setUInt8(0, UInt8(0x02)); predBase.setUInt8(1, UInt8(0x00))  // 0x0200
        let pred = predBase.predecessor()  // -> 0x01FF
        if (pred.getUInt8(0) != UInt8(0x01)) { return false }
        if (pred.getUInt8(1) != UInt8(0xFF)) { return false }
        if (!(pred < predBase)) { return false }

        return true
    }
}

/**
 * ValueBoxKey 越界 / 非法长度异常。
 */
public class ValueBoxKeyException <: Exception {
    public init(message: String) {
        super(message)
    }
}
