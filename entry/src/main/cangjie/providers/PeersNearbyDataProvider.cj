package ohos_app_cangjie_entry.providers

import ohos_app_cangjie_entry.services.getPeersNearbyService
import ohos_app_cangjie_entry.core.mtproto.{PeerNearbyEntry, PeersNearbyResult}
import std.collection.ArrayList

private var _peersNearbyDataProviderInstance: Option<PeersNearbyDataProvider> = None

public func getPeersNearbyDataProvider(): PeersNearbyDataProvider {
    match (_peersNearbyDataProviderInstance) {
        case Some(p) => return p
        case None =>
            let p = PeersNearbyDataProvider()
            _peersNearbyDataProviderInstance = Some(p)
            return p
    }
}

/**
 * PeersNearby 数据接口 (Phase TEPNB)
 *
 * 将 PeersNearbyService API 数据转为 UI 可用的列表
 * 对应 iOS PeersNearbyContext + PeersNearbyController 的 ViewModel 层
 *
 * 提供：
 * - 附近用户列表（含距离信息）
 * - 附近群组列表
 * - 自己的位置过期时间（从 getLocated 响应解析）
 */
public class PeersNearbyDataProvider {
    private let service = getPeersNearbyService()
    private var lastResult: PeersNearbyResult = PeersNearbyResult()

    /**
     * 加载附近的人完整数据（一次请求获取用户+群组+自己的位置）
     * @param lat 纬度
     * @param lng 经度
     * @return 完整解析结果
     */
    public func loadNearby(lat: Float64, lng: Float64): PeersNearbyResult {
        this.lastResult = this.service.getLocated(lat, lng)
        return this.lastResult
    }

    /**
     * 加载附近用户列表
     * @param lat 纬度
     * @param lng 经度
     * @return 附近用户列表（含 displayName、distance、expires）
     */
    public func loadNearbyUsers(lat: Float64, lng: Float64): ArrayList<PeerNearbyEntry> {
        let _ = this.loadNearby(lat, lng)
        return this.lastResult.nearbyUsers
    }

    /**
     * 加载附近群组列表
     * @param lat 纬度
     * @param lng 经度
     * @return 附近群组列表（含 displayName、distance、expires）
     */
    public func loadNearbyGroups(lat: Float64, lng: Float64): ArrayList<PeerNearbyEntry> {
        let _ = this.loadNearby(lat, lng)
        return this.lastResult.nearbyGroups
    }

    /**
     * 加载附近频道列表
     */
    public func loadNearbyChannels(lat: Float64, lng: Float64): ArrayList<PeerNearbyEntry> {
        let _ = this.loadNearby(lat, lng)
        return this.lastResult.nearbyChannels
    }

    /**
     * 获取上次请求中自己的位置过期时间（Unix 时间戳）
     * 0 表示未设置或已过期
     */
    public func getSelfExpires(): Int32 {
        return this.lastResult.selfExpires
    }

    /**
     * 更新自己的位置（刷新附近的人列表）
     * 调用 getLocated 会向服务器上报当前位置并获取最新列表
     *
     * @param lat 纬度
     * @param lng 经度
     * @return 完整解析结果（含 nearbyUsers、nearbyGroups、selfExpires）
     */
    public func updateOwnLocation(lat: Float64, lng: Float64): PeersNearbyResult {
        this.lastResult = this.service.getLocated(lat, lng)
        return this.lastResult
    }

    /**
     * 获取上次加载的完整结果（避免重复请求）
     */
    public func getLastResult(): PeersNearbyResult {
        return this.lastResult
    }
}
