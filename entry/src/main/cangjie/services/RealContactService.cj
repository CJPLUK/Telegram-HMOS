package ohos_app_cangjie_entry.services

import kit.ArkData.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.core.storage.trOr
import ohos_app_cangjie_entry.utils.*
import std.collection.ArrayList
import std.sync.*
import std.collection.HashMap
import std.collection.HashSet
import std.time.DateTime

/**
 * 真实联系人服务（Phase B + ContactList 增强 + P2-157 gaps）
 *
 * 对应 TelegramHarmony RealContactService.ets
 * 使用 MTProto 获取真实联系人列表
 *
 * 增强功能:
 * - 解析用户在线状态和最后上线时间
 * - 支持按名字或最后上线排序
 * - 格式化 "last seen" 显示文本
 * - P2-157: deviceSync toggle, findPeerByLocalContactId, deviceContactsImportedByCount
 */
private var _contactServiceInstance: Option<RealContactService> = None
// 全局刷新信号：AddContactPage 添加成功后设为 true，ContactListPage 检测到后刷新并清除
private var _contactsNeedRefresh: Bool = false
// V5 S1-05：联系人变更代数。上面的一次性标记只能被一个消费者（ContactListPage 轮询）清掉，
// 其它持有联系人快照的页面（New Message / ComposePage 等）无法据此得知列表已过期。
// 代数只增不减、不被消费：页面记住自己加载时的代数，重新可见时比对即可决定是否重拉。
// 对位 iOS：ComposeControllerNode 订阅 contactPeersView，联系人增删后列表立即更新。
private var _contactsRefreshGeneration: Int64 = 0

// P2-157: 设备联系人同步开关持久化存储
// 对应 iOS ContactsSettings.synchronizeContacts（UserDefaults 持久化）。
// 使用 HarmonyOS Preferences 存储到 "telegram_contacts_settings" store，key "device_sync_enabled"。
// 登出时应清除此 store（见 emitted_integration_contracts ic_deviceSync_logout_clear）。
private let _CONTACTS_SETTINGS_STORE: String = "telegram_contacts_settings"
private let _KEY_DEVICE_SYNC_ENABLED: String = "device_sync_enabled"
// 人工反馈 #1：HarmonyOS checkAccessToken 分不清「从未询问」与「已拒绝」，用本地持久化标记
// 记录是否已经弹过一次系统授权框，据此在 notDetermined("Allow Access") / denied("Allow in Settings")
// 两态之间切换（对位 iOS DeviceAccess.authorizationStatus(.contacts) 的 .notDetermined / .denied）。
private let _KEY_CONTACTS_PERM_ASKED: String = "contacts_perm_asked"
private var _contactsPermAsked: Bool = false
private var _deviceSyncPrefs: Option<Preferences> = None
private var _deviceSyncPrefsInitialized: Bool = false
// 内存缓存：避免每次读 Preferences（I/O）；write-through 到 Preferences
private var _deviceContactsSyncEnabled: Bool = true

// P2-157: 设备联系人导入计数缓存 (phone → importedByCount)
// 每次 importContact 成功时向 map 记录，deviceContactsImportedByCount() 从此读取。
// key: 规范化手机号 (+CC NNNN…)，value: 该号码被导入次数（来自 server popular_invites 的 importers 字段）
private var _deviceImportCountMap: HashMap<String, Int32> = HashMap<String, Int32>()

// P2-157: localContactId → userId 映射 (对应 iOS postbox DeviceContactImportInfo)
// key: device contact localIdentifier（如 "6B29FC40-CA47-1067-B31D-00DD010662DA"），value: Telegram userId
private var _localContactIdToUserId: HashMap<String, Int64> = HashMap<String, Int64>()

// P2-157b: contacts.getTopPeers 本地缓存（hash 增量）
// _topPeersHash: 上次成功响应用的 hash，用于下次请求（not_modified 时复用缓存）。
// _cachedTopPeers: 缓存的 ContactDisplayData 列表（已按 rating 降序排序）。
private var _topPeersHash: Int64 = 0
private var _cachedTopPeers: ArrayList<ContactDisplayData> = ArrayList<ContactDisplayData>()

// TC-CONTACTS 修复：getContacts 的 last-good 缓存。刷新循环偶发拿到传输层空回包/RPC 错误时
// 返回缓存而不是空列表，避免把已加载的联系人清空（对齐 iOS：失败刷新不清 UI）。
private var _cachedContacts: ArrayList<ContactDisplayData> = ArrayList<ContactDisplayData>()
// 并发合并守卫：启动时 loadContacts 与刷新信号循环会同毫秒并发 getContacts，
// 两条相同 TL 请求在 MTProto 响应配对上竞争——输家阻塞（曾实测 60s）或拿空回包。
// in-flight 期间的后续调用改为等待完成后直接取 last-good 缓存（页面加载即刻恢复）。
private var _contactsFetching: Bool = false

public func getRealContactService(): RealContactService {
    match (_contactServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = RealContactService()
            _contactServiceInstance = Some(inst)
            return inst
    }
}

// P2-157: 确保 Preferences 已初始化（懒初始化，仿 HintsService.ensureInit）
private func ensureDeviceSyncPrefsInit(): Unit {
    if (_deviceSyncPrefsInitialized) {
        return
    }
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, _CONTACTS_SETTINGS_STORE)
                _deviceSyncPrefs = Some(prefs)
                // 从持久化读取初始值（默认 true，与 iOS 默认相同）
                let val = prefs.get(_KEY_DEVICE_SYNC_ENABLED, PreferencesValueType.BoolData(true))
                match (val) {
                    case PreferencesValueType.BoolData(b) => _deviceContactsSyncEnabled = b
                    case _ => ()
                }
                match (prefs.get(_KEY_CONTACTS_PERM_ASKED, PreferencesValueType.BoolData(false))) {
                    case PreferencesValueType.BoolData(b) => _contactsPermAsked = b
                    case _ => ()
                }
                Hilog.info(0, "CjTelegram", "[ContactsSettings] Preferences initialized, device_sync=${_deviceContactsSyncEnabled}")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ContactsSettings] Preferences init failed, memory mode: ${e}")
            }
            _deviceSyncPrefsInitialized = true
        case None =>
            _deviceSyncPrefsInitialized = true
    }
}

/** 人工反馈 #1：是否已弹过一次通讯录系统授权框（持久化）。 */
public func getContactsPermissionAsked(): Bool {
    ensureDeviceSyncPrefsInit()
    return _contactsPermAsked
}

public func setContactsPermissionAsked(): Unit {
    ensureDeviceSyncPrefsInit()
    _contactsPermAsked = true
    match (_deviceSyncPrefs) {
        case Some(prefs) =>
            try {
                prefs.put(_KEY_CONTACTS_PERM_ASKED, PreferencesValueType.BoolData(true))
                prefs.flush()
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ContactsSettings] contacts_perm_asked persist failed: ${e}")
            }
        case None => ()
    }
}

// S8-01：联系人排序（iOS ContactSynchronizationSettings.sortOrder，默认 .presence），持久化。
private let _KEY_CONTACTS_SORT_BY_PRESENCE = "contacts_sort_by_presence"

