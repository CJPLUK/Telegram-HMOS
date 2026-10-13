package ohos_app_cangjie_entry.utils

/**
 * EncryptionKeyVisualizationUtils — 密钥可视化上层工具接口
 *
 * 对应 Telegram-iOS EncryptionKeyVisualization/Sources/SecretChatKeyVisualization.swift
 * 的公开 API secretChatKeyImage(_:size:)。
 *
 * 提供：
 * - secretChatKeyColorGrid: 从 SecretChatKeyFingerprint（SHA1 + SHA256）计算颜色网格
 * - secretChatKeyEmojiFingerprint: 将 SHA1 前 8 字节映射为 4 个 emoji 字符串
 * - keyColorGridDescription: 将颜色网格转换为可读字符串（调试用）
 */

import ohos_app_cangjie_entry.bindings.{EncryptionKeyVisualizationBinding, KeyColorGrid}

/**
 * 秘密聊天密钥指纹
 *
 * sha1Bytes:   SHA1 哈希字节（20 字节，来自 SecretChatKeyFingerprint.sha1.data()）
 * sha256Bytes: SHA256 哈希字节（32 字节，来自 SecretChatKeyFingerprint.sha256.data()）
 */
public class SecretChatKeyFingerprint {
    public var sha1Bytes: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var sha256Bytes: Array<Byte> = Array<Byte>(0, repeat: 0)
}

/**
 * 从秘密聊天密钥指纹计算颜色网格
 *
 * 等价于 iOS secretChatKeyImage(_:size:) 的数据层：
 * SecretChatKeyVisualization(keySignatureData, additionalSignature, size)
 *
 * @param fingerprint 密钥指纹（sha1 + sha256）
 * @return KeyColorGrid 颜色网格（gridSize=12，cells 长度 144）
 */
public func secretChatKeyColorGrid(fingerprint: SecretChatKeyFingerprint): KeyColorGrid {
    return EncryptionKeyVisualizationBinding.computeColorGrid(
        fingerprint.sha1Bytes,
        fingerprint.sha256Bytes
    )
}

/**
 * 从原始字节直接计算颜色网格（无需构造 SecretChatKeyFingerprint 对象）
 *
 * @param sha1Bytes  SHA1 指纹字节（最多 20 字节）
 * @param sha256Bytes SHA256 指纹字节（最多 32 字节；传空数组则使用 8×8 模式）
 * @return KeyColorGrid 颜色网格
 */
public func secretChatKeyColorGridFromBytes(sha1Bytes: Array<Byte>, sha256Bytes: Array<Byte>): KeyColorGrid {
    return EncryptionKeyVisualizationBinding.computeColorGrid(
        sha1Bytes,
        sha256Bytes
    )
}

/**
 * 将密钥指纹映射为 emoji 字符串（4 个 emoji）
 *
 * 算法：取 SHA1 字节的前 8 字节，每两字节解释为一个 Int16，
 * 对 emojiTable.size 取模，得到 4 个 emoji 索引。
 *
 * emoji 表来自 Telegram 官方 secret chat emoji 列表（56 个）。
 *
 * @param sha1Bytes SHA1 指纹字节
 * @return 4 个 emoji 字符串，用空格连接
 */
public func secretChatKeyEmojiFingerprint(sha1Bytes: Array<Byte>): String {
    let emojiTable: Array<String> = [
        "\u{1F608}", "\u{1F60D}", "\u{1F923}", "\u{1F614}", "\u{1F600}", "\u{1F607}", "\u{1F62C}",
        "\u{1F615}", "\u{1F62A}", "\u{1F637}", "\u{1F910}", "\u{1F911}", "\u{1F632}", "\u{1F621}",
        "\u{1F618}", "\u{1F61C}", "\u{1F605}", "\u{1F917}", "\u{1F60B}", "\u{1F928}", "\u{1F62D}",
        "\u{1F631}", "\u{1F920}", "\u{1F92F}", "\u{1F60F}", "\u{1F622}", "\u{1F633}", "\u{1F913}",
        "\u{1F629}", "\u{1F627}", "\u{1F61E}", "\u{1F62B}", "\u{1F924}", "\u{1F60C}", "\u{1F612}",
        "\u{1F603}", "\u{1F619}", "\u{1F625}", "\u{1F92D}", "\u{1F61F}", "\u{1F601}", "\u{1F616}",
        "\u{1F62E}", "\u{1F643}", "\u{1F642}", "\u{1F609}", "\u{1F613}", "\u{1F606}", "\u{1F604}",
        "\u{1F602}", "\u{1F92B}", "\u{1F611}", "\u{1F644}", "\u{1F610}", "\u{1F636}", "\u{1F92A}"
    ]

    let tableSize = Int64(emojiTable.size)
    var result: String = ""
    var pairIdx: Int64 = 0
    while (pairIdx < 4) {
        let byteBase = pairIdx * 2
        let lo: Int64
        let hi: Int64
        if (byteBase < sha1Bytes.size) {
            lo = Int64(UInt8(sha1Bytes[byteBase]))
        } else {
            lo = 0
        }
        if (byteBase + 1 < sha1Bytes.size) {
            hi = Int64(UInt8(sha1Bytes[byteBase + 1]))
        } else {
            hi = 0
        }
        let combined = (hi << 8) | lo
        let emojiIdx = combined % tableSize
        if (pairIdx > 0) {
            result = result + " "
        }
        result = result + emojiTable[emojiIdx]
        pairIdx++
    }
    return result
}

/**
 * 将 KeyColorGrid 转为可读描述字符串（调试工具）
 *
 * 使用字符符号表示颜色索引，每行一行。
 * 颜色映射：0="." 1="," 2="+" 3="#"
 *
 * @param grid 颜色网格
 * @return 多行字符串描述
 */
public func keyColorGridDescription(grid: KeyColorGrid): String {
    let symbols: Array<String> = [".", ",", "+", "#"]
    let sz = Int64(grid.gridSize)
    var out: String = ""
    var row: Int64 = 0
    while (row < sz) {
        var col: Int64 = 0
        while (col < sz) {
            let cellIdx = row * sz + col
            let colorIdx = Int64(grid.cells[cellIdx]) % 4
            out = out + symbols[colorIdx]
            col++
        }
        out = out + "\n"
        row++
    }
    return out
}
