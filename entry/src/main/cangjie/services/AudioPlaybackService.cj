package ohos_app_cangjie_entry.services

/**
 * AudioPlaybackService — 纯 Cangjie 音频播放服务
 *
 * 通过 dlopen/dlsym 加载系统 libohaudio.so，
 * 使用 OH_AudioStreamBuilder + OH_AudioRenderer 原生 API 播放 PCM/WAV 音频。
 * 无需修改任何 C++ 代码。
 *
 * 播放参数：自适应 WAV header（默认 16kHz / Mono / S16LE）
 *
 * P2-229 音频中断会话协调（真做）：
 *   ohRendererOnInterruptEvent @C 回调注册到 OHRendererCbs.onInterruptEvent。
 *   C 签名：(OH_AudioRenderer*, void* userData, OH_AudioInterrupt_ForceType, OH_AudioInterrupt_Hint)
 *   ForceType: 0=NONE, 1=FORCE_STOP, 2=FORCE_PAUSE
 *   Hint:      0=NONE, 1=RESUME, 2=PAUSE, 3=STOP, 4=DUCK, 5=UNDUCK
 *   当 forceType=FORCE_STOP(1) 或 FORCE_PAUSE(2) 时，标记 g_playInterrupted=true 并清除 g_playing。
 *   TelegramAudioService.waitForPlaybackFinish 通过 isInterrupted() 感知中断、自增 _interruptCount。
 *
 * deferred:
 *   - CMTimebase 时钟同步（无 HarmonyOS 对应 API）
 *   - AUGraph mixer/gain/EQ DSP 链（无 HarmonyOS Cangjie 公开对等 API）
 *   - RingBuffer 低水位反馈（缺等价 audio unit graph 接口）
 */

import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*

// dlopen/dlsym/memcpy declared in AudioCaptureService.cj (same package)

let PLAYBACK_RTLD_LAZY: Int32 = 1
let PLAYBACK_TYPE_RENDERER: Int32 = 1
let PLAYBACK_USAGE_MUSIC: Int32 = 1

// OH_AudioInterrupt_ForceType 常量（对应 libohaudio.so 枚举，值来自 OHAudio C API 头文件）
let OHAUDIO_INTERRUPT_FORCE_NONE: Int32 = 0
let OHAUDIO_INTERRUPT_FORCE_STOP: Int32 = 1
let OHAUDIO_INTERRUPT_FORCE_PAUSE: Int32 = 2

@C
struct OHRendererCbs {
    var onWriteData: CFunc<(CPointer<Unit>, CPointer<Unit>, CPointer<UInt8>, Int32) -> Int32> =
        CFunc<(CPointer<Unit>, CPointer<Unit>, CPointer<UInt8>, Int32) -> Int32>(CPointer<Unit>())
    var onStreamEvent: CPointer<Unit> = CPointer<Unit>()
    var onInterruptEvent: CFunc<(CPointer<Unit>, CPointer<Unit>, Int32, Int32) -> Unit> =
        CFunc<(CPointer<Unit>, CPointer<Unit>, Int32, Int32) -> Unit>(CPointer<Unit>())
    var onError: CPointer<Unit> = CPointer<Unit>()
}

var g_playBuffer: Array<Byte> = Array<Byte>(0, repeat: 0)
var g_playOffset: Int64 = 0
var g_playSize: Int64 = 0
var g_playing: Bool = false
var g_playFinished: Bool = false

/**
 * 音频中断标志（P2-229 真做）
 * 由 ohRendererOnInterruptEvent 回调置 true；由 stopPlayback/playFile 复位
 */
var g_playInterrupted: Bool = false

/**
 * OH_AudioRenderer 中断事件回调（P2-229 音频会话协调）
 *
 * 对应 iOS ManagedAudioSession 的 AVAudioSession.interruptionNotification：
 *   AVAudioSession.InterruptionType.began → 停止播放
 *   AVAudioSession.InterruptionType.ended → 可恢复（由 TelegramAudioService 决策）
 *
 * HarmonyOS 等价：OH_AudioStreamBuilder_SetRendererCallback 的 onInterruptEvent 字段
 *   ForceType=FORCE_STOP(1) 或 FORCE_PAUSE(2) → 标记中断，清除播放状态
 *   ForceType=NONE(0)，Hint=RESUME(1) → 可恢复（resume 由 TelegramAudioService 决策）
 *
 * deferred（KB 查询 "OH_AudioRenderer interrupt callback renderer" 最高分 0.016 无命中）：
 *   实际 C 结构体字段名称及枚举值来自 OHAudio C 头文件常量，非 Cangjie KB 文档；
 *   如实际 SDK 版本枚举偏移，需按真实设备日志校正常量值。
 */
