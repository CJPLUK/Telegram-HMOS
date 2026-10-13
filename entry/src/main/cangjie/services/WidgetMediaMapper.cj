package ohos_app_cangjie_entry.services

import ohos_app_cangjie_entry.models.Message
import ohos_app_cangjie_entry.models.Chat
import ohos_app_cangjie_entry.models.WidgetMessageContent
import ohos_app_cangjie_entry.models.WidgetMessageAuthor
import ohos_app_cangjie_entry.models.WidgetMessage
import ohos_app_cangjie_entry.models.WidgetContentImage
import ohos_app_cangjie_entry.models.WidgetContentVideo
import ohos_app_cangjie_entry.models.WidgetContentFile
import ohos_app_cangjie_entry.models.WidgetContentGif
import ohos_app_cangjie_entry.models.WidgetContentMusic
import ohos_app_cangjie_entry.models.WidgetContentVoiceMessage
import ohos_app_cangjie_entry.models.WidgetContentVideoMessage
import ohos_app_cangjie_entry.models.WidgetContentSticker
import ohos_app_cangjie_entry.models.WidgetContentCall
import ohos_app_cangjie_entry.models.WidgetContentMapLocation
import ohos_app_cangjie_entry.models.WidgetContentGame
import ohos_app_cangjie_entry.models.WidgetContentPoll
import ohos_app_cangjie_entry.models.WidgetContentAutodeleteTimer

/**
 * WidgetMediaMapper — P2-432
 *
 * 消息 media 属性 → WidgetMessageContent 14 类型归类
 *
 * 对应 iOS WidgetItemsUtils/Sources/WidgetItemsUtils.swift：
 *   extension WidgetDataPeer.Message { init(accountPeerId:, message: EngineMessage) }
 *   遍历 message.media，按媒体类型归类到 WidgetDataPeer.Message.Content 枚举。
 *
 * 仓颉侧使用 models.Message 的 messageType / documentMimeType / stickerAlt /
 * audioPerformer / audioTitle / audioDuration / isCallMessage / callReason /
 * locationLat / pollQuestion / documentFileName 等字段推断媒体类型。
 *
 * 归类优先级（从 iOS 源推导，file 属性覆盖顺序）：
 *   1. 照片   → messageType == "photo"       → ContentImage
 *   2. 文件   → messageType == "file"/"document"：
 *      a. sticker   → documentMimeType == "application/x-tgsticker" 或 "image/webp"，stickerAlt != ""
 *                   → ContentSticker(altText)
 *      b. videoNote → documentMimeType == "video/mp4"，documentFileName 含 "round"
 *                   → ContentVideoMessage(videoDuration)
 *      c. video     → documentMimeType 以 "video/" 开头（非 videoNote）
 *                   → ContentVideo
 *      d. voice     → documentMimeType == "audio/ogg" 且 audioDuration > 0
 *                   → ContentVoiceMessage(audioDuration)
 *      e. music     → documentMimeType 以 "audio/" 开头（非 voice）
 *                   → ContentMusic(artist, title, duration)
 *      f. gif       → documentMimeType == "video/mp4" 且 documentFileName 含 "animation"
 *                   → ContentGif
 *      g. fallback  → ContentFile(documentFileName)
 *   3. 通话   → messageType == "call" / isCallMessage == true → ContentCall(isVideo)
 *   4. 位置   → messageType == "map"/"location" → ContentMapLocation
 *   5. 投票   → messageType == "poll" → ContentPoll(question)
 *   6. 游戏   → messageType == "game" → ContentGame(title)
 *   7. 自动删除 → messageType == "autoDeleteTimer" → ContentAutodeleteTimer
 *   8. 默认   → ContentText
 *
 * 群消息 author 归属（iOS: message.peers[peerId] is TelegramGroup/TelegramChannel.group）：
 *   isGroup == true → 从 lastMessageSenderName 构造 Author；
 *   isMe = (lastMessageSenderName == "You" 或 lastMessageOutgoing == true)
 *
 * 调用方：WidgetItemsServiceV2.buildWidgetMessage(chat, msg)
 */
