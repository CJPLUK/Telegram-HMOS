package ohos_app_cangjie_entry.core.mtproto

import std.collection.ArrayList

/**
 * TL 构造函数 ID 常量
 * 
 * 对应 TelegramHarmony 的 TLSerialization.ets TLConstructors
 */
public class TLConstructors {
    public static let VECTOR: UInt32 = 0x1cb5c415
    public static let BOOL_TRUE: UInt32 = 0x997275b5
    public static let BOOL_FALSE: UInt32 = 0xbc799737
    public static let NULL_VALUE: UInt32 = 0x56730bcc

    // RPC
    public static let RPC_RESULT: UInt32 = 0xf35c6d01
    public static let RPC_ERROR: UInt32 = 0x2144ca19
    public static let RPC_DROP_ANSWER: UInt32 = 0x58e4a740
    // rpc_answer_dropped_running#cd78e586 — answer is being dropped (was running when cancelled)
    public static let RPC_ANSWER_DROPPED_RUNNING: UInt32 = 0xcd78e586
    // rpc_answer_unknown#5e2ad36e — server doesn't know about the req_msg_id
    public static let RPC_ANSWER_UNKNOWN: UInt32 = 0x5e2ad36e
    // rpc_answer_dropped#a43ad8b7 — answer was already processed and dropped
    public static let RPC_ANSWER_DROPPED: UInt32 = 0xa43ad8b7
    public static let MSG_CONTAINER: UInt32 = 0x73f1f8dc
    public static let MSG_COPY: UInt32 = 0xe06046b2
    public static let GZIP_PACKED: UInt32 = 0x3072cfa1

    // Messages
    public static let MSGS_ACK: UInt32 = 0x62d6b459
    public static let BAD_MSG_NOTIFICATION: UInt32 = 0xa7eff811
    public static let BAD_SERVER_SALT: UInt32 = 0xedab447b
    public static let MSGS_STATE_REQ: UInt32 = 0xda69fb52
    public static let MSGS_STATE_INFO: UInt32 = 0x04deb57d
    public static let MSGS_ALL_INFO: UInt32 = 0x8cc0d131
    public static let MSG_DETAILED_INFO: UInt32 = 0x276d3ec6
    public static let MSG_NEW_DETAILED_INFO: UInt32 = 0x809db6df
    public static let MSG_RESEND_REQ: UInt32 = 0x7d861a08
    public static let NEW_SESSION_CREATED: UInt32 = 0x9ec20908
    public static let DESTROY_SESSION: UInt32 = 0xe7512126
    public static let DESTROY_SESSION_OK: UInt32 = 0xe22045fc
    public static let DESTROY_SESSION_NONE: UInt32 = 0x62d350c9

    // Pong
    public static let PONG: UInt32 = 0x347773c5
    public static let PING: UInt32 = 0x7abe77ec
    public static let PING_DELAY_DISCONNECT: UInt32 = 0xf3427b8c

    // Future salts
    public static let FUTURE_SALT: UInt32 = 0x0949d9dc
    public static let FUTURE_SALTS: UInt32 = 0xae500895
    public static let GET_FUTURE_SALTS: UInt32 = 0xb921bd04
}

/**
 * TL 序列化器
 * 
 * 对应 TelegramHarmony 的 TLSerialization.ets TLSerializer
 * 将 TL 类型写入字节缓冲区（小端序）
 */
public class TLSerializer {
    private var buffer: Array<Byte>
    private var offset: Int64 = 0
    private var capacity: Int64

    public init(initialCapacity!: Int64 = 2048) {
        this.capacity = initialCapacity
        this.buffer = Array<Byte>(initialCapacity, repeat: 0)
    }

    /**
     * 确保有足够的容量
     */
    private func ensureCapacity(additional: Int64) {
        if (this.offset + additional > this.capacity) {
            let needed = this.offset + additional
            var newCapacity = this.capacity * 2
            if (newCapacity < needed) {
                newCapacity = needed
            }
            let newBuffer = Array<Byte>(newCapacity, repeat: 0)
            for (i in 0..this.offset) {
                newBuffer[i] = this.buffer[i]
            }
            this.buffer = newBuffer
            this.capacity = newCapacity
        }
    }

    /**
     * 写入原始字节
     */
    public func writeRawBytes(bytes: Array<Byte>) {
        ensureCapacity(bytes.size)
        for (i in 0..bytes.size) {
            this.buffer[this.offset] = bytes[i]
            this.offset++
        }
    }

