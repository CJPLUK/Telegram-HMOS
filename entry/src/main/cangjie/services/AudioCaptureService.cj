package ohos_app_cangjie_entry.services

/**
 * AudioCaptureService — 纯 Cangjie 语音录制服务
 *
 * 通过 dlopen/dlsym 加载系统 libohaudio.so，
 * 使用 OH_AudioStreamBuilder + OH_AudioCapturer 原生 API 录制 PCM 音频。
 * 无需修改任何 C++ 代码。
 *
 * 录音参数：16kHz / Mono / S16LE (32000 bytes/sec)
 * 最大缓冲：4MB（约 131 秒）
 */

import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*

/* ==================== libc FFI ==================== */

foreign func dlopen(path: CString, flags: Int32): CPointer<Unit>
foreign func dlsym(handle: CPointer<Unit>, symbol: CString): CPointer<Unit>
foreign func memcpy(dest: CPointer<UInt8>, src: CPointer<UInt8>, n: UIntNative): CPointer<UInt8>

/* ==================== OHOS OHAudio Constants ==================== */

let OHAUDIO_RTLD_LAZY: Int32 = 1
let OHAUDIO_TYPE_CAPTURER: Int32 = 2
let OHAUDIO_RATE_16K: Int32 = 16000
// iOS ManagedAudioRecorder 以 48 kHz 采集直接喂 Opus；16k 是早期 WAV 路径遗留
let OHAUDIO_RATE_48K: Int32 = 48000
let VOICE_SAMPLE_RATE: Int32 = OHAUDIO_RATE_48K
let OHAUDIO_CHANNEL_MONO: Int32 = 1
let OHAUDIO_FMT_S16LE: Int32 = 1
let OHAUDIO_ENC_RAW: Int32 = 0
let OHAUDIO_SRC_MIC: Int32 = 0

/* ==================== @C struct: Capturer Callbacks ==================== */

/**
 * Matches OH_AudioCapturer_Callbacks_Struct in libohaudio.so:
 *   { OnReadData, OnStreamEvent, OnInterruptEvent, OnError }
 * Each field is a C function pointer (8 bytes on ARM64).
 */
@C
struct OHCapturerCbs {
    var onReadData: CFunc<(CPointer<Unit>, CPointer<Unit>, CPointer<UInt8>, Int32) -> Int32> =
        CFunc<(CPointer<Unit>, CPointer<Unit>, CPointer<UInt8>, Int32) -> Int32>(CPointer<Unit>())
    var onStreamEvent: CPointer<Unit> = CPointer<Unit>()
    var onInterruptEvent: CPointer<Unit> = CPointer<Unit>()
    var onError: CPointer<Unit> = CPointer<Unit>()
}

@C
struct OHAudioSessionStrategy {
    var concurrencyMode: Int32 = 0
}

/* ==================== Global Audio Buffer ==================== */

// 48 kHz × 16bit × 单声道 = 96 KB/s；录音循环上限 600 s
let VOICE_MAX_BYTES: Int64 = 96000 * 600

var g_pcmBuffer: CPointer<UInt8> = CPointer<UInt8>()
var g_pcmOffset: Int64 = 0
var g_capturing: Bool = false

/* ==================== @C Callback ==================== */

@C
func ohCapturerOnReadData(
    _capturer: CPointer<Unit>,
    _userData: CPointer<Unit>,
    buffer: CPointer<UInt8>,
    length: Int32
): Int32 {
    if (!g_capturing || length <= 0) {
        return 0
    }
    let remaining = VOICE_MAX_BYTES - g_pcmOffset
    let toCopy = if (Int64(length) > remaining) { remaining } else { Int64(length) }
    if (toCopy <= 0) {
        return 0
    }
    unsafe { let _ = memcpy(g_pcmBuffer + g_pcmOffset, buffer, UIntNative(toCopy)) }
    g_pcmOffset = g_pcmOffset + toCopy
    return 0
}

/* ==================== Service Class ==================== */

public class AudioCaptureService {
    private static var _lib: CPointer<Unit> = CPointer<Unit>()
    private static var _loaded: Bool = false
    private static var _failed: Bool = false
    private static var _builder: CPointer<Unit> = CPointer<Unit>()
    private static var _capturer: CPointer<Unit> = CPointer<Unit>()

