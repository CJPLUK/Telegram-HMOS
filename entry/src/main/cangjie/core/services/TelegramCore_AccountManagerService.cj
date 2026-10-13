package ohos_app_cangjie_entry.core.services

import kit.PerformanceAnalysisKit.Hilog
import std.sync.ReentrantMutex
import std.collection.ArrayList
import std.collection.HashMap
import ohos_app_cangjie_entry.core.mtproto.{
    resetGlobalClient, getAccountClientForSlot, SessionManager, MTProtoClient,
    UsersGetUsers, InputUserSelf, TLDeserializer, UserResponse
}
import ohos_app_cangjie_entry.core.storage.{getAuthStorage, StoredUserData, StoredSessionData, AccountInfo}
import ohos_app_cangjie_entry.services.{
    getRealAuthService, getEntityKeyboardStore, getChatListProjection,
    getAccountUpdateCoordinator, getUpdatesManager,
    getTelegramCoreSettingsService, BADGE_TAG_CHANNEL, BADGE_TAG_GROUP,
    BADGE_TAG_BOT, BADGE_TAG_NON_CONTACT
}
/**
 * TelegramCore 账户管理器服务 — 账户生命周期与数据访问
 *
 * 对应 Telegram-iOS TelegramCore/Account/AccountManager + AccountIntermediateState
 * 管理账户状态查询、用户/会话数据访问、登出清理流程
 *
 * 账户中间状态机：unauthorized(0) → awaitingCode(1) → awaitingPassword(2) → authorized(3)
 * AuthStorage 持久化 authState；登录流程中仅 0 和 3 被持久化
 *
 * P2-318c 扩展：
 *   - switchAccount(slot): 切换活跃 slot + 连接新账号 client + 广播切换通知
 *   - addAccountSwitchListener / removeAccountSwitchListener: UI 层订阅切换事件
 *   - 单账号回归安全：未调用 switchAccount 时行为与改前完全一致
 *
 * P2-318d 扩展：
 *   - addAccount(): 分配新 slot + 临时切换 activeSlot 到新 slot，返回 (newSlot, originalSlot)
 *     登录流在新 slot 中执行（saveAuthData 写入 activeSlot=newSlot，不动原 slot 的 authKey）
 *   - completeAddAccount(newSlot, originalSlot): 登录成功后恢复 activeSlot=originalSlot
 *     新账号保留在 newSlot，可通过 switchAccount(newSlot) 切换；原账号 authKey 完全不变
 *   - cancelAddAccount(newSlot, originalSlot): 登录失败/取消时恢复 activeSlot=originalSlot
 *     并清除空的 newSlot（removeSlot），不留废 slot
 *   - removeAccountSwitchListener(listener): P2-318c 补充，防止重复注册导致重复回调
 *   - 回归安全保证：现有首次登录/重登流程完全不经过 addAccount，行为字节级不变
 *
 * 核心决策：
 * - 委托 AuthStorage 读写数据，不创建独立存储
 * - 委托 RealAuthService.logout 执行 auth.logOut TL + 存储清理
 * - 委托 core.mtproto.resetGlobalClient 断开网络，不直接操作 MTProtoClient
 * - 委托 getAccountClientForSlot 管理 per-account MTProtoClient 实例
 */
// 账户中间状态常量（与 AuthStorage.authState 对齐）
public let ACCOUNT_STATE_UNAUTHORIZED: Int32 = 0
public let ACCOUNT_STATE_AWAITING_CODE: Int32 = 1
public let ACCOUNT_STATE_AWAITING_PASSWORD: Int32 = 2
public let ACCOUNT_STATE_AUTHORIZED: Int32 = 3
private var _accountManagerServiceInstance: Option<TelegramCore_AccountManagerService> = None

public func getTelegramCore_AccountManagerService(): TelegramCore_AccountManagerService {
    match (_accountManagerServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = TelegramCore_AccountManagerService()
            _accountManagerServiceInstance = Some(inst)
            return inst
    }
}

// ==================== P2-318c/g: 账号切换监听器（per-listener ID 版本）====================
// 监听器 Map：ID -> 闭包；保护锁
// P2-318g 升级：addAccountSwitchListenerWithId 返回唯一 ID，removeAccountSwitchListener(id) 精准移除
// 保留 addAccountSwitchListener / removeAllAccountSwitchListeners 以兼容历史调用方
private var _accountSwitchListenerMap: HashMap<Int64, (Int32) -> Unit> = HashMap<Int64, (Int32) -> Unit>()
private var _nextListenerId: Int64 = 0
private let _accountSwitchListenersMutex = ReentrantMutex()

// ==================== P2-318d: 添加账号互斥锁 ====================
// 防止并发调用 addAccount 同时分配新 slot（每次只允许一个添加流在进行中）
private let _addAccountMutex = ReentrantMutex()
private var _addingAccount: Bool = false

/**
 * P2-318g: 注册账号切换监听器，返回唯一 listener ID。
 * 调用方应在 UI 销毁时用 removeAccountSwitchListener(id) 精准移除自己的监听器。
 * 多消费者场景下（ChatListPage + SettingsPage 同时注册）互不影响。
 * UI 层若需要更新 @State，必须在监听器内用 launch{} 切回主线程（对应 S-001）。
 *
 * @return Int64 listener 唯一 ID，传入 removeAccountSwitchListener 使用
 */
