/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 */
package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import std.sync.*
import std.time.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getHintsService

/**
 * TooltipBubble — 可复用的 Telegram 风格指向性气泡提示（feature 发现 / 引导）。
 *
 * 对应 iOS Telegram-iOS submodules/TooltipUI：
 *   指向某个 UI 元素（锚点）的深色气泡，内含可选 leading 图标 + 文案 + 指向箭头，
 *   通常用于功能引导，自动或受控消失。
 *
 * 实现策略（以 cangjie-kb 实证为准，不臆造 popup API）：
 *   鸿蒙 ArkUI 提供原生气泡能力 —— 通用属性 `bindPopup(show: ?Bool, popup: ?CustomPopupOptions)`。
 *   `CustomPopupOptions` 关键字段（来自 cj-common-types「基础类型定义」）：
 *     builder!:        () -> Unit                       —— 气泡内容（@Builder 函数）
 *     placement!:      ?Placement                       —— 弹出位置 / 箭头朝向（Top/Bottom/Left/Right/...）
 *     popupColor!:     ?Color                            —— 气泡背景色
 *     enableArrow!:    ?Bool                             —— 是否显示指向箭头
 *     autoCancel!:     ?Bool                             —— 点击气泡外区域是否自动关闭
 *     onStateChange!:  Option<(PopupStateChangeParam) -> Unit> —— 显隐回调（evt.isVisible）
 *     radius! / width! / arrowWidth! / arrowHeight! / offset! / mask! / targetSpace! ...
 *   `Color(value: UInt32)`（ARGB，alpha 在最高 8 位）。本封装用 0xF0202020（深色半透明）做 Telegram 风深底。
 *
 * 本单元提供两件可复用资产：
 *   1) @Component TooltipBubble —— Telegram 风格气泡「内容」组件（深色圆角底 + 可选 leading 图标 + 白字）。
 *      作为气泡内容渲染，由调用方包进自己的 @Builder 里交给 bindPopup 的 builder。
 *   2) tooltipPopupOptions(...) —— 辅助函数，组装一个 Telegram 风格的 `CustomPopupOptions`，
 *      让任意组件直接 `.bindPopup(this.showTip, tooltipOptions)` 弹出指向性气泡。
 *
 * ──────────────────────── 用法示例 ────────────────────────
 * 在任意 @Component 的某个 UI 元素上挂一个引导 tooltip：
 *
 *   @Component
 *   class SomePage {
 *       @State var showTip: Bool = false
 *
 *       // 气泡内容：复用 TooltipBubble 渲染 Telegram 风深色气泡
 *       @Builder
 *       func tipContent() {
 *           TooltipBubble(text: "点这里发起新聊天", iconRes: @r(app.media.icon))
 *       }
 *
 *       func build() {
 *           Button(trSource("New Chat"))
 *               .onClick({ e => this.showTip = !this.showTip })
 *               .bindPopup(
 *                   this.showTip,
 *                   tooltipPopupOptions(
 *                       builder: bind(this.tipContent, this),
 *                       placement: Placement.Bottom,   // 气泡在按钮下方，箭头朝上指向按钮
 *                       autoCancel: true,
 *                       onStateChange: { evt =>
 *                           if (!evt.isVisible) { this.showTip = false }
 *                       }
 *                   )
 *               )
 *       }
 *   }
 *
 * ──────────────────────── 自动消失 ────────────────────────
 * ArkUI bindPopup 的 CustomPopupOptions 不提供内建的 duration / 定时自动隐藏字段，
 * 因此「N 秒后自动消失」由调用方控制：在显示气泡时启动一个 Timer，到点把驱动 show 的
 * @State（例如上例的 showTip）置 false 即可（参见同目录 UndoToast.cj 的 Timer 计时范式）。
 * `autoCancel: true` 仅表示「点气泡外区域自动关闭」，不是定时关闭。
 * `onStateChange` 用于在气泡被关闭（含 autoCancel）时把 @State 同步回 false，避免状态漂移。
 */

// Telegram 气泡深色底（ARGB：alpha=0xF0 半透明，RGB=0x202020 近黑深灰）。
let TELEGRAM_TOOLTIP_BG: UInt32 = 0xF0202020

/**
 * Telegram 风格气泡内容组件。
 *
 * 渲染：圆角深色底 + 可选 leading 图标 + 白色文案，作为 bindPopup 的气泡内容。
 *
 * @Component 基本类型参数用普通 var（非 @Prop）—— 见同目录 QrCodeView / CodeInputViewComponent 约定。
 * 例外：text 见下方字段声明处的说明（diag-suite_settings_privacy-TC-0133-E8.md F-4）。
 *
 * 参数：
 *   text:        气泡文案（白字）
 *   iconRes:     可选 leading 图标资源；为空字符串表示无图标（纯文案气泡）
 *   maxWidthVp:  气泡最大宽度（vp），默认 240
 */
