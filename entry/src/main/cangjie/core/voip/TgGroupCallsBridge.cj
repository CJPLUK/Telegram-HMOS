package ohos_app_cangjie_entry.core.voip

/**
 * TgGroupCallsBridge — 群通话媒体引擎（tgcalls GroupInstanceCustomImpl）的 FFI 桥。
 *
 * 对位 iOS OngoingGroupCallContext（submodules/TelegramVoip/Sources/GroupCallContext.swift）：
 *   create → emitJoinPayload →（业务层 phone.joinGroupCall）→ setConnectionMode(rtc)
 *   → setJoinResponse → 音量 / 网络状态回调 → stop。
 *
 * C ABI 见 output/tgcalls_ohos/patches/shim/tgcalls_group_c_shim.cpp，签名必须逐条一致。
 * 所有回调都在 tgcalls/webrtc 工作线程触发，业务层拿到后自行 spawn/launch 切线程。
 * 与 1:1 桥一致：全局同一时刻只支持一个群通话实例（Telegram 设计如此）。
 */

import kit.PerformanceAnalysisKit.Hilog
import std.collection.{ArrayList, HashMap}
import std.sync.ReentrantMutex

public class GroupAudioLevel {
    public var ssrc: UInt32 = 0        // 0 = 本地麦克风（iOS AudioLevelKey.local）
    public var level: Float32 = 0.0
    public var voice: Bool = false
}

public enum GroupConnectionMode {
    | ModeNone
    | ModeRtc
    | ModeBroadcast
}

/**
 * 每个引擎实例一个槽位：回调按槽位分发，而不是放在全局变量里。
 *  - 屏幕共享需要第二个引擎实例（iOS 同样是独立的 screencast context），两套回调不能互相覆盖；
 *  - 旧引擎的 stop() 在后台线程里要跑几秒，全局变量的写法会把"刚建好的新引擎"的回调一并清掉
 *   （离开后立刻重进同一个通话时表现为一直 Connecting）。
 * 槽位号写在一小块 malloc 出来的内存里，作为 user 指针传给 C 层，回调时读回来。
 */
class GroupEngineCallbacks {
    var network: Option<(Bool, Bool, Int32) -> Unit> = None
    var levels: Option<(ArrayList<GroupAudioLevel>) -> Unit> = None
    var requestChannels: Option<(Int64, ArrayList<UInt32>) -> Unit> = None
    var joinPayload: Option<(String, UInt32) -> Unit> = None
}

let g_groupSlotLock = ReentrantMutex()
let g_groupSlots = HashMap<Int64, GroupEngineCallbacks>()
var g_groupNextSlot: Int64 = 1

func groupSlotOf(user: CPointer<Unit>): Option<GroupEngineCallbacks> {
    if (user.isNull()) { return None }
    let slot = unsafe { CPointer<Int64>(user).read() }
    synchronized(g_groupSlotLock) {
        return g_groupSlots.get(slot)
    }
}

@C
func onGroupNetworkState_C(user: CPointer<Unit>, isConnected: Bool, isTransitioning: Bool, mode: Int32): Unit {
    match (groupSlotOf(user)) {
        case Some(cbs) =>
            match (cbs.network) {
                case Some(cb) =>
                    try { cb(isConnected, isTransitioning, mode) } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[TgGroupBridge @C] network cb exception: ${e}")
                    }
                case None => ()
            }
        case None => ()
    }
}

@C
func onGroupAudioLevels_C(user: CPointer<Unit>, ssrcs: CPointer<UInt32>, levels: CPointer<Float32>,
                          voice: CPointer<UInt8>, n: Int32): Unit {
    if (n <= 0) { return }
    let cbOpt: Option<(ArrayList<GroupAudioLevel>) -> Unit> = match (groupSlotOf(user)) {
        case Some(cbs) => cbs.levels
        case None => Option<(ArrayList<GroupAudioLevel>) -> Unit>.None
    }
    match (cbOpt) {
        case Some(cb) =>
            try {
                let list = ArrayList<GroupAudioLevel>()
                var i: Int64 = 0
                while (i < Int64(n)) {
                    let item = GroupAudioLevel()
                    unsafe {
                        item.ssrc = (ssrcs + i).read()
                        item.level = (levels + i).read()
                        item.voice = (voice + i).read() != 0
                    }
                    list.add(item)
                    i = i + 1
                }
                cb(list)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[TgGroupBridge @C] levels cb exception: ${e}")
            }
        case None => ()
    }
}

