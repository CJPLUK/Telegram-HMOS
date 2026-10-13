package ohos_app_cangjie_entry.models

/**
 * Widget 数据模型 — P2-431
 *
 * 对应 iOS WidgetItems/Sources/WidgetItems.swift 的 WidgetDataPeer 及其嵌套类型。
 *
 * 14 种消息内容类型（真判别 enum，各带结构字段，operator== 手动实现）：
 *   text / image / video / file / gif / music / voiceMessage / videoMessage /
 *   sticker / call / mapLocation / game / poll / autodeleteTimer
 *
 * 新增字段（相比 D-版 WidgetPeerItem）：
 *   - WidgetMessageAuthor (isMe + title) — 群消息发送者
 *   - letters[] — 多字母头像
 *   - isForum — 论坛标记
 *   - WidgetData.unlockedForLockId — 锁屏态
 *   - WidgetData.accountId — 多账号
 *
 * serializeToJson / deserializeFromJson 为 P2-436 落盘设计（结构化 JSON 字符串）。
 *
 * [widget-host:P2-435] 接线点：
 *   FormExtensionAbility / form_config.json / formBindingData 卡片宿主由 P2-435 实现。
 *   本文件只提供数据模型，serializeToJson() 输出可直接被 P2-436 写入共享存储。
 *
 * 注意事项（仓颉陷阱）：
 *   R-112: enum 不自动派生 ==，需手动 operator func
 *   S-002: package 名与目录路径对应
 */

// ============================================================
// WidgetMessageAuthor — 群消息发送者 (iOS: WidgetDataPeer.Message.Author)
// ============================================================

public class WidgetMessageAuthor {
    public var isMe: Bool = false
    public var title: String = ""

    public init() {}

    public init(isMe!: Bool, title!: String) {
        this.isMe = isMe
        this.title = title
    }

    public func serializeToJson(): String {
        let titleEsc = this.title.replace("\\", "\\\\").replace("\"", "\\\"")
        return "{\"isMe\":${this.isMe},\"title\":\"${titleEsc}\"}"
    }
}

// ============================================================
// WidgetMessageContent — 14 种内容类型判别 enum
// (iOS: WidgetDataPeer.Message.Content)
// ============================================================

// ---- 各 case 携带的结构体 ----

public class WidgetContentImage {
    public init() {}
}

public class WidgetContentVideo {
    public init() {}
}

public class WidgetContentFile {
    public var name: String = ""
    public init() {}
    public init(name!: String) { this.name = name }
}

public class WidgetContentGif {
    public init() {}
}

public class WidgetContentMusic {
    public var artist: String = ""
    public var title: String = ""
    public var duration: Int32 = 0
    public init() {}
    public init(artist!: String, title!: String, duration!: Int32) {
        this.artist = artist
        this.title = title
        this.duration = duration
    }
}

public class WidgetContentVoiceMessage {
    public var duration: Int32 = 0
    public init() {}
    public init(duration!: Int32) { this.duration = duration }
}

public class WidgetContentVideoMessage {
    public var duration: Int32 = 0
    public init() {}
    public init(duration!: Int32) { this.duration = duration }
}

public class WidgetContentSticker {
    public var altText: String = ""
    public init() {}
    public init(altText!: String) { this.altText = altText }
}

public class WidgetContentCall {
    public var isVideo: Bool = false
    public init() {}
    public init(isVideo!: Bool) { this.isVideo = isVideo }
}

public class WidgetContentMapLocation {
    public init() {}
}

public class WidgetContentGame {
    public var title: String = ""
    public init() {}
    public init(title!: String) { this.title = title }
}

public class WidgetContentPoll {
    public var title: String = ""
    public init() {}
    public init(title!: String) { this.title = title }
}

public class WidgetContentAutodeleteTimer {
    public var value: Int32 = 0
    public var hasValue: Bool = false
    public init() {}
    public init(value!: Int32, hasValue!: Bool) {
        this.value = value
        this.hasValue = hasValue
    }
}

// ---- 14 类型判别 enum ----
// R-112: must be public + implement ordinal() + operator == / !=

