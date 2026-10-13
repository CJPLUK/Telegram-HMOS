package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.MediaLibraryKit.*
import kit.ArkData.*
import kit.CoreFileKit.*
import ohos.callback_invoke.*
import ohos.business_exception.BusinessException
import ohos_app_cangjie_entry.utils.copyText as pasteboardCopyText
import kit.ArkUI.launch
import std.collection.{ArrayList, HashSet}
import std.sync.ReentrantMutex
import std.convert.*

/**
 * 保存到相册服务（Save To Camera Roll）
 *
 * 对应 iOS SaveToCameraRoll.swift — 使用 HarmonyOS photoAccessHelper 替代 PHPhotoLibrary。
 * iOS 侧通过 MTProto 下载媒体数据后调用 PHPhotoLibrary；HarmonyOS 侧直接通过
 * photoAccessHelper 将已下载到本地的文件（file:// URI）保存到系统相册。
 * MTProto: N/A — 保存到相册是本地 API 调用，不涉及网络请求。
 * 媒体文件须在调用前通过 FileDownloadService 完成下载并保存到本地文件系统。
 *
 * Autosave config:
 * - autosavePrivateChats  — 自动保存来自私聊的媒体（对应 iOS MediaAutoSaveSettings contacts/otherPrivate）
 * - autosaveGroups        — 自动保存来自群组的媒体（对应 iOS MediaAutoSaveSettings groups）
 * - autosaveChannels      — 自动保存来自频道的媒体（对应 iOS MediaAutoSaveSettings channels）
 *
 * 存储使用独立 Preferences store "telegram_autosave"，通过 getGlobalAbilityContext() 懒加载。
 *
 * 权限治理返修（gallery-nopermission，跨 feature 用户授权治理）：
 * 历史 saveImageToGallery/saveVideoToGallery 使用
 * MediaAssetChangeRequest.createImageAssetRequest/createVideoAssetRequest + applyChanges，
 * 需要调用者持有 ohos.permission.WRITE_IMAGEVIDEO（availableLevel=system_basic，普通
 * apl:normal 签名档位下 signed HAP 装不上，见 ImageViewer.cj saveCurrentImage() 文档注释的
 * rework1 记录）。本轮对齐 ImageViewer.cj 已验证先例（TC-0024 rework2），改为
 * photoAccessHelper.showAssetsCreationDialog（cangjie-kb doc_id
 * cjlang_ohos_..._cj-apis-file-photo_access_helper，起始版本 22）：拉起系统"保存确认"弹窗，
 * 用户同意后返回已授予保存权限的 uri 列表，属一次性用户同意交互，不需要声明/申请
 * WRITE_IMAGEVIDEO AccessToken 权限。因该 API 是异步回调式（不是同步返回 Bool），
 * saveImageToGallery/saveVideoToGallery 的签名从 `(String): Bool` 改为
 * `(String, (Bool) -> Unit): Unit`（回调在主线程 launch 内触发，调用方无需自行切线程）。
 */

// showAssetsCreationDialog srcFileUri 的 bundleName authority（与 AppScope/app.json5 一致）
private let SAVE_URI_BUNDLE: String = "com.hmcangjie.telegram"

// Preferences key 常量（autosave config）
private let KEY_AUTOSAVE_PRIVATE: String  = "autosave_private_chats"
private let KEY_AUTOSAVE_GROUPS: String   = "autosave_groups"
private let KEY_AUTOSAVE_CHANNELS: String = "autosave_channels"
private let AUTOSAVE_MEDIA_STORE: String = "telegram_autosave_media"

// ── S7-95: 自动保存配置例外表（原定义于 pages/SaveIncomingMediaPage.cj，移至此处作为唯一权威定义，
// 供下载完成时的自动保存判定与设置页共用；store `telegram_autosave_media` 键 `<peerType>_exceptions`）──
public class MediaAutoSaveException {
    public var peerId: Int64 = 0
    public var photo: Bool = false
    public var video: Bool = false
    public var maximumVideoSize: Int64 = 100 * 1024 * 1024
    public init(peerId!: Int64, photo!: Bool, video!: Bool, maximumVideoSize!: Int64) {
        this.peerId = peerId
        this.photo = photo
        this.video = video
        this.maximumVideoSize = maximumVideoSize
    }
}

