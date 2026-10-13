package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.{getMTProtoClient, TLDeserializer, TLSerializer, TLObject, TLConstructors, InputPeerEmpty, ChatResponse, UserResponse, skipUpdate}
import std.collection.ArrayList

// ──────────────────────────────────────────────────────────────────
// 本地 TL 方法定义（不修改 TLMethods.cj，避免跨 feature 冲突）
// ──────────────────────────────────────────────────────────────────

/**
 * messages.checkChatInvite#3eadb1bb hash:string = ChatInvite
 * iOS Api42.swift: buffer.appendInt32(1051570619) → 0x3eadb1bb
 * telegram_api.tl: messages.checkChatInvite#3eadb1bb
 */
private class MessagesCheckChatInvite <: TLObject {
    public var hash: String = ""

    public func getConstructorId(): UInt32 { return 0x3eadb1bb }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.hash)
    }
}

/**
 * messages.importChatInvite#6c50051c hash:string = Updates
 * telegram_api.tl: messages.importChatInvite#6c50051c
 */
private class MessagesImportChatInvite <: TLObject {
    public var hash: String = ""

    public func getConstructorId(): UInt32 { return 0x6c50051c }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.hash)
    }
}

// ──────────────────────────────────────────────────────────────────
// 数据模型
// ──────────────────────────────────────────────────────────────────

/**
 * 群组邀请链接预览信息
 * 对应 iOS ExternalJoiningChatState.invite 的关键字段
 *
 * TL chatInvite#5c9d3702 flags:# channel:flags.0?true broadcast:flags.1?true
 *   public:flags.2?true megagroup:flags.3?true request_needed:flags.6?true
 *   verified:flags.7?true scam:flags.8?true fake:flags.9?true
 *   title:string about:flags.5?string photo:Photo participants_count:int
 *   participants:flags.4?Vector<User> color:int ...
 */
/** joinChatInvite 结果 */
public class JoinedChatResult {
    public var success: Bool = false
    public var errorCode: String = ""
    // 需审批的链接：已提交入群申请（iOS JoinLink .requestSent）
    public var requestSent: Bool = false
    public var chatId: Int64 = 0
    public var accessHash: Int64 = 0
    public var isChannel: Bool = false
    public var title: String = ""
    public init() {}
}

public class ChatInviteInfo {
    /** 群/频道名称 */
    public var title: String = ""
    /** 成员/订阅者数量 */
    public var participantsCount: Int32 = 0
    /** 简介 */
    public var about: String = ""
    /** 是否是频道（broadcast） */
    public var isChannel: Bool = false
    /** 是否需要管理员审批才能加入 */
    public var requestNeeded: Bool = false
    /** 是否已加入（alreadyJoined 状态） */
    public var alreadyJoined: Bool = false
    /** chatInvitePeek：用户已退出该群但链接仍可预览（iOS .peek(peer, expires)），不算已加入 */
    public var peek: Bool = false
    /** peek 的到期时间（unix 秒，chatInvitePeek.expires） */
    public var peekExpires: Int32 = 0
    /** 是否 hash 无效/已过期 */
    public var invalidHash: Bool = false
    // alreadyJoined 时由 chatInviteAlready 的 chat 填充
    public var chatId: Int64 = 0
    public var accessHash: Int64 = 0
    /** 是否已经是用户群（private 群直接加入） */
    public var isPublic: Bool = false

    /** verified 徽章（flags.7） */
    public var verified: Bool = false
    /** scam 警告（flags.8） */
    public var scam: Bool = false
    /** fake 警告（flags.9） */
    public var fake: Bool = false

    /**
     * 成员头像行 — 从 participants:Vector<User> 提取的名字列表（最多 5 条）
     * 每条是 first_name（可能为空则退化为 id 的首字符）
     * UI 用此字段渲染小头像 monogram 行 + "+X more"
     */
    public var memberNames: Array<String> = Array<String>()

    /**
     * 群/频道头像 CDN 下载 URL（由 getGroupPhotoUrl() 构造）
     * 如果 photo 是 photoEmpty 则为空字符串，UI 回退到 monogram
     */
    public var groupPhotoUrl: String = ""
}

// ──────────────────────────────────────────────────────────────────
// 全局共享状态（pending link，用于 Page 之间传参）
// ──────────────────────────────────────────────────────────────────

private var _pendingJoinLinkHash: String = ""
private var _pendingJoinLinkInfo: Option<ChatInviteInfo> = None

public func setPendingJoinLinkHash(hash: String): Unit {
    _pendingJoinLinkHash = hash
    _pendingJoinLinkInfo = None
}

