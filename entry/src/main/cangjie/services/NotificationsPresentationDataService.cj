package ohos_app_cangjie_entry.services

import ohos_app_cangjie_entry.core.mtproto.getMTProtoClient
import ohos_app_cangjie_entry.core.mtproto.{AccountGetNotifySettings, TLDeserializer, TLConstructors}
import std.collection.HashMap
import std.collection.ArrayList
import kit.PerformanceAnalysisKit.Hilog

/**
 * NotificationsPresentationData — 对应 iOS 结构体
 * applicationLockedMessageString: 锁屏时显示的消息
 * incomingCallString: 来电时显示的字符串
 */
public class NotificationsPresentationData {
    public var applicationLockedMessageString: String = "You have a new message"
    public var incomingCallString: String = "Incoming call"
}

/**
 * 生成 notificationsPresentationData 存储路径
 * 对应 iOS notificationsPresentationDataPath(rootPath:)
 */
public func notificationsPresentationDataPath(rootPath: String): String {
    return rootPath + "/notificationsPresentationData.json"
}

/**
 * 通知预览设置（用于 NotificationsPresentationDataComponent）
 */
public class NotifyPreviewSettings {
    public var showPreviews: Bool = true
}

// ==================== P2-260: PUSH_* loc-key 模板体系 ====================

/**
 * PushMessageTemplates — PUSH_* loc-key 英文模板库
 *
 * 对应 iOS en.lproj/Localizable.strings 中全部 PUSH_* 条目（主要条目）
 *
 * 模板格式约定（遵循 iOS .strings 格式）：
 *   %1$@ → args[0]
 *   %2$@ → args[1]
 *   %3$@ → args[2]
 *   %d   → 整数参数（本实现统一按 %1$@ 等处理 args）
 *   {author} → 特殊占位（主要见 PUSH_CHAT_MESSAGES_TEXT，按 args[0] 替换）
 *   "|"  → title/body 分隔符（左为 title 即 peer 名，右为 body）
 *
 * 注：iOS 中 PUSH_PHONE_CALL_REQUEST 通过代码拼接（SharedNotificationManager.swift:433）
 * 而非 loc-key 模板，这里提供等价 incomingCall 格式。
 */
public class PushMessageTemplates {

    // ---- 单聊消息 ----
    public static let MESSAGE_TEXT: String = "%1$@|%2$@"
    public static let MESSAGE_NOTEXT: String = "%1$@|sent you a message"
    public static let MESSAGE_PHOTO: String = "%1$@|sent you a photo"
    public static let MESSAGE_PHOTO_SECRET: String = "%1$@|sent you a self-destructing photo"
    public static let MESSAGE_VIDEO: String = "%1$@|sent you a video"
    public static let MESSAGE_VIDEO_SECRET: String = "%1$@|sent you a self-destructing video"
    public static let MESSAGE_ROUND: String = "%1$@|sent you a video message"
    public static let MESSAGE_AUDIO: String = "%1$@|sent you a voice message"
    public static let MESSAGE_DOC: String = "%1$@|sent you a file"
    public static let MESSAGE_GIF: String = "%1$@|sent you a GIF"
    public static let MESSAGE_STICKER: String = "%1$@|sent you a %2$@sticker"
    public static let MESSAGE_CONTACT: String = "%1$@|shared a contact %2$@ with you"
    public static let MESSAGE_GEO: String = "%1$@|sent you a map"
    public static let MESSAGE_GEOLIVE: String = "%1$@|started sharing their live location"
    public static let MESSAGE_POLL: String = "%1$@|sent you a poll %2$@"
    public static let MESSAGE_QUIZ: String = "%1$@|sent you a quiz %2$@"
    public static let MESSAGE_GAME: String = "%1$@|invited you to play %2$@"
    public static let MESSAGE_SCREENSHOT: String = "%1$@|took a screenshot!"
    public static let MESSAGE_STORY: String = "%1$@|shared a story with you"
    public static let ALBUM: String = "%1$@|sent you an album"

    // ---- 锁屏/加密 ----
    public static let ENCRYPTED_MESSAGE: String = "You have a new message%1$@"
    public static let LOCKED_MESSAGE: String = "You have a new message%1$@"
    public static let ENCRYPTION_REQUEST: String = "New encryption request%1$@"
    public static let ENCRYPTION_ACCEPT: String = "Your encryption request was accepted%1$@"

