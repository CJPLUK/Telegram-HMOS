package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList
import std.collection.HashMap
import kit.CoreFileKit.*

/**
 * WallpaperResourcesService — 云端壁纸资源服务
 *
 * 对应 iOS submodules/WallpaperResources/Sources/WallpaperResources.swift
 *
 * 功能：
 * - account.getWallPapers  — 获取云端壁纸列表
 * - account.getWallPaper   — 按 slug 获取单张壁纸信息
 * - account.getMultiWallPapers — 批量获取多张壁纸
 * - 缓存键派生：wallpaper_<id>_<accessHash>
 * - 委托 FileDownloadService 下载壁纸文件，写入磁盘，返回本地路径
 *
 * 调用链：
 *   getWallPapers(hash)
 *     → MTProtoClient.sendRequest(AccountGetWallPapers.toBytes())
 *     → parseWallPapersResponse()
 *     → [WallpaperItem]
 *
 *   downloadWallpaper(item)
 *     → deriveWallpaperCacheKey(id, accessHash)
 *     → 检查磁盘缓存
 *     → FileDownloadService.downloadDocument(fileId, accessHash, fileRef, dcId)
 *     → 写入 <filesDir>/wallpapers/wallpaper_<id>_<accessHash>
 *     → 返回 file:// 路径
 */

// ─────────────────────────────────────────────────────────────────
// 壁纸数据结构
// ─────────────────────────────────────────────────────────────────

/** 壁纸文件媒体信息（从 Document 中提取的最小集合） */
public class WallpaperDocumentInfo {
    public var fileId: Int64 = 0
    public var accessHash: Int64 = 0
    public var fileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var dcId: Int32 = 0
    public var fileSize: Int64 = 0
    public var mimeType: String = ""
    /**
     * Document.thumbs（Vector<PhotoSize>）里每个条目的 `type` 字符串（如 "s"/"m"/"x"）。
     * 对位 iOS previewRepresentations 的 sizeSpec 集合——渲染侧据此挑一个缩略图变体
     * （通常 "m"）下载，而不是取 mimeType=application/x-tgwallpattern 的文档原件
     * （ArkUI 无该格式解码器，见 TC-0408 round3 RC-B）。
     */
    public var thumbTypes: ArrayList<String> = ArrayList<String>()

    public init() {}
}

/**
 * 从 WallPaperSettings（wallPaperSettings#372efcd0）提取的底色/图案强度参数。
 * 对位 iOS WallpaperSettings（TelegramCore/Sources/ApiUtils/Wallpaper.swift）与
 * SettingsThemeWallpaperNode.swift:155-158 的消费方式：颜色只收已置位的那几个，
 * 不补默认色；渲染侧按 bg → second → third → fourth 顺序取用。
 */
public class WallPaperSettingsInfo {
    public var hasBackgroundColor: Bool = false
    public var backgroundColor: UInt32 = 0
    public var hasSecondBackgroundColor: Bool = false
    public var secondBackgroundColor: UInt32 = 0
    public var hasThirdBackgroundColor: Bool = false
    public var thirdBackgroundColor: UInt32 = 0
    public var hasFourthBackgroundColor: Bool = false
    public var fourthBackgroundColor: UInt32 = 0
    public var hasIntensity: Bool = false
    public var intensity: Int32 = 0
    public var hasRotation: Bool = false
    public var rotation: Int32 = 0
    public var hasEmoticon: Bool = false
    public var emoticon: String = ""

    public init() {}

    /**
     * 按 bg → second → third → fourth 顺序收集已置位的颜色，对位
     * SettingsThemeWallpaperNode.swift:155-157 的 `colors` 语义：只收存在的那几个，
     * 不补默认色。颜色数为 0 时渲染侧应退回占位块（服务端未给 settings）。
     */
    public func colorsArray(): Array<UInt32> {
        let list = ArrayList<UInt32>()
        if (this.hasBackgroundColor) { list.add(this.backgroundColor) }
        if (this.hasSecondBackgroundColor) { list.add(this.secondBackgroundColor) }
        if (this.hasThirdBackgroundColor) { list.add(this.thirdBackgroundColor) }
        if (this.hasFourthBackgroundColor) { list.add(this.fourthBackgroundColor) }
        return list.toArray()
    }
}

/**
 * 壁纸条目
 * 对应 TL WallPaper#A437C5CE 和 WallPaperNoFile#E0804116
 */
public class WallpaperItem {
    /** 壁纸 ID */
    public var id: Int64 = 0
    /** flags 位域 */
    public var flags: Int32 = 0
    /** 访问 Hash（wallPaper 类型有效） */
    public var accessHash: Int64 = 0
    /** slug（wallPaper 类型有效） */
    public var slug: String = ""
    /** 是否有文档（wallPaper 类型为 true） */
    public var hasDocument: Bool = false
    /** 文档信息（hasDocument=true 时有效） */
    public var document: WallpaperDocumentInfo = WallpaperDocumentInfo()
    /** 是否为 creator */
    public var isCreator: Bool = false
    /** 是否已安装 */
    public var isDefault: Bool = false
    /** 是否为图案壁纸 */
    public var isPattern: Bool = false
    /**
     * WallPaperSettings 提取的底色/强度参数（settings:flags.2?WallPaperSettings 未携带时保持
     * 全零默认值，即 colorsArray() 返回空数组）。供渲染侧（shell_settings_wallpaper）合成
     * 「底色 + 图案缩略图」两层网格格子，参见 TC-0408 round3 RC-B 修法方向 F-3。
     */
    public var settings: WallPaperSettingsInfo = WallPaperSettingsInfo()

    // ic_wallpaper_unsave_and_settings_shell_settings_wallpaper: WallPaperSettings#372efcd0
    // 字段（此前 skipWallPaperSettings() 只读不存）。None = 该字段在响应中不存在（对应
    // flags 位未置）；Some(v) = 服务端真实值。second/rotation 共用 flags.4（见
    // parseWallPaperSettingsInto 注释），二者恒同时 Some/同时 None。
    public var settingsBackgroundColor: Option<Int32> = None
    public var settingsSecondBackgroundColor: Option<Int32> = None
    public var settingsThirdBackgroundColor: Option<Int32> = None
    public var settingsFourthBackgroundColor: Option<Int32> = None
    public var settingsIntensity: Option<Int32> = None
    public var settingsRotation: Option<Int32> = None

    public init() {}

    /** 派生磁盘缓存键 */
    public func cacheKey(): String {
        return "wallpaper_" + this.id.toString() + "_" + this.accessHash.toString()
    }
}

/** getWallPapers 响应 */
public class WallpaperListResult {
    public var success: Bool = false
    /** 服务端是否返回 notModified（客户端 hash 未变化） */
    public var notModified: Bool = false
    /** 当前列表的 hash（用于下次增量查询） */
    public var hash: Int64 = 0
    public var items: ArrayList<WallpaperItem> = ArrayList<WallpaperItem>()
    public var errorCode: Int32 = 0
    public var errorMessage: String = ""

