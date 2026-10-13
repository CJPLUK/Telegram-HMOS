/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 */
package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*

/**
 * ContextMenu — 可复用的 Telegram 风格长按上下文菜单（消息 / 头像操作面板）。
 *
 * 对应 iOS Telegram-iOS submodules/ContextUI：
 *   长按某条消息 / 某个头像弹出竖排操作菜单（回复 / 复制 / 转发 / 删除…），
 *   每项含标题 + 可选图标，删除等破坏性操作文字标红（iOS systemRed ≈ 0xFF3B30），
 *   不可用项灰显且禁点。本单元把以前各页零散内联的 action sheet
 *   （ContactListPage.showContextMenu / CallHistoryPage / GroupMembersPage 各写各的）
 *   收敛成一套统一、可复用的菜单数据模型 + 两种渲染入口。
 *
 * ─────────────────── ArkUI menu API（cangjie-kb 实证，不臆造）───────────────────
 * 鸿蒙 ArkUI 通用属性提供原生上下文菜单：
 *   func bindContextMenu(builder!: ?CustomBuilder, responseType!: ?ResponseType,
 *                        options!: ?ContextMenuOptions = None): T
 *   - builder 是 CustomBuilder == `() -> Unit`（**无参** @Builder）。
 *   - responseType: ResponseType.LongPress（长按）/ RightClick / ...
 *   菜单体用 Menu { MenuItem(...) ... } 组合，Menu.init(child!: () -> Unit)。
 *   MenuItem 关键能力（来自 cj-menu-menuitem）：
 *     MenuItem(startIcon!: ?ResourceStr, content!: ?ResourceStr,
 *              endIcon!: ?ResourceStr, labelInfo!: ?ResourceStr, builder!: ...)
 *     .contentFontColor(value: ?ResourceColor)  —— 菜单项标题色（破坏性操作标红）
 *     .enabled(value: ?Bool)                    —— 禁用项灰显且禁点
 *   MenuItem 本身没有 onClick 命名参数；点击回调用通用事件 .onClick({ evt => ... }) 挂上去。
 *   注意：CustomBuilder 是无参的，菜单数据（items）必须由调用方先存进 @State，
 *   再用 `bind(this.someNoArgBuilder, this)` 把无参 builder 交给 bindContextMenu。
 *
 *   ⚠ startIcon 是 ResourceStr（图片资源），塞不进 emoji 字形。真·图标资源一律走
 *     ContextMenuItem.iconRes（?ResourceStr，默认 None）——两种渲染入口都会优先用它：
 *     原生 Menu 路径把它传给 MenuItem.startIcon（见 nativeMenuStartIcon），自绘
 *     ContextMenuView 路径渲染成 Image(...).fillColor(...)。iconText 仅作 emoji 兜底
 *     通道（无 iconRes 时使用），原生 MenuItem 路径里 emoji 会前缀进 content 文本
 *     （见 nativeMenuContent）。
 *
 * 本单元提供两件可复用资产（照 TooltipBubble.cj「内容组件 + options 工厂」双资产范式）：
 *   1) buildContextMenuItems(items) —— 在一个 @Builder 上下文里把 Array<ContextMenuItem>
 *      渲染成原生 Menu { MenuItem... }。供调用方包进自己的无参 @Builder，交给
 *      `.bindContextMenu(bind(thatBuilder, this), ResponseType.LongPress)`。
 *   2) @Component ContextMenuView —— 受控叠加层方式的自绘菜单卡片（深色/浅色圆角卡片 +
 *      菜单项列表），照本目录 OverlayStatusView / ContactListPage 现有 overlay 范式，
 *      作为 bindContextMenu 不便（如需自定义命中区域 / 锚定 / 动画）时的后备。
 *
 * ──────────────────────── 用法 A：原生 bindContextMenu ────────────────────────
 *   @Component
 *   class SomeRow {
 *       // 菜单数据存进成员（CustomBuilder 无参，故由 @State / 成员承载 items）
 *       private let menuItems: Array<ContextMenuItem> = [
 *           ContextMenuItem(title: "Reply",   iconText: "↩️", onClick: { => /* ... */ }),
 *           ContextMenuItem(title: "Copy",    iconText: "📋", onClick: { => /* ... */ }),
 *           ContextMenuItem(title: "Forward", iconText: "➡️", onClick: { => /* ... */ }),
 *           ContextMenuItem(title: "Delete",  iconText: "🗑", destructive: true,
 *                           onClick: { => /* ... */ })
 *       ]
 *
 *       // 无参 @Builder：内部把 items 交给 buildContextMenuItems
 *       @Builder
 *       func contextMenuBuilder() {
 *           buildContextMenuItems(this.menuItems)
 *       }
 *
 *       func build() {
 *           Row { /* 消息气泡 / 头像 */ }
 *               .bindContextMenu(
 *                   builder: bind(this.contextMenuBuilder, this),
 *                   responseType: ResponseType.LongPress
 *               )
 *       }
 *   }
 *
 * ──────────────────────── 用法 B：受控自绘叠加层 ────────────────────────
 *   @Component
 *   class SomePage {
 *       @State var showMenu: Bool = false
 *       private let menuItems: Array<ContextMenuItem> = [ /* 同上 */ ]
 *
 *       func build() {
 *           Stack {
 *               // ... 页面主体；长按某项时 this.showMenu = true
 *               if (this.showMenu) {
 *                   ContextMenuView(
 *                       items: this.menuItems,
 *                       onDismiss: { => this.showMenu = false }
 *                   )
 *               }
 *           }
 *       }
 *   }
 *   （ContextMenuView 内部点击任一项时，先触发该项 onClick，再调 onDismiss 关闭叠加层。）
 */