/** true = by Last Seen（.presence），false = by Name（.natural）。 */
public func getContactsSortByPresence(): Bool {
    ensureDeviceSyncPrefsInit()
    match (_deviceSyncPrefs) {
        case Some(prefs) =>
            try {
                match (prefs.get(_KEY_CONTACTS_SORT_BY_PRESENCE, PreferencesValueType.BoolData(true))) {
                    case PreferencesValueType.BoolData(b) => return b
                    case _ => return true
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ContactsSettings] sort order read failed: ${e}")
            }
        case None => ()
    }
    return true
}

public func setContactsSortByPresence(byPresence: Bool): Unit {
    ensureDeviceSyncPrefsInit()
    match (_deviceSyncPrefs) {
        case Some(prefs) =>
            try {
                prefs.put(_KEY_CONTACTS_SORT_BY_PRESENCE, PreferencesValueType.BoolData(byPresence))
                prefs.flush()
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ContactsSettings] sort order persist failed: ${e}")
            }
        case None => ()
    }
}

// P2-157: 设备联系人同步开关（对应 iOS updateIsContactSynchronizationEnabled）
// 写入内存缓存并持久化到 Preferences（重启后保持用户设置）
public func setDeviceContactsSyncEnabled(enabled: Bool): Unit {
    ensureDeviceSyncPrefsInit()
    _deviceContactsSyncEnabled = enabled
    match (_deviceSyncPrefs) {
        case Some(prefs) =>
            try {
                prefs.put(_KEY_DEVICE_SYNC_ENABLED, PreferencesValueType.BoolData(enabled))
                prefs.flush()
                Hilog.info(0, "CjTelegram", "[ContactsSettings] device_sync persisted: ${enabled}")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ContactsSettings] device_sync persist failed: ${e}")
            }
        case None => ()
    }
}

public func isDeviceContactsSyncEnabled(): Bool {
    ensureDeviceSyncPrefsInit()
    return _deviceContactsSyncEnabled
}

// P2-157: localContactId → userId 查找（对应 iOS findPeerByLocalContactIdentifier）
public func findPeerByLocalContactId(localId: String): Option<Int64> {
    if (_localContactIdToUserId.contains(localId)) {
        return Some(_localContactIdToUserId[localId])
    }
    return None
}

// P2-157: 注册 localContactId → userId 映射（importContact 成功后调用）
public func registerLocalContactId(localId: String, userId: Int64): Unit {
    _localContactIdToUserId[localId] = userId
}

// P2-157: 获取设备联系人被导入的次数（对应 iOS deviceContactsImportedByCount）
// phones: 手机号列表（规范化 +CC…），返回 phone → importedByCount 映射
public func deviceContactsImportedByCount(phones: ArrayList<String>): HashMap<String, Int32> {
    let result = HashMap<String, Int32>()
    for (phone in phones) {
        if (_deviceImportCountMap.contains(phone)) {
            let count = _deviceImportCountMap[phone]
            if (count > 0) {
                result[phone] = count
            }
        }
    }
    return result
}

// 内部：importContact 成功后更新 importedByCount 缓存（从 server popular_invites 的 importers 字段）
public func updateImportedByCount(phone: String, importers: Int32): Unit {
    if (_deviceImportCountMap.contains(phone)) {
        let existing = _deviceImportCountMap[phone]
        if (importers > existing) {
            _deviceImportCountMap[phone] = importers
        }
    } else {
        _deviceImportCountMap[phone] = importers
    }
}

/**
 * 标记联系人列表需要刷新（添加/删除联系人后调用）
 */
public func setContactsNeedRefresh(): Unit {
    _contactsNeedRefresh = true
    _contactsRefreshGeneration += 1
}

/** 当前联系人变更代数（每次 setContactsNeedRefresh 递增） */
public func getContactsRefreshGeneration(): Int64 {
    return _contactsRefreshGeneration
}

/**
 * 检查并清除刷新标记（ContactListPage 轮询调用）
 */
public func checkAndClearContactsRefresh(): Bool {
    if (_contactsNeedRefresh) {
        _contactsNeedRefresh = false
        return true
    }
    return false
}

/**
 * 联系人显示数据
 */
public class ContactDisplayData {
    public var userId: Int64 = 0
    public var accessHash: Int64 = 0
    public var firstName: String = ""
    public var lastName: String = ""
    public var username: String = ""
    public var phone: String = ""
    public var isBot: Bool = false
    public var isSelf: Bool = false
    // 在线状态
    public var isOnline: Bool = false
    public var wasOnline: Int32 = 0    // Unix timestamp (秒)
    public var statusType: String = "empty"  // "online", "offline", "recently", "lastWeek", "lastMonth", "empty"
    // P5-6: 群组角色
    public var role: String = ""  // "creator", "admin", "bot", "" (member)
    // P2-157b: contacts.getTopPeers 返回的交互频率评分（double）。0.0 表示非 top-peer 来源。
    public var rating: Float64 = 0.0
    // 人工反馈 #11：选择态下该行是否已勾选（仅用于 ForEach key，使勾选变化触发行重建；
    // SelectablePeerComponent.isSelected 是普通 var，首次 build 后不再随父级更新）
    public var uiSelected: Bool = false
    // 人工反馈 R2-3：上次渲染时的 presence 文案（进 ForEach key）。iOS PeerPresenceStatusManager
    // 会在 "just now → N minutes ago → today at" 该变的时刻自动重排；这里由 ContactListPage 的
    // 1s 轮询比对 getLastSeenText() 与该值，不一致才重建行。
    public var uiPresenceText: String = ""
    
    public func getDisplayName(): String {
        var name = this.firstName
        if (this.lastName.size > 0) {
            name = name + " " + this.lastName
        }
        if (name.isEmpty()) {
            if (this.username.size > 0) {
                return "@" + this.username
            }
            return "User ${this.userId}"
        }
        return name
    }
    
    public func getInitial(): String {
        let name = this.getDisplayName()
        if (name.size > 0) {
            let runes = name.toRuneArray()
            if (runes.size > 0) {
                return runes[0].toString()
            }
        }
        return "?"
    }

    /**
     * G-02 iOS lastFirst 显示顺序(参考端实拍 "**Yuan** Hao":主排序名=姓,加粗前置)。
     * 主名:lastName 非空取 lastName,否则退回 getDisplayName() 整串。
     */
    // 人工反馈 R2（姓名顺序）：iOS 默认 displayOrder / sortOrder 均为 firstLast
    //（"清源 牛"、"Qingyuan Niu"），原 G-02 的 lastFirst 口径与 iOS 实机不符，
    // 且与对话框标题（firstLast）互相矛盾。主名 = firstName（粗体），副名 = lastName（常规）。
    public func getListPrimaryName(): String {
        if (this.firstName.size > 0) {
            return this.firstName
        }
        return this.getDisplayName()
    }

    /** 副名：firstName 与 lastName 都非空时为 lastName（常规字重跟在主名后），否则空串。 */
    public func getListSecondaryName(): String {
        if (this.firstName.size > 0 && this.lastName.size > 0) {
            return this.lastName
        }
        return ""
    }

    /** 排序/分区键：firstLast 口径（"Qingyuan Niu" 排 Q 区，与 iOS 默认 sortOrder 一致）。 */
    public func getListSortName(): String {
        return this.getDisplayName()
    }

    /**
     * 获取两个字母的首字母（用于头像），如 "YL", "P"
     */
    public func getAvatarInitials(): String {
        if (this.firstName.size > 0 && this.lastName.size > 0) {
            let fRunes = this.firstName.toRuneArray()
            let lRunes = this.lastName.toRuneArray()
            if (fRunes.size > 0 && lRunes.size > 0) {
                return fRunes[0].toString() + lRunes[0].toString()
            }
        }
        return this.getInitial()
    }
    