    // ---- 群组消息 ----
    public static let CHAT_MESSAGE_TEXT: String = "%2$@|%1$@: %3$@"
    public static let CHAT_MESSAGE_NOTEXT: String = "%2$@|%1$@ sent a message"
    public static let CHAT_MESSAGE_PHOTO: String = "%2$@|%1$@ sent a photo"
    public static let CHAT_MESSAGE_VIDEO: String = "%2$@|%1$@ sent a video"
    public static let CHAT_MESSAGE_ROUND: String = "%2$@|%1$@ sent a video message"
    public static let CHAT_MESSAGE_AUDIO: String = "%2$@|%1$@ sent a voice message"
    public static let CHAT_MESSAGE_DOC: String = "%2$@|%1$@ sent a file"
    public static let CHAT_MESSAGE_GIF: String = "%2$@|%1$@ sent a GIF"
    public static let CHAT_MESSAGE_STICKER: String = "%2$@|%1$@ sent a %3$@sticker"
    public static let CHAT_MESSAGE_CONTACT: String = "%2$@|%1$@ shared a contact %3$@"
    public static let CHAT_MESSAGE_GEO: String = "%2$@|%1$@ sent a map"
    public static let CHAT_MESSAGE_GEOLIVE: String = "%2$@|%1$@ started sharing their live location"
    public static let CHAT_MESSAGE_POLL: String = "%2$@|%1$@ sent a poll"
    public static let CHAT_MESSAGE_QUIZ: String = "%2$@|%1$@ sent a quiz"
    public static let CHAT_MESSAGE_GAME: String = "%2$@|%1$@ invited the group to play %3$@"
    public static let CHAT_MESSAGE_FWD: String = "%2$@|%1$@ forwarded a message"
    public static let CHAT_MESSAGE_INVOICE: String = "%2$@|%1$@ sent an invoice for %3$@"
    public static let CHAT_MESSAGE_STORY: String = "%2$@|%1$@ shared a story to the group"
    public static let CHAT_ALBUM: String = "%2$@|%1$@ sent an album"
    public static let CHAT_CREATED: String = "%2$@|%1$@ invited you to the group"
    public static let CHAT_TITLE_EDITED: String = "%2$@|%1$@ edited the group's name"
    public static let CHAT_PHOTO_EDITED: String = "%2$@|%1$@ edited the group's photo"
    public static let CHAT_ADD_MEMBER: String = "%2$@|%1$@ invited %3$@ to the group"
    public static let CHAT_ADD_YOU: String = "%2$@|%1$@ invited you to the group"
    public static let CHAT_DELETE_YOU: String = "%2$@|%1$@ removed you from the group"
    public static let CHAT_DELETE_MEMBER: String = "%2$@|%1$@ removed %3$@ from the group"
    public static let CHAT_LEFT: String = "%2$@|%1$@ left the group"
    public static let CHAT_RETURNED: String = "%2$@|%1$@ returned to the group"
    public static let CHAT_JOINED: String = "%2$@|%1$@ has joined the group"
    public static let CHAT_REQ_JOINED: String = "%2$@|%1$@ was accepted into the group"
    public static let CHAT_REACT_TEXT: String = "%2$@|%1$@ %3$@ to your %4$@"
    public static let CHAT_REACT_NOTEXT: String = "%2$@|%1$@ %3$@ to your message"
    public static let CHAT_REACT_PHOTO: String = "%2$@|%1$@ %3$@ to your photo"
    public static let CHAT_REACT_VIDEO: String = "%2$@|%1$@ %3$@ to your video"
    public static let CHAT_REACT_AUDIO: String = "%2$@|%1$@ %3$@ to your voice message"
    public static let CHAT_REACT_DOC: String = "%2$@|%1$@ %3$@ to your file"
    public static let CHAT_REACT_GIF: String = "%2$@|%1$@ %3$@ to your GIF"
    public static let CHAT_REACT_STICKER: String = "%2$@|%1$@ %3$@ to your %4$@sticker"
    public static let CHAT_REACT_ROUND: String = "%2$@|%1$@ %3$@ to your video message"
    public static let CHAT_REACT_GEO: String = "%2$@|%1$@ %3$@ to your map"
    public static let CHAT_REACT_GEOLIVE: String = "%2$@|%1$@ %3$@ to your live location"
    public static let CHAT_REACT_GAME: String = "%2$@|%1$@ %3$@ to your game"
    public static let CHAT_REACT_INVOICE: String = "%2$@|%1$@ %3$@ to your invoice"
    public static let CHAT_REACT_PAID_MEDIA: String = "%2$@|%1$@ %3$@ to your paid post"
    public static let CHAT_REACT_POLL: String = "%2$@|%1$@ %3$@ to your poll %4$@"
    public static let CHAT_REACT_CONTACT: String = "%2$@|%1$@ %3$@ to your contact %4$@"
    public static let CHAT_LIVESTREAM_START: String = "%2$@|%1$@ started a live stream"
    public static let CHAT_LIVESTREAM_END: String = "%2$@|%1$@ has ended the live stream"
    public static let CHAT_LIVESTREAM_INVITE: String = "%2$@|%1$@ invited %3$@ to the live stream"
    public static let CHAT_LIVESTREAM_INVITE_YOU: String = "%2$@|%1$@ invited you to the live stream"

