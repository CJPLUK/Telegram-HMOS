package ohos_app_cangjie_entry.utils

import ohos_app_cangjie_entry.bindings.{
    RestrictionRule,
    PlatformRestrictionMatchingBinding,
    getPlatformRestrictionMatchingBinding
}

/**
 * PlatformRestrictionMatchingUtils — 内容平台限制匹配上层工具接口
 *
 * 对应 Telegram-iOS submodules/PlatformRestrictionMatching/Sources/PlatformRestrictionMatching.swift
 * 公开扩展方法 EngineRawMessage.isRestricted / EngineRawMessage.restrictionReason。
 *
 * 提供：
 * - ContentSettings: 平台内容设置（忽略原因集合 + 额外匹配平台集合）
 * - checkPlatformRestriction: 返回第一条限制原因文本（None = 不受限）
 * - isContentRestricted: 判断是否受限（bool 快捷接口）
 * - checkHarmonyPlatformRestriction: 鸿蒙平台专用快捷接口（平台固定为 "harmony"）
 * - isHarmonyContentRestricted: 鸿蒙平台专用快捷 bool 接口
 */

// ─────────────────────────────────────────────
// 配置数据类
// ─────────────────────────────────────────────

/**
 * 平台内容设置
 *
 * 对应 iOS ContentSettings：
 *   - addContentRestrictionReasons: 额外触发限制的平台标识集合
 *   - ignoreContentRestrictionReasons: 忽略的限制原因集合（这些原因不触发限制）
 */
public class ContentSettings {
    /**
     * 额外触发限制的平台标识集合
     * 若某条规则的 platform 在此集合中，该规则视为匹配当前平台
     */
    public var addContentRestrictionReasons: Array<String> = Array<String>(0, repeat: "")
    /**
     * 忽略的限制原因集合
     * 若某条规则的 reason 在此集合中，该规则不触发限制
     */
    public var ignoreContentRestrictionReasons: Array<String> = Array<String>(0, repeat: "")

    public init() {}

    public init(
        addContentRestrictionReasons: Array<String>,
        ignoreContentRestrictionReasons: Array<String>
    ) {
        this.addContentRestrictionReasons = addContentRestrictionReasons
        this.ignoreContentRestrictionReasons = ignoreContentRestrictionReasons
    }
}

// ─────────────────────────────────────────────
// 工具函数
// ─────────────────────────────────────────────

/**
 * 检查内容限制并返回限制原因文本
 *
 * 对应 iOS RestrictedContentMessageAttribute.platformText(platform:contentSettings:)
 *
 * @param rules           RestrictionRule 数组（来自消息 TL 解析结果）
 * @param platform        当前平台标识（通常为 "harmony"）
 * @param contentSettings 平台内容设置
 * @return 第一条命中限制规则的文本，未受限时返回 None
 */
public func checkPlatformRestriction(
    rules: Array<RestrictionRule>,
    platform: String,
    contentSettings: ContentSettings
): Option<String> {
    return getPlatformRestrictionMatchingBinding().matchPlatformRestriction(
        rules,
        platform,
        contentSettings.ignoreContentRestrictionReasons,
        contentSettings.addContentRestrictionReasons
    )
}

/**
 * 判断内容在指定平台是否受限
 *
 * 对应 iOS EngineRawMessage.isRestricted(platform:contentSettings:)
 *
 * @param rules           RestrictionRule 数组
 * @param platform        当前平台标识
 * @param contentSettings 平台内容设置
 * @return true 表示内容在当前平台受限，false 表示不受限
 */
public func isContentRestricted(
    rules: Array<RestrictionRule>,
    platform: String,
    contentSettings: ContentSettings
): Bool {
    return getPlatformRestrictionMatchingBinding().isRestricted(
        rules,
        platform,
        contentSettings.ignoreContentRestrictionReasons,
        contentSettings.addContentRestrictionReasons
    )
}

/**
 * 鸿蒙平台专用：检查内容限制并返回限制原因文本
 *
 * 平台标识固定为 "harmony"。
 * 仅 platform == "all" 或通过 contentSettings.addContentRestrictionReasons 加入的规则生效；
 * platform == "ios" / "android" 不会触发鸿蒙端限制。
 *
 * @param rules           RestrictionRule 数组
 * @param contentSettings 平台内容设置（可用空设置 ContentSettings()）
 * @return 第一条命中限制规则的文本，未受限时返回 None
 */
public func checkHarmonyPlatformRestriction(
    rules: Array<RestrictionRule>,
    contentSettings: ContentSettings
): Option<String> {
    return checkPlatformRestriction(rules, "harmony", contentSettings)
}

/**
 * 鸿蒙平台专用：判断内容是否受限（bool 快捷接口）
 *
 * @param rules           RestrictionRule 数组
 * @param contentSettings 平台内容设置
 * @return true 表示受限
 */
public func isHarmonyContentRestricted(
    rules: Array<RestrictionRule>,
    contentSettings: ContentSettings
): Bool {
    return isContentRestricted(rules, "harmony", contentSettings)
}

/**
 * 构建默认（宽松）ContentSettings — 不忽略任何原因，不额外匹配任何平台
 *
 * 等价于 iOS ContentSettings 的默认值（两个集合均为空）。
 */
public func defaultContentSettings(): ContentSettings {
    return ContentSettings()
}
