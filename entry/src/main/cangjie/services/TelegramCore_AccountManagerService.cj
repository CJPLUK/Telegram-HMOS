package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.core.mtproto.resetGlobalClient
import std.collection.ArrayList

/**
 * 多账号条目 — 用于 SettingsPage 账号列表展示
 *
 * 对应 iOS AccountContext / Account record 的 UI 侧数据结构
 */
public class MultiAccountEntry {
    public var userId: Int64 = 0
    public var slot: Int32 = 0
    public var firstName: String = ""
    public var lastName: String = ""
    public var phone: String = ""
    public var isPremium: Bool = false
    public var avatarText: String = "?"
    public var avatarPath: String = ""
    public var isActive: Bool = false
}

/**
 * services 层账号管理器 — 多账号功能服务
 *
 * 对应 iOS TelegramUI AccountSwitcher / AccountContext 的 UI 驱动侧
 *
 * 职责：
 * 1. 从 AuthStorage 读取当前已登录账号，构建 MultiAccountEntry 列表
 * 2. 提供账号切换意图（当前实现：单账号模式下无实际切换；多账号接口预留）
 * 3. 提供账号注销接口（委托 RealAuthService.logout + resetGlobalClient）
 *
 * P2-318d 更新：
 *   getLoggedInAccounts() 现在枚举全部已登录 slot（listSlots() + slotHasAuth(n)），
 *   通过临时切换 activeSlot 读取各 slot 的用户数据，读取完毕立即恢复原 activeSlot。
 *   account picker 集成：P2-318e UI 直接调用 getLoggedInAccounts() 获得多账号列表。
 *
 * 循环依赖说明：
 *   此文件在 services 包内，不引用 core.services 以避免循环依赖：
 *   services -> core.services (已有) 与 core.services -> services (已有) 形成循环。
 *   因此直接使用 AuthStorage (core.storage) 和 RealAuthService (同包 services)。
 */
private var _serviceInstance: Option<TelegramCoreAccountManagerService> = None

public func getTelegramCoreAccountManagerService(): TelegramCoreAccountManagerService {
    match (_serviceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = TelegramCoreAccountManagerService()
            _serviceInstance = Some(inst)
            return inst
    }
}

public class TelegramCoreAccountManagerService {
    public init() {}

    /**
     * 获取所有已登录账号列表（P2-318d 多 slot 枚举版本）
     *
     * 实现：枚举 listSlots() 中所有 slot，用 slot-specific 读取 API
     * 获取用户数据，不更改 activeSlot。
     *
     * 回归安全：
     *   - 单账号用户：listSlots()=[0], slotHasAuth(0)=true, 返回含一个条目的列表
     *   - 全程不修改 activeSlot，可与 add-account pending slot 安全并存
     *
     * iOS 对应: AccountManager.accountRecords / sharedContext.activeAccounts
     */
    public func getLoggedInAccounts(): Array<MultiAccountEntry> {
        let storage = getAuthStorage()
        let originalSlot = storage.getActiveSlot()
        let activeSlot = originalSlot

        let slots = storage.listSlots()
        let result = ArrayList<MultiAccountEntry>()

        var i: Int64 = 0
        while (i < slots.size) {
            let slot = slots[i]
            if (storage.slotHasAuth(slot)) {
                match (storage.getUserDataForSlot(slot)) {
                    case Some(user) =>
                        let entry = MultiAccountEntry()
                        entry.userId = user.id
                        entry.slot = slot
                        entry.firstName = user.firstName
                        entry.lastName = user.lastName
                        entry.phone = user.phone
                        entry.isPremium = user.isPremium
                        entry.avatarText = buildAvatarText(user.firstName, user.lastName)
                        entry.avatarPath = getUserPhotoService().getUserPhotoPath(user.id)
                        entry.isActive = (slot == activeSlot)
                        result.add(entry)
                    case None => ()
                }
            }
            i = i + 1
        }

        Hilog.info(0, "CjTelegram", "[TelegramCoreAccountManagerService] getLoggedInAccounts: found ${result.size} accounts")
        return result.toArray()
    }

