package ohos_app_cangjie_entry.services

import kit.AbilityKit.{Want, WantValueType}
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList

/**
 * ShareReceiverService — 系统 share sheet 接收侧（P2-355）
 *
 * iOS 对应：Share Extension 的 NSExtensionContext + ShareRootController
 *           → 鸿蒙用 UIAbility.onCreate/onNewWant 中的 Want 参数替代 Share Extension
 *
 * 功能：
 *   1. 从系统 Want 中提取外部分享内容（文本/URL/文件路径）
 *   2. 存储为待处理的 ExternalContentItem 列表（全局 pending）
 *   3. ShareControllerPage 在 aboutToAppear 时取出并走 P2-354 标准化管线
 *
 * 平台说明：
 *   iOS Share Extension 是独立进程；HarmonyOS 通过 UIAbility 的 skill/action 接收分享 Want。
 *   接收侧在 module.json5 中声明 skill（action: ohos.want.action.SEND_DATA）。
 *   Want 参数中关键字段：
 *     - want.action = "ohos.want.action.SEND_DATA"（文件/数据分享）
 *     - want.action = "ohos.want.action.SEND"（文本/URL 分享）
 *     - want.uri：文件 URI 或 URL
 *     - want.dataType：MIME type，如 "text/plain"、"image/ *" (不含空格)
 *     - want.parameters["ability.want.params.SHARE_TEXT"]：文本内容
 *
 * 调用链（完整）：
 *   MainAbility.onCreate/onNewWant(want)
 *     → ShareReceiverService.handleShareWant(want)
 *       → extractItemsFromWant(want)
 *         → setPendingExternalContent(items)
 *           → MainTabPage 检测 pendingExternalContent → pushPath("ShareControllerPage")
 *             → ShareControllerPage.aboutToAppear()
 *               → getPendingExternalContent() → ExternalContentNormalizationService.normalizeItems()
 *                 → 发送流（文本/文件/图片 → ShareControllerService）
 */

// ─────────────────────────────────────────────────────────────────
// 全局 pending 外部内容
// ─────────────────────────────────────────────────────────────────

private var _pendingExternalContent: ArrayList<ExternalContentItem> = ArrayList<ExternalContentItem>()
private var _pendingExternalFilePaths: ArrayList<String> = ArrayList<String>()
private var _hasPendingExternalContent: Bool = false

/**
 * 设置待处理外部内容
 * 由 ShareReceiverService.handleShareWant 或 LegacyICloudFilePage.onConfirmMultiSelect 调用
 */
public func setPendingExternalContent(items: ArrayList<ExternalContentItem>): Unit {
    _pendingExternalContent = items
    _hasPendingExternalContent = !items.isEmpty()
    Hilog.info(0, "CjTelegram", "[ShareReceiver] setPendingExternalContent: count=${items.size}")
}

/**
 * 获取并清除待处理外部内容
 */
public func consumePendingExternalContent(): ArrayList<ExternalContentItem> {
    let items = _pendingExternalContent
    _pendingExternalContent = ArrayList<ExternalContentItem>()
    _hasPendingExternalContent = false
    return items
}

/**
 * 是否有待处理外部内容
 * 供 MainTabPage 心跳检测并弹出 ShareControllerPage
 */
public func hasPendingExternalContent(): Bool {
    return _hasPendingExternalContent
}

/**
 * 设置待处理文件路径列表（P2-357 文件导入多选确认后调用）
 * 这些路径会被包装为 ExternalContentItem（kind=file）后路由到 ShareControllerPage
 */
public func setPendingExternalFilePaths(paths: ArrayList<String>): Unit {
    let items = ArrayList<ExternalContentItem>()
    for (path in paths) {
        let item = ExternalContentItem()
        item.kind = "file"
        item.filePath = path
        items.add(item)
    }
    setPendingExternalContent(items)
    Hilog.info(0, "CjTelegram", "[ShareReceiver] setPendingExternalFilePaths: ${paths.size} paths → pending")
}

// ─────────────────────────────────────────────────────────────────
// 单例访问
// ─────────────────────────────────────────────────────────────────

private var _shareReceiverSvcInst: Option<ShareReceiverService> = None

/** 获取 ShareReceiverService 单例 */
public func getShareReceiverService(): ShareReceiverService {
    match (_shareReceiverSvcInst) {
        case Some(s) => return s
        case None =>
            let s = ShareReceiverService()
            _shareReceiverSvcInst = Some(s)
            return s
    }
}

// ─────────────────────────────────────────────────────────────────
// ShareReceiverService
// ─────────────────────────────────────────────────────────────────

/**
 * 系统分享接收服务
 *
 * iOS 对应：Share Extension NSExtensionContext.inputItems[].attachments
 *           HarmonyOS 替代：UIAbility onCreate/onNewWant 的 Want 参数
 */
public class ShareReceiverService {

    public init() {}

    /**
     * 处理系统 Want（分享入口）
     *
     * 从 Want 中提取外部内容，存入全局 pending，供 MainTabPage 弹出 ShareControllerPage。
     *
     * 支持的 Want 格式：
     *   1. action="ohos.want.action.SEND" 文本分享
     *      → parameters["ability.want.params.SHARE_TEXT"] = StringValue(text)
     *   2. action="ohos.want.action.SEND_DATA" 文件分享
     *      → want.uri 为 file:// 或沙盒路径
     *   3. action="ohos.want.action.VIEW_DATA" 通用数据
     *      → want.uri + want.dataType 组合
     *
     * @param want 系统分发的 Want 对象
     * @return true 表示识别为分享 Want 并已存储 pending
     */
    public func handleShareWant(want: Want): Bool {
        let action = want.action
        if (action.size == 0) {
            return false
        }
        if (!action.contains("SEND") && !action.contains("SHARE") && !action.contains("VIEW_DATA")) {
            return false
        }

        let items = this.extractItemsFromWant(want)
        if (items.isEmpty()) {
            Hilog.info(0, "CjTelegram", "[ShareReceiver] handleShareWant: action=${action} → no items extracted")
            return false
        }

        setPendingExternalContent(items)
        Hilog.info(0, "CjTelegram", "[ShareReceiver] handleShareWant: action=${action} → ${items.size} items queued")
        return true
    }

