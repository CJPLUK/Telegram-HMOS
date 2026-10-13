package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.models.*
import ohos_app_cangjie_entry.core.storage.postbox.*
import std.collection.ArrayList
import std.collection.HashSet

/**
 * MessageHistoryStore —— RealMessageService 与本地 Postbox 消息主表之间的桥接层。
 *
 * 单元 P2-287f：让网络拉到的消息落本地 MessageHistoryTable，UI 优先读本地（命中即离线可读），
 * 不足再网络回源并回填。本类把"Message ↔ 本地表"的存储细节集中在一处，避免散进服务层。
 *
 * 对照 iOS local-first 语义（Telegram-iOS Postbox：消息先入库、视图优先从 Postbox 读、
 * 缺口再向网络回源回填）。
 *
 * DB open 容错（最高优先：不破坏现有可运行性）：
 *   工程当前未在启动期 open PostboxDatabase（main_ability 不 open postbox.db），
 *   故本类在首次用到时 lazy open（用 getGlobalAbilityContext() 拿 UIAbilityContext）。
 *   拿不到 context 或 open 抛异常时，所有本地操作安全降级为 no-op / 空结果——
 *   调用方（RealMessageService）据此回退纯网络路径，绝不让消息加载崩。
 *
 * MTProto 说明（N/A）：本地持久化桥接，不涉及 MTProto 协议。
 */
public class MessageHistoryStore {
    // 云消息命名空间常量。对照 iOS Namespaces.Message.Cloud —— 取固定值 0，
    // 与本地表 (peerId, namespace) 复合键的 namespace 段保持一致。
    public static let CLOUD_MESSAGE_NAMESPACE: Int32 = 0

    private let historyTable: MessageHistoryTable
    private let indexTable: MessageHistoryIndexTable
    private let holeTable: MessageHistoryHoleIndexTable

    public init() {
        this.historyTable = MessageHistoryTable()
        this.indexTable = MessageHistoryIndexTable()
        this.holeTable = MessageHistoryHoleIndexTable()
    }

