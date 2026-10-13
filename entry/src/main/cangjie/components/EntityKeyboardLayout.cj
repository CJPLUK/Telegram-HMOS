package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import std.collection.{ArrayList, HashMap}
import std.sync.Monitor
import ohos_app_cangjie_entry.services.{StickerItem, GifItem}

/**
 * iOS `EmojiPagerContentComponent.ItemLayout` 的同构移植。
 *
 * iOS 侧同一个 ItemLayout 同时负责三件事：算格子位置、算分组高度、算可见窗口。
 * 仓颉此前把这三件事拆成了互不相干的常量（绘制用 20% 宽 tile、滚动定位用 70.0
 * 行高、分组头按 30.0 估算），任何一处屏宽变化都会让三者对不上。这里把它们
 * 收敛成唯一真相：先由宽度算出 metrics，再由 metrics 把分组摊平成行，
 * 绘制与 scrollToIndex 都只认这份行表。
 *
 * 常量取自 EmojiPagerContentComponent.ItemLayout.init：
 *   compact（emoji）  minItemsPerRow 8, nativeItemSize 40, verticalSpacing 9
 *   detailed（贴纸）  minItemsPerRow 5, nativeItemSize 70, verticalSpacing 2
 */

/** 行类型：分组标题行。 */
public let KEYBOARD_ROW_HEADER: Int64 = 0
/** 行类型：一行格子。 */
public let KEYBOARD_ROW_ITEMS: Int64 = 1
/**
 * 行类型：分组底部的整宽行动按钮。
 *
 * iOS EmojiPagerContentComponent.swift:3337 —— **emoji** 面板的精选/锁定分组
 * 在分组末尾放一个整宽渐变按钮，而不是在分组头放小按钮：
 *   EmojiInput.UnlockPack = "Unlock %@"（premium 锁定，带锁图标）
 *   EmojiInput.AddPack    = "Add %@"（普通精选包）
 * 高度 50（同文件 groupPremiumButtonMeasuringFrame）。实测 iOS 上是
 * 一条紫蓝渐变的「Unlock Love Icons 🔒」，横跨整个分组宽度。
 *
 * 注意贴纸面板不同：那边（EmojiPagerContentSignals.swift:2127）确实用
 * actionButtonTitle 在**分组头**放 Install 按钮。两个面板版式不一样，别混。
 */
public let KEYBOARD_ROW_GROUP_BUTTON: Int64 = 2
public let KEYBOARD_GROUP_BUTTON_HEIGHT: Float64 = 50.0

/** 顶部包导航单个封面按钮的占宽（buildCustomPackTab 的 .width(36)）。 */
public let KEYBOARD_TOP_PANEL_TAB_WIDTH: Float64 = 36.0

/** 贴纸面板导航条单个按钮的占宽（buildPackNavigation 里每一项都是 .width(44)）。 */
public let STICKER_NAV_ITEM_WIDTH: Float64 = 44.0

/** iOS 把静态 Emoji 按 32/40 的字号比例画进格子（EmojiKeyboardItemLayer:287）。 */
public let KEYBOARD_EMOJI_GLYPH_RATIO: Float64 = 0.8

/**
 * 分组头的左右留白。lldb 从运行中的 iOS 量到 GroupHeaderLayer frame =
 * (16, y; width-32, 24)，与源码 headerInsets = containerInsets.left + 16 吻合。
 */
public let KEYBOARD_HEADER_INSET: Float64 = 16.0
/** iOS itemFeaturedHeaderHeight（detailed 布局）= 60。 */
public let KEYBOARD_FEATURED_HEADER_HEIGHT: Float64 = 60.0

/**
 * 一个格子。iOS 的 `EmojiPagerContentComponent.Item` 同样用一个类型承载
 * `.staticEmoji` / `.animation` / `.icon(.add)` 三种内容。
 */
