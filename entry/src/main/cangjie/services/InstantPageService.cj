package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.ArkData.*
import kit.AbilityKit.UIAbilityContext
import std.collection.ArrayList
import ohos_app_cangjie_entry.core.mtproto.*

// ==================== Rich-text entity types ====================

/**
 * Inline rich-text entity kinds (iOS: RichText / MessageTextEntityType)
 * These annotate sub-ranges of InstantPageBlock.text.
 */
public enum InstantPageEntityKind {
    | Bold
    | Italic
    | Underline
    | Strikethrough
    | Fixed          // monospace / code
    | Link           // has url field
    | Anchor         // internal anchor, has anchorName field
    | PlainText      // unstyled span
}

/**
 * A rich-text inline entity that annotates [start, end) within block.text.
 * For Link/Anchor, url / anchorName carry destination.
 */
public class InstantPageTextEntity {
    public var kind: InstantPageEntityKind = InstantPageEntityKind.PlainText
    public var start: Int64 = 0      // rune-based start index in text
    public var end: Int64 = 0        // rune-based end (exclusive)
    public var url: String = ""
    public var anchorName: String = ""

    public init(kind!: InstantPageEntityKind, start!: Int64, end!: Int64) {
        this.kind = kind
        this.start = start
        this.end = end
    }
}

// ==================== Block types ====================

/**
 * Block types for rich Instant View content.
 * Matches iOS InstantPageBlock enum cases.
 */
public enum InstantPageBlockKind {
    | Paragraph
    | Header
    | Subheader
    | Blockquote
    | Preformatted
    | ListItem
    | Image          // photo block — uses imageUrl + caption
    | Photo          // alias used when parsing cover photos; rendered same as Image
    | Divider
    | Anchor         // invisible anchor marker — has anchorName; used for #anchor navigation
    | Unsupported
}

/**
 * A single rendered block of Instant View content.
 *
 * text:        plaintext rendering (for text blocks)
 * imageUrl:    remote image URL (for Image/Photo blocks)
 * caption:     caption text below image (for Image/Photo blocks)
 * level:       list nesting level (for ListItem)
 * anchorName:  anchor identifier (for Anchor blocks — e.g. "section1")
 * entities:    rich-text inline entities annotating text
 * linkUrl:     if the entire block is a link (paragraph/article link)
 */
public class InstantPageBlock {
    public var kind: InstantPageBlockKind = InstantPageBlockKind.Paragraph
    public var text: String = ""
    public var imageUrl: String = ""
    public var caption: String = ""
    public var level: Int64 = 0
    public var anchorName: String = ""
    public var linkUrl: String = ""
    public var entities: ArrayList<InstantPageTextEntity> = ArrayList<InstantPageTextEntity>()

    public init(kind!: InstantPageBlockKind, text!: String) {
        this.kind = kind
        this.text = text
    }

    public init(kind!: InstantPageBlockKind, text!: String, imageUrl!: String) {
        this.kind = kind
        this.text = text
        this.imageUrl = imageUrl
    }
}

// ==================== Settings models (P2-215) ====================

/**
 * Instant View theme type (matches iOS InstantPageThemeType)
 */
public enum InstantPageTheme {
    | Light    // default white
    | Sepia    // warm brownish background
    | Dark     // dark gray
    | Night    // pure black / night mode
}

/**
 * Font size step (matches iOS InstantPagePresentationFontSize)
 * Values: xxsmall(-2)..xxlarge(4)
 */
public enum InstantPageFontSize {
    | XXSmall   // -2
    | XSmall    // -1
    | Small     // 0  (≈ 14vp)
    | Standard  // 1  (≈ 16vp, default)
    | Large     // 2  (≈ 19vp)
    | XLarge    // 3  (≈ 22vp)
    | XXLarge   // 4  (≈ 26vp)
}

/**
 * Runtime Instant View reading settings (P2-215).
 * Persisted via Preferences store "instant_page_settings".
 */
public class InstantPageSettings {
    public var theme: InstantPageTheme = InstantPageTheme.Light
    public var fontSize: InstantPageFontSize = InstantPageFontSize.Standard
    public var forceSerif: Bool = false   // use serif font family when true

    // Derived: base text size in vp
    public func baseFontSizeVp(): Float64 {
        return match (this.fontSize) {
            case InstantPageFontSize.XXSmall => 12.0
            case InstantPageFontSize.XSmall  => 13.0
            case InstantPageFontSize.Small   => 14.0
            case InstantPageFontSize.Standard => 16.0
            case InstantPageFontSize.Large   => 19.0
            case InstantPageFontSize.XLarge  => 22.0
            case InstantPageFontSize.XXLarge => 26.0
        }
    }