@C
func onGroupRequestChannels_C(user: CPointer<Unit>, requestId: Int64, ssrcs: CPointer<UInt32>, n: Int32): Unit {
    let cbOpt: Option<(Int64, ArrayList<UInt32>) -> Unit> = match (groupSlotOf(user)) {
        case Some(cbs) => cbs.requestChannels
        case None => Option<(Int64, ArrayList<UInt32>) -> Unit>.None
    }
    match (cbOpt) {
        case Some(cb) =>
            try {
                let list = ArrayList<UInt32>()
                var i: Int64 = 0
                while (i < Int64(n)) {
                    unsafe { list.add((ssrcs + i).read()) }
                    i = i + 1
                }
                cb(requestId, list)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[TgGroupBridge @C] request channels cb exception: ${e}")
            }
        case None => ()
    }
}

@C
func onGroupJoinPayload_C(user: CPointer<Unit>, json: CString, audioSsrc: UInt32): Unit {
    let cbOpt: Option<(String, UInt32) -> Unit> = match (groupSlotOf(user)) {
        case Some(cbs) => cbs.joinPayload
        case None => Option<(String, UInt32) -> Unit>.None
    }
    match (cbOpt) {
        case Some(cb) =>
            try {
                let text = json.toString()
                cb(text, audioSsrc)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[TgGroupBridge @C] join payload cb exception: ${e}")
            }
        case None => ()
    }
}

type GroupNetworkCFunc = CFunc<(CPointer<Unit>, Bool, Bool, Int32) -> Unit>
type GroupLevelsCFunc = CFunc<(CPointer<Unit>, CPointer<UInt32>, CPointer<Float32>, CPointer<UInt8>, Int32) -> Unit>
type GroupRequestChannelsCFunc = CFunc<(CPointer<Unit>, Int64, CPointer<UInt32>, Int32) -> Unit>
type GroupJoinPayloadCFunc = CFunc<(CPointer<Unit>, CString, UInt32) -> Unit>

class TgGroupLib {
    static var _resolved: Bool = false
    static var _ok: Bool = false

