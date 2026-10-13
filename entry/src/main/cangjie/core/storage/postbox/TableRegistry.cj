package ohos_app_cangjie_entry.core.storage.postbox

import kit.PerformanceAnalysisKit.Hilog

/**
 * TableRegistry —— Postbox 持久层「表 id 集中分配」+「幂等 schema 初始化/迁移」。
 *
 * iOS 标尺：
 *   - Telegram-iOS/submodules/Postbox/Sources/Postbox.swift
 *       Postbox 在 open 时按一组固定 table id 实例化各张 Table（MetadataTable / KeychainTable /
 *       PeerTable / MessageHistoryTable...），每张表的 id 是写死的常量。
 *   - Telegram-iOS/submodules/Postbox/Sources/SqliteValueBox.swift
 *       建库后读 PRAGMA user_version，按 currentVersion 决定是否跑迁移/首次建库。
 *
 * 本文件做两件事：
 *   ① 集中登记底座表 id：所有持久层表的物理 id 在此唯一分配，避免后续业务表
 *      （消息表 / 会话表 / peer 表...）id 撞车。新表加 id 必须改这里、并保证不与
 *      已用 id 冲突。
 *   ② initializeSchema(database)：在 PostboxDatabase open 之后调用一次，按 user_version
 *      跑「幂等」schema 初始化/迁移钩子——
 *        - version == 0（新库）：建底座、把 user_version 设为 CURRENT_VERSION；
 *        - 0 < version < CURRENT_VERSION：按版本逐级迁移（当前只有 v1，无迁移步骤），
 *          迁移完把 user_version 抬到 CURRENT_VERSION；
 *        - version == CURRENT_VERSION：no-op（幂等，重复调用安全）；
 *        - version > CURRENT_VERSION：库比代码新，记日志后保持只读语义不降级。
 *
 * 幂等性：表用 ValueBox 惰性建表（CREATE TABLE IF NOT EXISTS），重复 initializeSchema
 * 不会重复建表或破坏数据；user_version 单调推进，已是 CURRENT 时直接返回。
 *
 * MTProto 说明（N/A）：本地持久层 schema 管理，不涉及 MTProto 协议。
 */
public class TableRegistry {
    // ---- ① 集中表 id 分配 ----
    //
    // 表 id 与 iOS 对齐（iOS 各 Table 的 tableSpec(id) 写死编号）；本底座先登记已落地
    // 的元数据表 id。后续业务表在此段继续向后分配，禁止复用已占编号。
    //
    // 约定：
    //   - 0..99      预留给「核心底座表」（元数据 / keychain 等）
    //   - 100 起      业务表（消息 / 会话 / peer / media...）按需顺序分配
    // 取值参考 iOS Postbox.swift 中各 table id。

    /** 元数据表 id（对应 iOS MetadataTable，Postbox 中 id=0）。 */
    public static let METADATA_TABLE_ID: Int32 = 0

    /**
     * 消息历史主表 id（对应 iOS MessageHistoryTable）。
     *
     * 落在「100 起业务表段」，不撞 METADATA(0)；BinaryKey 表（键 = MessageIndex 20 字节
     * 大端复合键）。MessageHistoryTable.cj 持此 id 构造其 ValueBoxTable。
     */
    public static let MESSAGE_HISTORY_TABLE_ID: Int32 = 100

    /**
     * 消息历史 per-peer id 索引表 id（对应 iOS MessageHistoryIndexTable）。
     *
     * 落在「100 起业务表段」，新分配 101 —— 不撞 METADATA(0) 与 MESSAGE_HISTORY(100)；
     * BinaryKey 表（键 = (peerId:8, namespace:4, id:4) 16 字节大端复合键，无 timestamp）。
     * MessageHistoryIndexTable.cj 持此 id 构造其 ValueBoxTable，供「按 (peer,ns,id) 无 ts
     * 快速定位 / 存在性判断」，优化 MessageHistoryTable.getMessage(无 ts) 的全区间扫描。
     */
    public static let MESSAGE_HISTORY_INDEX_TABLE_ID: Int32 = 101

    /**
     * 会话列表主表 id（对应 iOS ChatListTable）。
     *
     * 落在「100 起业务表段」，新分配 102 —— 不撞 METADATA(0)、MESSAGE_HISTORY(100)、
     * MESSAGE_HISTORY_INDEX(101)；BinaryKey 表（键 = ChatListIndex 16 字节大端复合键
     * [pinningRank:4][invertedTimestamp:4][peerId:8]）。ChatListTable.cj 持此 id 构造其
     * ValueBoxTable，供离线会话列表 set/get/remove/有序枚举。
     */
    public static let CHAT_LIST_TABLE_ID: Int32 = 102

