package ohos_app_cangjie_entry.core.storage.postbox

import ohos_app_cangjie_entry.models.{Message, ReactionData, PollOptionData, TextEntityData}
import ohos_app_cangjie_entry.utils.formatClockHHMM
import std.collection.ArrayList

/**
 * IntermediateMessage —— 消息的"落盘中间表示"。
 *
 * iOS 标尺：
 *   - Telegram-iOS/submodules/Postbox/Sources/IntermediateMessage.swift（落盘字段集）
 *   - MessageHistoryTable.swift 的 justInsertMessage / readIntermediateEntry（编解码侧）
 *
 * iOS 的 IntermediateMessage 是 Postbox DB 里消息的紧凑表示：核心标量字段直接落，
 * 复杂结构（媒体 embeddedMediaData / 属性 attributesData / referencedMedia）以"字节 blob"
 * 透传，等读出后再由上层按需解析。本单元在仓颉侧对齐这一分层：
 *
 *   - 标量身份/内容字段：peerId / namespace / id / timestamp / flags / authorId / text
 *     按 key 用 PostboxEncoder 落盘、PostboxDecoder 对称读回。
 *   - 媒体 / 附加数据：embeddedMediaData / attributesData 两个字节 blob 原样透传
 *     （把复杂媒体序列化成 bytes 存，不在本单元解析媒体结构）。
 *
 * P2-287g 扩展：fromMessage/toMessage 现在完整往返 Message 的媒体/回复/reactions/转发字段：
 *   - embeddedMediaData：照片 + 文档/视频/语音/贴纸/webPage + 位置 + 通话 + 投票 字段集合
 *   - attributesData：回复 + 转发来源 + 状态标记 + reactions + 富文本实体 字段集合
 *
 * 序列化层：统一使用项目既有的 PostboxEncoder/PostboxDecoder（keyed 二进制格式），
 * 与 PostboxCoding.cj / MemoryBuffer.cj 同一编解码层，保证按 key 定位、字段可增删兼容。
 * 集合类型（reactions / pollOptions / textEntityList）序列化为 count(Int32) + 各项 bytes blob。
 *
 * 旧缓存兼容：embeddedMediaData/attributesData 为空时（旧缓存），toMessage 静默回落到默认值，
 * 不抛异常。
 *
 * 与 iOS 不同点：本单元不复刻 iOS 的"裸定位二进制布局"（justInsertMessage 里手写 offset 的
 * sharedBuffer.write），而是统一用工程已合入的 keyed PostboxCoding（encode*ForKey），与
 * PostboxCoding.cj / MemoryBuffer.cj 同一编解码层，保证按 key 定位、字段可增删兼容。
 *
 * 显式不落（out-of-scope，对齐 iOS 字段但本单元不持久化，留待后续单元）：
 *   groupInfo / groupingKey / globallyUniqueId / threadId / tags / globalTags / localTags /
 *   customTags / referencedMedia / readState / holes。
 * 这些是跨表联动/索引字段，落盘需要相邻表（globallyUniqueMessageIdsTable 等）配合，
 *  不属于本单元"单条消息核心子集"职责。
 * 分组显示标记（isFirstInGroup / isLastInGroup / isMiddleInGroup / isSingleMessage /
 *   showDateSeparator / dateSeparatorText）为纯 UI 派生字段，由 ViewModel 重算，不落盘。
 */
public class IntermediateMessage {
    // ==================== 身份 ====================
    // 会话标识与消息命名空间。Message 模型当前为扁平结构、不含 peerId/namespace，
    // 故这两字段由调用方在 fromMessage 时显式提供（默认 0），落盘表示独立保留。
    public var peerId: Int64 = 0
    public var namespace: Int32 = 0
    public var id: Int64 = 0

    // ==================== 核心标量 ====================
    public var timestamp: Int64 = 0
    public var flags: Int32 = 0
    // authorId 即发送者（iOS authorId / 工程 Message.senderId）。
    public var authorId: Int64 = 0
    public var text: String = ""
    // 消息类型（工程 Message.messageType，如 "text"/"photo"…），落盘以便读回还原 Message。
    public var messageType: String = "text"

    // ==================== 字节透传（媒体 / 附加数据）====================
    // 对齐 iOS embeddedMediaData / attributesData：复杂媒体与属性序列化为 bytes blob 原样存取。
    // P2-287g：fromMessage 将 Message 的媒体/回复/reactions/转发字段序列化进这两个 blob；
    //          toMessage 从 blob 还原，blob 为空时静默回落默认值（旧缓存兼容）。
    public var embeddedMediaData: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var attributesData: Array<Byte> = Array<Byte>(0, repeat: 0)

    public init() {}

    // ==================== PostboxCoding key 常量 ====================
    // 集中声明，保证 encode/decode 两侧 key 字符串严格一致（手写易漂移）。
    private static let KEY_PEER_ID = "p"
    private static let KEY_NAMESPACE = "n"
    private static let KEY_ID = "i"
    private static let KEY_TIMESTAMP = "t"
    private static let KEY_FLAGS = "f"
    private static let KEY_AUTHOR_ID = "a"
    private static let KEY_TEXT = "tx"
    private static let KEY_MESSAGE_TYPE = "mt"
    private static let KEY_EMBEDDED_MEDIA = "em"
    private static let KEY_ATTRIBUTES = "at"

    // ---- embeddedMediaData 内部 key (照片) ----
    private static let EM_PHOTO_ID = "pi"
    private static let EM_PHOTO_ACCESS_HASH = "pa"
    private static let EM_PHOTO_FILE_REF = "pf"
    private static let EM_PHOTO_DC_ID = "pd"
    private static let EM_PHOTO_WIDTH = "pw"
    private static let EM_PHOTO_HEIGHT = "ph"
    private static let EM_PHOTO_FILE_SIZE = "ps"
    // iOS persists every TelegramMediaImageRepresentation (dimensions + concrete resource).
    // Harmony currently flattens that model to the selected TL photo-size type, so that type
    // must be persisted as well; otherwise history restored from Postbox guesses "y" and may
    // request a representation that the photo does not have.
    private static let EM_PHOTO_LARGEST_TYPE = "pl"
    private static let EM_STRIPPED_THUMB = "pt"
    private static let EM_PHOTO_LOCAL_PATH = "pp"
    // ---- embeddedMediaData 内部 key (文档/视频/语音/贴纸) ----
    private static let EM_DOC_ID = "di"
    private static let EM_DOC_ACCESS_HASH = "da"
    private static let EM_DOC_FILE_REF = "df"
    private static let EM_DOC_DC_ID = "dd"
    private static let EM_DOC_SIZE = "ds"
    private static let EM_DOC_MIME = "dm"
    private static let EM_DOC_FILE_NAME = "dn"
    private static let EM_VIDEO_DURATION = "vd"
    private static let EM_VIDEO_WIDTH = "vw"
    private static let EM_VIDEO_HEIGHT = "vh"
    private static let EM_AUDIO_DURATION = "ad"
    private static let EM_AUDIO_TITLE = "atl"
    private static let EM_AUDIO_PERFORMER = "apr"
    private static let EM_AUDIO_WAVEFORM = "awf"
    private static let EM_STICKER_ALT = "sa"
    private static let EM_DOC_LOCAL_PATH = "dlp"
    private static let EM_DOC_THUMB_PATH = "dtp"
    // ---- embeddedMediaData 内部 key (webPage) ----
    private static let EM_WEB_URL = "wu"
    private static let EM_WEB_SITE = "ws"
    private static let EM_WEB_TITLE = "wt"
    private static let EM_WEB_DESC = "wd"
    private static let EM_WEB_PHOTO_ID = "wpi"
    private static let EM_WEB_PHOTO_AH = "wpa"
    private static let EM_WEB_PHOTO_REF = "wpf"
    private static let EM_WEB_PHOTO_DC = "wpd"
    private static let EM_WEB_PHOTO_WIDTH = "wpw"
    private static let EM_WEB_PHOTO_HEIGHT = "wph"
    private static let EM_WEB_PHOTO_LOCAL = "wpl"
    // ---- embeddedMediaData 内部 key (位置) ----
    private static let EM_LOC_LAT = "ll"
    private static let EM_LOC_LNG = "lg"
    private static let EM_IS_LIVE = "il"
    private static let EM_LIVE_PERIOD = "lp"
    // ---- embeddedMediaData 内部 key (通话) ----
    private static let EM_IS_CALL = "ic"
    private static let EM_CALL_DUR = "cd"
    private static let EM_CALL_REASON = "cr"
    private static let EM_SERVICE_TEXT = "svc"
    private static let EM_HIDDEN_IN_HISTORY = "hih"
    // ---- embeddedMediaData 内部 key (投票) ----
    private static let EM_POLL_ID = "oi"
    private static let EM_POLL_QUESTION = "oq"
    private static let EM_POLL_CLOSED = "oc"
    private static let EM_POLL_QUIZ = "oz"
    private static let EM_POLL_MULTI = "om"
    private static let EM_POLL_TOTAL = "ot"
    private static let EM_POLL_SOLUTION = "os"
    private static let EM_POLL_OPT_COUNT = "on"
    // ---- embeddedMediaData 内部 key (Bot invoice) ----
    private static let EM_INVOICE_TITLE = "it"
    private static let EM_INVOICE_DESC = "ix"
    private static let EM_INVOICE_CURRENCY = "icu"
    private static let EM_INVOICE_TOTAL = "iam"
    private static let EM_INVOICE_START = "isp"
    private static let EM_INVOICE_RECEIPT = "irm"
    private static let EM_INVOICE_BUTTON = "ibt"
    // 投票选项内部 key（每项 PostboxEncoder 子编码 blob）
    private static let PO_TEXT = "t"
    private static let PO_VOTERS = "v"
    private static let PO_CHOSEN = "c"
    private static let PO_CORRECT = "k"
    private static let PO_PCT = "p"
    private static let PO_OPT_DATA = "d"