    static var fn_create: CFunc<(CPointer<Unit>, GroupNetworkCFunc, GroupLevelsCFunc, GroupRequestChannelsCFunc, Int32, Bool, Bool) -> CPointer<Unit>> =
        CFunc<(CPointer<Unit>, GroupNetworkCFunc, GroupLevelsCFunc, GroupRequestChannelsCFunc, Int32, Bool, Bool) -> CPointer<Unit>>(CPointer<Unit>())
    static var fn_emit_join_payload: CFunc<(CPointer<Unit>, GroupJoinPayloadCFunc, CPointer<Unit>) -> Unit> =
        CFunc<(CPointer<Unit>, GroupJoinPayloadCFunc, CPointer<Unit>) -> Unit>(CPointer<Unit>())
    static var fn_set_connection_mode: CFunc<(CPointer<Unit>, Int32, Bool, Bool) -> Unit> =
        CFunc<(CPointer<Unit>, Int32, Bool, Bool) -> Unit>(CPointer<Unit>())
    static var fn_set_join_response: CFunc<(CPointer<Unit>, CString) -> Unit> =
        CFunc<(CPointer<Unit>, CString) -> Unit>(CPointer<Unit>())
    static var fn_set_muted: CFunc<(CPointer<Unit>, Bool) -> Unit> =
        CFunc<(CPointer<Unit>, Bool) -> Unit>(CPointer<Unit>())
    static var fn_set_noise_suppression: CFunc<(CPointer<Unit>, Bool) -> Unit> =
        CFunc<(CPointer<Unit>, Bool) -> Unit>(CPointer<Unit>())
    static var fn_set_volume: CFunc<(CPointer<Unit>, UInt32, Float64) -> Unit> =
        CFunc<(CPointer<Unit>, UInt32, Float64) -> Unit>(CPointer<Unit>())
    static var fn_remove_ssrcs: CFunc<(CPointer<Unit>, CPointer<UInt32>, Int32) -> Unit> =
        CFunc<(CPointer<Unit>, CPointer<UInt32>, Int32) -> Unit>(CPointer<Unit>())
    static var fn_provide_channels: CFunc<(CPointer<Unit>, Int64, CPointer<UInt32>, CPointer<Int64>, Int32) -> Unit> =
        CFunc<(CPointer<Unit>, Int64, CPointer<UInt32>, CPointer<Int64>, Int32) -> Unit>(CPointer<Unit>())
    static var fn_set_speaker: CFunc<(Bool) -> Unit> =
        CFunc<(Bool) -> Unit>(CPointer<Unit>())
    static var fn_set_video_enabled: CFunc<(CPointer<Unit>, Bool, Bool) -> Unit> =
        CFunc<(CPointer<Unit>, Bool, Bool) -> Unit>(CPointer<Unit>())
    static var fn_switch_camera: CFunc<(CPointer<Unit>, Bool) -> Unit> =
        CFunc<(CPointer<Unit>, Bool) -> Unit>(CPointer<Unit>())
    static var fn_set_local_video_surface: CFunc<(CPointer<Unit>, UInt64, Bool) -> Unit> =
        CFunc<(CPointer<Unit>, UInt64, Bool) -> Unit>(CPointer<Unit>())
    static var fn_set_incoming_video_surface: CFunc<(CPointer<Unit>, CString, UInt64) -> Unit> =
        CFunc<(CPointer<Unit>, CString, UInt64) -> Unit>(CPointer<Unit>())
    static var fn_set_requested_video_channels: CFunc<(CPointer<Unit>, CString) -> Unit> =
        CFunc<(CPointer<Unit>, CString) -> Unit>(CPointer<Unit>())
    // 屏幕共享（可选符号：老库没有时 start(screencast:) 返回 false）
    static var fn_create_screencast: CFunc<(CPointer<Unit>, GroupNetworkCFunc, GroupRequestChannelsCFunc) -> CPointer<Unit>> =
        CFunc<(CPointer<Unit>, GroupNetworkCFunc, GroupRequestChannelsCFunc) -> CPointer<Unit>>(CPointer<Unit>())
    static var fn_set_screen_capture: CFunc<(CPointer<Unit>, Bool) -> Unit> =
        CFunc<(CPointer<Unit>, Bool) -> Unit>(CPointer<Unit>())
    static var hasScreencast: Bool = false
    static var fn_stop: CFunc<(CPointer<Unit>) -> Unit> =
        CFunc<(CPointer<Unit>) -> Unit>(CPointer<Unit>())
    static var fn_destroy: CFunc<(CPointer<Unit>) -> Unit> =
        CFunc<(CPointer<Unit>) -> Unit>(CPointer<Unit>())