    /**
     * peer/用户表 id（对应 iOS PeerTable）。
     *
     * 落在「100 起业务表段」，新分配 103 —— 不撞 METADATA(0)、MESSAGE_HISTORY(100)、
     * MESSAGE_HISTORY_INDEX(101)、CHAT_LIST(102)；Int64Key 表（键 = peerId 8 字节大端，
     * 底层 INTEGER 主键，与 iOS PeerTable 的 keyType: .int64 对齐）。PeerTable.cj 持此 id
     * 构造其 ValueBoxTable，供离线 peer 信息（名字/头像/用户名）的 set/get/remove/getAll。
     */
    public static let PEER_TABLE_ID: Int32 = 103

    /**
     * 已读状态表 id（对应 iOS MessageHistoryReadStateTable）。
     *
     * 落在「100 起业务表段」，新分配 104 —— 不撞 METADATA(0)、MESSAGE_HISTORY(100)、
     * MESSAGE_HISTORY_INDEX(101)、CHAT_LIST(102)、PEER(103)；Int64Key 表（键 = peerId 8 字节
     * 大端 -> INTEGER 主键，与 iOS ReadStateTable 的 keyType: .int64 对齐）。ReadStateTable.cj
     * 持此 id 构造其 ValueBoxTable，供每会话「已读边界 + 未读计数」的 set/get/remove/便捷更新。
     */
    public static let READ_STATE_TABLE_ID: Int32 = 104

    /**
     * 媒体缓存元数据索引表 id（对应 iOS MediaBox 缓存元数据 / MediaResourceStatus 索引面）。
     *
     * 落在「100 起业务表段」，新分配 105 —— 不撞 METADATA(0)、MESSAGE_HISTORY(100)、
     * MESSAGE_HISTORY_INDEX(101)、CHAT_LIST(102)、PEER(103)、READ_STATE(104)；Int64Key 表
     * （键 = resourceId 的 djb2 稳定 hash → 8 字节大端 → INTEGER 主键；value 内同存完整 resourceId
     * 做碰撞校验）。MediaResourceIndexTable.cj 持此 id 构造其 ValueBoxTable，供已缓存媒体资源
     * 元数据（路径/大小/时间/是否完整/keepDuration）的 record/get/remove + 存储用量统计 + GC 候选枚举。
     */
    public static let MEDIA_RESOURCE_INDEX_TABLE_ID: Int32 = 105

    /**
     * 消息历史空洞索引表 id（对应 iOS MessageHistoryHoleIndexTable）。
     *
     * 107（106 已弃用）。BinaryKey 表，键 = [peerId:8][namespace:4]，value = 该会话已从服务端
     * 连续取回的 id 闭区间列表（空洞即其补集）。惰性建表（RdbValueBox.checkTable），
     * 老库无需迁移：无记录 = 整段皆空洞，与 iOS 新会话的初始 hole 1...Int32.max 同义。
     *
     * 106 下的记录由旧版本写入：页内消息落库失败（storeMessages 吞掉异常）时区间照样记为
     * 已填充，区间内却没有对应的行，上翻本地读会越过这段直接接到更早的零散缓存（R4 C3）。
     * 这些记录无法逐条甄别，换表 id 等价于把它们全部重新视为 hole，下一次进会话按网络补齐。
     */
    public static let MESSAGE_HISTORY_HOLE_INDEX_TABLE_ID: Int32 = 107

    // ---- ② schema 版本 ----
    //
    // 当前代码期望的 schema 版本。每次有破坏性 schema 变更（新增需迁移数据的表/列、
    // 改键编码等）必须 +1，并在 runMigrations 里补一段从 (CURRENT-1) 到 CURRENT 的迁移。
    public static let CURRENT_VERSION: Int32 = 1

    /**
     * 幂等 schema 初始化 / 迁移钩子。在 PostboxDatabase open 后调用一次。
     *
     * @param database 已 open 的 PostboxDatabase（提供 user_version 读写）
     */
    public static func initializeSchema(database: PostboxDatabase): Unit {
        let current = database.userVersion()

        if (current == CURRENT_VERSION) {
            // 已是最新版本：幂等返回（重复触发安全）。
            Hilog.info(0, "CjTelegram", "[TableRegistry] schema already at v${CURRENT_VERSION}, no-op")
            return
        }

        if (current == 0) {
            // 新库：建底座（惰性建表，CREATE TABLE IF NOT EXISTS）+ 设版本。
            createBaseSchema()
            let _ = database.setUserVersion(CURRENT_VERSION)
            Hilog.info(0, "CjTelegram", "[TableRegistry] fresh DB initialized to schema v${CURRENT_VERSION}")
            return
        }

        if (current < CURRENT_VERSION) {
            // 旧库：逐级迁移到 CURRENT_VERSION。
            runMigrations(database, current)
            let _ = database.setUserVersion(CURRENT_VERSION)
            Hilog.info(0, "CjTelegram", "[TableRegistry] migrated DB from v${current} to v${CURRENT_VERSION}")
            return
        }

        // current > CURRENT_VERSION：库比当前代码新，不降级（保持数据安全）。
        Hilog.error(0, "CjTelegram",
            "[TableRegistry] DB schema v${current} is newer than code v${CURRENT_VERSION}; not downgrading")
    }