    /**
     * 写入 int32（小端序）
     */
    public func writeInt32(value: Int32) {
        ensureCapacity(4)
        this.buffer[this.offset] = UInt8(value & 0xFF)
        this.offset++
        this.buffer[this.offset] = UInt8((value >> 8) & 0xFF)
        this.offset++
        this.buffer[this.offset] = UInt8((value >> 16) & 0xFF)
        this.offset++
        this.buffer[this.offset] = UInt8((value >> 24) & 0xFF)
        this.offset++
    }

    /**
     * 写入 uint32（小端序）
     * 注意：不能用 Int32(value) 转换，因为 UInt32 > Int32.Max 时会抛 OverflowException
     */
    public func writeUInt32(value: UInt32) {
        ensureCapacity(4)
        this.buffer[this.offset] = UInt8(value & 0xFF)
        this.offset++
        this.buffer[this.offset] = UInt8((value >> 8) & 0xFF)
        this.offset++
        this.buffer[this.offset] = UInt8((value >> 16) & 0xFF)
        this.offset++
        this.buffer[this.offset] = UInt8((value >> 24) & 0xFF)
        this.offset++
    }

    /**
     * 写入 int64（小端序）
     */
    public func writeInt64(value: Int64) {
        ensureCapacity(8)
        for (i in 0..8) {
            this.buffer[this.offset] = UInt8((value >> (i * 8)) & 0xFF)
            this.offset++
        }
    }

    /**
     * 写入 int128（原始16字节）
     */
    public func writeInt128(value: Array<Byte>) {
        if (value.size != 16) {
            let padded = Array<Byte>(16, repeat: 0)
            let copyLen = if (value.size < 16) { value.size } else { 16 }
            for (i in 0..copyLen) {
                padded[i] = value[i]
            }
            writeRawBytes(padded)
        } else {
            writeRawBytes(value)
        }
    }

    /**
     * 写入 int256（原始32字节）
     */
    public func writeInt256(value: Array<Byte>) {
        if (value.size != 32) {
            let padded = Array<Byte>(32, repeat: 0)
            let copyLen = if (value.size < 32) { value.size } else { 32 }
            for (i in 0..copyLen) {
                padded[i] = value[i]
            }
            writeRawBytes(padded)
        } else {
            writeRawBytes(value)
        }
    }

    /**
     * 写入 double（小端序，IEEE 754）
     * 
     * 对应 TelegramHarmony: `new DataView(buf).setFloat64(offset, value, true)`
     * 旧代码 `writeInt64(Int64(value))` 是错误的：将 float 截断为整数再写入。
     * 现在使用 float64ToBits 正确转换 IEEE 754 位模式。
     */
    public func writeDouble(value: Float64) {
        writeInt64(ByteUtils.float64ToBits(value))
    }

    /**
     * 写入变长字节数组（TL bytes 格式）
     * 长度 <= 253: 1字节长度头
     * 长度 > 253: 4字节长度头（0xFE + 3字节长度）
     * 然后对齐到4字节边界
     */
    public func writeBytes(bytes: Array<Byte>) {
        let length = bytes.size

        if (length <= 253) {
            ensureCapacity(1 + length)
            this.buffer[this.offset] = UInt8(length)
            this.offset++
        } else {
            ensureCapacity(4 + length)
            this.buffer[this.offset] = UInt8(254u8)
            this.offset++
            this.buffer[this.offset] = UInt8(length & 0xFF)
            this.offset++
            this.buffer[this.offset] = UInt8((length >> 8) & 0xFF)
            this.offset++
            this.buffer[this.offset] = UInt8((length >> 16) & 0xFF)
            this.offset++
        }

        writeRawBytes(bytes)

        // 对齐到4字节边界
        let headerLen: Int64 = if (length <= 253) { 1 } else { 4 }
        let padding = (4 - ((length + headerLen) % 4)) % 4
        for (_i in 0..padding) {
            ensureCapacity(1)
            this.buffer[this.offset] = 0
            this.offset++
        }
    }

    /**
     * 写入字符串（UTF-8 编码后作为 bytes 写入）
     */
    public func writeString(value: String) {
        let bytes = value.toArray()
        writeBytes(bytes)
    }

    /**
     * 写入布尔值
     */
    public func writeBool(value: Bool) {
        if (value) {
            writeUInt32(TLConstructors.BOOL_TRUE)
        } else {
            writeUInt32(TLConstructors.BOOL_FALSE)
        }
    }

    /**
     * 写入向量（Vector）
     */
    public func writeVector(items: ArrayList<Array<Byte>>) {
        writeUInt32(TLConstructors.VECTOR)
        writeInt32(Int32(items.size))
        for (item in items) {
            writeRawBytes(item)
        }
    }

    /**
     * 获取已序列化的字节结果
     */
    public func getBytes(): Array<Byte> {
        return ByteUtils.slice(this.buffer, 0, this.offset)
    }

