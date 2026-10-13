/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 */
package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import std.collection.HashMap
import ohos_app_cangjie_entry.utils.safeAnimateTo
import ohos_app_cangjie_entry.services.triggerHaptic
import ohos_app_cangjie_entry.core.storage.{
    PresentationSnapshot,
    currentPresentation,
    PresentationStringsSnapshot,
    currentPresentationStrings
}

/**
 * ItemListComponents — 统一设置项列表框架 (Phase P2-410)
 *
 * 对应 Telegram-iOS submodules/ItemListUI/Sources/ 的「分区列表」范式：
 *   分区头(ListSectionHeaderNode / SectionHeaderItem) + 圆角分组卡 +
 *   标准行类型(开关行 / 披露行 / 值行 / 按钮行 / 输入行)。
 *
 * 工程现状：各设置页(SettingsPage / AppearanceSettingsPage /
 * NotificationSettingsPage)各自用裸 List/Column 手拼分区头与行，行样式不收敛。
 * 本文件把这套样式抽成一组可复用 @Component，视觉严格对齐现有设置页。
 *
 * ===== 视觉规范(从现有设置页 grep 对齐) =====
 *   页面背景:        presentation.backgroundColor（宿主 ItemListPageHost；
 *                    Day 回退常量 ITEM_LIST_BG_GROUPED = 0xF2F2F7）
 *   分区卡背景:      presentation.cardColor（ItemListSection；
 *                    Day 回退常量 ITEM_LIST_BG_CARD = 0xFFFFFF）
 *   分区卡圆角:      10~12 (这里统一 10，对齐 SettingsPage 多数分区)
 *   分区卡边距:      left/right 16
 *   分区头标题:      大写小字，fontSize 13，色 0x8E8E93，
 *                    margin(left:16, top:16, bottom:8)，width 100%
 *   标准行高:        内容推导，最小 52vp(对齐源侧 ItemListDisclosureItem.swift glass 风格
 *                    verticalInset*2+content 公式，单行标题恒 52，带副标题/两行按内容增高)。
 *                    ItemListDisclosureRow/ItemListToggleRow/ItemListButtonRow 三者收敛到同一
 *                    最小值(G-8/RC-E12-7，diag-suite_settings_privacy-E12-batch.md §七)。
 *                    ItemListInputRow 固定 56，本轮未纳入收敛(该组件不在诊断点位内，见
 *                    uif_itemlist_items.md Hand-off)。
 *   行水平内边距:    left/right 16
 *   行主标题:        fontSize 17，色 0x000000
 *   行副标题:        fontSize 13，色 0x8E8E93
 *   行右值文字:      fontSize 17(或 15)，色 0x8E8E93
 *   chevron 披露符:  "›"，fontSize 20，色 0xC7C7CC
 *   分隔线:          color 0xE5E5EA，strokeWidth 1，margin(left:16)
 *   Toggle 选中色:   0x34C759 (绿)
 *   destructive 色:  0xFF3B30 (红)
 *   主蓝(可选图标):  0x007AFF
 *
 * ===== 实现说明(坑规避) =====
 *   - @Component 基本类型参数默认用普通 var + 默认值(参考 QrCodeView 约定)。
 *     但当字段值需要随父组件 @State 变化驱动已挂载子组件重新 build() 时
 *     (如 ItemListToggleRow.isOn，见 TC-0086 round-2)，必须改用 @Prop(无默认值、
 *     调用点必须显式传参)——@Prop 支持 Bool 等 primitive 类型，本工程已有
 *     SolidRoundedButton.cj:60 @Prop var enabled: Bool 实测先例，"@Prop 不支持
 *     primitive" 是过时说法。选型准则：字段只影响首次渲染观感 → 普通 var；
 *     字段需要在组件挂载后随父状态刷新 → @Prop + 调用侧按 D-125 传裸 @State 字段。
 *   - 闭包回调用普通 var + 默认空闭包(参考 SolidRoundedButton.onClick)。
 *   - custom @Component 实例化后不能直接链 .margin()/.width() 等内置属性；
 *     调用方若需外边距请外包 Column/Row。
 *   - 各 Row 组件自带卡片背景与内边距吗？—— 否。为最大复用，Row 组件只画
 *     "一行"(行高 + 左右内边距 + 内容)，不自带卡背景；分区卡背景/圆角由
 *     ItemListSection 容器统一提供。这与现有设置页"一组 Row 放进一个白色圆角
 *     Column"的写法一致。
 *   - ItemListSection 子组件列表传递：custom @Component 不能简单接收"子组件
 *     列表"，这里用 KB 文档化的 @BuilderParam 范式(类似 slot 占位符)承接调用方
 *     用尾随 @Builder / 闭包传入的若干行内容，外层套白色圆角 Column。
 *     (cangjie-kb: cj-macro-builderparam — @BuilderParam 承接 @Builder 函数)
 *   - 行间分隔线：调用方在两行之间手动放 ItemListSeparator()，或直接用现有
 *     Divider().color(0xE5E5EA).strokeWidth(1).margin(left:16)。提供
 *     ItemListSeparator 作为统一封装(本身不能链内置属性，已内置标准样式)。
 */

// ======================================================================
// 统一样式常量(供本文件各组件与调用方对齐)
// ======================================================================
public let ITEM_LIST_BG_GROUPED: UInt32 = 0xF2F2F7      // 页面分组背景
public let ITEM_LIST_BG_CARD: UInt32 = 0xFFFFFF         // 分区卡背景
// ItemList 宿主屏导航栏底衬色。对位源侧 rootNavigationBar.blurredBackgroundColor
// (DefaultDayPresentationTheme.swift:419 = UIColor(rgb: 0xf2f2f2, alpha: 0.9)，
// 经 :434 下发为 NavigationBarTheme.backgroundColor，由 NavigationBarImpl.swift:646
// 交给 NavigationBackgroundNode)。0xE6 = round(0.9*255)。
// 与 ITEM_LIST_BG_CARD 是两个独立 token：源侧导航栏底色 != 分区卡底色。
public let ITEM_LIST_NAVBAR_BLURRED_BG: UInt32 = 0xE6F2F2F2
public let ITEM_LIST_SEPARATOR: UInt32 = 0xE5E5EA       // 分隔线
public let ITEM_LIST_TEXT_PRIMARY: UInt32 = 0x000000    // 主标题
public let ITEM_LIST_TEXT_SECONDARY: UInt32 = 0x8E8E93  // 副标题 / 值 / 分区头
public let ITEM_LIST_CHEVRON: UInt32 = 0xC7C7CC         // 披露 chevron
public let ITEM_LIST_ACCENT: UInt32 = 0x007AFF          // 主蓝
public let ITEM_LIST_DESTRUCTIVE: UInt32 = 0xFF3B30     // 危险红
public let ITEM_LIST_TOGGLE_ON: UInt32 = 0x34C759       // Toggle 选中绿
public let ITEM_LIST_CARD_RADIUS: Int64 = 10            // 分区卡圆角
// 开关尺寸对回源侧实测值(diag-suite_settings_appearance-TC-0400-round12.md F-D：
// 源侧 ItemListSwitchItem.swift:541-547 用真实 UISwitch 的 sizeToFit() 尺寸，参照设备
// 实测 63×28pt(Night Mode OFF 与 Show Next Media on Tap ON 两处逐像素同值)；不取
// SwitchNode.swift:96 的 51×31 —— 那是 ASDisplayNode 的 calculateSizeThatFits 兜底，
// 本 item 不走该路径。此前 36×20vp 是 TC-0086 round-2 从 HarmonyOS 平台默认 Toggle
// 尺寸实测得出，从未与源侧对位过，本轮予以更正；锁定态捕获层/Stack 仍与之显式同尺寸，
// 不可用百分比)。
public let ITEM_LIST_SWITCH_W: Float64 = 63.0
public let ITEM_LIST_SWITCH_H: Float64 = 28.0
// ItemList 宿主屏导航栏高度。7 个宿主页现有手写栏一律 .height(56)，取同值 ⇒ 接入后
// 静止态几何逐像素不变(源侧对位: ItemListControllerNode.swift:655 insets.top += navigationBarHeight)。
public let ITEM_LIST_NAVBAR_H: Float64 = 56.0

/**
 * 页底 / 卡底 / 导航底的 snapshot 取值。对位源侧 ItemListControllerNode
 * theme.list.blocksBackgroundColor / itemBlocksBackgroundColor / NavigationBarTheme。
 * D-124 迫使页面用 Column 代替 ItemListSection / ItemListPageHost 时，刷这些函数，
 * 禁止再写 0xFFFFFF / 0xF2F2F7 当页或分组卡底（图标圆底、品牌按钮除外）。
 * 不是平行色表：只转发 currentPresentation() 已发布的 token。
 */
public func itemListPageBackgroundColor(): UInt32 {
    return currentPresentation().backgroundColor
}

public func itemListCardColor(): UInt32 {
    return currentPresentation().cardColor
}

public func itemListNavBarColor(): UInt32 {
    return currentPresentation().navBarColor
}

// ======================================================================
// ItemListNavBarBackground — 容器导航栏渐显契约(滚动偏移 → 背景 alpha)
// ======================================================================
/**
 * 对应源侧 ItemListControllerNode 的"导航栏背景随滚动偏移渐显"契约
 * (submodules/ItemListUI/Sources/ItemListControllerNode.swift:375-419/480/653-656/847-852，
 * diag-suite_settings_root-TC-0089.md「修法方向」A 部分)。这里只提供框架层的引擎与背景层：
 * 单一函数把滚动偏移换算成 alpha，配合一个只画背景(不含标题/按钮)的容器组件。
 *
 * 宿主页接入方式(源侧同构，三步，任何 ItemListController 版式的宿主屏均适用)：
 *   1. 版式改 `Stack` 叠层：列表 `Scroll` 铺满整屏且 `.padding(top: ITEM_LIST_NAVBAR_H)`
 *      (对位 insets.top += navigationBarHeight，内容从栏下穿过，不是 `Column` 兄弟节点排布)；
 *      导航栏(背景层 + 宿主自己的标题/按钮内容)叠在同一 `Stack` 的上层。
 *   2. 宿主自己维护一个裸 `@State var navBarAlpha255: UInt32 = 0`(初值 0，对位
 *      `didLoad` 把背景 alpha 置 0)，在 `Scroll` 的 `onDidScroll` 里用
 *      `itemListNavBarBackgroundAlpha255(offsetVp)` 算出新值写回该裸字段——
 *      不得传函数调用给 `ItemListNavBarBackground.alpha255`(D-125，子组件 `@Prop`
 *      只认调用点的裸 `@State` 字段引用，函数调用返回值不进依赖图)。
 *   3. 在导航栏层里把 `ItemListNavBarBackground(alpha255: this.navBarAlpha255)` 铺底，
 *      宿主自己的标题/返回控件/按钮叠在它上面——本组件只画背景，不含任何交互内容，
 *      不会改变宿主已有的返回控件/按钮形态。
 *
 * 本契约只覆盖 C 组(导航栏随滚动渐显)；分组圆角/分隔线/按下高亮/返回语义等其余
 * ItemList 容器契约面不在本组件职责内，宿主页各自已有实现不受影响。
 */

/**
 * 导航栏背景不透明度引擎。对位 ItemListControllerNode.swift:408
 * `updateBackgroundAlpha(min(30.0, value) / 30.0)`。
 * 返回 0..255 的整数 alpha，供 `ItemListNavBarBackground.alpha255` 消费。
 * 单位：offsetVp 与 `.height()`/`.padding()` 同为 vp，源侧 30pt ↔ 目标 30vp，不做密度换算。
 *
 * 边界条件(全部照源侧，不新增判断)：
 *   - offsetVp <= 0(含 EdgeEffect.Spring 回弹产生的负值) → 0，对位源侧 `value <= 0` 落
 *     alpha 0 的同一段。
 *   - offsetVp >= 30 → 255。
 *   - 源侧 `.unknown/.none` 分支(:415，alpha 恒 1.0)在目标侧无对应状态：
 *     `Scroller.currentOffset()` 只有"有值/无值"，没有"偏移未知"语义，`isNone()` 时
 *     由调用方按"本次不更新"处理即可，本函数不需要也不应该为此臆造一个 unknown 状态。
 *   - 源侧 `headerItemNode` 分支(:404-406，恒 0)与 `.expansion` contentNode 分支
 *     (:385-387，恒 1.0)在目标侧同样无对应物：ItemList 宿主页既无页眉节点，也无
 *     搜索/展开导航内容节点(TC-0089 case E1 已确认 SettingsUI 内 `searchItem:` 为 0 处)，
 *     本函数不为不可达状态造门控。
 */
public func itemListNavBarBackgroundAlpha255(offsetVp: Float64): UInt32 {
    let clamped = if (offsetVp < 0.0) {
        0.0
    } else if (offsetVp > 30.0) {
        30.0
    } else {
        offsetVp
    }
    return UInt32(clamped / 30.0 * 255.0)
}