// iOS systemRed —— 破坏性操作（删除等）标题色。
let CONTEXT_MENU_DESTRUCTIVE_COLOR: UInt32 = 0xFFFF3B30
// 普通菜单项标题色（近黑）。
let CONTEXT_MENU_NORMAL_COLOR: UInt32 = 0xFF000000
// 禁用项灰显色。
let CONTEXT_MENU_DISABLED_COLOR: UInt32 = 0xFFC7C7CC
// 自绘叠加层：半透明遮罩。
let CONTEXT_MENU_SCRIM_COLOR: UInt32 = 0x66000000
// 自绘叠加层：菜单卡片底色（浅色卡片，Telegram iOS 默认浅色 action sheet）。
let CONTEXT_MENU_CARD_COLOR: UInt32 = 0xFFFFFFFF
// 自绘叠加层：分隔线色。
let CONTEXT_MENU_DIVIDER_COLOR: UInt32 = 0xFFE5E5EA

/**
 * 上下文菜单项数据模型。
 *
 * 用 class（引用类型）便于在 Array 中携带闭包 onClick；字段命名参数 `!`。
 *
 * 参数：
 *   title:       菜单项标题（如 "Reply" / "Delete"）。
 *   iconText:    emoji 兜底图标通道，仅在无 iconRes 时使用；新代码一律用 iconRes。
 *                空串表示无图标。（原生 MenuItem 路径会把它前缀进 content 文本；
 *                自绘路径渲染成独立 Text。）
 *   iconRes:     可选真实矢量/位图图标资源（如 @r(app.media.xxx)）；非 None 时两种渲染
 *                入口都优先画它（原生 Menu 路径传给 MenuItem.startIcon，自绘
 *                ContextMenuView 路径渲染 Image 并用 resolveContentColor() 着色），
 *                iconText 分支不再生效。默认 None，既有调用点零改动。
 *   destructive: 是否破坏性操作（删除等），为 true 时标题标红 0xFF3B30。
 *   enabled:     是否可点击；false 时灰显且禁点。
 *   onClick:     点击回调（无参）。
 *   isSeparator: 是否为分组分隔项（对位 iOS ContextMenuActionItem.separator）；为 true
 *                时本项渲染为一条分隔带，title/iconText/iconRes/onClick 均被忽略。
 *                不直接传该参数构造，用静态工厂 ContextMenuItem.separator()。
 *   isText:      是否为纯说明文本项（对位 iOS ActionSheetTextItem，仅供 RC-6c 使用：底部
 *                ActionSheet 的正文说明行——居中灰色小字，不可点，不挂 onClick）。为 true
 *                时本项按 title 渲染纯文本，忽略 iconText/iconRes/destructive/enabled/onClick。
 *                不直接传该参数构造，用静态工厂 ContextMenuItem.text(_:)。
 *   centered:    RC-E12-11：本组件同时承载两个源侧不同语义的原语——ContextUI 的上下文菜单
 *                条目（源侧本来就左对齐，isText=false 的默认路径）与 Display 的
 *                ActionSheetButtonItem（源侧居中）。默认 false（左对齐，既有全部上下文菜单
 *                调用点行为零改动）；只有把 ContextMenuView 当贴底 ActionSheet 使用的调用方
 *                (如 SelectivePrivacySettingsPeersPage 的 Delete All / Cancel）才显式传 true。
 *                只影响自绘 ContextMenuView 路径的可点条目行标题对齐；不影响 isText 说明行
 *                （恒居中）、不影响原生 Menu 路径（buildContextMenuItems 无对齐概念）。
 */
