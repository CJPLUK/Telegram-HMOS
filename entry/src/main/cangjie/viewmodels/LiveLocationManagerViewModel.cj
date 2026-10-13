package ohos_app_cangjie_entry.viewmodels

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import std.sync.*
import ohos_app_cangjie_entry.services.*

// 进程级单例：附件面板 / 位置页 / 聊天顶部条共享同一份分享状态（iOS context.liveLocationManager）。
var _liveLocationManagerVM: Option<LiveLocationManagerViewModel> = None

public func getLiveLocationManagerViewModel(): LiveLocationManagerViewModel {
    match (_liveLocationManagerVM) {
        case Some(vm) => return vm
        case None =>
            let vm = LiveLocationManagerViewModel()
            _liveLocationManagerVM = Some(vm)
            return vm
    }
}

/**
 * LiveLocationManagerViewModel — 实时位置管理 ViewModel
 *
 * 对应 iOS LiveLocationManagerImpl 的上层管理状态，为 UI 提供：
 * - 当前是否有活跃实时位置广播（hasActiveBroadcast）
 * - 已发送实时位置的消息 ID（activeMsgId）
 * - 操作结果状态（isLoading / lastError）
 *
 * 调用链：
 *   LiveLocationManagerViewModel
 *     → LiveLocationManagerService.startLiveLocationBroadcast()
 *       → DeviceLocationManagerService.requestLocation() [GPS]
 *       → MTProtoClient.sendRequest(MessagesEditMessage + inputMediaGeoLive)
 *     → LiveLocationManagerService.stopLiveLocationBroadcast() → sendStopSignal
 *     → LiveLocationManagerService.cancelLiveLocation(peerId)
 *
 * 发送实时位置消息的流程（startSharing）：
 *   1. RealMessageService.sendLiveLocation → messages.sendMedia (inputMediaGeoLive) → 获取 messageId
 *   2. startBroadcast(peerType, peerId, messageId, period)
 *      → LiveLocationManagerService 后台周期上报坐标
 */
@Observed
public class LiveLocationManagerViewModel {

    @Publish public var hasActiveBroadcast: Bool = false
    @Publish public var activeMsgId: Int32 = 0
    @Publish public var isLoading: Bool = false
    @Publish public var lastError: String = ""

    // 当前活跃会话的 peer 信息（供 stop/cancel 使用）
    private var _activePeerType: String = ""
    private var _activePeerId: Int64 = 0

    private var _service: LiveLocationManagerService = getLiveLocationManagerService()
    private var _msgService: RealMessageService = getRealMessageService()
    private var _locationService: DeviceLocationManagerService = getDeviceLocationManagerService()

    // ==================== 公开 API ====================

    /**
     * 开始实时位置分享
     *
     * 流程：
     * 1. 通过 RealMessageService.sendLiveLocation 发送 messages.sendMedia(inputMediaGeoLive)
     * 2. 拿到服务端分配的 messageId
     * 3. 调用 LiveLocationManagerService.startLiveLocationBroadcast 开始周期上报
     *
     * @param peerType  对话类型 (user/chat/channel)
     * @param peerId    对话 ID
     * @param period    分享持续秒数（900=15min / 3600=1h / 28800=8h）
     */
    public func startSharing(peerType: String, peerId: Int64, period!: Int32 = 900): Unit {
        if (this.hasActiveBroadcast) {
            Hilog.info(0, "CjTelegram", "[LiveLocationVM] startSharing: already broadcasting for peerId=${peerId}")
            return
        }
        this.isLoading = true
        this.lastError = ""
        let _ = spawn {
            // Step 1: 获取当前坐标
            let locResult = this._locationService.requestLocation(LocationAccuracyLevel.High)
            if (!locResult.success) {
                launch {
                    this.lastError = "无法获取当前位置"
                    this.isLoading = false
                }
                Hilog.info(0, "CjTelegram", "[LiveLocationVM] startSharing: location unavailable")
                return
            }
            // Step 2: 发送实时位置消息 messages.sendMedia
            let sendResult = this._msgService.sendLiveLocation(
                peerType, peerId,
                locResult.latitude, locResult.longitude,
                period: period
            )
            if (!sendResult.success) {
                launch {
                    this.lastError = "发送实时位置失败"
                    this.isLoading = false
                }
                Hilog.info(0, "CjTelegram", "[LiveLocationVM] startSharing: sendLiveLocation failed")
                return
            }
            let msgId = sendResult.messageId
            Hilog.info(0, "CjTelegram", "[LiveLocationVM] startSharing: msgId=${msgId}, period=${period}s")
            // Step 3: 注册周期广播
            this._service.startLiveLocationBroadcast(peerType, peerId, msgId, period)
            launch {
                this.hasActiveBroadcast = true
                this.activeMsgId = msgId
                this._activePeerType = peerType
                this._activePeerId = peerId
                this.isLoading = false
                this.lastError = ""
            }
        }
    }

    /**
     * 停止当前活跃的实时位置广播（发送 stopped=true 到服务器）
     *
     * 对应 iOS stopMessageIds → engine.messages.requestEditLiveLocation(stop=true)
     */
    public func stopSharing(): Unit {
        if (!this.hasActiveBroadcast) { return }
        let msgId = this.activeMsgId
        Hilog.info(0, "CjTelegram", "[LiveLocationVM] stopSharing: msgId=${msgId}")
        this._service.stopLiveLocationBroadcast(msgId)
        this.hasActiveBroadcast = false
        this.activeMsgId = 0
        this._activePeerType = ""
        this._activePeerId = 0
    }

    /**
     * 取消某个 peer 的所有实时位置广播
     *
     * 对应 iOS cancelLiveLocation(peerId:)
     *
     * @param peerId 对话 ID
     */
    public func cancelLiveLocation(peerId: Int64): Unit {
        Hilog.info(0, "CjTelegram", "[LiveLocationVM] cancelLiveLocation: peerId=${peerId}")
        this._service.cancelLiveLocation(peerId)
        if (this._activePeerId == peerId) {
            this.hasActiveBroadcast = false
            this.activeMsgId = 0
            this._activePeerType = ""
            this._activePeerId = 0
        }
    }

    /**
     * 查询是否对某个 peer 有活跃广播
     *
     * @return Some(messageId) 若有，否则 None
     */
    public func getActiveMsgId(peerId: Int64): Option<Int32> {
        return this._service.getActiveMessageId(peerId)
    }

    /**
     * 页面出现时刷新状态
     */
    public func onAppear(): Unit {
        this.hasActiveBroadcast = this._service.hasActiveBroadcasts()
        Hilog.info(0, "CjTelegram", "[LiveLocationVM] onAppear: hasActive=${this.hasActiveBroadcast}")
    }
}