@C
func ohRendererOnInterruptEvent(
    _renderer: CPointer<Unit>,
    _userData: CPointer<Unit>,
    forceType: Int32,
    _hint: Int32
): Unit {
    if (forceType == OHAUDIO_INTERRUPT_FORCE_STOP || forceType == OHAUDIO_INTERRUPT_FORCE_PAUSE) {
        g_playing = false
        g_playInterrupted = true
        Hilog.info(0, "CjTelegram", "[AudioPlayback] Interrupt received forceType=${forceType}")
    }
}

@C
func ohRendererOnWriteData(
    _renderer: CPointer<Unit>,
    _userData: CPointer<Unit>,
    buffer: CPointer<UInt8>,
    length: Int32
): Int32 {
    if (!g_playing || length <= 0) {
        return 0
    }
    let remaining = g_playSize - g_playOffset
    if (remaining <= 0) {
        g_playFinished = true
        g_playing = false
        return 0
    }
    let toCopy = if (Int64(length) > remaining) { remaining } else { Int64(length) }
    unsafe {
        let handle = acquireArrayRawData(g_playBuffer)
        let src = handle.pointer + g_playOffset
        let _ = memcpy(buffer, src, UIntNative(toCopy))
        releaseArrayRawData(handle)
    }
    g_playOffset = g_playOffset + toCopy

    if (toCopy < Int64(length)) {
        g_playFinished = true
        g_playing = false
    }
    return 0
}

public class AudioPlaybackService {
    private static var _lib: CPointer<Unit> = CPointer<Unit>()
    private static var _loaded: Bool = false
    private static var _failed: Bool = false
    private static var _builder: CPointer<Unit> = CPointer<Unit>()
    private static var _renderer: CPointer<Unit> = CPointer<Unit>()

