package ohos_app_cangjie_entry.core.voip

/**
 * TgCallsBridge — VoIP FFI 桥接层 (Phase K8, fix #85)
 *
 * 通过 dlopen/dlsym 在运行时加载 libtgcalls_ohos.so，
 * 避免 DT_NEEDED 链接依赖导致 CJ 应用库加载时累计重定位过多崩溃。
 *
 * 设计要点：
 * 1. libtgcalls_ohos.so 不在 cjpm.toml 中通过 -l 链接
 * 2. 所有 tgcalls_* 函数通过 dlsym 获取函数指针，cast 为 CFunc 调用
 * 3. 库在首次 VoIP 操作时加载，不在 app 启动时加载
 * 4. dlopen/dlsym 来自 libc（始终可用，不增加 NEEDED 依赖）
 *
 * 对应 Telegram-iOS 的 OngoingCallThreadLocalContext.mm
 */

import kit.PerformanceAnalysisKit.Hilog

/* ==================== libc dlopen/dlsym (always available) ==================== */

foreign func dlopen(path: CString, flags: Int32): CPointer<Unit>
foreign func dlsym(handle: CPointer<Unit>, symbol: CString): CPointer<Unit>
foreign func dlclose(handle: CPointer<Unit>): Int32
foreign func dlerror(): CPointer<UInt8>
foreign func memcpy(dest: CPointer<UInt8>, src: CPointer<UInt8>, n: UIntNative): CPointer<UInt8>

// RTLD_LAZY = 1 on OHOS/Linux
let RTLD_LAZY: Int32 = 1

/* ==================== C Callback Bridges ==================== */

/**
 * 全局回调持有者 — 存储 Cangjie 侧回调 lambda。
 * 当前只支持单个通话实例（与 Telegram 设计一致）。
 */
var g_stateCallback: Option<(Int32) -> Unit> = None
var g_signalBarsCallback: Option<(Int32) -> Unit> = None
var g_audioLevelCallback: Option<(Float32) -> Unit> = None
var g_signalingDataCallback: Option<(Array<Byte>) -> Unit> = None
var g_remoteMediaStateCallback: Option<(Int32, Int32) -> Unit> = None
var g_videoFrameCallback: Option<(Array<Byte>, Int32, Int32) -> Unit> = None
var g_localVideoFrameCallback: Option<(Array<Byte>, Int32, Int32) -> Unit> = None

// C → Cangjie: 状态变化
@C
func onStateChanged_C(_userData: CPointer<Unit>, state: Int32): Unit {
    Hilog.info(0, "CjTelegram", "[TgCallsBridge @C] onStateChanged_C called! state=${state}")
    match (g_stateCallback) {
        case Some(cb) =>
            try {
                Hilog.info(0, "CjTelegram", "[TgCallsBridge @C] Dispatching state to CJ callback")
                cb(state)
                Hilog.info(0, "CjTelegram", "[TgCallsBridge @C] State callback returned OK")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[TgCallsBridge @C] EXCEPTION in state callback: ${e}")
            }
        case None =>
            Hilog.info(0, "CjTelegram", "[TgCallsBridge @C] WARNING: g_stateCallback is None!")
    }
}

// C → Cangjie: 信号强度
@C
func onSignalBars_C(_userData: CPointer<Unit>, bars: Int32): Unit {
    Hilog.info(0, "CjTelegram", "[TgCallsBridge @C] onSignalBars_C called! bars=${bars}")
    match (g_signalBarsCallback) {
        case Some(cb) => cb(bars)
        case None => ()
    }
}

// C → Cangjie: 音频电平
@C
func onAudioLevel_C(_userData: CPointer<Unit>, level: Float32): Unit {
    // No logging here to avoid spam
    match (g_audioLevelCallback) {
        case Some(cb) => cb(level)
        case None => ()
    }
}

// C → Cangjie: 信令数据
@C
func onSignalingData_C(_userData: CPointer<Unit>, data: CPointer<UInt8>, size: Int32): Unit {
    Hilog.info(0, "CjTelegram", "[TgCallsBridge @C] onSignalingData_C called! size=${size}")
    if (size <= 0) { return }
    let arr = Array<Byte>(Int64(size), repeat: 0)
    var i: Int64 = 0
    while (i < Int64(size)) {
        unsafe {
            arr[i] = (data + i).read()
        }
        i = i + 1
    }
    Hilog.info(0, "CjTelegram", "[TgCallsBridge @C] Data copied (${arr.size} bytes), dispatching to CJ callback")
    match (g_signalingDataCallback) {
        case Some(cb) =>
            try {
                cb(arr)
                Hilog.info(0, "CjTelegram", "[TgCallsBridge @C] Signaling callback returned OK")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[TgCallsBridge @C] EXCEPTION in signaling callback: ${e}")
            }
        case None =>
            Hilog.info(0, "CjTelegram", "[TgCallsBridge @C] WARNING: g_signalingDataCallback is None!")
    }
}

// C → Cangjie: 远端媒体状态 (audio_state, video_state)
@C
func onRemoteMediaState_C(_userData: CPointer<Unit>, audioState: Int32, videoState: Int32): Unit {
    Hilog.info(0, "CjTelegram", "[TgCallsBridge @C] onRemoteMediaState: audio=${audioState} video=${videoState}")
    match (g_remoteMediaStateCallback) {
        case Some(cb) => cb(audioState, videoState)
        case None => ()
    }
}

// C → Cangjie: 远端视频帧 (BGRA8888 from libyuv)
var g_remoteFrameSeq: Int64 = 0

