package ohos_app_cangjie_entry.services

/**
 * FormWidgetHostService — P2-435 (Cangjie side)
 *
 * 桌面卡片宿主数据层（Cangjie 侧）。
 *
 * PLATFORM BOUNDARY NOTE — 重要架构说明：
 *   HarmonyOS 桌面卡片（服务卡片）运行在独立的 ArkTS 受限运行时进程中。
 *   Cangjie 组件（@Component class）无法在卡片进程运行——这是真实平台边界，不是技术限制。
 *   卡片 UI 必须使用 ArkTS (.ets) 实现（FormExtension.ets + WidgetCard.ets）。
 *   Cangjie 侧的职责：
 *     1. 通过 WidgetStorageService 将 widget 数据写入 distributedKVStore（跨进程共享）
 *     2. 在应用内展示时提供 WidgetAvatarsGridComponent（应用内 widget preview）
 *     3. 通过 FormWidgetHostService 封装 updateForm 数据构建逻辑
 *
 * iOS 对应：WidgetKit Timeline Provider（同样是独立 Extension 进程）
 *
 * INTEROP:
 *   FormExtensionAbility → ArkTS (.ets) 专属卡片宿主 API
 *   卡片 UI → ArkTS (.ets) 文件 (entry/src/main/ets/widget/)
 *   跨进程数据 → distributedKVStore (WidgetStorageService)
 *
 * 调用链（main app → card process）：
 *   (main app) WidgetItemsServiceV2.refreshWidgetData()
 *     → WidgetStorageService.persistWidgetData()
 *       → distributedKVStore.put(WIDGET_DATA_KEY, json)
 *   (card process / ArkTS) FormExtension.onUpdateForm()
 *     → distributedKVStore.get(WIDGET_DATA_KEY)
 *     → formProvider.updateForm(formId, formBindingData)
 *
 * @State 无（服务类，无 UI 绑定）
 */

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.models.WidgetData
import ohos_app_cangjie_entry.models.WidgetDataPeer

// ============================================================
// Singleton
// ============================================================

private var _formWidgetHostServiceInstance: Option<FormWidgetHostService> = None

public func getFormWidgetHostService(): FormWidgetHostService {
    match (_formWidgetHostServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = FormWidgetHostService()
            _formWidgetHostServiceInstance = Some(inst)
            return inst
    }
}

// ============================================================
// FormWidgetHostService
// ============================================================

public class FormWidgetHostService {
    // 已注册的卡片 formId 列表（ArkTS 侧通过 Cangjie-ArkTS interop 传入）
    private var registeredFormIds: Array<String> = Array<String>(0, repeat: "")

    /**
     * 注册卡片 formId（由 ArkTS FormExtension.onAddForm 通过 arkinterop 调用）
     */
    public func registerFormId(formId: String): Unit {
        let newIds = Array<String>(this.registeredFormIds.size + 1, repeat: "")
        var i: Int64 = 0
        while (i < this.registeredFormIds.size) {
            newIds[i] = this.registeredFormIds[i]
            i = i + 1
        }
        newIds[this.registeredFormIds.size] = formId
        this.registeredFormIds = newIds
        Hilog.info(0, "CjTelegram", "[FormWidgetHostService] registered formId=${formId}")
    }

    /**
     * 移除卡片 formId（由 ArkTS FormExtension.onDestroyForm 通过 arkinterop 调用）
     */
    public func removeFormId(formId: String): Unit {
        var newSize: Int64 = 0
        for (id in this.registeredFormIds) {
            if (id != formId) { newSize = newSize + 1 }
        }
        let newIds = Array<String>(newSize, repeat: "")
        var j: Int64 = 0
        for (id in this.registeredFormIds) {
            if (id != formId) {
                newIds[j] = id
                j = j + 1
            }
        }
        this.registeredFormIds = newIds
        Hilog.info(0, "CjTelegram", "[FormWidgetHostService] removed formId=${formId}")
    }

    /**
     * 获取所有注册的 formId（供 ArkTS updateForm 循环调用）
     */
    public func getRegisteredFormIds(): Array<String> {
        return this.registeredFormIds
    }

