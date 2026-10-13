package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.ArkData.*
import ohos.business_exception.BusinessException
import std.collection.{ArrayList, HashMap}
import std.convert.*
import std.sync.*
import ohos_app_cangjie_entry.core.storage.getAuthStorage

// ==================== EmojiRecentService Singleton ====================

private var _emojiRecentServiceInstance: Option<EmojiRecentService> = None
private let _emojiRecentServiceInstanceMonitor = Monitor()

public func getEmojiRecentService(): EmojiRecentService {
    return synchronized(_emojiRecentServiceInstanceMonitor) {
        match (_emojiRecentServiceInstance) {
            case Some(inst) => inst
            case None =>
                let inst = EmojiRecentService()
                _emojiRecentServiceInstance = Some(inst)
                inst
        }
    }
}

// ==================== EmojiRecentService ====================

private let EMOJI_RECENT_PREFS: String = "telegram_emoji_recent"
private let EMOJI_RECENT_KEY: String = "recent_emojis_v1"
private let CUSTOM_EMOJI_RECENT_KEY: String = "recent_custom_emoji_ids_v1"
private let EMOJI_SKIN_TONE_KEY: String = "emoji_skin_tone_v1"
private let EMOJI_DISMISSED_TRENDING_KEY: String = "dismissed_trending_emoji_v1"
private let EMOJI_RECENT_MAX: Int32 = 30
private let CUSTOM_EMOJI_RECENT_MAX: Int32 = 32
private let EMOJI_SEP: String = "|"

/**
 * EmojiRecentService — 最近使用 emoji 持久化服务
 *
 * iOS 对应: EmojiPaneNode.recentEmojis (ChatMediaInputNode.swift)
 *   — 持久化到 Telegram AppGroupPreferences under "recentEmojis" key
 *
 * 实现：
 *   - 使用 HarmonyOS Preferences (UIAbilityContext) 持久化最近 emoji
 *   - 最多保存 EMOJI_RECENT_MAX 个，按最近使用顺序排列
 *   - 序列化格式：emoji1|emoji2|emoji3...（管道符分隔，避免 emoji 本身含逗号）
 *   - 同步 IO：Preferences.getPreferences 是同步 API，可在 launch{} 中安全调用
 */
public class EmojiRecentService {
    private let ioMonitor = Monitor()

    /**
     * 获取最近使用 emoji 列表（最多 EMOJI_RECENT_MAX 个）
     * 优先从 Preferences 读取；Preferences 未初始化时返回内置默认列表
     */
    public func getRecentEmojis(): Array<String> {
        let store = getEntityKeyboardStore()
        let token = store.currentToken()
        let scopedKey = store.preferencesKey(EMOJI_RECENT_KEY, token)
        let ctxOpt = getGlobalAbilityContext()
        match (ctxOpt) {
            case None =>
                Hilog.info(0, "CjTelegram", "[EmojiRecentService] no context, returning defaults")
                return defaultRecentEmojis()
            case Some(ctx) =>
                return synchronized(this.ioMonitor) {
                    try {
                        let prefs = Preferences.getPreferences(ctx, EMOJI_RECENT_PREFS)
                        var val = prefs.get(scopedKey, PreferencesValueType.StringData(""))
                        if (!prefs.has(scopedKey) && store.canMigrateLegacy(token) && prefs.has(EMOJI_RECENT_KEY)) {
                            val = prefs.get(EMOJI_RECENT_KEY, PreferencesValueType.StringData(""))
                            prefs.put(scopedKey, val)
                            prefs.flush()
                            Hilog.info(0, "CjTelegram", "[EmojiRecentService] migrated legacy recents slot=${token.slot}")
                        }
                        let raw = match (val) {
                            case PreferencesValueType.StringData(s) => s
                            case _ => ""
                        }
                        if (raw.size == 0) {
                            return defaultRecentEmojis()
                        }
                        return parseEmojiList(raw)
                    } catch (e: BusinessException) {
                        Hilog.info(0, "CjTelegram", "[EmojiRecentService] read failed")
                        return defaultRecentEmojis()
                    }
                }
        }
    }