public class ContextMenuItem {
    public var title: String
    public var iconText: String
    public var iconRes: ?ResourceStr
    public var destructive: Bool
    public var enabled: Bool
    public var onClick: () -> Unit
    public var isSeparator: Bool
    public var isText: Bool
    public var centered: Bool

    public init(
        title!: String,
        iconText!: String = "",
        iconRes!: ?ResourceStr = None,
        destructive!: Bool = false,
        enabled!: Bool = true,
        onClick!: () -> Unit = { => },
        isSeparator!: Bool = false,
        isText!: Bool = false,
        centered!: Bool = false
    ) {
        this.title = title
        this.iconText = iconText
        this.iconRes = iconRes
        this.destructive = destructive
        this.enabled = enabled
        this.onClick = onClick
        this.isSeparator = isSeparator
        this.isText = isText
        this.centered = centered
    }

    // 静态工厂：构造一条分组分隔带（对位 iOS ContextMenuActionItem.separator）。
    public static func separator(): ContextMenuItem {
        return ContextMenuItem(title: "", enabled: false, isSeparator: true)
    }

    // 静态工厂：构造一条纯说明文本项（对位 iOS ActionSheetTextItem；diag-suite_settings_
    // privacy-TC-0132.md RC-6c 授权新增，仅供该报告 §6 RC-6 的 Delete All 确认层使用）。
    public static func text(title!: String): ContextMenuItem {
        return ContextMenuItem(title: title, enabled: false, isText: true)
    }

    // 解析当前项的标题色（破坏性→红 / 禁用→灰 / 普通→黑）。
    func resolveContentColor(): UInt32 {
        if (!this.enabled) {
            return CONTEXT_MENU_DISABLED_COLOR
        }
        if (this.destructive) {
            return CONTEXT_MENU_DESTRUCTIVE_COLOR
        }
        return CONTEXT_MENU_NORMAL_COLOR
    }

    // 原生 MenuItem.content 用文本：把 emoji 图标前缀进标题（startIcon 只收图片资源）。
    func nativeMenuContent(): String {
        if (this.iconText.size > 0) {
            return this.iconText + "  " + this.title
        }
        return this.title
    }

    // 原生 MenuItem.startIcon 用值：有 iconRes 用它，否则空串——保持与既有代码一致的
    // "恒传非 None 值" 行为（原生路径此前恒传 ""，未验证过 None 的渲染表现，不冒险切换）。
    func nativeMenuStartIcon(): ?ResourceStr {
        if (this.iconRes.isSome()) {
            return this.iconRes
        }
        return ""
    }
}

/**
 * 在一个 @Builder 上下文里把 items 渲染成原生 ArkUI Menu { MenuItem... }。
 *
 * 设计为顶层 @Builder 函数（仓颉 @Builder 可作用于顶层函数），便于在调用方的
 * 无参成员 @Builder 内直接 `buildContextMenuItems(this.menuItems)` 调用，再把那个
 * 无参 @Builder 交给 `.bindContextMenu(bind(builder, this), ResponseType.LongPress)`。
 *
 * 渲染规则：
 *   - startIcon：有 iconRes 用它，否则空串（见 ContextMenuItem.nativeMenuStartIcon）；
 *   - content：iconText + title（见 ContextMenuItem.nativeMenuContent，iconText 只在
 *     无 iconRes 时兜底生效）；
 *   - 破坏性项 .contentFontColor 标红，禁用项 .enabled(false) 灰显禁点；
 *   - 每项 .onClick 触发该项 onClick（菜单点击后由系统自动收起）；
 *   - isSeparator 项在本原生路径下跳过、不发 MenuItem（ArkUI 原生 Menu 无经 KB 实证的
 *     分隔项原语，不臆造；原生菜单项间本身有系统分割线）。
 *   - isText 项同样跳过、不发 MenuItem——原生 Menu 的 MenuItem 恒可点，没有"纯文本不可点
 *     行"的对位原语（RC-6c）；跳过而不是降级成一个禁用 MenuItem，避免纯说明文本以可点击
 *     的 MenuItem 形态漏进原生菜单。
 */
