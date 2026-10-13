/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 */
package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings, PresentationSnapshot, currentPresentation}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getGlobalAbilityContext
import ohos_app_cangjie_entry.utils.copyText
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import std.collection.ArrayList

/**
 * QrCodeView — 可复用的二维码展示组件 (P2-175)
 *
 * 对应 Telegram-iOS submodules/QrCode：生成 / 展示二维码。
 * 用途：登录 QR（QrLoginPage）、分享链接 QR、邀请 QR 等。
 *
 * TC-0507 round5 前置返修（diag-suite_settings_root-TC-0507-round5.md §四.4/§七 F-A，
 * 合约 idx64）：ArkUI 原生 `QRCode` 组件是终端渲染件——不产出矩阵位图、无 icon/cutout
 * 参数，导致 `shell_chat_misc_components` 的遮罩着色链（A4a/A4b/A4c）与矩阵挖空（A5）
 * 在页面侧结构性不可达。本轮把 `build()` 内部渲染从 `QRCode(this.content)` 换成
 * `Canvas` + `CanvasRenderingContext2D` 自绘：内置一个纯 Cangjie 实现的 QR 编码器
 * （字节模式、Reed-Solomon 纠错、按 ISO/IEC 18004 自动选版本 1-40；不经 CIFilter /
 * 任何平台 QR 库——ArkUI SDK 除声明式 `QRCode` UI 组件外不暴露任何矩阵/编码 API，见
 * `ohos.arkui.component.qrcode.cj.d` 全文核对），矩阵每个暗模块按源
 * `submodules/QrCode/Sources/QrCode.swift:192-210` 的相邻合并规则画圆角矩形
 * （`cornerRadius = 模块边长/3.5`，对位 `:240`），三个定位角标按
 * `QrCode.swift:239-248 drawMarker` 画外环描边 + 内环填充双环。
 *
 * 接口契约（供 `shell_chat_misc_components` 整页重构消费，对位报告 §5.2/§七 F-A "新增出参"）：
 *   - `public class QrMatrixData { size: Int64; modules: Array<Array<Bool>> }`
 *     —— 原始矩阵数据（`modules[y][x]==true` 表示该模块为暗/前景）。
 *   - `public func generateQrCodeMatrix(content: String, ecl: String, cutoutCenter: Bool): ?QrMatrixData`
 *     —— 只编码不渲染，供调用方自行合成（如需要位图以外的用途）。
 *   - `public func drawQrCodeMatrix(ctx: CanvasRenderingContext2D, content: String, canvasSize: Float64,
 *      color: UInt32, backgroundColor: ?UInt32, ecl: String, cutoutCenter: Bool, contentOpacity: Float64): Bool`
 *     —— 编码 + 直接画进调用方提供的、已挂载 Canvas 节点的 `ctx`（同 D-190：ctx 必须与其
 *     Canvas 节点同生命周期，参见本文件 `QrCodeView` 自身用法）。返回 `false` 表示内容为空
 *     或编码失败（已 `clearRect`/按需填 `backgroundColor`，未画任何矩阵内容）。画完后调用方
 *     可自行 `ctx.getPixelMap(0.0, 0.0, canvasSize, canvasSize)` 取位图，配合既有先例
 *     `pages/ChatQrCodeSharePage.cj:571 drawQrHoleMark()` 的
 *     `globalCompositeOperation = "destination-out"` 挖空技法，把该位图当 alpha 遮罩消费——
 *     即 RC-1 遮罩着色链缺的"码图"那一块。
 *   - `cutoutCenter: Bool` —— true 时按 iOS `qrCodeCutout(size:dimensions:scale:)`
 *     （`QrCode.swift:25-38`）等价的模块坐标公式，在矩阵**编码结果层**（不是事后盖一个白
 *     方块）把中心一块方形区域的模块强制置空，尺寸/位置随二维码版本自动换算、调用方无需
 *     传入像素坐标。这就是 A5"矩阵挖空"的能力来源；圆盘底 + logo 图形叠加仍是页面侧职责
 *     （F-C2），本组件不画圆底、不画 logo。
 *   - `ecl: String` —— 纠错级别 "L"/"M"/"Q"/"H"，默认 "M"（对位 `QrCode.swift:41` 默认值）；
 *     分享屏按报告要求应显式传 "Q"（对位 `ChatQrCodeScreen.swift:1815`）。
 *
 * 已知简化（诚实记录，均不影响矩阵数据正确性/可解码性/挖空能力，纯视觉打磨或空间效率项）：
 *   1. 掩码固定用 mask 0（`(x+y)%2==0` 翻转），不做 8 种掩码的自动最优选择/惩罚评分。
 *      QR 规范允许任意合法掩码，牺牲的只是最优可读性余量。
 *   2. 只做暗模块的相邻合并圆角（对位源 `:192-210`），不做亮模块在暗模块 L 形夹角处的
 *      凹角平滑（源 `:212-226`）——纯视觉打磨项。
 *   3. 编码固定字节模式，用 `String.toArray()`（UTF-8 字节），不做数字/字母数字模式优化
 *      （更短内容可用更省空间的模式）；不影响正确性，只是版本可能选得比理论最优略大。
 *   4. 未做自动 ECL 提升（源侧同版本能容纳更高纠错级别时会自动升级）；本组件按调用方传入
 *      的 `ecl` 精确使用，不做隐式升档。
 *
 * cangjie-kb 降级声明：本轮 Milvus 不可达（`ModuleNotFoundError: openjiuwen`，同
 * `syntax_error.md:1836` 记录的既有降级模式）。本文件新增的全部 Canvas 2D API
 * （`beginPath`/`moveTo`/`lineTo`/`arcTo`/`closePath`/`fill`/`stroke`/`fillRect`/
 * `clearRect`/`fillStyle`/`strokeStyle`/`lineWidth`/`globalAlpha`）均非新引入——均已在本仓
 * `components/MessageBubble.cj`（`MessageBubbleShape.drawBubbleCanvas`）、
 * `components/WallpaperBackgroundComponent.cj`、`pages/ChatQrCodeSharePage.cj:549-582
 * drawQrHoleMark()`、`services/DrawingFlattenService.cj` 有编译通过的真实调用点先例，逐一
 * 交叉核对签名后直接复用，非凭经验臆造。QR 编码算法本身（Reed-Solomon 纠错、版本容量表、
 * 掩码/格式位公式）不是 SDK API 问题，是 ISO/IEC 18004 公开规范的纯 Cangjie 重实现——版本
 * 容量表、纠错分块表、Reed-Solomon 生成多项式算法均据 Project Nayuki 的 QR Code generator
 * library（MIT/public domain 参考实现，逐值核对而非凭记忆转录，因数值属规范事实、非可版权
 * 表达）转译为本仓 Cangjie 风格；GF(256) 乘法沿用本仓 `core/mtproto/CryptoUtils.cj:559 gmul`
 * 同款"移位前测高位、移位后条件异或既约多项式"写法（仅既约常数从 AES 的 `0x1b` 换成 QR 的
 * `0x1D`，对应 `0x11D`/`0x11B` 两套不同生成多项式）。
 *
 * 新增（P2-175）：showCenterLogo=true 时在 QR 中心叠加圆形 Telegram logo（Stack 布局，
 * 与矩阵挖空是两套独立机制——该项是纯视觉叠加，不动矩阵；矩阵级挖空走 cutoutCenter）。
 *
 * Props（@Component 基本类型参数用普通 var + 默认值，不用 @Prop——原实现即如此，保持向后
 * 兼容：三个既有调用点 `pages/QrLoginPage.cj:166` / `pages/ChatQrCodeSharePage.cj:803` /
 * 本文件 `ChatLinkQRPage.buildQrSection` 均只传 content/size/showCenterLogo 中的一部分，
 * 其余全部吃默认值——新增的 ecl/cutoutCenter 同理仅追加默认值，不改变调用点语义）：
 *   content:         二维码内容字符串
 *   size:            正方形边长（vp，宽=高），默认 200
 *   color:           前景色（0xRRGGBB），默认黑
 *   backgroundColor: 背景色（0xRRGGBB），默认白
 *   contentOpacity:  码点不透明度，默认 1.0
 *   showCenterLogo:  是否在中心叠加 Telegram logo（视觉叠加，非矩阵挖空），默认 false
 *   ecl:             纠错级别 "L"/"M"/"Q"/"H"，默认 "M"
 *   cutoutCenter:    是否在矩阵编码结果层挖空中心区域，默认 false
 */