public func addAccountSwitchListenerWithId(listener: (Int32) -> Unit): Int64 {
    _accountSwitchListenersMutex.lock()
    let id = _nextListenerId
    _nextListenerId = _nextListenerId + 1
    _accountSwitchListenerMap[id] = listener
    let total = _accountSwitchListenerMap.size
    _accountSwitchListenersMutex.unlock()
    Hilog.info(0, "CjTelegram", "[AccountManagerService] AccountSwitchListener registered id=${id} (total=${total})")
    return id
}

/**
 * P2-318g: 精准移除指定 ID 的监听器。
 * 仅移除本调用方注册的那条，不影响其他消费者（如 ChatListPage 与 SettingsPage 独立移除）。
 *
 * @param id addAccountSwitchListenerWithId 返回的 listener ID
 */
public func removeAccountSwitchListener(id: Int64): Unit {
    _accountSwitchListenersMutex.lock()
    _accountSwitchListenerMap.remove(id)
    let total = _accountSwitchListenerMap.size
    _accountSwitchListenersMutex.unlock()
    Hilog.info(0, "CjTelegram", "[AccountManagerService] AccountSwitchListener removed id=${id} (remaining=${total})")
}

/**
 * P2-318c/g: 注册账号切换监听器（兼容接口，内部用 addAccountSwitchListenerWithId）。
 * 单消费者场景或不需要精准移除时可使用。
 * 多消费者场景请改用 addAccountSwitchListenerWithId + removeAccountSwitchListener(id)。
 */
public func addAccountSwitchListener(listener: (Int32) -> Unit): Unit {
    let _ = addAccountSwitchListenerWithId(listener)
}

/**
 * P2-318c/g: 清除所有账号切换监听器（兼容接口）。
 * 注意：此方法会清除所有消费者的监听器，多消费者场景下请改用 removeAccountSwitchListener(id)。
 */
public func removeAllAccountSwitchListeners(): Unit {
    _accountSwitchListenersMutex.lock()
    _accountSwitchListenerMap = HashMap<Int64, (Int32) -> Unit>()
    _nextListenerId = 0
    _accountSwitchListenersMutex.unlock()
    Hilog.info(0, "CjTelegram", "[AccountManagerService] All AccountSwitchListeners cleared")
}

/**
 * P2-318c/g: 广播账号切换完成事件（内部调用）。
 * 在 spawn{} 中执行；快照监听器列表后逐一调用，避免持锁调用监听器。
 * P2-318g: 从 ArrayList 升级为 HashMap snapshot（ArrayList<(Int32)->Unit>），仍逐一调用。
 */
private func _notifyAccountSwitched(newSlot: Int32): Unit {
    // 先切换账号级 Entity Keyboard 状态，再通知 UI。这样任何页面监听器在收到
    // account switched 时读取到的都是新 generation 的空/磁盘快照，不会闪回旧账号。
    getEntityKeyboardStore().accountDidSwitch(newSlot)
    _accountSwitchListenersMutex.lock()
    // 快照：把 HashMap values 提取为 ArrayList<(Int32)->Unit>
    let snapshot = ArrayList<(Int32) -> Unit>()
    for ((_, cb) in _accountSwitchListenerMap) {
        snapshot.add(cb)
    }
    let sz = snapshot.size
    _accountSwitchListenersMutex.unlock()
    var i: Int64 = 0
    while (i < sz) {
        try {
            snapshot[i](newSlot)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[AccountManagerService] AccountSwitchListener[${i}] threw: ${e}")
        }
        i = i + 1
    }
    Hilog.info(0, "CjTelegram", "[AccountManagerService] Notified ${sz} listener(s) of switch to slot=${newSlot}")
}

public class TelegramCore_AccountManagerService {
    // P2-318c: 切换重入防护
    private let _switchMutex = ReentrantMutex()
    private var _switching: Bool = false

    public init() {}

    /**
     * Resolve the owner of the currently installed authorization from Telegram.
     * Local user metadata is presentation data and cannot prove account identity:
     * multiple authorization keys may belong to the same Telegram account.
     */
    private func requestAuthorizationOwner(client: MTProtoClient): Option<UserResponse> {
        try {
            let request = UsersGetUsers()
            request.ids.add(InputUserSelf())
            let responseData = client.sendRequest(request.toBytes())
            if (responseData.size == 0) { return None }
            let d = TLDeserializer(responseData)
            if (d.readUInt32() != 0x1cb5c415) { return None }
            let count = d.readInt32()
            var index: Int32 = 0
            while (index < count) {
                let user = UserResponse.deserializeBoxed(d)
                if (user.isSelf || count == 1) { return Some(user) }
                index += 1
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram",
                "[AccountManagerService] authorization owner request failed: ${e}")
        }
        return None
    }

    /** Find an authorized local record for a server-authoritative user id. */
    private func findAuthorizedSlotForUser(userId: Int64, excludingSlot: Int32): Int32 {
        let storage = getAuthStorage()
        let slots = storage.listSlots()
        var index: Int64 = 0
        while (index < slots.size) {
            let candidate = slots[index]
            if (candidate != excludingSlot && storage.slotHasAuth(candidate)) {
                match (storage.getUserDataForSlot(candidate)) {
                    case Some(user) where user.id == userId => return candidate
                    case _ => ()
                }
            }
            index += 1
        }
        return -1
    }

    /** Recreate the sole live network context from one persisted account record. */
    private func restoreClientForSlot(slot: Int32): MTProtoClient {
        let storage = getAuthStorage()
        resetGlobalClient()
        SessionManager.clearAllSessions()
        storage.setActiveSlot(slot)
        var dcId: Int64 = -1
        match (storage.getSessionData()) {
            case Some(sessionData) =>
                dcId = sessionData.dcId
                let _ = SessionManager.restoreSession(dcId)
            case None => ()
        }
        let client = getAccountClientForSlot(slot)
        if (!client.isInitialized()) {
            if (dcId > 0) {
                client.initialize(specificDcId: dcId)
            } else {
                client.initialize()
            }
        }
        return client
    }