    public init() {}
}

// WallPaperSettings ctor（提到文件靠前处：AccountSaveWallPaper.serialize() 需要在定义前使用，
// Cangjie 顶层 let 要求先定义后用，不像 class/func 可跨顺序互相引用）。
let WALLPAPER_SETTINGS_CTOR: UInt32 = 0x372efcd0

// ─────────────────────────────────────────────────────────────────
// TL 方法：AccountGetWallPapers
// account.getWallPapers#07967d36 hash:long = account.WallPapers
// constructor id: 127302966 (signed) = 0x07967d36 (unsigned)
// ─────────────────────────────────────────────────────────────────

class AccountGetWallPapers <: TLObject {
    public var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x07967d36 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.hash)
    }
}

// ─────────────────────────────────────────────────────────────────
// TL 方法：InputWallPaperSlug
// inputWallPaperSlug#72091c80 slug:string = InputWallPaper
// constructor id: 1913199744 (signed) = 0x72091c80 (unsigned)
// ─────────────────────────────────────────────────────────────────

class InputWallPaperSlug <: TLObject {
    public var slug: String = ""

    public func getConstructorId(): UInt32 { return 0x72091c80 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.slug)
    }
}

// ─────────────────────────────────────────────────────────────────
// TL 方法：AccountGetWallPaper
// account.getWallPaper#fc8ddbea wallpaper:InputWallPaper = WallPaper
// constructor id: -57811990 (signed) = 0xfc8ddbea (unsigned)
// ─────────────────────────────────────────────────────────────────

class AccountGetWallPaper <: TLObject {
    public var wallpaper: TLObject = InputWallPaperSlug()

    public func getConstructorId(): UInt32 { return 0xfc8ddbea }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.wallpaper.toBytes())
    }
}

// ─────────────────────────────────────────────────────────────────
// TL 方法：AccountSaveWallPaper（ic_wallpaper_unsave_and_settings_shell_settings_wallpaper）
// account.saveWallPaper#6c5a5b37 wallpaper:InputWallPaper unsave:Bool settings:WallPaperSettings = Bool
// constructor id: 1817860919 (signed) = 0x6c5a5b37 (unsigned)（对位源
// TelegramApi/Sources/Api42.swift:1375 saveWallPaper buffer.appendInt32(1817860919)）。
// unsave=true → 对位源 TelegramCore/Sources/Wallpapers.swift:177 deleteWallpaper（真实取消
// 收藏，而不只是本地会话隐藏）；unsave=false 可复用同一 TLObject 做 saveWallPaper（收藏）。
// settings 字段与 item 当前的 settingsXxx 一一对应回填（Wallpapers.swift:184 原样透传
// file.settings，本类同样把调用方传入的 item 快照的 settings 原样回写，不发明新值）。
// ─────────────────────────────────────────────────────────────────

class AccountSaveWallPaper <: TLObject {
    public var wallpaper: TLObject = InputWallPaperSlug()
    public var unsave: Bool = false
    public var settingsBackgroundColor: Option<Int32> = None
    public var settingsSecondBackgroundColor: Option<Int32> = None
    public var settingsThirdBackgroundColor: Option<Int32> = None
    public var settingsFourthBackgroundColor: Option<Int32> = None
    public var settingsIntensity: Option<Int32> = None
    public var settingsRotation: Option<Int32> = None

    public func getConstructorId(): UInt32 { return 0x6c5a5b37 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.wallpaper.toBytes())
        serializer.writeBool(this.unsave)
        // WallPaperSettings#372efcd0（boxed）—— second_background_color 与 rotation 共用
        // flags.4，与 parseWallPaperSettingsInto() 的读取侧对称：只有二者同时 Some 才置位、
        // 同时写出，不允许只有一个有值（源侧 schema 本就是这样绑定的，见该函数注释）。
        var flags: Int32 = 0
        match (this.settingsBackgroundColor) { case Some(_) => flags = flags | 1; case None => () }
        let pairSet = this.settingsSecondBackgroundColor.isSome() && this.settingsRotation.isSome()
        if (pairSet) { flags = flags | 16 }
        match (this.settingsThirdBackgroundColor) { case Some(_) => flags = flags | 32; case None => () }
        match (this.settingsFourthBackgroundColor) { case Some(_) => flags = flags | 64; case None => () }
        match (this.settingsIntensity) { case Some(_) => flags = flags | 8; case None => () }
        serializer.writeUInt32(WALLPAPER_SETTINGS_CTOR)
        serializer.writeInt32(flags)
        match (this.settingsBackgroundColor) { case Some(v) => serializer.writeInt32(v); case None => () }
        if (pairSet) {
            match (this.settingsSecondBackgroundColor) { case Some(v) => serializer.writeInt32(v); case None => () }
        }
        match (this.settingsThirdBackgroundColor) { case Some(v) => serializer.writeInt32(v); case None => () }
        match (this.settingsFourthBackgroundColor) { case Some(v) => serializer.writeInt32(v); case None => () }
        match (this.settingsIntensity) { case Some(v) => serializer.writeInt32(v); case None => () }
        if (pairSet) {
            match (this.settingsRotation) { case Some(v) => serializer.writeInt32(v); case None => () }
        }
    }
}

// ─────────────────────────────────────────────────────────────────
// 响应解析
// ─────────────────────────────────────────────────────────────────

/**
 * 跳过一个 Document 对象（不解析完整字段，仅提取 fileId/accessHash/dc/size/fileRef/mimeType）
 * document#1E207628 flags:# id:long access_hash:long file_reference:bytes date:int mime_type:string
 *   size:long thumbs:flags.0?Vector<PhotoSize> video_thumbs:flags.1?Vector<VideoSize>
 *   dc_id:int attributes:Vector<DocumentAttribute>
 */
