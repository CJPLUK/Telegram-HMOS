package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.AbilityKit.*
import kit.ArkData.*
import kit.ArkUI.launch
import ohos.business_exception.BusinessException
import ohos_app_cangjie_entry.core.mtproto.{getMTProtoClient, PhoneRequestCall, PhoneAcceptCall, PhoneConfirmCall, PhoneDiscardCall, PhoneReceivedCall, PhoneSendSignalingData, PhoneCallResponse, DhConfigResponse, MessagesGetDhConfig, SHA256, SHA1, BigIntMath, ByteUtils, TLDeserializer, TLObject, UpdatesGetState, decompress, MessagesSearch, InputPeerEmpty, InputPeerUser, InputMessagesFilterPhoneCalls, TLMessage, MessagesHistoryResponse, UserResponse, MessagesDeleteMessages, PhoneSetCallRating}
import ohos_app_cangjie_entry.models.CallSession
import ohos_app_cangjie_entry.models.CallRecord
import ohos_app_cangjie_entry.models.ConnectionEndpoint
import ohos_app_cangjie_entry.models.formatCallDuration
import ohos_app_cangjie_entry.utils.formatRelativeTimestamp
import ohos_app_cangjie_entry.router.routerPush
import ohos_app_cangjie_entry.interop.{callArkAsync, callArkOnJSTask, subscribe, VOIP_REPORT_INCOMING, VOIP_REPORT_STATE, EVT_VOIP_UI_EVENT}
import ohos_app_cangjie_entry.core.voip.{OngoingCallContext, VoipState, voipStateFromInt, TgCallsLib}
import std.collection.ArrayList
import std.collection.HashMap
import std.time.DateTime
import std.sync.{ReentrantMutex, Monitor}
import std.convert.*

/**
 * 通话服务 (Phase K4 — 修复版 v3)
 * 
 * 核心修复 (v3):
 * 1. 修复接收循环：processBuffer 异常不再杀死 startReceiveLoop（根因！）
 * 2. 在 app 启动时注册 updateCallback（不只是发起通话时）
 * 3. 添加 phoneCallRequested 字节扫描（支持接收来电）
 * 4. 添加 phoneCall(active) 字节扫描
 * 5. 简化轮询：getState 保活 + 推送标记检查（移除 getDifference）
 * 6. 添加连接健康检查 ensureConnectionAlive()
 * 7. handleServerUpdate 增加详细日志
 */
private var _callServiceInstance: Option<CallService> = None

// tgcalls V1 引擎门控：false = 只跑信令不拉起媒体引擎（dummy ADM 在真机段错误）。
// 第五步接好 OHAudio 真 ADM 后置 true 恢复真实语音。
let VOIP_MEDIA_ENGINE_ENABLED: Bool = true

public func getCallService(): CallService {
    match (_callServiceInstance) {
        case Some(s) => s
        case None =>
            let s = CallService()
            _callServiceInstance = Some(s)
            // 立即订阅账号级更新协调器，不直接拥有 MTProtoClient callback。
            s.ensureUpdateSubscription()
            s
    }
}

public class CallService {
    private var _currentCall: Option<CallSession> = None
    // Serializes identity-sensitive incoming/accept/reject transitions. UI actions carry the
    // expected callId so a delayed action can never operate on a replacement session.
    private let _callSessionMonitor: Monitor = Monitor()
    private var _callHistory: ArrayList<CallRecord> = ArrayList<CallRecord>()
    private var _timerRunning: Bool = false
    private var _timerEpoch: Int64 = 0
    private var _timerCallId: Int64 = 0
    private var _updateSubscriptionToken: Int64 = -1
    private let _updateSubscriptionMonitor = Monitor()
    
    // Phase T fix: flag to notify CallHistoryPage that a refresh is needed
    private var _callHistoryNeedsRefresh: Bool = false
    
    // 直接回调: 当通话记录列表变化时通知 UI
    private var _callHistoryChangedCallback: Option<(ArrayList<CallRecord>) -> Unit> = None

    // 缓存 DH 配置
    private var _cachedDhG: Int32 = 0
    private var _cachedDhP: Array<Byte> = Array<Byte>(0, repeat: 0)
    private var _cachedDhVersion: Int32 = 0

    // 通过推送收到的 phoneCallAccepted 标记
    private var _pendingAcceptedGB: Array<Byte> = Array<Byte>(0, repeat: 0)
    private var _pendingAcceptedCallId: Int64 = 0
    private var _pendingAcceptedAccessHash: Int64 = 0
    // 被叫在 acceptCall.protocol 里选定的库版本（协商结果，通常单元素）。
    // 主叫必须跑这个版本——此前写死 12.0.0(V3/SCTP)，而 iOS 被叫按我方通告列表
    // 升序选中 10.0.0(ReferenceImpl/无SCTP)，双方信令互不可解 → 44字节 SCTP INIT
    // 无人应答 → 20s Failed。
    private var _pendingAcceptedVersion: String = ""
    private var _pendingAcceptedMaxLayer: Int32 = 0
    private var _gotPhoneCallAccepted: Bool = false
    // help.getConfig 的 call_receive_timeout_ms / call_ring_timeout_ms（0 = 未取到）
    private var _callReceiveTimeoutMs: Int64 = 0
    private var _callRingTimeoutMs: Int64 = 0

    // reconnecting 兜底挂断的代际计数：进 Reconnecting 时 +1 并启动 30s 看门狗，
    // Established/结束时再 +1 使旧看门狗失效。推送死亡时对方挂断只表现为媒体断流
    // → 永久 reconnecting，看门狗按 disconnect 收尾（对齐 iOS 断流超时挂断）。
    private var _reconnectingEpoch: Int64 = 0

    // 通话结束 UI 收尾单发闸：CallScreen/VideoCallScreen 可能同时在栈（且各自轮询），
    // 远端挂断时若都执行 routerPop 会弹穿底层页面。首个申领者执行收尾，其余只停轮询。
    private var _uiDismissClaimed: Bool = false

    // (已移除 getDifference 轮询 — phoneCall 更新不影响 pts，只能通过推送接收)

    // Phase K5: 信令数据交换
    // 信令数据队列 — 接收到的 updatePhoneCallSignalingData 暂存于此
    // 待 VoIP 层 (OngoingCallContext) 订阅后分发
    private var _signalingDataQueue: ArrayList<Array<Byte>> = ArrayList<Array<Byte>>()

    // 出向信令串行化（真机实锤修复）：tgcalls 连接建立瞬间会爆发几十个信令包，
    // 此前每包 spawn 一个并发 sendRequest，风暴把 MTProto 流打坏——之后所有入向包
    // auth_key_id mismatch 全被丢弃（挂断推送/来电推送全失效）。改为单 worker 逐包串行发送。
    private let _sigSendMutex: ReentrantMutex = ReentrantMutex()
    private var _sigSendQueue: ArrayList<Array<Byte>> = ArrayList<Array<Byte>>()
    private var _sigSenderRunning: Bool = false
    // 信令数据回调 — VoIP 层注册后接收信令数据
    private var _signalingDataCallback: Option<(Array<Byte>) -> Unit> = None

    // Phase K10: VoIP 控制器
    private var _voipContext: Option<OngoingCallContext> = None

    // 来电回调 — UI 层注册后，收到来电时触发
    private var _incomingCallCallback: Option<(CallSession) -> Unit> = None
    // 已弹过全屏来电页的 callId（防同一来电 PUSH/RAW 双路径重复 push）
    private var _lastIncomingUiCallId: Int64 = 0
    // 系统通话界面（Call Service Kit voipCall，iOS CallKit 等价）：已上报的来电 / 在系统界面上被接听的来电
    private let _voipMonitor: Monitor = Monitor()
    private var _voipReportedCallId: Int64 = 0
    private var _voipAnsweredCallId: Int64 = 0
    private var _voipEventsSubscribed: Bool = false

    // VCALL-6: 远端视频帧回调 — 由 VideoCallScreen 注册
    private var _videoFrameCallback: Option<(Array<Byte>, Int32, Int32) -> Unit> = None
    // VCALL-8: 本地视频帧回调 — 由 VideoCallScreen PiP 注册
    private var _localVideoFrameCallback: Option<(Array<Byte>, Int32, Int32) -> Unit> = None
    // P2-067: 音频电平回调 — 由 CallScreen 注册，驱动 blob 动画振幅
    private var _audioLevelCallback: Option<(Float32) -> Unit> = None

    public func getCurrentCall(): Option<CallSession> {
        synchronized(this._callSessionMonitor) {
            return this._currentCall
        }
        return None
    }

    // 申领通话结束的 UI 收尾权（首个申领者返回 true 并负责 routerPop；线程安全）
    public func claimUiDismiss(): Bool {
        this._sigSendMutex.lock()
        let ok = !this._uiDismissClaimed
        if (ok) { this._uiDismissClaimed = true }
        this._sigSendMutex.unlock()
        return ok
    }

    private func hasVideoFrameCallback(): Bool {
        match (this._videoFrameCallback) { case Some(_) => true; case None => false }
    }
    private func hasLocalVideoFrameCallback(): Bool {
        match (this._localVideoFrameCallback) { case Some(_) => true; case None => false }
    }

    /**
     * 注册来电回调 — 由 MainTabPage 注册
     * 当收到 phoneCallRequested 时，会调用此回调通知 UI 显示来电界面
     */
    public func setIncomingCallCallback(cb: (CallSession) -> Unit): Unit {
        this._incomingCallCallback = Some(cb)
    }

    public func hasActiveCall(): Bool {
        match (this._currentCall) {
            case Some(call) => return call.state != "idle" && call.state != "terminated"
            case None => return false
        }
    }

    /**
     * 订阅 UpdatesManager 的通话事件域（推送机制 — 第一道防线）。
     * MTProtoClient 的唯一 callback 由 AccountUpdateCoordinator 持有；CallService
     * 不观察全量 raw 总线，更不能覆盖消息/Chats 的更新入口。
     */
    public func ensureUpdateSubscription(): Unit {
        synchronized(this._updateSubscriptionMonitor) {
            if (this._updateSubscriptionToken >= 0) { return }
            getAccountUpdateCoordinator().initialize()
            this._updateSubscriptionToken = getUpdatesManager().addCallUpdateSubscriber({
                data: Array<Byte> => this.handleServerUpdate(data)
            })
            Hilog.info(0, "CjTelegram",
                "[CallService] Account updates subscription registered token=${this._updateSubscriptionToken}")
        }
    }

