package ohos_app_cangjie_entry.models.api

import kit.ArkUI.*

/**
 * API 模型定义
 * 
 * 这些模型用于 API 响应的数据结构
 * 对应 iOS TelegramCore/Sources/TelegramEngine/ 中的各种数据类型
 */

/**
 * Telegram 用户信息
 * 对应 Bot API 中的 User 对象
 */
public class TelegramUser {
    public var id: Int64 = 0
    public var isBot: Bool = false
    public var firstName: String = ""
    public var lastName: String = ""
    public var username: String = ""
    public var languageCode: String = ""
    public var isPremium: Bool = false
}

/**
 * Telegram 聊天信息
 * 对应 Bot API 中的 Chat 对象
 */
public class TelegramChat {
    public var id: Int64 = 0
    public var chatType: String = "private"
    public var title: String = ""
    public var username: String = ""
    public var firstName: String = ""
    public var lastName: String = ""
}

/**
 * Telegram 消息信息
 * 对应 Bot API 中的 Message 对象
 */
public class TelegramMessage {
    public var messageId: Int64 = 0
    public var date: Int64 = 0
    public var chat: Option<TelegramChat> = None<TelegramChat>
    public var from: Option<TelegramUser> = None<TelegramUser>
    public var text: String = ""
    public var replyToMessageId: Int64 = 0
}

/**
 * Telegram 更新信息
 * 对应 Bot API 中的 Update 对象
 */
public class TelegramUpdate {
    public var updateId: Int64 = 0
    public var message: Option<TelegramMessage> = None<TelegramMessage>
    public var editedMessage: Option<TelegramMessage> = None<TelegramMessage>
}

/**
 * 网络请求状态
 */
public enum NetworkState {
    | IDLE        // 空闲
    | LOADING     // 加载中
    | SUCCESS     // 成功
    | ERROR       // 错误
    
    public func isLoading(): Bool {
        match (this) {
            case LOADING => true
            case _ => false
        }
    }
    
    public func isError(): Bool {
        match (this) {
            case ERROR => true
            case _ => false
        }
    }
}

/**
 * 分页请求参数
 */
public class PaginationParams {
    public var offset: Int64 = 0
    public var limit: Int64 = 20
    
    public func nextPage(): PaginationParams {
        let next = PaginationParams()
        next.offset = this.offset + this.limit
        next.limit = this.limit
        return next
    }
}

/**
 * 分页响应
 */
public class PaginatedResult<T> {
    public var items: Array<T> = Array<T>()
    public var hasMore: Bool = false
    public var nextOffset: Int64 = 0
}
