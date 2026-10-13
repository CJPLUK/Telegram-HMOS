package ohos_app_cangjie_entry.services

/**
 * PushTokenService — 推送 Token 注册/注销管线（P2-255 + P2-256）
 *
 * iOS 对应：
 *   TelegramCore/RegisterNotificationToken.swift — _internal_registerNotificationToken
 *   TelegramCore/Account.swift                  — masterNotificationsKey（secret 生成/加载）
 *
 * 鸿蒙 Push Kit 平台适配（Phase 3 反转模式, SSOT §5）：
 *   - HMS push token 获取：系统调用搬到 ArkTS 侧 (ets/interop/impls/PushTokenImpl.ets)
 *     调 @kit.PushKit pushService.getToken()（Promise<string>），启动时 registerArkFunc
 *     注册进仓颉；仓颉经 callArkAsync(PUSH_GET_TOKEN, "{}", cb) 调用并解析结果 JSON，
 *     token 交回 getHarmonyPushToken 的既有 callback（public 签名不变）。
 *   - VoIP 推送：鸿蒙无 APNS VoIP 等价能力 —— defer，不实现。
 *   - token 失效刷新回调：需 HMS pushService.onTokenRefresh 回调，同上 defer。
 *
 * masterNotificationsKey 机制（P2-255 gap fix — secret 非全零）：
 *   iOS: 在 Keychain 存 256 字节随机 secret；
 *       id = SHA1(secret) 末 8 字节；data = secret。
 *   鸿蒙: 用 Preferences 存 hex(secret)，key="push_master_secret"；
 *       id = SHA1(secret)[12..20]（末 8 字节）；data = secret。
 *   secret 仅在首次生成，之后从 Preferences 加载，保持稳定。
 *
 * account.registerDevice#ec86017a ctor 验证：
 *   iOS Api42.swift:1067 appendInt32(-326762118) = UInt32(3968205178) = 0xEC86017A
 *   TLMethods.cj AccountRegisterDevice.getConstructorId() = 0xec86017a [一致]
 *
 * account.unregisterDevice#6a0d3206 ctor 验证：
 *   iOS Api42.swift:1673 appendInt32(1779249670) = 0x6A0D3206
 *   TLMethods.cj AccountUnregisterDevice.getConstructorId() = 0x6a0d3206 [一致]
 */

import kit.PerformanceAnalysisKit.Hilog
import kit.ArkData.*
import kit.AbilityKit.UIAbilityContext
import std.collection.ArrayList
import ohos_app_cangjie_entry.interop.*
import ohos_app_cangjie_entry.core.mtproto.{SHA1, ByteUtils}

// ==================== masterNotificationsKey ====================

/**
 * 主通知加密密钥（对应 iOS MasterNotificationKey）
 * data: 256 字节随机 secret
 * id:   SHA1(data) 末 8 字节（key identifier）
 */
public class MasterNotificationsKey {
    public var id: Array<Byte>
    public var data: Array<Byte>

    public init(id: Array<Byte>, data: Array<Byte>) {
        this.id = id
        this.data = data
    }
}

private let PUSH_PREFS_NAME = "push_token_prefs"
private let PUSH_MASTER_SECRET_KEY = "push_master_secret"
private let PUSH_TOKEN_KEY = "push_token_cached"
private let PUSH_TOKEN_TYPE_KEY = "push_token_type_cached"

/**
 * 从 Preferences 加载或生成 masterNotificationsKey
 * 对应 iOS masterNotificationsKey(transaction:, createIfNotExists: true)
 *
 * 必须在 UIAbilityContext 可用时调用（通过 getGlobalAbilityContext()）。
 * 首次调用生成 256 字节随机 secret 并持久化；之后每次从 Preferences 加载。
 */
