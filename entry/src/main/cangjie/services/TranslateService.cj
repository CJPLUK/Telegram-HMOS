package ohos_app_cangjie_entry.services

import kit.ArkData.*
import kit.ArkUI.{AppStorage, launch}
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import std.collection.ArrayList

public let TRANSLATION_SETTINGS_KEY = "translationSettings"

/** Immutable counterpart of iOS AccountManager.sharedData TranslationSettings. */
public class TranslationSettingsSnapshot {
    public let showTranslate: Bool
    public let translateChats: Bool
    public let ignoredLanguagesCsv: String
    public let hasExplicitIgnoredLanguages: Bool

    public init(showTranslate: Bool, translateChats: Bool, ignoredLanguagesCsv: String,
        hasExplicitIgnoredLanguages: Bool) {
        this.showTranslate = showTranslate
        this.translateChats = translateChats
        this.ignoredLanguagesCsv = ignoredLanguagesCsv
        this.hasExplicitIgnoredLanguages = hasExplicitIgnoredLanguages
    }
}

/**
 * 消息翻译结果
 */
public class TranslateResult {
    public var success: Bool = false
    public var translatedText: String = ""
    public var toLang: String = ""
    public var errorMessage: String = ""

    public init() {}
}

/**
 * 翻译服务（Phase Translate）
 *
 * 封装 messages.translateText TL 方法，调用链:
 *   TranslateService.translateText() → getMTProtoClient().sendRequest() → Telegram 服务器
 *
 * TL 定义:
 *   messages.translateText#27e69375 flags:# peer:flags.0?InputPeer id:flags.0?Vector<int>
 *     text:flags.1?Vector<TextWithEntities> to_lang:string = messages.TranslatedText
 *
 * 响应 messages.TranslatedText:
 *   constructor 0x d61a8 — 实际为 result#33db32f8 result:Vector<TextWithEntities>
 */
public class TranslateService {

    public func settingsSnapshot(): TranslationSettingsSnapshot {
        return TranslationSettingsSnapshot(
            this.getShowTranslateButton(),
            this.getTranslateChatsEnabled(),
            this.getIgnoredLanguagesCsv(),
            this.hasExplicitIgnoredLanguages()
        )
    }

    private func publishSettings(): Unit {
        let snapshot = this.settingsSnapshot()
        launch {
            let _ = AppStorage.setOrCreate<TranslationSettingsSnapshot>(TRANSLATION_SETTINGS_KEY, snapshot)
        }
    }

