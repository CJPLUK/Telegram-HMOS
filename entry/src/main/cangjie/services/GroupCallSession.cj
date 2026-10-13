package ohos_app_cangjie_entry.services

/**
 * GroupCallSession — 群 Video Chat 的会话状态机（与页面解耦，页面关掉通话仍在）。
 *
 * 对位 iOS PresentationGroupCallImpl（submodules/TelegramCallsUI/Sources/PresentationGroupCall.swift）：
 *   requesting → active → established（:404-419），核心 updateSessionState（:1730）：
 *   1. 建引擎 → emitJoinPayload → phone.joinGroupCall(muted, video_stopped, params)
 *   2. 取 updateGroupCallConnection.params：stream==true 是 broadcast，否则 rtc
 *   3. setConnectionMode(rtc) + setJoinResponse(json)
 *   4. connecting 期间每 4s checkGroupCall([localSsrc])，自己 ssrc 不在 → 整体重 join（:2865）
 *   5. 音量回调 → 说话指示（阈值 0.1、静默 cutoff，:447-521）；未知 ssrc → 按 ssrc 反查（:2808）
 *   6. leave(terminate)：true → discardGroupCall；false → leaveGroupCall(source: localSsrc)（:3045）
 *
 * 成员排序对位 GroupCallParticipantsContext.Participant.compare（GroupCalls.swift:1377）。
 */

import kit.PerformanceAnalysisKit.Hilog
import std.collection.{ArrayList, HashMap}
import std.sync.*
import std.time.DateTime
import ohos_app_cangjie_entry.core.voip.{TgGroupCallEngine, GroupAudioLevel, GroupConnectionMode}

public class GroupCallMember {
    public var peerId: Int64 = 0
    public var peerType: String = "user"
    public var name: String = ""
    public var ssrc: UInt32 = 0
    public var isSelf: Bool = false
    public var isMuted: Bool = false
    public var canSelfUnmute: Bool = true
    public var mutedByYou: Bool = false
    public var hasRaiseHand: Bool = false
    public var raiseHandRating: Int64 = 0
    public var volume: Int32 = 10000
    public var hasVolume: Bool = false
    public var about: String = ""
    public var joinDate: Int64 = 0
    public var activeDate: Int64 = 0
    public var audioLevel: Float32 = 0.0
    public var isSpeaking: Bool = false
    public var lastSpokeMs: Int64 = 0
    // 视频（iOS Participant.videoDescription）
    public var videoEndpoint: String = ""
    public var videoGroupsJson: String = "[]"
    public var videoPaused: Bool = false
    // 屏幕共享（iOS Participant.presentationDescription）：和摄像头并列的第二路视频
    public var presentationEndpoint: String = ""
    public var presentationGroupsJson: String = "[]"
    public var presentationPaused: Bool = false
    public func hasPresentation(): Bool { return presentationEndpoint.size > 0 }
    public func hasVideo(): Bool { return videoEndpoint.size > 0 }
}

/** 通话内消息（iOS GroupCallMessagesContext.Message）。默认 10s 后从界面消失（group_call_message_ttl）。 */
public class GroupCallChatMessage {
    public var id: Int64 = 0            // 本地为 randomId，远端为服务器 id
    public var peerId: Int64 = 0
    public var name: String = ""
    public var text: String = ""
    public var isSelf: Bool = false
    public var expiresAtMs: Int64 = 0
}

let GROUP_CALL_MESSAGE_TTL_MS: Int64 = 10000
let GROUP_CALL_MESSAGE_MAX_LENGTH: Int64 = 128

// iOS SpeakingParticipantsContext：speakingLevelThreshold = 0.1，静默超时后熄灭
let GROUP_CALL_SPEAKING_THRESHOLD: Float32 = 0.1
let GROUP_CALL_SPEAKING_HOLD_MS: Int64 = 2000
let GROUP_CALL_CHECK_INTERVAL_MS: Int64 = 4000
let GROUP_CALL_PARTICIPANTS_REFRESH_MS: Int64 = 60000
// 服务端整表重拉（iOS resetStateFromServer）的最小间隔，防止连续推送触发请求风暴
let GROUP_CALL_RESET_MIN_INTERVAL_MS: Int64 = 2000

var _groupCallSession: Option<GroupCallSession> = None
let _groupCallSessionLock = ReentrantMutex()

public func getGroupCallSession(): GroupCallSession {
    synchronized(_groupCallSessionLock) {
        match (_groupCallSession) {
            case Some(s) => return s
            case None =>
                let s = GroupCallSession()
                _groupCallSession = Some(s)
                return s
        }
    }
}

public class GroupCallSession {
    private let lock = ReentrantMutex()
    private var engine: Option<TgGroupCallEngine> = None

    // —— 对外只读状态（读时经 snapshot*() 拷贝）——
    private var _state: String = "idle"          // idle / connecting / connected / failed
    private var _error: String = ""
    private var _callId: Int64 = 0
    private var _accessHash: Int64 = 0
    private var _title: String = ""
    private var _localSsrc: UInt32 = 0
    private var _isMuted: Bool = true            // iOS 入会默认自静音
    private var _canUnmute: Bool = true          // false = 被管理员静音（大按钮变"举手"）
    private var _raisedHand: Bool = false
    private var _members = HashMap<Int64, GroupCallMember>()
    private var _ssrcToPeer = HashMap<UInt32, Int64>()
    private var _generation: Int64 = 0           // 每次 join/leave 自增，旧循环据此退出
    private var _listener: Option<() -> Unit> = None
    private var _lastNotifyMs: Int64 = 0
    private var _selfLevel: Float32 = 0.0
    private var _lastSummary: String = ""
    private var _recording: Bool = false
    private var _messages = ArrayList<GroupCallChatMessage>()
    private var _messageTicker: Bool = false
    private var _messageSendError: String = ""
    private var _cameraOn: Bool = false
    private var _cameraFront: Bool = true
    private var _expandedEndpoint: String = ""      // UI 放大的那路（请求 Full 画质）
    private var _lastRequestedJson: String = ""
    private var _speakerOn: Bool = true          // iOS 群聊默认外放
    private var _canManage: Bool = false
    private var _messagesEnabled: Bool = true    // iOS 群聊默认 !isChannel；入会后由 layer-228 会话校正
    private var _canChangeMessages: Bool = false
    private var _displayAsPeers: ArrayList<GroupCallJoinAsPeer> = ArrayList<GroupCallJoinAsPeer>()
    private var _joinAsPeerId: Int64 = 0         // 0 = 以自己的身份
    // 屏幕共享（iOS screencast context）：独立的第二个引擎 + phone.joinGroupCallPresentation
    private var screenEngine: Option<TgGroupCallEngine> = None
    private var _screenSharing: Bool = false       // 已请求（含系统同意框阶段）
    private var _screenConnected: Bool = false
    private var _joinInFlight: Bool = false
    private var _joinFailures: Int64 = 0
    private var _joinMuted: Bool = false         // iOS defaultParticipantsAreMuted
    private var _canChangeJoinMuted: Bool = false
    private var _chatPeerType: String = ""
    private var _chatPeerId: Int64 = 0
    // iOS GroupCallParticipantsContext.State.version / totalCount
    private var _participantsVersion: Int32 = 0
    private var _totalCount: Int64 = 0
    private var _resetInFlight: Bool = false
    private var _resetPending: Bool = false
    private var _lastResetMs: Int64 = 0

    // ==================== 查询 ====================

    public func state(): String { synchronized(lock) { return _state } }
    public func errorText(): String { synchronized(lock) { return _error } }
    public func callId(): Int64 { synchronized(lock) { return _callId } }
    public func title(): String { synchronized(lock) { return _title } }
    public func isMuted(): Bool { synchronized(lock) { return _isMuted } }
    public func canUnmute(): Bool { synchronized(lock) { return _canUnmute } }
    public func raisedHand(): Bool { synchronized(lock) { return _raisedHand } }
    public func selfLevel(): Float32 { synchronized(lock) { return _selfLevel } }
    public func speakerOn(): Bool { synchronized(lock) { return _speakerOn } }
    public func canManage(): Bool { synchronized(lock) { return _canManage } }
    public func accessHash(): Int64 { synchronized(lock) { return _accessHash } }
    public func chatPeerId(): Int64 { synchronized(lock) { return _chatPeerId } }
    public func chatPeerType(): String { synchronized(lock) { return _chatPeerType } }
    public func memberCount(): Int64 { synchronized(lock) { return _members.size } }