public func mapMessageToWidgetContent(msg: Message): WidgetMessageContent {
    let mtype = msg.messageType

    if (mtype == "photo" || msg.photoId != 0) {
        return WidgetMessageContent.ContentImage(WidgetContentImage())
    }

    if (mtype == "call" || msg.isCallMessage) {
        let isVideo = (msg.callReason == "video" || mtype == "videoCall")
        return WidgetMessageContent.ContentCall(WidgetContentCall(isVideo: isVideo))
    }

    if (mtype == "map" || mtype == "location") {
        return WidgetMessageContent.ContentMapLocation(WidgetContentMapLocation())
    }

    if (mtype == "poll") {
        return WidgetMessageContent.ContentPoll(WidgetContentPoll(title: msg.pollQuestion))
    }

    if (mtype == "game") {
        return WidgetMessageContent.ContentGame(WidgetContentGame(title: msg.webPageTitle))
    }

    if (mtype == "autoDeleteTimer") {
        return WidgetMessageContent.ContentAutodeleteTimer(
            WidgetContentAutodeleteTimer(value: 0, hasValue: false))
    }

    if (mtype == "file" || mtype == "document" || msg.documentId != 0) {
        return classifyFileContent(msg)
    }

    if (mtype == "sticker") {
        return WidgetMessageContent.ContentSticker(WidgetContentSticker(altText: msg.stickerAlt))
    }

    if (mtype == "video" || mtype == "videoNote" || mtype == "round") {
        if (mtype == "videoNote" || mtype == "round") {
            return WidgetMessageContent.ContentVideoMessage(
                WidgetContentVideoMessage(duration: msg.videoDuration))
        }
        return WidgetMessageContent.ContentVideo(WidgetContentVideo())
    }

    if (mtype == "audio" || mtype == "voice") {
        if (mtype == "voice") {
            return WidgetMessageContent.ContentVoiceMessage(
                WidgetContentVoiceMessage(duration: msg.audioDuration))
        }
        return WidgetMessageContent.ContentMusic(
            WidgetContentMusic(
                artist: msg.audioPerformer,
                title: if (msg.audioTitle.size > 0) { msg.audioTitle } else { "Unknown" },
                duration: msg.audioDuration))
    }

    if (mtype == "gif" || mtype == "animation") {
        return WidgetMessageContent.ContentGif(WidgetContentGif())
    }

    return WidgetMessageContent.ContentText
}

/**
 * 细分 file/document 类型（对应 iOS WidgetItemsUtils 的 TelegramMediaFile 属性遍历）
 *
 * iOS 顺序：先 FileName → file；再逐 attribute：
 *   Sticker → sticker; Video(instantRoundVideo) → videoMessage; Video → video;
 *   Audio(isVoice) → voiceMessage; Audio(music) → music
 *
 * 本函数用 documentMimeType 和字段信号推断：
 */
private func classifyFileContent(msg: Message): WidgetMessageContent {
    let mime = msg.documentMimeType
    let fname = msg.documentFileName

    // Sticker: mime application/x-tgsticker, image/webp, or stickerAlt set
    if (msg.stickerAlt.size > 0) {
        return WidgetMessageContent.ContentSticker(WidgetContentSticker(altText: msg.stickerAlt))
    }
    if (mime == "application/x-tgsticker" || mime == "image/webp") {
        return WidgetMessageContent.ContentSticker(WidgetContentSticker(altText: ""))
    }

    // Video message (round/instant): mp4 + documentFileName contains "round"
    if (mime == "video/mp4" && (strContains(fname, "round") || strContains(fname, "videoNote"))) {
        return WidgetMessageContent.ContentVideoMessage(
            WidgetContentVideoMessage(duration: msg.videoDuration))
    }

    // Animation/GIF: mp4 + "animation" in filename, or mime video/mp4 with 0 duration
    if (mime == "video/mp4" && strContains(fname, "animation")) {
        return WidgetMessageContent.ContentGif(WidgetContentGif())
    }

    // Video: any video/* mime
    if (strStartsWith(mime, "video/")) {
        return WidgetMessageContent.ContentVideo(WidgetContentVideo())
    }

    // Voice: audio/ogg
    if (mime == "audio/ogg") {
        return WidgetMessageContent.ContentVoiceMessage(
            WidgetContentVoiceMessage(duration: msg.audioDuration))
    }

    // Music: any audio/*
    if (strStartsWith(mime, "audio/")) {
        return WidgetMessageContent.ContentMusic(
            WidgetContentMusic(
                artist: msg.audioPerformer,
                title: if (msg.audioTitle.size > 0) { msg.audioTitle } else { fname },
                duration: msg.audioDuration))
    }

    // fallback: generic file
    return WidgetMessageContent.ContentFile(
        WidgetContentFile(name: if (fname.size > 0) { fname } else { "file" }))
}

/**
 * 构造 WidgetMessage（含媒体归类 + 群 author 归属）
 *
 * @param chat         会话模型（含 isGroup / isSavedMessages / lastMessageSenderName）
 * @param msg          消息模型
 * @param accountPeerId 当前账号的 peerId（用于判断 isMe）
 */
public func buildWidgetMessage(chat: Chat, msg: Message, accountPeerId: Int64): WidgetMessage {
    let content = mapMessageToWidgetContent(msg)

    var author: Option<WidgetMessageAuthor> = None
    if (chat.isGroup || chat.isMegagroup) {
        let senderName = chat.lastMessageSenderName
        if (senderName.size > 0) {
            let isMe = msg.isSent || senderName == "You" || msg.senderId == accountPeerId
            author = Some(WidgetMessageAuthor(isMe: isMe, title: if (isMe) { "You" } else { senderName }))
        }
    }

    return WidgetMessage(
        author: author,
        text: msg.content,
        content: content,
        timestamp: Int32(msg.rawTimestamp))
}

// ============================================================
// 字符串工具（R-101: String 无 hasSuffix/startsWith）
// ============================================================

private func strContains(s: String, sub: String): Bool {
    return s.contains(sub)
}

private func strStartsWith(s: String, prefix: String): Bool {
    if (prefix.size == 0) { return true }
    if (s.size < prefix.size) { return false }
    return s[0..prefix.size] == prefix
}