/**
 * ItemList 宿主屏的导航栏背景层。对位源侧 NavigationBar 的背景节点——
 * ItemListControllerNode 驱动的是"背景节点的 alpha"，标题与左右按钮的不透明度不参与，
 * 所以本组件只负责背景，宿主页把自己的标题/返回控件叠在它上面，不与
 * `app/TelegramNavBar.cj` 竞争、不改变宿主已有的返回控件/按钮形态。
 *
 * Props:
 *   alpha255:  当前背景不透明度(0..255)，来自 `itemListNavBarBackgroundAlpha255`。
 *              `@Prop`(alpha 要在组件挂载后随宿主 @State 刷新，D-125；同文件
 *              `ItemListToggleRow.isOn` 是同一理由)。类型取 UInt32 而非 Float64：
 *              本文件 `ItemListActivityFootnote.textColor` 的 `@Prop var textColor: UInt32`
 *              已验证数值型 @Prop 可用，Float64 无先例，此处不做类型试探。
 *   barHeight: 栏高(默认 ITEM_LIST_NAVBAR_H)。
 *
 * 底色读 `presentation.navBarColor`（TC-0541 C1–C5：系统深色重进子屏时导航底必须
 * 跟 snapshot，禁止再刷编译期 `ITEM_LIST_NAVBAR_BLURRED_BG`）。该常量仍保留为
 * 「未订主题的 Day 回退」token，宿主路径不消费它。
 *
 * 材质走两层叠加，对位源侧 NavigationBackgroundView：`.backdropBlur()` 提供系统模糊
 * (源侧 UIVisualEffectView(UIBlurEffect(style: .light))，半径无源侧常量可对位，取本仓
 * 既有 backdropBlur 先例值 22.0：`components/MessageContextOverlay.cj:160`、
 * `pages/ChatListPage.cj:2415`)，`.backgroundColor()` 提供半透明色叠在模糊之上；
 * 两者顺序 `.backdropBlur` 在前、`.backgroundColor` 在后，照抄
 * `components/MessageReactions.cj:1025-1026` / `components/StickerPreviewOverlay.cj:47-48`
 * 的既有顺序。整体不透明度仍走独立的 `.opacity()` 通道，不把 alpha 编进 ARGB 色值：
 * 本 SDK 对首字节为 0 的数值颜色字面量一律强制补 alpha=FF(D-144)，`0x00xxxxxx` 系列
 * (含 `0x00FFFFFF`)在本 SDK 下都会渲染为对应色相的不透明色，只有 `.opacity()`/
 * `Color.Transparent` 才是真透明通道；`.opacity(0.0)` 有 `pages/ConfettiView.cj:215`
 * 的现成用法先例。
 */
@Component
public class ItemListNavBarBackground {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @Prop var alpha255: UInt32
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    public var barHeight: Float64 = ITEM_LIST_NAVBAR_H

    func build() {
        Row {}
            .width(100.percent)
            .height(this.barHeight)
            .backdropBlur(22.0)
            .backgroundColor(this.presentation.navBarColor)
            .opacity(Float64(this.alpha255) / 255.0)
    }
}

// ======================================================================
// ItemListSectionHeader — 分区头(大写灰色小字标题，如 "ACCOUNT")
// ======================================================================
/**
 * 分区头。对齐现有设置页 Text(trSource("MESSAGE NOTIFICATIONS")).fontSize(13).fontColor(0x8E8E93)。
 *
 * Props:
 *   title:   分区标题(调用方自行决定是否已大写；这里原样显示)
 *   topPad:  上边距(默认 16，对齐首个分区；段间分区用 24)
 */
@Component
public class ItemListSectionHeader {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // @Prop：父组件重渲染时随父侧最新值单向同步覆盖（diag-suite_settings_data_storage-TC-0426.md
    // RC-C M1-a；与 ItemListToggleRow.isOn / ItemListDisclosureRow.value 同型先例，见
    // dev_pattern.md D-125）。无默认值，调用点必须显式传入（编译期强制；全仓 43 个既有
    // 调用点已核实全部显式传 title:，零回归）。
    @Prop var title: String
    public var topPad: Int64 = 16
    // diag-suite_settings_appearance-TC-0402-round6.md F-2：分区头文字色随主题走。快照当前
    // 没有独立的 sectionHeaderTextColor 维度（TC-0134 round8 挂起的 token 精度轴另计），
    // 未就绪前先用 secondaryTextColor 承接「随主题变化」，不自造第二张色表。
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()

    func build() {
        Text(trSource(this.title))
            .fontSize(13)
            .fontColor(this.presentation.secondaryTextColor)
            .margin(top: this.topPad, bottom: 8)
            .padding(left: 31, right: 31)
            .width(100.percent)
    }
}

// ======================================================================
// ItemListSectionFooter — 分区脚注(灰色次级文字，贴在分区卡片下方)
// ======================================================================
/**
 * 分区脚注。对齐现有设置页手写形态
 *   Text(...).fontSize(13).fontColor(0x8E8E93).margin(left:16,right:16,top:8).width(100%)
 * （见 pages/PrivacySettingsPage.cj 多处同形写法）。
 * TC-0086 修法方向「改动 3」新增：源侧 `ItemListTextItem(.markdown(...))` 分区脚注在
 * 目标侧此前没有对应组件，各分区手写死行文案时逐个内联复制该样式；此处收敛为一个组件。
 *
 * diag-suite_settings_privacy-E8-batch.md RC-5 / F-6：新增 markdown 链接槽。源侧
 * `ItemListTextItem.swift` 的 `.markdown` 分支把脚注拆成"正文 + 一段可点链接 + 正文"，
 * link 段取 `itemAccentColor`、其余取 `itemSecondaryTextColor`，`linkAction` 由屏侧提供
 * （见 `SelectivePrivacySettingsPage.cj` 的 `infoLinkTarget`/`computeInfoLink()`）。不引入
 * markdown 解析器——本仓两处已知脚注链接（`https://t.me/+<digits>`、
 * `What is Telegram Premium?`）都只是"一段纯文本子串"，按子串定位即可。
 *
 * Props:
 *   text:      脚注文案
 *   topPad:    上边距(默认 8，与分区卡片贴近)
 *   linkText:  `text` 中需要渲染成可点链接的子串；空串(默认)= 不启用链接，
 *              `build()` 保持原单 `Text` 形态完全不变(既有 25+ 调用点零回归)。
 *   onLinkTap: 链接段点击回调，入参回传 `linkText` 本身。
 *
 * 边界条件：`linkText` 非空但在 `text` 中找不到子串时，整条按无链接渲染(不抛异常、
 * 不截断)——由 `hasFooterLink()` 统一判定，`build()` 只有两个分支，不存在"半链接"态。
 */
@Component
public class ItemListSectionFooter {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // @Prop：父组件重渲染时随父侧最新值单向同步覆盖（diag-suite_settings_privacy-TC-0127-round2.md
    // RC-D；与 ItemListSectionHeader.title / ItemListToggleRow.isOn 同型先例，见
    // dev_pattern.md D-125）。无默认值，调用点必须显式传入（编译期强制；全仓 25 个既有
    // 调用点已核实全部显式传 text:，零回归）。
    @Prop var text: String
    public var topPad: Int64 = 8
    // 无装饰器 public var：只在首次构造读取，不需要随父状态刷新（diag-suite_settings_privacy-E8-batch.md
    // F-6 明确指出——避免波及全仓 25+ 个既有调用点，同时避免像 RC-3 那样冻结：这里冻结不产生
    // 观察面，因为链接目标本身不会在同一屏内动态改变）。
    public var linkText: String = ""
    public var onLinkTap: (String) -> Unit = { _ => }
    // diag-suite_settings_appearance-TC-0402-round6.md F-2：分区脚注文字色随主题走，
    // 同 ItemListSectionHeader.title 的 secondaryTextColor 承接理由。
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()

    // linkText 非空且确实是 text 的子串 → 启用链接渲染分支。
    private func hasFooterLink(): Bool {
        if (this.linkText.size == 0) {
            return false
        }
        return this.text.indexOf(this.linkText).isSome()
    }

    // 链接前缀段（找不到时不会被调用，见 build() 的分支门控）。
    private func footerLinkPrefix(): String {
        if (!this.hasFooterLink()) {
            return ""
        }
        let idx = this.text.indexOf(this.linkText).getOrThrow()
        return this.text[0..idx]
    }

    // 链接后缀段。
    private func footerLinkSuffix(): String {
        if (!this.hasFooterLink()) {
            return ""
        }
        let idx = this.text.indexOf(this.linkText).getOrThrow()
        return this.text[(idx + this.linkText.size)..this.text.size]
    }

    func build() {
        if (this.hasFooterLink()) {
            Text() {
                Span(this.footerLinkPrefix())
                    .fontColor(this.presentation.secondaryTextColor)
                Span(this.linkText)
                    .fontColor(this.presentation.accentColor)
                    .onClick({ _ => this.onLinkTap(this.linkText) })
                Span(this.footerLinkSuffix())
                    .fontColor(this.presentation.secondaryTextColor)
            }
            .fontSize(13)
            .margin(top: this.topPad)
            .padding(left: 31, right: 31)
            .width(100.percent)
        } else {
            Text(trSource(this.text))
                .fontSize(13)
                .fontColor(this.presentation.secondaryTextColor)
                .margin(top: this.topPad)
                .padding(left: 31, right: 31)
                .width(100.percent)
        }
    }
}

// ======================================================================
// ItemListActivityFootnote — 脚注文字 + 行内活动指示器(同一条目、同一状态驱动)
// ======================================================================
/**
 * 对齐源侧 submodules/ItemListUI/Sources/Items/ItemListActivityTextItem.swift。
 * 源侧一个 item 内同时承载 titleNode(文字)与 activityIndicator(16x16 转圈)，
 * `displayActivity` 单一真值同步决定"文字是否伴随转圈"——不存在"文案已在 checking
 * 态但转圈缺席"的源侧状态(diag-suite_settings_root-TC-0090.md 归因)。
 *
 * 本组件把这两件事收进同一个共享条目，替代此前各宿主页面各自手搓"裸 Text + 物理
 * 独立的第二行 LoadingProgress"的拆分写法——旧写法两个状态变量互不同步，产生
 * ≥500ms 的"文案已现、转圈未现"窗口，即 TC-0090 归因根因。既有的 LoadingProgress
 * 原生控件在本组件内被**合并复用**，不是再新增一个转圈。
 *
 * Props:
 *   text:            脚注文案。`@Prop`(TC-0090 修法方向要求：与 displayActivity
 *                    同源同步，随父状态变化必须驱动本组件重新 build()；D-125 范式，
 *                    调用点须传裸 @State 字段，不能传函数调用/嵌套字段表达式，
 *                    否则子组件不会随父状态变化重新 build())。
 *   textColor:       文字色(调用方按源侧 TextColor 枚举映射后传入)。`@Prop`(同上)。
 *   displayActivity: 是否显示 16x16 活动指示器；本组件的核心不变量——为 true 时
 *                    指示器与文字必须同帧出现，不允许分属两个不同步的状态源。
 *                    `@Prop`(同上)。
 *   topPad:          上边距(默认 8，对齐 ItemListSectionFooter 同一进场约定)。
 *                    唯一预期调用点(pages/UsernameSettingsPage.cj，见 F2 修法)不
 *                    覆盖此值，静态默认即可，沿用 plain var。
 *
 * 边界条件(诊断报告 F1 逐条强制，详见 diag-suite_settings_root-TC-0090.md)：
 *   - 转圈固定用系统原生 LoadingProgress()，颜色写死 0x808080(源侧
 *     ActivityIndicator.swift:18-27 convertIndicatorColor 对 itemAccentColor
 *     的映射结果恒为 UIColor.gray，不随主题色变化，不得改用 ITEM_LIST_ACCENT)。
 *     禁止自绘弧线、禁止 emoji/字形顶替(源侧 forceCustom=false，自绘节点从不入树，
 *     屏上恒为系统菊花)。
 *   - displayActivity=false 时不渲染任何占位槽(连 0 宽度都不留)，文字回落到
 *     leftInset，这是源侧 activityWidth=0 的真实行为，D5 位移差正是靠这条自然恢复。
 *   - 字号恒 13(源侧 itemListBaseHeaderFontSize)，不加字重分支；不设背景色/圆角/
 *     分隔线(源侧 isAlwaysPlain=true)；不限制行数(源侧 maximumNumberOfLines: 0)。
 *   - 已知残差(不试图消除，仅记录)：源侧让位 TextNodeCutout(topLeft: 25x22) 只让
 *     第一行；本实现的 25vp 前置槽让所有行。仓颉 Text 无 textIndent 渲染属性
 *     (SDK ohos.arkui.component.text.cj.d:288-486 全量属性已核；textIndent 只存在于
 *     ohos.arkui.ui_context.cj.d:821 的 MeasureOptions 测量入参，不是渲染属性)，
 *     无法逐行区分。该差异仅在"displayActivity=true 且文案换行"时可见，源侧全部
 *     5 个构造点(UsernameSetupController.swift:226、
 *     ChannelVisibilityController.swift:639/701、CreateGroupController.swift:364、
 *     CreateChannelController.swift:243)在该态下文案均为不换行短串 ⇒ 该差异在源侧
 *     语义域内不可达。
 */