@C
func onVideoFrame_C(_userData: CPointer<Unit>, data: CPointer<UInt8>, size: Int32, width: Int32, height: Int32): Unit {
    g_remoteFrameSeq = g_remoteFrameSeq + 1
    if (g_remoteFrameSeq == 1 || g_remoteFrameSeq % 100 == 0) {
        Hilog.info(0, "CjTelegram", "[TgCallsBridge @C] onVideoFrame_C(REMOTE) #${g_remoteFrameSeq}: BGRA size=${size} ${width}x${height}")
    }
    if (size <= 0) { return }
    try {
        let arr = Array<Byte>(Int64(size), repeat: 0)
        unsafe {
            let handle = acquireArrayRawData(arr)
            let _ = memcpy(handle.pointer, data, UIntNative(size))
            releaseArrayRawData(handle)
        }
        match (g_videoFrameCallback) {
            case Some(cb) => cb(arr, width, height)
            case None =>
                if (g_remoteFrameSeq <= 3) {
                    Hilog.info(0, "CjTelegram", "[TgCallsBridge @C] onVideoFrame_C: NO callback registered")
                }
        }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[TgCallsBridge @C] onVideoFrame_C EXCEPTION: ${e}")
    }
}

// C → Cangjie: 本地视频帧 (BGRA8888 from libyuv)
var g_localFrameSeq: Int64 = 0

@C
func onLocalVideoFrame_C(_userData: CPointer<Unit>, data: CPointer<UInt8>, size: Int32, width: Int32, height: Int32): Unit {
    g_localFrameSeq = g_localFrameSeq + 1
    if (g_localFrameSeq == 1 || g_localFrameSeq % 30 == 0) {
        Hilog.info(0, "CjTelegram", "[TgCallsBridge @C] onLocalVideoFrame_C #${g_localFrameSeq}: BGRA size=${size} ${width}x${height}")
    }
    if (size <= 0) { return }
    try {
        let arr = Array<Byte>(Int64(size), repeat: 0)
        unsafe {
            let handle = acquireArrayRawData(arr)
            let _ = memcpy(handle.pointer, data, UIntNative(size))
            releaseArrayRawData(handle)
        }
        match (g_localVideoFrameCallback) {
            case Some(cb) => cb(arr, width, height)
            case None =>
                if (g_localFrameSeq <= 3) {
                    Hilog.info(0, "CjTelegram", "[TgCallsBridge @C] onLocalVideoFrame_C: NO callback registered")
                }
        }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[TgCallsBridge @C] onLocalVideoFrame_C EXCEPTION: ${e}")
    }
}

// C → Cangjie: 远端电池
@C
func onRemoteBattery_C(_userData: CPointer<Unit>, _isLow: Bool): Unit {
    // 暂不处理
}

/* ==================== Dynamic Library Loader ==================== */

/**
 * TgCallsLib — 延迟加载 libtgcalls_ohos.so 的函数指针表
 *
 * 所有 tgcalls C API 函数通过 dlsym 获取，
 * CPointer<Unit> 强转为对应的 CFunc 类型调用。
 */
public class TgCallsLib {
    private static var _handle: CPointer<Unit> = CPointer<Unit>()
    private static var _loaded: Bool = false
    private static var _loadFailed: Bool = false

    public static var _has_video_output: Bool = false
    public static var _has_switch_camera: Bool = false
    public static var _has_remote_media_state_cb: Bool = false
    public static var _has_local_video_output: Bool = false
    public static var _has_remote_video_surface: Bool = false

    // Function pointers (loaded via dlsym)
    static var fn_builder_new: CFunc<() -> CPointer<Unit>> =
        CFunc<() -> CPointer<Unit>>(CPointer<Unit>())
    static var fn_builder_set_key: CFunc<(CPointer<Unit>, CPointer<UInt8>, Int32) -> Unit> =
        CFunc<(CPointer<Unit>, CPointer<UInt8>, Int32) -> Unit>(CPointer<Unit>())
    static var fn_builder_set_outgoing: CFunc<(CPointer<Unit>, Bool) -> Unit> =
        CFunc<(CPointer<Unit>, Bool) -> Unit>(CPointer<Unit>())
    static var fn_builder_set_version: CFunc<(CPointer<Unit>, CString, Int32) -> Unit> =
        CFunc<(CPointer<Unit>, CString, Int32) -> Unit>(CPointer<Unit>())
    static var fn_builder_set_network_params: CFunc<(CPointer<Unit>, Bool, Bool, Bool) -> Unit> =
        CFunc<(CPointer<Unit>, Bool, Bool, Bool) -> Unit>(CPointer<Unit>())
    static var fn_builder_set_video: CFunc<(CPointer<Unit>, Bool) -> Unit> =
        CFunc<(CPointer<Unit>, Bool) -> Unit>(CPointer<Unit>())
    static var fn_builder_add_rtc_server: CFunc<(CPointer<Unit>, Int64, CString, UInt16, CString, CString, Bool, Bool) -> Unit> =
        CFunc<(CPointer<Unit>, Int64, CString, UInt16, CString, CString, Bool, Bool) -> Unit>(CPointer<Unit>())
    static var fn_builder_add_endpoint: CFunc<(CPointer<Unit>, Int64, CString, CString, UInt16, CPointer<UInt8>, Int32) -> Unit> =
        CFunc<(CPointer<Unit>, Int64, CString, CString, UInt16, CPointer<UInt8>, Int32) -> Unit>(CPointer<Unit>())
    static var fn_builder_create: CFunc<(CPointer<Unit>, CPointer<Unit>, CFunc<(CPointer<Unit>, Int32) -> Unit>, CFunc<(CPointer<Unit>, Int32) -> Unit>, CFunc<(CPointer<Unit>, Float32) -> Unit>, CFunc<(CPointer<Unit>, CPointer<UInt8>, Int32) -> Unit>, CFunc<(CPointer<Unit>, Bool) -> Unit>) -> CPointer<Unit>> =
        CFunc<(CPointer<Unit>, CPointer<Unit>, CFunc<(CPointer<Unit>, Int32) -> Unit>, CFunc<(CPointer<Unit>, Int32) -> Unit>, CFunc<(CPointer<Unit>, Float32) -> Unit>, CFunc<(CPointer<Unit>, CPointer<UInt8>, Int32) -> Unit>, CFunc<(CPointer<Unit>, Bool) -> Unit>) -> CPointer<Unit>>(CPointer<Unit>())
    static var fn_builder_free: CFunc<(CPointer<Unit>) -> Unit> =
        CFunc<(CPointer<Unit>) -> Unit>(CPointer<Unit>())

