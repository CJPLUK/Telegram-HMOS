package ohos_app_cangjie_entry.providers

import std.collection.ArrayList
import ohos_app_cangjie_entry.models.{
    LanguageInfo,
    LocalizationInfo,
    LocalizationListState,
    SuggestedLocalizationInfo,
    CountryInfo
}
import ohos_app_cangjie_entry.services.getLocalizationService

/**
 * LocalizationDataProvider — 本地化数据接口
 *
 * 对应 iOS TelegramEngine.Localization 的 UI 适配层
 * 将 LocalizationService 的数据转为 UI 可用的格式
 *
 * P2-164 新增 6 个 gap 全部通过此 Provider 暴露:
 * 1. getCountriesList
 * 2. synchronizedLocalizationListState
 * 3. suggestedLocalizationInfo
 * 4. requestLocalizationPreview
 * 5. downloadAndApplyLocalization
 * 6. removeSavedLocalization
 */
public class LocalizationDataProvider {
    private let localizationService = getLocalizationService()

    // ==================== Existing methods ====================

    /**
     * 获取可用语言列表
     */
    public func getAvailableLanguages(): ArrayList<LanguageInfo> {
        return this.localizationService.fetchAvailableLanguages()
    }

    /**
     * 获取当前语言代码
     */
    public func getCurrentLangCode(): String {
        return this.localizationService.getCurrentLangCode()
    }

    /**
     * 应用语言
     */
    public func applyLanguage(langCode: String): Bool {
        return this.localizationService.applyLanguage(langCode)
    }

    /**
     * 按 key 获取翻译
     */
    public func getTranslation(key: String): String {
        return this.localizationService.getTranslation(key)
    }

    // ==================== Gap 1: getCountriesList ====================

    /**
     * 获取国家列表（含国家代码 / ISO2 / 名称）
     * 带 hash 缓存，forceUpdate=true 跳过缓存。
     * iOS: TelegramEngine.Localization.getCountriesList
     */
    public func getCountriesList(langCode: String, forceUpdate: Bool): ArrayList<CountryInfo> {
        return this.localizationService.getCountriesList(langCode, forceUpdate)
    }

    // ==================== Gap 2: synchronizedLocalizationListState ====================

    /**
     * 同步可用本地化列表状态（刷新官方语言包列表）
     * iOS: TelegramEngine.Localization.synchronizedLocalizationListState
     */
    public func synchronizedLocalizationListState(): Bool {
        return this.localizationService.synchronizedLocalizationListState()
    }

    /**
     * 获取当前本地化列表状态（官方列表 + 已保存列表）
     */
    public func getLocalizationListState(): LocalizationListState {
        return this.localizationService.getLocalizationListState()
    }

    // ==================== Gap 3: suggestedLocalizationInfo ====================

    /**
     * 获取建议的本地化信息（基于语言代码 + 抽取 key）
     * iOS: TelegramEngine.Localization.suggestedLocalizationInfo
     */
    public func suggestedLocalizationInfo(languageCode: String, extractKeys: ArrayList<String>): Option<SuggestedLocalizationInfo> {
        return this.localizationService.suggestedLocalizationInfo(languageCode, extractKeys)
    }

    // ==================== Gap 4: requestLocalizationPreview ====================

    /**
     * 请求某语言包的预览信息（LangPackLanguage 元数据）
     * iOS: TelegramEngine.Localization.requestLocalizationPreview
     */
    public func requestLocalizationPreview(identifier: String): Option<LocalizationInfo> {
        return this.localizationService.requestLocalizationPreview(identifier)
    }

    // ==================== Gap 5: downloadAndApplyLocalization ====================

    /**
     * 下载并应用语言包（完整 LangPackDifference 流程）
     * 持久化 langCode 到 AuthStorage，应用 strings 到 I18nManager。
     * iOS: TelegramEngine.Localization.downloadAndApplyLocalization
     */
    public func downloadAndApplyLocalization(languageCode: String): Bool {
        return this.localizationService.downloadAndApplyLocalization(languageCode)
    }

    // ==================== Gap 6: removeSavedLocalization ====================

    /**
     * 移除已保存的本地化（从内存 LocalizationListState 中删除）
     * iOS: TelegramEngine.Localization.removeSavedLocalization
     */
    public func removeSavedLocalization(languageCode: String): Unit {
        this.localizationService.removeSavedLocalization(languageCode)
    }
}
