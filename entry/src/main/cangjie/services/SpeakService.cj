package ohos_app_cangjie_entry.services

/**
 * SpeakService — 文字转语音服务（TTS）
 *
 * iOS 对应：AVSpeechSynthesizer / SpeechSynthesizerHolder（Speak.swift）
 * HarmonyOS 实现：通过 dlopen 加载 libohtextospeech.so，使用
 *   OH_TextToSpeech_CreateEngine / OH_TextToSpeech_InitEngine /
 *   OH_TextToSpeech_Speak / OH_TextToSpeech_StopSpeaking /
 *   OH_TextToSpeech_DestroyEngine 完成真实 TTS 朗读。
 *
 * MTProto 说明：TTS 朗读是纯本地设备能力，无需 MTProto 网络调用（N/A）。
 * iOS 源码（Speak.swift）同样不涉及任何 MTProto 操作，仅使用 AVFoundation。
 *
 * 设计说明：
 *   - dlopen 模式与 AudioPlaybackService 完全相同，避免 link-time 依赖崩溃（见 #85）
 *   - TTS 引擎初始化延迟到首次 speakText 调用时
 *   - isSpeaking() 由全局标志位追踪（TTS 引擎无同步查询 API）
 *
 * P2-401 语言检测说明：
 *   iOS 使用 NSLinguisticTagger.dominantLanguage(for: text) 检测文本语言，
 *   选择对应的 AVSpeechSynthesisVoice。
 *   HarmonyOS 无对等标准库 API（KB 查询无命中）。
 *   采用 Unicode 区段启发式检测（detectTextLanguage()）:
 *     - CJK 统一汉字 → zh-CN
 *     - 日文假名 → ja-JP
 *     - 韩文音节 → ko-KR
 *     - 默认 → en-US
 *   结果写入 OHTTSParams.language，由 OH_TextToSpeech_Speak 读取。
 */

import kit.PerformanceAnalysisKit.Hilog

/**
 * P2-401: 语言检测 — 用 Unicode 区段启发式方法检测文本语言
 *
 * iOS 对应: NSLinguisticTagger.dominantLanguage(for: text) (iOS 11+)
 * 返回值格式: BCP-47 语言标签 (e.g. "zh-CN", "ja-JP", "ko-KR", "en-US")
 *
 * 实现策略（KB 查询无命中，自实现，见 unresolved_api_decisions）:
 *   扫描前 256 个 codepoint，统计各语言 Unicode 区段字符数，取占比最高者。
 */
public func detectTextLanguage(text: String): String {
    let runes = text.toRuneArray()
    let scanLen = if (runes.size > 256) { 256 } else { runes.size }
    var zhCount = 0
    var jaCount = 0
    var koCount = 0
    var total = 0
    var i = 0
    while (i < scanLen) {
        let cp = UInt32(runes[i])
        if ((cp >= 0x4E00 && cp <= 0x9FFF) || (cp >= 0x3400 && cp <= 0x4DBF) || (cp >= 0x20000 && cp <= 0x2A6DF)) {
            zhCount = zhCount + 1
            total = total + 1
        } else if ((cp >= 0x3040 && cp <= 0x309F) || (cp >= 0x30A0 && cp <= 0x30FF)) {
            jaCount = jaCount + 1
            total = total + 1
        } else if (cp >= 0xAC00 && cp <= 0xD7AF) {
            koCount = koCount + 1
            total = total + 1
        }
        i = i + 1
    }
    if (total == 0) {
        return "en-US"
    }
    if (jaCount > 0 && jaCount >= zhCount && jaCount >= koCount) {
        return "ja-JP"
    }
    if (koCount > 0 && koCount >= zhCount) {
        return "ko-KR"
    }
    if (zhCount > 0) {
        return "zh-CN"
    }
    return "en-US"
}

// dlopen/dlsym 已在 AudioCaptureService.cj（同包）中声明，此处直接使用

let TTS_RTLD_LAZY: Int32 = 1

// OH_TextToSpeech_Params 对应 C 结构体（按鸿蒙 NDK 布局）
@C
struct OHTTSParams {
    var language: CPointer<UInt8> = CPointer<UInt8>()
    var languageLen: Int32 = 0
    var speed: Float32 = 1.0
    var volume: Float32 = 1.0
    var pitch: Float32 = 1.0
    var playType: Int32 = 0
}