    /**
     * 翻译单条消息（通过 peer + msgId）
     *
     * @param peerId 对话 ID（user/chat/channel）
     * @param peerAccessHash 对话 accessHash（user/channel 需要）
     * @param peerType "user" | "chat" | "channel"
     * @param msgId 消息 ID
     * @param toLang 目标语言代码，如 "zh"、"en"、"ru"
     * @return TranslateResult
     */
    public func translateMessage(
        peerId: Int64,
        peerAccessHash: Int64,
        peerType: String,
        msgId: Int32,
        toLang: String
    ): TranslateResult {
        let client = getMTProtoClient()
        let req = MessagesTranslateText()
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        req.peerType = peerType
        req.msgId = msgId
        req.toLang = toLang

        try {
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size < 4) {
                let r = TranslateResult()
                r.toLang = toLang
                return r
            }
            return parseTranslateResponse(responseData, toLang)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[TranslateService] translateMessage error")
            let r = TranslateResult()
            r.toLang = toLang
            return r
        }
    }

    /**
     * 翻译裸文本（不依赖 peer/msgId，通过 text vector）
     *
     * @param text 待翻译文本
     * @param toLang 目标语言代码
     * @return TranslateResult
     */
    public func translateText(
        text: String,
        toLang: String
    ): TranslateResult {
        let client = getMTProtoClient()
        let req = MessagesTranslateTextRaw()
        req.text = text
        req.toLang = toLang

        try {
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size < 4) {
                let r = TranslateResult()
                r.toLang = toLang
                return r
            }
            return parseTranslateResponse(responseData, toLang)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[TranslateService] translateText error")
            let r = TranslateResult()
            r.toLang = toLang
            return r
        }
    }

    // ==================== 翻译设置持久化 ====================

    /**
     * 保存「显示翻译按钮」开关。
     * 对应 iOS TranslationSettings.showTranslate。
     * 存储 key: "translate_show_button"，store: "telegram_translate_settings"
     */
    public func saveShowTranslateButton(enabled: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_translate_settings")
                    prefs.put("translate_show_button", PreferencesValueType.BoolData(enabled))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[TranslateService] saveShowTranslateButton: ${enabled}")
                    this.publishSettings()
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[TranslateService] saveShowTranslateButton error")
                }
            case None => ()
        }
    }

    /**
     * 读取「显示翻译按钮」开关。默认 false（对应 iOS defaultSettings.showTranslate = false）。
     */
    public func getShowTranslateButton(): Bool {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_translate_settings")
                    let val = prefs.get("translate_show_button", PreferencesValueType.BoolData(false))
                    match (val) {
                        case PreferencesValueType.BoolData(b) => return b
                        case _ => return false
                    }
                } catch (_e: Exception) {
                    return false
                }
            case None => return false
        }
    }

    /**
     * 保存「整体聊天翻译」开关。
     * 对应 iOS TranslationSettings.translateChats。
     * 存储 key: "translate_chats_enabled"，store: "telegram_translate_settings"
     */
    public func saveTranslateChatsEnabled(enabled: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_translate_settings")
                    prefs.put("translate_chats_enabled", PreferencesValueType.BoolData(enabled))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[TranslateService] saveTranslateChatsEnabled: ${enabled}")
                    this.publishSettings()
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[TranslateService] saveTranslateChatsEnabled error")
                }
            case None => ()
        }
    }

    /**
     * 读取「整体聊天翻译」开关。默认 true（对应 iOS defaultSettings.translateChats = true）。
     */
    public func getTranslateChatsEnabled(): Bool {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_translate_settings")
                    let val = prefs.get("translate_chats_enabled", PreferencesValueType.BoolData(true))
                    match (val) {
                        case PreferencesValueType.BoolData(b) => return b
                        case _ => return true
                    }
                } catch (_e: Exception) {
                    return true
                }
            case None => return true
        }
    }

    /**
     * 保存「不翻译的语言」列表（逗号分隔的 BCP 47 语言代码）。
     * 对应 iOS TranslationSettings.ignoredLanguages: [String]?
     * 存储 key: "translate_ignored_langs"，store: "telegram_translate_settings"
     * 空列表存空字符串 ""。
     */
    public func saveIgnoredLanguages(codes: Array<String>): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    var joined = ""
                    var i: Int64 = 0
                    while (i < codes.size) {
                        if (i > 0) { joined = joined + "," }
                        joined = joined + codes[i]
                        i = i + 1
                    }
                    let prefs = Preferences.getPreferences(ctx, "telegram_translate_settings")
                    prefs.put("translate_ignored_langs", PreferencesValueType.StringData(joined))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[TranslateService] saveIgnoredLanguages: ${joined}")
                    this.publishSettings()
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[TranslateService] saveIgnoredLanguages error")
                }
            case None => ()
        }
    }

    /**
     * 读取「不翻译的语言」列表（BCP 47 语言代码 Array<String>）。默认空数组。
     */
    public func getIgnoredLanguages(): Array<String> {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_translate_settings")
                    let val = prefs.get("translate_ignored_langs", PreferencesValueType.StringData(""))
                    match (val) {
                        case PreferencesValueType.StringData(s) =>
                            if (s.size == 0) {
                                return Array<String>()
                            }
                            let parts = s.split(",")
                            var result = Array<String>(parts.size, repeat: "")
                            var j: Int64 = 0
                            while (j < parts.size) {
                                result[j] = parts[j]
                                j = j + 1
                            }
                            return result
                        case _ => return Array<String>()
                    }
                } catch (_e: Exception) {
                    return Array<String>()
                }
            case None => return Array<String>()
        }
    }

    private func getIgnoredLanguagesCsv(): String {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_translate_settings")
                    let val = prefs.get("translate_ignored_langs", PreferencesValueType.StringData(""))
                    match (val) {
                        case PreferencesValueType.StringData(value) => return value
                        case _ => return ""
                    }
                } catch (_e: Exception) { return "" }
            case None => return ""
        }
    }

    public func hasExplicitIgnoredLanguages(): Bool {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    return Preferences.getPreferences(ctx, "telegram_translate_settings")
                        .has("translate_ignored_langs")
                } catch (_e: Exception) { return false }
            case None => return false
        }
    }

    /** Restore ignoredLanguages=nil, matching TranslationSettings semantics. */
    public func clearIgnoredLanguages(): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_translate_settings")
                    if (prefs.has("translate_ignored_langs")) {
                        prefs.delete("translate_ignored_langs")
                    }
                    prefs.flush()
                    this.publishSettings()
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[TranslateService] clearIgnoredLanguages error")
                }
            case None => ()
        }
    }

    public func normalizeLanguageCode(code: String): String {
        let raw = if (code.endsWith("-raw")) { code[0..(code.size - 4)] } else { code }
        let parts = raw.split("-")
        let base = if (parts.size > 0) { parts[0] } else { raw }
        return if (base == "nb") { "no" } else { base }
    }

    /** iOS effectiveIgnoredTranslationLanguages: explicit list or interface + system. */
    public func effectiveIgnoredLanguages(): Array<String> {
        if (this.hasExplicitIgnoredLanguages()) {
            return this.getIgnoredLanguages()
        }
        let values = ArrayList<String>()
        let interfaceCode = this.normalizeLanguageCode(getAuthStorage().getLangCode())
        if (interfaceCode.size > 0) { values.add(interfaceCode) }
        let systemCode = this.normalizeLanguageCode(getLanguageSuggestionService().getSystemLocaleCode())
        var exists = false
        for (code in values) { if (code == systemCode) { exists = true } }
        if (!exists && systemCode.size > 0) { values.add(systemCode) }
        let result = Array<String>(values.size, repeat: "")
        var i: Int64 = 0
        while (i < values.size) { result[i] = values[i]; i += 1 }
        return result
    }

    /** Source canTranslateText policy used by the message context menu. */
    public func canTranslateText(text: String): Bool {
        if (!this.getShowTranslateButton()) { return false }
        return this.canTranslateChatText(text)
    }

    /** Language/ignored-list half of canTranslateText, also used by chat translation. */
    public func canTranslateChatText(text: String): Bool {
        if (text.size == 0) { return false }
        let detected = this.normalizeLanguageCode(getLanguageDetectionService().detectLanguage(text))
        var supported = false
        for (language in getSupportedLanguages()) {
            if (this.normalizeLanguageCode(language.code) == detected) { supported = true; break }
        }
        if (!supported) { return false }
        for (ignored in this.effectiveIgnoredLanguages()) {
            if (this.normalizeLanguageCode(ignored) == detected) { return false }
        }
        return true
    }

    /**
     * 解析 messages.translateText 响应
     *
     * 响应格式 messages.translateText (constructor 0x33db32f8):
     *   result: Vector<TextWithEntities>
     *
     * TextWithEntities:
     *   #dcf071ef text:string entities:Vector<MessageEntity>
     */
    private func parseTranslateResponse(data: Array<Byte>, toLang: String): TranslateResult {
        let result = TranslateResult()
        result.toLang = toLang
        try {
            let des = TLDeserializer(data)
            let constructorId = des.readUInt32()
            // messages.translateText#33db32f8
            if (constructorId == 0x33db32f8) {
                // read vector of TextWithEntities
                let vecCtor = des.readUInt32()  // 0x1cb5c415 (Vector)
                if (vecCtor == 0x1cb5c415) {
                    let count = des.readInt32()
                    if (count > 0) {
                        // TextWithEntities#dcf071ef text:string entities:Vector<MessageEntity>
                        let tweCtor = des.readUInt32()
                        if (tweCtor == 0xdcf071ef) {
                            let text = des.readString()
                            result.success = true
                            result.translatedText = text
                            return result
                        }
                    }
                }
            }
            // rpc_error — translation not available
            result.success = false
            result.errorMessage = "Translation unavailable"
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[TranslateService] parseTranslateResponse error")
            result.success = false
            result.errorMessage = "Parse error"
        }
        return result
    }
}