    /** 入会前由入口页告知所属会话与管理权限（iOS canManageCall：creator / admin.manageCalls）。 */
    public func configure(chatPeerType: String, chatPeerId: Int64, canManage: Bool): Unit {
        synchronized(lock) {
            _chatPeerType = chatPeerType
            _chatPeerId = chatPeerId
            _canManage = canManage
        }
    }

    public func setTitleLocal(title: String): Unit {
        synchronized(lock) { _title = title }
        this.notifyNow()
    }
    public func isActiveFor(callId: Int64): Bool {
        synchronized(lock) { return _callId == callId && (_state == "connecting" || _state == "connected") }
    }
    public func isActive(): Bool {
        synchronized(lock) { return _state == "connecting" || _state == "connected" }
    }

    public func setListener(cb: Option<() -> Unit>): Unit {
        synchronized(lock) { _listener = cb }
    }

    /** 排好序的成员快照（iOS Participant.compare:1377）。 */
    public func snapshotMembers(): ArrayList<GroupCallMember> {
        let list = ArrayList<GroupCallMember>()
        synchronized(lock) {
            for ((_, m) in _members) { list.add(m) }
        }
        list.sortBy(stable: true, comparator: { a: GroupCallMember, b: GroupCallMember =>
            // canUnmute 优先（能说话的排前）
            let aCan = !a.isMuted || a.canSelfUnmute
            let bCan = !b.isMuted || b.canSelfUnmute
            if (aCan != bCan) { return if (aCan) { Ordering.LT } else { Ordering.GT } }
            // 正在说话 / 最近活跃
            if (a.lastSpokeMs != b.lastSpokeMs) { return if (a.lastSpokeMs > b.lastSpokeMs) { Ordering.LT } else { Ordering.GT } }
            if (a.activeDate != b.activeDate) { return if (a.activeDate > b.activeDate) { Ordering.LT } else { Ordering.GT } }
            if (a.raiseHandRating != b.raiseHandRating) { return if (a.raiseHandRating > b.raiseHandRating) { Ordering.LT } else { Ordering.GT } }
            if (a.joinDate != b.joinDate) { return if (a.joinDate > b.joinDate) { Ordering.LT } else { Ordering.GT } }
            if (a.peerId < b.peerId) { return Ordering.LT }
            if (a.peerId > b.peerId) { return Ordering.GT }
            return Ordering.EQ
        })
        return list
    }

    // ==================== 入会 ====================

    public func join(callId: Int64, accessHash: Int64, title: String): Unit {
        var gen: Int64 = 0
        synchronized(lock) {
            if (_callId == callId && (_state == "connecting" || _state == "connected")) { return }
        }
        // 已在别的通话里：先离开（iOS PresentationCallManager.joinGroupCall:990-1028）
        if (this.isActive()) { this.leave(false) }
        synchronized(lock) {
            _generation = _generation + 1
            gen = _generation
            _state = "connecting"
            _error = ""
            _callId = callId
            _accessHash = accessHash
            _title = title
            _localSsrc = 0
            _isMuted = true
            _canUnmute = true
            _raisedHand = false
            _selfLevel = 0.0
            _messages = ArrayList<GroupCallChatMessage>()
            _cameraOn = false
            _cameraFront = true
            _expandedEndpoint = ""
            _lastRequestedJson = ""
            _members = HashMap<Int64, GroupCallMember>()
            _ssrcToPeer = HashMap<UInt32, Int64>()
            _participantsVersion = 0
            _totalCount = 0
            _resetInFlight = false
            _resetPending = false
            _lastResetMs = 0
        }
        this.notifyNow()
        let genCopy = gen
        let _ = spawn { this.startEngineAndJoin(genCopy) }
    }

    private func isCurrent(gen: Int64): Bool {
        synchronized(lock) { return _generation == gen }
    }

    private func startEngineAndJoin(gen: Int64): Unit {
        try {
            getCallService().ensureMicrophonePermission()
            getAudioSessionManager().acquireCallSession()
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[GroupCallSession] audio prep failed: ${e}")
        }
        let eng = TgGroupCallEngine()
        let ok = eng.start(
            { connected: Bool, transitioning: Bool, mode: Int32 => this.onNetworkState(gen, connected, transitioning, mode) },
            { levels: ArrayList<GroupAudioLevel> => this.onAudioLevels(gen, levels) },
            { requestId: Int64, ssrcs: ArrayList<UInt32> => this.onRequestChannels(gen, requestId, ssrcs) }
        )
        if (!ok) {
            this.fail(gen, "Audio engine unavailable")
            return
        }
        synchronized(lock) { engine = Some(eng) }
        eng.setMuted(true)
        eng.setSpeaker(this.speakerOn())
        eng.emitJoinPayload({ json: String, ssrc: UInt32 =>
            // 引擎线程 → 切到自己的线程做网络请求
            let _ = spawn { this.performJoin(gen, json, ssrc) }
        })
    }

    private func performJoin(gen: Int64, joinPayload: String, ssrc: UInt32): Unit {
        if (!this.isCurrent(gen)) { return }
        var cId: Int64 = 0
        var cHash: Int64 = 0
        synchronized(lock) {
            cId = _callId
            cHash = _accessHash
            _localSsrc = ssrc
        }
        Hilog.info(0, "CjTelegram", "[GroupCallSession] join payload ready ssrc=${ssrc} len=${joinPayload.size}")
        let svc = getCallsService()
        // iOS：入会默认静音 + video_stopped（GroupCalls.swift:695 bit2 恒置）
        synchronized(lock) { _joinInFlight = true }
        let resultOpt = svc.joinGroupCall(cId, cHash, joinPayload, 0, 0, true, true, "")
        synchronized(lock) { _joinInFlight = false }
        if (!this.isCurrent(gen)) { return }
        match (resultOpt) {
            case Some(result) =>
                let response = result.joinResponsePayload
                if (response.size == 0) {
                    // 服务器侧失败（真机：500 GROUPCALL_ADD_PARTICIPANTS_FAILED 连发）。指数退避重试，
                    // 不能 4s 一次地砸——那样只会换来 FLOOD_WAIT。
                    var attempt: Int64 = 0
                    synchronized(lock) { _joinFailures = _joinFailures + 1; attempt = _joinFailures }
                    if (attempt >= 4) {
                        this.fail(gen, "Server returned no connection parameters")
                        return
                    }
                    let waitMs: Int64 = 3000 * (1 << (attempt - 1))   // 3s, 6s, 12s
                    Hilog.info(0, "CjTelegram", "[GroupCallSession] join failed (attempt ${attempt}), retrying in ${waitMs}ms")
                    let payloadCopy = joinPayload
                    let _ = spawn {
                        sleep(Duration.millisecond * waitMs)
                        if (this.isCurrent(gen)) { this.performJoin(gen, payloadCopy, ssrc) }
                    }
                    return
                }
                synchronized(lock) { _joinFailures = 0 }
                if (response.contains("\"stream\":true")) {
                    // broadcast（大群流）模式需要 FFmpeg 解码分片，本平台引擎未编入
                    this.fail(gen, "This video chat is a live stream, which is not supported yet")
                    return
                }
                Hilog.info(0, "CjTelegram", "[GroupCallSession] join OK, response=${response.size} bytes")
                match (this.currentEngine()) {
                    case Some(eng) =>
                        eng.setConnectionMode(GroupConnectionMode.ModeRtc)
                        eng.setJoinResponse(response)
                    case None => return
                }
                this.refreshParticipants(gen)
                let warmId = cId
                let warmHash = cHash
                let _ = spawn {
                    let st = getCallsService().warmUpGroupCallMessages(warmId, warmHash)
                    synchronized(lock) {
                        if (gen == _generation) {
                            _joinMuted = st.joinMuted
                            _canChangeJoinMuted = st.canChangeJoinMuted
                        }
                    }
                    this.applyMessagesSettings(gen, st.messagesEnabled, st.canChangeMessages)
                }
                let _ = spawn {
                    // Display As：只有 >1 个身份时 iOS 才给菜单；先探明数量
                    let hash = match (getRealChatListService().getCachedChat(this.chatPeerType(), this.chatPeerId())) {
                        case Some(c) => c.accessHash
                        case None => 0
                    }
                    let peers = getCallsService().getGroupCallJoinAs(this.chatPeerType(), this.chatPeerId(), hash)
                    synchronized(lock) {
                        if (gen == _generation) { _displayAsPeers = peers }
                    }
                    this.notifyNow()
                }
                let _ = spawn { this.participantsLoop(gen) }
                let _ = spawn { this.checkLoop(gen) }
            case None =>
                this.fail(gen, "Failed to join the video chat")
        }
    }

