package ohos_app_cangjie_entry.services

import std.collection.*
import std.convert.*
import std.sync.*
import std.time.DateTime
import kit.ArkData.*
import kit.AbilityKit.UIAbilityContext
import kit.CoreFileKit.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.models.Message
import ohos_app_cangjie_entry.core.mtproto.{Base64, ByteUtils}
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.core.storage.postbox.IntermediateMessage

/**
 * FailedMessageStore — 发送失败消息的磁盘事实源。
 *
 * iOS 将 pending/failed message 作为 Postbox 状态持久化。仓颉侧暂以 Preferences
 * 承载同一生命周期语义：失败后立即落盘，杀进程重启后恢复，成功重发或用户删除后清理。
 *
 * v2 修复：
 * - 不再把 U+001D/U+001E/U+001F 控制字符写入 Preferences；所有字符串先 UTF-8
 *   Base64，再用可打印的 "|" / "\n" 分隔，避免 XML/Preferences 序列化拒绝控制字符。
 * - 复用 Postbox IntermediateMessage 完整二进制编解码，稳定保存本地 id、消息类型、
 *   回复、媒体、投票、位置和状态等字段，避免另维护一份易漂移的字段清单。
 * - 按 account slot 分区，账号切换时自动重载，避免不同账号的失败消息串线。
 * - 所有内存读写与序列化由同一把锁保护，避免多个发送任务同时失败时互相覆盖。
 * - 兼容读取旧 v1 格式，成功读取后自动迁移到 v2。
 */
private var _failedStore = HashMap<Int64, ArrayList<Message>>()
private var _failedNames = HashMap<Int64, String>()
private var _prefsCtx: Option<UIAbilityContext> = None
private var _loadedSlot: Int32 = -1
private let _failedStoreMutex = ReentrantMutex()

private let FAILED_PREFS = "failed_msg_prefs"
private let FAILED_KEY_V1 = "failed_msgs_v1"
private let FAILED_NAMES_KEY_V1 = "failed_names_v1"
private let FAILED_KEY_V2_PREFIX = "failed_msgs_v2_slot_"
private let FAILED_NAMES_KEY_V2_PREFIX = "failed_names_v2_slot_"

// 仅用于兼容旧版读取；v2 永远不再写控制字符。
private let LEGACY_SEP_FIELD = "\u{001F}"
private let LEGACY_SEP_REC = "\u{001E}"
private let LEGACY_SEP_ENTRY = "\u{001D}"

private func messagesKey(slot: Int32): String {
    return FAILED_KEY_V2_PREFIX + "${slot}"
}

private func namesKey(slot: Int32): String {
    return FAILED_NAMES_KEY_V2_PREFIX + "${slot}"
}

/** 空串使用 "-" 哨兵，保证 split 后字段数量稳定；Base64 字符集不包含 "-"。 */
private func encodeText(value: String): String {
    if (value.isEmpty()) { return "-" }
    return Base64.encode(ByteUtils.stringToBytes(value))
}

private func decodeText(value: String): String {
    if (value == "-" || value.isEmpty()) { return "" }
    try {
        return ByteUtils.bytesToString(Base64.decode(value))
    } catch (_: Exception) {
        return ""
    }
}

private func parseInt64(value: String, fallback: Int64): Int64 {
    return try { Int64.parse(value) } catch (_: Exception) { fallback }
}

/**
 * v2 单行：peerId|Base64(IntermediateMessage.encodeToBytes())
 *
 * Base64 字符集不含 "|" 和换行，因此一行一条记录可无歧义恢复；消息字段本身由项目
 * 现有 PostboxCoding keyed binary 格式负责版本兼容。
 */
private func encodeMessage(peerId: Int64, m: Message): String {
    let encoded = IntermediateMessage.fromMessage(m, peerId: peerId).encodeToBytes()
    return "${peerId}|" + Base64.encode(encoded)
}

private func decodeMessage(line: String): Option<(Int64, Message)> {
    let f = line.split("|")
    if (f.size < 2) { return None }
    let peerId = parseInt64(f[0], 0)
    if (peerId == 0) { return None }
    try {
        let intermediate = IntermediateMessage.decodeFromBytes(Base64.decode(f[1]))
        let message = intermediate.toMessage()
        // 磁盘事实源只保存失败消息；旧/损坏 status 不允许恢复成普通服务端消息。
        message.status = "failed"
        // IntermediateMessage 持久化 rawTimestamp，不持久化派生展示串 time。
        // 冷启动必须像服务端消息解析一样，由 Unix 秒重新按本地时区格式化。
        if (message.rawTimestamp <= 0) {
            // 兼容旧 v1/v2：旧实现只保存硬编码 "15:30"，没有真实时间戳。
            message.rawTimestamp = DateTime.now().toUnixTimeStamp().toSeconds()
        }
        message.time = formatMessageTime(message.rawTimestamp)
        return Some((peerId, message))
    } catch (_: Exception) {
        return None
    }
}