    /**
     * Validate the restored active record after its MTProto connection is ready.
     * This migrates historical installations before the user attempts a switch.
     */
    public func repairActiveAuthorizationOwner(): Bool {
        let storage = getAuthStorage()
        let activeSlot = storage.getActiveSlot()
        if (!storage.slotHasAuth(activeSlot)) { return false }
        let client = getAccountClientForSlot(activeSlot)
        match (this.requestAuthorizationOwner(client)) {
            case Some(serverUser) =>
                var storedUserId: Int64 = 0
                match (storage.getUserDataForSlot(activeSlot)) {
                    case Some(storedUser) => storedUserId = storedUser.id
                    case None => ()
                }
                if (storedUserId == serverUser.id) { return false }
                let ownerSlot = this.findAuthorizedSlotForUser(serverUser.id, activeSlot)
                if (ownerSlot >= 0) {
                    Hilog.info(0, "CjTelegram",
                        "[AccountManagerService] active slot=${activeSlot} claims user=${storedUserId} but authorization belongs to existing user=${serverUser.id}; removing contaminated slot")
                    storage.removeSlot(activeSlot)
                    let _ = this.restoreClientForSlot(ownerSlot)
                    getRealAuthService().bindActiveAccountClient()
                    getAccountUpdateCoordinator().accountDidSwitch()
                    _notifyAccountSwitched(ownerSlot)
                    return true
                }

                let repaired = StoredUserData()
                repaired.id = serverUser.id
                repaired.firstName = serverUser.firstName
                repaired.lastName = serverUser.lastName
                repaired.username = serverUser.username
                repaired.phone = serverUser.phone
                repaired.isPremium = serverUser.isPremium
                storage.saveUserData(repaired)
                _notifyAccountSwitched(activeSlot)
                Hilog.info(0, "CjTelegram",
                    "[AccountManagerService] repaired active slot=${activeSlot} identity from server user=${serverUser.id}")
                return true
            case None => return false
        }
    }

    /**
     * Derive the active account's rendered total unread from its committed chat
     * projection using the same mute, tag and count-category rules as BadgeAggregator.
     *
     * D-183 inline replica of services/BadgeAggregator.cj:apply — the filter body below
     * is kept verbatim with that implementation. `generation == 0` means no chat-list
     * projection has been committed for this account yet; apply skips the update
     * entirely in that case, so this returns None and callers must leave the value
     * already persisted for the slot untouched instead of storing a sentinel 0.
     */
    private func calculateRenderedTotalUnread(): Option<Int32> {
        let snapshot = getChatListProjection().currentSnapshot()
        if (snapshot.generation == 0) { return None }
        let settings = getTelegramCoreSettingsService()
        let includeTags = settings.getBadgeIncludeTags()
        let countMessages = settings.getBadgeCountMessages()
        var total: Int64 = 0
        for (chat in snapshot.chats) {
            if (chat.unreadCount <= 0) { continue }
            if (chat.isMuted) { continue }
            let tag: Int32 = if (chat.isChannel && !chat.isMegagroup) {
                BADGE_TAG_CHANNEL
            } else if (chat.isChannel || chat.isGroup) {
                BADGE_TAG_GROUP
            } else if (chat.isBot) {
                BADGE_TAG_BOT
            } else {
                BADGE_TAG_NON_CONTACT
            }
            if ((includeTags & tag) == 0) { continue }
            if (countMessages) {
                total += chat.unreadCount
            } else {
                total += 1
            }
        }
        let next = if (total > 9999) { Int32(9999) } else { Int32(total) }
        return Some(next)
    }

    /** Stable slot-specific read entry for account-list consumers. */
    public func getRenderedTotalUnreadForSlot(slot: Int32): Int32 {
        return getAuthStorage().getRenderedTotalUnreadForSlot(slot)
    }

    /** Return another authorized slot for the same Telegram user, or -1. */
    public func findOtherAuthorizedSlotForUser(userId: Int64, excludingSlot: Int32): Int32 {
        if (userId <= 0) { return -1 }
        let storage = getAuthStorage()
        let slots = storage.listSlots()
        var i: Int64 = 0
        while (i < slots.size) {
            let slot = slots[i]
            if (slot != excludingSlot && storage.slotHasAuth(slot)) {
                match (storage.getUserDataForSlot(slot)) {
                    case Some(user) => if (user.id == userId) { return slot }
                    case None => ()
                }
            }
            i = i + 1
        }
        return -1
    }

    /** Resolve the current authorized slot for a stable Telegram user identity. */
    public func findAuthorizedSlotForUser(userId: Int64): Int32 {
        if (userId <= 0) { return -1 }
        let storage = getAuthStorage()
        let slots = storage.listSlots()
        var i: Int64 = 0
        while (i < slots.size) {
            let slot = slots[i]
            if (storage.slotHasAuth(slot)) {
                match (storage.getUserDataForSlot(slot)) {
                    case Some(user) => if (user.id == userId) { return slot }
                    case None => ()
                }
            }
            i = i + 1
        }
        return -1
    }