func parseWallpaperDocument(d: TLDeserializer): WallpaperDocumentInfo {
    let info = WallpaperDocumentInfo()
    let flags = d.readInt32()
    info.fileId = d.readInt64()
    info.accessHash = d.readInt64()
    // file_reference: bytes
    info.fileReference = d.readBytes()
    // date: int
    let _ = d.readInt32()
    // mime_type: string
    info.mimeType = d.readString()
    // size: long
    info.fileSize = d.readInt64()
    // thumbs (optional flags.0) — Vector<PhotoSize> 装箱构造子（0x1cb5c415）先读+校验，
    // 对照 TLDialogs.cj:parseDocumentForTypeWithMeta 的 thumbs 分支（:1113-1124）。
    // 之前这里直接把装箱构造子的 4 字节当成 thumbCount 读，得到约 4.8 亿的循环上限，
    // 导致 skipPhotoSizeItem 在剩余缓冲区上失控扫描直至越界（TC-0408/TC-0409 round2 根因）。
    if ((flags & 1) != 0) {
        let thumbsVecCtor = d.readUInt32()
        if (thumbsVecCtor == TLConstructors.VECTOR) {
            let thumbCount = d.readInt32()
            var ti: Int32 = 0
            while (ti < thumbCount) {
                // 字节游标推进逻辑不变（仍是"读 ctor、查表、按格式跳过"）；
                // 唯一新增的是把已经读出来的 type 留下来，供渲染侧挑缩略图变体
                // （TC-0408 round3 RC-B F-3.3：优先 "m"）。
                let thumbType = skipPhotoSizeItem(d)
                if (thumbType.size > 0) {
                    info.thumbTypes.add(thumbType)
                }
                ti = ti + 1
            }
        }
        // 装箱构造子不匹配（不应发生）：字段是可选的，不做猜测性读取，
        // 直接不进入循环，让后续字段继续从当前 offset 解析。
    }
    // video_thumbs (optional flags.1) — 同上模式，对照 TLDialogs.cj:1126-1132。
    if ((flags & 2) != 0) {
        let videoThumbsVecCtor = d.readUInt32()
        if (videoThumbsVecCtor == TLConstructors.VECTOR) {
            let vtCount = d.readInt32()
            var vi: Int32 = 0
            while (vi < vtCount) {
                skipVideoSizeItem(d)
                vi = vi + 1
            }
        }
    }
    // dc_id: int
    info.dcId = d.readInt32()
    // attributes: Vector<DocumentAttribute>（非可选字段，装箱构造子读取不受 flags 位控制）
    // 对照 TLDialogs.cj:1152-1170 的 attrVecConst 分支。
    let attrVecCtor = d.readUInt32()
    if (attrVecCtor == TLConstructors.VECTOR) {
        let attrCount = d.readInt32()
        var ai: Int32 = 0
        while (ai < attrCount) {
            skipDocumentAttribute(d)
            ai = ai + 1
        }
    }
    return info
}

/**
 * 跳过（并保留 type）一个 PhotoSize 条目
 *
 * 构造子表严格对照 core/mtproto/TLDialogs.cj:skipPhotoSize（同仓已验证、被 7+ 处复用的规范实现），
 * 并与 iOS submodules/TelegramApi/Sources/Api0.swift 的构造子字典逐个核对。
 * 之前这里的表是独立手写的，四个构造子全部有误、且完全缺失 photoStrippedSize（0xe0b0bc2e，
 * 每个文档几乎必带的即时模糊预览缩略图），导致该变体落入 unknown 分支后只读了 type:string、
 * 漏读了 bytes:bytes，使 TLDeserializer 的偏移量错位，下一次读取即越界抛异常（TC-0408/TC-0409 根因）。
 *
 * 返回值：每个变体的 `type` 字段（如 "s"/"m"/"x"），供调用方收集 thumbTypes 挑缩略图变体
 * （TC-0408 round3 RC-B F-3.3）；未识别构造子无法安全读出 type，返回空字符串。
 * 字节游标推进逻辑与此前完全一致，只是把已经读出来的 type 值返回而非丢弃。
 *
 *   photoSizeEmpty#0e17e23c type:string
 *   photoSize#75c78e60 type:string w:int h:int size:int
 *   photoCachedSize#021e1ad6 type:string w:int h:int bytes:bytes
 *   photoStrippedSize#e0b0bc2e type:string bytes:bytes
 *   photoSizeProgressive#fa3efb95 type:string w:int h:int sizes:Vector<int>
 *   photoPathSize#d8214d41 / #6f8bf5a0(旧版) type:string bytes:bytes
 */
func skipPhotoSizeItem(d: TLDeserializer): String {
    let ctor = d.readUInt32()
    if (ctor == 0x0e17e23c) {
        // photoSizeEmpty type:string
        let t = d.readString()
        return t
    }
    if (ctor == 0x75c78e60) {
        // photoSize type:string w:int h:int size:int
        let t = d.readString()
        let _ = d.readInt32()
        let _ = d.readInt32()
        let _ = d.readInt32()
        return t
    }
    if (ctor == 0x021e1ad6) {
        // photoCachedSize type:string w:int h:int bytes:bytes
        let t = d.readString()
        let _ = d.readInt32()
        let _ = d.readInt32()
        let _ = d.readBytes()
        return t
    }
    if (ctor == 0xe0b0bc2e) {
        // photoStrippedSize type:string bytes:bytes — 之前完全缺失的变体
        let t = d.readString()
        let _ = d.readBytes()
        return t
    }
    if (ctor == 0xfa3efb95) {
        // photoSizeProgressive type:string w:int h:int sizes:Vector<int>
        let t = d.readString()
        let _ = d.readInt32()
        let _ = d.readInt32()
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let count = d.readInt32()
            var i: Int32 = 0
            while (i < count) {
                let _ = d.readInt32()
                i = i + 1
            }
        }
        return t
    }
    if (ctor == 0xd8214d41 || ctor == 0x6f8bf5a0) {
        // photoPathSize（含旧版 ctor）type:string bytes:bytes
        let t = d.readString()
        let _ = d.readBytes()
        return t
    }
    // 未识别构造子 — 仅记录日志、不做猜测性读取。此时已消费的只有 4 字节 ctor，
    // 猜测式读取（如误当作 type:string 读）只会制造新的偏移错位；与
    // TLDialogs.cj:skipPhotoSize 的 fallback 行为一致。返回空字符串（调用方按 size==0 跳过收集）。
    Hilog.info(0, "CjTelegram", "[skipPhotoSizeItem] Unknown constructor: ${ctor}")
    return ""
}

/**
 * 跳过 VideoSize 条目
 *
 * 构造子表对照 core/mtproto/TLDialogs.cj:skipVideoSize。之前这里把 videoSize#de33b094 与
 * videoSizeEmojiMarkup#f85c413c 合并成同一分支读取，但两者字段结构完全不同
 * （videoSizeEmojiMarkup 是 emoji_id:long + Vector<int>，不含 flags/type/w/h/size），
 * 一旦遇到 videoSizeEmojiMarkup 就会按错误布局读取造成偏移错位。
 *
 *   videoSize#de33b094 / #7be31cfd(旧版) flags:# type:string w:int h:int size:int video_start_ts:flags.0?double
 *   videoSizeEmojiMarkup#f85c413c emoji_id:long background_colors:Vector<int>
 *   videoSizeStickerMarkup#0da082fe stickerset:InputStickerSet sticker_id:long background_colors:Vector<int>
 */
func skipVideoSizeItem(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0xde33b094 || ctor == 0x7be31cfd) {
        let flags = d.readInt32()
        let _ = d.readString()
        let _ = d.readInt32()
        let _ = d.readInt32()
        let _ = d.readInt32()
        if ((flags & 1) != 0) { let _ = d.readDouble() }
        return
    }
    if (ctor == 0xf85c413c) {
        // videoSizeEmojiMarkup — 与 videoSize 结构完全不同，之前被错误合并处理
        let _ = d.readInt64()
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let count = d.readInt32()
            var i: Int32 = 0
            while (i < count) {
                let _ = d.readInt32()
                i = i + 1
            }
        }
        return
    }
    if (ctor == 0x0da082fe) {
        // videoSizeStickerMarkup
        skipBoxedDocAttr(d)  // stickerset (boxed InputStickerSet)
        let _ = d.readInt64()
        let vecCtor = d.readUInt32()
        if (vecCtor == TLConstructors.VECTOR) {
            let count = d.readInt32()
            var i: Int32 = 0
            while (i < count) {
                let _ = d.readInt32()
                i = i + 1
            }
        }
        return
    }
    Hilog.info(0, "CjTelegram", "[skipVideoSizeItem] Unknown constructor: ${ctor}")
}