    /**
     * 获取 DH 配置
     */
    private func getDhConfig(): (Int32, Array<Byte>) {
        if (this._cachedDhG > 0 && this._cachedDhP.size > 0) {
            return (this._cachedDhG, this._cachedDhP)
        }
        try {
            let client = getMTProtoClient()
            let req = MessagesGetDhConfig()
            req.version = this._cachedDhVersion
            req.randomLength = 256
            Hilog.info(0, "CjTelegram", "[CallService] Fetching DH config...")
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size > 0) {
                let config = DhConfigResponse.deserialize(responseData)
                if (config.isModified && config.g > 0 && config.p.size > 0) {
                    this._cachedDhG = config.g
                    this._cachedDhP = config.p
                    this._cachedDhVersion = config.version
                    Hilog.info(0, "CjTelegram", "[CallService] DH config OK")
                    return (config.g, config.p)
                }
            }
        } catch (_e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallService] DH config fetch failed")
        }
        Hilog.info(0, "CjTelegram", "[CallService] Using fallback DH prime")
        let g: Int32 = 3
        let p = generateFallbackDhPrime()
        this._cachedDhG = g
        this._cachedDhP = p
        return (g, p)
    }

    /**
     * 从对端 protocol.library_versions 中选出我方实现的版本。
     * 我方 libtgcalls_ohos 仅注册 InstanceV2Impl = {13.0.0, 12.0.0, 9.0.0, 8.0.0, 7.0.0}
     * （10.0.0/11.0.0 属 InstanceV2ReferenceImpl，未编译）。
     * 对齐 iOS selectVersionOnAccept：取"我方偏好序第一个、且对端列表包含"的版本。
     * 被叫回的通常是单元素列表（它选定的版本）——匹配到就跑它。
     */
    private func pickImplementedVersion(remote: ArrayList<String>): String {
        let implemented = ["13.0.0", "12.0.0", "9.0.0", "8.0.0", "7.0.0"]
        for (v in implemented) {
            for (r in remote) {
                if (r == v) { return v }
            }
        }
        return ""
    }

    /**
     * 解析 phoneCallProtocol#fc878fc8：flags:int min_layer:int max_layer:int
     * library_versions:Vector<string>。返回 (versions, maxLayer)；ctor 不符时返回空。
     */
    private func parseCallProtocol(d: TLDeserializer): (ArrayList<String>, Int32) {
        let versions = ArrayList<String>()
        let ctor = d.readUInt32()
        if (ctor != 0xfc878fc8) {
            return (versions, 0)
        }
        let _flags = d.readInt32()
        let _minLayer = d.readInt32()
        let maxLayer = d.readInt32()
        let vecCtor = d.readUInt32()
        if (vecCtor == 0x1cb5c415) {
            let count = d.readInt32()
            var i: Int32 = 0
            while (i < count && i < 32) {
                versions.add(d.readString())
                i += 1
            }
        }
        return (versions, maxLayer)
    }

    /**
     * 来电分发（结构化推送路径）：先读主叫 protocol 选定版本，再走 handleIncomingCall，
     * 最后把选定版本落到新建 session（版本协商，被叫侧）。
     */
    private func dispatchIncomingWithProtocol(d: TLDeserializer, callId: Int64, accessHash: Int64,
                                              adminId: Int64, isVideo: Bool, gAHash: Array<Byte>): Unit {
        var incomingChosen = ""
        try {
            let (callerVersions, callerMaxLayer) = this.parseCallProtocol(d)
            if (callerVersions.size > 0) {
                incomingChosen = this.pickImplementedVersion(callerVersions)
                Hilog.info(0, "CjTelegram", "[CallService] PUSH incoming protocol: n=${callerVersions.size} chosen='${incomingChosen}' maxLayer=${callerMaxLayer}")
            }
        } catch (_pe: Exception) {
            Hilog.info(0, "CjTelegram", "[CallService] PUSH incoming protocol parse failed (non-fatal)")
        }
        handleIncomingCall(callId, accessHash, adminId, "Incoming Call", isVideo, gAHash)
        if (incomingChosen.size > 0) {
            match (this._currentCall) {
                case Some(s) => s.protocolVersion = incomingChosen
                case None => ()
            }
        }
    }

    /**
     * 发起通话
     */
    public func requestCall(peerId: Int64, peerAccessHash: Int64, peerName: String, isVideo: Bool): CallSession {
        Hilog.info(0, "CjTelegram", "[CallService] Requesting call isVideo=${isVideo}")
        ensureUpdateSubscription()
        this.ensureMicrophonePermission()
        if (isVideo) {
            this.ensureCameraPermission()
        }

        // 重置推送标记
        this._gotPhoneCallAccepted = false
        this._pendingAcceptedGB = Array<Byte>(0, repeat: 0)
        this._pendingAcceptedVersion = ""
        this._pendingAcceptedMaxLayer = 0
        this._uiDismissClaimed = false

        let session = CallSession()
        session.peerId = peerId
        session.peerAccessHash = peerAccessHash
        session.peerName = peerName
        session.peerAvatarPath = getUserPhotoService().getUserPhotoPath(peerId)
        session.isVideo = isVideo
        session.isLocalVideoEnabled = isVideo
        session.isOutgoing = true
        session.state = "requesting"
        this._currentCall = Some(session)

        let _ = spawn {
            this.doRequestCallAndPoll(session)
        }

        return session
    }

    /**
     * 核心流程：发起通话 → 轮询等待接听 → 确认通话
     * 
     * 所有 MTProto RPC 调用在同一个 spawn 中顺序执行，避免并发冲突
     * 
     * 对应 iOS:
     * requestCall → .requested → (等 updatePhoneCall) → .confirming → .active
     */
    private func doRequestCallAndPoll(session: CallSession): Unit {
        // ========== Phase 1: 获取 DH 配置 + 发起请求 ==========
        try {
            let client = getMTProtoClient()

            let (g, p) = getDhConfig()
            session.dhG = g
            session.dhP = p

            let a = ByteUtils.randomBytes(256)
            session.dhA = a

            let gBytes = gToBytes(g)
            let gA = BigIntMath.modPow(gBytes, a, p)
            session.dhGA = gA

            let gAHash = SHA256.hash(gA)
            session.dhGAHash = gAHash

            Hilog.info(0, "CjTelegram", "[CallService] DH params computed, sending requestCall")

            let req = PhoneRequestCall()
            req.isVideo = session.isVideo
            req.userId = session.peerId
            req.userAccessHash = session.peerAccessHash
            req.randomId = Int32(DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() % 2147483647)
            req.gAHash = gAHash

            let responseData = client.sendCallRequest(req.toBytes())

            if (responseData.size < 4) {
                session.state = "terminated"
                session.endReason = "error"
                Hilog.info(0, "CjTelegram", "[CallService] Empty response from requestCall")
                return
            }

            // 检查 RPC Error
            let checkD = TLDeserializer(responseData)
            let checkCtor = checkD.readUInt32()
            if (checkCtor == 0x2144ca19) {
                let errCode = checkD.readInt32()
                let errMsg = checkD.readString()
                Hilog.info(0, "CjTelegram", "[CallService] RPC Error on requestCall")
                session.state = "terminated"
                session.endReason = "error"
                return
            }

            let response = PhoneCallResponse.deserialize(responseData)

            if (response.callType == "waiting" || response.callType == "requested") {
                session.callId = response.callId
                session.accessHash = response.accessHash
                session.state = "requested"
                Hilog.info(0, "CjTelegram", "[CallService] Call in requested state, waiting for peer")
                // iOS requestCallSession：phoneCallWaiting.receiveDate → remoteConfirmationTimestamp
                if (response.callType == "waiting" && response.receiveDate > 0) {
                    this.markRemoteRinging(session, response.callId)
                }
            } else if (response.callType == "discarded") {
                session.state = "terminated"
                session.endReason = response.discardReason
                Hilog.info(0, "CjTelegram", "[CallService] Call discarded by server")
                return
            } else {
                if (response.callId > 0) {
                    session.callId = response.callId
                    session.accessHash = response.accessHash
                }
                session.state = "requested"
                Hilog.info(0, "CjTelegram", "[CallService] Call response type unknown, polling anyway")
            }
        } catch (_e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallService] requestCall exception")
            session.state = "terminated"
            session.endReason = "error"
            return
        }

        // ========== Phase 2: 等待 phoneCallAccepted（推送驱动 + 保活轮询） ==========
        // 
        // 核心策略：
        // (A) 依赖 updateCallback 推送接收 phoneCallAccepted（主要机制）
        //     - 已通过修复 startReceiveLoop 和 processBuffer 确保接收循环不会因解析错误而死亡
        // (B) 每 1.5 秒发 updates.getState 保持 TCP 连接活跃（防止空闲断开）
        // (C) 每次迭代检查推送标记 _gotPhoneCallAccepted
        // (D) 每次迭代检查连接健康状态，如果断开则重连

        // 等待时长对齐 iOS：TelegramCore CallSessionManager 在 .requested 态没有任何客户端计时器，
        // 只在服务器下发 phoneCallDiscarded（对端拒接 / 服务器按 call_receive_timeout_ms、
        // call_ring_timeout_ms 判定未接）或用户挂断时结束；phoneCallWaiting.receive_date 只把状态
        // 标成 requesting(ringing: true)。此处的本地截止时间仅是服务器 discard 丢失时的兜底，
        // 取自 help.getConfig，且总落在服务器自身计时之后。
        this.ensureCallTimeoutsLoaded()
        let waitStartMs = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
        Hilog.info(0, "CjTelegram", "[CallService] Waiting for phoneCallAccepted (push-driven) receiveTimeoutMs=${this._callReceiveTimeoutMs} ringTimeoutMs=${this._callRingTimeoutMs}")

        var pollCount: Int64 = 0

        while (session.state == "requested" && !this.outgoingWaitExpired(session, waitStartMs)) {
            sleep(Duration.millisecond * 1500)
            pollCount = pollCount + 1

            // (C) 检查推送标记（由 updateCallback 设置）
            if (this._gotPhoneCallAccepted) {
                Hilog.info(0, "CjTelegram", "[CallService] phoneCallAccepted detected via PUSH! (poll #${pollCount})")
                session.dhGB = this._pendingAcceptedGB
                if (this._pendingAcceptedCallId > 0) {
                    session.callId = this._pendingAcceptedCallId
                    session.accessHash = this._pendingAcceptedAccessHash
                }
                // 版本协商：跑被叫选定的版本（结构化推送路径经 pending 中转）
                if (this._pendingAcceptedVersion.size > 0) {
                    session.protocolVersion = this._pendingAcceptedVersion
                    if (this._pendingAcceptedMaxLayer > 0) { session.maxLayer = this._pendingAcceptedMaxLayer }
                }
                session.state = "confirming"
                break
            }

            // 检查是否已被 updateCallback 设置为其他状态（terminated/active等）
            if (session.state != "requested") {
                Hilog.info(0, "CjTelegram", "[CallService] State changed to '${session.state}' via push")
                break
            }

            try {
                let client = getMTProtoClient()

                // (D) 确保连接存活
                client.ensureConnectionAlive()

                // (B) 发 getState 保持连接活跃
                // 这会触发服务器发送任何挂起的推送更新
                let _ = client.sendRequest(UpdatesGetState().toBytes())

                if (pollCount % 10 == 0) {
                    Hilog.info(0, "CjTelegram", "[CallService] Keep-alive #${pollCount}, still waiting...")
                }
            } catch (_e: Exception) {
                Hilog.info(0, "CjTelegram", "[CallService] Keep-alive request failed, will retry")
            }

            // 再次检查推送标记（getState 的响应处理期间可能收到了推送）
            if (this._gotPhoneCallAccepted) {
                Hilog.info(0, "CjTelegram", "[CallService] phoneCallAccepted detected after keep-alive!")
                session.dhGB = this._pendingAcceptedGB
                if (this._pendingAcceptedCallId > 0) {
                    session.callId = this._pendingAcceptedCallId
                    session.accessHash = this._pendingAcceptedAccessHash
                }
                // 版本协商：同上，落地被叫选定版本
                if (this._pendingAcceptedVersion.size > 0) {
                    session.protocolVersion = this._pendingAcceptedVersion
                    if (this._pendingAcceptedMaxLayer > 0) { session.maxLayer = this._pendingAcceptedMaxLayer }
                }
                session.state = "confirming"
                break
            }
        }

        // ========== Phase 3: 发送 phone.confirmCall ==========

        if (session.state == "confirming") {
            Hilog.info(0, "CjTelegram", "[CallService] Proceeding to confirmCall")
            doConfirmCall(session)
        } else if (session.state == "requested") {
            // 兜底超时（服务器 discard 未到达）
            Hilog.info(0, "CjTelegram", "[CallService] Poll timeout, no answer (remoteRinging=${session.remoteRinging})")
            session.state = "terminated"
            session.endReason = "missed"
            discardCallSignaling(session, "missed")
            addToHistory(session)
        }
        // 其他状态（terminated/active）已被处理
    }

    /**
     * 读取 help.getConfig 的通话超时（每进程成功一次即缓存；失败下次发起通话再取）。
     * 源侧 Api5.swift Cons_config.callReceiveTimeoutMs / callRingTimeoutMs。
     */
    private func ensureCallTimeoutsLoaded(): Unit {
        if (this._callReceiveTimeoutMs > 0 || this._callRingTimeoutMs > 0) { return }
        try {
            match (getTelegramEngineDataService().getConfigLimits()) {
                case Some(limits) =>
                    this._callReceiveTimeoutMs = Int64(limits.callReceiveTimeoutMs)
                    this._callRingTimeoutMs = Int64(limits.callRingTimeoutMs)
                case None => ()
            }
        } catch (_e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallService] help.getConfig for call timeouts failed")
        }
    }

    /**
     * 主叫等待的兜底截止判断。服务器先按 call_receive_timeout_ms 等被叫收到（phoneCallWaiting
     * 带 receive_date），再按 call_ring_timeout_ms 等接听，超时后自己下发 phoneCallDiscarded(missed)。
     * 本地只在比服务器更晚的时刻才放弃：已响铃 → 响铃起点 + ring；未知是否响铃 → 发起 + receive + ring；
     * 再加余量。服务器未下发超时配置时不设本地截止（与 iOS 一致，等服务器或用户挂断）。
     */
    private func outgoingWaitExpired(session: CallSession, waitStartMs: Int64): Bool {
        let ringMs = this._callRingTimeoutMs
        let receiveMs = this._callReceiveTimeoutMs
        if (ringMs <= 0 && receiveMs <= 0) { return false }
        let graceMs: Int64 = 5000
        let now = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
        if (session.remoteRinging && session.remoteRingingSinceMs > 0) {
            return now - session.remoteRingingSinceMs > ringMs + graceMs
        }
        return now - waitStartMs > receiveMs + ringMs + graceMs
    }

    /** phoneCallWaiting 带 receive_date：被叫已收到来电（iOS remoteConfirmationTimestamp）。 */
    private func markRemoteRinging(session: CallSession, callId: Int64): Unit {
        if (!session.isOutgoing || session.state != "requested" || callId != session.callId || session.remoteRinging) {
            return
        }
        session.remoteRinging = true
        session.remoteRingingSinceMs = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
        Hilog.info(0, "CjTelegram", "[CallService] peer received the call (phoneCallWaiting.receive_date) → ringing")
    }

    /**
     * 扫描原始字节寻找 phoneCallWaiting#c5226f17（源侧 Api0.swift dict[-987599081]）
     * flags:# video:flags.6?true id:long access_hash:long date:int admin_id:long participant_id:long
     * protocol:PhoneCallProtocol receive_date:flags.0?int
     */
    private func scanForPhoneCallWaiting(data: Array<Byte>, session: CallSession): Unit {
        var pos: Int64 = 0
        while (pos + 4 <= data.size) {
            if (UInt8(data[pos]) == 0x17 && UInt8(data[pos + 1]) == 0x6F &&
                UInt8(data[pos + 2]) == 0x22 && UInt8(data[pos + 3]) == 0xC5) {
                try {
                    let d = TLDeserializer(ByteUtils.slice(data, pos + 4, data.size))
                    let flags = d.readInt32()
                    let callId = d.readInt64()
                    if (callId == session.callId && (flags & 1) != 0) {
                        let _accessHash = d.readInt64()
                        let _date = d.readInt32()
                        let _adminId = d.readInt64()
                        let _participantId = d.readInt64()
                        let _ = this.parseCallProtocol(d)
                        let _receiveDate = d.readInt32()
                        this.markRemoteRinging(session, callId)
                        return
                    }
                } catch (_e: Exception) {}
            }
            pos = pos + 1
        }
    }

    /**
     * 扫描原始字节寻找 phoneCallAccepted#3660c311
     * 
     * 在 getDifference 响应中查找 phoneCallAccepted 构造器
     * 找到后解析 gB 等字段
     */
    private func scanForPhoneCallAccepted(data: Array<Byte>, session: CallSession): Bool {
        // 寻找 0x3660c311 (phoneCallAccepted) 的小端字节序: 11 c3 60 36
        let target0: UInt8 = 0x11
        let target1: UInt8 = 0xC3
        let target2: UInt8 = 0x60
        let target3: UInt8 = 0x36

        var pos: Int64 = 0
        while (pos + 4 <= data.size) {
            if (UInt8(data[pos]) == target0 && UInt8(data[pos + 1]) == target1 &&
                UInt8(data[pos + 2]) == target2 && UInt8(data[pos + 3]) == target3) {
                // 找到了！尝试从 pos+4 开始解析
                Hilog.info(0, "CjTelegram", "[CallService] phoneCallAccepted pattern found in response bytes")
                try {
                    let remaining = ByteUtils.slice(data, pos + 4, data.size)
                    let d = TLDeserializer(remaining)
                    let flags = d.readInt32()
                    let _isVideo = (flags & (1 << 6)) != 0
                    let callId = d.readInt64()
                    let accessHash = d.readInt64()
                    let _date = d.readInt32()
                    let _adminId = d.readInt64()
                    let _participantId = d.readInt64()
                    let gB = d.readBytes()

                    // iOS updateSession 按 contextIdByStableId[id] 定位会话：别的通话的 accepted 不得套到本会话
                    if (session.callId != 0 && callId != session.callId) {
                        Hilog.info(0, "CjTelegram", "[CallService] Ignore phoneCallAccepted for another call")
                        return false
                    }
                    session.dhGB = gB
                    session.callId = callId
                    session.accessHash = accessHash
                    Hilog.info(0, "CjTelegram", "[CallService] Parsed phoneCallAccepted: gB extracted")

                    // 版本协商修复：gB 之后紧跟 protocol:PhoneCallProtocol——被叫选定的
                    // 库版本在此。必须跑它（此前丢弃并写死 12.0.0 → 与 iOS 选的版本
                    // 信令格式不匹配，永远连不上）。解析失败不影响 accepted 主流程。
                    try {
                        let (peerVersions, peerMaxLayer) = this.parseCallProtocol(d)
                        if (peerVersions.size > 0) {
                            let chosen = this.pickImplementedVersion(peerVersions)
                            if (chosen.size > 0) {
                                session.protocolVersion = chosen
                                if (peerMaxLayer > 0) { session.maxLayer = peerMaxLayer }
                            }
                            Hilog.info(0, "CjTelegram", "[CallService] Accepted protocol: peer=[${peerVersions[0]}...] n=${peerVersions.size} chosen='${chosen}' maxLayer=${peerMaxLayer}")
                        } else {
                            Hilog.info(0, "CjTelegram", "[CallService] Accepted protocol: no versions parsed")
                        }
                    } catch (_pe: Exception) {
                        Hilog.info(0, "CjTelegram", "[CallService] Accepted protocol parse failed (non-fatal)")
                    }
                    return true
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CallService] Failed to parse after phoneCallAccepted pattern")
                }
            }
            pos = pos + 1
        }
        return false
    }

    /**
     * 扫描原始字节寻找 phoneCallDiscarded#50ca4de1，只认 id == session.callId 的那条
     * （iOS updateSession 按 contextIdByStableId[id] 定位；上一通电话迟到/重发的 discard
     * 不得结束当前通话）。命中时把 need_rating / reason 回填到 session。
     */
    private func scanForPhoneCallDiscarded(data: Array<Byte>, session: CallSession): Bool {
        let target0: UInt8 = 0xE1
        let target1: UInt8 = 0x4D
        let target2: UInt8 = 0xCA
        let target3: UInt8 = 0x50

        var pos: Int64 = 0
        while (pos + 4 <= data.size) {
            if (UInt8(data[pos]) == target0 && UInt8(data[pos + 1]) == target1 &&
                UInt8(data[pos + 2]) == target2 && UInt8(data[pos + 3]) == target3) {
                // 解析 phoneCallDiscarded：flags → id:long → reason:flags.0? → duration:flags.1?
                // 提取 need_rating(bit2) 与 discard reason（此前 raw 路径丢弃 reason、
                // 调用点硬编码 "hangup" → 主叫取消的未接来电不标 missed）。
                try {
                    let remaining = ByteUtils.slice(data, pos + 4, data.size)
                    let d = TLDeserializer(remaining)
                    let flags = d.readInt32()
                    let discardedId = d.readInt64()
                    if (session.callId != 0 && discardedId == session.callId) {
                        var reason = "hangup"
                        if ((flags & 1) != 0) {
                            let reasonCtor = d.readUInt32()
                            reason = parseDiscardReasonCtor(reasonCtor)
                        }
                        session.needRating = (flags & (1 << 2)) != 0
                        session.endReason = reason
                        return true
                    }
                    Hilog.info(0, "CjTelegram", "[CallService] Ignore phoneCallDiscarded for another call")
                } catch (_pe: Exception) {}
            }
            pos = pos + 1
        }
        return false
    }

    /**
     * 处理服务器推送的更新消息
     * 
     * 这是接收 phoneCall 更新的主要入口点
     * 通过 MTProtoClient.updateCallback 回调
     * 
     * 策略：先尝试结构化解析，失败则回退到原始字节扫描
     */
    public func handleServerUpdate(data: Array<Byte>): Unit {
        if (data.size < 4) { return }
        
        Hilog.info(0, "CjTelegram", "[CallService] handleServerUpdate: ${data.size} bytes")

        try {
            let d = TLDeserializer(data)
            let constructor = d.readUInt32()

            Hilog.info(0, "CjTelegram", "[CallService] Update constructor: 0x${UInt32ToHex(constructor)}")

            // *** gzip_packed#3072cfa1 — 解压后递归处理 ***
            // 服务器经常将 phoneCallAccepted 等更新用 GZIP 压缩
            // 这是之前通话无法接通的根因！
            if (constructor == 0x3072cfa1) {
                Hilog.info(0, "CjTelegram", "[CallService] GZIP_PACKED detected! Decompressing...")
                let compressedData = d.readBytes()
                let decompressed = decompress(compressedData)
                Hilog.info(0, "CjTelegram", "[CallService] Decompressed: ${compressedData.size} -> ${decompressed.size} bytes")
                if (decompressed.size >= 4) {
                    // 递归处理解压后的数据
                    handleServerUpdate(decompressed)
                }
                return
            }

            // updateShort#78d4dec1 — 只包含一个 Update
            if (constructor == 0x78d4dec1) {
                try {
                    let updateConstructor = d.readUInt32()
                    Hilog.info(0, "CjTelegram", "[CallService] updateShort inner: 0x${UInt32ToHex(updateConstructor)}")
                    if (updateConstructor == 0xab0f6b1e) {
                        // updatePhoneCall — 尝试结构化解析
                        handlePhoneCallUpdatePush(d)
                        return
                    }
                    if (updateConstructor == 0x2661BF09) {
                        // updatePhoneCallSignalingData — 信令数据
                        handleSignalingDataUpdate(d)
                        return
                    }
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CallService] updateShort parse failed, trying raw scan")
                }
                // 结构化解析失败，回退到字节扫描
                scanAndHandlePhoneCallInRawData(data)
                return
            }

            // updates#74ae4240 — 包含 Vector<Update>
            if (constructor == 0x74ae4240) {
                // 直接用字节扫描（无法可靠跳过未知 Update 类型）
                scanAndHandlePhoneCallInRawData(data)
                return
            }

            // updatesCombined#725b04c3
            if (constructor == 0x725b04c3) {
                scanAndHandlePhoneCallInRawData(data)
                return
            }

            // 直接是 updatePhoneCall#ab0f6b1e
            if (constructor == 0xab0f6b1e) {
                handlePhoneCallUpdatePush(d)
                return
            }

            // 直接是 updatePhoneCallSignalingData#2661bf09
            if (constructor == 0x2661BF09) {
                handleSignalingDataUpdate(d)
                return
            }

            // 其他类型：扫描原始字节
            scanAndHandlePhoneCallInRawData(data)

        } catch (_e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallService] Error in structured parsing, trying raw scan")
            try {
                scanAndHandlePhoneCallInRawData(data)
            } catch (_e2: Exception) {
                Hilog.info(0, "CjTelegram", "[CallService] Raw scan also failed")
            }
        }
    }

    /**
     * 扫描原始推送数据中的 phoneCall 构造器
     * 
     * 处理所有 phoneCall 类型：
     * - phoneCallRequested#14b0ed0c (来电)
     * - phoneCallAccepted#3660c311 (对方接听)
     * - phoneCallDiscarded#50ca4de1 (通话结束)
     * - phoneCall#30535af5 (通话活跃, 当前层) / phoneCall#967f7c67 (旧版)
     */
    private func scanAndHandlePhoneCallInRawData(data: Array<Byte>): Unit {
        // === 首先扫描来电 phoneCallRequested#14b0ed0c ===
        // 无论是否有 _currentCall 都要检查来电
        if (scanForPhoneCallRequested(data)) {
            Hilog.info(0, "CjTelegram", "[CallService] PUSH: phoneCallRequested found in raw data!")
            return
        }

        match (this._currentCall) {
            case Some(session) =>
                // *** 状态感知扫描顺序 ***
                // 
                // 关键修复：先扫描 phoneCallActive，再扫描 phoneCallAccepted
                // 原因：服务器可能在同一个 updates 容器中同时包含 phoneCallAccepted 和 phoneCall(active)
                // 如果先扫描 accepted，会在找到旧的 accepted 模式后直接返回，
                // 永远不会检测到 active 模式
                //
                // 而且：当 session.state 已经是 "confirming"（已收到 accepted，正在等 active），
                // 此时只需要找 active，不需要再找 accepted

                // 1. 始终优先扫描 phoneCall (active)#30535af5 / #967f7c67
                if (scanForPhoneCallActive(data, session)) {
                    Hilog.info(0, "CjTelegram", "[CallService] PUSH: phoneCall active detected in raw data!")
                    return
                }

                // 2. 扫描 phoneCallDiscarded（任何状态都需要检测）
                //    endReason 已由 scanForPhoneCallDiscarded 从 reason 字段解析回填，
                //    不再硬编码 hangup（否则主叫取消未接来电会误记 hangup 而非 missed）
                if (scanForPhoneCallDiscarded(data, session)) {
                    session.state = "terminated"
                    this.stopVoipEngine()
                    addToHistory(session)
                    Hilog.info(0, "CjTelegram", "[CallService] PUSH: phoneCallDiscarded detected")
                    return
                }

                // 3. 仅在 "requested" 状态才扫描 phoneCallAccepted
                //    "confirming"/"active" 状态不需要再找 accepted
                if (session.state == "requested") {
                    if (!session.remoteRinging) {
                        this.scanForPhoneCallWaiting(data, session)
                    }
                    if (scanForPhoneCallAccepted(data, session)) {
                        this._gotPhoneCallAccepted = true
                        this._pendingAcceptedGB = session.dhGB
                        this._pendingAcceptedCallId = session.callId
                        this._pendingAcceptedAccessHash = session.accessHash
                        // 版本协商：scan 已把选中版本写入 session.protocolVersion，同步进 pending
                        this._pendingAcceptedVersion = session.protocolVersion
                        this._pendingAcceptedMaxLayer = session.maxLayer
                        Hilog.info(0, "CjTelegram", "[CallService] PUSH: phoneCallAccepted detected in raw data!")
                        return
                    }
                }

                // 4. 扫描 updatePhoneCallSignalingData#2661bf09（通话进行中：connecting/active/reconnecting）
                //    关键修复（真机死锁）：对方的握手信令常在 tgcalls 尚处 Reconnecting 时到达，
                //    若只在 "active" 才喂给 tgcalls，握手回包被丢 → 永远连不上。必须放开 reconnecting。
                if (session.state == "connecting" || session.state == "active" || session.state == "reconnecting") {
                    scanForSignalingData(data, session)
                }
            case None => ()
        }
    }

    /**
     * 扫描原始字节寻找 updatePhoneCallSignalingData#2661bf09
     * 
     * TL: updatePhoneCallSignalingData#2661bf09 phone_call_id:long data:bytes
     * 小端字节: 09 bf 61 26
     */
    private func scanForSignalingData(data: Array<Byte>, session: CallSession): Unit {
        let target0: UInt8 = 0x09
        let target1: UInt8 = 0xBF
        let target2: UInt8 = 0x61
        let target3: UInt8 = 0x26

        var pos: Int64 = 0
        while (pos + 4 <= data.size) {
            if (UInt8(data[pos]) == target0 && UInt8(data[pos + 1]) == target1 &&
                UInt8(data[pos + 2]) == target2 && UInt8(data[pos + 3]) == target3) {
                try {
                    let remaining = ByteUtils.slice(data, pos + 4, data.size)
                    let d = TLDeserializer(remaining)
                    let phoneCallId = d.readInt64()
                    let sigData = d.readBytes()
                    if (phoneCallId == session.callId) {
                        Hilog.info(0, "CjTelegram", "[CallService] RAW: signaling data found, ${sigData.size} bytes")
                        deliverSignalingData(sigData)
                    }
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CallService] RAW: failed to parse signaling data at pos ${pos}")
                }
                return
            }
            pos = pos + 1
        }
    }

    /**
     * 扫描原始字节寻找 phoneCallRequested#14b0ed0c（来电）
     * 
     * TL: phoneCallRequested#14b0ed0c flags:# video:flags.6?true
     *     id:long access_hash:long date:int admin_id:long
     *     participant_id:long g_a_hash:bytes protocol:PhoneCallProtocol
     */
    private func scanForPhoneCallRequested(data: Array<Byte>): Bool {
        // 0x14b0ed0c 小端: 0c ed b0 14
        let target0: UInt8 = 0x0C
        let target1: UInt8 = 0xED
        let target2: UInt8 = 0xB0
        let target3: UInt8 = 0x14

        var pos: Int64 = 0
        while (pos + 4 <= data.size) {
            if (UInt8(data[pos]) == target0 && UInt8(data[pos + 1]) == target1 &&
                UInt8(data[pos + 2]) == target2 && UInt8(data[pos + 3]) == target3) {
                Hilog.info(0, "CjTelegram", "[CallService] phoneCallRequested pattern found at pos ${pos}")
                try {
                    let remaining = ByteUtils.slice(data, pos + 4, data.size)
                    let d = TLDeserializer(remaining)
                    let flags = d.readInt32()
                    let isVideo = (flags & (1 << 6)) != 0
                    let callId = d.readInt64()
                    let accessHash = d.readInt64()
                    let _date = d.readInt32()
                    let adminId = d.readInt64()
                    let _participantId = d.readInt64()
                    let gAHash = d.readBytes()
                    Hilog.info(0, "CjTelegram", "[CallService] Incoming call parsed: id=${callId}")
                    // 版本协商（被叫侧）：gAHash 后紧跟主叫的 protocol，从中选我方实现的版本
                    var incomingChosen = ""
                    try {
                        let (callerVersions, callerMaxLayer) = this.parseCallProtocol(d)
                        if (callerVersions.size > 0) {
                            incomingChosen = this.pickImplementedVersion(callerVersions)
                            Hilog.info(0, "CjTelegram", "[CallService] Incoming protocol: n=${callerVersions.size} chosen='${incomingChosen}' maxLayer=${callerMaxLayer}")
                        }
                    } catch (_pe: Exception) {
                        Hilog.info(0, "CjTelegram", "[CallService] Incoming protocol parse failed (non-fatal)")
                    }
                    handleIncomingCall(callId, accessHash, adminId, "Incoming Call", isVideo, gAHash)
                    if (incomingChosen.size > 0) {
                        match (this._currentCall) {
                            case Some(s) => s.protocolVersion = incomingChosen
                            case None => ()
                        }
                    }
                    return true
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CallService] Failed to parse phoneCallRequested")
                }
            }
            pos = pos + 1
        }
        return false
    }

    /**
     * 扫描原始字节寻找 phoneCall (active) 构造器
     * 
     * 当前层: phoneCall#30535af5 (0x30535AF5)
     * 旧版:   phoneCall#967f7c67 (0x967f7c67) — 作为兼容保留
     */
    private func scanForPhoneCallActive(data: Array<Byte>, session: CallSession): Bool {
        // 0x30535AF5 小端: F5 5A 53 30
        let newTarget0: UInt8 = 0xF5
        let newTarget1: UInt8 = 0x5A
        let newTarget2: UInt8 = 0x53
        let newTarget3: UInt8 = 0x30

        // 0x967f7c67 小端: 67 7c 7f 96 (旧版兼容)
        let oldTarget0: UInt8 = 0x67
        let oldTarget1: UInt8 = 0x7C
        let oldTarget2: UInt8 = 0x7F
        let oldTarget3: UInt8 = 0x96

        var pos: Int64 = 0
        while (pos + 4 <= data.size) {
            let b0 = UInt8(data[pos])
            let b1 = UInt8(data[pos + 1])
            let b2 = UInt8(data[pos + 2])
            let b3 = UInt8(data[pos + 3])

            let isNewCtor = (b0 == newTarget0 && b1 == newTarget1 && b2 == newTarget2 && b3 == newTarget3)
            let isOldCtor = (b0 == oldTarget0 && b1 == oldTarget1 && b2 == oldTarget2 && b3 == oldTarget3)

            if (isNewCtor || isOldCtor) {
                let ctorHex = if (isNewCtor) { "0x30535AF5" } else { "0x967f7c67" }
                Hilog.info(0, "CjTelegram", "[CallService] phoneCall active pattern found! ctor=${ctorHex} at pos=${pos}")
                try {
                    let remaining = ByteUtils.slice(data, pos + 4, data.size)
                    let d = TLDeserializer(remaining)
                    let flags = d.readInt32()
                    let callId = d.readInt64()
                    let accessHash = d.readInt64()
                    if (session.callId != 0 && callId != session.callId) {
                        Hilog.info(0, "CjTelegram", "[CallService] RAW: ignore active phoneCall for another call")
                        return false
                    }
                    session.callId = callId
                    session.accessHash = accessHash

                    // 完整解析：读取 date, adminId, participantId, gAOrB, keyFingerprint
                    let _date = d.readInt32()
                    let _adminId = d.readInt64()
                    let _participantId = d.readInt64()
                    let gAOrB = d.readBytes()
                    let keyFingerprint = d.readInt64()

                    // 对于来电：计算共享密钥
                    if (!session.isOutgoing && session.sharedKey.size == 0 && session.dhA.size > 0 && session.dhP.size > 0) {
                        Hilog.info(0, "CjTelegram", "[CallService] RAW: computing shared key for incoming call")
                        var key = BigIntMath.modPow(gAOrB, session.dhA, session.dhP)
                        if (key.size > 256) { key = ByteUtils.slice(key, key.size - 256, key.size) }
                        else if (key.size < 256) {
                            let padded = Array<Byte>(256, repeat: 0)
                            let offset = 256 - key.size
                            var idx: Int64 = 0
                            while (idx < key.size) { padded[offset + idx] = key[idx]; idx = idx + 1 }
                            key = padded
                        }
                        session.sharedKey = key
                        let keyPlusGA = ByteUtils.concat2(key, gAOrB)
                        session.keyEmoji = generateKeyEmojiFromHash(SHA256.hash(keyPlusGA))
                        session.keyFingerprint = keyFingerprint
                        Hilog.info(0, "CjTelegram", "[CallService] RAW: shared key computed OK (${key.size}B)")
                    }

                    // 解析 protocol 和 connections
                    parseProtocolToSession(d, session)
                    parseConnectionsToSession(d, session)

                    session.state = "active"
                    session.startTime = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
                    session.signalBars = 4
                    Hilog.info(0, "CjTelegram", "[CallService] >>> CALL ACTIVE via push! callId=${callId} sharedKey=${session.sharedKey.size}B connections=${session.connections.size} <<<")
                    this.startCallTimer(session)
                    // Phase K10: 启动 VoIP 引擎
                    this.startVoipEngine(session)
                    return true
                } catch (_e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CallService] Failed to parse phoneCall active: ${_e}")
                }
            }
            pos = pos + 1
        }
        return false
    }

    /**
     * 处理推送的 updatePhoneCall（结构化解析）
     * 仅在 updateShort 中使用
     * 
     * 关键：不 spawn doConfirmCall，仅设置标记
     */
    private func handlePhoneCallUpdatePush(d: TLDeserializer): Unit {
        let callCtor = d.readUInt32()
        Hilog.info(0, "CjTelegram", "[CallService] PUSH: phoneCall update received")

        match (this._currentCall) {
            case Some(session) =>
                // phoneCallAccepted#3660c311
                if (callCtor == 0x3660c311) {
                    Hilog.info(0, "CjTelegram", "[CallService] PUSH: >>> phoneCallAccepted! <<<")
                    let flags = d.readInt32()
                    let _isVideo = (flags & (1 << 6)) != 0
                    let callId = d.readInt64()
                    let accessHash = d.readInt64()
                    let _date = d.readInt32()
                    let _adminId = d.readInt64()
                    let _participantId = d.readInt64()
                    let gB = d.readBytes()
                    if (session.callId != 0 && callId != session.callId) {
                        Hilog.info(0, "CjTelegram", "[CallService] PUSH: ignore phoneCallAccepted for another call")
                        return
                    }

                    // 版本协商修复：读取被叫选定的 protocol.library_versions（解析失败不阻断）
                    try {
                        let (peerVersions, peerMaxLayer) = this.parseCallProtocol(d)
                        if (peerVersions.size > 0) {
                            let chosen = this.pickImplementedVersion(peerVersions)
                            this._pendingAcceptedVersion = chosen
                            this._pendingAcceptedMaxLayer = peerMaxLayer
                            Hilog.info(0, "CjTelegram", "[CallService] PUSH accepted protocol: n=${peerVersions.size} chosen='${chosen}'")
                        }
                    } catch (_pe: Exception) {
                        Hilog.info(0, "CjTelegram", "[CallService] PUSH accepted protocol parse failed (non-fatal)")
                    }

                    // 设置标记，让轮询循环在下一次迭代中处理
                    // 不 spawn doConfirmCall — 避免 sendRequest 并发
                    this._gotPhoneCallAccepted = true
                    this._pendingAcceptedGB = gB
                    this._pendingAcceptedCallId = callId
                    this._pendingAcceptedAccessHash = accessHash
                }
                // phoneCallDiscarded#50ca4de1
                else if (callCtor == 0x50ca4de1) {
                    Hilog.info(0, "CjTelegram", "[CallService] PUSH: phoneCallDiscarded")
                    let flags = d.readInt32()
                    let discardedId = d.readInt64()
                    var reason = "hangup"
                    if ((flags & 1) != 0) {
                        let reasonCtor = d.readUInt32()
                        reason = parseDiscardReasonCtor(reasonCtor)
                    }
                    if (session.callId == 0 || discardedId != session.callId) {
                        Hilog.info(0, "CjTelegram", "[CallService] PUSH: ignore phoneCallDiscarded for another call")
                        return
                    }
                    // need_rating = flags bit2（对齐 iOS CallSessionManager:1139 服务器抽样）
                    session.needRating = (flags & (1 << 2)) != 0
                    session.state = "terminated"
                    session.endReason = reason
                    this._timerRunning = false
                    this.stopVoipEngine()
                    addToHistory(session)
                }
                // phoneCallWaiting#c5226f17 — receive_date(flags.0) 表示被叫已收到（iOS CallSessionManager
                // updateSession .phoneCallWaiting → requested(remoteConfirmationTimestamp:)）
                else if (callCtor == 0xc5226f17) {
                    Hilog.info(0, "CjTelegram", "[CallService] PUSH: phoneCallWaiting")
                    let flags = d.readInt32()
                    let callId = d.readInt64()
                    if ((flags & 1) != 0 && callId == session.callId) {
                        let _accessHash = d.readInt64()
                        let _date = d.readInt32()
                        let _adminId = d.readInt64()
                        let _participantId = d.readInt64()
                        let _ = this.parseCallProtocol(d)
                        let _receiveDate = d.readInt32()
                        this.markRemoteRinging(session, callId)
                    }
                }
                // phoneCall#30535af5 (current) / phoneCall#967f7c67 (legacy) — active
                else if (callCtor == 0x30535AF5 || callCtor == 0x967f7c67) {
                    Hilog.info(0, "CjTelegram", "[CallService] PUSH: phoneCall active (ctor=${UInt32ToHex(callCtor)})")
                    try {
                        let flags = d.readInt32()
                        let callId = d.readInt64()
                        let accessHash = d.readInt64()
                        if (session.callId != 0 && callId != session.callId) {
                            Hilog.info(0, "CjTelegram", "[CallService] PUSH: ignore active phoneCall for another call")
                            return
                        }
                        session.callId = callId
                        session.accessHash = accessHash

                        // Phase K6: 结构化解析 active phoneCall 中的 connections
                        let _date = d.readInt32()
                        let _adminId = d.readInt64()
                        let _participantId = d.readInt64()
                        let gAOrB = d.readBytes()       // g_a_or_b:bytes
                        let keyFingerprint = d.readInt64()

                        // 关键修复：对于来电（isOutgoing=false），需要在此处计算共享密钥
                        // gAOrB 是对方的 gA，session.dhA 是我方的私钥 b，session.dhP 是 DH 素数
                        if (!session.isOutgoing && session.sharedKey.size == 0 && session.dhA.size > 0 && session.dhP.size > 0) {
                            Hilog.info(0, "CjTelegram", "[CallService] PUSH: computing shared key for incoming call (gA=${gAOrB.size}B, b=${session.dhA.size}B, p=${session.dhP.size}B)")
                            // 验证 gAHash
                            if (session.dhGAHash.size > 0) {
                                let computedHash = SHA256.hash(gAOrB)
                                if (ByteUtils.equals(computedHash, session.dhGAHash)) {
                                    Hilog.info(0, "CjTelegram", "[CallService] PUSH: gA hash verified OK")
                                } else {
                                    Hilog.info(0, "CjTelegram", "[CallService] PUSH: WARNING gA hash MISMATCH!")
                                }
                            }
                            var key = BigIntMath.modPow(gAOrB, session.dhA, session.dhP)
                            if (key.size > 256) { key = ByteUtils.slice(key, key.size - 256, key.size) }
                            else if (key.size < 256) {
                                let padded = Array<Byte>(256, repeat: 0)
                                let offset = 256 - key.size
                                var idx: Int64 = 0
                                while (idx < key.size) { padded[offset + idx] = key[idx]; idx = idx + 1 }
                                key = padded
                            }
                            session.sharedKey = key
                            let keyPlusGA = ByteUtils.concat2(key, gAOrB)
                            session.keyEmoji = generateKeyEmojiFromHash(SHA256.hash(keyPlusGA))
                            session.keyFingerprint = keyFingerprint
                            Hilog.info(0, "CjTelegram", "[CallService] PUSH: shared key computed OK (${key.size}B)")
                        } else if (session.sharedKey.size > 0) {
                            Hilog.info(0, "CjTelegram", "[CallService] PUSH: shared key already exists (${session.sharedKey.size}B)")
                        } else if (!session.isOutgoing) {
                            Hilog.info(0, "CjTelegram", "[CallService] PUSH: WARNING cannot compute shared key: dhA=${session.dhA.size}B dhP=${session.dhP.size}B")
                        }

                        // protocol:PhoneCallProtocol
                        parseProtocolToSession(d, session)

                        // connections:Vector<PhoneConnection>
                        parseConnectionsToSession(d, session)

                        Hilog.info(0, "CjTelegram", "[CallService] PUSH: parsed ${session.connections.size} connections, sharedKey=${session.sharedKey.size}B")
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[CallService] PUSH: active phoneCall connection parse error: ${e}")
                    }

                    session.state = "active"
                    session.startTime = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
                    session.signalBars = 4
                    this.startCallTimer(session)
                    // Phase K10: 启动 VoIP 引擎
                    this.startVoipEngine(session)
                }
                // phoneCallRequested#14b0ed0c (incoming)
                else if (callCtor == 0x14b0ed0c) {
                    Hilog.info(0, "CjTelegram", "[CallService] PUSH: incoming call")
                    let flags = d.readInt32()
                    let isVideo = (flags & (1 << 6)) != 0
                    let callId = d.readInt64()
                    let accessHash = d.readInt64()
                    let _date = d.readInt32()
                    let adminId = d.readInt64()
                    let _participantId = d.readInt64()
                    let gAHash = d.readBytes()
                    this.dispatchIncomingWithProtocol(d, callId, accessHash, adminId, isVideo, gAHash)
                }
            case None =>
                // 无活跃通话，检查来电
                if (callCtor == 0x14b0ed0c) {
                    let flags = d.readInt32()
                    let isVideo = (flags & (1 << 6)) != 0
                    let callId = d.readInt64()
                    let accessHash = d.readInt64()
                    let _date = d.readInt32()
                    let adminId = d.readInt64()
                    let _participantId = d.readInt64()
                    let gAHash = d.readBytes()
                    this.dispatchIncomingWithProtocol(d, callId, accessHash, adminId, isVideo, gAHash)
                }
        }
    }

    /**
     * 执行 phone.confirmCall
     * 
     * 在轮询循环的同一 spawn 中顺序调用，不会与 getState 并发
     */
    private func doConfirmCall(session: CallSession): Unit {
        try {
            let client = getMTProtoClient()
            let gB = session.dhGB
            let a = session.dhA
            let p = session.dhP
            let gA = session.dhGA

            if (gB.size == 0 || a.size == 0 || p.size == 0 || gA.size == 0) {
                Hilog.info(0, "CjTelegram", "[CallService] Missing DH params for confirmCall")
                session.state = "terminated"
                session.endReason = "error"
                return
            }

            Hilog.info(0, "CjTelegram", "[CallService] Computing shared key for confirmCall...")

            // key = gB^a mod p
            var key = BigIntMath.modPow(gB, a, p)

            // 确保 256 字节
            if (key.size > 256) {
                key = ByteUtils.slice(key, key.size - 256, key.size)
            } else if (key.size < 256) {
                let padded = Array<Byte>(256, repeat: 0)
                let offset = 256 - key.size
                var idx: Int64 = 0
                while (idx < key.size) {
                    padded[offset + idx] = key[idx]
                    idx = idx + 1
                }
                key = padded
            }
            session.sharedKey = key

            // keyFingerprint = last 8 bytes of SHA1(key)
            let keyHash = SHA1.hash(key)
            var fingerprint: Int64 = 0
            let hashLen = Int64(keyHash.size)
            var fi: Int64 = 0
            while (fi < 8 && (hashLen - 8 + fi) >= 0) {
                fingerprint = fingerprint | (Int64(UInt8(keyHash[hashLen - 8 + fi])) << Int32(fi * 8))
                fi = fi + 1
            }
            session.keyFingerprint = fingerprint

            // keyEmoji
            let keyPlusGA = ByteUtils.concat2(key, gA)
            let visualHash = SHA256.hash(keyPlusGA)
            session.keyEmoji = generateKeyEmojiFromHash(visualHash)

            Hilog.info(0, "CjTelegram", "[CallService] Sending phone.confirmCall...")

            let confirm = PhoneConfirmCall()
            confirm.callId = session.callId
            confirm.callAccessHash = session.accessHash
            confirm.gA = gA
            confirm.keyFingerprint = fingerprint
            // 版本协商：confirmCall 只回被叫选定的单一版本（对齐 iOS caller 1730 行为），
            // 避免被叫在 active 阶段又从全量列表里选出别的版本
            if (session.protocolVersion.size > 0) {
                confirm.libraryVersions.add(session.protocolVersion)
                Hilog.info(0, "CjTelegram", "[CallService] confirmCall echoing negotiated version '${session.protocolVersion}'")
            } else {
                Hilog.info(0, "CjTelegram", "[CallService] confirmCall: no negotiated version captured, sending default list")
            }

            let responseData = client.sendCallRequest(confirm.toBytes())

            if (responseData.size > 0) {
                // 检查 RPC error
                if (responseData.size >= 4) {
                    let checkD = TLDeserializer(responseData)
                    let checkCtor = checkD.readUInt32()
                    if (checkCtor == 0x2144ca19) {
                        let errCode = checkD.readInt32()
                        Hilog.info(0, "CjTelegram", "[CallService] RPC Error on confirmCall")
                        session.state = "terminated"
                        session.endReason = "error"
                        return
                    }
                }

                let response = PhoneCallResponse.deserialize(responseData)
                if (response.callType == "active") {
                    session.state = "active"
                    session.startTime = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
                    session.signalBars = 4

                    // 版本协商兜底：accepted 推送未解出版本时，用 active 响应回显的 protocol
                    if (session.protocolVersion.size == 0 && response.libraryVersions.size > 0) {
                        let chosen = this.pickImplementedVersion(response.libraryVersions)
                        if (chosen.size > 0) {
                            session.protocolVersion = chosen
                            if (response.maxLayer > 0) { session.maxLayer = response.maxLayer }
                            Hilog.info(0, "CjTelegram", "[CallService] Version from active response: '${chosen}'")
                        }
                    }

                    // Phase K6: 存储 connections 到 session
                    storeConnectionsFromResponse(session, response)

                    Hilog.info(0, "CjTelegram", "[CallService] >>> CALL CONFIRMED AND ACTIVE! <<<")
                    this.startCallTimer(session)
                    // Phase K10: 启动 VoIP 引擎
                    this.startVoipEngine(session)
                } else {
                    // confirmCall 成功但服务器返回的不是 active 状态（可能是 accepted）
                    // 等待 phoneCall(active) 推送到来
                    Hilog.info(0, "CjTelegram", "[CallService] confirmCall response callType='${response.callType}', waiting for active push")
                    var waitCount: Int64 = 0
                    while (waitCount < 10 && session.state == "confirming") {
                        sleep(Duration.second * 1)
                        waitCount = waitCount + 1
                    }
                    if (session.state == "confirming") {
                        session.state = "active"
                        session.startTime = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
                        session.signalBars = 4
                        Hilog.info(0, "CjTelegram", "[CallService] Call active (confirmCall sent successfully)")
                        this.startCallTimer(session)
                        // Phase K10: 启动 VoIP 引擎
                        this.startVoipEngine(session)
                    }
                }
            } else {
                session.state = "terminated"
                session.endReason = "disconnect"
                Hilog.info(0, "CjTelegram", "[CallService] No response from confirmCall")
            }
        } catch (_e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallService] confirmCall exception")
            session.state = "terminated"
            session.endReason = "error"
        }
    }

    /**
     * 接听来电
     */
    public func acceptCall(): Unit {
        let _ = this.acceptCallIfCurrent(0)
    }

    /**
     * Atomically accept only the session the UI rendered.
     * expectedCallId <= 0 preserves legacy callers that operate on the current ringing session.
     */
    public func acceptCallIfCurrent(expectedCallId: Int64): Bool {
        var target: Option<CallSession> = None
        synchronized(this._callSessionMonitor) {
            match (this._currentCall) {
                case Some(session) =>
                    if (session.state == "ringing" &&
                        (expectedCallId <= 0 || session.callId == expectedCallId)) {
                        session.state = "accepting"
                        target = Some(session)
                    }
                case None => ()
            }
        }
        match (target) {
            case Some(session) =>
                Hilog.info(0, "CjTelegram", "[CallService] Accepting incoming call id=${session.callId}")
                this.ensureMicrophonePermission()
                let _ = spawn { this.doAcceptCall(session) }
                return true
            case None =>
                Hilog.info(0, "CjTelegram", "[CallService] Ignore stale accept expected=${expectedCallId}")
                return false
        }
    }

    private func doAcceptCall(session: CallSession): Unit {
        try {
            let client = getMTProtoClient()
            let received = PhoneReceivedCall()
            received.callId = session.callId
            received.callAccessHash = session.accessHash
            let _ = client.sendCallRequest(received.toBytes())

            let (g, p) = getDhConfig()
            let b = ByteUtils.randomBytes(256)
            let gBytes = gToBytes(g)
            let gB = BigIntMath.modPow(gBytes, b, p)
            session.dhGB = gB

            // 关键修复：保存 b 和 p 到 session
            // 当 phone.acceptCall 响应不是 active（通常是 phoneCallAccepted），
            // 后续 phoneCall active 推送到达时需要 b 和 p 来计算共享密钥
            session.dhA = b    // 复用 dhA 字段存储被叫方私钥 b
            session.dhP = p    // 保存 DH 素数
            session.dhG = g    // 保存 DH 生成器
            Hilog.info(0, "CjTelegram", "[CallService] doAcceptCall: saved b(${b.size}B) and p(${p.size}B) to session")

            let accept = PhoneAcceptCall()
            accept.callId = session.callId
            accept.callAccessHash = session.accessHash
            accept.gB = gB
            // 版本协商（被叫侧）：只回选定的单一版本（对齐 iOS selectVersionOnAccept）
            if (session.protocolVersion.size > 0) {
                accept.libraryVersions.add(session.protocolVersion)
                Hilog.info(0, "CjTelegram", "[CallService] acceptCall with negotiated version '${session.protocolVersion}'")
            }

            let responseData = client.sendCallRequest(accept.toBytes())
            if (responseData.size > 0) {
                let response = PhoneCallResponse.deserialize(responseData)
                Hilog.info(0, "CjTelegram", "[CallService] doAcceptCall: response callType='${response.callType}' gA=${response.gA.size}B")
                if (response.callType == "active") {
                    let gA = response.gA
                    // 版本协商兜底（被叫）：来电解析未捕获主叫列表时，用 active 响应的 protocol
                    if (session.protocolVersion.size == 0 && response.libraryVersions.size > 0) {
                        let chosenV = this.pickImplementedVersion(response.libraryVersions)
                        if (chosenV.size > 0) {
                            session.protocolVersion = chosenV
                            if (response.maxLayer > 0) { session.maxLayer = response.maxLayer }
                            Hilog.info(0, "CjTelegram", "[CallService] Callee version from active response: '${chosenV}'")
                        }
                    }
                    // 验证 gAHash（安全检查）
                    if (session.dhGAHash.size > 0) {
                        let computedHash = SHA256.hash(gA)
                        if (!ByteUtils.equals(computedHash, session.dhGAHash)) {
                            Hilog.info(0, "CjTelegram", "[CallService] WARNING: gA hash mismatch!")
                        }
                    }
                    var key = BigIntMath.modPow(gA, b, p)
                    if (key.size > 256) { key = ByteUtils.slice(key, key.size - 256, key.size) }
                    else if (key.size < 256) {
                        let padded = Array<Byte>(256, repeat: 0)
                        let offset = 256 - key.size
                        var idx: Int64 = 0
                        while (idx < key.size) { padded[offset + idx] = key[idx]; idx = idx + 1 }
                        key = padded
                    }
                    session.sharedKey = key
                    let keyPlusGA = ByteUtils.concat2(key, gA)
                    session.keyEmoji = generateKeyEmojiFromHash(SHA256.hash(keyPlusGA))
                    Hilog.info(0, "CjTelegram", "[CallService] doAcceptCall: shared key computed (${key.size}B), state → active")
                    session.state = "active"
                    session.startTime = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
                    session.signalBars = 4
                    this.startCallTimer(session)
                    // Phase K10: 启动 VoIP 引擎
                    this.startVoipEngine(session)
                } else {
                    // phone.acceptCall 响应通常是 phoneCallAccepted（对方尚未 confirmCall）
                    // 共享密钥将在收到 phoneCall active 推送时计算（使用 session.dhA / dhP）
                    Hilog.info(0, "CjTelegram", "[CallService] doAcceptCall: response is '${response.callType}', waiting for active push (b/p saved)")
                    session.state = "accepting"
                }
            } else {
                session.state = "terminated"
                session.endReason = "error"
                Hilog.info(0, "CjTelegram", "[CallService] doAcceptCall: empty response")
            }
        } catch (_e: Exception) {
            session.state = "terminated"
            session.endReason = "error"
            Hilog.info(0, "CjTelegram", "[CallService] doAcceptCall: exception ${_e}")
        }
    }

    public func rejectCall(): Unit {
        let _ = this.rejectCallIfCurrent(0)
    }

    /**
     * Atomically reject only the session the UI rendered.
     */
    public func rejectCallIfCurrent(expectedCallId: Int64): Bool {
        var target: Option<CallSession> = None
        synchronized(this._callSessionMonitor) {
            match (this._currentCall) {
                case Some(session) =>
                    if (session.state == "ringing" &&
                        (expectedCallId <= 0 || session.callId == expectedCallId)) {
                        session.state = "terminated"
                        session.endReason = "rejected"
                        target = Some(session)
                    }
                case None => ()
            }
        }
        match (target) {
            case Some(session) =>
                discardCallSignaling(session, "busy")
                addToHistory(session)
                return true
            case None =>
                Hilog.info(0, "CjTelegram", "[CallService] Ignore stale reject expected=${expectedCallId}")
                return false
        }
    }

    public func endCall(): Unit {
        match (this._currentCall) {
            case Some(session) =>
                let prevState = session.state
                session.state = "terminated"
                session.endReason = "hangup"
                this._timerRunning = false
                // Phase K10: 停止 VoIP 引擎
                this.stopVoipEngine()
                addToHistory(session)
                // 补 accepting/reconnecting（均有有效 callId）：此前挂断在这两个态不发
                // discard → 对端要等自身 ~30s 超时才结束、一直显示 Reconnecting。
                // 对齐 iOS drop()：除 requesting（尚无 callId）外所有态都发 discard。
                if (prevState == "active" || prevState == "requested" || prevState == "requesting"
                    || prevState == "confirming" || prevState == "accepting" || prevState == "connecting"
                    || prevState == "reconnecting") {
                    discardCallSignaling(session, "hangup")
                }
            case None => ()
        }
    }

    public func clearCurrentCall(): Unit {
        this._timerRunning = false
        this.stopVoipEngine()
        this._currentCall = None
    }

    public func toggleMute(): Unit {
        match (this._currentCall) {
            case Some(s) =>
                s.isMuted = !s.isMuted
                // Phase K10: 转发静音到 VoIP 引擎
                match (this._voipContext) {
                    case Some(ctx) => ctx.setMuted(s.isMuted)
                    case None => ()
                }
            case None => ()
        }
    }

    public func toggleSpeaker(): Unit {
        match (this._currentCall) {
            case Some(s) =>
                s.isSpeaker = !s.isSpeaker
                match (this._voipContext) {
                    case Some(ctx) => ctx.setSpeaker(s.isSpeaker)
                    case None => ()
                }
                Hilog.info(0, "CjTelegram", "[CallService] toggleSpeaker: ${s.isSpeaker}")
            case None => ()
        }
    }

    public func setSpeakerMode(speaker: Bool): Unit {
        match (this._currentCall) {
            case Some(s) =>
                s.isSpeaker = speaker
                match (this._voipContext) {
                    case Some(ctx) => ctx.setSpeaker(speaker)
                    case None => ()
                }
            case None => ()
        }
    }

    public func toggleLocalVideo(): Unit {
        match (this.getCurrentCall()) {
            case Some(s) =>
                let _ = this.setLocalVideoEnabled(!s.isLocalVideoEnabled)
            case None => ()
        }
    }

    /**
     * Set an explicit desired camera state instead of toggling from a potentially stale UI copy.
     * Returns the authoritative state written to the current CallSession.
     */
    public func setLocalVideoEnabled(enabled: Bool): Bool {
        if (enabled) {
            this.ensureCameraPermission()
        }
        var applied = false
        synchronized(this._callSessionMonitor) {
            match (this._currentCall) {
                case Some(s) =>
                    if (enabled && !s.isVideo) { s.isVideo = true }
                    s.localVideoGeneration += 1
                    s.isLocalVideoEnabled = enabled
                    match (this._voipContext) {
                        case Some(ctx) => ctx.setVideoEnabled(enabled)
                        case None => ()
                    }
                    applied = enabled
                case None => ()
            }
        }
        if (applied == enabled) {
            Hilog.info(0, "CjTelegram", "[CallService] setLocalVideoEnabled: ${enabled}")
        }
        return applied
    }

    /**
     * VCALL-6: 翻转摄像头（前置/后置切换）
     * 使用真实 tgcalls_switch_camera C API，通过 VideoCaptureInterface::switchToDevice
     */
    public func flipCamera(): Unit {
        match (this._currentCall) {
            case Some(s) =>
                s.isFrontCamera = !s.isFrontCamera
                let deviceId = if (s.isFrontCamera) { "front" } else { "back" }
                match (this._voipContext) {
                    case Some(ctx) => ctx.switchCamera(deviceId)
                    case None => ()
                }
                Hilog.info(0, "CjTelegram", "[CallService] flipCamera: switched to ${deviceId}")
            case None => ()
        }
    }

    /**
     * VCALL-6: 设置远端视频帧回调 — 由 VideoCallScreen 注册
     * tgcalls 解码远端视频后通过此回调传递 I420 帧数据
     */
    public func setVideoOutput(onFrame: (Array<Byte>, Int32, Int32) -> Unit): Unit {
        this._videoFrameCallback = Some(onFrame)
        match (this._voipContext) {
            case Some(ctx) => ctx.setVideoOutput(onFrame)
            case None =>
                Hilog.info(0, "CjTelegram", "[CallService] setVideoOutput: no active VoIP context, callback stored for later")
        }
    }

    /**
     * VCALL-6: 清除远端视频帧回调
     */
    public func clearVideoOutput(): Unit {
        this._videoFrameCallback = None
    }

    /**
     * VCALL-8: 设置本地视频帧回调 — 由 VideoCallScreen PiP 注册
     */
    public func setLocalVideoOutput(onFrame: (Array<Byte>, Int32, Int32) -> Unit): Unit {
        this._localVideoFrameCallback = Some(onFrame)
        match (this._voipContext) {
            case Some(ctx) => ctx.setLocalVideoOutput(onFrame)
            case None =>
                Hilog.info(0, "CjTelegram", "[CallService] setLocalVideoOutput: no active VoIP context, callback stored for later")
        }
    }

    /**
     * VCALL-8: 清除本地视频帧回调
     */
    public func clearLocalVideoOutput(): Unit {
        this._localVideoFrameCallback = None
    }

    /**
     * P2-067: 设置音频电平回调 — 由 CallScreen 注册，驱动 blob 动画振幅
     *
     * 回调在 tgcalls audioLevel @C 回调线程上调用，非 UI 线程。
     * CallScreen 收到后需要通过 launch {} 更新 @State 字段（遵守 S-001）。
     * level 范围 [0.0, 1.0] Float32，映射自 tgcalls 引擎内部 RMS/峰值电平。
     */
    public func setAudioLevelCallback(cb: (Float32) -> Unit): Unit {
        this._audioLevelCallback = Some(cb)
        Hilog.info(0, "CjTelegram", "[CallService] P2-067 audioLevel callback registered")
    }

    /**
     * P2-067: 清除音频电平回调
     */
    public func clearAudioLevelCallback(): Unit {
        this._audioLevelCallback = None
        Hilog.info(0, "CjTelegram", "[CallService] P2-067 audioLevel callback cleared")
    }

    private func discardCallSignaling(session: CallSession, reason: String): Unit {
        let _ = spawn {
            try {
                let client = getMTProtoClient()
                let discard = PhoneDiscardCall()
                discard.callId = session.callId
                discard.callAccessHash = session.accessHash
                discard.duration = Int32(session.duration)
                discard.reason = reason
                discard.isVideo = session.isVideo
                let resp = client.sendCallRequest(discard.toBytes())
                // 本端挂断：响应 Updates 内含 phoneCallDiscarded(need_rating)——
                // 扫描提取评分标志（对齐 iOS dropCallSession 结果的 reportRating）
                if (resp.size > 0) {
                    let _ = this.scanForPhoneCallDiscarded(resp, session)
                }
            } catch (_e: Exception) { }
        }
    }

    private func startCallTimer(session: CallSession): Unit {
        // TL phoneCall(active) only means signaling setup completed. User-visible duration starts
        // when tgcalls first reaches Established, matching iOS PresentationCall semantics.
        if (!session.hasEverConnected) {
            return
        }
        if (this._timerRunning && this._timerCallId == session.callId) {
            return
        }
        this._timerEpoch += 1
        let epoch = this._timerEpoch
        this._timerCallId = session.callId
        this._timerRunning = true
        let _ = spawn {
            // Reconnecting after establishment continues counting (matching iOS).
            while (this._timerRunning && this._timerEpoch == epoch &&
                   (session.state == "active" || session.state == "reconnecting")) {
                sleep(Duration.second * 1)
                if (this._timerRunning && this._timerEpoch == epoch &&
                    (session.state == "active" || session.state == "reconnecting")) {
                    let now = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
                    session.duration = (now - session.startTime) / 1000
                }
            }
        }
    }

    private func addToHistory(session: CallSession): Unit {
        let record = CallRecord()
        record.id = session.callId
        record.peerId = session.peerId
        record.peerName = session.peerName
        record.peerAvatarPath = session.peerAvatarPath
        record.isOutgoing = session.isOutgoing
        // iOS parity: outgoing 通话即使对方未接也不算 missed（只有 incoming 未接才 missed/红）
        record.isMissed = !session.isOutgoing && session.endReason == "missed"
        record.mediaType = if (session.isVideo) { "video" } else { "voice" }
        record.isVideo = session.isVideo
        record.duration = formatCallDuration(session.duration)
        record.timestamp = "Just now"
        let newHistory = ArrayList<CallRecord>()
        newHistory.add(record)
        for (old in this._callHistory) { newHistory.add(old) }
        this._callHistory = newHistory
        this._callHistoryNeedsRefresh = true
        Hilog.info(0, "CjTelegram", "[CallService] addToHistory: ${record.peerName}, total=${newHistory.size}")
        notifyCallHistoryChanged()
    }

    /**
     * Resolve the incoming caller from the same peer sources used by the rest of the app.
     *
     * Telegram's phoneCallRequested update carries only adminId, not a display name. iOS stores
     * that id as the call peer and renders EnginePeer.displayTitle/avatar. The old Harmony path
     * passed the literal "Incoming Call", so both the in-app overlay and notification displayed
     * placeholder information even when the peer was already cached locally.
     */
    private func resolveIncomingPeerIdentity(adminId: Int64, fallbackName: String): (String, String) {
        var resolvedName = ""
        var avatarPath = ""

        // Postbox is the authoritative local peer source, matching iOS's EnginePeer lookup.
        match (getPeerStore().getLocalPeer(adminId)) {
            case Some(peer) =>
                resolvedName = peer.name
                avatarPath = peer.avatarLocalPath
            case None => ()
        }

        // Chat/contact loading may have a fresher in-memory name than Postbox. getCachedUser is
        // guarded by UserPhotoService.identityMonitor, so this read is safe on the MTProto thread.
        let photoService = getUserPhotoService()
        match (photoService.getCachedUser(adminId)) {
            case Some(user) =>
                var cachedName = user.firstName
                if (user.lastName.size > 0) {
                    cachedName = if (cachedName.size > 0) {
                        "${cachedName} ${user.lastName}"
                    } else {
                        user.lastName
                    }
                }
                if (cachedName.isEmpty() && user.username.size > 0) {
                    cachedName = "@${user.username}"
                }
                if (cachedName.size > 0) {
                    resolvedName = cachedName
                }
            case None => ()
        }
        let cachedAvatarPath = photoService.getUserPhotoPath(adminId)
        if (cachedAvatarPath.size > 0) {
            avatarPath = cachedAvatarPath
        }

        if (resolvedName.isEmpty() && fallbackName.size > 0 && fallbackName != "Incoming Call") {
            resolvedName = fallbackName
        }
        if (resolvedName.isEmpty()) {
            resolvedName = "User ${adminId}"
        }
        return (resolvedName, avatarPath)
    }

    public func handleIncomingCall(callId: Int64, accessHash: Int64, adminId: Int64,
                                    adminName: String, isVideo: Bool, gAHash: Array<Byte>): Unit {
        // Busy 守卫（audit P1-2）：已在通话中又来另一路来电时，此前无条件
        // _currentCall = 新 session → 覆盖活跃通话、旧 _voipContext 成孤儿、CallScreen
        // 界面突变。对齐 iOS（每通话独立 context、按 callId 去重、从不覆盖活跃通话）：
        // 对不同 callId 的并发来电回 busy 并 return，绝不动当前通话。
        // 用裸 discard 而非 discardCallSignaling（后者会扫描响应回写 _currentCall 状态、污染当前通话）。
        let (resolvedName, resolvedAvatarPath) = this.resolveIncomingPeerIdentity(adminId, adminName)
        let session = CallSession()
        session.callId = callId
        session.accessHash = accessHash
        session.peerId = adminId
        session.peerName = resolvedName
        session.peerAvatarPath = resolvedAvatarPath
        session.isVideo = isVideo
        session.isLocalVideoEnabled = isVideo
        session.isOutgoing = false
        session.state = "ringing"
        session.dhGAHash = gAHash

        var rejectAsBusy = false
        var duplicateUpdate = false
        var activeCallId: Int64 = 0
        var activeCallState = ""
        synchronized(this._callSessionMonitor) {
            match (this._currentCall) {
                case Some(cur) =>
                    if (cur.callId == callId && cur.state != "idle" && cur.state != "terminated") {
                        duplicateUpdate = true
                    } else if (cur.callId != callId && cur.state != "idle" && cur.state != "terminated") {
                        rejectAsBusy = true
                        activeCallId = cur.callId
                        activeCallState = cur.state
                    }
                case None => ()
            }
            if (!rejectAsBusy && !duplicateUpdate) {
                this._uiDismissClaimed = false  // 新通话重开 UI 收尾闸
                this._currentCall = Some(session)
            }
        }

        if (duplicateUpdate) {
            Hilog.info(0, "CjTelegram", "[CallService] Duplicate incoming update ignored id=${callId}")
            return
        }
        if (rejectAsBusy) {
            Hilog.info(0, "CjTelegram", "[CallService] Busy: incoming call ${callId} rejected (in call ${activeCallId} state=${activeCallState})")
            let rejId = callId
            let rejHash = accessHash
            let rejVideo = isVideo
            spawn {
                try {
                    let client = getMTProtoClient()
                    let discard = PhoneDiscardCall()
                    discard.callId = rejId
                    discard.callAccessHash = rejHash
                    discard.reason = "busy"
                    discard.isVideo = rejVideo
                    let _ = client.sendCallRequest(discard.toBytes())
                } catch (_e: Exception) {}
            }
            return
        }

        Hilog.info(0, "CjTelegram", "[CallService] Incoming call: id=${callId} peerId=${adminId} from=${resolvedName} avatar=${!resolvedAvatarPath.isEmpty()} video=${isVideo}")

        // Phase K5: 自动发送 phone.receivedCall 确认
        // 参考 Telegram-iOS CallSessionManager.swift:736-754
        // 通知服务器我们已收到来电，服务器会停止重复推送
        spawn {
            try {
                let client = getMTProtoClient()
                let receivedCall = PhoneReceivedCall()
                receivedCall.callId = callId
                receivedCall.callAccessHash = accessHash
                let _ = client.sendCallRequest(receivedCall.toBytes())
                Hilog.info(0, "CjTelegram", "[CallService] phone.receivedCall sent for callId=${callId}")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[CallService] Failed to send phone.receivedCall: ${e}")
            }
        }

        // 通知 UI 层显示来电界面（MainTabPage overlay——仅主页可见，保留作兜底）
        match (this._incomingCallCallback) {
            case Some(cb) =>
                Hilog.info(0, "CjTelegram", "[CallService] Notifying UI about incoming call")
                cb(session)
            case None =>
                Hilog.info(0, "CjTelegram", "[CallService] WARNING: No incoming call callback registered!")
        }

        // 全局全屏来电页（对齐 iOS：来电覆盖任意当前页面）。此前只有 MainTabPage
        // 内联 overlay，用户在聊天页/设置页等任何非主页时来电完全不可见。
        // 按 callId 去重：同一来电可能经 PUSH 与 RAW 两条路径各触发一次 handleIncomingCall。
        // ⚠️ routerPush/通知走 ark_interop，必须 launch 回主线程——本函数在 MTProto
        // 接收线程，直接调会 Thread mismatch 被外层 catch 吞掉（真机实锤:
        // "Pushing..." 后紧跟 "Failed to parse phoneCallRequested"，push 从未生效）。
        if (this._lastIncomingUiCallId != callId) {
            this._lastIncomingUiCallId = callId
            let notifName = resolvedName
            let notifCallId = callId
            let notifVideo = isVideo
            let notifAvatar = resolvedAvatarPath
            launch {
                Hilog.info(0, "CjTelegram", "[CallService] Pushing IncomingCallFullscreenPage (global, main thread)")
                if (isApplicationForeground()) {
                    // 前台：应用内全屏来电页直接可见，通知仅作铃声/记录
                    this.publishIncomingCallNotificationSafely(notifName, notifCallId)
                } else {
                    // 后台：app 无法自我置前。对齐 iOS CallKit（CallKitIntegration.swift:247-273
                    // reportNewIncomingCall）上报系统通话界面，由系统弹出带接听/拒绝的来电横幅；
                    // 系统不接受时退回通知（点通知回前台时全屏来电页已就位）。
                    this.reportIncomingCallToSystem(notifCallId, notifName, notifVideo, notifAvatar)
                }
                // Bind the destination to this exact call. The page rejects stale navigation if
                // the call ended or another session became current before ArkTS renders it.
                routerPush("IncomingCallFullscreenPage", "${notifCallId}")
            }
        }
    }

    private func publishIncomingCallNotificationSafely(name: String, callId: Int64): Unit {
        try {
            let _ = getLocalNotificationDisplayService().publishIncomingCallNotification(name, "${callId}")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallService] incoming call notification failed: ${e}")
        }
    }

    // ==================== 系统通话界面（Call Service Kit voipCall ≙ iOS CallKit）====================

    /** 主线程调用（callArkAsync 需要 JS scope）。 */
    private func reportIncomingCallToSystem(callId: Int64, name: String, isVideo: Bool, avatarPath: String): Unit {
        this.ensureVoipUiEventSubscription()
        synchronized(this._voipMonitor) {
            this._voipReportedCallId = callId
            this._voipAnsweredCallId = 0
        }
        let arg = "{\"callId\":\"${callId}\",\"name\":\"${escapeJsonString(name)}\",\"isVideo\":${isVideo},\"avatarPath\":\"${escapeJsonString(avatarPath)}\"}"
        callArkAsync(VOIP_REPORT_INCOMING, arg, { res: String =>
            let obj = JsonParser.parseObject(res)
            if (obj.getBool("ok")) {
                Hilog.info(0, "CjTelegram", "[CallService] incoming call ${callId} reported to system call UI")
                let _ = spawn { this.voipStateWatcher(callId, isVideo) }
            } else {
                Hilog.info(0, "CjTelegram", "[CallService] system call UI unavailable (reason=${obj.getInt("reason")} err=${obj.getString("err")}) → notification")
                synchronized(this._voipMonitor) {
                    if (this._voipReportedCallId == callId) { this._voipReportedCallId = 0 }
                }
                this.publishIncomingCallNotificationSafely(name, callId)
            }
        })
    }

    /**
     * 把应用侧通话状态同步给系统通话界面：接通 → ACTIVE，结束/被替换 → DISCONNECTED
     * （iOS CallKitIntegration reportCall(with:endedAt:reason:)，:199）。
     */
    private func voipStateWatcher(callId: Int64, isVideo: Bool): Unit {
        var reportedActive = false
        while (true) {
            sleep(Duration.millisecond * 500)
            var same = false
            var state = ""
            match (this.getCurrentCall()) {
                case Some(c) =>
                    same = c.callId == callId
                    state = c.state
                case None => ()
            }
            if (!same || state == "terminated" || state == "idle") {
                this.reportVoipState(callId, isVideo, 4)
                synchronized(this._voipMonitor) {
                    if (this._voipReportedCallId == callId) { this._voipReportedCallId = 0 }
                    if (this._voipAnsweredCallId == callId) { this._voipAnsweredCallId = 0 }
                }
                return
            }
            if (!reportedActive && state != "ringing") {
                this.reportVoipState(callId, isVideo, 2)
                reportedActive = true
            }
        }
    }

    private func reportVoipState(callId: Int64, isVideo: Bool, state: Int64): Unit {
        Hilog.info(0, "CjTelegram", "[CallService] system call UI state call=${callId} → ${state}")
        callArkOnJSTask(VOIP_REPORT_STATE, "{\"callId\":\"${callId}\",\"state\":${state},\"isVideo\":${isVideo}}", { _ => () })
    }

    private func ensureVoipUiEventSubscription(): Unit {
        synchronized(this._voipMonitor) {
            if (this._voipEventsSubscribed) { return }
            this._voipEventsSubscribed = true
        }
        subscribe(EVT_VOIP_UI_EVENT, { payload: String =>
            let obj = JsonParser.parseObject(payload)
            let callId = match (Int64.tryParse(obj.getString("callId"))) {
                case Some(v) => v
                case None => 0
            }
            let event = obj.getInt("event")
            if (callId != 0) {
                let _ = spawn { this.handleVoipUiEvent(callId, event) }
            }
        })
    }

    /**
     * 系统通话界面上的用户操作（voipCall.VoipCallUiEvent）→ 应用通话动作。
     * iOS 对位 CXProviderDelegate：CXAnswerCallAction → answer，CXEndCallAction → end/decline，
     * CXSetMutedCallAction → mute。
     */
    private func handleVoipUiEvent(callId: Int64, event: Int64): Unit {
        Hilog.info(0, "CjTelegram", "[CallService] system call UI event ${event} for call ${callId}")
        var state = ""
        var isCurrent = false
        var muted = false
        match (this.getCurrentCall()) {
            case Some(c) =>
                isCurrent = c.callId == callId
                state = c.state
                muted = c.isMuted
            case None => ()
        }
        if (!isCurrent) { return }
        if (event == 1 || event == 2) {
            // VOICE_ANSWER / VIDEO_ANSWER：由全屏来电页据此换成通话页
            synchronized(this._voipMonitor) { this._voipAnsweredCallId = callId }
            if (!this.acceptCallIfCurrent(callId)) {
                synchronized(this._voipMonitor) { this._voipAnsweredCallId = 0 }
            }
        } else if (event == 3 || event == 4) {
            // REJECT / HANGUP
            if (state == "ringing") {
                let _ = this.rejectCallIfCurrent(callId)
            } else if (state != "terminated" && state != "idle") {
                this.endCall()
            }
        } else if (event == 5 || event == 6) {
            // MUTED / UNMUTED
            let wantMuted = event == 5
            if (muted != wantMuted) { this.toggleMute() }
        } else if (event == 7 || event == 8) {
            this.setSpeakerMode(event == 7)
        }
    }

    /** 全屏来电页：该来电是否是在系统通话界面上接听的（取出即清除）。 */
    public func takeAnsweredFromSystemUi(callId: Int64): Bool {
        synchronized(this._voipMonitor) {
            if (this._voipAnsweredCallId == callId && callId != 0) {
                this._voipAnsweredCallId = 0
                return true
            }
        }
        return false
    }

    // ==================== Phase K5: 信令数据交换 ====================

    /**
     * 处理 updatePhoneCallSignalingData#2661bf09
     * phone_call_id:long data:bytes
     * 
     * 参考: Telegram-iOS CallSessionManager.swift:1300-1318
     * 将接收到的信令数据入队，若有回调则立即分发
     */
    private func handleSignalingDataUpdate(d: TLDeserializer): Unit {
        try {
            let phoneCallId = d.readInt64()
            let sigData = d.readBytes()
            Hilog.info(0, "CjTelegram", "[CallService] updatePhoneCallSignalingData: callId=${phoneCallId}, ${sigData.size} bytes")

            // 验证是否属于当前通话
            match (this._currentCall) {
                case Some(session) =>
                    if (session.callId == phoneCallId) {
                        deliverSignalingData(sigData)
                    } else {
                        Hilog.info(0, "CjTelegram", "[CallService] Signaling data for unknown callId=${phoneCallId}, current=${session.callId}")
                    }
                case None =>
                    Hilog.info(0, "CjTelegram", "[CallService] Signaling data received but no active call")
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallService] Failed to parse signaling data update: ${e}")
        }
    }

    /**
     * 分发信令数据：若有回调则立即分发，否则入队等待
     */
    private func deliverSignalingData(data: Array<Byte>): Unit {
        match (this._signalingDataCallback) {
            case Some(callback) =>
                callback(data)
            case None =>
                // VoIP 层尚未注册回调，入队等待
                this._signalingDataQueue.add(data)
                Hilog.info(0, "CjTelegram", "[CallService] Signaling data queued (total: ${this._signalingDataQueue.size})")
        }
    }

    /**
     * 注册信令数据接收回调 — 由 VoIP 层 (OngoingCallContext) 调用
     * 注册时会立即分发队列中所有已缓存的数据
     * 
     * 参考: Telegram-iOS CallSessionManager.beginReceivingCallSignalingData
     */
    public func registerSignalingDataCallback(callback: (Array<Byte>) -> Unit): Unit {
        this._signalingDataCallback = Some(callback)
        // 分发队列中已有的数据
        for (data in this._signalingDataQueue) {
            callback(data)
        }
        this._signalingDataQueue.clear()
        Hilog.info(0, "CjTelegram", "[CallService] Signaling data callback registered")
    }

    /**
     * 取消注册信令数据回调
     */
    public func unregisterSignalingDataCallback(): Unit {
        this._signalingDataCallback = None
        Hilog.info(0, "CjTelegram", "[CallService] Signaling data callback unregistered")
    }

    // ==================== Phase K6: 连接管理 ====================

    /**
     * 从 PhoneCallResponse 解析 connections 存储到 session
     * 
     * 参考: Telegram-iOS CallSessionManager.swift:269-361 (CallSessionConnection)
     */
    private func storeConnectionsFromResponse(session: CallSession, response: PhoneCallResponse): Unit {
        session.connections.clear()
        for (conn in response.connections) {
            let endpoint = ConnectionEndpoint()
            endpoint.id = conn.id
            endpoint.ip = conn.ip
            endpoint.ipv6 = conn.ipv6
            endpoint.port = conn.port
            endpoint.peerTag = conn.peerTag
            endpoint.isWebrtc = conn.isWebrtc
            endpoint.username = conn.username
            endpoint.password = conn.password
            endpoint.hasTurn = conn.turn
            endpoint.hasStun = conn.stun
            session.connections.add(endpoint)
        }
        Hilog.info(0, "CjTelegram", "[CallService] Stored ${session.connections.size} connections from response")
        for (ep in session.connections) {
            let connType = if (ep.isWebrtc) { "webrtc" } else { "reflector" }
            Hilog.info(0, "CjTelegram", "[CallService]   conn id=${ep.id}, type=${connType}, ip=${ep.ip}:${ep.port}")
        }
    }

    /**
     * 从 TLDeserializer 解析 PhoneCallProtocol 存入 session
     * 
     * TL: phoneCallProtocol#fc878fc8 flags:# udp_p2p:flags.0 udp_reflector:flags.1
     *     min_layer:int max_layer:int library_versions:Vector<string>
     */
    private func parseProtocolToSession(d: TLDeserializer, session: CallSession): Unit {
        let constructor = d.readUInt32()
        if (constructor == 0xfc878fc8) {
            let flags = d.readInt32()
            let minLayer = d.readInt32()
            let maxLayer = d.readInt32()
            session.minLayer = minLayer
            session.maxLayer = maxLayer
            // library_versions vector — collect ALL versions from the peer
            let vecCtor = d.readUInt32()
            var peerVersions = ArrayList<String>()
            if (vecCtor == 0x1cb5c415) {  // vector#1cb5c415
                let count = d.readInt32()
                var i: Int64 = 0
                while (i < Int64(count)) {
                    let ver = d.readString()
                    peerVersions.add(ver)
                    i = i + 1
                }
            }

            // 版本协商修复：只能选我方真正实现的版本（统一走 pickImplementedVersion）。
            // 旧列表含 11.0.0/10.0.0（ReferenceImpl）与 5.0.0/2.7.7（InstanceImpl）——均未编译；
            // 且"回退用对端第一个版本"可能选中未实现版本 → Meta::Create 失败/信令互不可解。
            let negotiated = this.pickImplementedVersion(peerVersions)
            if (negotiated.size > 0) {
                session.protocolVersion = negotiated
            }

            Hilog.info(0, "CjTelegram", "[CallService] Protocol: negotiated='${session.protocolVersion}' peerVersions=${peerVersions.size} layer=${minLayer}-${maxLayer}")
        }
    }

    /**
     * 从 TLDeserializer 解析 connections Vector<PhoneConnection> 存入 session
     */
    private func parseConnectionsToSession(d: TLDeserializer, session: CallSession): Unit {
        session.connections.clear()
        let vecCtor = d.readUInt32()
        if (vecCtor == 0x1cb5c415) {  // vector#1cb5c415
            let count = d.readInt32()
            var i: Int64 = 0
            while (i < Int64(count)) {
                let connCtor = d.readUInt32()
                let endpoint = ConnectionEndpoint()

                if (connCtor == 0x9cc123c7) {
                    // phoneConnection#9cc123c7 flags:# tcp:flags.0 id:long ip:string ipv6:string port:int peer_tag:bytes
                    let flags = d.readInt32()
                    endpoint.isTcp = (flags & 1) != 0
                    endpoint.id = d.readInt64()
                    endpoint.ip = d.readString()
                    endpoint.ipv6 = d.readString()
                    endpoint.port = d.readInt32()
                    endpoint.peerTag = d.readBytes()
                    session.connections.add(endpoint)
                } else if (connCtor == 0x635fe375) {
                    // phoneConnectionWebrtc#635fe375 flags:# turn:flags.0 stun:flags.1
                    //   id:long ip:string ipv6:string port:int username:string password:string
                    let flags = d.readInt32()
                    endpoint.isWebrtc = true
                    endpoint.hasTurn = (flags & 1) != 0
                    endpoint.hasStun = (flags & 2) != 0
                    endpoint.id = d.readInt64()

                    // === DIAGNOSTIC: dump raw hex at ip field position ===
                    let ipOffset = d.getOffset()
                    let ipHex = d.dumpHex(64)
                    Hilog.info(0, "CjTelegram", "[parseConn] WebRTC id=${endpoint.id} flags=${flags}")
                    Hilog.info(0, "CjTelegram", "[parseConn] ip@offset=${ipOffset} hex: ${ipHex}")

                    endpoint.ip = d.readString()
                    Hilog.info(0, "CjTelegram", "[parseConn] ip='${endpoint.ip}' (${endpoint.ip.size}ch), nextOff=${d.getOffset()}")

                    endpoint.ipv6 = d.readString()
                    Hilog.info(0, "CjTelegram", "[parseConn] ipv6='${endpoint.ipv6}' (${endpoint.ipv6.size}ch), nextOff=${d.getOffset()}")

                    endpoint.port = d.readInt32()
                    Hilog.info(0, "CjTelegram", "[parseConn] port=${endpoint.port}")

                    endpoint.username = d.readString()
                    Hilog.info(0, "CjTelegram", "[parseConn] user='${endpoint.username}' (${endpoint.username.size}ch)")

                    endpoint.password = d.readString()
                    Hilog.info(0, "CjTelegram", "[parseConn] pass='${endpoint.password.size}ch'")

                    session.connections.add(endpoint)
                } else {
                    Hilog.info(0, "CjTelegram", "[CallService] Unknown connection ctor: 0x${UInt32ToHex(connCtor)}")
                }
                i = i + 1
            }
        }
    }

    /**
     * 发送信令数据 — 通过 MTProto phone.sendSignalingData 传输
     * 由 VoIP 层在 tgcalls signalingDataEmitted 时调用
     * 
     * 参考: Telegram-iOS CallSessionManager.swift:1017-1025
     */
    public func sendSignalingData(data: Array<Byte>): Unit {
        match (this._currentCall) {
            case Some(session) =>
                Hilog.info(0, "CjTelegram", "[CallService] sendSignalingData: ${data.size} bytes, state='${session.state}'")
                // 关键修复（真机死锁）：信令在整个"通话进行中"期间都必须放行，
                // 即 connecting、active 与 reconnecting 都要发。tgcalls 启动后先进入
                // Reconnecting（握手中），UI 映射为 connecting。若只在 "active"
                // 才发，就会把 tgcalls 的握手包全丢掉 → 对方收不到 → 永远连不上 → 一直 reconnecting，
                // 形成死锁。收发两道闸门必须一致放开 reconnecting。
                if (session.state == "connecting" || session.state == "active" || session.state == "reconnecting") {
                    // 串行化：入队，仅在无 worker 时拉起一个（并发=1，保序）
                    this._sigSendMutex.lock()
                    this._sigSendQueue.add(data)
                    let needWorker = !this._sigSenderRunning
                    if (needWorker) { this._sigSenderRunning = true }
                    this._sigSendMutex.unlock()
                    if (needWorker) {
                        let _ = spawn { this.drainSignalingSendQueue() }
                    }
                } else {
                    Hilog.info(0, "CjTelegram", "[CallService] sendSignalingData DROPPED: state is '${session.state}', not live")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[CallService] sendSignalingData DROPPED: no current call")
        }
    }

    /**
     * 出向信令发送 worker：批量取空队列后退出（下个包到来时再拉起）。
     * 整批交换（swap）队列避免逐个 remove；包间严格串行 sendRequest。
     */
    private func drainSignalingSendQueue(): Unit {
        while (true) {
            this._sigSendMutex.lock()
            if (this._sigSendQueue.size == 0) {
                this._sigSenderRunning = false
                this._sigSendMutex.unlock()
                break
            }
            let batch = this._sigSendQueue
            this._sigSendQueue = ArrayList<Array<Byte>>()
            this._sigSendMutex.unlock()

            match (this.getCurrentCall()) {
                case Some(s) =>
                    if (s.state != "connecting" && s.state != "active" && s.state != "reconnecting") {
                        continue  // 通话已结束，丢弃残留包
                    }
                    try {
                        // iOS starts every phone.sendSignalingData request asynchronously. Sending
                        // them one-by-one and waiting for each RPC response added ~200ms per packet
                        // (6s for a normal video handshake). Preserve packet boundaries/order but
                        // put the whole drained batch into one MTProto msg_container.
                        let requests = ArrayList<Array<Byte>>()
                        var totalBytes: Int64 = 0
                        for (pkt in batch) {
                            let req = PhoneSendSignalingData()
                            req.callId = s.callId
                            req.callAccessHash = s.accessHash
                            req.data = pkt
                            requests.add(req.toBytes())
                            totalBytes += pkt.size
                        }
                        let results = getMTProtoClient().sendBatchedRPCRequests(requests)
                        Hilog.info(0, "CjTelegram", "[CallService] Signaling batch sent: packets=${requests.size} bytes=${totalBytes} responses=${results.size}")
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[CallService] Signaling batch failed: ${e}")
                    }
                case None => ()
            }
        }
    }

    // ==================== Phase K10: VoIP 引擎集成 ====================

    /**
     * 确保 MICROPHONE 权限已授权 — VoIP 音频必需
     * OHOS 的 ohos.permission.MICROPHONE 是 user_grant 权限，
     * 仅在 module.json5 中声明不够，必须在运行时请求。
     * 如果未授权，libohaudio.so 的 AudioCapturer 创建会失败，
     * 导致整个音频设备（含 Renderer）回退到 stub 模式（静音）。
     */
    public func ensureMicrophonePermission(): Unit {
        try {
            let atManager = AbilityAccessCtrl.createAtManager()
            let bundleInfo = BundleManager.getBundleInfoForSelf(BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
            let tokenID = bundleInfo.appInfo.accessTokenId

            let granted = atManager.checkAccessToken(tokenID, "ohos.permission.MICROPHONE")
            if (granted == GrantStatus.PermissionGranted) {
                Hilog.info(0, "CjTelegram", "[CallService] MICROPHONE permission already granted")
                return
            }

            Hilog.info(0, "CjTelegram", "[CallService] MICROPHONE permission NOT granted, requesting...")
            match (getGlobalAbilityContext()) {
                case Some(context) =>
                    let permissions: Array<String> = ["ohos.permission.MICROPHONE"]
                    atManager.requestPermissionsFromUser(
                        context,
                        permissions,
                        { errorCode: Option<BusinessException>, data: Option<PermissionRequestResult> =>
                            match (errorCode) {
                                case Some(e) =>
                                    Hilog.info(0, "CjTelegram", "[CallService] MICROPHONE requestPermission error: ${e.message}")
                                case _ =>
                                    match (data) {
                                        case Some(result) =>
                                            for (i in 0..result.authResults.size) {
                                                if (result.authResults[i] == 0) {
                                                    Hilog.info(0, "CjTelegram", "[CallService] MICROPHONE permission GRANTED by user")
                                                } else {
                                                    Hilog.info(0, "CjTelegram", "[CallService] MICROPHONE permission DENIED by user")
                                                }
                                            }
                                        case _ =>
                                            Hilog.info(0, "CjTelegram", "[CallService] MICROPHONE requestPermission: no result")
                                    }
                            }
                        }
                    )
                case _ =>
                    Hilog.info(0, "CjTelegram", "[CallService] No UIAbilityContext, cannot request MICROPHONE permission")
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallService] ensureMicrophonePermission error: ${e}")
        }
    }

    public func ensureCameraPermission(): Unit {
        try {
            let atManager = AbilityAccessCtrl.createAtManager()
            let bundleInfo = BundleManager.getBundleInfoForSelf(BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
            let tokenID = bundleInfo.appInfo.accessTokenId

            let granted = atManager.checkAccessToken(tokenID, "ohos.permission.CAMERA")
            if (granted == GrantStatus.PermissionGranted) {
                Hilog.info(0, "CjTelegram", "[CallService] CAMERA permission already granted")
                return
            }

            Hilog.info(0, "CjTelegram", "[CallService] CAMERA permission NOT granted, requesting...")
            match (getGlobalAbilityContext()) {
                case Some(context) =>
                    let permissions: Array<String> = ["ohos.permission.CAMERA"]
                    atManager.requestPermissionsFromUser(
                        context,
                        permissions,
                        { errorCode: Option<BusinessException>, data: Option<PermissionRequestResult> =>
                            match (errorCode) {
                                case Some(e) =>
                                    Hilog.info(0, "CjTelegram", "[CallService] CAMERA requestPermission error: ${e.message}")
                                case _ =>
                                    match (data) {
                                        case Some(result) =>
                                            for (i in 0..result.authResults.size) {
                                                if (result.authResults[i] == 0) {
                                                    Hilog.info(0, "CjTelegram", "[CallService] CAMERA permission GRANTED")
                                                } else {
                                                    Hilog.info(0, "CjTelegram", "[CallService] CAMERA permission DENIED by user")
                                                }
                                            }
                                        case _ =>
                                            Hilog.info(0, "CjTelegram", "[CallService] CAMERA requestPermission: no result")
                                    }
                            }
                        }
                    )
                case _ =>
                    Hilog.info(0, "CjTelegram", "[CallService] No UIAbilityContext, cannot request CAMERA permission")
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallService] ensureCameraPermission error: ${e}")
        }
    }

    /**
     * 启动 VoIP 引擎 — 当通话进入 active 状态时调用
     * 
     * 参考: Telegram-iOS OngoingCallContext 创建时机
     * 1. 创建 OngoingCallContext
     * 2. 注册信令数据回调 (MTProto → tgcalls)
     * 3. 注册 tgcalls 状态回调
     * 4. 启动引擎
     */
    private func startVoipEngine(session: CallSession): Unit {
        Hilog.info(0, "CjTelegram", "[CallService] >>>>>> startVoipEngine callId=${session.callId} isVideo=${session.isVideo} sym=[vo=${TgCallsLib._has_video_output},sc=${TgCallsLib._has_switch_camera},rm=${TgCallsLib._has_remote_media_state_cb},lv=${TgCallsLib._has_local_video_output}] <<<<<<")

        this.ensureMicrophonePermission()
        if (session.isVideo) {
            this.ensureCameraPermission()
        }

        // 创建 OngoingCallContext
        let ctx = OngoingCallContext(session, { data: Array<Byte> =>
            // tgcalls 需要发送信令数据 → 通过 MTProto 发送
            this.sendSignalingData(data)
        })

        // 注册状态回调
        ctx.onStateChanged({ state: VoipState =>
                let stateStr = match (state) {
                    case VoipState.Established => "Established"
                    case VoipState.Failed => "Failed"
                    case VoipState.Reconnecting => "Reconnecting"
                    case VoipState.WaitInit => "WaitInit"
                    case VoipState.WaitInitAck => "WaitInitAck"
                }
                Hilog.info(0, "CjTelegram", "[CallService] VoIP state: %{public}s", [stateStr])
                // P2-057: 映射 VoIP 状态到 session.state
                match (state) {
                    case VoipState.Reconnecting =>
                        // tgcalls uses Reconnecting for both the initial handshake and a real
                        // post-establishment network drop. iOS presents the former as Connecting.
                        session.state = if (session.hasEverConnected) { "reconnecting" } else { "connecting" }
                        // 30s 看门狗：仍未建立/恢复则按 disconnect 结束。
                        this._reconnectingEpoch += 1
                        let ep = this._reconnectingEpoch
                        let _ = spawn {
                            sleep(Duration.second * 30)
                            if (ep == this._reconnectingEpoch &&
                                (session.state == "connecting" || session.state == "reconnecting")) {
                                Hilog.info(0, "CjTelegram", "[CallService] connection timeout (30s) → drop call as disconnect")
                                session.state = "terminated"
                                session.endReason = "disconnect"
                                this._timerRunning = false
                                this.stopVoipEngine()
                                discardCallSignaling(session, "disconnect")
                                addToHistory(session)
                            }
                        }
                    case VoipState.Established =>
                        this._reconnectingEpoch += 1  // 使挂起的 reconnecting 看门狗失效
                        if (!session.hasEverConnected) {
                            session.hasEverConnected = true
                            session.startTime = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
                            session.duration = 0
                        }
                        if (session.state == "connecting" || session.state == "reconnecting") {
                            session.state = "active"
                        }
                        this.startCallTimer(session)
                    case VoipState.Failed =>
                        if (session.state == "connecting" || session.state == "active" || session.state == "reconnecting") {
                            session.state = "terminated"
                            session.endReason = "disconnect"
                            this._timerRunning = false
                            this.stopVoipEngine()
                            addToHistory(session)
                        }
                    case _ => ()
                }
        })

        // 注册信号强度回调
        ctx.onSignalBars({ bars: Int32 =>
            session.signalBars = bars
        })

        // P2-067: 注册音频电平回调 — 驱动 blob 动画振幅
        // 回调在 C FFI 线程上，UI 侧需 launch {} 包装 @State 更新 (S-001)
        ctx.onAudioLevel({ level: Float32 =>
            match (this._audioLevelCallback) {
                case Some(cb) => cb(level)
                case None => ()
            }
        })

        // ── tgcalls V1 引擎门控（2026-07-20 Mate60 真机段错误修复）──
        // libtgcalls_ohos.so 当前用树内 dummy AudioDeviceModule（第四步交付说明）；真机上
        // dummy ADM 被真实音频子系统调用时 NULL 解引用 → tgc-media 线程 SIGSEGV 闪退。
        // OHAudio 真 ADM 属第五步。在其就绪前，门控关闭引擎启动：信令/振铃/挂断/计时/UI
        // 全保留（通话流程可走通、可结束），仅不拉起会崩的 dummy 媒体引擎（无声）。
        // 打开开关（第五步接好 OHAudio ADM 后）即恢复真实媒体。
        if (!VOIP_MEDIA_ENGINE_ENABLED) {
            Hilog.info(0, "CjTelegram", "[CallService] VoIP media engine gated OFF (V1: dummy ADM segfaults on device); signaling-only call")
            return
        }

        // 启动引擎
        let started = ctx.start()
        if (started) {
            this._voipContext = Some(ctx)

            // 注册信令数据接收回调 — MTProto → tgcalls
            this.registerSignalingDataCallback({ data: Array<Byte> =>
                ctx.receiveSignaling(data)
            })

            // Phase P6-9: 注册远端媒体状态回调
            ctx.setRemoteMediaStateCallback({ audioState: Int32, videoState: Int32 =>
                // videoState 枚举对齐 tgcalls VideoState: 0=Inactive, 1=Paused, 2=Active
                // （此前注释/判断把 1 当 active——iOS 发视频时上报 2 被判 false，
                // 轮询每 500ms 把 UI 的 isRemoteVideoActive 压回 false 与帧回调拉锯，
                // UI 状态 30fps 抖动把本地 PiP 更新饿死——真机 17:42 日志实锤）
                session.isRemoteVideoEnabled = videoState == 2
                // 对方静音提示（此前 audioState 只打日志、从不赋值 → CallScreen 的
                // "%name%'s microphone is turned off" 永不显示）。tgcalls AudioState
                // Muted=0/Active=1，对齐 iOS remoteAudioState==.muted。
                session.isRemoteMicOff = audioState == 0
                Hilog.info(0, "CjTelegram", "[CallService] Remote media: audio=${audioState} video=${videoState}")
            })

            // VCALL-6: 注册远端视频输出（tgcalls → I420 帧 → Cangjie 回调）
            Hilog.info(0, "CjTelegram", "[CallService] Registering remote video output callback...")
            ctx.setVideoOutput({ frameData: Array<Byte>, width: Int32, height: Int32 =>
                match (this._videoFrameCallback) {
                    case Some(cb) => cb(frameData, width, height)
                    case None =>
                        Hilog.info(0, "CjTelegram", "[CallService] REMOTE frame received but no UI callback registered! ${width}x${height} size=${frameData.size}")
                }
            })

            // 启用视频捕获（如果是视频通话）
            Hilog.info(0, "CjTelegram", "[CallService] session.isVideo=${session.isVideo}")
            if (session.isVideo) {
                Hilog.info(0, "CjTelegram", "[CallService] Enabling video capture...")
                ctx.setVideoAspect(Float32(0.5625))  // 9:16 portrait

                // VCALL-8: Register local output before enabling capture. On physical devices,
                // enabling first can create the capturer without an attached sink; it then emits
                // no preview until an off/on toggle rebuilds the pipeline.
                Hilog.info(0, "CjTelegram", "[CallService] Registering local video output callback...")
                let localCb = { frameData: Array<Byte>, width: Int32, height: Int32 =>
                    match (this._localVideoFrameCallback) {
                        case Some(cb) => cb(frameData, width, height)
                        case None =>
                            Hilog.info(0, "CjTelegram", "[CallService] LOCAL frame received but no UI callback registered! ${width}x${height} size=${frameData.size}")
                    }
                }
                var retryGenerationValue: Int64 = 0
                synchronized(this._callSessionMonitor) {
                    retryGenerationValue = session.localVideoGeneration
                    ctx.setLocalVideoOutput(localCb)
                    ctx.setVideoEnabled(session.isLocalVideoEnabled)
                }
                let retryGeneration = retryGenerationValue

                // Re-apply both sink and desired state after the native capturer initializes.
                let _ = spawn {
                    sleep(Duration.millisecond * 500)
                    Hilog.info(0, "CjTelegram", "[CallService] Re-applying local video pipeline (500ms retry)")
                    synchronized(this._callSessionMonitor) {
                        if (session.localVideoGeneration == retryGeneration) {
                            ctx.setLocalVideoOutput(localCb)
                            ctx.setVideoEnabled(session.isLocalVideoEnabled)
                        }
                    }
                    sleep(Duration.second * 2)
                    Hilog.info(0, "CjTelegram", "[CallService] Re-applying local video pipeline (2.5s retry)")
                    synchronized(this._callSessionMonitor) {
                        if (session.localVideoGeneration == retryGeneration) {
                            ctx.setLocalVideoOutput(localCb)
                            ctx.setVideoEnabled(session.isLocalVideoEnabled)
                        }
                    }
                }

                Hilog.info(0, "CjTelegram", "[CallService] Video enabled for video call, hasVideoFrameCb=${this.hasVideoFrameCallback()}, hasLocalVideoFrameCb=${this.hasLocalVideoFrameCallback()}")
            }

            Hilog.info(0, "CjTelegram", "[CallService] VoIP engine started successfully")
        } else {
            Hilog.info(0, "CjTelegram", "[CallService] Failed to start VoIP engine")
        }
    }

    /**
     * 停止 VoIP 引擎 — 当通话结束时调用
     */
    private func stopVoipEngine(): Unit {
        match (this._voipContext) {
            case Some(ctx) =>
                Hilog.info(0, "CjTelegram", "[CallService] Stopping VoIP engine")
                this.unregisterSignalingDataCallback()
                // P2-067: 清除音频电平回调，防止悬空引用
                ctx.clearAudioLevelCallback()
                ctx.stop()
                this._voipContext = None
            case None => ()
        }
    }

    // ==================== P2-322: Call Data Saving Mode ====================
    // 0 = never, 1 = cellular only, 2 = always
    // Stored via Preferences in "call_settings" store.
    // If context not ready, falls back to in-memory value (per-session).
    private var _callDataSavingMode: Int32 = 0

    /**
     * Read call data saving mode from Preferences (lazy, fallback to memory).
     * Returns: 0=never, 1=cellular, 2=always (mirrors iOS VoiceCallDataSaving enum)
     */
    public func getCallDataSavingMode(): Int32 {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "call_settings")
                    let val = prefs.get("call_data_saving_mode", PreferencesValueType.Integer(0))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return this._callDataSavingMode
                    }
                } catch (_e: Exception) {
                    return this._callDataSavingMode
                }
            case None => return this._callDataSavingMode
        }
    }

    /**
     * Save call data saving mode to Preferences.
     * mode: 0=never, 1=cellular, 2=always
     */
    public func saveCallDataSavingMode(mode: Int32): Unit {
        let clamped: Int32 = if (mode < 0) { 0 } else { if (mode > 2) { 2 } else { mode } }
        this._callDataSavingMode = clamped
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "call_settings")
                    prefs.put("call_data_saving_mode", PreferencesValueType.Integer(Int64(clamped)))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[CallService] callDataSavingMode saved: ${clamped}")
                } catch (e: Exception) {
                    Hilog.error(0, "CjTelegram", "[CallService] saveCallDataSavingMode failed: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[CallService] saveCallDataSavingMode: context not ready, in-memory only")
        }
    }

    /**
     * Check whether call should use data-saving (low-bitrate) based on current mode and network.
     * Returns true if call should reduce bitrate.
     * mode 0 (never) → false
     * mode 1 (cellular) → true only when NOT on WiFi
     * mode 2 (always) → true
     */
    public func shouldUseCallDataSaving(): Bool {
        let mode = this.getCallDataSavingMode()
        match (mode) {
            case 0 => return false
            case 2 => return true
            case _ =>
                let status = ReachabilityService.getInstance().currentStatus()
                match (status) {
                    case NetCellular => return true
                    case _ => return false
                }
        }
    }

    public func getCallHistory(): ArrayList<CallRecord> { return this._callHistory }

    public func getCallHistoryNeedsRefresh(): Bool { return this._callHistoryNeedsRefresh }

    public func clearCallHistoryNeedsRefresh(): Unit { this._callHistoryNeedsRefresh = false }
    
    /**
     * 由 UpdatesManager 调用: 当检测到通话相关 update 时标记需要刷新
     * 这确保来自服务器推送的通话事件也能触发 CallHistoryPage 刷新
     */
    public func markCallHistoryRefresh(): Unit {
        this._callHistoryNeedsRefresh = true
    }
    
    /**
     * 注册通话记录变化回调 — CallHistoryPage 在 aboutToAppear 时注册
     * 当 _callHistory 变化时直接推送给 UI，无需轮询
     */
    public func setCallHistoryChangedCallback(cb: (ArrayList<CallRecord>) -> Unit): Unit {
        this._callHistoryChangedCallback = Some(cb)
    }
    
    public func clearCallHistoryChangedCallback(): Unit {
        this._callHistoryChangedCallback = None
    }
    
    /**
     * 通知 UI 通话记录已更新
     */
    private func notifyCallHistoryChanged(): Unit {
        match (this._callHistoryChangedCallback) {
            case Some(cb) => cb(this._callHistory)
            case None => ()
        }
    }

    /**
     * Phase T2: Load real call history from Telegram API
     * filterMissedOnly: when true, server returns only missed calls (API-level filter)
     */
    public func loadRealCallHistory(filterMissedOnly: Bool): Unit {
        this.doLoadCallHistory(InputPeerEmpty(), filterMissedOnly, 0, 0, false)
    }

    public func loadRealCallHistory(): Unit {
        this.loadRealCallHistory(false)
    }

    public func loadMoreCallHistory(offsetMsgId: Int32, offsetDate: Int32): Unit {
        this.doLoadCallHistory(InputPeerEmpty(), false, offsetMsgId, offsetDate, true)
    }

    public func loadCallHistoryForPeer(peerId: Int64, peerAccessHash: Int64): ArrayList<CallRecord> {
        let peer = InputPeerUser()
        peer.userId = peerId
        peer.accessHash = peerAccessHash
        return this.doLoadCallHistoryIntoList(peer, false, 0, 0)
    }

    public func rateCallQuality(callId: Int64, accessHash: Int64, rating: Int32, comment: String): Bool {
        if (callId <= 0 || accessHash == 0) { return false }
        try {
            let client = getMTProtoClient()
            let req = PhoneSetCallRating()
            req.userInitiative = true
            req.callId = callId
            req.callAccessHash = accessHash
            req.rating = if (rating < 1) { 1 } else { if (rating > 5) { 5 } else { rating } }
            req.comment = comment
            let _ = client.sendCallRequest(req.toBytes())
            Hilog.info(0, "CjTelegram", "[CallService] rateCallQuality sent")
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallService] rateCallQuality failed")
            return false
        }
    }

    private func doLoadCallHistory(peer: TLObject, filterMissedOnly: Bool, offsetId: Int32, offsetDate: Int32, append: Bool): Unit {
        let records = this.doLoadCallHistoryIntoList(peer, filterMissedOnly, offsetId, offsetDate)
        if (append) {
            for (r in records) { this._callHistory.add(r) }
            this._callHistoryNeedsRefresh = true
            notifyCallHistoryChanged()
        } else {
            this._callHistory = records
            this._callHistoryNeedsRefresh = true
            notifyCallHistoryChanged()
        }
    }

    private func doLoadCallHistoryIntoList(peer: TLObject, filterMissedOnly: Bool, offsetId: Int32, offsetDate: Int32): ArrayList<CallRecord> {
        let records = ArrayList<CallRecord>()
        Hilog.info(0, "CjTelegram", "[CallService] Loading call history")
        try {
            let client = getMTProtoClient()
            let filter = InputMessagesFilterPhoneCalls()
            filter.missed = filterMissedOnly
            let req = MessagesSearch()
            req.peer = peer
            req.q = ""
            req.filter = filter
            req.offsetId = offsetId
            req.offsetDate = offsetDate
            req.limit = 50
            
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size == 0) {
                Hilog.info(0, "CjTelegram", "[CallService] Empty response for call history")
                return records
            }
            
            // 检查 RPC Error
            if (responseData.size >= 4) {
                let checkD = TLDeserializer(responseData)
                let checkCtor = checkD.readUInt32()
                if (checkCtor == 0x2144ca19) {
                    // rpc_error#2144ca19 error_code:int error_message:string
                    let errCode = checkD.readInt32()
                    let errMsg = checkD.readString()
                    Hilog.info(0, "CjTelegram", "[CallService] RPC Error loading call history: code=${errCode}, msg=${errMsg}")
                    return records
                }
            }
            
            let response = MessagesHistoryResponse.deserialize(responseData)
            Hilog.info(0, "CjTelegram", "[CallService] Got ${response.messages.size} call messages, ${response.users.size} users")
            
            // Build userId -> name map from users
            var userNameMap = HashMap<Int64, String>()
            for (user in response.users) {
                var name = user.firstName
                if (user.lastName.size > 0) {
                    name = "${name} ${user.lastName}"
                }
                userNameMap[user.id] = name
            }
            var idx: Int64 = 0
            for (msg in response.messages) {
                if (msg.callId == 0) {
                    continue
                }
                let record = CallRecord()
                record.id = idx
                record.msgId = msg.id
                record.date = msg.date
                
                // 判断 isOutgoing: 使用 msg.isOutgoing (TL message flags bit 1 = out)
                // 这与 telegram-ios 的做法一致: message.flags.contains(.Incoming) 即 !(flags & 2)
                // msg.isOutgoing 在 TLDialogs.cj 中由 (flags & 2) != 0 正确解析
                // 注意: 之前使用 fromId == currentUserId 的方式不可靠，
                // 因为 messages.search 返回的 fromId 可能不总是代表发起通话的人
                record.isOutgoing = msg.isOutgoing
                // peerId: the OTHER person in the call
                // 对于 messages.search + InputPeerEmpty 返回的私聊消息，
                // peerId 始终是对方用户（无论是我打出去还是对方打进来）
                record.peerId = msg.peerId.id
                
                // Get peer name from user map
                match (userNameMap.get(record.peerId)) {
                    case Some(name) => record.peerName = name
                    case None => record.peerName = "User ${record.peerId}"
                }
                
                // iOS parity: missed（红）仅限 incoming 未接；outgoing 被取消（对方没接）
                // 仍算 outgoing（灰），文案层区分 Cancelled。discardReasonMissed#85e42301
                record.isMissed = !record.isOutgoing && msg.callReason == 0x85e42301
                record.isVideo = msg.callIsVideo
                record.discardReason = msg.callReason
                
                // Duration
                if (msg.callDuration > 0) {
                    let mins = Int64(msg.callDuration / 60)
                    let secs = Int64(msg.callDuration % 60)
                    let secStr = if (secs < 10) { "0${secs}" } else { "${secs}" }
                    record.duration = "${mins}:${secStr}"
                }
                
                // Format timestamp
                record.timestamp = this.formatCallTimestamp(msg.date)
                
                // Media type
                record.mediaType = "voice"
                
                records.add(record)
                idx = idx + 1
            }
            
            Hilog.info(0, "CjTelegram", "[CallService] Loaded call records")
            return records
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallService] Error loading call history")
            return records
        }
    }
    
    // iOS parity（CallListCallItem 日期列 = stringForRelativeTimestamp）：
    // 今天→"HH:MM"，昨天→"Yesterday"，本周→星期缩写"Wed"，更早→"MMM D"。
    // 原实现返回"Today, HH:MM"且用 UTC 取时分（双重不对），改用统一相对格式化（本地时区）。
    private func formatCallTimestamp(unixTime: Int32): String {
        if (unixTime == 0) { return "" }
        return formatRelativeTimestamp(Int64(unixTime))
    }

    /**
     * Phase P5-4: 批量删除通话记录
     * 通话记录是特殊的消息，使用 messages.deleteMessages 删除
     * msgIds: 要删除的消息 ID 列表
     * 返回: 是否成功
     */
    public func deleteCallRecords(msgIds: ArrayList<Int32>): Bool {
        return this.deleteCallRecords(msgIds, true)
    }

    /**
     * revoke=true: "Delete for me and <name>"（iOS deleteMessagesInteractively .forEveryone）；
     * revoke=false: "Delete for me"（.forLocalPeer）。CallListControllerNode.swift:370/378。
     */
    public func deleteCallRecords(msgIds: ArrayList<Int32>, revoke: Bool): Bool {
        if (msgIds.size == 0) { return false }
        Hilog.info(0, "CjTelegram", "[CallService] deleteCallRecords: ${msgIds.size} records")
        try {
            let client = getMTProtoClient()
            let req = MessagesDeleteMessages()
            req.revoke = revoke
            for (mid in msgIds) {
                req.idList.add(mid)
            }
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size >= 4) {
                let checkD = TLDeserializer(responseData)
                let checkCtor = checkD.readUInt32()
                if (checkCtor == 0x2144ca19) {
                    let errCode = checkD.readInt32()
                    let errMsg = checkD.readString()
                    Hilog.info(0, "CjTelegram", "[CallService] RPC Error deleting call records: code=${errCode}, msg=${errMsg}")
                    return false
                }
            }
            // 从本地列表中移除
            let remaining = ArrayList<CallRecord>()
            for (record in this._callHistory) {
                var found = false
                for (mid in msgIds) {
                    if (record.msgId == mid) {
                        found = true
                        break
                    }
                }
                if (!found) {
                    remaining.add(record)
                }
            }
            this._callHistory = remaining
            notifyCallHistoryChanged()
            Hilog.info(0, "CjTelegram", "[CallService] Deleted ${msgIds.size} call records, remaining=${remaining.size}")
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CallService] Error deleting call records: ${e}")
            return false
        }
    }

    public func loadMockCallHistory(): Unit {
        if (this._callHistory.size > 0) { return }
        let names = ["John Doe", "Alice Wang", "Bob Smith", "Sarah Johnson",
                      "Michael Chen", "Emily Davis", "David Wilson"]
        let times = ["Today, 2:30 PM", "Today, 11:45 AM", "Yesterday, 8:20 PM",
                      "Yesterday, 3:15 PM", "Jan 20, 6:30 PM", "Jan 20, 10:00 AM", "Jan 19, 9:00 PM"]
        let durations = ["5:23", "12:05", "", "28:17", "", "2:45", "15:30"]
        let types = ["outgoing", "incoming", "missed", "outgoing", "missed", "incoming", "outgoing"]
        let mediaTypes = ["voice", "video", "voice", "video", "voice", "voice", "voice"]
        var i: Int64 = 0
        while (i < 7) {
            let record = CallRecord()
            record.id = i + 1
            record.peerId = 1000 + i
            record.peerName = names[i]
            record.isOutgoing = types[i] == "outgoing"
            record.isMissed = types[i] == "missed"
            record.mediaType = mediaTypes[i]
            record.timestamp = times[i]
            record.duration = durations[i]
            this._callHistory.add(record)
            i = i + 1
        }
    }
}

