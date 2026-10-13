package ohos_app_cangjie_entry.core.mtproto

import std.collection.ArrayList
import std.io.ByteBuffer
import stdx.compress.zlib.*

/**
 * DEFLATE/GZIP 解压缩器
 * 
 * 对应 TelegramHarmony 的 Inflate.ets
 * 纯 Cangjie 实现，用于解压 Telegram gzip_packed 响应
 * 基于 RFC 1951 (DEFLATE) 和 RFC 1952 (GZIP)
 */

// 长度码表
let LENGTH_BASE: Array<Int64> = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258
]
let LENGTH_EXTRA: Array<Int64> = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0
]

// 距离码表
let DISTANCE_BASE: Array<Int64> = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577
]
let DISTANCE_EXTRA: Array<Int64> = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13
]

// 码长顺序
let CODE_LENGTH_ORDER: Array<Int64> = [
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15
]

/**
 * Huffman 树节点
 */
class HuffmanNode {
    var symbol: Int64 = -1  // -1 = 非叶子节点
    var left: Option<HuffmanNode> = None   // bit 0
    var right: Option<HuffmanNode> = None  // bit 1

    func isLeaf(): Bool {
        return this.symbol >= 0
    }
}

/**
 * 位读取器
 */
class BitReader {
    private let data: Array<Byte>
    private var bytePos: Int64 = 0
    private var bitPos: Int64 = 0

    init(data: Array<Byte>) {
        this.data = data
    }

    func readBits(count: Int64): Int64 {
        var result: Int64 = 0
        for (i in 0..count) {
            if (this.bytePos >= this.data.size) {
                return result
            }
            let bit = (Int64(UInt8(this.data[this.bytePos])) >> this.bitPos) & 1
            result = result | (bit << i)
            this.bitPos++
            if (this.bitPos == 8) {
                this.bitPos = 0
                this.bytePos++
            }
        }
        return result
    }

    func alignToByte() {
        if (this.bitPos != 0) {
            this.bitPos = 0
            this.bytePos++
        }
    }

    func readByte(): Int64 {
        alignToByte()
        if (this.bytePos >= this.data.size) {
            return 0
        }
        let b = Int64(UInt8(this.data[this.bytePos]))
        this.bytePos++
        return b
    }

    func readByteArray(count: Int64): Array<Byte> {
        alignToByte()
        let result = Array<Byte>(count, repeat: 0)
        for (i in 0..count) {
            if (this.bytePos < this.data.size) {
                result[i] = this.data[this.bytePos]
                this.bytePos++
            }
        }
        return result
    }

    func readHuffmanSymbol(tree: HuffmanNode): Int64 {
        var node = tree
        while (!node.isLeaf()) {
            let bit = readBits(1)
            if (bit == 0) {
                match (node.left) {
                    case Some(child) => node = child
                    case None => return -1
                }
            } else {
                match (node.right) {
                    case Some(child) => node = child
                    case None => return -1
                }
            }
        }
        return node.symbol
    }
}

/**
 * 输出缓冲区
 */
class OutputBuffer {
    var buffer: ArrayList<Byte> = ArrayList<Byte>()

    func push(byte_: Byte) {
        this.buffer.add(byte_)
    }

    func pushArray(bytes: Array<Byte>) {
        for (i in 0..bytes.size) {
            this.buffer.add(bytes[i])
        }
    }

    func copyFromBack(distance: Int64, length: Int64) {
        let start = this.buffer.size - distance
        for (i in 0..length) {
            let idx = start + (i % distance)
            this.buffer.add(this.buffer[idx])
        }
    }

    func toArray(): Array<Byte> {
        let result = Array<Byte>(this.buffer.size, repeat: 0)
        for (i in 0..this.buffer.size) {
            result[i] = this.buffer[i]
        }
        return result
    }
}

/**
 * 构建 Huffman 树
 */
func buildHuffmanTree(codeLengths: Array<Int64>): HuffmanNode {
    let blCount = Array<Int64>(16, repeat: 0)
    var maxLen: Int64 = 0

    for (i in 0..codeLengths.size) {
        let len = codeLengths[i]
        if (len > 0) {
            blCount[len]++
            if (len > maxLen) {
                maxLen = len
            }
        }
    }

    let nextCode = Array<Int64>(maxLen + 1, repeat: 0)
    var code: Int64 = 0
    for (bits in 1..(maxLen + 1)) {
        code = (code + blCount[bits - 1]) << 1
        nextCode[bits] = code
    }

    let root = HuffmanNode()

    for (n in 0..codeLengths.size) {
        let len = codeLengths[n]
        if (len > 0) {
            let huffCode = nextCode[len]
            nextCode[len] = nextCode[len] + 1

            var node = root
            var i = len - 1
            while (i >= 0) {
                let bit = (huffCode >> i) & 1
                if (bit == 0) {
                    if (node.left.isNone()) {
                        if (i == 0) {
                            let leaf = HuffmanNode()
                            leaf.symbol = n
                            node.left = Some(leaf)
                        } else {
                            node.left = Some(HuffmanNode())
                        }
                    }
                    match (node.left) {
                        case Some(child) => node = child
                        case None => break
                    }
                } else {
                    if (node.right.isNone()) {
                        if (i == 0) {
                            let leaf = HuffmanNode()
                            leaf.symbol = n
                            node.right = Some(leaf)
                        } else {
                            node.right = Some(HuffmanNode())
                        }
                    }
                    match (node.right) {
                        case Some(child) => node = child
                        case None => break
                    }
                }
                i--
            }
        }
    }

    return root
}