public func getPendingJoinLinkHash(): String {
    return _pendingJoinLinkHash
}

public func setPendingJoinLinkInfo(info: ChatInviteInfo): Unit {
    _pendingJoinLinkInfo = Some(info)
}

public func getPendingJoinLinkInfo(): Option<ChatInviteInfo> {
    return _pendingJoinLinkInfo
}

// ──────────────────────────────────────────────────────────────────
// Service
// ──────────────────────────────────────────────────────────────────

private var _joinLinkPreviewServiceInstance: Option<JoinLinkPreviewService> = None

public func getJoinLinkPreviewService(): JoinLinkPreviewService {
    match (_joinLinkPreviewServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = JoinLinkPreviewService()
            _joinLinkPreviewServiceInstance = Some(inst)
            return inst
    }
}

/**
 * JoinLinkPreviewService — 群组邀请链接预览服务
 *
 * 对应 iOS JoinLinkPreviewUI 的核心逻辑：
 * - checkChatInvite：获取邀请链接预览（messages.checkChatInvite）
 * - importChatInvite：加入群/频道（messages.importChatInvite）
 *
 * 调用链：JoinLinkPreviewService → getMTProtoClient().sendRequest()
 *
 * Constructor IDs verified against iOS Api0.swift + telegram_api.tl:
 *   chatInvite#5c9d3702        iOS dict[1553807106]
 *   chatInviteAlready#5a686d7c iOS dict[1516793212]
 *   chatInvitePeek#61695cb0    iOS dict[1634294960]
 */
public class JoinLinkPreviewService {

    /**
     * 检查邀请 hash，获取群/频道预览信息
     * TL: messages.checkChatInvite#3eadb1bb hash:string = ChatInvite
     *
     * @param hash  t.me/+xxx 中的 xxx 部分（或 joinchat/xxx 的 xxx 部分）
     * @return ChatInviteInfo，若 hash 无效则 invalidHash=true
     */
    public func checkChatInvite(hash: String): ChatInviteInfo {
        let info = ChatInviteInfo()
        if (hash.size == 0) {
            info.invalidHash = true
            return info
        }
        let client = getMTProtoClient()
        let req = MessagesCheckChatInvite()
        req.hash = hash
        try {
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) {
                Hilog.info(0, "CjTelegram", "[JoinLinkPreviewSvc] checkChatInvite: empty response")
                info.invalidHash = true
                return info
            }
            let d = TLDeserializer(data)
            let constructor = d.readUInt32()
            Hilog.info(0, "CjTelegram",
                "[JoinLinkPreviewSvc] checkChatInvite hash=${hash} response ctor=${constructor} (already=1516793212 invite=1553807106 peek=1634294960) ${data.size}B")

            if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[JoinLinkPreviewSvc] checkChatInvite RPC error ${errCode}: ${errMsg}")
                if (errCode == 400) {
                    info.invalidHash = true
                }
                return info
            }

            // chatInviteAlready#5a686d7c chat:Chat = ChatInvite
            // iOS: dict[1516793212] → 0x5a686d7c
            // (verified against telegram_api.tl and iOS Api0.swift)
            if (constructor == 0x5a686d7c) {
                info.alreadyJoined = true
                try {
                    let chat = ChatResponse.deserializeBoxed(d)
                    info.chatId = chat.id
                    info.accessHash = chat.accessHash
                    info.title = chat.title
                    info.isChannel = chat.isChannel
                    getRealChatListService().cacheChatResponse(chat)
                    // R6V S1-61：这是唯一不打日志的分支，真机上"点链接直接进群、无 [JoinLinkPreviewSvc]
                    // 行"正是它（服务端判定当前账号仍是成员，iOS JoinLinkPreviewController.swift:90-91
                    // .alreadyJoined → navigateToPeer 同样直接进会话）。记下服务端给的成员态供排查。
                    Hilog.info(0, "CjTelegram",
                        "[JoinLinkPreviewSvc] chatInviteAlready: chat=${chat.id} '${chat.title}' channel=${chat.isChannel} left=${chat.isLeft} participants=${chat.participantsCount} -> open chat (server says member)")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[JoinLinkPreviewSvc] chatInviteAlready chat parse skipped: ${e}")
                }
                return info
            }