public class KeyboardCell {
    /** 非空表示静态 Unicode Emoji。 */
    public var emoji: String = ""
    /** documentId != 0 表示贴纸或自定义表情文档。 */
    public var item: StickerItem = StickerItem()
    /** iOS recent 组首位的 `.icon(.add)`（新建贴纸入口）。 */
    public var isCreate: Bool = false
    /** 非空表示这是折叠占位格（iOS collapsedItemText，形如 "+128"）。 */
    public var expandLabel: String = ""

    public init() {}
}

public func emojiCell(value: String): KeyboardCell {
    let cell = KeyboardCell()
    cell.emoji = value
    return cell
}

public func documentCell(value: StickerItem): KeyboardCell {
    let cell = KeyboardCell()
    cell.item = value
    return cell
}

public func expandCell(label: String): KeyboardCell {
    let cell = KeyboardCell()
    cell.expandLabel = label
    return cell
}

public func createActionCell(): KeyboardCell {
    let cell = KeyboardCell()
    cell.isCreate = true
    return cell
}

public class KeyboardLayoutMetrics {
    /** 每行格子数（iOS itemsPerRow）。 */
    public var itemsPerRow: Int64 = 8
    /** 单格边长（iOS visibleItemSize，取 min(自适应值, nativeItemSize)）。 */
    public var itemSize: Float64 = 40.0
    /** 格子水平间距（iOS horizontalSpacing）。 */
    public var horizontalSpacing: Float64 = 9.0
    /** 行间距（iOS verticalSpacing）。 */
    public var verticalSpacing: Float64 = 9.0
    /** 内容整体居中后的左右留白（iOS itemInsets.left/right）。 */
    public var sideInset: Float64 = 7.0
    /** 分组标题高度（iOS itemDefaultHeaderHeight = 24）。 */
    public var headerHeight: Float64 = 24.0
    /** 分组之间的额外间距（iOS verticalGroupDefaultSpacing = 18）。 */
    public var groupSpacing: Float64 = 18.0

    public init() {}

    /** 一行格子占据的高度：格子边长 + 行间距。 */
    public func rowHeight(): Float64 {
        return this.itemSize + this.verticalSpacing
    }
}

/**
 * iOS compact 布局：emoji 面板。
 * 宽度 >= 420 时 iOS 收紧到 minSpacing 2 / sideInset 5，否则 9 / 7。
 */
public func emojiKeyboardMetrics(width: Float64): KeyboardLayoutMetrics {
    let metrics = KeyboardLayoutMetrics()
    metrics.verticalSpacing = 9.0
    metrics.headerHeight = 24.0
    metrics.groupSpacing = 18.0
    var minSpacing = 9.0
    var inset = 7.0
    if (width >= 420.0) {
        minSpacing = 2.0
        inset = 5.0
    }
    applyGridMetrics(metrics, width, inset, 8, 40.0, minSpacing)
    return metrics
}

/** iOS detailed 布局：贴纸面板主网格。 */
public func stickerKeyboardMetrics(width: Float64): KeyboardLayoutMetrics {
    let metrics = KeyboardLayoutMetrics()
    metrics.verticalSpacing = 2.0
    metrics.headerHeight = 24.0
    metrics.groupSpacing = 18.0
    applyGridMetrics(metrics, width, 10.0, 5, 70.0, 12.0)
    return metrics
}

/**
 * iOS 的 featuredTop 在 detailed 页里仍是常规分组，但本仓此前把它做成了一行
 * 紧凑封面条。行模型化之后先保留这一形态，等面板结构重构时再并回主网格。
 */
public func stickerFeaturedMetrics(width: Float64): KeyboardLayoutMetrics {
    let metrics = KeyboardLayoutMetrics()
    metrics.verticalSpacing = 4.0
    metrics.headerHeight = 24.0
    metrics.groupSpacing = 18.0
    applyGridMetrics(metrics, width, 10.0, 8, 40.0, 8.0)
    return metrics
}