    // ---- 频道消息 ----
    public static let CHANNEL_MESSAGE: String = "%1$@|posted a message"
    public static let CHANNEL_MESSAGE_TEXT: String = "%1$@|%2$@"
    public static let CHANNEL_MESSAGE_NOTEXT: String = "%1$@|posted a message"
    public static let CHANNEL_MESSAGE_PHOTO: String = "%1$@|posted a photo"
    public static let CHANNEL_MESSAGE_VIDEO: String = "%1$@|posted a video"
    public static let CHANNEL_MESSAGE_ROUND: String = "%1$@|posted a video message"
    public static let CHANNEL_MESSAGE_AUDIO: String = "%1$@|posted a voice message"
    public static let CHANNEL_MESSAGE_DOC: String = "%1$@|posted a document"
    public static let CHANNEL_MESSAGE_GIF: String = "%1$@|posted a GIF"
    public static let CHANNEL_MESSAGE_STICKER: String = "%1$@|posted a %2$@sticker"
    public static let CHANNEL_MESSAGE_CONTACT: String = "%1$@|posted a %2$@ contact"
    public static let CHANNEL_MESSAGE_GEO: String = "%1$@|posted a map"
    public static let CHANNEL_MESSAGE_GEOLIVE: String = "%1$@|posted a live location"
    public static let CHANNEL_MESSAGE_POLL: String = "%1$@|posted a poll"
    public static let CHANNEL_MESSAGE_QUIZ: String = "%1$@|posted a quiz"
    public static let CHANNEL_MESSAGE_GAME: String = "%1$@|invited you to play %2$@"
    public static let CHANNEL_MESSAGE_FWD: String = "%1$@|posted a forwarded message"
    public static let CHANNEL_MESSAGE_STORY: String = "%1$@|shared a story"
    public static let CHANNEL_ALBUM: String = "%1$@|posted an album"

    // ---- 系统 ----
    public static let CONTACT_JOINED: String = "%1$@|joined Telegram!"
    public static let AUTH_UNKNOWN: String = "New login|from unrecognized device %1$@"
    public static let AUTH_REGION: String = "New login|from unrecognized device %1$@, location: %2$@"
    public static let PINNED_POLL: String = "%1$@|pinned a poll"
    public static let PINNED_QUIZ: String = "%1$@|pinned a quiz"

    // ---- 来电 ----
    public static let PHONE_CALL_REQUEST: String = "%1$@|is calling you!"

    /**
     * 根据 loc-key 字符串查找对应模板
     * @return 模板字符串，找不到时返回 None
     */
    public static func templateForKey(key: String): Option<String> {
        let templates = PushMessageTemplates.buildTemplateMap()
        match (templates.get(key)) {
            case Some(t) => return Some(t)
            case None => return None
        }
    }