// 持久化编码：`<peerId>:<photo01>:<video01>:<maxSize>` 项，`;` 分隔（FIX-B-1 简化格式，
// 语义与 JSON 数组等价，避免引入通用 JSON 序列化依赖）。顺序即插入顺序即渲染顺序——
// 新增例外插到表头（`;` join 前 ArrayList 已按 D-125 惯例整体重赋值，见 persistExceptions()
// 调用点）。
public func encodeMediaAutoSaveExceptions(list: ArrayList<MediaAutoSaveException>): String {
    var out = ""
    var i: Int64 = 0
    while (i < list.size) {
        if (i > 0) { out = out + ";" }
        let e = list[i]
        let p = if (e.photo) { "1" } else { "0" }
        let v = if (e.video) { "1" } else { "0" }
        out = out + "${e.peerId}:${p}:${v}:${e.maximumVideoSize}"
        i += 1
    }
    return out
}

public func decodeMediaAutoSaveExceptions(raw: String): ArrayList<MediaAutoSaveException> {
    let out = ArrayList<MediaAutoSaveException>()
    if (raw.size == 0) { return out }
    let parts = raw.split(";")
    var i: Int64 = 0
    while (i < parts.size) {
        let trimmed = parts[i].trimAscii()
        if (trimmed.size > 0) {
            let fields = trimmed.split(":")
            if (fields.size == 4) {
                try {
                    let pid = Int64.parse(fields[0])
                    let photo = fields[1] != "0"
                    let video = fields[2] != "0"
                    let size = Int64.parse(fields[3])
                    out.add(MediaAutoSaveException(peerId: pid, photo: photo, video: video, maximumVideoSize: size))
                } catch (_e: Exception) {}
            }
        }
        i += 1
    }
    return out
}

private var _saveToCameraRollServiceInstance: Option<SaveToCameraRollService> = None

public func getSaveToCameraRollService(): SaveToCameraRollService {
    match (_saveToCameraRollServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = SaveToCameraRollService()
            _saveToCameraRollServiceInstance = Some(inst)
            return inst
    }
}

public class SaveToCameraRollService {

    // ──────────────────────── autosave config CRUD ────────────────────────

