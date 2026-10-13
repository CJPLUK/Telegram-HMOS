package ohos_app_cangjie_entry.viewmodels

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.TemporaryCachedPeerDataManagerService
import ohos_app_cangjie_entry.services.getTemporaryCachedPeerDataManagerService
import ohos_app_cangjie_entry.models.AdminMemberData
import std.collection.ArrayList

/**
 * 临时缓存 Peer 数据管理 ViewModel
 *
 * 对应 iOS TemporaryCachedPeerDataManager 的对外调用接口层，
 * 封装 TemporaryCachedPeerDataManagerService 的获取/刷新能力，
 * 供 AdminManagePage、GroupMembersPage 等 UI 层调用。
 *
 * 调用链：
 *   ViewModel.getAdmins(peerId)
 *     → Service.getOrFetchAdmins(peerId)
 *       → getMTProtoClient().sendRequest(ChannelsGetParticipants)
 *         → TLDeserializer → [AdminMemberData] (cached)
 */
public class TemporaryCachedPeerDataManagerViewModel {
    private var service: TemporaryCachedPeerDataManagerService

    public init() {
        this.service = getTemporaryCachedPeerDataManagerService()
    }

    /**
     * 获取频道管理员列表（命中缓存直接返回；过期或首次则向 MTProto 请求并更新缓存）
     *
     * @param peerId   频道 ID
     * @return 管理员列表
     */
    public func getAdmins(peerId: Int64): ArrayList<AdminMemberData> {
        Hilog.info(0, "CjTelegram", "[TCPDMViewModel] getAdmins peerId=${peerId}")
        return this.service.getOrFetchAdmins(peerId, forceRefresh: false)
    }

    /**
     * 强制刷新管理员列表（跳过缓存，直接向 MTProto 请求）
     *
     * @param peerId   频道 ID
     * @return 最新管理员列表
     */
    public func refreshAdmins(peerId: Int64): ArrayList<AdminMemberData> {
        Hilog.info(0, "CjTelegram", "[TCPDMViewModel] refreshAdmins peerId=${peerId}")
        return this.service.getOrFetchAdmins(peerId, forceRefresh: true)
    }

    /**
     * 使指定频道的管理员缓存失效（管理员发生变更时调用）
     *
     * @param peerId   频道 ID
     */
    public func invalidateAdminCache(peerId: Int64): Unit {
        Hilog.info(0, "CjTelegram", "[TCPDMViewModel] invalidateAdminCache peerId=${peerId}")
        this.service.invalidateCache(peerId)
    }

    /**
     * 注册 channel 的 accessHash（由外层聊天列表或群组详情页提供）
     *
     * @param peerId      频道 ID
     * @param accessHash  accessHash
     */
    public func registerChannelAccessHash(peerId: Int64, accessHash: Int64): Unit {
        this.service.registerChannelAccessHash(peerId, accessHash)
    }
}