/**
 * 跳过 DocumentAttribute 条目
 *
 * 构造子表对照 core/mtproto/TLDialogs.cj:skipDocumentAttribute，并与 iOS Api0.swift 的
 * 构造子字典核对。之前的问题：
 * - documentAttributeSticker（0x6319d612）漏读了 flags 位为 1 时才有的可选 MaskCoords（4 个字段），
 *   且与不相关的 0x6c37c15c / 虚构的 0x4f8360 合并成同一分支（0x6c37c15c 已被上面分支捕获，
 *   属死代码；0x4f8360 在真实构造子字典中不存在，已移除）。
 * - documentAttributeVideo 漏掉了当前层构造子 0x43c57c48，且把"中间版本"0xd38ff1c2
 *   误并入旧版 int-duration 布局读取（应为 double-duration + 可选字段布局）。
 * - documentAttributeAudio 漏读了 flags 位控制的可选 title/performer/waveform 字段。
 * - documentAttributeHasStickers（0x9801d2f7）、documentAttributeCustomEmoji（0xfd149899）
 *   完全缺失，落入"未识别、不读任何字节"的静默分支。
 */
func skipDocumentAttribute(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0x6c37c15c) {
        // documentAttributeImageSize w:int h:int
        let _ = d.readInt32()
        let _ = d.readInt32()
        return
    }
    if (ctor == 0x11b58939) {
        // documentAttributeAnimated — no fields
        return
    }
    if (ctor == 0x6319d612) {
        // documentAttributeSticker flags:# mask:flags.1?true alt:string stickerset:InputStickerSet mask_coords:flags.0?MaskCoords
        let flags = d.readInt32()
        let _ = d.readString()  // alt
        skipBoxedDocAttr(d)     // stickerset (boxed InputStickerSet)
        if ((flags & 1) != 0) {
            // MaskCoords: n:int x:double y:double zoom:double
            let _ = d.readInt32()
            let _ = d.readDouble()
            let _ = d.readDouble()
            let _ = d.readDouble()
        }
        return
    }
    if (ctor == 0x43c57c48 || ctor == 0xd38ff1c2) {
        // documentAttributeVideo（当前层 0x43c57c48 / 中间版本 0xd38ff1c2，同一布局）
        // flags:# duration:double w:int h:int preload_prefix_size:flags.2?int
        //   video_start_ts:flags.4?double video_codec:flags.5?string
        let flags = d.readInt32()
        let _ = d.readDouble()
        let _ = d.readInt32()
        let _ = d.readInt32()
        if ((flags & 4) != 0) { let _ = d.readInt32() }
        if ((flags & 16) != 0) { let _ = d.readDouble() }
        if ((flags & 32) != 0) { let _ = d.readString() }
        return
    }
    if (ctor == 0xef02ce6) {
        // documentAttributeVideo（旧版）flags:# duration:int w:int h:int
        let _ = d.readInt32()
        let _ = d.readInt32()
        let _ = d.readInt32()
        let _ = d.readInt32()
        return
    }
    if (ctor == 0x9852f9c6) {
        // documentAttributeAudio flags:# duration:int title:flags.0?string performer:flags.1?string waveform:flags.2?bytes
        let flags = d.readInt32()
        let _ = d.readInt32()
        if ((flags & 1) != 0) { let _ = d.readString() }
        if ((flags & 2) != 0) { let _ = d.readString() }
        if ((flags & 4) != 0) { let _ = d.readBytes() }
        return
    }
    if (ctor == 0x15590068) {
        // documentAttributeFilename file_name:string
        let _ = d.readString()
        return
    }
    if (ctor == 0x9801d2f7) {
        // documentAttributeHasStickers — no fields
        return
    }
    if (ctor == 0xfd149899) {
        // documentAttributeCustomEmoji flags:# free:flags.0?true text_color:flags.1?true alt:string stickerset:InputStickerSet
        let _ = d.readInt32()
        let _ = d.readString()
        skipBoxedDocAttr(d)
        return
    }
    // 未识别构造子 — 仅记录日志，不做猜测性读取（同上，避免二次错位）
    Hilog.info(0, "CjTelegram", "[skipDocumentAttribute] Unknown constructor: ${ctor}")
}

/**
 * 跳过 InputStickerSet（boxed）
 *
 * R-135 返修：本函数之前只覆盖 3/12 个 InputStickerSet union 构造子（Empty/ID/ShortName），
 * 其余 9 个落入"未识别、不读字节"的静默兜底。已用 input/Telegram-iOS/submodules/TelegramApi/Sources/Api0.swift
 * 的 InputStickerSet dict 注册表（12 条，行 529-540）逐一核对全部 12 个构造子，
 * 并用 Api13.swift:1308-1370 的 parse_inputStickerSet* 实现核对每个的真实字段布局：
 *
 *   inputStickerSetAnimatedEmoji#028703c8                       — 无字段（parse 直接 return enum case）
 *   inputStickerSetAnimatedEmojiAnimations#0cde3739              — 无字段
 *   inputStickerSetDice#e67f520e            emoticon:string      — 1 个 string 字段（旧代码会漏读，造成偏移错位）
 *   inputStickerSetEmojiChannelDefaultStatuses#49748553          — 无字段
 *   inputStickerSetEmojiDefaultStatuses#29d0f5ee                 — 无字段
 *   inputStickerSetEmojiDefaultTopicIcons#44c1f8e9                — 无字段
 *   inputStickerSetEmojiGenericAnimations#04c4d4ce                — 无字段
 *   inputStickerSetEmpty#ffb62b95                                 — 无字段（此前已修，值曾误为虚构的 0xd36786db）
 *   inputStickerSetID#9de7a269              id:long access_hash:long
 *   inputStickerSetPremiumGifts#c88b3b02                          — 无字段
 *   inputStickerSetShortName#861cc8a0       short_name:string
 *   inputStickerSetTonGifts#1cf671a0                              — 无字段
 *
 * 8 个"无字段"构造子此前的隐式 unknown 兜底恰好字节安全，但按 R-135 要求改为显式分支枚举，
 * 避免未来任何一个变体升级带字段时重蹈本轮同类缺陷（同一失效方式为 TC-0408 根因）。
 *
 * 对照 core/mtproto/TLDialogs.cj:skipInputStickerSet（1201/1224 两处调用点，其内部实现同样只有
 * 3 个分支、且连 unknown 兜底日志都没有）——该文件不在本 feature allowlist，只读参考，未修改。
 */