    /**
     * 保存"自动保存私聊媒体"开关
     * iOS 对应: MediaAutoSaveSettings — contacts / otherPrivate
     */
    public func saveAutosavePrivateChats(enabled: Bool): Unit {
        this.setBoolPref(KEY_AUTOSAVE_PRIVATE, enabled)
        Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] autosavePrivateChats=${enabled}")
    }

    /**
     * 读取"自动保存私聊媒体"开关（默认 false）
     */
    public func getAutosavePrivateChats(): Bool {
        return this.getBoolPref(KEY_AUTOSAVE_PRIVATE, false)
    }

    /**
     * 保存"自动保存群组媒体"开关
     * iOS 对应: MediaAutoSaveSettings — groups
     */
    public func saveAutosaveGroups(enabled: Bool): Unit {
        this.setBoolPref(KEY_AUTOSAVE_GROUPS, enabled)
        Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] autosaveGroups=${enabled}")
    }

    /**
     * 读取"自动保存群组媒体"开关（默认 false）
     */
    public func getAutosaveGroups(): Bool {
        return this.getBoolPref(KEY_AUTOSAVE_GROUPS, false)
    }

    /**
     * 保存"自动保存频道媒体"开关
     * iOS 对应: MediaAutoSaveSettings — channels
     */
    public func saveAutosaveChannels(enabled: Bool): Unit {
        this.setBoolPref(KEY_AUTOSAVE_CHANNELS, enabled)
        Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] autosaveChannels=${enabled}")
    }

    /**
     * 读取"自动保存频道媒体"开关（默认 false）
     */
    public func getAutosaveChannels(): Bool {
        return this.getBoolPref(KEY_AUTOSAVE_CHANNELS, false)
    }

    /**
     * Rich MediaAutoSaveSettings storage shared by the settings pages and the media pipeline.
     * Keys follow Telegram's peer-type configuration shape:
     * `<private|groups|channels>_<photo|video|max_video_size|exceptions|migrated>`.
     * Keeping access here prevents the root page and detail pages from growing independent
     * preference models for the same source-side setting.
     */
    public func getMediaSettingInt(key: String, defaultValue: Int64): Int64 {
        match (getGlobalAbilityContext()) {
            case None => return defaultValue
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, AUTOSAVE_MEDIA_STORE)
                    match (prefs.get(key, PreferencesValueType.Integer(defaultValue))) {
                        case PreferencesValueType.Integer(value) => return value
                        case _ => return defaultValue
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] getMediaSettingInt(${key}) error: ${e}")
                    return defaultValue
                }
        }
    }

    // ──────────────────────── S7-95: incoming media autosave ────────────────────────

    /**
     * iOS StoreDownloadedMedia.swift:60-123 的判定对位：peer 例外优先，否则按 peer 类型取
     * MediaAutoSaveConfiguration（私聊 users / 基础群与超级群 groups / 广播频道 channels），
     * 图片看 configuration.photo。配置存于 SaveIncomingMediaPage 写入的 store
     * `telegram_autosave_media`（`<prefix>_photo`；尚未迁移时回退旧单 Bool）。
     *
     * @param peerType  "user" | "chat" | "channel"
     */
    public func shouldAutosavePhoto(peerType: String, peerId: Int64, isBroadcast: Bool): Bool {
        let prefix = match (peerType) {
            case "user" => "private"
            case "chat" => "groups"
            case "channel" => if (isBroadcast) { "channels" } else { "groups" }
            case _ => ""
        }
        if (prefix.isEmpty()) { return false }
        match (getGlobalAbilityContext()) {
            case None => return false
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_autosave_media")
                    match (prefs.get("${prefix}_exceptions", PreferencesValueType.StringData(""))) {
                        case PreferencesValueType.StringData(raw) =>
                            for (e in decodeMediaAutoSaveExceptions(raw)) {
                                if (e.peerId == peerId) { return e.photo }
                            }
                        case _ => ()
                    }
                    var migrated = false
                    match (prefs.get("${prefix}_migrated", PreferencesValueType.Integer(0))) {
                        case PreferencesValueType.Integer(n) => migrated = n != 0
                        case _ => ()
                    }
                    if (!migrated) {
                        return match (prefix) {
                            case "groups" => this.getAutosaveGroups()
                            case "channels" => this.getAutosaveChannels()
                            case _ => this.getAutosavePrivateChats()
                        }
                    }
                    match (prefs.get("${prefix}_photo", PreferencesValueType.Integer(0))) {
                        case PreferencesValueType.Integer(n) => return n != 0
                        case _ => return false
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] shouldAutosavePhoto error: ${e}")
                    return false
                }
        }
    }

    public func setMediaSettingInt(key: String, value: Int64): Unit {
        match (getGlobalAbilityContext()) {
            case None => ()
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, AUTOSAVE_MEDIA_STORE)
                    prefs.put(key, PreferencesValueType.Integer(value))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] setMediaSettingInt(${key}) error: ${e}")
                }
        }
    }

    public func getMediaSettingString(key: String, defaultValue: String): String {
        match (getGlobalAbilityContext()) {
            case None => return defaultValue
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, AUTOSAVE_MEDIA_STORE)
                    match (prefs.get(key, PreferencesValueType.StringData(defaultValue))) {
                        case PreferencesValueType.StringData(value) => return value
                        case _ => return defaultValue
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] getMediaSettingString(${key}) error: ${e}")
                    return defaultValue
                }
        }
    }

    public func setMediaSettingString(key: String, value: String): Unit {
        match (getGlobalAbilityContext()) {
            case None => ()
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, AUTOSAVE_MEDIA_STORE)
                    prefs.put(key, PreferencesValueType.StringData(value))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] setMediaSettingString(${key}) error: ${e}")
                }
        }
    }

    /**
     * 聊天内照片刚从远端下载落盘（iOS chatMessagePhotoInteractiveFetched 在 `.remote` 结果上
     * 调 storeDownloadedMedia，PhotoResources.swift:2035）时调用：配置允许则写入系统相册。
     * 本应用不持有 WRITE_IMAGEVIDEO，写入走 showAssetsCreationDialog（系统保存确认），
     * 必须在 UI 线程拉起，故这里 launch 回主线程。可在任意线程调用。
     */
    public func autosaveDownloadedPhoto(localUri: String, peerType: String, peerId: Int64, isBroadcast: Bool): Unit {
        if (localUri.isEmpty() || !this.shouldAutosavePhoto(peerType, peerId, isBroadcast)) { return }
        // W5 S7-95：同一张图会从轮询（Polling new=）与 updates 推送两条路各下载一次、各带
        // autosave，去重后每张图只拉一次系统保存弹窗。
        this.autosaveMutex.lock()
        let duplicate = this.autosaveRequested.contains(localUri)
        if (!duplicate) { let _ = this.autosaveRequested.add(localUri) }
        this.autosaveMutex.unlock()
        if (duplicate) {
            Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] autosave skipped (already requested): ${localUri}")
            return
        }
        // iOS StoreDownloadedMedia.swift:135 `if !data.complete { return }`：只保存已完整落盘的文件。
        var srcBytes: Int64 = 0
        let raw = saveToRollRawPath(localUri)
        try { srcBytes = FileIo.stat(raw).size } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] autosave src stat failed ${raw}: ${e}")
        }
        if (srcBytes <= 0) {
            Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] autosave aborted: src empty ${raw}")
            return
        }
        Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] autosave incoming photo peer=${peerType}/${peerId} src=${raw} srcBytes=${srcBytes}")
        let uri = localUri
        let srcSize = srcBytes
        launch {
            this.saveImageToGallery(uri, { ok: Bool =>
                Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] autosave result: ${ok} src=${raw} srcBytes=${srcSize} lastWrite=${this.lastWriteSummary}")
            })
        }
    }

    private let autosaveRequested: HashSet<String> = HashSet<String>()
    private let autosaveMutex = ReentrantMutex()
    /** 最近一次 writeFileToUri 的摘要（"wrote N bytes, target M bytes -> uri"），供结果日志引用。 */
    private var lastWriteSummary: String = ""

    // ──────────────────────── media save API ────────────────────────

    /**
     * 将图片文件保存到系统相册（免 WRITE_IMAGEVIDEO 权限，弹系统保存确认弹窗）
     *
     * @param fileUri   本地图片文件路径（如 file:///data/storage/.../photo.jpg）
     *                  若 fileUri 不含 "file://" 前缀则自动补全
     * @param callback  保存结果回调（主线程调用）：true 表示用户同意并保存成功，
     *                  false 表示用户拒绝弹窗或保存失败
     */
    public func saveImageToGallery(fileUri: String, callback: (Bool) -> Unit): Unit {
        let uri = this.normalizeFileUri(fileUri)
        Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] saveImage: ${uri}")
        this.saveAsset(uri: uri, isVideo: false, callback: callback)
    }

    /**
     * 将视频文件保存到系统相册（免 WRITE_IMAGEVIDEO 权限，弹系统保存确认弹窗）
     *
     * @param fileUri   本地视频文件路径（如 file:///data/storage/.../video.mp4）
     *                  若 fileUri 不含 "file://" 前缀则自动补全
     * @param callback  保存结果回调（主线程调用）：true 表示用户同意并保存成功，
     *                  false 表示用户拒绝弹窗或保存失败
     */
    public func saveVideoToGallery(fileUri: String, callback: (Bool) -> Unit): Unit {
        let uri = this.normalizeFileUri(fileUri)
        Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] saveVideo: ${uri}")
        this.saveAsset(uri: uri, isVideo: true, callback: callback)
    }

    // ──────────────────────── media clipboard API ────────────────────────────

    /**
     * 将媒体文件 URI 复制到系统剪贴板（对应 iOS copyToPasteboard）
     *
     * iOS 侧通过 UIPasteboard.setData(jpeg, forPasteboardType: kUTTypeJPEG) 复制原始图片字节。
     * HarmonyOS NEXT 侧，UDMF PixelMap 通道的 C NDK 符号（OH_UdsPixelMap_*）在本工程
     * cangjie-kb 多轮检索中无文档覆盖，无法安全实现字节级粘贴板写入。
     * D-tier 替代：将标准化后的 file:// URI 以纯文本写入系统剪贴板，使用方可通过
     * 粘贴板读取路径、进一步读文件（platform fidelity gap，已诚实标注）。
     *
     * @param fileUri  本地文件路径或 file:// URI
     * @return  true 表示成功写入剪贴板，false 表示失败（不崩溃）
     */
    public func copyMediaFileUri(fileUri: String): Bool {
        let uri = this.normalizeFileUri(fileUri)
        Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] copyMediaFileUri: ${uri}")
        return pasteboardCopyText(uri)
    }

    // ──────────────────────────── private helpers ────────────────────────────

    /**
     * 确保路径为带 bundleName authority 的分享型 file URI。
     *
     * imgmenu 批次真机返修：photoAccessHelper.showAssetsCreationDialog 的 srcFileUri
     * 必须是 `file://<bundleName>/<绝对路径>` 形态（跨进程可读）。此前 "file://" + 沙箱
     * 绝对路径产生 `file:///data/...`（空 authority），媒体库进程无法读取源文件——真机
     * 实证：弹窗不出现，回调 <1s 即返回空列表（hilog "user declined or empty result"）。
     */
    private func normalizeFileUri(path: String): String {
        if (path.startsWith("file://")) {
            // 升级空 authority 历史形态 file:///data/... → file://<bundle>/data/...
            let rest = path[7..path.size]
            if (rest.startsWith("/")) {
                return "file://" + SAVE_URI_BUNDLE + rest
            }
            return path
        }
        if (path.startsWith("/")) {
            return "file://" + SAVE_URI_BUNDLE + path
        }
        return "file://" + path
    }

    /**
     * 核心保存逻辑：使用 photoAccessHelper.showAssetsCreationDialog 拉起系统保存确认弹窗，
     * 用户同意后返回已授予保存权限的 uri 列表，写入系统相册；免 WRITE_IMAGEVIDEO 权限。
     * KB 文档明确"当传入 uri 为沙箱路径时，可正常保存图片/视频，但无界面预览"——本服务
     * 调用方传入的均为本地沙箱路径，直接可用。
     */
    private func saveAsset(uri!: String, isVideo!: Bool, callback!: (Bool) -> Unit): Unit {
        match (getGlobalAbilityContext()) {
            case None =>
                Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] No ability context")
                callback(false)
            case Some(ctx) =>
                let ext = extractFileExtension(uri)
                let photoType = if (isVideo) { PhotoType.Video } else { PhotoType.Image }
                let config = PhotoCreationConfig(ext, photoType)
                let dialogCallback = SaveToCameraRollDialogCallback(uri, callback)
                try {
                    let phAccessHelper = getPhotoAccessHelper(ctx)
                    phAccessHelper.showAssetsCreationDialog([uri], [config], dialogCallback)
                } catch (e: BusinessException) {
                    Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] showAssetsCreationDialog BusinessException: ${e.message}")
                    callback(false)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] showAssetsCreationDialog Exception: ${e}")
                    callback(false)
                }
        }
    }

    // ──────────────────────── save-dialog 落盘（imgmenu 批次真机返修）────────────────

    /**
     * 把源文件字节写入 showAssetsCreationDialog 授权返回的目标 uri。
     *
     * 真机实证（imgmenu 批次）：用户点"允许"后媒体库只创建**空资产**并返回已授权的
     * 目标 uri（/storage/media/.../Photo/... 实测 0 字节），**写入媒体数据是调用方职责**
     * ——此前实现把"返回非空 uri 列表"当作保存完成，相册里得到 0 字节坏图。
     * 本方法读取源文件（沙箱路径 / file:// URI 均可）并写入目标 uri，返回是否成功。
     */
    public func writeFileToUri(srcPath: String, targetUri: String): Bool {
        let raw = saveToRollRawPath(srcPath)
        if (raw.size == 0) {
            Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] writeFileToUri: bad src ${srcPath}")
            return false
        }
        try {
            let srcFile = FileIo.open(raw, mode: 0o0)
            let stat = FileIo.stat(raw)
            let data = Array<Byte>(stat.size, repeat: 0)
            let n = FileIo.read(srcFile.fd, data)
            FileIo.close(srcFile)
            if (n <= 0) {
                Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] writeFileToUri: empty src ${raw}")
                return false
            }
            let payload = Array<Byte>(n, { i: Int64 => data[i] })
            // WRITE_ONLY（0o1）：目标为媒体库已授权 uri，资产已存在，不带 CREATE/TRUNC 标志
            let dstFile = FileIo.open(targetUri, mode: 0o1)
            let written = FileIo.write(dstFile.fd, payload)
            // W5 S7-95：自动保存回调 true 但相册无新图——此前只要 open/write 不抛就算成功，
            // 写入字节数与目标资产大小都没核对。现在按实际写入量与 fstat 回读判定。
            var targetBytes: Int64 = -1
            try { targetBytes = FileIo.stat(dstFile.fd).size } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] writeFileToUri: fstat target failed: ${e}")
            }
            FileIo.close(dstFile)
            this.lastWriteSummary = "wrote ${written}/${n} bytes, target ${targetBytes} bytes -> ${targetUri}"
            Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] writeFileToUri: ${this.lastWriteSummary} (src ${raw})")
            if (written != n) {
                Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] writeFileToUri: short write ${written} < ${n}")
                return false
            }
            if (targetBytes >= 0 && targetBytes < n) {
                Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] writeFileToUri: target size ${targetBytes} < ${n} after write")
                return false
            }
            return true
        } catch (e: Exception) {
            this.lastWriteSummary = "failed: ${e}"
            Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] writeFileToUri failed: ${e}")
            return false
        }
    }

    /**
     * 懒加载 Preferences store "telegram_autosave" 并写入布尔值
     * 存为 Integer(1)/Integer(0) 以保持与 AuthStorage 一致的惯例
     */
    private func setBoolPref(key: String, value: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case None =>
                Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] setBoolPref(${key}): no context")
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_autosave")
                    let v: Int64 = if (value) { 1 } else { 0 }
                    prefs.put(key, PreferencesValueType.Integer(v))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] setBoolPref(${key}) error: ${e}")
                }
        }
    }

    /**
     * 懒加载 Preferences store "telegram_autosave" 并读取布尔值
     */
    private func getBoolPref(key: String, defaultVal: Bool): Bool {
        match (getGlobalAbilityContext()) {
            case None => return defaultVal
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_autosave")
                    let dv: Int64 = if (defaultVal) { 1 } else { 0 }
                    let val = prefs.get(key, PreferencesValueType.Integer(dv))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return n != 0
                        case _ => return defaultVal
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] getBoolPref(${key}) error: ${e}")
                    return defaultVal
                }
        }
    }
}

