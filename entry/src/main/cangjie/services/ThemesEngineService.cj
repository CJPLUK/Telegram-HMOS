package ohos_app_cangjie_entry.services

import kit.ArkData.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.convert.*
import std.sync.*
import std.time.*
import ohos.settings.{getValue as settingsGetValue, Display as SettingsDisplay}
import ohos_app_cangjie_entry.core.storage.{getAppTheme, recomputePresentation, COLOR_MODE_DARK,
    PresentationExtras, registerPresentationExtrasProvider, CloudThemeColorSettings}
import ohos_app_cangjie_entry.core.mtproto.{
    TLObject,
    getMTProtoClient,
    AccountGetThemes,
    AccountGetChatThemes,
    AccountCreateTheme,
    AccountUploadTheme,
    AccountSaveTheme,
    AccountInstallTheme,
    InputThemeSlug,
    BaseThemeClassic,
    BaseThemeDay,
    BaseThemeNight,
    BaseThemeTinted,
    BaseThemeArctic,
    InputThemeSettings,
    InputDocument,
    TLDeserializer,
    TLConstructors,
    parseAccountThemesResponse,
    TLThemeInfo,
    TLThemeSettingsEntry,
    InputPeerUser,
    InputPeerChat,
    InputPeerChannel,
    InputPeerEmpty,
    InputWallPaperById,
    WallPaperSettings,
    MessagesSetChatWallPaper,
    MessagesSetChatTheme
}

/**
 * 主题条目（从 TL 层解析后对外暴露）
 *
 * diag-suite_settings_root-TC-0507-round5.md §4.5 RC-5 F-B1：`emoticon`/`settings` 系列字段此前
 * 在 getThemes()/getChatThemes() 的映射层被丢弃（TL 层 `TLThemeInfo`，core/mtproto/TLResponses.cj
 * :3868-3882，已正确解出这些值）。字段名与类型逐一对齐 `TLThemeInfo`，不新造命名——下游消费方
 * （如 pages/ChatThemesPage.cj:211-212、pages/ChatQrCodeSharePage.cj 的构格过滤）按同一字段名读取。
 * `hasSettings`/`hasWallpaper` 是显式存在位（对位 TLThemeInfo 的同名字段，这两个 TL flags 位可能
 * 为假），不得用空字符串/0 反推是否有值。
 *
 * ic_theme_item_emoticon_settings_fields（net_telegram_api 2026-09-04 就地扩展）：TLResponses.cj
 * 新增 settingsOutboxAccentColor/settingsMessageColors/wallpaperColors 三个调色板字段（TLThemeInfo，
 * core/mtproto/TLResponses.cj:3879-3891），此前两处映射循环没有跟进——这里补上，同样是纯字段直通，
 * 不排序、不去重、不做默认值推断。
 */
public class ThemeItem {
    public var id: Int64 = 0
    public var accessHash: Int64 = 0
    public var slug: String = ""
    public var title: String = ""
    public var isDefault: Bool = false
    public var isCreator: Bool = false
    // TC-0507 round5 F-B1 起新增，逐一对齐 TLThemeInfo（core/mtproto/TLResponses.cj:3868-3882）：
    public var emoticon: String = ""
    public var hasSettings: Bool = false
    public var settingsBaseTheme: String = ""
    public var settingsAccentColor: Int32 = 0
    public var hasWallpaper: Bool = false
    public var wallpaperId: Int64 = 0
    public var wallpaperSlug: String = ""
    // ic_theme_item_emoticon_settings_fields 就地扩展新增，逐一对齐 TLThemeInfo:3879-3891：
    public var settingsOutboxAccentColor: Int32 = 0
    public var settingsMessageColors: Array<UInt32> = Array<UInt32>()
    public var wallpaperColors: Array<UInt32> = Array<UInt32>()
    // wallpaperIntensity：settingsVariants[0] 的镜像，与上面几个单值字段同规则（诊断报告
    // TC-0507-round7 F-B2）。
    public var wallpaperIntensity: Int32 = 0
    public var wallpaperHasIntensity: Bool = false
    // settingsVariants：TLThemeInfo.settingsEntries 的纯直通（同一 ArrayList<TLThemeSettingsEntry>
    // 类型，不做 Array 转换），携带该主题全部 ThemeSettings 元素（通常日/夜两档），字段名逐一对齐
    // TLThemeSettingsEntry，不新造命名。选哪一档（按 isDarkAppearance 匹配 baseTheme）交给消费方决定，
    // 本层不做选择、不做过滤（诊断报告 TC-0507-round7 F-B2/F-B3）。
    public var settingsVariants: ArrayList<TLThemeSettingsEntry> = ArrayList<TLThemeSettingsEntry>()
}

/**
 * 主题列表结果
 */
public class ThemesResult {
    public var hash: Int64 = 0
    public var themes: ArrayList<ThemeItem> = ArrayList<ThemeItem>()
    public var notModified: Bool = false
}

public class CreateThemeResponse {
    public var success: Bool = false
    public var errorMessage: String = ""
}

/**
 * 壁纸条目（Themes 层对 WallpaperItem 的简化视图）
 * 对应 iOS TelegramEngine.Themes.wallpapers() 返回条目
 */
public class WallPaperEntry {
    public var id: Int64 = 0
    public var accessHash: Int64 = 0
    public var slug: String = ""
    public var hasDocument: Bool = false
    public var isDefault: Bool = false
    public var isPattern: Bool = false
}

/**
 * 壁纸列表结果
 * 对应 iOS account.WallPapers — wallPapers#cdc3858c / wallPapersNotModified#1c199183
 */
public class WallPapersResult {
    public var hash: Int64 = 0
    public var wallpapers: ArrayList<WallPaperEntry> = ArrayList<WallPaperEntry>()
    public var notModified: Bool = false
    public var success: Bool = false
}

/**
 * ThemesEngineService — 主题引擎服务
 *
 * 对应 iOS TelegramEngine.Themes
 * 通过 MTProto TL 方法真实访问 Telegram 云端主题/壁纸 API：
 *   - account.getThemes          → 获取所有主题列表
 *   - account.getChatThemes      → 获取聊天主题列表
 *   - account.saveTheme          → 保存/取消收藏主题
 *   - account.installTheme       → 安装（应用）主题
 *   - account.getWallPapers      → 获取云端壁纸列表（hash 增量）
 *   - messages.setChatWallPaper  → 设置/复用/还原聊天壁纸
 *   - messages.setChatTheme      → 设置聊天主题 emoticon
 *
 * wallpapers hash 缓存：
 *   内存缓存保存于 _wallpapersHash（进程生命周期内有效）。
 *   持久化缓存存储到 Preferences("telegram_themes_cache") key="wallpapers_hash"。
 *   登出时由 AuthStorage.clearAll() 清理 telegram_themes_cache store。
 */
public class ThemesEngineService {
    /** 内存 hash 缓存（wallpapers 增量请求） */
    private var _wallpapersHash: Int64 = 0
    /** TC-0402 F3: auto-night 1 秒重复求值定时器；见 startAutoNightTimer/stopAutoNightTimer。 */
    private var _autoNightTimer: Option<Timer> = None
    private let _autoNightTimerMutex = ReentrantMutex()