public func getOrCreateMasterNotificationsKey(ctx: UIAbilityContext): Option<MasterNotificationsKey> {
    try {
        let prefs = Preferences.getPreferences(ctx, PUSH_PREFS_NAME)
        let existingHex = match (prefs.get(PUSH_MASTER_SECRET_KEY, PreferencesValueType.StringData(""))) {
            case PreferencesValueType.StringData(s) => s
            case _ => ""
        }
        let secretBytes: Array<Byte>
        if (existingHex.size == 512) {
            secretBytes = ByteUtils.fromHex(existingHex)
            Hilog.info(0, "CjTelegram", "[PushTokenService] Loaded existing master secret (256 bytes)")
        } else {
            secretBytes = ByteUtils.randomBytes(256)
            let hexStr = ByteUtils.toHex(secretBytes)
            prefs.put(PUSH_MASTER_SECRET_KEY, PreferencesValueType.StringData(hexStr))
            prefs.flush()
            Hilog.info(0, "CjTelegram", "[PushTokenService] Generated new master secret (256 bytes)")
        }
        let sha1Hash = SHA1.hash(secretBytes)
        let idBytes = Array<Byte>(8, repeat: 0)
        let hashLen = sha1Hash.size
        for (i in 0..8) {
            idBytes[i] = sha1Hash[hashLen - 8 + i]
        }
        return Some(MasterNotificationsKey(idBytes, secretBytes))
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[PushTokenService] getOrCreateMasterNotificationsKey failed: ${e}")
        return None
    }
}

// ==================== PushTokenService ====================

private var _pushTokenServiceInstance: Option<PushTokenService> = None

public func getPushTokenService(): PushTokenService {
    match (_pushTokenServiceInstance) {
        case Some(svc) => return svc
        case None =>
            let svc = PushTokenService()
            _pushTokenServiceInstance = Some(svc)
            return svc
    }
}

/**
 * PushTokenService — 推送 Token 获取、注册、注销
 *
 * P2-256 (getHarmonyPushToken) Phase 3 反转:
 *   经 callArkAsync(PUSH_GET_TOKEN) 调 ArkTS 侧 @kit.PushKit pushService.getToken()。
 *   getToken() 是 Promise-based async API，token 交回 callback 签名（public 不变）。
 *
 * P2-255 gap fixes (registerDevice):
 *   - secret = masterNotificationsKey.data (256 字节)；原来恒全 0 已修复
 *   - noMuted = excludeMutedChats 参数已接通
 *   - otherUids 支持多账号
 *   - TOKEN_WAS_INVALIDATED: RPC_ERROR 分支已在 RealAuthService 处理（返回 false）
 */
public class PushTokenService {

    public init() {}

    /**
     * 获取鸿蒙 Push Kit 推送 Token（等价 APNS token）
     *
     * Phase 3 反转实现：ArkTS 侧 PushTokenImpl.ets 调 @kit.PushKit pushService.getToken()
     * （Promise<string>），线程 hop 已在 interop 层做；本侧只 callArkAsync 并解析结果 JSON。
     * getToken() 是 async API，因此本函数保持 callback 签名（public 签名不变）。
     *
     * 契约 (D3, 双侧一致)：method = PUSH_GET_TOKEN ("push.getToken")
     *   argJson (CJ→ArkTS): {}（无参）
     *   result (ArkTS→CJ):  {"ok": <bool>, "token": <string>}
     *   ok=false / token 空 → 仓颉侧回调 None。
     *
     * @param callback  token 到达时回调；Some(token) = 成功；None = 失败
     */
    public func getHarmonyPushToken(callback: (Option<String>) -> Unit): Unit {
        Hilog.info(0, "CjTelegram", "[PushTokenService] getHarmonyPushToken: callArkAsync(PUSH_GET_TOKEN)")
        // ⚠️ 必须在 ArkTS 主线程调用：ark_interop 的 JSContext 绑定主线程，spawn
        // 后台线程直接进来会 BusinessException 34300004 Thread mismatch（真机实锤,
        // 推送注册因此从未成功）。调用方（AppStartup）负责保证主线程上下文。
        callArkAsync(PUSH_GET_TOKEN, "{}") { resJson =>
            let json = JsonParser.parseObject(resJson)
            if (json.getBool("ok")) {
                let tokenStr = json.getString("token")
                if (tokenStr.size > 0) {
                    Hilog.info(0, "CjTelegram", "[PushTokenService] getHarmonyPushToken: received token (len=${tokenStr.size})")
                    callback(Some(tokenStr))
                } else {
                    Hilog.info(0, "CjTelegram", "[PushTokenService] getHarmonyPushToken: ok but empty token")
                    callback(None)
                }
            } else {
                Hilog.info(0, "CjTelegram", "[PushTokenService] getHarmonyPushToken: ok=false / rejected")
                callback(None)
            }
        }
    }