/**
 * iOS：itemsPerRow 由宽度反推，格子尺寸不超过 nativeItemSize，
 * 余量平摊成 horizontalSpacing，最后把整块内容水平居中。
 */
private func applyGridMetrics(
    metrics: KeyboardLayoutMetrics,
    width: Float64,
    baseInset: Float64,
    minItemsPerRow: Int64,
    nativeItemSize: Float64,
    minSpacing: Float64
): Unit {
    var space = width - baseInset * 2.0
    if (space < nativeItemSize) {
        space = nativeItemSize
    }
    var perRow = Int64((space + minSpacing) / (nativeItemSize + minSpacing))
    if (perRow < minItemsPerRow) {
        perRow = minItemsPerRow
    }
    metrics.itemsPerRow = perRow

    var proposed = (space - minSpacing * Float64(perRow - 1)) / Float64(perRow)
    proposed = Float64(Int64(proposed))
    var visible = nativeItemSize
    if (proposed < nativeItemSize) {
        visible = proposed
    }
    if (visible < 8.0) {
        visible = 8.0
    }
    metrics.itemSize = visible

    var spacing = 0.0
    if (perRow > 1) {
        spacing = (space - visible * Float64(perRow)) / Float64(perRow - 1)
        spacing = Float64(Int64(spacing))
        if (spacing < 0.0) {
            spacing = 0.0
        }
    }
    metrics.horizontalSpacing = spacing

    let contentWidth = visible * Float64(perRow) + spacing * Float64(perRow - 1)
    var inset = (width - contentWidth) / 2.0
    if (inset < 0.0) {
        inset = 0.0
    }
    metrics.sideInset = inset
}

/**
 * 一个待摊平的分组，对应 iOS 的 `ItemGroup`。
 * key 同时充当导航条的选中标识。
 */
public class KeyboardGroup {
    public var key: Int64 = 0
    public var title: String = ""
    /** 非空时在分组头右侧显示「×」，值为面板自定义的动作名。 */
    public var clearAction: String = ""
    /** 使用紧凑 metrics（贴纸面板的 trending 封面条）。 */
    public var compact: Bool = false
    /** 标题为空时不占分组头行（iOS recent 组 title = nil）。 */
    public var showsHeader: Bool = true
    /** iOS isFeatured：分组头用 60pt 的高版式。 */
    public var isFeatured: Bool = false
    /**
     * iOS ItemGroup.isEmbedded：整组渲染成**一条可横向滚动的行**，而不是换行网格。
     *
     * EmojiPagerContentSignals.swift:1543 / 2139 —— emoji 与贴纸两个面板的
     * `featuredTop` 组都是 isEmbedded = true，且**不设条数上限**
     *（同文件 275 行起遍历全部 featuredPacks 逐个 append）。
     *
     * 我们此前把 trending 截断在 8 个且不可滚：服务端给 99 个 featured 包，
     * 用户只能看到 8 个，其余 91 个在这一行里够不着。
     * iOS 实测两次左滑后是完全不同的一批封面。
     */
    public var isEmbedded: Bool = false
    /** iOS ItemGroup.actionButtonTitle：分组头右侧的行动按钮（精选包的 "Add"）。 */
    public var actionTitle: String = ""
    /** iOS ItemGroup.subtitle：精选包头下方的 "%d stickers"。 */
    public var subtitle: String = ""
    /** 分组底部整宽按钮的文案（空则不显示）。见 KEYBOARD_ROW_GROUP_BUTTON。 */
    public var bottomActionTitle: String = ""
    /** 该分组是 premium 锁定：按钮文案用 Unlock 并带锁图标。 */
    public var bottomActionLocked: Bool = false
    /**
     * iOS ItemGroup.badge：标题右侧的小圆角标。
     *
     * 全仓只用在一处（EmojiPagerContentSignals.swift:1310）——群组专属表情包的
     * 分组头，文案 Emoji.GroupEmoji = "GROUP EMOJI"。
     * 规格见 GroupHeaderLayer.swift:230 起：semibold 11、高 16、全圆角、
     * 左右各 4pt 内边距、位于标题右侧 4pt。
     */
    public var badge: String = ""
    /**
     * iOS ItemGroup.collapsedLineCount：未展开时最多显示几行，超出部分收进
     * 末位的 "+N" 格。0 表示不折叠。recent 组 iOS 用 5，featured emoji 包用 3。
     */
    public var collapsedLineCount: Int64 = 0
    /**
     * 子分组的起始格子下标。iOS 的静态 Emoji 是**一个** group（groupId "static"）
     * 配 8 个 subgroupId，面板上只有一个 "EMOJI" 标题；顶部分类 tab 点击时
     * 滚到对应 subgroup 而不是另一个 group。留空表示没有子分组。
     */
    public var subgroupStarts: Array<Int64> = Array<Int64>(0, repeat: 0)
    /**
     * 直接持有已构建好的格子数组。静态目录共 1519 枚，若每次 rebuild 都重新
     * new 一遍 KeyboardCell，光分配就足以让面板发涩；调用方应传入缓存数组。
     */
    public var cells: Array<KeyboardCell> = Array<KeyboardCell>(0, { _ => KeyboardCell() })