    /**
     * 记录 emoji 使用（插入到最前，去重，裁剪到 EMOJI_RECENT_MAX）
     */
    public func recordUsed(emoji: String) {
        let store = getEntityKeyboardStore()
        let token = store.currentToken()
        let scopedKey = store.preferencesKey(EMOJI_RECENT_KEY, token)
        let ctxOpt = getGlobalAbilityContext()
        match (ctxOpt) {
            case None =>
                Hilog.info(0, "CjTelegram", "[EmojiRecentService] no context for recordUsed")
                return
            case Some(ctx) =>
                let _ = spawn {
                    synchronized(this.ioMonitor) {
                        if (!store.isCurrent(token)) {
                            Hilog.info(0, "CjTelegram", "[EmojiRecentService] drop stale record generation=${token.generation}")
                            return
                        }
                        try {
                            let prefs = Preferences.getPreferences(ctx, EMOJI_RECENT_PREFS)
                            var val = prefs.get(scopedKey, PreferencesValueType.StringData(""))
                            if (!prefs.has(scopedKey) && store.canMigrateLegacy(token) && prefs.has(EMOJI_RECENT_KEY)) {
                                val = prefs.get(EMOJI_RECENT_KEY, PreferencesValueType.StringData(""))
                            }
                            let raw = match (val) {
                                case PreferencesValueType.StringData(s) => s
                                case _ => ""
                            }
                            let existing = if (raw.size > 0) { parseEmojiList(raw) } else { defaultRecentEmojis() }
                            let updated = insertRecentEmoji(existing, emoji)
                            let serialized = serializeEmojiList(updated)
                            prefs.put(scopedKey, PreferencesValueType.StringData(serialized))
                            prefs.flush()
                            Hilog.info(0, "CjTelegram", "[EmojiRecentService] recorded emoji slot=${token.slot}")
                        } catch (e: BusinessException) {
                            Hilog.info(0, "CjTelegram", "[EmojiRecentService] recordUsed failed")
                        }
                    }
                }
        }
    }

    /**
     * iOS 的 recent 组 isClearable：清空最近使用（含自定义表情）。
     */
    public func clearRecent(): Unit {
        let store = getEntityKeyboardStore()
        let token = store.currentToken()
        let emojiKey = store.preferencesKey(EMOJI_RECENT_KEY, token)
        let customKey = store.preferencesKey(CUSTOM_EMOJI_RECENT_KEY, token)
        match (getGlobalAbilityContext()) {
            case None => return
            case Some(ctx) =>
                let _ = spawn {
                    synchronized(this.ioMonitor) {
                        try {
                            let prefs = Preferences.getPreferences(ctx, EMOJI_RECENT_PREFS)
                            // 写空串而不是 delete：读取端把「空」当成「回退到默认列表」，
                            // 所以要留一个显式的空值把默认值也挡掉。
                            prefs.put(emojiKey, PreferencesValueType.StringData(EMOJI_SEP))
                            prefs.put(customKey, PreferencesValueType.StringData(""))
                            prefs.flush()
                        } catch (e: BusinessException) {
                            Hilog.info(0, "CjTelegram", "[EmojiRecentService] clearRecent failed")
                        }
                    }
                }
        }
    }

    /**
     * iOS 记住每个 emoji 上次选过的肤色，下次直接以该肤色呈现。
     * 存成 "base>variant|base>variant" 的扁平串，量很小，不值得单开一张表。
     */
    public func getSkinTones(): HashMap<String, String> {
        let result = HashMap<String, String>()
        let store = getEntityKeyboardStore()
        let token = store.currentToken()
        let key = store.preferencesKey(EMOJI_SKIN_TONE_KEY, token)
        match (getGlobalAbilityContext()) {
            case None => return result
            case Some(ctx) =>
                synchronized(this.ioMonitor) {
                    try {
                        let prefs = Preferences.getPreferences(ctx, EMOJI_RECENT_PREFS)
                        let raw = match (prefs.get(key, PreferencesValueType.StringData(""))) {
                            case PreferencesValueType.StringData(v) => v
                            case _ => ""
                        }
                        for (pair in raw.split(EMOJI_SEP)) {
                            let parts = pair.split(">")
                            if (parts.size == 2 && parts[0].size > 0 && parts[1].size > 0) {
                                result[parts[0]] = parts[1]
                            }
                        }
                    } catch (e: BusinessException) {
                        Hilog.info(0, "CjTelegram", "[EmojiRecentService] skin tone read failed")
                    }
                }
                return result
        }
    }

    public func recordSkinTone(base: String, variant: String): Unit {
        if (base.size == 0 || variant.size == 0) { return }
        let store = getEntityKeyboardStore()
        let token = store.currentToken()
        let key = store.preferencesKey(EMOJI_SKIN_TONE_KEY, token)
        match (getGlobalAbilityContext()) {
            case None => return
            case Some(ctx) =>
                let _ = spawn {
                    synchronized(this.ioMonitor) {
                        try {
                            let prefs = Preferences.getPreferences(ctx, EMOJI_RECENT_PREFS)
                            let raw = match (prefs.get(key, PreferencesValueType.StringData(""))) {
                                case PreferencesValueType.StringData(v) => v
                                case _ => ""
                            }
                            var next = "${base}>${variant}"
                            for (pair in raw.split(EMOJI_SEP)) {
                                let parts = pair.split(">")
                                if (parts.size == 2 && parts[0] != base && parts[0].size > 0) {
                                    next = next + EMOJI_SEP + pair
                                }
                            }
                            prefs.put(key, PreferencesValueType.StringData(next))
                            prefs.flush()
                        } catch (e: BusinessException) {
                            Hilog.info(0, "CjTelegram", "[EmojiRecentService] skin tone write failed")
                        }
                    }
                }
        }
    }