    private func currentEngine(): Option<TgGroupCallEngine> {
        synchronized(lock) { return engine }
    }

    private func fail(gen: Int64, message: String): Unit {
        if (!this.isCurrent(gen)) { return }
        Hilog.info(0, "CjTelegram", "[GroupCallSession] failed: ${message}")
        this.teardown(gen, "failed", message)
    }

    // ==================== 引擎回调 ====================

    private func onNetworkState(gen: Int64, connected: Bool, _transitioning: Bool, _mode: Int32): Unit {
        if (!this.isCurrent(gen)) { return }
        var changed = false
        synchronized(lock) {
            let next = if (connected) { "connected" } else { "connecting" }
            if (_state == "connecting" || _state == "connected") {
                if (_state != next) {
                    _state = next
                    changed = true
                }
            }
        }
        if (changed) {
            Hilog.info(0, "CjTelegram", "[GroupCallSession] network connected=${connected}")
            this.notifyNow()
            if (!connected) {
                let _ = spawn { this.checkLoop(gen) }
            }
        }
    }

    private func onAudioLevels(gen: Int64, levels: ArrayList<GroupAudioLevel>): Unit {
        if (!this.isCurrent(gen)) { return }
        let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        var changed = false
        let unknown = ArrayList<UInt32>()
        synchronized(lock) {
            for (item in levels) {
                if (item.ssrc == 0) {
                    // 本地麦克风
                    let lvl = if (_isMuted) { Float32(0.0) } else { item.level }
                    _selfLevel = lvl
                    for ((_, m) in _members) {
                        if (m.isSelf) {
                            m.audioLevel = lvl
                            if (lvl > GROUP_CALL_SPEAKING_THRESHOLD && item.voice) {
                                m.lastSpokeMs = nowMs
                                if (!m.isSpeaking) { m.isSpeaking = true; changed = true }
                            }
                        }
                    }
                    continue
                }
                if (!_ssrcToPeer.contains(item.ssrc)) {
                    if (item.level > 0.001) { unknown.add(item.ssrc) }
                    continue
                }
                let pid = _ssrcToPeer[item.ssrc]
                if (_members.contains(pid)) {
                    let m = _members[pid]
                    m.audioLevel = item.level
                    if (item.level > GROUP_CALL_SPEAKING_THRESHOLD && item.voice) {
                        m.lastSpokeMs = nowMs
                        if (!m.isSpeaking) { m.isSpeaking = true; changed = true }
                    }
                }
            }
            // 静默超时熄灭
            for ((_, m) in _members) {
                if (m.isSpeaking && nowMs - m.lastSpokeMs > GROUP_CALL_SPEAKING_HOLD_MS) {
                    m.isSpeaking = false
                    m.audioLevel = 0.0
                    changed = true
                }
            }
        }
        if (unknown.size > 0) {
            let _ = spawn { this.resolveUnknownSsrcs(gen, unknown) }
        }
        // 音量动画用：节流到 ~5Hz；说话态变化立即发。全场安静（没人在说、自己电平≈0）时不推：
        // 每次仓颉→ArkTS 推送在没有 JSValueScope 的回调里都要先抛一次异常（带栈打印）再回退，
        // 空转推送白白占主线程（newScope 需要 API 24，工程目标 22，暂不能用）。
        var quiet = true
        synchronized(lock) {
            if (_selfLevel > 0.01) { quiet = false }
            for ((_, m) in _members) {
                if (m.isSpeaking || m.audioLevel > 0.01) { quiet = false }
            }
        }
        if (changed) { this.notifyNow() } else if (!quiet) { this.notifyThrottled(nowMs, 200) }
    }

    private func onRequestChannels(gen: Int64, requestId: Int64, ssrcs: ArrayList<UInt32>): Unit {
        if (!this.isCurrent(gen)) { return }
        let _ = spawn {
            let known = ArrayList<UInt32>()
            let owners = ArrayList<Int64>()
            let missing = ArrayList<UInt32>()
            synchronized(lock) {
                for (s in ssrcs) {
                    if (_ssrcToPeer.contains(s)) {
                        known.add(s)
                        owners.add(_ssrcToPeer[s])
                    } else {
                        missing.add(s)
                    }
                }
            }
            if (missing.size > 0) {
                this.resolveUnknownSsrcs(gen, missing)
                synchronized(lock) {
                    for (s in missing) {
                        if (_ssrcToPeer.contains(s)) {
                            known.add(s)
                            owners.add(_ssrcToPeer[s])
                        }
                    }
                }
            }
            Hilog.info(0, "CjTelegram", "[GroupCallSession] channel request #${requestId}: asked=${ssrcs.size} answered=${known.size}")
            match (this.currentEngine()) {
                case Some(eng) => if (this.isCurrent(gen)) { eng.provideChannels(requestId, known, owners) }
                case None => ()
            }
        }
    }

    private func resolveUnknownSsrcs(gen: Int64, ssrcs: ArrayList<UInt32>): Unit {
        if (!this.isCurrent(gen)) { return }
        var cId: Int64 = 0
        var cHash: Int64 = 0
        synchronized(lock) { cId = _callId; cHash = _accessHash }
        let parts = getCallsService().getGroupParticipantsBySources(cId, cHash, ssrcs)
        if (!this.isCurrent(gen)) { return }
        this.mergeParticipants(parts, false)
        this.notifyNow()
    }

    // ==================== 成员 ====================

    private func refreshParticipants(gen: Int64): Unit {
        var cId: Int64 = 0
        var cHash: Int64 = 0
        synchronized(lock) { cId = _callId; cHash = _accessHash }
        let (parts, listVersion) = getCallsService().getGroupParticipantsVersioned(cId, cHash, "", 100)
        if (!this.isCurrent(gen)) { return }
        // 整表即新基线（iOS resetStateFromServer 用返回的 version 覆盖 state.version）
        // 整表比已合并的推送还旧（请求途中又来了推送）→ 只补不删，免得把刚进来的成员抹掉
        var listIsStale = false
        if (listVersion > 0) {
            synchronized(lock) {
                if (listVersion > _participantsVersion) { _participantsVersion = listVersion }
                else if (listVersion < _participantsVersion) { listIsStale = true }
            }
        }
        // 服务器的名单里没有自己 = 我们的参会记录被服务器丢了（真机复现：joinGroupCall 撞上 -503 重试后），
        // SFU 从此不再转发视频，但音频/引擎看起来还"连着"。这时只能重新 join，不能把自己从本地名单里删掉。
        var selfListed = false
        let myId = getCurrentUserId()
        var connected = false
        synchronized(lock) { connected = _state == "connected" }
        for (p in parts) {
            if (!p.left && (p.isCurrentUser || p.peerId == myId)) { selfListed = true }
        }
        if (!selfListed && connected) {
            // 名单可能只是分页/瞬时不一致：再用 checkGroupCall 确认一次，确认丢了才重新 join
            var ssrc: UInt32 = 0
            synchronized(lock) { ssrc = _localSsrc }
            let confirmed = match (getCallsService().checkGroupCall(cId, cHash, ssrc)) {
                case Some(there) => !there
                case None => false
            }
            if (!this.isCurrent(gen)) { return }
            Hilog.info(0, "CjTelegram", "[GroupCallSession] server list has no self entry (${parts.size} others), ssrc dropped=${confirmed}")
            if (confirmed) {
                this.mergeParticipants(parts, false)
                this.rejoin(gen)
                return
            }
        }
        this.mergeParticipants(parts, !listIsStale)
        var summary = ""
        for (p in parts) {
            summary = summary + " [${p.peerType}:${p.peerId} ssrc=${p.source} self=${p.isCurrentUser} muted=${p.isMuted} canUnmute=${p.canSelfUnmute} left=${p.left} '${p.name}']"
        }
        if (summary != this._lastSummary) {
            this._lastSummary = summary
            Hilog.info(0, "CjTelegram", "[GroupCallSession] participants(${parts.size}):${summary}")
        }
        this.notifyNow()
    }

