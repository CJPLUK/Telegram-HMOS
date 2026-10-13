/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 */
package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*

/**
 * NavBarButtons — Telegram 导航栏右上常用按钮原子 (Phase P2-417)
 *
 * 对应 Telegram-iOS submodules：
 *   - MoreButtonNode：导航栏右上「···」更多按钮（三点，点开上下文菜单）。
 *   - ProgressNavigationButtonNode：导航栏文字/图标按钮（如 "Done"/"Edit"），
 *     可切换 loading 转圈态（转圈替代文字 + 禁点）。
 *
 * 工程现状各页自拼导航栏按钮，本单元抽出两个可复用 @Component 原子。
 *
 * 视觉对齐工程现有导航栏按钮（pages/UsernameSettingsPage "Cancel"/"Done"、
 * pages/ChatListPage "Edit"）：
 *   - 文字按钮 fontSize 17，iOS 蓝 0x007AFF（部分页用 0x317AFF，二者一致系
 *     iOS 系统蓝），本封装默认 0x007AFF，可由 color 覆盖。
 *   - loading 转圈用 LoadingProgress（参考 SolidRoundedButton 的 Stack 叠加范式）。
 *
 * 实现说明（坑规避，沿用 SolidRoundedButton 约定）：
 *   - @Component 基本类型参数用普通 var + 默认值（参考 SolidRoundedButton /
 *     QrCodeView 约定），不用 @Prop（@Prop 不支持 primitive）。
 *   - custom @Component 实例化后不能直接链 .margin()/.width() 等内置属性；
 *     调用方若需外边距请外包 Column/Row。
 *   - loading / disabled 时 onClick 不触发：用 isInteractive() / handleClick()
 *     双保险守卫（同 SolidRoundedButton）。
 */

// 导航栏文字按钮默认色：iOS 系统蓝（与 UsernameSettingsPage "Cancel"/"Done" 一致）。
let NAVBAR_BUTTON_BLUE: UInt32 = 0x007AFF

/**
 * MoreButton — 导航栏右上「···」更多按钮。
 *
 * 渲染：三个点（"⋯" U+22EF 横向省略号），可点击弹出上下文菜单 / 触发回调。
 * 用 Text 渲染省略号字符（无需额外图标资源），fontWeight Bold 让三点更醒目，
 * 居中放进一个固定 size 的可点击 Column。
 *
 * 参数：
 *   onClick: 点击回调
 *   color:   点的颜色（默认 iOS 蓝 0x007AFF）
 *   size:    可点击区域边长（vp，默认 24）
 */
@Component
public class MoreButton {
    public var onClick: () -> Unit = { => }
    public var color: UInt32 = NAVBAR_BUTTON_BLUE
    public var size: Int64 = 24

    func build() {
        Column() {
            Text("\u{22EF}")
                .fontSize(this.size)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.color)
                .textAlign(TextAlign.Center)
        }
        .width(this.size)
        .height(this.size)
        .justifyContent(FlexAlign.Center)
        .onClick({ _ => this.onClick() })
    }
}

/**
 * ProgressNavButton — 导航栏文字按钮（如 "Done"/"Edit"），支持 loading 转圈态。
 *
 * 渲染：可点击文字；loading 时用 LoadingProgress 转圈替代文字并禁点；
 * disabled 时变灰并禁点。文字层与转圈层用 Stack(Center) 叠加（同 SolidRoundedButton）。
 *
 * 参数：
 *   title:    按钮文案（如 "Done"/"Edit"/"Save"）
 *   onClick:  点击回调（loading / disabled 时不触发）
 *   loading:  是否加载中（默认 false）；true → 显示转圈 + 禁点 + 隐藏文字
 *   enabled:  是否可用（默认 true）；false → 变灰 + 禁点
 *   color:    文字颜色（默认 iOS 蓝 0x007AFF）
 *   disabledColor: 禁用 / loading 态文字灰（默认 0xCCCCCC）
 *   fontSize: 文字字号（默认 17，对齐现有导航栏按钮）
 */
@Component
public class ProgressNavButton {
    public var title: String = ""
    public var onClick: () -> Unit = { => }
    public var loading: Bool = false
    public var enabled: Bool = true
    public var color: UInt32 = NAVBAR_BUTTON_BLUE
    public var disabledColor: UInt32 = 0xCCCCCC
    public var fontSize: Int64 = 17

    // 是否可交互（既未禁用又未加载）
    private func isInteractive(): Bool {
        return this.enabled && !this.loading
    }

    // 当前文字色：可交互用主色，否则灰
    private func effectiveColor(): UInt32 {
        if (this.enabled) {
            return this.color
        }
        return this.disabledColor
    }

    func build() {
        Stack(alignContent: Alignment.Center) {
            this.titleLayer()
            this.loadingOverlay()
        }
        .onClick({ _ => this.handleClick() })
    }

    // 文字层：loading 时用空串让位给转圈（沿用 SolidRoundedButton 的空文案范式），
    // 仍保留文字层占位以维持 Stack 中心对齐。
    @Builder
    private func titleLayer() {
        Text(if (this.loading) { "" } else { this.title })
            .fontSize(this.fontSize)
            .fontColor(this.effectiveColor())
    }

    // loading 叠加层：转圈，叠在文字中央。
    @Builder
    private func loadingOverlay() {
        if (this.loading) {
            LoadingProgress()
                .width(this.fontSize + 3)
                .height(this.fontSize + 3)
                .color(this.color)
        }
    }

    // 双保险：仅可交互时触发回调
    private func handleClick(): Unit {
        if (this.isInteractive()) {
            this.onClick()
        }
    }
}