    /**
     * 获取格式化的 "last seen" 文本
     * 类似 iOS Telegram: "last seen 10 minutes ago", "last seen 01/27/26"
     */
    public func getLastSeenText(): String {
        if (this.isOnline) {
            return trOr("Presence_online", "online")
        }
        if (this.statusType == "recently") {
            return trOr("LastSeen_Lately", "last seen recently")
        }
        if (this.statusType == "lastWeek") {
            return trOr("LastSeen_WithinAWeek", "last seen within a week")
        }
        if (this.statusType == "lastMonth") {
            return trOr("LastSeen_WithinAMonth", "last seen within a month")
        }
        if (this.wasOnline > 0) {
            return formatLastSeen(this.wasOnline)
        }
        if (this.isBot) {
            return trOr("Bot_GenericBotStatus", "bot")
        }
        return trOr("LastSeen_ALongTimeAgo", "last seen a long time ago")
    }
    
    /**
     * 获取排序用的 sortKey
     * 在线用户排最前，然后按最后在线时间降序
     */
    public func getSortKeyByLastSeen(): Int64 {
        // iOS parity（锚点比对发现）：iOS 将模糊态（recently/lastWeek/lastMonth）排在
        // 一切精确 wasOnline 时间戳之下（参考截图：Fawaz 1月精确时间 > J J "recently"）。
        // 原实现 recently=Int32.Max-1 错排到最前。
        if (this.isOnline) { return Int64(Int32.Max) }
        if (this.wasOnline > 0) { return Int64(this.wasOnline) }  // epoch 秒，远大于下面的哨兵值
        if (this.statusType == "recently") { return 3 }
        if (this.statusType == "lastWeek") { return 2 }
        if (this.statusType == "lastMonth") { return 1 }
        return 0
    }
}

/**
 * G-03 iOS 分层格式（PresenceStrings.swift stringForUserPresence,双端实拍核对）:
 * - <60s: "last seen just now"
 * - <60min: "last seen N minutes ago"
 * - 本地今天: "last seen today at HH:MM"
 * - 本地昨天: "last seen yesterday at HH:MM"（实拍 "last seen yesterday at 17:22"）
 * - 更早: "last seen dd/MM/yy"（实拍 "last seen 21/01/26"）
 */
func formatLastSeen(wasOnline: Int32): String {
    let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
    let nowSec = Int64(nowMs) / 1000
    let ts = Int64(wasOnline)
    let diff = nowSec - ts

    if (diff < 60) {
        return trOr("LastSeen_JustNow", "last seen just now")
    }
    if (diff < 3600) {
        let mins = diff / 60
        if (mins == 1) {
            return trOr("LastSeen_MinutesAgo_1", "last seen 1 minute ago")
        }
        return trOr("LastSeen_MinutesAgo_any", "last seen %@ minutes ago").replace("%@", "${mins}")
    }
    let tsDay = localDayIndexOf(ts)
    let nowDay = localDayIndexOf(nowSec)
    if (tsDay == nowDay) {
        return trOr("LastSeen_TodayAt", "last seen today at %@").replace("%@", formatClockHHMM(ts))
    }
    if (tsDay == nowDay - 1) {
        return trOr("LastSeen_YesterdayAt", "last seen yesterday at %@").replace("%@", formatClockHHMM(ts))
    }
    return trOr("LastSeen_AtDate", "last seen %@").replace("%@", formatShortDateSlashed(ts))
}

/**
 * 从 Unix 时间戳计算月份 (1-12)
 * 简化实现，不处理闰年精确计算
 */
func getMonthFromTimestamp(ts: Int64): Int64 {
    // 使用简单的日期计算
    let days = ts / 86400 + 719468  // 从公元0年开始的天数
    let era = (if (days >= 0) { days } else { days - 146096 }) / 146097
    let doe = days - era * 146097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let m = mp + (if (mp < 10) { Int64(3) } else { Int64(-9) })
    return m
}

/**
 * 从 Unix 时间戳计算日 (1-31)
 */
func getDayFromTimestamp(ts: Int64): Int64 {
    let days = ts / 86400 + 719468
    let era = (if (days >= 0) { days } else { days - 146096 }) / 146097
    let doe = days - era * 146097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    return d
}

/**
 * 从 Unix 时间戳计算年份
 */
func getYearFromTimestamp(ts: Int64): Int64 {
    let days = ts / 86400 + 719468
    let era = (if (days >= 0) { days } else { days - 146096 }) / 146097
    let doe = days - era * 146097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let adjustedY = y + (if (mp >= 10) { Int64(1) } else { Int64(0) })
    return adjustedY
}

/**
 * 屏蔽用户显示数据 (Phase P4-3)
 */
public class BlockedUserDisplayData {
    public var userId: Int64 = 0
    public var accessHash: Int64 = 0
    public var firstName: String = ""
    public var lastName: String = ""
    public var username: String = ""
    public var blockedDate: Int32 = 0

    public func getDisplayName(): String {
        var name = this.firstName
        if (this.lastName.size > 0) {
            name = name + " " + this.lastName
        }
        if (name.isEmpty()) {
            if (this.username.size > 0) {
                return "@" + this.username
            }
            return "User ${this.userId}"
        }
        return name
    }

    public func getInitial(): String {
        let name = this.getDisplayName()
        if (name.size > 0) {
            let runes = name.toRuneArray()
            if (runes.size > 0) {
                return runes[0].toString()
            }
        }
        return "?"
    }

    public func getBlockedDateText(): String {
        if (this.blockedDate <= 0) {
            return ""
        }
        return "blocked " + formatLastSeen(this.blockedDate).replace("last seen ", "")
    }
}

/**
 * BlockedUserEntry：用于 ForEach 的 ToString 包装
 */
public class BlockedUserEntry <: ToString {
    public let data: BlockedUserDisplayData

    public init(data: BlockedUserDisplayData) {
        this.data = data
    }

    public func toString(): String {
        return "blocked_${this.data.userId}_${this.data.firstName}"
    }
}

/**
 * 排序方式枚举
 */
public enum ContactSortMode {
    | ByName        // 按名字字母排序
    | ByLastSeen    // 按最后在线时间排序
}

/**
 * 对联系人列表排序
 */
public func sortContacts(contacts: ArrayList<ContactDisplayData>, mode: ContactSortMode): ArrayList<ContactDisplayData> {
    let arr = contacts.toArray()
    let sorted = ArrayList<ContactDisplayData>()
    
    // 简单选择排序
    let used = Array<Bool>(arr.size, repeat: false)
    
    var i: Int64 = 0
    while (i < arr.size) {
        var bestIdx: Int64 = -1
        var j: Int64 = 0
        while (j < arr.size) {
            if (!used[j]) {
                if (bestIdx < 0) {
                    bestIdx = j
                } else {
                    let better = match (mode) {
                        // G-02: lastFirst 排序键(与 iOS 参考端一致)
                        case ByName => compareNames(arr[j].getListSortName(), arr[bestIdx].getListSortName()) < 0
                        case ByLastSeen => arr[j].getSortKeyByLastSeen() > arr[bestIdx].getSortKeyByLastSeen()
                    }
                    if (better) {
                        bestIdx = j
                    }
                }
            }
            j = j + 1
        }
        if (bestIdx >= 0) {
            used[bestIdx] = true
            sorted.add(arr[bestIdx])
        }
        i = i + 1
    }
    return sorted
}

