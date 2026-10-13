package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.{getMTProtoClient, PhoneGetCallConfig, PhoneSaveCallDebug, TLDeserializer}
import ohos_app_cangjie_entry.utils.{isWebrtcSupported, getRecommendedVersions}

/**
 * TelegramVoipService — VoIP 引擎 API 服务 (telegram_voip)
 *
 * 专注 CallService 中不存在的 VoIP 特定功能：
 * - reflector 连接管理相关：getCallConfig (phone.getCallConfig)
 * - 通话调试：saveCallDebug (phone.saveCallDebug)
 * - 网络/引擎状态：WebRTC 可用性、推荐版本
 *
 * 不重复实现：1:1 通话、通话历史、信令(phone.requestCall/acceptCall/discardCall)、
 * SRTP 加密 等由 CallService + TgCallsBridge 提供。
 *
 * iOS 对照: TelegramVoip OngoingCallContext, ReflectorBenchmark, phone.getCallConfig
 */
private var _telegramVoipServiceInstance: Option<TelegramVoipService> = None

public func getTelegramVoipService(): TelegramVoipService {
    match (_telegramVoipServiceInstance) {
        case Some(s) => s
        case None =>
            let s = TelegramVoipService()
            _telegramVoipServiceInstance = Some(s)
            s
    }
}

public class TelegramVoipService {

    /**
     * phone.getCallConfig — 获取通话配置
     * 返回 DataJSON 字符串，包含 reflector 等配置
     * 参考: Telegram API phone.getCallConfig#55451fa9 = DataJSON
     */
    public func getCallConfig(): Option<String> {
        try {
            let client = getMTProtoClient()
            let req = PhoneGetCallConfig()
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size < 8) { return None }
            return parseDataJsonResponse(responseData)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[TelegramVoipService] getCallConfig failed")
            return None
        }
    }

    /**
     * phone.saveCallDebug — 保存通话调试数据
     * 用于诊断通话质量问题
     * @param callId 通话 ID
     * @param accessHash 通话 access_hash
     * @param debugData JSON 格式调试数据
     */
    public func saveCallDebug(callId: Int64, accessHash: Int64, debugData: String): Bool {
        if (callId <= 0 || accessHash == 0) { return false }
        try {
            let client = getMTProtoClient()
            let req = PhoneSaveCallDebug()
            req.callId = callId
            req.callAccessHash = accessHash
            req.debugData = if (debugData.size > 0) { debugData } else { "{}" }
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size < 4) { return false }
            let d = TLDeserializer(responseData)
            let ctor = d.readUInt32()
            // Bool 响应: boolTrue#997275b5 或 boolFalse#bc799737
            return ctor == 0x997275b5
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[TelegramVoipService] saveCallDebug failed")
            return false
        }
    }

    /**
     * WebRTC 引擎是否可用
     */
    public func getWebrtcStatus(): Bool {
        return isWebrtcSupported()
    }

    /**
     * 获取推荐协议版本列表
     */
    public func fetchRecommendedVersions(): Array<String> {
        return getRecommendedVersions()
    }

    /**
     * 解析 DataJSON 响应
     * dataJSON#7d748d04 data:string = DataJSON
     */
    private func parseDataJsonResponse(data: Array<Byte>): Option<String> {
        if (data.size < 8) { return None }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor != 0x7d748d04) { return None }
        let jsonStr = d.readString()
        return Some(jsonStr)
    }
}