    static var fn_receive_signaling: CFunc<(CPointer<Unit>, CPointer<UInt8>, Int32) -> Unit> =
        CFunc<(CPointer<Unit>, CPointer<UInt8>, Int32) -> Unit>(CPointer<Unit>())
    static var fn_set_mute: CFunc<(CPointer<Unit>, Bool) -> Unit> =
        CFunc<(CPointer<Unit>, Bool) -> Unit>(CPointer<Unit>())
    static var fn_set_speaker: CFunc<(Bool) -> Unit> =
        CFunc<(Bool) -> Unit>(CPointer<Unit>())
    static var fn_set_network_type: CFunc<(CPointer<Unit>, Int32) -> Unit> =
        CFunc<(CPointer<Unit>, Int32) -> Unit>(CPointer<Unit>())
    static var fn_stop: CFunc<(CPointer<Unit>) -> Unit> =
        CFunc<(CPointer<Unit>) -> Unit>(CPointer<Unit>())
    static var fn_destroy: CFunc<(CPointer<Unit>) -> Unit> =
        CFunc<(CPointer<Unit>) -> Unit>(CPointer<Unit>())

    static var fn_set_video_enabled: CFunc<(CPointer<Unit>, Bool) -> Unit> =
        CFunc<(CPointer<Unit>, Bool) -> Unit>(CPointer<Unit>())
    static var fn_set_video_aspect: CFunc<(CPointer<Unit>, Float32) -> Unit> =
        CFunc<(CPointer<Unit>, Float32) -> Unit>(CPointer<Unit>())
    static var fn_set_video_output: CFunc<(CPointer<Unit>, CFunc<(CPointer<Unit>, CPointer<UInt8>, Int32, Int32, Int32) -> Unit>, CPointer<Unit>) -> Unit> =
        CFunc<(CPointer<Unit>, CFunc<(CPointer<Unit>, CPointer<UInt8>, Int32, Int32, Int32) -> Unit>, CPointer<Unit>) -> Unit>(CPointer<Unit>())
    static var fn_switch_camera: CFunc<(CPointer<Unit>, CString) -> Unit> =
        CFunc<(CPointer<Unit>, CString) -> Unit>(CPointer<Unit>())
    static var fn_set_remote_media_state_cb: CFunc<(CPointer<Unit>, CFunc<(CPointer<Unit>, Int32, Int32) -> Unit>, CPointer<Unit>) -> Unit> =
        CFunc<(CPointer<Unit>, CFunc<(CPointer<Unit>, Int32, Int32) -> Unit>, CPointer<Unit>) -> Unit>(CPointer<Unit>())
    static var fn_set_local_video_output: CFunc<(CPointer<Unit>, CFunc<(CPointer<Unit>, CPointer<UInt8>, Int32, Int32, Int32) -> Unit>, CPointer<Unit>) -> Unit> =
        CFunc<(CPointer<Unit>, CFunc<(CPointer<Unit>, CPointer<UInt8>, Int32, Int32, Int32) -> Unit>, CPointer<Unit>) -> Unit>(CPointer<Unit>())
    static var fn_set_remote_video_surface: CFunc<(UInt64) -> Unit> =
        CFunc<(UInt64) -> Unit>(CPointer<Unit>())
    static var fn_remote_video_surface_active: CFunc<() -> Int32> =
        CFunc<() -> Int32>(CPointer<Unit>())
    public static var _has_surface_active_query: Bool = false

    static var fn_get_versions: CFunc<() -> CPointer<UInt8>> =
        CFunc<() -> CPointer<UInt8>>(CPointer<Unit>())
    static var fn_get_max_layer: CFunc<() -> Int32> =
        CFunc<() -> Int32>(CPointer<Unit>())
    static var fn_free_string: CFunc<(CPointer<UInt8>) -> Unit> =
        CFunc<(CPointer<UInt8>) -> Unit>(CPointer<Unit>())

    /**
     * 从 dlsym 获取的 CPointer<Unit> 转为指定 CFunc 类型。
     * 如果符号未找到返回 false。
     */
    private static func loadSym(name: String): CPointer<Unit> {
        let cName = unsafe { LibC.mallocCString(name) }
        let sym = unsafe { dlsym(_handle, cName) }
        unsafe { LibC.free(cName) }
        if (sym.isNull()) {
            Hilog.info(0, "CjTelegram", "[TgCallsLib] dlsym failed: ${name}")
        }
        return sym
    }