/**
 * 联系人分组（按首字母 A-Z，用于姓名索引分区）
 */
public class ContactSection {
    public var letter: String = ""
    public var contacts: ArrayList<ContactDisplayData> = ArrayList<ContactDisplayData>()

    public init(letter: String, contacts: ArrayList<ContactDisplayData>) {
        this.letter = letter
        this.contacts = contacts
    }
}

/**
 * 将联系人按首字母分组，用于姓名索引分区显示
 * 仅当 sortMode 为 ByName 时使用
 */
public func buildContactsGroupedBySection(contacts: ArrayList<ContactDisplayData>): ArrayList<ContactSection> {
    let sorted = sortContacts(contacts, ContactSortMode.ByName)
    let sections = ArrayList<ContactSection>()
    var currentLetter: String = ""
    var currentList = ArrayList<ContactDisplayData>()

    for (c in sorted) {
        // 使用 TransliterationUtils.firstLetterForSorting 派生首字母：
        // 中文联系人 → 拼音首字母大写 (A-Z)；英文 → 大写首字母；数字/符号/其他 → "#"
        // G-02: A-Z 分区取 lastFirst 排序键首字母
        let letter = firstLetterForSorting(c.getListSortName())

        if (letter != currentLetter) {
            if (currentList.size > 0) {
                sections.add(ContactSection(currentLetter, currentList))
            }
            currentLetter = letter
            currentList = ArrayList<ContactDisplayData>()
        }
        currentList.add(c)
    }
    if (currentList.size > 0) {
        sections.add(ContactSection(currentLetter, currentList))
    }
    return sections
}

/**
 * 获取 Telegram 邀请链接（用于 Invite Friends 分享）
 *
 * 对齐 iOS PresentationStrings 的 InviteText.URL。https://t.me 是 Web 入口，
 * 不是 Invite Friends 使用的客户端下载链接。
 */
public func getInviteLinkUrl(): String {
    return "https://telegram.org/dl"
}

/**
 * 获取单联系人邀请正文，对齐 iOS InviteText.SingleContact。
 */
public func getInviteText(): String {
    return "Hey, I'm using Telegram to chat. Join me! Download it here: " + getInviteLinkUrl()
}

/**
 * 拼音感知字符串比较（按字典序）。
 * 先通过 transliterateToLatin 将字符串中的中文汉字转换为拼音首字母，
 * 使中文联系人按拼音顺序而非 Unicode 码点排序；英文字母保持大小写折叠后的字母序。
 * 返回 <0 表示 a < b, 0 表示 a == b, >0 表示 a > b
 */
func compareNames(a: String, b: String): Int64 {
    // 将中文汉字映射为拼音首字母，非汉字字符原样保留；转小写折叠后比较
    let aKey = transliterateToLatin(a).toAsciiLower()
    let bKey = transliterateToLatin(b).toAsciiLower()
    let aRunes = aKey.toRuneArray()
    let bRunes = bKey.toRuneArray()
    let minLen = if (aRunes.size < bRunes.size) { aRunes.size } else { bRunes.size }
    var i: Int64 = 0
    while (i < minLen) {
        let aVal = Int64(UInt32(aRunes[i]))
        let bVal = Int64(UInt32(bRunes[i]))
        if (aVal != bVal) {
            return aVal - bVal
        }
        i = i + 1
    }
    return aRunes.size - bRunes.size
}

public class RealContactService {
    
    /**
     * 获取联系人列表
     */
    public func getContacts(): ArrayList<ContactDisplayData> {
        Hilog.info(0, "CjTelegram", "[RealContactService] getContacts")
        // 并发合并：已有一次拉取在途 → 等它完成后返回缓存（最多等 10s）
        if (_contactsFetching) {
            var waited: Int64 = 0
            while (_contactsFetching && waited < 100) {
                sleep(Duration.millisecond * 100)
                waited = waited + 1
            }
            Hilog.info(0, "CjTelegram", "[RealContactService] getContacts: coalesced with in-flight fetch, cache size=${_cachedContacts.size}")
            return _cachedContacts
        }
        _contactsFetching = true
        let client = getMTProtoClient()
        
        let req = ContactsGetContacts()
        req.hash = 0  // 首次加载，不用 hash
        
        let responseData = client.sendRequest(req.toBytes())
        
        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[RealContactService] getContacts: empty response, returning cache size=${_cachedContacts.size}")
            _contactsFetching = false
            return _cachedContacts
        }