// ==================== 辅助函数 ====================

func gToBytes(g: Int32): Array<Byte> {
    let bytes = Array<Byte>(4, repeat: 0)
    bytes[0] = UInt8((g >> 24) & 0xFF)
    bytes[1] = UInt8((g >> 16) & 0xFF)
    bytes[2] = UInt8((g >> 8) & 0xFF)
    bytes[3] = UInt8(g & 0xFF)
    return bytes
}

// 与 iOS CallsEmoji.m 的 emojisArray() 逐项一致（顺序决定双方显示的密钥 emoji）
let CALL_KEY_EMOJIS: Array<String> = [
    "😉", "😍", "😛", "😭", "😱", "😡", "😎", "😴", "😵", "😈",
    "😬", "😇", "😏", "👮", "👷", "💂", "👶", "👨", "👩", "👴",
    "👵", "😻", "😽", "🙀", "👺", "🙈", "🙉", "🙊", "💀", "👽",
    "💩", "🔥", "💥", "💤", "👂", "👀", "👃", "👅", "👄", "👍",
    "👎", "👌", "👊", "✌️", "✋️", "👐", "👆", "👇", "👉", "👈",
    "🙏", "👏", "💪", "🚶", "🏃", "💃", "👫", "👪", "👬", "👭",
    "💅", "🎩", "👑", "👒", "👟", "👞", "👠", "👕", "👗", "👖",
    "👙", "👜", "👓", "🎀", "💄", "💛", "💙", "💜", "💚", "💍",
    "💎", "🐶", "🐺", "🐱", "🐭", "🐹", "🐰", "🐸", "🐯", "🐨",
    "🐻", "🐷", "🐮", "🐗", "🐴", "🐑", "🐘", "🐼", "🐧", "🐥",
    "🐔", "🐍", "🐢", "🐛", "🐝", "🐜", "🐞", "🐌", "🐙", "🐚",
    "🐟", "🐬", "🐋", "🐐", "🐊", "🐫", "🍀", "🌹", "🌻", "🍁",
    "🌾", "🍄", "🌵", "🌴", "🌳", "🌞", "🌚", "🌙", "🌎", "🌋",
    "⚡️", "☔️", "❄️", "⛄️", "🌀", "🌈", "🌊", "🎓", "🎆", "🎃",
    "👻", "🎅", "🎄", "🎁", "🎈", "🔮", "🎥", "📷", "💿", "💻",
    "☎️", "📡", "📺", "📻", "🔉", "🔔", "⏳", "⏰", "⌚️", "🔒",
    "🔑", "🔎", "💡", "🔦", "🔌", "🔋", "🚿", "🚽", "🔧", "🔨",
    "🚪", "🚬", "💣", "🔫", "🔪", "💊", "💉", "💰", "💵", "💳",
    "✉️", "📫", "📦", "📅", "📁", "✂️", "📌", "📎", "✒️", "✏️",
    "📐", "📚", "🔬", "🔭", "🎨", "🎬", "🎤", "🎧", "🎵", "🎹",
    "🎻", "🎺", "🎸", "👾", "🎮", "🃏", "🎲", "🎯", "🏈", "🏀",
    "⚽️", "⚾️", "🎾", "🎱", "🏉", "🎳", "🏁", "🏇", "🏆", "🏊",
    "🏄", "☕️", "🍼", "🍺", "🍷", "🍴", "🍕", "🍔", "🍟", "🍗",
    "🍱", "🍚", "🍜", "🍡", "🍳", "🍞", "🍩", "🍦", "🎂", "🍰",
    "🍪", "🍫", "🍭", "🍯", "🍎", "🍏", "🍊", "🍋", "🍒", "🍇",
    "🍉", "🍓", "🍑", "🍌", "🍐", "🍍", "🍆", "🍅", "🌽", "🏡",
    "🏥", "🏦", "⛪️", "🏰", "⛺️", "🏭", "🗻", "🗽", "🎠", "🎡",
    "⛲️", "🎢", "🚢", "🚤", "⚓️", "🚀", "✈️", "🚁", "🚂", "🚋",
    "🚎", "🚌", "🚙", "🚗", "🚕", "🚛", "🚨", "🚔", "🚒", "🚑",
    "🚲", "🚠", "🚜", "🚦", "⚠️", "🚧", "⛽️", "🎰", "🗿", "🎪",
    "🎭", "🇯🇵", "🇰🇷", "🇩🇪", "🇨🇳", "🇺🇸", "🇫🇷", "🇪🇸", "🇮🇹", "🇷🇺",
    "🇬🇧", "1️⃣", "2️⃣", "3️⃣", "4️⃣", "5️⃣", "6️⃣", "7️⃣", "8️⃣", "9️⃣",
    "0️⃣", "🔟", "❗️", "❓", "♥️", "♦️", "💯", "🔗", "🔱", "🔴",
    "🔵", "🔶", "🔷",
]

