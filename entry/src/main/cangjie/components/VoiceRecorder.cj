package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import std.collection.ArrayList
import std.time.DateTime
import ohos_app_cangjie_entry.services.getAppFilesDir
import ohos_app_cangjie_entry.services.AudioCaptureService

/**
 * VoiceRecorder — 语音录制组件
 *
 * 使用 AudioCaptureService (dlopen libohaudio.so) 进行真实 PCM 录音。
 * 录音参数：16kHz / Mono / S16LE
 */

/**
 * 录音结果
 */
public class VoiceRecordResult {
    public var filePath: String = ""
    public var duration: Int32 = 0
    public var waveform: ArrayList<Int32> = ArrayList<Int32>()
    
    public init() {}
    
    public init(filePath!: String, duration!: Int32, waveform!: ArrayList<Int32>) {
        this.filePath = filePath
        this.duration = duration
        this.waveform = waveform
    }
}

@Component
public class VoiceRecorder {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    public var onComplete: (VoiceRecordResult) -> Unit = { _result: VoiceRecordResult => }
    public var onCancel: () -> Unit = { => }
    
    @State var isRecording: Bool = false
    @State var duration: Int32 = 0
    @State var currentLevel: Int32 = 0
    @State var waveform: ArrayList<Int32> = ArrayList<Int32>()
    @State var isLocked: Bool = false
    
    private var _recordingActive: Bool = false
    private var _recordFilePath: String = ""
    
    /**
     * 开始录音 — 使用 AudioCaptureService 进行真实 PCM 录音
     */
    public func startRecording() {
        if (this.isRecording) { return }
        
        Hilog.info(0, "CjTelegram", "[VoiceRecorder] Start recording")
        this.isRecording = true
        this.duration = 0
        this.currentLevel = 0
        this.waveform = ArrayList<Int32>()
        this._recordingActive = true
        
        let filesDir = getAppFilesDir()
        if (filesDir.size > 0) {
            let voiceDir = filesDir + "/voice"
            try { FileIo.mkdir(voiceDir) } catch (_e: Exception) {}
            let ts = DateTime.now().toUnixTimeStamp().toMilliseconds()
            this._recordFilePath = voiceDir + "/voice_${ts}.wav"
        }
        
        let captureStarted = AudioCaptureService.startCapture()
        if (!captureStarted) {
            Hilog.info(0, "CjTelegram", "[VoiceRecorder] AudioCaptureService.startCapture() failed, recording without audio")
        }
        
        spawn {
            var dur: Int32 = 0
            var localWave = ArrayList<Int32>()
            while (this._recordingActive && dur < 120) {
                sleep(Duration.second * 1)
                if (!this._recordingActive) { break }
                dur = dur + 1
                
                let bytesRecorded = AudioCaptureService.getBytesRecorded()
                let level = if (bytesRecorded > 0) {
                    Int32((bytesRecorded / 320) % 33 + 5)
                } else {
                    Int32((dur * 17 + 23) % 33)
                }
                if (localWave.size < 100) {
                    localWave.add(level)
                }
                let copy = ArrayList<Int32>()
                for (w in localWave) { copy.add(w) }
                let d = dur
                launch {
                    this.duration = d
                    this.currentLevel = level
                    this.waveform = copy
                }
                if (dur >= 120) {
                    launch { this.stopRecording(false) }
                    break
                }
            }
        }
    }
    
    /**
     * 停止录音
     */
    public func stopRecording(cancelled: Bool) {
        if (!this._recordingActive) { return }
        
        this._recordingActive = false
        this.isRecording = false
        
        if (cancelled) {
            Hilog.info(0, "CjTelegram", "[VoiceRecorder] Recording cancelled")
            AudioCaptureService.cancelCapture()
            if (this._recordFilePath.size > 0) {
                try { FileIo.unlink(this._recordFilePath) } catch (_e: Exception) {}
            }
            this.onCancel()
        } else if (this.duration >= 1) {
            let bytesWritten = AudioCaptureService.stopCapture(this._recordFilePath)
            Hilog.info(0, "CjTelegram", "[VoiceRecorder] Recording complete: ${this.duration}s, ${bytesWritten} bytes")
            
            if (bytesWritten > 0) {
                let result = VoiceRecordResult(
                    filePath: this._recordFilePath,
                    duration: this.duration,
                    waveform: this.waveform
                )
                this.onComplete(result)
            } else {
                Hilog.info(0, "CjTelegram", "[VoiceRecorder] No audio data captured")
                this.onCancel()
            }
        } else {
            Hilog.info(0, "CjTelegram", "[VoiceRecorder] Recording too short")
            AudioCaptureService.cancelCapture()
            this.onCancel()
        }
        
        this.duration = 0
        this.currentLevel = 0
        this.waveform = ArrayList<Int32>()
        this.isLocked = false
        this._recordFilePath = ""
    }
    
    private func getDisplayWaveform(): Array<Int32> {
        if (this.waveform.size > 30) {
            let recent = ArrayList<Int32>()
            var startIdx = this.waveform.size - 30
            while (startIdx < this.waveform.size) {
                recent.add(this.waveform[startIdx])
                startIdx += 1
            }
            return recent.toArray()
        } else {
            return this.waveform.toArray()
        }
    }
    