    static func ensureResolved(): Bool {
        if (_resolved) { return _ok }
        _resolved = true
        var ok = true
        var sym = TgCallsLib.resolve("tgcalls_group_create")
        if (sym.isNull()) { ok = false } else {
            fn_create = CFunc<(CPointer<Unit>, GroupNetworkCFunc, GroupLevelsCFunc, GroupRequestChannelsCFunc, Int32, Bool, Bool) -> CPointer<Unit>>(sym)
        }
        sym = TgCallsLib.resolve("tgcalls_group_emit_join_payload")
        if (sym.isNull()) { ok = false } else { fn_emit_join_payload = CFunc<(CPointer<Unit>, GroupJoinPayloadCFunc, CPointer<Unit>) -> Unit>(sym) }
        sym = TgCallsLib.resolve("tgcalls_group_set_connection_mode")
        if (sym.isNull()) { ok = false } else { fn_set_connection_mode = CFunc<(CPointer<Unit>, Int32, Bool, Bool) -> Unit>(sym) }
        sym = TgCallsLib.resolve("tgcalls_group_set_join_response")
        if (sym.isNull()) { ok = false } else { fn_set_join_response = CFunc<(CPointer<Unit>, CString) -> Unit>(sym) }
        sym = TgCallsLib.resolve("tgcalls_group_set_muted")
        if (sym.isNull()) { ok = false } else { fn_set_muted = CFunc<(CPointer<Unit>, Bool) -> Unit>(sym) }
        sym = TgCallsLib.resolve("tgcalls_group_set_noise_suppression")
        if (sym.isNull()) { ok = false } else { fn_set_noise_suppression = CFunc<(CPointer<Unit>, Bool) -> Unit>(sym) }
        sym = TgCallsLib.resolve("tgcalls_group_set_volume")
        if (sym.isNull()) { ok = false } else { fn_set_volume = CFunc<(CPointer<Unit>, UInt32, Float64) -> Unit>(sym) }
        sym = TgCallsLib.resolve("tgcalls_group_remove_ssrcs")
        if (sym.isNull()) { ok = false } else { fn_remove_ssrcs = CFunc<(CPointer<Unit>, CPointer<UInt32>, Int32) -> Unit>(sym) }
        sym = TgCallsLib.resolve("tgcalls_group_provide_channels")
        if (sym.isNull()) { ok = false } else { fn_provide_channels = CFunc<(CPointer<Unit>, Int64, CPointer<UInt32>, CPointer<Int64>, Int32) -> Unit>(sym) }
        sym = TgCallsLib.resolve("tgcalls_group_set_speaker")
        if (sym.isNull()) { ok = false } else { fn_set_speaker = CFunc<(Bool) -> Unit>(sym) }
        sym = TgCallsLib.resolve("tgcalls_group_set_video_enabled")
        if (sym.isNull()) { ok = false } else { fn_set_video_enabled = CFunc<(CPointer<Unit>, Bool, Bool) -> Unit>(sym) }
        sym = TgCallsLib.resolve("tgcalls_group_switch_camera")
        if (sym.isNull()) { ok = false } else { fn_switch_camera = CFunc<(CPointer<Unit>, Bool) -> Unit>(sym) }
        sym = TgCallsLib.resolve("tgcalls_group_set_local_video_surface")
        if (sym.isNull()) { ok = false } else { fn_set_local_video_surface = CFunc<(CPointer<Unit>, UInt64, Bool) -> Unit>(sym) }
        sym = TgCallsLib.resolve("tgcalls_group_set_incoming_video_surface")
        if (sym.isNull()) { ok = false } else { fn_set_incoming_video_surface = CFunc<(CPointer<Unit>, CString, UInt64) -> Unit>(sym) }
        sym = TgCallsLib.resolve("tgcalls_group_set_requested_video_channels")
        if (sym.isNull()) { ok = false } else { fn_set_requested_video_channels = CFunc<(CPointer<Unit>, CString) -> Unit>(sym) }
        sym = TgCallsLib.resolve("tgcalls_group_create_screencast")
        if (!sym.isNull()) { fn_create_screencast = CFunc<(CPointer<Unit>, GroupNetworkCFunc, GroupRequestChannelsCFunc) -> CPointer<Unit>>(sym) }
        sym = TgCallsLib.resolve("tgcalls_group_set_screen_capture")
        if (!sym.isNull()) { fn_set_screen_capture = CFunc<(CPointer<Unit>, Bool) -> Unit>(sym); hasScreencast = true }
        sym = TgCallsLib.resolve("tgcalls_group_stop")
        if (sym.isNull()) { ok = false } else { fn_stop = CFunc<(CPointer<Unit>) -> Unit>(sym) }
        sym = TgCallsLib.resolve("tgcalls_group_destroy")
        if (sym.isNull()) { ok = false } else { fn_destroy = CFunc<(CPointer<Unit>) -> Unit>(sym) }
        _ok = ok
        Hilog.info(0, "CjTelegram", "[TgGroupBridge] symbols resolved ok=${ok}")
        return ok
    }
}

