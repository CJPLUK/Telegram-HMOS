package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.collection.HashMap
import std.time.DateTime
import std.math.*

/**
 * LiveLocationSummaryService — 多人 live 位置聚合服务 (P2-189)
 *
 * iOS 对应:
 *   submodules/LocationUI/Sources/LocationViewControllerNode.swift
 *   - renderLiveLocations Signal (effectiveLiveLocations = [EngineMessage])
 *   - 为每条 live-location 消息构建 LocationPinAnnotation (多 pin)
 *   - distance / ETA 按 peer 分别计算
 *
 * 功能:
 *   1. 维护同一会话(peerId)内所有活跃 live-location 记录
 *   2. 为每个 peer 计算到当前用户位置的距离/方位/ETA
 *   3. 导出 LiveLocationPeerEntry 列表供 UI 渲染多 pin 地图
 *
 * 调用链:
 *   LiveLocationSummaryPage.aboutToAppear
 *     → getLiveLocationSummaryService().refresh(chatPeerId, myLat, myLng)
 *       → LiveLocationSummaryService.refresh(...)
 *         → 构建 LiveLocationPeerEntry[] (含距离/ETA)
 *         → getLocationDistanceService().haversineDistance / bearing / estimatedWalkTime
 */

// ─────────────────────────────────────────────────────────────────────────────
// 数据模型
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 单个 live-location peer 的状态记录
 *
 * 对应 iOS LocationViewEntry.liveLocation / LocationPinAnnotation
 */
public class LiveLocationPeerEntry {
    // Peer 标识
    public var peerId: Int64 = 0
    public var peerType: String = ""
    public var displayName: String = ""

    // 位置
    public var latitude: Float64 = 0.0
    public var longitude: Float64 = 0.0

    // 时间戳 (最后更新 Unix 秒)
    public var lastUpdateSec: Int64 = 0

    // 广播剩余时间（秒）；-1 = 无限期；0 = 已过期/已停止
    public var remainingSeconds: Int64 = 0

    // 是否是自己（当前用户发出的 live location）
    public var isSelf: Bool = false

    // 计算得出的距离信息 (到当前用户)
    public var distanceMeters: Float64 = -1.0   // -1 = 未计算/无自身位置
    public var distanceText: String = ""
    public var bearingDegrees: Float64 = 0.0
    public var bearingText: String = ""
    public var walkTimeMin: Int32 = 0
    public var driveTimeMin: Int32 = 0
    public var etaText: String = ""

    public init() {}
}

// ─────────────────────────────────────────────────────────────────────────────
// Singleton
// ─────────────────────────────────────────────────────────────────────────────

private var _liveLocationSummaryServiceInstance: Option<LiveLocationSummaryService> = None