public enum WidgetMessageContent {
    | ContentText
    | ContentImage(WidgetContentImage)
    | ContentVideo(WidgetContentVideo)
    | ContentFile(WidgetContentFile)
    | ContentGif(WidgetContentGif)
    | ContentMusic(WidgetContentMusic)
    | ContentVoiceMessage(WidgetContentVoiceMessage)
    | ContentVideoMessage(WidgetContentVideoMessage)
    | ContentSticker(WidgetContentSticker)
    | ContentCall(WidgetContentCall)
    | ContentMapLocation(WidgetContentMapLocation)
    | ContentGame(WidgetContentGame)
    | ContentPoll(WidgetContentPoll)
    | ContentAutodeleteTimer(WidgetContentAutodeleteTimer)

    public func ordinal(): Int32 {
        match (this) {
            case ContentText => 0
            case ContentImage(_) => 1
            case ContentVideo(_) => 2
            case ContentFile(_) => 3
            case ContentGif(_) => 4
            case ContentMusic(_) => 5
            case ContentVoiceMessage(_) => 6
            case ContentVideoMessage(_) => 7
            case ContentSticker(_) => 8
            case ContentCall(_) => 9
            case ContentMapLocation(_) => 10
            case ContentGame(_) => 11
            case ContentPoll(_) => 12
            case ContentAutodeleteTimer(_) => 13
        }
    }

    public operator func ==(right: WidgetMessageContent): Bool {
        return this.ordinal() == right.ordinal()
    }

    public operator func !=(right: WidgetMessageContent): Bool {
        return this.ordinal() != right.ordinal()
    }

    /**
     * 结构化预览文案（P2-433 结构化消息预览）
     * 按 iOS WidgetPresentationData 对应文案：
     *   Photo / Video / GIF / Voice Message / Video Message / Sticker /
     *   Call / Video Call / Map / game title / poll question / file name /
     *   Auto-delete timer updated
     */
    public func previewIcon(): String {
        match (this) {
            case ContentText => ""
            case ContentImage(_) => "Photo"
            case ContentVideo(_) => "Video"
            case ContentFile(_) => "File"
            case ContentGif(_) => "GIF"
            case ContentMusic(m) => m.title
            case ContentVoiceMessage(_) => "Voice Message"
            case ContentVideoMessage(_) => "Video Message"
            case ContentSticker(s) => if (s.altText.size > 0) { "${s.altText} Sticker" } else { "Sticker" }
            case ContentCall(c) => if (c.isVideo) { "Video Call" } else { "Call" }
            case ContentMapLocation(_) => "Map"
            case ContentGame(g) => g.title
            case ContentPoll(p) => p.title
            case ContentAutodeleteTimer(_) => "Auto-delete timer updated"
        }
    }

    /**
     * 序列化为 JSON 对象片段（discriminator + payload）
     * 格式: {"type":"image"} 或 {"type":"file","name":"foo.pdf"}
     */
    public func serializeToJson(): String {
        match (this) {
            case ContentText => "{\"type\":\"text\"}"
            case ContentImage(_) => "{\"type\":\"image\"}"
            case ContentVideo(_) => "{\"type\":\"video\"}"
            case ContentFile(f) =>
                let n = f.name.replace("\\", "\\\\").replace("\"", "\\\"")
                "{\"type\":\"file\",\"name\":\"${n}\"}"
            case ContentGif(_) => "{\"type\":\"gif\"}"
            case ContentMusic(m) =>
                let a = m.artist.replace("\\", "\\\\").replace("\"", "\\\"")
                let t = m.title.replace("\\", "\\\\").replace("\"", "\\\"")
                "{\"type\":\"music\",\"artist\":\"${a}\",\"title\":\"${t}\",\"duration\":${m.duration}}"
            case ContentVoiceMessage(v) =>
                "{\"type\":\"voiceMessage\",\"duration\":${v.duration}}"
            case ContentVideoMessage(v) =>
                "{\"type\":\"videoMessage\",\"duration\":${v.duration}}"
            case ContentSticker(s) =>
                let alt = s.altText.replace("\\", "\\\\").replace("\"", "\\\"")
                "{\"type\":\"sticker\",\"altText\":\"${alt}\"}"
            case ContentCall(c) =>
                "{\"type\":\"call\",\"isVideo\":${c.isVideo}}"
            case ContentMapLocation(_) => "{\"type\":\"mapLocation\"}"
            case ContentGame(g) =>
                let t = g.title.replace("\\", "\\\\").replace("\"", "\\\"")
                "{\"type\":\"game\",\"title\":\"${t}\"}"
            case ContentPoll(p) =>
                let t = p.title.replace("\\", "\\\\").replace("\"", "\\\"")
                "{\"type\":\"poll\",\"title\":\"${t}\"}"
            case ContentAutodeleteTimer(adt) =>
                "{\"type\":\"autodeleteTimer\",\"value\":${adt.value},\"hasValue\":${adt.hasValue}}"
        }
    }
}