    // ---- attributesData 内部 key (回复) ----
    private static let AT_REPLY_TO_ID = "ri"
    private static let AT_REPLY_TEXT = "rt"
    private static let AT_REPLY_SENDER = "rs"
    // ---- attributesData 内部 key (转发) ----
    private static let AT_FWD_FROM = "ff"
    // ---- attributesData 内部 key (状态标记) ----
    private static let AT_IS_EDITED = "ie"
    private static let AT_IS_PINNED = "ip"
    private static let AT_VIEWS = "vw"
    private static let AT_IS_SENT = "is"
    private static let AT_STATUS = "st"
    private static let AT_SENDER_NAME = "sn"
    private static let AT_SENDER_PEER_TYPE = "sp"
    private static let AT_SENDER_ROLE = "sr"
    private static let AT_MEDIA_DESC = "md"
    private static let AT_EDIT_DATE = "ed"
    // ---- attributesData 内部 key (reactions) ----
    private static let AT_REACT_COUNT = "rc"
    // reaction 每项内部 key
    private static let RD_EMOJI = "e"
    private static let RD_COUNT = "c"
    private static let RD_SELECTED = "s"
    private static let RD_INITIALS = "i"
    private static let RD_PEER_COUNT = "pn"
    private static let RD_PEER_ID_PREFIX = "pi"
    private static let RD_AVATAR_PREFIX = "pa"
    private static let RD_INITIALS_PREFIX = "pl"
    // ---- attributesData 内部 key (文本实体) ----
    private static let AT_TE_STR = "ts"
    private static let AT_TE_COUNT = "tc"
    // 文本实体每项内部 key
    private static let TE_TYPE = "t"
    private static let TE_OFFSET = "o"
    private static let TE_LENGTH = "l"
    private static let TE_URL = "u"
    private static let TE_CUSTOM_EMOJI_DOC_ID = "d"

    /**
     * 按 key 把各字段写入编码器（对齐 iOS justInsertMessage 的字段落盘集，但走 keyed 格式）。
     */
    public func encode(encoder: PostboxEncoder): Unit {
        encoder.encodeInt64(this.peerId, key: IntermediateMessage.KEY_PEER_ID)
        encoder.encodeInt32(this.namespace, key: IntermediateMessage.KEY_NAMESPACE)
        encoder.encodeInt64(this.id, key: IntermediateMessage.KEY_ID)
        encoder.encodeInt64(this.timestamp, key: IntermediateMessage.KEY_TIMESTAMP)
        encoder.encodeInt32(this.flags, key: IntermediateMessage.KEY_FLAGS)
        encoder.encodeInt64(this.authorId, key: IntermediateMessage.KEY_AUTHOR_ID)
        encoder.encodeString(this.text, key: IntermediateMessage.KEY_TEXT)
        encoder.encodeString(this.messageType, key: IntermediateMessage.KEY_MESSAGE_TYPE)
        encoder.encodeBytes(this.embeddedMediaData, key: IntermediateMessage.KEY_EMBEDDED_MEDIA)
        encoder.encodeBytes(this.attributesData, key: IntermediateMessage.KEY_ATTRIBUTES)
    }

    /**
     * 从解码器对称读回（对齐 iOS readIntermediateEntry 的读侧）。
     * 缺失字段回落到与默认值一致的 orElse，保证向后兼容（新增字段读旧数据不崩）。
     */
    public static func decode(decoder: PostboxDecoder): IntermediateMessage {
        let m = IntermediateMessage()
        m.peerId = decoder.decodeInt64(IntermediateMessage.KEY_PEER_ID, orElse: 0)
        m.namespace = decoder.decodeInt32(IntermediateMessage.KEY_NAMESPACE, orElse: 0)
        m.id = decoder.decodeInt64(IntermediateMessage.KEY_ID, orElse: 0)
        m.timestamp = decoder.decodeInt64(IntermediateMessage.KEY_TIMESTAMP, orElse: 0)
        m.flags = decoder.decodeInt32(IntermediateMessage.KEY_FLAGS, orElse: 0)
        m.authorId = decoder.decodeInt64(IntermediateMessage.KEY_AUTHOR_ID, orElse: 0)
        m.text = decoder.decodeString(IntermediateMessage.KEY_TEXT, orElse: "")
        m.messageType = decoder.decodeString(IntermediateMessage.KEY_MESSAGE_TYPE, orElse: "text")
        m.embeddedMediaData = decoder.decodeBytes(
            IntermediateMessage.KEY_EMBEDDED_MEDIA, orElse: Array<Byte>(0, repeat: 0))
        m.attributesData = decoder.decodeBytes(
            IntermediateMessage.KEY_ATTRIBUTES, orElse: Array<Byte>(0, repeat: 0))
        return m
    }

    /**
     * 便捷：直接编码成字节流。
     */
    public func encodeToBytes(): Array<Byte> {
        let encoder = PostboxEncoder()
        this.encode(encoder)
        return encoder.makeBytes()
    }

    /**
     * 便捷：从字节流解码。
     */
    public static func decodeFromBytes(data: Array<Byte>): IntermediateMessage {
        return IntermediateMessage.decode(PostboxDecoder(data))
    }

    // ==================== 媒体 blob 序列化辅助 ====================

    /**
     * 将投票选项（PollOptionData）序列化为 bytes blob。
     */
    private static func encodePollOption(opt: PollOptionData): Array<Byte> {
        let enc = PostboxEncoder()
        enc.encodeString(opt.text, key: IntermediateMessage.PO_TEXT)
        enc.encodeInt32(opt.voters, key: IntermediateMessage.PO_VOTERS)
        enc.encodeBool(opt.chosen, key: IntermediateMessage.PO_CHOSEN)
        enc.encodeBool(opt.correct, key: IntermediateMessage.PO_CORRECT)
        enc.encodeInt32(opt.percentage, key: IntermediateMessage.PO_PCT)
        enc.encodeBytes(opt.optionData, key: IntermediateMessage.PO_OPT_DATA)
        return enc.makeBytes()
    }

    /**
     * 从 bytes blob 还原 PollOptionData。
     */
    private static func decodePollOption(data: Array<Byte>): PollOptionData {
        let dec = PostboxDecoder(data)
        let opt = PollOptionData()
        opt.text = dec.decodeString(IntermediateMessage.PO_TEXT, orElse: "")
        opt.voters = dec.decodeInt32(IntermediateMessage.PO_VOTERS, orElse: 0)
        opt.chosen = dec.decodeBool(IntermediateMessage.PO_CHOSEN, orElse: false)
        opt.correct = dec.decodeBool(IntermediateMessage.PO_CORRECT, orElse: false)
        opt.percentage = dec.decodeInt32(IntermediateMessage.PO_PCT, orElse: 0)
        opt.optionData = dec.decodeBytes(IntermediateMessage.PO_OPT_DATA, orElse: Array<Byte>(0, repeat: 0))
        return opt
    }