    /**
     * 获取所有云端主题列表
     * 对应 account.getThemes#7206e458 flags:# format:flags.0?string hash:long
     * @param format 主题格式（如 "android"），None 则不传 format 参数
     * @param hash   缓存 hash，0 表示强制刷新
     */
    public func getThemes(format: Option<String>, hash: Int64): ThemesResult {
        let result = ThemesResult()
        result.hash = hash
        try {
            let req = AccountGetThemes()
            req.format = format
            req.hash = hash
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size > 4) {
                let (modified, newHash, tlThemes) = parseAccountThemesResponse(responseData)
                if (!modified) {
                    result.notModified = true
                } else {
                    result.hash = newHash
                    for (t in tlThemes) {
                        let item = ThemeItem()
                        item.id = t.id
                        item.accessHash = t.accessHash
                        item.slug = t.slug
                        item.title = t.title
                        item.isDefault = t.isDefault
                        item.isCreator = t.isCreator
                        // F-B2：纯字段直通，不加过滤、不做默认值推断（过滤规则属页面侧）。
                        item.emoticon = t.emoticon
                        item.hasSettings = t.hasSettings
                        item.settingsBaseTheme = t.settingsBaseTheme
                        item.settingsAccentColor = t.settingsAccentColor
                        item.hasWallpaper = t.hasWallpaper
                        item.wallpaperId = t.wallpaperId
                        item.wallpaperSlug = t.wallpaperSlug
                        // ic_theme_item_emoticon_settings_fields 就地扩展：三个调色板字段同样纯直通。
                        item.settingsOutboxAccentColor = t.settingsOutboxAccentColor
                        item.settingsMessageColors = t.settingsMessageColors
                        item.wallpaperColors = t.wallpaperColors
                        // TC-0507-round7 F-B2：intensity 镜像 + 全部 settings 元素纯直通，不做选择。
                        item.wallpaperIntensity = t.wallpaperIntensity
                        item.wallpaperHasIntensity = t.wallpaperHasIntensity
                        item.settingsVariants = t.settingsEntries
                        result.themes.add(item)
                    }
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ThemesEngineService] getThemes error")
        }
        return result
    }

    /**
     * 获取聊天主题列表
     * 对应 account.getChatThemes#d638de89 hash:long
     * @param hash 缓存 hash，0 表示强制刷新
     */
    public func getChatThemes(hash: Int64): ThemesResult {
        let result = ThemesResult()
        result.hash = hash
        try {
            let req = AccountGetChatThemes()
            req.hash = hash
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size > 4) {
                let (modified, newHash, tlThemes) = parseAccountThemesResponse(responseData)
                if (!modified) {
                    result.notModified = true
                } else {
                    result.hash = newHash
                    for (t in tlThemes) {
                        let item = ThemeItem()
                        item.id = t.id
                        item.accessHash = t.accessHash
                        item.slug = t.slug
                        item.title = t.title
                        item.isDefault = t.isDefault
                        item.isCreator = t.isCreator
                        // F-B2 (diag TC-0507-round5 §4.5 RC-5)：TL 层已经解出 emoticon/settings
                        // （TLThemeInfo，core/mtproto/TLResponses.cj:3963-4018），此前在这里被丢弃，
                        // 导致 B5a/A4b/B5c 拿不到每主题壁纸/色板、emoji 只能从 title 抠首字符。
                        // 纯字段直通，不加过滤、不做默认值推断（构格过滤属页面侧，见 F-C5）。
                        item.emoticon = t.emoticon
                        item.hasSettings = t.hasSettings
                        item.settingsBaseTheme = t.settingsBaseTheme
                        item.settingsAccentColor = t.settingsAccentColor
                        item.hasWallpaper = t.hasWallpaper
                        item.wallpaperId = t.wallpaperId
                        item.wallpaperSlug = t.wallpaperSlug
                        // ic_theme_item_emoticon_settings_fields 就地扩展：三个调色板字段同样纯直通。
                        item.settingsOutboxAccentColor = t.settingsOutboxAccentColor
                        item.settingsMessageColors = t.settingsMessageColors
                        item.wallpaperColors = t.wallpaperColors
                        // TC-0507-round7 F-B2：intensity 镜像 + 全部 settings 元素纯直通，不做选择。
                        item.wallpaperIntensity = t.wallpaperIntensity
                        item.wallpaperHasIntensity = t.wallpaperHasIntensity
                        item.settingsVariants = t.settingsEntries
                        result.themes.add(item)
                    }
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ThemesEngineService] getChatThemes error")
        }
        return result
    }

    /**
     * 以当前 Appearance 的真实主题设置创建云主题。
     * 对位 TelegramCore/Themes.swift createTheme(resource:nil, settings:[...])：请求携带
     * account.createTheme 的 settings 分支，成功响应必须是 Theme#a00e67d6。
     */
    private func currentInputThemeSettings(): InputThemeSettings {
        let settings = InputThemeSettings()
        let preset = this.getThemePreset()
        if (preset == 1) { settings.baseTheme = BaseThemeTinted() }
        else if (preset == 2) { settings.baseTheme = BaseThemeDay() }
        else if (preset == 3) { settings.baseTheme = BaseThemeNight() }
        else { settings.baseTheme = BaseThemeClassic() }
        settings.accentColor = this.getAccentColor() & 0x00FFFFFF
        let bubbleColor = this.getCustomBubbleColor() & 0x00FFFFFF
        if (bubbleColor != 0) { settings.messageColors = [bubbleColor] }
        settings.animateMessageColors = this.getAnimateMessageColors()
        return settings
    }