private func addLoadedMessage(peerId: Int64, message: Message): Unit {
    if (_failedStore.contains(peerId)) {
        _failedStore[peerId].add(message)
    } else {
        let list = ArrayList<Message>()
        list.add(message)
        _failedStore[peerId] = list
    }
}

private func loadLegacyValues(raw: String, rawNames: String): Bool {
    var loaded = false
    if (!rawNames.isEmpty()) {
        for (entry in rawNames.split(LEGACY_SEP_ENTRY)) {
            let parts = entry.split(LEGACY_SEP_FIELD)
            if (parts.size >= 2) {
                let peerId = parseInt64(parts[0], 0)
                if (peerId != 0) { _failedNames[peerId] = parts[1] }
            }
        }
    }
    if (!raw.isEmpty()) {
        for (entry in raw.split(LEGACY_SEP_ENTRY)) {
            let records = entry.split(LEGACY_SEP_REC)
            if (records.size < 2) { continue }
            let peerId = parseInt64(records[0], 0)
            if (peerId == 0) { continue }
            var i: Int64 = 1
            while (i < records.size) {
                let f = records[i].split(LEGACY_SEP_FIELD)
                if (f.size >= 4) {
                    let m = Message()
                    m.content = f[0]
                    // v1 的 time 可能是硬编码 "15:30"，没有可恢复的日期语义。
                    m.rawTimestamp = DateTime.now().toUnixTimeStamp().toSeconds()
                    m.time = formatMessageTime(m.rawTimestamp)
                    m.isSent = (f[2] == "1")
                    m.senderId = parseInt64(f[3], 0)
                    m.status = "failed"
                    addLoadedMessage(peerId, m)
                    loaded = true
                }
                i += 1
            }
        }
    }
    return loaded
}

private func loadLegacy(prefs: Preferences): Bool {
    let rawNames = match (prefs.get(FAILED_NAMES_KEY_V1, PreferencesValueType.StringData(""))) {
        case PreferencesValueType.StringData(s) => s
        case _ => ""
    }
    let raw = match (prefs.get(FAILED_KEY_V1, PreferencesValueType.StringData(""))) {
        case PreferencesValueType.StringData(s) => s
        case _ => ""
    }
    return loadLegacyValues(raw, rawNames)
}

private func xmlStringValue(xml: String, key: String): String {
    let marker = "<string key=\"${key}\">"
    match (xml.indexOf(marker)) {
        case Some(start) =>
            let tail = xml[(start + marker.size)..xml.size]
            match (tail.indexOf("</string>")) {
                case Some(end) =>
                    // Preferences XML 对普通文本做实体转义；控制分隔符本身原样存在，
                    // 也正是文件被标记 broken 的原因。
                    return tail[0..end]
                        .replace("&lt;", "<")
                        .replace("&gt;", ">")
                        .replace("&quot;", "\"")
                        .replace("&apos;", "'")
                        .replace("&amp;", "&")
                case None => return ""
            }
        case None => return ""
    }
}

/**
 * Harmony Preferences 遇到旧版 XML 中的控制字符后，会把文件改名为
 * failed_msg_prefs.broken。Preferences API 随后只返回空数据；这里做一次只读抢救，
 * 将旧内容解析后写成安全 v2。路径由 context.filesDir 的同级 preferences 目录推导。
 */
private func recoverBrokenLegacy(ctx: UIAbilityContext): Bool {
    let path = ctx.filesDir + "/../preferences/failed_msg_prefs.broken"
    try {
        if (!FileIo.access(path)) { return false }
        let stat = FileIo.stat(path)
        if (stat.size <= 0 || stat.size > 1048576) { return false }
        let bytes = Array<Byte>(stat.size, repeat: 0)
        let file = FileIo.open(path, mode: 0o0)
        let readCount = FileIo.read(file.fd, bytes)
        FileIo.close(file)
        if (readCount <= 0) { return false }
        let actual = Array<Byte>(readCount, { i: Int64 => bytes[i] })
        let xml = String.fromUtf8(actual)
        let raw = xmlStringValue(xml, FAILED_KEY_V1)
        let rawNames = xmlStringValue(xml, FAILED_NAMES_KEY_V1)
        return loadLegacyValues(raw, rawNames)
    } catch (e: Exception) {
        Hilog.error(0, "CjTelegram", "[FailedStore] broken v1 recovery failed: ${e}")
        return false
    }
}

