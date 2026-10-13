package ohos_app_cangjie_entry.utils

import kit.PerformanceAnalysisKit.Hilog
import kit.ArkUI.launch
import ohos_app_cangjie_entry.interop.*

/**
 * LocalAuthManager — 本地生物认证工具（非 TL/MTProto 服务）
 *
 * 对应 iOS LocalAuth.swift（LAContext biometricAuthentication + auth(reason:)）。
 *
 * 实现路径（P2-271，Phase 3 反转后）：
 *   HarmonyOS userIAM 无公开 C NDK；能力实现搬到 ArkTS 侧（ets/interop/impls/LocalAuthImpl.ets），
 *   真实调用 @kit.UserAuthenticationKit userAuth.getAvailableStatus / getUserAuthInstance。
 *   仓颉侧经 interop 反转桥调用：
 *     - localauth.available     → 探测 FACE/FINGERPRINT 可用性（回 {available,type}）
 *     - localauth.authenticate  → getUserAuthInstance(...).on("result").start()（回 {ok,msg}）
 *
 *   AuthType/AuthTrustLevel/ResultCode 等系统常量已移到 ArkTS 侧，仓颉侧不再持有。
 *
 * INTEROP 契约 (D3, 双侧一致):
 *   LOCALAUTH_AVAILABLE ("localauth.available")
 *     argJson (CJ→ArkTS): {}                          （无参）
 *     result  (ArkTS→CJ): {"available":<bool>,"type":"face"|"fingerprint"|"none"}
 *   LOCALAUTH_AUTHENTICATE ("localauth.authenticate")
 *     argJson (CJ→ArkTS): {"type":"face"|"fingerprint","reason":<str>}
 *     result  (ArkTS→CJ): {"ok":<bool>,"msg":<str>}
 *
 * 与调用方的接线（AppLockPage / AppLockComponent / AppLockStateService / AppLockService / WebAppPage）：
 *   - isBiometricAvailable(): Bool / getBiometricType(): String — 同步签名保持不变。
 *   - authenticateWithBiometric(reason, callback) → 反转桥 → callback(true/false, msg)。
 *
 * ⚠️ 同步→异步适配（公共签名未变，语义有一处收敛）：
 *   原实现 getAvailableStatus 是同步系统调用，可在同步 isBiometricAvailable() 内就地取值。
 *   反转后可用性探测走异步 callArkAsync；为保住同步 Bool/String 签名（5+ 处调用方内联使用返回值），
 *   本类改为「缓存 + 懒发探测」：首次 isBiometricAvailable()/getBiometricType() 触发一次异步探测并
 *   立即返回当前缓存（初值 false/"none"，安全降级）；探测在极短时间后回填缓存，后续调用返回真值。
 *   可选 warmupAvailability() 供 UI 早期（如 index.aboutToAppear）预热，缩小首帧窗口。
 *   调用方源码零改动。
 */

// ─────────────────────────────────────────────────────────────────
// LocalAuthManager — 全局单例
// ─────────────────────────────────────────────────────────────────

private var _localAuthManagerInstance: Option<LocalAuthManager> = None

public func getLocalAuthManager(): LocalAuthManager {
    match (_localAuthManagerInstance) {
        case Some(mgr) => return mgr
        case None =>
            let mgr = LocalAuthManager()
            _localAuthManagerInstance = Some(mgr)
            return mgr
    }
}

public class LocalAuthManager {
    // 缓存可用性检测结果（异步探测回填；同步 getter 读缓存）
    private var _probeDispatched: Bool = false
    private var _biometricAvailable: Bool = false
    // 支持的类型："fingerprint"/"face"/"none"
    private var _biometricType: String = "none"

    /**
     * 检查设备是否支持指纹/人脸生物认证。
     *
     * 反转后可用性探测走异步 interop；为保住同步 Bool 签名：首次调用懒发一次异步探测
     * 并立即返回当前缓存（初值 false，安全降级），探测回填后续调用返回真值。
     * 调用方（AppLockPage/Component、AppLockStateService、AppLockService、WebAppPage）零改动。
     */
    public func isBiometricAvailable(): Bool {
        this.ensureProbeDispatched()
        return this._biometricAvailable
    }

    /**
     * 获取设备支持的生物认证类型
     * @return "fingerprint" | "face" | "none"
     */
    public func getBiometricType(): String {
        this.ensureProbeDispatched()
        if (!this._biometricAvailable) {
            return "none"
        }
        return this._biometricType
    }

    /**
     * 预热可用性探测（可选）。UI 早期（如首页 aboutToAppear/onAppear）调用一次，
     * 缩短首帧到探测回填之间同步 getter 返回降级值的窗口。幂等。
     */
    public func warmupAvailability(): Unit {
        this.ensureProbeDispatched()
    }