    /** replaceAll=true：以服务端整表为准（不在表里的成员移除）。 */
    private func mergeParticipants(parts: ArrayList<GroupCallParticipantInfo>, replaceAll: Bool): Unit {
        let myId = getCurrentUserId()
        let volumeUpdates = ArrayList<(UInt32, Float64)>()
        let removedSsrcs = ArrayList<UInt32>()
        synchronized(lock) {
            let seen = HashMap<Int64, Bool>()
            for (p in parts) {
                if (p.peerId == 0) { continue }
                if (p.left) {
                    if (_members.contains(p.peerId)) {
                        let old = _members[p.peerId]
                        if (old.ssrc != 0) { removedSsrcs.add(old.ssrc); _ssrcToPeer.remove(old.ssrc) }
                        _members.remove(p.peerId)
                    }
                    continue
                }
                seen[p.peerId] = true
                let m = if (_members.contains(p.peerId)) { _members[p.peerId] } else {
                    let created = GroupCallMember()
                    created.peerId = p.peerId
                    _members[p.peerId] = created
                    created
                }
                m.peerType = p.peerType
                m.isSelf = p.isCurrentUser || p.peerId == myId
                if (p.name.size > 0) { m.name = p.name }
                if (m.name.size == 0) { m.name = this.lookupName(p.peerId) }
                if (p.source != 0 && m.ssrc != p.source) {
                    if (m.ssrc != 0) { removedSsrcs.add(m.ssrc); _ssrcToPeer.remove(m.ssrc) }
                    m.ssrc = p.source
                    _ssrcToPeer[p.source] = p.peerId
                }
                // isMin 的更新不携带 mutedByYou / volume（iOS :2267-2341 合并规则）
                m.isMuted = p.isMuted
                m.canSelfUnmute = p.canSelfUnmute
                if (!p.isMin) {
                    m.mutedByYou = p.mutedByYou
                    m.hasVolume = p.hasVolume
                    if (p.hasVolume) { m.volume = p.volume }
                }
                match (p.video) {
                    case Some(v) =>
                        m.videoEndpoint = v.endpointId
                        m.videoGroupsJson = v.toJsonGroups()
                        m.videoPaused = v.isPaused
                    case None =>
                        if (!p.isMin) {
                            m.videoEndpoint = ""
                            m.videoGroupsJson = "[]"
                            m.videoPaused = false
                        }
                }
                match (p.presentation) {
                    case Some(v) =>
                        m.presentationEndpoint = v.endpointId
                        m.presentationGroupsJson = v.toJsonGroups()
                        m.presentationPaused = v.isPaused
                    case None =>
                        if (!p.isMin) {
                            m.presentationEndpoint = ""
                            m.presentationGroupsJson = "[]"
                            m.presentationPaused = false
                        }
                }
                m.hasRaiseHand = p.hasRaiseHand
                m.raiseHandRating = p.raiseHandRating
                m.about = p.about
                m.joinDate = p.date
                if (p.activeDate > m.activeDate) { m.activeDate = p.activeDate }
                if (m.isSelf) {
                    // 服务端视角的自己：被管理员静音 → 不能自行开麦
                    _canUnmute = !(p.isMuted && !p.canSelfUnmute)
                    if (!_canUnmute) { _isMuted = true }
                    if (!p.hasRaiseHand) { _raisedHand = false }
                } else if (m.ssrc != 0) {
                    let vol: Float64 = if (m.mutedByYou) { 0.0 } else if (m.hasVolume) { Float64(m.volume) / 10000.0 } else { 1.0 }
                    volumeUpdates.add((m.ssrc, vol))
                }
            }
            if (replaceAll) {
                let gone = ArrayList<Int64>()
                for ((pid, m) in _members) {
                    if (!seen.contains(pid) && !m.isSelf) { gone.add(pid) }
                }
                for (pid in gone) {
                    let old = _members[pid]
                    if (old.ssrc != 0) { removedSsrcs.add(old.ssrc); _ssrcToPeer.remove(old.ssrc) }
                    _members.remove(pid)
                }
            }
        }
        match (this.currentEngine()) {
            case Some(eng) =>
                if (removedSsrcs.size > 0) { eng.removeSsrcs(removedSsrcs) }
                for ((ssrc, vol) in volumeUpdates) { eng.setVolume(ssrc, vol) }
                if (!this.canUnmute()) { eng.setMuted(true) }
            case None => ()
        }
        this.updateRequestedVideoChannels()
    }

    // ==================== 通话内消息 ====================

    /** iOS GroupCallParticipantsContext.State.messagesAreEnabled */
    public func messagesAreEnabled(): Bool {
        synchronized(lock) { return _messagesEnabled }
    }

    public func canChangeMessagesEnabled(): Bool {
        synchronized(lock) { return _canChangeMessages }
    }

    public func displayAsPeers(): ArrayList<GroupCallJoinAsPeer> {
        synchronized(lock) {
            let copy = ArrayList<GroupCallJoinAsPeer>()
            for (p in _displayAsPeers) { copy.add(p) }
            return copy
        }
    }

    /** 当前身份的 peerId（以自己身份时返回自己的 userId）。 */
    public func joinAsPeerId(): Int64 {
        synchronized(lock) { return if (_joinAsPeerId != 0) { _joinAsPeerId } else { getCurrentUserId() } }
    }

    /**
     * iOS PresentationGroupCall.reconnect(as:)（:2996）：关视频、回到静音，然后用新的 join_as 重新走
     * joinGroupCall；旧身份那一行由服务器的 left 更新清掉，这里先本地摘除免得闪两行。
     */
    public func reconnectAs(peerId: Int64): Unit {
        var target: Option<GroupCallJoinAsPeer> = None
        var gen: Int64 = 0
        var wasCameraOn = false
        let myId = getCurrentUserId()
        synchronized(lock) {
            if (_state != "connected") { return }
            let current = if (_joinAsPeerId != 0) { _joinAsPeerId } else { myId }
            if (peerId == current) { return }
            for (p in _displayAsPeers) {
                if (p.peerId == peerId) { target = Some(p) }
            }
            if (target.isNone()) { return }
            _joinAsPeerId = if (peerId == myId) { 0 } else { peerId }
            wasCameraOn = _cameraOn
            _cameraOn = false
            _isMuted = true
            _raisedHand = false
            let stale = ArrayList<Int64>()
            for ((id, m) in _members) {
                if (m.isSelf) { stale.add(id) }
            }
            for (id in stale) { _members.remove(id) }
            _state = "connecting"
            gen = _generation
        }
        Hilog.info(0, "CjTelegram", "[GroupCallSession] reconnecting as peer=${peerId}")
        getCallsService().setJoinAsPeer(if (peerId == myId) { Option<GroupCallJoinAsPeer>.None } else { target })
        match (this.currentEngine()) {
            case Some(eng) =>
                if (wasCameraOn) { eng.setVideoEnabled(false, true) }
                eng.setMuted(true)
            case None => ()
        }
        this.notifyNow()
        this.rejoin(gen)
    }

    public func joinMuted(): Bool { synchronized(lock) { return _joinMuted } }
    public func canChangeJoinMuted(): Bool { synchronized(lock) { return _canChangeJoinMuted } }

    /** iOS updateDefaultParticipantsAreMuted：先本地生效，服务器拒绝再回滚。 */
    public func setJoinMuted(muted: Bool): Unit {
        var cId: Int64 = 0
        var cHash: Int64 = 0
        synchronized(lock) {
            if (!_canChangeJoinMuted || _joinMuted == muted) { return }
            _joinMuted = muted
            cId = _callId
            cHash = _accessHash
        }
        this.notifyNow()
        let id = cId
        let hash = cHash
        let _ = spawn {
            if (!getCallsService().setGroupCallJoinMuted(id, hash, muted)) {
                synchronized(lock) { _joinMuted = !muted }
                this.notifyNow()
            }
        }
    }

