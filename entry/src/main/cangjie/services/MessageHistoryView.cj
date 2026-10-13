package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.models.*
import ohos_app_cangjie_entry.core.storage.postbox.*
import std.collection.ArrayList
import std.collection.HashMap
import std.sync.Mutex

/**
 * MessageHistoryView —— 单会话消息历史的**有序权威容器**。
 *
 * ============================ 为什么要有这一层 ============================
 *
 * 此前 ChatRoomViewModel.messageList 是一个裸 ArrayList：47 个写入点、零排序、
 * 多线程直接整表替换。实测症状是聊天室消息乱序（退出会话再进去顺序才恢复正常）。
 *
 * 对照 iOS，缺的不是「一个锁」，而是**整整一层**：
 *
 *   iOS:  MTProto → AccountStateManager → Postbox(单串行队列)
 *                 → ViewTracker → pipe.putNext → UI 订阅
 *   仓颉: MTProto → UpdatesManager ──→ MessageHistoryTable(已有，仅离线读)
 *                       ↓
 *                 messageList (裸 ArrayList，断层在这)
 *                       ↓ 500ms 指纹轮询
 *                 ChatRoomPage.displayMessages
 *
 * 本类补的就是这一层。乱序、竞态、500ms 轮询、47 个写入点，是同一个缺失的四种症状。
 *
 * ============================ 对齐 iOS 的三点 ============================
 *
 * ① 有序容器 + 二分定位（不是每次写入整表排序）
 *    iOS: OrderedHistoryViewEntries
 *         Telegram-iOS/submodules/Postbox/Sources/MessageHistoryViewState.swift:936
 *         - find(index:)   :1226  ┐
 *         - update(index:) :1261  ├─ 全部走 binarySearch
 *         - remove(index:) :1276  ┘
 *         - insertLowerOrAtAnchorAtArrayIndex :1065  定点插入
 *         注意 :1206 那处 sort 是 fixMonotony 的断言兜底路径，**不是日常写入路径**。
 *    本类: probeLowerBound 同构实现（已由探针 PROBE-V3 在真机验证）。
 *
 * ② 全序键含 namespace（不是只按 id 或只按 timestamp）
 *    iOS: MessageIndex.< (Message.swift:236-250) 优先级 timestamp → namespace → id → peerId
 *         Namespaces.Message.Cloud = 0 / .Local = 1
 *         (TelegramCore/Sources/SyncCore/SyncCore_Namespaces.swift:6-7)
 *    本类: 直接复用本仓已有的 core/storage/postbox/MessageIndex.cj:131-145，
 *         其 compareTo 与 iOS `<` 逐条同序，且自带 selfCheck()。
 *
 *    为什么 namespace 是必需的：本地待发消息用计数器 id（messageIdCounter 初值 100），
 *    服务端消息 id≈1100。同一秒内若按 id 排序，待发消息会被排到已收消息**前面**。
 *    iOS 靠 namespace（Cloud=0 < Local=1）把待发消息压在同秒云消息之后，而不是靠 id。
 *    真机实测（PROBE-V3 ①）：ts=1000 下 {ns=1,id=100} 与 {ns=0,id=1100} → 0:1100,1:100 ✓
 *
 * ③ 增量算子，不整表替换
 *    iOS: MessageHistoryView.swift:593/595 的 .InsertMessage / .Remove 操作集
 *    本类: insert / insertMany / update / replace / remove / replaceAll / prependAll / clear
 *
 * ============================ 线程模型 ============================
 *
 * 本类**不依赖 UI**（不 import ArkUI、不调 launch），对齐 iOS —— Postbox 不认识 UI，
 * 主线程投递由上层 deliverOnMainQueue 负责。
 *
 *   - 内部状态由 Mutex 保护，所有算子**同步生效**（调用后立即可读到新状态）。
 *     不把算子做成 launch{} 异步，是为了避免「写完立刻读还是旧值」的语义陷阱 ——
 *     47 个调用点里有多处写后即读。
 *   - 变更通知走 onChanged 回调，由调用方（ChatRoomViewModel）决定是否包 launch{}
 *     投递到 UI 线程。回调在锁**外**触发，避免调用方在回调里再调本类导致自死锁。
 *
 * 回调即 iOS ValuePipe 的等价物：
 *   ValuePipe.subscribers: Bag<(T)->Void> + putNext 遍历
 *   (Telegram-iOS/submodules/SSignalKit/SwiftSignalKit/Source/ValuePipe.swift:4/31-38)
 *
 * 为什么不用框架自带的 ObservedArrayList.subscribeInner：
 *   实测不可达 —— 该方法在 ArkUI 包装层源码里是 protected
 *   (arkui_cangjie_wrapper/ohos/arkui/state_management/observed_array_list.cj:79/92)，
 *   而 `public class ObservedArrayList<T>` 未加 open，无法继承绕过。
 *   同理 ObservedComplexAbstract.notifyChanges (observed_complex_abstract.cj:99) 亦 protected。
 *   本仓已有同构回调先例：services/UpdatesManager.cj:91/195/937。
 *
 * MTProto 说明（N/A）：纯本地有序容器，不涉及协议编解码。
 */