    /**
     * 将单个 ReactionData 序列化为 bytes blob。
     */
    private static func encodeReaction(r: ReactionData): Array<Byte> {
        let enc = PostboxEncoder()
        enc.encodeString(r.emoji, key: IntermediateMessage.RD_EMOJI)
        enc.encodeInt64(r.count, key: IntermediateMessage.RD_COUNT)
        enc.encodeBool(r.isSelected, key: IntermediateMessage.RD_SELECTED)
        enc.encodeString(r.peerInitials, key: IntermediateMessage.RD_INITIALS)
        let peerCount = if (r.peerIds.size > 3) { 3 } else { r.peerIds.size }
        enc.encodeInt32(Int32(peerCount), key: IntermediateMessage.RD_PEER_COUNT)
        for (idx in 0..peerCount) {
            enc.encodeInt64(r.peerIds[idx], key: IntermediateMessage.RD_PEER_ID_PREFIX + IntermediateMessage.indexKey(idx))
            let avatarPath = if (idx < r.peerAvatarPaths.size) { r.peerAvatarPaths[idx] } else { "" }
            let initials = if (idx < r.peerInitialsList.size) { r.peerInitialsList[idx] } else { "?" }
            enc.encodeString(avatarPath, key: IntermediateMessage.RD_AVATAR_PREFIX + IntermediateMessage.indexKey(idx))
            enc.encodeString(initials, key: IntermediateMessage.RD_INITIALS_PREFIX + IntermediateMessage.indexKey(idx))
        }
        return enc.makeBytes()
    }

    /**
     * 从 bytes blob 还原 ReactionData。
     */
    private static func decodeReaction(data: Array<Byte>): ReactionData {
        let dec = PostboxDecoder(data)
        let r = ReactionData()
        r.emoji = dec.decodeString(IntermediateMessage.RD_EMOJI, orElse: "")
        r.count = dec.decodeInt64(IntermediateMessage.RD_COUNT, orElse: 0)
        r.isSelected = dec.decodeBool(IntermediateMessage.RD_SELECTED, orElse: false)
        r.peerInitials = dec.decodeString(IntermediateMessage.RD_INITIALS, orElse: "")
        let storedPeerCount = dec.decodeInt32(IntermediateMessage.RD_PEER_COUNT, orElse: 0)
        let peerCount = if (storedPeerCount < 0) { Int32(0) } else if (storedPeerCount > 3) { Int32(3) } else { storedPeerCount }
        for (idx in 0..Int64(peerCount)) {
            r.peerIds.add(dec.decodeInt64(
                IntermediateMessage.RD_PEER_ID_PREFIX + IntermediateMessage.indexKey(idx), orElse: 0))
            r.peerAvatarPaths.add(dec.decodeString(
                IntermediateMessage.RD_AVATAR_PREFIX + IntermediateMessage.indexKey(idx), orElse: ""))
            r.peerInitialsList.add(dec.decodeString(
                IntermediateMessage.RD_INITIALS_PREFIX + IntermediateMessage.indexKey(idx), orElse: "?"))
        }
        return r
    }

    /**
     * 将单个 TextEntityData 序列化为 bytes blob。
     */
    private static func encodeTextEntity(e: TextEntityData): Array<Byte> {
        let enc = PostboxEncoder()
        enc.encodeString(e.entityType, key: IntermediateMessage.TE_TYPE)
        enc.encodeInt32(e.offset, key: IntermediateMessage.TE_OFFSET)
        enc.encodeInt32(e.length, key: IntermediateMessage.TE_LENGTH)
        enc.encodeString(e.url, key: IntermediateMessage.TE_URL)
        enc.encodeInt64(e.customEmojiDocumentId, key: IntermediateMessage.TE_CUSTOM_EMOJI_DOC_ID)
        return enc.makeBytes()
    }

    /**
     * 从 bytes blob 还原 TextEntityData。
     */
    private static func decodeTextEntity(data: Array<Byte>): TextEntityData {
        let dec = PostboxDecoder(data)
        let e = TextEntityData()
        e.entityType = dec.decodeString(IntermediateMessage.TE_TYPE, orElse: "")
        e.offset = dec.decodeInt32(IntermediateMessage.TE_OFFSET, orElse: 0)
        e.length = dec.decodeInt32(IntermediateMessage.TE_LENGTH, orElse: 0)
        e.url = dec.decodeString(IntermediateMessage.TE_URL, orElse: "")
        e.customEmojiDocumentId = dec.decodeInt64(IntermediateMessage.TE_CUSTOM_EMOJI_DOC_ID, orElse: 0)
        return e
    }

    /**
     * 把 Int32 index 转为 key 字符串（集合项索引 key，如 "0","1",…,"99"）。
     * 最多支持 100 项（key 长度约束 127 byte，2 位数字绰绰有余）。
     */
    private static func indexKey(i: Int64): String {
        return i.toString()
    }

