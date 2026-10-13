package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*

/**
 * PeersNearby API 服务 (Phase TEPNB)
 *
 * 封装 contacts.getLocated TL 方法，提供附近用户/群组完整列表
 * 对应 iOS TelegramEngine.PeersNearby / PeersNearbyContext
 *
 * 与 PeersNearbyIconService 的区别：
 * - PeersNearbyIconService: 仅返回附近人数（用于图标角标）
 * - PeersNearbyService: 返回完整列表（用户+群组+距离+自己的位置过期）
 */
private var _peersNearbyServiceInstance: Option<PeersNearbyService> = None

public func getPeersNearbyService(): PeersNearbyService {
    match (_peersNearbyServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = PeersNearbyService()
            _peersNearbyServiceInstance = Some(inst)
            return inst
    }
}

public class PeersNearbyService {

    /**
     * 获取附近的人完整列表
     * 调用 contacts.getLocated(lat, lng) 并解析 Updates
     *
     * @param lat 纬度
     * @param lng 经度
     * @return PeersNearbyResult（附近用户、附近群组、自己的位置过期时间）
     */
    public func getLocated(lat: Float64, lng: Float64): PeersNearbyResult {
        try {
            let client = getMTProtoClient()
            let geoPoint = InputGeoPoint()
            geoPoint.lat = lat
            geoPoint.long = lng
            let req = ContactsGetLocated()
            req.geoPoint = geoPoint
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size < 4) {
                return PeersNearbyResult()
            }
            let checkD = TLDeserializer(responseData)
            let checkConstructor = checkD.readUInt32()
            if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMessage = checkD.readString()
                let errStr = "${errorCode} - ${errorMessage}"
                Hilog.info(0, "CjTelegram", "[PeersNearbyService] getLocated RPC Error: %{public}s", [errStr])
                return PeersNearbyResult()
            }
            return parsePeersNearbyFull(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PeersNearbyService] getLocated error", [])
            return PeersNearbyResult()
        }
    }
}