    private func parseCreateThemeResponse(responseData: Array<Byte>): CreateThemeResponse {
        let result = CreateThemeResponse()
        if (responseData.size < 4) {
            result.errorMessage = "Empty server response"
            return result
        }
        let decoder = TLDeserializer(responseData)
        let constructor = decoder.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let _ = decoder.readInt32()
            result.errorMessage = decoder.readString()
            return result
        }
        if (constructor != 0xa00e67d6) {
            result.errorMessage = "Unexpected theme response"
            return result
        }
        result.success = true
        return result
    }

    public func createThemeFromCurrentSettings(title: String): CreateThemeResponse {
        try {
            let request = AccountCreateTheme()
            request.title = title
            request.settings = [this.currentInputThemeSettings()]
            return this.parseCreateThemeResponse(getMTProtoClient().sendRequest(request.toBytes()))
        } catch (e: Exception) {
            let result = CreateThemeResponse()
            result.errorMessage = e.toString()
            return result
        }
    }

    /** Upload a user-selected .tgios-theme document and create the cloud theme from it. */
    public func createThemeFromFile(title: String, data: Array<Byte>, fileName: String): CreateThemeResponse {
        let failure = CreateThemeResponse()
        if (data.size == 0) {
            failure.errorMessage = "The selected theme file is empty"
            return failure
        }
        try {
            let inputFile = getFileUploadService().uploadFile(data, fileName)
            match (inputFile) {
                case None =>
                    failure.errorMessage = "Unable to upload theme file"
                    return failure
                case Some(file) =>
                    let upload = AccountUploadTheme()
                    upload.file = file
                    upload.fileName = fileName
                    let uploadedData = getMTProtoClient().sendRequest(upload.toBytes())
                    if (uploadedData.size < 4) {
                        failure.errorMessage = "Empty upload response"
                        return failure
                    }
                    let decoder = TLDeserializer(uploadedData)
                    let constructor = decoder.readUInt32()
                    if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
                        let _ = decoder.readInt32()
                        failure.errorMessage = decoder.readString()
                        return failure
                    }
                    if (constructor != 0x8fd4c4d8) {
                        failure.errorMessage = "Unexpected uploaded document response"
                        return failure
                    }
                    let _ = decoder.readInt32()
                    let document = InputDocument()
                    document.id = decoder.readInt64()
                    document.accessHash = decoder.readInt64()
                    document.fileReference = decoder.readBytes()

                    let create = AccountCreateTheme()
                    create.title = title
                    create.document = Some(document)
                    create.settings = [this.currentInputThemeSettings()]
                    return this.parseCreateThemeResponse(getMTProtoClient().sendRequest(create.toBytes()))
            }
        } catch (e: Exception) {
            failure.errorMessage = e.toString()
            return failure
        }
    }

    /**
     * 保存（收藏）或取消收藏一个云端主题
     * 对应 account.saveTheme#f257106c flags:# unsave:flags.0?true theme:InputTheme
     * @param slug   主题的 URL slug（如 "aurora"）
     * @param unsave true 表示取消收藏
     * @return 操作是否成功
     */
    public func saveTheme(slug: String, unsave: Bool): Bool {
        try {
            let inputTheme = InputThemeSlug()
            inputTheme.slug = slug
            let req = AccountSaveTheme()
            req.theme = inputTheme
            req.unsave = unsave
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size >= 4) {
                // Bool: boolTrue#997275b5 / boolFalse#bc799737
                let b0 = UInt32(responseData[0])
                let b1 = UInt32(responseData[1])
                let b2 = UInt32(responseData[2])
                let b3 = UInt32(responseData[3])
                let ctor = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
                return ctor == 0x997275b5
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ThemesEngineService] saveTheme error")
        }
        return false
    }

    /**
     * 安装（应用）主题
     * 对应 account.installTheme#7ae43737 flags:# dark:flags.0?true theme:flags.1?InputTheme format:flags.2?string base_theme:flags.3?BaseTheme
     * @param dark      true=深色模式, false=浅色模式
     * @param slug      主题 slug（None 表示恢复系统默认）
     * @param format    主题格式（None 表示不指定）
     * @param baseThemeId  BaseTheme 编号：0=Classic 1=Day 2=Night 3=Tinted 4=Arctic（None 表示不指定）
     * @return 操作是否成功
     */
    public func installTheme(dark: Bool, slug: Option<String>, format: Option<String>, baseThemeId: Option<Int32>): Bool {
        try {
            let req = AccountInstallTheme()
            req.dark = dark
            match (slug) {
                case Some(s) =>
                    let inputTheme = InputThemeSlug()
                    inputTheme.slug = s
                    req.theme = Some(inputTheme)
                case None => ()
            }
            req.format = format
            match (baseThemeId) {
                case Some(id) =>
                    if (id == 0) {
                        req.baseTheme = Some(BaseThemeClassic())
                    } else if (id == 1) {
                        req.baseTheme = Some(BaseThemeDay())
                    } else if (id == 2) {
                        req.baseTheme = Some(BaseThemeNight())
                    } else if (id == 3) {
                        req.baseTheme = Some(BaseThemeTinted())
                    } else {
                        req.baseTheme = Some(BaseThemeArctic())
                    }
                case None => ()
            }
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size >= 4) {
                let b0 = UInt32(responseData[0])
                let b1 = UInt32(responseData[1])
                let b2 = UInt32(responseData[2])
                let b3 = UInt32(responseData[3])
                let ctor = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
                return ctor == 0x997275b5
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ThemesEngineService] installTheme error")
        }
        return false
    }

    // ==================== 壁纸 ====================

    /**
     * 获取云端壁纸列表（真实 TL 调用，hash 增量）
     * 对应 iOS TelegramEngine.Themes.wallpapers(accountManager:forceUpdate:)
     * TL: account.getWallPapers#07967d36 hash:long = account.WallPapers
     *   account.wallPapers#cdc3858c hash:long wallpapers:Vector<WallPaper>
     *   account.wallPapersNotModified#1c199183
     *
     * hash 缓存：内存 _wallpapersHash（进程内）+ Preferences("telegram_themes_cache")
     *   key="wallpapers_hash"。登出时由 AuthStorage.clearAll() 清理 telegram_themes_cache。
     *
     * @param hash 上次响应 hash（0 = 强制刷新）；传 -1 则使用内存缓存的 _wallpapersHash
     */
    public func getWallPapers(hash: Int64): WallPapersResult {
        let result = WallPapersResult()
        let effectiveHash = if (hash < 0) { this._wallpapersHash } else { hash }
        try {
            let svc = getWallpaperResourcesService()
            let raw = svc.getWallPapers(hash: effectiveHash)
            if (!raw.success) {
                Hilog.info(0, "CjTelegram", "[ThemesEngine] getWallPapers failed: ${raw.errorMessage}")
                return result
            }
            result.success = true
            if (raw.notModified) {
                result.notModified = true
                result.hash = effectiveHash
                return result
            }
            result.hash = raw.hash
            this._wallpapersHash = raw.hash
            this.persistWallpapersHash(raw.hash)
            for (item in raw.items) {
                let entry = WallPaperEntry()
                entry.id = item.id
                entry.accessHash = item.accessHash
                entry.slug = item.slug
                entry.hasDocument = item.hasDocument
                entry.isDefault = item.isDefault
                entry.isPattern = item.isPattern
                result.wallpapers.add(entry)
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ThemesEngine] getWallPapers error: ${e}")
        }
        return result
    }

    // ==================== 聊天壁纸 ====================

    /**
     * 设置聊天壁纸（通过 wallpaper id+accessHash 引用现有壁纸）
     * 对应 iOS messages.setChatWallPaper with InputWallPaper (for_both optional)
     * TL: messages.setChatWallPaper#8ffacae1
     *   flags:# for_both:flags.3?true revert:flags.4?true
     *   peer:InputPeer wallpaper:flags.0?InputWallPaper settings:flags.2?WallPaperSettings
     *   id:flags.1?int = Updates
     *
     * @param peerId      目标对话 ID（user/chat/channel）
     * @param peerType    "user" | "chat" | "channel"
     * @param accessHash  peer accessHash（channel/user 时需要）
     * @param wallpaperId 壁纸 ID
     * @param wallpaperAccessHash 壁纸 accessHash
     * @param forBoth     true = 双端同时设置
     */
    public func setChatWallPaper(peerId: Int64, peerType: String, accessHash: Int64,
                                  wallpaperId: Int64, wallpaperAccessHash: Int64,
                                  forBoth: Bool): Bool {
        try {
            let req = MessagesSetChatWallPaper()
            req.peer = buildInputPeer(peerId, peerType, accessHash)
            req.hasWallpaper = true
            let wp = InputWallPaperById()
            wp.id = wallpaperId
            wp.accessHash = wallpaperAccessHash
            req.wallpaper = wp
            req.forBoth = forBoth
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return responseData.size >= 4
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ThemesEngine] setChatWallPaper error: ${e}")
        }
        return false
    }

    /**
     * 复用最近壁纸（setExisting — 通过消息 id 引用已使用过的壁纸）
     * TL: messages.setChatWallPaper flags with flags.1 set (id field)
     *
     * @param peerId  目标对话 ID
     * @param peerType "user" | "chat" | "channel"
     * @param accessHash peer accessHash
     * @param msgId   含壁纸的消息 ID
     */
    public func setChatWallPaperById(peerId: Int64, peerType: String, accessHash: Int64, msgId: Int32): Bool {
        try {
            let req = MessagesSetChatWallPaper()
            req.peer = buildInputPeer(peerId, peerType, accessHash)
            req.hasId = true
            req.id = msgId
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return responseData.size >= 4
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ThemesEngine] setChatWallPaperById error: ${e}")
        }
        return false
    }

    /**
     * 还原聊天壁纸为默认
     * TL: messages.setChatWallPaper flags.4 (revert=true)，不传 wallpaper/id
     *
     * @param peerId  目标对话 ID
     * @param peerType "user" | "chat" | "channel"
     * @param accessHash peer accessHash
     */
    public func revertChatWallPaper(peerId: Int64, peerType: String, accessHash: Int64): Bool {
        try {
            let req = MessagesSetChatWallPaper()
            req.peer = buildInputPeer(peerId, peerType, accessHash)
            req.revert = true
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return responseData.size >= 4
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ThemesEngine] revertChatWallPaper error: ${e}")
        }
        return false
    }

    // ==================== 聊天主题 ====================

    /**
     * 设置聊天主题
     * 对应 iOS messages.setChatTheme
     * TL: messages.setChatTheme#e63be13f peer:InputPeer emoticon:string = Updates
     *
     * @param peerId    目标对话 ID
     * @param peerType  "user" | "chat" | "channel"
     * @param accessHash peer accessHash（channel/user 需要）
     * @param emoticon  主题表情符号字符串；传空字符串清除主题
     */
    public func setChatTheme(peerId: Int64, peerType: String, accessHash: Int64, emoticon: String): Bool {
        try {
            let req = MessagesSetChatTheme()
            req.peer = buildInputPeer(peerId, peerType, accessHash)
            req.emoticon = emoticon
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            return responseData.size >= 4
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ThemesEngine] setChatTheme error: ${e}")
        }
        return false
    }

    // ==================== 私有辅助 ====================

    /**
     * 根据 peerType 构造 InputPeer
     * peerType: "user" → InputPeerUser, "chat" → InputPeerChat, "channel" → InputPeerChannel
     */
    private func buildInputPeer(peerId: Int64, peerType: String, accessHash: Int64): TLObject {
        if (peerType == "user") {
            let p = InputPeerUser()
            p.userId = peerId
            p.accessHash = accessHash
            return p
        }
        if (peerType == "chat") {
            let p = InputPeerChat()
            p.chatId = peerId
            return p
        }
        if (peerType == "channel") {
            let p = InputPeerChannel()
            p.channelId = peerId
            p.accessHash = accessHash
            return p
        }
        return InputPeerEmpty()
    }

    /**
     * 将 wallpapers hash 持久化到 Preferences
     * store: "telegram_themes_cache", key: "wallpapers_hash"
     * 登出时由 AuthStorage.clearAll() 执行 sp.clear() 清理该 store。
     */
    private func persistWallpapersHash(hash: Int64): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("wallpapers_hash", PreferencesValueType.Integer(hash))
                    prefs.flush()
                } catch (_e: Exception) {}
            case None => ()
        }
    }

    /**
     * 从 Preferences 恢复 wallpapers hash（服务启动时调用）
     */
    public func restoreWallpapersHash(): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("wallpapers_hash", PreferencesValueType.Integer(0))
                    match (val) {
                        case PreferencesValueType.Integer(n) => this._wallpapersHash = n
                        case _ => ()
                    }
                } catch (_e: Exception) {}
            case None => ()
        }
    }

    // ==================== 本地外观: Accent 色 ====================

    /**
     * 保存用户选中的 accent 颜色（十六进制 ARGB）到 Preferences。
     * key: "appearance_accent_color", store: "telegram_themes_cache"
     * 对应 iOS PresentationThemeAccentColor — 本地存储侧。
     *
     * P2-009 架构重建后：不再直接改写 AppTheme 单例字段（该字段已随重建移除，
     * accentColor 现在只活在 PresentationSnapshot 上）。持久化后触发一次
     * recomputePresentation()，accentColor 会在下一次快照里从这里刚写入的值解出
     * （core/storage/AppTheme.cj#recomputePresentation() 的单一入口）。
     */
    public func saveAccentColor(colorHex: UInt32): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("appearance_accent_color", PreferencesValueType.Integer(Int64(colorHex)))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveAccentColor: 0x${colorHex.toString()}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveAccentColor error")
                }
            case None => ()
        }
        let _ = recomputePresentation()
    }

    /**
     * 读取持久化的 accent 颜色。默认值 0x0088FF（iOS 日间主题蓝）。
     * 旧版本可能把编译期缺省 0x317AFF 写入 Preferences；该值按旧缺省迁移，
     * 其它用户选择的十六进制颜色保持不变。
     * 对应 iOS PresentationThemeAccentColor.accentColor。
     */
    public func getAccentColor(): UInt32 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("appearance_accent_color", PreferencesValueType.Integer(0x0088FF))
                    match (val) {
                        case PreferencesValueType.Integer(n) =>
                            if (n == 0x317AFF) {
                                return 0x0088FF
                            }
                            return UInt32(n)
                        case _ => return 0x0088FF
                    }
                } catch (_e: Exception) {
                    return 0x0088FF
                }
            case None => return 0x0088FF
        }
    }

    // ==================== 本地外观: 主题预设 ====================

    /**
     * 保存选中的主题预设索引（对应 Telegram base theme）。
     * 0 = Classic/Day, 1 = Night, 2 = Tinted, 3 = Arctic
     * key: "appearance_theme_preset", store: "telegram_themes_cache"
     * 对应 iOS PresentationBuiltinThemeReference (dayClassic/night/nightAccent/day)。
     */
    public func saveThemePreset(preset: Int32): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("appearance_theme_preset", PreferencesValueType.Integer(Int64(preset)))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveThemePreset: ${preset}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveThemePreset error")
                }
            case None => ()
        }
    }

    /**
     * 读取持久化的主题预设索引。默认值 0（Classic/Day）。
     */
    public func getThemePreset(): Int32 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("appearance_theme_preset", PreferencesValueType.Integer(0))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return 0
                    }
                } catch (_e: Exception) {
                    return 0
                }
            case None => return 0
        }
    }

    /** Persist the PresentationThemeReference used by the Appearance carousel. */
    public func saveSelectedChatThemeSlug(slug: String): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("appearance_chat_theme_slug", PreferencesValueType.StringData(slug))
                    prefs.flush()
                } catch (_e: Exception) {}
            case None => ()
        }
        let _ = recomputePresentation()
    }

    public func getSelectedChatThemeSlug(): String {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    match (prefs.get("appearance_chat_theme_slug", PreferencesValueType.StringData(""))) {
                        case PreferencesValueType.StringData(value) => return value
                        case _ => return ""
                    }
                } catch (_e: Exception) {
                    return ""
                }
            case None => return ""
        }
    }

    public func saveSelectedChatThemePalette(accent: UInt32, bubble: UInt32): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("appearance_chat_theme_accent", PreferencesValueType.Integer(Int64(accent)))
                    prefs.put("appearance_chat_theme_bubble", PreferencesValueType.Integer(Int64(bubble)))
                    prefs.flush()
                } catch (_e: Exception) {}
            case None => ()
        }
        let _ = recomputePresentation()
    }

    private func getSelectedChatThemeAccent(): UInt32 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    match (prefs.get("appearance_chat_theme_accent", PreferencesValueType.Integer(0x0088FF))) {
                        case PreferencesValueType.Integer(value) => return UInt32(value)
                        case _ => return 0x0088FF
                    }
                } catch (_e: Exception) { return 0x0088FF }
            case None => return 0x0088FF
        }
    }

    private func getSelectedChatThemeBubble(): UInt32 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    match (prefs.get("appearance_chat_theme_bubble", PreferencesValueType.Integer(0))) {
                        case PreferencesValueType.Integer(value) => return UInt32(value)
                        case _ => return 0
                    }
                } catch (_e: Exception) { return 0 }
            case None => return 0
        }
    }

    // ==================== 本地外观: 自定义气泡色 ====================

    /**
     * 保存用户自定义的发送气泡颜色（ARGB 十六进制）。
     * key: "appearance_custom_bubble", store: "telegram_themes_cache"
     * 对应 iOS PresentationThemeAccentColor.bubbleColors 侧（简化：单色）。
     *
     * P2-009 架构重建后：不再直接改写 AppTheme 单例字段（已随重建移除）。该字段此前也没有
     * 任何读者——真正的气泡预览一直读的是 getCustomBubbleColor() 本身
     * （pages/AppearanceSettingsPage.cj:223/296 的 customBubbleColor 状态），
     * PresentationSnapshot.bubbleOutColor 仍按主题表解出、不并入自定义气泡色
     * （气泡渲染另有 services/ChatMessageBackgroundService.cj#getBubbleColors 独立通路，
     * 不在本 feature 范围）。
     */
    public func saveCustomBubbleColor(colorHex: UInt32): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("appearance_custom_bubble", PreferencesValueType.Integer(Int64(colorHex)))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveCustomBubbleColor: 0x${colorHex.toString()}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveCustomBubbleColor error")
                }
            case None => ()
        }
        let _ = recomputePresentation()
    }

    /**
     * 读取持久化的自定义气泡颜色。默认值 0（0 = 未设置，使用主题默认值）。
     */
    public func getCustomBubbleColor(): UInt32 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("appearance_custom_bubble", PreferencesValueType.Integer(0))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return UInt32(n)
                        case _ => return 0
                    }
                } catch (_e: Exception) {
                    return 0
                }
            case None => return 0
        }
    }

    public func saveAnimateMessageColors(enabled: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("appearance_animate_message_colors", PreferencesValueType.BoolData(enabled))
                    prefs.flush()
                } catch (_e: Exception) {}
            case None => ()
        }
    }

    public func getAnimateMessageColors(): Bool {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    match (prefs.get("appearance_animate_message_colors", PreferencesValueType.BoolData(false))) {
                        case PreferencesValueType.BoolData(value) => return value
                        case _ => return false
                    }
                } catch (_e: Exception) { return false }
            case None => return false
        }
    }

    // ==================== P2-339: Auto-Night Mode ====================

    /**
     * 保存自动夜间模式开关。
     * key: "auto_night_enabled", store: "telegram_themes_cache"
     * 对应 iOS AutomaticThemeSwitchSetting.trigger != .none
     */
    public func saveAutoNightEnabled(enabled: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let v: Int64 = if (enabled) { 1 } else { 0 }
                    prefs.put("auto_night_enabled", PreferencesValueType.Integer(v))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveAutoNightEnabled: ${enabled}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveAutoNightEnabled error")
                }
            case None => ()
        }
    }

    /**
     * 读取自动夜间模式开关。默认 false（关闭）。
     */
    public func getAutoNightEnabled(): Bool {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("auto_night_enabled", PreferencesValueType.Integer(0))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return n != 0
                        case _ => return false
                    }
                } catch (_e: Exception) {
                    return false
                }
            case None => return false
        }
    }

    /**
     * 保存自动夜间模式触发模式。
     * 0 = 关闭, 1 = 定时(from/to), 2 = 日落日出, 3 = 跟随系统
     * 对应 iOS AutomaticThemeSwitchSetting.trigger: none/timeBased/brightness/system
     * key: "auto_night_mode", store: "telegram_themes_cache"
     */
    public func saveAutoNightMode(mode: Int32): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("auto_night_mode", PreferencesValueType.Integer(Int64(mode)))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveAutoNightMode: ${mode}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveAutoNightMode error")
                }
            case None => ()
        }
    }

    /**
     * 读取自动夜间模式触发模式。默认 3（跟随系统）。
     */
    public func getAutoNightMode(): Int32 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("auto_night_mode", PreferencesValueType.Integer(3))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return 3
                    }
                } catch (_e: Exception) {
                    return 3
                }
            case None => return 3
        }
    }

    /**
     * 保存定时自动夜间模式的起始小时（0-23）。
     * key: "auto_night_from_hour", store: "telegram_themes_cache"
     * 对应 iOS AutomaticThemeSwitchSetting.fromSeconds (timeBased trigger)
     */
    public func saveAutoNightFromHour(hour: Int32): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("auto_night_from_hour", PreferencesValueType.Integer(Int64(hour)))
                    prefs.flush()
                } catch (_e: Exception) {}
            case None => ()
        }
    }

    /**
     * 读取定时自动夜间模式的起始小时。默认 22（晚上 10 点）。
     */
    public func getAutoNightFromHour(): Int32 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("auto_night_from_hour", PreferencesValueType.Integer(22))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return 22
                    }
                } catch (_e: Exception) {
                    return 22
                }
            case None => return 22
        }
    }

    /**
     * 保存定时自动夜间模式的结束小时（0-23）。
     * key: "auto_night_to_hour", store: "telegram_themes_cache"
     */
    public func saveAutoNightToHour(hour: Int32): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("auto_night_to_hour", PreferencesValueType.Integer(Int64(hour)))
                    prefs.flush()
                } catch (_e: Exception) {}
            case None => ()
        }
    }

    /**
     * 读取定时自动夜间模式的结束小时。默认 8（早上 8 点）。
     */
    public func getAutoNightToHour(): Int32 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("auto_night_to_hour", PreferencesValueType.Integer(8))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return 8
                    }
                } catch (_e: Exception) {
                    return 8
                }
            case None => return 8
        }
    }

    /**
     * ic_auto_night_evaluator_minute_precision (set_theme_editing round1): minute-precision
     * persisted storage for the Scheduled trigger's "from" boundary, widening the evaluator beyond
     * getAutoNightFromHour()'s hour-only granularity. `minutes` is total minutes-of-day (0-1439).
     * key: "auto_night_from_minutes", store: "telegram_themes_cache" (same store as the hour keys).
     */
    public func saveAutoNightFromMinutes(minutes: Int32): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("auto_night_from_minutes", PreferencesValueType.Integer(Int64(minutes)))
                    prefs.flush()
                } catch (_e: Exception) {}
            case None => ()
        }
    }

    /**
     * 读取定时自动夜间模式的起始分钟精度值（0-1439，自 00:00 起算）。未显式写过该键时（既有账号,
     * 或写入方仍停在 saveAutoNightFromHour()，如本轮 pages/AutoNightSettingsPage.cj 的
     * floorToHour() 现状）,回落到 getAutoNightFromHour() * 60 —— 与当前小时精度值完全等价,不引入
     * 净变化。真正的分钟精度只在某个调用方开始调用 saveAutoNightFromMinutes() 之后生效。
     */
    public func getAutoNightFromMinutes(): Int32 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("auto_night_from_minutes", PreferencesValueType.Integer(-1))
                    match (val) {
                        case PreferencesValueType.Integer(n) =>
                            if (n < 0) {
                                return this.getAutoNightFromHour() * 60
                            }
                            return Int32(n)
                        case _ => return this.getAutoNightFromHour() * 60
                    }
                } catch (_e: Exception) {
                    return this.getAutoNightFromHour() * 60
                }
            case None => return this.getAutoNightFromHour() * 60
        }
    }

    /**
     * ic_auto_night_evaluator_minute_precision: minute-precision persisted storage for the
     * Scheduled trigger's "to" boundary. Same shape as saveAutoNightFromMinutes().
     * key: "auto_night_to_minutes", store: "telegram_themes_cache".
     */
    public func saveAutoNightToMinutes(minutes: Int32): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("auto_night_to_minutes", PreferencesValueType.Integer(Int64(minutes)))
                    prefs.flush()
                } catch (_e: Exception) {}
            case None => ()
        }
    }

    /**
     * 读取定时自动夜间模式的结束分钟精度值。语义同 getAutoNightFromMinutes()，未写过时回落
     * getAutoNightToHour() * 60。
     */
    public func getAutoNightToMinutes(): Int32 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("auto_night_to_minutes", PreferencesValueType.Integer(-1))
                    match (val) {
                        case PreferencesValueType.Integer(n) =>
                            if (n < 0) {
                                return this.getAutoNightToHour() * 60
                            }
                            return Int32(n)
                        case _ => return this.getAutoNightToHour() * 60
                    }
                } catch (_e: Exception) {
                    return this.getAutoNightToHour() * 60
                }
            case None => return this.getAutoNightToHour() * 60
        }
    }

    // ==================== P2-341: App Icon Selection ====================

    /**
     * 保存当前选中的备用 app 图标索引。
     * 0 = 默认图标, 1..N = 备用图标
     * key: "app_icon_index", store: "telegram_themes_cache"
     * 注: 鸿蒙平台目前无公开 API 可在运行时切换桌面图标，
     *     此处仅持久化用户选择供 UI 展示；实际图标切换为 defer。
     */
    public func saveAppIconIndex(index: Int32): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("app_icon_index", PreferencesValueType.Integer(Int64(index)))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveAppIconIndex: ${index}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveAppIconIndex error")
                }
            case None => ()
        }
    }

    /**
     * 读取当前选中的备用 app 图标索引。默认 0（默认图标）。
     */
    public func getAppIconIndex(): Int32 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("app_icon_index", PreferencesValueType.Integer(0))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return 0
                    }
                } catch (_e: Exception) {
                    return 0
                }
            case None => return 0
        }
    }

    // ==================== Media Display Settings ====================

    /**
     * Save whether a tap in the narrow left/right edge of a gallery moves to the
     * adjacent item. The source MediaDisplaySettings defaults this value to true.
     */
    public func saveShowNextMediaOnTap(enabled: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let value: Int64 = if (enabled) { 1 } else { 0 }
                    prefs.put("show_next_media_on_tap", PreferencesValueType.Integer(value))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveShowNextMediaOnTap: ${enabled}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveShowNextMediaOnTap error")
                }
            case None => ()
        }
    }

    /** Read the source-compatible media edge-navigation setting. */
    public func getShowNextMediaOnTap(): Bool {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("show_next_media_on_tap", PreferencesValueType.Integer(1))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return n != 0
                        case _ => return true
                    }
                } catch (_e: Exception) {
                    return true
                }
            case None => return true
        }
    }

    // ==================== P2-341: Profile Name Color ====================

    /**
     * 保存用户资料名称色索引（0-7 对应 Telegram 预设颜色）。
     * key: "profile_name_color_index", store: "telegram_themes_cache"
     * 对应 iOS account.updateColor (forProfile:false) PeerNameColor 枚举。
     */
    public func saveProfileNameColorIndex(index: Int32): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("profile_name_color_index", PreferencesValueType.Integer(Int64(index)))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveProfileNameColorIndex: ${index}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveProfileNameColorIndex error")
                }
            case None => ()
        }
    }

    /**
     * 读取资料名称色索引。默认 0（蓝色，对应 PeerNameColor.blue）。
     */
    public func getProfileNameColorIndex(): Int32 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("profile_name_color_index", PreferencesValueType.Integer(0))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return 0
                    }
                } catch (_e: Exception) {
                    return 0
                }
            case None => return 0
        }
    }

    /**
     * 保存用户资料配色索引（0-7，profile header 背景色）。
     * key: "profile_header_color_index", store: "telegram_themes_cache"
     * 对应 iOS account.updateColor (forProfile:true) PeerNameColor 枚举。
     */
    public func saveProfileHeaderColorIndex(index: Int32): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("profile_header_color_index", PreferencesValueType.Integer(Int64(index)))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveProfileHeaderColorIndex: ${index}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveProfileHeaderColorIndex error")
                }
            case None => ()
        }
    }

    /**
     * 读取资料配色索引。默认 0（蓝色）。
     */
    public func getProfileHeaderColorIndex(): Int32 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("profile_header_color_index", PreferencesValueType.Integer(0))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return 0
                    }
                } catch (_e: Exception) {
                    return 0
                }
            case None => return 0
        }
    }

    /**
     * ic_profile_header_color_index_option: 与 getProfileHeaderColorIndex() 语义等价，但用
     * Option<Int32> 区分"从未设置过"（None）与"显式设为 0/红色"（Some(0)）——
     * getProfileHeaderColorIndex() 用 Preferences 缺省值 0 兜底，无法表达这个区分；本函数
     * 用 prefs.has(...)（同 core/storage/AuthStorage.cj 既有惯例）先判 key 是否存在，
     * 不改动 getProfileHeaderColorIndex() 本身的签名/行为（其另外两个既有调用点
     * ProfileColorPage.cj / AppearanceSettingsPage.cj 不受影响）。
     */
    public func getProfileHeaderColorIndexOption(): Option<Int32> {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    if (!prefs.has("profile_header_color_index")) {
                        return None
                    }
                    let val = prefs.get("profile_header_color_index", PreferencesValueType.Integer(0))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Some(Int32(n))
                        case _ => return None
                    }
                } catch (_e: Exception) {
                    return None
                }
            case None => return None
        }
    }

    /**
     * 将本地资料色索引同步到 Telegram 服务端（account.updateColor）。
     * @param forProfile true = 资料头图色，false = 名称色
     * @param colorIndex  Telegram PeerNameColor 枚举值（0-6: red/orange/violet/green/cyan/blue/pink）
     * 对应 iOS SettingsService.updateNameColor(forProfile:color:backgroundEmojiId:)
     */
    public func applyProfileColorToServer(forProfile: Bool, colorIndex: Int32): Bool {
        return getSettingsService().updateNameColor(forProfile, colorIndex, 0)
    }

    public func applyCollectibleNameColorToServer(collectibleId: Int64): Bool {
        return getSettingsService().updateNameCollectibleColor(collectibleId)
    }

    // ==================== P2-340: Message Bubble Shape Settings ====================

    /**
     * 保存消息气泡主角半径（vp 单位，默认 16）。
     * 对应 iOS PresentationChatBubbleSettings.mainRadius (default: 16)
     * key: "bubble_main_radius", store: "telegram_themes_cache"
     */
    public func saveBubbleMainRadius(radius: Int32): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("bubble_main_radius", PreferencesValueType.Integer(Int64(radius)))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveBubbleMainRadius: ${radius}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveBubbleMainRadius error")
                }
            case None => ()
        }
    }

    /**
     * 读取消息气泡主角半径。默认值 16vp。
     */
    public func getBubbleMainRadius(): Int32 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("bubble_main_radius", PreferencesValueType.Integer(16))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return 16
                    }
                } catch (_e: Exception) {
                    return 16
                }
            case None => return 16
        }
    }

    /**
     * 保存消息气泡辅助角半径（分组消息内侧圆角，默认 8vp）。
     * 对应 iOS PresentationChatBubbleSettings.auxiliaryRadius (default: 8)
     * key: "bubble_aux_radius", store: "telegram_themes_cache"
     */
    public func saveBubbleAuxRadius(radius: Int32): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("bubble_aux_radius", PreferencesValueType.Integer(Int64(radius)))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveBubbleAuxRadius: ${radius}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveBubbleAuxRadius error")
                }
            case None => ()
        }
    }

    /**
     * 读取消息气泡辅助角半径。默认值 8vp。
     */
    public func getBubbleAuxRadius(): Int32 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("bubble_aux_radius", PreferencesValueType.Integer(8))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return 8
                    }
                } catch (_e: Exception) {
                    return 8
                }
            case None => return 8
        }
    }

    /**
     * 保存是否合并连续消息的气泡圆角（默认 true）。
     * 对应 iOS PresentationChatBubbleSettings.mergeBubbleCorners (default: true)
     * key: "bubble_merge_corners", store: "telegram_themes_cache"
     */
    public func saveBubbleMergeCorners(enabled: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let v: Int64 = if (enabled) { 1 } else { 0 }
                    prefs.put("bubble_merge_corners", PreferencesValueType.Integer(v))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveBubbleMergeCorners: ${enabled}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveBubbleMergeCorners error")
                }
            case None => ()
        }
    }

    /**
     * 读取是否合并连续消息气泡圆角。默认值 true。
     */
    public func getBubbleMergeCorners(): Bool {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("bubble_merge_corners", PreferencesValueType.Integer(1))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return n != 0
                        case _ => return true
                    }
                } catch (_e: Exception) {
                    return true
                }
            case None => return true
        }
    }

    /**
     * 保存是否为消息气泡显示阴影（默认 false）。
     * 对应 iOS 气泡阴影效果（ChatMessageBubbleView dropShadow）。
     * key: "bubble_shadow_enabled", store: "telegram_themes_cache"
     */
    public func saveBubbleShadowEnabled(enabled: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let v: Int64 = if (enabled) { 1 } else { 0 }
                    prefs.put("bubble_shadow_enabled", PreferencesValueType.Integer(v))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveBubbleShadowEnabled: ${enabled}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveBubbleShadowEnabled error")
                }
            case None => ()
        }
    }

    /**
     * 读取是否为消息气泡显示阴影。默认值 false。
     */
    public func getBubbleShadowEnabled(): Bool {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("bubble_shadow_enabled", PreferencesValueType.Integer(0))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return n != 0
                        case _ => return false
                    }
                } catch (_e: Exception) {
                    return false
                }
            case None => return false
        }
    }

    // ==================== TC-0404 F4: 字号呈现维度（chatFontSize / listsFontSize / useSystemFont） ====================
    // 对应 iOS PresentationData.swift:88/95-102 — listsFontSize 与 chatFontSize 并列进入呈现快照；
    // useSystemFont 驱动 core/storage/AppTheme.cj 的 resolveFontSize()（对位 :846-858）。
    // chatFontSize 本身沿用既有 AuthStorage.getAppearanceTextSize()，此处只补 listsFontSize 与开关。

    /**
     * 保存"使用系统字号"开关。为真时 core/storage/AppTheme.cj#resolveFontSize()
     * 让 chatFontSize/listsFontSize 两量相等、由系统字号缩放解出。
     * key: "appearance_use_system_font", store: "telegram_themes_cache"
     */
    public func saveUseSystemFont(enabled: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let v: Int64 = if (enabled) { 1 } else { 0 }
                    prefs.put("appearance_use_system_font", PreferencesValueType.Integer(v))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveUseSystemFont: ${enabled}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveUseSystemFont error")
                }
            case None => ()
        }
    }

    /** 读取"使用系统字号"开关。默认 true（对位 iOS PresentationThemeSettings.swift:655 defaultSettings.useSystemFont = true 与 :705 的 `?? 1` 缺键回落）。 */
    public func getUseSystemFont(): Bool {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("appearance_use_system_font", PreferencesValueType.Integer(1))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return n != 0
                        case _ => return true
                    }
                } catch (_e: Exception) {
                    return true
                }
            case None => return true
        }
    }

    /**
     * 保存列表（会话列表）字号，与气泡字号（chatFontSize，沿用既有
     * AuthStorage.saveAppearanceTextSize）分开持久化。
     * 对应 iOS PresentationData.swift:88 listsFontSize。
     * key: "appearance_lists_font_size", store: "telegram_themes_cache"
     */
    public func saveListsFontSize(size: Int32): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("appearance_lists_font_size", PreferencesValueType.Integer(Int64(size)))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveListsFontSize: ${size}")
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ThemesEngine] saveListsFontSize error")
                }
            case None => ()
        }
    }

    /** 读取列表字号。默认 16（对齐既有 chatFontSize 的默认值）。 */
    public func getListsFontSize(): Int32 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("appearance_lists_font_size", PreferencesValueType.Integer(16))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return 16
                    }
                } catch (_e: Exception) {
                    return 16
                }
            case None => return 16
        }
    }

    // ==================== TC-0402 F3: auto-night 求值器 ====================
    // 对应 iOS PresentationData.swift:487-505 automaticThemeShouldSwitchNow 的仓颉等价实现，
    // 逐条对位五个触发器 PreparedAutomaticThemeSwitchTrigger（:443-448）。
    //
    // 现有 getAutoNightMode() 持久化值域是历史遗留的 0-3（0=关闭 1=定时 2=日落日出 3=跟随系统，
    // 见其上方文档），只覆盖源侧五个触发器里的三个（explicitNone/time/system）；
    // explicitForce 与 brightness 目前没有任何 UI 产出这些值（set_theme_editing 的 TC-0403
    // 返修单会重建四选一的模式行组，届时会接通这两个分支）。为了不与 TC-0403 对 mode==2
    // （"Sunset to Sunrise"，其归因报告判定它其实是 time 触发器的 location 子选项）的迁移计划
    // 冲突，这里不挪用 2，改为在现有值域之外新增两个保留位 4/5——加法式扩展，
    // 不改变 0-3 的既有语义，现在没有任何写入路径会产生 4/5，接通前恒不可达。

    /**
     * 保存自动夜间亮度触发阈值（0.0-1.0，屏幕亮度低于等于该值时触发）。
     * 对应 iOS PreparedAutomaticThemeSwitchTrigger.brightness(threshold: Double)。
     * key: "auto_night_brightness_threshold", store: "telegram_themes_cache"
     */
    public func saveAutoNightBrightnessThreshold(threshold: Float64): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    prefs.put("auto_night_brightness_threshold", PreferencesValueType.Double(threshold))
                    prefs.flush()
                } catch (_e: Exception) {}
            case None => ()
        }
    }

    /** 读取自动夜间亮度触发阈值。默认 0.2。 */
    public func getAutoNightBrightnessThreshold(): Float64 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                    let val = prefs.get("auto_night_brightness_threshold", PreferencesValueType.Double(0.2))
                    match (val) {
                        case PreferencesValueType.Double(n) => return n
                        case _ => return 0.2
                    }
                } catch (_e: Exception) {
                    return 0.2
                }
            case None => return 0.2
        }
    }

    /**
     * 读取当前系统屏幕亮度（0.0-1.0）。
     *
     * D-141 round-2 review 复核：round-1 只查了 `@system.brightness.d.ts`（该文件的
     * `Brightness.getValue()` 确认 `@deprecated since 7` 且 `@reserved["liteWearable"]`，与本
     * 手机 App 不适用）就下结论，未继续搜 SDK 其余 ets/api 目录下的 .d.ts 文件。本轮按 review
     * 指出的路径重新调查：对 ets/api 目录全量 .d.ts 文件 grep 'brightness' 命中 `@ohos.settings.d.ts`，其
     * `namespace settings.display` 下的 `SCREEN_BRIGHTNESS_STATUS`（0-255，@since 7，未标
     * `@deprecated`）配合 `settings.getValue(context, name)` 是一条真实可用、未废弃的读路径。
     * 本地 Cangjie SDK 对应有编译产物存根 `ohos.settings.cj.d`：
     * `public func getValue<T>(context: UIAbilityContext, name: T, defValue: String): String
     * where T <: ToString`（@!APILevel since 22，未标废弃）+ 与 `SCREEN_BRIGHTNESS_STATUS` 一一
     * 对位的 `Display.ScreenBrightnessStatus` 枚举项——与 `getGlobalAbilityContext()` 已经在用的
     * `Option<UIAbilityContext>` 类型完全匹配，无需额外类型转换。该 API 标注
     * `workerthread: true`，与本文件 `Preferences.getPreferences()`/`.get()`（同样标注
     * `workerthread: true`，见 saveAutoNightBrightnessThreshold/getAutoNightBrightnessThreshold
     * 上方两个函数）采用完全相同的同步调用 + try/catch(Exception) 写法，不做额外线程调度——
     * 与本仓已确立的先例一致。
     *
     * 取值域文档标注 0-255；此处归一化到 0.0-1.0 以匹配本函数既有契约（调用方
     * autoNightShouldSwitchNow() 的 mode==5 分支用它与 getAutoNightBrightnessThreshold() 的
     * 0.0-1.0 阈值比较）。Context 不可用或调用/解析失败时返回 None（调用方在 None 时不触发亮度
     * 分支），不用电量、环境光传感器等其它量近似代替屏幕亮度。
     */
    func currentSystemBrightness(): Option<Float64> {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let raw = settingsGetValue(ctx, SettingsDisplay.ScreenBrightnessStatus, "-1")
                    let level = Int64.parse(raw)
                    if (level < 0) {
                        return None
                    }
                    var clamped = level
                    if (clamped > 255) {
                        clamped = 255
                    }
                    return Some(Float64(clamped) / 255.0)
                } catch (_e: Exception) {
                    return None
                }
            case None => return None
        }
    }

    /**
     * 对位 PresentationData.swift:487-505 automaticThemeShouldSwitchNow。
     * @param systemColorMode 见 core/storage/AppTheme.cj 的 COLOR_MODE_* 常量语义
     */
    public func autoNightShouldSwitchNow(systemColorMode: Int32): Bool {
        let mode = this.getAutoNightMode()
        if (mode == 0) {
            // explicitNone
            return false
        } else if (mode == 4) {
            // explicitForce（保留位，当前无 UI 产出该值）
            return true
        } else if (mode == 3) {
            // system
            return systemColorMode == COLOR_MODE_DARK
        } else if (mode == 5) {
            // brightness(threshold)（保留位，当前无 UI 产出该值）
            match (this.currentSystemBrightness()) {
                case Some(b) => return b <= this.getAutoNightBrightnessThreshold()
                case None => return false
            }
        } else {
            // mode == 1（定时 from/to）或 mode == 2（"Sunset to Sunrise"，按 TC-0403 归因
            // 报告是 time 触发器的 location 子选项，本轮无地理位置计算能力，
            // 退化为与 mode==1 相同的手动 from/to 小时判定，留待 TC-0403 落地真实日出日落）。
            // 照搬源侧的 OR 逻辑与跨零点语义（:495-501），不改写成区间包含判断——
            // ic_auto_night_evaluator_minute_precision 只加宽了 from/to 的精度来源
            // （getAutoNightFromHour/ToHour → getAutoNightFromMinutes/ToMinutes），比较逻辑本身
            // 一字不改。getAutoNightFromMinutes/ToMinutes 未被任何调用方写过分钟精度值时精确回落
            // 到 *Hour() * 60，即与本条修改前完全等价。
            let fromMinutes = this.getAutoNightFromMinutes()
            let toMinutes = this.getAutoNightToMinutes()
            let now = DateTime.now().inLocal()
            let nowSeconds = now.hour * 3600 + now.minute * 60 + now.second
            let fromSeconds = Int64(fromMinutes) * 60
            let toSeconds = Int64(toMinutes) * 60
            return nowSeconds >= fromSeconds || nowSeconds <= toSeconds
        }
    }

    /**
     * 对位 PresentationData.swift:507-529 automaticThemeShouldSwitch 里的 1 秒重复定时器分支。
     * 幂等：若已有定时器则先 cancel 再重建。
     *
     * 已知限制（写入 feature 报告）：源侧在 force/explicitNone 时短路、不启定时器；本实现未做该
     * 短路优化（每秒都会重算一次，由 recomputePresentation() 的 distinctUntilChanged 兜底去重，
     * 不会产生多余广播，只有多余的一次 CPU/Preferences 读）。源侧还把定时器约束在前台运行；
     * 本仓 ArkTS 侧 EntryAbility.onForeground 已有 dispatchEvent(FOREGROUND_CHANGED) 通道，
     * 但 onBackground 未对称派发"离开前台"事件（预置的既有缺口，不在本 feature 范围内），
     * 故本定时器当前是进程存活期间常驻运行，不做前台门控。
     *
     * S-001 (round-1 review): `Timer.repeat`'s callback runs on the timer's own background
     * thread, not the UI thread (confirmed against std.sync.cj.d — see this feature's
     * kb_consultations). recomputePresentation() itself has no UI-thread requirement (only the
     * actual AppStorage write does); that requirement is now enforced inside
     * core/storage/AppTheme.cj#publishPresentation() itself via `launch{}`, so this call site no
     * longer needs its own wrap — see that function's doc comment for why the dispatch was moved
     * there instead of duplicated at every caller (D-167).
     */
    public func startAutoNightTimer(): Unit {
        this._autoNightTimerMutex.lock()
        match (this._autoNightTimer) {
            case Some(t) => t.cancel()
            case None => ()
        }
        let t = Timer.repeat(Duration.second, Duration.second, { =>
            let _ = recomputePresentation()
        })
        this._autoNightTimer = Some(t)
        this._autoNightTimerMutex.unlock()
        Hilog.info(0, "CjTelegram", "[ThemesEngine] Auto-night evaluation timer started (1s interval)")
    }

    public func stopAutoNightTimer(): Unit {
        this._autoNightTimerMutex.lock()
        match (this._autoNightTimer) {
            case Some(t) =>
                t.cancel()
                this._autoNightTimer = None
            case None => ()
        }
        this._autoNightTimerMutex.unlock()
    }

    /**
     * Gathers the services-layer inputs core/storage/AppTheme.cj#recomputePresentation() needs
     * but cannot import directly (see that file's "Cross-package input gathering" section).
     * Registered as the provider callback in getThemesEngineService()'s first-construction branch.
     */
    func gatherPresentationExtras(systemColorMode: Int32): PresentationExtras {
        let selectedChatThemeSlug = this.getSelectedChatThemeSlug()
        let userAccent = if (selectedChatThemeSlug.size > 0) { this.getSelectedChatThemeAccent() } else { this.getAccentColor() }
        let customBubbleColor = if (selectedChatThemeSlug.size > 0) { this.getSelectedChatThemeBubble() } else { this.getCustomBubbleColor() }
        let useSystemFont = this.getUseSystemFont()
        let userListsFontSize = this.getListsFontSize()
        // 对位 PresentationData.swift:507-511 automaticThemeShouldSwitch 的合成式：
        // triggered = force || eval(trigger)。`force`（getAutoNightEnabled()，读
        // auto_night_enabled，即 Night Mode 开关本身）是短路为 true 的覆盖位，不是
        // 求值器的总使能——force 为 false 时触发器仍照常求值。"关闭" 语义已经由
        // autoNightShouldSwitchNow() 内 mode==0（explicitNone）承载（对位源侧
        // `:454-458` trigger = .explicitNone），此处不再重复一道方向相反的门。
        let force = this.getAutoNightEnabled()
        let autoNightTriggered = if (force) {
            true
        } else {
            this.autoNightShouldSwitchNow(systemColorMode)
        }
        // S7-106：已应用云主题的配色（iOS PresentationThemeSettings.theme = .cloud → makePresentationTheme）。
        var cloudColors: Option<CloudThemeColorSettings> = Option<CloudThemeColorSettings>.None
        match (getAppliedCloudTheme()) {
            case Some(t) => cloudColors = t.colorSettings()
            case _ => ()
        }
        return PresentationExtras(userAccent, customBubbleColor, useSystemFont, userListsFontSize,
            autoNightTriggered, autoNightThemePreset: automaticNightThemePreset(),
            cloudTheme: cloudColors)
    }
}