    /**
     * 首次建库时建立底座表（幂等：底层 ValueBox.checkTable 走 CREATE TABLE IF NOT EXISTS）。
     *
     * 当前底座只含元数据表。后续新增底座表在此追加 checkTable 调用。
     */
    private static func createBaseSchema(): Unit {
        let valueBox = RdbValueBox.getInstance()
        let metadataTable = ValueBoxTable(id: METADATA_TABLE_ID, keyType: ValueBoxKeyType.Int64Key)
        valueBox.checkTable(metadataTable)

        // 消息历史主表（BinaryKey：MessageIndex 20 字节大端复合键）。
        // 惰性建表 CREATE TABLE IF NOT EXISTS，重复 initializeSchema 安全（幂等）。
        let messageHistoryTable = ValueBoxTable(
            id: MESSAGE_HISTORY_TABLE_ID, keyType: ValueBoxKeyType.BinaryKey)
        valueBox.checkTable(messageHistoryTable)

        // 消息历史 per-peer id 索引表（BinaryKey：(peer,ns,id) 16 字节大端键，无 timestamp）。
        // 惰性建表 CREATE TABLE IF NOT EXISTS，重复 initializeSchema 安全（幂等）。
        let messageHistoryIndexTable = ValueBoxTable(
            id: MESSAGE_HISTORY_INDEX_TABLE_ID, keyType: ValueBoxKeyType.BinaryKey)
        valueBox.checkTable(messageHistoryIndexTable)

        // 会话列表主表（BinaryKey：ChatListIndex 16 字节大端复合键
        // [pinningRank:4][invertedTimestamp:4][peerId:8]）。
        // 惰性建表 CREATE TABLE IF NOT EXISTS，重复 initializeSchema 安全（幂等）。
        let chatListTable = ValueBoxTable(
            id: CHAT_LIST_TABLE_ID, keyType: ValueBoxKeyType.BinaryKey)
        valueBox.checkTable(chatListTable)

        // peer/用户表（Int64Key：peerId 8 字节大端 -> INTEGER 主键，对齐 iOS PeerTable）。
        // 惰性建表 CREATE TABLE IF NOT EXISTS，重复 initializeSchema 安全（幂等）。
        let peerTable = ValueBoxTable(
            id: PEER_TABLE_ID, keyType: ValueBoxKeyType.Int64Key)
        valueBox.checkTable(peerTable)

        // 已读状态表（Int64Key：peerId 8 字节大端 -> INTEGER 主键，对齐 iOS ReadStateTable）。
        // 惰性建表 CREATE TABLE IF NOT EXISTS，重复 initializeSchema 安全（幂等）。
        let readStateTable = ValueBoxTable(
            id: READ_STATE_TABLE_ID, keyType: ValueBoxKeyType.Int64Key)
        valueBox.checkTable(readStateTable)

        // 媒体缓存元数据索引表（Int64Key：resourceId 的 djb2 hash → 8 字节大端 → INTEGER 主键）。
        // 惰性建表 CREATE TABLE IF NOT EXISTS，重复 initializeSchema 安全（幂等）。
        let mediaResourceIndexTable = ValueBoxTable(
            id: MEDIA_RESOURCE_INDEX_TABLE_ID, keyType: ValueBoxKeyType.Int64Key)
        valueBox.checkTable(mediaResourceIndexTable)
    }

    /**
     * 从 fromVersion 逐级迁移到 CURRENT_VERSION。
     *
     * 当前 CURRENT_VERSION == 1 且无更早的已发布版本，因此没有真实迁移步骤——
     * 仅保证底座表存在（防止从异常/手工置入的中间 version 进入时漏建表）。
     * 后续每提升一次 CURRENT_VERSION，在此按 `if (fromVersion < N) { ...migrate to N... }`
     * 顺序追加迁移段（单调向上，互不覆盖）。
     */
    private static func runMigrations(database: PostboxDatabase, fromVersion: Int32): Unit {
        // 兜底：确保底座表存在（惰性建表，已存在则无副作用）。
        createBaseSchema()
        // 未来迁移段示例（按需补全）：
        //   if (fromVersion < 2) { /* v1 -> v2 迁移 */ }
        let _ = fromVersion
        let _ = database
    }
}