    /** iOS dismissedTrendingEmojiPacks：关掉 TRENDING 之后要跨会话记住。 */
    public func isTrendingDismissed(): Bool {
        let store = getEntityKeyboardStore()
        let key = store.preferencesKey(EMOJI_DISMISSED_TRENDING_KEY, store.currentToken())
        match (getGlobalAbilityContext()) {
            case None => return false
            case Some(ctx) =>
                synchronized(this.ioMonitor) {
                    try {
                        let prefs = Preferences.getPreferences(ctx, EMOJI_RECENT_PREFS)
                        return match (prefs.get(key, PreferencesValueType.StringData(""))) {
                            case PreferencesValueType.StringData(v) => v == "1"
                            case _ => false
                        }
                    } catch (e: BusinessException) { return false }
                }
        }
    }

    public func setTrendingDismissed(dismissed: Bool): Unit {
        let store = getEntityKeyboardStore()
        let key = store.preferencesKey(EMOJI_DISMISSED_TRENDING_KEY, store.currentToken())
        match (getGlobalAbilityContext()) {
            case None => return
            case Some(ctx) =>
                let _ = spawn {
                    synchronized(this.ioMonitor) {
                        try {
                            let prefs = Preferences.getPreferences(ctx, EMOJI_RECENT_PREFS)
                            prefs.put(key, PreferencesValueType.StringData(
                                if (dismissed) { "1" } else { "0" }))
                            prefs.flush()
                        } catch (e: BusinessException) {
                            Hilog.info(0, "CjTelegram", "[EmojiRecentService] trending flag write failed")
                        }
                    }
                }
        }
    }

    /**
     * iOS 的 Recent 同时包含 Unicode Emoji 与 Custom Emoji。Custom Emoji 只持久化
     * document id，文档元数据由账号级 getCustomEmojiDocuments 缓存恢复，既不会把
     * file_reference 这种短生命周期字段写进 Preferences，也能跟随服务端刷新。
     */
    public func getRecentCustomEmoji(): Array<StickerItem> {
        let ids = this.getRecentCustomEmojiIds()
        if (ids.isEmpty()) {
            return Array<StickerItem>(0, repeat: StickerItem())
        }
        let requested = ArrayList<Int64>()
        for (id in ids) { requested.add(id) }
        let resolved = fetchCustomEmojiDocuments(requested)
        // 非 premium 账号：recent 里不应出现任何 premium 自定义表情。
        // 历史脏数据来源：早期门禁/标志位演进时期与自动化测试点击写入的记录
        //（现行点击路径 selectCustomEmoji 已在记录前拦截 locked 项）。
        // 这里读取时过滤，并把清洗后的 id 列表回写 Preferences 一次性自愈 ——
        // 该锁定项同时是 emoji 行表 gen 乒乓（A/B 内容交替、无限 reload）
        // 的物质基础，剔除后一并平息。
        let premium = match (getAuthStorage().getUserData()) {
            case Some(user) => user.isPremium
            case None => false
        }
        let ordered = ArrayList<StickerItem>()
        let keptIds = ArrayList<Int64>()
        for (id in ids) {
            for (item in resolved) {
                if (item.documentId == id) {
                    if (!premium && item.isCustomEmoji && !item.isFreeEmoji) {
                        continue
                    }
                    ordered.add(item)
                    keptIds.add(id)
                }
            }
        }
        if (keptIds.size < Int64(ids.size)) {
            this.rewriteRecentCustomEmojiIds(keptIds.toArray())
        }
        return ordered.toArray()
    }

    /** 清洗回写（与 recordCustomEmojiUsed 同一把 ioMonitor/同一个 scoped key）。 */
    private func rewriteRecentCustomEmojiIds(ids: Array<Int64>): Unit {
        let store = getEntityKeyboardStore()
        let token = store.currentToken()
        let scopedKey = store.preferencesKey(CUSTOM_EMOJI_RECENT_KEY, token)
        match (getGlobalAbilityContext()) {
            case None => ()
            case Some(ctx) =>
                synchronized(this.ioMonitor) {
                    if (!store.isCurrent(token)) { return }
                    try {
                        let prefs = Preferences.getPreferences(ctx, EMOJI_RECENT_PREFS)
                        prefs.put(scopedKey, PreferencesValueType.StringData(
                            serializeCustomEmojiIds(ids)))
                        prefs.flush()
                        Hilog.info(0, "CjTelegram",
                            "[EmojiRecentService] purged locked custom emoji from recents, kept=${ids.size}")
                    } catch (_e: BusinessException) {
                        Hilog.info(0, "CjTelegram",
                            "[EmojiRecentService] recent purge rewrite failed")
                    }
                }
        }
    }