// ==================== TL 方法：messages.translateText (peer mode) ====================

/**
 * messages.translateText#a5eec345
 * flags:# peer:flags.0?InputPeer id:flags.0?Vector<int> text:flags.1?Vector<TextWithEntities> to_lang:string
 *
 * 通过 peer + msgId 翻译消息
 * flags bit 0: peer + id 模式
 */
public class MessagesTranslateText <: TLObject {
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var peerType: String = "user"
    public var msgId: Int32 = 0
    public var toLang: String = "en"

    public func getConstructorId(): UInt32 { return 0xa5eec345 }

    public func serialize(serializer: TLSerializer) {
        // flags bit 0 = peer+id present
        let flags: Int32 = 1
        serializer.writeInt32(flags)

        // peer (flags.0): InputPeer
        if (peerType == "channel") {
            serializer.writeUInt32(0x27bcbbfc)  // inputPeerChannel
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        } else if (peerType == "chat") {
            serializer.writeUInt32(0x35a95cb9)  // inputPeerChat
            serializer.writeInt64(this.peerId)
        } else {
            serializer.writeUInt32(0xdde8a54c)  // inputPeerUser
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        }

        // id (flags.0): Vector<int> with single msgId
        serializer.writeUInt32(0x1cb5c415)  // Vector constructor
        serializer.writeInt32(1)             // count = 1
        serializer.writeInt32(this.msgId)

        // to_lang: string
        serializer.writeString(this.toLang)
    }
}

