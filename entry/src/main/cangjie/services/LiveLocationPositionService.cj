package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.models.Message

// ==================== 数据模型 ====================

/**
 * LiveLocationPositionData — 渲染 live location 头像 pin 所需的数据快照
 *
 * 对应 iOS ChatMessageLiveLocationPositionNode.Mode.liveLocation(peer:active:latitude:longitude:heading:)
 */
public class LiveLocationPositionData {
    // 消息发送者 ID
    public var senderId: Int64 = 0
    // 发送者昵称（fallback 首字显示）
    public var senderName: String = ""
    // 发送者头像本地路径（"" = 无头像，显示首字母占位）
    public var avatarPath: String = ""
    // 纬度
    public var latitude: Float64 = 0.0
    // 经度
    public var longitude: Float64 = 0.0
    // 是否活跃（未过期的实时位置 → true；已停止或静态位置 → false）
    public var active: Bool = false
    // 方向角（弧度，None = 无方向箭头，Some(radians) = 显示方向箭头）
    public var headingRadians: Option<Float64> = None<Float64>
    // 消息 ID（用于编辑 / 停止实时位置）
    public var messageId: Int32 = 0

    public init() {}
}

// ==================== 服务 ====================

/**
 * LiveLocationPositionService — 实时位置头像标记数据服务
 *
 * 职责：
 * 1. 从 Message 提取 LiveLocationPositionData（头像路径 / 坐标 / 方向角 / active 状态）
 * 2. 通过 sendLiveLocationMessage() 转发实时位置发送请求
 *    调用链：LiveLocationPositionService → sendLiveLocationMessage →
 *           RealMessageService.sendLiveLocation → MTProtoClient.sendRequest
 *
 * 不维护后台更新循环（由 LiveLocationManagerService 负责）；
 * 仅在 UI 渲染时按需提供当前快照数据。
 */
public class LiveLocationPositionService {

    public init() {}

    /**
     * P2-180/188 gap fix: 从消息对象提取渲染数据快照
     *
     * 航向优先级（对应 iOS effectiveHeading = heading ?? location.course）：
     *   1. 服务器 heading（msg.locationHeading >= 0）→ 直接使用（最可靠）
     *   2. 坐标 delta 推算（prevLat/prevLng != msg.lat/lng）→ 近似方向
     *   3. 无有效位移 → None（不显示方向箭头）
     *
     * @param msg 含 isLiveLocation/locationLat/locationLng/locationHeading 的消息
     * @param prevLat 上一次已知纬度（供坐标 delta 回退计算，server heading 优先时不用）
     * @param prevLng 上一次已知经度
     */
    public func extractPositionData(msg: Message, prevLat: Float64, prevLng: Float64): LiveLocationPositionData {
        let data = LiveLocationPositionData()
        data.senderId = msg.senderId
        data.senderName = msg.senderName
        data.messageId = Int32(msg.id)
        data.latitude = msg.locationLat
        data.longitude = msg.locationLng
        data.active = msg.isLiveLocation

        // 头像路径
        if (data.senderId != 0) {
            data.avatarPath = getUserPhotoService().getUserPhotoPath(data.senderId)
        }

        // P2-188 gap fix: 航向优先使用服务器 heading（对应 iOS effectiveHeading = heading ?? location.course）
        if (msg.locationHeading >= 0) {
            // 服务器提供了真实 heading（0-359°），转弧度供 Canvas rotate 使用
            let pi = 3.14159265358979323846
            let radians = Float64(msg.locationHeading) * pi / 180.0
            data.headingRadians = Some<Float64>(radians)
            Hilog.info(0, "CjTelegram", "[LiveLocationPositionService] heading from server: ${msg.locationHeading}° → ${radians}rad")
        } else {
            // 回退：坐标 delta 近似（仅在有真实位移时有效）
            data.headingRadians = this.computeHeading(
                prevLat, prevLng,
                data.latitude, data.longitude
            )
        }

        Hilog.info(0, "CjTelegram", "[LiveLocationPositionService] extractPositionData senderId=" + "${data.senderId}" + " active=" + "${data.active}")
        return data
    }

    /**
     * 从两个坐标点计算前进方向（弧度）
     * 与 iOS asyncLayout 中的 atan2(y, x) 逻辑等价
     *
     * @param lat1 起点纬度（度）
     * @param lon1 起点经度（度）
     * @param lat2 终点纬度（度）
     * @param lon2 终点经度（度）
     * @return None = 位移为零无法计算；Some(rad) = 方向角（弧度）
     */
    public func computeHeading(lat1: Float64, lon1: Float64, lat2: Float64, lon2: Float64): Option<Float64> {
        let pi = 3.14159265358979323846
        let toRad = pi / 180.0
        let rlat1 = lat1 * toRad
        let rlon1 = lon1 * toRad
        let rlat2 = lat2 * toRad
        let rlon2 = lon2 * toRad
        let dLat = rlat2 - rlat1
        let dLon = rlon2 - rlon1
        if (dLat == 0.0 && dLon == 0.0) {
            return None<Float64>
        }
        let y = sin(dLon) * cos(rlat2)
        let x = cos(rlat1) * sin(rlat2) - sin(rlat1) * cos(rlat2) * cos(dLon)
        return Some<Float64>(atan2(y, x))
    }

