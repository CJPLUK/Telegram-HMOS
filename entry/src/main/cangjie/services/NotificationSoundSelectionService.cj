package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.ArkData.*
import ohos_app_cangjie_entry.interop.{callArkAsync, PICK_DOCUMENT}
import ohos_app_cangjie_entry.core.mtproto.{
    getMTProtoClient,
    AccountGetSavedRingtones,
    AccountSaveRingtone,
    AccountUploadRingtone,
    InputDocument,
    TLDeserializer,
    TLConstructors
}
import std.collection.ArrayList

/**
 * 通知铃声选择服务（Phase NSND）
 *
 * 封装 account.getSavedRingtones、account.saveRingtone、account.uploadRingtone
 * 对应 iOS NotificationSoundSelectionUI
 *
 * TL 方法:
 *   - account.getSavedRingtones#e1902288 hash:long = account.SavedRingtones
 *   - account.saveRingtone#3dea5b03 id:InputDocument unsave:Bool = account.SavedRingtone
 *   - account.uploadRingtone#831a83a2 file:InputFile file_name:string mime_type:string = Document
 *
 * 选择结果通过 Preferences 持久化，key: NSND_SOUND_ID / NSND_SOUND_HASH
 * 冷重启后从 Preferences 恢复选中状态。
 *
 * `diag-suite_settings_notifications-TC-0446.md` F-A1c（本 feature 内直接改的部分）：
 * `commitSelection(category, …)` 是页面提交时唯一的公开写入口，按 category 落盘到
 * per-category 槽（真正到达账号级 notify settings 的上传链路——
 * `services/SettingsService.cj` 透传 soundId、`TelegramCoreSettingsService.cj` 的
 * `AccountUpdateNotifySettings` 序列化 `sound`（flags.3）——都不在本 feature
 * allowlist 内，已按该报告 emit `emitted_integration_contracts[]`，不在这里直接改）。
 * `setSelectedSound`/`getSelectedSound`（全局单槽）签名保留不变——
 * `services/LocalNotificationDisplayService.cj:84,221` 读它且不在本 feature
 * allowlist 内，删除会让那个文件的调用点悬空；`commitSelection` 内部仍会透传写它，
 * 使其继续拿到"最近一次选择"这个近似值，避免制造第二条独立漂移的写路径。
 */

private let NSND_PREFS_NAME: String = "notif_sound_selection"
private let NSND_KEY_SOUND_ID: String = "selected_sound_id"
private let NSND_KEY_SOUND_HASH: String = "selected_sound_hash"
private let NSND_CATEGORY_KEY_ID_PREFIX: String = "category_sound_id_"
private let NSND_CATEGORY_KEY_HASH_PREFIX: String = "category_sound_hash_"

// 反转调用契约方法名（值必须与 ArkTS 侧登记 `registerArkFunc` 时使用的字符串一字不差）。
// CJ 侧具名常量 `PICK_DOCUMENT` 的正主现为 `interop/interop.cj:55`（round5 由
// `set_account_identity` 落地，本文件不再需要保留同值私有副本）；直接 import 它。
// ArkTS 侧仍是内联字面量 `'document.pick'`（`ets/interop/impls/DocumentPickerImpl.ets`
// 注释已写明该值与本常量、`InteropContract.ets` 三方须一字不差）。

public func getNotificationSoundSelectionService(): NotificationSoundSelectionService {
    return NotificationSoundSelectionService()
}

/**
 * 铃声条目（从 Document 解析）
 */
public class RingtoneEntry {
    public var id: Int64 = 0
    public var accessHash: Int64 = 0
    public var fileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var title: String = ""

    public func toString(): String {
        return "ringtone_${this.id}"
    }
}