    /**
     * 序列化 Message 的媒体/位置/通话/投票字段 → embeddedMediaData blob。
     * 只在 Message 有实质内容时序列化（所有媒体字段均为零/空 → 空 blob，减少存储）。
     */
    private static func buildEmbeddedMediaData(m: Message): Array<Byte> {
        let enc = PostboxEncoder()
        // -- 照片 --
        enc.encodeInt64(m.photoId, key: IntermediateMessage.EM_PHOTO_ID)
        enc.encodeInt64(m.photoAccessHash, key: IntermediateMessage.EM_PHOTO_ACCESS_HASH)
        enc.encodeBytes(m.photoFileReference, key: IntermediateMessage.EM_PHOTO_FILE_REF)
        enc.encodeInt32(m.photoDcId, key: IntermediateMessage.EM_PHOTO_DC_ID)
        enc.encodeInt32(m.photoWidth, key: IntermediateMessage.EM_PHOTO_WIDTH)
        enc.encodeInt32(m.photoHeight, key: IntermediateMessage.EM_PHOTO_HEIGHT)
        enc.encodeInt32(m.photoFileSize, key: IntermediateMessage.EM_PHOTO_FILE_SIZE)
        enc.encodeString(m.photoLargestType, key: IntermediateMessage.EM_PHOTO_LARGEST_TYPE)
        enc.encodeBytes(m.strippedThumb, key: IntermediateMessage.EM_STRIPPED_THUMB)
        enc.encodeString(m.photoLocalPath, key: IntermediateMessage.EM_PHOTO_LOCAL_PATH)
        // -- 文档/视频/语音/贴纸 --
        enc.encodeInt64(m.documentId, key: IntermediateMessage.EM_DOC_ID)
        enc.encodeInt64(m.documentAccessHash, key: IntermediateMessage.EM_DOC_ACCESS_HASH)
        enc.encodeBytes(m.documentFileReference, key: IntermediateMessage.EM_DOC_FILE_REF)
        enc.encodeInt32(m.documentDcId, key: IntermediateMessage.EM_DOC_DC_ID)
        enc.encodeInt64(m.documentSize, key: IntermediateMessage.EM_DOC_SIZE)
        enc.encodeString(m.documentMimeType, key: IntermediateMessage.EM_DOC_MIME)
        enc.encodeString(m.documentFileName, key: IntermediateMessage.EM_DOC_FILE_NAME)
        enc.encodeInt32(m.videoDuration, key: IntermediateMessage.EM_VIDEO_DURATION)
        enc.encodeInt32(m.videoWidth, key: IntermediateMessage.EM_VIDEO_WIDTH)
        enc.encodeInt32(m.videoHeight, key: IntermediateMessage.EM_VIDEO_HEIGHT)
        enc.encodeInt32(m.audioDuration, key: IntermediateMessage.EM_AUDIO_DURATION)
        enc.encodeString(m.audioTitle, key: IntermediateMessage.EM_AUDIO_TITLE)
        enc.encodeString(m.audioPerformer, key: IntermediateMessage.EM_AUDIO_PERFORMER)
        enc.encodeBytes(m.audioWaveform, key: IntermediateMessage.EM_AUDIO_WAVEFORM)
        enc.encodeString(m.stickerAlt, key: IntermediateMessage.EM_STICKER_ALT)
        enc.encodeString(m.documentLocalPath, key: IntermediateMessage.EM_DOC_LOCAL_PATH)
        enc.encodeString(m.documentThumbnailPath, key: IntermediateMessage.EM_DOC_THUMB_PATH)
        // -- webPage --
        enc.encodeString(m.webPageUrl, key: IntermediateMessage.EM_WEB_URL)
        enc.encodeString(m.webPageSiteName, key: IntermediateMessage.EM_WEB_SITE)
        enc.encodeString(m.webPageTitle, key: IntermediateMessage.EM_WEB_TITLE)
        enc.encodeString(m.webPageDescription, key: IntermediateMessage.EM_WEB_DESC)
        enc.encodeInt64(m.webPagePhotoId, key: IntermediateMessage.EM_WEB_PHOTO_ID)
        enc.encodeInt64(m.webPagePhotoAccessHash, key: IntermediateMessage.EM_WEB_PHOTO_AH)
        enc.encodeBytes(m.webPagePhotoFileReference, key: IntermediateMessage.EM_WEB_PHOTO_REF)
        enc.encodeInt32(m.webPagePhotoDcId, key: IntermediateMessage.EM_WEB_PHOTO_DC)
        enc.encodeInt32(m.webPagePhotoWidth, key: IntermediateMessage.EM_WEB_PHOTO_WIDTH)
        enc.encodeInt32(m.webPagePhotoHeight, key: IntermediateMessage.EM_WEB_PHOTO_HEIGHT)
        enc.encodeString(m.webPagePhotoLocalPath, key: IntermediateMessage.EM_WEB_PHOTO_LOCAL)
        // -- 位置 --
        enc.encodeDouble(m.locationLat, key: IntermediateMessage.EM_LOC_LAT)
        enc.encodeDouble(m.locationLng, key: IntermediateMessage.EM_LOC_LNG)
        enc.encodeBool(m.isLiveLocation, key: IntermediateMessage.EM_IS_LIVE)
        enc.encodeInt32(m.liveLocationPeriod, key: IntermediateMessage.EM_LIVE_PERIOD)
        // -- 通话 --
        enc.encodeBool(m.isCallMessage, key: IntermediateMessage.EM_IS_CALL)
        enc.encodeInt32(m.callDuration, key: IntermediateMessage.EM_CALL_DUR)
        enc.encodeString(m.callReason, key: IntermediateMessage.EM_CALL_REASON)
        // -- 服务消息文案（本地优先渲染时也要有真实动作文本）--
        enc.encodeString(m.serviceText, key: IntermediateMessage.EM_SERVICE_TEXT)
        enc.encodeBool(m.hiddenInHistory, key: IntermediateMessage.EM_HIDDEN_IN_HISTORY)
        // -- 投票 --
        enc.encodeInt64(m.pollId, key: IntermediateMessage.EM_POLL_ID)
        enc.encodeString(m.pollQuestion, key: IntermediateMessage.EM_POLL_QUESTION)
        enc.encodeBool(m.pollClosed, key: IntermediateMessage.EM_POLL_CLOSED)
        enc.encodeBool(m.pollQuiz, key: IntermediateMessage.EM_POLL_QUIZ)
        enc.encodeBool(m.pollMultipleChoice, key: IntermediateMessage.EM_POLL_MULTI)
        enc.encodeInt32(m.pollTotalVoters, key: IntermediateMessage.EM_POLL_TOTAL)
        enc.encodeString(m.pollSolution, key: IntermediateMessage.EM_POLL_SOLUTION)
        let pollOptCount = if (m.pollOptions.size > 100) { 100 } else { m.pollOptions.size }
        enc.encodeInt32(Int32(pollOptCount), key: IntermediateMessage.EM_POLL_OPT_COUNT)
        for (idx in 0..pollOptCount) {
            let optOpt = m.pollOptions.get(idx)
            if (optOpt.isSome()) {
                enc.encodeBytes(IntermediateMessage.encodePollOption(optOpt.getOrThrow()),
                    key: IntermediateMessage.indexKey(idx))
            }
        }
        // -- Bot invoice --
        enc.encodeString(m.invoiceTitle, key: IntermediateMessage.EM_INVOICE_TITLE)
        enc.encodeString(m.invoiceDescription, key: IntermediateMessage.EM_INVOICE_DESC)
        enc.encodeString(m.invoiceCurrency, key: IntermediateMessage.EM_INVOICE_CURRENCY)
        enc.encodeInt64(m.invoiceTotalAmount, key: IntermediateMessage.EM_INVOICE_TOTAL)
        enc.encodeString(m.invoiceStartParam, key: IntermediateMessage.EM_INVOICE_START)
        enc.encodeInt32(m.invoiceReceiptMsgId, key: IntermediateMessage.EM_INVOICE_RECEIPT)
        enc.encodeString(m.invoicePaymentButtonTitle, key: IntermediateMessage.EM_INVOICE_BUTTON)
        return enc.makeBytes()
    }

