package ohos_app_cangjie_entry.bindings

import kit.PerformanceAnalysisKit.Hilog

/**
 * YuvConversionBinding — YUV/RGBA 像素格式转换平台封装层
 *
 * 对应 Telegram-iOS YuvConversion/Sources/YUV.m（使用 vImage Accelerate 框架）。
 * 鸿蒙侧使用纯仓颉实现等效的 YUV ↔ RGBA 色彩空间转换算法。
 *
 * 色彩矩阵约定：
 * - encodeRGBAToYUVA / decodeYUVAToRGBA：BT.709（ITU-R 709-2），与 iOS vImage kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2 一致
 * - decodeYUVAPlanesToRGBA：BT.601（ITU-R 601-4），与 iOS kvImage_YpCbCrToARGBMatrix_ITU_R_601_4 一致
 *
 * YUVA 内存布局（encodeRGBAToYUVA / decodeYUVAToRGBA 使用的紧凑格式）：
 *   [0 ..  w*h)        = Y 平面
 *   [w*h .. w*h*2)     = CbCr 交错（NV12 半平面）
 *   [w*h*2 .. ...]     = Alpha（非紧凑时每像素 1 字节 / 紧凑时每 2 像素 1 字节）
 *
 * 提供：
 * - encodeRGBAToYUVA：RGBA → YUVA（BT.709, compactAlpha 可选, unpremultiply 可选）
 * - resizeAndEncodeRGBAToYUVA：先双线性缩放再 RGBA → YUVA（BT.709）
 * - decodeYUVAToRGBA：YUVA → RGBA（BT.709）
 * - decodeYUVAPlanesToRGBA：YUV420 三平面 → RGBA（BT.601，可选 alpha 平面）
 */

private var _yuvConversionBindingInstance: Option<YuvConversionBinding> = None

/**
 * 获取 YuvConversionBinding 单例
 */
public func getYuvConversionBinding(): YuvConversionBinding {
    match (_yuvConversionBindingInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = YuvConversionBinding()
            _yuvConversionBindingInstance = Some(inst)
            return inst
    }
}

/**
 * YUV/RGBA 像素格式转换核心实现
 */
public class YuvConversionBinding {

    // -------------------------------------------------------------------------
    // BT.709 (ITU-R 709-2) 编码系数
    // 与 iOS kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2 一致
    // Y  =  0.2126 * R + 0.7152 * G + 0.0722 * B
    // Cb = -0.1146 * R - 0.3854 * G + 0.5000 * B + 128
    // Cr =  0.5000 * R - 0.4542 * G - 0.0458 * B + 128
    //
    // 使用定点运算（x256）：
    //   yR=54, yG=183, yB=18  (sum=255)
    //   cbR=-29, cbG=-99, cbB=128
    //   crR=128, crG=-116, crB=-12
    // -------------------------------------------------------------------------

    // -------------------------------------------------------------------------
    // BT.601 (ITU-R 601-4) 解码系数（视频范围 16-235/240）
    // 与 iOS kvImage_YpCbCrToARGBMatrix_ITU_R_601_4 一致
    // pixelRange: { Yp_bias=16, CbCr_bias=128, YpRangeMax=235, CbCrRangeMax=240 }
    //
    // 缩放到完整范围后的近似解码：
    //   R = 1.164 * (Y - 16) + 1.596 * (Cr - 128)
    //   G = 1.164 * (Y - 16) - 0.391 * (Cb - 128) - 0.813 * (Cr - 128)
    //   B = 1.164 * (Y - 16) + 2.018 * (Cb - 128)
    //
    // 定点 x1024：
    //   yScale=1192, rCr=1634, gCb=-400, gCr=-833, bCb=2066
    // -------------------------------------------------------------------------