    public init() {}
}

/**
 * 静态 Emoji 分类的格子缓存。目录是编译期常量，格子对象也就没有理由重建。
 */
private let staticEmojiCellCacheMonitor: Monitor = Monitor()
private var staticEmojiCellCache: HashMap<Int64, Array<KeyboardCell>> = HashMap<Int64, Array<KeyboardCell>>()

public func cachedEmojiCells(cacheKey: Int64, values: Array<String>): Array<KeyboardCell> {
    synchronized(staticEmojiCellCacheMonitor) {
        if (staticEmojiCellCache.contains(cacheKey)) {
            return staticEmojiCellCache[cacheKey]
        }
    }
    let built = ArrayList<KeyboardCell>()
    for (value in values) {
        built.add(emojiCell(value))
    }
    let result = built.toArray()
    synchronized(staticEmojiCellCacheMonitor) {
        staticEmojiCellCache[cacheKey] = result
    }
    return result
}

/**
 * 摊平后的一行。LazyForEach 只会为可见行调用 itemGenerator，
 * 因此一屏之外的格子既不建组件也不发起媒体下载。
 */
public class KeyboardRow {
    /** 该行是 isEmbedded 组的整组内容，绘制侧需套一层横向 Scroll。 */
    public var embedded: Bool = false
    /** iOS ItemGroup.badge：标题右侧角标（群组专属表情包的 "GROUP EMOJI"）。 */
    public var badge: String = ""
    /** KEYBOARD_ROW_GROUP_BUTTON 行的锁定态。 */
    public var actionLocked: Bool = false
    public var kind: Int64 = KEYBOARD_ROW_ITEMS
    public var groupKey: Int64 = 0
    public var title: String = ""
    public var subtitle: String = ""
    public var actionTitle: String = ""
    public var clearAction: String = ""
    public var compact: Bool = false
    public var itemSize: Float64 = 70.0
    public var horizontalSpacing: Float64 = 12.0
    public var sideInset: Float64 = 10.0
    public var height: Float64 = 72.0
    public var cells: Array<KeyboardCell> = Array<KeyboardCell>(0, { _ => KeyboardCell() })
    /** 所属子分组下标（静态 Emoji 的 8 个分类）；-1 表示该分组没有子分组。 */
    public var subgroup: Int64 = -1
    /**
     * LazyForEach 的复用键。缺省键在行表整体替换后会让 ArkUI 判定全部失效并
     * 重建每个可见项；显式给出 group + 行序即可复用同一批 ListItem。
     */
    public var key: String = ""

    public init() {}