    /**
     * 触发生物认证（真实实现，经 interop 反转桥）。
     *
     *   成功 → callback(true, "")
     *   取消 / 失败 / 不可用 → callback(false, errorMsg)
     *
     * @param reason 显示给用户的提示文案
     * @param callback (success: Bool, errorMessage: String) -> Unit
     *
     * 说明：onResult 回调可能在非 UI 线程触发，调用方若需更新 @State 应自行 spawn(UIThread)
     *   （既有调用方 AppLockStateComponent / WebAppPage 已在回调内 launch / spawn(UIThread)）。
     */
    public func authenticateWithBiometric(reason: String, callback: (Bool, String) -> Unit): Unit {
        this.ensureProbeDispatched()
        if (!this._biometricAvailable) {
            callback(false, "Biometric not available on this device")
            return
        }
        Hilog.info(0, "CjTelegram", "[LocalAuthManager] authenticateWithBiometric: reason=${reason}")
        let authType = this._biometricType
        // argJson schema 与 ArkTS LocalAuthImpl 逐条对应 (D3): {"type":<str>,"reason":<str>}
        let argJson = "{\"type\":\"${authType}\",\"reason\":\"${jsonEscapeLocalAuth(reason)}\"}"
        callArkAsync(LOCALAUTH_AUTHENTICATE, argJson, { res =>
            // result (ArkTS→CJ): {"ok":<bool>,"msg":<str>}
            let ok = jsonBoolField(res, "ok")
            let msg = jsonStringField(res, "msg")
            Hilog.info(0, "CjTelegram", "[LocalAuthManager] auth result ok=${ok} msg=${msg}")
            // 原实现在 launch{} 中回调以脱离 JS 回调线程；保留该语义（既有调用方再自行 hop UIThread）。
            launch {
                callback(ok, msg)
            }
        })
    }

    // ─── internal ───

    /**
     * 懒发一次异步可用性探测（幂等）。结果 {available,type} 回填缓存。
     * 首次同步 getter 在探测回填前返回降级值 false/"none"（安全）。
     */
    private func ensureProbeDispatched(): Unit {
        if (this._probeDispatched) {
            return
        }
        this._probeDispatched = true
        callArkAsync(LOCALAUTH_AVAILABLE, "{}", { res =>
            let avail = jsonBoolField(res, "available")
            let ty = jsonStringField(res, "type")
            this._biometricAvailable = avail
            this._biometricType = if (avail && (ty == "face" || ty == "fingerprint")) { ty } else { "none" }
            Hilog.info(0, "CjTelegram", "[LocalAuthManager] availability probe: available=${this._biometricAvailable} type=${this._biometricType}")
        })
    }
}

// ─────────────────────────────────────────────────────────────────
// 轻量 JSON 字段读取 / 转义（仅解析 interop 回传的扁平 result 对象）
// ─────────────────────────────────────────────────────────────────

// 读取 {"<key>": true/false} 布尔字段
func jsonBoolField(json: String, key: String): Bool {
    let needle = "\"${key}\""
    match (json.indexOf(needle)) {
        case Some(i) =>
            let rest = json[(i + needle.size)..json.size]
            // 判断 key 后的值是否为 true（近似：true 先于 false 出现）
            match (rest.indexOf("true")) {
                case Some(t) =>
                    match (rest.indexOf("false")) {
                        case Some(f) => return t < f
                        case None => return true
                    }
                case None => return false
            }
        case None => return false
    }
}

// 读取 {"<key>": "<value>"} 字符串字段（不处理转义嵌套，interop msg 为简单文案）
func jsonStringField(json: String, key: String): String {
    let needle = "\"${key}\""
    match (json.indexOf(needle)) {
        case Some(i) =>
            let afterKey = json[(i + needle.size)..json.size]
            // 找到 key 后的第一个引号（值起始引号）
            match (afterKey.indexOf("\"")) {
                case Some(q1) =>
                    let valStart = afterKey[(q1 + 1)..afterKey.size]
                    match (valStart.indexOf("\"")) {
                        case Some(q2) => return valStart[0..q2]
                        case None => return ""
                    }
                case None => return ""
            }
        case None => return ""
    }
}

// 转义 reason 文案中的引号 / 反斜杠 / 换行，供插值进 argJson
func jsonEscapeLocalAuth(s: String): String {
    var result = ""
    for (ch in s.runes()) {
        if (ch == r'"') {
            result += "\\\""
        } else if (ch == r'\\') {
            result += "\\\\"
        } else if (ch == r'\n') {
            result += "\\n"
        } else if (ch == r'\r') {
            result += "\\r"
        } else if (ch == r'\t') {
            result += "\\t"
        } else {
            result += ch.toString()
        }
    }
    return result
}