// TTS 回调结构体（C 函数指针）
@C
struct OHTTSCallbacks {
    var onSpeechStart: CFunc<(CPointer<Unit>) -> Unit> =
        CFunc<(CPointer<Unit>) -> Unit>(CPointer<Unit>())
    var onSpeechFinish: CFunc<(CPointer<Unit>) -> Unit> =
        CFunc<(CPointer<Unit>) -> Unit>(CPointer<Unit>())
    var onError: CFunc<(CPointer<Unit>, Int32) -> Unit> =
        CFunc<(CPointer<Unit>, Int32) -> Unit>(CPointer<Unit>())
}

var g_ttsSpeaking: Bool = false

@C
func ohTTSOnFinish(_userData: CPointer<Unit>): Unit {
    g_ttsSpeaking = false
    Hilog.info(0, "CjTelegram", "[SpeakService] TTS finished")
}

@C
func ohTTSOnError(_userData: CPointer<Unit>, _code: Int32): Unit {
    g_ttsSpeaking = false
    Hilog.info(0, "CjTelegram", "[SpeakService] TTS error")
}

@C
func ohTTSOnStart(_userData: CPointer<Unit>): Unit {
    g_ttsSpeaking = true
    Hilog.info(0, "CjTelegram", "[SpeakService] TTS started")
}

private var _ttsSpeakServiceInstance: Option<SpeakService> = None

public func getSpeakService(): SpeakService {
    match (_ttsSpeakServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = SpeakService()
            _ttsSpeakServiceInstance = Some(inst)
            return inst
    }
}

public class SpeakService {
    private var _lib: CPointer<Unit> = CPointer<Unit>()
    private var _engine: CPointer<Unit> = CPointer<Unit>()
    private var _loaded: Bool = false
    private var _failed: Bool = false