    /**
     * 构建 formBindingData JSON 字符串（供 ArkTS formProvider.updateForm 使用）
     *
     * 读取 WidgetStorageService 中 KVStore 数据，封装为 formBindingData 格式。
     * ArkTS 侧 JSON.parse(bindingDataStr) 后传给 formProvider.updateForm。
     *
     * 格式：
     * {
     *   "peers": [ { "id": "...", "name": "...", "letter": "...", "badge": 0, ... }, ... ],
     *   "isLocked": false,
     *   "appName": "Telegram"
     * }
     */
    public func buildFormBindingDataJson(): String {
        let widgetJson = getWidgetStorageService().getWidgetJsonFromKVStore()
        if (widgetJson.size == 0) {
            return this.buildEmptyFormJson()
        }

        // 使用 WidgetItemsServiceV2 缓存数据构建 formBindingData
        match (getWidgetItemsServiceV2().getCachedWidgetData()) {
            case None => return this.buildEmptyFormJson()
            case Some(wd) =>
                let isLocked = !wd.isUnlocked() && wd.accountId != 0
                if (isLocked) {
                    return this.buildLockedFormJson()
                }
                match (wd.content) {
                    case None => return this.buildEmptyFormJson()
                    case Some(wdPeers) =>
                        return this.buildPeersFormJson(wdPeers.peers)
                }
        }
    }

    // ============================================================
    // 私有 JSON 构建辅助
    // ============================================================

    private func buildEmptyFormJson(): String {
        let appName = WidgetPresentationData.appName.replace("\"", "\\\"")
        let noChats = WidgetPresentationData.noChatsTitle.replace("\"", "\\\"")
        return "{\"peers\":[],\"isLocked\":false,\"isEmpty\":true,\"appName\":\"${appName}\",\"emptyText\":\"${noChats}\"}"
    }

    private func buildLockedFormJson(): String {
        let appName = WidgetPresentationData.appName.replace("\"", "\\\"")
        let lockedTitle = WidgetPresentationData.lockedTitle.replace("\"", "\\\"")
        let lockedSub = WidgetPresentationData.lockedSubtitle.replace("\"", "\\\"")
        return "{\"peers\":[],\"isLocked\":true,\"isEmpty\":false,\"appName\":\"${appName}\",\"lockedTitle\":\"${lockedTitle}\",\"lockedSubtitle\":\"${lockedSub}\"}"
    }

    private func buildPeersFormJson(peers: Array<WidgetDataPeer>): String {
        let appName = WidgetPresentationData.appName.replace("\"", "\\\"")
        var peersJson = "["
        var first = true
        var i: Int64 = 0
        let maxPeers: Int64 = if (peers.size < 4) { peers.size } else { 4 }
        while (i < maxPeers) {
            let peer = peers[i]
            if (!first) { peersJson = peersJson + "," }
            peersJson = peersJson + this.buildPeerJson(peer)
            first = false
            i = i + 1
        }
        peersJson = peersJson + "]"
        return "{\"peers\":${peersJson},\"isLocked\":false,\"isEmpty\":false,\"appName\":\"${appName}\"}"
    }

    private func buildPeerJson(peer: WidgetDataPeer): String {
        let nameEsc = peer.name.replace("\\", "\\\\").replace("\"", "\\\"")
        let letterEsc = peer.primaryLetter().replace("\\", "\\\\").replace("\"", "\\\"")
        let avatarEsc = peer.avatarPath.replace("\\", "\\\\").replace("\"", "\\\"")
        let badgeCount: Int32 = match (peer.badge) {
            case Some(b) => b.count
            case None => Int32(0)
        }
        let isMuted: Bool = match (peer.badge) {
            case Some(b) => b.isMuted
            case None => false
        }
        return "{\"id\":${peer.id},\"name\":\"${nameEsc}\",\"letter\":\"${letterEsc}\",\"avatarPath\":\"${avatarEsc}\",\"badge\":${badgeCount},\"isMuted\":${isMuted}}"
    }
}