    /** 静态 Emoji 的字号：iOS 的 32/40 比例。 */
    public func glyphSize(): Float64 {
        return this.itemSize * KEYBOARD_EMOJI_GLYPH_RATIO
    }
}

/**
 * 按 metrics 把分组摊平成行表。第一组之前不留 groupSpacing，
 * 与 iOS `verticalGroupOrigin` 的推进方式一致。
 */
public func buildKeyboardRows(
    groups: ArrayList<KeyboardGroup>,
    metrics: KeyboardLayoutMetrics,
    compactMetrics: KeyboardLayoutMetrics
): Array<KeyboardRow> {
    return buildKeyboardRowsExpanded(groups, metrics, compactMetrics, Array<Int64>(0, repeat: 0))
}

/**
 * 与 iOS ItemLayout.init 的折叠规则一致：
 *   visibleItemCount = itemsPerRow * maxLines - 1
 *   末位补一个 "+（总数 - visibleItemCount）" 的展开格
 * expandedKeys 里的分组不折叠。
 */
public func buildKeyboardRowsExpanded(
    groups: ArrayList<KeyboardGroup>,
    metrics: KeyboardLayoutMetrics,
    compactMetrics: KeyboardLayoutMetrics,
    expandedKeys: Array<Int64>
): Array<KeyboardRow> {
    let rows = ArrayList<KeyboardRow>()
    var emitted: Int64 = 0
    // 上一组末尾是否有整宽按钮（Unlock/Add）：按钮自带上下留白，
    // 已经是视觉分隔，下一组的头行不必再叠 groupSpacing。
    var prevHadButton = false
    for (group in groups) {
        if (group.cells.size == 0) {
            continue
        }
        var active = metrics
        if (group.compact) {
            active = compactMetrics
        }
        if (group.showsHeader) {
            let header = KeyboardRow()
            header.kind = KEYBOARD_ROW_HEADER
            header.groupKey = group.key
            header.title = group.title
            header.clearAction = group.clearAction
            header.subtitle = group.subtitle
            header.badge = group.badge
            header.actionTitle = group.actionTitle
            header.actionLocked = group.bottomActionLocked
            header.compact = group.compact
            var headerBase = active.headerHeight
            if (group.isFeatured) { headerBase = KEYBOARD_FEATURED_HEADER_HEIGHT }
            header.height = headerBase
            // 组间距只在「上一组没有整宽按钮」时叠加：Unlock/Add 按钮
            // 自带 margin，再叠 18vp 就是用户看到的「主题上面一行留白」。
            // 锁定/付费组（自带整宽按钮）的头行一律不叠间距 —— 这一段
            // 的组与组之间已有按钮留白，头行再加 18vp 就是「一行留白」。
            if (emitted > 0 && !group.isFeatured && !prevHadButton &&
                group.bottomActionTitle.size == 0) {
                header.height = headerBase + active.groupSpacing
            }
            header.key = "h${group.key}"
            rows.add(header)
        }

        if (group.isEmbedded) {
            // 整组塞进一行，由绘制侧的横向 Scroll 负责滚动与虚拟化。
            let row = KeyboardRow()
            row.kind = KEYBOARD_ROW_ITEMS
            row.groupKey = group.key
            row.compact = group.compact
            row.embedded = true
            row.itemSize = active.itemSize
            row.horizontalSpacing = active.horizontalSpacing
            row.sideInset = active.sideInset
            row.height = active.rowHeight()
            row.cells = group.cells
            row.subgroup = -1
            row.key = "e${group.key}"
            rows.add(row)
            prevHadButton = false
            emitted = emitted + 1
            continue
        }

        var index: Int64 = 0
        var rowIndex: Int64 = 0
        var total = Int64(group.cells.size)
        var expandTail = ""
        if (group.collapsedLineCount > 0 && !containsKey(expandedKeys, group.key)) {
            let rowsNeeded = (total + active.itemsPerRow - 1) / active.itemsPerRow
            if (rowsNeeded > group.collapsedLineCount) {
                let visible = active.itemsPerRow * group.collapsedLineCount - 1
                expandTail = "+${total - visible}"
                total = visible
            }
        }
        while (index < total) {
            let row = KeyboardRow()
            row.kind = KEYBOARD_ROW_ITEMS
            row.groupKey = group.key
            row.compact = group.compact
            row.itemSize = active.itemSize
            row.horizontalSpacing = active.horizontalSpacing
            row.sideInset = active.sideInset
            row.height = active.rowHeight()
            var take = total - index
            if (take > active.itemsPerRow) {
                take = active.itemsPerRow
            }
            row.cells = sliceCells(group.cells, index, take)
            if (expandTail.size > 0 && index + take >= total) {
                row.cells = appendCell(row.cells, expandCell(expandTail))
            }
            row.subgroup = subgroupAt(group.subgroupStarts, index)
            row.key = "r${group.key}_${rowIndex}"
            rows.add(row)
            rowIndex = rowIndex + 1
            index = index + take
        }
        if (group.bottomActionTitle.size > 0) {
            let button = KeyboardRow()
            button.kind = KEYBOARD_ROW_GROUP_BUTTON
            button.groupKey = group.key
            button.title = group.bottomActionTitle
            button.actionLocked = group.bottomActionLocked
            button.sideInset = active.sideInset
            button.height = KEYBOARD_GROUP_BUTTON_HEIGHT
            button.key = "b${group.key}"
            rows.add(button)
        }
        prevHadButton = group.bottomActionTitle.size > 0
        emitted = emitted + 1
    }
    return rows.toArray()
}

