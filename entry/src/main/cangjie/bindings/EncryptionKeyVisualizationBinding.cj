package ohos_app_cangjie_entry.bindings

/**
 * EncryptionKeyVisualizationBinding — 密钥可视化平台封装层
 *
 * 对应 Telegram-iOS EncryptionKeyVisualizationImpl/SecretChatKeyVisualization.m
 * 将秘密聊天 auth key 指纹字节映射为彩色方块网格数据。
 *
 * 算法要点：
 * - 4 种颜色：白 0xffffff / 浅蓝 0xd5e6f3 / 深蓝 0x2d5775 / 亮蓝 0x2f99c9
 * - 仅 SHA1 数据（无 additionalData）→ 8×8 网格，每格取 2 bit
 * - SHA1 + SHA256 两路数据 → 12×12 网格，前 64 格来自 SHA1，后 80 格来自 SHA256
 * - bit 提取：小端序，从低位起逐 2 bit 读取
 *
 * 不依赖图形绘制库；只输出颜色索引数组，由上层负责渲染。
 */

/**
 * 密钥颜色网格结果
 *
 * cells: 网格颜色索引数组（0-3），长度为 gridSize*gridSize
 * gridSize: 8 或 12
 * colors: 4 种 ARGB 颜色值（0xAARRGGBB，A=0xFF）
 */
public class KeyColorGrid {
    public var cells: Array<Int32> = Array<Int32>(0, repeat: 0)
    public var gridSize: Int32 = 8
    public var colors: Array<Int64> = [
        Int64(0xFFFFFFFF),  // 白色
        Int64(0xFFD5E6F3),  // 浅蓝
        Int64(0xFF2D5775),  // 深蓝
        Int64(0xFF2F99C9)   // 亮蓝
    ]
}

/**
 * 从字节数组中提取 2 位值
 *
 * 对应 iOS get_bits(bytes, bitOffset, 2) 实现：
 * 小端序，从 bitOffset/8 处字节的第 bitOffset%8 位开始，取 2 位。
 *
 * @param bytes 源字节数组
 * @param bitOffset 位偏移量（从 0 开始）
 * @return 提取到的 2 位值（0~3）
 */
private func getBits2(srcBytes: Array<Byte>, bitOffset: Int64): Int32 {
    let byteIdx = bitOffset / 8
    let bitShift = bitOffset % 8
    if (byteIdx >= srcBytes.size) {
        return 0
    }
    let byteVal = Int32(UInt8(srcBytes[byteIdx]))
    if (bitShift <= 5) {
        return (byteVal >> Int32(bitShift)) & 3
    }
    let hi = byteVal >> Int32(bitShift)
    if (byteIdx + 1 >= srcBytes.size) {
        return hi & 3
    }
    let nextByte = Int32(UInt8(srcBytes[byteIdx + 1]))
    let lo = nextByte << Int32(8 - bitShift)
    return (hi | lo) & 3
}

/**
 * EncryptionKeyVisualizationBinding — 密钥可视化封装
 *
 * 使用场景：秘密聊天界面展示 auth key 指纹视觉图案。
 */
public class EncryptionKeyVisualizationBinding {

    /**
     * 计算密钥颜色网格
     *
     * @param sha1Data  SHA1 指纹字节（对应 iOS keySignatureData，最多 20 字节）
     * @param sha256Data SHA256 指纹字节（对应 iOS additionalSignature，最多 32 字节）。
     *                   传空数组表示仅使用 SHA1 模式（8×8 网格）。
     * @return KeyColorGrid 实例，包含颜色索引网格
     */
    public static func computeColorGrid(sha1Data: Array<Byte>, sha256Data: Array<Byte>): KeyColorGrid {
        let grid = KeyColorGrid()

        if (sha256Data.size == 0) {
            grid.gridSize = 8
            let total = 8 * 8
            grid.cells = Array<Int32>(total, repeat: 0)
            var bitPointer: Int64 = 0
            var idx: Int64 = 0
            while (idx < total) {
                let colorIdx = getBits2(sha1Data, bitPointer)
                grid.cells[idx] = colorIdx
                bitPointer += 2
                idx++
            }
        } else {
            grid.gridSize = 12
            let total = 12 * 12
            grid.cells = Array<Int32>(total, repeat: 0)
            var bitPointer: Int64 = 0
            var idx: Int64 = 0
            while (idx < total) {
                let colorIdx: Int32
                if (bitPointer < 128) {
                    colorIdx = getBits2(sha1Data, bitPointer)
                } else {
                    colorIdx = getBits2(sha256Data, bitPointer - 128)
                }
                grid.cells[idx] = colorIdx
                bitPointer += 2
                idx++
            }
        }

        return grid
    }

    /**
     * 获取网格单元的 ARGB 颜色值（0xAARRGGBB）
     *
     * @param colorIndex 颜色索引（0-3）
     * @return ARGB 颜色值
     */
    public static func colorForIndex(colorIndex: Int32): Int64 {
        let palette: Array<Int64> = [
            Int64(0xFFFFFFFF),
            Int64(0xFFD5E6F3),
            Int64(0xFF2D5775),
            Int64(0xFF2F99C9)
        ]
        let idx = Int64(colorIndex) % 4
        if (idx < 0) { return palette[0] }
        return palette[idx]
    }

    /**
     * 将 KeyColorGrid 展开为 ARGB 颜色数组
     *
     * 长度 = gridSize * gridSize，每个元素为 0xAARRGGBB 颜色值。
     *
     * @param grid 颜色网格
     * @return ARGB 颜色值数组
     */
    public static func flattenToArgbArray(grid: KeyColorGrid): Array<Int64> {
        let size = grid.cells.size
        let result = Array<Int64>(size, repeat: Int64(0xFFFFFFFF))
        var i: Int64 = 0
        while (i < size) {
            result[i] = colorForIndex(grid.cells[i])
            i++
        }
        return result
    }
}