public class MessageHistoryView {
    /** 云消息命名空间。对齐 iOS Namespaces.Message.Cloud = 0，与 MessageHistoryStore.cj:28 一致。 */
    public static let NS_CLOUD: Int32 = 0
    /** 本地待发/未确认消息命名空间。对齐 iOS Namespaces.Message.Local = 1。 */
    public static let NS_LOCAL: Int32 = 1

    private let lock = Mutex()

    /** 按全序键升序排列的条目。所有定位一律二分，日常写入路径不排序。 */
    private var entries: ArrayList<Message> = ArrayList<Message>()

    /**
     * id → Message 的辅助索引，使「按 id 查找」从 O(n) 线性扫描降到 O(1)。
     *
     * 为什么需要它：iOS 的 update/remove 入参是完整 MessageIndex，可直接二分
     * （MessageHistoryViewState.swift:1261/1276）；而本工程 47 个调用点只持有 id，
     * 拿不到 timestamp/namespace，无法直接构键二分。先用本索引取回 Message，
     * 即可得到它的全序键，再二分定位数组下标 —— 整体 O(1) + O(log n)。
     *
     * 概念上对应 iOS 的 reverseAssociatedIndices（同文件 :943）：同样是为了避免
     * 「已知某个标识、要找它在有序数组中的位置」时退化成线性扫描。
     */
    private var byId: HashMap<Int64, Message> = HashMap<Int64, Message>()

    private var peerId: Int64 = 0
    private var _onChanged: Option<() -> Unit> = None

    /**
     * stableId 分配器。对齐 iOS historyMetadataTable.getNextStableMessageIndexId()
     * （MessageHistoryTable.swift:1090）。单调递增，切换会话不复位 —— 复位会让
     * 新会话的消息拿到与旧会话相同的身份值，若两者同时存在于某个列表就会撞键。
     */
    private var nextStableId: Int64 = 1

    // 命名参数风格与本仓 MessageIndex(peerId!:, namespace!:, ...) 保持一致。
    public init(peerId!: Int64) {
        this.peerId = peerId
    }

    // ==================== 订阅 ====================

    /**
     * 注册变更回调（对齐 iOS ValuePipe 的订阅端）。
     * 回调在锁外执行，可安全地在其中读取本视图。
     */
    public func setOnChanged(handler: () -> Unit): Unit {
        synchronized(this.lock) {
            this._onChanged = Some(handler)
        }
    }

    /** 切换会话时复用同一实例。会清空内容并重置 peerId。 */
    public func rebind(peerId!: Int64): Unit {
        synchronized(this.lock) {
            this.peerId = peerId
            this.entries = ArrayList<Message>()
            this.byId = HashMap<Int64, Message>()
        }
        this.notifyChanged()
    }

    // ==================== 读取 ====================

    /**
     * 当前有序快照（时间正序）。返回**副本**，调用方遍历期间不受并发写影响。
     *
     * 注意：Message 是引用类型，副本里的元素与内部是同一批对象 —— 这与现状一致
     * （下载回填等路径本就原地改 Message 字段）。副本只保证「列表结构」不被并发改动。
     */
    public prop items: ArrayList<Message> {
        get() {
            synchronized(this.lock) {
                let out = ArrayList<Message>()
                for (m in this.entries) {
                    out.add(m)
                }
                return out
            }
        }
    }

