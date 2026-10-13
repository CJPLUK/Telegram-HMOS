package ohos_app_cangjie_entry.bindings

import kit.PerformanceAnalysisKit.Hilog

/**
 * PdfBinding — PDF 渲染平台封装层
 *
 * 对应 Telegram-iOS submodules/Pdf/Sources/PDF.swift（使用 CoreGraphics CGPDFDocument
 * 渲染第一页为 UIImage 预览）。
 *
 * 鸿蒙侧能力差异说明：
 *   - HarmonyOS 未提供等价于 CGPDFDocument/CGContext 的逐页像素渲染 API（仓颉 KB
 *     中无此类接口，检索词：PDF kit / pdfService / CGPDFDocument / page render）。
 *   - 平台提供的 PDF 能力：通过 Web 组件（ohos.web.webview.WebviewController +
 *     kit.ArkUI.Web）加载本地沙箱文件路径，支持完整的 PDF 查看（缩放/翻页/目录）。
 *     参见官方文档："使用Web组件的PDF文档预览能力"。
 *   - 像素级缩略图提取（对应 iOS generatePdfPreviewImage）：HarmonyOS Cangjie 层
 *     无等价 API，属于平台能力缺口（platform_gap），不做像素渲染，调用方应使用
 *     getPdfPreviewUrl() 构造 file:// URL 交由 Web 组件展示。
 *
 * 提供：
 * - buildPdfPreviewUrl：将本地沙箱绝对路径转换为 Web 组件可接受的 URL 字符串
 * - getPdfPageCount：获取 PDF 页数（platform_gap：无法从 Cangjie 层解析 PDF 字节）
 * - isValidPdfPath：验证路径后缀是否为 .pdf
 */

private var _pdfBindingInstance: Option<PdfBinding> = None

/**
 * 获取 PdfBinding 单例
 */
public func getPdfBinding(): PdfBinding {
    match (_pdfBindingInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = PdfBinding()
            _pdfBindingInstance = Some(inst)
            return inst
    }
}

/**
 * PDF 渲染平台封装层
 */
public class PdfBinding {

    /**
     * 将本地沙箱绝对路径转换为 Web 组件可接受的 URL 字符串。
     *
     * Web 组件加载本地文件要求路径为应用沙箱绝对路径（通常是
     * Context.filesDirectory + "/xxx.pdf"）。Web 组件的 src 参数直接接受
     * 沙箱绝对路径字符串（HarmonyOS 文档示例："abilityContext.filesDirectory +
     * \"/test.pdf\""），不需要额外添加 file:// 前缀。
     *
     * @param absolutePath 沙箱内 PDF 文件的绝对路径
     * @return 可直接作为 Web(src:) 参数的路径字符串；路径为空时返回 None
     */
    public func buildPdfPreviewUrl(absolutePath: String): Option<String> {
        if (absolutePath.size == 0) {
            Hilog.info(0, "CjTelegram", "[PdfBinding] buildPdfPreviewUrl: empty path")
            return None
        }
        Hilog.info(0, "CjTelegram", "[PdfBinding] buildPdfPreviewUrl: OK")
        return Some(absolutePath)
    }

    /**
     * 获取 PDF 文档页数。
     *
     * platform_gap：HarmonyOS Cangjie 层未提供 PDF 解析 API（无法在 Cangjie 层
     * 直接读取 PDF 字节流并解析页数，等价 iOS CGPDFDocument.numberOfPages 的能力
     * 不存在于当前 Cangjie SDK）。
     *
     * 返回值约定：
     *   -1  表示平台能力缺口，调用方不应依赖此值做分页逻辑
     *    n  预留给未来 HarmonyOS 补齐此能力时使用
     *
     * 调用方应使用 Web 组件的原生 PDF 查看器（含内置翻页/页数显示），
     * 而不依赖此函数的返回值驱动翻页 UI。
     *
     * @param absolutePath 沙箱内 PDF 文件的绝对路径（当前实现不读取此文件）
     * @return -1（平台能力缺口），或未来补齐后的实际页数
     */
    public func getPdfPageCount(absolutePath: String): Int32 {
        Hilog.info(0, "CjTelegram", "[PdfBinding] getPdfPageCount: platform_gap, returning -1")
        return -1
    }

    /**
     * 验证路径后缀是否为 .pdf（不区分大小写）。
     *
     * @param path 文件路径
     * @return 路径以 .pdf 或 .PDF 等结尾则返回 true
     */
    public func isValidPdfPath(path: String): Bool {
        if (path.size < 4) {
            return false
        }
        let lower = path.toAsciiLower()
        return lower.endsWith(".pdf")
    }

    /**
     * 构建 Web 组件加载本地 PDF 所需的文件访问配置提示。
     *
     * Web 组件加载沙箱内文件时需启用 fileAccess(true)，此方法返回固定的提示
     * 字符串供调用方在日志或调试中参考，实际配置需在调用 Web 组件时完成。
     *
     * @return 描述所需权限的字符串
     */
    public func getPdfWebAccessHint(): String {
        return "Web component requires: .fileAccess(true) and .domStorageAccess(true) for local PDF preview"
    }
}
