package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.models.ExportedChatFolderLink
import ohos_app_cangjie_entry.models.FolderShareablePeer
import ohos_app_cangjie_entry.models.ChatFolder
import ohos_app_cangjie_entry.models.ChatFolderPeer
import std.collection.ArrayList

/**
 * 聊天文件夹邀请链接服务（P2-174）
 *
 * 封装 chatlists.* TL 方法：
 *   - chatlists.exportChatlistInvite  (创建文件夹邀请链接)
 *   - chatlists.getExportedInvites    (获取文件夹邀请链接列表)
 *   - chatlists.editExportedInvite    (编辑/撤销文件夹邀请链接)
 *   - chatlists.deleteExportedInvite  (删除文件夹邀请链接)
 *
 * iOS ref: TelegramCore/Communities.swift
 *   _internal_exportChatFolder / _internal_getExportedChatFolderLinks /
 *   _internal_editChatFolderLink / _internal_deleteChatFolderLink
 */
private var _chatFolderLinksServiceInstance: Option<ChatFolderLinksService> = None

public func getChatFolderLinksService(): ChatFolderLinksService {
    match (_chatFolderLinksServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ChatFolderLinksService()
            _chatFolderLinksServiceInstance = Some(inst)
            return inst
    }
}

public class ChatFolderLinksService {

    private func shareInputPeerFor(peer: FolderShareablePeer): TLObject {
        if (peer.peerType == "chat") {
            let input = InputPeerChat()
            input.chatId = peer.peerId
            return input
        }
        let input = InputPeerChannel()
        input.channelId = peer.peerId
        input.accessHash = if (peer.accessHash != 0) { peer.accessHash } else { getRealMessageService().getAccessHashForChannel(peer.peerId) }
        return input
    }

    private func inputPeerFor(peer: ChatFolderPeer): TLObject {
        if (peer.peerType == "chat") {
            let input = InputPeerChat()
            input.chatId = peer.id
            return input
        }
        if (peer.peerType == "channel") {
            let input = InputPeerChannel()
            input.channelId = peer.id
            input.accessHash = if (peer.accessHash != 0) { peer.accessHash } else { getRealMessageService().getAccessHashForChannel(peer.id) }
            return input
        }
        let input = InputPeerUser()
        input.userId = peer.id
        input.accessHash = if (peer.accessHash != 0) { peer.accessHash } else { getRealMessageService().getAccessHashForUser(peer.id) }
        return input
    }