    /**
     * 构建 loc-key → 模板字符串的映射表
     * 注：HashMap 不支持静态初始化，每次按需构建（服务层可缓存）
     */
    static func buildTemplateMap(): HashMap<String, String> {
        let m = HashMap<String, String>()
        m.add("PUSH_MESSAGE_TEXT", PushMessageTemplates.MESSAGE_TEXT)
        m.add("PUSH_MESSAGE_NOTEXT", PushMessageTemplates.MESSAGE_NOTEXT)
        m.add("PUSH_MESSAGE_PHOTO", PushMessageTemplates.MESSAGE_PHOTO)
        m.add("PUSH_MESSAGE_PHOTO_SECRET", PushMessageTemplates.MESSAGE_PHOTO_SECRET)
        m.add("PUSH_MESSAGE_VIDEO", PushMessageTemplates.MESSAGE_VIDEO)
        m.add("PUSH_MESSAGE_VIDEO_SECRET", PushMessageTemplates.MESSAGE_VIDEO_SECRET)
        m.add("PUSH_MESSAGE_ROUND", PushMessageTemplates.MESSAGE_ROUND)
        m.add("PUSH_MESSAGE_AUDIO", PushMessageTemplates.MESSAGE_AUDIO)
        m.add("PUSH_MESSAGE_DOC", PushMessageTemplates.MESSAGE_DOC)
        m.add("PUSH_MESSAGE_GIF", PushMessageTemplates.MESSAGE_GIF)
        m.add("PUSH_MESSAGE_STICKER", PushMessageTemplates.MESSAGE_STICKER)
        m.add("PUSH_MESSAGE_CONTACT", PushMessageTemplates.MESSAGE_CONTACT)
        m.add("PUSH_MESSAGE_GEO", PushMessageTemplates.MESSAGE_GEO)
        m.add("PUSH_MESSAGE_GEOLIVE", PushMessageTemplates.MESSAGE_GEOLIVE)
        m.add("PUSH_MESSAGE_POLL", PushMessageTemplates.MESSAGE_POLL)
        m.add("PUSH_MESSAGE_QUIZ", PushMessageTemplates.MESSAGE_QUIZ)
        m.add("PUSH_MESSAGE_GAME", PushMessageTemplates.MESSAGE_GAME)
        m.add("PUSH_MESSAGE_SCREENSHOT", PushMessageTemplates.MESSAGE_SCREENSHOT)
        m.add("PUSH_MESSAGE_STORY", PushMessageTemplates.MESSAGE_STORY)
        m.add("PUSH_ALBUM", PushMessageTemplates.ALBUM)
        m.add("PUSH_ENCRYPTED_MESSAGE", PushMessageTemplates.ENCRYPTED_MESSAGE)
        m.add("PUSH_LOCKED_MESSAGE", PushMessageTemplates.LOCKED_MESSAGE)
        m.add("PUSH_ENCRYPTION_REQUEST", PushMessageTemplates.ENCRYPTION_REQUEST)
        m.add("PUSH_ENCRYPTION_ACCEPT", PushMessageTemplates.ENCRYPTION_ACCEPT)
        m.add("PUSH_CHAT_MESSAGE_TEXT", PushMessageTemplates.CHAT_MESSAGE_TEXT)
        m.add("PUSH_CHAT_MESSAGE_NOTEXT", PushMessageTemplates.CHAT_MESSAGE_NOTEXT)
        m.add("PUSH_CHAT_MESSAGE_PHOTO", PushMessageTemplates.CHAT_MESSAGE_PHOTO)
        m.add("PUSH_CHAT_MESSAGE_VIDEO", PushMessageTemplates.CHAT_MESSAGE_VIDEO)
        m.add("PUSH_CHAT_MESSAGE_ROUND", PushMessageTemplates.CHAT_MESSAGE_ROUND)
        m.add("PUSH_CHAT_MESSAGE_AUDIO", PushMessageTemplates.CHAT_MESSAGE_AUDIO)
        m.add("PUSH_CHAT_MESSAGE_DOC", PushMessageTemplates.CHAT_MESSAGE_DOC)
        m.add("PUSH_CHAT_MESSAGE_GIF", PushMessageTemplates.CHAT_MESSAGE_GIF)
        m.add("PUSH_CHAT_MESSAGE_STICKER", PushMessageTemplates.CHAT_MESSAGE_STICKER)
        m.add("PUSH_CHAT_MESSAGE_CONTACT", PushMessageTemplates.CHAT_MESSAGE_CONTACT)
        m.add("PUSH_CHAT_MESSAGE_GEO", PushMessageTemplates.CHAT_MESSAGE_GEO)
        m.add("PUSH_CHAT_MESSAGE_GEOLIVE", PushMessageTemplates.CHAT_MESSAGE_GEOLIVE)
        m.add("PUSH_CHAT_MESSAGE_POLL", PushMessageTemplates.CHAT_MESSAGE_POLL)
        m.add("PUSH_CHAT_MESSAGE_QUIZ", PushMessageTemplates.CHAT_MESSAGE_QUIZ)
        m.add("PUSH_CHAT_MESSAGE_GAME", PushMessageTemplates.CHAT_MESSAGE_GAME)
        m.add("PUSH_CHAT_MESSAGE_FWD", PushMessageTemplates.CHAT_MESSAGE_FWD)
        m.add("PUSH_CHAT_MESSAGE_INVOICE", PushMessageTemplates.CHAT_MESSAGE_INVOICE)
        m.add("PUSH_CHAT_MESSAGE_STORY", PushMessageTemplates.CHAT_MESSAGE_STORY)
        m.add("PUSH_CHAT_ALBUM", PushMessageTemplates.CHAT_ALBUM)
        m.add("PUSH_CHAT_CREATED", PushMessageTemplates.CHAT_CREATED)
        m.add("PUSH_CHAT_TITLE_EDITED", PushMessageTemplates.CHAT_TITLE_EDITED)
        m.add("PUSH_CHAT_PHOTO_EDITED", PushMessageTemplates.CHAT_PHOTO_EDITED)
        m.add("PUSH_CHAT_ADD_MEMBER", PushMessageTemplates.CHAT_ADD_MEMBER)
        m.add("PUSH_CHAT_ADD_YOU", PushMessageTemplates.CHAT_ADD_YOU)
        m.add("PUSH_CHAT_DELETE_YOU", PushMessageTemplates.CHAT_DELETE_YOU)
        m.add("PUSH_CHAT_DELETE_MEMBER", PushMessageTemplates.CHAT_DELETE_MEMBER)
        m.add("PUSH_CHAT_LEFT", PushMessageTemplates.CHAT_LEFT)
        m.add("PUSH_CHAT_RETURNED", PushMessageTemplates.CHAT_RETURNED)
        m.add("PUSH_CHAT_JOINED", PushMessageTemplates.CHAT_JOINED)
        m.add("PUSH_CHAT_REQ_JOINED", PushMessageTemplates.CHAT_REQ_JOINED)
        m.add("PUSH_CHAT_REACT_TEXT", PushMessageTemplates.CHAT_REACT_TEXT)
        m.add("PUSH_CHAT_REACT_NOTEXT", PushMessageTemplates.CHAT_REACT_NOTEXT)
        m.add("PUSH_CHAT_REACT_PHOTO", PushMessageTemplates.CHAT_REACT_PHOTO)
        m.add("PUSH_CHAT_REACT_VIDEO", PushMessageTemplates.CHAT_REACT_VIDEO)
        m.add("PUSH_CHAT_REACT_AUDIO", PushMessageTemplates.CHAT_REACT_AUDIO)
        m.add("PUSH_CHAT_REACT_DOC", PushMessageTemplates.CHAT_REACT_DOC)
        m.add("PUSH_CHAT_REACT_GIF", PushMessageTemplates.CHAT_REACT_GIF)
        m.add("PUSH_CHAT_REACT_STICKER", PushMessageTemplates.CHAT_REACT_STICKER)
        m.add("PUSH_CHAT_REACT_ROUND", PushMessageTemplates.CHAT_REACT_ROUND)
        m.add("PUSH_CHAT_REACT_GEO", PushMessageTemplates.CHAT_REACT_GEO)
        m.add("PUSH_CHAT_REACT_GEOLIVE", PushMessageTemplates.CHAT_REACT_GEOLIVE)
        m.add("PUSH_CHAT_REACT_GAME", PushMessageTemplates.CHAT_REACT_GAME)
        m.add("PUSH_CHAT_REACT_INVOICE", PushMessageTemplates.CHAT_REACT_INVOICE)
        m.add("PUSH_CHAT_REACT_PAID_MEDIA", PushMessageTemplates.CHAT_REACT_PAID_MEDIA)
        m.add("PUSH_CHAT_REACT_POLL", PushMessageTemplates.CHAT_REACT_POLL)
        m.add("PUSH_CHAT_REACT_CONTACT", PushMessageTemplates.CHAT_REACT_CONTACT)
        m.add("PUSH_CHAT_LIVESTREAM_START", PushMessageTemplates.CHAT_LIVESTREAM_START)
        m.add("PUSH_CHAT_LIVESTREAM_END", PushMessageTemplates.CHAT_LIVESTREAM_END)
        m.add("PUSH_CHAT_LIVESTREAM_INVITE", PushMessageTemplates.CHAT_LIVESTREAM_INVITE)
        m.add("PUSH_CHAT_LIVESTREAM_INVITE_YOU", PushMessageTemplates.CHAT_LIVESTREAM_INVITE_YOU)
        m.add("PUSH_CHANNEL_MESSAGE", PushMessageTemplates.CHANNEL_MESSAGE)
        m.add("PUSH_CHANNEL_MESSAGE_TEXT", PushMessageTemplates.CHANNEL_MESSAGE_TEXT)
        m.add("PUSH_CHANNEL_MESSAGE_NOTEXT", PushMessageTemplates.CHANNEL_MESSAGE_NOTEXT)
        m.add("PUSH_CHANNEL_MESSAGE_PHOTO", PushMessageTemplates.CHANNEL_MESSAGE_PHOTO)
        m.add("PUSH_CHANNEL_MESSAGE_VIDEO", PushMessageTemplates.CHANNEL_MESSAGE_VIDEO)
        m.add("PUSH_CHANNEL_MESSAGE_ROUND", PushMessageTemplates.CHANNEL_MESSAGE_ROUND)
        m.add("PUSH_CHANNEL_MESSAGE_AUDIO", PushMessageTemplates.CHANNEL_MESSAGE_AUDIO)
        m.add("PUSH_CHANNEL_MESSAGE_DOC", PushMessageTemplates.CHANNEL_MESSAGE_DOC)
        m.add("PUSH_CHANNEL_MESSAGE_GIF", PushMessageTemplates.CHANNEL_MESSAGE_GIF)
        m.add("PUSH_CHANNEL_MESSAGE_STICKER", PushMessageTemplates.CHANNEL_MESSAGE_STICKER)
        m.add("PUSH_CHANNEL_MESSAGE_CONTACT", PushMessageTemplates.CHANNEL_MESSAGE_CONTACT)
        m.add("PUSH_CHANNEL_MESSAGE_GEO", PushMessageTemplates.CHANNEL_MESSAGE_GEO)
        m.add("PUSH_CHANNEL_MESSAGE_GEOLIVE", PushMessageTemplates.CHANNEL_MESSAGE_GEOLIVE)
        m.add("PUSH_CHANNEL_MESSAGE_POLL", PushMessageTemplates.CHANNEL_MESSAGE_POLL)
        m.add("PUSH_CHANNEL_MESSAGE_QUIZ", PushMessageTemplates.CHANNEL_MESSAGE_QUIZ)
        m.add("PUSH_CHANNEL_MESSAGE_GAME", PushMessageTemplates.CHANNEL_MESSAGE_GAME)
        m.add("PUSH_CHANNEL_MESSAGE_FWD", PushMessageTemplates.CHANNEL_MESSAGE_FWD)
        m.add("PUSH_CHANNEL_MESSAGE_STORY", PushMessageTemplates.CHANNEL_MESSAGE_STORY)
        m.add("PUSH_CHANNEL_ALBUM", PushMessageTemplates.CHANNEL_ALBUM)
        m.add("PUSH_CONTACT_JOINED", PushMessageTemplates.CONTACT_JOINED)
        m.add("PUSH_AUTH_UNKNOWN", PushMessageTemplates.AUTH_UNKNOWN)
        m.add("PUSH_AUTH_REGION", PushMessageTemplates.AUTH_REGION)
        m.add("PUSH_PINNED_POLL", PushMessageTemplates.PINNED_POLL)
        m.add("PUSH_PINNED_QUIZ", PushMessageTemplates.PINNED_QUIZ)
        m.add("PUSH_PHONE_CALL_REQUEST", PushMessageTemplates.PHONE_CALL_REQUEST)
        return m
    }
}

