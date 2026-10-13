package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import std.collection.ArrayList

/**
 * DebugPageArguments — Debug 屏（`pages/DebugSettingsPage.cj`，路由名 "DebugSettingsPage"，
 * 无法在 allowlist 外新增/改路由，类名与既有路由绑定不能改）的共享支撑机：
 *
 *   - `DebugSheetButton` / `DebugSheetButtonStyle`：ActionSheet 按钮的最小数据模型。
 *   - `DebugActionSheet`：源侧多处 `ActionSheetController`（Send * 家族 7 处、
 *     `Clear Database` / `Clear Database and Cache` 2 处）共用的底部弹层视觉容器，
 *     对齐本工程既有 `components/DeleteChatPeerActionSheetComponent.cj` 的“白色圆角卡片 +
 *     背景遮罩点击关闭 + 按钮组”范式。
 *
 * 与 `pages/DebugAccountsPageArguments.cj` 同包（`pages`），Login-to-another-account 的
 * Production/Test/Cancel sheet 复用同一个 `DebugActionSheet`。
 *
 * 本仓命名约定：`*PageArguments.cj` 是既有的“页面级仓颉实现文件”命名后缀（见
 * `pages/LanguageSelectionPageArguments.cj` / `pages/BotReceiptPageArguments.cj`）。
 * 本文件不是独立路由页（未注册 `route_map.json` / `.ets` 壳，越界文件，交付报告已说明），
 * 而是 Debug 屏 fc 声明的第二个 target_file，承载其“参数化”支撑层——ActionSheet 模型与容器。
 */

// ==================== ActionSheet 按钮模型 ====================

public enum DebugSheetButtonStyle {
    | SheetAccent      // 蓝色（源侧 .accent）
    | SheetDestructive // 红色（源侧 .destructive）
    | SheetBold        // 蓝色加粗（源侧 Cancel 常用 .accent + .bold）
}

public class DebugSheetButton {
    public var label: String = ""
    public var style: DebugSheetButtonStyle = DebugSheetButtonStyle.SheetAccent
    public var onTap: () -> Unit = { => }

    public init() {}

    public init(label: String, style: DebugSheetButtonStyle, onTap: () -> Unit) {
        this.label = label
        this.style = style
        this.onTap = onTap
    }
}

private func debugSheetButtonColor(style: DebugSheetButtonStyle): UInt32 {
    match (style) {
        case DebugSheetButtonStyle.SheetDestructive => 0xFF3B30
        case _ => 0x007AFF
    }
}

private func debugSheetButtonWeight(style: DebugSheetButtonStyle): FontWeight {
    match (style) {
        case DebugSheetButtonStyle.SheetBold => FontWeight.Bold
        case _ => FontWeight.Regular
    }
}

// ==================== ActionSheet 容器（Send * 家族 / Clear Database 家族 / Accounts Login 共用） ====================

/**
 * DebugActionSheet — 底部弹层。
 *
 * Props:
 *   message:    顶部纯文本说明（源侧 `ActionSheetTextItem`；空串=不显示，对应 Send * 家族无文案行）
 *   group1:     第一组按钮（源侧首个 `ActionSheetItemGroup`）
 *   group2:     第二组按钮（源侧第二个 `ActionSheetItemGroup`，通常只含 Cancel）
 *   onDismiss:  背景遮罩点击时的关闭回调
 *
 * 视觉对齐 `components/DeleteChatPeerActionSheetComponent.cj`：背景半透明遮罩 + 底部白色圆角卡片。
 */
@Component
public class DebugActionSheet {
    public var message: String = ""
    public var group1: ArrayList<DebugSheetButton> = ArrayList<DebugSheetButton>()
    public var group2: ArrayList<DebugSheetButton> = ArrayList<DebugSheetButton>()
    public var onDismiss: () -> Unit = { => }

    // D-115: @Component 内 @Builder 函数不能带参数调用——按钮行直接在两处 ForEach
    // itemGenerator 闭包内联展开（不抽 buildButton(btn) 这类带参 @Builder）。

    func build() {
        Column {
            Column { }
                .width(100.percent)
                .layoutWeight(1)
                .backgroundColor(0x66000000)
                .onClick({ _ => this.onDismiss() })

            Column {
                if (this.message.size > 0) {
                    Text(this.message)
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .textAlign(TextAlign.Center)
                        .padding(left: 16, right: 16, top: 16, bottom: 12)
                        .width(100.percent)
                }
                ForEach(this.group1.toArray(), itemGenerator: { btn: DebugSheetButton, idx: Int64 =>
                    Text(btn.label)
                        .fontSize(17)
                        .fontWeight(debugSheetButtonWeight(btn.style))
                        .fontColor(debugSheetButtonColor(btn.style))
                        .width(100.percent)
                        .height(50)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => btn.onTap() })
                    if (idx < this.group1.size - 1) {
                        Divider().color(0xE5E5EA).strokeWidth(1)
                    }
                })
            }
            .width(100.percent)
            .backgroundColor(0xFFFFFF)
            .borderRadius(14)
            .margin(left: 8, right: 8, bottom: 8)

            Column {
                ForEach(this.group2.toArray(), itemGenerator: { btn: DebugSheetButton, idx: Int64 =>
                    Text(btn.label)
                        .fontSize(17)
                        .fontWeight(debugSheetButtonWeight(btn.style))
                        .fontColor(debugSheetButtonColor(btn.style))
                        .width(100.percent)
                        .height(50)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => btn.onTap() })
                    if (idx < this.group2.size - 1) {
                        Divider().color(0xE5E5EA).strokeWidth(1)
                    }
                })
            }
            .width(100.percent)
            .backgroundColor(0xFFFFFF)
            .borderRadius(14)
            .margin(left: 8, right: 8, bottom: 8)
        }
        .width(100.percent)
        .height(100.percent)
        .justifyContent(FlexAlign.End)
        .position(x: 0, y: 0)
    }
}

// ==================== Send * 家族 sheet 构成策略 ====================

/**
 * 对应源侧 `debugControllerEntries` 7 个 `Send *` 条目的 sheet 按钮集合差异
 * （`DebugController.swift` 逐处 `ActionSheetButtonItem` 装配；§3 D4.4 双侧代码对照已核实）：
 * 除 `Send All Logs` 与 `Send Storage Stats` 外，其余 5 行均含 `Via Email`。
 */
public func debugSendLogsRowHasViaEmail(actionId: String): Bool {
    if (actionId == "sendAllLogs" || actionId == "sendStorageStats") {
        return false
    }
    return true
}

/** 标题文案（源侧硬编码英文字面量，不走本地化） */
public func debugSendLogsRowTitle(actionId: String): String {
    match (actionId) {
        case "sendLogs" => "Send Logs (Up to 40 MB)"
        case "sendShareLogs" => "Send Share Logs (Up to 40 MB)"
        case "sendGroupCallLogs" => "Send Group Call Logs (Up to 40 MB)"
        case "sendNotificationLogs" => "Send Notification Logs (Up to 40 MB)"
        case "sendCriticalLogs" => "Send Critical Logs"
        case "sendAllLogs" => "Send All Logs"
        case "sendStorageStats" => "Send Storage Stats"
        case _ => ""
    }
}
