package ohos_app_cangjie_entry.viewmodels

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    PeerPresenceStatusManagerService,
    getPeerPresenceStatusManagerService,
    formatPresenceText,
    presenceStatusFromFields
}

/**
 * 对方在线状态 ViewModel
 *
 * 对应 iOS PeerPresenceStatusManager：
 * - 维护当前 presenceText / isOnline 状态供 UI 直接绑定
 * - 调用 PeerPresenceStatusManagerService 做文案格式化 + 定时刷新调度
 * - 定时器到期后自动重新计算文案并更新 @Publish 字段
 *
 * 使用方式：
 *   let vm = PeerPresenceStatusManagerViewModel()
 *   vm.updatePresence(peerId: 123, isOnline: false, wasOnline: ts, statusType: "offline")
 *   // UI 绑定 vm.presenceText / vm.isOnline
 *   // 离开页面时调用 vm.cancel()
 */
@Observed
public class PeerPresenceStatusManagerViewModel {

    /** 格式化后的在线状态文案，如 "online" / "last seen 5 minutes ago" */
    @Publish public var presenceText: String = ""

    /** 是否当前在线 */
    @Publish public var isOnline: Bool = false

    // 缓存上次传入的状态，定时刷新时复用
    private var _peerId: Int64 = 0
    private var _wasOnline: Int32 = 0
    private var _statusType: String = "empty"

    private var _service: PeerPresenceStatusManagerService = getPeerPresenceStatusManagerService()

    /**
     * 更新对方在线状态，立即刷新文案并启动定时器
     *
     * @param peerId      对方用户 ID
     * @param isOnline    是否当前在线
     * @param wasOnline   离线 Unix 时间戳（0 = 无）
     * @param statusType  "online"/"offline"/"recently"/"lastWeek"/"lastMonth"/"empty"
     */
    public func updatePresence(
        peerId: Int64,
        isOnline: Bool,
        wasOnline: Int32,
        statusType: String
    ): Unit {
        _peerId = peerId
        _wasOnline = wasOnline
        _statusType = statusType

        // 立即更新文案
        this.presenceText = _service.formatText(isOnline, wasOnline, statusType)
        this.isOnline = isOnline

        Hilog.info(0, "CjTelegram", "[PPSMViewModel] peer=%{public}s updated", [peerId.toString()])

        // 调度定时刷新（到期回调：重新计算文案）
        _service.reset(
            peerId,
            isOnline,
            wasOnline,
            statusType,
            { =>
                let newText = _service.formatText(false, _wasOnline, _statusType)
                Hilog.info(0, "CjTelegram", "[PPSMViewModel] timer refresh", [""])
                launch {
                    this.presenceText = newText
                    this.isOnline = false
                }
                // 继续调度下一次刷新
                _service.reset(_peerId, false, _wasOnline, _statusType, { => this.triggerRefresh() })
            }
        )
    }

    /**
     * 取消定时器，通常在页面 aboutToDisappear 中调用
     */
    public func cancel(): Unit {
        _service.cancel()
    }

    /**
     * 内部：定时器到期后递归触发文案刷新
     */
    private func triggerRefresh(): Unit {
        let newText = _service.formatText(false, _wasOnline, _statusType)
        Hilog.info(0, "CjTelegram", "[PPSMViewModel] recursive refresh", [""])
        launch {
            this.presenceText = newText
            this.isOnline = false
        }
        _service.reset(_peerId, false, _wasOnline, _statusType, { => this.triggerRefresh() })
    }
}
