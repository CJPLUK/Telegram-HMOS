package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*

/**
 * 来电覆盖层辅助函数 (Phase K8)
 * 
 * 对应 iOS CallKit 来电界面
 * 因跨包 @Component 宏问题，提供辅助函数供 MainTabPage/ChatRoomPage 内联使用
 * 
 * 来电 UI 包含：
 * - 来电者姓名 + 头像
 * - "Telegram Audio/Video Call" 提示
 * - 拒绝（红色）+ 接听（绿色）按钮
 * - 滑动接听提示
 */

/**
 * 获取来电类型显示文字
 */
public func getIncomingCallTypeText(isVideo: Bool): String {
    if (isVideo) {
        return "Telegram Video Call"
    }
    return "Telegram Audio Call"
}

/**
 * 获取接听按钮颜色
 */
public func getAcceptButtonColor(): Int64 {
    return 0x34C759  // 绿色
}

/**
 * 获取拒绝按钮颜色
 */
public func getDeclineButtonColor(): Int64 {
    return 0xFF3B30  // 红色
}

/**
 * 获取来电图标
 */
public func getIncomingCallIcon(isVideo: Bool): String {
    if (isVideo) { return "📹" }
    return "📞"
}

/**
 * 获取来电者首字母用于头像
 */
public func getCallerInitial(name: String): String {
    if (name.size > 0) {
        return name.toRuneArray()[0].toString()
    }
    return "?"
}