// ==================== TL 方法：messages.translateText (text mode) ====================

/**
 * messages.translateText#a5eec345 (text mode)
 * flags bit 1 = text vector mode (no peer/id)
 *
 * TextWithEntities#dcf071ef text:string entities:Vector<MessageEntity>
 */
public class MessagesTranslateTextRaw <: TLObject {
    public var text: String = ""
    public var toLang: String = "en"

    public func getConstructorId(): UInt32 { return 0xa5eec345 }

    public func serialize(serializer: TLSerializer) {
        // flags bit 1 = text vector mode
        let flags: Int32 = 2
        serializer.writeInt32(flags)

        // text (flags.1): Vector<TextWithEntities>
        serializer.writeUInt32(0x1cb5c415)  // Vector constructor
        serializer.writeInt32(1)             // count = 1
        // TextWithEntities#dcf071ef
        serializer.writeUInt32(0xdcf071ef)
        serializer.writeString(this.text)
        // entities: empty vector
        serializer.writeUInt32(0x1cb5c415)
        serializer.writeInt32(0)

        // to_lang: string
        serializer.writeString(this.toLang)
    }
}

// ==================== 全局访问 ====================

private var _translateServiceInstance: Option<TranslateService> = None

public func getTranslateService(): TranslateService {
    match (_translateServiceInstance) {
        case Some(svc) => return svc
        case None =>
            let svc = TranslateService()
            _translateServiceInstance = Some(svc)
            return svc
    }
}

public func currentTranslationSettings(): TranslationSettingsSnapshot {
    return getTranslateService().settingsSnapshot()
}

// ==================== 支持的语言列表 ====================

public class TranslateLanguage {
    public var code: String = ""
    public var name: String = ""

    public init() {}

    public init(langCode: String, langName: String) {
        this.code = langCode
        this.name = langName
    }
}

/**
 * iOS 对齐的 104 条翻译目标语言列表（来自 TranslateUI/Sources/Translate.swift supportedTranslationLanguages）
 */