    private func formatDuration(seconds: Int32): String {
        let mins = seconds / 60
        let secs = seconds % 60
        let sStr = if (secs < 10) { "0${secs}" } else { "${secs}" }
        return "${mins}:${sStr}"
    }
    
    public func build() {
        Column {
            if (this.isRecording) {
                Column {
                    Row {
                        ForEach(this.getDisplayWaveform(), itemGenerator: { level: Int32, index: Int64 =>
                            Column {}
                                .width(3)
                                .height(Int64(level) + 8)
                                .backgroundColor(0xFF3B30)
                                .borderRadius(2)
                                .margin(left: if (index > 0) { 2 } else { 0 })
                        })
                    }
                    .height(40)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(VerticalAlign.Center)
                    
                    Text(this.formatDuration(this.duration))
                        .fontSize(48)
                        .fontWeight(FontWeight.Lighter)
                        .fontColor(0xFF3B30)
                        .margin(top: 20)
                    
                    Row {
                        Column {}
                            .width(8)
                            .height(8)
                            .backgroundColor(0xFF3B30)
                            .borderRadius(4)
                        Text("Recording")
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .margin(left: 8)
                    }
                    .margin(top: 12)
                    .alignItems(VerticalAlign.Center)
                    
                    Text(if (this.isLocked) { "Tap to stop" } else { "Release to send" })
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 16)
                    
                    // 资源保真修复：真实矢量图标替代 "🗑/🔒/⬆/🎤" 字形，来源
                    // Item List/Icons/Delete (trashbin.pdf) / Chat/Stickers/Lock (lock_24.pdf) /
                    // Chat/Input/Text/SendIcon (send.pdf) / Item List/Icons/Microphone (microphone.pdf)
                    Row {
                        Column {
                            Image(@r(app.media.callui_ic_trash))
                                .width(24)
                                .height(24)
                                .fillColor(0xFFFFFF)
                        }
                        .width(60)
                        .height(60)
                        .backgroundColor(0xFF3B30)
                        .borderRadius(30)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                        .onClick({ evt =>
                            this.stopRecording(true)
                        })

                        Blank()

                        if (!this.isLocked) {
                            Column {
                                Image(@r(app.media.callui_ic_lock))
                                    .width(24)
                                    .height(24)
                                    .fillColor(0x0088CC)
                            }
                            .width(60)
                            .height(60)
                            .backgroundColor(0xF2F2F7)
                            .borderRadius(30)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                            .onClick({ evt =>
                                this.isLocked = true
                            })
                        }

                        Blank()

                        // 组件级 if/else 切图标（D-133：@r() 不塞值级 if/else 表达式分支）
                        Column {
                            if (this.isLocked) {
                                Image(@r(app.media.callui_ic_send))
                                    .width(24)
                                    .height(24)
                                    .fillColor(0xFFFFFF)
                            } else {
                                Image(@r(app.media.callui_ic_mic))
                                    .width(24)
                                    .height(24)
                                    .fillColor(0xFFFFFF)
                            }
                        }
                        .width(60)
                        .height(60)
                        .backgroundColor(0x0088CC)
                        .borderRadius(30)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                        .onClick({ evt =>
                            this.stopRecording(false)
                        })
                    }
                    .width(100.percent)
                    .padding(left: 40, right: 40)
                    .margin(top: 32)
                }
                .width(100.percent)
                .padding(top: 40, bottom: 40)
                .backgroundColor(0xFFFFFF)
                .borderRadius(topLeft: 24, topRight: 24)
            } else {
                Column {
                    Row {
                        Column {}
                            .width(36)
                            .height(4)
                            .backgroundColor(0xD1D1D6)
                            .borderRadius(2)
                    }
                    .width(100.percent)
                    .justifyContent(FlexAlign.Center)
                    .padding(top: 8, bottom: 16)
                    
                    Text(trSource("Voice Message"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .margin(bottom: 20)
                    
                    // 资源保真修复：真实矢量图标（Item List/Icons/Microphone.imageset/microphone.pdf）替代 "🎤" 字形
                    Column {
                        Image(@r(app.media.callui_ic_mic))
                            .width(40)
                            .height(40)
                            .fillColor(0xFFFFFF)
                    }
                    .width(80)
                    .height(80)
                    .backgroundColor(0x0088CC)
                    .borderRadius(40)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .onClick({ evt =>
                        this.startRecording()
                    })
                    
                    Text("Tap to record")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 12)
                    
                    Button(trSource("Cancel"))
                        .width(90.percent)
                        .height(50)
                        .fontSize(17)
                        .fontColor(0x0088CC)
                        .backgroundColor(0xF2F2F7)
                        .borderRadius(12)
                        .margin(top: 24, bottom: 16)
                        .onClick({ evt =>
                            this.onCancel()
                        })
                }
                .width(100.percent)
                .backgroundColor(0xFFFFFF)
                .borderRadius(topLeft: 16, topRight: 16)
                .alignItems(HorizontalAlign.Center)
            }
        }
        .width(100.percent)
    }
}