    public func recordCustomEmojiUsed(documentId: Int64): Unit {
        if (documentId == 0) { return }
        let store = getEntityKeyboardStore()
        let token = store.currentToken()
        let scopedKey = store.preferencesKey(CUSTOM_EMOJI_RECENT_KEY, token)
        match (getGlobalAbilityContext()) {
            case None => ()
            case Some(ctx) =>
                let _ = spawn {
                    synchronized(this.ioMonitor) {
                        if (!store.isCurrent(token)) { return }
                        try {
                            let prefs = Preferences.getPreferences(ctx, EMOJI_RECENT_PREFS)
                            let current = match (prefs.get(scopedKey,
                                PreferencesValueType.StringData(""))) {
                                case PreferencesValueType.StringData(value) =>
                                    parseCustomEmojiIds(value)
                                case _ => Array<Int64>(0, repeat: 0)
                            }
                            let next = insertRecentCustomEmoji(current, documentId)
                            prefs.put(scopedKey, PreferencesValueType.StringData(
                                serializeCustomEmojiIds(next)))
                            prefs.flush()
                        } catch (_e: BusinessException) {
                            Hilog.info(0, "CjTelegram",
                                "[EmojiRecentService] record custom Emoji failed")
                        }
                    }
                }
        }
    }

    private func getRecentCustomEmojiIds(): Array<Int64> {
        let store = getEntityKeyboardStore()
        let token = store.currentToken()
        let scopedKey = store.preferencesKey(CUSTOM_EMOJI_RECENT_KEY, token)
        match (getGlobalAbilityContext()) {
            case None => return Array<Int64>(0, repeat: 0)
            case Some(ctx) =>
                return synchronized(this.ioMonitor) {
                    try {
                        let prefs = Preferences.getPreferences(ctx, EMOJI_RECENT_PREFS)
                        match (prefs.get(scopedKey, PreferencesValueType.StringData(""))) {
                            case PreferencesValueType.StringData(value) =>
                                parseCustomEmojiIds(value)
                            case _ => Array<Int64>(0, repeat: 0)
                        }
                    } catch (_e: BusinessException) {
                        Array<Int64>(0, repeat: 0)
                    }
                }
        }
    }

    /**
     * 默认最近 emoji（首次使用或 Preferences 不可用时）
     */
    public func defaultRecentEmojis(): Array<String> {
        return ["😀", "❤️", "👍", "🔥", "😂", "🎉", "💯", "✨", "😍", "🙏"]
    }
}

// ==================== Emoji 列表序列化辅助 ====================

/**
 * 解析 Preferences 存储的 emoji 列表（管道符分隔）
 */
private func parseEmojiList(raw: String): Array<String> {
    let parts = raw.split(EMOJI_SEP)
    let result = ArrayList<String>()
    for (part in parts) {
        if (part.size > 0) {
            result.add(part)
        }
    }
    return result.toArray()
}

/**
 * 序列化 emoji 列表为存储格式
 */
private func serializeEmojiList(emojis: Array<String>): String {
    var s: String = ""
    var i: Int64 = 0
    while (i < Int64(emojis.size)) {
        if (i > 0) {
            s = s + EMOJI_SEP
        }
        s = s + emojis[i]
        i = i + 1
    }
    return s
}

/**
 * 插入 emoji 到最近列表头部（去重，裁剪）
 */
private func insertRecentEmoji(existing: Array<String>, newEmoji: String): Array<String> {
    let list = ArrayList<String>()
    list.add(newEmoji)
    for (e in existing) {
        if (e != newEmoji && Int32(list.size) < EMOJI_RECENT_MAX) {
            list.add(e)
        }
    }
    return list.toArray()
}

private func parseCustomEmojiIds(raw: String): Array<Int64> {
    let result = ArrayList<Int64>()
    for (part in raw.split(",")) {
        try {
            let id = Int64.parse(part)
            if (id != 0) { result.add(id) }
        } catch (_e: Exception) {}
    }
    return result.toArray()
}

private func serializeCustomEmojiIds(ids: Array<Int64>): String {
    var value = ""
    var index: Int64 = 0
    while (index < Int64(ids.size)) {
        if (index > 0) { value = value + "," }
        value = value + ids[index].toString()
        index = index + 1
    }
    return value
}

private func insertRecentCustomEmoji(existing: Array<Int64>, documentId: Int64): Array<Int64> {
    let result = ArrayList<Int64>()
    result.add(documentId)
    for (id in existing) {
        if (id != documentId && Int32(result.size) < CUSTOM_EMOJI_RECENT_MAX) {
            result.add(id)
        }
    }
    return result.toArray()
}