@Component
public class ItemListActivityFootnote {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    public var topPad: Int64 = 8
    @Prop var text: String
    @Prop var textColor: UInt32
    @Prop var displayActivity: Bool

    func build() {
        Row {
            if (this.displayActivity) {
                // 让位槽：宽 25vp，与源侧 activityWidth = 25.0 等值；
                // 槽内 16x16 转圈，与源侧 activityIndicator.frame 的 16x16 等值。
                Stack(alignContent: Alignment.Center) {
                    LoadingProgress()
                        .width(16)
                        .height(16)
                        .color(0x808080)
                }
                .width(25)
            }
            Text(trSource(this.text))
                .fontSize(13)
                .fontColor(this.textColor)
                .layoutWeight(1)
        }
        .width(100.percent)
        .margin(top: this.topPad)
        .padding(left: 31, right: 31)
        .alignItems(VerticalAlign.Center)     // 对位源侧 activityIndicator 的整行垂直居中
    }
}

// ======================================================================
// ItemListSeparator — 行间标准分隔线(已内置标准样式，不可再链内置属性)
// ======================================================================
/**
 * 行间细分隔线。等价于
 *   Divider().color(0xE5E5EA).strokeWidth(1).margin(left: leftInset, right: rightInset)。
 *
 * Props:
 *   leftInset:  左侧缩进(默认 16；行内有图标列时用 61 对齐文字起点)
 *   rightInset: 右侧缩进(默认 16 = glass 风格常量。对位源侧
 *               PeerInfoScreenDisclosureItem.swift:408 / ItemListSingleLineInputItem.swift:277
 *               的 separatorRightInset——glass 风格下分隔线右端一律内插 16，是"一个 style
 *               开关统管全表"的统一规则。本工程分组卡已是 glass 形态(borderRadius(26)对位
 *               PresentationResourcesItemList.swift 的 glass 常量)，所以默认值取 16 而不是 0。
 *               diag-suite_settings_root-TC-0074-round4.md 修法B)
 */
@Component
public class ItemListSeparator {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    public var leftInset: Int64 = 16
    public var rightInset: Int64 = 16
    // diag-suite_settings_appearance-TC-0402-round6.md F-2：分隔线随主题走。
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()

    func build() {
        Divider()
            .color(this.presentation.dividerColor)
            .strokeWidth(1)
            .margin(left: this.leftInset, right: this.rightInset)
    }
}

// ======================================================================
// ItemListSection — 圆角分组容器(白色卡片圆角，内含若干行)
// ======================================================================
/**
 * 分区卡片容器。承接调用方传入的若干行(ItemListToggleRow / DisclosureRow / ...)，
 * 外层套白色圆角 Column，对齐现有设置页"一组 Row 放进白色圆角 Column"的写法。
 *
 * 用法(尾随 @BuilderParam content)：
 *   ItemListSection {
 *       ItemListToggleRow(title: "Sounds", isOn: this.sounds,
 *                         onChange: { v => this.sounds = v })
 *       ItemListSeparator()
 *       ItemListDisclosureRow(title: "Text Tone", value: "Default",
 *                             onClick: { => ... })
 *   }
 *
 * Props:
 *   topMargin: 顶部外边距(默认 0；段间分区一般给 20)
 *   content:   @BuilderParam — 分区内的行内容(slot 占位符)
 */
@Builder
func itemListEmptyContent() {}

@Component
public class ItemListSection {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    public var topMargin: Int64 = 0
    // diag-suite_settings_appearance-TC-0402-round6.md F-2：分区卡背景随主题走(是本组件的
    // 调用方普遍不像 AppearanceSettingsPage 那样自绘卡背景，靠本组件统一提供，此前恒白，
    // 深色下不适配)。
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()

    @BuilderParam
    var content: () -> Unit = itemListEmptyContent

    func build() {
        Column {
            this.content()
        }
        .backgroundColor(this.presentation.cardColor)
        .borderRadius(ITEM_LIST_CARD_RADIUS)
        .clip(true)
        .margin(left: 16, right: 16, top: this.topMargin)
    }
}

// ======================================================================
// ItemListPageHost — 页级 chrome（页底 + 内容槽）
// ======================================================================
/**
 * 对位源侧 ItemListControllerNode.swift:906-914：theme 变化时把控制器 / list /
 * overlay 背景设为 `theme.list.blocksBackgroundColor`（分组列表）或
 * `plainBackgroundColor`。目标侧行组件已订 presentation，但此前没有页级宿主，
 * 各设置子屏手写 `0xFFFFFF` / `0xF2F2F7`，系统深色重进后整页仍浅色（TC-0541 C1–C5）。
 *
 * 用法（D-123：自定义 @Component 禁止尾随 `{ }`，必须命名参数）：
 *   ItemListPageHost(content: this.pageBody)
 *
 * 页底只读 `presentation.backgroundColor`。导航底走同文件
 * `ItemListNavBarBackground`（已订 `presentation.navBarColor`）。分区卡走
 * `ItemListSection`（已订 `presentation.cardColor`）。D-124 跨包 @BuilderParam
 * 迫使页面继续用 Column 时，卡底刷 `itemListCardColor()`，不要再包白 Column。
 *
 * 不拨 Night Mode、不改 resolveIsDark / setSystemColorMode、不发明深浅平行色表。
 */
@Component
public class ItemListPageHost {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()

    @BuilderParam
    var content: () -> Unit = itemListEmptyContent

    func build() {
        Column {
            this.content()
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.presentation.backgroundColor)
    }
}

// ======================================================================
// ItemListToggleRow — 左标题(+可选副标题) + 右 Toggle 开关行
// ======================================================================
/**
 * 开关行。对齐现有设置页
 *   Row { Text(...).layoutWeight(1); Toggle(ToggleType.Switch, isOn:).selectedColor(0x34C759) }
 *
 * Props:
 *   title:    左主标题
 *   isOn:     当前开关态。`@Prop`(无默认值，调用点必须显式传参；TC-0086 round-2 修复：
 *             原普通 var 只在组件首次构造时赋值一次，父组件 @State 变化后已挂载的行会
 *             冻结在构造时初值，见 dev_pattern.md D-125/本条追记；调用点若要随父状态刷新，
 *             按 D-125 传裸 @State 字段，不要传函数调用/嵌套字段表达式)。
 *   onChange: 切换回调(Bool)
 *   subtitle: 可选副标题(空串=不显示；显示时行高自动撑高)
 *   enabled:  是否可交互(默认 true；false → 开关原生禁用 + 行内整行叠一层遮罩，对齐
 *             ItemListSwitchItem.enabled/disabledOverlayNode。diag-suite_settings_appearance-
 *             TC-0402-round13.md F-4：禁用视觉的实现手段是遮罩层，不是逐元素改前景色——
 *             标题色/开关色本身不随 enabled 改变，见 build() 内 maskColor() 与遮罩节点)
 *
 * Premium 锁定三元组(TC-0086 修法方向「改动 1」，逐一对齐
 * ItemListSwitchItem.swift 的 enableInteractiveChanges/displayLocked/activatedWhileDisabled；
 * 全部带默认值，既有调用点零改动)：
 *   enableInteractiveChanges: Toggle 自身是否响应交互(默认 true = !isLocked)。
 *     为 false 时不调用 onChange——不同于 enabled=false，enableInteractiveChanges=false
 *     时标题**不**置灰(源侧本行显式传 enabled:true，只是 switch 交互被关闭)。
 *   displayLocked: 是否在 Toggle 上叠一枚锁形图标(默认 false)。
 *   onActivatedWhileDisabled: 锁定态下点击 Toggle 区域时触发(默认空)，
 *     对齐 activatedWhileDisabled——只弹反馈，不改变 isOn。
 *
 * 锁定态点击转投实现说明(TC-0130 round-2 更正)：当前 cangjie ArkUI 绑定未见
 * `hitTestBehavior` 声明(components/UndoToast.cj 已实测确认该 API 缺口)，
 * 故不采用源侧 ItemListSwitchItem.swift:552
 * "isUserInteractionEnabled=false + 同尺寸手势覆盖 node 接管点击"的字面写法。
 * round-1 曾只在 Stack 内于 Toggle **之上**叠一层同尺寸透明 Column 并挂 onClick、
 * 靠"同尺寸覆盖"近似关闭本体命中——TC-0130 round-2 实测证伪该近似：ArkUI
 * `Toggle(Switch)` 的实际可点区域(含默认 margin 与越出 frame 的热区)超出其声明
 * 布局盒，覆盖层按声明尺寸定尺盖不住，声明下边缘外 ~9px 处点击会绕过覆盖层
 * 直接命中原生 Toggle。现改为源侧同款的**两道独立保险**：
 *   1) `toggleResponseRegion()` + `.responseRegion(...)`——捕获态时把 Toggle 自身
 *      响应区显式设为零面积，等价于源侧 `isUserInteractionEnabled=false`，与坐标
 *      无关，不依赖任何覆盖层的尺寸吻合；
 *   2) `switchRemountToggle` + `buildSwitch()` 的 D-160 双分支 remount——对位源侧
 *      `:550-551` 每次 layout apply 的无条件对账，`onChange` 里一旦观测到显示态与
 *      权威值 `isOn` 分叉就强制销毁重建 Toggle 子树，与保险 1 几何无关、独立闭合。
 * Column 透明层继续挂在 Toggle 之上、仅在需要接管点击时(!enableInteractiveChanges
 * || !enabled，镜像 switchGestureNode.isHidden 的取反条件)挂载，现在只负责锁定态
 * 反馈(onActivatedWhileDisabled)，不再独自承担"挡住 Toggle 命中"。未锁定时 Toggle
 * 直接接收点击，行为与改动前完全一致。
 */
@Component
public class ItemListToggleRow {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @Prop var title: String
    // diag-suite_settings_data_storage-TC-0423.md RC-1/FIX-A-2：前导徽标槽位，签名与
    // ItemListDisclosureRow.icon（同文件 :722）完全一致——普通 var 而非 @Prop：调用点上的
    // 字面量常量、挂载后不变，`None` 默认 ⇒ 全仓既有 71 个调用点零改动、零回归。
    public var icon: ?ResourceStr = None
    // @Prop：父组件重渲染时随父侧最新值单向同步覆盖（TC-0086 round-2 修复 P2，
    // 详见上方类注释 + dev_pattern.md D-125）。无默认值，调用点必须显式传入
    // （编译期强制；全仓 71 个既有调用点已核实全部显式传 isOn:，零回归）。
    @Prop var isOn: Bool
    public var onChange: (Bool) -> Unit = { _ => }
    public var subtitle: String = ""
    public var enabled: Bool = true
    public var enableInteractiveChanges: Bool = true
    public var displayLocked: Bool = false
    public var onActivatedWhileDisabled: () -> Unit = { => }
    // TC-0130 round-2 守卫补全（对位 ItemListSwitchItem.swift:550-551 的无条件对账）：
    // 显示态一旦被绕过捕获层的点击掰到与权威值 isOn 分叉，翻转本字段强制销毁重建
    // Toggle 子树，使其以 isOn 重新构造、视觉态归位。与 F1-a 的 responseRegion 命中
    // 屏蔽相互独立、几何无关——任一失效另一个仍闭合。机制见 dev_pattern.md D-160
    // （先例 pages/ChatQrCodeSharePage.cj:78,201,230,474-478）。
    @State var switchRemountToggle: Bool = false
    // diag-suite_settings_appearance-TC-0402-round6.md F-2：锁形图标次级色随主题走。
    // 直接声明本组件自己的 @StorageLink，lockIconColor() 改为接收已在调用点语法读到的
    // 颜色值作参数——不在函数体内读 this.presentation（同 D-125，函数体内部读取对构建
    // 该元素的表达式不可见，与 F-1b' colorThemeHeaderTitle(triggered:) 同一形状）。
    // diag-suite_settings_appearance-TC-0402-round13.md F-4：titleColor()（曾在此处按 enabled
    // 在 primaryColor/secondaryColor 间二选一）已删除——源侧 ItemListSwitchItem.swift 全文件
    // 没有任何由 enabled 参与 textColor 计算的分支，禁用态的标题变暗完全来自 build() 内的
    // 整行遮罩层，标题本身恒取 presentation.textColor（见下方 Text(this.title) 调用点）。
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()

    // 镜像 ItemListSwitchItem.swift:553 switchGestureNode.isHidden = enableInteractiveChanges && enabled
    private func shouldCaptureTap(): Bool {
        return !this.enableInteractiveChanges || !this.enabled
    }

    // 镜像 ItemListSwitchItem.swift:578 item.value ? positiveColor : itemSecondaryTextColor
    // ITEM_LIST_TOGGLE_ON 是语义色(源侧同为固定 token)，不随主题变化，故仍是字面量；
    // 次级色改由调用点传入 presentation.secondaryTextColor（理由同 D-125，见上方类字段注释）。
    // 与 enabled 无关（diag-suite_settings_appearance-TC-0402-round13.md F-4 边界条件：
    // 本函数与 subtitle 取色本轮不动）。
    private func lockIconColor(secondaryColor: UInt32): UInt32 {
        if (this.isOn) {
            return ITEM_LIST_TOGGLE_ON
        }
        return secondaryColor
    }

