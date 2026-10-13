package ohos_app_cangjie_entry.services

import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.models.*
import ohos_app_cangjie_entry.models.api.*
import std.collection.ArrayList

/**
 * TelegramCore API 工具服务
 *
 * 对应 Telegram-iOS TelegramCore/Sources/ApiUtils/
 * 提供跨服务共用的工具方法：
 * - UserResponse → TelegramUser 转换
 * - ChatResponse → TelegramChat 转换
 * - Admin/Banned rights flags 解析
 * - Media resource location 构建
 * - TextEntity 解析
 *
 * 禁止重复 RealMessageService/RealContactService/RealChatListService 中已有的方法
 */
private var _apiUtilsServiceInstance: Option<TelegramCore_ApiUtilsService> = None

public func getTelegramCore_ApiUtilsService(): TelegramCore_ApiUtilsService {
    match (_apiUtilsServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = TelegramCore_ApiUtilsService()
            _apiUtilsServiceInstance = Some(inst)
            return inst
    }
}

public class TelegramCore_ApiUtilsService {
    public init() {}

    // ==================== UserResponse → TelegramUser ====================

    /**
     * 将 TL UserResponse 转换为 TelegramUser 模型
     * 供上层统一类型使用
     */
    public func userResponseToTelegramUser(user: UserResponse): TelegramUser {
        let tg = TelegramUser()
        tg.id = user.id
        tg.isBot = user.isBot
        tg.firstName = user.firstName
        tg.lastName = user.lastName
        tg.username = user.username
        tg.isPremium = user.isPremium
        return tg
    }

    // ==================== ChatResponse → TelegramChat ====================

    /**
     * 将 TL ChatResponse 转换为 TelegramChat 模型
     * chatType: "channel" | "supergroup" | "group"
     */
    public func chatResponseToTelegramChat(chat: ChatResponse): TelegramChat {
        let tg = TelegramChat()
        tg.id = chat.id
        tg.title = chat.title
        tg.username = chat.username
        if (chat.isChannel && chat.isMegagroup) {
            tg.chatType = "supergroup"
        } else if (chat.isChannel) {
            tg.chatType = "channel"
        } else {
            tg.chatType = "group"
        }
        return tg
    }

    // ==================== Admin Rights Flags ====================

    /**
     * 解析 ChatAdminRights flags 为权限名称列表
     * 对应 TLMethods ChatAdminRights 注释的 bit 定义
     */
    public func parseAdminRightsFlags(flags: Int32): ArrayList<String> {
        let result = ArrayList<String>()
        if ((flags & 1) != 0) { result.add("change_info") }
        if ((flags & 2) != 0) { result.add("post_messages") }
        if ((flags & 4) != 0) { result.add("edit_messages") }
        if ((flags & 8) != 0) { result.add("delete_messages") }
        if ((flags & 16) != 0) { result.add("ban_users") }
        if ((flags & 32) != 0) { result.add("invite_users") }
        if ((flags & 128) != 0) { result.add("pin_messages") }
        if ((flags & 512) != 0) { result.add("add_admins") }
        if ((flags & 1024) != 0) { result.add("anonymous") }
        if ((flags & 2048) != 0) { result.add("manage_call") }
        if ((flags & 4096) != 0) { result.add("other") }
        if ((flags & 8192) != 0) { result.add("manage_topics") }
        return result
    }

    /**
     * 从权限名称列表构建 ChatAdminRights flags
     */
    public func buildAdminRightsFlags(permissions: ArrayList<String>): Int32 {
        var flags: Int32 = 0
        for (p in permissions) {
            if (p == "change_info") { flags = flags | 1 }
            else if (p == "post_messages") { flags = flags | 2 }
            else if (p == "edit_messages") { flags = flags | 4 }
            else if (p == "delete_messages") { flags = flags | 8 }
            else if (p == "ban_users") { flags = flags | 16 }
            else if (p == "invite_users") { flags = flags | 32 }
            else if (p == "pin_messages") { flags = flags | 128 }
            else if (p == "add_admins") { flags = flags | 512 }
            else if (p == "anonymous") { flags = flags | 1024 }
            else if (p == "manage_call") { flags = flags | 2048 }
            else if (p == "other") { flags = flags | 4096 }
            else if (p == "manage_topics") { flags = flags | 8192 }
        }
        return flags
    }