    static var fnCreate: CFunc<(CPointer<Unit>, Int32) -> Int32> =
        CFunc<(CPointer<Unit>, Int32) -> Int32>(CPointer<Unit>())
    static var fnDestroy: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())
    static var fnSetRate: CFunc<(CPointer<Unit>, Int32) -> Int32> =
        CFunc<(CPointer<Unit>, Int32) -> Int32>(CPointer<Unit>())
    static var fnSetCh: CFunc<(CPointer<Unit>, Int32) -> Int32> =
        CFunc<(CPointer<Unit>, Int32) -> Int32>(CPointer<Unit>())
    static var fnSetFmt: CFunc<(CPointer<Unit>, Int32) -> Int32> =
        CFunc<(CPointer<Unit>, Int32) -> Int32>(CPointer<Unit>())
    static var fnSetEnc: CFunc<(CPointer<Unit>, Int32) -> Int32> =
        CFunc<(CPointer<Unit>, Int32) -> Int32>(CPointer<Unit>())
    static var fnSetUsage: CFunc<(CPointer<Unit>, Int32) -> Int32> =
        CFunc<(CPointer<Unit>, Int32) -> Int32>(CPointer<Unit>())
    static var fnSetCb: CFunc<(CPointer<Unit>, OHRendererCbs, CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>, OHRendererCbs, CPointer<Unit>) -> Int32>(CPointer<Unit>())
    static var fnGenRen: CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(CPointer<Unit>())
    static var fnStart: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())
    static var fnStop: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())
    static var fnRelease: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())

    private static func sym(name: String): CPointer<Unit> {
        let cs = unsafe { LibC.mallocCString(name) }
        let p = unsafe { dlsym(_lib, cs) }
        unsafe { LibC.free(cs) }
        if (p.isNull()) {
            Hilog.info(0, "CjTelegram", "[AudioPlayback] dlsym miss: ${name}")
        }
        return p
    }

    private static func load(): Bool {
        if (_loaded) { return true }
        if (_failed) { return false }

        Hilog.info(0, "CjTelegram", "[AudioPlayback] Loading libohaudio.so...")
        let cs = unsafe { LibC.mallocCString("libohaudio.so") }
        _lib = unsafe { dlopen(cs, PLAYBACK_RTLD_LAZY) }
        unsafe { LibC.free(cs) }
        if (_lib.isNull()) {
            Hilog.info(0, "CjTelegram", "[AudioPlayback] dlopen FAILED")
            _failed = true
            return false
        }

        var ok = true
        var s: CPointer<Unit>

        s = sym("OH_AudioStreamBuilder_Create")
        if (s.isNull()) { ok = false } else { fnCreate = CFunc<(CPointer<Unit>, Int32) -> Int32>(s) }

        s = sym("OH_AudioStreamBuilder_Destroy")
        if (s.isNull()) { ok = false } else { fnDestroy = CFunc<(CPointer<Unit>) -> Int32>(s) }

        s = sym("OH_AudioStreamBuilder_SetSamplingRate")
        if (s.isNull()) { ok = false } else { fnSetRate = CFunc<(CPointer<Unit>, Int32) -> Int32>(s) }

        s = sym("OH_AudioStreamBuilder_SetChannelCount")
        if (s.isNull()) { ok = false } else { fnSetCh = CFunc<(CPointer<Unit>, Int32) -> Int32>(s) }

        s = sym("OH_AudioStreamBuilder_SetSampleFormat")
        if (s.isNull()) { ok = false } else { fnSetFmt = CFunc<(CPointer<Unit>, Int32) -> Int32>(s) }

        s = sym("OH_AudioStreamBuilder_SetEncodingType")
        if (s.isNull()) { ok = false } else { fnSetEnc = CFunc<(CPointer<Unit>, Int32) -> Int32>(s) }

        s = sym("OH_AudioStreamBuilder_SetRendererInfo")
        if (s.isNull()) { ok = false } else { fnSetUsage = CFunc<(CPointer<Unit>, Int32) -> Int32>(s) }

        s = sym("OH_AudioStreamBuilder_SetRendererCallback")
        if (s.isNull()) { ok = false } else { fnSetCb = CFunc<(CPointer<Unit>, OHRendererCbs, CPointer<Unit>) -> Int32>(s) }

        s = sym("OH_AudioStreamBuilder_GenerateRenderer")
        if (s.isNull()) { ok = false } else { fnGenRen = CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(s) }

        s = sym("OH_AudioRenderer_Start")
        if (s.isNull()) { ok = false } else { fnStart = CFunc<(CPointer<Unit>) -> Int32>(s) }

        s = sym("OH_AudioRenderer_Stop")
        if (s.isNull()) { ok = false } else { fnStop = CFunc<(CPointer<Unit>) -> Int32>(s) }

        s = sym("OH_AudioRenderer_Release")
        if (s.isNull()) { ok = false } else { fnRelease = CFunc<(CPointer<Unit>) -> Int32>(s) }

        if (ok) {
            _loaded = true
            Hilog.info(0, "CjTelegram", "[AudioPlayback] All symbols resolved")
        } else {
            _failed = true
            Hilog.info(0, "CjTelegram", "[AudioPlayback] Missing symbols")
        }
        return ok
    }

    /**
     * Play a WAV file. Reads the file, parses WAV header for audio params,
     * then uses OHAudio renderer to play the PCM data.
     * Returns true if playback started.
     */
    public static func playFile(filePath: String): Bool {
        if (g_playing) {
            stopPlayback()
        }
        if (!load()) { return false }

        let fileData: Array<Byte>
        try {
            let file = FileIo.open(filePath, mode: 0o0)
            let stat = FileIo.stat(filePath)
            let size = stat.size
            if (size <= 44) {
                Hilog.info(0, "CjTelegram", "[AudioPlayback] File too small: ${size}")
                FileIo.close(file)
                return false
            }
            let buf = Array<Byte>(size, repeat: 0)
            let _ = FileIo.read(file.fd, buf)
            FileIo.close(file)
            fileData = buf
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[AudioPlayback] Read failed: ${e}")
            return false
        }

        var sampleRate: Int32 = 16000
        var channels: Int32 = 1
        var bitsPerSample: Int32 = 16

        let isWav = fileData.size > 44 &&
            fileData[0] == UInt8(0x52) &&
            fileData[1] == UInt8(0x49) &&
            fileData[2] == UInt8(0x46) &&
            fileData[3] == UInt8(0x46)

        let pcmStart: Int64 = if (isWav) { 44 } else { 0 }
        if (isWav) {
            channels = Int32(fileData[22]) | (Int32(fileData[23]) << 8)
            sampleRate = Int32(fileData[24]) | (Int32(fileData[25]) << 8) |
                         (Int32(fileData[26]) << 16) | (Int32(fileData[27]) << 24)
            bitsPerSample = Int32(fileData[34]) | (Int32(fileData[35]) << 8)
            Hilog.info(0, "CjTelegram", "[AudioPlayback] WAV: ${sampleRate}Hz, ${channels}ch, ${bitsPerSample}bit")
        }

        let pcmLen = fileData.size - pcmStart
        let pcmOff = pcmStart
        g_playBuffer = Array<Byte>(pcmLen, { i => fileData[pcmOff + i] })
        g_playOffset = 0
        g_playSize = pcmLen
        g_playing = true
        g_playFinished = false
        g_playInterrupted = false

        let sampleFmt: Int32 = if (bitsPerSample == 16) { 1 } else { 0 }

        var createResult: Int32 = 0
        var genResult: Int32 = 0
        var startResult: Int32 = 0

        unsafe {
            let pOut = LibC.malloc<CPointer<Unit>>(count: 1)
            pOut.write(CPointer<Unit>())

            createResult = fnCreate(CPointer<Unit>(pOut), PLAYBACK_TYPE_RENDERER)
            if (createResult != 0) {
                LibC.free(pOut)
                g_playing = false
            } else {
                _builder = pOut.read()
                LibC.free(pOut)
            }
        }
        if (createResult != 0) {
            Hilog.info(0, "CjTelegram", "[AudioPlayback] Builder_Create failed: ${createResult}")
            return false
        }
        if (_builder.isNull()) {
            Hilog.info(0, "CjTelegram", "[AudioPlayback] Builder is null")
            g_playing = false
            return false
        }

        unsafe {
            fnSetRate(_builder, sampleRate)
            fnSetCh(_builder, channels)
            fnSetFmt(_builder, sampleFmt)
            fnSetEnc(_builder, 0)
            fnSetUsage(_builder, PLAYBACK_USAGE_MUSIC)

            var cbs = OHRendererCbs()
            cbs.onWriteData = ohRendererOnWriteData
            cbs.onInterruptEvent = ohRendererOnInterruptEvent
            fnSetCb(_builder, cbs, CPointer<Unit>())

            let pRen = LibC.malloc<CPointer<Unit>>(count: 1)
            pRen.write(CPointer<Unit>())
            genResult = fnGenRen(_builder, CPointer<Unit>(pRen))
            if (genResult == 0) {
                _renderer = pRen.read()
            }
            LibC.free(pRen)
        }
        if (genResult != 0 || _renderer.isNull()) {
            Hilog.info(0, "CjTelegram", "[AudioPlayback] GenerateRenderer failed: ${genResult}")
            cleanupBuilder()
            g_playing = false
            return false
        }

        unsafe { startResult = fnStart(_renderer) }
        if (startResult != 0) {
            Hilog.info(0, "CjTelegram", "[AudioPlayback] Start failed: ${startResult}")
            cleanupAll()
            g_playing = false
            return false
        }

        Hilog.info(0, "CjTelegram", "[AudioPlayback] Playing: ${pcmLen} bytes PCM")
        return true
    }

    public static func stopPlayback(): Unit {
        g_playing = false
        g_playInterrupted = false
        if (!_renderer.isNull()) {
            unsafe {
                let _ = fnStop(_renderer)
                let _ = fnRelease(_renderer)
            }
            _renderer = CPointer<Unit>()
        }
        cleanupBuilder()
        g_playBuffer = Array<Byte>(0, repeat: 0)
        g_playOffset = 0
        g_playSize = 0
        Hilog.info(0, "CjTelegram", "[AudioPlayback] Stopped")
    }

    public static func isPlaying(): Bool {
        return g_playing
    }

    public static func isFinished(): Bool {
        return g_playFinished
    }

    /**
     * 播放是否因外部中断（来电/通知/耳机拔出）被强制停止（P2-229 真做）
     * 由 ohRendererOnInterruptEvent 置 true；由 playFile/stopPlayback 复位
     */
    public static func isInterrupted(): Bool {
        return g_playInterrupted
    }

    public static func getProgress(): Float64 {
        if (g_playSize <= 0) { return 0.0 }
        return Float64(g_playOffset) / Float64(g_playSize)
    }

    private static func cleanupBuilder(): Unit {
        if (!_builder.isNull()) {
            unsafe { let _ = fnDestroy(_builder) }
            _builder = CPointer<Unit>()
        }
    }

    private static func cleanupAll(): Unit {
        if (!_renderer.isNull()) {
            unsafe { let _ = fnRelease(_renderer) }
            _renderer = CPointer<Unit>()
        }
        cleanupBuilder()
    }
}
