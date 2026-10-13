package ohos_app_cangjie_entry.bindings

/**
 * PlatformRestrictionMatchingBinding — 内容平台限制匹配封装层
 *
 * 对应 Telegram-iOS submodules/PlatformRestrictionMatching/Sources/PlatformRestrictionMatching.swift
 *
 * iOS 原始逻辑：
 *   1. 遍历 RestrictedContentMessageAttribute.rules（RestrictionReason 列表）
 *   2. 跳过 reason == "sensitive" 的规则
 *   3. 若 rule.platform == "all" || rule.platform == "ios" ||
 *         contentSettings.addContentRestrictionReasons.contains(rule.platform)
 *      且 !contentSettings.ignoreContentRestrictionReasons.contains(rule.reason)
 *      → 返回 rule.text（表示此内容在当前平台受限）
 *
 * 鸿蒙侧：平台标识为 "harmony"；"ios" 规则在纯鸿蒙端不触发（不在白名单），
 *   除非调用方通过 addReasons 显式加入。"all" 规则始终生效。
 *
 * 提供：
 * - RestrictionRule: 单条限制规则（platform, reason, text）
 * - PlatformRestrictionMatchingBinding: 平台限制匹配服务
 */

// ─────────────────────────────────────────────
// 数据类
// ─────────────────────────────────────────────

/**
 * 单条内容限制规则
 * 对应 TL RestrictionReason#d072acb4 platform:string reason:string text:string
 */
public class RestrictionRule {
    /** 目标平台标识（"ios" / "android" / "all" 等） */
    public var platform: String = ""
    /** 限制原因标识（"sensitive" / "age_restriction" 等） */
    public var reason: String = ""
    /** 用户可见的限制说明文本 */
    public var text: String = ""

    public init() {}

    public init(platform: String, reason: String, text: String) {
        this.platform = platform
        this.reason = reason
        this.text = text
    }
}

// ─────────────────────────────────────────────
// 单例
// ─────────────────────────────────────────────

private var _platformRestrictionMatchingBindingInstance: Option<PlatformRestrictionMatchingBinding> = None

/**
 * 获取 PlatformRestrictionMatchingBinding 单例
 */
public func getPlatformRestrictionMatchingBinding(): PlatformRestrictionMatchingBinding {
    match (_platformRestrictionMatchingBindingInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = PlatformRestrictionMatchingBinding()
            _platformRestrictionMatchingBindingInstance = Some(inst)
            return inst
    }
}

// ─────────────────────────────────────────────
// 绑定服务
// ─────────────────────────────────────────────

/**
 * 平台内容限制匹配服务
 *
 * 复刻 iOS RestrictedContentMessageAttribute.platformText(platform:contentSettings:) 逻辑：
 *   - 跳过 reason == "sensitive" 的规则
 *   - 仅匹配 platform == "all"、platform == currentPlatform，
 *     或 platform 在 addPlatforms 白名单内
 *   - 若匹配规则的 reason 在 ignoreReasons 中，跳过
 *   - 返回第一条命中规则的 text；无命中返回 None
 */
public class PlatformRestrictionMatchingBinding {

    /**
     * 在规则列表中寻找当前平台适用的限制原因文本
     *
     * @param rules          RestrictionRule 数组（来自 TL 解析结果）
     * @param currentPlatform 当前平台标识（鸿蒙端传 "harmony"）
     * @param ignoreReasons  忽略的限制原因集合（不限制这些原因）
     * @param addPlatforms   额外匹配的平台集合（除 "all" 和 currentPlatform 外）
     * @return 第一条命中规则的 text，无命中返回 None
     */
    public func matchPlatformRestriction(
        rules: Array<RestrictionRule>,
        currentPlatform: String,
        ignoreReasons: Array<String>,
        addPlatforms: Array<String>
    ): Option<String> {
        for (rule in rules) {
            if (rule.reason == "sensitive") {
                continue
            }
            let platformMatches: Bool
            if (rule.platform == "all" || rule.platform == currentPlatform) {
                platformMatches = true
            } else {
                platformMatches = containsString(addPlatforms, rule.platform)
            }
            if (!platformMatches) {
                continue
            }
            if (containsString(ignoreReasons, rule.reason)) {
                continue
            }
            return Some(rule.text)
        }
        return None
    }

    /**
     * 判断内容在当前平台是否受限
     *
     * @param rules          RestrictionRule 数组
     * @param currentPlatform 当前平台标识
     * @param ignoreReasons  忽略的限制原因集合
     * @param addPlatforms   额外匹配的平台集合
     * @return true 表示受限，false 表示不受限
     */
    public func isRestricted(
        rules: Array<RestrictionRule>,
        currentPlatform: String,
        ignoreReasons: Array<String>,
        addPlatforms: Array<String>
    ): Bool {
        match (this.matchPlatformRestriction(rules, currentPlatform, ignoreReasons, addPlatforms)) {
            case Some(_) => return true
            case None => return false
        }
    }

    /**
     * 检查数组中是否包含指定字符串（辅助函数）
     */
    private func containsString(arr: Array<String>, target: String): Bool {
        for (s in arr) {
            if (s == target) {
                return true
            }
        }
        return false
    }
}