            // chatInvite#5c9d3702 flags:# channel:flags.0?true broadcast:flags.1?true
            //   public:flags.2?true megagroup:flags.3?true request_needed:flags.6?true
            //   verified:flags.7?true scam:flags.8?true fake:flags.9?true
            //   can_refulfill_subscription:flags.11?true
            //   title:string about:flags.5?string photo:Photo participants_count:int
            //   participants:flags.4?Vector<User> color:int
            //   subscription_pricing:flags.10?StarsSubscriptionPricing
            //   subscription_form_id:flags.12?long bot_verification:flags.13?BotVerification
            // iOS: dict[1553807106] → 0x5c9d3702
            if (constructor == 0x5c9d3702) {
                let flags = d.readInt32()
                // flags.1 = broadcast (isBroadcast / isChannel)
                let isBroadcast = (flags & 2) != 0
                // flags.6 = request_needed
                let requestNeeded = (flags & 64) != 0
                // flags.2 = public
                let isPublic = (flags & 4) != 0
                // flags.7 = verified
                let verified = (flags & 128) != 0
                // flags.8 = scam
                let scam = (flags & 256) != 0
                // flags.9 = fake
                let fake = (flags & 512) != 0

                info.isChannel = isBroadcast
                info.requestNeeded = requestNeeded
                info.isPublic = isPublic
                info.verified = verified
                info.scam = scam
                info.fake = fake

                // title (always present)
                info.title = d.readString()
                // about = flags.5?string
                if ((flags & 32) != 0) {
                    info.about = d.readString()
                }

                // photo:Photo — must read to advance offset
                // photo#fb197a65 or photoEmpty#2331b22d
                try {
                    let photoConst = d.readUInt32()
                    if (photoConst == 0x2331b22d) {
                        // photoEmpty: id:long (8 bytes)
                        let _ = d.readInt64()
                    } else if (photoConst == 0xfb197a65) {
                        // photo#fb197a65 flags:# id:long access_hash:long file_reference:bytes
                        //   date:int sizes:Vector<PhotoSize> video_sizes:flags.1?Vector<VideoSize>
                        //   dc_id:int
                        let photoFlags = d.readInt32()
                        let photoId = d.readInt64()
                        let _ = d.readInt64()   // access_hash
                        let _ = d.readBytes()   // file_reference
                        let _ = d.readInt32()   // date
                        // skip sizes Vector<PhotoSize>
                        JoinLinkPreviewService.skipPhotoSizes(d)
                        // video_sizes optional (flags.1)
                        if ((photoFlags & 2) != 0) {
                            JoinLinkPreviewService.skipVideoSizes(d)
                        }
                        let dcId = d.readInt32()
                        // group photo parsed: dcId available for future CDN resolution
                        Hilog.info(0, "CjTelegram", "[JoinLinkPreviewSvc] group photo id=${photoId} dc=${dcId}")
                    }
                } catch (_pe: Exception) {
                    Hilog.info(0, "CjTelegram", "[JoinLinkPreviewSvc] photo parse skipped: ${_pe}")
                }

                // participants_count:int (always present)
                try {
                    info.participantsCount = d.readInt32()
                } catch (_ce: Exception) {
                    Hilog.info(0, "CjTelegram", "[JoinLinkPreviewSvc] participantsCount read failed")
                }

                // participants:flags.4?Vector<User>
                if ((flags & 16) != 0) {
                    try {
                        let names = JoinLinkPreviewService.parseParticipantNames(d, 5)
                        info.memberNames = names
                    } catch (_ve: Exception) {
                        Hilog.info(0, "CjTelegram", "[JoinLinkPreviewSvc] participants parse skipped: ${_ve}")
                    }
                }

                Hilog.info(0, "CjTelegram", "[JoinLinkPreviewSvc] checkChatInvite ok: title=${info.title} verified=${info.verified} scam=${info.scam}")
                return info
            }

            // chatInvitePeek#61695cb0 chat:Chat expires:int = ChatInvite
            // iOS: dict[1634294960] → 0x61695cb0
            // V6/V7 S1-61：peek = 用户已退出该群、链接仍有效，可预览到 expires 为止
            // （iOS JoinLink.swift:204-211 → .peek(peer, expires)；JoinLinkPreviewController.swift:93
            // 以 ChatPeekTimeout 打开会话并在输入栏给 Join）。此前把 peek 当 alreadyJoined：
            // 直接 openJoinedChat 进了旧群（能看到以前的 "joined via invite link"），
            // 从未发 importChatInvite，getDialogs 回的 chat 仍 left=true → 会话列表正确地
            // 不显示它。现在 peek 不算已加入：带上群名/人数走加入确认框 → importChatInvite。
            if (constructor == 0x61695cb0) {
                info.peek = true
                try {
                    let chat = ChatResponse.deserializeBoxed(d)
                    info.chatId = chat.id
                    info.accessHash = chat.accessHash
                    info.title = chat.title
                    info.isChannel = chat.isChannel && chat.isBroadcast
                    info.participantsCount = chat.participantsCount
                    info.peekExpires = d.readInt32()
                    // 服务器状态（left=true）照常并入缓存，与 Postbox 以服务端 peer 为准一致。
                    getRealChatListService().cacheChatResponse(chat)
                    Hilog.info(0, "CjTelegram", "[JoinLinkPreviewSvc] chatInvitePeek: chat=${chat.id} '${chat.title}' left=${chat.isLeft} expires=${info.peekExpires} -> join dialog")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[JoinLinkPreviewSvc] chatInvitePeek chat parse skipped: ${e}")
                }
                return info
            }