    /**
     * 获取当前写入偏移量
     */
    public func getOffset(): Int64 {
        return this.offset
    }
}

/**
 * TL 反序列化器
 * 
 * 对应 TelegramHarmony 的 TLSerialization.ets TLDeserializer
 * 从字节缓冲区读取 TL 类型（小端序）
 */
public class TLDeserializer {
    private let buffer: Array<Byte>
    private var offset: Int64 = 0

    public init(data: Array<Byte>) {
        this.buffer = data
    }

    /**
     * 读取原始字节
     */
    public func readRawBytes(length: Int64): Array<Byte> {
        let result = ByteUtils.slice(this.buffer, this.offset, this.offset + length)
        this.offset += length
        return result
    }

    /**
     * 读取 int32（小端序）
     */
    public func readInt32(): Int32 {
        let result = ByteUtils.bytesToInt32(this.buffer, offset: this.offset)
        this.offset += 4
        return result
    }

    /**
     * 读取 uint32（小端序）
     */
    public func readUInt32(): UInt32 {
        let result = ByteUtils.bytesToUInt32(this.buffer, offset: this.offset)
        this.offset += 4
        return result
    }

    /**
     * 读取 int64（小端序）
     */
    public func readInt64(): Int64 {
        let result = ByteUtils.bytesToInt64(this.buffer, offset: this.offset)
        this.offset += 8
        return result
    }

    /**
     * 读取 int128（原始16字节）
     */
    public func readInt128(): Array<Byte> {
        return readRawBytes(16)
    }

    /**
     * 读取 int256（原始32字节）
     */
    public func readInt256(): Array<Byte> {
        return readRawBytes(32)
    }

    /**
     * 读取 double（小端序，IEEE 754）
     * 
     * 对应 TelegramHarmony: `new DataView(buf).getFloat64(0, true)`
     * 旧代码 `Float64(bits)` 是错误的：它将整数值转为浮点，而不是重新解释位模式！
     * 例如 IEEE 754 的 5.0 = 0x4014000000000000，旧代码会返回 4.617e18 而不是 5.0。
     */
    public func readDouble(): Float64 {
        let bits = readInt64()
        return ByteUtils.bitsToFloat64(bits)
    }

    /**
     * 读取变长字节数组（TL bytes 格式）
     */
    public func readBytes(): Array<Byte> {
        var length: Int64 = Int64(UInt8(this.buffer[this.offset]))
        this.offset++

        if (length == 254) {
            let b0 = Int64(UInt8(this.buffer[this.offset]))
            let b1 = Int64(UInt8(this.buffer[this.offset + 1]))
            let b2 = Int64(UInt8(this.buffer[this.offset + 2]))
            length = b0 | (b1 << 8) | (b2 << 16)
            this.offset += 3
        }

        let result = readRawBytes(length)

        // 跳过对齐填充
        let headerLength: Int64 = if (length <= 253) { 1 } else { 4 }
        let padding = (4 - ((length + headerLength) % 4)) % 4
        this.offset += padding

        return result
    }

    /**
     * 读取字符串
     */
    public func readString(): String {
        let bytes = readBytes()
        return String.fromUtf8(bytes)
    }

    /**
     * 读取布尔值
     */
    public func readBool(): Bool {
        let constructor = readUInt32()
        return constructor == TLConstructors.BOOL_TRUE
    }

    /**
     * 获取当前偏移量
     */
    public func getOffset(): Int64 {
        return this.offset
    }

    /**
     * 设置偏移量
     */
    public func setOffset(offset: Int64) {
        this.offset = offset
    }

    /**
     * 获取剩余字节数
     */
    public func remaining(): Int64 {
        return this.buffer.size - this.offset
    }

    /**
     * 查看下一个 uint32 但不移动偏移量
     */
    public func peekUInt32(): UInt32 {
        return ByteUtils.bytesToUInt32(this.buffer, offset: this.offset)
    }

    /**
     * 诊断用：dump 当前偏移量附近的 N 个字节为十六进制字符串
     */
    public func dumpHex(count: Int64): String {
        var result = ""
        var i: Int64 = 0
        while (i < count && (this.offset + i) < this.buffer.size) {
            let b = UInt8(this.buffer[this.offset + i])
            // 手动转为两位十六进制
            let hi = b >> 4
            let lo = b & 0x0F
            let hexChars = "0123456789abcdef"
            result += "${hexChars[Int64(hi)]}${hexChars[Int64(lo)]}"
            if (i < count - 1) { result += " " }
            i = i + 1
        }
        return result
    }

    /**
     * 获取当前缓冲区总大小
     */
    public func getBufferSize(): Int64 {
        return this.buffer.size
    }
}

