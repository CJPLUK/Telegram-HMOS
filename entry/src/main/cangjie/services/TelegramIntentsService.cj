package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList
import std.collection.HashMap

/**
 * TelegramIntentsService — Telegram 快捷意图服务
 *
 * iOS 原型: submodules/TelegramIntents/Sources/TelegramIntents.swift
 *
 * iOS 使用 INSendMessageIntent / INInteraction.donate() 向 Siri 捐赠联系人快捷方式。
 * HarmonyOS 映射方案：
 *   - 系统级快捷方式通过 module.json5 的 shortcuts_config.json 静态配置（不需要运行时 API）
 *   - 运行时"捐赠"在此服务中以内存注册表实现，记录哪些联系人已被标记为快捷意图
 *   - 后续可由集成 feature（如 app_shell）将注册表写入 Preferences 实现持久化
 *
 * 调用链：
 *   TelegramIntentsComponent → TelegramIntentsService → getRealContactService() → MTProtoClient.send()
 */

// ==================== 数据模型 ====================

/**
 * 意图主题类型，对应 iOS SendMessageIntentSubject
 */
public enum IntentSubject {
    | Contact
    | SavedMessages
    | PrivateChat
    | Group
}

/**
 * 联系人快捷意图条目
 * 对应 iOS INPerson + INSendMessageIntent 的数据载体
 */
public class IntentDonation {
    public var peerId: Int64 = 0
    public var accessHash: Int64 = 0
    public var displayName: String = ""
    public var subject: IntentSubject = IntentSubject.Contact
    public var groupIdentifier: String = ""    // "sendMessage_<peerId>"
    public var conversationId: String = ""     // "tg<peerId>"
    public var avatarInitials: String = ""

    public init() {}

    public init(peerId: Int64, accessHash: Int64, displayName: String,
                subject: IntentSubject, avatarInitials: String) {
        this.peerId = peerId
        this.accessHash = accessHash
        this.displayName = displayName
        this.subject = subject
        this.groupIdentifier = "sendMessage_${peerId}"
        this.conversationId = "tg${peerId}"
        this.avatarInitials = avatarInitials
    }

    public func subjectLabel(): String {
        match (this.subject) {
            case IntentSubject.Contact => "contact"
            case IntentSubject.SavedMessages => "savedMessages"
            case IntentSubject.PrivateChat => "privateChat"
            case IntentSubject.Group => "group"
        }
    }
}

// ==================== 单例 ====================

private var _telegramIntentsServiceInstance: Option<TelegramIntentsService> = None

public func getTelegramIntentsService(): TelegramIntentsService {
    match (_telegramIntentsServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = TelegramIntentsService()
            _telegramIntentsServiceInstance = Some(inst)
            return inst
    }
}

// ==================== 服务实现 ====================

public class TelegramIntentsService {
    // 内存注册表：peerId -> IntentDonation
    private var donations: HashMap<Int64, IntentDonation> = HashMap<Int64, IntentDonation>()

    /**
     * 向注册表捐赠联系人快捷意图
     * 对应 iOS INInteraction.donate()
     *
     * 从 RealContactService 获取联系人数据后，按 iOS 过滤规则（
     * 跳过 bot、跳过非联系人、归档聊天等）构建 IntentDonation。
     *
     * @param peerIds 要捐赠的 peer ID 列表
     * @return 成功捐赠的条目列表
     */
    public func donateSendMessageIntents(peerIds: ArrayList<Int64>): ArrayList<IntentDonation> {
        Hilog.info(0, "CjTelegram", "[TelegramIntentsService] donateSendMessageIntents: ${peerIds.size} peerIds")
        let contactService = getRealContactService()
        let allContacts = contactService.getContacts()
        Hilog.info(0, "CjTelegram", "[TelegramIntentsService] loaded ${allContacts.size} contacts for donation")

        // 建立快速查找表
        let contactMap = HashMap<Int64, ContactDisplayData>()
        for (c in allContacts) {
            contactMap[c.userId] = c
        }

        let result = ArrayList<IntentDonation>()
        for (peerId in peerIds) {
            match (contactMap.get(peerId)) {
                case Some(contact) =>
                    // 跳过 bot 和 self（savedMessages 在 iOS 里是 account.peerId，此处简化：只处理真实联系人）
                    if (contact.isBot) {
                        Hilog.info(0, "CjTelegram", "[TelegramIntentsService] skip bot peerId=${peerId}")
                        continue
                    }
                    let subject = if (contact.isSelf) {
                        IntentSubject.SavedMessages
                    } else {
                        IntentSubject.Contact
                    }
                    let donation = IntentDonation(
                        contact.userId,
                        contact.accessHash,
                        contact.getDisplayName(),
                        subject,
                        contact.getAvatarInitials()
                    )
                    this.donations[peerId] = donation
                    result.add(donation)
                    Hilog.info(0, "CjTelegram", "[TelegramIntentsService] donated intent")
                case None =>
                    Hilog.info(0, "CjTelegram", "[TelegramIntentsService] peerId not found in contacts, skip")
            }
        }
        Hilog.info(0, "CjTelegram", "[TelegramIntentsService] donated ${result.size} intents")
        return result
    }

    /**
     * 删除指定 peerId 的快捷意图
     * 对应 iOS deleteSendMessageIntents(peerId:)
     */
    public func deleteSendMessageIntent(peerId: Int64): Unit {
        Hilog.info(0, "CjTelegram", "[TelegramIntentsService] deleteSendMessageIntent peerId=${peerId}")
        let _ = this.donations.remove(peerId)
    }

    /**
     * 删除全部快捷意图
     * 对应 iOS deleteAllSendMessageIntents()
     */
    public func deleteAllSendMessageIntents(): Unit {
        Hilog.info(0, "CjTelegram", "[TelegramIntentsService] deleteAllSendMessageIntents: clearing ${this.donations.size} entries")
        this.donations.clear()
    }

    /**
     * 查询当前已注册的全部捐赠条目
     */
    public func getActiveDonations(): ArrayList<IntentDonation> {
        let result = ArrayList<IntentDonation>()
        for ((_, v) in this.donations) {
            result.add(v)
        }
        return result
    }

    /**
     * 查询指定 peerId 是否已捐赠
     */
    public func isDonated(peerId: Int64): Bool {
        return this.donations.contains(peerId)
    }

    /**
     * 从联系人列表批量推断并捐赠所有符合条件的联系人
     * 便捷方法：拉取全量联系人并捐赠（对应 iOS 不设上限的行为）
     */
    public func donateTopContacts(): ArrayList<IntentDonation> {
        Hilog.info(0, "CjTelegram", "[TelegramIntentsService] donateTopContacts")
        let contactService = getRealContactService()
        let contacts = contactService.getContacts()

        let peerIds = ArrayList<Int64>()
        for (c in contacts) {
            peerIds.add(c.userId)
        }
        return this.donateSendMessageIntents(peerIds)
    }
}
