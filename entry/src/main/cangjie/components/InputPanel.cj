package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*

/**
 * 输入面板组件（静态展示）
 * 对应 iOS ChatTextInputPanel
 * 
 * iOS 文件参考:
 * - submodules/TelegramUI/Sources/ChatTextInputPanelNode.swift
 * 
 * 功能:
 * - 静态展示输入框
 * - 显示发送按钮
 * - Phase 2 将实现真实输入功能
 */
@Component
public class InputPanel {
    public func build() {
        Row {
            // 输入框区域
            Text("输入消息...")
                .fontSize(16)
                .fontColor(0x999999)
                .padding(left: 16, top: 10, bottom: 10)
                .layoutWeight(1)
                .backgroundColor(0xF0F0F0)
                .borderRadius(20)
            
            // 发送按钮
            Text("📤")
                .fontSize(24)
                .padding(8)
                .margin(left: 8)
        }
        .width(100.percent)
        .padding(12)
        .backgroundColor(0xFFFFFF)
        .border(width: 1, color: 0xE0E0E0, style: BorderStyle.Solid)
    }
}