    // diag-suite_settings_appearance-TC-0402-round13.md F-4：禁用遮罩色 = 当前卡底色(随主题
    // 变化的 presentation.cardColor) @ 60% 透明度，对位源侧
    // itemBackgroundColor.withAlphaComponent(0.6)（ItemListSwitchItem.swift:429）。手工位运算
    // 而非 Color 透明度 API：cardColor 是随主题切换的 UInt32(RRGGBB，顶字节 0)，需要保留其
    // 随主题变化的 RGB、只替换 alpha 字节；0.6*255=153=0x99(非 0，不落进 D-144"首字节为 0
    // 强制补 FF"的边界情形)。与 components/MessageBubble.cj:2592-2593 的 withAlpha() 同一手法
    // (该文件已验证 alpha=0x1A/0x47 两个非零字节值生效)，本组件独立声明一份、不跨 allowlist
    // import 另一 feature 的私有函数。
    private func maskColor(baseColor: UInt32, alphaByte: UInt32): UInt32 {
        return (alphaByte << 24) | (baseColor & 0x00FFFFFF)
    }

    // TC-0130 round-2（F1-a）：对位 ItemListSwitchItem.swift:552
    // switchView.isUserInteractionEnabled = item.enableInteractiveChanges。捕获态返回
    // 零面积响应区 = 该 Toggle 在任何坐标上都不再参与命中测试（含 ArkUI Switch 越出
    // frame 的默认热区，实测下方 ≥9px）；非捕获态返回 None = 不设该属性，行为与改动
    // 前逐字相同。API 依据：ohos.arkui.component.common.cj.d:13370
    // func responseRegion(value: ?Rectangle): T；Rectangle 构造 :12498-12556
    // init(x!:?Length, y!:?Length, width!:?Length, height!:?Length)；
    // Float64 <: LengthProp & Length（ohos.base.cj.d:464）故 0.0 直接可作 Length。
    private func toggleResponseRegion(): ?Rectangle {
        if (this.shouldCaptureTap()) {
            return Rectangle(x: 0.0, y: 0.0, width: 0.0, height: 0.0)
        }
        return Option.None
    }

    // TC-0130 round-2（F1-b/F1-c）：Toggle 本体的实例化抽到独立 @Builder，供 build() 内
    // 两个内容相同的 if/else 分支各调用一次（D-160 双相同分支 remount 守卫）。
    // .margin(0.0)（F1-c，对位 ItemListSwitchItem.swift:548）抹掉 ArkUI 给
    // ToggleType.Switch 的默认 margin，消掉承载 Stack/捕获层与 Toggle frame 之间实测
    // 6px 的横向错位，使接管者与被接管者同位。
    @Builder
    func buildSwitch() {
        Toggle(ToggleType.Switch, isOn: this.isOn)
            .width(ITEM_LIST_SWITCH_W)
            .height(ITEM_LIST_SWITCH_H)
            .margin(0.0)
            .selectedColor(ITEM_LIST_TOGGLE_ON)
            .enabled(this.enabled)
            .responseRegion(this.toggleResponseRegion())
            .onChange({ on: Bool =>
                if (this.enabled && this.enableInteractiveChanges) {
                    this.onChange(on)
                } else if (on != this.isOn) {
                    // 显示态与权威态一旦分叉，无条件把显示态拉回权威值（对位 :550-551）
                    launch { this.switchRemountToggle = !this.switchRemountToggle }
                }
            })
    }

    func build() {
        Row {
            // diag-suite_settings_data_storage-TC-0423.md FIX-A-2：与 ItemListDisclosureRow
            // (:818-822) 逐字同形的图标列，只做 icon 分支——源侧 ItemListSwitchItem 只有
            // icon: UIImage? 一个入口，没有文字图标形态，不搬 iconText/iconBg 过来。
            if (this.icon.isSome()) {
                Image(this.icon)
                    .width(29)
                    .height(29)
                    .margin(right: 16)
            }
            Column {
                Text(trSource(this.title))
                    .fontSize(17)
                    .fontColor(this.presentation.textColor)
                    .width(100.percent)
                if (this.subtitle.size > 0) {
                    Text(trSource(this.subtitle))
                        .fontSize(13)
                        .fontColor(this.presentation.secondaryTextColor)
                        .margin(top: 2)
                        .width(100.percent)
                }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // diag-suite_settings_appearance-TC-0402-round13.md F-4：禁用态整行遮罩，对位
            // ItemListSwitchItem.swift:362-366/:417-433 的 disabledOverlayNode。
            //   层级——插在源侧 switchGestureNode 之下：本节点在同一个 Row 内声明于图标/标题
            //     列之后、开关 Stack 之前，ArkUI 同容器内后声明的兄弟节点绘制在先声明者之上，
            //     故遮罩盖住图标与标题（视觉变暗完全来自本层，标题自身颜色不变，见上方
            //     Text(this.title) 恒取 presentation.textColor），但盖不住随后声明的开关
            //     Stack——与源侧"遮罩在开关手势节点之下"同一层级关系，开关维持自身原生
            //     禁用置灰、不被本层二次压暗。
            //   尺寸——.position(x:0,y:0) 出流(dev_pattern.md D-144 附近 :633-636 记录的
            //     "百分比子节点在无显式定尺的 Stack 内会把 Stack 撑爆到父级可用约束"陷阱只
            //     适用于参与正常测量的子节点；.position() 语义上不参与父容器测量，因此不
            //     触发该陷阱，可以安全给一个本身按内容动态定高(minHeight 52 + 可选 subtitle)
            //     的 Row 加一层铺满遮罩，不必再包一层需要显式定尺的 Stack。100.percent 相对
            //     的是 Row 自身盒子(含其 :681 一带的 padding 修饰符)，与本 Row 之外的
            //     ItemListSeparator()（同层级独立兄弟组件，从不落在本 Row 边界内）天然互斥
            //     ⇒ 铺满本 Row 即等价于源侧"整行减分隔线"，无需额外扣减。
            //   颜色——见 maskColor()，presentation.cardColor 随主题变化 @ 0.6 透明度。
            //   过渡——.transition(OPACITY) 使本层随 if(!enabled) 的挂载/卸载各带一次
            //     0↔1 alpha 渐变，对位源侧 transition.updateAlpha(0→1)。
            if (!this.enabled) {
                Column {}
                    .width(100.percent)
                    .height(100.percent)
                    .position(x: 0, y: 0)
                    .backgroundColor(this.maskColor(this.presentation.cardColor, 0x99))
                    .transition(TransitionEffect.OPACITY.animation(AnimateParam(duration: 200, curve: Curve.EaseInOut)))
            }

            // Stack 必须显式定尺(TC-0086 round-2 修复 P1-b)：这是内容定尺的 Stack，
            // 若任一子节点用百分比尺寸，会按父级可用约束展开、反向把 Stack 撑爆
            // (实测从 138×98px 撑到 1096×1075px，连锁挤爆标题列/撑爆行高/顶出脚注/
            // 膨胀点击热区)。显式给 Stack 本身与开关同尺寸，杜绝该反向撑爆。
            Stack(alignContent: if (this.isOn) { Alignment.End } else { Alignment.Start }) {
                // TC-0130 round-2：Toggle 本体改走 D-160 双相同分支 remount 守卫（见
                // buildSwitch() 与 switchRemountToggle 字段注释），两分支内容故意保持
                // 一致，仅利用 if/else 源码位置切换触发框架销毁重建子树。
                if (this.switchRemountToggle) {
                    this.buildSwitch()
                } else {
                    this.buildSwitch()
                }

                // 锁形图标(displayLocked=true 时叠加；对齐 ItemListSwitchItem.swift:557-596)
                if (this.displayLocked) {
                    Image(@r(app.media.misc_ic_premiumlock))
                        .width(12)
                        .height(12)
                        .fillColor(this.lockIconColor(this.presentation.secondaryTextColor))
                        .margin(left: 4, right: 4)
                }

                // 锁定态点击转投层(见类注释)——必须与 Toggle 等大同位，不得扩到整行。
                // 尺寸改为与开关显式同尺寸(修 P1-b，不用百分比)；背景改 Color.Transparent
                // (修 P1-a：本 SDK 对首字节为 0 的数值颜色字面量强制补 alpha=FF，
                // 0x00FFFFFF 与 0x00000000 都会落成不透明色，只有 Color.Transparent
                // 才是本工程唯一验证过真正透明的写法，见 dev_pattern.md D-144)。
                // TC-0130 round-2：本层仍保留、继续承担"锁定态点击给出反馈"的职责，
                // 但不再独自承担"挡住 Toggle 命中"——那部分已由 buildSwitch() 里的
                // responseRegion(F1-a) 直接关闭；两者是互相独立的两道保险，同覆盖
                // ArkUI Switch 越出 frame 的默认热区，任一失效另一个仍闭合。
                if (this.shouldCaptureTap()) {
                    Column {}
                        .width(ITEM_LIST_SWITCH_W)
                        .height(ITEM_LIST_SWITCH_H)
                        .backgroundColor(Color.Transparent)
                        .onClick({ _ => this.onActivatedWhileDisabled() })
                }
            }
            .width(ITEM_LIST_SWITCH_W)
            .height(ITEM_LIST_SWITCH_H)
        }
        .width(100.percent)
        // G-8/RC-E12-7：56 → 52，与 ItemListDisclosureRow/ItemListButtonRow 收敛到同一最小值，
        // 使同卡内各行等高(源侧 ItemListDisclosureItem.swift glass 风格恒 52，无 56 这一档)。
        // 仍为 constraintSize(minHeight:)，非固定 height：带 subtitle 时按内容继续增高不变。
        .constraintSize(minHeight: 52)
        .padding(left: 16, right: 16, top: 8, bottom: 8)
        .alignItems(VerticalAlign.Center)
    }
}

// ======================================================================
// ItemListDisclosureRow — 左标题 + 右值文字 + chevron(>)，可点
// ======================================================================
/**
 * 披露/值行。对齐现有设置页
 *   Row { [icon] Text(title).layoutWeight(1); Text(value); Image(@r(app.media.item_list_disclosure_arrow)) }
 *
 * Props:
 *   title:       左主标题
 *   value:       右侧值文字(空串=不显示)；与 badgeText 互斥，badgeText 非空时优先。
 *                `@Prop`(无默认值，调用点必须显式传参；TC-0427 F3 修复：原普通 var 只在组件
 *                首次构造时赋值一次，父组件 @State 变化后已挂载的行会冻结在构造时初值，
 *                同 TC-0086 round-2 对 ItemListToggleRow.isOn 的修复同一类，见
 *                dev_pattern.md D-125/D-156；调用点若要随父状态刷新，按 D-125 传裸
 *                @State 字段，不要传函数调用返回值/嵌套字段访问)
 *   onClick:     整行点击回调
 *   icon:        可选左侧成品图标资源(如 @r(app.media.xxx))；非 None 时优先于 iconText
 *   iconText:    可选左侧图标文字/emoji(空串=不显示图标列；仅 icon 为 None 时生效)
 *   iconBg:      图标列背景色(默认主蓝；仅 iconText 非空时生效)
 *   showChevron: 是否显示右侧 chevron(默认 true)
 *   badgeText:   可选右侧圆形徽标文字(空串=不显示；非空时在 value 之前渲染，二者互斥)。
 *                对齐源侧 PeerInfoScreenDisclosureItem.swift 的 `.badge` label 形态
 *                (`PeerInfoScreenDisclosureItem.swift:170-172/:253/:382`)：直径 20vp、
 *                白字 15sp、圆形底色，右对齐于 chevron 之左。本工程目前唯一预期用法是单字符
 *                `"!"` 通知权限徽标，故不做自适应宽度。
 *   badgeColor:  徽标底色(默认 ITEM_LIST_DESTRUCTIVE = 源侧 itemDestructiveColor)
 *   useDetailLabelStyle: 对位源侧 ItemListDisclosureItem.labelStyle 的 `.detailText`/`.text`
 *                二选一(默认 false = `.text`，单行，右侧渲染 value/badgeText/chevron，语义同
 *                上面几条)。true 时对位 `.detailText`：`value` 改渲染为标题下方独立第二行
 *                (15sp)，右侧只保留 chevron，`badgeText` 不再渲染(两种 labelStyle 互斥，
 *                `.detailText` 形态下源侧 label 已经是第二行，不会再有右侧 badge)。字面量
 *                常量，调用点决定、挂载后不变，故普通 var 是正确选型(diag-suite_settings_
 *                data_storage-TC-0418-round4.md §M1)。
 */
@Component
public class ItemListDisclosureRow {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @Prop var title: String
    // Source ItemList entries are regenerated from the current PresentationData.
    // A row with a key observes the same complete strings snapshot directly, so
    // it never depends on a parent helper call being recognized as an ArkUI
    // property dependency. Empty keeps every existing non-localized call site
    // byte-for-byte compatible.
    public var localizedTitleKey: String = ""
    // @Prop：父组件重渲染时随父侧最新值单向同步覆盖（TC-0427 F3 修复，同 ItemListToggleRow.isOn
    // 一类，详见上方类注释 + dev_pattern.md D-125）。无默认值，调用点必须显式传入。
    @Prop var value: String
    public var localizedValueKey: String = ""
    // diag-suite_settings_data_storage-TC-0418-round4.md §M1 改动 1：对位源侧
    // ItemListDisclosureItem.labelStyle 的 `.detailText`/`.text` 二选一——是每个调用点上的
    // 字面量常量，挂载后不变，故按本文件 :44-52 准则用普通 var 是正确的（不得改 @Prop：本
    // SDK @Prop 无默认值，会强制全部 65 处调用点显式传参，波及不在本 feature allowlist 内
    // 的文件）。两行分支下第二行文本改走已有 @Prop 的 `value`（round3 引入的 detailText 动态
    // 串字段已删除——它是无装饰器普通 var，父组件 @State 变化后不回灌，是 round4 查明的真实
    // 根因：value: 从能刷新的 @Prop 通道被搬到了不回灌的 detailText 通道）。
    public var useDetailLabelStyle: Bool = false
    // ic_nsnd_disclosure_row_third_slot: 第三种独立槽位——非空时同时渲染标题(左上) +
    // 本字段(左下副标题) + 右侧单行 value(与 badgeText 不互斥) + chevron，对位源侧
    // NotificationsCategoryItemListItem.swift:213/218/220 三次独立 layout。与
    // useDetailLabelStyle 互斥优先：非空时走独立分支，不影响 useDetailLabelStyle 与默认
    // 单行分支的既有 128 处调用点（二者都不设本字段，保持逐字节不变）。
    public var subtitleText: String = ""
    // diag-suite_settings_data_storage-TC-0423.md RC-3/FIX-C-1：并列入参（对位源侧
    // ItemListDisclosureItem.additionalDetailLabel，与 useDetailLabelStyle 互斥的
    // 二选一不同——本字段与右值 value 同时成立：右值留右侧，本字段另加标题下方第二行）。
    // 普通 var（非 @Prop）：本 SDK @Prop 无默认值，改 @Prop 会强制全仓 65+ 处既有调用点
    // 显式传参，超出本轮 grant 范围（只覆盖本文件两处 ~170 行相隔的点名配方）。调用点需要
    // 随父 @State 变化回灌时，不追加装饰器——按 dev_pattern.md D-184（诊断报告指定 @Prop
    // 但级联跨 allowlist 且未获授权扩大 ⇒ 改用 D-160）在调用方单文件内用「双相同分支挂载
    // 守卫 + 专用 toggle」达成同等响应式效果，字段本身保持普通 var 不变。
    public var additionalDetailLabel: String = ""
    public var onClick: () -> Unit = { => }
    public var icon: ?ResourceStr = None
    public var iconText: String = ""
    public var iconBg: UInt32 = 0x007AFF
    public var showChevron: Bool = true
    public var badgeText: String = ""
    public var badgeColor: UInt32 = ITEM_LIST_DESTRUCTIVE
    // CTL-SHARED-002: iOS 行按压高亮
    @State var isPressed: Bool = false
    // diag-suite_settings_appearance-TC-0402-round6.md F-2：标题/次级值/chevron/图标列前景色
    // 随主题走。
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @StorageLink["presentationStrings"] var presentationStrings: PresentationStringsSnapshot = currentPresentationStrings()