    // OHAudio function pointers
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
    static var fnSetSrc: CFunc<(CPointer<Unit>, Int32) -> Int32> =
        CFunc<(CPointer<Unit>, Int32) -> Int32>(CPointer<Unit>())
    static var fnSetCb: CFunc<(CPointer<Unit>, OHCapturerCbs, CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>, OHCapturerCbs, CPointer<Unit>) -> Int32>(CPointer<Unit>())
    static var fnGenCap: CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(CPointer<Unit>())
    static var fnStart: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())
    static var fnStop: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())
    static var fnRelease: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())
    static var fnGetSessionManager: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())
    static var fnActivateSession: CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(CPointer<Unit>())
    static var fnDeactivateSession: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())
    static var _sessionManager: CPointer<Unit> = CPointer<Unit>()
    static var _sessionSymbolsAvailable: Bool = false

    private static func sym(name: String): CPointer<Unit> {
        let cs = unsafe { LibC.mallocCString(name) }
        let p = unsafe { dlsym(_lib, cs) }
        unsafe { LibC.free(cs) }
        if (p.isNull()) {
            Hilog.info(0, "CjTelegram", "[AudioCapture] dlsym miss: ${name}")
        }
        return p
    }

    private static func load(): Bool {
        if (_loaded) { return true }
        if (_failed) { return false }

        Hilog.info(0, "CjTelegram", "[AudioCapture] Loading libohaudio.so...")
        let cs = unsafe { LibC.mallocCString("libohaudio.so") }
        _lib = unsafe { dlopen(cs, OHAUDIO_RTLD_LAZY) }
        unsafe { LibC.free(cs) }
        if (_lib.isNull()) {
            Hilog.info(0, "CjTelegram", "[AudioCapture] dlopen FAILED")
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

        s = sym("OH_AudioStreamBuilder_SetCapturerInfo")
        if (s.isNull()) { ok = false } else { fnSetSrc = CFunc<(CPointer<Unit>, Int32) -> Int32>(s) }

        s = sym("OH_AudioStreamBuilder_SetCapturerCallback")
        if (s.isNull()) { ok = false } else { fnSetCb = CFunc<(CPointer<Unit>, OHCapturerCbs, CPointer<Unit>) -> Int32>(s) }

        s = sym("OH_AudioStreamBuilder_GenerateCapturer")
        if (s.isNull()) { ok = false } else { fnGenCap = CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(s) }

        s = sym("OH_AudioCapturer_Start")
        if (s.isNull()) { ok = false } else { fnStart = CFunc<(CPointer<Unit>) -> Int32>(s) }

        s = sym("OH_AudioCapturer_Stop")
        if (s.isNull()) { ok = false } else { fnStop = CFunc<(CPointer<Unit>) -> Int32>(s) }

        s = sym("OH_AudioCapturer_Release")
        if (s.isNull()) { ok = false } else { fnRelease = CFunc<(CPointer<Unit>) -> Int32>(s) }

        let getSessionSym = sym("OH_AudioManager_GetAudioSessionManager")
        let activateSessionSym = sym("OH_AudioSessionManager_ActivateAudioSession")
        let deactivateSessionSym = sym("OH_AudioSessionManager_DeactivateAudioSession")
        if (!getSessionSym.isNull() && !activateSessionSym.isNull() && !deactivateSessionSym.isNull()) {
            fnGetSessionManager = CFunc<(CPointer<Unit>) -> Int32>(getSessionSym)
            fnActivateSession = CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(activateSessionSym)
            fnDeactivateSession = CFunc<(CPointer<Unit>) -> Int32>(deactivateSessionSym)
            _sessionSymbolsAvailable = true
        }

        if (ok) {
            _loaded = true
            Hilog.info(0, "CjTelegram", "[AudioCapture] All symbols resolved")
        } else {
            _failed = true
            Hilog.info(0, "CjTelegram", "[AudioCapture] Missing symbols")
        }
        return ok
    }

    private static func activateRecordingSession(): Unit {
        if (!_sessionSymbolsAvailable) { return }
        unsafe {
            if (_sessionManager.isNull()) {
                let managerOut = LibC.malloc<CPointer<Unit>>(count: 1)
                managerOut.write(CPointer<Unit>())
                let managerResult = fnGetSessionManager(CPointer<Unit>(managerOut))
                if (managerResult == 0) {
                    _sessionManager = managerOut.read()
                }
                LibC.free(managerOut)
            }
            if (!_sessionManager.isNull()) {
                let strategy = LibC.malloc<OHAudioSessionStrategy>(count: 1)
                let pauseOthers = getMiscSettingsStore().getPauseMusicOnRecording()
                let modeName = if (pauseOthers) { "pauseOthers" } else { "mixWithOthers" }
                var strategyValue = OHAudioSessionStrategy()
                strategyValue.concurrencyMode = if (pauseOthers) { 3 } else { 1 }
                strategy.write(strategyValue)
                let result = fnActivateSession(_sessionManager, CPointer<Unit>(strategy))
                LibC.free(strategy)
                Hilog.info(0, "CjTelegram", "[AudioCapture] Audio session mode=${modeName} result=${result}")
            }
        }
    }

    private static func deactivateRecordingSession(): Unit {
        if (!_sessionSymbolsAvailable || _sessionManager.isNull()) { return }
        unsafe {
            let result = fnDeactivateSession(_sessionManager)
            Hilog.info(0, "CjTelegram", "[AudioCapture] Audio session deactivated result=${result}")
        }
    }

    /**
     * Start audio capture. Returns true if started.
     */
    public static func startCapture(): Bool {
        if (g_capturing) {
            Hilog.info(0, "CjTelegram", "[AudioCapture] Already active")
            return true
        }
        if (!load()) { return false }

        unsafe { g_pcmBuffer = LibC.malloc<UInt8>(count: VOICE_MAX_BYTES) }
        if (g_pcmBuffer.isNull()) {
            Hilog.info(0, "CjTelegram", "[AudioCapture] Native PCM allocation failed")
            return false
        }
        g_pcmOffset = 0
        g_capturing = true

        var createResult: Int32 = 0
        var genResult: Int32 = 0
        var startResult: Int32 = 0

        unsafe {
            let pOut = LibC.malloc<CPointer<Unit>>(count: 1)
            pOut.write(CPointer<Unit>())

            createResult = fnCreate(CPointer<Unit>(pOut), OHAUDIO_TYPE_CAPTURER)
            if (createResult != 0) {
                LibC.free(pOut)
                g_capturing = false
            } else {
                _builder = pOut.read()
                LibC.free(pOut)
            }
        }
        if (createResult != 0) {
            releasePcmBuffer()
            Hilog.info(0, "CjTelegram", "[AudioCapture] Builder_Create failed")
            return false
        }
        if (_builder.isNull()) {
            Hilog.info(0, "CjTelegram", "[AudioCapture] Builder is null")
            g_capturing = false
            releasePcmBuffer()
            return false
        }

        unsafe {
            fnSetRate(_builder, VOICE_SAMPLE_RATE)
            fnSetCh(_builder, OHAUDIO_CHANNEL_MONO)
            fnSetFmt(_builder, OHAUDIO_FMT_S16LE)
            fnSetEnc(_builder, OHAUDIO_ENC_RAW)
            fnSetSrc(_builder, OHAUDIO_SRC_MIC)

            var cbs = OHCapturerCbs()
            cbs.onReadData = ohCapturerOnReadData
            fnSetCb(_builder, cbs, CPointer<Unit>())

            let cOut = LibC.malloc<CPointer<Unit>>(count: 1)
            cOut.write(CPointer<Unit>())

            genResult = fnGenCap(_builder, CPointer<Unit>(cOut))
            if (genResult != 0) {
                fnDestroy(_builder)
                _builder = CPointer<Unit>()
                LibC.free(cOut)
                g_capturing = false
            } else {
                _capturer = cOut.read()
                LibC.free(cOut)
            }
        }
        if (genResult != 0) {
            releasePcmBuffer()
            Hilog.info(0, "CjTelegram", "[AudioCapture] GenerateCapturer failed")
            return false
        }
        if (_capturer.isNull()) {
            Hilog.info(0, "CjTelegram", "[AudioCapture] Capturer is null")
            unsafe { fnDestroy(_builder) }
            _builder = CPointer<Unit>()
            g_capturing = false
            releasePcmBuffer()
            return false
        }

        activateRecordingSession()
        unsafe {
            startResult = fnStart(_capturer)
            if (startResult != 0) {
                fnRelease(_capturer)
                fnDestroy(_builder)
                _capturer = CPointer<Unit>()
                _builder = CPointer<Unit>()
                g_capturing = false
            }
        }
        if (startResult != 0) {
            deactivateRecordingSession()
            releasePcmBuffer()
            Hilog.info(0, "CjTelegram", "[AudioCapture] Start failed")
            return false
        }

        Hilog.info(0, "CjTelegram", "[AudioCapture] Started (48kHz mono S16LE)")
        return true
    }

    /**
     * Build a 44-byte WAV header for VOICE_SAMPLE_RATE / mono / S16LE PCM data.
     */
    private static func buildWavHeader(pcmBytes: Int64): Array<Byte> {
        let sampleRate: Int32 = VOICE_SAMPLE_RATE
        let channels: Int32 = 1
        let bitsPerSample: Int32 = 16
        let byteRate: Int32 = sampleRate * channels * bitsPerSample / 8
        let blockAlign: Int32 = channels * bitsPerSample / 8
        let dataSize: Int32 = Int32(pcmBytes)
        let fileSize: Int32 = dataSize + 36

        let h = Array<Byte>(44, repeat: 0)
        // "RIFF"
        h[0] = 0x52; h[1] = 0x49; h[2] = 0x46; h[3] = 0x46
        // file size - 8
        h[4] = UInt8(fileSize & 0xFF)
        h[5] = UInt8((fileSize >> 8) & 0xFF)
        h[6] = UInt8((fileSize >> 16) & 0xFF)
        h[7] = UInt8((fileSize >> 24) & 0xFF)
        // "WAVE"
        h[8] = 0x57; h[9] = 0x41; h[10] = 0x56; h[11] = 0x45
        // "fmt "
        h[12] = 0x66; h[13] = 0x6D; h[14] = 0x74; h[15] = 0x20
        // fmt chunk size = 16
        h[16] = 16; h[17] = 0; h[18] = 0; h[19] = 0
        // audio format = 1 (PCM)
        h[20] = 1; h[21] = 0
        // channels
        h[22] = UInt8(channels & 0xFF); h[23] = 0
        // sample rate
        h[24] = UInt8(sampleRate & 0xFF)
        h[25] = UInt8((sampleRate >> 8) & 0xFF)
        h[26] = UInt8((sampleRate >> 16) & 0xFF)
        h[27] = UInt8((sampleRate >> 24) & 0xFF)
        // byte rate
        h[28] = UInt8(byteRate & 0xFF)
        h[29] = UInt8((byteRate >> 8) & 0xFF)
        h[30] = UInt8((byteRate >> 16) & 0xFF)
        h[31] = UInt8((byteRate >> 24) & 0xFF)
        // block align
        h[32] = UInt8(blockAlign & 0xFF); h[33] = 0
        // bits per sample
        h[34] = UInt8(bitsPerSample & 0xFF); h[35] = 0
        // "data"
        h[36] = 0x64; h[37] = 0x61; h[38] = 0x74; h[39] = 0x61
        // data size
        h[40] = UInt8(dataSize & 0xFF)
        h[41] = UInt8((dataSize >> 8) & 0xFF)
        h[42] = UInt8((dataSize >> 16) & 0xFF)
        h[43] = UInt8((dataSize >> 24) & 0xFF)
        return h
    }

    private static func releasePcmBuffer(): Unit {
        if (!g_pcmBuffer.isNull()) {
            unsafe { LibC.free(g_pcmBuffer) }
            g_pcmBuffer = CPointer<UInt8>()
        }
        g_pcmOffset = 0
    }

    /**
     * Stop capture and write WAV file (44-byte header + PCM data).
     * Returns bytes written (including header), 0 on failure.
     */
    public static func stopCapture(outputPath: String): Int64 {
        if (!g_capturing) { return 0 }
        g_capturing = false

        unsafe {
            if (!_capturer.isNull()) {
                fnStop(_capturer)
                fnRelease(_capturer)
                _capturer = CPointer<Unit>()
            }
            if (!_builder.isNull()) {
                fnDestroy(_builder)
                _builder = CPointer<Unit>()
            }
        }
        deactivateRecordingSession()

        let recorded = g_pcmOffset
        Hilog.info(0, "CjTelegram", "[AudioCapture] Stopped, ${recorded} bytes PCM")

        if (recorded <= 0) {
            releasePcmBuffer()
            return 0
        }

        try {
            let wavHeader = buildWavHeader(recorded)
            let totalSize = 44 + recorded
            let file = FileIo.open(outputPath, mode: 0o1101)
            FileIo.write(file.fd, wavHeader)
            var written: Int64 = 0
            let chunkCapacity: Int64 = 256 * 1024
            while (written < recorded) {
                let remaining = recorded - written
                let chunkSize = if (remaining < chunkCapacity) { remaining } else { chunkCapacity }
                let chunk = Array<Byte>(chunkSize, repeat: 0)
                unsafe {
                    let handle = acquireArrayRawData(chunk)
                    let _ = memcpy(handle.pointer, g_pcmBuffer + written, UIntNative(chunkSize))
                    releaseArrayRawData(handle)
                }
                FileIo.write(file.fd, chunk)
                written += chunkSize
            }
            FileIo.close(file)
            Hilog.info(0, "CjTelegram", "[AudioCapture] WAV written: ${totalSize} bytes to ${outputPath}")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[AudioCapture] Write failed: ${e}")
            releasePcmBuffer()
            return 0
        }

        releasePcmBuffer()
        return recorded
    }

    /**
     * Cancel recording, discard data.
     */
    public static func cancelCapture(): Unit {
        if (!g_capturing) { return }
        g_capturing = false

        unsafe {
            if (!_capturer.isNull()) {
                fnStop(_capturer)
                fnRelease(_capturer)
                _capturer = CPointer<Unit>()
            }
            if (!_builder.isNull()) {
                fnDestroy(_builder)
                _builder = CPointer<Unit>()
            }
        }
        deactivateRecordingSession()

        releasePcmBuffer()
        Hilog.info(0, "CjTelegram", "[AudioCapture] Cancelled")
    }

    public static func getBytesRecorded(): Int64 {
        return g_pcmOffset
    }

    public static func isRecording(): Bool {
        return g_capturing
    }
}