    /**
     * RGBA(BGRA 均支持，iOS 侧实际传入顺序为 ARGB 经过 permuteMap 转为 ARGB→YUVA) → YUVA 紧凑格式
     *
     * 注意：iOS 源码传入 argb 指针实为每像素 [A,R,G,B] 内存布局（ARGB8888），
     * 代码中通过 permuteMap {3,2,1,0} 将其转换为 [B,G,R,A]，然后送入 vImage420 转换。
     * 因此这里期望的输入格式为 ARGB8888（每像素 [A,R,G,B]）。
     *
     * yuva: 输出缓冲，调用方预分配，最小尺寸 =
     *       compactAlpha=true:  w*h + w*h + w*h/2 = w*h*2 + w*h/2
     *       compactAlpha=false: w*h + w*h + w*h   = w*h*3
     * argb: 输入 ARGB8888 缓冲，每行 bytesPerRow 字节
     * compactAlpha: 紧凑 alpha（每 2 像素打包为 1 字节）
     * unpremultiply: 输入为预乘 alpha，需先反预乘
     */
    public func encodeRGBAToYUVA(
        yuva: Array<UInt8>,
        argb: Array<UInt8>,
        width: Int32,
        height: Int32,
        bytesPerRow: Int32,
        compactAlpha: Bool,
        unpremultiply: Bool
    ): Unit {
        let w = Int64(width)
        let h = Int64(height)
        let bpr = Int64(bytesPerRow)
        let ySize = w * h

        // 处理 alpha 通道（从输入 ARGB 提取 A 分量）
        let alphaOffset: Int64
        if (compactAlpha) {
            alphaOffset = ySize * 2
        } else {
            alphaOffset = ySize * 3
        }

        var alphaIdx: Int64 = 0
        var row: Int64 = 0
        while (row < h) {
            let rowBase = row * bpr
            if (compactAlpha) {
                var col: Int64 = 0
                while (col < w) {
                    let a0 = Int64(argb[rowBase + col * 4 + 0]) >> 4 << 4
                    let col1 = if (col + 1 < w) { col + 1 } else { col }
                    let a1 = Int64(argb[rowBase + col1 * 4 + 0]) >> 4 << 4
                    yuva[alphaOffset + alphaIdx / 2] = UInt8((a0 & 0xF0) | ((a1 & 0xF0) >> 4))
                    alphaIdx = alphaIdx + 2
                    col = col + 2
                }
            } else {
                var col: Int64 = 0
                while (col < w) {
                    let a = argb[rowBase + col * 4 + 0]
                    yuva[alphaOffset + alphaIdx] = a
                    alphaIdx = alphaIdx + 1
                    col = col + 1
                }
            }
            row = row + 1
        }

        // 将 ARGB 转换为 YCbCr（BT.709），逐 2x2 块处理（YUV420 半平面格式）
        // Y 平面：每像素一个 Y 值（索引 0..ySize）
        // CbCr 平面：每 2 行 2 列采样一对 Cb/Cr（索引 ySize..ySize*2，交错存放）
        var y: Int64 = 0
        while (y < h) {
            let rowBase0 = y * bpr
            let rowBase1 = if (y + 1 < h) { (y + 1) * bpr } else { y * bpr }

            var x: Int64 = 0
            while (x < w) {
                // 取 2x2 块的四个像素（用于 4:2:0 色度下采样）
                // 输入为 ARGB：索引 [pixelBase+0]=A, [+1]=R, [+2]=G, [+3]=B
                let p00Base = rowBase0 + x * 4
                let p01Base = if (x + 1 < w) { rowBase0 + (x + 1) * 4 } else { p00Base }
                let p10Base = rowBase1 + x * 4
                let p11Base = if (x + 1 < w) { rowBase1 + (x + 1) * 4 } else { p10Base }

                // 提取 ARGB 各分量（注意：iOS permuteMap {3,2,1,0} 将 ARGB → BGRA，但这里直接用 ARGB 源数据）
                // A=+0, R=+1, G=+2, B=+3
                let a00 = Int64(argb[p00Base + 0])
                let r00Raw = Int64(argb[p00Base + 1])
                let g00Raw = Int64(argb[p00Base + 2])
                let b00Raw = Int64(argb[p00Base + 3])

                let a01 = Int64(argb[p01Base + 0])
                let r01Raw = Int64(argb[p01Base + 1])
                let g01Raw = Int64(argb[p01Base + 2])
                let b01Raw = Int64(argb[p01Base + 3])

                let r10Raw = Int64(argb[p10Base + 1])
                let g10Raw = Int64(argb[p10Base + 2])
                let b10Raw = Int64(argb[p10Base + 3])
                let a10 = Int64(argb[p10Base + 0])

                let r11Raw = Int64(argb[p11Base + 1])
                let g11Raw = Int64(argb[p11Base + 2])
                let b11Raw = Int64(argb[p11Base + 3])
                let a11 = Int64(argb[p11Base + 0])

                // 反预乘 alpha（若 unpremultiply 为 true）
                let r00: Int64
                let g00: Int64
                let b00: Int64
                let r01: Int64
                let g01: Int64
                let b01: Int64
                let r10: Int64
                let g10: Int64
                let b10: Int64
                let r11: Int64
                let g11: Int64
                let b11: Int64
                if (unpremultiply) {
                    r00 = if (a00 > 0) { r00Raw * 255 / a00 } else { 0 }
                    g00 = if (a00 > 0) { g00Raw * 255 / a00 } else { 0 }
                    b00 = if (a00 > 0) { b00Raw * 255 / a00 } else { 0 }
                    r01 = if (a01 > 0) { r01Raw * 255 / a01 } else { 0 }
                    g01 = if (a01 > 0) { g01Raw * 255 / a01 } else { 0 }
                    b01 = if (a01 > 0) { b01Raw * 255 / a01 } else { 0 }
                    r10 = if (a10 > 0) { r10Raw * 255 / a10 } else { 0 }
                    g10 = if (a10 > 0) { g10Raw * 255 / a10 } else { 0 }
                    b10 = if (a10 > 0) { b10Raw * 255 / a10 } else { 0 }
                    r11 = if (a11 > 0) { r11Raw * 255 / a11 } else { 0 }
                    g11 = if (a11 > 0) { g11Raw * 255 / a11 } else { 0 }
                    b11 = if (a11 > 0) { b11Raw * 255 / a11 } else { 0 }
                } else {
                    r00 = r00Raw
                    g00 = g00Raw
                    b00 = b00Raw
                    r01 = r01Raw
                    g01 = g01Raw
                    b01 = b01Raw
                    r10 = r10Raw
                    g10 = g10Raw
                    b10 = b10Raw
                    r11 = r11Raw
                    g11 = g11Raw
                    b11 = b11Raw
                }

                // BT.709 Y 值（定点 x256）
                // Y = (54*R + 183*G + 18*B) / 256，范围 [0, 255]
                let y00 = clampU8((54 * r00 + 183 * g00 + 18 * b00) / 256)
                let y01 = clampU8((54 * r01 + 183 * g01 + 18 * b01) / 256)
                let y10 = clampU8((54 * r10 + 183 * g10 + 18 * b10) / 256)
                let y11 = clampU8((54 * r11 + 183 * g11 + 18 * b11) / 256)

                yuva[y * w + x] = UInt8(y00)
                if (x + 1 < w) { yuva[y * w + x + 1] = UInt8(y01) }
                if (y + 1 < h) { yuva[(y + 1) * w + x] = UInt8(y10) }
                if (y + 1 < h && x + 1 < w) { yuva[(y + 1) * w + x + 1] = UInt8(y11) }

                // BT.709 Cb/Cr（对 2x2 块取平均色度，定点 x256）
                // Cb = (-29*R - 99*G + 128*B) / 256 + 128
                // Cr = (128*R - 116*G - 12*B) / 256 + 128
                let rAvg = (r00 + r01 + r10 + r11) / 4
                let gAvg = (g00 + g01 + g10 + g11) / 4
                let bAvg = (b00 + b01 + b10 + b11) / 4
                let cb = clampU8((-29 * rAvg - 99 * gAvg + 128 * bAvg) / 256 + 128)
                let cr = clampU8((128 * rAvg - 116 * gAvg - 12 * bAvg) / 256 + 128)

                // CbCr 半平面位置（NV12 交错：Cb, Cr 交替）
                // 在 YUVA 布局中 CbCr 平面起始于 ySize
                let cbCrBase = ySize + (y / 2) * w + (x / 2) * 2
                yuva[cbCrBase] = UInt8(cb)
                if (cbCrBase + 1 < Int64(yuva.size)) {
                    yuva[cbCrBase + 1] = UInt8(cr)
                }

                x = x + 2
            }
            y = y + 2
        }
    }