private func persistLocked(): Unit {
    match (_prefsCtx) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, FAILED_PREFS)
                let rows = StringBuilder()
                var first = true
                for ((peerId, list) in _failedStore) {
                    for (m in list) {
                        if (!first) { rows.append("\n") }
                        first = false
                        rows.append(encodeMessage(peerId, m))
                    }
                }

                let names = StringBuilder()
                var firstName = true
                for ((peerId, name) in _failedNames) {
                    if (!firstName) { names.append("\n") }
                    firstName = false
                    names.append("${peerId}|")
                    names.append(encodeText(name))
                }

                prefs.put(messagesKey(_loadedSlot), PreferencesValueType.StringData(rows.toString()))
                prefs.put(namesKey(_loadedSlot), PreferencesValueType.StringData(names.toString()))
                prefs.flush()
                Hilog.info(0, "CjTelegram",
                    "[FailedStore] persisted slot=${_loadedSlot}, peers=${_failedStore.size}")
            } catch (e: Exception) {
                Hilog.error(0, "CjTelegram", "[FailedStore] persist failed: ${e}")
            }
        case None =>
            Hilog.error(0, "CjTelegram", "[FailedStore] persist skipped: context not initialized")
    }
}

private func loadSlotLocked(slot: Int32): Unit {
    _failedStore = HashMap<Int64, ArrayList<Message>>()
    _failedNames = HashMap<Int64, String>()
    _loadedSlot = slot

    match (_prefsCtx) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, FAILED_PREFS)
                let raw = match (prefs.get(messagesKey(slot), PreferencesValueType.StringData(""))) {
                    case PreferencesValueType.StringData(s) => s
                    case _ => ""
                }
                let rawNames = match (prefs.get(namesKey(slot), PreferencesValueType.StringData(""))) {
                    case PreferencesValueType.StringData(s) => s
                    case _ => ""
                }

                if (!rawNames.isEmpty()) {
                    for (line in rawNames.split("\n")) {
                        let f = line.split("|")
                        if (f.size >= 2) {
                            let peerId = parseInt64(f[0], 0)
                            if (peerId != 0) { _failedNames[peerId] = decodeText(f[1]) }
                        }
                    }
                }
                if (!raw.isEmpty()) {
                    for (line in raw.split("\n")) {
                        match (decodeMessage(line)) {
                            case Some((peerId, message)) => addLoadedMessage(peerId, message)
                            case None => Hilog.error(0, "CjTelegram", "[FailedStore] ignored corrupt v2 row")
                        }
                    }
                }

                // 旧版本没有账号分区，只允许迁移到默认 slot 0。
                var migratedLegacy = false
                if (raw.isEmpty() && slot == 0) {
                    migratedLegacy = loadLegacy(prefs)
                    if (!migratedLegacy) {
                        migratedLegacy = recoverBrokenLegacy(ctx)
                    }
                }
                if (migratedLegacy) {
                    persistLocked()
                    prefs.delete(FAILED_KEY_V1)
                    prefs.delete(FAILED_NAMES_KEY_V1)
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[FailedStore] migrated legacy v1 to v2")
                }
                Hilog.info(0, "CjTelegram",
                    "[FailedStore] loaded slot=${slot}, peers=${_failedStore.size}")
            } catch (e: Exception) {
                Hilog.error(0, "CjTelegram", "[FailedStore] load failed: ${e}")
            }
        case None => ()
    }
}

private func ensureActiveSlotLocked(): Unit {
    let slot = getAuthStorage().getActiveSlot()
    if (_loadedSlot != slot) {
        loadSlotLocked(slot)
    }
}

/** 启动时绑定 Preferences context，并恢复当前账号的失败消息。 */
public func failedStoreLoad(ctx: UIAbilityContext): Unit {
    synchronized(_failedStoreMutex) {
        _prefsCtx = Some(ctx)
        loadSlotLocked(getAuthStorage().getActiveSlot())
    }
}