func skipBoxedDocAttr(d: TLDeserializer): Unit {
    let ctor = d.readUInt32()
    if (ctor == 0xffb62b95) {
        // inputStickerSetEmpty — no fields
        return
    }
    if (ctor == 0x9de7a269) {
        // inputStickerSetID id:long access_hash:long
        let _ = d.readInt64()
        let _ = d.readInt64()
        return
    }
    if (ctor == 0x861cc8a0) {
        // inputStickerSetShortName short_name:string
        let _ = d.readString()
        return
    }
    if (ctor == 0xe67f520e) {
        // inputStickerSetDice emoticon:string — 字节关键：旧 unknown 兜底会漏读该字段
        let _ = d.readString()
        return
    }
    if (ctor == 0x028703c8) {
        // inputStickerSetAnimatedEmoji — no fields
        return
    }
    if (ctor == 0x0cde3739) {
        // inputStickerSetAnimatedEmojiAnimations — no fields
        return
    }
    if (ctor == 0x49748553) {
        // inputStickerSetEmojiChannelDefaultStatuses — no fields
        return
    }
    if (ctor == 0x29d0f5ee) {
        // inputStickerSetEmojiDefaultStatuses — no fields
        return
    }
    if (ctor == 0x44c1f8e9) {
        // inputStickerSetEmojiDefaultTopicIcons — no fields
        return
    }
    if (ctor == 0x04c4d4ce) {
        // inputStickerSetEmojiGenericAnimations — no fields
        return
    }
    if (ctor == 0xc88b3b02) {
        // inputStickerSetPremiumGifts — no fields
        return
    }
    if (ctor == 0x1cf671a0) {
        // inputStickerSetTonGifts — no fields
        return
    }
    // 未识别构造子 — 仅记录日志，不做猜测性读取（12 个真实构造子已全部显式覆盖，
    // 走到此处说明 schema 出现了新构造子）
    Hilog.info(0, "CjTelegram", "[skipBoxedDocAttr] Unknown constructor: ${ctor}")
}

/**
 * 解析 WallPaperSettings（flags 读取后），把提取到的颜色/强度/旋转写回 item 的
 * settingsXxx Option 字段（ic_wallpaper_unsave_and_settings_shell_settings_wallpaper
 * 修法 2：供本轮新增的 AccountSaveWallPaper 收藏回填读取，见 :962-967）。
 *
 * 本函数与下面的 parseWallPaperSettings() 并存、读取同一段 WallPaperSettings 字节，
 * 但服务两个不同消费者：本函数写 item.settingsXxx（AccountSaveWallPaper 回填），
 * parseWallPaperSettings() 返回 WallPaperSettingsInfo 供 item.settings 渲染消费
 * （WallpaperPickerPage.cj:271-283,714 的 item.settings.colorsArray()/hasIntensity/
 * intensity，TC-0408 round3 修复）。两者都是真实需求，调用方（见下方 parseWallpaperItem()
 * 两处调用点）用 TLDeserializer.getOffset()/setOffset() 复位游标各调一次，不丢失任一侧数据；
 * 两个函数体本身互不修改。
 *
 * wallPaperSettings#372efcd0 flags:#
 *   background_color:flags.0?int
 *   second_background_color:flags.4?int
 *   third_background_color:flags.5?int
 *   fourth_background_color:flags.6?int
 *   intensity:flags.3?int
 *   rotation:flags.4?int
 *   emoticon:flags.7?string
 *
 * NOTE: 调用前已读取 ctor；此处读取 flags 及所有可选字段。source 侧 Api30.swift:2113-2222
 * 逐字段核实：second_background_color 与 rotation 确实共用 flags.4（并非笔误），二者恒同时
 * 存在/同时缺失，不得拆成两个独立哨兵位。emoticon 暂不建模到 WallpaperItem（本契约
 * required_outcomes 只要求颜色/强度/旋转字段，emoticon 是表情壁纸标识，不在本轮范围）。
 */
func parseWallPaperSettingsInto(d: TLDeserializer, item: WallpaperItem): Unit {
    let flags = d.readInt32()
    // flags.0 → background_color
    if ((flags & 1) != 0) { item.settingsBackgroundColor = Some(d.readInt32()) }
    // flags.4 → second_background_color
    if ((flags & 16) != 0) { item.settingsSecondBackgroundColor = Some(d.readInt32()) }
    // flags.5 → third_background_color
    if ((flags & 32) != 0) { item.settingsThirdBackgroundColor = Some(d.readInt32()) }
    // flags.6 → fourth_background_color
    if ((flags & 64) != 0) { item.settingsFourthBackgroundColor = Some(d.readInt32()) }
    // flags.3 → intensity
    if ((flags & 8) != 0) { item.settingsIntensity = Some(d.readInt32()) }
    // flags.4 → rotation (same bit as second_background_color — both read if bit set)
    if ((flags & 16) != 0) { item.settingsRotation = Some(d.readInt32()) }
    // flags.7 → emoticon（不建模，仅按位跳过，保持反序列化游标正确前进）
    if ((flags & 128) != 0) { let _ = d.readString() }
}

/**
 * 解析 WallPaperSettings（flags 读取后）——之前叫 skipWallPaperSettings，逐字段读出后
 * 全部 `let _ = ...` 丢弃；TC-0408 round3 RC-B 指出这是格子拿不到底色层的直接原因
 * （案文 §C2：本 suite 的壁纸是运行时绘制的纯色/渐变底 + 需下载的图案层，不是位图 asset）。
 * 读取顺序、位掩码、字段个数与旧版 skipWallPaperSettings 逐字一致，只把丢弃改成赋值。
 *
 * NOTE: 调用前已读取 ctor；此处读取 flags 及所有可选字段。颜色字段用 readUInt32() 而非
 * readInt32() 读取——与 readInt32() 消费的字节完全相同（同一个 4 字节小端读取，仅返回值的
 * 有无符号解释不同），直接得到 UInt32 供渲染侧 WallpaperType 颜色数组（如
 * WallpaperBackgroundComponent.gradientColors: Array<UInt32>）使用，无需额外位模式转换。
 */
func parseWallPaperSettings(d: TLDeserializer): WallPaperSettingsInfo {
    let info = WallPaperSettingsInfo()
    let flags = d.readInt32()
    // flags.0 → background_color
    if ((flags & 1) != 0) {
        info.hasBackgroundColor = true
        info.backgroundColor = d.readUInt32()
    }
    // flags.4 → second_background_color
    if ((flags & 16) != 0) {
        info.hasSecondBackgroundColor = true
        info.secondBackgroundColor = d.readUInt32()
    }
    // flags.5 → third_background_color
    if ((flags & 32) != 0) {
        info.hasThirdBackgroundColor = true
        info.thirdBackgroundColor = d.readUInt32()
    }
    // flags.6 → fourth_background_color
    if ((flags & 64) != 0) {
        info.hasFourthBackgroundColor = true
        info.fourthBackgroundColor = d.readUInt32()
    }
    // flags.3 → intensity
    if ((flags & 8) != 0) {
        info.hasIntensity = true
        info.intensity = d.readInt32()
    }
    // flags.4 → rotation (same bit as second_background_color — both read if bit set)
    if ((flags & 16) != 0) {
        info.hasRotation = true
        info.rotation = d.readInt32()
    }
    // flags.7 → emoticon
    if ((flags & 128) != 0) {
        info.hasEmoticon = true
        info.emoticon = d.readString()
    }
    return info
}