    /**
     * 先双线性缩放，再 RGBA → YUVA（BT.709, compactAlpha=true, 无 unpremultiply）
     * 对应 iOS resizeAndEncodeRGBAToYUVA
     */
    public func resizeAndEncodeRGBAToYUVA(
        yuva: Array<UInt8>,
        argb: Array<UInt8>,
        width: Int32,
        height: Int32,
        bytesPerRow: Int32,
        originalWidth: Int32,
        originalHeight: Int32,
        originalBytesPerRow: Int32,
        unpremultiply: Bool
    ): Unit {
        let dstW = Int64(width)
        let dstH = Int64(height)
        let srcW = Int64(originalWidth)
        let srcH = Int64(originalHeight)
        let srcBpr = Int64(originalBytesPerRow)
        let dstBpr = Int64(bytesPerRow)

        // 双线性插值缩放到目标尺寸
        let scaled = Array<UInt8>(dstBpr * dstH, repeat: 0)
        var dy: Int64 = 0
        while (dy < dstH) {
            let srcYf = Int64(dy) * (srcH - 1) / if (dstH > 1) { dstH - 1 } else { 1 }
            let y0 = srcYf
            let y1 = if (y0 + 1 < srcH) { y0 + 1 } else { srcH - 1 }
            let fy = (Int64(dy) * (srcH - 1)) - y0 * if (dstH > 1) { dstH - 1 } else { 1 }
            let fyN = if (dstH > 1) { dstH - 1 } else { 1 }

            var dx: Int64 = 0
            while (dx < dstW) {
                let srcXf = dx * (srcW - 1) / if (dstW > 1) { dstW - 1 } else { 1 }
                let x0 = srcXf
                let x1 = if (x0 + 1 < srcW) { x0 + 1 } else { srcW - 1 }
                let fx = dx * (srcW - 1) - x0 * if (dstW > 1) { dstW - 1 } else { 1 }
                let fxN = if (dstW > 1) { dstW - 1 } else { 1 }

                var ch: Int64 = 0
                while (ch < 4) {
                    let p00 = Int64(argb[y0 * srcBpr + x0 * 4 + ch])
                    let p01 = Int64(argb[y0 * srcBpr + x1 * 4 + ch])
                    let p10 = Int64(argb[y1 * srcBpr + x0 * 4 + ch])
                    let p11 = Int64(argb[y1 * srcBpr + x1 * 4 + ch])
                    let top = p00 * (fxN - fx) + p01 * fx
                    let bottom = p10 * (fxN - fx) + p11 * fx
                    let val = (top * (fyN - fy) + bottom * fy) / (fxN * fyN)
                    scaled[dy * dstBpr + dx * 4 + ch] = UInt8(val)
                    ch = ch + 1
                }
                dx = dx + 1
            }
            dy = dy + 1
        }

        // 使用 compactAlpha=true, unpremultiply 参数
        encodeRGBAToYUVA(yuva, scaled, width, height, bytesPerRow, true, unpremultiply)
    }