    public prop size: Int64 {
        get() {
            synchronized(this.lock) {
                return this.entries.size
            }
        }
    }

    // ==================== 算子 ====================

    /**
     * 有序插入单条。已存在同 (namespace, id) 则先移除旧条目再按新键插入
     * （服务端可能修正 timestamp，此时位置需要跟着变）。
     *
     * @return true 表示列表发生了变化
     */
    public func insert(msg: Message): Bool {
        var changed = false
        synchronized(this.lock) {
            changed = this.insertLocked(msg)
        }
        if (changed) {
            this.notifyChanged()
        }
        return changed
    }

    /** 批量有序插入（轮询回填、向下翻页追加）。 */
    public func insertMany(msgs: ArrayList<Message>): Bool {
        var changed = false
        synchronized(this.lock) {
            for (m in msgs) {
                if (this.insertLocked(m)) {
                    changed = true
                }
            }
        }
        if (changed) {
            this.notifyChanged()
        }
        return changed
    }

    /**
     * 原地更新一条消息（编辑内容、改状态、加 reaction 等）。
     *
     * transform 在锁内执行且只应改 msg 的字段。若改动影响排序键
     * （rawTimestamp / namespace / id），会自动重排到正确位置。
     */
    public func update(id: Int64, transform: (Message) -> Unit): Bool {
        var changed = false
        synchronized(this.lock) {
            match (this.byId.get(id)) {
                case Some(m) =>
                    let beforeKey = this.keyOf(m)
                    transform(m)
                    let afterKey = this.keyOf(m)
                    if (m.id != id) {
                        // transform 改了 id（发送成功后本地计数器 id 换成服务端 id）——
                        // byId 索引必须同步，否则旧 id 残留、新 id 查不到，后续 update/remove 全部落空。
                        //
                        // 换号目标 id 上可能**已经躺着另一个对象**：updateNewMessage 推送常常
                        // 先于 sendMessage 回包到达，onNewMessagePush 只按 id 去重（本地条目
                        // 此刻还是计数器 id，比不上），于是服务端那条已被插进 entries。
                        // 若此处只覆盖 byId，被顶掉的那个对象仍留在 entries 里无人认领 ——
                        // 同一条消息渲染两遍（真机：发一个表情连着出现两条一模一样的气泡，
                        // 但服务端只有一条）。先把它摘掉，再让本地这条接管该 id。
                        match (this.byId.get(m.id)) {
                            case Some(duplicate) =>
                                if (!refEq(duplicate, m)) {
                                    match (this.positionOfLocked(duplicate)) {
                                        case Some(dupPos) => this.entries.remove(at: dupPos)
                                        case None => ()
                                    }
                                }
                            case None => ()
                        }
                        let _ = this.byId.remove(id)
                        this.byId.add(m.id, m)
                    }
                    if (beforeKey != afterKey) {
                        // 排序键变了 —— 按**旧键**二分定位摘出，再按新键定点插回。
                        // 不能用 m 的当前键去找旧位置：transform 已经把它改了。
                        // 对应 iOS：键变即需重定位（OrderedHistoryViewEntries 同样先 remove 再 insert）。
                        match (this.positionOfKeyLocked(beforeKey, m)) {
                            case Some(oldPos) => this.entries.remove(at: oldPos)
                            case None => ()
                        }
                        let newPos = this.lowerBoundLocked(afterKey)
                        this.entries.add(m, at: newPos)
                    }
                    // 键未变时**不搬动数组** —— Message 是引用类型，transform 已原地生效。
                    // 对应 iOS setLowerOrAtAnchorAtArrayIndex（MessageHistoryViewState.swift:987）
                    // 的「位置不变、只换内容」语义。
                    changed = true
                case None => ()
            }
        }
        if (changed) {
            this.notifyChanged()
        }
        return changed
    }