    /**
     * Remove duplicate authorized records produced by older add-account builds.
     * The currently active slot always wins, so repair never changes the account
     * the user is viewing.
     */
    public func repairDuplicateAuthorizedSlots(): Unit {
        let storage = getAuthStorage()
        var activeSlot = storage.getActiveSlot()
        let slots = storage.listSlots()

        // An account context is identified by its MTProto authorization, not by
        // the locally stored display peer. Older add-account builds reused the
        // process-global SessionManager and could therefore save the original
        // account's auth key beside a newly returned user record. Such a slot is
        // not a second account: every RPC still executes as the key owner. Keep
        // the first record for an auth key and remove later contaminated records.
        let authKeyOwners = HashMap<String, Int32>()
        var authIndex: Int64 = 0
        while (authIndex < slots.size) {
            let slot = slots[authIndex]
            if (storage.slotHasAuth(slot)) {
                match (storage.getSessionDataForSlot(slot)) {
                    case Some(session) =>
                        if (session.authKeyId.size > 0 && authKeyOwners.contains(session.authKeyId)) {
                            let ownerSlot = authKeyOwners[session.authKeyId]
                            storage.removeSlot(slot)
                            if (activeSlot == slot) {
                                activeSlot = ownerSlot
                                storage.setActiveSlot(ownerSlot)
                            }
                            Hilog.info(0, "CjTelegram",
                                "[AccountManagerService] Removed reused-auth slot=${slot}; canonical slot=${ownerSlot}")
                        } else if (session.authKeyId.size > 0) {
                            authKeyOwners[session.authKeyId] = slot
                        }
                    case None => ()
                }
            }
            authIndex += 1
        }

        if (!storage.slotHasAuth(activeSlot)) { return }
        var activeUserId: Int64 = 0
        match (storage.getUserDataForSlot(activeSlot)) {
            case Some(user) => activeUserId = user.id
            case None => return
        }
        let seenUserIds = ArrayList<Int64>()
        if (activeUserId > 0) { seenUserIds.add(activeUserId) }
        var i: Int64 = 0
        while (i < slots.size) {
            let slot = slots[i]
            if (slot != activeSlot && storage.slotHasAuth(slot)) {
                match (storage.getUserDataForSlot(slot)) {
                    case Some(user) =>
                        var duplicate = false
                        for (seenId in seenUserIds) {
                            if (seenId == user.id && user.id > 0) { duplicate = true }
                        }
                        if (duplicate) {
                            storage.removeSlot(slot)
                            Hilog.info(0, "CjTelegram", "[AccountManagerService] Removed duplicate authorized slot=${slot} userId=${user.id}")
                        } else if (user.id > 0) {
                            seenUserIds.add(user.id)
                        }
                    case None => ()
                }
            }
            i = i + 1
        }
    }

    /**
     * 是否已登录
     * 委托 AuthStorage.hasStoredLogin
     */
    public func isLoggedIn(): Bool {
        let storage = getAuthStorage()
        return storage.hasStoredLogin()
    }

    /**
     * 获取当前 DC ID
     * 委托 AuthStorage.getSessionData
     */
    public func getCurrentDcId(): Int64 {
        let storage = getAuthStorage()
        match (storage.getSessionData()) {
            case Some(session) => return session.dcId
            case None => return -1
        }
    }

    /**
     * 获取当前用户数据
     * 委托 AuthStorage.getUserData
     */
    public func getCurrentUserData(): Option<StoredUserData> {
        let storage = getAuthStorage()
        return storage.getUserData()
    }

    /**
     * 获取当前会话数据
     * 委托 AuthStorage.getSessionData
     */
    public func getSessionData(): Option<StoredSessionData> {
        let storage = getAuthStorage()
        return storage.getSessionData()
    }

    /**
     * 获取账户中间状态
     * 委托 AuthStorage.getAuthState
     * 0=unauthorized, 1=awaitingCode, 2=awaitingPassword, 3=authorized
     */
    public func getAccountIntermediateState(): Int32 {
        let storage = getAuthStorage()
        return storage.getAuthState()
    }

    /**
     * 获取当前账户信息（userId, firstName, lastName, phone, username）
     * 委托 AuthStorage.getUserData，映射为 AccountInfo
     */
    public func getCurrentAccountInfo(): Option<AccountInfo> {
        match (this.getCurrentUserData()) {
            case Some(user) =>
                let info = AccountInfo()
                info.userId = user.id
                info.firstName = user.firstName
                info.lastName = user.lastName
                info.phone = user.phone
                info.username = user.username
                return Some(info)
            case None => return None
        }
    }

    /**
     * P2-010: 切换到指定 userId 对应的账号。
     *
     * 实现：枚举 listSlots()，临时切到每个 slot 读取 userId，找到匹配后
     * 调用 switchAccount(slot)（含 setActiveSlot + client 初始化 + _notifyAccountSwitched）。
     * 读取过程中临时切换 activeSlot 是安全的（只读，读完后恢复）。
     *
     * iOS 对应: AccountManager.switchToAccount(id:) → makeSharedAccountContext
     */
    public func switchToAccount(userId: Int64): Bool {
        let storage = getAuthStorage()

        // Guard: check if userId is already the active account
        match (storage.getUserData()) {
            case Some(user) =>
                if (user.id == userId) {
                    Hilog.info(0, "CjTelegram", "[AccountManagerService] switchToAccount: already active userId=${userId}")
                    return true
                }
            case None => ()
        }

        // Enumerate all slots to find the target userId
        let currentSlot = storage.getActiveSlot()
        let slots = storage.listSlots()
        var targetSlot: Int32 = -1
        var i: Int64 = 0
        while (i < slots.size) {
            let slot = slots[i]
            if (storage.slotHasAuth(slot) && slot != currentSlot) {
                storage.setActiveSlot(slot)
                match (storage.getUserData()) {
                    case Some(slotUser) =>
                        if (slotUser.id == userId) {
                            targetSlot = slot
                        }
                    case None => ()
                }
                if (targetSlot < 0) {
                    storage.setActiveSlot(currentSlot)
                }
            }
            if (targetSlot >= 0) { break }
            i = i + 1
        }

        if (targetSlot < 0) {
            storage.setActiveSlot(currentSlot)
            Hilog.info(0, "CjTelegram", "[AccountManagerService] switchToAccount: userId=${userId} not found in any slot")
            return false
        }

        // Enumeration above temporarily routed storage to targetSlot. Restore
        // the actual current record so switchAccount observes a real transition
        // and performs its client/session handoff instead of returning as a
        // same-slot no-op.
        storage.setActiveSlot(currentSlot)
        Hilog.info(0, "CjTelegram", "[AccountManagerService] switchToAccount: found userId=${userId} at slot=${targetSlot}, delegating to switchAccount")
        return this.switchAccount(targetSlot)
    }