    // Derived: background color (Int64 0xRRGGBB)
    public func backgroundColor(): Int64 {
        return match (this.theme) {
            case InstantPageTheme.Light => 0xFFFFFF
            case InstantPageTheme.Sepia => 0xFBF0D9
            case InstantPageTheme.Dark  => 0x2B2B2B
            case InstantPageTheme.Night => 0x000000
        }
    }

    // Derived: primary text color
    public func textColor(): Int64 {
        return match (this.theme) {
            case InstantPageTheme.Light => 0x222222
            case InstantPageTheme.Sepia => 0x3D2B1F
            case InstantPageTheme.Dark  => 0xDDDDDD
            case InstantPageTheme.Night => 0xCCCCCC
        }
    }

    // Derived: secondary / dimmed text color
    public func secondaryTextColor(): Int64 {
        return match (this.theme) {
            case InstantPageTheme.Light => 0x888888
            case InstantPageTheme.Sepia => 0x7A6455
            case InstantPageTheme.Dark  => 0xAAAAAA
            case InstantPageTheme.Night => 0x999999
        }
    }

    // Derived: blockquote accent color
    public func accentColor(): Int64 {
        return match (this.theme) {
            case InstantPageTheme.Light => 0x2563EB
            case InstantPageTheme.Sepia => 0x8B6914
            case InstantPageTheme.Dark  => 0x5B9BD5
            case InstantPageTheme.Night => 0x4D8FC0
        }
    }

    // Derived: surface / card background (blockquote bg, preformatted bg)
    public func surfaceColor(): Int64 {
        return match (this.theme) {
            case InstantPageTheme.Light => 0xF5F5F5
            case InstantPageTheme.Sepia => 0xEFE3C8
            case InstantPageTheme.Dark  => 0x3A3A3A
            case InstantPageTheme.Night => 0x1A1A1A
        }
    }

    // Derived: preformatted text color
    public func codeColor(): Int64 {
        return match (this.theme) {
            case InstantPageTheme.Light => 0x0A5F38
            case InstantPageTheme.Sepia => 0x5C4520
            case InstantPageTheme.Dark  => 0x6DD07F
            case InstantPageTheme.Night => 0x5BBF6D
        }
    }
}

// ==================== Settings singleton + Preferences persistence ====================

private var _instantPageSettings: Option<InstantPageSettings> = None

public func getInstantPageSettings(): InstantPageSettings {
    match (_instantPageSettings) {
        case Some(s) => return s
        case None =>
            let s = InstantPageSettings()
            _instantPageSettings = Some(s)
            return s
    }
}

/**
 * Persist settings to Preferences store.
 * theme: 0=Light,1=Sepia,2=Dark,3=Night
 * fontSize: 0..6 (XXSmall..XXLarge)
 * forceSerif: "1"/"0"
 */
public func saveInstantPageSettings(settings: InstantPageSettings): Unit {
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, "instant_page_settings")
                let themeVal = match (settings.theme) {
                    case InstantPageTheme.Light => "0"
                    case InstantPageTheme.Sepia => "1"
                    case InstantPageTheme.Dark  => "2"
                    case InstantPageTheme.Night => "3"
                }
                let fontVal = match (settings.fontSize) {
                    case InstantPageFontSize.XXSmall  => "0"
                    case InstantPageFontSize.XSmall   => "1"
                    case InstantPageFontSize.Small    => "2"
                    case InstantPageFontSize.Standard => "3"
                    case InstantPageFontSize.Large    => "4"
                    case InstantPageFontSize.XLarge   => "5"
                    case InstantPageFontSize.XXLarge  => "6"
                }
                let serifVal = if (settings.forceSerif) { "1" } else { "0" }
                prefs.put("theme", PreferencesValueType.StringData(themeVal))
                prefs.put("fontSize", PreferencesValueType.StringData(fontVal))
                prefs.put("forceSerif", PreferencesValueType.StringData(serifVal))
                prefs.flush()
                _instantPageSettings = Some(settings)
                Hilog.info(0, "CjTelegram", "[IPSettings] saved settings")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[IPSettings] save error: ${e}")
            }
        case None =>
            _instantPageSettings = Some(settings)
            Hilog.info(0, "CjTelegram", "[IPSettings] no context, saved in-memory only")
    }
}

/**
 * Load settings from Preferences store (called at app start or on first access).
 * Falls back to defaults on any error.
 */