// 按 CALL_KEY_EMOJIS 最长匹配切分密钥 emoji：表中含国旗、变体选择符等多码点条目，不能按 rune 切
public func callKeyEmojiSlot(emoji: String, idx: Int32): String {
    let runes = emoji.toRuneArray()
    var pos = 0
    var slot: Int32 = 0
    while (pos < runes.size) {
        var bestLen = 1
        for (e in CALL_KEY_EMOJIS) {
            let er = e.toRuneArray()
            if (er.size > bestLen && pos + er.size <= runes.size) {
                var same = true
                var k = 0
                while (k < er.size) {
                    if (runes[pos + k] != er[k]) {
                        same = false
                        break
                    }
                    k = k + 1
                }
                if (same) {
                    bestLen = er.size
                }
            }
        }
        if (slot == idx) {
            return String(runes[pos..pos + bestLen])
        }
        pos = pos + bestLen
        slot = slot + 1
    }
    return ""
}

// iOS stringForEmojiHashOfData(keyVisualHash, 4)：第 i 个 emoji 取 hash[i*8..i*8+8) 的大端 63 位整数对表长取模
func generateKeyEmojiFromHash(hash: Array<Byte>): String {
    if (hash.size != 32) {
        return ""
    }
    let count = Int64(CALL_KEY_EMOJIS.size)
    var result = ""
    var i = 0
    while (i < 4) {
        let offset = i * 8
        var num: Int64 = Int64(UInt8(hash[offset]) & 0x7F)
        var k = 1
        while (k < 8) {
            num = (num << 8) | Int64(UInt8(hash[offset + k]))
            k = k + 1
        }
        result = result + CALL_KEY_EMOJIS[num % count]
        i = i + 1
    }
    return result
}

