package ohos_app_cangjie_entry.components

import kit.ImageKit.{createImageSource, createPixelMap, InitializationOptions, Size, PixelMap, PixelMapFormat}
import kit.PerformanceAnalysisKit.Hilog

/**
 * CameraThumbnailHelper — 拍照后缩略图 PixelMap 全局持有器
 *
 * 避免在 @Component CameraPage 中直接持有 Option<PixelMap>（宏展开歧义）。
 * 拍照完成后从 JPEG 文件字节解码 PixelMap，存入此全局变量；
 * CameraPage 通过 @State capturedThumbnailTick 计数器触发刷新，
 * 在 build() 中调用 getCameraThumbnailPixelMap() 显示缩略图。
 */

/** 上一次拍照的缩略图 PixelMap */
var _cameraThumbnailPixelMap: Option<PixelMap> = None

/**
 * 获取上一次拍照的缩略图 PixelMap。
 * 无图时返回 None，调用方负责判断是否显示。
 */
public func getCameraThumbnailPixelMapOpt(): Option<PixelMap> {
    return _cameraThumbnailPixelMap
}

/**
 * 是否有可用的缩略图（用于 @Builder 中的条件判断，避免在 @Builder 中用 let 匹配 Option）。
 */
public func hasCameraThumbnail(): Bool {
    match (_cameraThumbnailPixelMap) {
        case Some(_) => return true
        case None => return false
    }
}

/**
 * 获取缩略图 PixelMap，无图时返回 1×1 占位（避免 @Builder 中的 Option 匹配）。
 * 调用前应先用 hasCameraThumbnail() 检查。
 */
public func getCameraThumbnailPixelMap(): PixelMap {
    match (_cameraThumbnailPixelMap) {
        case Some(pm) => return pm
        case None =>
            // 返回 1×1 透明 PixelMap（不应被直接渲染，调用方需先检查 hasCameraThumbnail()）
            return createDummyThumbnailPixelMap()
    }
}

/**
 * 从 JPEG 字节数组解码并保存为缩略图 PixelMap。
 * 在后台线程调用（createImageSource.createPixelMap 可能阻塞）。
 * @param jpegBytes JPEG 文件内容（Array<Byte>，Cangjie 中 Byte = UInt8）
 */
public func setCameraThumbnailFromJpeg(jpegBytes: Array<Byte>): Unit {
    if (jpegBytes.size == 0) {
        return
    }
    try {
        let src = createImageSource(jpegBytes)
        let pm = src.createPixelMap()
        _cameraThumbnailPixelMap = Some(pm)
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[CameraThumbnailHelper] decode thumbnail error")
    }
}

/**
 * 清除缩略图（相机重置或页面退出时调用）。
 */
public func clearCameraThumbnail(): Unit {
    _cameraThumbnailPixelMap = None
}

/**
 * 创建 1×1 透明占位 PixelMap（作为空缩略图的安全返回值）。
 */
public func createDummyThumbnailPixelMap(): PixelMap {
    let opts = InitializationOptions(
        Size(1, 1),
        srcPixelFormat: PixelMapFormat.Bgra8888,
        pixelFormat: PixelMapFormat.Bgra8888
    )
    return createPixelMap(Array<UInt8>(4, repeat: 0), opts)
}