/** index 落在第几个子分组里；没有子分组时返回 -1。 */
private func subgroupAt(starts: Array<Int64>, index: Int64): Int64 {
    if (starts.size == 0) { return -1 }
    var result: Int64 = 0
    var i: Int64 = 0
    while (i < Int64(starts.size)) {
        if (starts[i] <= index) { result = i } else { break }
        i = i + 1
    }
    return result
}

/** 行表中该分组指定子分组的首行下标；找不到返回 -1。 */
public func keyboardRowIndexForSubgroup(
    rows: Array<KeyboardRow>, groupKey: Int64, subgroup: Int64
): Int64 {
    var index: Int64 = 0
    while (index < Int64(rows.size)) {
        if (rows[index].groupKey == groupKey && rows[index].subgroup == subgroup &&
            rows[index].kind == KEYBOARD_ROW_ITEMS) {
            return index
        }
        index = index + 1
    }
    return -1
}

private func containsKey(keys: Array<Int64>, value: Int64): Bool {
    var i: Int64 = 0
    while (i < Int64(keys.size)) {
        if (keys[i] == value) { return true }
        i = i + 1
    }
    return false
}

private func appendCell(source: Array<KeyboardCell>, extra: KeyboardCell): Array<KeyboardCell> {
    let result = ArrayList<KeyboardCell>()
    for (cell in source) { result.add(cell) }
    result.add(extra)
    return result.toArray()
}

private func sliceCells(source: Array<KeyboardCell>, start: Int64, count: Int64): Array<KeyboardCell> {
    let result = ArrayList<KeyboardCell>()
    var index = start
    let limit = start + count
    while (index < limit && index < Int64(source.size)) {
        result.add(source[index])
        index = index + 1
    }
    return result.toArray()
}

/** 行表中该分组的首行下标，供 scrollToIndex 使用；找不到返回 -1。 */
public func keyboardRowIndexForGroup(rows: Array<KeyboardRow>, groupKey: Int64): Int64 {
    var index: Int64 = 0
    while (index < Int64(rows.size)) {
        if (rows[index].groupKey == groupKey) {
            return index
        }
        index = index + 1
    }
    return -1
}