    /**
     * 用服务端返回的消息替换本地待发消息（发送成功后 id 由计数器换成真实 id）。
     * 旧条目按 oldId 移除，新条目按其自身键有序插入。
     */
    public func replace(oldId: Int64, newMsg: Message): Bool {
        var changed = false
        synchronized(this.lock) {
            if (oldId != newMsg.id) {
                match (this.byId.get(oldId)) {
                    case Some(old) =>
                        match (this.positionOfLocked(old)) {
                            case Some(i) => this.entries.remove(at: i)
                            case None => ()
                        }
                        let _ = this.byId.remove(oldId)
                    case None => ()
                }
            }
            changed = this.insertLocked(newMsg)
        }
        if (changed) {
            this.notifyChanged()
        }
        return changed
    }

    /** 按 id 删除。 */
    public func remove(id: Int64): Bool {
        var changed = false
        synchronized(this.lock) {
            match (this.byId.get(id)) {
                case Some(m) =>
                    match (this.positionOfLocked(m)) {
                        case Some(i) =>
                            this.entries.remove(at: i)
                            changed = true
                        case None => ()
                    }
                    let _ = this.byId.remove(id)
                case None => ()
            }
        }
        if (changed) {
            this.notifyChanged()
        }
        return changed
    }

    /**
     * 整表重载。入参无需预先排序 —— 本方法会按全序键重建。
     *
     * ⚠️ **当前无调用者，且不要用它做「服务端历史刷新」**。
     *
     * 曾被 `ChatRoomViewModel.setMessageList` 用于 `getHistory(limit: 30)` 之后的刷新，
     * 结果是把容器里更早的历史整片抹掉。真机 `[RENDER-DBG]` count 序列 `30 → 50 → 30`：
     * 本地秒开 30 条 → `onReachStart` 触发 `prependAll` 补 20 条更早历史（50）
     * → 网络 30 条 `replaceAll` → 刚补的 20 条没了（30）。
     * 长度剧变还会带偏滚动位置、触发大批组件回收复用。
     * 历史刷新一律走 `insertMany`（见 `ChatRoomViewModel.mergeMessageList`）。
     *
     * 保留本方法仅为容器算子的完整性（如整会话重置场景）；
     * 真要「以某批数据为全集」，请先想清楚被丢弃的条目是否都该丢。
     */
    public func replaceAll(msgs: ArrayList<Message>): Unit {
        synchronized(this.lock) {
            this.entries = ArrayList<Message>()
            this.byId = HashMap<Int64, Message>()
            for (m in msgs) {
                let _ = this.insertLocked(m)
            }
        }
        this.notifyChanged()
    }

    /** 向上翻页：把更早的历史并入（有序插入，天然落到前部）。 */
    public func prependAll(msgs: ArrayList<Message>): Bool {
        return this.insertMany(msgs)
    }

    /**
     * 移除 id < lowerId 的云消息（本地待发/失败消息不动），返回移除条数。
     * 用于最新一页与本地旧缓存之间隔着 hole 时，把 hole 以下的缓存移出视图。
     */
    public func removeCloudBelow(lowerId: Int64): Int64 {
        var removed: Int64 = 0
        synchronized(this.lock) {
            let kept = ArrayList<Message>()
            for (m in this.entries) {
                if (m.namespace == MessageHistoryView.NS_CLOUD && m.id > 0 && m.id < lowerId) {
                    let _ = this.byId.remove(m.id)
                    removed += 1
                } else {
                    kept.add(m)
                }
            }
            if (removed > 0) {
                this.entries = kept
            }
        }
        if (removed > 0) {
            this.notifyChanged()
        }
        return removed
    }

    public func clear(): Unit {
        synchronized(this.lock) {
            this.entries = ArrayList<Message>()
            this.byId = HashMap<Int64, Message>()
        }
        this.notifyChanged()
    }

