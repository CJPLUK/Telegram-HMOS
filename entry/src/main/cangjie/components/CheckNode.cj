/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 */
package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*

/**
 * CheckNode — 统一可复用勾选标记原子组件 (Phase P2-412)
 *
 * 对应 Telegram-iOS submodules/CheckNode：
 *   选择态勾选标记（圆形 / 方形边框 + 选中态填充主题蓝 + 白色对勾 ✓），
 *   点击可切换。常见于多选列表 / 设置开关 / 单选项前导勾。
 *
 * 视觉对齐工程现有勾选范式（GridMessageSelectionComponent 的
 * Stack(Circle + Text "✓")）：
 *   - 未选中：透明填充 + 灰描边圆/方框
 *   - 选中：填充主题蓝 0x317AFF + 白色对勾 ✓（\u{2713}）
 *   - 默认 size 24，shape "circle"（也支持 "square"）
 *
 * 实现说明（坑规避，承接 SearchBar / SolidRoundedButton 经验）：
 *   - @Component 基本类型 / 函数参数用普通 var + 默认值（不用 @Prop，@Prop 不支持 primitive）。
 *   - custom @Component 实例化后不能直接链内置属性（.margin/.width 等）；
 *     调用方若需外边距请外包 Column/Row。
 *   - build() 根节点是单个 Stack 容器（对齐工程范式）。
 *   - 形状用运行时分支：circle → Circle()，square → 圆角矩形（borderRadius(4) 的 Column）。
 *     不能在 build 内用 let，颜色 / 判定抽出为辅助方法。
 *   - 对勾字形用 "\u{2713}"（✓）转义，确保可编译。
 *   - 顶层名 CheckNode 避免与包级已有符号冲突（components 包内无同名）。
 *
 * Props:
 *   checked:     是否选中（调用方维护）
 *   onToggle:    点击切换回调 () -> Unit
 *   size:        边长（默认 24）
 *   shape:       "circle"（默认）/ "square"
 *   checkColor:  对勾颜色（默认白 0xFFFFFF）
 *   borderColor: 未选中描边色（默认灰 0xC7C7CC）
 *   fillColor:   选中填充色（默认主蓝 0x317AFF）
 */
@Component
public class CheckNode {
    public var checked: Bool = false
    public var onToggle: () -> Unit = { => }
    public var size: Int64 = 24
    public var shape: String = "circle"
    public var checkColor: UInt32 = 0xFFFFFF
    public var borderColor: UInt32 = 0xC7C7CC
    public var fillColor: UInt32 = 0x317AFF

    // 是否方形（否则圆形）
    private func isSquare(): Bool {
        return this.shape == "square"
    }

    // 当前填充色：选中用 fillColor，未选中透明
    private func effectiveFill(): UInt32 {
        if (this.checked) {
            return this.fillColor
        }
        return 0x00FFFFFF
    }

    // 当前描边色：选中时用填充色（看不见的描边），未选中用 borderColor
    private func effectiveStroke(): UInt32 {
        if (this.checked) {
            return this.fillColor
        }
        return this.borderColor
    }

    // 对勾字号：约为 size 的 0.6
    private func checkFontSize(): Int64 {
        return this.size * 6 / 10
    }

    // 方形圆角：约 size 的 1/6
    private func squareRadius(): Int64 {
        return this.size / 6
    }

    public func build() {
        Stack(alignContent: Alignment.Center) {
            // 边框 / 填充层：圆形 or 方形
            if (this.isSquare()) {
                Column {}
                    .width(this.size)
                    .height(this.size)
                    .backgroundColor(this.effectiveFill())
                    .borderRadius(this.squareRadius())
                    .border(
                        width: 1.5,
                        color: this.effectiveStroke(),
                        style: BorderStyle.Solid
                    )
            } else {
                Circle()
                    .width(this.size)
                    .height(this.size)
                    .fill(this.effectiveFill())
                    .stroke(this.effectiveStroke())
                    .strokeWidth(1.5)
            }

            // 选中时显示白色对勾
            if (this.checked) {
                Text("\u{2713}")
                    .fontSize(this.checkFontSize())
                    .fontColor(this.checkColor)
                    .fontWeight(FontWeight.Bold)
            }
        }
        .width(this.size)
        .height(this.size)
        .onClick({ _evt =>
            this.onToggle()
        })
    }
}
