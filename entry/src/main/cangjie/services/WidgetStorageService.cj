package ohos_app_cangjie_entry.services

/**
 * WidgetStorageService — P2-436
 *
 * 跨进程共享存储：将 widget 数据序列化为 JSON 写入 distributedKVStore，
 * 供桌面卡片进程（FormExtensionAbility / ArkTS 受限运行时）读取。
 *
 * iOS 对应：AppGroup 共享容器（UserDefaults suite / group.ph.telegra.Telegraph）。
 * HarmonyOS 对应：distributedKVStore（SingleKVStore），同 bundleName 不同进程均可读写。
 *
 * PLATFORM NOTE:
 *   HarmonyOS 桌面卡片运行在独立进程（FormExtensionAbility/ArkTS 受限运行时），
 *   普通 app Preferences 是进程私有，无法跨进程读。
 *   distributedKVStore 支持同 bundle 内多进程共享同一 storeId，是正确的跨进程方案。
 *
 * KB 确认 API（从 KB score=0.016 文档示例提取，Reviewer 请复查）：
 *   - store.put(key, KVValueType.StringValue(value))
 *   - store.get(key): KVValueType → match { case StringValue(v) => }
 *   - KVManagerConfig(ctx, bundleName)
 *   - KVOptions(KVSecurityLevel.S1)
 *   - getKVStore<SingleKVStore>(storeId, opts): Option<SingleKVStore>
 *
 * 调用链：
 *   persistWidgetData()
 *     → getWidgetItemsServiceV2().serializeToJson()
 *     → getOrCreateKVStore() → SingleKVStore.put(WIDGET_DATA_KEY, json)
 *
 *   getWidgetJsonFromKVStore()
 *     → getOrCreateKVStore() → SingleKVStore.get(WIDGET_DATA_KEY)
 *     → KVValueType match StringValue → json String
 *
 * @State 无（本服务无 UI 绑定）
 */

import kit.ArkData.DistributedKVStore
import kit.ArkData.KVManagerConfig
import kit.ArkData.KVOptions
import kit.ArkData.KVSecurityLevel
import kit.ArkData.KVValueType
import kit.ArkData.SingleKVStore
import kit.AbilityKit.UIAbilityContext
import kit.PerformanceAnalysisKit.Hilog
import ohos.business_exception.BusinessException

// ============================================================
// 常量
// ============================================================

private let WIDGET_STORE_ID: String = "telegram_widget_store"
private let WIDGET_DATA_KEY: String = "widget_data_json"
private let WIDGET_BUNDLE_NAME: String = "com.example.telegram"

// ============================================================
// 全局 context（由 MainAbility.onCreate 注入）
// ============================================================

private var _widgetStorageContext: Option<UIAbilityContext> = None

/**
 * 注入 UIAbilityContext（在 MainAbility.onCreate 中调用）
 * distributedKVStore 需要 UIAbilityContext（不能用 AbilityStage context）
 * 对应 S-012 合规。
 */
public func setWidgetStorageContext(ctx: UIAbilityContext): Unit {
    _widgetStorageContext = Some(ctx)
    Hilog.info(0, "CjTelegram", "[WidgetStorageService] context set")
}

// ============================================================
// Singleton
// ============================================================

private var _widgetStorageServiceInstance: Option<WidgetStorageService> = None

public func getWidgetStorageService(): WidgetStorageService {
    match (_widgetStorageServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = WidgetStorageService()
            _widgetStorageServiceInstance = Some(inst)
            return inst
    }
}

// ============================================================
// WidgetStorageService
// ============================================================

public class WidgetStorageService {
    // 已初始化的 KV store（懒初始化，init 后复用）
    private var cachedStore: Option<SingleKVStore> = None

    /**
     * 将当前 WidgetItemsServiceV2 缓存数据持久化到 distributedKVStore。
     * 卡片进程启动时读取同一 storeId 拿到数据。
     *
     * @return true 落盘成功，false 失败
     */
    public func persistWidgetData(): Bool {
        let json = getWidgetItemsServiceV2().serializeToJson()
        Hilog.info(0, "CjTelegram", "[WidgetStorageService] persistWidgetData json.len=${json.size}")
        return this.putJson(json)
    }

    /**
     * 刷新 widget 数据并落盘（一步完成）
     * @param unlockedForLockId 解锁标记
     */
    public func refreshAndPersist(unlockedForLockId!: String = ""): Bool {
        let _ = getWidgetItemsServiceV2().refreshWidgetData(unlockedForLockId: unlockedForLockId)
        return this.persistWidgetData()
    }

