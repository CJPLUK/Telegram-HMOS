package ohos_app_cangjie_entry.utils

import ohos_app_cangjie_entry.bindings.{getYuvConversionBinding}

/**
 * YuvConversionUtils — YUV/RGBA 像素格式转换高层工具接口
 *
 * 对应 Telegram-iOS submodules/YuvConversion/PublicHeaders/YuvConversion/YUV.h 的四个公开函数：
 * - encodeRGBAToYUVA
 * - resizeAndEncodeRGBAToYUVA
 * - decodeYUVAToRGBA
 * - decodeYUVAPlanesToRGBA
 *
 * 使用场景：视频帧渲染前的色彩空间转换（相机帧 NV12 → RGBA、贴图 RGBA → YUV420 等）。
 * 色彩矩阵：BT.709（encode/decode YUVA 系列）/ BT.601（decodePlanes 系列）。
 */

/**
 * 将 ARGB8888 图像编码为 YUVA 紧凑格式（BT.709）
 *
 * yuva: 输出缓冲（调用方预分配）
 *       compactAlpha=true 时最小尺寸 = width*height*2 + width*height/2
 *       compactAlpha=false 时最小尺寸 = width*height*3
 * argb: 输入 ARGB8888 缓冲，每行 bytesPerRow 字节，像素顺序 [A,R,G,B]
 * width: 图像宽度（像素）
 * height: 图像高度（像素）
 * bytesPerRow: 输入每行字节数（通常 = width * 4）
 * compactAlpha: true = 紧凑 alpha（每 2 像素 1 字节），false = 全精度 alpha（每像素 1 字节）
 * unpremultiply: true = 输入为预乘 alpha，需先反预乘；false = 直通 alpha，无需处理
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
    getYuvConversionBinding().encodeRGBAToYUVA(
        yuva, argb, width, height, bytesPerRow, compactAlpha, unpremultiply
    )
}

/**
 * 先将 ARGB8888 图像缩放到目标尺寸，再编码为 YUVA 紧凑格式（BT.709, compactAlpha=true）
 *
 * yuva: 输出缓冲（最小尺寸 = width*height*2 + width*height/2）
 * argb: 原始尺寸 ARGB8888 输入缓冲
 * width: 目标宽度（像素）
 * height: 目标高度（像素）
 * bytesPerRow: 目标每行字节数
 * originalWidth: 原始图像宽度
 * originalHeight: 原始图像高度
 * originalBytesPerRow: 原始图像每行字节数
 * unpremultiply: true = 输入为预乘 alpha，需先反预乘
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
    getYuvConversionBinding().resizeAndEncodeRGBAToYUVA(
        yuva, argb, width, height, bytesPerRow,
        originalWidth, originalHeight, originalBytesPerRow, unpremultiply
    )
}

/**
 * 将 YUVA 紧凑格式解码为 ARGB8888（BT.709）
 *
 * yuva: YUVA 输入缓冲（非紧凑 alpha，每像素 1 字节 alpha）
 *       内存布局：[Y 平面 w*h] + [CbCr 半平面 w*h] + [Alpha 平面 w*h]
 * argb: 输出 ARGB8888 缓冲（调用方预分配，最小尺寸 = height*bytesPerRow）
 * width: 图像宽度
 * height: 图像高度
 * bytesPerRow: 输出每行字节数
 */
public func decodeYUVAToRGBA(
    yuva: Array<UInt8>,
    argb: Array<UInt8>,
    width: Int32,
    height: Int32,
    bytesPerRow: Int32
): Unit {
    getYuvConversionBinding().decodeYUVAToRGBA(yuva, argb, width, height, bytesPerRow)
}

/**
 * 将 YUV420 三平面格式解码为 ARGB8888（BT.601 视频范围）
 *
 * 对应相机 / 视频解码器输出的 YUV420P / I420 格式（独立 Y/Cb/Cr 平面）。
 * Cb/Cr 平面宽度为 width/2，高度为 height（每 2x1 像素共享一对 Cb/Cr）。
 *
 * srcYp: Y 平面数据
 * srcYpBytesPerRow: Y 平面每行字节数（通常 = width）
 * srcCb: Cb 平面数据
 * srcCbBytesPerRow: Cb 平面每行字节数（通常 = width/2）
 * srcCr: Cr 平面数据
 * srcCrBytesPerRow: Cr 平面每行字节数（通常 = width/2）
 * hasAlpha: 是否附带 alpha 平面
 * alphaData: alpha 平面数据（宽 width），无 alpha 时传空数组
 * argb: 输出 ARGB8888 缓冲
 * width: 图像宽度
 * height: 图像高度
 * bytesPerRow: 输出每行字节数
 * unpremultiply: false = 输出预乘 alpha；true = 输出直通 alpha（非预乘）
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
    getYuvConversionBinding().decodeYUVAPlanesToRGBA(
        srcYp, srcYpBytesPerRow,
        srcCb, srcCbBytesPerRow,
        srcCr, srcCrBytesPerRow,
        hasAlpha, alphaData,
        argb, width, height, bytesPerRow, unpremultiply
    )
}