        // 检查 RPC 错误
        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkConstructor = checkD.readUInt32()
            if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMessage = checkD.readString()
                Hilog.info(0, "CjTelegram", "[RealContactService] getContacts RPC Error: ${errorCode} - ${errorMessage}, returning cache size=${_cachedContacts.size}")
                _contactsFetching = false
                return _cachedContacts
            }
        }
        
        let response = ContactsContactsResponse.deserialize(responseData)
        
        // 构建用户 map + 缓存到 UserPhotoService (Phase L4)
        let userMap = HashMap<Int64, UserResponse>()
        let photoService = getUserPhotoService()
        // P2-289b: 网络拿到的联系人 User 落本地 PeerTable（离线 peer 信息可读）。
        // 收集成 ArrayList 一次批量落库；DB 不可用时 PeerStore 内部静默降级，不影响联系人加载。
        let peerStore = getPeerStore()
        let peersToCache = ArrayList<UserResponse>()
        for (user in response.users) {
            userMap[user.id] = user
            photoService.cacheUser(user)
            peersToCache.add(user)
        }
        peerStore.cacheUserResponses(peersToCache)
        
        // 转换为显示数据
        let contacts = ArrayList<ContactDisplayData>()
        let msgService = getRealMessageService()
        
        for (userId in response.contactUserIds) {
            if (userMap.contains(userId)) {
                let user = userMap[userId]
                // 跳过自己和机器人
                if (user.isSelf) { continue }
                
                let contact = ContactDisplayData()
                contact.userId = user.id
                contact.accessHash = user.accessHash
                contact.firstName = user.firstName
                contact.lastName = user.lastName
                contact.username = user.username
                contact.phone = user.phone
                contact.isBot = user.isBot
                // 填充在线状态
                contact.isOnline = user.isOnline
                contact.wasOnline = user.wasOnline
                contact.statusType = user.statusType
                
                // 缓存 accessHash
                if (user.accessHash != 0) {
                    msgService.cacheUserAccessHash(user.id, user.accessHash)
                }
                
                contacts.add(contact)
            }
        }
        
        Hilog.info(0, "CjTelegram", "[RealContactService] getContacts: ${contacts.size} contacts")
        // last-good 缓存：仅在拿到非空结果时更新（服务器真返回 0 联系人的账户首查也安全——
        // 空缓存 + 空结果等价）
        if (contacts.size > 0) {
            _cachedContacts = contacts
        }
        _contactsFetching = false
        return contacts
    }
    
    /**
     * 搜索联系人
     */
    public func searchContacts(query: String, limit!: Int32 = 20): ArrayList<ContactDisplayData> {
        Hilog.info(0, "CjTelegram", "[RealContactService] searchContacts: q='${query}'")
        let client = getMTProtoClient()
        
        let req = ContactsSearch()
        req.q = query
        req.limit = limit
        
        let responseData = client.sendRequest(req.toBytes())
        
        if (responseData.size == 0) {
            return ArrayList<ContactDisplayData>()
        }
        
        // 检查 RPC 错误
        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkConstructor = checkD.readUInt32()
            if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMessage = checkD.readString()
                Hilog.info(0, "CjTelegram", "[RealContactService] searchContacts RPC Error: ${errorCode} - ${errorMessage}")
                return ArrayList<ContactDisplayData>()
            }
        }
        
        let response = ContactsFoundResponse.deserialize(responseData)
        let contacts = ArrayList<ContactDisplayData>()
        let msgService = getRealMessageService()
        
        for (user in response.users) {
            if (user.isSelf || user.isEmpty) { continue }
            let contact = ContactDisplayData()
            contact.userId = user.id
            contact.accessHash = user.accessHash
            contact.firstName = user.firstName
            contact.lastName = user.lastName
            contact.username = user.username
            contact.phone = user.phone
            contact.isBot = user.isBot
            contact.isOnline = user.isOnline
            contact.wasOnline = user.wasOnline
            contact.statusType = user.statusType
            
            if (user.accessHash != 0) {
                msgService.cacheUserAccessHash(user.id, user.accessHash)
            }
            
            contacts.add(contact)
        }
        
        return contacts
    }
    
    /**
     * S8-03: contacts.search 的远端用户结果，按 iOS searchRemotePeers 的两组顺序
     * （my_results 在前、results 在后，ContactsSearchContainerNode.swift:500-575）只取 user 类
     * peer，跳过 self / empty。用于联系人页搜索的 GLOBAL SEARCH 分区。
     */
    public func searchRemoteUsers(query: String, limit!: Int32 = 20): ArrayList<ContactDisplayData> {
        let out = ArrayList<ContactDisplayData>()
        let req = ContactsSearch()
        req.q = query
        req.limit = limit
        let responseData = getMTProtoClient().sendRequest(req.toBytes())
        if (responseData.size < 4) { return out }
        let checkD = TLDeserializer(responseData)
        let checkConstructor = checkD.readUInt32()
        if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
            Hilog.info(0, "CjTelegram", "[RealContactService] searchRemoteUsers RPC error")
            return out
        }
        let response = ContactsFoundResponse.deserialize(responseData)
        let usersById = HashMap<Int64, UserResponse>()
        for (u in response.users) { usersById[u.id] = u }
        let msgService = getRealMessageService()
        let seen = HashSet<Int64>()
        let ordered = ArrayList<PeerResponse>()
        ordered.add(all: response.myResults)
        ordered.add(all: response.results)
        for (peer in ordered) {
            if (peer.type_ != "user" || seen.contains(peer.id) || !usersById.contains(peer.id)) { continue }
            let user = usersById[peer.id]
            if (user.isSelf || user.isEmpty) { continue }
            let _ = seen.add(peer.id)
            let contact = ContactDisplayData()
            contact.userId = user.id
            contact.accessHash = user.accessHash
            contact.firstName = user.firstName
            contact.lastName = user.lastName
            contact.username = user.username
            contact.phone = user.phone
            contact.isBot = user.isBot
            contact.isOnline = user.isOnline
            contact.wasOnline = user.wasOnline
            contact.statusType = user.statusType
            if (user.accessHash != 0) {
                msgService.cacheUserAccessHash(user.id, user.accessHash)
            }
            getRealChatListService().cacheUserResponse(user)
            out.add(contact)
        }
        return out
    }

    /**
     * 通过用户名解析用户
     */
    public func resolveUsername(username: String): Option<ContactDisplayData> {
        Hilog.info(0, "CjTelegram", "[RealContactService] resolveUsername: ${username}")
        let client = getMTProtoClient()
        
        let req = ContactsResolveUsername()
        req.username = username
        
        let responseData = client.sendRequest(req.toBytes())
        
        if (responseData.size == 0) {
            return None
        }
        
        // 检查 RPC 错误
        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkConstructor = checkD.readUInt32()
            if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                return None
            }
        }
        
        let response = ContactsResolvedPeerResponse.deserialize(responseData)
        let msgService = getRealMessageService()
        
        for (user in response.users) {
            if (user.id == response.peer.id) {
                let contact = ContactDisplayData()
                contact.userId = user.id
                contact.accessHash = user.accessHash
                contact.firstName = user.firstName
                contact.lastName = user.lastName
                contact.username = user.username
                contact.phone = user.phone
                
                if (user.accessHash != 0) {
                    msgService.cacheUserAccessHash(user.id, user.accessHash)
                }
                
                return Some(contact)
            }
        }
        
        return None
    }
    
    /**
     * 通过手机号导入联系人（查找 Telegram 用户）
     * 返回找到的用户信息（如果该手机号已注册 Telegram）
     */
    public func importContact(phone: String, firstName: String, lastName: String): Option<ContactDisplayData> {
        Hilog.info(0, "CjTelegram", "[RealContactService] importContact: phone='${phone}', name='${firstName} ${lastName}'")
        let client = getMTProtoClient()
        
        let contact = InputPhoneContact()
        contact.clientId = 1
        contact.phone = phone
        contact.firstName = firstName
        contact.lastName = lastName
        
        let req = ContactsImportContacts()
        req.contacts.add(contact)
        
        let responseData = client.sendRequest(req.toBytes())
        
        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[RealContactService] importContact: empty response")
            return None
        }
        
        // 检查 RPC 错误
        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkConstructor = checkD.readUInt32()
            if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMessage = checkD.readString()
                Hilog.info(0, "CjTelegram", "[RealContactService] importContact RPC Error: ${errorCode} - ${errorMessage}")
                return None
            }
        }
        
        let response = ContactsImportedContactsResponse.deserialize(responseData)
        let msgService = getRealMessageService()
        
        if (response.users.size > 0) {
            let user = response.users[0]
            let contactData = ContactDisplayData()
            contactData.userId = user.id
            contactData.accessHash = user.accessHash
            contactData.firstName = user.firstName
            contactData.lastName = user.lastName
            contactData.username = user.username
            contactData.phone = user.phone

            if (user.accessHash != 0) {
                msgService.cacheUserAccessHash(user.id, user.accessHash)
            }

            Hilog.info(0, "CjTelegram", "[RealContactService] importContact: found user id=${user.id}, name='${user.firstName}'")
            return Some(contactData)
        }

        Hilog.info(0, "CjTelegram", "[RealContactService] importContact: phone not registered on Telegram")
        return None
    }

    /**
     * P2-157 Gap 3 + 7: 将用户添加为联系人，同时记录 localContactId 映射和 importedByCount
     * 对应 iOS importContact + registerLocalContactId 组合
     * localContactId: 设备通讯录标识符（如 iOS CNContact.identifier）
     */
    public func importContactWithLocalId(phone: String, firstName: String, lastName: String, localContactId: String): Option<ContactDisplayData> {
        let result = this.importContact(phone, firstName, lastName)
        match (result) {
            case Some(contact) =>
                if (localContactId.size > 0) {
                    registerLocalContactId(localContactId, contact.userId)
                }
                updateImportedByCount(phone, 1)
                return Some(contact)
            case None =>
                return None
        }
    }
    
    /**
     * 将用户添加为联系人
     * 使用 contacts.addContact API
     */
    public func addContact(userId: Int64, accessHash: Int64, firstName: String, lastName: String, phone: String): Bool {
        Hilog.info(0, "CjTelegram", "[RealContactService] addContact: userId=${userId}")
        let client = getMTProtoClient()
        
        let req = ContactsAddContact()
        let inputUser = InputUser()
        inputUser.userId = userId
        inputUser.accessHash = accessHash
        req.id = inputUser
        req.firstName = firstName
        req.lastName = lastName
        req.phone = phone
        
        let responseData = client.sendRequest(req.toBytes())
        
        if (responseData.size == 0) {
            return false
        }
        
        // 检查 RPC 错误
        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkConstructor = checkD.readUInt32()
            if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMessage = checkD.readString()
                Hilog.info(0, "CjTelegram", "[RealContactService] addContact RPC Error: ${errorCode} - ${errorMessage}")
                return false
            }
        }
        
        this.applyUsersFromUpdates(responseData)
        Hilog.info(0, "CjTelegram", "[RealContactService] addContact: success")
        return true
    }

    /**
     * contacts.addContact 返回 Updates，其中 users 是改过备注后的最新 User：
     * 写回用户缓存，各页面重新出现时即可读到新名字。
     */
    private func applyUsersFromUpdates(data: Array<Byte>): Unit {
        try {
            let d = TLDeserializer(data)
            let constructor = d.readUInt32()
            if (constructor == 0x74ae4240 || constructor == 0x725b04c3) {
                let _ = d.readUInt32()
                let updateCount = d.readInt32()
                for (_i in 0..Int64(updateCount)) { skipUpdate(d) }
                let _ = d.readUInt32()
                let userCount = d.readInt32()
                for (_i in 0..Int64(userCount)) {
                    let user = UserResponse.deserializeBoxed(d)
                    getRealChatListService().cacheUserResponse(user)
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[RealContactService] addContact users parse skipped: ${e}")
        }
        getUpdatesManager().handleRawUpdate(data)
    }
    
    // ==================== Phase P4-3: 黑名单管理 ====================

    /**
     * 获取屏蔽用户列表
     * 调用 contacts.getBlocked (0x9a868f80)
     * 返回 BlockedUserDisplayData 列表 (userId, name, date)
     */
    public func getBlockedUsers(): ArrayList<BlockedUserDisplayData> {
        Hilog.info(0, "CjTelegram", "[RealContactService] getBlockedUsers")
        let client = getMTProtoClient()

        let req = ContactsGetBlocked()
        req.offset = 0
        req.limit = 100

        let responseData = client.sendRequest(req.toBytes())
        let result = ArrayList<BlockedUserDisplayData>()

        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[RealContactService] getBlockedUsers: empty response")
            return result
        }

        // 检查 RPC 错误
        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkConstructor = checkD.readUInt32()
            if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMessage = checkD.readString()
                Hilog.info(0, "CjTelegram", "[RealContactService] getBlockedUsers RPC Error: ${errorCode} - ${errorMessage}")
                return result
            }
        }

        let response = ContactsBlockedResponse.deserialize(responseData)

        // 构建 userId → UserResponse 映射
        let userMap = HashMap<Int64, UserResponse>()
        let msgService = getRealMessageService()
        for (user in response.users) {
            userMap[user.id] = user
            if (user.accessHash != 0) {
                msgService.cacheUserAccessHash(user.id, user.accessHash)
            }
        }

        // 将 blocked entries 与 user 数据合并
        for (entry in response.blocked) {
            let data = BlockedUserDisplayData()
            data.userId = entry.peerId
            data.blockedDate = entry.date
            if (userMap.contains(entry.peerId)) {
                let user = userMap[entry.peerId]
                data.accessHash = user.accessHash
                data.firstName = user.firstName
                data.lastName = user.lastName
                data.username = user.username
            }
            result.add(data)
        }

        Hilog.info(0, "CjTelegram", "[RealContactService] getBlockedUsers: ${result.size} blocked users")
        return result
    }

    /**
     * 解除屏蔽
     * 调用 contacts.unblock (0xb550d328)
     */
    public func unblockUser(userId: Int64, accessHash: Int64): Bool {
        Hilog.info(0, "CjTelegram", "[RealContactService] unblockUser: ${userId}")
        let client = getMTProtoClient()

        let peer = InputPeerUser()
        peer.userId = userId
        peer.accessHash = accessHash

        let req = ContactsUnblock()
        req.id = peer

        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkConstructor = checkD.readUInt32()
            if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMessage = checkD.readString()
                Hilog.info(0, "CjTelegram", "[RealContactService] unblockUser RPC Error: ${errorCode} - ${errorMessage}")
                return false
            }
        }

        Hilog.info(0, "CjTelegram", "[RealContactService] unblockUser: success")
        return true
    }

    /**
     * Phase P5-2: 删除联系人 contacts.deleteContacts
     */
    public func deleteContact(userId: Int64, accessHash: Int64): Bool {
        Hilog.info(0, "CjTelegram", "[RealContactService] deleteContact: userId=${userId}")
        let client = getMTProtoClient()

        let inputUser = InputUser()
        inputUser.userId = userId
        inputUser.accessHash = accessHash

        let req = ContactsDeleteContacts()
        req.idList.add(inputUser)

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkConstructor = checkD.readUInt32()
            if (checkConstructor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMessage = checkD.readString()
                Hilog.info(0, "CjTelegram", "[RealContactService] deleteContact RPC Error: ${errorCode} - ${errorMessage}")
                return false
            }
        }

        Hilog.info(0, "CjTelegram", "[RealContactService] deleteContact: success")
        // iOS _internal_deleteContactPeerInteractively → _internal_updatePeerIsContact(isContact: false)
        // (ContactManagement.swift:111-120)：本地 peer 立即变为非联系人，私聊顶部栏据此显示 Add to Contacts
        match (getUserPhotoService().getCachedUser(userId)) {
            case Some(u) => u.isContact = false
            case None => ()
        }
        match (getRealChatListService().getCachedUser(userId)) {
            case Some(u) => u.isContact = false
            case None => ()
        }
        return true
    }

    // ==================== P2-157: 联系人扩展方法 ====================

    /**
     * P2-157 Gap 2: 更新联系人姓名（contacts.addContact#e8f463d0 复用：flags=0 + 空 phone）
     * 对应 iOS _internal_updateContactName → contacts.addContact(flags:0 id: firstName: lastName: phone:"" note:nil)
     */
    public func updateContactName(userId: Int64, accessHash: Int64, firstName: String, lastName: String): Bool {
        Hilog.info(0, "CjTelegram", "[RealContactService] updateContactName: userId=${userId}")
        let client = getMTProtoClient()

        let inputUser = InputUser()
        inputUser.userId = userId
        inputUser.accessHash = accessHash

        let req = ContactsAddContact()
        req.id = inputUser
        req.firstName = firstName
        req.lastName = lastName
        req.phone = ""

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkCtor = checkD.readUInt32()
            if (checkCtor == TLConstructors.RPC_ERROR || checkCtor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMsg = checkD.readString()
                Hilog.info(0, "CjTelegram", "[RealContactService] updateContactName RPC Error: ${errorCode} - ${errorMsg}")
                return false
            }
        }
        Hilog.info(0, "CjTelegram", "[RealContactService] updateContactName: success")
        return true
    }

    /**
     * P2-157 Gap 2: 更新联系人备注（contacts.updateContactNote#139f63fb）
     * 对应 iOS _internal_updateContactNote → contacts.updateContactNote(id:, note:TextWithEntities)
     * contacts.updateContactNote 返回 Bool（0x997275b5 = true, 0xbc799737 = false）
     */
    public func updateContactNote(userId: Int64, accessHash: Int64, noteText: String): Bool {
        Hilog.info(0, "CjTelegram", "[RealContactService] updateContactNote: userId=${userId}")
        let client = getMTProtoClient()

        let inputUser = InputUser()
        inputUser.userId = userId
        inputUser.accessHash = accessHash

        let req = ContactsUpdateContactNote()
        req.id = inputUser
        req.noteText = noteText

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkCtor = checkD.readUInt32()
            if (checkCtor == TLConstructors.RPC_ERROR || checkCtor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMsg = checkD.readString()
                Hilog.info(0, "CjTelegram", "[RealContactService] updateContactNote RPC Error: ${errorCode} - ${errorMsg}")
                return false
            }
            if (checkCtor == 0x997275b5) {
                Hilog.info(0, "CjTelegram", "[RealContactService] updateContactNote: success (boolTrue)")
                return true
            }
        }
        Hilog.info(0, "CjTelegram", "[RealContactService] updateContactNote: success")
        return true
    }

    /**
     * P2-157 Gap 4: 接受并共享联系人（contacts.acceptContact#f831a20f id:InputUser = Updates）
     * 对应 iOS _internal_acceptAndShareContact → contacts.acceptContact(id:)
     */
    public func acceptAndShareContact(userId: Int64, accessHash: Int64): Bool {
        Hilog.info(0, "CjTelegram", "[RealContactService] acceptAndShareContact: userId=${userId}")
        let client = getMTProtoClient()

        let inputUser = InputUser()
        inputUser.userId = userId
        inputUser.accessHash = accessHash

        let req = ContactsAcceptContact()
        req.id = inputUser

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkCtor = checkD.readUInt32()
            if (checkCtor == TLConstructors.RPC_ERROR || checkCtor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMsg = checkD.readString()
                Hilog.info(0, "CjTelegram", "[RealContactService] acceptAndShareContact RPC Error: ${errorCode} - ${errorMsg}")
                return false
            }
        }
        Hilog.info(0, "CjTelegram", "[RealContactService] acceptAndShareContact: success")
        setContactsNeedRefresh()
        return true
    }

    /**
     * P2-157 Gap 5: 搜索远端 peers（contacts.search#11f812d8 → contacts.found#b3134d9d）
     * 对应 iOS _internal_searchPeers → contacts.search(q: limit:)
     * 返回用户列表（ContactDisplayData），chats 列表（ChatDisplayData 暂用同结构）
     * 复用现有 ContactsSearch + ContactsFoundResponse。
     */
    public func searchRemotePeers(query: String, limit!: Int32 = 50): ArrayList<ContactDisplayData> {
        Hilog.info(0, "CjTelegram", "[RealContactService] searchRemotePeers: q='${query}'")
        let client = getMTProtoClient()

        let req = ContactsSearch()
        req.q = query
        req.limit = limit

        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size == 0) {
            return ArrayList<ContactDisplayData>()
        }

        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkCtor = checkD.readUInt32()
            if (checkCtor == TLConstructors.RPC_ERROR || checkCtor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMsg = checkD.readString()
                Hilog.info(0, "CjTelegram", "[RealContactService] searchRemotePeers RPC Error: ${errorCode} - ${errorMsg}")
                return ArrayList<ContactDisplayData>()
            }
        }

        let response = ContactsFoundResponse.deserialize(responseData)
        let contacts = ArrayList<ContactDisplayData>()
        let msgService = getRealMessageService()

        for (user in response.users) {
            if (user.isSelf || user.isEmpty) { continue }
            let contact = ContactDisplayData()
            contact.userId = user.id
            contact.accessHash = user.accessHash
            contact.firstName = user.firstName
            contact.lastName = user.lastName
            contact.username = user.username
            contact.phone = user.phone
            contact.isBot = user.isBot
            contact.isOnline = user.isOnline
            contact.wasOnline = user.wasOnline
            contact.statusType = user.statusType
            if (user.accessHash != 0) {
                msgService.cacheUserAccessHash(user.id, user.accessHash)
            }
            contacts.add(contact)
        }

        Hilog.info(0, "CjTelegram", "[RealContactService] searchRemotePeers: ${contacts.size} results")
        return contacts
    }

    /**
     * 创建群组
     */
    public func createGroup(title: String, members: ArrayList<(Int64, Int64)>): Bool {
        Hilog.info(0, "CjTelegram", "[RealContactService] createGroup: title='${title}', members=${members.size}")
        let client = getMTProtoClient()

        let req = MessagesCreateChat()
        req.title = title

        // messages.createChat#92ceddd4 users:Vector<InputUser> —— 必须用 InputUser(#f21158c6) 且带 access_hash。
        // 原来误用 InputPeerUser + 不设 access_hash，导致成员无法加入（群创建异常）。
        let users = ArrayList<TLObject>()
        for ((userId, accessHash) in members) {
            let inputUser = InputUser()
            inputUser.userId = userId
            inputUser.accessHash = accessHash
            users.add(inputUser)
        }
        req.users = users
        
        let responseData = client.sendRequest(req.toBytes())
        
        if (responseData.size == 0) {
            return false
        }
        
        // 检查 RPC 错误
        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkConstructor = checkD.readUInt32()
            if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMessage = checkD.readString()
                Hilog.info(0, "CjTelegram", "[RealContactService] createGroup RPC Error: ${errorCode} - ${errorMessage}")
                return false
            }
        }
        
        Hilog.info(0, "CjTelegram", "[RealContactService] createGroup: success")
        return true
    }

    // ==================== P2-157: 设备同步 / localId 映射 / importedByCount 类方法封装 ====================

    /**
     * P2-157 Gap 6: 设备联系人同步开关（包装包级 setDeviceContactsSyncEnabled）
     */
    public func setDeviceSyncEnabled(enabled: Bool): Unit {
        setDeviceContactsSyncEnabled(enabled)
    }

    public func getDeviceSyncEnabled(): Bool {
        return isDeviceContactsSyncEnabled()
    }

    /**
     * P2-157 Gap 7: 通过本地联系人 ID 查找 userId（包装包级 findPeerByLocalContactId）
     */
    public func findByLocalContactId(localId: String): Option<Int64> {
        return findPeerByLocalContactId(localId)
    }

    /**
     * P2-157 Gap 3: 获取设备联系人被导入次数
     * 直接访问包级 _deviceImportCountMap（避免与包级同名函数冲突）
     */
    public func getImportedByCountForPhones(phones: ArrayList<String>): HashMap<String, Int32> {
        let result = HashMap<String, Int32>()
        for (phone in phones) {
            if (_deviceImportCountMap.contains(phone)) {
                let count = _deviceImportCountMap[phone]
                if (count > 0) {
                    result[phone] = count
                }
            }
        }
        return result
    }

    // ==================== P2-157b: contacts.getTopPeers 真实 RPC ====================

    /**
     * P2-157b: contacts.getTopPeers — 获取常用联系人，带 rating 频率排序
     *
     * 对应 iOS TelegramEngine.Contacts.topPeers / EngineData.Item.Contacts.TopPeers。
     * 调用 contacts.getTopPeers#973478b6（correspondents flag=true）。
     * 响应含 categories:Vector<TopPeerCategoryPeers>，每条 category 下是 Vector<TopPeer>(peer+rating)。
     *
     * 缓存：使用模块级 _topPeersHash / _cachedTopPeers。
     *   服务端返回 not_modified → 直接返回 _cachedTopPeers。
     *   服务端返回 disabled → 返回空列表，不清 cache（下次重试可能重新启用）。
     *   成功解析 → 计算新 hash（peer ids XOR）、刷新缓存、按 rating 降序排序后返回。
     *
     * @param limit 最多请求条目数（默认 16，UI 一般只显示 8）
     * @return rating 降序排列的 ContactDisplayData 列表，rating 字段为真实服务端评分
     */
    public func getTopPeers(limit!: Int32 = 16): ArrayList<ContactDisplayData> {
        Hilog.info(0, "CjTelegram", "[RealContactService] getTopPeers limit=${limit} hash=${_topPeersHash}")
        let client = getMTProtoClient()

        let req = ContactsGetTopPeers()
        req.correspondents = true
        req.limit = limit
        req.hash = _topPeersHash

        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[RealContactService] getTopPeers: empty response, returning cache size=${_cachedTopPeers.size}")
            return _cachedTopPeers
        }

        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkCtor = checkD.readUInt32()
            if (checkCtor == TLConstructors.RPC_ERROR || checkCtor == 0x2144ca19) {
                let errorCode = checkD.readInt32()
                let errorMsg = checkD.readString()
                Hilog.info(0, "CjTelegram", "[RealContactService] getTopPeers RPC Error: ${errorCode} - ${errorMsg}")
                return _cachedTopPeers
            }
        }

        let response = ContactsTopPeersResponse.deserialize(responseData)

        if (response.notModified) {
            Hilog.info(0, "CjTelegram", "[RealContactService] getTopPeers: not_modified, cache size=${_cachedTopPeers.size}")
            return _cachedTopPeers
        }

        if (response.disabled) {
            Hilog.info(0, "CjTelegram", "[RealContactService] getTopPeers: disabled")
            return ArrayList<ContactDisplayData>()
        }

        // 构建 userId → UserResponse 映射，用于 peer → ContactDisplayData 转换
        let userMap = HashMap<Int64, UserResponse>()
        let msgService = getRealMessageService()
        let photoService = getUserPhotoService()
        let peerStore = getPeerStore()
        let peersToCache = ArrayList<UserResponse>()
        for (user in response.users) {
            userMap[user.id] = user
            photoService.cacheUser(user)
            peersToCache.add(user)
        }
        peerStore.cacheUserResponses(peersToCache)

        let result = ArrayList<ContactDisplayData>()
        var newHash: Int64 = 0

        for (entry in response.peers) {
            if (entry.peerType != "user") {
                continue
            }
            let uid = entry.peerId
            newHash = newHash ^ uid

            if (!userMap.contains(uid)) {
                continue
            }
            let user = userMap[uid]
            if (user.isSelf || user.isEmpty) {
                continue
            }

            let contact = ContactDisplayData()
            contact.userId = user.id
            contact.accessHash = user.accessHash
            contact.firstName = user.firstName
            contact.lastName = user.lastName
            contact.username = user.username
            contact.phone = user.phone
            contact.isBot = user.isBot
            contact.isOnline = user.isOnline
            contact.wasOnline = user.wasOnline
            contact.statusType = user.statusType
            contact.rating = entry.rating

            if (user.accessHash != 0) {
                msgService.cacheUserAccessHash(user.id, user.accessHash)
            }

            result.add(contact)
        }

        // rating 降序排序（选择排序，与既有 sortContacts 模式一致）
        let sorted = sortTopPeersByRating(result)

        _topPeersHash = newHash
        _cachedTopPeers = sorted

        Hilog.info(0, "CjTelegram", "[RealContactService] getTopPeers: ${sorted.size} peers, newHash=${newHash}")
        return sorted
    }
}