// WallPaper constructors
// wallPaper#a437c3ed (iOS: -1539849235 = 0xa437c3ed)
let WALLPAPER_CTOR: UInt32        = 0xa437c3ed
// wallPaperNoFile#e0804116 (iOS: -528465642 = 0xe0804116)
let WALLPAPER_NOFILE_CTOR: UInt32 = 0xe0804116

// account.WallPapers constructors
// account.wallPapers#cdc3858c (iOS: -842824308 = 0xcdc3858c)
let ACCOUNT_WALLPAPERS_CTOR: UInt32          = 0xcdc3858c
// account.wallPapersNotModified#1c199183 (iOS: 471437699)
let ACCOUNT_WALLPAPERS_NOT_MODIFIED_CTOR: UInt32 = 0x1c199183

/**
 * 解析单个 WallPaper 条目（不含 ctor，ctor 已在调用方读取）
 */
func parseWallpaperItem(ctor: UInt32, d: TLDeserializer): WallpaperItem {
    let item = WallpaperItem()
    if (ctor == WALLPAPER_CTOR) {
        // wallPaper#A437C5CE id:long flags:# access_hash:long slug:string document:Document settings:flags.2?WallPaperSettings
        item.id = d.readInt64()
        item.flags = d.readInt32()
        item.accessHash = d.readInt64()
        item.slug = d.readString()
        item.hasDocument = true
        item.isCreator = (item.flags & 1) != 0
        item.isDefault = (item.flags & 2) != 0
        item.isPattern = (item.flags & 8) != 0
        // document (boxed) — document#8fd4c4d8
        let docCtor = d.readUInt32()
        if (docCtor == 0x8fd4c4d8) {
            item.document = parseWallpaperDocument(d)
        }
        // settings (optional flags.2)
        if ((item.flags & 4) != 0) {
            let settingsCtor = d.readUInt32()
            if (settingsCtor == WALLPAPER_SETTINGS_CTOR) {
                // 两个消费者读同一段 WallPaperSettings 字节：先跑 parseWallPaperSettings()
                // 拿 item.settings（渲染消费），复位游标后再跑 parseWallPaperSettingsInto()
                // 写 item.settingsXxx（AccountSaveWallPaper 回填消费）。两个函数体均不改动，
                // 只在此处用 getOffset()/setOffset() 复用同一段字节，详见上方两函数的文档注释。
                let settingsOffset = d.getOffset()
                item.settings = parseWallPaperSettings(d)
                d.setOffset(settingsOffset)
                parseWallPaperSettingsInto(d, item)
            }
        }
    } else if (ctor == WALLPAPER_NOFILE_CTOR) {
        // wallPaperNoFile#E0804116 id:long flags:# settings:flags.2?WallPaperSettings
        item.id = d.readInt64()
        item.flags = d.readInt32()
        item.hasDocument = false
        item.isCreator = (item.flags & 1) != 0
        item.isDefault = (item.flags & 2) != 0
        // settings (optional flags.2) — wallPaperNoFile 类型除了 settings 什么都没有，
        // 这类条目要能画出内容（纯色/渐变底），必须挂上 item.settings。
        if ((item.flags & 4) != 0) {
            let settingsCtor = d.readUInt32()
            if (settingsCtor == WALLPAPER_SETTINGS_CTOR) {
                // 两个消费者读同一段 WallPaperSettings 字节：先跑 parseWallPaperSettings()
                // 拿 item.settings（渲染消费），复位游标后再跑 parseWallPaperSettingsInto()
                // 写 item.settingsXxx（AccountSaveWallPaper 回填消费）。两个函数体均不改动，
                // 只在此处用 getOffset()/setOffset() 复用同一段字节，详见上方两函数的文档注释。
                let settingsOffset = d.getOffset()
                item.settings = parseWallPaperSettings(d)
                d.setOffset(settingsOffset)
                parseWallPaperSettingsInto(d, item)
            }
        }
    }
    return item
}

/**
 * 解析 account.getWallPapers 响应
 */
public func parseWallPapersResponse(data: Array<Byte>): WallpaperListResult {
    let result = WallpaperListResult()
    if (data.size < 4) {
        result.errorMessage = "empty_response"
        return result
    }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
        result.errorCode = d.readInt32()
        result.errorMessage = d.readString()
        return result
    }
    if (ctor == ACCOUNT_WALLPAPERS_NOT_MODIFIED_CTOR) {
        result.success = true
        result.notModified = true
        return result
    }
    if (ctor != ACCOUNT_WALLPAPERS_CTOR) {
        Hilog.info(0, "CjTelegram", "[WallpaperSvc] Unknown ctor for wallpapers response")
        result.errorMessage = "unknown_ctor"
        return result
    }
    // account.wallPapers#CCAD8CCC hash:long wallpapers:Vector<WallPaper>
    result.hash = d.readInt64()
    // Vector boxed: 0x1cb5c415
    let vectorCtor = d.readUInt32()
    if (vectorCtor != 0x1cb5c415) {
        result.errorMessage = "missing_vector"
        return result
    }
    let count = d.readInt32()
    var i: Int32 = 0
    while (i < count) {
        let itemCtor = d.readUInt32()
        let item = parseWallpaperItem(itemCtor, d)
        result.items.add(item)
        i = i + 1
    }
    result.success = true
    Hilog.info(0, "CjTelegram", "[WallpaperSvc] Parsed wallpapers list, count=${count}")
    return result
}

/**
 * 解析 account.getWallPaper 单张壁纸响应
 */
public func parseSingleWallPaperResponse(data: Array<Byte>): WallpaperItem {
    let item = WallpaperItem()
    if (data.size < 4) { return item }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
        return item
    }
    if (ctor == WALLPAPER_CTOR || ctor == WALLPAPER_NOFILE_CTOR) {
        return parseWallpaperItem(ctor, d)
    }
    return item
}

// ─────────────────────────────────────────────────────────────────
// 服务单例
// ─────────────────────────────────────────────────────────────────

private var _wallpaperResourcesServiceInstance: Option<WallpaperResourcesService> = None

public func getWallpaperResourcesService(): WallpaperResourcesService {
    match (_wallpaperResourcesServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = WallpaperResourcesService()
            _wallpaperResourcesServiceInstance = Some(inst)
            return inst
    }
}

// ─────────────────────────────────────────────────────────────────
// WallpaperResourcesService
// ─────────────────────────────────────────────────────────────────

public class WallpaperResourcesService {
    /** 内存缓存：cacheKey → 本地文件路径 */
    private var _localPathCache: HashMap<String, String> = HashMap<String, String>()

    // ── 壁纸列表 ────────────────────────────────────────────────

