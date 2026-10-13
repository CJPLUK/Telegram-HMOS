package ohos_app_cangjie_entry.models

/**
 * 账号内稳定的会话标识。
 *
 * Telegram 的 user、基础群和 channel 可以拥有相同的数值 id，任何只用 Int64 id
 * 的缓存、可见性或列表 identity 都可能串会话。PeerKey 在协议入口统一 namespace，
 * UI 层需要旧 peerType 字符串时再由 toPeerType() 转回。
 */
public class PeerKey <: ToString {
    public static let USER: String = "user"
    public static let BASIC_GROUP: String = "basicGroup"
    public static let CHANNEL: String = "channel"
    public static let SECRET_CHAT: String = "secretChat"

    public let namespace: String
    public let id: Int64

    public init(namespace: String, id: Int64) {
        this.namespace = PeerKey.normalizeNamespace(namespace)
        this.id = id
    }

    public static func fromPeerType(peerType: String, id: Int64): PeerKey {
        return PeerKey(peerType, id)
    }

    public static func normalizeNamespace(value: String): String {
        if (value == "group" || value == "chat" || value == PeerKey.BASIC_GROUP) {
            return PeerKey.BASIC_GROUP
        }
        if (value == "supergroup" || value == PeerKey.CHANNEL) {
            return PeerKey.CHANNEL
        }
        if (value == "secret" || value == PeerKey.SECRET_CHAT) {
            return PeerKey.SECRET_CHAT
        }
        // 未识别命名空间保持原值，避免把未来协议类型误归到 user。
        return value
    }

    public func toPeerType(): String {
        if (this.namespace == PeerKey.BASIC_GROUP) { return "chat" }
        return this.namespace
    }

    public func equals(other: PeerKey): Bool {
        return this.id == other.id && this.namespace == other.namespace
    }

    /**
     * 供仍以 Int64 为物理主键的 Postbox 表使用的命名空间编码。
     * user 保持旧正数键兼容已有缓存；其它 peer 类型使用互不重叠的负数区间。
     */
    public func storageId(): Int64 {
        if (this.namespace == PeerKey.BASIC_GROUP) { return -this.id }
        if (this.namespace == PeerKey.CHANNEL) { return -(2000000000000000000 + this.id) }
        if (this.namespace == PeerKey.SECRET_CHAT) { return -(4000000000000000000 + this.id) }
        return this.id
    }

    public func toString(): String {
        return "${this.namespace}:${this.id}"
    }
}