    private func resolvedTitle(): String {
        if (this.localizedTitleKey.size > 0) {
            return this.presentationStrings.getOr(this.localizedTitleKey, this.title)
        }
        return trSource(this.title)
    }

    private func resolvedValue(): String {
        if (this.localizedValueKey.size > 0) {
            return this.presentationStrings.getOr(this.localizedValueKey, this.value)
        }
        return trSource(this.value)
    }

    func build() {
        // ic_nsnd_disclosure_row_third_slot: subtitleText 非空 → 三槽位形态，标题 + 独立
        // 第二行副标题 + 右侧单行 value(与 badgeText 不互斥) + chevron 四者互不覆盖，对位
        // 源侧 NotificationsCategoryItemListItem.swift:354(titleFrame)/357(subtitleFrame，
        // 挂 titleFrame 下方)/360(labelFrame，挂最右侧)。优先于下面两条既有分支判断，但两条
        // 既有分支自身逐字节不变（本分支只在 subtitleText 非空时才会进入）。
        if (this.subtitleText.size > 0) {
            Row {
                if (this.icon.isSome()) {
                    Image(this.icon)
                        .width(29)
                        .height(29)
                        .margin(right: 16)
                } else if (this.iconText.size > 0) {
                    Column {
                        Text(this.iconText)
                            .fontSize(14)
                            .fontColor(0xFFFFFF)
                    }
                    .width(29)
                    .height(29)
                    .borderRadius(7)
                    .backgroundColor(this.iconBg)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .margin(right: 16)
                }

                Column {
                    Text(this.resolvedTitle())
                        .fontSize(17)
                        .fontColor(this.presentation.textColor)
                        .width(100.percent)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                    Text(trSource(this.subtitleText))
                        .fontSize(15)
                        .fontColor(this.presentation.secondaryTextColor)
                        .width(100.percent)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                        .margin(top: 1)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                if (this.badgeText.size > 0) {
                    Text(this.badgeText)
                        .fontSize(15)
                        .fontColor(0xFFFFFF)
                        .constraintSize(minWidth: 20)
                        .height(20)
                        .padding(left: 5, right: 5)
                        .borderRadius(10)
                        .backgroundColor(this.badgeColor)
                        .textAlign(TextAlign.Center)
                        .margin(right: 6)
                }
                // 源侧 labelNode 与 subtitle 互不覆盖：value 独立渲染，不与 badgeText 二选一。
                if (this.resolvedValue().size > 0) {
                    Text(this.resolvedValue())
                        .fontSize(15)
                        .fontColor(this.presentation.secondaryTextColor)
                        .margin(right: 6)
                }

                if (this.showChevron) {
                    Image(@r(app.media.item_list_disclosure_arrow))
                        .width(7)
                        .height(12)
                        .fillColor(this.presentation.secondaryTextColor)
                }
            }
            .width(100.percent)
            .constraintSize(minHeight: 44)
            .padding(left: 16, right: 16, top: 13, bottom: 13)
            .alignItems(VerticalAlign.Center)
            .backgroundColor(if (!this.isPressed) { Color.Transparent } else { 0xE5E5EA })
            .onClick({ _ => this.onClick() })
            .onTouch({ evt =>
                match (evt.eventType) {
                    case TouchType.Down => this.isPressed = true
                    case TouchType.Up =>
                        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 250, curve: Curve.EaseInOut), { =>
                            this.isPressed = false
                        })
                    case _ => this.isPressed = false
                }
            })
        } else if (this.useDetailLabelStyle) {
            Row {
                if (this.icon.isSome()) {
                    Image(this.icon)
                        .width(29)
                        .height(29)
                        .margin(right: 16)
                } else if (this.iconText.size > 0) {
                    Column {
                        Text(this.iconText)
                            .fontSize(14)
                            .fontColor(0xFFFFFF)
                    }
                    .width(29)
                    .height(29)
                    .borderRadius(7)
                    .backgroundColor(this.iconBg)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .margin(right: 16)
                }

                Column {
                    Text(this.resolvedTitle())
                        .fontSize(17)
                        .fontColor(this.presentation.textColor)
                        .width(100.percent)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                    // diag-suite_settings_data_storage-TC-0418-round4.md §M1 改动 1：第二行
                    // 文本改取已有 @Prop 的 `value`（不再是不回灌的 detailText）；字号 15，
                    // 对位源侧 ItemListDisclosureItem.swift:467 detailFont = floor(17*15/17)。
                    Text(this.resolvedValue())
                        .fontSize(15)
                        .fontColor(this.presentation.secondaryTextColor)
                        .width(100.percent)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                        .margin(top: 1)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                // diag-suite_settings_data_storage-TC-0418-round4.md §M1 改动 1：`.detailText`
                // labelStyle 下源侧 label 已经渲染成第二行，右侧不再重复渲染 badge/value——
                // `.badge` 是另一个互斥的 labelStyle 枚举分支，不可能与 `.detailText` 同时成立。

                if (this.showChevron) {
                    // diag-suite_settings_notifications-TC-0439-round2.md 修法 1：真实矢量资源
                    // 替代字符字形，尺寸/fillColor 对位既有先例 PhoneInputComponent.cj:310-313 /
                    // EditProfilePage.cj:546-547（同为 7x12，随主题 tint）。
                    Image(@r(app.media.item_list_disclosure_arrow))
                        .width(7)
                        .height(12)
                        .fillColor(this.presentation.disclosureArrowColor)
                }
            }
            .width(100.percent)
            // G-8/RC-E12-7：44 → 52 最小值(标题+副标题两行分支，仍按内容继续增高不变，
            // 只把地板值对齐源侧 verticalInset 公式的单行基准，见类头 :33 与 RC-E12-7 修法)。
            .constraintSize(minHeight: 52)
            .padding(left: 16, right: 16, top: 13, bottom: 13)
            .alignItems(VerticalAlign.Center)
            // D-144: 首字节为 0 的数值颜色字面量在本 SDK 下强制补 alpha=FF，0x00FFFFFF 落成不透明白；
            // 只有 Color.Transparent 是本工程验证过真正生效的透明写法（同文件 :502 先例）。
            .backgroundColor(if (!this.isPressed) { Color.Transparent } else { 0xE5E5EA })
            .onClick({ _ => this.onClick() })
            .onTouch({ evt =>
                match (evt.eventType) {
                    case TouchType.Down => this.isPressed = true
                    case TouchType.Up =>
                        // CTL-SETTINGS-002: iOS PeerInfoScreenSelectableBackgroundNode 淡出 0.25s
                        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 250, curve: Curve.EaseInOut), { =>
                            this.isPressed = false
                        })
                    case _ => this.isPressed = false
                }
            })
        } else {
            Row {
                if (this.icon.isSome()) {
                    Image(this.icon)
                        .width(29)
                        .height(29)
                        .margin(right: 16)
                } else if (this.iconText.size > 0) {
                    Column {
                        Text(this.iconText)
                            .fontSize(14)
                            .fontColor(0xFFFFFF)
                    }
                    .width(29)
                    .height(29)
                    .borderRadius(7)
                    .backgroundColor(this.iconBg)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .margin(right: 16)
                }

                // diag-suite_settings_data_storage-TC-0423.md FIX-C-1: 两态各自独立成分支
                // （D-173/同文件 :735-737 已确立的纪律——不用条件化的单个修饰符调用）。右侧
                // value/badge/chevron 渲染逐字不动，这是本条与 useDetailLabelStyle 的关键
                // 区别：additionalDetailLabel 与 value 并列，右值不下沉。
                if (this.additionalDetailLabel.size > 0) {
                    Column {
                        Text(this.resolvedTitle())
                            .fontSize(17)
                            .fontColor(this.presentation.textColor)
                            .width(100.percent)
                            .maxLines(1)
                            .textOverflow(TextOverflow.Ellipsis)
                        Text(this.additionalDetailLabel)
                            .fontSize(15)
                            .fontColor(this.presentation.secondaryTextColor)
                            .width(100.percent)
                            .maxLines(1)
                            .textOverflow(TextOverflow.Ellipsis)
                            .margin(top: 1)
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                } else {
                    Text(this.resolvedTitle())
                        .fontSize(17)
                        .fontColor(this.presentation.textColor)
                        .layoutWeight(1)
                }

                if (this.badgeText.size > 0) {
                    Text(this.badgeText)
                        .fontSize(15)
                        .fontColor(0xFFFFFF)
                        .constraintSize(minWidth: 20)
                        .height(20)
                        .padding(left: 5, right: 5)
                        .borderRadius(10)
                        .backgroundColor(this.badgeColor)
                        .textAlign(TextAlign.Center)
                        .margin(right: 6)
                } else if (this.resolvedValue().size > 0) {
                    Text(this.resolvedValue())
                        .fontSize(17)
                        .fontColor(this.presentation.secondaryTextColor)
                        .margin(right: 6)
                }

                if (this.showChevron) {
                    // diag-suite_settings_notifications-TC-0439-round2.md 修法 1：真实矢量资源
                    // 替代字符字形，尺寸/fillColor 对位既有先例 PhoneInputComponent.cj:310-313 /
                    // EditProfilePage.cj:546-547（同为 7x12，随主题 tint）。
                    Image(@r(app.media.item_list_disclosure_arrow))
                        .width(7)
                        .height(12)
                        .fillColor(this.presentation.disclosureArrowColor)
                }
            }
            .width(100.percent)
            // G-8/RC-E12-7：固定 .height(44) → constraintSize(minHeight: 52) 内容推导。
            // 本分支标题恒单行(源侧 glass .text labelStyle 恒 52)；改用 minHeight 而非固定
            // height 是为了与 detail 分支(:788)同一机制，若标题异常换行也不裁切内容。
            .constraintSize(minHeight: 52)
            // FIX-C-1: additionalDetailLabel 非空时上下内边距对位 detail 分支(:821)的
            // top:13/bottom:13（源侧 verticalInset 15→13）；为空时逐字节保持原样(无 top/
            // bottom)。本 Row 未 .height() 定尺（只 constraintSize(minHeight:)），padding
            // 变化会让内容自然撑高，不落入 D-162 的"定尺盒子 padding 挪不动盒子"陷阱。
            .padding(left: 16, right: 16, top: if (this.additionalDetailLabel.size > 0) { 13 } else { 0 }, bottom: if (this.additionalDetailLabel.size > 0) { 13 } else { 0 })
            .alignItems(VerticalAlign.Center)
            // D-144: 首字节为 0 的数值颜色字面量在本 SDK 下强制补 alpha=FF，0x00FFFFFF 落成不透明白；
            // 只有 Color.Transparent 是本工程验证过真正生效的透明写法（同文件 :502 先例）。
            .backgroundColor(if (!this.isPressed) { Color.Transparent } else { 0xE5E5EA })
            .onClick({ _ => this.onClick() })
            .onTouch({ evt =>
                match (evt.eventType) {
                    case TouchType.Down => this.isPressed = true
                    case TouchType.Up =>
                        // CTL-SETTINGS-002: iOS PeerInfoScreenSelectableBackgroundNode 淡出 0.25s
                        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 250, curve: Curve.EaseInOut), { =>
                            this.isPressed = false
                        })
                    case _ => this.isPressed = false
                }
            })
        }
    }
}