    /** 自己在通话页里改了 bio / 名字：先本地反映到自己那一行。 */
    public func setSelfAboutLocal(about: String): Unit {
        synchronized(lock) {
            for ((_, m) in _members) {
                if (m.isSelf) { m.about = about }
            }
        }
        this.notifyNow()
    }

    public func setSelfNameLocal(name: String): Unit {
        synchronized(lock) {
            for ((_, m) in _members) {
                if (m.isSelf) { m.name = name }
            }
        }
        this.notifyNow()
    }

    /** iOS setMessagesEnabled：先本地生效，服务器拒绝再回滚。 */
    public func toggleMessagesEnabled(): Unit {
        var target = true
        var cId: Int64 = 0
        var cHash: Int64 = 0
        var gen: Int64 = 0
        synchronized(lock) {
            if (!_canChangeMessages) { return }
            target = !_messagesEnabled
            _messagesEnabled = target
            cId = _callId
            cHash = _accessHash
            gen = _generation
        }
        this.notifyNow()
        let enabled = target
        let id = cId
        let hash = cHash
        let g = gen
        let _ = spawn {
            if (!getCallsService().setGroupCallMessagesEnabled(id, hash, enabled)) {
                this.applyMessagesSettings(g, !enabled, true)
            }
        }
    }

    /** layer-228 会话推来的 groupCall：同步消息开关（min 形态不带 canChange，保留原值即可）。 */
    public func onMessagesSettings(callId: Int64, enabled: Bool, canChange: Bool): Unit {
        var changed = false
        synchronized(lock) {
            if (callId != _callId || _callId == 0) { return }
            if (_messagesEnabled != enabled) {
                _messagesEnabled = enabled
                changed = true
            }
            if (canChange && !_canChangeMessages) {
                _canChangeMessages = true
                changed = true
            }
        }
        if (changed) { this.notifyNow() }
    }

    private func applyMessagesSettings(gen: Int64, enabled: Bool, canChange: Bool): Unit {
        synchronized(lock) {
            if (gen != _generation) { return }
            _messagesEnabled = enabled
            _canChangeMessages = canChange
        }
        this.notifyNow()
    }

    public func snapshotMessages(): ArrayList<GroupCallChatMessage> {
        let list = ArrayList<GroupCallChatMessage>()
        synchronized(lock) { for (m in _messages) { list.add(m) } }
        return list
    }

    public func lastMessageError(): String { synchronized(lock) { return _messageSendError } }

    /** iOS sendInput:1420 —— 纯空白不发；乐观插入；错误静默（这里多留一条日志与错误文本供排查）。 */
    public func sendMessage(rawText: String): Unit {
        var text = rawText.trimAscii()
        if (text.size == 0) { return }
        let runes = text.toRuneArray()
        if (runes.size > GROUP_CALL_MESSAGE_MAX_LENGTH) {
            text = String(runes[0..GROUP_CALL_MESSAGE_MAX_LENGTH])
        }
        var cId: Int64 = 0
        var cHash: Int64 = 0
        let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let randomId = nowMs * 1000 + (nowMs % 997)
        synchronized(lock) {
            if (_state != "connected" && _state != "connecting") { return }
            cId = _callId
            cHash = _accessHash
            let m = GroupCallChatMessage()
            m.id = randomId
            m.peerId = getCurrentUserId()
            m.name = this.lookupName(m.peerId)
            m.text = text
            m.isSelf = true
            m.expiresAtMs = nowMs + GROUP_CALL_MESSAGE_TTL_MS
            _messages.add(m)
            _messageSendError = ""
        }
        this.notifyNow()
        this.ensureMessageTicker()
        let idCopy = cId
        let hashCopy = cHash
        let textCopy = text
        let _ = spawn {
            let (ok, err) = getCallsService().sendGroupCallMessage(idCopy, hashCopy, randomId, textCopy)
            if (!ok) {
                synchronized(lock) { _messageSendError = err }
            }
        }
    }

    /** updateGroupCallMessage。自己发的那条已乐观插入，按作者+文本去重。 */
    public func onIncomingMessage(callId: Int64, msgId: Int64, fromId: Int64, text: String, _date: Int64): Unit {
        if (!this.isActiveFor(callId)) { return }
        let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let myId = getCurrentUserId()
        synchronized(lock) {
            if (fromId == myId) {
                for (m in _messages) {
                    if (m.isSelf && m.text == text) {
                        m.expiresAtMs = nowMs + GROUP_CALL_MESSAGE_TTL_MS   // 以服务器回执时刻重新计时（iOS 同）
                        return
                    }
                }
            }
            for (m in _messages) { if (m.id == msgId && m.peerId == fromId) { return } }
            let m = GroupCallChatMessage()
            m.id = msgId
            m.peerId = fromId
            m.name = if (_members.contains(fromId) && _members[fromId].name.size > 0) { _members[fromId].name } else { this.lookupName(fromId) }
            m.text = text
            m.isSelf = fromId == myId
            m.expiresAtMs = nowMs + GROUP_CALL_MESSAGE_TTL_MS
            _messages.add(m)
        }
        this.notifyNow()
        this.ensureMessageTicker()
    }

    /** iOS messageLifetimeTick：1s 一次，过期的从列表里拿掉；列表空了就停。 */
    private func ensureMessageTicker(): Unit {
        synchronized(lock) {
            if (_messageTicker) { return }
            _messageTicker = true
        }
        let _ = spawn {
            while (true) {
                sleep(Duration.millisecond * 1000)
                let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
                var changed = false
                var empty = false
                synchronized(lock) {
                    let keep = ArrayList<GroupCallChatMessage>()
                    for (m in _messages) {
                        if (m.expiresAtMs > nowMs) { keep.add(m) } else { changed = true }
                    }
                    _messages = keep
                    empty = keep.size == 0
                    if (empty) { _messageTicker = false }
                }
                if (changed) { this.notifyNow() }
                if (empty) { return }
            }
        }
    }

    // ==================== 视频 ====================

    /**
     * iOS VideoChatParticipantsComponent:1950-2012 → setRequestedVideoList：
     * 有视频的他人默认 Medium；被放大的那路 Full，其余降到 Thumbnail。
     */
    private func updateRequestedVideoChannels(): Unit {
        var json = "["
        var count: Int64 = 0
        synchronized(lock) {
            var tiles: Int64 = if (_cameraOn) { 1 } else { 0 }
            for ((_, m) in _members) {
                if (!m.isSelf && m.hasVideo() && m.ssrc != 0) { tiles = tiles + 1 }
                if (!m.isSelf && m.hasPresentation() && m.ssrc != 0) { tiles = tiles + 1 }
            }
            // 屏幕共享（iOS VideoChatScreen requestedVideoChannels：presentation 与 video 各是一条 channel，
            // audioSsrc 都用该成员的音频 ssrc）。屏幕内容要看清字，宫格里也一律要 Full；
            // 只有当别的画面被放大时才降到缩略。
            for ((_, m) in _members) {
                if (m.isSelf || !m.hasPresentation() || m.ssrc == 0) { continue }
                // 屏幕共享：宫格 Medium、放大 Full（iOS maxPresentationQuality 同规则；共享出现时 UI 会自动放大它）
                var pMax: Int64 = 1
                if (_expandedEndpoint.size > 0) { pMax = if (m.presentationEndpoint == _expandedEndpoint) { 2 } else { 0 } }
                if (count > 0) { json = json + "," }
                json = json + "{\"audioSsrc\":${m.ssrc},\"userId\":${m.peerId},\"endpointId\":\"${m.presentationEndpoint}\",\"minQuality\":0,\"maxQuality\":${pMax},\"ssrcGroups\":${m.presentationGroupsJson}}"
                count = count + 1
            }
            for ((_, m) in _members) {
                if (m.isSelf || !m.hasVideo() || m.ssrc == 0) { continue }
                var minQ: Int64 = 0
                var maxQ: Int64 = 1
                // 宫格一律 Medium(360p)、放大才 Full(720p)——与 iOS 完全一致（VideoChatParticipantsComponent.swift:1994）。
                // 曾改成"≤2 路就要 Full"追求清晰度，代价是 SFU 会通过 SenderVideoConstraints 让发送方打开
                // 900kbps 的 720p 层，对方上行一抖就整层关闭→SFU 换层→冻结；共享屏幕时更是两路 Full 同时要。
                // minQuality 恒为 thumbnail（iOS requestedVideoChannel(minQuality: .thumbnail, …)），
                // 否则发送方带宽不足只出低层时，服务器可能一层都不转发。
                if (_expandedEndpoint.size > 0) {
                    if (m.videoEndpoint == _expandedEndpoint) { maxQ = 2 } else { maxQ = 0 }
                }
                if (count > 0) { json = json + "," }
                json = json + "{\"audioSsrc\":${m.ssrc},\"userId\":${m.peerId},\"endpointId\":\"${m.videoEndpoint}\",\"minQuality\":${minQ},\"maxQuality\":${maxQ},\"ssrcGroups\":${m.videoGroupsJson}}"
                count = count + 1
            }
        }
        json = json + "]"
        var changed = false
        synchronized(lock) {
            if (json != _lastRequestedJson) { _lastRequestedJson = json; changed = true }
        }
        if (!changed) { return }
        Hilog.info(0, "CjTelegram", "[GroupCallSession] requested video channels=${count}")
        match (this.currentEngine()) {
            case Some(eng) => eng.setRequestedVideoChannels(json)
            case None => ()
        }
    }