public func getSupportedLanguages(): ArrayList<TranslateLanguage> {
    let langs = ArrayList<TranslateLanguage>()
    langs.add(TranslateLanguage("af", "Afrikaans"))
    langs.add(TranslateLanguage("sq", "Albanian"))
    langs.add(TranslateLanguage("am", "Amharic"))
    langs.add(TranslateLanguage("ar", "Arabic"))
    langs.add(TranslateLanguage("hy", "Armenian"))
    langs.add(TranslateLanguage("az", "Azerbaijani"))
    langs.add(TranslateLanguage("eu", "Basque"))
    langs.add(TranslateLanguage("be", "Belarusian"))
    langs.add(TranslateLanguage("bn", "Bengali"))
    langs.add(TranslateLanguage("bs", "Bosnian"))
    langs.add(TranslateLanguage("bg", "Bulgarian"))
    langs.add(TranslateLanguage("ca", "Catalan"))
    langs.add(TranslateLanguage("ceb", "Cebuano"))
    langs.add(TranslateLanguage("zh", "Chinese (Simplified)"))
    langs.add(TranslateLanguage("co", "Corsican"))
    langs.add(TranslateLanguage("hr", "Croatian"))
    langs.add(TranslateLanguage("cs", "Czech"))
    langs.add(TranslateLanguage("da", "Danish"))
    langs.add(TranslateLanguage("nl", "Dutch"))
    langs.add(TranslateLanguage("en", "English"))
    langs.add(TranslateLanguage("eo", "Esperanto"))
    langs.add(TranslateLanguage("et", "Estonian"))
    langs.add(TranslateLanguage("fi", "Finnish"))
    langs.add(TranslateLanguage("fr", "French"))
    langs.add(TranslateLanguage("fy", "Frisian"))
    langs.add(TranslateLanguage("gl", "Galician"))
    langs.add(TranslateLanguage("ka", "Georgian"))
    langs.add(TranslateLanguage("de", "German"))
    langs.add(TranslateLanguage("el", "Greek"))
    langs.add(TranslateLanguage("gu", "Gujarati"))
    langs.add(TranslateLanguage("ht", "Haitian Creole"))
    langs.add(TranslateLanguage("ha", "Hausa"))
    langs.add(TranslateLanguage("haw", "Hawaiian"))
    langs.add(TranslateLanguage("he", "Hebrew"))
    langs.add(TranslateLanguage("hi", "Hindi"))
    langs.add(TranslateLanguage("hmn", "Hmong"))
    langs.add(TranslateLanguage("hu", "Hungarian"))
    langs.add(TranslateLanguage("is", "Icelandic"))
    langs.add(TranslateLanguage("ig", "Igbo"))
    langs.add(TranslateLanguage("id", "Indonesian"))
    langs.add(TranslateLanguage("ga", "Irish"))
    langs.add(TranslateLanguage("it", "Italian"))
    langs.add(TranslateLanguage("ja", "Japanese"))
    langs.add(TranslateLanguage("jv", "Javanese"))
    langs.add(TranslateLanguage("kn", "Kannada"))
    langs.add(TranslateLanguage("kk", "Kazakh"))
    langs.add(TranslateLanguage("km", "Khmer"))
    langs.add(TranslateLanguage("rw", "Kinyarwanda"))
    langs.add(TranslateLanguage("ko", "Korean"))
    langs.add(TranslateLanguage("ku", "Kurdish"))
    langs.add(TranslateLanguage("ky", "Kyrgyz"))
    langs.add(TranslateLanguage("lo", "Lao"))
    langs.add(TranslateLanguage("lv", "Latvian"))
    langs.add(TranslateLanguage("lt", "Lithuanian"))
    langs.add(TranslateLanguage("lb", "Luxembourgish"))
    langs.add(TranslateLanguage("mk", "Macedonian"))
    langs.add(TranslateLanguage("mg", "Malagasy"))
    langs.add(TranslateLanguage("ms", "Malay"))
    langs.add(TranslateLanguage("ml", "Malayalam"))
    langs.add(TranslateLanguage("mt", "Maltese"))
    langs.add(TranslateLanguage("mi", "Maori"))
    langs.add(TranslateLanguage("mr", "Marathi"))
    langs.add(TranslateLanguage("mn", "Mongolian"))
    langs.add(TranslateLanguage("my", "Myanmar (Burmese)"))
    langs.add(TranslateLanguage("ne", "Nepali"))
    langs.add(TranslateLanguage("no", "Norwegian"))
    langs.add(TranslateLanguage("ny", "Nyanja (Chichewa)"))
    langs.add(TranslateLanguage("or", "Odia (Oriya)"))
    langs.add(TranslateLanguage("ps", "Pashto"))
    langs.add(TranslateLanguage("fa", "Persian"))
    langs.add(TranslateLanguage("pl", "Polish"))
    langs.add(TranslateLanguage("pt", "Portuguese"))
    langs.add(TranslateLanguage("pt-BR", "Portuguese (Brazil)"))
    langs.add(TranslateLanguage("pa", "Punjabi"))
    langs.add(TranslateLanguage("ro", "Romanian"))
    langs.add(TranslateLanguage("ru", "Russian"))
    langs.add(TranslateLanguage("sm", "Samoan"))
    langs.add(TranslateLanguage("gd", "Scots Gaelic"))
    langs.add(TranslateLanguage("sr", "Serbian"))
    langs.add(TranslateLanguage("st", "Sesotho"))
    langs.add(TranslateLanguage("sn", "Shona"))
    langs.add(TranslateLanguage("sd", "Sindhi"))
    langs.add(TranslateLanguage("si", "Sinhala (Sinhalese)"))
    langs.add(TranslateLanguage("sk", "Slovak"))
    langs.add(TranslateLanguage("sl", "Slovenian"))
    langs.add(TranslateLanguage("so", "Somali"))
    langs.add(TranslateLanguage("es", "Spanish"))
    langs.add(TranslateLanguage("su", "Sundanese"))
    langs.add(TranslateLanguage("sw", "Swahili"))
    langs.add(TranslateLanguage("sv", "Swedish"))
    langs.add(TranslateLanguage("tl", "Tagalog (Filipino)"))
    langs.add(TranslateLanguage("tg", "Tajik"))
    langs.add(TranslateLanguage("ta", "Tamil"))
    langs.add(TranslateLanguage("tt", "Tatar"))
    langs.add(TranslateLanguage("te", "Telugu"))
    langs.add(TranslateLanguage("th", "Thai"))
    langs.add(TranslateLanguage("tr", "Turkish"))
    langs.add(TranslateLanguage("tk", "Turkmen"))
    langs.add(TranslateLanguage("uk", "Ukrainian"))
    langs.add(TranslateLanguage("ur", "Urdu"))
    langs.add(TranslateLanguage("ug", "Uyghur"))
    langs.add(TranslateLanguage("uz", "Uzbek"))
    langs.add(TranslateLanguage("vi", "Vietnamese"))
    langs.add(TranslateLanguage("cy", "Welsh"))
    langs.add(TranslateLanguage("xh", "Xhosa"))
    langs.add(TranslateLanguage("yi", "Yiddish"))
    langs.add(TranslateLanguage("yo", "Yoruba"))
    langs.add(TranslateLanguage("zu", "Zulu"))
    return langs
}

