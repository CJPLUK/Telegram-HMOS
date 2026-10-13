package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import ohos.resource.AppResource

/**
 * 通话控制按钮组件 (Phase K6)
 *
 * 对应 iOS CallControllerButtonsNode
 * 提供通话中的控制按钮：静音、扬声器、视频、挂断等
 *
 * 注意：因跨包 @Component 宏问题，这些作为独立辅助函数供内联使用
 *
 * 资源保真修复：iOS CallControllerButton.swift 对 mute/speaker/video 三种控件
 * 在 on/off 两态使用的是**同一张 PDF 图标**（Call/CallMuteButton、Call/CallSpeakerButton、
 * Call/CallCameraButton），仅通过按钮底色（`.blurred(isFilled)` 白底 vs 半透明）区分状态，
 * 不切换图标形状。此处对齐同一模式：getCallControlIconRes 返回单一 @r() 资源，
 * 调用方（CallScreen/VideoCallScreen）继续用既有 getCallControlBgColor() 做状态区分。
 */

/**
 * 获取控制按钮的矢量图标资源名（app.media.callui_ic_*）
 *
 * iOS 源: Call/CallMuteButton (ic_call_microphone.pdf) / Call/CallSpeakerButton
 * (ic_call_speaker.pdf) / Call/CallCameraButton (videocall.pdf) /
 * Call/CallSwitchCameraButton (ic_flip (1).pdf) / Call/CallDeclineButton (ic_calls_decline.pdf)
 */
public func getCallControlIconRes(controlType: String): AppResource {
    if (controlType == "mute") {
        return @r(app.media.callui_ic_mute)
    }
    if (controlType == "speaker") {
        return @r(app.media.callui_ic_speaker)
    }
    if (controlType == "video") {
        return @r(app.media.callui_ic_video)
    }
    if (controlType == "flip") {
        return @r(app.media.callui_ic_flip)
    }
    return @r(app.media.callui_ic_end)
}

/**
 * 获取控制按钮标签
 */
public func getCallControlLabel(controlType: String): String {
    if (controlType == "mute") { return "Mute" }
    if (controlType == "speaker") { return "Speaker" }
    if (controlType == "video") { return "Video" }
    if (controlType == "flip") { return "Flip" }
    if (controlType == "end") { return "End" }
    return ""
}

/**
 * 获取控制按钮背景色
 */
public func getCallControlBgColor(controlType: String, isActive: Bool): Int64 {
    if (controlType == "end") {
        return 0xFF3B30  // 红色挂断按钮
    }
    if (isActive) {
        return 0xFFFFFF  // 激活状态白色
    }
    return 0x40FFFFFF  // 半透明白色
}

/**
 * 获取控制按钮文字色
 */
public func getCallControlTextColor(controlType: String, isActive: Bool): Int64 {
    if (controlType == "end") {
        return 0xFFFFFF  // 白色
    }
    if (isActive) {
        return 0x317AFF  // 蓝色
    }
    return 0xFFFFFF  // 白色
}

// ============================================================================
// V2 通话 UI 辅助（对齐 iOS PrivateCallScreen，2023-12 重设计）
//
// iOS 规格源（精确值，勿凭感觉改）：
// - ButtonGroupView.swift: buttonSize=56, buttonSpacing=36,
//   buttonY = H - insets.bottom - 52 - 56；notice 与按钮间距 16
// - ContentOverlayButton.swift: 图标绘制尺寸 = 自然尺寸(72pt canvas)*0.8；
//   label fontSize 13 白色，位于按钮下方 +4；
//   destructive(end) 填充 0xFF3B30；selected → 白底+图标镂空（此处近似为
//   白底+深色图标，因 ArkUI 无逐像素 blend 镂空）；未选中 → 玻璃态半透明白
// - CallBackgroundLayer.swift: 三组 4 色渐变
//   state0(blue-violet, requesting/ringing/connecting/reconnecting/terminated):
//     0x568FD6, 0x626ED5, 0xA667D5, 0x7664DA
//   state1(green, active 信号好): 0xACBD65, 0x459F8D, 0x53A4D1, 0x3E917A
//   state2(orange, active 信号差 quality<=0.2): 0xC0508D, 0xF09536, 0xCE5081, 0xFC7C4C
// - 资产: CallScreenAssets.xcassets/Call/{Mute,Speaker,Video,Flip}.imageset (PDF 72x72)
//   + End.imageset/CallCancelIcon@3x.png（白色 ✕，21pt 自然尺寸）
//   → 提取为 callui_v2_mute/speaker/video/flip.svg + callui_v2_end.png
// ============================================================================

