package ohos_app_cangjie_entry.components

import kit.ImageKit.{createPixelMap, InitializationOptions, Size, PixelMap, PixelMapFormat}
import kit.PerformanceAnalysisKit.Hilog

/**
 * CameraPreviewHelper — 相机预览帧 PixelMap 全局持有器
 *
 * 与 VideoFrameHelper 相同的设计模式：
 * - 不在此文件 import kit.ArkUI.*，避免 Size 命名冲突
 * - 全局变量持有当前预览帧 PixelMap
 * - CameraPage 通过 @State frameVersion 计数器驱动 Image 组件刷新
 *
 * 预览流架构说明（P2-072）：
 *   Camera Kit 将预览帧写入 ImageReceiver（in-memory buffer）。
 *   XComponent 在 Cangjie SDK 中无绑定（ohos.arkui.component.xcomponent.cj.d 不存在），
 *   因此无法通过 XComponent.onLoad → surfaceId 做硬件 surface 直渲染。
 *   本方案：后台线程定期调用 CameraService.readPreviewFrameBytes() 从 ImageReceiver
 *   读取 JPEG 帧 → createImageSource(buf).createPixelMap() 解码 → 存入全局变量 →
 *   触发 @State previewFrameTick 自增驱动 Image 组件刷新。
 *   帧率受限于 ImageReceiver 写入速率及解码耗时，约 5~15 fps；画质与 Camera Kit 输出一致。
 *
 * 平台限制标注（诚实注解）：
 *   XComponent API 限制：Cangjie ArkUI SDK 6.0 未提供 XComponent 绑定，
 *   无法实现 XComponent.onLoad → getXComponentSurfaceId → camera preview_output 直渲染。
 *   当前 ImageReceiver→Image 轮询方案是 Cangjie 侧唯一可用的帧显示路径。
 */

/** 当前预览帧（JPEG 解码后的 PixelMap）；None 表示尚无帧 */
var _cameraPreviewPixelMap: Option<PixelMap> = None

/**
 * 获取当前相机预览帧 PixelMap。
 * 无帧时返回 1×1 黑色占位 PixelMap，不返回 None，
 * 避免 @Component 宏展开时 Option<PixelMap>.None 构造器歧义。
 */
public func getCameraPreviewPixelMap(): PixelMap {
    match (_cameraPreviewPixelMap) {
        case Some(pm) => return pm
        case None => return createDummyCameraPixelMap()
    }
}

/**
 * 更新全局预览帧 PixelMap（由后台轮询线程调用）。
 */
public func setCameraPreviewPixelMap(pm: PixelMap): Unit {
    _cameraPreviewPixelMap = Some(pm)
}

/**
 * 清除预览帧（相机释放时调用）。
 */
public func clearCameraPreviewPixelMap(): Unit {
    _cameraPreviewPixelMap = None
}

/**
 * 创建 1×1 黑色占位 PixelMap。
 */
public func createDummyCameraPixelMap(): PixelMap {
    let opts = InitializationOptions(
        Size(1, 1),
        srcPixelFormat: PixelMapFormat.Bgra8888,
        pixelFormat: PixelMapFormat.Bgra8888
    )
    return createPixelMap(Array<UInt8>(4, repeat: 0), opts)
}