/**
 * 获取固定 Huffman 字面量码长表
 */
func getFixedLiteralLengths(): Array<Int64> {
    let arr = Array<Int64>(288, repeat: 0)
    for (i in 0..144) { arr[i] = 8 }
    for (i in 144..256) { arr[i] = 9 }
    for (i in 256..280) { arr[i] = 7 }
    for (i in 280..288) { arr[i] = 8 }
    return arr
}

func getFixedDistanceLengths(): Array<Int64> {
    return Array<Int64>(32, repeat: 5)
}

/**
 * 解压一个块
 */
func inflateBlock(reader: BitReader, output: OutputBuffer, literalTree: HuffmanNode, distanceTree: HuffmanNode) {
    while (true) {
        let symbol = reader.readHuffmanSymbol(literalTree)

        if (symbol < 256) {
            output.push(UInt8(symbol & 0xFF))
        } else if (symbol == 256) {
            break
        } else {
            let lengthCode = symbol - 257
            if (lengthCode >= LENGTH_BASE.size) {
                break
            }
            let length = LENGTH_BASE[lengthCode] + reader.readBits(LENGTH_EXTRA[lengthCode])
            let distanceCode = reader.readHuffmanSymbol(distanceTree)
            if (distanceCode >= DISTANCE_BASE.size) {
                break
            }
            let distance = DISTANCE_BASE[distanceCode] + reader.readBits(DISTANCE_EXTRA[distanceCode])
            output.copyFromBack(distance, length)
        }
    }
}

func inflateStored(reader: BitReader, output: OutputBuffer) {
    reader.alignToByte()
    let len = reader.readByte() | (reader.readByte() << 8)
    let _ = reader.readByte() | (reader.readByte() << 8) // nlen
    let data = reader.readByteArray(len)
    output.pushArray(data)
}

func inflateFixed(reader: BitReader, output: OutputBuffer) {
    let literalTree = buildHuffmanTree(getFixedLiteralLengths())
    let distanceTree = buildHuffmanTree(getFixedDistanceLengths())
    inflateBlock(reader, output, literalTree, distanceTree)
}

func readCodeLengths(reader: BitReader, tree: HuffmanNode, count: Int64): Array<Int64> {
    let lengths = ArrayList<Int64>()

    while (lengths.size < count) {
        let symbol = reader.readHuffmanSymbol(tree)

        if (symbol < 16) {
            lengths.add(symbol)
        } else if (symbol == 16) {
            let repeatCount = reader.readBits(2) + 3
            let lastLength = if (lengths.size > 0) { lengths[lengths.size - 1] } else { 0 }
            for (_i in 0..repeatCount) {
                if (lengths.size < count) {
                    lengths.add(lastLength)
                }
            }
        } else if (symbol == 17) {
            let repeatCount = reader.readBits(3) + 3
            for (_i in 0..repeatCount) {
                if (lengths.size < count) {
                    lengths.add(0)
                }
            }
        } else if (symbol == 18) {
            let repeatCount = reader.readBits(7) + 11
            for (_i in 0..repeatCount) {
                if (lengths.size < count) {
                    lengths.add(0)
                }
            }
        }
    }

    let result = Array<Int64>(lengths.size, repeat: 0)
    for (i in 0..lengths.size) {
        result[i] = lengths[i]
    }
    return result
}

func inflateDynamic(reader: BitReader, output: OutputBuffer) {
    let hlit = reader.readBits(5) + 257
    let hdist = reader.readBits(5) + 1
    let hclen = reader.readBits(4) + 4

    let codeLengthLengths = Array<Int64>(19, repeat: 0)
    for (i in 0..hclen) {
        codeLengthLengths[CODE_LENGTH_ORDER[i]] = reader.readBits(3)
    }

    let codeLengthTree = buildHuffmanTree(codeLengthLengths)
    let literalLengths = readCodeLengths(reader, codeLengthTree, hlit)
    let distanceLengths = readCodeLengths(reader, codeLengthTree, hdist)

    let literalTree = buildHuffmanTree(literalLengths)
    let distanceTree = buildHuffmanTree(distanceLengths)

    inflateBlock(reader, output, literalTree, distanceTree)
}

func inflateDeflate(reader: BitReader): Array<Byte> {
    let output = OutputBuffer()
    var finalBlock = false

    while (!finalBlock) {
        finalBlock = reader.readBits(1) == 1
        let blockType = reader.readBits(2)

        if (blockType == 0) {
            inflateStored(reader, output)
        } else if (blockType == 1) {
            inflateFixed(reader, output)
        } else if (blockType == 2) {
            inflateDynamic(reader, output)
        }
    }

    return output.toArray()
}