// ======================================================================
// ItemListButtonRow — 整行可点的操作(如 "Log Out")，可 destructive
// ======================================================================
/**
 * 按钮行。对齐现有设置页 "Log Out" 行
 *   Row { Text(trSource("Log Out")).fontColor(0xFF3B30).layoutWeight(1).textAlign(Center) }
 *
 * Props:
 *   title:       行文字
 *   onClick:     点击回调
 *   destructive: 是否危险操作(默认 false)；true → 红字
 *   centered:    是否居中(默认 true，对齐 "Log Out")；false → 左对齐(主蓝操作)
 *   icon:        可选左侧成品图标资源(如 @r(app.media.xxx))，默认 None 不渲染任何节点。
 *                对齐源侧 PeerInfoScreenActionItem.swift 的 `icon: UIImage?` 槽——该基元
 *                本身同时支持"整行可点操作"与"可选左图标"，二者不互斥；此字段补齐该基元在本
 *                工程原有的缺口(diag-suite_settings_root-TC-0073.md 归因)。图标固定
 *                29x29、右边距 16，数值与 ItemListDisclosureRow 的图标分支逐字一致，对位源侧
 *                `PeerInfoScreenActionItem.swift:105` 的 `leftInset = 16 + 29 + 16 = 61`。
 *   rowHeight:   行高(默认 52，对齐源侧 `PeerInfoScreenActionItem.swift:130`
 *                `height = textSize.height + 32.0` 的 glass 风格恒值)。G-8/RC-E12-7
 *                （diag-suite_settings_privacy-E12-batch.md §七）把此前挂起的全局迁移
 *                （diag-suite_settings_root-TC-0073.md:148、diag-suite_settings_root-
 *                TC-0074-round4.md §6.3-2）执行为默认值统一迁移，理由：迁移前本工程 36 处
 *                调用点(9 个文件)中仅 `pages/EditProfilePage.cj` 的 2 处显式传 `rowHeight: 52`，
 *                其余全部落在 legacy 44，且与同卡内已收敛到 52 的 `ItemListDisclosureRow`/
 *                `ItemListToggleRow` 高低不齐(源侧不存在这种同卡内不等高形态，见 RC-E12-7)。
 *                该字段仍保留(公开可覆盖)，`EditProfilePage.cj` 的 2 处显式 `rowHeight: 52`
 *                传参在迁移后成为冗余但无害，未改动。
 */
@Component
public class ItemListButtonRow {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @Prop var title: String
    public var localizedTitleKey: String = ""
    public var onClick: () -> Unit = { => }
    public var destructive: Bool = false
    public var centered: Bool = true
    public var icon: ?ResourceStr = None
    public var rowHeight: Int64 = 52
    // CTL-SHARED-002: iOS 行按压高亮(与 ItemListDisclosureRow 同一套三件套)
    @State var isPressed: Bool = false
    @StorageLink["presentationStrings"] var presentationStrings: PresentationStringsSnapshot = currentPresentationStrings()

    private func resolvedTitle(): String {
        if (this.localizedTitleKey.size > 0) {
            return this.presentationStrings.getOr(this.localizedTitleKey, this.title)
        }
        return trSource(this.title)
    }

    private func textColor(): UInt32 {
        if (this.destructive) {
            return ITEM_LIST_DESTRUCTIVE
        }
        return ITEM_LIST_ACCENT
    }

    func build() {
        Row {
            if (this.icon.isSome()) {
                Image(this.icon)
                    .width(29)
                    .height(29)
                    .margin(right: 16)
            }
            if (this.centered) {
                Text(this.resolvedTitle())
                    .fontSize(17)
                    .fontColor(this.textColor())
                    .layoutWeight(1)
                    .textAlign(TextAlign.Center)
            } else {
                Text(this.resolvedTitle())
                    .fontSize(17)
                    .fontColor(this.textColor())
                    .layoutWeight(1)
                    .textAlign(TextAlign.Start)
            }
        }
        .width(100.percent)
        .height(this.rowHeight)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        // D-144: 首字节为 0 的数值颜色字面量在本 SDK 下强制补 alpha=FF，0x00FFFFFF 落成不透明白；
        // 只有 Color.Transparent 是本工程验证过真正生效的透明写法（同文件 :502 先例）。
        .backgroundColor(if (!this.isPressed) { Color.Transparent } else { 0xE5E5EA })
        .onClick({ _ => this.onClick() })
        .onTouch({ evt =>
            match (evt.eventType) {
                case TouchType.Down => this.isPressed = true
                case TouchType.Up =>
                    // CTL-SETTINGS-002: iOS PeerInfoScreenSelectableBackgroundNode 淡出 0.25s
                    safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 250, curve: Curve.EaseInOut), { =>
                        this.isPressed = false
                    })
                case _ => this.isPressed = false
            }
        })
    }
}

// ======================================================================
// ItemListInputType — 输入行的语义类型（TC-0082 R2 修法 F2-a）
// ======================================================================
/**
 * 对应源侧 ItemListSingleLineInputItem.type。目标侧 ItemListInputRow 此前完全没有
 * "输入类型"这个概念(diag-suite_settings_root-TC-0082.md round2 归因)，本条新增：
 *   Regular:  无约束(默认值，兼容既有全部调用点零改动)。
 *   Username: 用户名输入约束——变音符折叠 / 空格转下划线 / 非法字符不上屏 / 抖动+触觉反馈，
 *             对齐源侧 ItemListSingleLineInputItem.swift:567-598 的 .username 分支。
 */
public enum ItemListInputType {
    | Regular
    | Username
}

// ======================================================================
// 用户名输入清洗管线（TC-0082 R2 修法 F2-a：变音符折叠表 + 共享清洗函数）
// ======================================================================
/**
 * DIACRITIC_FOLD_TABLE —— Unicode 规范分解(NFD)折叠表，对齐源侧
 * `String.folding(options: .diacriticInsensitive, locale: .current)` 的可观测效果。
 *
 * 生成方式(按诊断报告 F2-a 要求"必须按底层逻辑复刻，不得拼近似映射表")：
 *   对 U+00C0–U+00FF(Latin-1 Supplement)、U+0100–U+017F(Latin Extended-A)、
 *   U+1E00–U+1EFF(Latin Extended Additional)三个区间的每个码点，取 Unicode 官方
 *   UnicodeData.txt canonical decomposition 字段(等价于 Python
 *   `unicodedata.normalize('NFD', chr(cp))`，该实现直接读取 UnicodeData.txt)的分解结果，
 *   若分解出的首个(基)字符落在 ASCII a-z/A-Z/0-9 范围内则收录该映射——分解出的组合变音符
 *   本身被丢弃，只保留基字符，与源侧折叠的可观测效果等价。
 *   作用域收敛依据(诊断报告原文)："折叠只在结果落入 [a-zA-Z0-9_] 时才有可见效果，故表只需
 *   覆盖规范分解基字符为 ASCII 字母/数字的码点"——因此三个区间内分解基字符非 ASCII 的码点
 *   (如变体附加符号、非拉丁基字符)不收录，此为规则本身的收敛，不是遗漏。
 */
private let DIACRITIC_FOLD_TABLE: HashMap<UInt32, Rune> = buildDiacriticFoldTable()