    /**
     * 断言级自检：条目必须按全序键 (timestamp, namespace, id) **严格**升序，且 id 唯一。
     *
     * 对齐 iOS OrderedHistoryViewEntries.fixMonotony（MessageHistoryViewState.swift:1169，:1469 调用）：
     * 日常写入走二分定点插入，从不整表排序；只有检测到单调性被破坏（有人绕过算子原地改了
     * 排序键，或同一 id 残留了两个对象）时才兜底重排。返回检出的违例数（0 = 正常），
     * 调用方负责记录；本方法不触发 onChanged（调用方随后发布的快照即为修正后的结果）。
     */
    public func checkAndFixMonotony(): Int64 {
        var violations: Int64 = 0
        synchronized(this.lock) {
            let seen = HashMap<Int64, Bool>()
            var i: Int64 = 0
            while (i < this.entries.size) {
                let m = this.entries[i]
                if (seen.contains(m.id)) {
                    violations += 1
                } else {
                    seen[m.id] = true
                }
                if (i > 0 && !(this.keyOf(this.entries[i - 1]) < this.keyOf(m))) {
                    violations += 1
                }
                i += 1
            }
            if (violations > 0) {
                // 每个 id 只保留 byId 认领的那个对象（它是最后一次写入的权威版本），再按键重建。
                let rebuilt = ArrayList<Message>()
                let placed = HashMap<Int64, Bool>()
                for (m in this.entries) {
                    if (placed.contains(m.id)) { continue }
                    var keep = m
                    match (this.byId.get(m.id)) {
                        case Some(owner) => keep = owner
                        case None => this.byId.add(m.id, m)
                    }
                    placed[m.id] = true
                    var lo: Int64 = 0
                    var hi: Int64 = rebuilt.size
                    let key = this.keyOf(keep)
                    while (lo < hi) {
                        let mid = lo + (hi - lo) / 2
                        if (this.keyOf(rebuilt[mid]) < key) { lo = mid + 1 } else { hi = mid }
                    }
                    rebuilt.add(keep, at: lo)
                }
                this.entries = rebuilt
            }
        }
        return violations
    }

    // ==================== 内部实现 ====================

    /** 构造该消息的全序键。timestamp/id 超出 Int32 时钳位，避免转换抛异常。 */
    private func keyOf(m: Message): MessageIndex {
        return MessageIndex(
            peerId: this.peerId,
            namespace: m.namespace,
            timestamp: MessageHistoryView.clampToInt32(m.rawTimestamp),
            id: MessageHistoryView.clampToInt32(m.id)
        )
    }

    private static func clampToInt32(v: Int64): Int32 {
        if (v > 2147483647) {
            return 2147483647
        }
        if (v < -2147483648) {
            return -2147483648
        }
        return Int32(v)
    }