    /**
     * 供同包的群通话桥（TgGroupCallsBridge.cj）按名解析 tgcalls_group_* 符号。
     * 复用同一个 dlopen 句柄，避免二次加载 10MB 的库。
     */
    public static func resolve(name: String): CPointer<Unit> {
        if (!ensureLoaded()) { return CPointer<Unit>() }
        return loadSym(name)
    }

    /**
     * 加载 libtgcalls_ohos.so 并解析所有符号。
     * 返回 true 表示加载成功。
     */
    public static func ensureLoaded(): Bool {
        if (_loaded) { return true }
        if (_loadFailed) { return false }

        Hilog.info(0, "CjTelegram", "[TgCallsLib] Loading libtgcalls_ohos.so via dlopen...")

        // On OHOS, app-bundled native libs are at /data/storage/el1/bundle/libs/arm64/
        // Plain filename dlopen won't find them because the app namespace search path
        // is not inherited by plain POSIX dlopen calls.
        let LIB_PATHS = [
            "/data/storage/el1/bundle/libs/arm64/libtgcalls_ohos.so",
            "libtgcalls_ohos.so"
        ]

        var pathIdx: Int64 = 0
        while (pathIdx < LIB_PATHS.size) {
            let tryPath = LIB_PATHS[pathIdx]
            Hilog.info(0, "CjTelegram", "[TgCallsLib] Trying: ${tryPath}")
            let cPath = unsafe { LibC.mallocCString(tryPath) }
            _handle = unsafe { dlopen(cPath, RTLD_LAZY) }
            unsafe { LibC.free(cPath) }
            if (!_handle.isNull()) {
                Hilog.info(0, "CjTelegram", "[TgCallsLib] dlopen succeeded with: ${tryPath}")
                break
            }
            let errPtr = unsafe { dlerror() }
            let errMsg = if (errPtr.isNull()) { "unknown" } else { unsafe { unsafeCPtrToString(errPtr) } }
            Hilog.info(0, "CjTelegram", "[TgCallsLib] dlopen failed for ${tryPath}: ${errMsg}")
            pathIdx = pathIdx + 1
        }

        if (_handle.isNull()) {
            Hilog.info(0, "CjTelegram", "[TgCallsLib] All dlopen attempts failed!")
            _loadFailed = true
            return false
        }

        Hilog.info(0, "CjTelegram", "[TgCallsLib] Resolving symbols...")

        // Resolve all function pointers
        var ok = true
        var sym: CPointer<Unit>

        sym = loadSym("tgcalls_builder_new")
        if (sym.isNull()) { ok = false } else { fn_builder_new = CFunc<() -> CPointer<Unit>>(sym) }

        sym = loadSym("tgcalls_builder_set_key")
        if (sym.isNull()) { ok = false } else { fn_builder_set_key = CFunc<(CPointer<Unit>, CPointer<UInt8>, Int32) -> Unit>(sym) }

        sym = loadSym("tgcalls_builder_set_outgoing")
        if (sym.isNull()) { ok = false } else { fn_builder_set_outgoing = CFunc<(CPointer<Unit>, Bool) -> Unit>(sym) }

        sym = loadSym("tgcalls_builder_set_version")
        if (sym.isNull()) { ok = false } else { fn_builder_set_version = CFunc<(CPointer<Unit>, CString, Int32) -> Unit>(sym) }

        sym = loadSym("tgcalls_builder_set_network_params")
        if (sym.isNull()) { ok = false } else { fn_builder_set_network_params = CFunc<(CPointer<Unit>, Bool, Bool, Bool) -> Unit>(sym) }

        sym = loadSym("tgcalls_builder_set_video")
        if (!sym.isNull()) { fn_builder_set_video = CFunc<(CPointer<Unit>, Bool) -> Unit>(sym) }

        sym = loadSym("tgcalls_builder_add_rtc_server")
        if (sym.isNull()) { ok = false } else { fn_builder_add_rtc_server = CFunc<(CPointer<Unit>, Int64, CString, UInt16, CString, CString, Bool, Bool) -> Unit>(sym) }

        sym = loadSym("tgcalls_builder_add_endpoint")
        if (sym.isNull()) { ok = false } else { fn_builder_add_endpoint = CFunc<(CPointer<Unit>, Int64, CString, CString, UInt16, CPointer<UInt8>, Int32) -> Unit>(sym) }

        sym = loadSym("tgcalls_builder_create")
        if (sym.isNull()) { ok = false } else { fn_builder_create = CFunc<(CPointer<Unit>, CPointer<Unit>, CFunc<(CPointer<Unit>, Int32) -> Unit>, CFunc<(CPointer<Unit>, Int32) -> Unit>, CFunc<(CPointer<Unit>, Float32) -> Unit>, CFunc<(CPointer<Unit>, CPointer<UInt8>, Int32) -> Unit>, CFunc<(CPointer<Unit>, Bool) -> Unit>) -> CPointer<Unit>>(sym) }

        sym = loadSym("tgcalls_builder_free")
        if (sym.isNull()) { ok = false } else { fn_builder_free = CFunc<(CPointer<Unit>) -> Unit>(sym) }

        sym = loadSym("tgcalls_receive_signaling")
        if (sym.isNull()) { ok = false } else { fn_receive_signaling = CFunc<(CPointer<Unit>, CPointer<UInt8>, Int32) -> Unit>(sym) }

        sym = loadSym("tgcalls_set_mute")
        if (sym.isNull()) { ok = false } else { fn_set_mute = CFunc<(CPointer<Unit>, Bool) -> Unit>(sym) }

        sym = loadSym("tgcalls_set_speaker")
        if (sym.isNull()) { ok = false } else { fn_set_speaker = CFunc<(Bool) -> Unit>(sym) }

        sym = loadSym("tgcalls_set_network_type")
        if (sym.isNull()) { ok = false } else { fn_set_network_type = CFunc<(CPointer<Unit>, Int32) -> Unit>(sym) }

        sym = loadSym("tgcalls_stop")
        if (sym.isNull()) { ok = false } else { fn_stop = CFunc<(CPointer<Unit>) -> Unit>(sym) }

        sym = loadSym("tgcalls_destroy")
        if (sym.isNull()) { ok = false } else { fn_destroy = CFunc<(CPointer<Unit>) -> Unit>(sym) }

        sym = loadSym("tgcalls_set_video_enabled")
        if (sym.isNull()) { ok = false } else { fn_set_video_enabled = CFunc<(CPointer<Unit>, Bool) -> Unit>(sym) }

        sym = loadSym("tgcalls_set_video_aspect")
        if (sym.isNull()) { ok = false } else { fn_set_video_aspect = CFunc<(CPointer<Unit>, Float32) -> Unit>(sym) }

        sym = loadSym("tgcalls_set_video_output")
        if (!sym.isNull()) { fn_set_video_output = CFunc<(CPointer<Unit>, CFunc<(CPointer<Unit>, CPointer<UInt8>, Int32, Int32, Int32) -> Unit>, CPointer<Unit>) -> Unit>(sym); _has_video_output = true }

        sym = loadSym("tgcalls_switch_camera")
        if (!sym.isNull()) { fn_switch_camera = CFunc<(CPointer<Unit>, CString) -> Unit>(sym); _has_switch_camera = true }

        sym = loadSym("tgcalls_set_remote_media_state_cb")
        if (!sym.isNull()) { fn_set_remote_media_state_cb = CFunc<(CPointer<Unit>, CFunc<(CPointer<Unit>, Int32, Int32) -> Unit>, CPointer<Unit>) -> Unit>(sym); _has_remote_media_state_cb = true }

        sym = loadSym("tgcalls_set_local_video_output")
        if (!sym.isNull()) { fn_set_local_video_output = CFunc<(CPointer<Unit>, CFunc<(CPointer<Unit>, CPointer<UInt8>, Int32, Int32, Int32) -> Unit>, CPointer<Unit>) -> Unit>(sym); _has_local_video_output = true }

        // surface 直渲：XComponent surfaceId → 解码器 GPU 直渲（可选符号，旧 .so 无此不阻断）
        sym = loadSym("tgcalls_set_remote_video_surface")
        if (!sym.isNull()) { fn_set_remote_video_surface = CFunc<(UInt64) -> Unit>(sym); _has_remote_video_surface = true }

        sym = loadSym("tgcalls_remote_video_surface_active")
        if (!sym.isNull()) { fn_remote_video_surface_active = CFunc<() -> Int32>(sym); _has_surface_active_query = true }

        sym = loadSym("tgcalls_get_versions")
        if (sym.isNull()) { ok = false } else { fn_get_versions = CFunc<() -> CPointer<UInt8>>(sym) }

        sym = loadSym("tgcalls_get_max_layer")
        if (sym.isNull()) { ok = false } else { fn_get_max_layer = CFunc<() -> Int32>(sym) }

        sym = loadSym("tgcalls_free_string")
        if (sym.isNull()) { ok = false } else { fn_free_string = CFunc<(CPointer<UInt8>) -> Unit>(sym) }

        if (!ok) {
            Hilog.info(0, "CjTelegram", "[TgCallsLib] WARNING: some required symbols not found, VoIP may not work")
        } else {
            Hilog.info(0, "CjTelegram", "[TgCallsLib] All required symbols resolved successfully")
        }

        Hilog.info(0, "CjTelegram", "[TgCallsLib] Video symbol availability: video_output=${_has_video_output} switch_camera=${_has_switch_camera} remote_media_state=${_has_remote_media_state_cb} local_video_output=${_has_local_video_output}")

        _loaded = true
        return true
    }