    /**
     * 发送实时位置消息
     * 调用链：LiveLocationPositionService → sendLiveLocationMessage →
     *         RealMessageService.sendLiveLocation → MTProtoClient.sendRequest
     *
     * @param peerType 对话类型（"user"/"chat"/"channel"）
     * @param peerId   对话 ID
     * @param lat      纬度
     * @param lng      经度
     * @param period   分享时长（秒，典型值 900/3600/28800）
     * @return true = 发送成功
     */
    public func sendLiveLocation(peerType: String, peerId: Int64, lat: Float64, lng: Float64, period: Int32): Bool {
        let result = sendLiveLocationMessage(peerType, peerId, Float64(lat), Float64(lng), period)
        Hilog.info(0, "CjTelegram", "[LiveLocationPositionService] sendLiveLocation result=" + "${result}")
        return result
    }

    /**
     * 获取发送者首字母占位符（无头像时使用）
     *
     * @param name 发送者名称
     * @return 第一个 Rune 转字符串，或 "?" 作为 fallback
     */
    public func getAvatarPlaceholder(name: String): String {
        if (name.size == 0) {
            return "?"
        }
        let runes = name.toRuneArray()
        return String(runes[0..1])
    }
}

// ==================== 模块内数学辅助（避免 import math 不确定性）====================

/**
 * sin 近似实现（泰勒展开，足够精度用于方向角计算）
 */
private func sin(x: Float64): Float64 {
    var angle = x
    let pi = 3.14159265358979323846
    let twoPi = 2.0 * pi
    // 规约到 [-pi, pi]
    while (angle > pi) { angle = angle - twoPi }
    while (angle < -pi) { angle = angle + twoPi }
    // 泰勒级数 5 项：sin(x) ≈ x - x³/6 + x⁵/120 - x⁷/5040 + x⁹/362880
    let x2 = angle * angle
    let x3 = x2 * angle
    let x5 = x3 * x2
    let x7 = x5 * x2
    let x9 = x7 * x2
    return angle - x3 / 6.0 + x5 / 120.0 - x7 / 5040.0 + x9 / 362880.0
}

/**
 * cos(x) = sin(x + pi/2)
 */
private func cos(x: Float64): Float64 {
    let pi = 3.14159265358979323846
    return sin(x + pi / 2.0)
}

/**
 * atan2(y, x) 近似（适合方向角计算）
 */
private func atan2(y: Float64, x: Float64): Float64 {
    let pi = 3.14159265358979323846
    if (x > 0.0) {
        return atan(y / x)
    } else if (x < 0.0 && y >= 0.0) {
        return atan(y / x) + pi
    } else if (x < 0.0 && y < 0.0) {
        return atan(y / x) - pi
    } else if (x == 0.0 && y > 0.0) {
        return pi / 2.0
    } else if (x == 0.0 && y < 0.0) {
        return -pi / 2.0
    } else {
        return 0.0
    }
}

/**
 * atan(x) 近似（[-1,1] 用泰勒，否则用恒等式）
 */
private func atan(x: Float64): Float64 {
    let pi = 3.14159265358979323846
    if (x > 1.0) {
        return pi / 2.0 - atan(1.0 / x)
    } else if (x < -1.0) {
        return -pi / 2.0 - atan(1.0 / x)
    }
    // 泰勒: atan(x) ≈ x - x³/3 + x⁵/5 - x⁷/7 + x⁹/9 - x¹¹/11
    let x2 = x * x
    let x3 = x2 * x
    let x5 = x3 * x2
    let x7 = x5 * x2
    let x9 = x7 * x2
    let x11 = x9 * x2
    return x - x3 / 3.0 + x5 / 5.0 - x7 / 7.0 + x9 / 9.0 - x11 / 11.0
}

// ==================== 服务单例 ====================

private var _liveLocationPositionServiceInstance: Option<LiveLocationPositionService> = None<LiveLocationPositionService>

public func getLiveLocationPositionService(): LiveLocationPositionService {
    match (_liveLocationPositionServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = LiveLocationPositionService()
            _liveLocationPositionServiceInstance = Some(inst)
            return inst
    }
}