    // TTS engine function pointers
    private var fnCreate: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())
    private var fnInit: CFunc<(CPointer<Unit>, OHTTSCallbacks, CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>, OHTTSCallbacks, CPointer<Unit>) -> Int32>(CPointer<Unit>())
    private var fnSpeak: CFunc<(CPointer<Unit>, CPointer<UInt8>, Int32, OHTTSParams) -> Int32> =
        CFunc<(CPointer<Unit>, CPointer<UInt8>, Int32, OHTTSParams) -> Int32>(CPointer<Unit>())
    private var fnStop: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())
    private var fnDestroy: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())

    private func sym(name: String): CPointer<Unit> {
        let cs = unsafe { LibC.mallocCString(name) }
        let p = unsafe { dlsym(_lib, cs) }
        unsafe { LibC.free(cs) }
        if (p.isNull()) {
            Hilog.info(0, "CjTelegram", "[SpeakService] dlsym miss: ${name}")
        }
        return p
    }

    private func loadLib(): Bool {
        if (_loaded) { return true }
        if (_failed) { return false }

        Hilog.info(0, "CjTelegram", "[SpeakService] Loading libohtextospeech.so...")
        let cs = unsafe { LibC.mallocCString("libohtextospeech.so") }
        _lib = unsafe { dlopen(cs, TTS_RTLD_LAZY) }
        unsafe { LibC.free(cs) }
        if (_lib.isNull()) {
            Hilog.info(0, "CjTelegram", "[SpeakService] dlopen failed — TTS not available on this device")
            _failed = true
            return false
        }

        var ok = true
        var s: CPointer<Unit>

        s = sym("OH_TextToSpeech_CreateEngine")
        if (s.isNull()) { ok = false } else {
            fnCreate = CFunc<(CPointer<Unit>) -> Int32>(s)
        }

        s = sym("OH_TextToSpeech_InitEngine")
        if (s.isNull()) { ok = false } else {
            fnInit = CFunc<(CPointer<Unit>, OHTTSCallbacks, CPointer<Unit>) -> Int32>(s)
        }

        s = sym("OH_TextToSpeech_Speak")
        if (s.isNull()) { ok = false } else {
            fnSpeak = CFunc<(CPointer<Unit>, CPointer<UInt8>, Int32, OHTTSParams) -> Int32>(s)
        }

        s = sym("OH_TextToSpeech_StopSpeaking")
        if (s.isNull()) { ok = false } else {
            fnStop = CFunc<(CPointer<Unit>) -> Int32>(s)
        }

        s = sym("OH_TextToSpeech_DestroyEngine")
        if (s.isNull()) { ok = false } else {
            fnDestroy = CFunc<(CPointer<Unit>) -> Int32>(s)
        }

        if (ok) {
            _loaded = true
            Hilog.info(0, "CjTelegram", "[SpeakService] All TTS symbols resolved")
        } else {
            _failed = true
            Hilog.info(0, "CjTelegram", "[SpeakService] Some TTS symbols missing")
        }
        return ok
    }

    private func ensureEngine(): Bool {
        if (!_engine.isNull()) { return true }
        if (!loadLib()) { return false }

        var createResult: Int32 = 0
        unsafe {
            let pOut = LibC.malloc<CPointer<Unit>>(count: 1)
            pOut.write(CPointer<Unit>())
            createResult = fnCreate(CPointer<Unit>(pOut))
            if (createResult == 0) {
                _engine = pOut.read()
            }
            LibC.free(pOut)
        }
        if (createResult != 0 || _engine.isNull()) {
            Hilog.info(0, "CjTelegram", "[SpeakService] CreateEngine failed: ${createResult}")
            return false
        }

        var cbs = OHTTSCallbacks()
        cbs.onSpeechStart = ohTTSOnStart
        cbs.onSpeechFinish = ohTTSOnFinish
        cbs.onError = ohTTSOnError

        var initResult: Int32 = 0
        unsafe {
            initResult = fnInit(_engine, cbs, CPointer<Unit>())
        }
        if (initResult != 0) {
            Hilog.info(0, "CjTelegram", "[SpeakService] InitEngine failed: ${initResult}")
            unsafe { let _ = fnDestroy(_engine) }
            _engine = CPointer<Unit>()
            return false
        }
        Hilog.info(0, "CjTelegram", "[SpeakService] TTS engine ready")
        return true
    }

    /**
     * 朗读文本（对应 iOS speakText）
     * 返回 true 表示朗读已开始；false 表示设备不支持 TTS 或文本为空。
     *
     * P2-401: 朗读前先检测文本语言，设置 OHTTSParams.language 字段。
     * iOS 对应: NSLinguisticTagger.dominantLanguage → AVSpeechSynthesisVoice(language:)
     */
    public func speakText(text: String): Bool {
        if (text.isEmpty()) {
            return false
        }
        if (g_ttsSpeaking) {
            stopSpeaking()
        }
        if (!ensureEngine()) {
            Hilog.info(0, "CjTelegram", "[SpeakService] TTS engine unavailable")
            return false
        }

        let detectedLang = detectTextLanguage(text)
        Hilog.info(0, "CjTelegram", "[SpeakService] detected language=${detectedLang}")

        var params = OHTTSParams()
        let langBytes = detectedLang.toArray()
        let langLen = Int32(langBytes.size)

        let bytes = text.toArray()
        let len = Int32(bytes.size)

        var result: Int32 = 0
        unsafe {
            let langHandle = acquireArrayRawData(langBytes)
            params.language = langHandle.pointer
            params.languageLen = langLen
            let handle = acquireArrayRawData(bytes)
            result = fnSpeak(_engine, handle.pointer, len, params)
            releaseArrayRawData(handle)
            releaseArrayRawData(langHandle)
        }

        if (result == 0) {
            g_ttsSpeaking = true
            Hilog.info(0, "CjTelegram", "[SpeakService] Speaking text (${len} bytes)")
            return true
        } else {
            Hilog.info(0, "CjTelegram", "[SpeakService] Speak failed: ${result}")
            return false
        }
    }

    /**
     * 停止朗读（对应 iOS SpeechSynthesizerHolder.stop）
     */
    public func stopSpeaking(): Unit {
        if (!_engine.isNull() && g_ttsSpeaking) {
            unsafe { let _ = fnStop(_engine) }
        }
        g_ttsSpeaking = false
        Hilog.info(0, "CjTelegram", "[SpeakService] Stopped")
    }

    /**
     * 是否正在朗读
     */
    public func isSpeaking(): Bool {
        return g_ttsSpeaking
    }

    /**
     * 释放 TTS 引擎（应用退出时调用）
     */
    public func release(): Unit {
        if (!_engine.isNull()) {
            unsafe { let _ = fnStop(_engine) }
            unsafe { let _ = fnDestroy(_engine) }
            _engine = CPointer<Unit>()
        }
        g_ttsSpeaking = false
    }
}