func UInt32ToHex(value: UInt32): String {
    let hexArr = ["0", "1", "2", "3", "4", "5", "6", "7",
                  "8", "9", "a", "b", "c", "d", "e", "f"]
    var result = ""
    var v = value
    var i = 0
    while (i < 8) {
        let nibble = Int64((v >> UInt32(28)) & 0xF)
        result = result + hexArr[nibble]
        v = v << 4
        i = i + 1
    }
    return result
}

func parseDiscardReasonCtor(constructor: UInt32): String {
    if (constructor == 0x85e42301) { return "missed" }
    if (constructor == 0xe095c1a0) { return "disconnect" }
    if (constructor == 0xfaf7e8c9) { return "busy" }
    return "hangup"
}

func generateFallbackDhPrime(): Array<Byte> {
    let hexStr = "C71CAEB9C6B1C9048E6C522F70F13F73980D40238E3E21C14934D037563D930F48198A0AA7C14058229493D22530F4DBFA336F6E0AC925139543AED44CCE7C3720FD51F69458705AC68CD4FE6B6B13ABDC9746512969328454F18FAF8C595F642477FE96BB2A941D5BCD1D4AC8CC49880708FA9B378E3C4F3A9060BEE67CF9A4A4A695811051907E162753B56B0F6B410DBA74D8A84B2A14B3144E0EF1284754FD17ED950D5965B4B9DD46582DB1178D169C6BC465B0D6FF9CA3928FEF5B9AE4E418FC15E83EBEA0F87FA9FF5EED70050DED2849F47BF959D956850CE929851F0D8115F635B105EE2E4E15D04B2454BF6F4FADF034B10403119CD8E3B92FCC5B"
    return ByteUtils.fromHex(hexStr)
}

