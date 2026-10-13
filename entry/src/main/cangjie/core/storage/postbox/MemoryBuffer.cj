package ohos_app_cangjie_entry.core.storage.postbox

/**
 * 字节缓冲底座 —— Postbox 二进制编解码层的底层内存缓冲。
 *
 * iOS 标尺：Telegram-iOS/submodules/Postbox/Sources/Coding.swift 中的
 *   MemoryBuffer / WriteBuffer / ReadBuffer。
 *
 * iOS 版基于 UnsafeMutableRawPointer + malloc/realloc 手动管理裸内存；
 * 仓颉版用受管的 Array<Byte>（Byte == UInt8）替代裸指针，语义对齐：
 *   - WriteBuffer：顺序追加写 + 超容量时自动扩容（geometric + 余量）。
 *   - ReadBuffer：顺序读 + 越界保护（越界抛异常而非读到脏内存）。
 *
 * 本层只关心"原始字节流"，不理解 ValueType/key —— 那是 PostboxCoding.cj 的职责。
 */

/**
 * 缓冲越界异常 —— ReadBuffer 读取越过 length 时抛出。
 *
 * iOS 版用裸指针读越界时是未定义行为；仓颉版改为显式可捕获异常，
 * 与仓颉"逻辑错误用 Exception 子类"惯例一致（见 cangjie 异常文档）。
 */
public class BufferReadException <: Exception {
    public init(message: String) {
        super(message)
    }
}

/**
 * 顺序写字节缓冲。
 *
 * 对应 iOS WriteBuffer：内部 memory(裸指针) + capacity + offset，
 * write 时 offset+length 超过 capacity 则 realloc 扩容。
 * 仓颉版用 Array<Byte> 承载，扩容时分配新数组并逐字节拷贝旧内容。
 */
public class WriteBuffer {
    private var storage: Array<Byte>
    private var capacity: Int64
    // offset 即已写入长度（iOS WriteBuffer.offset，写完后等于 length）
    private var offset: Int64 = 0

    public init() {
        this.capacity = 32
        this.storage = Array<Byte>(32, repeat: 0)
    }

    public init(initialCapacity!: Int64) {
        let cap = if (initialCapacity > 0) { initialCapacity } else { 32 }
        this.capacity = cap
        this.storage = Array<Byte>(cap, repeat: 0)
    }

    /**
     * 确保还能再写入 additional 个字节，不足则扩容。
     *
     * 对应 iOS WriteBuffer.write 中的 `self.capacity = self.offset + length + 256`，
     * 这里同时保留几何增长（*2）以摊还多次小写入的成本。
     */
    private func ensureCapacity(additional: Int64): Unit {
        let needed = this.offset + additional
        if (needed <= this.capacity) {
            return
        }
        var newCapacity = this.capacity * 2
        // 对齐 iOS 的 +256 余量，避免逐字节写时反复扩容
        let minCapacity = needed + 256
        if (newCapacity < minCapacity) {
            newCapacity = minCapacity
        }
        let newStorage = Array<Byte>(newCapacity, repeat: 0)
        for (i in 0..this.offset) {
            newStorage[i] = this.storage[i]
        }
        this.storage = newStorage
        this.capacity = newCapacity
    }

    /**
     * 追加写入一个字节。
     */
    public func writeByte(value: Byte): Unit {
        ensureCapacity(1)
        this.storage[this.offset] = value
        this.offset++
    }

    /**
     * 追加写入整段原始字节（对应 iOS write(_:length:) 的 memcpy）。
     */
    public func writeBytes(bytes: Array<Byte>): Unit {
        let length = bytes.size
        if (length == 0) {
            return
        }
        ensureCapacity(length)
        for (i in 0..length) {
            this.storage[this.offset] = bytes[i]
            this.offset++
        }
    }

    /**
     * 当前已写入字节数（== iOS WriteBuffer.offset）。
     */
    public func length(): Int64 {
        return this.offset
    }

    /**
     * 取出已写入的字节副本（对应 iOS makeData()，截取 [0, offset)）。
     */
    public func makeBytes(): Array<Byte> {
        let result = Array<Byte>(this.offset, repeat: 0)
        for (i in 0..this.offset) {
            result[i] = this.storage[i]
        }
        return result
    }

    /**
     * 以当前内容构造一个 ReadBuffer（对应 iOS makeReadBufferAndReset 的读侧产物，
     * 但这里不复用底层内存、不重置写缓冲，语义更简单安全）。
     */
    public func makeReadBuffer(): ReadBuffer {
        return ReadBuffer(makeBytes())
    }

    /**
     * 重置写指针（对应 iOS reset()）。底层数组保留以复用容量。
     */
    public func reset(): Unit {
        this.offset = 0
    }
}

/**
 * 顺序读字节缓冲（带越界保护）。
 *
 * 对应 iOS ReadBuffer：内部 memory + length + offset，read 时 memcpy 后推进 offset。
 * 仓颉版基于 Array<Byte>，每次读取前校验 offset+length <= length()，越界抛 BufferReadException。
 */
public class ReadBuffer {
    private let storage: Array<Byte>
    private var offset: Int64 = 0

    public init(data: Array<Byte>) {
        this.storage = data
    }

    private func checkBounds(need: Int64): Unit {
        if (this.offset + need > this.storage.size) {
            throw BufferReadException(
                "ReadBuffer underflow: offset=${this.offset} need=${need} length=${this.storage.size}")
        }
    }

    /**
     * 读取一个字节并推进。
     */
    public func readByte(): Byte {
        checkBounds(1)
        let value = this.storage[this.offset]
        this.offset++
        return value
    }

    /**
     * 读取 length 个原始字节（对应 iOS read(_:length:)）。
     */
    public func readBytes(length: Int64): Array<Byte> {
        if (length < 0) {
            throw BufferReadException("ReadBuffer negative length: ${length}")
        }
        if (length == 0) {
            return Array<Byte>(0, repeat: 0)
        }
        checkBounds(length)
        let result = Array<Byte>(length, repeat: 0)
        for (i in 0..length) {
            result[i] = this.storage[this.offset]
            this.offset++
        }
        return result
    }

    /**
     * 跳过 length 个字节（对应 iOS skip(_:)）。
     */
    public func skip(length: Int64): Unit {
        if (length < 0) {
            throw BufferReadException("ReadBuffer negative skip: ${length}")
        }
        checkBounds(length)
        this.offset += length
    }

    /**
     * 当前读指针位置。
     */
    public func position(): Int64 {
        return this.offset
    }

    /**
     * 设置读指针位置（对应 positionOnKey 算法回绕到任意 key 起点的能力）。
     */
    public func setPosition(value: Int64): Unit {
        if (value < 0 || value > this.storage.size) {
            throw BufferReadException("ReadBuffer invalid position: ${value} length=${this.storage.size}")
        }
        this.offset = value
    }

    /**
     * 缓冲总长度（对应 iOS length）。
     */
    public func length(): Int64 {
        return this.storage.size
    }

    /**
     * 剩余可读字节数。
     */
    public func remaining(): Int64 {
        return this.storage.size - this.offset
    }

    /**
     * 重置读指针到 0（对应 iOS reset()）。
     */
    public func reset(): Unit {
        this.offset = 0
    }
}