// ============================================================
// WidgetMessage — 带内容类型的消息快照
// (iOS: WidgetDataPeer.Message)
// ============================================================

public class WidgetMessage {
    public var author: Option<WidgetMessageAuthor> = None
    public var text: String = ""
    public var content: WidgetMessageContent = WidgetMessageContent.ContentText
    public var timestamp: Int32 = 0

    public init() {}

    public init(
        author!: Option<WidgetMessageAuthor>,
        text!: String,
        content!: WidgetMessageContent,
        timestamp!: Int32
    ) {
        this.author = author
        this.text = text
        this.content = content
        this.timestamp = timestamp
    }

    /**
     * 构造结构化预览文案（P2-433）
     * 格式：
     *   - 纯文字消息：[Sender: ]text
     *   - 媒体消息：[Sender: ]icon 或 icon: text
     * 群消息带发送者前缀（iOS: author.title + ": "，自己=You）
     */
    public func buildPreviewText(): String {
        let senderPrefix = this.senderPrefix()
        let icon = this.content.previewIcon()
        let body: String
        if (icon.size == 0) {
            // text
            body = this.text
        } else if (this.text.size > 0) {
            body = "${icon}: ${this.text}"
        } else {
            body = icon
        }
        if (senderPrefix.size > 0) {
            return "${senderPrefix}: ${body}"
        }
        return body
    }

    private func senderPrefix(): String {
        match (this.author) {
            case Some(a) =>
                if (a.isMe) { return "You" } else { return a.title }
            case None => return ""
        }
    }

    public func serializeToJson(): String {
        let textEsc = this.text.replace("\\", "\\\\").replace("\"", "\\\"")
        let authorJson = match (this.author) {
            case Some(a) => a.serializeToJson()
            case None => "null"
        }
        let contentJson = this.content.serializeToJson()
        return "{\"author\":${authorJson},\"text\":\"${textEsc}\",\"content\":${contentJson},\"timestamp\":${this.timestamp}}"
    }
}

// ============================================================
// WidgetDataPeer.Badge — 未读徽章
// (iOS: WidgetDataPeer.Badge)
// ============================================================

public class WidgetBadge {
    public var count: Int32 = 0
    public var isMuted: Bool = false

    public init() {}

    public init(count!: Int32, isMuted!: Bool) {
        this.count = count
        this.isMuted = isMuted
    }

    public func serializeToJson(): String {
        return "{\"count\":${this.count},\"isMuted\":${this.isMuted}}"
    }
}

// ============================================================
// WidgetDataPeer — 单个会话的 widget 快照
// (iOS: WidgetDataPeer)
// ============================================================

public class WidgetDataPeer {
    public var id: Int64 = 0
    public var name: String = ""
    public var lastName: String = ""
    public var hasLastName: Bool = false
    // letters[]：多字母头像（iOS: [String] 通常 1-2 字母，如 ["А", "Б"]）
    public var letters: Array<String> = Array<String>(0, repeat: "")
    public var avatarPath: String = ""
    public var hasAvatarPath: Bool = false
    public var badge: Option<WidgetBadge> = None
    public var message: Option<WidgetMessage> = None
    public var isForum: Bool = false

    public init() {}

    /**
     * 是否为 Saved Messages（自己对自己，iOS: id == accountPeerId）
     * 由调用方（WidgetItemsService）注入 accountId 后比较
     */
    public func isSavedMessages(accountPeerId: Int64): Bool {
        return this.id == accountPeerId
    }

    /**
     * 头像首字母（letters 数组首个，供 UI 回退显示）
     */
    public func primaryLetter(): String {
        if (this.letters.size > 0) {
            return this.letters[0]
        }
        if (this.name.size > 0) {
            let runes = this.name.toRuneArray()
            if (runes.size > 0) { return runes[0].toString() }
        }
        return "?"
    }