@Builder
public func buildContextMenuItems(items: Array<ContextMenuItem>): Unit {
    Menu {
        ForEach(items, itemGenerator: { item: ContextMenuItem, _index: Int64 =>
            if (!item.isSeparator && !item.isText) {
                // 本工具链 MenuItem 五个命名参数均必填（startIcon/content/endIcon/labelInfo/builder）；
                // startIcon 优先用 iconRes（真图标），否则退回空串；无子菜单 → builder: None。
                MenuItem(
                    startIcon: item.nativeMenuStartIcon(),
                    content: item.nativeMenuContent(),
                    endIcon: "",
                    labelInfo: "",
                    builder: None<() -> Unit>
                )
                    .contentFontColor(Color(item.resolveContentColor()))
                    .enabled(item.enabled)
                    .onClick({ _evt =>
                        if (item.enabled) {
                            item.onClick()
                        }
                    })
            }
        })
    }
}

/**
 * ContextMenuView — 受控自绘上下文菜单叠加层（后备渲染入口）。
 *
 * 当 bindContextMenu 不便（需要自定义命中、底部 action-sheet 式锚定、统一深浅色风格、
 * 或在不支持原生 Menu 的容器内）时使用。照本目录 OverlayStatusView / PromptDialog 的
 * 受控叠加层范式：本组件不持有业务状态，items / onDismiss 由调用方传入。
 *
 * 渲染：全屏半透明遮罩（点击关闭）+ 底部圆角白卡片 + 竖排菜单项列表；
 *   破坏性项标红、禁用项灰显且禁点、点击任一可用项先触发 onClick 再 onDismiss。
 *
 * @Component 的基本类型 / Array / 闭包参数用普通 var（非 @Prop）——
 *   见同目录 TooltipBubble / MessageReactions 约定。
 *
 * 参数：
 *   items:       菜单项列表。
 *   onDismiss:   关闭回调（点遮罩 / 点完某项后调用，由调用方把驱动显示的 @State 置 false）。
 *   bottomInset: 底部菜单卡片额外内边距（vp），用于避让宿主页面的浮动元素（如
 *                MainTabPage 的悬浮 tab bar）。默认 0（现有调用点行为不变）；需要避让时
 *                由调用方按自己宿主的浮层高度显式传入，本组件不硬编码任何具体数值。
 */
@Component
public class ContextMenuView {
    public var items: Array<ContextMenuItem> = Array<ContextMenuItem>()
    public var onDismiss: () -> Unit = { => }
    public var bottomInset: Float64 = 0.0

    func build() {
        Column {
            // 半透明遮罩：点击空白处关闭。
            Column {}
                .width(100.percent)
                .layoutWeight(1)
                .backgroundColor(CONTEXT_MENU_SCRIM_COLOR)
                .onClick({ _evt =>
                    this.onDismiss()
                })

            // 底部菜单卡片。
            Column {
                ForEach(this.items, itemGenerator: { item: ContextMenuItem, index: Int64 =>
                    Column {
                        if (item.isText) {
                            // RC-6c：纯说明文本项（对位 iOS ActionSheetTextItem）——居中灰色
                            // 小字，不挂 onClick，不受 enabled/destructive/图标槽影响。
                            Text(item.title)
                                .fontSize(13)
                                .fontColor(CONTEXT_MENU_DISABLED_COLOR)
                                .textAlign(TextAlign.Center)
                                .width(100.percent)
                                .padding(left: 16, right: 16, top: 16, bottom: 16)
                        } else if (item.isSeparator) {
                            // 分组分隔带：不画行内容，前后也不再叠加普通分隔线
                            // （见下方分隔线条件对 isSeparator 邻项的排除）。
                            Row {}
                                .width(100.percent)
                                .height(8)
                                .backgroundColor(CONTEXT_MENU_DIVIDER_COLOR)
                        } else {
                            Row(space: 10.0) {
                                if (item.iconRes.isSome()) {
                                    Image(item.iconRes.getOrThrow())
                                        .width(24)
                                        .height(24)
                                        .fillColor(item.resolveContentColor())
                                        .opacity(if (item.enabled) { 1.0 } else { 0.4 })
                                } else if (item.iconText.size > 0) {
                                    Text(item.iconText)
                                        .fontSize(18)
                                        .opacity(if (item.enabled) { 1.0 } else { 0.4 })
                                }
                                Text(item.title)
                                    .fontSize(17)
                                    .fontColor(item.resolveContentColor())
                                    .layoutWeight(1)
                                    .textAlign(if (item.centered) { TextAlign.Center } else { TextAlign.Start })
                            }
                            .width(100.percent)
                            .height(52)
                            .padding(left: 16, right: 16)
                            .alignItems(VerticalAlign.Center)
                            .opacity(if (item.enabled) { 1.0 } else { 0.6 })
                            .onClick({ _evt =>
                                if (item.enabled) {
                                    item.onClick()
                                    this.onDismiss()
                                }
                            })
                        }

                        // 项间分隔线（最后一项不画；当前项或下一项是分隔带时也不画，
                        // 避免分隔带上下再叠一条细线）。
                        if (index < this.items.size - 1 && !item.isSeparator &&
                            !this.items[index + 1].isSeparator) {
                            Divider()
                                .color(CONTEXT_MENU_DIVIDER_COLOR)
                                .strokeWidth(0.5)
                        }
                    }
                })
            }
            .width(100.percent)
            .backgroundColor(CONTEXT_MENU_CARD_COLOR)
            .borderRadius(topLeft: 14, topRight: 14)
            .padding(bottom: this.bottomInset)
        }
        .width(100.percent)
        .height(100.percent)
        .position(x: 0, y: 0)
    }
}