/**
 * M8.0 探针：试着启动一次系统屏幕采集（OH_AVScreenCapture），把状态变化和收到的帧数打到 hilog
 *（tag tgcalls_ohos，前缀 [screen]）。返回 0 = 已启动，1 = 已有一次在跑，-1 = 库里没有这个符号。
 */
public func probeScreenCapture(seconds: Int32): Int32 {
    let sym = TgCallsLib.resolve("tgcalls_screen_capture_probe")
    if (sym.isNull()) { return -1 }
    let fn = CFunc<(Int32, Int32, Int32) -> Int32>(sym)
    return unsafe { fn(seconds, 720, 1280) }
}

public class TgGroupCallEngine {
    private var _instance: CPointer<Unit> = CPointer<Unit>()
    private var _slot: Int64 = 0
    private var _slotPtr: CPointer<Int64> = CPointer<Int64>()

    public func isActive(): Bool { return !this._instance.isNull() }

    /**
     * 创建引擎。iOS：outgoingAudioBitrateKbit 默认 32（GroupCallContext.swift:645），
     * 噪声抑制初始关闭（PresentationGroupCall.swift:1889）。
     */
    public func start(
        onNetworkState: (Bool, Bool, Int32) -> Unit,
        onAudioLevels: (ArrayList<GroupAudioLevel>) -> Unit,
        onRequestChannels: (Int64, ArrayList<UInt32>) -> Unit,
        outgoingAudioBitrateKbit!: Int32 = 32,
        enableNoiseSuppression!: Bool = false,
        disableAudioInput!: Bool = false      // 屏幕共享用的第二实例不采麦克风（iOS screencast context 同）
    ): Bool {
        if (!this._instance.isNull()) { return true }
        if (!TgGroupLib.ensureResolved()) {
            Hilog.info(0, "CjTelegram", "[TgGroupBridge] group symbols missing in libtgcalls_ohos.so")
            return false
        }
        let cbs = GroupEngineCallbacks()
        cbs.network = Some(onNetworkState)
        cbs.levels = Some(onAudioLevels)
        cbs.requestChannels = Some(onRequestChannels)
        var slot: Int64 = 0
        synchronized(g_groupSlotLock) {
            slot = g_groupNextSlot
            g_groupNextSlot = g_groupNextSlot + 1
            g_groupSlots[slot] = cbs
        }
        let slotPtr = unsafe { LibC.malloc<Int64>(count: 1) }
        unsafe { slotPtr.write(slot) }
        let inst = unsafe {
            TgGroupLib.fn_create(CPointer<Unit>(slotPtr), onGroupNetworkState_C, onGroupAudioLevels_C,
                onGroupRequestChannels_C, outgoingAudioBitrateKbit, enableNoiseSuppression, disableAudioInput)
        }
        if (inst.isNull()) {
            Hilog.info(0, "CjTelegram", "[TgGroupBridge] tgcalls_group_create returned NULL")
            synchronized(g_groupSlotLock) { g_groupSlots.remove(slot) }
            unsafe { LibC.free(slotPtr) }
            return false
        }
        this._instance = inst
        this._slot = slot
        this._slotPtr = slotPtr
        Hilog.info(0, "CjTelegram", "[TgGroupBridge] engine created (slot ${slot})")
        return true
    }

    /** 异步：引擎在自己的线程生成 ufrag/pwd/fingerprint/ssrc 后回调 (json, audioSsrc)。 */
    public func emitJoinPayload(completion: (String, UInt32) -> Unit): Unit {
        if (this._instance.isNull()) { return }
        synchronized(g_groupSlotLock) {
            match (g_groupSlots.get(this._slot)) {
                case Some(cbs) => cbs.joinPayload = Some(completion)
                case None => ()
            }
        }
        unsafe { TgGroupLib.fn_emit_join_payload(this._instance, onGroupJoinPayload_C, CPointer<Unit>(this._slotPtr)) }
    }