/**
 * 对 PUSH_* loc-key 模板字符串填充 loc-args 位置参数
 *
 * 对应 iOS .strings 中 %1$@, %2$@, %3$@, %4$@ 占位符替换逻辑
 * 以及 {author} 特殊占位（PUSH_CHAT_MESSAGES_TEXT_* 类型）
 *
 * 规则：
 *   %N$@ → 替换为 args[N-1]（N 从 1 开始，args 从 0 开始）
 *   {author} → 替换为 args[0]（PUSH_CHAT_MESSAGES_TEXT 特例）
 *   %d → 替换为 args[0]（整数占位，按首位 arg）
 *
 * @param template  模板字符串（如 "%2$@|%1$@: %3$@"）
 * @param args      位置参数列表（按 iOS loc-args 顺序传入，args[0]=%1$@）
 * @return 填充后的字符串
 */
public func applyPushLocArgs(template: String, args: ArrayList<String>): String {
    var result = template
    var idx: Int64 = 0
    while (idx < args.size) {
        let argVal = args[idx]
        let n: Int64 = idx + 1
        let placeholder = "%" + n.toString() + "$@"
        result = result.replace(placeholder, argVal)
        idx = idx + 1
    }
    if (result.contains("{author}") && args.size > 0) {
        result = result.replace("{author}", args[0])
    }
    if (result.contains("%d") && args.size > 0) {
        result = result.replace("%d", args[0])
    }
    return result
}