    /**
     * 注册推送 Token 到 Telegram 服务端
     *
     * 对应 iOS _internal_registerNotificationToken:
     *   1. 获取 masterNotificationsKey（确保 secret 非全零）
     *   2. 调用 account.registerDevice#ec86017a
     *
     * @param token           设备 token（hex 字符串）
     * @param tokenType       1=Harmony(APNS 等价), 13=Huawei HMS
     * @param appSandbox      false（鸿蒙无沙盒概念）
     * @param excludeMutedChats  noMuted flag（对应 iOS excludeMutedChats）
     * @param otherUids       多账号额外 uid 列表（单账号传空）
     * @return true = 服务端确认；false = 失败或推迟
     */
    public func registerDevice(
        token: String,
        tokenType: Int32,
        appSandbox: Bool,
        excludeMutedChats: Bool,
        otherUids: ArrayList<Int64>
    ): Bool {
        if (token.size == 0) {
            Hilog.info(0, "CjTelegram", "[PushTokenService] registerDevice: empty token, skip")
            return false
        }
        let ctx = getGlobalAbilityContext()
        match (ctx) {
            case None =>
                Hilog.info(0, "CjTelegram", "[PushTokenService] registerDevice: no AbilityContext, cannot get master key")
                return false
            case Some(c) =>
                let masterKeyOpt = getOrCreateMasterNotificationsKey(c)
                let secretBytes: Array<Byte>
                match (masterKeyOpt) {
                    case None =>
                        Hilog.info(0, "CjTelegram", "[PushTokenService] registerDevice: master key unavailable, using empty secret (degraded)")
                        secretBytes = Array<Byte>(0, repeat: 0)
                    case Some(mk) =>
                        secretBytes = mk.data
                        Hilog.info(0, "CjTelegram", "[PushTokenService] registerDevice: master key ready, keyId=${ByteUtils.toHex(mk.id)}")
                }
                let svc = getRealAuthService()
                return svc.registerPushToken(
                    token,
                    tokenType,
                    appSandbox,
                    secret: secretBytes,
                    noMuted: excludeMutedChats,
                    otherUids: otherUids
                )
        }
    }

    /**
     * 注销推送 Token（account.unregisterDevice#6a0d3206）
     * iOS ctor: appendInt32(1779249670) = 0x6A0D3206 [verified vs Api42.swift:1673]
     */
    public func unregisterDevice(token: String, tokenType: Int32): Bool {
        if (token.size == 0) {
            Hilog.info(0, "CjTelegram", "[PushTokenService] unregisterDevice: empty token, skip")
            return false
        }
        Hilog.info(0, "CjTelegram", "[PushTokenService] unregisterDevice tokenType=${tokenType}")
        return getRealAuthService().unregisterPushToken(token, tokenType)
    }

    /**
     * 推送注册入口 — 在账号认证完成后调用
     *
     * 对应 iOS SharedNotificationManager 中登录后触发注册的流程：
     *   1. 异步获取 HMS Push token（通过 arkinterop 桥接）
     *   2. token 到达时（callback 回调）调用 registerDevice
     *
     * 由调用方（如 MainAbility / 认证完成回调）调用；token 回调在 ArkTS JS 线程触发，
     * registerDevice 会在回调线程同步执行。
     */
    public func initPushRegistration(excludeMutedChats: Bool, otherUids: ArrayList<Int64>): Unit {
        Hilog.info(0, "CjTelegram", "[PushTokenService] initPushRegistration start")
        this.getHarmonyPushToken({ tokenOpt =>
            match (tokenOpt) {
                case None =>
                    Hilog.info(0, "CjTelegram", "[PushTokenService] initPushRegistration: no token from HMS, skipping registerDevice")
                case Some(token) =>
                    // token 回调在 JS 主线程；registerDevice 是同步 MTProto RPC，
                    // 必须 spawn 回后台线程执行，避免阻塞 UI。
                    spawn {
                        let ok = this.registerDevice(
                            token,
                            13,
                            false,
                            excludeMutedChats,
                            otherUids
                        )
                        Hilog.info(0, "CjTelegram", "[PushTokenService] initPushRegistration registerDevice result=${ok}")
                    }
            }
        })
    }
}