/**
 * P2-157b: Top peers 按 rating 降序排列（选择排序）
 * rating 值越大表示交互频率越高，排在越前面。
 */
func sortTopPeersByRating(peers: ArrayList<ContactDisplayData>): ArrayList<ContactDisplayData> {
    let arr = peers.toArray()
    let sorted = ArrayList<ContactDisplayData>()
    let used = Array<Bool>(arr.size, repeat: false)

    var i: Int64 = 0
    while (i < arr.size) {
        var bestIdx: Int64 = -1
        var j: Int64 = 0
        while (j < arr.size) {
            if (!used[j]) {
                if (bestIdx < 0) {
                    bestIdx = j
                } else {
                    if (arr[j].rating > arr[bestIdx].rating) {
                        bestIdx = j
                    }
                }
            }
            j = j + 1
        }
        if (bestIdx >= 0) {
            used[bestIdx] = true
            sorted.add(arr[bestIdx])
        }
        i = i + 1
    }
    return sorted
}

/**
 * 联系人列表显示项（分区头 或 联系人），实现 ToString 供 ForEach keying
 */
public class ContactListDisplayItem <: ToString {
    public var isSection: Bool = false
    public var sectionLetter: String = ""
    public var contact: Option<ContactDisplayData> = None

    public static func section(letter: String): ContactListDisplayItem {
        let item = ContactListDisplayItem()
        item.isSection = true
        item.sectionLetter = letter
        return item
    }