/**
 * 从填充后的模板字符串拆分标题和正文
 *
 * 对应 iOS: alert["title"] / alert["body"] 分离逻辑
 * iOS Localizable.strings 约定用 "|" 分隔 title 和 body：
 *   "%1$@|sent you a photo"  →  title="%1$@", body="sent you a photo"
 *
 * @param formatted 已完成 locArgs 填充的字符串
 * @return (title, body)：若无 "|" 则 title="" body=formatted
 */
public func splitPushTitleBody(formatted: String): (String, String) {
    match (formatted.indexOf("|")) {
        case Some(sepIdx) =>
            let title = formatted[0..sepIdx]
            let body = formatted[(sepIdx + 1)..formatted.size]
            return (title, body)
        case None =>
            return ("", formatted)
    }
}

// ==================== NotificationsPresentationDataService ====================

/**
 * 通知预览数据服务（工厂函数）
 */
public func getNotificationsPresentationDataService(): NotificationsPresentationDataService {
    return NotificationsPresentationDataService()
}

/**
 * NotificationsPresentationDataService — 通知预览数据服务
 *
 * P2-260 增强：完整 PUSH_* loc-key 模板体系，loc-args 占位填充，多语言结构支持
 * P2-264 接入：展示前可调用 shouldSuppressForPeer() 做静音检查
 *
 * 对应 iOS：
 *   NotificationsPresentationData + TelegramPresentationData strings.*
 *   SharedNotificationManager.swift PUSH_* 模板调用
 */
