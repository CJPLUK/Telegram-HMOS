package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.ArkData.*
import kit.AbilityKit.UIAbilityContext

/**
 * ItemCacheService — 通用 key-value 缓存引擎 (feature: telegram_engine_item_cache)
 *
 * 基于 HarmonyOS Preferences API 的持久化存储，参考 AuthStorage.cj 模式。
 * 提供 get/put/remove/clear/has 等操作，支持字符串和 JSON 对象存储。
 *
 * 必须在 MainAbility.onWindowStageCreate 中调用 initialize(context)。
 */
private var _itemCacheServiceInstance: Option<ItemCacheService> = None

public func getTelegramEngineItemCacheService(): ItemCacheService {
    match (_itemCacheServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ItemCacheService()
            _itemCacheServiceInstance = Some(inst)
            return inst
    }
}

public class ItemCacheService {
    private var preferences: Option<Preferences> = None
    private var initialized: Bool = false

    /**
     * 使用 UIAbilityContext 初始化 Preferences 持久化存储
     * 必须在 MainAbility.onWindowStageCreate 中调用
     */
    public func initialize(context: UIAbilityContext): Unit {
        try {
            let prefs = Preferences.getPreferences(context, "telegram_item_cache")
            this.preferences = Some(prefs)
            this.initialized = true
            Hilog.info(0, "CjTelegram", "[ItemCacheService] Initialized with Preferences (persistent storage)")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ItemCacheService] Failed to initialize Preferences: ${e}")
            this.initialized = true
        }
    }

    public func isInitialized(): Bool {
        return this.initialized
    }

    /**
     * 存储字符串值
     */
    public func put(key: String, value: String): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(key, PreferencesValueType.StringData(value))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ItemCacheService] Failed to put key=${key}: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[ItemCacheService] Preferences not initialized, cannot put")
        }
    }

    /**
     * 获取字符串值
     */
    public func get(key: String): Option<String> {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    if (!prefs.has(key)) {
                        return None
                    }
                    let val = prefs.get(key, PreferencesValueType.StringData(""))
                    match (val) {
                        case PreferencesValueType.StringData(s) => return Some(s)
                        case _ => return None
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ItemCacheService] Failed to get key=${key}: ${e}")
                    return None
                }
            case None => return None
        }
    }

    /**
     * 删除指定 key
     */
    public func remove(key: String): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.delete(key)
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ItemCacheService] Failed to remove key=${key}: ${e}")
                }
            case None => ()
        }
    }

    /**
     * 检查 key 是否存在
     */
    public func has(key: String): Bool {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    return prefs.has(key)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ItemCacheService] Failed to has key=${key}: ${e}")
                    return false
                }
            case None => return false
        }
    }

    /**
     * 清空所有缓存条目
     * 使用 Preferences.clear() 若 API 可用，否则无操作（ItemCache 通常按 key 管理，clear 使用较少）
     */
    public func clear(): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.clear()
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[ItemCacheService] Cleared all entries")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ItemCacheService] Failed to clear: ${e}")
                }
            case None => ()
        }
    }

    /**
     * 获取当前缓存条目数（byte estimate: each entry ~1 KB average）
     * Returns an estimated byte count for display purposes.
     * Actual memory: key-value Preferences entries; estimated 1 KB per entry.
     */
    public func estimateCacheSizeBytes(): Int64 {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let all = prefs.getAll()
                    var totalBytes: Int64 = 0
                    for ((k, v) in all) {
                        totalBytes = totalBytes + Int64(k.size)
                        match (v) {
                            case PreferencesValueType.StringData(s) => totalBytes = totalBytes + Int64(s.size)
                            case PreferencesValueType.Integer(_) => totalBytes = totalBytes + 8
                            case _ => totalBytes = totalBytes + 64
                        }
                    }
                    return totalBytes
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ItemCacheService] estimateCacheSizeBytes failed: ${e}")
                    return 0
                }
            case None => return 0
        }
    }
}
