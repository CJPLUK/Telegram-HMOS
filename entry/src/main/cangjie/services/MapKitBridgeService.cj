package ohos_app_cangjie_entry.services

/**
 * MapKitBridgeService — 仓颉侧对 HMS Map Kit 反转能力的同步封装
 *
 * ArkTS 侧 ets/interop/impls/MapKitImpl.ets 提供三条通道：
 *   map.staticImage   静态地图图片（气泡 / 详情页 / 附件面板兜底），对位 iOS MKMapSnapshotter
 *   map.nearbySearch  附近 POI（附件面板「OR CHOOSE A PLACE」）
 *   map.queryLocation 拉起系统地图查看页（点位置气泡）
 * callArkAsync 是回调式；这里用 Monitor 把前两条包成同步调用，供本就在 spawn 线程里
 * 跑的 LocationResourcesService.fetchMapSnapshot / LocationPicker.loadVenues 直接用。
 * **不得在 UI 线程调用同步封装**（回调经 JS 主线程投递，会死锁）。
 */

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.interop.{callArkAsync, MAP_STATIC_IMAGE, MAP_NEARBY_SEARCH, MAP_QUERY_LOCATION}

private var _mapKitBridge: Option<MapKitBridgeService> = None

public func getMapKitBridgeService(): MapKitBridgeService {
    match (_mapKitBridge) {
        case Some(s) => return s
        case None =>
            let s = MapKitBridgeService()
            _mapKitBridge = Some(s)
            return s
    }
}

public class MapKitBridgeService {
    public init() {}

    private func callArkSync(name: String, argJson: String, timeoutMs: Int64): String {
        return arkCallSync(name, argJson, timeoutMs)
    }

    /** 系统地图静态图片；成功返回沙箱路径，失败返回 "" */
    public func fetchSystemMapImage(lat: Float64, lng: Float64, width: Int32, height: Int32, zoom: Int32): String {
        let arg = "{\"lat\":${lat},\"lng\":${lng},\"w\":${width},\"h\":${height},\"zoom\":${zoom}}"
        let res = this.callArkSync(MAP_STATIC_IMAGE, arg, 8000)
        if (res.size == 0) {
            Hilog.info(0, "CjTelegram", "[MapKitBridge] staticImage timeout")
            return ""
        }
        let obj = JsonParser.parseObject(res)
        if (!obj.getBool("ok")) { return "" }
        let path = obj.getString("path")
        Hilog.info(0, "CjTelegram", "[MapKitBridge] staticImage ok: ${path}")
        return path
    }

    /** 附近 POI（Map Kit site.nearbySearch），失败返回空表 */
    public func nearbySearch(lat: Float64, lng: Float64, query: String, radius: Int32): ArrayList<VenueItemData> {
        let list = ArrayList<VenueItemData>()
        let q = jsonEscapeMapKit(query)
        let arg = "{\"lat\":${lat},\"lng\":${lng},\"query\":\"${q}\",\"radius\":${radius}}"
        let res = this.callArkSync(MAP_NEARBY_SEARCH, arg, 8000)
        if (res.size == 0) {
            Hilog.info(0, "CjTelegram", "[MapKitBridge] nearbySearch timeout")
            return list
        }
        let obj = JsonParser.parseObject(res)
        if (!obj.getBool("ok")) {
            Hilog.info(0, "CjTelegram", "[MapKitBridge] nearbySearch failed")
            return list
        }
        for (item in obj.getArray("sites").getObjects()) {
            let v = VenueItemData()
            v.venueId = item.getString("id")
            v.title = item.getString("name")
            v.address = item.getString("address")
            v.type_ = item.getString("type")
            v.latitude = item.getFloat("lat")
            v.longitude = item.getFloat("lng")
            v.provider = "petalmaps"
            if (v.title.size > 0) { list.add(v) }
        }
        Hilog.info(0, "CjTelegram", "[MapKitBridge] nearbySearch: ${list.size} sites")
        return list
    }

    /** 拉起系统地图查看页（异步）；onDone(ok) 在 JS 线程回调 */
    public func openSystemLocation(lat: Float64, lng: Float64, name: String, onDone: (Bool) -> Unit): Unit {
        let n = jsonEscapeMapKit(name)
        let arg = "{\"lat\":${lat},\"lng\":${lng},\"name\":\"${n}\"}"
        callArkAsync(MAP_QUERY_LOCATION, arg, { r: String =>
            onDone(JsonParser.parseObject(r).getBool("ok"))
        })
    }
}

func jsonEscapeMapKit(s: String): String {
    var out = ""
    for (c in s.toRuneArray()) {
        if (c == r'"') { out = out + "\\\"" }
        else if (c == r'\\') { out = out + "\\\\" }
        else if (c == r'\n') { out = out + " " }
        else { out = out + String(c) }
    }
    return out
}