    /**
     * 创建文件夹邀请链接（chatlists.exportChatlistInvite）
     *
     * ctor: 0x8472478e
     * iOS ref: Api42.swift:4405, Communities.swift:75 _internal_exportChatFolder
     *
     * @param filterId  文件夹 ID（对应 DialogFilter.id）
     * @param title     邀请链接标题
     * @param peers     要包含在链接中的 channel/supergroup peers
     * @return ExportedChatFolderLink 成功时返回新链接；失败时返回 title=="" 的空对象
     */
    public func exportChatlistInvite(
        filterId: Int32,
        title: String,
        peers: ArrayList<FolderShareablePeer>
    ): ExportedChatFolderLink {
        let client = getMTProtoClient()

        let req = ChatlistsExportChatlistInvite()
        req.filterId = filterId
        req.title = title
        for (p in peers) {
            if (p.isSelected && p.isAvailable) {
                req.peers.add(this.shareInputPeerFor(p))
            }
        }

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] exportChatlistInvite: empty response")
            return ExportedChatFolderLink()
        }

        let d = TLDeserializer(responseData)
        let outerCtor = d.readUInt32()

        if (outerCtor == TLConstructors.RPC_ERROR || outerCtor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] exportChatlistInvite error: ${errMsg}")
            return ExportedChatFolderLink()
        }

        // chatlists.ExportedChatlistInvite#10e6e3a6 (filter, invite)
        // iOS ref: Api34.swift:296
        if (outerCtor == 0x10e6e3a6) {
            return parseExportedChatlistInviteResponse(d)
        }

        Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] exportChatlistInvite: unexpected ctor 0x${outerCtor}")
        return ExportedChatFolderLink()
    }

    /**
     * 获取文件夹邀请链接列表（chatlists.getExportedInvites）
     *
     * ctor: 0xce03da83
     * iOS ref: Api42.swift:4441, Communities.swift:157 _internal_getExportedChatFolderLinks
     *
     * @param filterId  文件夹 ID
     * @return ArrayList<ExportedChatFolderLink> 链接列表（含已撤销的）
     */
    public func getExportedInvites(filterId: Int32): ArrayList<ExportedChatFolderLink> {
        let client = getMTProtoClient()

        let req = ChatlistsGetExportedInvites()
        req.filterId = filterId

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] getExportedInvites: empty response")
            return ArrayList<ExportedChatFolderLink>()
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()

        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] getExportedInvites error: ${errMsg}")
            return ArrayList<ExportedChatFolderLink>()
        }

        // chatlists.ExportedInvites#10ab6dc7 (invites: Vector<ExportedChatlistInvite>, chats, users)
        // iOS ref: Api34.swift:305
        if (ctor == 0x10ab6dc7) {
            return parseExportedInvitesResponse(d)
        }

        Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] getExportedInvites: unexpected ctor 0x${ctor}")
        return ArrayList<ExportedChatFolderLink>()
    }

    /**
     * 编辑文件夹邀请链接（chatlists.editExportedInvite）
     *
     * ctor: 0x653db63d
     * iOS ref: Api42.swift:4378, Communities.swift:199 _internal_editChatFolderLink
     *   flags bit 0 = revoke, bit 1 = has title, bit 2 = has peers update
     *
     * @param filterId    文件夹 ID
     * @param slug        链接 slug（url去掉 "https://t.me/addlist/" 前缀）
     * @param newTitle    新标题（None = 不修改）
     * @param peers       新 peer 列表（None = 不修改）
     * @param revoke      true = 撤销链接（设置 bit 0）
     * @return 更新后的 ExportedChatFolderLink；失败时 title==""
     */
    public func editExportedInvite(
        filterId: Int32,
        slug: String,
        newTitle!: String = "",
        hasTitle!: Bool = false,
        peers!: ArrayList<FolderShareablePeer> = ArrayList<FolderShareablePeer>(),
        hasPeers!: Bool = false,
        revoke!: Bool = false
    ): ExportedChatFolderLink {
        let client = getMTProtoClient()

        let req = ChatlistsEditExportedInvite()
        req.filterId = filterId
        req.slug = slug
        req.revoked = revoke
        req.hasTitle = hasTitle
        req.title = newTitle
        req.hasPeers = hasPeers
        if (hasPeers) {
            for (p in peers) {
                if (p.isSelected && p.isAvailable) {
                    req.peers.add(this.shareInputPeerFor(p))
                }
            }
        }

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] editExportedInvite: empty response")
            return ExportedChatFolderLink()
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()

        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] editExportedInvite error: ${errMsg}")
            return ExportedChatFolderLink()
        }

        // ExportedChatlistInvite#0c5181ac (flags title url peers)
        // iOS ref: Api7.swift:669
        if (ctor == 0x0c5181ac) {
            return parseExportedChatlistInviteDirect(d)
        }

        Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] editExportedInvite: unexpected ctor 0x${ctor}")
        return ExportedChatFolderLink()
    }

    /**
     * 删除文件夹邀请链接（chatlists.deleteExportedInvite）
     *
     * ctor: 0x719c5c5e
     * iOS ref: Api42.swift:4362, Communities.swift:238 _internal_deleteChatFolderLink
     *
     * @param filterId  文件夹 ID
     * @param slug      链接 slug（url去掉 "https://t.me/addlist/" 前缀）
     * @return true = 删除成功
     */
    public func deleteExportedInvite(filterId: Int32, slug: String): Bool {
        let client = getMTProtoClient()

        let req = ChatlistsDeleteExportedInvite()
        req.filterId = filterId
        req.slug = slug

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] deleteExportedInvite: empty response")
            return false
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()

        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] deleteExportedInvite error: ${errMsg}")
            return false
        }

        return ctor == TLConstructors.BOOL_TRUE
    }

    /**
     * 上报聊天文件夹重排后的顺序（messages.updateDialogFiltersOrder）
     *
     * ctor: 0xc563c1e4
     * iOS ref: telegram_api.tl:2314, ChatListFiltering.swift:549/1599 _internal_updateChatListFilterOrder
     * TC-0015 (clist_filter_preset_editor): 文件夹拖拽重排后台上报，本地优先生效、后台异步上报。
     *
     * @param order 新的 filter id 顺序（含 All Chats 的 id==0），与本地已生效顺序一致
     * @return true = 服务端确认成功
     */
    public func updateDialogFiltersOrder(order: ArrayList<Int32>): Bool {
        let client = getMTProtoClient()

        let req = MessagesUpdateDialogFiltersOrder()
        req.order = order

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] updateDialogFiltersOrder: empty response")
            return false
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()

        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] updateDialogFiltersOrder error: ${errMsg}")
            return false
        }

        return ctor == TLConstructors.BOOL_TRUE
    }

    /**
     * 创建/更新单个聊天文件夹（messages.updateDialogFilter）
     *
     * ctor: 0x1ad4a04a
     * iOS ref: telegram_api.tl:2313, ChatListFiltering.swift:524 _internal_requestUpdateChatListFilter
     * TC-0015 round4 (clist_filter_preset_editor): 文件夹创建/推荐添加提交后持久化到服务端。
     * 本地已生效、后台异步上报，模式对齐已工作的 updateDialogFiltersOrder。
     *
     * @param folder 待创建/更新的文件夹（id 必须已本地分配）
     * @return true = 服务端确认成功
     */
    public func updateDialogFilter(folder: ChatFolder): Bool {
        let client = getMTProtoClient()

        let req = MessagesUpdateDialogFilter()
        req.filterId = folder.id
        req.title = folder.name
        req.isShared = folder.isShared
        req.hasFilter = true
        // S029：布尔位 / emoticon / 三个 peer 向量（iOS ChatListFilter.apiFilter()）
        req.includeContacts = folder.includeContacts
        req.includeNonContacts = folder.includeNonContacts
        req.includeGroups = folder.includeGroups
        req.includeChannels = folder.includeChannels
        req.includeBots = folder.includeBots
        req.excludeMuted = folder.excludeMuted
        req.excludeRead = folder.excludeRead
        req.excludeArchived = folder.excludeArchived
        req.emoticon = if (!folder.emoticon.isEmpty()) { folder.emoticon } else { folder.icon }
        req.hasColor = folder.hasColor || folder.color >= 0
        req.color = folder.color
        for (id in folder.pinnedPeers) {
            match (resolveInputPeerFromCache(id)) {
                case Some(p) => req.pinnedPeers.add(p)
                case None => Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] pinned peer ${id} not in cache, skipped")
            }
        }
        if (!folder.includePeerRefs.isEmpty()) {
            for (peer in folder.includePeerRefs) { req.includePeers.add(this.inputPeerFor(peer)) }
        } else {
            for (id in folder.includePeers) {
                match (resolveInputPeerFromCache(id)) {
                    case Some(p) => req.includePeers.add(p)
                    case None => Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] include peer ${id} not in cache, skipped")
                }
            }
        }
        if (!folder.isShared) {
            if (!folder.excludePeerRefs.isEmpty()) {
                for (peer in folder.excludePeerRefs) { req.excludePeers.add(this.inputPeerFor(peer)) }
            } else {
                for (id in folder.excludePeers) {
                    match (resolveInputPeerFromCache(id)) {
                        case Some(p) => req.excludePeers.add(p)
                        case None => Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] exclude peer ${id} not in cache, skipped")
                    }
                }
            }
        }
        Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] updateDialogFilter id=${folder.id} include=${req.includePeers.size} exclude=${req.excludePeers.size} pinned=${req.pinnedPeers.size}")

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] updateDialogFilter: empty response")
            return false
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()

        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] updateDialogFilter error: ${errMsg}")
            return false
        }

        return ctor == TLConstructors.BOOL_TRUE
    }

    public func toggleDialogFilterTags(enabled: Bool): Bool {
        let req = MessagesToggleDialogFilterTags()
        req.enabled = enabled
        let responseData = getMTProtoClient().sendRequest(req.toBytes())
        if (responseData.size < 4) { return false }
        let d = TLDeserializer(responseData)
        return d.readUInt32() == TLConstructors.BOOL_TRUE
    }

    /**
     * 删除单个聊天文件夹（messages.updateDialogFilter，filter 字段省略即删除语义）
     *
     * ctor: 0x1ad4a04a（与 updateDialogFilter 共用同一 TL 方法，flags bit0 不置位）
     * iOS ref: ChatListFiltering.swift:526 filter: nil 分支
     *
     * @param filterId 待删除的文件夹 id
     * @return true = 服务端确认成功
     */
    public func deleteDialogFilter(filterId: Int32): Bool {
        let client = getMTProtoClient()

        let req = MessagesUpdateDialogFilter()
        req.filterId = filterId
        req.hasFilter = false

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] deleteDialogFilter: empty response")
            return false
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()

        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] deleteDialogFilter error: ${errMsg}")
            return false
        }

        return ctor == TLConstructors.BOOL_TRUE
    }

    // ==================== 私有解析函数 ====================

    /**
     * 解析 chatlists.ExportedChatlistInvite#10e6e3a6 响应
     * 结构: filter (DialogFilter, boxed) + invite (ExportedChatlistInvite#0c5181ac, boxed)
     * iOS ref: Api34.swift:284-301, Api5.swift:1935-2023
     *
     * DialogFilter variants (iOS Api0.swift:246-248):
     *   dialogFilter#aa472651        — flags id title emoticon? color? pinnedPeers includePeers excludePeers
     *   dialogFilterChatlist#96537bd7 — flags id title emoticon? color? pinnedPeers includePeers
     *   dialogFilterDefault#363293ae  — no fields
     */
    private func parseExportedChatlistInviteResponse(d: TLDeserializer): ExportedChatFolderLink {
        // Read and skip filter:DialogFilter (boxed — ctor already consumed by caller)
        let filterCtor = d.readUInt32()
        skipDialogFilterBody(d, filterCtor)

        // Read invite:ExportedChatlistInvite (boxed)
        let inviteCtor = d.readUInt32()
        if (inviteCtor != 0x0c5181ac) {
            Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] parseExportedChatlistInviteResponse: unexpected invite ctor 0x${inviteCtor}")
            return ExportedChatFolderLink()
        }
        return parseExportedChatlistInviteDirect(d)
    }

    /**
     * 按 DialogFilter 变体跳过其字段（ctor 已读取）
     * iOS Api5.swift:1935-2023
     *
     * dialogFilter#aa472651:        flags:# id:int title:TextWithEntities emoticon:flags.25?string
     *                               color:flags.27?int pinnedPeers:Vector<InputPeer>
     *                               includePeers:Vector<InputPeer> excludePeers:Vector<InputPeer>
     * dialogFilterChatlist#96537bd7: flags:# id:int title:TextWithEntities emoticon:flags.25?string
     *                               color:flags.27?int pinnedPeers:Vector<InputPeer>
     *                               includePeers:Vector<InputPeer>
     * dialogFilterDefault#363293ae:  (no fields)
     */
    private func skipDialogFilterBody(d: TLDeserializer, filterCtor: UInt32): Unit {
        if (filterCtor == 0x363293ae) {
            // dialogFilterDefault — no fields
            return
        }
        if (filterCtor != 0xaa472651 && filterCtor != 0x96537bd7) {
            Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] skipDialogFilterBody: unknown filter ctor 0x${filterCtor}")
            return
        }
        // Common: flags:# id:int title:TextWithEntities
        let flags = d.readInt32()
        let _ = d.readInt32() // id
        // title: TextWithEntities#751f3146 (boxed) — ctor + string + Vector<MessageEntity>
        let titleCtor = d.readUInt32()
        if (titleCtor == 0x751f3146) {
            let _ = d.readString()
            skipMessageEntityVector(d)
        }
        // emoticon: flags.25?string
        if ((flags & (1 << 25)) != 0) { let _ = d.readString() }
        // color: flags.27?int
        if ((flags & (1 << 27)) != 0) { let _ = d.readInt32() }
        // pinnedPeers: Vector<InputPeer>
        skipInputPeerVector(d)
        // includePeers: Vector<InputPeer>
        skipInputPeerVector(d)
        // excludePeers: Vector<InputPeer> — only present in dialogFilter, not dialogFilterChatlist
        if (filterCtor == 0xaa472651) {
            skipInputPeerVector(d)
        }
    }

    /**
     * 跳过 Vector<MessageEntity>（boxed vector）
     * MessageEntity 每个变体都以 ctor(UInt32)+offset(Int32)+length(Int32) 开头，
     * 附加字段依变体而异；此处按各变体逐一跳过。
     * iOS Api5.swift: MessageEntity variants
     */
    private func skipMessageEntityVector(d: TLDeserializer): Unit {
        let vecCtor = d.readUInt32()
        if (vecCtor != 0x1cb5c415) { return } // not VECTOR
        let count = d.readInt32()
        var i: Int64 = 0
        while (i < Int64(count)) {
            let eCtor = d.readUInt32()
            let _ = d.readInt32() // offset
            let _ = d.readInt32() // length
            // variants with extra fields (iOS Api5.swift):
            // messageEntityMentionName#dc7b1140 — user_id:Int64 (iOS Api0.swift:683)
            // inputMessageEntityMentionName#208e68c9 — user_id:InputUser (boxed: ctor+id+hash)
            // messageEntityCustomEmoji#c8cf05f8 — document_id:Int64
            // messageEntityPre#73924be0 — language:string
            // messageEntityTextUrl#76a6d327 — url:string
            if (eCtor == 0xdc7b1140) {
                let _ = d.readInt64() // user_id
            } else if (eCtor == 0x208e68c9) {
                let _ = d.readUInt32() // inputUser ctor
                let _ = d.readInt64() // user_id
                let _ = d.readInt64() // access_hash
            } else if (eCtor == 0xc8cf05f8) {
                let _ = d.readInt64() // document_id
            } else if (eCtor == 0x73924be0) {
                let _ = d.readString() // language
            } else if (eCtor == 0x76a6d327) {
                let _ = d.readString() // url
            }
            // all other entity types: only offset+length (already read above)
            i = i + 1
        }
    }

    /**
     * 跳过 Vector<InputPeer>（boxed vector；每个 InputPeer 按 ctor 跳过）
     * iOS Api0.swift:456-462, Api12.swift:388-467
     */
    private func skipInputPeerVector(d: TLDeserializer): Unit {
        let vecCtor = d.readUInt32()
        if (vecCtor != 0x1cb5c415) { return } // not VECTOR
        let count = d.readInt32()
        var i: Int64 = 0
        while (i < Int64(count)) {
            let pCtor = d.readUInt32()
            if (pCtor == 0x7f3b18ea || pCtor == 0x7da07ec9) {
                // inputPeerEmpty / inputPeerSelf — no fields
            } else if (pCtor == 0x35a95cb9) {
                let _ = d.readInt64() // chat_id
            } else if (pCtor == 0xdde8a54c) {
                let _ = d.readInt64() // user_id
                let _ = d.readInt64() // access_hash
            } else if (pCtor == 0x27bcbbfc) {
                let _ = d.readInt64() // channel_id
                let _ = d.readInt64() // access_hash
            } else if (pCtor == 0xbd2a0840 || pCtor == 0xa87b0a1c) {
                // inputPeerChannelFromMessage / inputPeerUserFromMessage
                // peer:InputPeer (boxed) + msg_id:Int32 + channel_id/user_id:Int64
                let innerCtor = d.readUInt32()
                skipSingleInputPeerBody(d, innerCtor)
                let _ = d.readInt32() // msg_id
                let _ = d.readInt64() // channel_id or user_id
            }
            i = i + 1
        }
    }

    /**
     * 跳过单个 InputPeer 的字段（ctor 已读）
     */
    private func skipSingleInputPeerBody(d: TLDeserializer, pCtor: UInt32): Unit {
        if (pCtor == 0x7f3b18ea || pCtor == 0x7da07ec9) {
            // no fields
        } else if (pCtor == 0x35a95cb9) {
            let _ = d.readInt64()
        } else if (pCtor == 0xdde8a54c || pCtor == 0x27bcbbfc) {
            let _ = d.readInt64()
            let _ = d.readInt64()
        }
    }

    /**
     * 解析 ExportedChatlistInvite#0c5181ac 内联体
     * 结构: flags:Int32 title:String url:String peers:Vector<Peer>
     * iOS ref: Api7.swift:712-733, Communities.swift:141-147
     *   flags bit 0: isRevoked
     */
    private func parseExportedChatlistInviteDirect(d: TLDeserializer): ExportedChatFolderLink {
        let link = ExportedChatFolderLink()
        let flags = d.readInt32()
        link.isRevoked = (flags & 1) != 0
        link.title = d.readString()
        link.url = d.readString()
        // peers: Vector<Peer> — read vector header then count
        // Peer ctors (iOS Api0.swift:815-817, TLResponses.cj:349-353):
        //   peerUser#59511722    user_id:Int64
        //   peerChat#36c6019a   chat_id:Int64
        //   peerChannel#a2a5371e channel_id:Int64
        let vectorCtor = d.readUInt32()
        if (vectorCtor == 0x1cb5c415) {
            let count = d.readInt32()
            var i: Int64 = 0
            while (i < Int64(count)) {
                let peerCtor = d.readUInt32()
                if (peerCtor == 0x59511722) {
                    let userId = d.readInt64()
                    link.peerIds.add(userId)
                } else if (peerCtor == 0x36c6019a) {
                    let chatId = d.readInt64()
                    link.peerIds.add(chatId)
                } else if (peerCtor == 0xa2a5371e) {
                    let channelId = d.readInt64()
                    link.peerIds.add(channelId)
                }
                i = i + 1
            }
        }
        return link
    }

    /**
     * 解析 chatlists.ExportedInvites#10ab6dc7 响应
     * 结构: invites:Vector<ExportedChatlistInvite> chats:Vector users:Vector
     * iOS ref: Api34.swift:353-375
     */
    private func parseExportedInvitesResponse(d: TLDeserializer): ArrayList<ExportedChatFolderLink> {
        let result = ArrayList<ExportedChatFolderLink>()
        // invites: Vector<ExportedChatlistInvite>
        let vectorCtor = d.readUInt32()
        if (vectorCtor != 0x1cb5c415) {
            Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] parseExportedInvitesResponse: expected VECTOR, got 0x${vectorCtor}")
            return result
        }
        let count = d.readInt32()
        var i: Int64 = 0
        while (i < Int64(count)) {
            let inviteCtor = d.readUInt32()
            if (inviteCtor == 0x0c5181ac) {
                let link = parseExportedChatlistInviteDirect(d)
                result.add(link)
            } else {
                Hilog.info(0, "CjTelegram", "[ChatFolderLinksService] parseExportedInvitesResponse: unexpected invite ctor 0x${inviteCtor}")
            }
            i = i + 1
        }
        return result
    }
}

/**
 * 由会话列表缓存把 peer id 解析为 boxed InputPeer（携带 accessHash）。
 * 先查 chat 缓存（chat/channel），再查 user 缓存；都未命中返回 None（调用方跳过该 peer）。
 */
public func resolveInputPeerFromCache(id: Int64): Option<TLObject> {
    let cl = getRealChatListService()
    match (cl.getCachedChat(id)) {
        case Some(c) =>
            if (c.isChannel) {
                let ch = InputPeerChannel()
                ch.channelId = c.id
                ch.accessHash = c.accessHash
                let obj: TLObject = ch
                return Some(obj)
            } else {
                let g = InputPeerChat()
                g.chatId = c.id
                let obj: TLObject = g
                return Some(obj)
            }
        case None => ()
    }
    match (cl.getCachedUser(id)) {
        case Some(u) =>
            let up = InputPeerUser()
            up.userId = u.id
            up.accessHash = u.accessHash
            let obj: TLObject = up
            return Some(obj)
        case None => ()
    }
    return None
}