    public func setConnectionMode(mode: GroupConnectionMode, keepBroadcastIfWasEnabled!: Bool = false,
                                  isUnifiedBroadcast!: Bool = false): Unit {
        if (this._instance.isNull()) { return }
        let m: Int32 = match (mode) {
            case ModeNone => 0
            case ModeRtc => 1
            case ModeBroadcast => 2
        }
        unsafe { TgGroupLib.fn_set_connection_mode(this._instance, m, keepBroadcastIfWasEnabled, isUnifiedBroadcast) }
    }

    public func setJoinResponse(json: String): Unit {
        if (this._instance.isNull()) { return }
        unsafe {
            let c = LibC.mallocCString(json)
            TgGroupLib.fn_set_join_response(this._instance, c)
            LibC.free(c)
        }
    }

    public func setMuted(isMuted: Bool): Unit {
        if (this._instance.isNull()) { return }
        unsafe { TgGroupLib.fn_set_muted(this._instance, isMuted) }
    }

    /** 听筒 / 扬声器（进程级；引擎未建也可先设，渲染器创建时会应用）。 */
    public func setSpeaker(speaker: Bool): Unit {
        if (!TgGroupLib.ensureResolved()) { return }
        unsafe { TgGroupLib.fn_set_speaker(speaker) }
    }

    public func setNoiseSuppression(enabled: Bool): Unit {
        if (this._instance.isNull()) { return }
        unsafe { TgGroupLib.fn_set_noise_suppression(this._instance, enabled) }
    }

    /** volume：1.0 = 100%（iOS 传 participant.volume / 10000.0）。 */
    public func setVolume(ssrc: UInt32, volume: Float64): Unit {
        if (this._instance.isNull()) { return }
        unsafe { TgGroupLib.fn_set_volume(this._instance, ssrc, volume) }
    }

    public func removeSsrcs(ssrcs: ArrayList<UInt32>): Unit {
        if (this._instance.isNull() || ssrcs.size == 0) { return }
        unsafe {
            let buf = LibC.malloc<UInt32>(count: ssrcs.size)
            var i: Int64 = 0
            while (i < ssrcs.size) {
                (buf + i).write(ssrcs[i])
                i = i + 1
            }
            TgGroupLib.fn_remove_ssrcs(this._instance, buf, Int32(ssrcs.size))
            LibC.free(buf)
        }
    }

    /** 回答引擎的未知 ssrc 查询；查不到的 ssrc 直接不放进来（空回答合法）。 */
    public func provideChannels(requestId: Int64, ssrcs: ArrayList<UInt32>, userIds: ArrayList<Int64>): Unit {
        if (this._instance.isNull()) { return }
        let n = ssrcs.size
        unsafe {
            if (n == 0) {
                TgGroupLib.fn_provide_channels(this._instance, requestId, CPointer<UInt32>(), CPointer<Int64>(), 0)
                return
            }
            let sBuf = LibC.malloc<UInt32>(count: n)
            let uBuf = LibC.malloc<Int64>(count: n)
            var i: Int64 = 0
            while (i < n) {
                (sBuf + i).write(ssrcs[i])
                (uBuf + i).write(userIds[i])
                i = i + 1
            }
            TgGroupLib.fn_provide_channels(this._instance, requestId, sBuf, uBuf, Int32(n))
            LibC.free(sBuf)
            LibC.free(uBuf)
        }
    }

    // ==================== 视频 ====================