/**
 * V2 图标资源（callui_v2_*，均自 iOS 官方资产逐一转换）
 */
public func getCallV2IconRes(controlType: String): AppResource {
    if (controlType == "mute") {
        return @r(app.media.callui_v2_mute)
    }
    if (controlType == "speaker") {
        return @r(app.media.callui_v2_speaker)
    }
    if (controlType == "video") {
        return @r(app.media.callui_v2_video)
    }
    if (controlType == "flip") {
        return @r(app.media.callui_v2_flip)
    }
    if (controlType == "accept") {
        return @r(app.media.callui_v2_accept)
    }
    if (controlType == "decline") {
        return @r(app.media.callui_v2_decline)
    }
    if (controlType == "back") {
        return @r(app.media.callui_v2_back)
    }
    return @r(app.media.callui_v2_end)
}

/**
 * V2 按钮标签（iOS 官方英文串小写风格：speaker/video/mute/end call/flip）
 */
public func getCallV2Label(controlType: String): String {
    if (controlType == "mute") { return "mute" }
    if (controlType == "speaker") { return "speaker" }
    if (controlType == "video") { return "video" }
    if (controlType == "flip") { return "flip" }
    if (controlType == "end") { return "end call" }
    return ""
}

/**
 * V2 背景渐变 4 色（CallBackgroundLayer.swift colorSets 精确值）
 * stateIndex: 0=blue-violet 1=green 2=weak-signal orange; slot 0-3
 */
public func getCallV2BgColor(stateIndex: Int32, slot: Int32): UInt32 {
    if (stateIndex == 1) {
        if (slot == 0) { return 0xFFACBD65 }
        if (slot == 1) { return 0xFF459F8D }
        if (slot == 2) { return 0xFF53A4D1 }
        return 0xFF3E917A
    }
    if (stateIndex == 2) {
        if (slot == 0) { return 0xFFC0508D }
        if (slot == 1) { return 0xFFF09536 }
        if (slot == 2) { return 0xFFCE5081 }
        return 0xFFFC7C4C
    }
    if (slot == 0) { return 0xFF568FD6 }
    if (slot == 1) { return 0xFF626ED5 }
    if (slot == 2) { return 0xFFA667D5 }
    return 0xFF7664DA
}

/**
 * V2 按钮圈底色: end→0xFF3B30 红; selected→白; 未选→玻璃态半透明白
 * (iOS ContentOverlayButton: blur 玻璃态无法逐像素复刻，近似 20% 白)
 */
public func getCallV2CircleBg(controlType: String, isActive: Bool): Int64 {
    if (controlType == "end") { return 0xFF3B30 }
    if (isActive) { return 0xFFFFFF }
    return 0x33FFFFFF
}

/**
 * V2 按钮图标色: selected 白底时用深色（近似 iOS 镂空透底效果），其余白色
 */
public func getCallV2IconColor(controlType: String, isActive: Bool): Int64 {
    if (controlType != "end" && isActive) { return 0x2E3436 }
    return 0xFFFFFF
}

/**
 * Telegram 头像渐变色对（上浅下深），index 0-6，对齐 iOS AvatarNode 官方色板
 */
public func getAvatarGradTop(index: Int64): UInt32 {
    let idx = ((index % 7) + 7) % 7
    if (idx == 0) { return 0xFFFF885E }
    if (idx == 1) { return 0xFFFFCD6A }
    if (idx == 2) { return 0xFF82B1FF }
    if (idx == 3) { return 0xFFA0DE7E }
    if (idx == 4) { return 0xFF53EDD6 }
    if (idx == 5) { return 0xFF72D5FD }
    return 0xFFE0A2F3
}

public func getAvatarGradBottom(index: Int64): UInt32 {
    let idx = ((index % 7) + 7) % 7
    if (idx == 0) { return 0xFFFF516A }
    if (idx == 1) { return 0xFFFFA85C }
    if (idx == 2) { return 0xFF665FFF }
    if (idx == 3) { return 0xFF54CB68 }
    if (idx == 4) { return 0xFF28C9B7 }
    if (idx == 5) { return 0xFF2A9EF1 }
    return 0xFFD669ED
}

/**
 * 姓名 → 头像色板 index（首字符码 % 7，与既有 buildAvatarBgColor 同源规则）
 */
public func getAvatarColorIdxByName(name: String): Int64 {
    if (name.size == 0) { return 5 }
    let code = UInt32(name.toRuneArray()[0])
    return Int64(code) % 7
}