@Component
public class TooltipBubble {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // text 必须是 @Prop（非普通 var）：唯一真实调用点 pages/SelectivePrivacySettingsPage.cj:870
    // 传的是随档位切换的 @State 派生文案，普通 var 只在首次构造时赋值一次，档位切换后不回灌
    // （dev_pattern.md D-125/D-156）。@Prop 不能带默认值，调用点必须显式传入（编译期强制；
    // 全仓两处调用点已核实全部显式传 text:，零级联：pages/SelectivePrivacySettingsPage.cj:870、
    // 本文件 :266 ComposeButtonTooltip.tipContent()）。
    @Prop var text: String
    public var iconRes: String = ""
    public var maxWidthVp: Int64 = 240

    func build() {
        Row(space: 8.0) {
            if (this.iconRes.size > 0) {
                Image(this.iconRes)
                    .width(20)
                    .height(20)
                    .objectFit(ImageFit.Contain)
            }
            Text(this.text)
                .fontSize(14)
                .fontColor(0xFFFFFFFF)
                .maxLines(3)
                .textOverflow(TextOverflow.Ellipsis)
        }
        .padding(top: 10, bottom: 10, left: 12, right: 12)
        .constraintSize(maxWidth: this.maxWidthVp)
        .backgroundColor(TELEGRAM_TOOLTIP_BG)
        .borderRadius(12)
        .alignItems(VerticalAlign.Center)
    }
}

/**
 * 组装一个 Telegram 风格的 CustomPopupOptions（指向性深色气泡）。
 *
 * 把这个返回值交给任意组件的 `.bindPopup(show, options)` 即可弹出指向锚点的引导气泡。
 * 气泡内容由调用方通过 `builder`（一个 @Builder 函数，通常内部渲染 TooltipBubble）提供，
 * 这样气泡背景 / 圆角等 Telegram 风格统一在此封装，文案与图标随内容灵活定制。
 *
 * 字段语义与默认值（全部以 cangjie-kb 实证的 CustomPopupOptions 字段为准）：
 *   builder:       气泡内容 @Builder 函数（() -> Unit）。类成员 @Builder 用 `bind(this.xxx, this)` 传入。
 *   placement:     气泡相对锚点的位置；箭头朝向由 placement 决定（默认 Bottom：气泡在下、箭头朝上指锚点）。
 *   popupColor:    气泡背景色（默认 Telegram 深色 0xF0202020）。
 *   enableArrow:   是否显示指向箭头（默认 true —— 这是「指向性」气泡的核心）。
 *   autoCancel:    点击气泡外区域是否自动关闭（默认 true）。
 *   radius:        气泡圆角（默认 12vp，和 TooltipBubble 内容圆角一致）。
 *   onStateChange: 显隐回调，建议在 !isVisible 时把驱动 show 的 @State 置 false。
 */
public func tooltipPopupOptions(
    builder!: () -> Unit,
    placement!: Placement = Placement.Bottom,
    popupColor!: Color = Color(TELEGRAM_TOOLTIP_BG),
    enableArrow!: Bool = true,
    autoCancel!: Bool = true,
    radius!: Length = 12.vp,
    onStateChange!: Option<(PopupStateChangeParam) -> Unit> = Option.None
): CustomPopupOptions {
    CustomPopupOptions(
        builder: builder,
        placement: placement,
        popupColor: popupColor,
        enableArrow: enableArrow,
        autoCancel: autoCancel,
        radius: radius,
        onStateChange: onStateChange
    )
}

/**
 * ComposeButtonTooltip — ChatListPage 顶栏 Compose（真实矢量图标）按钮的首次引导指向性气泡。
 *
 * 对应 iOS Telegram-iOS submodules/TooltipUI TooltipScreen：
 *   - 首次进入 ChatListPage 时（HintsService.hasShownComposeTooltip() == false）自动弹出
 *   - 深色指向性气泡，箭头向上指向 Compose 按钮（Placement.Bottom：气泡在按钮下方）
 *   - 5 秒后自动消失（对应 iOS DisplayDuration.default ≈ 5s），参考 UndoToast Timer 范式
 *   - autoCancel: true —— 点击气泡外区域也会消失
 *   - 展示后立即写持久化标志（HintsService.markComposeTooltipShown），下次启动不再弹出
 *
 * 用法：将本组件作为 Compose 按钮的容器（包裹按钮文本），在 ChatListPage 标题栏末尾使用：
 *   ComposeButtonTooltip(onPress: { => this.showComposeMenu = true })
 *
 * 生命周期：
 *   aboutToAppear → checkFirstUse → 若未展示过则 showTip=true + markShown + 启动 5s timer
 *   timer 到点 → launch{ showTip=false } + cancel timer
 *   autoCancel/外部点击 → onStateChange 回调 → launch{ showTip=false }
 *   aboutToDisappear → stopTimer (避免野指针)
 *
 * R-69: Timer 回调内 @State 写必须包 launch{}
 * S-64: aboutToAppear/aboutToDisappear 必须 public override func ... : Unit
 */