    public static func isLoaded(): Bool { return _loaded }

    /**
     * surface 直渲：把 XComponent 的 surfaceId 交给原生解码器 GPU 直渲。
     * sid=0 清除。确保 .so 已加载；符号不存在则静默忽略（旧 .so 兼容）。
     */
    // surface 直渲是否激活（sid!=0 且符号存在）。通话页据此隐藏 CPU 渲染的远端
    // Image，让 XComponent surface 透出；未激活则回落 CPU PixelMap 路径。
    public static var surfaceActive: Bool = false
    // 当前绑定的 surfaceId。用于 sid 匹配清除：双 push VideoCallScreen 时，被 pop
    // 的旧 shell 的 onDisAppear 可能晚于存活 shell 的 onLoad 到达，无条件清零会
    // 误杀存活页的绑定（实锤：用户「本地看不到画面」，解码器 surf=1 渲染到已解绑
    // 的 surface，仓颉侧却回落渐变背景盖住 XComponent）。
    public static var currentSurfaceSid: UInt64 = 0

    public static func setRemoteVideoSurface(sid: UInt64): Unit {
        if (!ensureLoaded()) { return }
        if (!_has_remote_video_surface) {
            Hilog.info(0, "CjTelegram", "[TgCallsLib] set_remote_video_surface symbol absent; skip")
            return
        }
        unsafe { fn_set_remote_video_surface(sid) }
        currentSurfaceSid = sid
        surfaceActive = (sid != 0)
        Hilog.info(0, "CjTelegram", "[TgCallsLib] remote video surface set: sid=${sid} active=${surfaceActive}")
    }