/**
 * 内置铃声分类（F-2，diag-suite_settings_notifications-TC-0446.md 修法方向）。
 * 对位源 `SyncCore_TelegramPeerNotificationSettings.swift:38-57 CloudSoundBuiltinCategory`：
 * 该文件 `:4-36` 的 `cloudSoundMapping` 是服务端固定 fileId 常量表，key<50（[2,9]，8 个）
 * 为 classic、key>=50（[100,111]∪[200,210]，23 个）为 modern；不在该表值域内的 fileId
 * 视为用户自定义上传（对位源侧 `init?(id:)` 返回 nil），归 `Custom`。
 * 分类依据直接照抄源侧常量表，不是凭 UI 表现反推的硬编码名字表。
 */
public enum CloudSoundBuiltinCategory {
    | Modern
    | Classic
    | Custom
}

// 对位 cloudSoundMapping key 2..9（classic）
private let CLOUD_SOUND_CLASSIC_FILE_IDS: Array<Int64> = [
    5078299559046677200, 5078299559046677201, 5078299559046677202, 5078299559046677203,
    5078299559046677204, 5078299559046677205, 5078299559046677206, 5078299559046677207
]

// 对位 cloudSoundMapping key 100..111 与 200..210（均为 modern）
private let CLOUD_SOUND_MODERN_FILE_IDS: Array<Int64> = [
    5078299559046677208, 5078299559046677209, 5078299559046677210, 5078299559046677211,
    5078299559046677212, 5078299559046677213, 5078299559046677214, 5078299559046677215,
    5078299559046677216, 5078299559046677217, 5078299559046677218, 5078299559046677219,
    5032932652722685163, 5032932652722685160, 5032932652722685159, 5032932652722685158,
    5032932652722685168, 5032932652722685167, 5032932652722685166, 5032932652722685165,
    5032932652722685164, 5032932652722685162, 5032932652722685161
]

public func classifyCloudSound(fileId: Int64): CloudSoundBuiltinCategory {
    for (v in CLOUD_SOUND_CLASSIC_FILE_IDS) {
        if (v == fileId) {
            return CloudSoundBuiltinCategory.Classic
        }
    }
    for (v in CLOUD_SOUND_MODERN_FILE_IDS) {
        if (v == fileId) {
            return CloudSoundBuiltinCategory.Modern
        }
    }
    return CloudSoundBuiltinCategory.Custom
}

private var _selectedSoundId: Int64 = 0
private var _selectedAccessHash: Int64 = 0
private var _selectedFileRef: Array<Byte> = Array<Byte>(0, repeat: 0)