    public func setExpandedEndpoint(endpointId: String): Unit {
        synchronized(lock) { _expandedEndpoint = endpointId }
        this.updateRequestedVideoChannels()
    }

    /** XComponent surface ↔ 远端 endpoint；surfaceId=0 解绑。 */
    public func bindRemoteSurface(endpointId: String, surfaceId: UInt64): Unit {
        match (this.currentEngine()) {
            case Some(eng) => eng.setIncomingVideoSurface(endpointId, surfaceId)
            case None => ()
        }
    }

    public func bindLocalSurface(surfaceId: UInt64): Unit {
        match (this.currentEngine()) {
            case Some(eng) => eng.setLocalVideoSurface(surfaceId, this.cameraFront())
            case None => ()
        }
    }

    /**
     * 摄像头开关（iOS requestVideo:3389 / disableVideo:3415）：
     * 引擎 setVideoCapture + phone.editGroupCallParticipant(video_stopped)。
     * 被管理员静音时 iOS 直接隐藏按钮，这里同样拒绝。
     */
    public func toggleCamera(): Unit {
        var next = false
        var front = true
        var cId: Int64 = 0
        var cHash: Int64 = 0
        synchronized(lock) {
            if (_state != "connected") { return }
            if (!_canUnmute && !_cameraOn) { return }
            _cameraOn = !_cameraOn
            next = _cameraOn
            front = _cameraFront
            cId = _callId
            cHash = _accessHash
        }
        this.notifyNow()
        let nextCopy = next
        let frontCopy = front
        let idCopy = cId
        let hashCopy = cHash
        let _ = spawn {
            if (nextCopy) { getCallService().ensureCameraPermission() }
            match (this.currentEngine()) {
                case Some(eng) => eng.setVideoEnabled(nextCopy, frontCopy)
                case None => ()
            }
            this.updateRequestedVideoChannels()
            let ok = getCallsService().editSelfVideoState(idCopy, hashCopy, !nextCopy, false)
            Hilog.info(0, "CjTelegram", "[GroupCallSession] camera on=${nextCopy} synced=${ok}")
        }
    }

    public func flipCamera(): Unit {
        var front = true
        synchronized(lock) {
            if (!_cameraOn) { return }
            _cameraFront = !_cameraFront
            front = _cameraFront
        }
        match (this.currentEngine()) {
            case Some(eng) => eng.switchCamera(front)
            case None => ()
        }
        this.notifyNow()
    }

    // ==================== 服务端推送（UpdatesManager）====================

    /**
     * updateGroupCallParticipants：增量合并（iOS GroupCallParticipantsContext.processUpdate:2229）。
     * 版本规则同 iOS：version 落后于当前 → 丢弃（重复/过期推送）；跳号（> 当前+1）→ 中间有推送丢了，
     * 以服务端整表为准重拉（resetStateFromServer:2238-2243）。本条仍先合并，界面不必等重拉返回。
     */
    public func applyParticipantUpdates(callId: Int64, parts: ArrayList<GroupCallParticipantInfo>, version: Int32): Unit {
        if (!this.isActiveFor(callId)) { return }
        var gen: Int64 = 0
        var mySsrc: UInt32 = 0
        var stale = false
        var gap = false
        synchronized(lock) {
            gen = _generation
            mySsrc = _localSsrc
            if (_participantsVersion > 0 && version < _participantsVersion) {
                stale = true
            } else {
                if (_participantsVersion > 0 && version > _participantsVersion + 1) { gap = true }
                if (version > _participantsVersion) { _participantsVersion = version }
            }
        }
        if (stale) { return }
        // 自己的 ssrc 被换掉 = 同账号在别的设备入会（iOS :1084-1144 → markAsCanBeRemoved）
        let myId = getCurrentUserId()
        for (p in parts) {
            if ((p.isCurrentUser || p.peerId == myId) && !p.left && p.source != 0 && mySsrc != 0 && p.source != mySsrc) {
                Hilog.info(0, "CjTelegram", "[GroupCallSession] joined from another device (ssrc ${mySsrc} → ${p.source}), closing here")
                this.teardown(gen, "idle", "")
                return
            }
        }
        this.mergeParticipants(parts, false)
        this.notifyNow()
        if (gap) {
            Hilog.info(0, "CjTelegram", "[GroupCallSession] participants version gap (update ${version}), reloading from server")
            this.requestServerReset(gen)
        }
    }