public class NotificationsPresentationDataService {

    /**
     * 获取指定类型的通知设置（用于预览）
     *
     * P2-274: 若 App 当前处于锁定状态（AppLockStateService.isLocked()），
     *   强制 showPreviews = false，通知只显示"New message"不显示发送者/正文。
     *   iOS 对应: AppLock.passcodeEnabled → UNNotificationContent.body = "You have a new message"
     */
    public func getNotifySettings(peerType: String): NotifyPreviewSettings {
        let result = NotifyPreviewSettings()
        try {
            let client = getMTProtoClient()
            let req = AccountGetNotifySettings()
            req.peerType = peerType
            let data = client.sendRequest(req.toBytes())
            if (data.size >= 8) {
                let d = TLDeserializer(data)
                let ctor = d.readUInt32()
                if (ctor == 0x99622c0c) {
                    let flags = d.readInt32()
                    if ((flags & 1) != 0) {
                        let b = d.readUInt32()
                        result.showPreviews = (b == 0x997275b5)
                    }
                }
            }
        } catch (_e: Exception) {}
        // P2-274: 锁屏时强制隐藏通知内容预览
        // iOS 对应: SharedNotificationManager → applicationLockedMessageString ("You have a new message")
        // 当 App 被 passcode 锁定时，isLocked() 返回 true，覆盖服务器端 showPreviews 设置
        if (result.showPreviews) {
            try {
                if (getAppLockStateService().isLocked()) {
                    result.showPreviews = false
                    Hilog.info(0, "CjTelegram", "[NotificationsPresentationDataService] App locked: forcing showPreviews=false (P2-274)")
                }
            } catch (_e2: Exception) {
                Hilog.info(0, "CjTelegram", "[NotificationsPresentationDataService] P2-274 lock check failed, keeping showPreviews as-is")
            }
        }
        return result
    }

    /**
     * 格式化通知标题（原有签名，向后兼容）
     *
     * @param peerName peer 显示名称
     * @param _        预留参数（未使用）
     * @return 通知标题字符串
     */
    public func formatNotificationTitle(peerName: String, _: String): String {
        if (peerName.size > 0) {
            return peerName
        }
        return "Telegram"
    }

    /**
     * 格式化通知标题（P2-260 新版，支持 loc-key 模板）
     *
     * 优先使用 loc-key 模板；退回到 peerName 直接返回
     *
     * @param locKey    PUSH_* loc-key（如 "PUSH_MESSAGE_PHOTO"）；空串=不使用模板
     * @param locArgs   loc-args 位置参数（配合模板替换 %1$@ 等）
     * @param peerName  peer 显示名称（模板无结果时的 fallback）
     * @return 通知标题字符串
     */
    public func formatNotificationTitleLocKey(locKey: String, locArgs: ArrayList<String>, peerName: String): String {
        if (locKey.size > 0) {
            match (PushMessageTemplates.templateForKey(locKey)) {
                case Some(tmpl) =>
                    let filled = applyPushLocArgs(tmpl, locArgs)
                    let pair = splitPushTitleBody(filled)
                    let title = pair[0]
                    if (title.size > 0) {
                        return title
                    }
                case None => ()
            }
        }
        if (peerName.size > 0) {
            return peerName
        }
        return "Telegram"
    }

    /**
     * 格式化通知正文（原有签名，向后兼容）
     *
     * @param peerName  peer 显示名称
     * @param messageText 消息文本
     * @param showPreviews 是否展示预览
     * @return 通知正文字符串
     */
    public func formatNotificationBody(peerName: String, messageText: String, showPreviews: Bool): String {
        if (showPreviews && messageText.size > 0) {
            return messageText
        }
        if (peerName.size > 0) {
            return "New message from " + peerName
        }
        return "New message"
    }

