package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.TLTextEntity

/**
 * 文本格式菜单服务
 *
 * 对应 iOS: submodules/TextInputMenu/Sources/TextInputMenu.swift
 *
 * 职责：
 * - 构建文本格式实体（bold / italic / underline / strike / code / spoiler / textUrl）
 * - 纯本地编辑逻辑，不发 MTProto 请求（iOS 原版亦无 TL 调用）
 *
 * MTProto: N/A — 纯本地格式化菜单无 TL（iOS 原版亦如此）
 */
public class TextInputMenuService {

    public init() {}

    /**
     * 构建 bold 实体（粗体）
     */
    public func buildBoldEntity(offset: Int32, length: Int32): TLTextEntity {
        let entity = TLTextEntity()
        entity.entityType = "bold"
        entity.offset = offset
        entity.length = length
        Hilog.info(0, "CjTelegram", "[TextInputMenuService] buildBoldEntity")
        return entity
    }

    /**
     * 构建 italic 实体（斜体）
     */
    public func buildItalicEntity(offset: Int32, length: Int32): TLTextEntity {
        let entity = TLTextEntity()
        entity.entityType = "italic"
        entity.offset = offset
        entity.length = length
        Hilog.info(0, "CjTelegram", "[TextInputMenuService] buildItalicEntity")
        return entity
    }

    /**
     * 构建 underline 实体（下划线）
     */
    public func buildUnderlineEntity(offset: Int32, length: Int32): TLTextEntity {
        let entity = TLTextEntity()
        entity.entityType = "underline"
        entity.offset = offset
        entity.length = length
        Hilog.info(0, "CjTelegram", "[TextInputMenuService] buildUnderlineEntity")
        return entity
    }

    /**
     * 构建 strike 实体（删除线）
     */
    public func buildStrikeEntity(offset: Int32, length: Int32): TLTextEntity {
        let entity = TLTextEntity()
        entity.entityType = "strike"
        entity.offset = offset
        entity.length = length
        Hilog.info(0, "CjTelegram", "[TextInputMenuService] buildStrikeEntity")
        return entity
    }

    /**
     * 构建 code 实体（等宽字体/monospace）
     */
    public func buildCodeEntity(offset: Int32, length: Int32): TLTextEntity {
        let entity = TLTextEntity()
        entity.entityType = "code"
        entity.offset = offset
        entity.length = length
        Hilog.info(0, "CjTelegram", "[TextInputMenuService] buildCodeEntity")
        return entity
    }

    /**
     * 构建 spoiler 实体（遮挡内容）
     */
    public func buildSpoilerEntity(offset: Int32, length: Int32): TLTextEntity {
        let entity = TLTextEntity()
        entity.entityType = "spoiler"
        entity.offset = offset
        entity.length = length
        Hilog.info(0, "CjTelegram", "[TextInputMenuService] buildSpoilerEntity")
        return entity
    }

    /**
     * 构建 textUrl 实体（超链接）
     * url 为空字符串表示移除链接
     */
    public func buildTextUrlEntity(offset: Int32, length: Int32, url: String): TLTextEntity {
        let entity = TLTextEntity()
        entity.entityType = "textUrl"
        entity.offset = offset
        entity.length = length
        entity.url = url
        Hilog.info(0, "CjTelegram", "[TextInputMenuService] buildTextUrlEntity")
        return entity
    }
}

// 全局单例访问器
var _textInputMenuService: ?TextInputMenuService = None

public func getTextInputMenuService(): TextInputMenuService {
    match (_textInputMenuService) {
        case Some(svc) => return svc
        case None =>
            let svc = TextInputMenuService()
            _textInputMenuService = Some(svc)
            return svc
    }
}