    /** 仅当 sid 仍是当前绑定时才清除；旧 shell 迟到的销毁回调对新绑定无效。 */
    public static func clearRemoteVideoSurfaceIf(sid: UInt64): Unit {
        if (sid != 0 && sid != currentSurfaceSid) {
            Hilog.info(0, "CjTelegram",
                "[TgCallsLib] stale surface clear ignored: sid=${sid} current=${currentSurfaceSid}")
            return
        }
        setRemoteVideoSurface(0)
    }

    /**
     * surface 是否已绑定 — 直接问 native（进程级唯一事实源）。
     * 实锤教训：napi 桥（ArkTS 调入）与页面代码可能在不同 Cangjie runtime，
     * 静态变量不共享——桥设了 surfaceActive=true，页面读到 false，导致渐变
     * 背景盖住 XComponent（用户「本地看不到画面」）。页面必须用本函数轮询。
     */
    public static func isRemoteSurfaceActiveNative(): Bool {
        if (!ensureLoaded() || !_has_surface_active_query) { return surfaceActive }
        var r: Int32 = 0
        unsafe { r = fn_remote_video_surface_active() }
        return r != 0
    }
}

/* ==================== Public API Types ==================== */

/**
 * VoIP 通话状态枚举 — 映射 tgcalls State
 */
public enum VoipState {
    | WaitInit
    | WaitInitAck
    | Established
    | Failed
    | Reconnecting
}

/**
 * 将 Int32 转换为 VoipState
 */
public func voipStateFromInt(value: Int32): VoipState {
    if (value == 0) { return VoipState.WaitInit }
    if (value == 1) { return VoipState.WaitInitAck }
    if (value == 2) { return VoipState.Established }
    if (value == 3) { return VoipState.Failed }
    if (value == 4) { return VoipState.Reconnecting }
    return VoipState.Failed
}

/**
 * VoIP 配置 — Cangjie 友好接口
 */
public class VoipConfig {
    public var encryptionKey: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var isOutgoing: Bool = false
    public var isVideo: Bool = false
    public var version: String = "12.0.0"
    public var maxLayer: Int32 = 92
    public var allowP2P: Bool = true
    public var allowTCP: Bool = true
    public var enableStunMarking: Bool = true
    public var customParameters: String = ""

    // WebRTC 服务器
    public var rtcServers: Array<VoipRtcServer> = Array<VoipRtcServer>(0, { _i => VoipRtcServer() })

    // Legacy 端点
    public var endpoints: Array<VoipEndpoint> = Array<VoipEndpoint>(0, { _i => VoipEndpoint() })
}

public class VoipRtcServer {
    public var id: Int64 = 0
    public var host: String = ""
    public var port: UInt16 = 0
    public var username: String = ""
    public var password: String = ""
    public var isTurn: Bool = false
    public var isTcp: Bool = false
}

public class VoipEndpoint {
    public var id: Int64 = 0
    public var ip: String = ""
    public var ipv6: String = ""
    public var port: UInt16 = 0
    public var peerTag: Array<Byte> = Array<Byte>(16, repeat: 0)
}

/* ==================== TgCallsBridge ==================== */

/**
 * TgCallsBridge — FFI 桥接 libtgcalls_ohos.so (runtime dlopen)
 *
 * 使用 Builder API 创建 tgcalls 实例，
 * 所有 FFI 交互通过 dlsym 获取的 CFunc 调用。
 */
public class TgCallsBridge {
    private var _instance: CPointer<Unit> = CPointer<Unit>()
    private var _isActive: Bool = false
    private var _isMuted: Bool = false