    /**
     * P2-318c: 切换到指定 account slot。
     *
     * 完整流程（对应 iOS AccountContext 切换）：
     *   1. Guard: 目标 slot 无有效登录数据 → 拒绝切换（返回 false）
     *   2. Guard: 目标 slot 已经是当前活跃 slot → no-op（返回 true）
     *   3. Guard: 切换进行中（重入防护）→ 拒绝（返回 false）
     *   4. setActiveSlot(slot) — 持久化活跃 slot；后续 getAuthKey/getMTProtoClient 解析到新 slot
     *   5. spawn{ } 中：清理旧账号的内存会话，从目标 slot 恢复会话并按其 home DC 初始化
     *   6. 广播 _notifyAccountSwitched(slot)：UI 层通过 addAccountSwitchListener 订阅并刷新数据源
     *
     * 回归安全：
     *   - 单账号用户永远不调用本函数，行为完全不变
     *   - setActiveSlotProvider 注入后，getMTProtoClient() 解析到 activeSlot 对应的 client
     *   - slot 0 是默认 slot：单账号时 getActiveSlot()=0，与改前等价
     *
     * 线程安全：
     *   - _switchMutex 防重入（切换中再次调用立即返回 false）
     *   - setActiveSlot 内部已持 AuthStorage 保护
     *   - initialize() 在 spawn{} 内执行（RPC/连接操作不阻塞调用方）
     *
     * @param slot account slot 编号（来自 AuthStorage.listSlots()）
     * @return true 表示切换成功发起；false 表示拒绝切换
     */
    public func switchAccount(slot: Int32): Bool {
        return this.switchAccountImpl(slot, false)
    }

    /**
     * S7-16: same switch as switchAccount, but the client re-initialisation and the
     * account-switched broadcast run on the caller's (background) thread before returning,
     * so the caller can rebuild the root UI for the new account right after.
     */
    public func switchAccountNow(slot: Int32): Bool {
        return this.switchAccountImpl(slot, true)
    }

    private func switchAccountImpl(slot: Int32, synchronous: Bool): Bool {
        let storage = getAuthStorage()

        // Guard 1: 目标 slot 无有效登录数据 → 拒绝
        if (!storage.slotHasAuth(slot)) {
            Hilog.info(0, "CjTelegram", "[AccountManagerService] switchAccount: slot=${slot} has no auth data, rejected")
            return false
        }

        // Guard 2: 同 slot no-op
        let currentSlot = storage.getActiveSlot()
        if (currentSlot == slot) {
            Hilog.info(0, "CjTelegram", "[AccountManagerService] switchAccount: slot=${slot} is already active, no-op")
            return true
        }

        // Guard 3: 重入防护
        _switchMutex.lock()
        if (this._switching) {
            _switchMutex.unlock()
            Hilog.info(0, "CjTelegram", "[AccountManagerService] switchAccount: switch already in progress, rejected")
            return false
        }
        this._switching = true
        _switchMutex.unlock()

        Hilog.info(0, "CjTelegram", "[AccountManagerService] switchAccount: ${currentSlot} -> ${slot}")

        // The projection still belongs to currentSlot here. Persist its rendered total
        // before resetGlobalClient tears down the old account context. When no
        // projection has been committed yet there is no value to publish for this slot,
        // so the count saved on a previous departure stays on disk.
        match (this.calculateRenderedTotalUnread()) {
            case Some(renderedTotalUnread) =>
                storage.setRenderedTotalUnreadForSlot(currentSlot, renderedTotalUnread)
            case None =>
                Hilog.info(0, "CjTelegram", "[AccountManagerService] switchAccount: slot=${currentSlot} has no committed chat projection, keeping its persisted rendered total unread")
        }

        // 先在旧 slot 仍是写入目标时断开旧 client，再切换存储路由。
        // 如果先 setActiveSlot，旧 client 的接收线程可能在后台 spawn
        // 真正执行 reset 前把旧会话回写到新 slot。
        resetGlobalClient()
        SessionManager.clearAllSessions()

        // Step 4: 持久化活跃 slot（后续 getMTProtoClient() 通过 _activeSlotProvider 解析到新 slot）
        storage.setActiveSlot(slot)

        // Step 4.5: 账号级共享状态在广播之前同步归零 —— 会话列表投影清空并标记新 owner，
        // 更新状态机丢弃上一账号的 pts / 去重表并按新账号游标重载。此前投影一直保留旧账号
        // 行，新页面的 loadRealDialogs 会把它们当作首帧沿用；再切回时旧账号的本地缓存 /
        // 旧 VM 的迟到发布又把它们灌回投影（真机复现：切回后 initialDialogs=8 行随后被
        // dialogFilters/initialArchive 以 19 行覆盖）。
        getChatListProjection().resetForAccountSwitch(slot)
        getUpdatesManager().resetForAccountSwitch()

        // Step 5 & 6: 在后台 spawn 中确保新 slot 的 client 已初始化并广播通知
        // RPC/连接操作不阻塞 UI；广播也在后台完成（UI 监听器用 launch{} 切回主线程）
        let targetSlot = slot
        let svc = this
        if (synchronous) {
            svc.finishSwitch(targetSlot)
        } else {
            let _ = spawn { svc.finishSwitch(targetSlot) }
        }
        return true
    }

