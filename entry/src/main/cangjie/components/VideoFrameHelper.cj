package ohos_app_cangjie_entry.components

import kit.ImageKit.{createPixelMap, InitializationOptions, Size, PixelMap, PixelMapFormat}
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getSoftwareVideoService

/**
 * 视频帧 → PixelMap 转换工具
 *
 * 独立文件避免 kit.ArkUI.Size 与 kit.ImageKit.Size 命名冲突。
 * kit.ArkUI.* 不在此文件导入。
 *
 * C++ 层 (VideoFrameSinkAdapter) 已用 libyuv::I420ToARGB 将 I420 转为 BGRA8888，
 * 此文件直接用 BGRA 数据创建 PixelMap。
 */

var _bgraFrameSeq: Int64 = 0

/**
 * 从 BGRA8888 原始数据创建 PixelMap
 *
 * @param bgraData BGRA8888 像素数据 (由 C++ libyuv 转换)
 * @param width    帧宽度
 * @param height   帧高度
 * @return 可用于 Image 组件渲染的 PixelMap
 */
public func createPixelMapFromBgra(bgraData: Array<UInt8>, width: Int32, height: Int32): PixelMap {
    _bgraFrameSeq = _bgraFrameSeq + 1

    let expected = Int64(width) * Int64(height) * 4
    if (bgraData.size != expected) {
        Hilog.info(0, "CjTelegram", "[VideoFrameHelper] Size mismatch: got=${bgraData.size} expected=${expected} (${width}x${height}x4)")
    }

    // 注意：OpenHarmony image.Size 接口声明是 {height, width}——height 在前
    // （ImageKit 特有顺序，与 ArkUI 的 width-first 相反）。此处必须 Size(height, width)。
    // 教训：曾按"width-first 常规"误改成 (width,height)，导致本地预览行几何错乱
    // （左右重影+行纹），而发送流（C++ 直接编码）不受影响——真机 vc4 实锤后回滚。
    let opts = InitializationOptions(
        Size(height, width),
        srcPixelFormat: PixelMapFormat.Bgra8888,
        pixelFormat: PixelMapFormat.Bgra8888
    )
    let pm = createPixelMap(bgraData, opts)

    return pm
}

/**
 * 兼容旧接口：从 I420 数据创建 PixelMap (仍调用 BGRA 路径)
 * 注意：此函数做 Cangjie 侧 YUV→RGB 软件转换，性能远不如 C++ libyuv。
 * 仅用于 C++ 层未转换的场景。
 */
public func createPixelMapFromI420(i420Data: Array<Byte>, width: Int32, height: Int32): PixelMap {
    let bgraData = i420ToBgraConvert(i420Data, width, height)
    // 同上：image.Size 为 {height, width}（height 在前）
    let opts = InitializationOptions(Size(height, width), srcPixelFormat: PixelMapFormat.Bgra8888, pixelFormat: PixelMapFormat.Bgra8888)
    return createPixelMap(bgraData, opts)
}

/**
 * 创建 1x1 透明占位 PixelMap
 */
public func createDummyPixelMap(): PixelMap {
    let opts = InitializationOptions(Size(1, 1), srcPixelFormat: PixelMapFormat.Bgra8888, pixelFormat: PixelMapFormat.Bgra8888)
    return createPixelMap(Array<UInt8>(4, repeat: 0), opts)
}

/**
 * I420 → BGRA8888 软件转换 (BT.601)
 */
func i420ToBgraConvert(data: Array<Byte>, width: Int32, height: Int32): Array<UInt8> {
    let w = Int64(width)
    let h = Int64(height)
    let ySize = w * h
    let uvW = (w + 1) / 2
    let uvH = (h + 1) / 2
    let uOffset = ySize
    let vOffset = ySize + uvW * uvH
    let bgraSize = w * h * 4
    let result = Array<UInt8>(bgraSize, repeat: 255)

    var row: Int64 = 0
    while (row < h) {
        var col: Int64 = 0
        while (col < w) {
            let yIdx = row * w + col
            let uvRow = row / 2
            let uvCol = col / 2
            let uIdx = uOffset + uvRow * uvW + uvCol
            let vIdx = vOffset + uvRow * uvW + uvCol

            let yVal = Int64(UInt8(data[yIdx]))
            let uVal = if (uIdx < data.size) { Int64(UInt8(data[uIdx])) } else { 128 }
            let vVal = if (vIdx < data.size) { Int64(UInt8(data[vIdx])) } else { 128 }

            let c = yVal - 16
            let d = uVal - 128
            let e = vVal - 128

            var r = (298 * c + 409 * e + 128) >> 8
            var g = (298 * c - 100 * d - 208 * e + 128) >> 8
            var b = (298 * c + 516 * d + 128) >> 8

            if (r < 0) { r = 0 } else if (r > 255) { r = 255 }
            if (g < 0) { g = 0 } else if (g > 255) { g = 255 }
            if (b < 0) { b = 0 } else if (b > 255) { b = 255 }

            let pixelIdx = (row * w + col) * 4
            result[pixelIdx] = UInt8(b)
            result[pixelIdx + 1] = UInt8(g)
            result[pixelIdx + 2] = UInt8(r)
            result[pixelIdx + 3] = 255

            col = col + 1
        }
        row = row + 1
    }
    return result
}

/**
 * 从 SoftwareVideoService.lastFrame 获取当前帧 PixelMap，或返回占位 PixelMap。
 *
 * 此函数在不导入 kit.ArkUI.* 的 VideoFrameHelper.cj 中定义，
 * 避免 @Component 宏展开时 Option<PixelMap> 的 None 构造器歧义（S-64/宏展开限制）。
 * SoftwareVideoComponent.build() 中通过调用此函数访问 PixelMap，
 * 无需在组件文件中直接声明 PixelMap 相关字段或变量。
 */
public func getSoftwareVideoCurrentPixelMap(): PixelMap {
    let svc = getSoftwareVideoService()
    match (svc.lastFrame.pixelMap) {
        case Some(pm) => return pm
        case None => return createDummyPixelMap()
    }
}