public class NotificationSoundSelectionService {
    /**
     * 设置并持久化当前选中声音。
     * 同时写入内存缓存和 Preferences（冷重启可恢复）。
     * id=0: Default; id=-1: None; id>0: cloud ringtone
     */
    public func setSelectedSound(id: Int64, accessHash: Int64, fileRef: Array<Byte>): Unit {
        _selectedSoundId = id
        _selectedAccessHash = accessHash
        _selectedFileRef = fileRef
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, NSND_PREFS_NAME)
                    prefs.put(NSND_KEY_SOUND_ID, PreferencesValueType.Integer(id))
                    prefs.put(NSND_KEY_SOUND_HASH, PreferencesValueType.Integer(accessHash))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[NSND] setSelectedSound persisted: id=${id}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[NSND] setSelectedSound prefs error: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[NSND] setSelectedSound: no context, in-memory only")
        }
    }

    /**
     * 获取当前选中声音，优先从 Preferences 恢复（冷重启安全）。
     * 返回 (soundId, accessHash, fileReference)
     */
    public func getSelectedSound(): (Int64, Int64, Array<Byte>) {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, NSND_PREFS_NAME)
                    let idVal = prefs.get(NSND_KEY_SOUND_ID, PreferencesValueType.Integer(_selectedSoundId))
                    let hashVal = prefs.get(NSND_KEY_SOUND_HASH, PreferencesValueType.Integer(_selectedAccessHash))
                    var storedId = _selectedSoundId
                    var storedHash = _selectedAccessHash
                    match (idVal) {
                        case PreferencesValueType.Integer(n) => storedId = n
                        case _ => ()
                    }
                    match (hashVal) {
                        case PreferencesValueType.Integer(n) => storedHash = n
                        case _ => ()
                    }
                    _selectedSoundId = storedId
                    _selectedAccessHash = storedHash
                    return (storedId, storedHash, _selectedFileRef)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[NSND] getSelectedSound prefs error: ${e}")
                }
            case None => ()
        }
        return (_selectedSoundId, _selectedAccessHash, _selectedFileRef)
    }

    /**
     * 页面提交时的唯一公开写入口（F-A1c）。按 category 落盘到 per-category 槽，
     * 同时透传旧的全局单槽（`setSelectedSound`）以保持
     * `LocalNotificationDisplayService.cj` 等跨文件读方不悬空（见文件头注释）。
     * id=0: Default; id=-1: None; id>0: cloud ringtone（沿用既有约定）。
     * category 为空串时落到 "default" 槽（无分类上下文的兜底路径）。
     */
    public func commitSelection(category: String, id: Int64, accessHash: Int64, fileRef: Array<Byte>): Unit {
        this.setSelectedSound(id, accessHash, fileRef)
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, NSND_PREFS_NAME)
                    let idKey = this.categoryKey(NSND_CATEGORY_KEY_ID_PREFIX, category)
                    let hashKey = this.categoryKey(NSND_CATEGORY_KEY_HASH_PREFIX, category)
                    prefs.put(idKey, PreferencesValueType.Integer(id))
                    prefs.put(hashKey, PreferencesValueType.Integer(accessHash))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[NSND] commitSelection persisted: category=${category} id=${id}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[NSND] commitSelection prefs error: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[NSND] commitSelection: no context, in-memory only")
        }
    }

    /**
     * 读取某分类当前已提交的铃声（供分类子屏"Sound"行显示当前值、以及构造
     * routerPush 到本页的 currentSoundId/currentAccessHash 用）。不持久化
     * fileReference——与 `getSelectedSound()` 同样的既有限制（云端文档的
     * file_reference 会轮换，调用方应在真正需要提交前用 `getSavedRingtones`
     * 拿到的新鲜条目重新对齐，本页 `loadRingtones()` 已是这个模式）。
     */
    public func getCategorySound(category: String): (Int64, Int64) {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, NSND_PREFS_NAME)
                    let idKey = this.categoryKey(NSND_CATEGORY_KEY_ID_PREFIX, category)
                    let hashKey = this.categoryKey(NSND_CATEGORY_KEY_HASH_PREFIX, category)
                    let idVal = prefs.get(idKey, PreferencesValueType.Integer(0))
                    let hashVal = prefs.get(hashKey, PreferencesValueType.Integer(0))
                    var storedId: Int64 = 0
                    var storedHash: Int64 = 0
                    match (idVal) {
                        case PreferencesValueType.Integer(n) => storedId = n
                        case _ => ()
                    }
                    match (hashVal) {
                        case PreferencesValueType.Integer(n) => storedHash = n
                        case _ => ()
                    }
                    return (storedId, storedHash)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[NSND] getCategorySound prefs error: ${e}")
                }
            case None => ()
        }
        return (0, 0)
    }

    private func categoryKey(prefix: String, category: String): String {
        if (category.size == 0) {
            return prefix + "default"
        }
        return prefix + category
    }

    /**
     * X1/X2 阈值来源（`diag-suite_settings_notifications-TC-0449-round6.md` 改动1）。
     * 对位源 `NotificationSoundList.swift:7-27 NotificationSoundSettings`：从
     * `help.getAppConfig` 的 `configJson` 解析 `ringtone_size_max`（字节）/
     * `ringtone_duration_max`（秒），逐字照 `pages/ChatFoldersPage.cj:348-368
     * parseFolderLimitFromConfigJson` 的既有范式（appConfig 不可用 / 字段缺失 /
     * 非法值三种情况均落回源侧同值兜底），不得把阈值硬编码成常量后跳过 appConfig 通路。
     */
    private func parseRingtoneLimitFromConfigJson(configJson: String, fieldName: String, fallback: Int64): Int64 {
        if (configJson.size == 0) {
            Hilog.info(0, "CjTelegram",
                "[NSND] parseRingtoneLimitFromConfigJson: appConfig unavailable, field=${fieldName} fallback=${fallback}")
            return fallback
        }
        let obj = JsonParser.parseObject(configJson)
        if (!obj.has(fieldName)) {
            Hilog.info(0, "CjTelegram",
                "[NSND] parseRingtoneLimitFromConfigJson: field ${fieldName} missing in appConfig, fallback=${fallback}")
            return fallback
        }
        let serverLimit = obj.getInt(fieldName)
        if (serverLimit <= 0) {
            Hilog.info(0, "CjTelegram",
                "[NSND] parseRingtoneLimitFromConfigJson: field ${fieldName} invalid value=${serverLimit}, fallback=${fallback}")
            return fallback
        }
        return serverLimit
    }

    /**
     * 返回 (maxSizeBytes, maxDurationSecs)。拿不到 appConfig 时兜底
     * (102400, 5)（源侧同值默认）。这是一次同步阻塞的 RPC 调用
     * （`getTelegramEngineDataService().getAppConfig()`），调用方必须在后台线程
     * （`spawn{}`）里调，不能在 UI 线程同步调用（同 `ChatFoldersPage.prefetchFolderLimits`
     * 的既有约束）。
     */
    public func getRingtoneLimits(): (Int64, Int64) {
        let appConfig = getTelegramEngineDataService().getAppConfig()
        let configJson = match (appConfig) {
            case Some(cfg) => cfg.configJson
            case None => ""
        }
        let maxSizeBytes = this.parseRingtoneLimitFromConfigJson(configJson, "ringtone_size_max", 102400)
        let maxDurationSecs = this.parseRingtoneLimitFromConfigJson(configJson, "ringtone_duration_max", 5)
        return (maxSizeBytes, maxDurationSecs)
    }

    /**
     * 获取已保存的铃声列表
     * @param hash 缓存 hash，首次传 0
     * @return (ringtones, newHash) 或 (空列表, 0) 若失败
     */
    public func getSavedRingtones(hash: Int64): (ArrayList<RingtoneEntry>, Int64) {
        var result = ArrayList<RingtoneEntry>()
        var newHash: Int64 = 0
        try {
            let client = getMTProtoClient()
            let req = AccountGetSavedRingtones()
            req.hash = hash
            let data = client.sendRequest(req.toBytes())
            if (data.size >= 4) {
                let (parsed, h) = this.parseSavedRingtones(data)
                result = parsed
                newHash = h
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[NSND] getSavedRingtones error: ${e}")
        }
        return (result, newHash)
    }

    /**
     * 解析 account.savedRingtones#c1e92cc5 或 account.savedRingtonesNotModified#fbf6e8b1
     */
    private func parseSavedRingtones(data: Array<Byte>): (ArrayList<RingtoneEntry>, Int64) {
        var result = ArrayList<RingtoneEntry>()
        var hash: Int64 = 0
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == 0xfbf6e8b1) {
            return (result, 0)
        }
        if (ctor == 0xc1e92cc5) {
            hash = d.readInt64()
            let vecCtor = d.readUInt32()
            if (vecCtor == TLConstructors.VECTOR) {
                let count = d.readInt32()
                var i: Int32 = 0
                while (i < count) {
                    let entry = this.parseDocument(d)
                    if (entry.id != 0) {
                        result.add(entry)
                    }
                    i = i + 1
                }
            }
        } else if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let errCode = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[NSND] getSavedRingtones RPC error: ${errCode} ${errMsg}")
        }
        return (result, hash)
    }

    /**
     * 解析 document#8fd4c4d8 提取 id/access_hash/file_reference
     */
    private func parseDocument(d: TLDeserializer): RingtoneEntry {
        let entry = RingtoneEntry()
        let docCtor = d.readUInt32()
        if (docCtor == 0x36f8c871) {
            entry.id = d.readInt64()
            return entry
        }
        if (docCtor == 0x8fd4c4d8) {
            let flags = d.readInt32()
            entry.id = d.readInt64()
            entry.accessHash = d.readInt64()
            entry.fileReference = d.readBytes()
            let _ = d.readInt32()
            let _ = d.readString()
            let _ = d.readInt64()
            if ((flags & 1) != 0) {
                let vecC = d.readUInt32()
                if (vecC == TLConstructors.VECTOR) {
                    let thumbCount = d.readInt32()
                    var ti: Int32 = 0
                    while (ti < thumbCount) {
                        this.skipPhotoSize(d)
                        ti = ti + 1
                    }
                }
            }
            if ((flags & 2) != 0) {
                let vecC = d.readUInt32()
                if (vecC == TLConstructors.VECTOR) {
                    let vc = d.readInt32()
                    var vi: Int32 = 0
                    while (vi < vc) {
                        this.skipVideoSize(d)
                        vi = vi + 1
                    }
                }
            }
            let _ = d.readInt32()
            let attrVecC = d.readUInt32()
            if (attrVecC == TLConstructors.VECTOR) {
            let attrCount = d.readInt32()
            var ai: Int32 = 0
            while (ai < attrCount) {
                let attrCtor = d.readUInt32()
                if (attrCtor == 0x15590068) {
                    entry.title = d.readString()
                } else {
                    this.skipDocumentAttribute(d, attrCtor)
                }
                ai = ai + 1
            }
            }
        }
        return entry
    }

    private func skipPhotoSize(d: TLDeserializer): Unit {
        let c = d.readUInt32()
        if (c == 0x0e17e23c) {
            let _ = d.readString()
            return
        }
        if (c == 0x75c78e60 || c == 0x021e1ad6) {
            let _ = d.readString()
            let _ = d.readInt32()
            let _ = d.readInt32()
            let _ = d.readInt32()
            if (c == 0x021e1ad6) { let _ = d.readBytes() }
            return
        }
    }

    private func skipVideoSize(d: TLDeserializer): Unit {
        let c = d.readUInt32()
        if (c == 0xde33b094 || c == 0x7be31cfd) {
            let flags = d.readInt32()
            let _ = d.readString()
            let _ = d.readInt32()
            let _ = d.readInt32()
            let _ = d.readInt32()
            if ((flags & 1) != 0) { let _ = d.readDouble() }
            return
        }
        if (c == 0xf85c413c) {
            let _ = d.readInt64()
            let vecC = d.readUInt32()
            if (vecC == TLConstructors.VECTOR) {
                let n = d.readInt32()
                var i: Int32 = 0
                while (i < n) { let _ = d.readInt32(); i = i + 1 }
            }
            return
        }
    }

    private func skipDocumentAttribute(d: TLDeserializer, attrCtor: UInt32): Unit {
        if (attrCtor == 0x9852f9c6) {
            let af = d.readInt32()
            let _ = d.readInt32()
            if ((af & 1) != 0) { let _ = d.readString() }
            if ((af & 2) != 0) { let _ = d.readString() }
            if ((af & 4) != 0) { let _ = d.readBytes() }
        } else if (attrCtor == 0xd38ff1c2 || attrCtor == 0x43c57c48) {
            let vf = d.readInt32()
            let _ = d.readDouble()
            let _ = d.readInt32()
            let _ = d.readInt32()
            if ((vf & 4) != 0) { let _ = d.readInt32() }
            if ((vf & 16) != 0) { let _ = d.readDouble() }
            if ((vf & 32) != 0) { let _ = d.readString() }
        } else if (attrCtor == 0xef02ce6) {
            let _ = d.readInt32()
            let _ = d.readInt32()
            let _ = d.readInt32()
            let _ = d.readInt32()
        } else if (attrCtor == 0x15590068) {
            let _ = d.readString()
        } else if (attrCtor == 0x6319d612) {
            let _ = d.readString()
        }
    }

    /**
     * 保存铃声（将上传的 Document 加入收藏）
     * @param docId Document id
     * @param accessHash Document access_hash
     * @param fileReference Document file_reference
     * @return 是否成功
     */
    public func saveRingtone(docId: Int64, accessHash: Int64, fileReference: Array<Byte>): Bool {
        try {
            let client = getMTProtoClient()
            let inputDoc = InputDocument()
            inputDoc.id = docId
            inputDoc.accessHash = accessHash
            inputDoc.fileReference = fileReference
            let req = AccountSaveRingtone()
            req.id = inputDoc
            req.unsave = false
            let data = client.sendRequest(req.toBytes())
            if (data.size >= 4) {
                let d = TLDeserializer(data)
                let ctor = d.readUInt32()
                if (ctor == 0xb7263f6d || ctor == 0x1f307eb7) {
                    Hilog.info(0, "CjTelegram", "[NSND] saveRingtone success")
                    return true
                }
                if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                    let errCode = d.readInt32()
                    let errMsg = d.readString()
                    Hilog.info(0, "CjTelegram", "[NSND] saveRingtone RPC error: ${errCode} ${errMsg}")
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[NSND] saveRingtone exception: ${e}")
        }
        return false
    }

    /**
     * 删除铃声（从收藏中移除）
     */
    public func deleteRingtone(docId: Int64, accessHash: Int64, fileReference: Array<Byte>): Bool {
        try {
            let client = getMTProtoClient()
            let inputDoc = InputDocument()
            inputDoc.id = docId
            inputDoc.accessHash = accessHash
            inputDoc.fileReference = fileReference
            let req = AccountSaveRingtone()
            req.id = inputDoc
            req.unsave = true
            let data = client.sendRequest(req.toBytes())
            if (data.size >= 4) {
                let d = TLDeserializer(data)
                let ctor = d.readUInt32()
                if (ctor == 0xb7263f6d) {
                    Hilog.info(0, "CjTelegram", "[NSND] deleteRingtone success")
                    return true
                }
                if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                    let errCode = d.readInt32()
                    let errMsg = d.readString()
                    Hilog.info(0, "CjTelegram", "[NSND] deleteRingtone RPC error: ${errCode} ${errMsg}")
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[NSND] deleteRingtone exception: ${e}")
        }
        return false
    }

    /**
     * 拉起系统文档选择器选一个 mp3（对位源
     * `NotificationSoundSelection.swift:500 legacyICloudFilePicker(documentTypes: ["public.mp3"])`
     * → `LegacyICloudFilePicker.swift:69-118 UIDocumentPickerViewController(in: .open)`）。
     *
     * 反转链路与 `PhotoPickerImpl` 同形：`callArkAsync(PICK_DOCUMENT, argJson)` →
     * ArkTS 侧 `picker.DocumentViewPicker.select(...)` 拉起系统选择器 → 把选中 URI 拷进
     * 沙箱 `cacheDir` → 回传 `{"ok","status","paths","names"}`。选择域是设备文档域，
     * 不是应用沙箱（`diag-suite_settings_notifications-TC-0449-round4.md` A1）。
     *
     * `suffixes` 由本侧传入而非在 ArkTS 侧写死：类型过滤必须发生在**系统选择器层**
     * （`DocumentSelectOptions.fileSuffixFilters`），非 mp3 在界面上就不出现，
     * 这就是源侧 `documentTypes` 的对位物（同报告 A2）。本调用点只传 `.mp3`。
     *
     * `names` 与 `paths` 并列回传：上传要用**用户所选文件的原始名**（源侧
     * `:518 url.lastPathComponent`），不能从沙箱临时路径反推。
     *
     * 取消 / 失败一律静默：只写日志、不回调、不产生任何 UI 提示——源侧
     * `documentPickerWasCancelled` 与其余失败分支共九处 `Logger.shared.log`、零处提示
     * （X7/X8），此处不得"顺手改善"。
     *
     * ArkTS 侧桥接（`ets/interop/impls/DocumentPickerImpl.ets` 新建 +
     * `InteropRegistry.ets` 登记）不在本 feature allowlist 内，已 emit
     * `ic_nsnd_document_picker_impl` / `ic_nsnd_document_picker_registry`。桥接落地前
     * `callArkAsync` 走 `interop/interop.cj:76 case None` 分支回传
     * `{"error":"no ark func: document.pick"}`，本函数按失败分支静默返回。
     *
     * @param onPicked 选中成功时回调 (沙箱可读路径, 原始文件名)；取消/失败不回调
     */
    public func requestMp3Document(onPicked: (String, String) -> Unit): Unit {
        callArkAsync(PICK_DOCUMENT, "{\"suffixes\":[\".mp3\"],\"maxSelectNumber\":1}") { resJson =>
            var pickedPath = ""
            var pickedName = ""
            var status = "error"
            // diag-...-TC-0449-round5.md 改动4：桥接不存在（case None 同步回传
            // {"error":...}）与用户取消曾共用同一条静默分支，仅靠空 status 区分，
            // 定位耗时一整轮。这里只加一条判别日志，不改静默语义、不加任何 UI。
            var bridgeError = ""
            try {
                let json = JsonParser.parseObject(resJson)
                status = json.getString("status")
                if (json.has("error")) {
                    bridgeError = json.getString("error")
                }
                if (json.getBool("ok") && status == "picked") {
                    let paths = json.getArray("paths")
                    let names = json.getArray("names")
                    if (paths.size() > 0 && names.size() > 0) {
                        pickedPath = paths.getString(0)
                        pickedName = names.getString(0)
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[NSND] document pick parse exception: ${e}")
            }
            if (bridgeError.size > 0 && status.size == 0) {
                Hilog.info(0, "CjTelegram", "[NSND] document pick bridge unavailable: ${bridgeError}")
                return
            }
            if (pickedPath.size == 0 || pickedName.size == 0) {
                Hilog.info(0, "CjTelegram", "[NSND] document pick ended without selection: status=${status}")
                return
            }
            // R-111/D-114：回调闭包只传不可变绑定，不把 var 交给调用方。
            let path = pickedPath
            let name = pickedName
            onPicked(path, name)
        }
    }

    /**
     * 上传自定义铃声
     * @param data 音频文件数据 (MP3/OGG)
     * @param fileName 文件名
     * @return (docId, accessHash, fileReference) 或 (0, 0, 空) 若失败
     */
    public func uploadRingtone(data: Array<Byte>, fileName: String): (Int64, Int64, Array<Byte>) {
        var docId: Int64 = 0
        var accessHash: Int64 = 0
        let emptyRef = Array<Byte>(0, repeat: 0)
        try {
            let inputFileOpt = getFileUploadService().uploadFile(data, fileName)
            match (inputFileOpt) {
                case Some(inputFile) =>
                    let client = getMTProtoClient()
                    let req = AccountUploadRingtone()
                    req.file = inputFile
                    req.fileName = fileName
                    req.mimeType = "audio/mpeg"
                    let resp = client.sendRequest(req.toBytes())
                    if (resp.size >= 4) {
                        let (id, ah, fr) = this.parseDocumentResponse(resp)
                        docId = id
                        accessHash = ah
                        return (id, ah, fr)
                    }
                case None =>
                    Hilog.info(0, "CjTelegram", "[NSND] uploadRingtone: FileUpload failed")
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[NSND] uploadRingtone exception: ${e}")
        }
        return (docId, accessHash, emptyRef)
    }

    private func parseDocumentResponse(data: Array<Byte>): (Int64, Int64, Array<Byte>) {
        var docId: Int64 = 0
        var accessHash: Int64 = 0
        var fileRef = Array<Byte>(0, repeat: 0)
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == 0x8fd4c4d8) {
            let flags = d.readInt32()
            docId = d.readInt64()
            accessHash = d.readInt64()
            fileRef = d.readBytes()
        } else if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let errCode = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[NSND] uploadRingtone RPC error: ${errCode} ${errMsg}")
        }
        return (docId, accessHash, fileRef)
    }
}