            Hilog.info(0, "CjTelegram", "[JoinLinkPreviewSvc] checkChatInvite unknown constructor")
            info.invalidHash = true
            return info
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[JoinLinkPreviewSvc] checkChatInvite exception: ${e}")
            info.invalidHash = true
            return info
        }
    }

    /**
     * 通过邀请 hash 加入群/频道
     * TL: messages.importChatInvite#6c50051c hash:string = Updates
     *
     * @param hash  t.me/+xxx 中的 xxx 部分
     * @return true 表示成功加入（或已是成员），false 表示失败
     */
    public func importChatInvite(hash: String): Bool {
        return this.joinChatInvite(hash).success
    }

    /**
     * 加入并返回加入的会话（从 Updates 的 chats 里取），用于加入后直接打开聊天。
     */
    public func joinChatInvite(hash: String): JoinedChatResult {
        let result = JoinedChatResult()
        if (hash.size == 0) {
            return result
        }
        let client = getMTProtoClient()
        let req = MessagesImportChatInvite()
        req.hash = hash
        try {
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) {
                Hilog.info(0, "CjTelegram", "[JoinLinkPreviewSvc] joinChatInvite: empty response")
                return result
            }
            let d = TLDeserializer(data)
            let constructor = d.readUInt32()
            if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
                let _ = d.readInt32()
                result.errorCode = d.readString()
                if (result.errorCode == "INVITE_REQUEST_SENT") { result.requestSent = true }
                Hilog.info(0, "CjTelegram", "[JoinLinkPreviewSvc] joinChatInvite error: ${result.errorCode}")
                return result
            }
            result.success = true
            // updates#74ae4240 / updatesCombined#725b04c3: updates:Vector<Update> users:Vector<User> chats:Vector<Chat> ...
            if (constructor == 0x74ae4240 || constructor == 0x725b04c3) {
                try {
                    let _ = d.readUInt32()
                    let updateCount = d.readInt32()
                    for (_i in 0..Int64(updateCount)) { skipUpdate(d) }
                    let _ = d.readUInt32()
                    let userCount = d.readInt32()
                    for (_i in 0..Int64(userCount)) {
                        let user = UserResponse.deserializeBoxed(d)
                        getUserPhotoService().cacheUser(user)
                    }
                    let _ = d.readUInt32()
                    let chatCount = d.readInt32()
                    for (_i in 0..Int64(chatCount)) {
                        let chat = ChatResponse.deserializeBoxed(d)
                        getRealChatListService().cacheChatResponse(chat)
                        if (result.chatId == 0) {
                            result.chatId = chat.id
                            result.accessHash = chat.accessHash
                            result.isChannel = chat.isChannel
                            result.title = chat.title
                        }
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[JoinLinkPreviewSvc] joinChatInvite chats parse skipped: ${e}")
                }
                // 与 iOS stateManager.addUpdates 一致：加入产生的更新交给更新管理器
                getUpdatesManager().handleRawUpdate(data)
            }
            Hilog.info(0, "CjTelegram", "[JoinLinkPreviewSvc] joinChatInvite success chatId=${result.chatId}")
            return result
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[JoinLinkPreviewSvc] joinChatInvite exception: ${e}")
            return result
        }
    }

    // ────────────────────────────────────────────────────
    // Private helpers
    // ────────────────────────────────────────────────────

    /**
     * Skip Vector<PhotoSize> from deserializer offset.
     * PhotoSize variants in TL: photoSizeEmpty, photoSize, photoCachedSize, photoStrippedSize, photoSizeProgressive, photoPathSize
     * We skip the entire vector by reading count + skipping each item.
     */
    private static func skipPhotoSizes(d: TLDeserializer): Unit {
        // Vector<PhotoSize> starts with 0x1cb5c415 (vector constructor) then count:int
        let vecConst = d.readUInt32()
        if (vecConst != 0x1cb5c415) {
            // not a vector, bail
            return
        }
        let count = d.readInt32()
        var i: Int32 = 0
        while (i < count) {
            let psConst = d.readUInt32()
            if (psConst == 0x0e17e23c) {
                // photoSizeEmpty: type:string
                let _ = d.readString()
            } else if (psConst == 0x75c831c) {
                // photoSize: type:string w:int h:int size:int
                let _ = d.readString()
                let _ = d.readInt32()
                let _ = d.readInt32()
                let _ = d.readInt32()
            } else if (psConst == 0xe9a734fa) {
                // photoCachedSize: type:string w:int h:int bytes:bytes
                let _ = d.readString()
                let _ = d.readInt32()
                let _ = d.readInt32()
                let _ = d.readBytes()
            } else if (psConst == 0xe0b0bc2e) {
                // photoStrippedSize: type:string bytes:bytes
                let _ = d.readString()
                let _ = d.readBytes()
            } else if (psConst == 0xfa3efb95) {
                // photoSizeProgressive: type:string w:int h:int sizes:Vector<int>
                let _ = d.readString()
                let _ = d.readInt32()
                let _ = d.readInt32()
                // inner vector of ints
                let innerVec = d.readUInt32()
                if (innerVec == 0x1cb5c415) {
                    let ic = d.readInt32()
                    var j: Int32 = 0
                    while (j < ic) {
                        let _ = d.readInt32()
                        j = j + 1
                    }
                }
            } else {
                // photoPathSize or unknown — has type:string bytes:bytes
                let _ = d.readString()
                let _ = d.readBytes()
            }
            i = i + 1
        }
    }

    /**
     * Skip Vector<VideoSize> from deserializer offset.
     */
    private static func skipVideoSizes(d: TLDeserializer): Unit {
        let vecConst = d.readUInt32()
        if (vecConst != 0x1cb5c415) {
            return
        }
        let count = d.readInt32()
        var i: Int32 = 0
        while (i < count) {
            // videoSize#de33b094 flags:# type:string w:int h:int size:int video_start_ts:flags.0?double
            // videoSizeEmojiMarkup#f85c413c ...
            let vsConst = d.readUInt32()
            if (vsConst == 0xde33b094) {
                let vsFlags = d.readInt32()
                let _ = d.readString()
                let _ = d.readInt32()
                let _ = d.readInt32()
                let _ = d.readInt32()
                if ((vsFlags & 1) != 0) {
                    let _ = d.readDouble()
                }
            } else {
                // skip 3 ints as a best-effort (type-less)
                let _ = d.readInt32()
                let _ = d.readInt32()
                let _ = d.readInt32()
            }
            i = i + 1
        }
    }

    /**
     * Parse Vector<User> participants and extract display names.
     * Stops at maxCount or end of vector.
     * Only reads fields up to first_name (minimal parse).
     */
    private static func parseParticipantNames(d: TLDeserializer, maxCount: Int32): Array<String> {
        let vecConst = d.readUInt32()
        if (vecConst != 0x1cb5c415) {
            return Array<String>()
        }
        let count = d.readInt32()
        let names = ArrayList<String>()
        var i: Int32 = 0
        while (i < count) {
            let userConst = d.readUInt32()
            if (userConst == 0xd3bc4b7a) {
                // userEmpty#d3bc4b7a id:long
                let _ = d.readInt64()
            } else if (userConst == 0x31774388) {
                // user#31774388 — iOS Api30.swift dict[829899656]; parse just enough to get name
                let uFlags = d.readInt32()
                let _ = d.readInt32()   // flags2
                let _ = d.readInt64()   // id
                // access_hash:flags.0?long
                if ((uFlags & 1) != 0) {
                    let _ = d.readInt64()
                }
                // first_name:flags.1?string
                var firstName: String = ""
                if ((uFlags & 2) != 0) {
                    firstName = d.readString()
                }
                // last_name:flags.2?string
                if ((uFlags & 4) != 0) {
                    let _ = d.readString()
                }
                // username:flags.3?string
                if ((uFlags & 8) != 0) {
                    let _ = d.readString()
                }
                // phone:flags.4?string
                if ((uFlags & 16) != 0) {
                    let _ = d.readString()
                }
                // Skip remaining optional fields — we have what we need
                // (photo, status, etc. all optional, skip by returning early)
                if (names.size < Int64(maxCount)) {
                    if (firstName.size > 0) {
                        names.add(firstName)
                    } else {
                        names.add("?")
                    }
                }
                // We cannot safely parse the rest of a User (too many optional fields),
                // so we'll try a best-effort abort of the rest of the vector
                // to avoid corruption. Return what we have.
                return names.toArray()
            } else {
                // unknown user constructor, abort parsing
                return names.toArray()
            }
            i = i + 1
        }
        return names.toArray()
    }

}

