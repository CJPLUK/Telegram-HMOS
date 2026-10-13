package ohos_app_cangjie_entry.core.storage.postbox

import std.collection.ArrayList

/**
 * MediaResourceIndexTable —— 已缓存媒体资源的「持久化缓存元数据索引」。
 *
 * iOS 标尺：
 *   - Telegram-iOS/submodules/Postbox/Sources/MediaBox.swift
 *       MediaBox 以 resourceId 为单位维护本地缓存文件（cachedRepresentationPathsForId、
 *       collectResourceCacheUsage、removeOtherCachedResources 等），并按 keepDuration
 *       (.general / .shortLived) 决定 GC 优先级；存储用量统计遍历缓存目录累加文件大小。
 *   - Telegram-iOS/submodules/Postbox/Sources/MediaResourceStatus.swift
 *       资源缓存状态（是否完整 / 部分）；本表用 `complete:Bool` 表达「资源是否已完整落盘」。
 *
 * 本单元范围（务实最小面，与 MediaResourcesService.cj 接线）：
 *   媒体文件本身的磁盘缓存已由 MediaResourcesService 实现（buildCachePath/downloadRepresentation
 *   落盘）。本表只补「持久化的缓存元数据索引 + 接线记录 + GC 支持」：
 *     - recordCached(entry)        记录/覆盖一条缓存元数据（落盘成功后调用）
 *     - getEntry(resourceId)       按 resourceId 取回元数据（含 hash 碰撞校验）
 *     - removeEntry(resourceId)    删除一条索引（缓存文件被清理后调用）
 *     - totalCacheSize()           遍历求和，得当前已缓存总字节数（存储用量统计）
 *     - entriesOlderThan(timestamp)按 lastAccess 时间戳过滤出 GC 候选
 *     - allEntries(limit)          枚举全部（limit>0 截断）
 *   显式排除范围：部分下载分片 map（streaming 分片）—— 后续单元职责，本文件不碰。
 *
 * 键类型选择（resourceId 是 String，仓颉 ValueBoxKey 不支持 String 键）：
 *   ValueBoxKey 只提供固定长度大端字节键（setInt64 / setInt32 / setUInt8...），没有 String 键。
 *   两条可行路径：(a) 用 resourceId 的 UTF-8 字节做变长 BinaryKey；(b) 把 resourceId 稳定 hash 成
 *   Int64 做 Int64Key 表。本单元选 (b) ——
 *     - 与工程内既有范式一致：PeerTable / ReadStateTable 都是 Int64Key 表（INTEGER 主键，省存储），
 *       且 services/ICloudResourcesService.cj 已有 djb2 风格 `simpleStringHash(String): Int64`
 *       的稳定哈希先例（「对应 iOS enginePersistentHash32 的等效替代」），本表复用同一 djb2 变体。
 *     - resourceId 可能很长（uniqueId 派生串），变长 BinaryKey 会把整串塞进主键；Int64 hash 键更紧凑。
 *   hash 碰撞防护（关键）：Int64 hash 不是单射，不同 resourceId 可能落到同一键。因此 value 里
 *     **同时完整存 resourceId 原串**；getEntry/removeEntry 在命中后校验 `entry.resourceId == 传入串`，
 *     不相等视作「碰撞落到同槽的另一资源」按未命中处理（不返回、不误删）。这保证语义正确性，
 *     代价是极小概率碰撞下该 resourceId 暂不可索引（可接受：仅元数据索引，缓存文件本体仍在磁盘）。
 *
 * 依赖底座（已合入 master）：
 *   - ValueBox.cj / RdbValueBox.cj —— ValueBoxTable + get/set/remove/scan（KV 引擎）。
 *   - ValueBoxKey.cj               —— 8 字节大端键 setInt64/getInt64。
 *   - PostboxCoding.cj             —— PostboxEncoder / PostboxDecoder（字段级标量编解码）。
 *   - TableRegistry.cj             —— MEDIA_RESOURCE_INDEX_TABLE_ID = 105 + schema checkTable。
 *   - services/MediaResourcesService.cj —— 缓存键(uniqueId)/路径(buildCachePath)/keepDuration 派生源。
 *
 * 表封装范式严格复用 PeerTable.cj / ReadStateTable.cj（Int64Key 表：键=8 字节大端 ValueBoxKey，
 *   值=PostboxEncoder 编码字节）。totalCacheSize/entriesOlderThan/allEntries 走 valueBox.scan
 *   全表遍历，求和/收集载体用一个 `let` ArrayList（引用被闭包捕获、内容可变；KB「闭包不得捕获
 *   本地 var」约束下的标准范式，与 PeerTable.getAllPeers / ReadStateTable.totalUnreadCount 一致）。
 *
 * MTProto 说明（N/A）：本地持久化缓存元数据索引，不涉及 MTProto 协议。
 */