    /**
     * 创建 tgcalls 实例 (Runtime dlopen + Builder API)
     */
    public func create(config: VoipConfig,
                       onStateChanged: (Int32) -> Unit,
                       onSignalBars: (Int32) -> Unit,
                       onAudioLevel: (Float32) -> Unit,
                       onSignalingData: (Array<Byte>) -> Unit): Bool {

        // 确保库已加载
        if (!TgCallsLib.ensureLoaded()) {
            Hilog.info(0, "CjTelegram", "[TgCallsBridge] Failed to load libtgcalls_ohos.so")
            return false
        }

        // 设置全局回调
        g_stateCallback = Some(onStateChanged)
        g_signalBarsCallback = Some(onSignalBars)
        g_audioLevelCallback = Some(onAudioLevel)
        g_signalingDataCallback = Some(onSignalingData)

        Hilog.info(0, "CjTelegram", "[TgCallsBridge] Creating instance (outgoing=${config.isOutgoing}, version=${config.version})")
        Hilog.info(0, "CjTelegram", "[TgCallsBridge] key=${config.encryptionKey.size}B, rtcServers=${config.rtcServers.size}, endpoints=${config.endpoints.size}")

        unsafe {
            // 1. 创建 Builder
            let builder = TgCallsLib.fn_builder_new()
            if (builder.isNull()) {
                Hilog.info(0, "CjTelegram", "[TgCallsBridge] Failed to create builder")
                return false
            }

            // 2. 设置加密密钥
            if (config.encryptionKey.size > 0) {
                let keyPtr = LibC.malloc<UInt8>(count: config.encryptionKey.size)
                var ki: Int64 = 0
                while (ki < config.encryptionKey.size) {
                    (keyPtr + ki).write(UInt8(config.encryptionKey[ki]))
                    ki = ki + 1
                }
                TgCallsLib.fn_builder_set_key(builder, keyPtr, Int32(config.encryptionKey.size))
                LibC.free(keyPtr)
            }

            // 3. 设置方向
            TgCallsLib.fn_builder_set_outgoing(builder, config.isOutgoing)

            // 4. 设置版本
            let versionCStr = LibC.mallocCString(config.version)
            TgCallsLib.fn_builder_set_version(builder, versionCStr, config.maxLayer)
            LibC.free(versionCStr)

            // 5. 设置网络参数
            TgCallsLib.fn_builder_set_network_params(builder,
                config.allowP2P, config.allowTCP, config.enableStunMarking)

            // 5b. 标记视频通话 — 使初始 SDP offer 包含视频轨道
            TgCallsLib.fn_builder_set_video(builder, config.isVideo)

            // 6. 添加 RTC 服务器
            var ri: Int64 = 0
            while (ri < config.rtcServers.size) {
                let server = config.rtcServers[ri]
                let hostCStr = LibC.mallocCString(server.host)
                let userCStr = LibC.mallocCString(server.username)
                let passCStr = LibC.mallocCString(server.password)
                TgCallsLib.fn_builder_add_rtc_server(builder,
                    server.id, hostCStr, server.port,
                    userCStr, passCStr,
                    server.isTurn, server.isTcp)
                LibC.free(hostCStr)
                LibC.free(userCStr)
                LibC.free(passCStr)
                ri = ri + 1
            }

            // 7. 添加 Legacy 端点
            var ei: Int64 = 0
            while (ei < config.endpoints.size) {
                let ep = config.endpoints[ei]
                let ipCStr = LibC.mallocCString(ep.ip)
                let ipv6CStr = LibC.mallocCString(ep.ipv6)
                let tagPtr = LibC.malloc<UInt8>(count: 16)
                var ti: Int64 = 0
                while (ti < 16 && ti < ep.peerTag.size) {
                    (tagPtr + ti).write(UInt8(ep.peerTag[ti]))
                    ti = ti + 1
                }
                TgCallsLib.fn_builder_add_endpoint(builder,
                    ep.id, ipCStr, ipv6CStr, ep.port, tagPtr, 16)
                LibC.free(ipCStr)
                LibC.free(ipv6CStr)
                LibC.free(tagPtr)
                ei = ei + 1
            }

            // 8. 创建实例
            let inst = TgCallsLib.fn_builder_create(builder,
                CPointer<Unit>(),
                onStateChanged_C,
                onSignalBars_C,
                onAudioLevel_C,
                onSignalingData_C,
                onRemoteBattery_C)

            if (inst.isNull()) {
                Hilog.info(0, "CjTelegram", "[TgCallsBridge] tgcalls_builder_create returned NULL")
                return false
            }

            this._instance = inst
            this._isActive = true

            Hilog.info(0, "CjTelegram", "[TgCallsBridge] Instance created successfully")
            return true
        }
    }

    /**
     * 接收信令数据
     */
    public func receiveSignaling(data: Array<Byte>): Unit {
        if (!this._isActive) { return }
        Hilog.info(0, "CjTelegram", "[TgCallsBridge] Sending signaling to C: ${data.size} bytes")
        unsafe {
            let ptr = LibC.malloc<UInt8>(count: data.size)
            var i: Int64 = 0
            while (i < data.size) {
                (ptr + i).write(UInt8(data[i]))
                i = i + 1
            }
            TgCallsLib.fn_receive_signaling(this._instance, ptr, Int32(data.size))
            LibC.free(ptr)
        }
    }

    /**
     * 设置静音
     */
    public func setMuted(muted: Bool): Unit {
        if (!this._isActive) { return }
        this._isMuted = muted
        unsafe {
            TgCallsLib.fn_set_mute(this._instance, muted)
        }
        Hilog.info(0, "CjTelegram", "[TgCallsBridge] Mute: ${muted}")
    }

    /**
     * 切换扬声器/听筒
     */
    public func setSpeaker(speaker: Bool): Unit {
        unsafe {
            TgCallsLib.fn_set_speaker(speaker)
        }
        Hilog.info(0, "CjTelegram", "[TgCallsBridge] Speaker: ${speaker}")
    }

    /**
     * 设置网络类型 — 对应 tgcalls setNetworkType
     * @param networkType 0=Unknown, 1=GPRS, 2=EDGE, 3=3G, 4=HSPA, 5=LTE, 6=WiFi
     */
    public func setNetworkType(networkType: Int32): Unit {
        if (!this._isActive) { return }
        unsafe {
            TgCallsLib.fn_set_network_type(this._instance, networkType)
        }
        Hilog.info(0, "CjTelegram", "[TgCallsBridge] setNetworkType: ${networkType}")
    }

    /**
     * 停止通话
     */
    public func stop(): Unit {
        if (!this._isActive) { return }
        Hilog.info(0, "CjTelegram", "[TgCallsBridge] Stopping...")
        unsafe {
            TgCallsLib.fn_stop(this._instance)
        }
    }

