package ohos_app_cangjie_entry.utils

import ohos_app_cangjie_entry.bindings.{getPdfBinding}
import kit.PerformanceAnalysisKit.Hilog

/**
 * PdfUtils — PDF 渲染高层工具接口
 *
 * 对应 Telegram-iOS submodules/Pdf/Sources/PDF.swift 公开函数：
 *   - generatePdfPreviewImage(url: URL, size: CGSize) -> UIImage?
 *   - generatePdfPreviewImage(data: Data, size: CGSize) -> UIImage?
 *
 * 平台差异说明：
 *   iOS 通过 CGPDFDocument + CGContext 将 PDF 第一页渲染为 UIImage 位图缩略图。
 *   HarmonyOS 无等价逐页像素渲染 API（platform_gap），改用 Web 组件整体预览：
 *     - getPdfPreviewUrl()：获取可传入 Web(src:) 的沙箱路径字符串
 *     - getPdfPageCount()：返回 -1，表示平台能力缺口
 *     - isSupportedPdfFile()：验证文件路径是否为 PDF
 *
 * 调用方应将 getPdfPreviewUrl() 的返回值传给 ArkUI 的 Web 组件展示，
 * 而不期望获得 PixelMap 形式的缩略图。
 */

/**
 * 获取适合传入 Web 组件 src 参数的 PDF 预览路径。
 *
 * 对应 iOS generatePdfPreviewImage(url:, size:) 的鸿蒙迁移等价物。
 * 由于 HarmonyOS Cangjie 层无法像素级渲染 PDF，使用 Web 组件整体预览替代。
 *
 * absolutePath: 应用沙箱内 PDF 文件的绝对路径（如 Context.filesDirectory + "/doc.pdf"）
 * 返回 适合作为 Web(src:) 参数的路径字符串；路径无效时返回 None
 *
 * 使用示例（调用方 UI 层）：
 *   match (getPdfPreviewUrl(localPath)) {
 *     case Some(url) =>
 *       Web(src: url, controller: this.webController)
 *         .fileAccess(true)
 *         .domStorageAccess(true)
 *         .width(100.percent)
 *         .height(100.percent)
 *     case None =>
 *       Text("无法加载 PDF")
 *   }
 */
public func getPdfPreviewUrl(absolutePath: String): Option<String> {
    let binding = getPdfBinding()
    if (!binding.isValidPdfPath(absolutePath)) {
        Hilog.info(0, "CjTelegram", "[PdfUtils] getPdfPreviewUrl: not a .pdf path")
        return None
    }
    return binding.buildPdfPreviewUrl(absolutePath)
}

/**
 * 获取 PDF 文档页数。
 *
 * platform_gap：HarmonyOS Cangjie 层无 PDF 解析 API，无法获取实际页数。
 * 返回 -1 表示平台能力缺口；调用方不应依赖此值驱动翻页 UI，
 * 应使用 Web 组件内置的 PDF 查看功能（含翻页/页码显示）。
 *
 * 对应 iOS 的 CGPDFDocument.numberOfPages。
 *
 * absolutePath: 沙箱内 PDF 文件的绝对路径
 * 返回 -1（platform_gap），未来 HarmonyOS 补齐后返回实际页数
 */
public func getPdfPageCount(absolutePath: String): Int32 {
    return getPdfBinding().getPdfPageCount(absolutePath)
}

/**
 * 验证文件路径是否为受支持的 PDF 文件（通过扩展名判断）。
 *
 * path: 文件路径
 * 返回 路径以 .pdf（不区分大小写）结尾则返回 true
 */
public func isSupportedPdfFile(path: String): Bool {
    return getPdfBinding().isValidPdfPath(path)
}

/**
 * 获取 Web 组件加载本地 PDF 所需的访问配置提示字符串。
 *
 * 调用方在集成 Web 组件时应启用 .fileAccess(true) 和 .domStorageAccess(true)。
 * 此函数返回提示字符串便于在日志中确认配置要求，不执行任何副作用。
 *
 * 返回 描述 Web 组件配置要求的字符串
 */
public func getPdfWebAccessHint(): String {
    return getPdfBinding().getPdfWebAccessHint()
}