    private func finishSwitch(targetSlot: Int32): Unit {
        let storage = getAuthStorage()
        let svc = this
        try {
                Hilog.info(0, "CjTelegram", "[AccountManagerService] switchAccount: initializing client for slot=${targetSlot}")

                // SessionManager 的会话表以 DC 为 key，不能在账号切换后继续沿用
                // 上一账号的内存会话。切换时只保留一个活跃网络上下文：
                // 断开已注册 client，清空内存会话，再由已切换到 targetSlot 的
                // AuthStorage load callback 还原该账号的 auth key 与 home DC。
                var restoredDcId: Int64 = -1
                match (storage.getSessionData()) {
                    case Some(sessionData) =>
                        restoredDcId = sessionData.dcId
                        let _ = SessionManager.restoreSession(restoredDcId)
                        Hilog.info(0, "CjTelegram", "[AccountManagerService] switchAccount: restored slot=${targetSlot} session for DC${restoredDcId}")
                    case None => ()
                }

                let client = getAccountClientForSlot(targetSlot)
                if (!client.hasAuthKey()) {
                    // 存储层已通过 slotHasAuth 门禁，如果此处仍无 key，
                    // initialize 会在目标账号的分区内重建网络会话。
                    if (restoredDcId > 0) {
                        client.initialize(specificDcId: restoredDcId)
                    } else {
                        client.initialize()
                    }
                    Hilog.info(0, "CjTelegram", "[AccountManagerService] switchAccount: client for slot=${targetSlot} initialized")
                } else {
                    // restoreSession 已安装目标账号的 auth key，仍需初始化 transport。
                    if (!client.isInitialized()) {
                        client.initialize(specificDcId: restoredDcId)
                    }
                    Hilog.info(0, "CjTelegram", "[AccountManagerService] switchAccount: client for slot=${targetSlot} already has auth key, no re-init needed")
                }
                // The server-side authorization owner is the identity boundary.
                // If an older build attached another local user record to this
                // authorization, never expose it as a switchable second account.
                var effectiveSlot = targetSlot
                match (svc.requestAuthorizationOwner(client)) {
                    case Some(serverUser) =>
                        var storedUserId: Int64 = 0
                        match (storage.getUserDataForSlot(targetSlot)) {
                            case Some(storedUser) => storedUserId = storedUser.id
                            case None => ()
                        }
                        if (storedUserId != serverUser.id) {
                            let ownerSlot = svc.findAuthorizedSlotForUser(serverUser.id, targetSlot)
                            if (ownerSlot >= 0) {
                                Hilog.info(0, "CjTelegram",
                                    "[AccountManagerService] slot=${targetSlot} claims user=${storedUserId} but authorization belongs to existing user=${serverUser.id}; removing contaminated slot")
                                storage.removeSlot(targetSlot)
                                effectiveSlot = ownerSlot
                                let _ = svc.restoreClientForSlot(ownerSlot)
                            } else {
                                // No duplicate local record exists. Repair the small
                                // identity record from the authoritative self peer.
                                let repaired = StoredUserData()
                                repaired.id = serverUser.id
                                repaired.firstName = serverUser.firstName
                                repaired.lastName = serverUser.lastName
                                repaired.username = serverUser.username
                                repaired.phone = serverUser.phone
                                repaired.isPremium = serverUser.isPremium
                                storage.saveUserData(repaired)
                                Hilog.info(0, "CjTelegram",
                                    "[AccountManagerService] repaired slot=${targetSlot} identity from server user=${serverUser.id}")
                            }
                        }
                    case None =>
                        Hilog.info(0, "CjTelegram",
                            "[AccountManagerService] switchAccount: owner validation unavailable for slot=${targetSlot}")
                }
                getRealAuthService().bindActiveAccountClient()
                getAccountUpdateCoordinator().accountDidSwitch()
                // Step 6: 广播账号切换完成
                _notifyAccountSwitched(effectiveSlot)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[AccountManagerService] switchAccount: exception during client init for slot=${targetSlot}: ${e}")
                // 即使初始化失败也广播通知（UI 可重试）
                _notifyAccountSwitched(storage.getActiveSlot())
            }
            // 清除重入标志（在 spawn 末尾，确保 initialize() 完成后才允许再次切换）
        svc.clearSwitching()
    }

    /**
     * P2-318c: 清除切换进行中标志（由 spawn 完成时调用）
     */
    public func clearSwitching(): Unit {
        _switchMutex.lock()
        this._switching = false
        _switchMutex.unlock()
    }

    // ==================== P2-318d: 添加账号流程 ====================