    /**
     * 获取云端壁纸列表
     *
     * 调用链：
     *   MTProtoClient.sendRequest(AccountGetWallPapers)
     *   → parseWallPapersResponse()
     *   → WallpaperListResult
     *
     * @param hash  上次响应的 hash（0 表示首次请求）；
     *              服务端相同则返回 notModified=true
     */
    public func getWallPapers(hash!: Int64 = 0): WallpaperListResult {
        Hilog.info(0, "CjTelegram", "[WallpaperSvc] getWallPapers hash=${hash}")
        let req = AccountGetWallPapers()
        req.hash = hash
        let client = getMTProtoClient()
        let responseData = client.sendRequest(req.toBytes())
        return parseWallPapersResponse(responseData)
    }

    /**
     * 按 slug 获取单张壁纸信息
     *
     * 调用链：
     *   MTProtoClient.sendRequest(AccountGetWallPaper(InputWallPaperSlug(slug)))
     *   → parseSingleWallPaperResponse()
     *   → WallpaperItem
     *
     * @param slug  壁纸 slug（如 "fqeXCsBAAAA"）
     */
    public func getWallPaper(slug: String): WallpaperItem {
        Hilog.info(0, "CjTelegram", "[WallpaperSvc] getWallPaper slug=${slug}")
        let inputSlug = InputWallPaperSlug()
        inputSlug.slug = slug
        let req = AccountGetWallPaper()
        req.wallpaper = inputSlug
        let client = getMTProtoClient()
        let responseData = client.sendRequest(req.toBytes())
        return parseSingleWallPaperResponse(responseData)
    }

    // ── 收藏/取消收藏（account.saveWallPaper） ──────────────────────
    // ic_wallpaper_unsave_and_settings_shell_settings_wallpaper 修法 1：真正的服务端
    // 取消收藏调用，对位 TelegramCore/Sources/Wallpapers.swift:177 deleteWallpaper /
    // :173 saveWallpaper（同一 TL 方法，unsave 参数区分方向）。settings 字段原样透传
    // item 当前快照（Wallpapers.swift:184 同样原样透传 file.settings，不重新构造）。

    /**
     * 从用户「已收藏壁纸」列表中移除（真实服务端调用，非本地会话隐藏）。
     * @param item 待取消收藏的壁纸（必须有 slug，wallPaperNoFile 无 slug 时无法定位，返回 false）
     */
    public func unsaveWallPaper(item: WallpaperItem): Bool {
        return this.saveOrUnsaveWallPaper(item, true)
    }

    /** 加入用户「已收藏壁纸」列表（与 unsaveWallPaper 对称，供未来收藏流程复用）。 */
    public func saveWallPaper(item: WallpaperItem): Bool {
        return this.saveOrUnsaveWallPaper(item, false)
    }

