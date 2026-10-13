package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.TLTextEntity

/**
 * 文本链接编辑服务
 *
 * 对应 iOS: ChatTextLinkEditController (ChatTextLinkEditUI)
 *
 * 职责：
 * - URL 合法性校验（支持 http / https / tg / ton / tonsite scheme）
 * - URL 规范化（补全 https:// 前缀）
 * - 构建 messageEntityTextUrl (TLTextEntity)
 *
 * MTProto: N/A — 纯本地编辑逻辑，不发网络请求
 */
public class ChatTextLinkEditService {

    public init() {}

    /**
     * 校验 URL 是否合法
     * 支持的 scheme：http / https / tg / ton / tonsite
     */
    public func isValidLinkUrl(url: String): Bool {
        if (url.size == 0) {
            return false
        }
        let lower = url.toAsciiLower()
        if (lower.startsWith("http://")) { return true }
        if (lower.startsWith("https://")) { return true }
        if (lower.startsWith("tg://")) { return true }
        if (lower.startsWith("ton://")) { return true }
        if (lower.startsWith("tonsite://")) { return true }
        return false
    }

    /**
     * 规范化 URL：若无 scheme 则补全 https://
     */
    public func normalizeUrl(url: String): String {
        if (url.size == 0) {
            return url
        }
        let lower = url.toAsciiLower()
        if (lower.startsWith("http://")) { return url }
        if (lower.startsWith("https://")) { return url }
        if (lower.startsWith("tg://")) { return url }
        if (lower.startsWith("ton://")) { return url }
        if (lower.startsWith("tonsite://")) { return url }
        return "https://" + url
    }

    /**
     * 构建 messageEntityTextUrl 实体
     *
     * @param offset  实体在消息文本中的起始字节偏移
     * @param length  实体在消息文本中的字节长度
     * @param url     超链接目标 URL（已规范化）
     * @return TLTextEntity，entityType = "textUrl"
     */
    public func buildTextUrlEntity(offset: Int32, length: Int32, url: String): TLTextEntity {
        let entity = TLTextEntity()
        entity.entityType = "textUrl"
        entity.offset = offset
        entity.length = length
        entity.url = url
        Hilog.info(0, "CjTelegram", "[ChatTextLinkEditService] built textUrl entity offset=${offset} length=${length}")
        return entity
    }
}

// 全局单例访问器
var _chatTextLinkEditService: ?ChatTextLinkEditService = None

public func getChatTextLinkEditService(): ChatTextLinkEditService {
    match (_chatTextLinkEditService) {
        case Some(svc) => return svc
        case None =>
            let svc = ChatTextLinkEditService()
            _chatTextLinkEditService = Some(svc)
            return svc
    }
}