    /**
     * P2-318d: 开始添加账号流程。
     *
     * 实现方案（方案A：临时切换 activeSlot + 严格失败恢复）：
     *   1. 互斥检查：防止并发启动两个添加流
     *   2. 检查 slot 上限（最多 3 个已登录账号）
     *   3. 保存 originalSlot = storage.getActiveSlot()
     *   4. 分配新 slot: newSlot = storage.createSlot()
     *   5. 临时切换 activeSlot → newSlot
     *      — 后续 RealAuthService.sendCode/verifyCode/saveAuthData 写入 activeSlot=newSlot
     *      — originalSlot 的 authKey/session 完全不受影响
     *   6. 返回 AddAccountContext(newSlot, originalSlot) 供 UI 层引用
     *
     * 方案A 选择理由（vs 方案B 参数化）：
     *   - 方案B 需要在 RealAuthService/AuthStorage 整条链路加 targetSlot 参数，改动面极大
     *   - 方案A 只需改 AccountManagerService + 严格保证失败/取消恢复路径
     *   - AuthStorage 的所有写入方法均通过 sk() → _activeSlot 路由，临时切换安全
     *
     * 回归安全：
     *   - 现有首次登录/重登流程完全不调用 addAccount，不经过此路径
     *   - 单账号用户 activeSlot 始终 0，getActiveSlot()=0 → 登录写 slot_0，行为不变
     *
     * @return Some((newSlot, originalSlot)) 表示成功开始；None 表示拒绝（已有添加进行中/达到上限）
     */
    public func addAccount(): Option<(Int32, Int32)> {
        let storage = getAuthStorage()

        this.repairDuplicateAuthorizedSlots()

        // 互斥检查：防止并发添加流
        _addAccountMutex.lock()
        if (_addingAccount) {
            _addAccountMutex.unlock()
            Hilog.info(0, "CjTelegram", "[AccountManagerService] addAccount: already in progress, rejected")
            return None
        }
        _addingAccount = true
        _addAccountMutex.unlock()

        // Telegram iOS: 3 accounts normally, 4 when any active account is Premium.
        let existingSlots = storage.listSlots()
        var loggedInCount: Int64 = 0
        var hasPremiumAccount = false
        var i: Int64 = 0
        while (i < existingSlots.size) {
            if (storage.slotHasAuth(existingSlots[i])) {
                loggedInCount = loggedInCount + 1
                match (storage.getUserDataForSlot(existingSlots[i])) {
                    case Some(user) => if (user.isPremium) { hasPremiumAccount = true }
                    case None => ()
                }
            }
            i = i + 1
        }
        let maximumAccounts: Int64 = if (hasPremiumAccount) { 4 } else { 3 }
        if (loggedInCount >= maximumAccounts) {
            _addAccountMutex.lock()
            _addingAccount = false
            _addAccountMutex.unlock()
            Hilog.info(0, "CjTelegram", "[AccountManagerService] addAccount: account limit (${maximumAccounts}) reached, rejected")
            return None
        }

        // 保存原始 slot，分配新 slot，临时切换
        // TC-0086 fix: 用 beginAuthSlot 代替 setActiveSlot——只写 pending 指针 + 内存路由，
        // 不再把"当前已授权账号"的磁盘指针（active_slot）挪到这个尚未授权的新 slot。
        // 这样任何一次被强杀/放弃的添加账号流程都不会让 originalSlot 的账号在下次冷启动
        // 时失踪：AuthStorage.initialize() 重新读到的仍是 originalSlot。
        let originalSlot = storage.getActiveSlot()
        let newSlot = storage.createSlot()

        // SessionManager is process-global. A new account must start without any
        // session from the currently authorized account; otherwise a migration
        // to the same home DC can reuse the old Registered auth key and attach the
        // new local user record to the old server account.
        resetGlobalClient()
        SessionManager.clearAllSessions()
        storage.beginAuthSlot(newSlot)

        Hilog.info(0, "CjTelegram", "[AccountManagerService] addAccount: originalSlot=${originalSlot}, newSlot=${newSlot}. pendingAuthSlot now=${newSlot} (active_slot on disk unchanged=${originalSlot}). Login flow will write to newSlot.")
        return Some((newSlot, originalSlot))
    }

    /**
     * P2-318d: 添加账号成功后的收尾动作。
     *
     * 登录流（PhoneInput → sendCode → verifyCode → saveAuthData）已将认证数据写入 newSlot。
     * 调用本方法恢复 activeSlot → originalSlot，使原账号重新成为活跃账号。
     * 新账号留在 newSlot，用户可通过 switchAccount(newSlot) 随时切换。
     *
     * 调用时机：PhoneInputPage/CodeInputPage 收到 isLoggedIn=true（addAccount 路径下）后调用。
     *
     * @param newSlot    addAccount() 返回的新 slot 编号
     * @param originalSlot  addAccount() 返回的原始 slot 编号
     */
    public func completeAddAccount(newSlot: Int32, originalSlot: Int32): Unit {
        let storage = getAuthStorage()

        // Tear down the pending auth context while writes are still routed to
        // newSlot, then restore the original record from its own persisted key.
        resetGlobalClient()
        SessionManager.clearAllSessions()

        // TC-0086 fix: 先清 pending 指针，再落 active——顺序固定，避免中间态窗口。
        storage.endAuthSlot()

        // 恢复 activeSlot → originalSlot（原账号重新激活）
        storage.setActiveSlot(originalSlot)

        // 清除添加进行中标志
        _addAccountMutex.lock()
        _addingAccount = false
        _addAccountMutex.unlock()

        Hilog.info(0, "CjTelegram", "[AccountManagerService] completeAddAccount: newSlot=${newSlot} logged in. Restored activeSlot=${originalSlot}. Original session intact.")

        // S7-16: iOS makes the newly authorized account the current one
        // (TelegramCore Authorization.swift: transaction.setCurrentId(account.id)). Go through
        // the regular account switch (client reset + session restore + broadcast) from the
        // consistent original-slot state; it runs synchronously because every caller is on a
        // background thread and rebuilds the root UI right after this returns.
        if (!this.switchAccountNow(newSlot)) {
            Hilog.info(0, "CjTelegram", "[AccountManagerService] completeAddAccount: switch to newSlot=${newSlot} failed, staying on ${originalSlot}")
            spawn {
                _notifyAccountSwitched(originalSlot)
            }
        }
    }