    /**
     * YUVA 紧凑格式 → RGBA（BT.709）
     * 对应 iOS decodeYUVAToRGBA
     * yuva: YUVA 输入（紧凑格式，非 compactAlpha，每像素 1 字节 alpha）
     * argb: 输出 ARGB8888 缓冲
     */
    public func decodeYUVAToRGBA(
        yuva: Array<UInt8>,
        argb: Array<UInt8>,
        width: Int32,
        height: Int32,
        bytesPerRow: Int32
    ): Unit {
        let w = Int64(width)
        let h = Int64(height)
        let bpr = Int64(bytesPerRow)
        let ySize = w * h
        // alpha 平面起始位置（非紧凑，每像素 1 字节）
        // 布局同 decodeYUVAToRGBA：yuva + (w*h*1 + w*h*1) = yuva + w*h*2
        let alphaOffset = ySize * 2

        // BT.709 解码：
        // R = Y + 1.5748 * (Cr - 128)
        // G = Y - 0.1873 * (Cb - 128) - 0.4681 * (Cr - 128)
        // B = Y + 1.8556 * (Cb - 128)
        // 定点 x1024：rCr=1613, gCb=-192, gCr=-479, bCb=1900

        var row: Int64 = 0
        while (row < h) {
            var col: Int64 = 0
            while (col < w) {
                let yVal = Int64(yuva[row * w + col])
                // CbCr 半平面（NV12 交错），2x2 块取同一 Cb/Cr
                let cbCrBase = ySize + (row / 2) * w + (col / 2) * 2
                let cb = Int64(yuva[cbCrBase]) - 128
                let cr = Int64(yuva[cbCrBase + 1]) - 128

                let r = clampU8((yVal * 1024 + 1613 * cr) / 1024)
                let g = clampU8((yVal * 1024 - 192 * cb - 479 * cr) / 1024)
                let b = clampU8((yVal * 1024 + 1900 * cb) / 1024)

                // 读取 alpha
                let alphaIdx = row * w + col
                let a = Int64(yuva[alphaOffset + alphaIdx])

                // 写回 ARGB8888：[A, R, G, B]
                let outBase = row * bpr + col * 4
                argb[outBase + 0] = UInt8(a)
                argb[outBase + 1] = UInt8(r)
                argb[outBase + 2] = UInt8(g)
                argb[outBase + 3] = UInt8(b)

                col = col + 1
            }
            row = row + 1
        }

        // premultiply alpha（对应 iOS vImagePremultiplyData_ARGB8888）
        var i: Int64 = 0
        while (i < h) {
            var j: Int64 = 0
            while (j < w) {
                let base = i * bpr + j * 4
                let a = Int64(argb[base + 0])
                argb[base + 1] = UInt8(Int64(argb[base + 1]) * a / 255)
                argb[base + 2] = UInt8(Int64(argb[base + 2]) * a / 255)
                argb[base + 3] = UInt8(Int64(argb[base + 3]) * a / 255)
                j = j + 1
            }
            i = i + 1
        }

        // permuteMap {3,2,1,0}：ARGB → BGRA（[A,R,G,B] → [B,G,R,A]）
        // 对应 iOS vImagePermuteChannels_ARGB8888 with permuteMap {3,2,1,0}
        var pi: Int64 = 0
        while (pi < h) {
            var pj: Int64 = 0
            while (pj < w) {
                let base = pi * bpr + pj * 4
                let ch0 = argb[base + 0]
                let ch1 = argb[base + 1]
                let ch2 = argb[base + 2]
                let ch3 = argb[base + 3]
                argb[base + 0] = ch3
                argb[base + 1] = ch2
                argb[base + 2] = ch1
                argb[base + 3] = ch0
                pj = pj + 1
            }
            pi = pi + 1
        }
    }