/**
 * MediaResourceCacheEntry —— 单条已缓存媒体资源的元数据值类型。
 *
 * 字段（与 MediaBox 缓存元数据 + MediaResourcesService 对齐）：
 *   - resourceId   ：缓存键（MediaResourcesService 的 uniqueId / resource 唯一标识）。**完整存于 value**
 *                    以做 hash 碰撞校验。
 *   - localPath    ：缓存文件磁盘绝对路径（MediaResourcesService.buildCachePath 的结果）。
 *   - size         ：缓存文件字节数（存储用量统计求和的基数）。
 *   - timestamp    ：最近访问时间（lastAccess，毫秒/秒由调用方约定；GC 按此过滤旧条目）。
 *   - complete     ：资源是否已完整落盘（对应 MediaResourceStatus 完整 vs 部分；部分分片 map 不在本单元）。
 *   - keepDuration ：缓存保持时长策略原始值（对齐 MediaResourcesService.CachedRepresentationKeepDuration：
 *                    KEEP_GENERAL=0 长期 / KEEP_SHORT_LIVED=1 短暂可优先清理）。GC 据此分级。
 *
 * 用 class（与工程内 IntermediatePeer / PeerReadState 纯数据类风格一致；落盘项需可变字段聚合）。
 * encode(PostboxEncoder) / static decode(PostboxDecoder) 与底座编解码层对称；缺字段 decode
 * 回落默认值（向后兼容旧库）。
 */
public class MediaResourceCacheEntry {
    public var resourceId: String
    public var localPath: String
    public var size: Int64
    public var timestamp: Int64
    public var complete: Bool
    public var keepDuration: Int32

    // ---- keepDuration 取值常量（对齐 MediaResourcesService.CachedRepresentationKeepDuration）----
    /** 通用长期缓存（对应 iOS .general / CachedRepresentationKeepDuration.General）。 */
    public static let KEEP_GENERAL: Int32 = 0
    /** 短暂缓存，GC 可优先清理（对应 iOS .shortLived / CachedRepresentationKeepDuration.ShortLived）。 */
    public static let KEEP_SHORT_LIVED: Int32 = 1

    public init(
        resourceId!: String,
        localPath!: String = "",
        size!: Int64 = 0,
        timestamp!: Int64 = 0,
        complete!: Bool = false,
        keepDuration!: Int32 = MediaResourceCacheEntry.KEEP_GENERAL
    ) {
        this.resourceId = resourceId
        this.localPath = localPath
        this.size = size
        this.timestamp = timestamp
        this.complete = complete
        this.keepDuration = keepDuration
    }

    /**
     * 编码到 PostboxEncoder（字段级标量编解码）。字段 key 用短稳定串，与 decode 对称。
     */
    public func encode(encoder: PostboxEncoder): Unit {
        encoder.encodeString(this.resourceId, key: "ri")
        encoder.encodeString(this.localPath, key: "lp")
        encoder.encodeInt64(this.size, key: "sz")
        encoder.encodeInt64(this.timestamp, key: "ts")
        encoder.encodeBool(this.complete, key: "cp")
        encoder.encodeInt32(this.keepDuration, key: "kd")
    }

    /**
     * 从 PostboxDecoder 还原（与 encode 严格对称）。缺字段回落默认值（向后兼容旧库）。
     */
    public static func decode(decoder: PostboxDecoder): MediaResourceCacheEntry {
        let resourceId = decoder.decodeString("ri", orElse: "")
        let localPath = decoder.decodeString("lp", orElse: "")
        let size = decoder.decodeInt64("sz", orElse: 0)
        let timestamp = decoder.decodeInt64("ts", orElse: 0)
        let complete = decoder.decodeBool("cp", orElse: false)
        let keepDuration = decoder.decodeInt32("kd", orElse: MediaResourceCacheEntry.KEEP_GENERAL)
        return MediaResourceCacheEntry(
            resourceId: resourceId,
            localPath: localPath,
            size: size,
            timestamp: timestamp,
            complete: complete,
            keepDuration: keepDuration
        )
    }
}