    /**
     * P2-318d: 添加账号失败/用户取消时的回滚动作。
     *
     * 恢复 activeSlot → originalSlot，并清除在 newSlot 写入的任何不完整数据。
     * 保证原账号的 authKey/session 完全不受影响。
     *
     * 调用时机：
     *   - 用户点击返回取消添加账号流程
     *   - sendCode/verifyCode 失败且用户放弃
     *   - 应用在 addAccount 流程中异常退出（需在 onDestroy/onBackground 中保护性调用）
     *
     * @param newSlot    addAccount() 返回的新 slot 编号（将被清除）
     * @param originalSlot  addAccount() 返回的原始 slot 编号（将被恢复为 activeSlot）
     */
    public func cancelAddAccount(newSlot: Int32, originalSlot: Int32): Unit {
        let storage = getAuthStorage()

        resetGlobalClient()
        SessionManager.clearAllSessions()

        // TC-0086 fix: 先清 pending 指针，再落 active——顺序固定，避免中间态窗口。
        storage.endAuthSlot()

        // 恢复 activeSlot → originalSlot
        storage.setActiveSlot(originalSlot)

        // 清除新分配的空 slot（包括任何中途写入的不完整数据）
        // removeSlot 不影响 activeSlot，不影响其他 slot
        storage.removeSlot(newSlot)

        // 清除添加进行中标志
        _addAccountMutex.lock()
        _addingAccount = false
        _addAccountMutex.unlock()

        Hilog.info(0, "CjTelegram", "[AccountManagerService] cancelAddAccount: newSlot=${newSlot} cleared. Restored activeSlot=${originalSlot}. Original session intact.")

        spawn {
            match (storage.getSessionData()) {
                case Some(sessionData) =>
                    let _ = SessionManager.restoreSession(sessionData.dcId)
                    let client = getAccountClientForSlot(originalSlot)
                    client.initialize(specificDcId: sessionData.dcId)
                case None => ()
            }
            getRealAuthService().bindActiveAccountClient()
            getAccountUpdateCoordinator().accountDidSwitch()
        }
    }

    /**
     * P2-318d: 查询当前是否正在进行添加账号流程。
     * UI 层可据此防止重复触发 addAccount。
     */
    public func isAddingAccount(): Bool {
        _addAccountMutex.lock()
        let v = _addingAccount
        _addAccountMutex.unlock()
        return v
    }

    /**
     * 登出：执行完整清理流程
     * 1. 委托 RealAuthService.logout（auth.logOut TL + 存储清理 + SessionManager 清理）
     * 2. 委托 resetGlobalClient 断开网络
     */
    public func logout(): Unit {
        Hilog.info(0, "CjTelegram", "[AccountManagerService] Logout: delegating to RealAuthService + resetGlobalClient")
        getRealAuthService().logout()
        resetGlobalClient()
    }

    /**
     * 登出当前账号，并在仍有其他已登录 slot 时恢复其中一个账号。
     *
     * 返回值：
     *   >= 0  已切换并恢复到该 slot
     *   -1    已无其他登录账号
     *
     * RealAuthService.logout() 只清除当前 activeSlot；这里在清除后重新枚举
     * slot_list，选择第一个仍有完整授权数据的 slot，并把 RealAuthService 的
     * 内存用户态同步恢复。这样 Edit Profile 页的 Log Out 不会把多账号用户
     * 错误送回首次登录页。
     */
    public func logoutCurrentAccountAndSelectNext(): Int32 {
        let storage = getAuthStorage()
        let loggedOutSlot = storage.getActiveSlot()
        let authService = getRealAuthService()

        Hilog.info(0, "CjTelegram", "[AccountManagerService] logoutCurrentAccountAndSelectNext: slot=${loggedOutSlot}")
        authService.logout()
        resetGlobalClient()

        let remainingSlots = storage.listSlots()
        var nextSlot: Int32 = -1
        var i: Int64 = 0
        while (i < remainingSlots.size) {
            let slot = remainingSlots[i]
            if (storage.slotHasAuth(slot)) {
                nextSlot = slot
                break
            }
            i = i + 1
        }

        if (nextSlot < 0) {
            Hilog.info(0, "CjTelegram", "[AccountManagerService] logoutCurrentAccountAndSelectNext: no accounts remain")
            return -1
        }

        storage.setActiveSlot(nextSlot)
        if (!authService.tryRestoreLogin()) {
            Hilog.info(0, "CjTelegram", "[AccountManagerService] logoutCurrentAccountAndSelectNext: restore failed for slot=${nextSlot}")
            return -1
        }

        // 本地登录态已经恢复即可放行 UI；网络初始化失败时保留磁盘登录态，
        // 后续正常请求仍可沿既有重连机制恢复连接。
        try {
            authService.initializeClient()
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[AccountManagerService] logoutCurrentAccountAndSelectNext: client init deferred for slot=${nextSlot}: ${e}")
        }

        _notifyAccountSwitched(nextSlot)
        Hilog.info(0, "CjTelegram", "[AccountManagerService] logoutCurrentAccountAndSelectNext: restored slot=${nextSlot}")
        return nextSlot
    }
}
