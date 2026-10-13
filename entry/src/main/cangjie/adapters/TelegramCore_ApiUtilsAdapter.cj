package ohos_app_cangjie_entry.adapters

import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.models.*
import ohos_app_cangjie_entry.models.api.*
import ohos_app_cangjie_entry.services.getTelegramCore_ApiUtilsService
import std.collection.ArrayList

/**
 * TelegramCore ApiUtils 对外接口适配层
 *
 * 对应 Telegram-iOS TelegramCore/ApiUtils 对外 API
 * 为上层业务提供统一的类型转换和工具方法，委托 TelegramCore_ApiUtilsService 实现
 *
 * 使用方式：
 *   let adapter = getTelegramCore_ApiUtilsAdapter()
 *   let tgUser = adapter.userResponseToTelegramUser(userResponse)
 *   let tgChat = adapter.chatResponseToTelegramChat(chatResponse)
 */
private var _adapterInstance: Option<TelegramCore_ApiUtilsAdapter> = None

public func getTelegramCore_ApiUtilsAdapter(): TelegramCore_ApiUtilsAdapter {
    match (_adapterInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = TelegramCore_ApiUtilsAdapter()
            _adapterInstance = Some(inst)
            return inst
    }
}

public class TelegramCore_ApiUtilsAdapter {
    public init() {}

    /**
     * UserResponse → TelegramUser 转换
     */
    public func userResponseToTelegramUser(user: UserResponse): TelegramUser {
        return getTelegramCore_ApiUtilsService().userResponseToTelegramUser(user)
    }

    /**
     * ChatResponse → TelegramChat 转换
     */
    public func chatResponseToTelegramChat(chat: ChatResponse): TelegramChat {
        return getTelegramCore_ApiUtilsService().chatResponseToTelegramChat(chat)
    }

    /**
     * 解析管理员权限 flags 为权限名称列表
     */
    public func parseAdminRightsFlags(flags: Int32): ArrayList<String> {
        return getTelegramCore_ApiUtilsService().parseAdminRightsFlags(flags)
    }

    /**
     * 从权限名称列表构建 ChatAdminRights flags
     */
    public func buildAdminRightsFlags(permissions: ArrayList<String>): Int32 {
        return getTelegramCore_ApiUtilsService().buildAdminRightsFlags(permissions)
    }

    /**
     * 解析封禁权限 flags 为禁止的权限名称列表
     */
    public func parseBannedRightsFlags(flags: Int32): ArrayList<String> {
        return getTelegramCore_ApiUtilsService().parseBannedRightsFlags(flags)
    }

    /**
     * 从禁止权限名称列表构建 ChatBannedRights flags
     */
    public func buildBannedRightsFlags(permissions: ArrayList<String>): Int32 {
        return getTelegramCore_ApiUtilsService().buildBannedRightsFlags(permissions)
    }

    /**
     * 构建 InputPhotoFileLocation
     */
    public func buildInputPhotoFileLocation(
        id: Int64,
        accessHash: Int64,
        fileReference: Array<Byte>,
        thumbSize: String
    ): InputPhotoFileLocation {
        return getTelegramCore_ApiUtilsService().buildInputPhotoFileLocation(id, accessHash, fileReference, thumbSize)
    }

    /**
     * 构建 InputDocumentFileLocation
     */
    public func buildInputDocumentFileLocation(
        id: Int64,
        accessHash: Int64,
        fileReference: Array<Byte>,
        thumbSize: String
    ): InputDocumentFileLocation {
        return getTelegramCore_ApiUtilsService().buildInputDocumentFileLocation(id, accessHash, fileReference, thumbSize)
    }

    /**
     * 构建 InputPeerPhotoFileLocation
     */
    public func buildInputPeerPhotoFileLocation(
        big: Bool,
        peer: TLObject,
        photoId: Int64
    ): InputPeerPhotoFileLocation {
        return getTelegramCore_ApiUtilsService().buildInputPeerPhotoFileLocation(big, peer, photoId)
    }

    /**
     * TLTextEntity 列表 → TextEntityData 列表
     */
    public func parseTextEntitiesToData(entities: ArrayList<TLTextEntity>): ArrayList<TextEntityData> {
        return getTelegramCore_ApiUtilsService().parseTextEntitiesToData(entities)
    }
}