    /**
     * 从 embeddedMediaData blob 还原 Message 的媒体/位置/通话/投票字段。
     * blob 为空时静默回落到 Message 默认值（旧缓存兼容）。
     */
    private static func restoreEmbeddedMediaData(data: Array<Byte>, m: Message): Unit {
        if (data.size == 0) {
            return
        }
        let dec = PostboxDecoder(data)
        // -- 照片 --
        m.photoId = dec.decodeInt64(IntermediateMessage.EM_PHOTO_ID, orElse: 0)
        m.photoAccessHash = dec.decodeInt64(IntermediateMessage.EM_PHOTO_ACCESS_HASH, orElse: 0)
        m.photoFileReference = dec.decodeBytes(IntermediateMessage.EM_PHOTO_FILE_REF,
            orElse: Array<Byte>(0, repeat: 0))
        m.photoDcId = dec.decodeInt32(IntermediateMessage.EM_PHOTO_DC_ID, orElse: 0)
        m.photoWidth = dec.decodeInt32(IntermediateMessage.EM_PHOTO_WIDTH, orElse: 0)
        m.photoHeight = dec.decodeInt32(IntermediateMessage.EM_PHOTO_HEIGHT, orElse: 0)
        m.photoFileSize = dec.decodeInt32(IntermediateMessage.EM_PHOTO_FILE_SIZE, orElse: 0)
        m.photoLargestType = dec.decodeString(IntermediateMessage.EM_PHOTO_LARGEST_TYPE, orElse: "")
        m.strippedThumb = dec.decodeBytes(IntermediateMessage.EM_STRIPPED_THUMB,
            orElse: Array<Byte>(0, repeat: 0))
        m.photoLocalPath = dec.decodeString(IntermediateMessage.EM_PHOTO_LOCAL_PATH, orElse: "")
        // -- 文档/视频/语音/贴纸 --
        m.documentId = dec.decodeInt64(IntermediateMessage.EM_DOC_ID, orElse: 0)
        m.documentAccessHash = dec.decodeInt64(IntermediateMessage.EM_DOC_ACCESS_HASH, orElse: 0)
        m.documentFileReference = dec.decodeBytes(IntermediateMessage.EM_DOC_FILE_REF,
            orElse: Array<Byte>(0, repeat: 0))
        m.documentDcId = dec.decodeInt32(IntermediateMessage.EM_DOC_DC_ID, orElse: 0)
        m.documentSize = dec.decodeInt64(IntermediateMessage.EM_DOC_SIZE, orElse: 0)
        m.documentMimeType = dec.decodeString(IntermediateMessage.EM_DOC_MIME, orElse: "")
        m.documentFileName = dec.decodeString(IntermediateMessage.EM_DOC_FILE_NAME, orElse: "")
        m.videoDuration = dec.decodeInt32(IntermediateMessage.EM_VIDEO_DURATION, orElse: 0)
        m.videoWidth = dec.decodeInt32(IntermediateMessage.EM_VIDEO_WIDTH, orElse: 0)
        m.videoHeight = dec.decodeInt32(IntermediateMessage.EM_VIDEO_HEIGHT, orElse: 0)
        m.audioDuration = dec.decodeInt32(IntermediateMessage.EM_AUDIO_DURATION, orElse: 0)
        m.audioTitle = dec.decodeString(IntermediateMessage.EM_AUDIO_TITLE, orElse: "")
        m.audioPerformer = dec.decodeString(IntermediateMessage.EM_AUDIO_PERFORMER, orElse: "")
        m.audioWaveform = dec.decodeBytes(IntermediateMessage.EM_AUDIO_WAVEFORM,
            orElse: Array<Byte>(0, repeat: 0))
        m.stickerAlt = dec.decodeString(IntermediateMessage.EM_STICKER_ALT, orElse: "")
        m.documentLocalPath = dec.decodeString(IntermediateMessage.EM_DOC_LOCAL_PATH, orElse: "")
        m.documentThumbnailPath = dec.decodeString(IntermediateMessage.EM_DOC_THUMB_PATH, orElse: "")
        // -- webPage --
        m.webPageUrl = dec.decodeString(IntermediateMessage.EM_WEB_URL, orElse: "")
        m.webPageSiteName = dec.decodeString(IntermediateMessage.EM_WEB_SITE, orElse: "")
        m.webPageTitle = dec.decodeString(IntermediateMessage.EM_WEB_TITLE, orElse: "")
        m.webPageDescription = dec.decodeString(IntermediateMessage.EM_WEB_DESC, orElse: "")
        m.webPagePhotoId = dec.decodeInt64(IntermediateMessage.EM_WEB_PHOTO_ID, orElse: 0)
        m.webPagePhotoAccessHash = dec.decodeInt64(IntermediateMessage.EM_WEB_PHOTO_AH, orElse: 0)
        m.webPagePhotoFileReference = dec.decodeBytes(IntermediateMessage.EM_WEB_PHOTO_REF,
            orElse: Array<Byte>(0, repeat: 0))
        m.webPagePhotoDcId = dec.decodeInt32(IntermediateMessage.EM_WEB_PHOTO_DC, orElse: 0)
        m.webPagePhotoWidth = dec.decodeInt32(IntermediateMessage.EM_WEB_PHOTO_WIDTH, orElse: 0)
        m.webPagePhotoHeight = dec.decodeInt32(IntermediateMessage.EM_WEB_PHOTO_HEIGHT, orElse: 0)
        m.webPagePhotoLocalPath = dec.decodeString(IntermediateMessage.EM_WEB_PHOTO_LOCAL, orElse: "")
        // -- 位置 --
        m.locationLat = dec.decodeDouble(IntermediateMessage.EM_LOC_LAT, orElse: 0.0)
        m.locationLng = dec.decodeDouble(IntermediateMessage.EM_LOC_LNG, orElse: 0.0)
        m.isLiveLocation = dec.decodeBool(IntermediateMessage.EM_IS_LIVE, orElse: false)
        m.liveLocationPeriod = dec.decodeInt32(IntermediateMessage.EM_LIVE_PERIOD, orElse: 0)
        // -- 通话 --
        m.isCallMessage = dec.decodeBool(IntermediateMessage.EM_IS_CALL, orElse: false)
        m.callDuration = dec.decodeInt32(IntermediateMessage.EM_CALL_DUR, orElse: 0)
        m.callReason = dec.decodeString(IntermediateMessage.EM_CALL_REASON, orElse: "")
        m.serviceText = dec.decodeString(IntermediateMessage.EM_SERVICE_TEXT, orElse: "")
        m.hiddenInHistory = dec.decodeBool(IntermediateMessage.EM_HIDDEN_IN_HISTORY, orElse: false)
        // -- 投票 --
        m.pollId = dec.decodeInt64(IntermediateMessage.EM_POLL_ID, orElse: 0)
        m.pollQuestion = dec.decodeString(IntermediateMessage.EM_POLL_QUESTION, orElse: "")
        m.pollClosed = dec.decodeBool(IntermediateMessage.EM_POLL_CLOSED, orElse: false)
        m.pollQuiz = dec.decodeBool(IntermediateMessage.EM_POLL_QUIZ, orElse: false)
        m.pollMultipleChoice = dec.decodeBool(IntermediateMessage.EM_POLL_MULTI, orElse: false)
        m.pollTotalVoters = dec.decodeInt32(IntermediateMessage.EM_POLL_TOTAL, orElse: 0)
        m.pollSolution = dec.decodeString(IntermediateMessage.EM_POLL_SOLUTION, orElse: "")
        let pollOptCount = dec.decodeInt32(IntermediateMessage.EM_POLL_OPT_COUNT, orElse: 0)
        m.pollOptions = ArrayList<PollOptionData>()
        for (idx in 0..Int64(pollOptCount)) {
            let optBytes = dec.decodeBytes(IntermediateMessage.indexKey(idx),
                orElse: Array<Byte>(0, repeat: 0))
            if (optBytes.size > 0) {
                m.pollOptions.add(IntermediateMessage.decodePollOption(optBytes))
            }
        }
        // -- Bot invoice --
        m.invoiceTitle = dec.decodeString(IntermediateMessage.EM_INVOICE_TITLE, orElse: "")
        m.invoiceDescription = dec.decodeString(IntermediateMessage.EM_INVOICE_DESC, orElse: "")
        m.invoiceCurrency = dec.decodeString(IntermediateMessage.EM_INVOICE_CURRENCY, orElse: "")
        m.invoiceTotalAmount = dec.decodeInt64(IntermediateMessage.EM_INVOICE_TOTAL, orElse: 0)
        m.invoiceStartParam = dec.decodeString(IntermediateMessage.EM_INVOICE_START, orElse: "")
        m.invoiceReceiptMsgId = dec.decodeInt32(IntermediateMessage.EM_INVOICE_RECEIPT, orElse: 0)
        m.invoicePaymentButtonTitle = dec.decodeString(IntermediateMessage.EM_INVOICE_BUTTON, orElse: "")
    }

    /**
     * 序列化 Message 的回复/转发/状态标记/reactions/文本实体 → attributesData blob。
     */
    private static func buildAttributesData(m: Message): Array<Byte> {
        let enc = PostboxEncoder()
        // -- 回复 --
        enc.encodeInt64(m.replyToMsgId, key: IntermediateMessage.AT_REPLY_TO_ID)
        enc.encodeString(m.replyToText, key: IntermediateMessage.AT_REPLY_TEXT)
        enc.encodeString(m.replyToSenderName, key: IntermediateMessage.AT_REPLY_SENDER)
        // -- 转发 --
        enc.encodeString(m.forwardFromName, key: IntermediateMessage.AT_FWD_FROM)
        // -- 状态标记 --
        enc.encodeBool(m.isEdited, key: IntermediateMessage.AT_IS_EDITED)
        enc.encodeBool(m.isPinned, key: IntermediateMessage.AT_IS_PINNED)
        enc.encodeInt64(m.views, key: IntermediateMessage.AT_VIEWS)
        enc.encodeBool(m.isSent, key: IntermediateMessage.AT_IS_SENT)
        enc.encodeString(m.status, key: IntermediateMessage.AT_STATUS)
        enc.encodeString(m.senderName, key: IntermediateMessage.AT_SENDER_NAME)
        enc.encodeString(m.senderPeerType, key: IntermediateMessage.AT_SENDER_PEER_TYPE)
        enc.encodeString(m.senderRole, key: IntermediateMessage.AT_SENDER_ROLE)
        enc.encodeString(m.mediaDescription, key: IntermediateMessage.AT_MEDIA_DESC)
        enc.encodeInt64(m.editDate, key: IntermediateMessage.AT_EDIT_DATE)
        // -- reactions --
        let reactCount = if (m.reactions.size > 100) { 100 } else { m.reactions.size }
        enc.encodeInt32(Int32(reactCount), key: IntermediateMessage.AT_REACT_COUNT)
        for (idx in 0..reactCount) {
            let optR = m.reactions.get(idx)
            if (optR.isSome()) {
                enc.encodeBytes(IntermediateMessage.encodeReaction(optR.getOrThrow()),
                    key: IntermediateMessage.indexKey(idx))
            }
        }
        // -- 文本实体 --
        enc.encodeString(m.textEntities, key: IntermediateMessage.AT_TE_STR)
        let teCount = if (m.textEntityList.size > 100) { 100 } else { m.textEntityList.size }
        enc.encodeInt32(Int32(teCount), key: IntermediateMessage.AT_TE_COUNT)
        for (idx in 0..teCount) {
            let optE = m.textEntityList.get(idx)
            if (optE.isSome()) {
                let teKey = "e" + IntermediateMessage.indexKey(idx)
                enc.encodeBytes(IntermediateMessage.encodeTextEntity(optE.getOrThrow()),
                    key: teKey)
            }
        }
        return enc.makeBytes()
    }