/**
 * iOS 对齐的 12 条热门翻译语言（来自 TranslateUI/Sources/Translate.swift popularTranslationLanguages）
 * 用于 LanguageSelectionPageArguments 置顶显示
 */
public func getPopularLanguages(): ArrayList<TranslateLanguage> {
    let popular = ArrayList<TranslateLanguage>()
    popular.add(TranslateLanguage("en", "English"))
    popular.add(TranslateLanguage("ar", "Arabic"))
    popular.add(TranslateLanguage("zh", "Chinese (Simplified)"))
    popular.add(TranslateLanguage("fr", "French"))
    popular.add(TranslateLanguage("de", "German"))
    popular.add(TranslateLanguage("it", "Italian"))
    popular.add(TranslateLanguage("ja", "Japanese"))
    popular.add(TranslateLanguage("ko", "Korean"))
    popular.add(TranslateLanguage("pt-BR", "Portuguese (Brazil)"))
    popular.add(TranslateLanguage("ru", "Russian"))
    popular.add(TranslateLanguage("es", "Spanish"))
    popular.add(TranslateLanguage("uk", "Ukrainian"))
    return popular
}

// ==================== P2-399: 全局选中翻译语言状态 ====================
// 从 LanguageSelectionPageArguments 移至 TranslateService 保持单一包归属
// ChatRoomPage / MessageBubble 等消费方通过 services.* import 访问

