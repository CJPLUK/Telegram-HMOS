package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*

/**
 * 附近的人图标数据服务 (Phase PNRIN)
 *
 * 封装 contacts.getLocated TL 方法，提供附近用户数量
 * 对应 Telegram-iOS PeersNearbyContext / PeersNearbyIconNode
 */
private var _peersNearbyServiceInstance: Option<PeersNearbyIconService> = None

public func getPeersNearbyIconService(): PeersNearbyIconService {
    match (_peersNearbyServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = PeersNearbyIconService()
            _peersNearbyServiceInstance = Some(inst)
            return inst
    }
}

public class PeersNearbyIconService {

    /**
     * 获取附近用户数量
     * 调用 contacts.getLocated(lat, lng) 并解析 Updates 中的 updatePeerLocated
     *
     * @param lat 纬度
     * @param lng 经度
     * @return 附近人数，失败或无权限时返回 0
     */
    public func getNearbyCount(lat: Float64, lng: Float64): Int32 {
        try {
            let client = getMTProtoClient()
            let geoPoint = InputGeoPoint()
            geoPoint.lat = lat
            geoPoint.long = lng
            let req = ContactsGetLocated()
            req.geoPoint = geoPoint
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size < 4) {
                return 0
            }
            let checkD = TLDeserializer(responseData)
            let checkConstructor = checkD.readUInt32()
            if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMessage = checkD.readString()
                Hilog.info(0, "CjTelegram", "[PeersNearbyIconService] getLocated RPC Error", [])
                return 0
            }
            return parseUpdatesPeersNearbyCount(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PeersNearbyIconService] getNearbyCount error", [])
            return 0
        }
    }
}
