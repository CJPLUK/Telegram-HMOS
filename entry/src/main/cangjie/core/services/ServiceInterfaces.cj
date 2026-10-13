package ohos_app_cangjie_entry.core.services

import std.collection.ArrayList

/**
 * 服务接口定义（Phase G2）
 * 
 * 参照 TelegramHarmony 的 IAuthService、IChatListService 等接口
 * 
 * 定义抽象接口，使 Real 和 Mock 实现可互换
 * 注意: Cangjie 的 @Observed 限制使得不能直接用 interface 做 ViewModel
 *       但服务层可以用 interface 抽象
 */

/**
 * 认证服务接口
 */
public interface IAuthService {
    func sendCode(phoneNumber: String): Bool
    func verifyCode(code: String): Bool
    func logout(): Unit
    func isAuthenticated(): Bool
}

/**
 * 聊天列表服务接口
 */
public interface IChatListService {
    func getDialogs(limit: Int32): ArrayList<ChatDisplayData>
    func deleteDialog(peerType: String, peerId: Int64): Bool
    func togglePinDialog(peerType: String, peerId: Int64, pinned: Bool): Bool
    func toggleMuteDialog(peerType: String, peerId: Int64, muted: Bool): Bool
    func markDialogAsRead(peerType: String, peerId: Int64): Bool
}

/**
 * 消息服务接口
 */
public interface IMessageService {
    func getHistory(peerType: String, peerId: Int64, limit: Int32, offsetId: Int32): ArrayList<MessageDisplayData>
    func sendMessage(peerType: String, peerId: Int64, message: String): Bool
    func deleteMessages(peerType: String, peerId: Int64, messageIds: ArrayList<Int32>, revoke: Bool): Bool
    func editMessage(peerType: String, peerId: Int64, messageId: Int32, newText: String): Bool
}

/**
 * 联系人服务接口
 */
public interface IContactService {
    func getContacts(): ArrayList<ContactData>
    func searchContacts(query: String, limit: Int32): ArrayList<ContactData>
}

// ==================== 展示数据类型 ====================

/**
 * 聊天列表展示数据（轻量级）
 */
public class ChatDisplayData {
    public var id: Int64 = 0
    public var name: String = ""
    public var lastMessage: String = ""
    public var time: String = ""
    public var unreadCount: Int64 = 0
    public var peerType: String = "user"
    public var isPinned: Bool = false
    public var isMuted: Bool = false
}

/**
 * 消息展示数据（轻量级）
 */
public class MessageDisplayData {
    public var id: Int64 = 0
    public var content: String = ""
    public var senderName: String = ""
    public var time: String = ""
    public var isOutgoing: Bool = false
    public var messageType: String = "text"
}

/**
 * 联系人展示数据
 */
public class ContactData {
    public var id: Int64 = 0
    public var firstName: String = ""
    public var lastName: String = ""
    public var username: String = ""
    public var phone: String = ""
}