    /**
     * YUV420 三平面（独立 Y/Cb/Cr 平面） → RGBA（BT.601 视频范围）
     * 对应 iOS decodeYUVAPlanesToRGBA
     *
     * srcYp: Y 平面数据，每行 srcYpBytesPerRow 字节
     * srcCb: Cb 平面数据（宽 width/2），每行 srcCbBytesPerRow 字节
     * srcCr: Cr 平面数据（宽 width/2），每行 srcCrBytesPerRow 字节
     * hasAlpha: 是否附带 alpha 平面
     * alphaData: alpha 平面数据（宽 width），每行 srcYpBytesPerRow 字节
     * argb: 输出 ARGB8888 缓冲
     * unpremultiply: 输出不预乘（true）还是预乘（false）
     *
     * BT.601 视频范围解码（定点 x1024，与 iOS 601-4 一致）：
     *   Y' = (Y - 16) * 1192
     *   R = clamp((Y' + 1634*(Cr-128)) / 1024)
     *   G = clamp((Y' - 400*(Cb-128) - 833*(Cr-128)) / 1024)
     *   B = clamp((Y' + 2066*(Cb-128)) / 1024)
     */
    public func decodeYUVAPlanesToRGBA(
        srcYp: Array<UInt8>,
        srcYpBytesPerRow: Int32,
        srcCb: Array<UInt8>,
        srcCbBytesPerRow: Int32,
        srcCr: Array<UInt8>,
        srcCrBytesPerRow: Int32,
        hasAlpha: Bool,
        alphaData: Array<UInt8>,
        argb: Array<UInt8>,
        width: Int32,
        height: Int32,
        bytesPerRow: Int32,
        unpremultiply: Bool
    ): Unit {
        let w = Int64(width)
        let h = Int64(height)
        let bpr = Int64(bytesPerRow)
        let yBpr = Int64(srcYpBytesPerRow)
        let cbBpr = Int64(srcCbBytesPerRow)
        let crBpr = Int64(srcCrBytesPerRow)

        var row: Int64 = 0
        while (row < h) {
            var col: Int64 = 0
            while (col < w) {
                let yRaw = Int64(srcYp[row * yBpr + col])
                let cbIdx = (row / 2) * cbBpr + (col / 2)
                let crIdx = (row / 2) * crBpr + (col / 2)
                let cbVal = Int64(srcCb[cbIdx]) - 128
                let crVal = Int64(srcCr[crIdx]) - 128

                // BT.601 视频范围
                let yScaled = (yRaw - 16) * 1192
                let r = clampU8((yScaled + 1634 * crVal) / 1024)
                let g = clampU8((yScaled - 400 * cbVal - 833 * crVal) / 1024)
                let b = clampU8((yScaled + 2066 * cbVal) / 1024)

                let outBase = row * bpr + col * 4
                // 先写 ARGB 格式（alpha=0xFF 默认不透明）
                argb[outBase + 0] = 0xFF
                argb[outBase + 1] = UInt8(r)
                argb[outBase + 2] = UInt8(g)
                argb[outBase + 3] = UInt8(b)

                col = col + 1
            }
            row = row + 1
        }

        // 覆盖 alpha 平面（若有）
        if (hasAlpha) {
            var ai: Int64 = 0
            while (ai < h) {
                let alphaRowOffset = ai * yBpr
                var aj: Int64 = 0
                while (aj < w) {
                    let outBase = ai * bpr + aj * 4
                    argb[outBase + 0] = alphaData[alphaRowOffset + aj]
                    aj = aj + 1
                }
                ai = ai + 1
            }
        }

        if (unpremultiply) {
            // vImageUnpremultiplyData_ARGB8888：除以 alpha（输入已是非预乘格式时为 no-op，
            // 但 iOS 侧实际上是对已经是直通（straight）数据做 unpremultiply，这里保持调用链一致）
            var ui: Int64 = 0
            while (ui < h) {
                var uj: Int64 = 0
                while (uj < w) {
                    let base = ui * bpr + uj * 4
                    let a = Int64(argb[base + 0])
                    if (a < 255 && a > 0) {
                        argb[base + 1] = UInt8(clampU8(Int64(argb[base + 1]) * 255 / a))
                        argb[base + 2] = UInt8(clampU8(Int64(argb[base + 2]) * 255 / a))
                        argb[base + 3] = UInt8(clampU8(Int64(argb[base + 3]) * 255 / a))
                    }
                    uj = uj + 1
                }
                ui = ui + 1
            }
        } else {
            // vImagePremultiplyData_ARGB8888：预乘 alpha
            var pi: Int64 = 0
            while (pi < h) {
                var pj: Int64 = 0
                while (pj < w) {
                    let base = pi * bpr + pj * 4
                    let a = Int64(argb[base + 0])
                    argb[base + 1] = UInt8(Int64(argb[base + 1]) * a / 255)
                    argb[base + 2] = UInt8(Int64(argb[base + 2]) * a / 255)
                    argb[base + 3] = UInt8(Int64(argb[base + 3]) * a / 255)
                    pj = pj + 1
                }
                pi = pi + 1
            }
        }

        // permuteMap {3,2,1,0}：ARGB → BGRA
        var qi: Int64 = 0
        while (qi < h) {
            var qj: Int64 = 0
            while (qj < w) {
                let base = qi * bpr + qj * 4
                let ch0 = argb[base + 0]
                let ch1 = argb[base + 1]
                let ch2 = argb[base + 2]
                let ch3 = argb[base + 3]
                argb[base + 0] = ch3
                argb[base + 1] = ch2
                argb[base + 2] = ch1
                argb[base + 3] = ch0
                qj = qj + 1
            }
            qi = qi + 1
        }
    }

    /**
     * 将 Int64 值箝位到 [0, 255] 并返回 Int64
     */
    private func clampU8(val: Int64): Int64 {
        if (val < 0) { return 0 }
        if (val > 255) { return 255 }
        return val
    }
}