@Component
public class ComposeButtonTooltip {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 点击 Compose 按钮时调用（透传到 ChatListPage 的 showComposeMenu = true）
    public var onPress: () -> Unit = { => }

    // 气泡显示状态（驱动 bindPopup）
    @State var showTip: Bool = false

    // 5s 自动消失计时器
    var dismissTimer: Option<Timer> = None<Timer>

    // ==================== 生命周期 ====================

    public override func aboutToAppear(): Unit {
        this.checkFirstUse()
        Hilog.info(0, "CjTelegram", "[ComposeButtonTooltip] aboutToAppear showTip=${this.showTip}")
    }

    public override func aboutToDisappear(): Unit {
        this.stopTimer()
        Hilog.info(0, "CjTelegram", "[ComposeButtonTooltip] aboutToDisappear")
    }

    // ==================== 首次使用检查（F2）====================

    /**
     * 检查是否首次使用 Compose 按钮引导。
     * 若 HintsService 记录未展示过 → 弹气泡并写持久化标志，再启动 5s 自动消失计时器。
     */
    private func checkFirstUse(): Unit {
        let hints = getHintsService()
        if (!hints.hasShownComposeTooltip()) {
            hints.markComposeTooltipShown()
            this.showTip = true
            this.startDismissTimer()
            Hilog.info(0, "CjTelegram", "[ComposeButtonTooltip] first-use: showing tooltip")
        } else {
            Hilog.info(0, "CjTelegram", "[ComposeButtonTooltip] already shown, skip tooltip")
        }
    }

    // ==================== 5s 自动消失计时器（F3）====================

    /**
     * 启动 5s 自动消失计时器。
     * 对应 iOS TooltipUI DisplayDuration.default ≈ 5s。
     * 使用 Timer.repeat 每 100ms tick 一次（同 UndoToast 范式），5000ms 后关闭气泡。
     * R-69: @State 写必须包 launch{}。
     */
    private func startDismissTimer(): Unit {
        if (this.dismissTimer.isSome()) {
            return
        }
        let startMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let durationMs: Int64 = 5000
        this.dismissTimer = Some(Timer.repeat(
            Duration.millisecond * 100,
            Duration.millisecond * 100,
            { =>
                let elapsed = DateTime.now().toUnixTimeStamp().toMilliseconds() - startMs
                if (elapsed >= durationMs) {
                    this.stopTimer()
                    launch { this.showTip = false }
                    Hilog.info(0, "CjTelegram", "[ComposeButtonTooltip] 5s auto-dismiss fired")
                }
            },
            style: CatchupStyle.Skip
        ))
    }

    private func stopTimer(): Unit {
        match (this.dismissTimer) {
            case Some(t) =>
                t.cancel()
                this.dismissTimer = None<Timer>
            case None => ()
        }
    }

    // ==================== 气泡内容 Builder ====================

    /**
     * 气泡内容：复用 TooltipBubble 组件（Telegram 深色圆角风格）。
     * 文案对应 iOS Telegram "Compose" 功能引导提示语义。
     */
    @Builder
    func tipContent() {
        TooltipBubble(text: "Tap to start a new message, group, or channel")
    }

    // ==================== UI ====================

    func build() {
        // 资源保真修复：真实矢量图标（Chat List/ComposeIcon.imageset/ic_create.pdf 转 SVG）替代 emoji 字形
        Image(@r(app.media.clist_ic_compose))
            .width(20)
            .height(20)
            .fillColor(0x000000)
            .onClick({ _e: ClickEvent =>
                let cb = this.onPress
                cb()
            })
            .bindPopup(
                this.showTip,
                tooltipPopupOptions(
                    builder: bind(this.tipContent, this),
                    placement: Placement.Bottom,
                    enableArrow: true,
                    autoCancel: true,
                    onStateChange: Option.Some({ evt: PopupStateChangeParam =>
                        if (!evt.isVisible) {
                            this.stopTimer()
                            launch { this.showTip = false }
                        }
                    })
                )
            )
    }
}