func generateRandomBytes(count: Int64): Array<Byte> {
    let now = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
    return Array<Byte>(count, { i: Int64 => UInt8(((i + 1) * 17 + now + i * i * 31) % 256) })
}

// ==================== DH Key Exchange ====================

public class CallDHExchange {
    public static func generateCallerParams(g: Int32, p: Array<Byte>): (Array<Byte>, Array<Byte>, Array<Byte>) {
        let a = ByteUtils.randomBytes(256)
        let gBytes = gToBytes(g)
        let gA = BigIntMath.modPow(gBytes, a, p)
        let gAHash = SHA256.hash(gA)
        return (a, gA, gAHash)
    }

    public static func generateCalleeParams(g: Int32, p: Array<Byte>): (Array<Byte>, Array<Byte>) {
        let b = ByteUtils.randomBytes(256)
        let gBytes = gToBytes(g)
        let gB = BigIntMath.modPow(gBytes, b, p)
        return (b, gB)
    }

    public static func computeSharedKey(remoteG: Array<Byte>, localPrivate: Array<Byte>, p: Array<Byte>): Array<Byte> {
        return BigIntMath.modPow(remoteG, localPrivate, p)
    }

    public static func computeKeyFingerprint(sharedKey: Array<Byte>): Int64 {
        let sha1 = SHA1.hash(sharedKey)
        var fingerprint: Int64 = 0
        let hashLen = Int64(sha1.size)
        var i: Int64 = 0
        while (i < 8 && (hashLen - 8 + i) >= 0) {
            fingerprint = fingerprint | (Int64(UInt8(sha1[hashLen - 8 + i])) << Int32(i * 8))
            i = i + 1
        }
        return fingerprint
    }

    public static func verifyGAHash(gA: Array<Byte>, expectedHash: Array<Byte>): Bool {
        let computed = SHA256.hash(gA)
        if (computed.size != expectedHash.size) { return false }
        var i: Int64 = 0
        while (i < Int64(computed.size)) {
            if (computed[i] != expectedHash[i]) { return false }
            i = i + 1
        }
        return true
    }

    public static func generateKeyEmoji(sharedKey: Array<Byte>, gA: Array<Byte>): String {
        let combined = ByteUtils.concat2(sharedKey, gA)
        let hash = SHA256.hash(combined)
        return generateKeyEmojiFromHash(hash)
    }
}