    /**
     * 二分下界：返回第一个键 >= target 的位置。O(log n)。
     * 对应 iOS binarySearch（MessageHistoryViewState.swift:1226/1261/1276）。
     * 算法已由 PROBE-V3 在真机三组断言验证（namespace 分序 / timestamp 主序 / 乱序收敛）。
     */
    private func lowerBoundLocked(target: MessageIndex): Int64 {
        var lo: Int64 = 0
        var hi: Int64 = this.entries.size
        while (lo < hi) {
            let mid = lo + (hi - lo) / 2
            if (this.keyOf(this.entries[mid]) < target) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    /**
     * 按给定键二分定位「就是 target 这个对象」的下标。O(log n)。
     * 对应 iOS binarySearch（MessageHistoryViewState.swift:1226/1261/1276）。
     *
     * 用 refEq 做身份确认而非值比较：Message 未实现 Equatable，且这里要的本来就是
     * 「同一个对象」而不是「内容相等」。refEq 见 std.core.cj.d:5387
     * `public func refEq(a: Object, b: Object): Bool`。
     *
     * 兜底：二分未命中时退化为一次线性扫描。这只会在有人绕过算子、原地改了排序键
     * （rawTimestamp/namespace/id）后发生 —— 宁可慢一次，也不静默丢条目。
     */
    private func positionOfKeyLocked(key: MessageIndex, target: Message): Option<Int64> {
        let pos = this.lowerBoundLocked(key)
        if (pos < this.entries.size && refEq(this.entries[pos], target)) {
            return Some(pos)
        }
        var i: Int64 = 0
        while (i < this.entries.size) {
            if (refEq(this.entries[i], target)) {
                return Some(i)
            }
            i = i + 1
        }
        return None
    }

    /** 按对象当前键二分定位其下标。 */
    private func positionOfLocked(target: Message): Option<Int64> {
        return this.positionOfKeyLocked(this.keyOf(target), target)
    }

    /**
     * 锁内有序插入。三条路径，尽量少搬动数组：
     *   ① 同一对象且键未变        → 完全无变化，直接返回 false（不触发推送）
     *   ② 换了对象但键未变        → **原地写**，位置不动
     *   ③ 键变了 / 全新条目       → 摘旧（若有）+ 二分定点插入
     *
     * ② 对应 iOS setLowerOrAtAnchorAtArrayIndex（MessageHistoryViewState.swift:987），
     * 比 remove+add 少一次数组搬移；① 则避免轮询与推送重复送达同一条时的无谓重绘。
     *
     * @return true 表示容器内容发生变化（需要推送）
     */
    private func insertLocked(msg: Message): Bool {
        match (this.byId.get(msg.id)) {
            case Some(old) =>
                // UpdatesManager 的 edit/reaction 更新可能只有消息本体，不带 users/chats；
                // 媒体下载路径和 authorRank 也都是本地派生状态。iOS Postbox 更新单条
                // Message 时保留 peer table 与 MediaBox 状态，这里在统一替换入口完成
                // 同样的缺省字段继承，避免任何局部更新把完整气泡降级成“无名/无图”。
                if (msg.senderId == 0) { msg.senderId = old.senderId }
                if (msg.senderName.size == 0) { msg.senderName = old.senderName }
                if (msg.senderRole.size == 0) { msg.senderRole = old.senderRole }
                if (msg.senderPeerType.size == 0 ||
                    (msg.senderPeerType == "user" && old.senderPeerType != "user" && msg.senderId == old.senderId)) {
                    msg.senderPeerType = old.senderPeerType
                }
                if (msg.replyToSenderName.size == 0) { msg.replyToSenderName = old.replyToSenderName }
                if (msg.replyToText.size == 0 && msg.replyToMsgId == old.replyToMsgId) { msg.replyToText = old.replyToText }
                if (msg.photoLocalPath.size == 0) { msg.photoLocalPath = old.photoLocalPath }
                if (msg.documentLocalPath.size == 0) { msg.documentLocalPath = old.documentLocalPath }
                if (msg.documentThumbnailPath.size == 0) { msg.documentThumbnailPath = old.documentThumbnailPath }
                if (msg.webPagePhotoLocalPath.size == 0) { msg.webPagePhotoLocalPath = old.webPagePhotoLocalPath }
                // 继承既有条目的身份 —— 服务端刷新会带来**全新的 Message 对象**，
                // 若重新分配 stableId，UI 会认为「换了一条消息」而重建组件。
                // 对齐 iOS：updateMessage 沿用 previousMessage.stableId
                // （MessageHistoryTable.swift:1831），以及 StoreMessage 的 customStableId
                // （MessageHistoryTable.swift:1090）。
                if (old.stableId != 0) {
                    msg.stableId = old.stableId
                }
                let oldKey = this.keyOf(old)
                let newKey = this.keyOf(msg)
                if (oldKey == newKey) {
                    if (refEq(old, msg)) {
                        return false                                  // ①
                    }
                    match (this.positionOfKeyLocked(oldKey, old)) {
                        case Some(i) =>
                            this.entries[i] = msg                     // ②
                            this.byId.add(msg.id, msg)
                            return true
                        case None => ()
                    }
                } else {
                    match (this.positionOfKeyLocked(oldKey, old)) {   // ③ 摘旧
                        case Some(i) => this.entries.remove(at: i)
                        case None => ()
                    }
                }
            case None => ()
        }
        if (msg.stableId == 0) {
            msg.stableId = this.nextStableId
            this.nextStableId = this.nextStableId + 1
        }
        let pos = this.lowerBoundLocked(this.keyOf(msg))
        this.entries.add(msg, at: pos)
        this.byId.add(msg.id, msg)
        return true
    }

    /** 在锁外触发回调，避免调用方在回调中回调本类造成自死锁。 */
    private func notifyChanged(): Unit {
        var handler: Option<() -> Unit> = None
        synchronized(this.lock) {
            handler = this._onChanged
        }
        match (handler) {
            case Some(h) =>
                try {
                    h()
                } catch (e: Exception) {
                    Hilog.error(0, "CjTelegram", "[MessageHistoryView] onChanged handler threw: ${e}")
                }
            case None => ()
        }
    }
}