public func loadInstantPageSettings(): InstantPageSettings {
    let defaults = InstantPageSettings()
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, "instant_page_settings")
                let themeStr = match (prefs.get("theme", PreferencesValueType.StringData(""))) {
                    case PreferencesValueType.StringData(s) => s
                    case _ => "0"
                }
                let fontStr = match (prefs.get("fontSize", PreferencesValueType.StringData(""))) {
                    case PreferencesValueType.StringData(s) => s
                    case _ => "3"
                }
                let serifStr = match (prefs.get("forceSerif", PreferencesValueType.StringData(""))) {
                    case PreferencesValueType.StringData(s) => s
                    case _ => "0"
                }
                let s = InstantPageSettings()
                s.theme = match (themeStr) {
                    case "1" => InstantPageTheme.Sepia
                    case "2" => InstantPageTheme.Dark
                    case "3" => InstantPageTheme.Night
                    case _   => InstantPageTheme.Light
                }
                s.fontSize = match (fontStr) {
                    case "0" => InstantPageFontSize.XXSmall
                    case "1" => InstantPageFontSize.XSmall
                    case "2" => InstantPageFontSize.Small
                    case "4" => InstantPageFontSize.Large
                    case "5" => InstantPageFontSize.XLarge
                    case "6" => InstantPageFontSize.XXLarge
                    case _   => InstantPageFontSize.Standard
                }
                s.forceSerif = (serifStr == "1")
                _instantPageSettings = Some(s)
                Hilog.info(0, "CjTelegram", "[IPSettings] loaded settings")
                return s
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[IPSettings] load error: ${e}")
                return defaults
            }
        case None =>
            return defaults
    }
}

// ==================== TL Method: messages.getWebPage ====================

/**
 * messages.getWebPage#8d9692a3 url:string hash:int = messages.WebPage
 */
public class MessagesGetWebPage <: TLObject {
    public var url: String = ""
    public var hash: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x8d9692a3 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.url)
        serializer.writeInt32(this.hash)
    }
}

// ==================== Response parsing ====================

/**
 * Parse the server response from messages.getWebPage.
 */
func parseWebPageResponse(data: Array<Byte>): InstantPageData {
    let result = InstantPageData()
    if (data.size < 4) {
        return result
    }

    let b0 = UInt32(data[0])
    let b1 = UInt32(data[1]) << 8
    let b2 = UInt32(data[2]) << 16
    let b3 = UInt32(data[3]) << 24
    let ctor = b0 | b1 | b2 | b3

    // webPageNotModified#7311ca11 — page unchanged
    if (ctor == 0x7311ca11) {
        result.loaded = true
        return result
    }

    let fieldData = extractSubArray(data, 4, data.size)
    let fd = TLDeserializer(fieldData)

    let extracted = ArrayList<String>()
    var attempts: Int64 = 0
    while (attempts < 20 && extracted.size < 6 && fd.remaining() > 0) {
        try {
            if (fd.remaining() < 1) { break }
            let s = fd.readString()
            if (s.size > 0) {
                extracted.add(s)
            }
        } catch (_: Exception) {
            break
        }
        attempts = attempts + 1
    }

    // Heuristic assignment: url, display_url, type, site_name, title, description
    var idx: Int64 = 0
    for (s in extracted) {
        if (idx == 0) {
            result.url = s
        } else if (idx == 4) {
            result.title = s
        } else if (idx == 5) {
            result.description = s
        }
        idx = idx + 1
    }

    if (result.title.size > 0) {
        result.blocks.add(InstantPageBlock(kind: InstantPageBlockKind.Header, text: result.title))
    }
    if (result.description.size > 0) {
        result.blocks.add(InstantPageBlock(kind: InstantPageBlockKind.Paragraph, text: result.description))
    }

    result.loaded = true
    return result
}

/**
 * Extract a sub-slice of an Array<Byte> from start (inclusive) to end (exclusive).
 */
func extractSubArray(data: Array<Byte>, start: Int64, end: Int64): Array<Byte> {
    let safeEnd = if (end > data.size) { data.size } else { end }
    let len = if (safeEnd > start) { safeEnd - start } else { 0 }
    return Array<Byte>(len, { i: Int64 => data[start + i] })
}

// ==================== Parsed page model ====================

/**
 * Parsed Instant View page structure
 */
public class InstantPageData {
    public var url: String = ""
    public var title: String = ""
    public var description: String = ""
    public var blocks: ArrayList<InstantPageBlock> = ArrayList<InstantPageBlock>()
    public var loaded: Bool = false
}

// ==================== Service ====================

/**
 * InstantPageService — Provides Instant View article data.
 *
 * P2-217: Wraps InstantPageCacheService:
 *   - isFresh(url) → return cached blocks immediately
 *   - !isFresh or miss → MTProto fetch → update cache
 *
 * Call chain:
 *   InstantPagePage → fetchWebPage(url) [in spawn{}]
 *     → cache.isFresh(url)? → return cached (fast path)
 *     : getMTProtoClient().sendRequest(MessagesGetWebPage.toBytes())
 *       → parseWebPageResponse → InstantPageData
 *       → cache.updateCachedPage(url, content)
 */
