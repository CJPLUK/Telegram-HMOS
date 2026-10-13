package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.models.ChatFolder

/**
 * 对话过滤器设置头数据层
 *
 * 封装 messages.getDialogFilters TL 方法，为 ChatListFilterSettingsHeaderComponent 提供数据。
 * 调用链：Service → MTProtoClient.sendRequest() → 解析 DialogFiltersResponse
 *
 * 使用 RealChatListService 缓存，不重复实现聊天列表逻辑。
 */
private var _chatListFilterSettingsHeaderServiceInstance: Option<ChatListFilterSettingsHeaderService> = None

public func getChatListFilterSettingsHeaderService(): ChatListFilterSettingsHeaderService {
    match (_chatListFilterSettingsHeaderServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ChatListFilterSettingsHeaderService()
            _chatListFilterSettingsHeaderServiceInstance = Some(inst)
            return inst
    }
}

public class ChatListFilterSettingsHeaderService {
    private var _tagsEnabled: Bool = false

    public func tagsEnabled(): Bool { return this._tagsEnabled }

    /**
     * 从服务器获取对话过滤器列表
     * 调用 messages.getDialogFilters TL 方法
     *
     * @return 过滤器列表，失败时返回空列表
     */
    public func fetchFiltersFromServer(): ArrayList<ChatFolder> {
        try {
            let client = getMTProtoClient()
            let req = MessagesGetDialogFilters()
            let requestBytes = req.toBytes()

            Hilog.info(0, "CjTelegram", "%{public}s", "[ChatListFilterSettingsHeaderService] Sending messages.getDialogFilters")
            let responseData = client.sendRequest(requestBytes)

            if (responseData.size == 0) {
                Hilog.info(0, "CjTelegram", "%{public}s", "[ChatListFilterSettingsHeaderService] Empty response")
                return ArrayList<ChatFolder>()
            }

            // 检查 RPC 错误
            let checkD = TLDeserializer(responseData)
            let checkConstructor = checkD.readUInt32()
            if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMessage = checkD.readString()
                Hilog.info(0, "CjTelegram", "%{public}s", "[ChatListFilterSettingsHeaderService] RPC Error: ${errorCode} - ${errorMessage}")
                return ArrayList<ChatFolder>()
            }

            let response = DialogFiltersResponse.deserialize(responseData)
            this._tagsEnabled = response.tagsEnabled
            Hilog.info(0, "CjTelegram", "%{public}s", "[ChatListFilterSettingsHeaderService] Fetched ${response.filters.size} filters from server")

            // 同步到 RealChatListService 缓存
            getRealChatListService().replaceDialogFiltersCache(response.filters)

            return response.filters
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "%{public}s", "[ChatListFilterSettingsHeaderService] fetchFiltersFromServer failed: ${e}")
            return ArrayList<ChatFolder>()
        }
    }

    /**
     * 获取过滤器列表（优先从 RealChatListService 缓存读取）
     * 若缓存为空则从服务器拉取
     */
    public func getFilters(): ArrayList<ChatFolder> {
        let chatListSvc = getRealChatListService()
        let cached = chatListSvc.getDialogFilters()
        if (!cached.isEmpty()) {
            return cached
        }
        return this.fetchFiltersFromServer()
    }

    /** Fetch the server-authored recommended folder presets used by iOS. */
    public func fetchSuggestedFiltersFromServer(): ArrayList<ChatFolder> {
        try {
            let responseData = getMTProtoClient().sendRequest(MessagesGetSuggestedDialogFilters().toBytes())
            if (responseData.size < 4) { return ArrayList<ChatFolder>() }
            let check = TLDeserializer(responseData)
            let constructor = check.readUInt32()
            if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
                let errorCode = check.readInt32()
                let errorMessage = check.readString()
                Hilog.info(0, "CjTelegram", "%{public}s", "[ChatListFilterSettingsHeaderService] getSuggestedDialogFilters RPC Error: ${errorCode} - ${errorMessage}")
                return ArrayList<ChatFolder>()
            }
            let response = SuggestedDialogFiltersResponse.deserialize(responseData)
            Hilog.info(0, "CjTelegram", "%{public}s", "[ChatListFilterSettingsHeaderService] Fetched ${response.filters.size} suggested filters")
            return response.filters
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "%{public}s", "[ChatListFilterSettingsHeaderService] fetchSuggestedFiltersFromServer failed: ${e}")
            return ArrayList<ChatFolder>()
        }
    }
}