/**
 * LazyForEach 数据源。行表整体替换时发 onDataReloaded，
 * 与 iOS 每次 inputData 变更后重算 ItemLayout 的粒度一致。
 */
public class KeyboardRowSource <: IDataSource<KeyboardRow> {
    private var rows: Array<KeyboardRow> = Array<KeyboardRow>(0, { _ => KeyboardRow() })
    private var listeners: ArrayList<DataChangeListener> = ArrayList<DataChangeListener>()

    public init() {}

    public func totalCount(): Int64 {
        return Int64(this.rows.size)
    }

    public func getData(index: Int64): KeyboardRow {
        if (index < 0 || index >= Int64(this.rows.size)) {
            return KeyboardRow()
        }
        return this.rows[index]
    }

    public func registerDataChangeListener(listener: DataChangeListener): Unit {
        for (existing in this.listeners) {
            if (refEq(existing, listener)) {
                return
            }
        }
        this.listeners.add(listener)
    }

    public func unregisterDataChangeListener(listener: DataChangeListener): Unit {
        let kept = ArrayList<DataChangeListener>()
        for (existing in this.listeners) {
            if (!refEq(existing, listener)) {
                kept.add(existing)
            }
        }
        this.listeners = kept
    }

    public func currentRows(): Array<KeyboardRow> {
        return this.rows
    }

    public func setRows(values: Array<KeyboardRow>): Unit {
        this.rows = values
        for (listener in this.listeners) {
            listener.onDataReloaded()
        }
    }
}

/**
 * 贴纸建议条用的数据源。
 *
 * iOS `HorizontalStickersChatContextPanelNode` 用的是 GridNode——旋转 90° 的
 * **虚拟化**网格（`preloadSize: 100.0`，itemSize 66×66），只实例化可见项加一屏预载，
 * 对结果条数不设上限。这里的 List + LazyForEach 是它的等价物。
 *
 * 之前这条用的是裸 ForEach：`messages.getStickers` 单个 emoji 就能回 100 条，
 * 于是一次建 100 个格子、投 100 个加载任务。叠加 KeyboardMediaScheduler 的 LIFO
 * 取任务顺序后，**后提交的先跑**——而后提交的正是屏幕右侧看不见的那些，
 * 肉眼可见的最左几个排在栈底永远轮不上，表现为「建议条只出一个贴纸」。
 * 虚拟化之后只有可见格子会提交，LIFO 与可见顺序重新一致。
 */
public class StickerItemSource <: IDataSource<StickerItem> {
    private var items: Array<StickerItem> = Array<StickerItem>(0, repeat: StickerItem())
    private var listeners: ArrayList<DataChangeListener> = ArrayList<DataChangeListener>()

    public init() {}

    public func totalCount(): Int64 {
        return Int64(this.items.size)
    }

    public func getData(index: Int64): StickerItem {
        if (index < 0 || index >= Int64(this.items.size)) {
            return StickerItem()
        }
        return this.items[index]
    }

    public func registerDataChangeListener(listener: DataChangeListener): Unit {
        for (existing in this.listeners) {
            if (refEq(existing, listener)) {
                return
            }
        }
        this.listeners.add(listener)
    }

    public func unregisterDataChangeListener(listener: DataChangeListener): Unit {
        let kept = ArrayList<DataChangeListener>()
        for (existing in this.listeners) {
            if (!refEq(existing, listener)) {
                kept.add(existing)
            }
        }
        this.listeners = kept
    }

    public func setItems(values: Array<StickerItem>): Unit {
        this.items = values
        for (listener in this.listeners) {
            listener.onDataReloaded()
        }
    }
}