    /**
     * 从 Want 参数中提取外部内容项列表
     *
     * 对应 iOS NSExtensionContext.inputItems 遍历 → NSItemProvider loadData/loadURL/loadImage
     *
     * @param want 系统 Want
     * @return 提取到的 ExternalContentItem 列表
     */
    public func extractItemsFromWant(want: Want): ArrayList<ExternalContentItem> {
        let result = ArrayList<ExternalContentItem>()

        // 1. 提取 SHARE_TEXT 参数（文本/URL 分享）
        let shareText = getStringParam(want, "ability.want.params.SHARE_TEXT")
        if (shareText.size > 0) {
            let item = ExternalContentItem()
            if (isLikelyUrl(shareText)) {
                item.kind = "url"
                item.textValue = shareText
            } else {
                item.kind = "text"
                item.textValue = shareText
            }
            result.add(item)
            Hilog.info(0, "CjTelegram", "[ShareReceiver] extractItems: SHARE_TEXT → ${item.kind} len=${shareText.size}")
        }

        // 2. 提取 want.uri（文件/URL 分享）
        let uri = want.uri
        if (uri.size > 0) {
            let item = ExternalContentItem()
            if (uri.contains("://") && !uri.contains("file://")) {
                item.kind = "url"
                item.textValue = uri
                result.add(item)
                Hilog.info(0, "CjTelegram", "[ShareReceiver] extractItems: uri → url ${uri}")
            } else {
                let localPath = resolveFileUri(uri)
                if (localPath.size > 0) {
                    item.kind = detectFileKind(localPath, want.dataType)
                    item.filePath = localPath
                    result.add(item)
                    Hilog.info(0, "CjTelegram", "[ShareReceiver] extractItems: uri → file kind=${item.kind} path=${localPath}")
                }
            }
        }

        // 3. 提取 SHARE_FILES 数组（多文件分享）
        let filesParam = getStringParam(want, "ability.want.params.SHARE_FILES")
        if (filesParam.size > 0) {
            let paths = filesParam.split(",")
            for (path in paths) {
                let trimmed = path.replace(" ", "")
                if (trimmed.size > 0) {
                    let item = ExternalContentItem()
                    item.kind = detectFileKind(trimmed, "")
                    item.filePath = trimmed
                    result.add(item)
                }
            }
            Hilog.info(0, "CjTelegram", "[ShareReceiver] extractItems: SHARE_FILES → ${result.size} items")
        }

        return result
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 私有辅助
    // ─────────────────────────────────────────────────────────────────────────

    private func getStringParam(want: Want, key: String): String {
        let params = want.parameters
        match (params.get(key)) {
            case Some(WantValueType.StringValue(s)) => return s
            case _ => return ""
        }
    }

    /** 判断字符串是否形似 URL */
    private func isLikelyUrl(text: String): Bool {
        return text.contains("http://") || text.contains("https://") || text.contains("tg://") || text.contains("t.me/")
    }

    /**
     * 将文件 URI 解析为本地绝对路径
     *
     * 对应 iOS url.startAccessingSecurityScopedResource + url.path
     * HarmonyOS file:// URI → 直接去掉 file:// 前缀
     */
    private func resolveFileUri(uri: String): String {
        if (uri.contains("file://")) {
            let idx = findSubstringIndex(uri, "file://")
            if (idx >= 0) {
                return uri[(idx + 7)..]
            }
        }
        if (uri.size > 0 && uri.toRuneArray()[0] == r'/') {
            return uri
        }
        return ""
    }

    private func findSubstringIndex(s: String, sub: String): Int64 {
        if (sub.size == 0 || s.size < sub.size) { return -1 }
        var i: Int64 = 0
        while (i <= s.size - sub.size) {
            if (s[i..(i + sub.size)] == sub) { return i }
            i += 1
        }
        return -1
    }

    /**
     * 根据文件路径和 MIME type 推断 ExternalContentItem.kind
     *
     * 对应 iOS kUTType* 常量匹配
     */
    private func detectFileKind(path: String, dataType: String): String {
        let ext = extractExtFromPath(path)
        let imageExts: Array<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp"]
        let videoExts: Array<String> = ["mp4", "mov", "avi", "mkv", "m4v"]
        let audioExts: Array<String> = ["mp3", "m4a", "aac", "flac", "wav", "ogg"]
        for (e in imageExts) { if (ext == e) { return "image" } }
        for (e in videoExts) { if (ext == e) { return "video" } }
        for (e in audioExts) { if (ext == e) { return "audio" } }
        if (ext == "vcf") { return "vcard" }
        if (dataType.contains("image")) { return "image" }
        if (dataType.contains("video")) { return "video" }
        if (dataType.contains("audio")) { return "audio" }
        return "file"
    }

    private func extractExtFromPath(path: String): String {
        let runes = path.toRuneArray()
        var lastDot: Int64 = -1
        var i: Int64 = 0
        while (i < runes.size) {
            if (runes[i] == r'.') { lastDot = i }
            i += 1
        }
        if (lastDot < 0 || lastDot + 1 >= runes.size) { return "" }
        return path[(lastDot + 1)..].toAsciiLower()
    }
}