/**
 * GZIP 解压缩
 */
public func gunzip(data: Array<Byte>): Array<Byte> {
    if (data.size < 10) {
        return data
    }

    // 检查魔数
    if (UInt8(data[0]) != 0x1f || UInt8(data[1]) != 0x8b) {
        return data
    }

    // 压缩方法必须是 8 (deflate)
    if (UInt8(data[2]) != 8) {
        return data
    }

    let flags = UInt8(data[3])
    var offset: Int64 = 10

    // 跳过 FEXTRA
    if ((flags & 4) != 0) {
        let xlen = Int64(UInt8(data[offset])) | (Int64(UInt8(data[offset + 1])) << 8)
        offset += 2 + xlen
    }

    // 跳过 FNAME
    if ((flags & 8) != 0) {
        while (offset < data.size && data[offset] != 0) {
            offset++
        }
        offset++
    }

    // 跳过 FCOMMENT
    if ((flags & 16) != 0) {
        while (offset < data.size && data[offset] != 0) {
            offset++
        }
        offset++
    }

    // 跳过 FHCRC
    if ((flags & 2) != 0) {
        offset += 2
    }

    // 解压 DEFLATE 数据（去掉尾部 8 字节的 CRC32 + ISIZE）
    let deflateData = ByteUtils.slice(data, offset, data.size - 8)
    let reader = BitReader(deflateData)
    return inflateDeflate(reader)
}

/**
 * 原始 DEFLATE 解压缩
 */
public func inflate(data: Array<Byte>): Array<Byte> {
    let reader = BitReader(data)
    return inflateDeflate(reader)
}

/**
 * 自动检测并解压缩
 */
public func decompress(data: Array<Byte>): Array<Byte> {
    if (data.size >= 2 && UInt8(data[0]) == 0x1f && UInt8(data[1]) == 0x8b) {
        return gunzip(data)
    }
    return inflate(data)
}

// ============================================================
// P2-248: GZIP 压缩侧（对应 iOS MTGzip.compress / deflateInit2 windowBits=31）
// ============================================================

/**
 * 用 GZIP 格式压缩数据（stdx.compress.zlib CompressInputStream + GzipFormat + BestCompression）。
 *
 * 对应 iOS MTGzip.compress：deflateInit2(&stream, Z_BEST_COMPRESSION, Z_DEFLATED, 31, 8, ...)
 * windowBits=31 = 15+16 = GZIP header/trailer format，与 gunzip() 解压的格式对称。
 *
 * 返回 GZIP 压缩后的字节数组；若输入为空或压缩失败，返回原始数据。
 */
public func gzip(data: Array<Byte>): Array<Byte> {
    if (data.size == 0) {
        return data
    }
    let srcBuf = ByteBuffer(data)
    var compressStream = CompressInputStream(srcBuf, wrap: GzipFormat, compressLevel: BestCompression)
    let outBuf = ArrayList<Byte>()
    let chunk = Array<Byte>(4096, repeat: 0)
    var n = compressStream.read(chunk)
    while (n > 0) {
        for (i in 0..n) {
            outBuf.add(chunk[i])
        }
        n = compressStream.read(chunk)
    }
    compressStream.close()
    if (outBuf.size == 0) {
        return data
    }
    let result = Array<Byte>(outBuf.size, repeat: 0)
    for (i in 0..outBuf.size) {
        result[i] = outBuf[i]
    }
    return result
}

/**
 * 将已压缩的 GZIP 字节封装成 TL gzip_packed#3072cfa1 wire 格式。
 *
 * TL 布局（对应 iOS MTOutputStream.writeBytes + 构造子前缀）：
 *   [0x3072cfa1 LE32] [TL-bytes: compressedData]
 * TL-bytes 格式：
 *   - 若 len <= 253: 1字节长度头 + data + 0~3字节 4 对齐填充
 *   - 若 len >= 254: 0xFE + 3字节长度LE + data + 0~3字节 4 对齐填充
 */
public func packGzipPacked(compressedData: Array<Byte>): Array<Byte> {
    let ser = TLSerializer()
    ser.writeUInt32(TLConstructors.GZIP_PACKED)
    ser.writeBytes(compressedData)
    return ser.getBytes()
}

/**
 * 若压缩后字节数更少，返回 gzip_packed TL 封装字节；否则返回原始 data（不压缩）。
 *
 * 对应 iOS Download.swift wrapMethodBody：
 *   if let compressed = MTGzip.compress(body), compressed.count < body.size { wrap }
 *
 * 调用方将返回值作为消息 body 传入 buildMessage/serializeContainer 即可。
 */
public func wrapGzipIfBeneficial(data: Array<Byte>): Array<Byte> {
    if (data.size == 0) {
        return data
    }
    let compressed = gzip(data)
    let packed = packGzipPacked(compressed)
    if (packed.size < data.size) {
        return packed
    }
    return data
}