// ═════════════════════════════════════════════════════════════════════════════
// QR 编码器（纯 Cangjie 实现，字节模式 + Reed-Solomon，对位 ISO/IEC 18004）
//
// 版本容量表 / 纠错分块表 / 生成多项式算法均据 Project Nayuki 的公开参考实现逐值核对
// 转译（数值属规范事实，非可版权表达）；GF(256) 乘法写法同款
// `core/mtproto/CryptoUtils.cj:559 gmul`（既约常数换成 QR 的 0x1D，对应生成多项式 0x11D）。
// 掩码固定用 mask 0，不做自动最优选择；不做亮模块凹角平滑（见本文件头部"已知简化"）。
// ═════════════════════════════════════════════════════════════════════════════

/** 纠错分块表：ECC_CODEWORDS_PER_BLOCK[eclOrdinal(L=0,M=1,Q=2,H=3)][version(1-40)]，index 0 占位未用。 */
private let ECC_CODEWORDS_PER_BLOCK: Array<Array<Int64>> = [
    [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
    [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30]
]

/** 纠错分块数表：NUM_ERROR_CORRECTION_BLOCKS[eclOrdinal][version]，index 0 占位未用。 */
private let NUM_ERROR_CORRECTION_BLOCKS: Array<Array<Int64>> = [
    [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
    [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
    [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
    [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81]
]

private func i64Abs(v: Int64): Int64 {
    if (v < 0) {
        return -v
    }
    return v
}

private func i64Max(a: Int64, b: Int64): Int64 {
    if (a > b) {
        return a
    }
    return b
}

private func i64Min(a: Int64, b: Int64): Int64 {
    if (a < b) {
        return a
    }
    return b
}

private func qrEclOrdinal(ecl: String): Int64 {
    if (ecl == "L") {
        return 0
    }
    if (ecl == "Q") {
        return 2
    }
    if (ecl == "H") {
        return 3
    }
    return 1 // "M" 默认，未识别值同样回落 M
}

private func qrEclFormatBits(ecl: String): Int64 {
    if (ecl == "L") {
        return 1
    }
    if (ecl == "Q") {
        return 3
    }
    if (ecl == "H") {
        return 2
    }
    return 0 // "M"
}

/** GF(256) 乘法（既约多项式 0x11D），同款 CryptoUtils.cj:559 gmul 写法。 */
private func qrGf256Multiply(x: UInt8, y: UInt8): UInt8 {
    var z: UInt8 = 0
    var i: Int64 = 7
    while (i >= 0) {
        let carry = (z & 0x80) != 0
        z = z << 1
        if (carry) {
            z = z ^ 0x1D
        }
        let yBit = (y >> UInt8(i)) & 1
        if (yBit != 0) {
            z = z ^ x
        }
        i = i - 1
    }
    return z
}

/** Reed-Solomon 生成多项式（度数=纠错码字数），系数从高到低存储，隐去最高项系数 1。 */
private func qrReedSolomonDivisor(degree: Int64): Array<UInt8> {
    var result = Array<UInt8>(degree, { _ => 0 })
    result[degree - 1] = 1
    var root: UInt8 = 1
    var i: Int64 = 0
    while (i < degree) {
        var j: Int64 = 0
        while (j < degree) {
            result[j] = qrGf256Multiply(result[j], root)
            if (j + 1 < degree) {
                result[j] = result[j] ^ result[j + 1]
            }
            j = j + 1
        }
        root = qrGf256Multiply(root, 2)
        i = i + 1
    }
    return result
}

/** 多项式除法求 Reed-Solomon 纠错余式。 */
private func qrReedSolomonRemainder(data: Array<UInt8>, divisor: Array<UInt8>): Array<UInt8> {
    let divLen = divisor.size
    var result = Array<UInt8>(divLen, { _ => 0 })
    var di: Int64 = 0
    while (di < data.size) {
        let factor = data[di] ^ result[0]
        var k: Int64 = 0
        while (k < divLen - 1) {
            result[k] = result[k + 1]
            k = k + 1
        }
        result[divLen - 1] = 0
        var m: Int64 = 0
        while (m < divLen) {
            result[m] = result[m] ^ qrGf256Multiply(divisor[m], factor)
            m = m + 1
        }
        di = di + 1
    }
    return result
}

/** 按 bit 顺序累积的写入器，最终打包为大端字节数组（对位 Nayuki `_BitBuffer`）。 */
private class QrBitWriter {
    private var bits: ArrayList<Bool> = ArrayList<Bool>()

    public func appendBits(val: Int64, n: Int64): Unit {
        var i = n - 1
        while (i >= 0) {
            let bit = ((val >> i) & 1) != 0
            this.bits.add(bit)
            i = i - 1
        }
    }

    public func bitCount(): Int64 {
        return this.bits.size
    }

    public func toBytes(): Array<UInt8> {
        let numBytes = (this.bits.size + 7) / 8
        var result = Array<UInt8>(numBytes, { _ => 0 })
        var i: Int64 = 0
        while (i < this.bits.size) {
            if (this.bits.get(i).getOrThrow()) {
                let byteIndex = i / 8
                let bitIndex = 7 - (i % 8)
                result[byteIndex] = result[byteIndex] | UInt8(1 << bitIndex)
            }
            i = i + 1
        }
        return result
    }
}

private func qrNumRawDataModules(ver: Int64): Int64 {
    var result = (16 * ver + 128) * ver + 64
    if (ver >= 2) {
        let numAlign = ver / 7 + 2
        result = result - ((25 * numAlign - 10) * numAlign - 55)
        if (ver >= 7) {
            result = result - 36
        }
    }
    return result
}

private func qrNumDataCodewords(ver: Int64, eclOrdinal: Int64): Int64 {
    return qrNumRawDataModules(ver) / 8 - ECC_CODEWORDS_PER_BLOCK[eclOrdinal][ver] * NUM_ERROR_CORRECTION_BLOCKS[eclOrdinal][ver]
}

/** 字节模式字符计数字段位宽：版本 1-9 用 8 位，10-40 用 16 位（对位 Nayuki Mode.BYTE charcounts）。 */
private func qrByteModeCharCountBits(ver: Int64): Int64 {
    if (ver <= 9) {
        return 8
    }
    return 16
}

/** 找能容纳该字节长度数据的最小版本（1-40），找不到返回 None（内容超出该纠错级别下的最大容量）。 */
private func qrSelectVersion(dataByteLen: Int64, eclOrdinal: Int64): ?Int64 {
    var ver: Int64 = 1
    while (ver <= 40) {
        let ccBits = qrByteModeCharCountBits(ver)
        let maxChars: Int64 = 1 << ccBits
        if (dataByteLen < maxChars) {
            let usedBits = 4 + ccBits + dataByteLen * 8
            let capBits = qrNumDataCodewords(ver, eclOrdinal) * 8
            if (usedBits <= capBits) {
                return Some(ver)
            }
        }
        ver = ver + 1
    }
    return None
}

/** 组装数据码字：模式指示符(0x4=字节模式) + 字符计数 + 数据 + 终止符 + 补齐到字节边界 + 交替填充字节。 */
private func qrBuildDataCodewords(dataBytes: Array<UInt8>, ver: Int64, eclOrdinal: Int64): Array<UInt8> {
    let bw = QrBitWriter()
    bw.appendBits(4, 4)
    let ccBits = qrByteModeCharCountBits(ver)
    bw.appendBits(dataBytes.size, ccBits)
    var i: Int64 = 0
    while (i < dataBytes.size) {
        bw.appendBits(Int64(dataBytes[i]), 8)
        i = i + 1
    }
    let capBits = qrNumDataCodewords(ver, eclOrdinal) * 8
    let termBits = i64Min(4, capBits - bw.bitCount())
    if (termBits > 0) {
        bw.appendBits(0, termBits)
    }
    let rem = bw.bitCount() % 8
    if (rem != 0) {
        bw.appendBits(0, 8 - rem)
    }
    var toggle = true
    while (bw.bitCount() < capBits) {
        if (toggle) {
            bw.appendBits(0xEC, 8)
        } else {
            bw.appendBits(0x11, 8)
        }
        toggle = !toggle
    }
    return bw.toBytes()
}

/** 分块加纠错码 + 按列交织（对位 Nayuki `_add_ecc_and_interleave`）。 */
private func qrAddEccAndInterleave(data: Array<UInt8>, ver: Int64, eclOrdinal: Int64): Array<UInt8> {
    let numBlocks = NUM_ERROR_CORRECTION_BLOCKS[eclOrdinal][ver]
    let blockEccLen = ECC_CODEWORDS_PER_BLOCK[eclOrdinal][ver]
    let rawCodewords = qrNumRawDataModules(ver) / 8
    let numShortBlocks = numBlocks - (rawCodewords % numBlocks)
    let shortBlockLen = rawCodewords / numBlocks
    let rsdiv = qrReedSolomonDivisor(blockEccLen)

    var blocks = Array<Array<UInt8>>(numBlocks, { _ => Array<UInt8>(0, { _ => 0 }) })
    var k: Int64 = 0
    var bi: Int64 = 0
    while (bi < numBlocks) {
        let isShort = bi < numShortBlocks
        let extra = if (isShort) { 0 } else { 1 }
        let datLen = shortBlockLen - blockEccLen + extra
        // S-139: Array 初始化闭包不能捕获外层 var（"needs to be called directly"），先把
        // 当轮的 k 值过一道 let 重绑定成不可变副本再进闭包。
        let kFixed = k
        let dat = Array<UInt8>(datLen, { idx => data[kFixed + idx] })
        k = k + datLen
        let ecc = qrReedSolomonRemainder(dat, rsdiv)
        let padExtra = if (isShort) { 1 } else { 0 }
        let blockLen = datLen + padExtra + blockEccLen
        var block = Array<UInt8>(blockLen, { _ => 0 })
        var p: Int64 = 0
        while (p < datLen) {
            block[p] = dat[p]
            p = p + 1
        }
        let eccStart = datLen + padExtra
        var q: Int64 = 0
        while (q < ecc.size) {
            block[eccStart + q] = ecc[q]
            q = q + 1
        }
        blocks[bi] = block
        bi = bi + 1
    }

    let blockArrLen = blocks[0].size
    var result = Array<UInt8>(rawCodewords, { _ => 0 })
    var ri: Int64 = 0
    var col: Int64 = 0
    while (col < blockArrLen) {
        var j: Int64 = 0
        while (j < numBlocks) {
            let skip = (col == shortBlockLen - blockEccLen) && (j < numShortBlocks)
            if (!skip) {
                result[ri] = blocks[j][col]
                ri = ri + 1
            }
            j = j + 1
        }
        col = col + 1
    }
    return result
}

private func qrSetFunctionModule(modules: Array<Array<Bool>>, isFunction: Array<Array<Bool>>, x: Int64, y: Int64, dark: Bool): Unit {
    modules[y][x] = dark
    isFunction[y][x] = true
}

private func qrDrawFinderPattern(modules: Array<Array<Bool>>, isFunction: Array<Array<Bool>>, size: Int64, cx: Int64, cy: Int64): Unit {
    var dy: Int64 = -4
    while (dy <= 4) {
        var dx: Int64 = -4
        while (dx <= 4) {
            let xx = cx + dx
            let yy = cy + dy
            if (xx >= 0 && xx < size && yy >= 0 && yy < size) {
                let d = i64Max(i64Abs(dx), i64Abs(dy))
                let dark = d != 2 && d != 4
                qrSetFunctionModule(modules, isFunction, xx, yy, dark)
            }
            dx = dx + 1
        }
        dy = dy + 1
    }
}

private func qrDrawAlignmentPattern(modules: Array<Array<Bool>>, isFunction: Array<Array<Bool>>, cx: Int64, cy: Int64): Unit {
    var dy: Int64 = -2
    while (dy <= 2) {
        var dx: Int64 = -2
        while (dx <= 2) {
            let d = i64Max(i64Abs(dx), i64Abs(dy))
            let dark = d != 1
            qrSetFunctionModule(modules, isFunction, cx + dx, cy + dy, dark)
            dx = dx + 1
        }
        dy = dy + 1
    }
}

private func qrAlignmentPositions(ver: Int64, size: Int64): Array<Int64> {
    if (ver == 1) {
        return Array<Int64>(0, { _ => 0 })
    }
    let numAlign = ver / 7 + 2
    let step = (ver * 8 + numAlign * 3 + 5) / (numAlign * 4 - 4) * 2
    var raw = Array<Int64>(numAlign, { _ => 0 })
    var i: Int64 = 0
    while (i < numAlign - 1) {
        raw[i] = size - 7 - i * step
        i = i + 1
    }
    raw[numAlign - 1] = 6
    var result = Array<Int64>(numAlign, { _ => 0 })
    var k: Int64 = 0
    while (k < numAlign) {
        result[k] = raw[numAlign - 1 - k]
        k = k + 1
    }
    return result
}

private func qrGetBit(x: Int64, i: Int64): Bool {
    return ((x >> i) & 1) != 0
}

/** 格式信息双拷贝（纠错级别 + 固定 mask=0），对位 Nayuki `_draw_format_bits`。 */
private func qrDrawFormatBits(modules: Array<Array<Bool>>, isFunction: Array<Array<Bool>>, size: Int64, eclFormatBits: Int64): Unit {
    let data = (eclFormatBits << 3) | 0
    var rem = data
    var t: Int64 = 0
    while (t < 10) {
        rem = (rem << 1) ^ ((rem >> 9) * 0x537)
        t = t + 1
    }
    let bits = ((data << 10) | rem) ^ 0x5412

    var i: Int64 = 0
    while (i < 6) {
        qrSetFunctionModule(modules, isFunction, 8, i, qrGetBit(bits, i))
        i = i + 1
    }
    qrSetFunctionModule(modules, isFunction, 8, 7, qrGetBit(bits, 6))
    qrSetFunctionModule(modules, isFunction, 8, 8, qrGetBit(bits, 7))
    qrSetFunctionModule(modules, isFunction, 7, 8, qrGetBit(bits, 8))
    var j: Int64 = 9
    while (j < 15) {
        qrSetFunctionModule(modules, isFunction, 14 - j, 8, qrGetBit(bits, j))
        j = j + 1
    }
    var k: Int64 = 0
    while (k < 8) {
        qrSetFunctionModule(modules, isFunction, size - 1 - k, 8, qrGetBit(bits, k))
        k = k + 1
    }
    var m: Int64 = 8
    while (m < 15) {
        qrSetFunctionModule(modules, isFunction, 8, size - 15 + m, qrGetBit(bits, m))
        m = m + 1
    }
    qrSetFunctionModule(modules, isFunction, 8, size - 8, true)
}

/** 版本信息双拷贝（仅 version>=7），对位 Nayuki `_draw_version`。 */
private func qrDrawVersionBits(modules: Array<Array<Bool>>, isFunction: Array<Array<Bool>>, size: Int64, ver: Int64): Unit {
    var rem = ver
    var t: Int64 = 0
    while (t < 12) {
        rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
        t = t + 1
    }
    let bits = (ver << 12) | rem
    var i: Int64 = 0
    while (i < 18) {
        let bit = qrGetBit(bits, i)
        let a = size - 11 + i % 3
        let b = i / 3
        qrSetFunctionModule(modules, isFunction, a, b, bit)
        qrSetFunctionModule(modules, isFunction, b, a, bit)
        i = i + 1
    }
}

private func qrDrawFunctionPatterns(modules: Array<Array<Bool>>, isFunction: Array<Array<Bool>>, size: Int64, ver: Int64, eclFormatBits: Int64): Unit {
    var i: Int64 = 0
    while (i < size) {
        let dark = i % 2 == 0
        qrSetFunctionModule(modules, isFunction, 6, i, dark)
        qrSetFunctionModule(modules, isFunction, i, 6, dark)
        i = i + 1
    }
    qrDrawFinderPattern(modules, isFunction, size, 3, 3)
    qrDrawFinderPattern(modules, isFunction, size, size - 4, 3)
    qrDrawFinderPattern(modules, isFunction, size, 3, size - 4)

    let alignPos = qrAlignmentPositions(ver, size)
    let numAlign = alignPos.size
    var ai: Int64 = 0
    while (ai < numAlign) {
        var aj: Int64 = 0
        while (aj < numAlign) {
            let isCorner = (ai == 0 && aj == 0) || (ai == 0 && aj == numAlign - 1) || (ai == numAlign - 1 && aj == 0)
            if (!isCorner) {
                qrDrawAlignmentPattern(modules, isFunction, alignPos[ai], alignPos[aj])
            }
            aj = aj + 1
        }
        ai = ai + 1
    }

    qrDrawFormatBits(modules, isFunction, size, eclFormatBits)
    if (ver >= 7) {
        qrDrawVersionBits(modules, isFunction, size, ver)
    }
}

/**
 * 之字形扫描填充码字位，固定用 mask 0（`(x+y)%2==0` 翻转）就地异或。cutoutStart/cutoutEnd
 * >=0 时，落在该模块坐标开区间内的模块强制置空（挖空发生在编码结果层：底层 bit 仍按位流
 * 正常推进/计数，只是渲染用的 modules[][] 被覆写——对位源 `QrCode.swift:91-107 valueAt`
 * 的 cutout 处理：编码不受影响，只有"这一块要不要画出来"受影响）。
 */
private func qrPlaceCodewords(
    modules: Array<Array<Bool>>,
    isFunction: Array<Array<Bool>>,
    size: Int64,
    data: Array<UInt8>,
    cutoutStart: Int64,
    cutoutEnd: Int64
): Unit {
    var i: Int64 = 0
    var trueRight = size - 1
    while (trueRight > 0) {
        var right = trueRight
        if (right <= 6) {
            right = right - 1
        }
        var vert: Int64 = 0
        while (vert < size) {
            var j: Int64 = 0
            while (j < 2) {
                let x = right - j
                let upward = ((right + 1) & 2) == 0
                let y = if (upward) { size - 1 - vert } else { vert }
                if (!isFunction[y][x] && i < data.size * 8) {
                    let byteIdx = i / 8
                    let bitIdx = 7 - (i % 8)
                    var bitVal = ((data[byteIdx] >> UInt8(bitIdx)) & 1) != 0
                    if ((x + y) % 2 == 0) {
                        bitVal = !bitVal
                    }
                    if (cutoutStart >= 0 && x > cutoutStart && x < cutoutEnd && y > cutoutStart && y < cutoutEnd) {
                        modules[y][x] = false
                    } else {
                        modules[y][x] = bitVal
                    }
                    i = i + 1
                }
                j = j + 1
            }
            vert = vert + 1
        }
        trueRight = trueRight - 2
    }
}

/** 中心挖空的模块坐标范围（开区间），对位 iOS `QrCode.swift:25-38 qrCodeCutout` 的模块空间部分。 */
private func qrCutoutModuleRange(size: Int64): (Int64, Int64) {
    var cutoutSize = Int64(Float64(size) * 0.297 + 0.5)
    if (size == 39) {
        cutoutSize = 11
    } else if (cutoutSize % 2 == 0) {
        cutoutSize = cutoutSize + 1
    }
    if (cutoutSize > 23) {
        cutoutSize = 23
    }
    let start = (size - cutoutSize) / 2
    let end = start + cutoutSize - 1
    return (start, end)
}

/** 二维码矩阵数据（`modules[y][x]==true` 表示该模块为暗/前景）。见文件头"接口契约"。 */
public class QrMatrixData {
    public let size: Int64
    public let modules: Array<Array<Bool>>

    public init(size: Int64, modules: Array<Array<Bool>>) {
        this.size = size
        this.modules = modules
    }
}

/** 只编码不渲染。见文件头"接口契约"。 */
public func generateQrCodeMatrix(content: String, ecl: String, cutoutCenter: Bool): ?QrMatrixData {
    if (content.isEmpty()) {
        return None
    }
    let eclOrdinal = qrEclOrdinal(ecl)
    let eclFormatBits = qrEclFormatBits(ecl)
    let dataBytes: Array<UInt8> = content.toArray()
    match (qrSelectVersion(dataBytes.size, eclOrdinal)) {
        case None => return None
        case Some(ver) =>
            let size = ver * 4 + 17
            let modules = Array<Array<Bool>>(size, { _ => Array<Bool>(size, repeat: false) })
            let isFunction = Array<Array<Bool>>(size, { _ => Array<Bool>(size, repeat: false) })
            qrDrawFunctionPatterns(modules, isFunction, size, ver, eclFormatBits)
            let dataCodewords = qrBuildDataCodewords(dataBytes, ver, eclOrdinal)
            let allCodewords = qrAddEccAndInterleave(dataCodewords, ver, eclOrdinal)
            var cutoutStart: Int64 = -1
            var cutoutEnd: Int64 = -1
            if (cutoutCenter) {
                let range = qrCutoutModuleRange(size)
                cutoutStart = range[0]
                cutoutEnd = range[1]
            }
            qrPlaceCodewords(modules, isFunction, size, allCodewords, cutoutStart, cutoutEnd)
            return Some(QrMatrixData(size, modules))
    }
}

/** 统一圆角矩形路径（每角可独立开关），MessageBubbleShape 同款 moveTo/arcTo/lineTo 写法。 */
private func qrDrawRoundedRectPath(
    ctx: CanvasRenderingContext2D,
    x: Float64, y: Float64, w: Float64, h: Float64, r: Float64,
    tl: Bool, tr: Bool, br: Bool, bl: Bool
): Unit {
    let rtl = if (tl) { r } else { 0.0 }
    let rtr = if (tr) { r } else { 0.0 }
    let rbr = if (br) { r } else { 0.0 }
    let rbl = if (bl) { r } else { 0.0 }
    ctx.beginPath()
    ctx.moveTo(x + rtl, y)
    ctx.lineTo(x + w - rtr, y)
    if (tr) {
        ctx.arcTo(x + w, y, x + w, y + rtr, rtr)
    } else {
        ctx.lineTo(x + w, y)
    }
    ctx.lineTo(x + w, y + h - rbr)
    if (br) {
        ctx.arcTo(x + w, y + h, x + w - rbr, y + h, rbr)
    } else {
        ctx.lineTo(x + w, y + h)
    }
    ctx.lineTo(x + rbl, y + h)
    if (bl) {
        ctx.arcTo(x, y + h, x, y + h - rbl, rbl)
    } else {
        ctx.lineTo(x, y + h)
    }
    ctx.lineTo(x, y + rtl)
    if (tl) {
        ctx.arcTo(x, y, x + rtl, y, rtl)
    } else {
        ctx.lineTo(x, y)
    }
    ctx.closePath()
}

private func qrIsInFinderZone(x: Int64, y: Int64, size: Int64): Bool {
    if (x <= 6 && y <= 6) {
        return true
    }
    if (x >= size - 7 && y <= 6) {
        return true
    }
    if (x <= 6 && y >= size - 7) {
        return true
    }
    return false
}

/** 暗模块相邻合并圆角绘制（跳过 3 个定位角标区域，交给 qrDrawFinderMarker 双环处理）。 */
private func qrDrawModulesGeneric(ctx: CanvasRenderingContext2D, modules: Array<Array<Bool>>, size: Int64, moduleSize: Float64): Unit {
    var y: Int64 = 0
    while (y < size) {
        var x: Int64 = 0
        while (x < size) {
            if (!qrIsInFinderZone(x, y, size) && modules[y][x]) {
                let leftDark = x > 0 && modules[y][x - 1]
                let rightDark = x < size - 1 && modules[y][x + 1]
                let topDark = y > 0 && modules[y - 1][x]
                let bottomDark = y < size - 1 && modules[y + 1][x]
                var tl = true
                var tr = true
                var bl = true
                var br = true
                if (topDark) {
                    tl = false
                    tr = false
                }
                if (bottomDark) {
                    bl = false
                    br = false
                }
                if (leftDark) {
                    tl = false
                    bl = false
                }
                if (rightDark) {
                    tr = false
                    br = false
                }
                let px = Float64(x) * moduleSize
                let py = Float64(y) * moduleSize
                let r = moduleSize / 3.5
                qrDrawRoundedRectPath(ctx, px, py, moduleSize, moduleSize, r, tl, tr, br, bl)
                ctx.fill()
            }
            x = x + 1
        }
        y = y + 1
    }
}

/** 定位角标双环：外环描边 + 内环填充，对位 `QrCode.swift:239-248 drawMarker`（半径公式 side/3.5）。 */
private func qrDrawFinderMarker(ctx: CanvasRenderingContext2D, boxLeft: Int64, boxTop: Int64, moduleSize: Float64, color: UInt32): Unit {
    let px = Float64(boxLeft) * moduleSize
    let py = Float64(boxTop) * moduleSize
    let outerSide = 7.0 * moduleSize
    let ringWidth = moduleSize
    let ringRadius = outerSide / 3.5
    let ringInset = ringWidth / 2.0
    ctx.lineWidth = ringWidth
    ctx.strokeStyle = color
    qrDrawRoundedRectPath(ctx, px + ringInset, py + ringInset, outerSide - ringWidth, outerSide - ringWidth, ringRadius, true, true, true, true)
    ctx.stroke()

    let dotSide = 3.0 * moduleSize
    let dotRadius = dotSide / 3.5
    let dotX = px + 2.0 * moduleSize
    let dotY = py + 2.0 * moduleSize
    ctx.fillStyle = color
    qrDrawRoundedRectPath(ctx, dotX, dotY, dotSide, dotSide, dotRadius, true, true, true, true)
    ctx.fill()
}

private func qrRenderToCanvas(
    ctx: CanvasRenderingContext2D,
    modules: Array<Array<Bool>>,
    size: Int64,
    canvasSize: Float64,
    color: UInt32,
    backgroundColor: ?UInt32,
    contentOpacity: Float64
): Unit {
    ctx.clearRect(0.0, 0.0, canvasSize, canvasSize)
    ctx.globalAlpha = 1.0
    match (backgroundColor) {
        case Some(bg) =>
            ctx.fillStyle = bg
            ctx.fillRect(0.0, 0.0, canvasSize, canvasSize)
        case None => ()
    }
    let moduleSize = canvasSize / Float64(size)
    ctx.globalAlpha = contentOpacity
    ctx.fillStyle = color
    qrDrawModulesGeneric(ctx, modules, size, moduleSize)
    qrDrawFinderMarker(ctx, 0, 0, moduleSize, color)
    qrDrawFinderMarker(ctx, size - 7, 0, moduleSize, color)
    qrDrawFinderMarker(ctx, 0, size - 7, moduleSize, color)
    ctx.globalAlpha = 1.0
}

/** 编码 + 直接画进调用方提供的 ctx。见文件头"接口契约"。返回 false 表示未画任何内容。 */
public func drawQrCodeMatrix(
    ctx: CanvasRenderingContext2D,
    content: String,
    canvasSize: Float64,
    color: UInt32,
    backgroundColor: ?UInt32,
    ecl: String,
    cutoutCenter: Bool,
    contentOpacity: Float64
): Bool {
    match (generateQrCodeMatrix(content, ecl, cutoutCenter)) {
        case None =>
            ctx.clearRect(0.0, 0.0, canvasSize, canvasSize)
            match (backgroundColor) {
                case Some(bg) =>
                    ctx.globalAlpha = 1.0
                    ctx.fillStyle = bg
                    ctx.fillRect(0.0, 0.0, canvasSize, canvasSize)
                case None => ()
            }
            return false
        case Some(matrix) =>
            qrRenderToCanvas(ctx, matrix.modules, matrix.size, canvasSize, color, backgroundColor, contentOpacity)
            return true
    }
}

@Component
public class QrCodeView {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    var content: String = ""
    var size: Int64 = 200
    var color: UInt32 = 0x000000
    var backgroundColor: UInt32 = 0xFFFFFF
    var contentOpacity: Float64 = 1.0
    var showCenterLogo: Bool = false
    var ecl: String = "M"
    var cutoutCenter: Bool = false

    // D-190：ctx 必须与它的 Canvas 节点同生命周期，声明在这里与下面 build() 里的 Canvas
    // 节点由同一次构造产出（同 MessageBubbleShape/WallpaperBackgroundComponent 先例）。
    private let qrCtx: CanvasRenderingContext2D = CanvasRenderingContext2D(
        RenderingContextSettings(antialias: true)
    )

    // 重绘去重键：普通 var（非 @State），只做比对，不触发新一轮 build()。
    private var paintedContent: String = ""
    private var paintedSize: Int64 = -1
    private var paintedColor: UInt32 = 0
    private var paintedBackgroundColor: UInt32 = 0
    private var paintedContentOpacity: Float64 = -1.0
    private var paintedEcl: String = ""
    private var paintedCutoutCenter: Bool = false

    /** 无条件按当前值重绘并记账。onReady 走这条：那一刻探针可能已经记过账但画布还没挂上。 */
    private func paintQr(): Unit {
        this.paintedContent = this.content
        this.paintedSize = this.size
        this.paintedColor = this.color
        this.paintedBackgroundColor = this.backgroundColor
        this.paintedContentOpacity = this.contentOpacity
        this.paintedEcl = this.ecl
        this.paintedCutoutCenter = this.cutoutCenter
        let _ = drawQrCodeMatrix(
            this.qrCtx, this.content, Float64(this.size), this.color,
            Some(this.backgroundColor), this.ecl, this.cutoutCenter, this.contentOpacity
        )
    }

    /** 任一入参相对"上次真正画出去的那一份"有变化时重绘一次（同 MessageBubbleShape 去重范式）。 */
    private func repaintIfChanged(): String {
        if (this.content != this.paintedContent || this.size != this.paintedSize ||
            this.color != this.paintedColor || this.backgroundColor != this.paintedBackgroundColor ||
            this.contentOpacity != this.paintedContentOpacity || this.ecl != this.paintedEcl ||
            this.cutoutCenter != this.paintedCutoutCenter) {
            this.paintQr()
        }
        return ""
    }

    private func logoSize(): Int64 {
        return Int64(Float64(this.size) * 0.22)
    }

    func build() {
        Stack(alignContent: Alignment.Center) {
            // 零高度探针必须排在 Canvas 之前（同一 build() 内按出现顺序求值），使"值变了就
            // 重画"与 .onReady 成为两条互不依赖的通道（同 MessageBubbleShape 范式）。
            Text(this.repaintIfChanged()).height(0).fontSize(0)
            Canvas(this.qrCtx)
                .width(this.size)
                .height(this.size)
                .onReady({ => this.paintQr() })
            if (this.showCenterLogo) {
                Column {
                    Text("\u{2708}")
                        .fontSize(this.logoSize() / 2)
                        .fontColor(0xFFFFFF)
                }
                .width(this.logoSize())
                .height(this.logoSize())
                .borderRadius(this.logoSize() / 2)
                .backgroundColor(0x29B6F6)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            }
        }
        .width(this.size)
        .height(this.size)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// QrSubjectType — 对应 iOS QrCodeScreen.Subject 四类型
// ─────────────────────────────────────────────────────────────────────────────

/**
 * QR 展示类型（对应 iOS QrCodeScreen.Subject）:
 *   PeerType    — 用户 username 链接：https://t.me/<username>
 *   GroupType   — 群组邀请链接（group invite link）
 *   ChannelType — 频道邀请链接（channel invite link）
 *   ProxyQr     — 代理服务器 tg://proxy?... / https://t.me/proxy?...
 */
public enum QrSubjectType {
    | PeerType
    | GroupType
    | ChannelType
    | ProxyQr
}

// ─────────────────────────────────────────────────────────────────────────────
// chatLinkQRBuildLink — 根据类型构造 QR 内容链接（对应 iOS Subject.link 计算属性）
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 根据 QR 展示类型和参数构造链接字符串。
 *   peer:    "https://t.me/<username>"（对应 iOS Subject.peer）
 *   group/channel: inviteLink 原样（https://t.me/+xxx 格式）
 *   proxy mtp:   "tg://proxy?server=<host>&port=<port>&secret=<secret>"
 *                或 "https://t.me/proxy?server=<host>&port=<port>&secret=<secret>"
 *   proxy socks: "tg://socks?server=<host>&port=<port>[&user=...][&pass=...]"
 *                或 "https://t.me/socks?..."
 */
public func chatLinkQRBuildLink(
    subjectType: QrSubjectType,
    username: String,
    inviteLink: String,
    proxyHost: String,
    proxyPort: String,
    proxyMtp: Bool,
    proxySecret: String,
    proxySocksUser: String,
    proxyPass: String,
    proxyExternal: Bool
): String {
    match (subjectType) {
        case PeerType =>
            if (username.isEmpty()) { return "" }
            return "https://t.me/" + username
        case GroupType | ChannelType =>
            if (inviteLink.isEmpty()) { return "" }
            return inviteLink
        case ProxyQr =>
            if (proxyHost.isEmpty() || proxyPort.isEmpty()) { return "" }
            if (proxyMtp) {
                let schemeBase = if (proxyExternal) { "https://t.me/proxy" } else { "tg://proxy" }
                return schemeBase + "?server=" + proxyHost + "&port=" + proxyPort + "&secret=" + proxySecret
            } else {
                let schemeBase = if (proxyExternal) { "https://t.me/socks" } else { "tg://socks" }
                var link = schemeBase + "?server=" + proxyHost + "&port=" + proxyPort
                if (!proxySocksUser.isEmpty()) {
                    link = link + "&user=" + proxySocksUser
                }
                if (!proxyPass.isEmpty()) {
                    link = link + "&pass=" + proxyPass
                }
                return link
            }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ChatLinkQRPage — 邀请/分享 QR 展示屏 (P2-175 核心 UI)
//
// 对应 iOS QrCodeScreen（submodules/QrCodeUI/Sources/QrCodeScreen.swift）:
//   - 四类型 tab（peer / group / channel / proxy）
//   - QR 码中心 Telegram logo（Stack 叠加 @r(app.media.startIcon)）
//   - 展示时提升屏幕亮度（aboutToAppear: getLastWindow.setWindowBrightness(1.0)）
//   - 分享：copyText 将链接复制到剪贴板（对应 iOS shareQrCode as link）
//   - proxy 类型附带 tg:// / t.me 切换（对应 iOS selectedProxyExternalLink）
//   - 关闭时恢复亮度（setWindowBrightness(-1.0) 还原系统默认）
//
// 路由名：ChatLinkQRPage（需在 MainTabPage.pageMap 注册，见 emitted_integration_contracts）
// ─────────────────────────────────────────────────────────────────────────────

@Component
public class ChatLinkQRPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @Consume var pageStack: NavPathStack

    // ── 输入参数（由路由调用方按 param 约定填充）──
    // peer 类型参数
    var peerUsername: String = ""
    var peerDisplayName: String = ""
    // 群组/频道 invite link（https://t.me/+xxx 格式）
    var groupInviteLink: String = ""
    var channelInviteLink: String = ""
    // proxy 参数（与 ProxyConfig 字段对应）
    var proxyHost: String = ""
    var proxyPort: String = "1080"
    var proxyMtp: Bool = false
    var proxySecret: String = ""
    var proxySocksUser: String = ""
    var proxySocksPass: String = ""

    // ── 页面状态 ──
    @State var selectedTabIndex: Int32 = 0   // 0=peer, 1=group, 2=channel, 3=proxy
    @State var proxyExternalLink: Bool = false
    @State var copyFeedback: String = ""

    // ─── 生命周期 ───

    public func aboutToAppear(): Unit {
        this.adjustBrightness(true)
    }

    public func aboutToDisappear(): Unit {
        this.adjustBrightness(false)
    }

    // ─── 亮度提升（window.setWindowBrightness，非阻塞，失败不影响功能）───

    private func adjustBrightness(boost: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                let _ = spawn {
                    try {
                        let win = getLastWindow(ctx)
                        let brightness = if (boost) { Float32(1.0) } else { Float32(-1.0) }
                        win.setWindowBrightness(brightness)
                        Hilog.info(0, "CjTelegram", "[ChatLinkQRPage] brightness=${brightness}")
                    } catch (_: Exception) {
                        Hilog.warn(0, "CjTelegram", "[ChatLinkQRPage] adjustBrightness non-fatal fail")
                    }
                }
            case None =>
                Hilog.warn(0, "CjTelegram", "[ChatLinkQRPage] no ability context for brightness")
        }
    }

    // ─── QR 链接计算（私有方法，供 @Builder 通过调用拿到结果）───

    private func currentSubjectType(): QrSubjectType {
        if (this.selectedTabIndex == 0) { return QrSubjectType.PeerType }
        if (this.selectedTabIndex == 1) { return QrSubjectType.GroupType }
        if (this.selectedTabIndex == 2) { return QrSubjectType.ChannelType }
        return QrSubjectType.ProxyQr
    }

    private func currentInviteLink(): String {
        if (this.selectedTabIndex == 1) { return this.groupInviteLink }
        if (this.selectedTabIndex == 2) { return this.channelInviteLink }
        return ""
    }

    private func currentQrLink(): String {
        return chatLinkQRBuildLink(
            this.currentSubjectType(),
            this.peerUsername,
            this.currentInviteLink(),
            this.proxyHost,
            this.proxyPort,
            this.proxyMtp,
            this.proxySecret,
            this.proxySocksUser,
            this.proxySocksPass,
            this.proxyExternalLink
        )
    }

    private func isQrLinkEmpty(): Bool {
        return this.currentQrLink().isEmpty()
    }

    // ─── UI 文本 helpers ───

    private func titleText(): String {
        if (this.selectedTabIndex == 0) { return "QR Code" }
        if (this.selectedTabIndex == 3) { return "Proxy QR Code" }
        return "Invite via QR Code"
    }

    private func subtitleText(): String {
        if (this.selectedTabIndex == 0) { return "Scan to open this profile" }
        if (this.selectedTabIndex == 1) { return "Scan to join the group" }
        if (this.selectedTabIndex == 2) { return "Scan to join the channel" }
        return "Scan to use this proxy server"
    }

    private func tabLabel(index: Int32): String {
        if (index == 0) { return "Peer" }
        if (index == 1) { return "Group" }
        if (index == 2) { return "Channel" }
        return "Proxy"
    }

    private func isTabSelected(index: Int32): Bool {
        return this.selectedTabIndex == index
    }

    private func isProxyTab(): Bool {
        return this.selectedTabIndex == 3
    }

    private func qrLinkForDisplay(): String {
        return this.currentQrLink()
    }

    // ─── 动作 ───

    private func performCopyLink(): Unit {
        let link = this.currentQrLink()
        if (link.isEmpty()) {
            launch {
                this.copyFeedback = "No link to copy"
            }
            return
        }
        let ok = copyText(link)
        let msg = if (ok) { "Link copied!" } else { "Copy failed" }
        launch {
            this.copyFeedback = msg
        }
    }

    private func selectTab(index: Int32): Unit {
        this.selectedTabIndex = index
        this.copyFeedback = ""
    }

    // ─── @Builder helpers (禁止 let/var，只有 UI 表达式和方法调用) ───

    @Builder
    func buildTabBar() {
        Row {
            Button(this.tabLabel(0))
                .fontSize(13)
                .fontColor(if (this.isTabSelected(0)) { 0xFFFFFF } else { 0x317AFF })
                .backgroundColor(if (this.isTabSelected(0)) { 0x317AFF } else { 0xEEF4FF })
                .borderRadius(16)
                .height(32)
                .padding(left: 10, right: 10)
                .margin(left: 4, right: 4)
                .onClick({ _ => this.selectTab(0) })
            Button(this.tabLabel(1))
                .fontSize(13)
                .fontColor(if (this.isTabSelected(1)) { 0xFFFFFF } else { 0x317AFF })
                .backgroundColor(if (this.isTabSelected(1)) { 0x317AFF } else { 0xEEF4FF })
                .borderRadius(16)
                .height(32)
                .padding(left: 10, right: 10)
                .margin(left: 4, right: 4)
                .onClick({ _ => this.selectTab(1) })
            Button(this.tabLabel(2))
                .fontSize(13)
                .fontColor(if (this.isTabSelected(2)) { 0xFFFFFF } else { 0x317AFF })
                .backgroundColor(if (this.isTabSelected(2)) { 0x317AFF } else { 0xEEF4FF })
                .borderRadius(16)
                .height(32)
                .padding(left: 10, right: 10)
                .margin(left: 4, right: 4)
                .onClick({ _ => this.selectTab(2) })
            Button(this.tabLabel(3))
                .fontSize(13)
                .fontColor(if (this.isTabSelected(3)) { 0xFFFFFF } else { 0x317AFF })
                .backgroundColor(if (this.isTabSelected(3)) { 0x317AFF } else { 0xEEF4FF })
                .borderRadius(16)
                .height(32)
                .padding(left: 10, right: 10)
                .margin(left: 4, right: 4)
                .onClick({ _ => this.selectTab(3) })
        }
        .justifyContent(FlexAlign.Center)
        .width(100.percent)
        .padding(top: 8, bottom: 4)
    }

    @Builder
    func buildProxyLinkToggle() {
        Row {
            Text(trSource("tg:// link"))
                .fontSize(13)
                .fontColor(if (!this.proxyExternalLink) { 0xFFFFFF } else { 0x317AFF })
                .backgroundColor(if (!this.proxyExternalLink) { 0x317AFF } else { 0xEEF4FF })
                .padding(top: 6, right: 16, bottom: 6, left: 16)
                .borderRadius(14)
                .onClick({ _ =>
                    this.proxyExternalLink = false
                    this.copyFeedback = ""
                })
            Text(trSource("t.me link"))
                .fontSize(13)
                .fontColor(if (this.proxyExternalLink) { 0xFFFFFF } else { 0x317AFF })
                .backgroundColor(if (this.proxyExternalLink) { 0x317AFF } else { 0xEEF4FF })
                .padding(top: 6, right: 16, bottom: 6, left: 16)
                .borderRadius(14)
                .margin(left: 8)
                .onClick({ _ =>
                    this.proxyExternalLink = true
                    this.copyFeedback = ""
                })
        }
        .justifyContent(FlexAlign.Center)
        .width(100.percent)
        .padding(top: 4, bottom: 8)
    }

    @Builder
    func buildQrSection() {
        Column {
            if (this.isQrLinkEmpty()) {
                Column {
                    Text("No link available for this type")
                        .fontSize(13)
                        .fontColor(0x999999)
                        .textAlign(TextAlign.Center)
                }
                .width(240)
                .height(240)
                .borderRadius(20)
                .backgroundColor(0xF5F5F5)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                QrCodeView(
                    content: this.qrLinkForDisplay(),
                    size: 240,
                    showCenterLogo: true
                )
            }
        }
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .width(100.percent)
        .padding(top: 16, bottom: 16)
    }

    @Builder
    func buildLinkLabel() {
        if (!this.isQrLinkEmpty()) {
            Text(this.qrLinkForDisplay())
                .fontSize(11)
                .fontColor(0xAAAAAA)
                .textAlign(TextAlign.Center)
                .maxLines(2)
                .textOverflow(TextOverflow.Ellipsis)
                .width(100.percent)
                .padding(left: 32, right: 32, bottom: 4)
        }
    }

    @Builder
    func buildActions() {
        Column {
            Button(trSource("Copy Link"))
                .width(200)
                .height(44)
                .borderRadius(22)
                .backgroundColor(0x317AFF)
                .fontColor(0xFFFFFF)
                .fontSize(15)
                .onClick({ _ =>
                    this.performCopyLink()
                })
            if (this.copyFeedback.size > 0) {
                Text(this.copyFeedback)
                    .fontSize(13)
                    .fontColor(0x34C759)
                    .margin(top: 8)
            }
        }
        .alignItems(HorizontalAlign.Center)
        .width(100.percent)
        .padding(top: 8, bottom: 24)
    }

    func build() {
        NavDestination() {
            Column {
                Row {
                    Button(trSource("Back"))
                        .width(60)
                        .height(36)
                        .borderRadius(18)
                        .backgroundColor(0xF0F0F0)
                        .fontColor(0x333333)
                        .fontSize(14)
                        .onClick({ _ =>
                            this.pageStack.pop(animated: true)
                        })
                    Blank()
                    Text(this.titleText())
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(0x000000)
                    Blank()
                    Column {}.width(60)
                }
                .width(100.percent)
                .padding(top: 16, left: 16, right: 16, bottom: 8)
                .alignItems(VerticalAlign.Center)

                this.buildTabBar()

                if (this.isProxyTab()) {
                    this.buildProxyLinkToggle()
                }

                this.buildQrSection()

                Text(this.subtitleText())
                    .fontSize(14)
                    .fontColor(0x666666)
                    .textAlign(TextAlign.Center)
                    .padding(left: 32, right: 32, bottom: 4)

                this.buildLinkLabel()
                this.buildActions()
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFFFFFF)
            .alignItems(HorizontalAlign.Center)
        }
        .hideTitleBar(true)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ProxyQrSharePage — ic_proxy_share_qr_destination 的可路由 target 落点
// ─────────────────────────────────────────────────────────────────────────────

/**
 * ProxyQrSharePage — 可达的 ProxyQr 二维码分享屏（ic_proxy_share_qr_destination）
 *
 * 对位源侧 QrCodeScreen(subject: .proxy(...))。QrSubjectType.ProxyQr 的渲染逻辑
 * （chatLinkQRBuildLink 的 ProxyQr 分支）本文件早已具备（P2-175），缺的只是一个可达路由
 * 入口——diag-suite_settings_data_storage-TC-0433.md 结论：ChatLinkQRPage（本文件另一既有
 * 类）走的是 D-001~D-009 记载的旧 pageMap + `@Consume NavPathStack` + 自建 NavDestination()
 * 模式，而 D-148 已确认本工程全仓该模式零命中、路由 SSOT 是 route_map.json + ets 壳 +
 * @HybridComponentEntry；ChatLinkQRPage 因此从未真正可达。本类改走 D-148 的真实路由机制，
 * 只做 ProxyQr 这一种 subject（不是 ChatLinkQRPage 的四 tab 通用屏——按 ic 要求的最小可行
 * 目的地，与 BirthdayPrivacyPage 同一克制边界）。
 *
 * 路由参数（本类唯一 SSOT）：
 *   routerPush("ProxyQrSharePage", "<host>|<port>|<mtp 0/1>|<secret>|<user>|<pass>|<external 0/1>")
 *   管道分隔，同 SelectivePrivacySettingsPeersPage 的 "kind|mode" 惯例。调用方
 *   （set_proxy_settings 的 ProxySettingsPage.shareFormProxy()）不在本任务 target_files 内，
 *   接线该 push 调用点归其 owner——本类只保证目的地存在、可达、渲染正确（ic 的
 *   required_outcomes 明确把两侧接线拆成两条独立陈述，本类落地 invite_qr_code 那一条）。
 */
@HybridComponentEntry
@Component
public class ProxyQrSharePage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @State var paramParsed: Bool = false
    @State var proxyHost: String = ""
    @State var proxyPort: String = "1080"
    @State var proxyMtp: Bool = false
    @State var proxySecret: String = ""
    @State var proxyUser: String = ""
    @State var proxyPass: String = ""
    @State var proxyExternal: Bool = false

    public func aboutToAppear(): Unit {
        this.parseRouteParamOnce()
    }

    private func parseRouteParamOnce(): Unit {
        if (this.paramParsed) {
            return
        }
        this.paramParsed = true
        let raw = takePending("ProxyQrSharePage")
        if (raw.size > 0 && raw != "{}") {
            let parts = raw.trimAscii().split("|")
            if (parts.size >= 1) { this.proxyHost = parts[0] }
            if (parts.size >= 2 && parts[1].size > 0) { this.proxyPort = parts[1] }
            if (parts.size >= 3) { this.proxyMtp = parts[2] == "1" }
            if (parts.size >= 4) { this.proxySecret = parts[3] }
            if (parts.size >= 5) { this.proxyUser = parts[4] }
            if (parts.size >= 6) { this.proxyPass = parts[5] }
            if (parts.size >= 7) { this.proxyExternal = parts[6] == "1" }
        }
    }

    private func qrLink(): String {
        return chatLinkQRBuildLink(
            QrSubjectType.ProxyQr,
            "",
            "",
            this.proxyHost,
            this.proxyPort,
            this.proxyMtp,
            this.proxySecret,
            this.proxyUser,
            this.proxyPass,
            this.proxyExternal
        )
    }

    private func isLinkEmpty(): Bool {
        return this.qrLink().isEmpty()
    }

    private func performCopyLink(): Unit {
        let link = this.qrLink()
        if (!link.isEmpty()) {
            let _ = copyText(link)
        }
    }

    public func build() {
        Column {
            Row {
                Row { Image(@r(app.media.callui_v2_back)).width(10).height(18).fillColor(this.presentation.accentColor) }
                    .width(44).height(44).borderRadius(22)
                    .backgroundColor(if (this.presentation.isDark) { 0x663A3A3C } else { 0x99FFFFFF })
                    .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
                    .onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
                Text("Proxy QR Code")
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.presentation.textColor)
                Blank().layoutWeight(1)
                Row {}.width(60)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(this.presentation.navBarColor)
            .alignItems(VerticalAlign.Center)

            if (this.isLinkEmpty()) {
                Column {
                    Text("No proxy details to display")
                        .fontSize(13)
                        .fontColor(this.presentation.secondaryTextColor)
                        .textAlign(TextAlign.Center)
                }
                .width(240)
                .height(240)
                .borderRadius(20)
                .backgroundColor(this.presentation.cardColor)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .margin(top: 32)
            } else {
                Column {
                    QrCodeView(content: this.qrLink(), size: 240, showCenterLogo: true)
                }
                .margin(top: 32)

                Text("Scan to use this proxy server")
                    .fontSize(14)
                    .fontColor(this.presentation.secondaryTextColor)
                    .textAlign(TextAlign.Center)
                    .padding(left: 32, right: 32, top: 16)

                Button(trSource("Copy Link"))
                    .width(200)
                    .height(44)
                    .borderRadius(22)
                    .backgroundColor(this.presentation.accentColor)
                    .fontColor(0xFFFFFF)
                    .fontSize(15)
                    .margin(top: 16)
                    .onClick({ _ => this.performCopyLink() })
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.presentation.backgroundColor)
        .alignItems(HorizontalAlign.Center)
        .padding(bottom: getSafeAreaBottom())
    }
}
