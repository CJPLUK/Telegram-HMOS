/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 */
package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*

/**
 * SolidRoundedButton — 统一实心圆角主操作按钮 (Phase P2-416)
 *
 * 对应 Telegram-iOS submodules/SolidRoundedButtonNode：
 *   全宽实心圆角主按钮（登录 / 继续 / 确认 / 发送），支持标题、可选副标题、
 *   loading 转圈态（禁点）、disabled 变灰态（禁点）、可定制背景/文字色/圆角/高度。
 *
 * 视觉对齐工程现有主按钮（auth/SplashPage "Start Messaging"、
 * auth/PhoneInputPage "Next"）：
 *   - 全宽（width 100%）
 *   - height 48
 *   - borderRadius 24
 *   - 主蓝 0x317AFF；disabled 灰 0xCCCCCC
 *   - 文字白 0xFFFFFF，fontSize 16
 *   - loading 转圈用 LoadingProgress（参考 PhoneInputPage 的 LoadingProgress 0x317AFF）
 *
 * 实现说明（坑规避）：
 *   - 基础层是 ArkUI 原生 Button（自带按下高亮/水波纹）；loading 态用 Stack
 *     在按钮上方叠加 LoadingProgress（参考 RadialStatusComponent 的
 *     Stack(alignContent: Alignment.Center) 范式）。
 *   - enabled/loading 用 @Prop（父子单向同步，父组件重新渲染时子组件的 @Prop 会
 *     被父组件的数据源重置——参见 CangjieUI "@Prop宏：父子单向同步" 文档，@Prop
 *     支持简单类型包括 Bool）。此前用普通 var + 默认值：普通 var 只在组件首次构造
 *     时被赋值一次，父组件重新渲染并不会刷新已存在子组件实例的普通 var 字段，
 *     导致父组件算出的最新 enabled 值永远传不到已渲染的按钮（P2-defect：Next 按钮
 *     手机号校验通过后仍卡在禁用态）。@Prop 无默认值、禁止本地初始化，调用方必须
 *     显式传入 enabled/loading（不能省略，省略会编译失败）。
 *   - custom @Component 实例化后不能直接链 .margin()/.width() 等内置属性，
 *     调用方若需外边距请外包 Column/Row。
 *
 * Props:
 *   title:           主标题文字
 *   onClick:         点击回调（loading / disabled 时不触发）
 *   subtitle:        可选副标题（空串=不显示）
 *   enabled:         是否可用（@Prop，无默认值，调用方必须显式传入）；false → 变灰 + 禁点
 *   loading:         是否加载中（@Prop，无默认值，调用方必须显式传入）；true → 显示转圈 + 禁点 + 隐藏文字
 *   backgroundColor: 主背景色（默认主蓝 0x317AFF）
 *   disabledColor:   禁用 / loading 态背景灰（默认 0xCCCCCC）
 *   textColor:       文字颜色（默认白 0xFFFFFF）
 *   cornerRadius:    圆角（默认 24，对齐现有）
 *   height:          高度（默认 48，对齐现有）
 *   fullWidth:       是否全宽（默认 true）；false → 自适应内容宽度
 */
@Component
public class SolidRoundedButton {
    public var title: String = ""
    public var onClick: () -> Unit = { => }
    public var subtitle: String = ""
    // @Prop：父组件重渲染时随父侧最新值单向同步覆盖（详见上方类注释）。
    // 无默认值、调用方必须显式传入（编译期强制）。
    @Prop var enabled: Bool
    @Prop var loading: Bool
    public var backgroundColor: UInt32 = 0x317AFF
    public var disabledColor: UInt32 = 0xCCCCCC
    public var textColor: UInt32 = 0xFFFFFF
    public var cornerRadius: Int64 = 24
    public var height: Int64 = 48
    public var fullWidth: Bool = true

    // 是否可交互（既未禁用又未加载）
    private func isInteractive(): Bool {
        return this.enabled && !this.loading
    }

    // 当前背景色：可交互用主色，否则用灰色
    private func effectiveBg(): UInt32 {
        if (this.isInteractive()) {
            return this.backgroundColor
        }
        return this.disabledColor
    }

    func build() {
        if (this.fullWidth) {
            Stack(alignContent: Alignment.Center) {
                this.buttonLayer(true)
                this.loadingOverlay()
            }
            .width(100.percent)
            .height(this.height)
        } else {
            // 非全宽：宽度跟随内容（不在 Stack/Button 上强制 100%）
            Stack(alignContent: Alignment.Center) {
                this.buttonLayer(false)
                this.loadingOverlay()
            }
            .height(this.height)
        }
    }

    // 基础层：原生 Button（自带按下高亮）。loading 时文字让位给转圈，
    // 用空标题保持按钮形状与背景。
    @Builder
    private func buttonLayer(wide: Bool) {
        if (wide) {
            Button(if (this.loading) { "" } else { this.titleLine() })
                .width(100.percent)
                .height(this.height)
                .borderRadius(this.cornerRadius)
                .backgroundColor(this.effectiveBg())
                .fontColor(this.textColor)
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .enabled(this.isInteractive())
                .onClick({ _ => this.handleClick() })
        } else {
            Button(if (this.loading) { "" } else { this.titleLine() })
                .height(this.height)
                .borderRadius(this.cornerRadius)
                .backgroundColor(this.effectiveBg())
                .fontColor(this.textColor)
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .enabled(this.isInteractive())
                .onClick({ _ => this.handleClick() })
        }
    }

    // loading 叠加层：转圈，叠在按钮中央
    @Builder
    private func loadingOverlay() {
        if (this.loading) {
            LoadingProgress()
                .width(this.height / 2)
                .height(this.height / 2)
                .color(this.textColor)
        }
    }

    // 双保险：仅可交互时触发回调
    private func handleClick(): Unit {
        if (this.isInteractive()) {
            this.onClick()
        }
    }

    // 主标题 + 可选副标题合成单行 Button 文案（Button 文本参数为 String，
    // 副标题以换行附加；无副标题时仅标题）。
    private func titleLine(): String {
        if (this.subtitle.size > 0) {
            return this.title + "\n" + this.subtitle
        }
        return this.title
    }
}