    /**
     * iOS resetStateFromServer：串行、限频地整表重拉。进行中再次请求只记一笔，结束后补拉一次。
     */
    private func requestServerReset(gen: Int64): Unit {
        var waitMs: Int64 = 0
        synchronized(lock) {
            if (gen != _generation) { return }
            if (_resetInFlight) { _resetPending = true; return }
            _resetInFlight = true
            let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
            let since = nowMs - _lastResetMs
            if (since < GROUP_CALL_RESET_MIN_INTERVAL_MS) { waitMs = GROUP_CALL_RESET_MIN_INTERVAL_MS - since }
        }
        let delayMs = waitMs
        let _ = spawn {
            if (delayMs > 0) { sleep(Duration.millisecond * delayMs) }
            var again = false
            if (this.isCurrent(gen)) {
                try { this.refreshParticipants(gen) } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[GroupCallSession] reset from server failed: ${e}")
                }
            }
            synchronized(lock) {
                _lastResetMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
                _resetInFlight = false
                again = _resetPending && gen == _generation
                _resetPending = false
            }
            if (again) { this.requestServerReset(gen) }
        }
    }

    /**
     * updateGroupCall.participants_count（iOS addUpdates .call → state.totalCount，GroupCalls.swift:2033-2042）。
     * 人数与本地名单对不上 = 有成员进出的 updateGroupCallParticipants 没送到本端，按服务端整表收敛。
     */
    public func onParticipantsCount(callId: Int64, count: Int64): Unit {
        if (count <= 0 || !this.isActiveFor(callId)) { return }
        var gen: Int64 = 0
        var mismatch = false
        synchronized(lock) {
            gen = _generation
            _totalCount = count
            let known = _members.size
            // 整表一次只拉 100 人；超出后人数本就对不上，不据此反复重拉
            mismatch = count != known && !(count > 100 && known >= 100)
        }
        if (mismatch) {
            Hilog.info(0, "CjTelegram", "[GroupCallSession] server participants_count=${count} differs from local list, reloading")
            this.requestServerReset(gen)
        }
    }

    public func totalCount(): Int64 { synchronized(lock) { return _totalCount } }

    public func onCallDiscarded(callId: Int64): Unit {
        if (!this.isActiveFor(callId)) { return }
        var gen: Int64 = 0
        synchronized(lock) { gen = _generation }
        Hilog.info(0, "CjTelegram", "[GroupCallSession] call ended by an admin")
        this.teardown(gen, "idle", "")
    }

    public func onCallInfo(callId: Int64, title: String, hasTitle: Bool, recording: Bool, count: Int64): Unit {
        if (!this.isActiveFor(callId)) { return }
        synchronized(lock) {
            if (hasTitle) { _title = title }
            _recording = recording
        }
        this.notifyNow()
        this.onParticipantsCount(callId, count)
    }

    public func isRecording(): Bool { synchronized(lock) { return _recording } }
    public func cameraOn(): Bool { synchronized(lock) { return _cameraOn } }
    public func cameraFront(): Bool { synchronized(lock) { return _cameraFront } }

    private func lookupName(peerId: Int64): String {
        match (getUserPhotoService().getCachedUser(peerId)) {
            case Some(u) =>
                if (u.lastName.size > 0 && u.firstName.size > 0) { return "${u.firstName} ${u.lastName}" }
                if (u.firstName.size > 0) { return u.firstName }
                return u.lastName
            case None => return ""
        }
    }

    private func participantsLoop(gen: Int64): Unit {
        // 在 updateGroupCallParticipants 推送接通之前，用短轮询保证成员/静音态收敛
        while (this.isCurrent(gen)) {
            sleep(Duration.millisecond * GROUP_CALL_PARTICIPANTS_REFRESH_MS)
            if (!this.isCurrent(gen)) { return }
            try { this.refreshParticipants(gen) } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GroupCallSession] refresh failed: ${e}")
            }
        }
    }

    /** iOS startCheckingCallIfNeeded（:2865）：未连通期间每 4s 查一次自己的 ssrc。 */
    private func checkLoop(gen: Int64): Unit {
        while (this.isCurrent(gen)) {
            sleep(Duration.millisecond * GROUP_CALL_CHECK_INTERVAL_MS)
            if (!this.isCurrent(gen)) { return }
            var cId: Int64 = 0
            var cHash: Int64 = 0
            var ssrc: UInt32 = 0
            var st = ""
            synchronized(lock) { cId = _callId; cHash = _accessHash; ssrc = _localSsrc; st = _state }
            // 只在 connecting 期间查（iOS 同：连通即 dispose）。曾改成连通后也查，结果视频状态刚改完
            // 服务器短暂查不到 ssrc → 误判 → 明明连着还去重新 join → 500 ADD_PARTICIPANTS_FAILED + FLOOD_WAIT 风暴。
            if (st != "connecting") { return }
            if (ssrc == 0 || _joinInFlight) { continue }
            match (getCallsService().checkGroupCall(cId, cHash, ssrc)) {
                case Some(stillThere) =>
                    if (!stillThere && this.isCurrent(gen)) {
                        Hilog.info(0, "CjTelegram", "[GroupCallSession] own ssrc dropped by server → rejoin")
                        this.rejoin(gen)
                        return
                    }
                case None => ()
            }
        }
    }

    private func rejoin(gen: Int64): Unit {
        match (this.currentEngine()) {
            case Some(eng) =>
                eng.setConnectionMode(GroupConnectionMode.ModeNone)
                eng.emitJoinPayload({ json: String, ssrc: UInt32 =>
                    let _ = spawn { this.performJoin(gen, json, ssrc) }
                })
            case None => ()
        }
    }

    // ==================== 用户动作 ====================

    /** 大麦克风按钮。被管理员静音时改为举手（iOS VideoChatMicButtonComponent .raiseHand）。 */
    public func toggleMute(): Unit {
        var target = false
        var cId: Int64 = 0
        var cHash: Int64 = 0
        var raise = false
        synchronized(lock) {
            if (_state != "connected" && _state != "connecting") { return }
            cId = _callId
            cHash = _accessHash
            if (!_canUnmute) {
                if (_raisedHand) { return }   // iOS raiseHand()：已举手则 no-op
                _raisedHand = true
                raise = true
            } else {
                _isMuted = !_isMuted
                target = _isMuted
                for ((_, m) in _members) {
                    if (m.isSelf) { m.isMuted = target }   // 乐观更新
                }
            }
        }
        let idCopy = cId
        let hashCopy = cHash
        let targetCopy = target
        if (raise) {
            this.notifyNow()
            let _ = spawn { let _ = getCallsService().editSelfParticipant(idCopy, hashCopy, false, false, true, true) }
            return
        }
        match (this.currentEngine()) {
            case Some(eng) => eng.setMuted(target)
            case None => ()
        }
        this.notifyNow()
        let _ = spawn {
            let ok = getCallsService().editSelfParticipant(idCopy, hashCopy, targetCopy, true, false, false)
            Hilog.info(0, "CjTelegram", "[GroupCallSession] self muted=${targetCopy} synced=${ok}")
        }
    }

    public func toggleSpeaker(): Unit {
        var next = true
        synchronized(lock) {
            _speakerOn = !_speakerOn
            next = _speakerOn
        }
        TgGroupCallEngine().setSpeaker(next)
        this.notifyNow()
    }

    /**
     * 管理员：静音成员 / 允许发言（iOS updateMuteState:3625 admin 分支 →
     * phone.editGroupCallParticipant(muted)）。
     */
    public func adminSetMemberMuted(peerId: Int64, muted: Bool): Unit {
        var cId: Int64 = 0
        var cHash: Int64 = 0
        synchronized(lock) {
            if (!_members.contains(peerId)) { return }
            cId = _callId
            cHash = _accessHash
            let m = _members[peerId]
            m.isMuted = muted
            m.canSelfUnmute = !muted
            if (!muted) { m.hasRaiseHand = false }
        }
        this.notifyNow()
        let idCopy = cId
        let hashCopy = cHash
        let _ = spawn {
            let ah = getPeerInfoService().getUserAccessHash(peerId)
            let ok = getCallsService().editGroupCallParticipant(idCopy, hashCopy, peerId, ah, muted, true, 0, false)
            Hilog.info(0, "CjTelegram", "[GroupCallSession] admin muted=${muted} peer=${peerId} ok=${ok}")
        }
    }

    /** 管理员静音/解除某成员；普通成员则是"仅对我静音"（本地音量 0）。 */
    public func setMemberMutedForMe(peerId: Int64, muted: Bool): Unit {
        var ssrc: UInt32 = 0
        synchronized(lock) {
            if (!_members.contains(peerId)) { return }
            let m = _members[peerId]
            m.mutedByYou = muted
            ssrc = m.ssrc
        }
        if (ssrc != 0) {
            match (this.currentEngine()) {
                case Some(eng) => eng.setVolume(ssrc, if (muted) { 0.0 } else { 1.0 })
                case None => ()
            }
        }
        this.notifyNow()
        // iOS updateMuteState（非管理员）同样发 editGroupCallParticipant(muted)，服务器记成 muted_by_you
        var cId: Int64 = 0
        var cHash: Int64 = 0
        synchronized(lock) { cId = _callId; cHash = _accessHash }
        let idCopy = cId
        let hashCopy = cHash
        let _ = spawn {
            let ah = getPeerInfoService().getUserAccessHash(peerId)
            let ok = getCallsService().editGroupCallParticipant(idCopy, hashCopy, peerId, ah, muted, true, 0, false)
            Hilog.info(0, "CjTelegram", "[GroupCallSession] mutedForMe=${muted} peer=${peerId} synced=${ok}")
        }
    }

    /**
     * 成员音量（iOS VoiceChatVolumeContextItem → setVolume(peerId, volume, sync)）。volume: 0…20000，10000 = 100%。
     * 拖动中只改本地播放音量；松手（finished）才同步 phone.editGroupCallParticipant(volume)。
     */
    public func setMemberVolume(peerId: Int64, volume: Int32, finished: Bool): Unit {
        var ssrc: UInt32 = 0
        var cId: Int64 = 0
        var cHash: Int64 = 0
        let clamped: Int32 = if (volume < 1) { 1 } else if (volume > 20000) { 20000 } else { volume }
        synchronized(lock) {
            if (!_members.contains(peerId)) { return }
            let m = _members[peerId]
            m.volume = clamped
            m.hasVolume = true
            ssrc = m.ssrc
            cId = _callId
            cHash = _accessHash
        }
        if (ssrc != 0) {
            match (this.currentEngine()) {
                case Some(eng) => eng.setVolume(ssrc, Float64(clamped) / 10000.0)
                case None => ()
            }
        }
        if (!finished) { return }
        this.notifyNow()
        let idCopy = cId
        let hashCopy = cHash
        let _ = spawn {
            let ah = getPeerInfoService().getUserAccessHash(peerId)
            let ok = getCallsService().editGroupCallParticipant(idCopy, hashCopy, peerId, ah, false, false, clamped, true)
            Hilog.info(0, "CjTelegram", "[GroupCallSession] volume=${clamped} peer=${peerId} synced=${ok}")
        }
    }

    /**
     * 管理员把成员移出群（iOS :260-311：确认后 removePeerMember，toast "You removed %@ from this group"）。
     * 返回是否成功；成员行由随后的 updateGroupCallParticipants(left) 清掉，这里先本地摘除。
     */
    public func removeMember(peerId: Int64): Bool {
        var chatType = ""
        var chatId: Int64 = 0
        synchronized(lock) {
            if (!_canManage) { return false }
            chatType = _chatPeerType
            chatId = _chatPeerId
        }
        if (chatId == 0) { return false }
        let ah = getPeerInfoService().getUserAccessHash(peerId)
        let ok = if (chatType == "channel") {
            getRealMessageService().kickMember(chatId, peerId, ah)
        } else {
            getPeersService().removeGroupMember(chatId, peerId, ah).success
        }
        Hilog.info(0, "CjTelegram", "[GroupCallSession] remove peer=${peerId} from ${chatType}:${chatId} ok=${ok}")
        if (ok) {
            synchronized(lock) {
                if (_members.contains(peerId)) {
                    let gone = _members[peerId]
                    if (gone.ssrc != 0) { _ssrcToPeer.remove(gone.ssrc) }
                    _members.remove(peerId)
                }
            }
            this.notifyNow()
        }
        return ok
    }

    public func isScreenSharing(): Bool { synchronized(lock) { return _screenSharing } }
    public func isScreenConnected(): Bool { synchronized(lock) { return _screenConnected } }

    /**
     * 开始共享屏幕（iOS PresentationGroupCall.requestScreencast → screencastContext.joinGroupCallPresentation）。
     * 系统会弹隐私同意框；用户拒绝时采集器上报 Inactive → 引擎不出视频，这里靠 phone 侧 left 或 UI 手动停止收尾。
     */
    public func startScreenShare(): Unit {
        var gen: Int64 = 0
        var cId: Int64 = 0
        var cHash: Int64 = 0
        synchronized(lock) {
            if (_state != "connected" || _screenSharing) { return }
            _screenSharing = true
            _screenConnected = false
            gen = _generation
            cId = _callId
            cHash = _accessHash
        }
        this.notifyNow()
        let eng = TgGroupCallEngine()
        let ok = eng.startScreencast(
            { connected: Bool, _t: Bool, _m: Int32 =>
                var changed = false
                synchronized(lock) {
                    if (_screenConnected != connected) { _screenConnected = connected; changed = true }
                }
                if (changed) {
                    Hilog.info(0, "CjTelegram", "[GroupCallSession] screencast network connected=${connected}")
                    this.notifyNow()
                }
            },
            { _reqId: Int64, _ssrcs: ArrayList<UInt32> => () }   // 共享引擎不收别人的媒体
        )
        if (!ok) {
            synchronized(lock) { _screenSharing = false }
            this.notifyNow()
            showToast("Screen sharing is not available")
            return
        }
        synchronized(lock) { screenEngine = Some(eng) }
        let id = cId
        let hash = cHash
        let genCopy = gen
        eng.emitJoinPayload({ json: String, _ssrc: UInt32 =>
            let _ = spawn {
                if (!this.isCurrent(genCopy)) { return }
                match (getCallsService().joinGroupCallPresentation(id, hash, json)) {
                    case Some(result) =>
                        let response = result.joinResponsePayload
                        if (response.size == 0) {
                            Hilog.info(0, "CjTelegram", "[GroupCallSession] presentation join: no connection parameters")
                            this.stopScreenShare()
                            showToast("Could not start screen sharing")
                            return
                        }
                        Hilog.info(0, "CjTelegram", "[GroupCallSession] presentation join OK, response=${response.size} bytes")
                        eng.setConnectionMode(GroupConnectionMode.ModeRtc)
                        eng.setJoinResponse(response)
                        eng.setScreenCapture(true)   // 系统同意框在这一步弹出
                    case None =>
                        Hilog.info(0, "CjTelegram", "[GroupCallSession] presentation join failed")
                        this.stopScreenShare()
                        showToast("Could not start screen sharing")
                }
            }
        })
    }

    public func stopScreenShare(): Unit {
        var eng: Option<TgGroupCallEngine> = None
        var cId: Int64 = 0
        var cHash: Int64 = 0
        synchronized(lock) {
            if (!_screenSharing) { return }
            _screenSharing = false
            _screenConnected = false
            eng = screenEngine
            screenEngine = None
            cId = _callId
            cHash = _accessHash
        }
        this.notifyNow()
        let engCopy = eng
        let id = cId
        let hash = cHash
        let _ = spawn {
            match (engCopy) {
                case Some(e) =>
                    e.setScreenCapture(false)
                    e.stop()
                case None => ()
            }
            let ok = getCallsService().leaveGroupCallPresentation(id, hash)
            Hilog.info(0, "CjTelegram", "[GroupCallSession] screen share stopped, leavePresentation ok=${ok}")
        }
    }

    /** terminate=true：结束整个 Video Chat（需管理权限）。 */
    public func leave(terminate: Bool): Unit {
        var gen: Int64 = 0
        var cId: Int64 = 0
        var cHash: Int64 = 0
        var ssrc: UInt32 = 0
        synchronized(lock) {
            if (_state == "idle") { return }
            gen = _generation
            cId = _callId
            cHash = _accessHash
            ssrc = _localSsrc
        }
        let chatId = this.chatPeerId()
        this.teardown(gen, "idle", "")
        let idCopy = cId
        let hashCopy = cHash
        let ssrcCopy = ssrc
        let _ = spawn {
            let svc = getCallsService()
            if (terminate) {
                if (svc.discardGroupCall(idCopy, hashCopy) && chatId != 0) {
                    // 自己结束的通话不会再推 updateGroupCall 回来：主动收掉聊天页的 JOIN 条
                    notifyActiveGroupCallChanged(chatId, 0, 0, 0)
                }
            } else {
                let _ = svc.leaveGroupCall(idCopy, hashCopy, ssrcToInt32(ssrcCopy))
            }
            Hilog.info(0, "CjTelegram", "[GroupCallSession] left call=${idCopy} terminate=${terminate} ssrc=${ssrcCopy}")
        }
    }

    private func teardown(gen: Int64, finalState: String, message: String): Unit {
        var eng: Option<TgGroupCallEngine> = None
        var screenEng: Option<TgGroupCallEngine> = None
        synchronized(lock) {
            if (_generation != gen) { return }
            _generation = _generation + 1
            eng = engine
            engine = None
            screenEng = screenEngine
            screenEngine = None
            _screenSharing = false
            _screenConnected = false
            _state = finalState
            _error = message
            _selfLevel = 0.0
            _cameraOn = false
            _lastRequestedJson = ""
            _joinAsPeerId = 0
            _joinFailures = 0
            _joinInFlight = false
            _displayAsPeers = ArrayList<GroupCallJoinAsPeer>()
            if (finalState == "idle") {
                _members = HashMap<Int64, GroupCallMember>()
                _ssrcToPeer = HashMap<UInt32, Int64>()
                _callId = 0
                _accessHash = 0
            }
        }
        getCallsService().setJoinAsPeer(Option<GroupCallJoinAsPeer>.None)
        this.notifyNow()
        let engCopy = eng
        let screenEngCopy = screenEng
        let _ = spawn {
            match (engCopy) {
                case Some(e) => e.stop()   // 阻塞（≤5s），必须在后台线程
                case None => ()
            }
            match (screenEngCopy) {
                case Some(e) =>
                    e.setScreenCapture(false)
                    e.stop()
                case None => ()
            }
            try { getAudioSessionManager().releaseCallSession() } catch (_: Exception) {}
        }
    }

    // ==================== 通知 ====================

    private func notifyNow(): Unit {
        var cb: Option<() -> Unit> = None
        synchronized(lock) {
            cb = _listener
            _lastNotifyMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        }
        match (cb) {
            case Some(f) => try { f() } catch (_: Exception) {}
            case None => ()
        }
    }

    private func notifyThrottled(nowMs: Int64, minIntervalMs: Int64): Unit {
        var due = false
        synchronized(lock) {
            if (nowMs - _lastNotifyMs >= minIntervalMs) { due = true }
        }
        if (due) { this.notifyNow() }
    }
}
