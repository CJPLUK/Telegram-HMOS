/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 */
package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*

/**
 * SegmentedControl — 统一可复用分段切换控件 (Phase P2-413)
 *
 * 对应 Telegram-iOS submodules/SegmentedControlNode：
 *   顶部分段切换（等分横向分段 + 圆角背景轨道 + 选中段高亮滑块），点击切换。
 *   常见于「Phone Number / Username」「Members / Admins」等模式切换。
 *
 * 视觉对齐工程现有分段范式（pages/AddContactPage 的 mode-switch Row）：
 *   - 外层圆角轨道：背景灰 0xE9E9EB，borderRadius 9，内 padding 2
 *   - 每段 layoutWeight(1) 等分，height 32，居中
 *   - 选中段：填充 selectedColor（默认主蓝 0x317AFF）+ borderRadius 7 + 白字
 *   - 未选中段：Color.Transparent（D-175：0x00000000 会被 alphaAdapt 写成不透明黑）
 *     + selectedColor 文字
 *
 * 实现说明（坑规避，承接 SearchBar / SolidRoundedButton / CheckNode 经验）：
 *   - selectedIndex 必须是 @Prop（KB cj-macro-prop：父 @State → 子单向同步）。
 *     普通 var 只在构造时吃到初值 0，之后父侧改值不回灌，isSelected(0) 会永久吞掉 All。
 *     @Link 要求数据源是同类型宏状态变量，会打断 StickersSettingsPage / AddContactPage
 *     的 Int64(...) 调用点；@State 不是父→子输入通道。S-141：@Prop 声明处不带初始值。
 *   - 其余基本类型 / 函数参数仍用普通 var + 默认值。
 *   - 段用 ForEach(this.segments, { title, index => ... }) 动态展开
 *     （对齐 ChatListSearchRecentPeersComponent 的 ForEach 用法）。
 *   - custom @Component 实例化后不能直接链内置属性；调用方需外边距请外包 Column/Row。
 *   - build() 根节点是单个 Row 容器。颜色 / 判定抽出为辅助方法（不能在 build 用 let）。
 *   - 顶层名 SegmentedControl 避免与包级已有符号冲突（components 包内无同名）。
 *
 * Props:
 *   segments:      分段标题数组（每段一个 String）
 *   selectedIndex: 当前选中段下标（调用方维护；@Prop 随父侧回灌）
 *   onChange:      切换回调 (Int64) -> Unit，参数为新选中下标
 *   color:         未选中文字色 / 选中段填充色（默认主蓝 0x317AFF）
 *   selectedColor: 选中段填充色（默认主蓝 0x317AFF；与 color 分离以便定制）
 *   trackColor:    轨道背景色（默认 0xE9E9EB）
 */
@Component
public class SegmentedControl {
    public var segments: Array<String> = Array<String>()
    @Prop var selectedIndex: Int64
    public var onChange: (Int64) -> Unit = { _i => }
    public var color: UInt32 = 0x317AFF
    public var selectedColor: UInt32 = 0x317AFF
    public var trackColor: UInt32 = 0xE9E9EB

    // 某段是否被选中
    private func isSelected(index: Int64): Bool {
        return index == this.selectedIndex
    }

    // 某段文字色：选中白字，未选中用 color
    private func segFg(index: Int64): UInt32 {
        if (this.isSelected(index)) {
            return 0xFFFFFF
        }
        return this.color
    }

    public func build() {
        Row {
            ForEach(this.segments, itemGenerator: { title: String, index: Int64 =>
                Row {
                    Text(title)
                        .fontSize(14)
                        .fontColor(this.segFg(index))
                        .fontWeight(FontWeight.Medium)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                }
                .layoutWeight(1)
                .height(32)
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)
                .backgroundColor(if (this.isSelected(index)) { this.selectedColor } else { Color.Transparent })
                .borderRadius(7)
                .onClick({ _evt =>
                    if (!this.isSelected(index)) {
                        this.selectedIndex = index
                        this.onChange(index)
                    }
                })
            })
        }
        .width(100.percent)
        .height(36)
        .padding(left: 2, right: 2, top: 2, bottom: 2)
        .backgroundColor(this.trackColor)
        .borderRadius(9)
        .alignItems(VerticalAlign.Center)
    }
}
