package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.unicode.*
import ohos.resource.__GenerateResource__
import ohos_app_cangjie_entry.utils.*
import ohos_app_cangjie_entry.components.SearchBar
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.viewmodels.getAuthViewModel
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * 国家选择页面 — 全屏可搜索、按 A-Z 分组的国家列表
 *
 * 对应 iOS AuthorizationSequenceCountrySelectionController
 * 功能：搜索、字母分区、国旗+国家名+拨号代码、点击选择后返回 PhoneInputPage
 * 右侧 A-Z 字母快速索引（对应 iOS UITableView sectionIndexTitles / Section index Slider）
 */
@HybridComponentEntry
@Component
public class CountrySelectionPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var countrySearchText: String = ""
    @State var selectedAlphaIndex: Int32 = 0
    // P2-fix HI-AUTH-0006: ForEach 必须消费裸 @State 字段，函数调用返回值在 CangjieUI 中
    // 不会在 @State 变更后被 ForEach 重新求值（同源 D-125：宏依赖追踪只认裸字段引用）。
    // 搜索结果镜像进本字段，由 onChange / aboutToAppear 显式重算并写回。
    @State var displayItems: ArrayList<CountryDisplayItem> = ArrayList<CountryDisplayItem>()
    // HI-AUTH-0006 round 2 真因：List 组件在 displayItems 从 223 项大幅收窄到
    // 个位数项时，真机复现懒加载视口/滚动状态无法正确重置——真机截图确认内容被
    // 裁剪到可视区之外（origBounds 起点为负、或仅渲染最后一节且缺自己的节头）。
    // scrollEdge(Top) / scrollToIndex(0) / 换新 Scroller 实例 / .id() 强制重建节点 /
    // cachedCount 放大 / initialIndex 均未能在真机上修复。改用无内部虚拟化状态的
    // Scroll+Column 承载平铺列表，彻底绕开 List 该问题；字母索引跳转改为按固定
    // 行高换算像素偏移后 scroller.scrollTo(...)。
    private var listScroller: Scroller = Scroller()

    // N-1 fix (diag-suite_auth_login-TC-0008 rework round2): 拖动列表时收起软键盘，
    // 对应源侧 scrollViewWillBeginDragging -> view.endEditing(true)（主表/搜索表共用
    // 同一 delegate）。目标侧没有等价的 view 级 resign 接口，改用「把焦点转移到一个
    // 不可见的哨兵节点」使 SearchBar 内部 TextInput 失焦、软键盘随之收起。
    // dragKeyboardDismissed 是一次性哨兵：同一次拖动手势内只申请一次焦点转移，
    // 避免 onDidScroll 每帧回调重复调用 FocusControl.requestFocus。不驱动任何 UI
    // 渲染，用普通 var（非 @State）避免每帧滚动回调都触发无谓重渲染。
    private var dragKeyboardDismissed: Bool = false
    private let keyboardDismissAnchorId: String = "csp_keyboard_dismiss_anchor"

    private let alphabets: Array<String> = [
        "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
        "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"
    ]

    protected override func aboutToAppear(): Unit {
        this.refreshDisplayItems()
    }

    /**
     * 按当前 countrySearchText 重新计算并写回 displayItems（@State 镜像字段）。
     * 必须由搜索文本变化的事件回调（SearchBar onChange/onCancel）显式触发，
     * 不能依赖 ForEach 直接调用函数——CangjieUI 不会因此重新求值。
     *
     * C5 修复：空查询走分区骨架（主列表态），非空查询平铺不分区（搜索结果态）——
     * 对应源侧两个独立 UITableView（tableView 分节主表 / searchTableView 平铺
     * 结果表）整表切换的语义，而不是共用同一套骨架。
     */
    private func refreshDisplayItems(): Unit {
        let indices = searchCountries(this.countrySearchText)
        if (this.countrySearchText.trim().size == 0) {
            let sections = buildCountrySections(indices)
            this.displayItems = flattenCountrySections(sections)
        } else {
            this.displayItems = flattenCountryIndices(indices)
        }
        // 结果集变化后滚回顶部：Scroll+Column 无 List 的懒加载视口状态问题，
        // scrollEdge 在这里能可靠生效（真机验证）。
        this.listScroller.scrollEdge(Edge.Top)
    }

    private func getDisplayItems(): ArrayList<CountryDisplayItem> {
        return this.displayItems
    }

    private func getCountryName(idx: Int64): String {
        let countries = getCountryList()
        if (idx >= 0 && idx < Int64(countries.size)) { return countries[idx][0] }
        return ""
    }

    private func getCountryDialCode(idx: Int64): String {
        let countries = getCountryList()
        if (idx >= 0 && idx < Int64(countries.size)) { return countries[idx][1] }
        return ""
    }

    private func getCountryFlag(idx: Int64): String {
        let countries = getCountryList()
        if (idx >= 0 && idx < Int64(countries.size)) { return countries[idx][2] }
        return ""
    }

    private func selectCountry(idx: Int64): Unit {
        let countries = getCountryList()
        if (idx >= 0 && idx < Int64(countries.size)) {
            let code = countries[idx][1]
            let name = countries[idx][0]
            // 混合迁移 auth-flow：@Consume countryCode/countryName 在隔离嵌入页无法回写调用方；
            // 直接写 app 级单例 getAuthViewModel().countryCode/.countryName，PhoneInputPage 读回。
            getAuthViewModel().countryCode = code
            getAuthViewModel().countryName = name
            Hilog.info(0, "CjTelegram", "[CountrySelectionPage] Selected country")
            routerPop()
        }
    }

    /**
     * 根据字母索引位置（alphabets 数组下标）找到对应分节在平铺列表中的起始位置
     * 用于 AlphabetIndexer onSelect 触发列表滚动
     */
    private func findSectionFlatIndex(alphaIdx: Int64): Int64 {
        let letter = this.alphabets[alphaIdx]
        let items = this.getDisplayItems()
        for (i in 0..Int64(items.size)) {
            let item = items[i]
            if (item.isSection && item.sectionLetter == letter) {
                return i
            }
        }
        return 0
    }

    /**
     * 把平铺列表下标换算成 Scroll 容器内的像素纵向偏移（section 行固定高 36，
     * country 行固定高 48），用于 AlphabetIndexer 跳转（Scroll 无 List 的
     * scrollToIndex，改用 scroller.scrollTo(yOffset: ...) 定位）。
     */
    private func flatIndexToPixelOffset(flatIdx: Int64): Float64 {
        let items = this.getDisplayItems()
        var offset: Float64 = 0.0
        var i: Int64 = 0
        while (i < flatIdx && i < Int64(items.size)) {
            if (items[i].isSection) {
                offset = offset + 36.0
            } else {
                offset = offset + 48.0
            }
            i = i + 1
        }
        return offset
    }

    /**
     * 根据 Scroll 当前纵向像素偏移，反推最接近的平铺列表下标（按固定行高
     * 36/48 累加），用于 onDidScroll 反向同步 AlphabetIndexer 选中项。
     */
    private func pixelOffsetToFlatIndex(yOffset: Float64): Int64 {
        let items = this.getDisplayItems()
        var offset: Float64 = 0.0
        var i: Int64 = 0
        while (i < Int64(items.size)) {
            let rowHeight = if (items[i].isSection) { 36.0 } else { 48.0 }
            if (offset + rowHeight > yOffset) {
                return i
            }
            offset = offset + rowHeight
            i = i + 1
        }
        return if (Int64(items.size) > 0) { Int64(items.size) - 1 } else { 0 }
    }

    /**
     * 根据平铺列表的当前首可见项下标，推算对应字母在 alphabets 数组中的位置
     * 用于 Scroll onDidScroll 反向同步 AlphabetIndexer 选中项
     */
    private func findAlphaIndexForFlatIndex(flatIdx: Int64): Int32 {
        let items = this.getDisplayItems()
        if (flatIdx < 0 || flatIdx >= Int64(items.size)) {
            return 0
        }
        var letter: String = ""
        var scanIdx = flatIdx
        while (scanIdx >= 0) {
            let item = items[scanIdx]
            if (item.isSection) {
                letter = item.sectionLetter
                scanIdx = -1
            } else {
                scanIdx = scanIdx - 1
            }
        }
        if (letter.size == 0) {
            return 0
        }
        for (i in 0..Int64(this.alphabets.size)) {
            if (this.alphabets[i] == letter) {
                return Int32(i)
            }
        }
        return 0
    }

    @Builder
    func countryRow(item: CountryDisplayItem) {
        if (item.isSection) {
            // N-3-② insetGrouped：节头无卡片背景，落在页面浅灰底上（源侧节头位于
            // 卡片之外），与下方 country 行的白色圆角卡片天然形成分组间隔。
            Column {
                Text(item.sectionLetter)
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .fontWeight(FontWeight.Medium)
                    .width(100.percent)
                    .height(28)
                    .padding(left: 16, top: 8)
            }
            .width(100.percent)
            .height(36)
        } else {
            // N-3-② insetGrouped 卡片：行整体左右内缩 16、卡片首/尾行分别圆首/尾角
            // （中间行不设圆角，视觉上无缝拼成一张白色圆角卡片）；行高固定 48（不受
            // 分隔线影响），保持 flatIndexToPixelOffset/pixelOffsetToFlatIndex 里
            // 写死的 36/48 常量继续成立——分隔线用 Stack 叠在行底部而不是新增一行，
            // 因此不会改变卡片累计高度、不会让字母索引跳转跑偏。
            Stack(alignContent: Alignment.Bottom) {
                Row {
                    Text(this.getCountryFlag(item.countryIndex))
                        .fontSize(22)
                        .margin(right: 10)
                    Text(this.getCountryName(item.countryIndex))
                        .fontSize(16)
                        .fontColor(0x000000)
                        .layoutWeight(1)
                    Text(this.getCountryDialCode(item.countryIndex))
                        .fontSize(16)
                        .fontColor(0x999999)
                }
                .width(100.percent)
                .height(48)
                .padding(left: 16, right: 16)
                .alignItems(VerticalAlign.Center)
                .onClick({ evt =>
                    this.selectCountry(item.countryIndex)
                })

                if (!item.isLastInCard) {
                    Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16)
                }
            }
            .width(100.percent)
            .height(48)
            .margin(left: 16, right: 16)
            .backgroundColor(0xFFFFFF)
            .borderRadius(
                topLeft: if (item.isFirstInCard) { 10 } else { 0 },
                topRight: if (item.isFirstInCard) { 10 } else { 0 },
                bottomLeft: if (item.isLastInCard) { 10 } else { 0 },
                bottomRight: if (item.isLastInCard) { 10 } else { 0 }
            )
            .clip(true)
        }
    }

    public func build() {
        Column {
                // 单一 dismiss 控件：圆形关闭按钮，对应 iOS glass 变体 closeButtonNode
                // （Navigation/Close，40x40，左上角）；不再冗余叠加文字 "Cancel"
                // B1 修复：真实矢量图标，源资产 Navigation/Close.imageset/headercross_30.pdf
                // 用 PyMuPDF 解析内容流路径（page.get_drawings，该 PDF 无 clip-trick，坐标
                // 已是 fitz 的 y-down 设备空间，无需再翻转）、按紧包围盒裁剪并归零得到
                // nav_ic_close.svg（19.792×17.072vp，path 精确到小数点后 3 位，已用像素
                // 光栅化与源 PDF 渲染逐点比对确认几何一致）。不再用 Text("✕") 字形兜底。
                // N-3-① 修复（diag TC-0008 rework round2）：容器补齐源侧
                // GlassBarButtonComponent(size: 40×40, state: .glass) 的玻璃底样式——
                // 40×40（对齐 barButtonSize，此前 32×32 偏小）、圆角 20（半径=边长一半，
                // 全圆）、白底 + 柔和投影近似玻璃质感（同 CallHistoryPage.cj:543-548
                // "G-01: 白底胶囊,靠柔和阴影与白色导航区分(iOS Liquid Glass 近似)"
                // 已验证的项目内玻璃按钮惯例，投影参数按 40×40 尺寸等比缩小）。
                // 图标本身（19.8×17.1）与 onClick→routerPop() 语义不变。
                Row {
                    Column {
                        Image(@r(app.media.nav_ic_close))
                            .width(19.8)
                            .height(17.1)
                            .fillColor(0x000000)
                    }
                        .width(40)
                        .height(40)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(20)
                        .shadow(radius: 6.0, color: 0x33000000, offsetX: 0.0, offsetY: 2.0)
                        .onClick({ evt =>
                            routerPop()
                        })
                    Blank()
                    Text(trSource("Country"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                    Blank()
                    Row {}.width(40)
                }
                .width(100.percent)
                .height(50)
                .padding(left: 16, right: 16)
                .alignItems(VerticalAlign.Center)
                // N-3-② insetGrouped: 页面下方切换为浅灰分组底，头部条自身仍需保持
                // 不透明白底，不随页面背景转灰（源侧导航条与分组表背景是两层）。
                .backgroundColor(0xFFFFFF)

                Divider().color(0xE5E5EA).strokeWidth(1)

                // 列表 + 右侧字母索引 + 底部悬浮搜索栏（对应 iOS glass 变体
                // SearchInputPanelComponent：y = layout.height - bottomInset - height）
                // HI-AUTH-0006 round 2: 平铺列表改用 Scroll+Column（非 List），
                // 规避 List 组件在结果集大幅缩短时的懒加载视口/滚动状态复位问题
                // （真机复现：搜索到个位数项时整屏空白或只剩最后一节且缺节头，
                // scrollEdge/scrollToIndex/新建 Scroller/.id() 强制重建均未能修复）。
                Stack(alignContent: Alignment.Bottom) {
                    Stack(alignContent: Alignment.End) {
                        Scroll(this.listScroller) {
                            Column {
                                ForEach(this.displayItems, itemGenerator: { item: CountryDisplayItem, _idx: Int64 =>
                                    this.countryRow(item)
                                })
                            }
                            .width(100.percent)
                        }
                        .width(100.percent)
                        .height(100.percent)
                        .onDidScroll({ _xDelta: Float64, _yDelta: Float64, scrollState: ScrollState =>
                            // N-1 修复（diag TC-0008 rework round2）：ScrollState.Scroll 是
                            // KB 确认的"手指拖动状态"语义（区别于程序化 scrollTo/scrollEdge
                            // 触发的滚动），对齐源侧 scrollViewWillBeginDragging——拖动开始
                            // 时把焦点转移到不可见哨兵节点，使搜索框失焦、软键盘收起。
                            // dragKeyboardDismissed 一次性哨兵：同一次拖动手势内只申请一次，
                            // 松手/惯性滑动（非 Scroll 态）后复位，下次拖动可再次触发。
                            if (scrollState == ScrollState.Scroll) {
                                if (!this.dragKeyboardDismissed) {
                                    this.dragKeyboardDismissed = true
                                    FocusControl.requestFocus(this.keyboardDismissAnchorId)
                                }
                            } else {
                                this.dragKeyboardDismissed = false
                            }
                            // C5 修复：搜索结果态无字母索引条，反向同步在该态下短路，
                            // 避免对不存在的索引条做无意义计算。
                            if (this.countrySearchText.trim().size == 0) {
                                let curOffset = this.listScroller.currentOffset()
                                if (curOffset.isSome()) {
                                    let flatIdx = this.pixelOffsetToFlatIndex(curOffset.getOrThrow().yOffset)
                                    this.selectedAlphaIndex = this.findAlphaIndexForFlatIndex(flatIdx)
                                }
                            }
                        })

                        // C5 修复：搜索结果态（非空查询）整节点不上树，对应源侧
                        // searchTableView 无 sectionIndexTitles（返回 nil）。
                        // N-3-③ 修复：索引条此前未设颜色（取 ArkUI 默认深色）；源侧
                        // glass 分支 sectionIndexColor 落回 accent 蓝，工程内既有链接色
                        // 0x317AFF（PhoneInputComponent.cj:96 / SearchBar.cj 已用）。
                        if (this.countrySearchText.trim().size == 0) {
                            AlphabetIndexer(arrayValue: this.alphabets, selected: UInt32(0))
                                .color(0x317AFF)
                                .onSelect({ index: Int64 =>
                                    let flatIdx = this.findSectionFlatIndex(index)
                                    let yOffset = this.flatIndexToPixelOffset(flatIdx)
                                    this.listScroller.scrollTo(xOffset: 0.vp, yOffset: yOffset.vp)
                                })
                        }

                        // N-1 修复：不可见焦点哨兵，仅用于 FocusControl.requestFocus 把焦点从
                        // 搜索框移走以收起软键盘；1×1 + opacity(0) 不产生任何可见像素，叠放在
                        // 本 Stack 内不影响 Scroll / AlphabetIndexer 的布局与点击区域。
                        Text(trSource(""))
                            .width(1)
                            .height(1)
                            .opacity(0.0)
                            .focusable(true)
                            .id(this.keyboardDismissAnchorId)
                    }
                    .width(100.percent)
                    .height(100.percent)

                    // P2-RETRO-search-c: TextInput → SearchBar 原子
                    // SearchBar 是 @Component，不能直接链内置属性（D-120），外包 Column 添加 margin
                    Column {
                        SearchBar(
                            loading: false,
                            backArrow: false,
                            text: this.countrySearchText,
                            hint: trSource("Search"),
                            onChange: { value: String =>
                                this.countrySearchText = value
                                this.selectedAlphaIndex = 0
                                this.refreshDisplayItems()
                            },
                            onCancel: { =>
                                this.countrySearchText = ""
                                this.selectedAlphaIndex = 0
                                this.refreshDisplayItems()
                            }
                        )
                    }
                    .width(100.percent)
                    .margin(left: 16, right: 16, bottom: 12)
                }
                .width(100.percent)
                .layoutWeight(1)
            }
            .width(100.percent)
            .height(100.percent)
            // N-3-② insetGrouped 修复（diag TC-0008 rework round2）：源侧两张表在 glass
            // 形态下背景一律为 blocksBackgroundColor（浅灰），country 行改铺白色圆角卡片
            // 后需要这层浅灰打底才能显出"卡片浮于灰底"的分组观感；头部条已显式补回白底
            // （见上方 header Row .backgroundColor(0xFFFFFF)），不受本行影响。项目内既有
            // 分组背景色 0xF2F2F7（ItemListComponents.cj ITEM_LIST_BG_GROUPED 同值，已在
            // AttachmentPanel/MessageSearch 等多处沿用，非本次臆造）。
            .backgroundColor(0xF2F2F7)
            .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
    }
}
