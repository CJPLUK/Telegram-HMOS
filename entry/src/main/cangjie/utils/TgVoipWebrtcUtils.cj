package ohos_app_cangjie_entry.utils

/**
 * TgVoipWebrtcUtils — WebRTC 引擎上层工具接口 (tg_voip_webrtc)
 *
 * 提供高层工具函数，供 CallService、OngoingCallContext、通话 UI 等调用。
 * 不创建新的 CallService，复用已有 CallService。
 *
 * 提供：
 * - isWebrtcSupported: 检测 WebRTC 引擎是否可用
 * - getRecommendedVersions: 获取推荐协议版本列表
 * - createDefaultVoipConfig: 创建默认 VoipConfig
 * - getRecommendedVideoAspect: 获取推荐视频宽高比
 */

import ohos_app_cangjie_entry.core.voip.{TgCallsLib, VoipConfig, VoipRtcServer, VoipEndpoint}
import ohos_app_cangjie_entry.bindings.{getSupportedVersions, VoipNetworkType}
import std.collection.ArrayList

/**
 * 检测 WebRTC 引擎（libtgcalls_ohos.so）是否可用
 * @return true 表示可加载并解析符号
 */
public func isWebrtcSupported(): Bool {
    return TgCallsLib.ensureLoaded()
}

/**
 * 获取推荐协议版本列表
 * 解析 tgcalls 返回的逗号分隔字符串为数组
 * @return 版本字符串数组，如 ["12.0.0", "13.0.0"]
 */
public func getRecommendedVersions(): Array<String> {
    let raw = getSupportedVersions()
    if (raw.size == 0) {
        return Array<String>(0, repeat: "")
    }
    let parts = raw.split(",")
    let list = ArrayList<String>()
    for (p in parts) {
        let trimmed = trimVersionPart(p)
        if (trimmed.size > 0) {
            list.add(trimmed)
        }
    }
    return Array<String>(list.size, { i: Int64 => list[i] })
}

/**
 * 去除版本字符串首尾空白
 */
private func trimVersionPart(s: String): String {
    let runes = s.toRuneArray()
    if (runes.size == 0) { return "" }
    var start: Int64 = 0
    while (start < runes.size) {
        let r = runes[start]
        let code = UInt32(r)
        if (code != 32 && code != 9) { break }
        start = start + 1
    }
    var end: Int64 = runes.size - 1
    while (end >= start) {
        let r = runes[end]
        let code = UInt32(r)
        if (code != 32 && code != 9) { break }
        end = end - 1
    }
    if (start > end) { return "" }
    var out: String = ""
    var i: Int64 = start
    while (i <= end) {
        out = out + runes[i].toString()
        i = i + 1
    }
    return out
}

/**
 * 创建默认 VoipConfig
 * 用于测试或未提供完整配置时的回退
 */
public func createDefaultVoipConfig(): VoipConfig {
    let config = VoipConfig()
    config.version = "12.0.0"
    config.maxLayer = 92
    config.allowP2P = true
    config.allowTCP = true
    config.enableStunMarking = true
    config.isVideo = false
    config.isOutgoing = true
    config.encryptionKey = Array<Byte>(0, repeat: 0)
    config.rtcServers = Array<VoipRtcServer>(0, repeat: VoipRtcServer())
    config.endpoints = Array<VoipEndpoint>(0, repeat: VoipEndpoint())
    return config
}

/**
 * 获取推荐视频宽高比（16:9 = 1.777...）
 * 用于 setVideoAspect 调用
 */
public func getRecommendedVideoAspect(): Float32 {
    return 1.7777778
}

/**
 * 获取默认协议版本
 * 优先使用 12.0.0（与 Telegram 现代客户端兼容）
 */
public func getDefaultProtocolVersion(): String {
    return "12.0.0"
}

/**
 * 获取默认最大层
 */
public func getDefaultMaxLayer(): Int32 {
    return 92
}

/**
 * 获取默认网络类型（WiFi，通话质量最佳）
 * 用于 setNetworkType 调用
 */
public func getDefaultNetworkType(): VoipNetworkType {
    return VoipNetworkType.WiFi
}
