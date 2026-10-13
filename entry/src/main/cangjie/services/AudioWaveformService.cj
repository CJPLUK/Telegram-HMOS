package ohos_app_cangjie_entry.services

import std.collection.ArrayList

/**
 * AudioWaveformService — 音频波形数据处理服务
 *
 * 对应 iOS AudioWaveform.swift:
 *   - init(bitstream: Data, bitsPerSample: Int) — 从 N-bit packed bitstream 解码采样
 *   - makeBitstream() — 编码采样为 5-bit packed bitstream
 *   - subwaveform(from:to:) — 截取子波形
 *
 * 纯本地计算，无网络/MTProto 调用。
 */
public class AudioWaveformService {

    /**
     * 从 N-bit packed bitstream 解码音频采样。
     *
     * iOS 对应：AudioWaveform.init(bitstream:bitsPerSample:)
     *
     * bitstream 中每个采样占 bitsPerSample 位，小端位序（低位在前）。
     * 返回 Int64 数组，每个值范围 0..(2^bitsPerSample - 1)。
     *
     * @param bitstream    packed bitstream 字节数组
     * @param bitsPerSample 每采样位数（Telegram 波形为 5）
     * @return 解码后的采样值数组
     */
    public static func decodeWaveform(bitstream!: Array<Byte>, bitsPerSample!: Int64): Array<Int64> {
        if (bitstream.size == 0 || bitsPerSample <= 0 || bitsPerSample > 16) {
            return Array<Int64>(0, { _i: Int64 => 0 })
        }

        let totalBits = Int64(bitstream.size) * 8
        let numSamples = totalBits / bitsPerSample
        if (numSamples == 0) {
            return Array<Int64>(0, { _i: Int64 => 0 })
        }

        let mask: Int64 = (1 << bitsPerSample) - 1
        let samples = ArrayList<Int64>()

        var i: Int64 = 0
        while (i < numSamples) {
            let bitOffset = i * bitsPerSample
            let byteIdx = bitOffset / 8
            let bitOff = bitOffset % 8
            let b0: Int64 = if (byteIdx < Int64(bitstream.size)) {
                Int64(bitstream[byteIdx]) & 0xFF
            } else {
                0
            }
            let b1: Int64 = if (byteIdx + 1 < Int64(bitstream.size)) {
                Int64(bitstream[byteIdx + 1]) & 0xFF
            } else {
                0
            }
            let b2: Int64 = if (byteIdx + 2 < Int64(bitstream.size)) {
                Int64(bitstream[byteIdx + 2]) & 0xFF
            } else {
                0
            }
            let combined: Int64 = (b0 | (b1 << 8) | (b2 << 16)) >> bitOff
            samples.add(combined & mask)
            i += 1
        }

        let immSamples = samples
        return Array<Int64>(immSamples.size, { idx: Int64 => immSamples[idx] })
    }

    /**
     * 将采样数组下采样到 barCount 个显示条，归一化到 minHeight..maxHeight。
     *
     * iOS 对应：AudioWaveform.makeBitstream() 中 value = min(31, abs(samples[i]) * 31 / maxSample) 的归一化逻辑。
     *
     * @param samples    原始采样数组（可来自 decodeWaveform）
     * @param barCount   目标 bar 数量
     * @param maxRaw     原始采样最大值（5-bit = 31）
     * @param minHeight  输出最小高度（px，Int64）
     * @param maxHeight  输出最大高度（px，Int64）
     * @return barCount 个 Int64 高度值
     */
    public static func generateBars(
        samples!: Array<Int64>,
        barCount!: Int64,
        maxRaw!: Int64,
        minHeight!: Int64,
        maxHeight!: Int64
    ): Array<Int64> {
        if (barCount <= 0) {
            return Array<Int64>(0, { _i: Int64 => minHeight })
        }
        let sampleCount = Int64(samples.size)
        if (sampleCount == 0) {
            return Array<Int64>(barCount, { _i: Int64 => minHeight })
        }
        let realMax: Int64 = if (maxRaw <= 0) { 31 } else { maxRaw }
        let heightRange: Int64 = maxHeight - minHeight
        let immSamples = samples
        return Array<Int64>(barCount, { i: Int64 =>
            let sIdx = i * sampleCount / barCount
            let raw: Int64 = if (sIdx < immSamples.size) { immSamples[sIdx] } else { 0 }
            let h = raw * heightRange / realMax + minHeight
            if (h < minHeight) { minHeight } else if (h > maxHeight) { maxHeight } else { h }
        })
    }