/**
 * MediaResourceIndexTable —— 媒体缓存元数据索引表
 *   （持有 ValueBoxTable(MEDIA_RESOURCE_INDEX_TABLE_ID, Int64Key) + ValueBox）。
 *
 * 键 = resourceId 的 djb2 稳定 hash 编成的 8 字节大端 ValueBoxKey（Int64Key 表，底层 INTEGER 主键）。
 * 值 = MediaResourceCacheEntry 的 PostboxEncoder 编码字节（内含完整 resourceId 供碰撞校验）。
 */
public class MediaResourceIndexTable {
    // 本表逻辑描述符：int64 键（resourceId 的 hash），值是 BLOB。
    private let table: ValueBoxTable
    // 底层通用 KV 引擎（复用进程内单例，与 PostboxDatabase 同一 RDB 连接）。
    private let valueBox: ValueBox

    /**
     * 用进程内单例 ValueBox（RdbValueBox）构造（推荐路径）。
     * 表描述符固定为 (MEDIA_RESOURCE_INDEX_TABLE_ID, Int64Key)。
     */
    public init() {
        this.table = ValueBoxTable(
            id: TableRegistry.MEDIA_RESOURCE_INDEX_TABLE_ID,
            keyType: ValueBoxKeyType.Int64Key
        )
        this.valueBox = RdbValueBox.getInstance()
    }

    /**
     * 注入式构造（测试 / 自定义 ValueBox 实现时使用）。
     */
    public init(valueBox: ValueBox) {
        this.table = ValueBoxTable(
            id: TableRegistry.MEDIA_RESOURCE_INDEX_TABLE_ID,
            keyType: ValueBoxKeyType.Int64Key
        )
        this.valueBox = valueBox
    }

    /**
     * resourceId 稳定 hash（djb2 变体；与 services/ICloudResourcesService.simpleStringHash 同算法，
     * 「对应 iOS enginePersistentHash32 的等效替代」）。相同输入恒得相同输出。
     * 结果 `& 0x7FFFFFFFFFFFFFFF` 落非负 Int63 区间，规避溢出且对 Int64Key 大端编码友好。
     */
    private static func hashResourceId(resourceId: String): Int64 {
        var hash: Int64 = 5381
        for (r in resourceId.toRuneArray()) {
            let code = Int64(UInt32(r))
            hash = ((hash * 33) ^ code) & 0x7FFFFFFFFFFFFFFF
        }
        return hash
    }

    /**
     * 把 resourceId 的 hash 编成 8 字节大端键（Int64Key 表，对应底层 INTEGER 主键）。
     */
    private static func keyForResource(resourceId: String): ValueBoxKey {
        let k = ValueBoxKey(length: 8)
        k.setInt64(0, MediaResourceIndexTable.hashResourceId(resourceId))
        return k
    }

    /**
     * 把一条 entry 编码成落库值字节。
     */
    private static func encodeValue(entry: MediaResourceCacheEntry): Array<Byte> {
        let encoder = PostboxEncoder()
        entry.encode(encoder)
        return encoder.makeBytes()
    }

    /**
     * 把落库值字节解码回 MediaResourceCacheEntry。
     */
    private static func decodeValue(bytes: Array<Byte>): MediaResourceCacheEntry {
        return MediaResourceCacheEntry.decode(PostboxDecoder(bytes))
    }

    /**
     * 记录 / 覆盖一条缓存元数据（缓存文件落盘成功后调用）。
     * 键 = keyForResource(entry.resourceId)；值 = encode(entry)。INSERT OR REPLACE：同 hash 槽覆盖。
     *
     * 接线对象：MediaResourcesService 缓存写入成功（writeBytes 返回 true）后，可构造一条 entry
     *   （resourceId = repr.uniqueId() 衍生键、localPath = targetPath、size = data.size、
     *    timestamp = now、complete = true、keepDuration 由 repr.keepDuration() 映射）调用本方法。
     */
    public func recordCached(entry: MediaResourceCacheEntry): Unit {
        let key = MediaResourceIndexTable.keyForResource(entry.resourceId)
        let value = MediaResourceIndexTable.encodeValue(entry)
        this.valueBox.set(this.table, key, value)
    }