    /**
     * 销毁实例
     */
    public func destroy(): Unit {
        if (!this._isActive) { return }
        this._isActive = false
        Hilog.info(0, "CjTelegram", "[TgCallsBridge] Destroying...")
        unsafe {
            TgCallsLib.fn_destroy(this._instance)
        }
        this._instance = CPointer<Unit>()

        // 清除全局回调
        g_stateCallback = None
        g_signalBarsCallback = None
        g_audioLevelCallback = None
        g_signalingDataCallback = None
        g_remoteMediaStateCallback = None
        g_videoFrameCallback = None
        g_localVideoFrameCallback = None

        Hilog.info(0, "CjTelegram", "[TgCallsBridge] Destroyed")
    }

    /**
     * 启用/禁用视频
     */
    public func setVideoEnabled(enabled: Bool): Unit {
        if (!this._isActive) {
            Hilog.info(0, "CjTelegram", "[TgCallsBridge] setVideoEnabled(${enabled}): SKIPPED — bridge not active")
            return
        }
        unsafe {
            TgCallsLib.fn_set_video_enabled(this._instance, enabled)
        }
        Hilog.info(0, "CjTelegram", "[TgCallsBridge] setVideoEnabled(${enabled}): called native fn OK")
    }

    /**
     * 设置远端视频帧输出回调
     * tgcalls 解码远端视频后通过此回调传递帧数据
     */
    public func setVideoOutput(onFrame: (Array<Byte>, Int32, Int32) -> Unit): Unit {
        if (!this._isActive) { return }
        g_videoFrameCallback = Some(onFrame)
        if (!TgCallsLib._has_video_output) {
            Hilog.info(0, "CjTelegram", "[TgCallsBridge] setVideoOutput: symbol not available, skipping")
            return
        }
        unsafe {
            TgCallsLib.fn_set_video_output(this._instance, onVideoFrame_C, CPointer<Unit>())
        }
        Hilog.info(0, "CjTelegram", "[TgCallsBridge] Video output callback set")
    }

    /**
     * 设置本地视频帧输出回调（用于 PiP 预览）
     * 本地摄像头捕获帧通过此回调传递
     */
    public func setLocalVideoOutput(onFrame: (Array<Byte>, Int32, Int32) -> Unit): Unit {
        if (!this._isActive) { return }
        g_localVideoFrameCallback = Some(onFrame)
        if (!TgCallsLib._has_local_video_output) {
            Hilog.info(0, "CjTelegram", "[TgCallsBridge] setLocalVideoOutput: symbol not available, skipping")
            return
        }
        unsafe {
            TgCallsLib.fn_set_local_video_output(this._instance, onLocalVideoFrame_C, CPointer<Unit>())
        }
        Hilog.info(0, "CjTelegram", "[TgCallsBridge] Local video output callback set")
    }

    /**
     * 切换前后摄像头
     * @param deviceId "front" 或 "back"（空字符串 = 前置）
     */
    public func switchCamera(deviceId: String): Unit {
        if (!this._isActive) { return }
        if (!TgCallsLib._has_switch_camera) {
            Hilog.info(0, "CjTelegram", "[TgCallsBridge] switchCamera: symbol not available, skipping")
            return
        }
        unsafe {
            let cStr = LibC.mallocCString(deviceId)
            TgCallsLib.fn_switch_camera(this._instance, cStr)
            LibC.free(cStr)
        }
        Hilog.info(0, "CjTelegram", "[TgCallsBridge] switchCamera: ${deviceId}")
    }

    /**
     * 设置远端媒体状态回调
     */
    public func setRemoteMediaStateCallback(cb: (Int32, Int32) -> Unit): Unit {
        g_remoteMediaStateCallback = Some(cb)
        if (this._isActive && TgCallsLib._has_remote_media_state_cb) {
            unsafe {
                TgCallsLib.fn_set_remote_media_state_cb(this._instance, onRemoteMediaState_C, CPointer<Unit>())
            }
        }
        Hilog.info(0, "CjTelegram", "[TgCallsBridge] Remote media state callback set (available=${TgCallsLib._has_remote_media_state_cb})")
    }

    /**
     * 设置视频宽高比
     */
    public func setVideoAspect(aspect: Float32): Unit {
        if (!this._isActive) { return }
        unsafe {
            TgCallsLib.fn_set_video_aspect(this._instance, aspect)
        }
    }

    /**
     * 获取支持的 tgcalls 版本列表
     */
    public static func getVersions(): String {
        if (!TgCallsLib.ensureLoaded()) { return "12.0.0" }
        unsafe {
            let cStr = TgCallsLib.fn_get_versions()
            if (cStr.isNull()) { return "12.0.0" }
            let result = unsafeCPtrToString(cStr)
            TgCallsLib.fn_free_string(cStr)
            return result
        }
    }

    /**
     * 获取最大协议层
     */
    public static func getMaxLayer(): Int32 {
        if (!TgCallsLib.ensureLoaded()) { return 92 }
        unsafe {
            return TgCallsLib.fn_get_max_layer()
        }
    }

    public func isActive(): Bool { return this._isActive }
}

/* ==================== Helpers ==================== */

/**
 * 将 C 字符串 (CPointer<UInt8>) 转换为 Cangjie String
 */
unsafe func unsafeCPtrToString(cstr: CPointer<UInt8>): String {
    if (cstr.isNull()) { return "" }
    var len: Int64 = 0
    while ((cstr + len).read() != 0) {
        len = len + 1
        if (len > 4096) { break }
    }
    if (len == 0) { return "" }
    let bytes = Array<Byte>(len, repeat: 0)
    var i: Int64 = 0
    while (i < len) {
        bytes[i] = (cstr + i).read()
        i = i + 1
    }
    return String.fromUtf8(bytes)
}