    // ==================== Banned Rights Flags ====================

    /**
     * 解析 ChatBannedRights flags 为禁止的权限名称列表
     * 设置对应 bit 表示禁止该操作
     */
    public func parseBannedRightsFlags(flags: Int32): ArrayList<String> {
        let result = ArrayList<String>()
        if ((flags & 1) != 0) { result.add("view_messages") }
        if ((flags & 2) != 0) { result.add("send_messages") }
        if ((flags & 4) != 0) { result.add("send_media") }
        if ((flags & 8) != 0) { result.add("send_stickers") }
        if ((flags & 16) != 0) { result.add("send_gifs") }
        if ((flags & 32) != 0) { result.add("send_games") }
        if ((flags & 64) != 0) { result.add("send_inline") }
        if ((flags & 128) != 0) { result.add("embed_links") }
        if ((flags & 256) != 0) { result.add("send_polls") }
        if ((flags & 1024) != 0) { result.add("change_info") }
        if ((flags & 32768) != 0) { result.add("invite_users") }
        if ((flags & 131072) != 0) { result.add("pin_messages") }
        if ((flags & 262144) != 0) { result.add("manage_topics") }
        return result
    }

    /**
     * 从禁止权限名称列表构建 ChatBannedRights flags
     */
    public func buildBannedRightsFlags(permissions: ArrayList<String>): Int32 {
        var flags: Int32 = 0
        for (p in permissions) {
            if (p == "view_messages") { flags = flags | 1 }
            else if (p == "send_messages") { flags = flags | 2 }
            else if (p == "send_media") { flags = flags | 4 }
            else if (p == "send_stickers") { flags = flags | 8 }
            else if (p == "send_gifs") { flags = flags | 16 }
            else if (p == "send_games") { flags = flags | 32 }
            else if (p == "send_inline") { flags = flags | 64 }
            else if (p == "embed_links") { flags = flags | 128 }
            else if (p == "send_polls") { flags = flags | 256 }
            else if (p == "change_info") { flags = flags | 1024 }
            else if (p == "invite_users") { flags = flags | 32768 }
            else if (p == "pin_messages") { flags = flags | 131072 }
            else if (p == "manage_topics") { flags = flags | 262144 }
        }
        return flags
    }

    // ==================== Media Resource Location ====================

    /**
     * 构建 InputPhotoFileLocation 用于下载照片
     */
    public func buildInputPhotoFileLocation(
        id: Int64,
        accessHash: Int64,
        fileReference: Array<Byte>,
        thumbSize: String
    ): InputPhotoFileLocation {
        let loc = InputPhotoFileLocation()
        loc.id = id
        loc.accessHash = accessHash
        loc.fileReference = fileReference
        loc.thumbSize = thumbSize
        return loc
    }

    /**
     * 构建 InputDocumentFileLocation 用于下载文档/视频/语音等
     */
    public func buildInputDocumentFileLocation(
        id: Int64,
        accessHash: Int64,
        fileReference: Array<Byte>,
        thumbSize: String
    ): InputDocumentFileLocation {
        let loc = InputDocumentFileLocation()
        loc.id = id
        loc.accessHash = accessHash
        loc.fileReference = fileReference
        loc.thumbSize = thumbSize
        return loc
    }

    /**
     * 构建 InputPeerPhotoFileLocation 用于下载用户/群组头像
     */
    public func buildInputPeerPhotoFileLocation(
        big: Bool,
        peer: TLObject,
        photoId: Int64
    ): InputPeerPhotoFileLocation {
        let loc = InputPeerPhotoFileLocation()
        loc.big = big
        loc.peer = peer
        loc.photoId = photoId
        return loc
    }

    // ==================== TextEntity 解析 ====================

    /**
     * 将 TLTextEntity 列表转换为 TextEntityData 列表
     * 仅保留 UI 可渲染的类型
     */
    public func parseTextEntitiesToData(entities: ArrayList<TLTextEntity>): ArrayList<TextEntityData> {
        let result = ArrayList<TextEntityData>()
        for (tlEntity in entities) {
            let entity = TextEntityData()
            entity.entityType = tlEntity.entityType
            entity.offset = tlEntity.offset
            entity.length = tlEntity.length
            entity.url = tlEntity.url
            entity.customEmojiDocumentId = tlEntity.documentId
            result.add(entity)
        }
        return result
    }
}