private func buildDiacriticFoldTable(): HashMap<UInt32, Rune> {
    let m = HashMap<UInt32, Rune>()
    // Latin-1 Supplement (U+00C0–U+00FF), 53 个码点
    m[UInt32(0x00C0)] = r'A'; m[UInt32(0x00C1)] = r'A'; m[UInt32(0x00C2)] = r'A'; m[UInt32(0x00C3)] = r'A'; m[UInt32(0x00C4)] = r'A'; m[UInt32(0x00C5)] = r'A';
    m[UInt32(0x00C7)] = r'C'; m[UInt32(0x00C8)] = r'E'; m[UInt32(0x00C9)] = r'E'; m[UInt32(0x00CA)] = r'E'; m[UInt32(0x00CB)] = r'E'; m[UInt32(0x00CC)] = r'I';
    m[UInt32(0x00CD)] = r'I'; m[UInt32(0x00CE)] = r'I'; m[UInt32(0x00CF)] = r'I'; m[UInt32(0x00D1)] = r'N'; m[UInt32(0x00D2)] = r'O'; m[UInt32(0x00D3)] = r'O';
    m[UInt32(0x00D4)] = r'O'; m[UInt32(0x00D5)] = r'O'; m[UInt32(0x00D6)] = r'O'; m[UInt32(0x00D9)] = r'U'; m[UInt32(0x00DA)] = r'U'; m[UInt32(0x00DB)] = r'U';
    m[UInt32(0x00DC)] = r'U'; m[UInt32(0x00DD)] = r'Y'; m[UInt32(0x00E0)] = r'a'; m[UInt32(0x00E1)] = r'a'; m[UInt32(0x00E2)] = r'a'; m[UInt32(0x00E3)] = r'a';
    m[UInt32(0x00E4)] = r'a'; m[UInt32(0x00E5)] = r'a'; m[UInt32(0x00E7)] = r'c'; m[UInt32(0x00E8)] = r'e'; m[UInt32(0x00E9)] = r'e'; m[UInt32(0x00EA)] = r'e';
    m[UInt32(0x00EB)] = r'e'; m[UInt32(0x00EC)] = r'i'; m[UInt32(0x00ED)] = r'i'; m[UInt32(0x00EE)] = r'i'; m[UInt32(0x00EF)] = r'i'; m[UInt32(0x00F1)] = r'n';
    m[UInt32(0x00F2)] = r'o'; m[UInt32(0x00F3)] = r'o'; m[UInt32(0x00F4)] = r'o'; m[UInt32(0x00F5)] = r'o'; m[UInt32(0x00F6)] = r'o'; m[UInt32(0x00F9)] = r'u';
    m[UInt32(0x00FA)] = r'u'; m[UInt32(0x00FB)] = r'u'; m[UInt32(0x00FC)] = r'u'; m[UInt32(0x00FD)] = r'y'; m[UInt32(0x00FF)] = r'y';

    // Latin Extended-A (U+0100–U+017F), 108 个码点
    m[UInt32(0x0100)] = r'A'; m[UInt32(0x0101)] = r'a'; m[UInt32(0x0102)] = r'A'; m[UInt32(0x0103)] = r'a'; m[UInt32(0x0104)] = r'A'; m[UInt32(0x0105)] = r'a';
    m[UInt32(0x0106)] = r'C'; m[UInt32(0x0107)] = r'c'; m[UInt32(0x0108)] = r'C'; m[UInt32(0x0109)] = r'c'; m[UInt32(0x010A)] = r'C'; m[UInt32(0x010B)] = r'c';
    m[UInt32(0x010C)] = r'C'; m[UInt32(0x010D)] = r'c'; m[UInt32(0x010E)] = r'D'; m[UInt32(0x010F)] = r'd'; m[UInt32(0x0112)] = r'E'; m[UInt32(0x0113)] = r'e';
    m[UInt32(0x0114)] = r'E'; m[UInt32(0x0115)] = r'e'; m[UInt32(0x0116)] = r'E'; m[UInt32(0x0117)] = r'e'; m[UInt32(0x0118)] = r'E'; m[UInt32(0x0119)] = r'e';
    m[UInt32(0x011A)] = r'E'; m[UInt32(0x011B)] = r'e'; m[UInt32(0x011C)] = r'G'; m[UInt32(0x011D)] = r'g'; m[UInt32(0x011E)] = r'G'; m[UInt32(0x011F)] = r'g';
    m[UInt32(0x0120)] = r'G'; m[UInt32(0x0121)] = r'g'; m[UInt32(0x0122)] = r'G'; m[UInt32(0x0123)] = r'g'; m[UInt32(0x0124)] = r'H'; m[UInt32(0x0125)] = r'h';
    m[UInt32(0x0128)] = r'I'; m[UInt32(0x0129)] = r'i'; m[UInt32(0x012A)] = r'I'; m[UInt32(0x012B)] = r'i'; m[UInt32(0x012C)] = r'I'; m[UInt32(0x012D)] = r'i';
    m[UInt32(0x012E)] = r'I'; m[UInt32(0x012F)] = r'i'; m[UInt32(0x0130)] = r'I'; m[UInt32(0x0134)] = r'J'; m[UInt32(0x0135)] = r'j'; m[UInt32(0x0136)] = r'K';
    m[UInt32(0x0137)] = r'k'; m[UInt32(0x0139)] = r'L'; m[UInt32(0x013A)] = r'l'; m[UInt32(0x013B)] = r'L'; m[UInt32(0x013C)] = r'l'; m[UInt32(0x013D)] = r'L';
    m[UInt32(0x013E)] = r'l'; m[UInt32(0x0143)] = r'N'; m[UInt32(0x0144)] = r'n'; m[UInt32(0x0145)] = r'N'; m[UInt32(0x0146)] = r'n'; m[UInt32(0x0147)] = r'N';
    m[UInt32(0x0148)] = r'n'; m[UInt32(0x014C)] = r'O'; m[UInt32(0x014D)] = r'o'; m[UInt32(0x014E)] = r'O'; m[UInt32(0x014F)] = r'o'; m[UInt32(0x0150)] = r'O';
    m[UInt32(0x0151)] = r'o'; m[UInt32(0x0154)] = r'R'; m[UInt32(0x0155)] = r'r'; m[UInt32(0x0156)] = r'R'; m[UInt32(0x0157)] = r'r'; m[UInt32(0x0158)] = r'R';
    m[UInt32(0x0159)] = r'r'; m[UInt32(0x015A)] = r'S'; m[UInt32(0x015B)] = r's'; m[UInt32(0x015C)] = r'S'; m[UInt32(0x015D)] = r's'; m[UInt32(0x015E)] = r'S';
    m[UInt32(0x015F)] = r's'; m[UInt32(0x0160)] = r'S'; m[UInt32(0x0161)] = r's'; m[UInt32(0x0162)] = r'T'; m[UInt32(0x0163)] = r't'; m[UInt32(0x0164)] = r'T';
    m[UInt32(0x0165)] = r't'; m[UInt32(0x0168)] = r'U'; m[UInt32(0x0169)] = r'u'; m[UInt32(0x016A)] = r'U'; m[UInt32(0x016B)] = r'u'; m[UInt32(0x016C)] = r'U';
    m[UInt32(0x016D)] = r'u'; m[UInt32(0x016E)] = r'U'; m[UInt32(0x016F)] = r'u'; m[UInt32(0x0170)] = r'U'; m[UInt32(0x0171)] = r'u'; m[UInt32(0x0172)] = r'U';
    m[UInt32(0x0173)] = r'u'; m[UInt32(0x0174)] = r'W'; m[UInt32(0x0175)] = r'w'; m[UInt32(0x0176)] = r'Y'; m[UInt32(0x0177)] = r'y'; m[UInt32(0x0178)] = r'Y';
    m[UInt32(0x0179)] = r'Z'; m[UInt32(0x017A)] = r'z'; m[UInt32(0x017B)] = r'Z'; m[UInt32(0x017C)] = r'z'; m[UInt32(0x017D)] = r'Z'; m[UInt32(0x017E)] = r'z';

    // Latin Extended Additional (U+1E00–U+1EFF), 244 个码点
    m[UInt32(0x1E00)] = r'A'; m[UInt32(0x1E01)] = r'a'; m[UInt32(0x1E02)] = r'B'; m[UInt32(0x1E03)] = r'b'; m[UInt32(0x1E04)] = r'B'; m[UInt32(0x1E05)] = r'b';
    m[UInt32(0x1E06)] = r'B'; m[UInt32(0x1E07)] = r'b'; m[UInt32(0x1E08)] = r'C'; m[UInt32(0x1E09)] = r'c'; m[UInt32(0x1E0A)] = r'D'; m[UInt32(0x1E0B)] = r'd';
    m[UInt32(0x1E0C)] = r'D'; m[UInt32(0x1E0D)] = r'd'; m[UInt32(0x1E0E)] = r'D'; m[UInt32(0x1E0F)] = r'd'; m[UInt32(0x1E10)] = r'D'; m[UInt32(0x1E11)] = r'd';
    m[UInt32(0x1E12)] = r'D'; m[UInt32(0x1E13)] = r'd'; m[UInt32(0x1E14)] = r'E'; m[UInt32(0x1E15)] = r'e'; m[UInt32(0x1E16)] = r'E'; m[UInt32(0x1E17)] = r'e';
    m[UInt32(0x1E18)] = r'E'; m[UInt32(0x1E19)] = r'e'; m[UInt32(0x1E1A)] = r'E'; m[UInt32(0x1E1B)] = r'e'; m[UInt32(0x1E1C)] = r'E'; m[UInt32(0x1E1D)] = r'e';
    m[UInt32(0x1E1E)] = r'F'; m[UInt32(0x1E1F)] = r'f'; m[UInt32(0x1E20)] = r'G'; m[UInt32(0x1E21)] = r'g'; m[UInt32(0x1E22)] = r'H'; m[UInt32(0x1E23)] = r'h';
    m[UInt32(0x1E24)] = r'H'; m[UInt32(0x1E25)] = r'h'; m[UInt32(0x1E26)] = r'H'; m[UInt32(0x1E27)] = r'h'; m[UInt32(0x1E28)] = r'H'; m[UInt32(0x1E29)] = r'h';
    m[UInt32(0x1E2A)] = r'H'; m[UInt32(0x1E2B)] = r'h'; m[UInt32(0x1E2C)] = r'I'; m[UInt32(0x1E2D)] = r'i'; m[UInt32(0x1E2E)] = r'I'; m[UInt32(0x1E2F)] = r'i';
    m[UInt32(0x1E30)] = r'K'; m[UInt32(0x1E31)] = r'k'; m[UInt32(0x1E32)] = r'K'; m[UInt32(0x1E33)] = r'k'; m[UInt32(0x1E34)] = r'K'; m[UInt32(0x1E35)] = r'k';
    m[UInt32(0x1E36)] = r'L'; m[UInt32(0x1E37)] = r'l'; m[UInt32(0x1E38)] = r'L'; m[UInt32(0x1E39)] = r'l'; m[UInt32(0x1E3A)] = r'L'; m[UInt32(0x1E3B)] = r'l';
    m[UInt32(0x1E3C)] = r'L'; m[UInt32(0x1E3D)] = r'l'; m[UInt32(0x1E3E)] = r'M'; m[UInt32(0x1E3F)] = r'm'; m[UInt32(0x1E40)] = r'M'; m[UInt32(0x1E41)] = r'm';
    m[UInt32(0x1E42)] = r'M'; m[UInt32(0x1E43)] = r'm'; m[UInt32(0x1E44)] = r'N'; m[UInt32(0x1E45)] = r'n'; m[UInt32(0x1E46)] = r'N'; m[UInt32(0x1E47)] = r'n';
    m[UInt32(0x1E48)] = r'N'; m[UInt32(0x1E49)] = r'n'; m[UInt32(0x1E4A)] = r'N'; m[UInt32(0x1E4B)] = r'n'; m[UInt32(0x1E4C)] = r'O'; m[UInt32(0x1E4D)] = r'o';
    m[UInt32(0x1E4E)] = r'O'; m[UInt32(0x1E4F)] = r'o'; m[UInt32(0x1E50)] = r'O'; m[UInt32(0x1E51)] = r'o'; m[UInt32(0x1E52)] = r'O'; m[UInt32(0x1E53)] = r'o';
    m[UInt32(0x1E54)] = r'P'; m[UInt32(0x1E55)] = r'p'; m[UInt32(0x1E56)] = r'P'; m[UInt32(0x1E57)] = r'p'; m[UInt32(0x1E58)] = r'R'; m[UInt32(0x1E59)] = r'r';
    m[UInt32(0x1E5A)] = r'R'; m[UInt32(0x1E5B)] = r'r'; m[UInt32(0x1E5C)] = r'R'; m[UInt32(0x1E5D)] = r'r'; m[UInt32(0x1E5E)] = r'R'; m[UInt32(0x1E5F)] = r'r';
    m[UInt32(0x1E60)] = r'S'; m[UInt32(0x1E61)] = r's'; m[UInt32(0x1E62)] = r'S'; m[UInt32(0x1E63)] = r's'; m[UInt32(0x1E64)] = r'S'; m[UInt32(0x1E65)] = r's';
    m[UInt32(0x1E66)] = r'S'; m[UInt32(0x1E67)] = r's'; m[UInt32(0x1E68)] = r'S'; m[UInt32(0x1E69)] = r's'; m[UInt32(0x1E6A)] = r'T'; m[UInt32(0x1E6B)] = r't';
    m[UInt32(0x1E6C)] = r'T'; m[UInt32(0x1E6D)] = r't'; m[UInt32(0x1E6E)] = r'T'; m[UInt32(0x1E6F)] = r't'; m[UInt32(0x1E70)] = r'T'; m[UInt32(0x1E71)] = r't';
    m[UInt32(0x1E72)] = r'U'; m[UInt32(0x1E73)] = r'u'; m[UInt32(0x1E74)] = r'U'; m[UInt32(0x1E75)] = r'u'; m[UInt32(0x1E76)] = r'U'; m[UInt32(0x1E77)] = r'u';
    m[UInt32(0x1E78)] = r'U'; m[UInt32(0x1E79)] = r'u'; m[UInt32(0x1E7A)] = r'U'; m[UInt32(0x1E7B)] = r'u'; m[UInt32(0x1E7C)] = r'V'; m[UInt32(0x1E7D)] = r'v';
    m[UInt32(0x1E7E)] = r'V'; m[UInt32(0x1E7F)] = r'v'; m[UInt32(0x1E80)] = r'W'; m[UInt32(0x1E81)] = r'w'; m[UInt32(0x1E82)] = r'W'; m[UInt32(0x1E83)] = r'w';
    m[UInt32(0x1E84)] = r'W'; m[UInt32(0x1E85)] = r'w'; m[UInt32(0x1E86)] = r'W'; m[UInt32(0x1E87)] = r'w'; m[UInt32(0x1E88)] = r'W'; m[UInt32(0x1E89)] = r'w';
    m[UInt32(0x1E8A)] = r'X'; m[UInt32(0x1E8B)] = r'x'; m[UInt32(0x1E8C)] = r'X'; m[UInt32(0x1E8D)] = r'x'; m[UInt32(0x1E8E)] = r'Y'; m[UInt32(0x1E8F)] = r'y';
    m[UInt32(0x1E90)] = r'Z'; m[UInt32(0x1E91)] = r'z'; m[UInt32(0x1E92)] = r'Z'; m[UInt32(0x1E93)] = r'z'; m[UInt32(0x1E94)] = r'Z'; m[UInt32(0x1E95)] = r'z';
    m[UInt32(0x1E96)] = r'h'; m[UInt32(0x1E97)] = r't'; m[UInt32(0x1E98)] = r'w'; m[UInt32(0x1E99)] = r'y'; m[UInt32(0x1EA0)] = r'A'; m[UInt32(0x1EA1)] = r'a';
    m[UInt32(0x1EA2)] = r'A'; m[UInt32(0x1EA3)] = r'a'; m[UInt32(0x1EA4)] = r'A'; m[UInt32(0x1EA5)] = r'a'; m[UInt32(0x1EA6)] = r'A'; m[UInt32(0x1EA7)] = r'a';
    m[UInt32(0x1EA8)] = r'A'; m[UInt32(0x1EA9)] = r'a'; m[UInt32(0x1EAA)] = r'A'; m[UInt32(0x1EAB)] = r'a'; m[UInt32(0x1EAC)] = r'A'; m[UInt32(0x1EAD)] = r'a';
    m[UInt32(0x1EAE)] = r'A'; m[UInt32(0x1EAF)] = r'a'; m[UInt32(0x1EB0)] = r'A'; m[UInt32(0x1EB1)] = r'a'; m[UInt32(0x1EB2)] = r'A'; m[UInt32(0x1EB3)] = r'a';
    m[UInt32(0x1EB4)] = r'A'; m[UInt32(0x1EB5)] = r'a'; m[UInt32(0x1EB6)] = r'A'; m[UInt32(0x1EB7)] = r'a'; m[UInt32(0x1EB8)] = r'E'; m[UInt32(0x1EB9)] = r'e';
    m[UInt32(0x1EBA)] = r'E'; m[UInt32(0x1EBB)] = r'e'; m[UInt32(0x1EBC)] = r'E'; m[UInt32(0x1EBD)] = r'e'; m[UInt32(0x1EBE)] = r'E'; m[UInt32(0x1EBF)] = r'e';
    m[UInt32(0x1EC0)] = r'E'; m[UInt32(0x1EC1)] = r'e'; m[UInt32(0x1EC2)] = r'E'; m[UInt32(0x1EC3)] = r'e'; m[UInt32(0x1EC4)] = r'E'; m[UInt32(0x1EC5)] = r'e';
    m[UInt32(0x1EC6)] = r'E'; m[UInt32(0x1EC7)] = r'e'; m[UInt32(0x1EC8)] = r'I'; m[UInt32(0x1EC9)] = r'i'; m[UInt32(0x1ECA)] = r'I'; m[UInt32(0x1ECB)] = r'i';
    m[UInt32(0x1ECC)] = r'O'; m[UInt32(0x1ECD)] = r'o'; m[UInt32(0x1ECE)] = r'O'; m[UInt32(0x1ECF)] = r'o'; m[UInt32(0x1ED0)] = r'O'; m[UInt32(0x1ED1)] = r'o';
    m[UInt32(0x1ED2)] = r'O'; m[UInt32(0x1ED3)] = r'o'; m[UInt32(0x1ED4)] = r'O'; m[UInt32(0x1ED5)] = r'o'; m[UInt32(0x1ED6)] = r'O'; m[UInt32(0x1ED7)] = r'o';
    m[UInt32(0x1ED8)] = r'O'; m[UInt32(0x1ED9)] = r'o'; m[UInt32(0x1EDA)] = r'O'; m[UInt32(0x1EDB)] = r'o'; m[UInt32(0x1EDC)] = r'O'; m[UInt32(0x1EDD)] = r'o';
    m[UInt32(0x1EDE)] = r'O'; m[UInt32(0x1EDF)] = r'o'; m[UInt32(0x1EE0)] = r'O'; m[UInt32(0x1EE1)] = r'o'; m[UInt32(0x1EE2)] = r'O'; m[UInt32(0x1EE3)] = r'o';
    m[UInt32(0x1EE4)] = r'U'; m[UInt32(0x1EE5)] = r'u'; m[UInt32(0x1EE6)] = r'U'; m[UInt32(0x1EE7)] = r'u'; m[UInt32(0x1EE8)] = r'U'; m[UInt32(0x1EE9)] = r'u';
    m[UInt32(0x1EEA)] = r'U'; m[UInt32(0x1EEB)] = r'u'; m[UInt32(0x1EEC)] = r'U'; m[UInt32(0x1EED)] = r'u'; m[UInt32(0x1EEE)] = r'U'; m[UInt32(0x1EEF)] = r'u';
    m[UInt32(0x1EF0)] = r'U'; m[UInt32(0x1EF1)] = r'u'; m[UInt32(0x1EF2)] = r'Y'; m[UInt32(0x1EF3)] = r'y'; m[UInt32(0x1EF4)] = r'Y'; m[UInt32(0x1EF5)] = r'y';
    m[UInt32(0x1EF6)] = r'Y'; m[UInt32(0x1EF7)] = r'y'; m[UInt32(0x1EF8)] = r'Y'; m[UInt32(0x1EF9)] = r'y';

    // 合计 405 个码点
    return m
}