    /**
     * 从 distributedKVStore 读取 widget JSON（供 FormWidgetHostService 调用）
     * @return JSON 字符串，读取失败返回 ""
     */
    public func getWidgetJsonFromKVStore(): String {
        match (this.getOrCreateKVStore()) {
            case None =>
                Hilog.warn(0, "CjTelegram", "[WidgetStorageService] getWidgetJsonFromKVStore: store not ready")
                return ""
            case Some(store) =>
                try {
                    // KB API: store.get(key: String): KVValueType  (1 arg only)
                    let val = store.get(WIDGET_DATA_KEY)
                    match (val) {
                        case KVValueType.StringValue(s) =>
                            Hilog.info(0, "CjTelegram", "[WidgetStorageService] getWidgetJson ok len=${s.size}")
                            return s
                        case _ => return ""
                    }
                } catch (e: BusinessException) {
                    Hilog.error(0, "CjTelegram", "[WidgetStorageService] get failed: ${e.message}")
                    return ""
                }
        }
    }

    // ============================================================
    // 内部实现
    // ============================================================

    private func putJson(json: String): Bool {
        match (this.getOrCreateKVStore()) {
            case None =>
                Hilog.warn(0, "CjTelegram", "[WidgetStorageService] putJson: store not ready")
                return false
            case Some(store) =>
                try {
                    // KB API: store.put(key: String, value: KVValueType)
                    store.put(WIDGET_DATA_KEY, KVValueType.StringValue(json))
                    Hilog.info(0, "CjTelegram", "[WidgetStorageService] put ok key=${WIDGET_DATA_KEY}")
                    return true
                } catch (e: BusinessException) {
                    Hilog.error(0, "CjTelegram", "[WidgetStorageService] put failed: ${e.message}")
                    return false
                }
        }
    }

    /**
     * 获取或初始化 SingleKVStore。
     * 需要 UIAbilityContext（S-012 合规）。
     *
     * KB API:
     *   DistributedKVStore.createKVManager(KVManagerConfig(ctx, bundleName)): KVManager
     *   mgr.getKVStore<SingleKVStore>(storeId, opts): Option<SingleKVStore>
     *   KVOptions(KVSecurityLevel.S1, createIfMissing: ..., encrypt: ..., backup: ..., autoSync: ...)
     */
    private func getOrCreateKVStore(): Option<SingleKVStore> {
        match (this.cachedStore) {
            case Some(_) => return this.cachedStore
            case None => ()
        }

        match (_widgetStorageContext) {
            case None =>
                Hilog.warn(0, "CjTelegram", "[WidgetStorageService] context not set, cannot init KVStore")
                return None
            case Some(ctx) =>
                try {
                    let cfg = KVManagerConfig(ctx, WIDGET_BUNDLE_NAME)
                    let mgr = DistributedKVStore.createKVManager(cfg)
                    let opts = KVOptions(
                        KVSecurityLevel.S1,
                        createIfMissing: true,
                        encrypt: false,
                        backup: false,
                        autoSync: false)
                    let store: SingleKVStore = mgr.getKVStore<SingleKVStore>(WIDGET_STORE_ID, opts)
                    this.cachedStore = Some(store)
                    Hilog.info(0, "CjTelegram", "[WidgetStorageService] KVStore initialized storeId=${WIDGET_STORE_ID}")
                    return this.cachedStore
                } catch (e: BusinessException) {
                    Hilog.error(0, "CjTelegram", "[WidgetStorageService] KVStore init failed: ${e.message}")
                    return None
                }
        }
    }
}

// ============================================================
// WidgetPresentationData — P2-436 本地化文案
//
// iOS: WidgetPresentationData (widget extension 内的本地化字符串)
// HarmonyOS: Cangjie 侧文案，FormWidgetHostService 通过 formBindingData 下发给 ArkTS 卡片
// ============================================================

public class WidgetPresentationData {
    // Locked 态文案
    public static let lockedTitle: String = "Locked"
    public static let lockedSubtitle: String = "Open Telegram to view chats"
    // 空态文案
    public static let noChatsTitle: String = "No recent chats"
    // 应用名
    public static let appName: String = "Telegram"
    // "Saved Messages" 会话名
    public static let savedMessagesTitle: String = "Saved Messages"

    /**
     * 从系统语言选择文案（简化版：返回英文，正式应集成 LocalizationService）
     */
    public static func localized(key: String): String {
        if (key == "widget.locked.title") { return WidgetPresentationData.lockedTitle }
        if (key == "widget.locked.subtitle") { return WidgetPresentationData.lockedSubtitle }
        if (key == "widget.noChats.title") { return WidgetPresentationData.noChatsTitle }
        if (key == "widget.app.name") { return WidgetPresentationData.appName }
        if (key == "widget.savedMessages") { return WidgetPresentationData.savedMessagesTitle }
        return key
    }
}
