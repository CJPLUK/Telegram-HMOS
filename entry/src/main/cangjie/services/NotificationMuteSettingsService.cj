package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.ArkData.*
import std.time.DateTime
import std.collection.ArrayList
import std.convert.*
import ohos_app_cangjie_entry.core.mtproto.{
    getMTProtoClient,
    AccountUpdatePeerNotifySettings,
    InputPeerUser,
    TLDeserializer,
    TLConstructors,
    TLSerializer
}

/**
 * 通知声音设置（对应 iOS NotificationSoundSettings）
 * DEFERRED: value (PeerMessageSound?) — iOS 使用 TelegramPresentationData 本地化。
 * OHOS 暂无等效 peer message sound API，仅保留结构占位。
 */
public class NotificationSoundSettings {
    public var hasCustomSound: Bool = false
}

/**
 * 每对端通知例外记录（对应 iOS NotificationExceptionMode 条目）
 * 持久化于 Preferences "nmute_exceptions"，key 为 "<peerId>"
 * 格式: "<muteUntil>|<peerName>"
 */
public class PeerNotifyException {
    public var peerId: Int64 = 0
    public var peerName: String = ""
    /** muteUntil 语义同全局设置：0=未静音，2147483647=永久，Unix 时间戳=至该时间 */
    public var muteUntil: Int32 = 0

    public init(peerId: Int64, peerName: String, muteUntil: Int32) {
        this.peerId = peerId
        this.peerName = peerName
        this.muteUntil = muteUntil
    }
}

// Preferences store name for per-peer exception list
let NMUTE_EXCEPTION_PREFS = "nmute_exceptions"
let NMUTE_EXCEPTION_KEY_PREFIX = "peer_"
// Encoding separator for exception value: "<muteUntil>|<peerName>"
let NMUTE_SEP = "|"

/**
 * 通知静音设置服务（Phase NMUTE + P2-334）
 *
 * 封装 account.getNotifySettings、account.updateNotifySettings
 * 对应 iOS NotificationMuteSettingsController: enable, 1h, 2d, disable
 * P2-334 新增：逐对端例外列表（PeerNotifyException），持久化于 Preferences
 *
 * mute_until 语义:
 *   - 0: 取消静音 (enable)
 *   - 2147483647 (Int32.max): 永久静音 (disable)
 *   - Unix 时间戳: 静音至该时间点 (interval)
 */
public func getNotificationMuteSettingsService(): NotificationMuteSettingsService {
    return NotificationMuteSettingsService()
}

public class NotificationMuteSettingsService {
    /**
     * 获取指定用户的通知设置
     * @return muteUntil: 0=未静音, 2147483647=永久静音, 其他=静音至该 Unix 时间戳
     */
    public func getNotifySettings(userId: Int64): Int32 {
        let msgService = getRealMessageService()
        let accessHash = msgService.getAccessHashForUser(userId)
        return this.getNotifySettingsWithHash(userId, accessHash)
    }

    /**
     * 使用 accessHash 获取通知设置（当已有 accessHash 时避免重复查询）
     */
    public func getNotifySettingsWithHash(userId: Int64, accessHash: Int64): Int32 {
        try {
            let client = getMTProtoClient()
            let serializer = TLSerializer()
            serializer.writeUInt32(0x12b3ad31)
            serializer.writeUInt32(0xb8bc5b0c)
            serializer.writeUInt32(0xdde8a54c)
            serializer.writeInt64(userId)
            serializer.writeInt64(accessHash)
            let responseData = client.sendRequest(serializer.getBytes())
            if (responseData.size >= 4) {
                let d = TLDeserializer(responseData)
                let ctor = d.readUInt32()
                if (ctor == 0x99622c0c) {
                    let flags = d.readInt32()
                    if ((flags & 1) != 0) { let _ = d.readUInt32() }
                    if ((flags & 2) != 0) { let _ = d.readUInt32() }
                    if ((flags & 4) != 0) {
                        return d.readInt32()
                    }
                    return 0
                } else if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                    let errorCode = d.readInt32()
                    let errorMsg = d.readString()
                    Hilog.info(0, "CjTelegram", "[NMuteService] getNotifySettings error: ${errorCode} ${errorMsg}")
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[NMuteService] getNotifySettings exception: ${e}")
        }
        return 0
    }

    /**
     * 更新指定用户的静音设置
     * @param muteUntil 0=取消静音, 2147483647=永久静音, Unix 时间戳=静音至该时间
     * @return 是否成功
     */
    public func updateNotifySettings(userId: Int64, muteUntil: Int32): Bool {
        let msgService = getRealMessageService()
        let accessHash = msgService.getAccessHashForUser(userId)
        return this.updateNotifySettingsWithHash(userId, accessHash, muteUntil)
    }

    /**
     * 使用 accessHash 更新静音设置
     */
    public func updateNotifySettingsWithHash(userId: Int64, accessHash: Int64, muteUntil: Int32): Bool {
        try {
            let client = getMTProtoClient()
            let peer = InputPeerUser()
            peer.userId = userId
            peer.accessHash = accessHash
            let req = AccountUpdatePeerNotifySettings()
            req.peer = peer
            req.muteUntil = muteUntil
            req.showPreviews = muteUntil == 0
            req.silent = muteUntil != 0
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size >= 4) {
                let d = TLDeserializer(responseData)
                let ctor = d.readUInt32()
                if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                    let errorCode = d.readInt32()
                    let errorMsg = d.readString()
                    Hilog.info(0, "CjTelegram", "[NMuteService] updateNotifySettings error: ${errorCode} ${errorMsg}")
                    return false
                }
                Hilog.info(0, "CjTelegram", "[NMuteService] Updated mute for user ${userId}: muteUntil=${muteUntil}")
                return true
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[NMuteService] updateNotifySettings exception: ${e}")
        }
        return false
    }

