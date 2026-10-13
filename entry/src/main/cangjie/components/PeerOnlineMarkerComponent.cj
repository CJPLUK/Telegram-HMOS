package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.services.getPeerOnlineMarkerService
import ohos_app_cangjie_entry.utils.safeAnimateTo

/**
 * 在线标记组件 (Phase PONMN)
 *
 * 对应 Telegram-iOS PeerOnlineMarkerNode
 * 在头像右下角渲染绿色在线状态圆点（带白色描边）
 * 在线/隐藏态通过 scale + opacity 动画切换
 *
 * 用法：
 *   PeerOnlineMarkerComponent(peerId: userId, size: 14)
 *
 * 布局建议：使用 Stack 将本组件叠加在头像右下角
 *   Stack(alignContent: Alignment.BottomEnd) {
 *       avatarView()
 *       PeerOnlineMarkerComponent(peerId: userId, size: 14)
 *   }
 */
@Component
public class PeerOnlineMarkerComponent {
    /** Telegram 用户 ID，用于向 PeerOnlineMarkerService 查询在线状态 */
    public var peerId: Int64 = 0

    /**
     * 绿点直径（含描边），默认 14 dp
     * iOS 原版：在线小图标 14x14，voiceChat 图标 22x22
     */
    public var size: Int64 = 14

    /**
     * 背景描边颜色（通常与头像容器背景色一致，制造"缺口"视觉）
     * 默认白色 0xFFFFFF
     */
    public var borderColor: Int64 = 0xFFFFFF

    /** 动画时长（毫秒） */
    public var animDuration: Int32 = 200

    @State var isVisible: Bool = false
    @State var dotScale: Float32 = 0.0
    @State var dotOpacity: Float32 = 0.0

    public override func aboutToAppear(): Unit {
        let online = getPeerOnlineMarkerService().isOnline(this.peerId)
        if (online) {
            this.isVisible = true
            this.dotScale = 1.0
            this.dotOpacity = 1.0
        }
        Hilog.info(0, "CjTelegram", "[PeerOnlineMarkerComponent] aboutToAppear", [])
    }

    /**
     * 更新在线状态，带 scale+opacity 动画
     * 可由外层 ViewModel 在收到 updateUserStatus 时调用触发状态刷新
     */
    public func updateOnlineStatus(online: Bool): Unit {
        if (online) {
            this.isVisible = true
            safeAnimateTo({ => getUIContext() }, 
                AnimateParam(duration: Int32(this.animDuration), curve: Curve.EaseOut),
                { =>
                    this.dotScale = 1.0
                    this.dotOpacity = 1.0
                }
            )
        } else {
            safeAnimateTo({ => getUIContext() }, 
                AnimateParam(duration: Int32(this.animDuration), curve: Curve.EaseIn),
                { =>
                    this.dotScale = 0.001
                    this.dotOpacity = 0.0
                }
            )
        }
        Hilog.info(0, "CjTelegram", "[PeerOnlineMarkerComponent] updateOnlineStatus", [])
    }

    private func getGreenDotSize(): Int64 {
        return this.size - 4
    }

    private func getBorderWidth(): Int64 {
        return 2
    }

    public func build() {
        if (this.isVisible) {
            this.buildDot()
        }
    }

    @Builder
    private func buildDot() {
        Stack(alignContent: Alignment.Center) {
            Column {}
                .width(this.size)
                .height(this.size)
                .borderRadius(this.size / 2)
                .backgroundColor(this.borderColor)
            Column {}
                .width(this.getGreenDotSize())
                .height(this.getGreenDotSize())
                .borderRadius(this.getGreenDotSize() / 2)
                .backgroundColor(0x4CD964)
        }
        .width(this.size)
        .height(this.size)
        .scale(x: this.dotScale, y: this.dotScale)
        .opacity(Float64(this.dotOpacity))
    }
}