    /**
     * 按 resourceId 取单条元数据。命中后校验解码出的 resourceId 与传入串相等（hash 碰撞防护）：
     *   相等返回 Some(entry)；不相等（碰撞落到另一资源）按未命中返回 None；底层未命中返回 None。
     */
    public func getEntry(resourceId: String): Option<MediaResourceCacheEntry> {
        let key = MediaResourceIndexTable.keyForResource(resourceId)
        match (this.valueBox.get(this.table, key)) {
            case Some(bytes) =>
                let entry = MediaResourceIndexTable.decodeValue(bytes)
                if (entry.resourceId == resourceId) {
                    return Some(entry)
                }
                // hash 碰撞：同槽落的是另一资源，按未命中处理。
                return None
            case None => return None
        }
    }

    /**
     * 单条元数据是否存在（含碰撞校验）。
     */
    public func containsEntry(resourceId: String): Bool {
        match (this.getEntry(resourceId)) {
            case Some(_) => return true
            case None => return false
        }
    }

    /**
     * 按 resourceId 删除一条索引（缓存文件被清理后调用）。
     * 碰撞防护：先校验同槽落库的确是该 resourceId，相等才删；否则不动（避免误删碰撞到同槽的另一资源）。
     */
    public func removeEntry(resourceId: String): Unit {
        let key = MediaResourceIndexTable.keyForResource(resourceId)
        match (this.valueBox.get(this.table, key)) {
            case Some(bytes) =>
                let entry = MediaResourceIndexTable.decodeValue(bytes)
                if (entry.resourceId == resourceId) {
                    this.valueBox.remove(this.table, key)
                }
                // 不相等：碰撞落到另一资源，不误删。
            case None => ()
        }
    }

    /**
     * 当前已缓存总字节数（存储用量统计）。走 valueBox.scan 全表遍历累加各 entry.size。
     *
     * 求和载体：用一个单元素 `let` ArrayList<Int64> 承载累计值，闭包改其内容（引用不变；KB「闭包
     * 不得捕获本地 var」约束下的标准范式，与 ReadStateTable.totalUnreadCount 一致）。
     */
    public func totalCacheSize(): Int64 {
        let acc = ArrayList<Int64>()
        acc.add(0)
        this.valueBox.scan(this.table, { _, v =>
            let entry = MediaResourceIndexTable.decodeValue(v)
            acc[0] = acc[0] + entry.size
            return true
        })
        return acc[0]
    }

    /**
     * GC 候选：返回 timestamp（lastAccess）严格早于给定 threshold 的全部条目。
     * 走 valueBox.scan 全表遍历，过滤收集进一个 `let` ArrayList（引用被闭包捕获、内容可变）。
     */
    public func entriesOlderThan(threshold: Int64): Array<MediaResourceCacheEntry> {
        let collected = ArrayList<MediaResourceCacheEntry>()
        this.valueBox.scan(this.table, { _, v =>
            let entry = MediaResourceIndexTable.decodeValue(v)
            if (entry.timestamp < threshold) {
                collected.add(entry)
            }
            return true
        })
        return MediaResourceIndexTable.toArray(collected)
    }

    /**
     * 枚举全部条目（limit > 0 取前 limit 条后早停，limit <= 0 不限）。
     * 收集范式同 PeerTable.getAllPeers：结果进 `let` ArrayList，早停计数用 `let` ArrayList<Int64>。
     */
    public func allEntries(limit: Int64): Array<MediaResourceCacheEntry> {
        let collected = ArrayList<MediaResourceCacheEntry>()
        let counter = ArrayList<Int64>()
        counter.add(0)
        this.valueBox.scan(this.table, { _, v =>
            collected.add(MediaResourceIndexTable.decodeValue(v))
            counter[0] = counter[0] + 1
            if (limit > 0 && counter[0] >= limit) {
                return false
            }
            return true
        })
        return MediaResourceIndexTable.toArray(collected)
    }

    /**
     * 收集容器 ArrayList 物化成 Array（保持原顺序）。与 PeerTable.toArray 同范式
     * （Array 固定长度构造需元素工厂，用一个占位项填充后逐位覆盖）。
     */
    private static func toArray(list: ArrayList<MediaResourceCacheEntry>): Array<MediaResourceCacheEntry> {
        let n = list.size
        let arr = Array<MediaResourceCacheEntry>(n, { _ => MediaResourceIndexTable.seedEntry() })
        for (i in 0..n) {
            arr[i] = list[i]
        }
        return arr
    }