    private func saveOrUnsaveWallPaper(item: WallpaperItem, unsave: Bool): Bool {
        if (item.slug.size == 0) {
            Hilog.info(0, "CjTelegram", "[WallpaperSvc] saveOrUnsaveWallPaper: empty slug, cannot target server-side (wallPaperNoFile item?)")
            return false
        }
        Hilog.info(0, "CjTelegram", "[WallpaperSvc] saveOrUnsaveWallPaper slug=${item.slug} unsave=${unsave}")
        let inputSlug = InputWallPaperSlug()
        inputSlug.slug = item.slug
        let req = AccountSaveWallPaper()
        req.wallpaper = inputSlug
        req.unsave = unsave
        req.settingsBackgroundColor = item.settingsBackgroundColor
        req.settingsSecondBackgroundColor = item.settingsSecondBackgroundColor
        req.settingsThirdBackgroundColor = item.settingsThirdBackgroundColor
        req.settingsFourthBackgroundColor = item.settingsFourthBackgroundColor
        req.settingsIntensity = item.settingsIntensity
        req.settingsRotation = item.settingsRotation
        try {
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size >= 4) {
                let d = TLDeserializer(responseData)
                let ctor = d.readUInt32()
                if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                    let errorCode = d.readInt32()
                    let errorMsg = d.readString()
                    Hilog.info(0, "CjTelegram", "[WallpaperSvc] saveOrUnsaveWallPaper error: ${errorCode} ${errorMsg}")
                    return false
                }
                return ctor == TLConstructors.BOOL_TRUE
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[WallpaperSvc] saveOrUnsaveWallPaper exception: ${e}")
        }
        return false
    }

    // ── 缓存键派生 ───────────────────────────────────────────────

    /**
     * 派生壁纸文件磁盘缓存键
     *
     * 格式：wallpaper_<id>_<accessHash>
     * 与 iOS CachedPreparedPatternWallpaperRepresentation.uniqueId 保持语义一致。
     *
     * @param id          壁纸 ID
     * @param accessHash  访问 Hash
     */
    public func deriveWallpaperCacheKey(id: Int64, accessHash: Int64): String {
        return "wallpaper_" + id.toString() + "_" + accessHash.toString()
    }

    // ── 本地路径查询 ────────────────────────────────────────────

    /**
     * 查询壁纸文件的本地缓存路径（不触发下载）
     *
     * @param cacheKey  由 deriveWallpaperCacheKey 派生的键
     * @return 本地 file:// 路径；若未缓存返回空字符串
     */
    public func getCachedLocalPath(cacheKey: String): String {
        if (_localPathCache.contains(cacheKey)) {
            return _localPathCache[cacheKey]
        }
        let path = buildWallpaperFilePath(cacheKey)
        var fileExists = false
        try {
            fileExists = FileIo.access(path)
        } catch (_e: Exception) {
            fileExists = false
        }
        if (fileExists) {
            _localPathCache[cacheKey] = "file://" + path
            return "file://" + path
        }
        return ""
    }

    /**
     * 判断壁纸文件是否已缓存到本地磁盘
     *
     * @param cacheKey  缓存键
     */
    public func hasCachedWallpaper(cacheKey: String): Bool {
        return getCachedLocalPath(cacheKey).size > 0
    }

    // ── 下载 ────────────────────────────────────────────────────

    /**
     * 下载壁纸文件并写入磁盘，返回本地 file:// URI
     *
     * 下载委托给 FileDownloadService（→ MTProtoClient UploadGetFile）。
     * 下载完成后写入 <filesDir>/wallpapers/<cacheKey> 并更新内存缓存。
     *
     * @param item  WallpaperItem（必须有 hasDocument=true）
     * @return 本地 file:// 路径；失败返回空字符串
     */
    public func downloadWallpaper(item: WallpaperItem): String {
        if (!item.hasDocument) {
            Hilog.info(0, "CjTelegram", "[WallpaperSvc] downloadWallpaper: no document for id=${item.id}")
            return ""
        }
        let key = item.cacheKey()
        let cached = getCachedLocalPath(key)
        if (cached.size > 0) {
            Hilog.info(0, "CjTelegram", "[WallpaperSvc] downloadWallpaper: cache hit key=${key}")
            return cached
        }
        Hilog.info(0, "CjTelegram", "[WallpaperSvc] downloadWallpaper: downloading id=${item.id} dc=${item.document.dcId}")
        let downloadSvc = getFileDownloadService()
        let data = downloadSvc.downloadDocument(
            item.document.fileId,
            item.document.accessHash,
            item.document.fileReference,
            item.document.dcId,
            fileSize: item.document.fileSize
        )
        if (data.size == 0) {
            Hilog.info(0, "CjTelegram", "[WallpaperSvc] downloadWallpaper: empty data for id=${item.id}")
            return ""
        }
        let localPath = saveWallpaperData(key, data)
        if (localPath.size > 0) {
            let uri = "file://" + localPath
            _localPathCache[key] = uri
            Hilog.info(0, "CjTelegram", "[WallpaperSvc] downloadWallpaper: saved to ${localPath}")
            return uri
        }
        return ""
    }

    /**
     * 派生壁纸缩略图（图案层）的磁盘缓存键——在整份文档的 cacheKey 基础上加 "_thumb" 后缀，
     * 与 downloadWallpaper() 走的全量文档缓存互不冲突（TC-0410 全屏预览 / applyCloudWallpaper()
     * 仍需要全量文档，两条路径独立缓存、互不覆盖）。
     */
    public func deriveWallpaperThumbCacheKey(id: Int64, accessHash: Int64): String {
        return this.deriveWallpaperCacheKey(id, accessHash) + "_thumb"
    }

    /**
     * 查询本地缓存路径，且额外校验文件非空（对位 ChatRoomViewModel.usableMediaFile() 的既有做法）。
     *
     * getCachedLocalPath() 只判 FileIo.access(path) 存在性；一次中断的缩略图写入会在磁盘上
     * 留下一个 0 字节文件，若沿用只判存在性的检查，会被永久当成"已缓存"却画不出任何内容。
     * 供本类内部的缩略图缓存命中路径使用，也供渲染侧（shell_settings_wallpaper 的缩略图版
     * getCachedCloudWallpaperUri）复用，避免各自重复实现同一个非空校验。
     *
     * @param cacheKey  缓存键
     * @return 本地 file:// 路径；未缓存或缓存文件为空返回空字符串
     */
    public func getCachedLocalPathNonEmpty(cacheKey: String): String {
        let path = buildWallpaperFilePath(cacheKey)
        var usable = false
        try {
            usable = FileIo.access(path) && FileIo.stat(path).size > 0
        } catch (_e: Exception) {
            usable = false
        }
        if (usable) {
            let uri = "file://" + path
            _localPathCache[cacheKey] = uri
            return uri
        }
        return ""
    }

    /**
     * 下载壁纸文档的缩略图变体（图案层），返回本地 file:// URI
     *
     * 对位 downloadWallpaper()，但走 FileDownloadService.downloadDocumentThumb()（已存在、
     * 默认 thumbSize="m"）而非 downloadDocument()，取的是 sizeSpec:"m" 的栅格缩略图而不是
     * mimeType=application/x-tgwallpattern 的文档原件——ArkUI 没有该格式的解码器，直接把
     * 原件喂给 Image() 是 TC-0408 round3 RC-B 的根因之一（见 :530 parseWallPaperSettings
     * 同批修法方向文档头部注释）。
     *
     * thumbSize 从 item.document.thumbTypes 里挑：优先精确匹配 "m"；没有 "m" 时取列表最后
     * 一个（通常是尺寸最大的变体，比 "s" 更接近源侧 sizeSpec:"m" 的效果）；thumbTypes 为空
     * （文档未带 thumbs 字段）时仍尝试用 FileDownloadService 的默认值 "m" 请求一次，让服务端
     * 决定是否有该变体可用，失败则返回空字符串（调用方据此退回占位/纯色底层，不崩溃）。
     *
     * @param item  WallpaperItem（必须有 hasDocument=true）
     * @return 本地 file:// 路径；失败返回空字符串
     */
    public func downloadWallpaperThumb(item: WallpaperItem): String {
        if (!item.hasDocument) {
            Hilog.info(0, "CjTelegram", "[WallpaperSvc] downloadWallpaperThumb: no document for id=${item.id}")
            return ""
        }
        let key = this.deriveWallpaperThumbCacheKey(item.id, item.accessHash)
        let cached = getCachedLocalPathNonEmpty(key)
        if (cached.size > 0) {
            Hilog.info(0, "CjTelegram", "[WallpaperSvc] downloadWallpaperThumb: cache hit key=${key}")
            return cached
        }
        var thumbSize = "m"
        var foundM = false
        for (t in item.document.thumbTypes) {
            if (t == "m") { foundM = true }
        }
        if (!foundM && item.document.thumbTypes.size > 0) {
            thumbSize = item.document.thumbTypes[item.document.thumbTypes.size - 1]
        }
        Hilog.info(0, "CjTelegram",
            "[WallpaperSvc] downloadWallpaperThumb: downloading id=${item.id} thumbSize=${thumbSize}")
        let downloadSvc = getFileDownloadService()
        let data = downloadSvc.downloadDocumentThumb(
            item.document.fileId,
            item.document.accessHash,
            item.document.fileReference,
            thumbSize: thumbSize,
            dcId: item.document.dcId
        )
        if (data.size == 0) {
            Hilog.info(0, "CjTelegram", "[WallpaperSvc] downloadWallpaperThumb: empty data for id=${item.id}")
            return ""
        }
        let localPath = saveWallpaperData(key, data)
        if (localPath.size > 0) {
            let uri = "file://" + localPath
            _localPathCache[key] = uri
            Hilog.info(0, "CjTelegram", "[WallpaperSvc] downloadWallpaperThumb: saved to ${localPath}")
            return uri
        }
        return ""
    }

    /**
     * 使指定缓存键的内存缓存失效（磁盘文件保留）
     *
     * @param cacheKey  缓存键
     */
    public func invalidateMemoryCache(cacheKey: String): Unit {
        if (_localPathCache.contains(cacheKey)) {
            _localPathCache.remove(cacheKey)
        }
    }

    // ── 私有辅助 ────────────────────────────────────────────────

    private func buildWallpaperFilePath(cacheKey: String): String {
        let filesDir = getAppFilesDir()
        let dir = filesDir + "/wallpapers"
        try {
            if (!FileIo.access(dir)) {
                FileIo.mkdir(dir)
            }
        } catch (_e: Exception) {
            try { FileIo.mkdir(dir) } catch (_e2: Exception) {}
        }
        return dir + "/" + cacheKey
    }

    private func saveWallpaperData(cacheKey: String, data: Array<Byte>): String {
        let path = buildWallpaperFilePath(cacheKey)
        if (path.size == 0) { return "" }
        try {
            let fd = FileIo.open(path, mode: 0o1101)
            FileIo.write(fd.fd, data)
            FileIo.close(fd)
            return path
        } catch (_e: Exception) {
            Hilog.info(0, "CjTelegram", "[WallpaperSvc] saveWallpaperData: write failed for ${cacheKey}")
            return ""
        }
    }
}