    /**
     * 从 attributesData blob 还原 Message 的回复/转发/状态/reactions/文本实体字段。
     * blob 为空时静默回落到 Message 默认值（旧缓存兼容）。
     */
    private static func restoreAttributesData(data: Array<Byte>, m: Message): Unit {
        if (data.size == 0) {
            return
        }
        let dec = PostboxDecoder(data)
        // -- 回复 --
        m.replyToMsgId = dec.decodeInt64(IntermediateMessage.AT_REPLY_TO_ID, orElse: 0)
        m.replyToText = dec.decodeString(IntermediateMessage.AT_REPLY_TEXT, orElse: "")
        m.replyToSenderName = dec.decodeString(IntermediateMessage.AT_REPLY_SENDER, orElse: "")
        // -- 转发 --
        m.forwardFromName = dec.decodeString(IntermediateMessage.AT_FWD_FROM, orElse: "")
        // -- 状态标记 --
        m.isEdited = dec.decodeBool(IntermediateMessage.AT_IS_EDITED, orElse: false)
        m.isPinned = dec.decodeBool(IntermediateMessage.AT_IS_PINNED, orElse: false)
        m.views = dec.decodeInt64(IntermediateMessage.AT_VIEWS, orElse: 0)
        m.isSent = dec.decodeBool(IntermediateMessage.AT_IS_SENT, orElse: false)
        m.status = dec.decodeString(IntermediateMessage.AT_STATUS, orElse: "sent")
        m.senderName = dec.decodeString(IntermediateMessage.AT_SENDER_NAME, orElse: "")
        m.senderPeerType = dec.decodeString(IntermediateMessage.AT_SENDER_PEER_TYPE, orElse: "user")
        m.senderRole = dec.decodeString(IntermediateMessage.AT_SENDER_ROLE, orElse: "")
        m.mediaDescription = dec.decodeString(IntermediateMessage.AT_MEDIA_DESC, orElse: "")
        m.editDate = dec.decodeInt64(IntermediateMessage.AT_EDIT_DATE, orElse: 0)
        // -- reactions --
        let reactCount = dec.decodeInt32(IntermediateMessage.AT_REACT_COUNT, orElse: 0)
        m.reactions = ArrayList<ReactionData>()
        for (idx in 0..Int64(reactCount)) {
            let rBytes = dec.decodeBytes(IntermediateMessage.indexKey(idx),
                orElse: Array<Byte>(0, repeat: 0))
            if (rBytes.size > 0) {
                m.reactions.add(IntermediateMessage.decodeReaction(rBytes))
            }
        }
        // -- 文本实体 --
        m.textEntities = dec.decodeString(IntermediateMessage.AT_TE_STR, orElse: "")
        let teCount = dec.decodeInt32(IntermediateMessage.AT_TE_COUNT, orElse: 0)
        m.textEntityList = ArrayList<TextEntityData>()
        for (idx in 0..Int64(teCount)) {
            let teKey = "e" + IntermediateMessage.indexKey(idx)
            let eBytes = dec.decodeBytes(teKey, orElse: Array<Byte>(0, repeat: 0))
            if (eBytes.size > 0) {
                m.textEntityList.add(IntermediateMessage.decodeTextEntity(eBytes))
            }
        }
    }

    // ==================== Message ↔ IntermediateMessage ====================

    /**
     * 从工程 Message 模型构造落盘表示（P2-287g 扩展版）。
     *
     * 5 个身份/内容标量字段（id/timestamp/authorId/text/messageType）直接写入顶层字段；
     * 媒体字段序列化进 embeddedMediaData blob；
     * 回复/转发/状态/reactions/文本实体字段序列化进 attributesData blob。
     *
     * peerId/namespace 由调用方显式传入（Message 无此字段）。
     */
    public static func fromMessage(m: Message, peerId!: Int64 = 0, namespace!: Int32 = 0): IntermediateMessage {
        let im = IntermediateMessage()
        im.peerId = peerId
        im.namespace = namespace
        im.id = m.id
        im.timestamp = m.rawTimestamp
        im.authorId = m.senderId
        im.text = m.content
        im.messageType = m.messageType
        im.embeddedMediaData = IntermediateMessage.buildEmbeddedMediaData(m)
        im.attributesData = IntermediateMessage.buildAttributesData(m)
        return im
    }

    /**
     * 转回工程 Message 模型（P2-287g 扩展版）。
     *
     * 还原全部落盘字段：5 个标量 + embeddedMediaData（媒体/位置/通话/投票）
     *   + attributesData（回复/转发/状态/reactions/文本实体）。
     *
     * 两个 blob 为空时（旧缓存）静默回落到 Message 默认值，不抛异常。
     * 分组显示标记（isFirstInGroup 等）为纯 UI 派生字段，由 ViewModel 重算，不在此还原。
     */
    public func toMessage(): Message {
        let m = Message()
        // -- 5 个核心标量 --
        m.id = this.id
        m.rawTimestamp = this.timestamp
        // 展示用的 "HH:MM" 不落盘（它是 rawTimestamp 的派生值，且随时区/12-24h 设置变化），
        // 但必须在此重算：网络解析路径由 RealMessageService.parseMessage 填 time，
        // 本地缓存路径此前漏了，于是「本地秒开」的那批历史消息 time 为空串、
        // 气泡里的时间戳渲染成空白 —— 表现为部分历史消息不显示时间。
        m.time = formatClockHHMM(this.timestamp)
        m.senderId = this.authorId
        m.content = this.text
        m.messageType = this.messageType
        // 命名空间随本地表复合键一并还原 —— 它参与全序排序（timestamp → namespace → id），
        // 不还原则本地缓存读出的消息一律按 0(Cloud) 处理。当前落库只写 Cloud，
        // 故行为不变；此处补上是为了将来待发消息也落库时不出错。
        m.namespace = this.namespace
        // -- 媒体 blob 还原（旧缓存兼容：blob 为空时跳过）--
        IntermediateMessage.restoreEmbeddedMediaData(this.embeddedMediaData, m)
        // -- 属性 blob 还原（旧缓存兼容：blob 为空时跳过）--
        IntermediateMessage.restoreAttributesData(this.attributesData, m)
        return m
    }
}

/**
 * 往返自检（验收项②）：
 *
 * P2-287g 扩展版：除原有 5 标量 + blob 透传校验外，新增媒体/回复/reactions/转发字段的
 * 完整 Message → fromMessage → encode → decode → toMessage 往返校验。
 *
 * 旧缓存兼容性自检：空 blob 时 toMessage 应静默回落到默认值（不抛异常）。
 */