private var _selectedTranslateLang: String = "en"

/**
 * 获取当前选中的翻译目标语言代码（默认 "en"）
 */
public func getSelectedTranslateLang(): String {
    return _selectedTranslateLang
}

/**
 * 设置翻译目标语言代码（由 LanguageSelectionPageArguments 在用户选择后调用）
 */
public func setSelectedTranslateLang(lang: String): Unit {
    _selectedTranslateLang = lang
}

// ==================== P2-398: ChatTranslationState（per-peer 整聊天翻译状态） ====================

/**
 * 整聊天翻译状态（对应 iOS ChatTranslationState）
 *
 * iOS 字段映射：
 *   baseLang    → 用户 UI 语言（检测用，持久化用字符串）
 *   fromLang    → 聊天消息检测到的语言
 *   toLang      → 翻译目标语言（可选，nil 时用全局 selectedTranslateLang）
 *   isEnabled   → 翻译条是否开启（用户点击 "Translate" 后为 true）
 */
public class ChatTranslationState {
    public var fromLang: String = ""
    public var toLang: String = ""
    public var isEnabled: Bool = false

    public init() {}

}

/**
 * 保存 per-peer 整聊天翻译状态（Preferences / UIAbilityContext，S-012 合规）
 * Store: "telegram_chat_translation_state"
 * Keys:
 *   "chat_trans_enabled_<peerId>"  → Bool
 *   "chat_trans_fromlang_<peerId>" → String
 *   "chat_trans_tolang_<peerId>"   → String
 */
public func saveChatTranslationState(peerId: Int64, state: ChatTranslationState): Unit {
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, "telegram_chat_translation_state")
                let key = peerId.toString()
                prefs.put("chat_trans_enabled_" + key, PreferencesValueType.BoolData(state.isEnabled))
                prefs.put("chat_trans_fromlang_" + key, PreferencesValueType.StringData(state.fromLang))
                prefs.put("chat_trans_tolang_" + key, PreferencesValueType.StringData(state.toLang))
                prefs.flush()
                Hilog.info(0, "CjTelegram", "[TranslateService] saveChatTranslationState peerId=${peerId} isEnabled=${state.isEnabled}")
            } catch (_e: Exception) {
                Hilog.info(0, "CjTelegram", "[TranslateService] saveChatTranslationState error")
            }
        case None => ()
    }
}

/**
 * 读取 per-peer 整聊天翻译状态。若未保存，返回 isEnabled=false。
 */
public func loadChatTranslationState(peerId: Int64): ChatTranslationState {
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, "telegram_chat_translation_state")
                let key = peerId.toString()
                let enabledVal = prefs.get("chat_trans_enabled_" + key, PreferencesValueType.BoolData(false))
                let fromLangVal = prefs.get("chat_trans_fromlang_" + key, PreferencesValueType.StringData(""))
                let toLangVal = prefs.get("chat_trans_tolang_" + key, PreferencesValueType.StringData(""))
                let enabled = match (enabledVal) {
                    case PreferencesValueType.BoolData(b) => b
                    case _ => false
                }
                let fromLang = match (fromLangVal) {
                    case PreferencesValueType.StringData(s) => s
                    case _ => ""
                }
                let toLang = match (toLangVal) {
                    case PreferencesValueType.StringData(s) => s
                    case _ => ""
                }
                let st = ChatTranslationState()
                st.fromLang = fromLang
                st.toLang = toLang
                st.isEnabled = enabled
                return st
            } catch (_e: Exception) {
                return ChatTranslationState()
            }
        case None => return ChatTranslationState()
    }
}

// ==================== P2-398: messages.togglePeerTranslations TL wire ====================