    /**
     * Array 固定长度构造所需的种子元素（随即被逐位覆盖，不参与逻辑）。
     */
    private static func seedEntry(): MediaResourceCacheEntry {
        return MediaResourceCacheEntry(resourceId: "")
    }

    /**
     * 自检（验收项②）：需要一个「已 open 的 PostboxDatabase（真实 RDB）」，因此只在设备 / 集成
     * 诊断时显式调用，不在 app 主流程自动运行（与 PeerTable.selfCheck / ReadStateTable.selfCheck
     * 的定位一致）。DB 不可用时调用方负责 try/catch（见接线说明）。
     *
     * 验证：
     *   ② recordCached -> getEntry 往返字段相等；totalCacheSize 求和正确；
     *      entriesOlderThan 过滤正确；removeEntry 后 getEntry 返 None；allEntries 枚举 + limit 截断。
     * 全部断言通过返回 true，任一不符返回 false。
     */
    public func selfCheck(): Bool {
        let e1 = MediaResourceCacheEntry(
            resourceId: "res-alpha-沙",
            localPath: "/data/cache/alpha",
            size: 1000,
            timestamp: 100,
            complete: true,
            keepDuration: MediaResourceCacheEntry.KEEP_GENERAL
        )
        let e2 = MediaResourceCacheEntry(
            resourceId: "res-beta",
            localPath: "/data/cache/beta",
            size: 2500,
            timestamp: 500,
            complete: false,
            keepDuration: MediaResourceCacheEntry.KEEP_SHORT_LIVED
        )
        let e3 = MediaResourceCacheEntry(
            resourceId: "res-gamma",
            localPath: "/data/cache/gamma",
            size: 700,
            timestamp: 50,
            complete: true,
            keepDuration: MediaResourceCacheEntry.KEEP_GENERAL
        )
        let all = [e1, e2, e3]

        // 清场：先删全部（避免上一轮残留）。
        for (e in all) {
            this.removeEntry(e.resourceId)
        }

        // ② recordCached -> getEntry 往返字段相等。
        for (e in all) {
            this.recordCached(e)
        }
        match (this.getEntry("res-alpha-沙")) {
            case Some(got) =>
                if (got.resourceId != "res-alpha-沙") { return false }
                if (got.localPath != "/data/cache/alpha") { return false }
                if (got.size != 1000) { return false }
                if (got.timestamp != 100) { return false }
                if (!got.complete) { return false }
                if (got.keepDuration != MediaResourceCacheEntry.KEEP_GENERAL) { return false }
            case None => return false
        }
        match (this.getEntry("res-beta")) {
            case Some(got) =>
                if (got.size != 2500) { return false }
                if (got.complete) { return false }
                if (got.keepDuration != MediaResourceCacheEntry.KEEP_SHORT_LIVED) { return false }
            case None => return false
        }

        // 不存在的 resourceId 返 None。
        match (this.getEntry("res-missing")) {
            case Some(_) => return false
            case None => ()
        }

        // totalCacheSize 求和：1000 + 2500 + 700 = 4200。
        if (this.totalCacheSize() != 4200) { return false }

        // entriesOlderThan(100)：timestamp < 100 → 仅 e3(50)。e1(100) 边界严格小于，不入选。
        let old100 = this.entriesOlderThan(100)
        if (old100.size != 1) { return false }
        if (old100[0].resourceId != "res-gamma") { return false }

        // entriesOlderThan(600)：全部 3 条（50/100/500 < 600）。
        if (this.entriesOlderThan(600).size != 3) { return false }

        // allEntries 全枚举 = 3；limit 截断 = 2。
        if (this.allEntries(0).size != 3) { return false }
        if (this.allEntries(2).size != 2) { return false }

        // ② removeEntry 后 getEntry 返 None；全删后 allEntries 空、totalCacheSize 0。
        this.removeEntry("res-beta")
        match (this.getEntry("res-beta")) {
            case Some(_) => return false
            case None => ()
        }
        if (this.allEntries(0).size != 2) { return false }

        for (e in all) {
            this.removeEntry(e.resourceId)
        }
        if (this.allEntries(0).size != 0) { return false }
        if (this.totalCacheSize() != 0) { return false }

        return true
    }
}