    public static func fromContact(c: ContactDisplayData): ContactListDisplayItem {
        let item = ContactListDisplayItem()
        item.isSection = false
        item.contact = Some(c)
        return item
    }

    public func toString(): String {
        if (this.isSection) {
            return "section_${this.sectionLetter}"
        }
        match (this.contact) {
            case Some(c) => return "contact_${c.userId}_${c.firstName}_${c.statusType}_${c.isOnline}_${c.wasOnline}_${c.uiSelected}_${c.uiPresenceText}"
            case None => return "empty"
        }
    }
}

/**
 * 将分组后的联系人展平为列表项（分区头 + 联系人交替）
 */
public func flattenContactSections(sections: ArrayList<ContactSection>): ArrayList<ContactListDisplayItem> {
    let result = ArrayList<ContactListDisplayItem>()
    for (sec in sections) {
        result.add(ContactListDisplayItem.section(sec.letter))
        for (c in sec.contacts) {
            result.add(ContactListDisplayItem.fromContact(c))
        }
    }
    return result
}

/**
 * ContactEntry：ContactDisplayData 的轻量包装，实现 ToString 接口
 * 
 * 为什么需要？（与 ChatEntry / MessageEntry 相同原因）
 * - ForEach 默认 keyGenerator（来自 arkui/custom_view.cj）：
 *     case realDataStr: ToString => idx.toString() + "_" + realDataStr.toString()
 *     case _ => idx.toString()    ← 不实现 ToString 时只用 index 作 key
 * - 只用 index 作 key → 排序/搜索后列表变化但 key 相同 → 组件复用不更新
 * 
 * ContactEntry 实现 ToString，toString() 包含 userId + 名字 + 状态，
 * 使 ForEach 在排序/搜索/状态变化时生成不同的 key → 销毁旧组件 → 创建新组件 → UI 正确更新
 */
public class ContactEntry <: ToString {
    public let contact: ContactDisplayData

    public init(contact: ContactDisplayData) {
        this.contact = contact
    }

    public func toString(): String {
        return "${this.contact.userId}_${this.contact.firstName}_${this.contact.lastName}_${this.contact.statusType}_${this.contact.isOnline}_${this.contact.wasOnline}_${this.contact.uiSelected}_${this.contact.uiPresenceText}"
    }
}