/**
 * messages.togglePeerTranslations#e47cb579
 * flags:# disabled:flags.0?true peer:InputPeer = Bool
 *
 * iOS iOS ref: `Api.functions.messages.togglePeerTranslations(flags:, peer:)`
 *   buffer.appendInt32(-461589127)  → 0xe47cb579
 *   flags bit 0: disabled=true（隐藏翻译）; flags=0: enabled（显示翻译）
 *
 * Cangjie 对齐：当 hide=true 时 flags=1，否则 flags=0
 */
public class MessagesTogglePeerTranslations <: TLObject {
    public var hide: Bool = false
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var peerType: String = "user"

    public func getConstructorId(): UInt32 { return 0xe47cb579 }

    public func serialize(serializer: TLSerializer) {
        // flags bit 0 = disabled (hidden)
        let flags: Int32 = if (this.hide) { 1 } else { 0 }
        serializer.writeInt32(flags)

        // peer: InputPeer
        if (peerType == "channel") {
            serializer.writeUInt32(0x27bcbbfc)  // inputPeerChannel
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        } else if (peerType == "chat") {
            serializer.writeUInt32(0x35a95cb9)  // inputPeerChat
            serializer.writeInt64(this.peerId)
        } else {
            serializer.writeUInt32(0xdde8a54c)  // inputPeerUser
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        }
    }
}

/**
 * 发送 messages.togglePeerTranslations，通知服务端启用/禁用该 peer 翻译
 * iOS: _internal_togglePeerMessagesTranslationHidden(account:peerId:hidden:)
 *
 * @param peerId     对话 ID
 * @param peerAccessHash  accessHash
 * @param peerType   "user" | "chat" | "channel"
 * @param hide       true=禁用翻译（iOS hidden=true）; false=启用翻译
 */
public func togglePeerTranslations(
    peerId: Int64,
    peerAccessHash: Int64,
    peerType: String,
    hide: Bool
): Unit {
    spawn {
        let client = getMTProtoClient()
        let req = MessagesTogglePeerTranslations()
        req.hide = hide
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        req.peerType = peerType
        try {
            let _resp = client.sendRequest(req.toBytes())
            Hilog.info(0, "CjTelegram", "[TranslateService] togglePeerTranslations peerId=${peerId} hide=${hide} sent")
        } catch (_e: Exception) {
            Hilog.info(0, "CjTelegram", "[TranslateService] togglePeerTranslations error")
        }
    }
}

/**
 * P2-398: 批量翻译聊天内所有消息（自动翻译模式）
 * 对每条消息逐条调用 translateMessage（复用 P2-397 路径）
 * 结果通过回调 onResult(msgId, translatedText) 异步返回（在调用方 launch{} 中更新 @State）
 *
 * @param msgIds         要翻译的消息 ID 列表
 * @param peerId         对话 ID
 * @param peerAccessHash accessHash
 * @param peerType       "user"|"chat"|"channel"
 * @param toLang         目标语言代码
 * @param onResult       每条翻译成功后的回调 (msgId: Int64, text: String)
 */
public func translateAllMessages(
    msgIds: ArrayList<Int64>,
    peerId: Int64,
    peerAccessHash: Int64,
    peerType: String,
    toLang: String,
    onResult: (Int64, String) -> Unit
): Unit {
    let svc = getTranslateService()
    let capturedPeerId = peerId
    let capturedHash = peerAccessHash
    let capturedType = peerType
    let capturedLang = toLang
    spawn {
        var i: Int64 = 0
        while (i < msgIds.size) {
            let mid = msgIds[i]
            let result = svc.translateMessage(
                capturedPeerId,
                capturedHash,
                capturedType,
                Int32(mid),
                capturedLang
            )
            if (result.success && result.translatedText.size > 0) {
                let capturedMid = mid
                let capturedText = result.translatedText
                onResult(capturedMid, capturedText)
            }
            i = i + 1
        }
        Hilog.info(0, "CjTelegram", "[TranslateService] translateAllMessages done, count=${msgIds.size}")
    }
}
