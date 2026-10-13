package ohos_app_cangjie_entry.pages

/**
 * StickerPreviewPagePresentationArguments — 贴纸包预览路由参数
 *
 * 对应 iOS StickerPreviewControllerPresentationArguments：
 * 封装打开贴纸包预览页（StickerPackPreviewPage）所需的路由参数。
 *
 * 路由参数格式（pipe 分隔字符串，传入 NavPathStack.pushPathByName 的 param）：
 *   "packId|accessHash|shortName"
 *   例："1234567890|-9876543210|AnimEmoji"
 *
 * packId=0 且 shortName 非空时按短名称查询。
 */
public class StickerPreviewPagePresentationArguments {
    public var packId: Int64 = 0
    public var accessHash: Int64 = 0
    public var shortName: String = ""

    public init() {}

    public init(packId: Int64, accessHash: Int64, shortName: String) {
        this.packId = packId
        this.accessHash = accessHash
        this.shortName = shortName
    }

    /**
     * 编码为路由参数字符串 "packId|accessHash|shortName"
     */
    public func toRouteParam(): String {
        return this.packId.toString() + "|" + this.accessHash.toString() + "|" + this.shortName
    }

    /**
     * 从路由参数字符串解析 "packId|accessHash|shortName"
     */
    public static func fromRouteParam(raw: String): StickerPreviewPagePresentationArguments {
        let args = StickerPreviewPagePresentationArguments()
        if (raw.size == 0) {
            return args
        }
        let parts = raw.split("|")
        if (parts.size >= 1) {
            args.packId = parseInt64Safe(parts[0])
        }
        if (parts.size >= 2) {
            args.accessHash = parseInt64Safe(parts[1])
        }
        if (parts.size >= 3) {
            args.shortName = parts[2]
        }
        return args
    }
}

// ─── 辅助函数 ───────────────────────────────────────────────────────────────

/**
 * 安全解析 Int64，非法输入返回 0
 */
private func parseInt64Safe(s: String): Int64 {
    var result: Int64 = 0
    var negative = false
    var start: Int64 = 0
    let runes = s.toRuneArray()
    if (runes.size > 0 && runes[0] == r'-') {
        negative = true
        start = 1
    }
    var i = start
    while (i < Int64(runes.size)) {
        let d = Int64(UInt32(runes[i])) - 48
        if (d < 0 || d > 9) { break }
        result = result * 10 + d
        i = i + 1
    }
    if (negative) { return -result }
    return result
}