public func intermediateMessageRoundTripSelfCheck(): Bool {
    // ========== 1. 构造带全字段的 Message ==========
    let src = Message()
    src.id = 42
    src.rawTimestamp = 1700000000
    src.senderId = 1001
    src.content = "héllo 世界 — round trip"
    src.messageType = "photo"
    // 照片字段
    src.photoId = 99887766
    src.photoAccessHash = -123456789
    src.photoFileReference = [1u8, 2u8, 3u8, 4u8]
    src.photoDcId = 2
    src.photoWidth = 1280
    src.photoHeight = 720
    src.photoFileSize = 204800
    src.strippedThumb = [0xFFu8, 0xD8u8, 0xFFu8]
    src.photoLocalPath = "/data/photo/99887766.jpg"
    // 文档字段
    src.documentId = 55443322
    src.documentAccessHash = 111222333
    src.documentMimeType = "video/mp4"
    src.documentFileName = "clip.mp4"
    src.videoDuration = 30
    src.videoWidth = 1920
    src.videoHeight = 1080
    src.documentLocalPath = "/data/doc/clip.mp4"
    // 语音字段
    src.audioDuration = 15
    src.audioTitle = "Voice"
    src.audioPerformer = ""
    src.audioWaveform = [10u8, 20u8, 30u8]
    // webPage 字段
    src.webPageUrl = "https://example.com/article"
    src.webPageTitle = "Example Article"
    src.webPageDescription = "A short description"
    // 位置字段
    src.locationLat = 37.5665
    src.locationLng = 126.9780
    src.isLiveLocation = true
    src.liveLocationPeriod = 3600
    // 通话字段
    src.isCallMessage = true
    src.callDuration = 125
    src.callReason = "hangup"
    // 投票字段
    src.pollId = 999888
    src.pollQuestion = "Best language?"
    src.pollClosed = false
    src.pollQuiz = true
    src.pollMultipleChoice = false
    src.pollTotalVoters = 42
    src.pollSolution = "Cangjie"
    let opt1 = PollOptionData()
    opt1.text = "Cangjie"
    opt1.voters = 30
    opt1.chosen = true
    opt1.correct = true
    opt1.percentage = 71
    opt1.optionData = [0xAAu8, 0xBBu8]
    let opt2 = PollOptionData()
    opt2.text = "Swift"
    opt2.voters = 12
    opt2.chosen = false
    opt2.correct = false
    opt2.percentage = 29
    opt2.optionData = [0xCCu8]
    src.pollOptions = ArrayList<PollOptionData>()
    src.pollOptions.add(opt1)
    src.pollOptions.add(opt2)
    // 回复字段
    src.replyToMsgId = 777
    src.replyToText = "Quoted text"
    src.replyToSenderName = "Alice"
    // 转发字段
    src.forwardFromName = "Bob"
    // 状态标记
    src.isEdited = true
    src.isPinned = false
    src.views = 123456
    src.isSent = true
    src.status = "read"
    src.senderName = "Charlie"
    src.mediaDescription = "A photo of a cat"
    // reactions
    let r1 = ReactionData(emoji: "👍", count: 5, isSelected: true, peerInitials: "AB")
    r1.peerIds.add(1001)
    r1.peerIds.add(1002)
    r1.peerAvatarPaths.add("file:///data/avatar-1001.jpg")
    r1.peerAvatarPaths.add("")
    r1.peerInitialsList.add("A")
    r1.peerInitialsList.add("B")
    let r2 = ReactionData(emoji: "❤️", count: 3, isSelected: false, peerInitials: "")
    src.reactions = ArrayList<ReactionData>()
    src.reactions.add(r1)
    src.reactions.add(r2)
    // 文本实体
    src.textEntities = "bold:0:5"
    let te1 = TextEntityData()
    te1.entityType = "bold"
    te1.offset = 0
    te1.length = 5
    te1.url = ""
    let te2 = TextEntityData()
    te2.entityType = "textUrl"
    te2.offset = 6
    te2.length = 10
    te2.url = "https://t.me"
    src.textEntityList = ArrayList<TextEntityData>()
    src.textEntityList.add(te1)
    src.textEntityList.add(te2)

    // ========== 2. Message → IntermediateMessage → encode → decode ==========
    let im = IntermediateMessage.fromMessage(src, peerId: 777, namespace: 5)
    im.flags = 0x40
    let restoredIm = IntermediateMessage.decodeFromBytes(im.encodeToBytes())

    // -- 落盘层标量校验 --
    if (restoredIm.peerId != 777) {
        throw PostboxCodingException("IM roundTrip failed: peerId got ${restoredIm.peerId}")
    }
    if (restoredIm.namespace != 5) {
        throw PostboxCodingException("IM roundTrip failed: namespace got ${restoredIm.namespace}")
    }
    if (restoredIm.id != 42) {
        throw PostboxCodingException("IM roundTrip failed: id got ${restoredIm.id}")
    }
    if (restoredIm.timestamp != 1700000000) {
        throw PostboxCodingException("IM roundTrip failed: timestamp got ${restoredIm.timestamp}")
    }
    if (restoredIm.flags != 0x40) {
        throw PostboxCodingException("IM roundTrip failed: flags got ${restoredIm.flags}")
    }
    if (restoredIm.authorId != 1001) {
        throw PostboxCodingException("IM roundTrip failed: authorId got ${restoredIm.authorId}")
    }
    if (restoredIm.text != "héllo 世界 — round trip") {
        throw PostboxCodingException("IM roundTrip failed: text got ${restoredIm.text}")
    }
    if (restoredIm.messageType != "photo") {
        throw PostboxCodingException("IM roundTrip failed: messageType got ${restoredIm.messageType}")
    }

    // ========== 3. IntermediateMessage → Message，校验全字段往返 ==========
    let dst = restoredIm.toMessage()

    // 5 标量不回归
    if (dst.id != src.id) {
        throw PostboxCodingException("IM roundTrip failed: Message.id ${dst.id} != ${src.id}")
    }
    if (dst.rawTimestamp != src.rawTimestamp) {
        throw PostboxCodingException("IM roundTrip failed: Message.rawTimestamp")
    }
    if (dst.senderId != src.senderId) {
        throw PostboxCodingException("IM roundTrip failed: Message.senderId")
    }
    if (dst.content != src.content) {
        throw PostboxCodingException("IM roundTrip failed: Message.content")
    }
    if (dst.messageType != src.messageType) {
        throw PostboxCodingException("IM roundTrip failed: Message.messageType")
    }

    // 照片字段往返
    if (dst.photoId != 99887766) {
        throw PostboxCodingException("IM roundTrip failed: photoId ${dst.photoId}")
    }
    if (dst.photoAccessHash != -123456789) {
        throw PostboxCodingException("IM roundTrip failed: photoAccessHash ${dst.photoAccessHash}")
    }
    if (dst.photoFileReference.size != 4 || dst.photoFileReference[0] != 1u8 || dst.photoFileReference[3] != 4u8) {
        throw PostboxCodingException("IM roundTrip failed: photoFileReference")
    }
    if (dst.photoDcId != 2) {
        throw PostboxCodingException("IM roundTrip failed: photoDcId ${dst.photoDcId}")
    }
    if (dst.photoWidth != 1280 || dst.photoHeight != 720) {
        throw PostboxCodingException("IM roundTrip failed: photo dimensions")
    }
    if (dst.photoLocalPath != "/data/photo/99887766.jpg") {
        throw PostboxCodingException("IM roundTrip failed: photoLocalPath ${dst.photoLocalPath}")
    }
    if (dst.strippedThumb.size != 3 || dst.strippedThumb[0] != 0xFFu8) {
        throw PostboxCodingException("IM roundTrip failed: strippedThumb")
    }

    // 文档/视频字段往返
    if (dst.documentId != 55443322) {
        throw PostboxCodingException("IM roundTrip failed: documentId ${dst.documentId}")
    }
    if (dst.documentMimeType != "video/mp4") {
        throw PostboxCodingException("IM roundTrip failed: documentMimeType ${dst.documentMimeType}")
    }
    if (dst.videoDuration != 30 || dst.videoWidth != 1920 || dst.videoHeight != 1080) {
        throw PostboxCodingException("IM roundTrip failed: video fields")
    }
    if (dst.documentLocalPath != "/data/doc/clip.mp4") {
        throw PostboxCodingException("IM roundTrip failed: documentLocalPath ${dst.documentLocalPath}")
    }

    // 语音字段往返
    if (dst.audioDuration != 15) {
        throw PostboxCodingException("IM roundTrip failed: audioDuration ${dst.audioDuration}")
    }
    if (dst.audioWaveform.size != 3 || dst.audioWaveform[0] != 10u8) {
        throw PostboxCodingException("IM roundTrip failed: audioWaveform")
    }

    // webPage 字段往返
    if (dst.webPageUrl != "https://example.com/article") {
        throw PostboxCodingException("IM roundTrip failed: webPageUrl ${dst.webPageUrl}")
    }
    if (dst.webPageTitle != "Example Article") {
        throw PostboxCodingException("IM roundTrip failed: webPageTitle ${dst.webPageTitle}")
    }

    // 位置字段往返
    if (dst.locationLat != 37.5665) {
        throw PostboxCodingException("IM roundTrip failed: locationLat ${dst.locationLat}")
    }
    if (dst.locationLng != 126.9780) {
        throw PostboxCodingException("IM roundTrip failed: locationLng ${dst.locationLng}")
    }
    if (dst.isLiveLocation != true) {
        throw PostboxCodingException("IM roundTrip failed: isLiveLocation")
    }
    if (dst.liveLocationPeriod != 3600) {
        throw PostboxCodingException("IM roundTrip failed: liveLocationPeriod ${dst.liveLocationPeriod}")
    }

    // 通话字段往返
    if (dst.isCallMessage != true) {
        throw PostboxCodingException("IM roundTrip failed: isCallMessage")
    }
    if (dst.callDuration != 125) {
        throw PostboxCodingException("IM roundTrip failed: callDuration ${dst.callDuration}")
    }
    if (dst.callReason != "hangup") {
        throw PostboxCodingException("IM roundTrip failed: callReason ${dst.callReason}")
    }

    // 投票字段往返
    if (dst.pollId != 999888) {
        throw PostboxCodingException("IM roundTrip failed: pollId ${dst.pollId}")
    }
    if (dst.pollQuestion != "Best language?") {
        throw PostboxCodingException("IM roundTrip failed: pollQuestion ${dst.pollQuestion}")
    }
    if (dst.pollQuiz != true) {
        throw PostboxCodingException("IM roundTrip failed: pollQuiz")
    }
    if (dst.pollTotalVoters != 42) {
        throw PostboxCodingException("IM roundTrip failed: pollTotalVoters ${dst.pollTotalVoters}")
    }
    if (dst.pollSolution != "Cangjie") {
        throw PostboxCodingException("IM roundTrip failed: pollSolution ${dst.pollSolution}")
    }
    if (dst.pollOptions.size != 2) {
        throw PostboxCodingException("IM roundTrip failed: pollOptions.size ${dst.pollOptions.size}")
    }
    let dstOpt0 = dst.pollOptions.get(0)
    if (dstOpt0.isNone()) {
        throw PostboxCodingException("IM roundTrip failed: pollOptions[0] is None")
    }
    if (dstOpt0.getOrThrow().text != "Cangjie" || dstOpt0.getOrThrow().chosen != true) {
        throw PostboxCodingException("IM roundTrip failed: pollOptions[0] content")
    }
    let dstOpt1 = dst.pollOptions.get(1)
    if (dstOpt1.isNone()) {
        throw PostboxCodingException("IM roundTrip failed: pollOptions[1] is None")
    }
    if (dstOpt1.getOrThrow().text != "Swift" || dstOpt1.getOrThrow().percentage != 29) {
        throw PostboxCodingException("IM roundTrip failed: pollOptions[1] content")
    }

    // 回复字段往返
    if (dst.replyToMsgId != 777) {
        throw PostboxCodingException("IM roundTrip failed: replyToMsgId ${dst.replyToMsgId}")
    }
    if (dst.replyToText != "Quoted text") {
        throw PostboxCodingException("IM roundTrip failed: replyToText ${dst.replyToText}")
    }
    if (dst.replyToSenderName != "Alice") {
        throw PostboxCodingException("IM roundTrip failed: replyToSenderName ${dst.replyToSenderName}")
    }

    // 转发字段往返
    if (dst.forwardFromName != "Bob") {
        throw PostboxCodingException("IM roundTrip failed: forwardFromName ${dst.forwardFromName}")
    }

    // 状态标记往返
    if (dst.isEdited != true) {
        throw PostboxCodingException("IM roundTrip failed: isEdited")
    }
    if (dst.views != 123456) {
        throw PostboxCodingException("IM roundTrip failed: views ${dst.views}")
    }
    if (dst.isSent != true) {
        throw PostboxCodingException("IM roundTrip failed: isSent")
    }
    if (dst.status != "read") {
        throw PostboxCodingException("IM roundTrip failed: status ${dst.status}")
    }
    if (dst.senderName != "Charlie") {
        throw PostboxCodingException("IM roundTrip failed: senderName ${dst.senderName}")
    }
    if (dst.mediaDescription != "A photo of a cat") {
        throw PostboxCodingException("IM roundTrip failed: mediaDescription ${dst.mediaDescription}")
    }

    // reactions 往返
    if (dst.reactions.size != 2) {
        throw PostboxCodingException("IM roundTrip failed: reactions.size ${dst.reactions.size}")
    }
    let dr0 = dst.reactions.get(0)
    if (dr0.isNone()) {
        throw PostboxCodingException("IM roundTrip failed: reactions[0] is None")
    }
    if (dr0.getOrThrow().emoji != "👍" || dr0.getOrThrow().count != 5 || dr0.getOrThrow().isSelected != true) {
        throw PostboxCodingException("IM roundTrip failed: reactions[0] content")
    }
    if (dr0.getOrThrow().peerInitials != "AB") {
        throw PostboxCodingException("IM roundTrip failed: reactions[0].peerInitials ${dr0.getOrThrow().peerInitials}")
    }
    if (dr0.getOrThrow().peerIds.size != 2 || dr0.getOrThrow().peerIds[0] != 1001 ||
        dr0.getOrThrow().peerIds[1] != 1002) {
        throw PostboxCodingException("IM roundTrip failed: reactions[0].peerIds")
    }
    if (dr0.getOrThrow().peerAvatarPaths.size != 2 ||
        dr0.getOrThrow().peerAvatarPaths[0] != "file:///data/avatar-1001.jpg") {
        throw PostboxCodingException("IM roundTrip failed: reactions[0].peerAvatarPaths")
    }
    if (dr0.getOrThrow().peerInitialsList.size != 2 ||
        dr0.getOrThrow().peerInitialsList[0] != "A" || dr0.getOrThrow().peerInitialsList[1] != "B") {
        throw PostboxCodingException("IM roundTrip failed: reactions[0].peerInitialsList")
    }
    let dr1 = dst.reactions.get(1)
    if (dr1.isNone()) {
        throw PostboxCodingException("IM roundTrip failed: reactions[1] is None")
    }
    if (dr1.getOrThrow().emoji != "❤️" || dr1.getOrThrow().count != 3) {
        throw PostboxCodingException("IM roundTrip failed: reactions[1] content")
    }

    // 文本实体往返
    if (dst.textEntities != "bold:0:5") {
        throw PostboxCodingException("IM roundTrip failed: textEntities ${dst.textEntities}")
    }
    if (dst.textEntityList.size != 2) {
        throw PostboxCodingException("IM roundTrip failed: textEntityList.size ${dst.textEntityList.size}")
    }
    let de0 = dst.textEntityList.get(0)
    if (de0.isNone()) {
        throw PostboxCodingException("IM roundTrip failed: textEntityList[0] is None")
    }
    if (de0.getOrThrow().entityType != "bold" || de0.getOrThrow().offset != 0 || de0.getOrThrow().length != 5) {
        throw PostboxCodingException("IM roundTrip failed: textEntityList[0] content")
    }
    let de1 = dst.textEntityList.get(1)
    if (de1.isNone()) {
        throw PostboxCodingException("IM roundTrip failed: textEntityList[1] is None")
    }
    if (de1.getOrThrow().entityType != "textUrl" || de1.getOrThrow().url != "https://t.me") {
        throw PostboxCodingException("IM roundTrip failed: textEntityList[1] content")
    }

    // ========== 4. 旧缓存兼容性校验：空 blob 时不抛异常，回落到默认值 ==========
    let legacyIm = IntermediateMessage()
    legacyIm.id = 1
    legacyIm.timestamp = 1000
    legacyIm.authorId = 2
    legacyIm.text = "legacy"
    legacyIm.messageType = "text"
    // embeddedMediaData / attributesData 保持空（Array<Byte>(0, repeat: 0)）
    let legacyMsg = legacyIm.toMessage()
    if (legacyMsg.id != 1) {
        throw PostboxCodingException("IM roundTrip failed: legacy id")
    }
    if (legacyMsg.photoId != 0) {
        throw PostboxCodingException("IM roundTrip failed: legacy photoId should be 0 got ${legacyMsg.photoId}")
    }
    if (legacyMsg.reactions.size != 0) {
        throw PostboxCodingException("IM roundTrip failed: legacy reactions should be empty")
    }
    if (legacyMsg.replyToMsgId != 0) {
        throw PostboxCodingException("IM roundTrip failed: legacy replyToMsgId should be 0")
    }

    return true
}