    /**
     * 计算静音时长对应的 muteUntil 值
     * @param seconds 静音秒数，0=取消静音
     * @return muteUntil 值
     */
    public func muteUntilForDuration(seconds: Int64): Int32 {
        if (seconds <= 0) { return 0 }
        let nowSec = DateTime.now().toUnixTimeStamp().toMilliseconds() / 1000
        let target = nowSec + seconds
        if (target >= 2147483647) { return 2147483647 }
        return Int32(target)
    }

    // =============================================
    // P2-334: 逐对端例外列表（Per-peer Exceptions）
    // 持久化于 HarmonyOS Preferences "nmute_exceptions"
    // key: "peer_<userId>", value: "<muteUntil>|<peerName>"
    // =============================================

    /**
     * 获取已保存的通知例外列表（本地 Preferences）
     * 对应 iOS NotificationExceptionMode.users/groups 条目列表
     */
    public func getExceptionList(): ArrayList<PeerNotifyException> {
        let result = ArrayList<PeerNotifyException>()
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, NMUTE_EXCEPTION_PREFS)
                    let allKeys = prefs.getAll()
                    for ((key, value) in allKeys) {
                        if (key.startsWith(NMUTE_EXCEPTION_KEY_PREFIX)) {
                            let peerIdStr = key[NMUTE_EXCEPTION_KEY_PREFIX.size..key.size]
                            try {
                                let peerId = Int64.parse(peerIdStr)
                                match (value) {
                                    case PreferencesValueType.StringData(encoded) =>
                                        let exc = this.decodeException(peerId, encoded)
                                        result.add(exc)
                                    case _ => ()
                                }
                            } catch (_: Exception) {
                                Hilog.info(0, "CjTelegram", "[NMuteService] Skipping malformed exception key: ${key}")
                            }
                        }
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[NMuteService] getExceptionList error: ${e}")
                }
            case None => ()
        }
        return result
    }

    /**
     * 保存/更新指定 peer 的通知例外
     * @param peerId Telegram 用户/群组 ID
     * @param peerName 显示名称（用于 UI）
     * @param muteUntil 静音值（0/Unix时间戳/Int32.max）
     * 并同步调用 account.updateNotifySettings
     */
    public func setException(peerId: Int64, peerName: String, muteUntil: Int32): Unit {
        let encoded = this.encodeException(muteUntil, peerName)
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, NMUTE_EXCEPTION_PREFS)
                    let key = "${NMUTE_EXCEPTION_KEY_PREFIX}${peerId}"
                    prefs.put(key, PreferencesValueType.StringData(encoded))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[NMuteService] setException peer=${peerId} muteUntil=${muteUntil}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[NMuteService] setException prefs error: ${e}")
                }
            case None => ()
        }
        let _ = this.updateNotifySettings(peerId, muteUntil)
    }

    /**
     * 删除指定 peer 的通知例外（恢复全局设置）
     * 并同步调用 account.updateNotifySettings(muteUntil=0)
     */
    public func removeException(peerId: Int64): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, NMUTE_EXCEPTION_PREFS)
                    let key = "${NMUTE_EXCEPTION_KEY_PREFIX}${peerId}"
                    prefs.delete(key)
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[NMuteService] removeException peer=${peerId}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[NMuteService] removeException prefs error: ${e}")
                }
            case None => ()
        }
        let _ = this.updateNotifySettings(peerId, 0)
    }

    /**
     * 获取指定 peer 当前的本地例外设置（如有）
     * @return Some(muteUntil) 若有例外，None 若无
     */
    public func getExceptionForPeer(peerId: Int64): Option<Int32> {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, NMUTE_EXCEPTION_PREFS)
                    let key = "${NMUTE_EXCEPTION_KEY_PREFIX}${peerId}"
                    let val = prefs.get(key, PreferencesValueType.StringData(""))
                    match (val) {
                        case PreferencesValueType.StringData(encoded) =>
                            if (encoded.size > 0) {
                                let exc = this.decodeException(peerId, encoded)
                                return Some(exc.muteUntil)
                            }
                        case _ => ()
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[NMuteService] getExceptionForPeer error: ${e}")
                }
            case None => ()
        }
        return None
    }

    // ---- 内部编解码 ----

    /**
     * 将例外编码为 Preferences 字符串: "<muteUntil>|<peerName>"
     */
    private func encodeException(muteUntil: Int32, peerName: String): String {
        return "${muteUntil}${NMUTE_SEP}${peerName}"
    }

    /**
     * 从 Preferences 字符串解码例外
     * 格式: "<muteUntil>|<peerName>"，peerName 可能含 '|'
     */
    private func decodeException(peerId: Int64, encoded: String): PeerNotifyException {
        match (encoded.indexOf(NMUTE_SEP)) {
            case Some(sepIdx) =>
                let muteStr = encoded[0..sepIdx]
                let nameStr = encoded[(sepIdx + 1)..encoded.size]
                var muteVal: Int32 = 0
                try {
                    muteVal = Int32(Int64.parse(muteStr))
                } catch (_: Exception) {
                    muteVal = 0
                }
                return PeerNotifyException(peerId, nameStr, muteVal)
            case None =>
                return PeerNotifyException(peerId, "", 0)
        }
    }

    /**
     * 判断静音是否已过期（仅对有时间戳的情况）
     * @return true 若静音仍然有效（未过期）
     */
    public func isMuteActive(muteUntil: Int32): Bool {
        if (muteUntil == 0) { return false }
        if (muteUntil == 2147483647) { return true }
        let nowSec = DateTime.now().toUnixTimeStamp().toMilliseconds() / 1000
        return Int64(muteUntil) > nowSec
    }

    // =============================================
    // P2-264: 展示前按 peer 静音状态过滤
    // 对应 iOS SharedNotificationManager 中收到推送后判断 peer 是否静音
    // =============================================

    /**
     * 判断指定 peer 的通知是否应该被抑制（静音中）
     *
     * 对应 iOS: 推送到达时检查 NotifySettings.muteUntil；若静音则不展示通知
     * 优先从本地 Preferences 例外列表读取 muteUntil（快速路径，避免 MTProto 阻塞）
     *
     * @param peerId  Telegram peer ID（用户/群组/频道）
     * @return true = 该 peer 当前静音，应抑制通知展示
     */
    public func shouldSuppressNotification(peerId: Int64): Bool {
        let exceptionOpt = this.getExceptionForPeer(peerId)
        match (exceptionOpt) {
            case Some(muteUntil) =>
                let active = this.isMuteActive(muteUntil)
                Hilog.info(0, "CjTelegram", "[NMuteService] shouldSuppress peer=${peerId} muteUntil=${muteUntil} active=${active}")
                return active
            case None =>
                return false
        }
    }

    /**
     * 处理 MESSAGE_MUTED loc-key 推送
     *
     * iOS 对应: MESSAGE_MUTED → shouldPollState=true（轮询服务端状态）
     * 鸿蒙端：收到 MESSAGE_MUTED 时，将服务端返回的静音状态同步到本地例外列表
     * 并触发状态轮询逻辑（轮询由 PushPayloadRouter 的 PollState action 处理）
     *
     * @param peerId    被静音的 peer ID
     * @param peerName  peer 显示名称（用于本地存储）
     * @return true = 已记录静音状态，调用方可继续轮询
     */
    public func handleMessageMuted(peerId: Int64, peerName: String): Bool {
        let serverMuteUntil = this.getNotifySettings(peerId)
        if (this.isMuteActive(serverMuteUntil)) {
            this.setException(peerId, peerName, serverMuteUntil)
            Hilog.info(0, "CjTelegram", "[NMuteService] MESSAGE_MUTED: peer=${peerId} muteUntil=${serverMuteUntil} saved to local exceptions")
        } else {
            this.removeException(peerId)
            Hilog.info(0, "CjTelegram", "[NMuteService] MESSAGE_MUTED: peer=${peerId} not muted on server, cleared local exception")
        }
        return true
    }

    /**
     * 在展示通知前做静音抑制检查（核心入口）
     *
     * 调用方（通知展示管线）在展示任何用户可见通知前应调用本函数：
     * - 若返回 true → 抑制（不展示）通知
     * - 若返回 false → 正常展示
     *
     * 实现: 查本地 Preferences 例外列表，无需 MTProto 请求（展示路径必须低延迟）
     *
     * @param peerId 通知来自的 peer ID
     * @return true = 应抑制；false = 应展示
     */
    public func suppressNotificationIfMuted(peerId: Int64): Bool {
        return this.shouldSuppressNotification(peerId)
    }
}