/**
 * GIF 网格的数据源。
 *
 * 之前 GifPanel 是 `Grid { ForEach(displayGifs) }`——eager，而 `loadMore()` 是无限下拉，
 * 于是 Video 节点只增不减。每个 GIF 格子是一个带独立解码线程的 `Video`，每帧都往主线程
 * 投一次 `ArkUIVideoCurrentTimeChange`；节点一多主线程事件队列就被打满，真机实测下拉
 * 约 16 次即 `THREAD_BLOCK_3S`（"App main thread is not response"）白屏并被系统杀掉。
 *
 * 与贴纸建议条是同一个病根（eager ForEach 套无界媒体集合），但载荷重得多：
 * 贴纸是 Image，GIF 是带线程的 Video。虚拟化之后活着的 Video 数量被可视窗口夹住。
 */
public class GifItemSource <: IDataSource<GifItem> {
    private var items: Array<GifItem> = Array<GifItem>(0, repeat: GifItem())
    private var listeners: ArrayList<DataChangeListener> = ArrayList<DataChangeListener>()

    public init() {}

    public func totalCount(): Int64 {
        return Int64(this.items.size)
    }

    public func getData(index: Int64): GifItem {
        if (index < 0 || index >= Int64(this.items.size)) {
            return GifItem()
        }
        return this.items[index]
    }

    public func registerDataChangeListener(listener: DataChangeListener): Unit {
        for (existing in this.listeners) {
            if (refEq(existing, listener)) {
                return
            }
        }
        this.listeners.add(listener)
    }

    public func unregisterDataChangeListener(listener: DataChangeListener): Unit {
        let kept = ArrayList<DataChangeListener>()
        for (existing in this.listeners) {
            if (!refEq(existing, listener)) {
                kept.add(existing)
            }
        }
        this.listeners = kept
    }

    public func setItems(values: Array<GifItem>): Unit {
        this.items = values
        for (listener in this.listeners) {
            listener.onDataReloaded()
        }
    }
}

/**
 * isEmbedded 行的数据源。
 *
 * 放开 trending 的条数上限就**必须**同时虚拟化。第一版用的是
 * `Scroll { Row { ForEach } }`——eager，90 个 StickerGridCell 一次性创建，
 * 把 KeyboardMediaScheduler（3 worker / 队列 48 / LIFO）灌满，可见的那几个排在
 * 栈底永远轮不上，结果 trending 行和顶部导航条**双双空白**。
 *
 * 这与 StickerSuggestionStrip 当初那个缺陷是同一个结构：
 * **eager 容器套无界集合**。截断在 8 个时看不出来，一放开就立刻现形。
 */
public class KeyboardCellSource <: IDataSource<KeyboardCell> {
    private var cells: Array<KeyboardCell> = Array<KeyboardCell>(0, { _ => KeyboardCell() })
    private var listeners: ArrayList<DataChangeListener> = ArrayList<DataChangeListener>()

    public init() {}

    public func totalCount(): Int64 {
        return Int64(this.cells.size)
    }

    public func getData(index: Int64): KeyboardCell {
        if (index < 0 || index >= Int64(this.cells.size)) {
            return KeyboardCell()
        }
        return this.cells[index]
    }

    public func registerDataChangeListener(listener: DataChangeListener): Unit {
        for (existing in this.listeners) {
            if (refEq(existing, listener)) { return }
        }
        this.listeners.add(listener)
    }

    public func unregisterDataChangeListener(listener: DataChangeListener): Unit {
        let kept = ArrayList<DataChangeListener>()
        for (existing in this.listeners) {
            if (!refEq(existing, listener)) { kept.add(existing) }
        }
        this.listeners = kept
    }

    public func setCells(values: Array<KeyboardCell>): Unit {
        this.cells = values
        for (listener in this.listeners) { listener.onDataReloaded() }
    }
}

/** 行表里第一条 embedded 行的 cells；没有则返回空。 */
public func embeddedRowCells(rows: Array<KeyboardRow>): Array<KeyboardCell> {
    for (row in rows) {
        if (row.embedded) { return row.cells }
    }
    return Array<KeyboardCell>(0, { _ => KeyboardCell() })
}