/**
 * ContextPopoverMenu — 锚定在触发按钮下方的浮层菜单（对位 iOS ContextUI 的 popover 形态，
 * 如资料页「more」菜单）。图标资源自带颜色，本组件不做着色。
 *
 *   topOffset:  卡片顶边距屏幕顶部的距离（vp），由调用方按触发按钮位置传入。
 *   rightInset: 卡片右边距屏幕右侧的距离（vp）。
 */
@Component
public class ContextPopoverMenu {
    public var items: Array<ContextMenuItem> = Array<ContextMenuItem>()
    public var onDismiss: () -> Unit = { => }
    public var topOffset: Float64 = 0.0
    public var rightInset: Float64 = 16.0
    // 贴着触发行左缘展开（列表行的上下文菜单）；默认贴右缘（导航栏按钮）
    public var alignStart: Bool = false
    public var leftInset: Float64 = 16.0

    func build() {
        Stack(alignContent: if (this.alignStart) { Alignment.TopStart } else { Alignment.TopEnd }) {
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0x1A000000)
                .onClick({ _evt => this.onDismiss() })

            Column {
                ForEach(this.items, itemGenerator: { item: ContextMenuItem, index: Int64 =>
                    Column {
                        if (item.isSeparator) {
                            Row {}
                                .width(100.percent)
                                .height(8)
                                .backgroundColor(0xFFF0F0F2)
                        } else {
                            Row(space: 14.0) {
                                if (item.iconRes.isSome()) {
                                    Image(item.iconRes.getOrThrow())
                                        .width(24)
                                        .height(24)
                                        .opacity(if (item.enabled) { 1.0 } else { 0.4 })
                                }
                                Text(item.title)
                                    .fontSize(17)
                                    .fontColor(item.resolveContentColor())
                                    .layoutWeight(1)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                            }
                            .width(100.percent)
                            .height(46)
                            .padding(left: 16, right: 16)
                            .alignItems(VerticalAlign.Center)
                            .onClick({ _evt =>
                                if (item.enabled) {
                                    item.onClick()
                                    this.onDismiss()
                                }
                            })
                        }
                        if (index < this.items.size - 1 && !item.isSeparator &&
                            !this.items[index + 1].isSeparator) {
                            Divider()
                                .color(CONTEXT_MENU_DIVIDER_COLOR)
                                .strokeWidth(0.5)
                                .margin(left: 54)
                        }
                    }
                })
            }
            .width(250)
            .backgroundColor(CONTEXT_MENU_CARD_COLOR)
            .borderRadius(14)
            .clip(true)
            .shadow(radius: 24.0, color: 0x30000000, offsetX: 0.0, offsetY: 6.0)
            .margin(top: this.topOffset,
                left: if (this.alignStart) { this.leftInset } else { 0.0 },
                right: if (this.alignStart) { 0.0 } else { this.rightInset })
        }
        .width(100.percent)
        .height(100.percent)
        .position(x: 0, y: 0)
    }
}