public func getLiveLocationSummaryService(): LiveLocationSummaryService {
    match (_liveLocationSummaryServiceInstance) {
        case Some(svc) => return svc
        case None =>
            let svc = LiveLocationSummaryService()
            _liveLocationSummaryServiceInstance = Some(svc)
            return svc
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// LiveLocationSummaryManager
// ─────────────────────────────────────────────────────────────────────────────

/**
 * LiveLocationSummaryService — 聚合同会话多 peer live 位置
 *
 * 工作模式（对应 iOS 的 renderLiveLocations signal）：
 * 1. 外部通过 addOrUpdatePeer(...) 注入/更新每个 peer 的 live 位置数据
 *    （数据来源是 MTProto updateMessageID / MessageService.getLiveLocationsForChat）
 * 2. refresh(myLat, myLng) 重新计算所有 peer 的距离/ETA
 * 3. getPeers() 返回当前聚合结果列表（供 LiveLocationSummaryPage UI 使用）
 */
public class LiveLocationSummaryService {

    // 当前聚合的 peer 记录（keyed by peerId）
    private var _peers: HashMap<Int64, LiveLocationPeerEntry> = HashMap<Int64, LiveLocationPeerEntry>()

    private var _distSvc: LocationDistanceService = getLocationDistanceService()

    // ==================== 公开 API ====================

    /**
     * 注册或更新一个 peer 的 live 位置
     *
     * 对应 iOS effectiveLiveLocations 中每条 EngineMessage 的处理
     *
     * @param peerId        对话/用户 ID
     * @param peerType      "user" / "chat" / "channel"
     * @param displayName   显示名（用户名或群名）
     * @param lat           纬度
     * @param lng           经度
     * @param lastUpdateSec 最后更新 Unix 时间戳（秒）
     * @param periodSec     广播总时长（秒）；0x7fffffff = 无限期
     * @param isSelf        是否是当前用户自己的 live location
     */
    public func addOrUpdatePeer(
        peerId: Int64,
        peerType: String,
        displayName: String,
        lat: Float64,
        lng: Float64,
        lastUpdateSec: Int64,
        periodSec: Int64,
        isSelf: Bool
    ): Unit {
        let entry = LiveLocationPeerEntry()
        entry.peerId = peerId
        entry.peerType = peerType
        entry.displayName = displayName
        entry.latitude = lat
        entry.longitude = lng
        entry.lastUpdateSec = lastUpdateSec
        entry.isSelf = isSelf

        // 计算剩余时间
        let nowSec = DateTime.now().toUnixTimeStamp().toSeconds()
        if (periodSec == Int64(0x7fffffff)) {
            entry.remainingSeconds = Int64(0x7fffffff)
        } else {
            let elapsedSec = nowSec - lastUpdateSec
            let remaining = periodSec - elapsedSec
            entry.remainingSeconds = if (remaining > 0) { remaining } else { 0 }
        }

        this._peers[peerId] = entry
        Hilog.info(0, "CjTelegram", "[LiveLocationSummary] addOrUpdate: peer=${peerId} displayName=${displayName} lat=${lat} lng=${lng}")
    }

    /**
     * 移除某个 peer 的记录（对应 iOS stop 事件）
     */
    public func removePeer(peerId: Int64): Unit {
        let _ = this._peers.remove(peerId)
        Hilog.info(0, "CjTelegram", "[LiveLocationSummary] remove: peer=${peerId}")
    }

    /**
     * 清空所有记录（切换会话时调用）
     */
    public func clearAll(): Unit {
        this._peers.clear()
        Hilog.info(0, "CjTelegram", "[LiveLocationSummary] clearAll")
    }

    /**
     * 计算所有 peer 到当前用户位置的距离/ETA
     *
     * 对应 iOS LocationViewControllerNode combineLatest 中每条 liveLocation 的 distance/eta 计算
     *
     * @param myLat 当前用户纬度（无位置时传 0.0 / 0.0，距离将不计算）
     * @param myLng 当前用户经度
     */
    public func refresh(myLat: Float64, myLng: Float64): Unit {
        let hasMyLocation = myLat != 0.0 || myLng != 0.0
        let nowSec = DateTime.now().toUnixTimeStamp().toSeconds()

        for ((_peerId, entry) in this._peers) {
            // 更新剩余时间
            if (entry.remainingSeconds != Int64(0x7fffffff) && entry.remainingSeconds > 0) {
                let elapsedSinceUpdate = nowSec - entry.lastUpdateSec
                let recomputedRemaining = entry.remainingSeconds - elapsedSinceUpdate
                if (recomputedRemaining < 0) {
                    entry.remainingSeconds = 0
                }
            }

            // 计算距离/ETA
            if (hasMyLocation && !entry.isSelf) {
                let dist = this._distSvc.haversineDistance(myLat, myLng, entry.latitude, entry.longitude)
                let bear = this._distSvc.bearing(myLat, myLng, entry.latitude, entry.longitude)
                let walkMin = this._distSvc.estimatedWalkTime(dist)
                let driveMin = this._distSvc.estimatedDriveTime(dist)
                entry.distanceMeters = dist
                entry.distanceText = this._distSvc.formatDistance(dist)
                entry.bearingDegrees = bear
                entry.bearingText = this._distSvc.formatBearing(bear)
                entry.walkTimeMin = walkMin
                entry.driveTimeMin = driveMin
                entry.etaText = this.buildEtaText(walkMin, driveMin)
            } else {
                entry.distanceMeters = -1.0
                entry.distanceText = ""
                entry.bearingText = ""
                entry.etaText = ""
            }
        }
        Hilog.info(0, "CjTelegram", "[LiveLocationSummary] refresh: peerCount=${this._peers.size} hasMyLoc=${hasMyLocation}")
    }

    /**
     * 获取当前所有 peer 列表（按距离升序排序；自身排首位）
     *
     * 对应 iOS sortedLiveLocations (effectiveSubject 排首位)
     */
    public func getPeers(): ArrayList<LiveLocationPeerEntry> {
        let result = ArrayList<LiveLocationPeerEntry>()
        let selfPeers = ArrayList<LiveLocationPeerEntry>()
        let otherPeers = ArrayList<LiveLocationPeerEntry>()

        for ((_id, entry) in this._peers) {
            if (entry.isSelf) {
                selfPeers.add(entry)
            } else {
                otherPeers.add(entry)
            }
        }

        // 自身排首位
        for (e in selfPeers) {
            result.add(e)
        }

        // 其他按距离升序（简单插入排序，peer 数通常 <20）
        let sortedOthers = this.sortByDistance(otherPeers)
        for (e in sortedOthers) {
            result.add(e)
        }
        return result
    }

    /**
     * 查询活跃 peer 数量
     */
    public func activePeerCount(): Int64 {
        var count: Int64 = 0
        for ((_id, entry) in this._peers) {
            if (entry.remainingSeconds != 0) {
                count = count + 1
            }
        }
        return count
    }

    /**
     * 获取地图中心点（所有 peer 位置的质心）
     *
     * 用于确定 OSM 快照 URL 的 lat/lng 参数
     * 对应 iOS LocationMapHeaderNode 的 region 计算
     */
    public func getCenterCoordinate(): (Float64, Float64) {
        if (this._peers.size == 0) {
            return (0.0, 0.0)
        }
        var sumLat = 0.0
        var sumLng = 0.0
        var count = 0
        for ((_id, entry) in this._peers) {
            sumLat = sumLat + entry.latitude
            sumLng = sumLng + entry.longitude
            count = count + 1
        }
        if (count == 0) { return (0.0, 0.0) }
        return (sumLat / Float64(count), sumLng / Float64(count))
    }

    // ==================== 内部辅助 ====================

    private func buildEtaText(walkMin: Int32, driveMin: Int32): String {
        if (walkMin <= 0 && driveMin <= 0) { return "" }
        if (walkMin > 0 && driveMin > 0) {
            return "步行约 ${walkMin} 分钟 / 驾车约 ${driveMin} 分钟"
        }
        if (walkMin > 0) { return "步行约 ${walkMin} 分钟" }
        return "驾车约 ${driveMin} 分钟"
    }

    /**
     * 对 ArrayList<LiveLocationPeerEntry> 按 distanceMeters 升序（未知距离排最后）
     * 简单插入排序，peer 数通常 <20，无需高效算法
     */
    private func sortByDistance(list: ArrayList<LiveLocationPeerEntry>): ArrayList<LiveLocationPeerEntry> {
        let n = list.size
        if (n <= 1) { return list }
        // 转 Array 做排序
        var arr = Array<LiveLocationPeerEntry>(n, { i => list[i] })
        var i = 1
        while (i < n) {
            let key = arr[i]
            var j = i - 1
            while (j >= 0 && this.distanceOf(arr[j]) > this.distanceOf(key)) {
                arr[j + 1] = arr[j]
                j = j - 1
            }
            arr[j + 1] = key
            i = i + 1
        }
        let result = ArrayList<LiveLocationPeerEntry>()
        for (e in arr) { result.add(e) }
        return result
    }

    private func distanceOf(entry: LiveLocationPeerEntry): Float64 {
        if (entry.distanceMeters < 0.0) { return Float64(999999999) }
        return entry.distanceMeters
    }
}