    /**
     * 确保 PostboxDatabase 已 open。
     *
     * 已 open → true。未 open → 尝试用 getGlobalAbilityContext() 拿到的 UIAbilityContext
     * lazy open；context 不可用或 open 抛异常 → false（安全降级，调用方回退网络）。
     */
    private func ensureDbOpen(): Bool {
        let db = PostboxDatabase.getInstance()
        if (db.isOpen()) {
            return true
        }
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    db.open(ctx)
                    return db.isOpen()
                } catch (e: Exception) {
                    Hilog.error(0, "CjTelegram", "[MessageHistoryStore] lazy open failed: ${e}")
                    return false
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[MessageHistoryStore] no ability context, degrade to network")
                return false
        }
    }

    /**
     * 把一批网络回源得到的 Message 落本地表（写入主表 + 维护 id 索引表）。
     *
     * 幂等：底层 ValueBox.set 是 INSERT OR REPLACE 语义，同 (peerId, namespace, timestamp, id)
     * 复合键重复写覆盖、不产生重复行；索引表同理。
     *
     * DB 不可用时静默 no-op（不抛、不崩）。
     *
     * @param peerId   会话 ID（Message 模型无 peerId，由调用方按 getHistory 参数显式传入）
     * @param messages 网络回源、已 parse 的 Message 列表
     */
    public func storeMessages(peerId: Int64, messages: ArrayList<Message>, peerType!: String = "user"): Unit {
        let _ = this.storeMessagesChecked(peerId, messages, peerType)
    }

    /** storeMessages 的实现；整批写入成功返回 true（空批次视为成功），DB 不可用或写入异常返回 false。 */
    private func storeMessagesChecked(peerId: Int64, messages: ArrayList<Message>, peerType: String): Bool {
        if (messages.isEmpty()) {
            return true
        }
        if (!this.ensureDbOpen()) {
            return false
        }
        try {
            let storagePeerId = PeerKey.fromPeerType(peerType, peerId).storageId()
            let ns = MessageHistoryStore.CLOUD_MESSAGE_NAMESPACE
            let ims = ArrayList<IntermediateMessage>()
            let staleRows = ArrayList<MessageIndex>()
            for (m in messages) {
                let im = IntermediateMessage.fromMessage(m, peerId: storagePeerId, namespace: ns)
                ims.add(im)
                // 主表键含 timestamp：同一 id 以不同 timestamp 再写一次会留下两行，
                // 本地读出同一条消息两遍、且落在两个时间位置。iOS 按 MessageId 走索引表
                // 定位旧条目再更新（MessageHistoryTable.updateMessage），这里先删旧行。
                match (this.indexTable.getTimestamp(storagePeerId, ns, Int32(im.id))) {
                    case Some(oldTs) =>
                        if (oldTs != Int32(im.timestamp)) {
                            staleRows.add(MessageIndex(peerId: storagePeerId, namespace: ns,
                                timestamp: oldTs, id: Int32(im.id)))
                        }
                    case None => ()
                }
            }
            if (!staleRows.isEmpty()) {
                this.historyTable.removeMessages(MessageHistoryStore.toIndexArray(staleRows))
            }
            this.historyTable.addMessages(MessageHistoryStore.toImArray(ims))
            // 维护 id 索引（供 offsetId 翻页定位 timestamp）
            for (im in ims) {
                this.indexTable.add(storagePeerId, ns, Int32(im.id), Int32(im.timestamp))
            }
            Hilog.info(0, "CjTelegram", "[MessageHistoryStore] stored ${ims.size} messages for peer=${peerId}")
            return true
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[MessageHistoryStore] storeMessages failed: ${e}")
            return false
        }
    }

    /**
     * 落库一页 messages.getHistory 回包，并按 iOS fetchMessageHistoryHole 的 filledRange 规则
     * 把该页覆盖的 id 区间从 hole 中移除（TelegramCore Holes.swift:1097-1143）。
     *
     * 只有「一次服务端回包的连续 id 段」才能改 hole；推送、会话列表 top message、回复预览、
     * 跳转定位等单条写入一律走 storeMessages，不得扩大区间。区间上下界：
     *   - 向更早翻页（offsetId > 0, addOffset == 0；iOS `.range(start: offsetId-1, end: 1)`，
     *     filledRange = min(ids)...start）：[min(id), offsetId-1]。
     *   - 最新一页（offsetId == 0, addOffset == 0；iOS `.range(start: Int32.max, end: 1)`）：
     *     [min(id), max(id)]。iOS 把上界记到 Int32.max，依赖 AccountStateManager 在
     *     getChannelDifference too long 时重新在顶端开 hole；这里没有那条通道，只认本页实际上界。
     *   - 围绕锚点（offsetId > 0, addOffset < 0；iOS `.aroundId`）：[min(id), max(id)]。
     *   - 「到头」：向更早翻页时服务端正常回包但没有任何消息（iOS ids.count == 0 分支
     *     filledRange = minMaxRange，即整段 hole 连同下界 1 一并填掉）：[1, offsetId-1]。
     *     「正常回包」以 serverCount > 0 判定（messagesSlice / channelMessages 带会话总条数）；
     *     RealMessageService.getHistory 在 RPC 错误 / 空响应时返回的空对象 count 为 0，
     *     分不清「真的到头」和「请求失败」时保留 hole，下次再补。
     *     页内条数少于 limit 不据此判定到头（iOS 同样只认空页）。
     * 本页消息落库失败时不改 hole：区间一旦记为已填充，上翻就只读本地，缺行会被直接跳过。
     *
     * @param serverCount 回包里的会话消息总数（messages.messagesSlice / channelMessages 的 count；0 = 未知）
     */
    public func storeHistoryFill(peerId: Int64, messages: ArrayList<Message>, peerType!: String = "user",
        offsetId!: Int32 = 0, addOffset!: Int32 = 0, serverCount!: Int32 = 0): Unit {
        if (messages.isEmpty()) {
            if (addOffset == 0 && offsetId > 1 && serverCount > 0) {
                this.markFilled(peerId, 1, Int64(offsetId) - 1, peerType: peerType)
                Hilog.info(0, "CjTelegram",
                    "[HistoryHole] fill peer=${peerId} offsetId=${offsetId} empty page (server count=${serverCount}) -> [1,${Int64(offsetId) - 1}] ranges=${this.describeRanges(peerId, peerType)}")
            }
            return
        }
        if (!this.storeMessagesChecked(peerId, messages, peerType)) {
            Hilog.info(0, "CjTelegram",
                "[HistoryHole] fill skipped peer=${peerId} offsetId=${offsetId}: page not persisted")
            return
        }
        var minId: Int64 = 0
        var maxId: Int64 = 0
        for (m in messages) {
            if (m.namespace != MessageHistoryStore.CLOUD_MESSAGE_NAMESPACE || m.id <= 0) { continue }
            if (minId == 0 || m.id < minId) { minId = m.id }
            if (m.id > maxId) { maxId = m.id }
        }
        if (minId == 0) { return }
        let lo: Int64 = minId
        var hi: Int64 = maxId
        if (addOffset == 0 && offsetId > 0) {
            hi = Int64(offsetId) - 1
            // 回包必须全部落在锚点以下，否则不是这次请求定义的那段，不能据此填洞。
            if (maxId > hi) {
                Hilog.info(0, "CjTelegram",
                    "[HistoryHole] fill rejected peer=${peerId} offsetId=${offsetId}: page max ${maxId} >= anchor")
                return
            }
        } else if (!(addOffset == 0 && offsetId == 0) && !(addOffset < 0 && offsetId > 0)) {
            // 其它参数组合（向更新方向等）只落库、不改 hole。
            return
        }
        this.markFilled(peerId, lo, hi, peerType: peerType)
        Hilog.info(0, "CjTelegram",
            "[HistoryHole] fill peer=${peerId} offsetId=${offsetId} addOffset=${addOffset} count=${messages.size} -> [${lo},${hi}] ranges=${this.describeRanges(peerId, peerType)}")
        if (PeerKey.normalizeNamespace(peerType) == PeerKey.CHANNEL) {
            this.removeChannelStrays(peerId, peerType, lo, hi, messages)
        }
    }

    /**
     * 服务端这一页覆盖 [lo, hi]，本地该区间里服务端没返回的频道云消息已被删除。
     *
     * 对齐 iOS HistoryViewStateValidation.swift validateChannelMessagesBatch（:520）/ validateBatch
     * （:957-988）：以 getHistory 校验可见区间，区间内不在回包里的消息 _internal_deleteMessages。
     * 频道删帖若发生在本端离线期间，本地缓存会一直保留已删帖子，长按转发时服务端回 MESSAGE_ID_INVALID。
     */
    private func removeChannelStrays(peerId: Int64, peerType: String, lo: Int64, hi: Int64,
        messages: ArrayList<Message>): Unit {
        try {
            let returned = HashSet<Int64>()
            for (m in messages) {
                if (m.namespace == MessageHistoryStore.CLOUD_MESSAGE_NAMESPACE) { returned.add(m.id) }
            }
            let storagePeerId = PeerKey.fromPeerType(peerType, peerId).storageId()
            let stored = this.historyTable.messagesForPeer(storagePeerId, MessageHistoryStore.CLOUD_MESSAGE_NAMESPACE, 0)
            let strays = ArrayList<Int64>()
            for (im in stored) {
                if (im.id >= lo && im.id <= hi && !returned.contains(im.id)) { strays.add(im.id) }
            }
            if (!strays.isEmpty()) {
                Hilog.info(0, "CjTelegram",
                    "[HistoryValidation] peer=${peerId} [${lo},${hi}] deleting ${strays.size} message(s) missing on server, first=${strays[0]}")
                this.removeMessages(peerId, strays, peerType: peerType)
            }
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[HistoryValidation] stray check failed peer=${peerId}: ${e}")
        }
    }

    /** 该会话已填充区间的日志文本，例如 "[4700,4813] [1,120]"（降序）。 */
    public func describeRanges(peerId: Int64, peerType: String): String {
        if (!this.ensureDbOpen()) { return "?" }
        try {
            let storagePeerId = PeerKey.fromPeerType(peerType, peerId).storageId()
            let ranges = this.holeTable.filledRanges(storagePeerId, MessageHistoryStore.CLOUD_MESSAGE_NAMESPACE)
            if (ranges.isEmpty()) { return "none" }
            var text = ""
            var i = ranges.size - 1
            var shown: Int64 = 0
            while (i >= 0 && shown < 4) {
                let (rLo, rHi) = ranges[i]
                if (text.size > 0) { text = text + " " }
                text = text + "[${rLo},${rHi}]"
                i -= 1
                shown += 1
            }
            if (ranges.size > shown) { text = text + " +${ranges.size - shown}" }
            return text
        } catch (e: Exception) {
            return "?"
        }
    }

    /** 标记 [lo, hi] 已从服务端完整取回（iOS transaction.removeHole）。 */
    public func markFilled(peerId: Int64, lo: Int64, hi: Int64, peerType!: String = "user"): Unit {
        if (lo <= 0 || lo > hi || hi > 2147483647) { return }
        if (!this.ensureDbOpen()) { return }
        try {
            let storagePeerId = PeerKey.fromPeerType(peerType, peerId).storageId()
            this.holeTable.removeHole(storagePeerId, MessageHistoryStore.CLOUD_MESSAGE_NAMESPACE,
                Int32(lo), Int32(hi))
            Hilog.info(0, "CjTelegram", "[MessageHistoryStore] filled ${lo}...${hi} for peer=${peerId}")
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[MessageHistoryStore] markFilled failed: ${e}")
        }
    }

    /**
     * 包含 id 的已填充区间下界（该区间内的本地消息与服务端连续一致）；id 落在 hole 里返回 None。
     */
    public func filledLowerBound(peerId: Int64, id: Int64, peerType!: String = "user"): Option<Int64> {
        if (id <= 0 || id > 2147483647) { return None }
        if (!this.ensureDbOpen()) { return None }
        try {
            let storagePeerId = PeerKey.fromPeerType(peerType, peerId).storageId()
            match (this.holeTable.filledRangeContaining(storagePeerId,
                MessageHistoryStore.CLOUD_MESSAGE_NAMESPACE, Int32(id))) {
                case Some((lo, _)) => return Some(Int64(lo))
                case None => return None
            }
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[MessageHistoryStore] filledLowerBound failed: ${e}")
            return None
        }
    }

    /**
     * 本地优先读：取该 peer 的本地消息（按时间正序），命中即可离线返回。
     *
     * 只读与服务端连续的区段（iOS 历史视图只在两个 hole 之间读 Postbox）：本地表还混有
     * 会话列表 top message、推送、回复预览、搜索/日历跳转写入的零散消息，越过 hole 读会把
     * 几个月前的缓存直接接在当前位置下面。
     *
     * - offsetId == 0（初始加载）：只在最新一个已填充区间 [lo, hi] 覆盖到本地已知最新的云消息时，
     *   返回该区间内最近 limit 条。区间上方还有本地行（推送 / 会话列表 top message 写入、
     *   不与区间相连）说明顶端是 hole —— iOS 此时同样停在 hole 处等网络，这里返回空。
     * - offsetId > 0（向上翻页）：锚点必须位于某个已填充区间内部（lo < offsetId <= hi），
     *   只返回该区间内严格早于锚点的最靠近 limit 条；锚点在 hole 里或恰为区间下界 → 返回空，
     *   由调用方以 offsetId 向服务端分页。
     *
     * 每次判定都打 `[HistoryHole] peer=… anchor=… filled=[a,b] -> local|network` 供回归核对。
     * DB 不可用 / 异常 → 返回空（调用方回退网络）。
     *
     * @return 本地命中的 Message 列表（时间正序）；空表示未命中 / 需回退网络
     */
    public func loadLocalMessages(peerId: Int64, limit: Int32, offsetId: Int32,
        peerType!: String = "user"): ArrayList<Message> {
        let result = ArrayList<Message>()
        if (!this.ensureDbOpen()) {
            return result
        }
        try {
            let storagePeerId = PeerKey.fromPeerType(peerType, peerId).storageId()
            let ns = MessageHistoryStore.CLOUD_MESSAGE_NAMESPACE
            var ims: Array<IntermediateMessage>
            var minAllowedId: Int64 = 0
            var maxAllowedId: Int64 = 0
            if (offsetId > 0) {
                match (this.holeTable.filledRangeContaining(storagePeerId, ns, offsetId)) {
                    case Some((lo, hi)) =>
                        if (lo >= offsetId) {
                            Hilog.info(0, "CjTelegram",
                                "[HistoryHole] peer=${peerId} anchor=${offsetId} filled=[${lo},${hi}] -> network (hole below range)")
                            return result
                        }
                        minAllowedId = Int64(lo)
                        maxAllowedId = Int64(offsetId) - 1
                        Hilog.info(0, "CjTelegram",
                            "[HistoryHole] peer=${peerId} anchor=${offsetId} filled=[${lo},${hi}] -> local")
                    case None =>
                        Hilog.info(0, "CjTelegram",
                            "[HistoryHole] peer=${peerId} anchor=${offsetId} filled=none ranges=${this.describeRanges(peerId, peerType)} -> network")
                        return result
                }
                // 先查索引拿 offsetId 的 timestamp，定位锚点后取更早的 limit 条
                match (this.indexTable.getTimestamp(storagePeerId, ns, offsetId)) {
                    case Some(ts) =>
                        let fromIndex = MessageIndex(
                            peerId: storagePeerId, namespace: ns, timestamp: ts, id: offsetId)
                        ims = this.historyTable.earlierMessages(storagePeerId, ns, fromIndex, Int64(limit))
                    case None =>
                        // 本地无此锚点 → 不命中，回退网络
                        Hilog.info(0, "CjTelegram",
                            "[HistoryHole] peer=${peerId} anchor=${offsetId} not stored locally -> network")
                        return result
                }
            } else {
                let ranges = this.holeTable.filledRanges(storagePeerId, ns)
                if (ranges.isEmpty()) {
                    // 没有任何已填充区间 = iOS 语义下整段都是 hole（新会话初始 1...Int32.max）。
                    Hilog.info(0, "CjTelegram",
                        "[HistoryHole] peer=${peerId} anchor=0 filled=none -> network")
                    return result
                }
                let (latestLo, latestHi) = ranges[ranges.size - 1]
                let all = this.historyTable.messagesForPeer(storagePeerId, ns, 0)
                var newestKnown: Int64 = 0
                for (im in all) {
                    if (im.id > newestKnown) { newestKnown = im.id }
                }
                if (newestKnown > Int64(latestHi)) {
                    Hilog.info(0, "CjTelegram",
                        "[HistoryHole] peer=${peerId} anchor=0 filled=[${latestLo},${latestHi}] newestLocal=${newestKnown} -> network (hole at top)")
                    return result
                }
                minAllowedId = Int64(latestLo)
                maxAllowedId = Int64(latestHi)
                let kept = ArrayList<IntermediateMessage>()
                for (im in all) {
                    if (im.id >= minAllowedId && im.id <= maxAllowedId) { kept.add(im) }
                }
                ims = MessageHistoryStore.tail(MessageHistoryStore.toImArray(kept), limit)
                Hilog.info(0, "CjTelegram",
                    "[HistoryHole] peer=${peerId} anchor=0 filled=[${latestLo},${latestHi}] -> local")
            }
            for (im in ims) {
                if (im.id < minAllowedId || im.id > maxAllowedId) { continue }
                result.add(im.toMessage())
            }
            Hilog.info(0, "CjTelegram", "[MessageHistoryStore] local hit ${result.size} for peer=${peerId}, offsetId=${offsetId}")
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[MessageHistoryStore] loadLocalMessages failed: ${e}")
            return ArrayList<Message>()
        }
        return result
    }

    /**
     * 本地最近 limit 条云消息（时间正序），不按 hole 过滤。
     *
     * 只给「扫一遍本地已知消息」的场景用（例如实时位置页找仍在进行中的 live location，
     * 那些消息靠推送和编辑写入，本来就不在任何已填充区间里）；不得用于拼历史列表。
     */
    public func loadRecentLocalMessages(peerId: Int64, limit: Int32, peerType!: String = "user"): ArrayList<Message> {
        let result = ArrayList<Message>()
        if (!this.ensureDbOpen()) { return result }
        try {
            let storagePeerId = PeerKey.fromPeerType(peerType, peerId).storageId()
            let all = this.historyTable.messagesForPeer(storagePeerId, MessageHistoryStore.CLOUD_MESSAGE_NAMESPACE, 0)
            for (im in MessageHistoryStore.tail(all, limit)) {
                result.add(im.toMessage())
            }
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[MessageHistoryStore] loadRecentLocalMessages failed: ${e}")
            return ArrayList<Message>()
        }
        return result
    }

    /**
     * 从本地表删除某会话的指定消息（主表行 + id 索引）。
     *
     * 对齐 iOS DeleteMessagesInteractively → transaction.deleteMessages：本地删除与服务端请求同时生效，
     * 被删消息不得在冷启动 local-first 读取时复活。先用 id 索引取 timestamp 精确定位主表键；
     * 索引缺失时回退到 (peer,ns) 区间按 id 扫描。DB 不可用时静默 no-op。
     */
    public func removeMessages(peerId: Int64, ids: ArrayList<Int64>, peerType!: String = "user"): Unit {
        if (ids.isEmpty()) { return }
        if (!this.ensureDbOpen()) { return }
        try {
            let storagePeerId = PeerKey.fromPeerType(peerType, peerId).storageId()
            let ns = MessageHistoryStore.CLOUD_MESSAGE_NAMESPACE
            let indices = ArrayList<MessageIndex>()
            for (id64 in ids) {
                let id = Int32(id64)
                match (this.indexTable.getTimestamp(storagePeerId, ns, id)) {
                    case Some(ts) =>
                        indices.add(MessageIndex(peerId: storagePeerId, namespace: ns, timestamp: ts, id: id))
                    case None =>
                        match (this.historyTable.getMessage(storagePeerId, ns, id)) {
                            case Some(im) =>
                                indices.add(MessageIndex(peerId: storagePeerId, namespace: ns,
                                    timestamp: Int32(im.timestamp), id: id))
                            case None => ()
                        }
                }
                this.indexTable.removeId(storagePeerId, ns, id)
            }
            this.historyTable.removeMessages(MessageHistoryStore.toIndexArray(indices))
            Hilog.info(0, "CjTelegram", "[MessageHistoryStore] removed ${indices.size}/${ids.size} messages for peer=${peerId}")
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[MessageHistoryStore] removeMessages failed: ${e}")
        }
    }

    /**
     * 服务端围绕锚点的一页在更早方向回包不足 → 该会话的历史从 historyStartId 开始
     * （iOS Holes.swift：回包少于 limit 即把 hole 一直填到区间下界 1）。
     *
     * 把 [1, historyStartId-1] 标记为已填充，并删掉本地仍残留的更早云消息——本端离线期间
     * 被清空/删除、没收到 updateDeleteMessages 的消息会一直留在表里，翻页时被当作
     * "与服务端连续"的区段读出来，接在服务端历史起点之上（S2-10：日历跳转落点上方冒出
     * 已删除的同日旧消息，日期分隔线因此消失）。
     *
     * @return 被删除的本地消息 id（调用方据此同步视图）
     */
    public func markHistoryStart(peerId: Int64, historyStartId: Int64, peerType!: String = "user"): ArrayList<Int64> {
        let removed = ArrayList<Int64>()
        if (historyStartId <= 1) { return removed }
        if (!this.ensureDbOpen()) { return removed }
        try {
            let storagePeerId = PeerKey.fromPeerType(peerType, peerId).storageId()
            let stored = this.historyTable.messagesForPeer(storagePeerId, MessageHistoryStore.CLOUD_MESSAGE_NAMESPACE, 0)
            for (im in stored) {
                if (im.id > 0 && im.id < historyStartId) { removed.add(im.id) }
            }
            if (!removed.isEmpty()) {
                Hilog.info(0, "CjTelegram",
                    "[HistoryValidation] peer=${peerId} history starts at ${historyStartId}: deleting ${removed.size} cached message(s) below it, first=${removed[0]}")
                this.removeMessages(peerId, removed, peerType: peerType)
            }
            this.markFilled(peerId, 1, historyStartId - 1, peerType: peerType)
            Hilog.info(0, "CjTelegram",
                "[HistoryHole] history start peer=${peerId} at ${historyStartId} -> filled [1,${historyStartId - 1}] ranges=${this.describeRanges(peerId, peerType)}")
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[MessageHistoryStore] markHistoryStart failed peer=${peerId}: ${e}")
        }
        return removed
    }

    /**
     * 按账号全局 id 删除 user / 基础群会话中的消息（updateDeleteMessages 只带 id、不带 peer）。
     *
     * 对齐 iOS AccountStateManagementUtils 对 .deleteMessages(ids) 的处理：
     * transaction.messageIdsForGlobalIds(ids) 反查所属会话后 deleteMessages。
     * channel / secret chat 的 id 是会话内局部的，不参与全局匹配（其删除走带 channel_id 的更新）。
     */
    public func removeMessagesByGlobalIds(ids: ArrayList<Int64>): Unit {
        if (ids.isEmpty()) { return }
        if (!this.ensureDbOpen()) { return }
        try {
            let ns = MessageHistoryStore.CLOUD_MESSAGE_NAMESPACE
            let idSet = HashSet<Int32>()
            for (id in ids) { idSet.add(Int32(id)) }
            let channelFloor = PeerKey.fromPeerType(PeerKey.CHANNEL, 0).storageId()
            let entries = this.indexTable.entriesForGlobalIds(ns, idSet, { storagePeerId: Int64 =>
                storagePeerId > channelFloor
            })
            let indices = ArrayList<MessageIndex>()
            for ((storagePeerId, id, ts) in entries) {
                indices.add(MessageIndex(peerId: storagePeerId, namespace: ns, timestamp: ts, id: id))
                this.indexTable.removeId(storagePeerId, ns, id)
            }
            this.historyTable.removeMessages(MessageHistoryStore.toIndexArray(indices))
            Hilog.info(0, "CjTelegram", "[MessageHistoryStore] global delete removed ${indices.size}/${ids.size} messages")
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[MessageHistoryStore] removeMessagesByGlobalIds failed: ${e}")
        }
    }

    private static func toIndexArray(list: ArrayList<MessageIndex>): Array<MessageIndex> {
        let arr = Array<MessageIndex>(list.size, { _ => MessageIndex(peerId: 0, namespace: 0, timestamp: 0, id: 0) })
        for (i in 0..list.size) {
            arr[i] = list[i]
        }
        return arr
    }

    /** 清除一个会话的云消息主表和 id 索引，供 clear history 成功后立即刷新本地视图。 */
    public func clearPeer(peerId: Int64, peerType!: String = "user"): Unit {
        if (!this.ensureDbOpen()) { return }
        try {
            let storagePeerId = PeerKey.fromPeerType(peerType, peerId).storageId()
            let ns = MessageHistoryStore.CLOUD_MESSAGE_NAMESPACE
            let messages = this.historyTable.messagesForPeer(storagePeerId, ns, 0)
            let indices = Array<MessageIndex>(messages.size, { _ =>
                MessageIndex(peerId: 0, namespace: 0, timestamp: 0, id: 0)
            })
            for (i in 0..messages.size) {
                let message = messages[i]
                indices[i] = MessageIndex(
                    peerId: storagePeerId,
                    namespace: ns,
                    timestamp: Int32(message.timestamp),
                    id: Int32(message.id)
                )
                this.indexTable.removeId(storagePeerId, ns, Int32(message.id))
            }
            this.historyTable.removeMessages(indices)
            this.holeTable.clear(storagePeerId, ns)
            Hilog.info(0, "CjTelegram", "[MessageHistoryStore] cleared ${messages.size} messages for peer=${peerId}")
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[MessageHistoryStore] clearPeer failed: ${e}")
        }
    }

    /**
     * 取数组末尾 count 个元素（保持原顺序）；count <= 0 或数组为空返回空数组。
     * 用于把"最早 limit 条"全量结果截成"最新 limit 条"。
     */
    private static func tail(arr: Array<IntermediateMessage>, count: Int32): Array<IntermediateMessage> {
        if (count <= 0 || arr.size == 0) {
            return Array<IntermediateMessage>(0, { _ => IntermediateMessage() })
        }
        let n = arr.size
        let take = if (Int64(count) < n) { Int64(count) } else { n }
        let start = n - take
        let out = Array<IntermediateMessage>(take, { _ => IntermediateMessage() })
        for (i in 0..take) {
            out[i] = arr[start + i]
        }
        return out
    }

    /**
     * 把 ArrayList<IntermediateMessage> 物化成 Array（保持原顺序），供 addMessages 入参。
     */
    private static func toImArray(list: ArrayList<IntermediateMessage>): Array<IntermediateMessage> {
        let n = list.size
        let arr = Array<IntermediateMessage>(n, { _ => IntermediateMessage() })
        for (i in 0..n) {
            arr[i] = list[i]
        }
        return arr
    }
}

// ==================== 单例访问器 ====================

private var _messageHistoryStoreInstance: Option<MessageHistoryStore> = None

public func getMessageHistoryStore(): MessageHistoryStore {
    match (_messageHistoryStoreInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = MessageHistoryStore()
            _messageHistoryStoreInstance = Some(inst)
            return inst
    }
}