    /**
     * 屏幕共享专用引擎（iOS screencast OngoingGroupCallContext）：不采麦、VideoContentType=Screencast。
     * 之后 emitJoinPayload → phone.joinGroupCallPresentation → setJoinResponse，再 setScreenCapture(true)。
     */
    public func startScreencast(
        onNetworkState: (Bool, Bool, Int32) -> Unit,
        onRequestChannels: (Int64, ArrayList<UInt32>) -> Unit
    ): Bool {
        if (!this._instance.isNull()) { return true }
        if (!TgGroupLib.ensureResolved() || !TgGroupLib.hasScreencast) {
            Hilog.info(0, "CjTelegram", "[TgGroupBridge] screencast symbols missing in libtgcalls_ohos.so")
            return false
        }
        let cbs = GroupEngineCallbacks()
        cbs.network = Some(onNetworkState)
        cbs.requestChannels = Some(onRequestChannels)
        var slot: Int64 = 0
        synchronized(g_groupSlotLock) {
            slot = g_groupNextSlot
            g_groupNextSlot = g_groupNextSlot + 1
            g_groupSlots[slot] = cbs
        }
        let slotPtr = unsafe { LibC.malloc<Int64>(count: 1) }
        unsafe { slotPtr.write(slot) }
        let inst = unsafe {
            TgGroupLib.fn_create_screencast(CPointer<Unit>(slotPtr), onGroupNetworkState_C, onGroupRequestChannels_C)
        }
        if (inst.isNull()) {
            synchronized(g_groupSlotLock) { g_groupSlots.remove(slot) }
            unsafe { LibC.free(slotPtr) }
            return false
        }
        this._instance = inst
        this._slot = slot
        this._slotPtr = slotPtr
        Hilog.info(0, "CjTelegram", "[TgGroupBridge] screencast engine created (slot ${slot})")
        return true
    }

    public func setScreenCapture(enabled: Bool): Unit {
        if (this._instance.isNull() || !TgGroupLib.hasScreencast) { return }
        unsafe { TgGroupLib.fn_set_screen_capture(this._instance, enabled) }
    }

    public func setVideoEnabled(enabled: Bool, front: Bool): Unit {
        if (this._instance.isNull()) { return }
        unsafe { TgGroupLib.fn_set_video_enabled(this._instance, enabled, front) }
    }

    public func switchCamera(front: Bool): Unit {
        if (this._instance.isNull()) { return }
        unsafe { TgGroupLib.fn_switch_camera(this._instance, front) }
    }

    /** 自己的预览渲染到 XComponent surface；surfaceId=0 解绑。 */
    public func setLocalVideoSurface(surfaceId: UInt64, mirror: Bool): Unit {
        if (this._instance.isNull()) { return }
        unsafe { TgGroupLib.fn_set_local_video_surface(this._instance, surfaceId, mirror) }
    }

    /** 某个 endpoint 的远端视频渲染到 XComponent surface；surfaceId=0 解绑。 */
    public func setIncomingVideoSurface(endpointId: String, surfaceId: UInt64): Unit {
        if (this._instance.isNull()) { return }
        unsafe {
            let c = LibC.mallocCString(endpointId)
            TgGroupLib.fn_set_incoming_video_surface(this._instance, c, surfaceId)
            LibC.free(c)
        }
    }

    /** iOS setRequestedVideoList → setRequestedVideoChannels；json 格式见 C shim。 */
    public func setRequestedVideoChannels(json: String): Unit {
        if (this._instance.isNull()) { return }
        unsafe {
            let c = LibC.mallocCString(json)
            TgGroupLib.fn_set_requested_video_channels(this._instance, c)
            LibC.free(c)
        }
    }

    /** 阻塞至引擎拆除完成（shim 内 5s 上限），随后释放实例。务必在后台线程调用。 */
    public func stop(): Unit {
        if (this._instance.isNull()) { return }
        let inst = this._instance
        let slot = this._slot
        let slotPtr = this._slotPtr
        this._instance = CPointer<Unit>()
        this._slotPtr = CPointer<Int64>()
        // 先摘掉本槽位的回调（只影响自己这个实例），再停引擎；槽位内存要等引擎彻底销毁后才能放
        synchronized(g_groupSlotLock) { g_groupSlots.remove(slot) }
        unsafe {
            TgGroupLib.fn_stop(inst)
            TgGroupLib.fn_destroy(inst)
            if (!slotPtr.isNull()) { LibC.free(slotPtr) }
        }
        Hilog.info(0, "CjTelegram", "[TgGroupBridge] engine stopped (slot ${slot})")
    }
}