/**
 * TL 对象基类
 * 
 * 所有 TL 方法和类型都继承此抽象类
 */
public abstract class TLObject {
    /**
     * 获取构造函数 ID
     */
    public open func getConstructorId(): UInt32 { return 0 }

    /**
     * 序列化对象字段（不包含构造函数 ID）
     */
    public open func serialize(serializer: TLSerializer) {}

    /**
     * 转换为完整字节数组（包含构造函数 ID）
     */
    public func toBytes(): Array<Byte> {
        let serializer = TLSerializer()
        serializer.writeUInt32(getConstructorId())
        serialize(serializer)
        return serializer.getBytes()
    }
}

// ==================== 协议消息类型 ====================

/**
 * RPC 结果
 */
public class RPCResult {
    public var reqMsgId: Int64 = 0
    public var result: Array<Byte> = Array<Byte>(0, repeat: 0)

    public static func deserialize(deserializer: TLDeserializer): RPCResult {
        let r = RPCResult()
        r.reqMsgId = deserializer.readInt64()
        r.result = deserializer.readRawBytes(deserializer.remaining())
        return r
    }
}

/**
 * RPC 错误
 */
public class RPCError {
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""

    public init() {}
    public init(code: Int32, message: String) {
        this.errorCode = code
        this.errorMessage = message
    }

    public static func deserialize(deserializer: TLDeserializer): RPCError {
        let e = RPCError()
        e.errorCode = deserializer.readInt32()
        e.errorMessage = deserializer.readString()
        return e
    }

    public func toString(): String {
        return "RPC Error ${this.errorCode}: ${this.errorMessage}"
    }
}

/**
 * 消息容器
 */
public class MsgContainer {
    public var messages: ArrayList<ContainedMessage> = ArrayList<ContainedMessage>()

    public static func deserialize(deserializer: TLDeserializer): MsgContainer {
        let container = MsgContainer()
        let count = deserializer.readInt32()
        for (_i in 0..Int64(count)) {
            let msg = ContainedMessage()
            msg.msgId = deserializer.readInt64()
            msg.seqNo = deserializer.readInt32()
            let bodyLength = deserializer.readInt32()
            msg.body = deserializer.readRawBytes(Int64(bodyLength))
            container.messages.add(msg)
        }
        return container
    }
}

/**
 * 容器内的消息
 */
public class ContainedMessage {
    public var msgId: Int64 = 0
    public var seqNo: Int32 = 0
    public var body: Array<Byte> = Array<Byte>(0, repeat: 0)
}

/**
 * 新会话创建
 */
public class NewSessionCreated {
    public var firstMsgId: Int64 = 0
    public var uniqueId: Int64 = 0
    public var serverSalt: Int64 = 0

    public static func deserialize(deserializer: TLDeserializer): NewSessionCreated {
        let r = NewSessionCreated()
        r.firstMsgId = deserializer.readInt64()
        r.uniqueId = deserializer.readInt64()
        r.serverSalt = deserializer.readInt64()
        return r
    }
}

/**
 * 消息确认
 */
public class MsgsAck <: TLObject {
    public var msgIds: ArrayList<Int64> = ArrayList<Int64>()

    public func getConstructorId(): UInt32 {
        return TLConstructors.MSGS_ACK
    }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(TLConstructors.VECTOR)
        serializer.writeInt32(Int32(this.msgIds.size))
        for (id in this.msgIds) {
            serializer.writeInt64(id)
        }
    }

    public static func deserialize(deserializer: TLDeserializer): MsgsAck {
        let r = MsgsAck()
        let _ = deserializer.readUInt32() // vector constructor
        let count = deserializer.readInt32()
        for (_i in 0..Int64(count)) {
            r.msgIds.add(deserializer.readInt64())
        }
        return r
    }
}

/**
 * Pong 响应
 */
public class Pong {
    public var msgId: Int64 = 0
    public var pingId: Int64 = 0

    public static func deserialize(deserializer: TLDeserializer): Pong {
        let r = Pong()
        r.msgId = deserializer.readInt64()
        r.pingId = deserializer.readInt64()
        return r
    }
}

/**
 * Bad Server Salt
 */
public class BadServerSaltMsg {
    public var badMsgId: Int64 = 0
    public var badMsgSeqNo: Int32 = 0
    public var errorCode: Int32 = 0
    public var newServerSalt: Int64 = 0

    public static func deserialize(deserializer: TLDeserializer): BadServerSaltMsg {
        let r = BadServerSaltMsg()
        r.badMsgId = deserializer.readInt64()
        r.badMsgSeqNo = deserializer.readInt32()
        r.errorCode = deserializer.readInt32()
        r.newServerSalt = deserializer.readInt64()
        return r
    }
}