    /**
     * 获取当前活跃账号的 userId
     * 从 AuthStorage.getUserData() 读取
     */
    public func getActiveAccountUserId(): Int64 {
        let storage = getAuthStorage()
        match (storage.getUserData()) {
            case Some(user) => return user.id
            case None => return -1
        }
    }

    /**
     * P2-010: 切换到指定 userId 对应的账号
     *
     * 实现：通过 getLoggedInAccounts() 找到 userId 对应的 slot，
     * 然后执行 setActiveSlot + resetGlobalClient 完成切换。
     * 广播通过 entry 侧的 addAccountSwitchListenerWithId 触发（core service 已实现）。
     *
     * iOS 对应: AccountManager.switchToAccount(id:)
     */
    public func switchToAccount(userId: Int64): Bool {
        let accounts = this.getLoggedInAccounts()
        var targetSlot: Int32 = -1
        var i: Int64 = 0
        while (i < accounts.size) {
            if (accounts[i].userId == userId) {
                if (accounts[i].isActive) {
                    Hilog.info(0, "CjTelegram", "[TelegramCoreAccountManagerService] switchToAccount: already active userId=${userId}")
                    return true
                }
                targetSlot = accounts[i].slot
                break
            }
            i = i + 1
        }
        if (targetSlot < 0) {
            Hilog.info(0, "CjTelegram", "[TelegramCoreAccountManagerService] switchToAccount: userId=${userId} not found")
            return false
        }
        Hilog.info(0, "CjTelegram", "[TelegramCoreAccountManagerService] switchToAccount: userId=${userId} slot=${targetSlot}")
        getAuthStorage().setActiveSlot(targetSlot)
        resetGlobalClient()
        Hilog.info(0, "CjTelegram", "[TelegramCoreAccountManagerService] switchToAccount: done, new active slot=${targetSlot}")
        return true
    }

    /**
     * 检查是否可以添加新账号（最多 3 个）
     *
     * iOS 对应: AccountManager.canBeginNewAuth
     */
    public func canAddAccount(): Bool {
        let accounts = this.getLoggedInAccounts()
        let MAX_ACCOUNTS: Int64 = 3
        return accounts.size < MAX_ACCOUNTS
    }

    /**
     * 登出指定账号
     *
     * 当前实现：若 userId 与当前活跃账号一致，执行完整登出流程。
     * 多账号扩展：后续可仅清除对应 slot 而保留其他账号。
     *
     * iOS 对应: AccountManager.logoutAccount(id:)
     */
    public func logoutAccount(userId: Int64): Bool {
        let activeId = this.getActiveAccountUserId()
        if (activeId == userId) {
            Hilog.info(0, "CjTelegram", "[AccountManagerService] Logout account userId=${userId}")
            getRealAuthService().logout()
            resetGlobalClient()
            return true
        }
        Hilog.info(0, "CjTelegram", "[AccountManagerService] logoutAccount: userId=${userId} is not active account=${activeId}, skipped")
        return false
    }

    /**
     * 检查是否已登录（至少有一个活跃账号）
     */
    public func isLoggedIn(): Bool {
        let storage = getAuthStorage()
        return storage.hasStoredLogin()
    }
}

/**
 * 构建头像文字（首字母缩写）
 * 名字首字母 + 姓氏首字母（若有）
 */
public func buildAvatarText(firstName: String, lastName: String): String {
    if (firstName.size == 0) {
        return "?"
    }
    let firstRunes = firstName.toRuneArray()
    if (lastName.size > 0) {
        let lastRunes = lastName.toRuneArray()
        return "${firstRunes[0].toString()}${lastRunes[0].toString()}"
    }
    return firstRunes[0].toString()
}