private var _themesEngineServiceInstance: Option<ThemesEngineService> = None

public func getThemesEngineService(): ThemesEngineService {
    match (_themesEngineServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ThemesEngineService()
            _themesEngineServiceInstance = Some(inst)
            // Wire this feature's dependency-inversion hook (core/storage/AppTheme.cj cannot
            // import this package — see its "Cross-package input gathering" section) and produce
            // a corrected first snapshot + start the auto-night evaluator now that the provider
            // is live (any earlier recomputePresentation() call, e.g. from initAppTheme(), ran
            // against safe fallback defaults until this point).
            //
            // S-001/D-157 (round-1 review): this branch is reachable from pre-existing bare
            // `spawn{}` call sites elsewhere (pages/ChatQrCodeSharePage.cj:118,
            // services/WallpaperBackgroundService.cj:731-746), i.e. not guaranteed to run on the
            // UI thread. recomputePresentation() itself has no UI-thread requirement; only the
            // actual AppStorage write inside it does, and that dispatch is now centralized in
            // core/storage/AppTheme.cj#publishPresentation() (`launch{}`) rather than required at
            // every call site including this one — see that function's doc comment.
            //
            // Still not a fix for the *registration itself* going unreached on a cold start that
            // never calls getThemesEngineService() at all — that is a separate gap, see
            // core/storage/AppTheme.cj#registerPresentationExtrasProvider()'s doc comment and this
            // feature's emitted `ic_themes_engine_cold_start_bootstrap` contract.
            registerPresentationExtrasProvider({ mode => inst.gatherPresentationExtras(mode) })
            let _ = recomputePresentation()
            inst.startAutoNightTimer()
            return inst
    }
}