    /**
     * 格式化通知正文（P2-260 新版，支持 loc-key 模板）
     *
     * 优先使用 loc-key 模板；退回到 showPreviews/messageText 逻辑
     *
     * @param locKey    PUSH_* loc-key（如 "PUSH_MESSAGE_PHOTO"）；空串=不使用模板
     * @param locArgs   loc-args 位置参数
     * @param peerName  peer 显示名称（fallback）
     * @param messageText 明文消息内容（showPreviews=true 且有内容时直接用）
     * @param showPreviews 是否显示预览
     * @return 通知正文字符串
     */
    public func formatNotificationBodyLocKey(
        locKey: String,
        locArgs: ArrayList<String>,
        peerName: String,
        messageText: String,
        showPreviews: Bool
    ): String {
        if (locKey.size > 0) {
            match (PushMessageTemplates.templateForKey(locKey)) {
                case Some(tmpl) =>
                    let filled = applyPushLocArgs(tmpl, locArgs)
                    let pair = splitPushTitleBody(filled)
                    let body = pair[1]
                    if (body.size > 0) {
                        return body
                    }
                    if (filled.size > 0) {
                        return filled
                    }
                case None => ()
            }
        }
        if (showPreviews && messageText.size > 0) {
            return messageText
        }
        if (peerName.size > 0) {
            return "New message from " + peerName
        }
        return "New message"
    }

    /**
     * 从 loc-key + loc-args 一步格式化完整通知（标题 + 正文）
     *
     * 对应 iOS: alert["title"] + alert["body"] 拆分
     * 调用方通常从推送 payload 的 "loc-key"/"loc-args" 字段获取参数
     *
     * @param locKey  PUSH_* loc-key 字符串
     * @param locArgs 参数列表（%1$@ → args[0]，%2$@ → args[1]，……）
     * @return (title, body) 元组；未命中模板时返回 ("Telegram", "New message")
     */
    public func formatFromLocKey(locKey: String, locArgs: ArrayList<String>): (String, String) {
        match (PushMessageTemplates.templateForKey(locKey)) {
            case Some(tmpl) =>
                let filled = applyPushLocArgs(tmpl, locArgs)
                let pair = splitPushTitleBody(filled)
                let title = pair[0]
                let body = pair[1]
                let resolvedTitle = if (title.size > 0) { title } else { "Telegram" }
                let resolvedBody = if (body.size > 0) { body } else { filled }
                Hilog.info(0, "CjTelegram", "[NPresentationDataService] formatFromLocKey: ${locKey} → title='${resolvedTitle}' body='${resolvedBody}'")
                return (resolvedTitle, resolvedBody)
            case None =>
                Hilog.info(0, "CjTelegram", "[NPresentationDataService] formatFromLocKey: unknown loc-key '${locKey}'")
                return ("Telegram", "New message")
        }
    }

    /**
     * 获取来电通知字符串（incomingCallString，对应 iOS NotificationsPresentationData.incomingCallString）
     *
     * P2-260: 使用 PUSH_PHONE_CALL_REQUEST 模板化，callerName 填充 %1$@
     *
     * @param callerName 来电方显示名称；空串时退回到 "Incoming call"
     * @return 来电通知展示字符串
     */
    public func getIncomingCallString(callerName: String): String {
        if (callerName.size > 0) {
            let args = ArrayList<String>()
            args.add(callerName)
            let pair = this.formatFromLocKey("PUSH_PHONE_CALL_REQUEST", args)
            let body = pair[1]
            if (body.size > 0) {
                return body
            }
        }
        return "Incoming call"
    }

    /**
     * 获取 NotificationsPresentationData（对应 iOS 2 个字符串属性）
     *
     * P2-260: incomingCallString 使用模板化（空 callerName 走默认）
     */
    public func getPresentationData(): NotificationsPresentationData {
        let d = NotificationsPresentationData()
        d.applicationLockedMessageString = "You have a new message"
        d.incomingCallString = this.getIncomingCallString("")
        return d
    }

    /**
     * 判断该 peer 通知是否应被抑制（P2-264 接入点）
     *
     * 调用 NotificationMuteSettingsService.suppressNotificationIfMuted
     * 在展示任何通知前可由通知管线调用
     *
     * @param peerId 通知来源 peer ID
     * @return true = 应抑制；false = 应展示
     */
    public func shouldSuppressForPeer(peerId: Int64): Bool {
        let muteSvc = getNotificationMuteSettingsService()
        return muteSvc.suppressNotificationIfMuted(peerId)
    }
}