    /**
     * 合并入口：从 Telegram 5-bit packed waveform 字节数据生成显示条高度数组。
     *
     * 无波形数据时用 fallbackSeed 生成伪随机占位波形（避免平坦显示）。
     *
     * @param waveformData  Message.audioWaveform 字节数组
     * @param barCount      目标 bar 数量（建议 20）
     * @param fallbackSeed  无数据时生成伪随机波形的种子（通常用 messageId）
     * @return barCount 个 Int64 高度值，范围 4..24
     */
    public static func getWaveformBars(
        waveformData!: Array<Byte>,
        barCount!: Int64,
        fallbackSeed!: Int64
    ): Array<Int64> {
        let count: Int64 = if (barCount <= 0) { 20 } else { barCount }
        if (waveformData.size == 0) {
            return Array<Int64>(count, { i: Int64 =>
                (fallbackSeed * 7 + i * 13 + 3) % 20 + 4
            })
        }

        let samples = decodeWaveform(bitstream: waveformData, bitsPerSample: 5)
        if (samples.size == 0) {
            return Array<Int64>(count, { i: Int64 =>
                (fallbackSeed * 7 + i * 13 + 3) % 20 + 4
            })
        }

        return generateBars(samples: samples, barCount: count, maxRaw: 31, minHeight: 4, maxHeight: 24)
    }

    /**
     * 截取子波形（对应 iOS AudioWaveform.subwaveform(from:to:)）。
     *
     * @param waveformData  完整波形字节数组
     * @param start         起始比例 0.0..1.0
     * @param end           结束比例 0.0..1.0
     * @return 截取区间的波形字节数组
     */
    public static func subWaveform(waveformData!: Array<Byte>, start!: Float64, end!: Float64): Array<Byte> {
        if (waveformData.size == 0) {
            return Array<Byte>(0, repeat: 0)
        }
        let normStart: Float64 = if (start < 0.0) { 0.0 } else if (start > 1.0) { 1.0 } else { start }
        let normEnd: Float64 = if (end < normStart) { normStart } else if (end > 1.0) { 1.0 } else { end }
        let totalLen = Int64(waveformData.size)
        let startIdx: Int64 = Int64(Float64(totalLen) * normStart)
        let endIdx: Int64 = Int64(Float64(totalLen) * normEnd)
        let rangeLen = endIdx - startIdx
        if (rangeLen <= 0) {
            return Array<Byte>(0, repeat: 0)
        }
        let immData = waveformData
        return Array<Byte>(rangeLen, { i: Int64 => immData[startIdx + i] })
    }

    /**
     * 编码采样数组为 5-bit packed bitstream（对应 iOS AudioWaveform.makeBitstream()）。
     *
     * 每个采样 0..peak 归一化到 0..31 后，5 bits 小端打包写入结果字节数组。
     *
     * @param samples  Int16 采样数组（范围任意，按 peak 归一化）
     * @param peak     采样最大峰值（对应 iOS self.peak，通常为 31）
     * @return 5-bit packed bitstream 字节数组
     */
    public static func makeBitstream(samples!: Array<Int64>, peak!: Int64): Array<Byte> {
        let numSamples = Int64(samples.size)
        if (numSamples == 0) {
            return Array<Byte>(0, repeat: 0)
        }
        let bitstreamLen: Int64 = (numSamples * 5) / 8 + (if ((numSamples * 5) % 8 == 0) { 0 } else { 1 })
        let result = Array<Byte>(bitstreamLen + 4, repeat: 0)
        let maxSample: Int64 = if (peak <= 0) { 1 } else { peak }
        let immSamples = samples

        var i: Int64 = 0
        while (i < numSamples) {
            let raw = immSamples[i]
            let absVal: Int64 = if (raw < 0) { -raw } else { raw }
            var value: Int64 = absVal * 31 / maxSample
            if (value > 31) { value = 31 }
            value = value & 31

            let bitOffset = i * 5
            let byteIdx = bitOffset / 8
            let bitOff = bitOffset % 8
            let cur: Int64 = Int64(result[byteIdx]) & 0xFF
            result[byteIdx] = UInt8((cur | (value << bitOff)) & 0xFF)
            if (bitOff + 5 > 8 && byteIdx + 1 < Int64(result.size)) {
                let cur1: Int64 = Int64(result[byteIdx + 1]) & 0xFF
                result[byteIdx + 1] = UInt8((cur1 | (value >> (8 - bitOff))) & 0xFF)
            }
            i += 1
        }

        return Array<Byte>(bitstreamLen, { idx: Int64 => result[idx] })
    }
}