/** 对单个字符串做变音符折叠（NFD 分解 + 丢弃组合变音符），非收录码点原样保留 */
private func foldDiacritics(input: String): String {
    let sb = StringBuilder()
    for (ch in input.toRuneArray()) {
        sb.append(DIACRITIC_FOLD_TABLE.get(UInt32(ch)) ?? ch)
    }
    return sb.toString()
}

/**
 * cleanUsernameText —— 用户名输入共享清洗函数（TC-0082 R2 修法 F2-a 边界条件：
 * "粘贴路径与逐键路径共用同一清洗函数"）。顺序对齐源侧 :567-598：
 *   1. 变音符折叠（foldDiacritics）
 *   2. 空格 → 下划线
 *   3. 丢弃仍不在 [a-zA-Z0-9_] 合法集内的字符（不上屏，不拼近似）
 * 幂等：对已清洗过的字符串重复调用不产生进一步变化，双路径(onChange/onPaste)各自独立
 * 调用也能收敛到同一结果，不需要额外的调用序同步。
 */
private func cleanUsernameText(raw: String): String {
    let folded = foldDiacritics(raw)
    let sb = StringBuilder()
    for (ch in folded.toRuneArray()) {
        if (ch == r' ') {
            sb.append(r'_')
        } else if ((ch >= r'a' && ch <= r'z') || (ch >= r'A' && ch <= r'Z') || (ch >= r'0' && ch <= r'9') || ch == r'_') {
            sb.append(ch)
        }
        // 其余(!、CJK、emoji 等)直接丢弃，不上屏 —— 对齐源侧 validIdentifierSet 过滤效果
    }
    return sb.toString()
}

// ======================================================================
// ItemListInputRow — 左标题 + 右 TextInput
// ======================================================================
/**
 * 输入行。对齐现有设置页 Row { Text(title); TextInput(...) }。
 *
 * Props:
 *   title:       左标题(空串=不显示标题，TextInput 占满)。全仓唯一真实调用点
 *                (pages/UsernameSettingsPage.cj:322-328)传静态字面量 "@"，非响应式风险面，
 *                沿用 plain var。
 *   text:        当前文本值。`@Prop`(无默认值，调用点必须显式传参；TC-0086/TC-0082 返修轮
 *                修复：原普通 var 只在组件首次构造时赋值一次，父组件 @State 变化后已挂载的
 *                行会冻结在构造时初值，见 dev_pattern.md D-125、ItemListToggleRow.isOn 同型
 *                先例。唯一真实调用点已核实按 D-125 传裸 @State 字段 `this.username`，非表
 *                达式/方法包装)。
 *   placeholder: 占位提示。唯一真实调用点传静态字面量 "username"，非响应式风险面，沿用 plain var。
 *   onChange:    文本变更回调(String)——Username 类型下回调收到的已是清洗后的值。回调是方法
 *                引用而非快照数据，调用时经 `this` 动态派发到调用方当前状态，不受 D-125 冻结
 *                问题影响，沿用 plain var。
 *   inputType:   输入类型(默认 Regular，TC-0082 R2 修法新增)。唯一真实调用点传静态枚举字面量
 *                ItemListInputType.Username，非响应式风险面，沿用 plain var。
 *
 * Username 类型实现说明(diag-suite_settings_root-TC-0082.md round2 F2-a)：
 *   - `.inputFilter("[a-zA-Z0-9_ ]", error: {...})` 是 ArkUI 原生逐键关卡，只能拒收不能改写
 *     (Cangjie ArkUI 无 iOS `shouldChangeCharactersIn:` 等价的"拦截并改写"钩子)；未落入该
 *     字符集的按键在到达 onChange 前即被拒收，同时触发 error 回调(抖动+触觉)。
 *   - 变音符折叠因此对"逐键输入"路径无可观测效果(已被 inputFilter 挡在前面)，但
 *     `.onPaste(callback: ?(String) -> Unit)` 是独立于 inputFilter 的原生钩子，可以拿到未经
 *     逐键过滤的完整粘贴串，折叠在这里真正生效——这是折叠表在本组件里唯一有实际效果的路径，
 *     与逐键路径共用同一个 cleanUsernameText()。
 *   - 空格 → 下划线的改写只能在 onChange 里做(inputFilter 放行空格但不能重写)。
 *   - 二者最终都通过外部 onChange(cleaned) 把清洗后的值交回调用方；调用方把返回值写回自己的
 *     裸 @State 字段、驱动本组件在下一次父组件 build() 时以新 text 值重新构造，从而让 TextInput
 *     的显示内容收敛到清洗结果(text 现为 `@Prop`，见上方 Props 说明；调用方还需保证首次
 *     build() 前该裸 @State 字段已有值，否则首帧仍会短暂显示初值——本组件的唯一调用点
 *     pages/UsernameSettingsPage.cj 已配合把 username 的同步初始读取提前到 aboutToAppear())。
 */
@Component
public class ItemListInputRow {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    public var title: String = ""
    public var inputId: String = ""
    // @Prop：父组件重渲染时随父侧最新值单向同步覆盖(TC-0082/TC-0086 返修轮修复，详见上方类
    // 注释 + dev_pattern.md D-125)。无默认值，调用点必须显式传入(编译期强制；全仓唯一真实
    // 调用点 pages/UsernameSettingsPage.cj:324 已核实显式传 text: this.username)。
    @Prop var text: String
    public var placeholder: String = ""
    public var onChange: (String) -> Unit = { _ => }
    public var inputType: ItemListInputType = ItemListInputType.Regular
    // diag-suite_settings_root-TC-0081.md §6-A4：新增可选参数，默认关，既有调用点零改动。
    // 对位源侧 ItemListSingleLineInputItem.swift:478-495 updateClearButtonVisibility()
    // 的 .always 语义——非空即显、点击清空并以 "" 触发既有 onChange。
    public var showClearButton: Bool = false
    // 抖动位移(仅 Username 类型下，inputFilter 拒收非法字符时触发；见类注释)
    @State var shakeOffset: Float64 = 0.0
    // diag-suite_settings_appearance-TC-0402-round6.md F-2：标题文字色随主题走。
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()

    // R-112: enum 不自动派生 ==，用 match 判别而不是比较运算符
    private func isUsername(): Bool {
        match (this.inputType) {
            case ItemListInputType.Username => true
            case ItemListInputType.Regular => false
        }
    }

    // 抖动关键帧：0 → +3vp → -3vp → +3vp → -3vp → 0，共 0.3s，每段 0.06s、不衰减
    // (对齐源侧 ShakeAnimation.swift:9-40 的确定参数，诊断报告 F2-a 逐字给出)
    private func runShakeStep(offsets: Array<Float64>, idx: Int64): Unit {
        if (idx >= offsets.size) {
            return
        }
        let nextIdx = idx + 1
        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 60, curve: Curve.Linear, onFinish: { =>
            this.runShakeStep(offsets, nextIdx)
        }), { =>
            this.shakeOffset = offsets[idx]
        })
    }

    private func triggerIllegalCharFeedback(): Unit {
        this.runShakeStep([3.0, -3.0, 3.0, -3.0, 0.0], 0)
        // 源侧同点位 HapticFeedback().error() → notification.error 映射(见 HapticService.cj)
        triggerHaptic("notification", "error")
    }

    func build() {
        Row {
            if (this.title.size > 0) {
                Text(trSource(this.title))
                    .fontSize(17)
                    .fontColor(this.presentation.textColor)
                    // diag-suite_settings_root-TC-0081-round6.md F-2：
                    // UsernameSetupController.swift:196 spacing: 10.0（值起点 = 标题右缘 + spacing，
                    // 源侧字段内部无额外内缩，见 ItemListSingleLineInputItem.swift:401）。
                    .margin(right: 10)
            }

            if (this.isUsername()) {
                TextInput(placeholder: this.placeholder, text: this.text)
                    .id(this.inputId)
                    .layoutWeight(1)
                    .fontSize(17)
                    .backgroundColor(Color.Transparent)
                    // diag-suite_settings_root-TC-0081-round6.md F-2：ArkUI TextInput 默认横向
                    // 内边距(实测≈16vp)与源侧无对应物，源侧 spacing 通道已由标题 margin 承载，
                    // 此处清零避免叠加内缩。同型先例 pages/ProxySettingsPage.cj:1283 等 5 处。
                    .padding(left: 0, right: 0)
                    // diag-suite_settings_root-TC-0081-round6.md F-3：
                    // ItemListSingleLineInputItem.swift:255-256 rightInset 规则 —— 无清除按钮
                    // 态 rightInset=16，有清除按钮态 rightInset=16+32=48（该量只作用于文本字段
                    // 宽度，清除按钮自身另有独立 38pt 命中区，见下方 Stack）。
                    .margin(right: if (this.showClearButton && this.text.size > 0) { 48 } else { 16 })
                    .inputFilter("[a-zA-Z0-9_ ]", error: { _: String => this.triggerIllegalCharFeedback() })
                    .onPaste({ pasted: String =>
                        this.onChange(cleanUsernameText(pasted))
                    })
                    .onChange({ value: String =>
                        this.onChange(cleanUsernameText(value))
                    })
                    .translate(x: this.shakeOffset)
            } else {
                TextInput(placeholder: this.placeholder, text: this.text)
                    .id(this.inputId)
                    .layoutWeight(1)
                    .fontSize(17)
                    .backgroundColor(Color.Transparent)
                    .padding(left: 0, right: 0)
                    .margin(right: if (this.showClearButton && this.text.size > 0) { 48 } else { 16 })
                    .onChange({ value: String =>
                        this.onChange(value)
                    })
            }

            if (this.showClearButton && this.text.size > 0) {
                // diag-suite_settings_root-TC-0081-round6.md F-3：清除按钮从"行内吃 Row 右
                // 内边距的图标"改成"右缘与卡齐平的 38vp 定宽按钮"，对位
                // ItemListSingleLineInputItem.swift:416-419（38pt 按钮右缘齐平，图标居中）。
                Stack(alignContent: Alignment.Center) {
                    Image(@r(app.media.itemlist_ic_input_clear))
                        .width(16)
                        .height(16)
                }
                .width(38)
                .height(56)
                .onClick({ _ => this.onChange("") })
            }
        }
        .width(100.percent)
        .height(56)
        // diag-suite_settings_root-TC-0081-round6.md F-3：清除按钮改为右缘齐平的独立按钮后，
        // 行不再对右侧留 16vp 内边距（否则按钮会再被行 padding 推离卡右缘）。
        .padding(left: 16, right: 0)
        .alignItems(VerticalAlign.Center)
    }
}