    public func serializeToJson(): String {
        let nameEsc = this.name.replace("\\", "\\\\").replace("\"", "\\\"")
        let lastNameEsc = this.lastName.replace("\\", "\\\\").replace("\"", "\\\"")
        let avatarEsc = this.avatarPath.replace("\\", "\\\\").replace("\"", "\\\"")

        var lettersJson = "["
        var firstL = true
        for (l in this.letters) {
            if (!firstL) { lettersJson = lettersJson + "," }
            let lEsc = l.replace("\\", "\\\\").replace("\"", "\\\"")
            lettersJson = lettersJson + "\"${lEsc}\""
            firstL = false
        }
        lettersJson = lettersJson + "]"

        let badgeJson = match (this.badge) {
            case Some(b) => b.serializeToJson()
            case None => "null"
        }
        let messageJson = match (this.message) {
            case Some(m) => m.serializeToJson()
            case None => "null"
        }
        let lastNameJson = if (this.hasLastName) { "\"${lastNameEsc}\"" } else { "null" }
        let avatarJson = if (this.hasAvatarPath) { "\"${avatarEsc}\"" } else { "null" }

        return "{\"id\":${this.id},\"name\":\"${nameEsc}\",\"lastName\":${lastNameJson},\"letters\":${lettersJson},\"avatarPath\":${avatarJson},\"badge\":${badgeJson},\"message\":${messageJson},\"isForum\":${this.isForum}}"
    }
}

// ============================================================
// WidgetDataPeers — 账号级别的会话列表快照
// (iOS: WidgetDataPeers)
// ============================================================

public class WidgetDataPeers {
    public var accountPeerId: Int64 = 0
    public var peers: Array<WidgetDataPeer> = Array<WidgetDataPeer>(0, { _ => WidgetDataPeer() })
    public var updateTimestamp: Int32 = 0

    public init() {}

    public init(accountPeerId!: Int64, peers!: Array<WidgetDataPeer>, updateTimestamp!: Int32) {
        this.accountPeerId = accountPeerId
        this.peers = peers
        this.updateTimestamp = updateTimestamp
    }

    public func serializeToJson(): String {
        var peersJson = "["
        var first = true
        for (p in this.peers) {
            if (!first) { peersJson = peersJson + "," }
            peersJson = peersJson + p.serializeToJson()
            first = false
        }
        peersJson = peersJson + "]"
        return "{\"accountPeerId\":${this.accountPeerId},\"peers\":${peersJson},\"updateTimestamp\":${this.updateTimestamp}}"
    }
}

// ============================================================
// WidgetData — 顶层 widget 数据容器
// (iOS: WidgetData { accountId, content, unlockedForLockId })
//
// [widget-host:P2-435] 接线点：
//   serializeToJson() 输出格式供 P2-436 写入 distributedKVStore/Preferences。
//   FormExtensionAbility 读取端由 P2-435 实现。
// ============================================================

public class WidgetData {
    public var accountId: Int64 = 0
    // content: None = empty, Some = peers snapshot
    public var content: Option<WidgetDataPeers> = None
    // unlockedForLockId: 锁屏解锁标记（iOS: String?）
    public var unlockedForLockId: String = ""
    public var hasUnlockedForLockId: Bool = false

    public init() {}

    public init(
        accountId!: Int64,
        content!: Option<WidgetDataPeers>,
        unlockedForLockId!: String,
        hasUnlockedForLockId!: Bool
    ) {
        this.accountId = accountId
        this.content = content
        this.unlockedForLockId = unlockedForLockId
        this.hasUnlockedForLockId = hasUnlockedForLockId
    }

    /**
     * 是否处于锁屏态（iOS: unlockedForLockId != nil 且与当前锁屏 passcodeLockId 不同）
     * 简化版：hasUnlockedForLockId == true 表示数据已解锁可显示
     */
    public func isUnlocked(): Bool {
        return this.hasUnlockedForLockId
    }

    /**
     * 序列化为 JSON（供 P2-436 落盘：distributedKVStore 或 Preferences）
     */
    public func serializeToJson(): String {
        let contentJson = match (this.content) {
            case Some(p) => p.serializeToJson()
            case None => "null"
        }
        let lockIdEsc = this.unlockedForLockId.replace("\\", "\\\\").replace("\"", "\\\"")
        let lockJson = if (this.hasUnlockedForLockId) { "\"${lockIdEsc}\"" } else { "null" }
        return "{\"accountId\":${this.accountId},\"content\":${contentJson},\"unlockedForLockId\":${lockJson}}"
    }
}