/**
 * showAssetsCreationDialog 的结果回调实现（对齐 ImageViewer.cj ImageViewerSaveDialogCallback
 * 同一惯例）。savedUris 非空 = 用户同意；imgmenu 批次真机返修：同意后必须由调用方把源文件
 * 字节写入返回的目标 uri（否则相册只有 0 字节空资产），故此处携带 srcUri 并在回调内落盘，
 * 落盘成功才回调 true。空列表 = 用户拒绝，按失败语义回调 false。
 */
class SaveToCameraRollDialogCallback <: Callback1Argument<Array<String>> {
    private var _srcUri: String
    private var _onResult: (Bool) -> Unit

    init(srcUri: String, onResult: (Bool) -> Unit) {
        this._srcUri = srcUri
        this._onResult = onResult
    }

    public func invoke(err: ?BusinessException, arg: Array<String>): Unit {
        match (err) {
            case Some(e) =>
                Hilog.info(0, "CjTelegram", "[SaveToCameraRoll] showAssetsCreationDialog callback error: ${e.message}")
                this._onResult(false)
            case None =>
                if (arg.size > 0) {
                    let ok = getSaveToCameraRollService().writeFileToUri(this._srcUri, arg[0])
                    this._onResult(ok)
                } else {
                    this._onResult(false)
                }
        }
    }
}

/**
 * file:// URI → 原始沙箱绝对路径（供 FileIo 读取）。
 * 支持 file:///abs（空 authority）与 file://<bundle>/abs（bundleName authority）两种形态；
 * 非 file:// 直接原样返回。
 */
private func saveToRollRawPath(path: String): String {
    if (!path.startsWith("file://")) {
        return path
    }
    let rest = path[7..path.size]
    if (rest.startsWith("/")) {
        return rest
    }
    // 去掉 authority 段（首个 "/" 之前）
    let parts = rest.split("/")
    if (parts.size <= 1) {
        return ""
    }
    var out = ""
    var i: Int64 = 1
    while (i < parts.size) {
        out = out + "/" + parts[i]
        i += 1
    }
    return out
}

/**
 * 从本地文件路径 / URI 提取扩展名（不含 "."），供 PhotoCreationConfig.fileNameExtension 使用。
 * R-101: String 无 hasSuffix，用 split(".") 取最后一段代替。
 */
private func extractFileExtension(path: String): String {
    let parts = path.split(".")
    if (parts.size > 1) {
        return parts[parts.size - 1]
    }
    return "jpg"
}