public class InstantPageService {

    public init() {}

    /**
     * Fetch Instant View page for the given URL.
     * P2-217: checks InstantPageCacheService before network.
     * Blocks the calling thread; call inside spawn{}.
     */
    public func fetchWebPage(url: String): InstantPageData {
        Hilog.info(0, "CjTelegram", "[InstantPageService] fetchWebPage start")

        // P2-217: cache look-up (fast path)
        let cache = getInstantPageCacheService()
        if (cache.isFresh(url)) {
            match (cache.getCachedPage(url)) {
                case Some(entry) =>
                    Hilog.info(0, "CjTelegram", "[InstantPageService] serving from cache")
                    let cached = buildDataFromCachedContent(url, entry.content)
                    return cached
                case None => ()
            }
        }

        // Network path
        let req = MessagesGetWebPage()
        req.url = url
        req.hash = 0
        try {
            let client = getMTProtoClient()
            let responseBytes = client.sendRequest(req.toBytes())
            if (responseBytes.size < 4) {
                Hilog.info(0, "CjTelegram", "[InstantPageService] empty response")
                let empty = InstantPageData()
                empty.url = url
                return empty
            }
            let pageData = parseWebPageResponse(responseBytes)
            if (pageData.url.size == 0) {
                pageData.url = url
            }
            // P2-217: store in cache (title||description as cache content string)
            if (pageData.loaded && (pageData.title.size > 0 || pageData.description.size > 0)) {
                let cacheContent = pageData.title + "||" + pageData.description
                cache.updateCachedPage(url, cacheContent)
            }
            Hilog.info(0, "CjTelegram", "[InstantPageService] fetchWebPage done")
            return pageData
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[InstantPageService] fetchWebPage error")
            let errData = InstantPageData()
            errData.url = url
            return errData
        }
    }

    /**
     * Build reference blocks for sub-pages (P2-216 reference/gallery sub-page).
     */
    public func buildReferenceBlocks(referenceText: String): ArrayList<InstantPageBlock> {
        let blocks = ArrayList<InstantPageBlock>()
        if (referenceText.size > 0) {
            blocks.add(InstantPageBlock(kind: InstantPageBlockKind.Subheader, text: "Reference"))
            blocks.add(InstantPageBlock(kind: InstantPageBlockKind.Paragraph, text: referenceText))
        } else {
            blocks.add(InstantPageBlock(kind: InstantPageBlockKind.Paragraph, text: "No reference content."))
        }
        return blocks
    }
}

/**
 * Rebuild InstantPageData from cached content string ("title||description").
 */
private func buildDataFromCachedContent(url: String, content: String): InstantPageData {
    let data = InstantPageData()
    data.url = url
    data.loaded = true
    let sepIdx = instSvcFindSep(content, "||")
    if (sepIdx >= 0) {
        let runes = content.toRuneArray()
        let titlePart = String(runes[0..sepIdx])
        let descPart = String(runes[(sepIdx + 2)..runes.size])
        if (titlePart.size > 0) {
            data.title = titlePart
            data.blocks.add(InstantPageBlock(kind: InstantPageBlockKind.Header, text: titlePart))
        }
        if (descPart.size > 0) {
            data.description = descPart
            data.blocks.add(InstantPageBlock(kind: InstantPageBlockKind.Paragraph, text: descPart))
        }
    } else if (content.size > 0) {
        data.title = content
        data.blocks.add(InstantPageBlock(kind: InstantPageBlockKind.Header, text: content))
    }
    return data
}

private func instSvcFindSep(s: String, sep: String): Int64 {
    let sR = s.toRuneArray()
    let sepR = sep.toRuneArray()
    let sLen = sR.size
    let sepLen = sepR.size
    if (sepLen == 0 || sLen < sepLen) { return -1 }
    var i: Int64 = 0
    while (i <= sLen - sepLen) {
        var matched = true
        var j: Int64 = 0
        while (j < sepLen) {
            if (sR[i + j] != sepR[j]) { matched = false; break }
            j += 1
        }
        if (matched) { return i }
        i += 1
    }
    return -1
}

// ==================== Singleton ====================

var _globalInstantPageService: Option<InstantPageService> = None

public func getInstantPageService(): InstantPageService {
    match (_globalInstantPageService) {
        case Some(svc) => return svc
        case None =>
            let svc = InstantPageService()
            _globalInstantPageService = Some(svc)
            return svc
    }
}