public func failedStoreAdd(peerId: Int64, peerName: String, msg: Message): Unit {
    synchronized(_failedStoreMutex) {
        ensureActiveSlotLocked()
        if (!peerName.isEmpty()) { _failedNames[peerId] = peerName }
        // 与 iOS enqueueMessages 的 StoreMessage.timestamp 一致：失败发生前本地消息
        // 就必须具有真实 Unix 时间；time 只是由它派生的本地时区展示值。
        if (msg.rawTimestamp <= 0) {
            msg.rawTimestamp = DateTime.now().toUnixTimeStamp().toSeconds()
        }
        msg.time = formatMessageTime(msg.rawTimestamp)

        // 同一失败回调重复到达时按稳定本地 id 去重；旧 v1 的 id=0 回退到内容+时间。
        let kept = ArrayList<Message>()
        if (_failedStore.contains(peerId)) {
            for (existing in _failedStore[peerId]) {
                let same = if (msg.id != 0 && existing.id != 0) {
                    msg.id == existing.id
                } else {
                    msg.content == existing.content && msg.time == existing.time
                }
                if (!same) { kept.add(existing) }
            }
        }
        kept.add(msg)
        _failedStore[peerId] = kept
        persistLocked()
    }
}

public func failedStoreGet(peerId: Int64): ArrayList<Message> {
    return synchronized(_failedStoreMutex) {
        ensureActiveSlotLocked()
        let copy = ArrayList<Message>()
        if (_failedStore.contains(peerId)) {
            for (m in _failedStore[peerId]) { copy.add(m) }
        }
        copy
    }
}

public func failedStoreHas(peerId: Int64): Bool {
    return synchronized(_failedStoreMutex) {
        ensureActiveSlotLocked()
        _failedStore.contains(peerId) && _failedStore[peerId].size > 0
    }
}

/** 聊天列表预览用：最后一条失败消息文本。 */
public func failedStoreLastText(peerId: Int64): String {
    return synchronized(_failedStoreMutex) {
        ensureActiveSlotLocked()
        if (_failedStore.contains(peerId) && _failedStore[peerId].size > 0) {
            let list = _failedStore[peerId]
            list[list.size - 1].content
        } else {
            ""
        }
    }
}

/** 最后一条失败消息的 Unix 秒；没有失败消息时为 0。 */
public func failedStoreLastTimestamp(peerId: Int64): Int64 {
    return synchronized(_failedStoreMutex) {
        ensureActiveSlotLocked()
        if (_failedStore.contains(peerId) && _failedStore[peerId].size > 0) {
            var latest: Int64 = 0
            for (m in _failedStore[peerId]) {
                if (m.rawTimestamp > latest) { latest = m.rawTimestamp }
            }
            latest
        } else {
            0
        }
    }
}

/** 重发成功或用户删除后移除。 */
public func failedStoreRemove(peerId: Int64, msg: Message): Unit {
    synchronized(_failedStoreMutex) {
        ensureActiveSlotLocked()
        if (!_failedStore.contains(peerId)) { return }
        let kept = ArrayList<Message>()
        for (existing in _failedStore[peerId]) {
            let same = if (msg.id != 0 && existing.id != 0) {
                msg.id == existing.id
            } else {
                msg.content == existing.content && msg.time == existing.time
            }
            if (!same) { kept.add(existing) }
        }
        if (kept.isEmpty()) {
            let _ = _failedStore.remove(peerId)
            let _ = _failedNames.remove(peerId)
        } else {
            _failedStore[peerId] = kept
        }
        persistLocked()
    }
}

public func failedStoreClear(peerId: Int64): Unit {
    synchronized(_failedStoreMutex) {
        ensureActiveSlotLocked()
        let _ = _failedStore.remove(peerId)
        let _ = _failedNames.remove(peerId)
        persistLocked()
    }
}

/** 有失败消息的全部 peerId（聊天列表本地合成条目用）。 */
public func failedStorePeers(): ArrayList<Int64> {
    return synchronized(_failedStoreMutex) {
        ensureActiveSlotLocked()
        let out = ArrayList<Int64>()
        for ((peerId, list) in _failedStore) {
            if (!list.isEmpty()) { out.add(peerId) }
        }
        out
    }
}

public func failedStoreName(peerId: Int64): String {
    return synchronized(_failedStoreMutex) {
        ensureActiveSlotLocked()
        if (_failedNames.contains(peerId)) { _failedNames[peerId] } else { "" }
    }
}
