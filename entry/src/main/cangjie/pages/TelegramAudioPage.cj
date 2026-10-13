package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    TelegramAudioService,
    AudioOutputRoute,
    AudioSessionState,
    getTelegramAudioService
}
import kit.CoreFileKit.*
import ohos_app_cangjie_entry.router.*

/**
 * TelegramAudioPage — 音频会话管理 UI（混合工程迁移版）
 *
 * 对应 iOS TelegramAudio 子模块（AudioSessionManager / ManagedAudioSession）。
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹
 *  - pageStack.pop() → routerPop()
 *  - aboutToAppear 有实逻辑 → ensureLoaded()+.onAppear
 *
 * MTProto：iOS 源文件无 TL 方法，N/A。
 */
@HybridComponentEntry
@Component
public class TelegramAudioPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var playFilePath: String = ""
    @State var recordFilePath: String = ""
    @State var isPlaying: Bool = false
    @State var isRecording: Bool = false
    @State var playProgress: Float64 = 0.0
    @State var recordedBytes: Int64 = 0
    @State var sessionStateLabel: String = "Idle"
    @State var routeLabel: String = "Speaker"
    @State var interruptCount: Int32 = 0
    @State var statusMessage: String = ""
    @State var isSpeaker: Bool = true
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        refreshState()
    }

    // ── 状态刷新 ───────────────────────────────────────────────────────

    private func refreshState(): Unit {
        this.isPlaying = TelegramAudioService.isPlaying()
        this.isRecording = TelegramAudioService.isRecording()
        this.playProgress = TelegramAudioService.getPlaybackProgress()
        this.recordedBytes = TelegramAudioService.getRecordedBytes()
        this.interruptCount = TelegramAudioService.getInterruptCount()
        let route = TelegramAudioService.getCurrentRoute()
        this.isSpeaker = match (route) {
            case AudioOutputRoute.Speaker => true
            case AudioOutputRoute.Earphone => false
        }
        this.routeLabel = match (route) {
            case AudioOutputRoute.Speaker => "Speaker"
            case AudioOutputRoute.Earphone => "Earphone"
        }
        let state = TelegramAudioService.getSessionState()
        this.sessionStateLabel = match (state) {
            case AudioSessionState.Idle => "Idle"
            case AudioSessionState.Playing => "Playing"
            case AudioSessionState.Recording => "Recording"
            case AudioSessionState.PlaybackInterrupted => "Interrupted"
        }
    }

    // ── 播放逻辑 ───────────────────────────────────────────────────────

    private func doPlay(): Unit {
        let path = this.playFilePath
        if (path.size == 0) {
            this.statusMessage = "Enter a file path to play"
            return
        }
        this.statusMessage = "Starting playback..."
        let _ = spawn {
            let ok = TelegramAudioService.playAudio(path)
            launch {
                if (ok) {
                    this.isPlaying = true
                    this.sessionStateLabel = "Playing"
                    this.statusMessage = "Playing"
                } else {
                    this.statusMessage = "Playback failed"
                    this.isPlaying = false
                }
            }
        }
    }

    private func doStop(): Unit {
        TelegramAudioService.stopAudio()
        this.isPlaying = false
        this.playProgress = 0.0
        this.sessionStateLabel = "Idle"
        this.statusMessage = "Stopped"
    }

    private func doRefreshProgress(): Unit {
        let _ = spawn {
            let progress = TelegramAudioService.getPlaybackProgress()
            let stillPlaying = TelegramAudioService.isPlaying()
            let interrupts = TelegramAudioService.getInterruptCount()
            launch {
                this.playProgress = progress
                this.isPlaying = stillPlaying
                this.interruptCount = interrupts
                if (!stillPlaying && this.sessionStateLabel == "Playing") {
                    this.sessionStateLabel = "Idle"
                    this.playProgress = 0.0
                }
            }
        }
    }

    // ── 录音逻辑 ───────────────────────────────────────────────────────

    private func doStartRecord(): Unit {
        let _ = spawn {
            let ok = TelegramAudioService.startRecording()
            launch {
                if (ok) {
                    this.isRecording = true
                    this.sessionStateLabel = "Recording"
                    this.statusMessage = "Recording..."
                } else {
                    this.statusMessage = "Failed to start recording"
                }
            }
        }
    }

    private func doStopRecord(): Unit {
        let path = this.recordFilePath
        if (path.size == 0) {
            TelegramAudioService.cancelRecording()
            this.isRecording = false
            this.statusMessage = "Recording cancelled (no output path)"
            this.sessionStateLabel = "Idle"
            return
        }
        let _ = spawn {
            let written = TelegramAudioService.stopRecording(path)
            launch {
                this.isRecording = false
                this.recordedBytes = written
                this.sessionStateLabel = "Idle"
                if (written > 0) {
                    this.statusMessage = "Saved ${written} bytes"
                } else {
                    this.statusMessage = "Recording save failed"
                }
            }
        }
    }

    private func doRefreshRecordBytes(): Unit {
        let _ = spawn {
            let bytes = TelegramAudioService.getRecordedBytes()
            launch {
                this.recordedBytes = bytes
            }
        }
    }

    // ── 路由逻辑 ───────────────────────────────────────────────────────

    private func doToggleRoute(): Unit {
        let newRoute: AudioOutputRoute = if (this.isSpeaker) {
            AudioOutputRoute.Earphone
        } else {
            AudioOutputRoute.Speaker
        }
        TelegramAudioService.setOutputRoute(newRoute)
        this.isSpeaker = !this.isSpeaker
        this.routeLabel = if (this.isSpeaker) { "Speaker" } else { "Earphone" }
        this.statusMessage = "Route: ${this.routeLabel}"
        Hilog.info(0, "CjTelegram", "[TelegramAudioPage] Route toggled to ${this.routeLabel}")
    }

    // ── build ─────────────────────────────────────────────────────────

    func build() {
        Column() {
            // 标题
            Text("Audio Session")
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .margin(top: 16, bottom: 8)

            // 状态行
            Row() {
                Text("State: ${this.sessionStateLabel}")
                    .fontSize(14)
                Text("  Route: ${this.routeLabel}")
                    .fontSize(14)
                Text("  Interrupts: ${this.interruptCount}")
                    .fontSize(14)
            }
            .width(100.percent)
            .padding(left: 16, right: 16)
            .margin(bottom: 8)

            // 状态消息
            if (this.statusMessage.size > 0) {
                Text(this.statusMessage)
                    .fontSize(13)
                    .fontColor(0xFF888888)
                    .padding(left: 16, right: 16)
                    .margin(bottom: 8)
            }

            Divider().margin(top: 4, bottom: 12)

            // ── 播放区 ──────────────────────────────────────────
            Text("Playback")
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .padding(left: 16)
                .margin(bottom: 6)

            Text("WAV file path to play:")
                .fontSize(12)
                .fontColor(0xFF888888)
                .padding(left: 16)
            TextInput(text: this.playFilePath)
                .onChange({ value: String =>
                    this.playFilePath = value
                })
                .padding(left: 16, right: 16)
                .margin(bottom: 8)

            // 进度条
            Slider(value: Float64(Int64(this.playProgress * 100.0)), min: 0.0, max: 100.0, step: 1.0)
                .width(100.percent)
                .padding(left: 16, right: 16)
                .margin(bottom: 6)

            Text("Progress: ${Int64(this.playProgress * 100.0)}%")
                .fontSize(13)
                .fontColor(0xFF888888)
                .padding(left: 16)
                .margin(bottom: 8)

            Row() {
                Button(if (this.isPlaying) { "Stop" } else { "Play" })
                    .onClick({ _ =>
                        if (this.isPlaying) {
                            doStop()
                        } else {
                            doPlay()
                        }
                    })
                    .width(100)
                    .margin(right: 8)

                Button("Refresh")
                    .onClick({ _ =>
                        doRefreshProgress()
                    })
                    .width(90)
            }
            .padding(left: 16)
            .margin(bottom: 12)

            Divider().margin(top: 4, bottom: 12)

            // ── 录音区 ──────────────────────────────────────────
            Text("Recording")
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .padding(left: 16)
                .margin(bottom: 6)

            Text("Output WAV file path:")
                .fontSize(12)
                .fontColor(0xFF888888)
                .padding(left: 16)
            TextInput(text: this.recordFilePath)
                .onChange({ value: String =>
                    this.recordFilePath = value
                })
                .padding(left: 16, right: 16)
                .margin(bottom: 6)

            Text("Recorded: ${this.recordedBytes} bytes")
                .fontSize(13)
                .fontColor(0xFF888888)
                .padding(left: 16)
                .margin(bottom: 8)

            Row() {
                Button(if (this.isRecording) { "Stop Record" } else { "Record" })
                    .onClick({ _ =>
                        if (this.isRecording) {
                            doStopRecord()
                        } else {
                            doStartRecord()
                        }
                    })
                    .width(120)
                    .margin(right: 8)

                Button("Refresh")
                    .onClick({ _ =>
                        doRefreshRecordBytes()
                    })
                    .width(90)
            }
            .padding(left: 16)
            .margin(bottom: 12)

            Divider().margin(top: 4, bottom: 12)

            // ── 路由切换 ─────────────────────────────────────────
            Text("Output Route")
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .padding(left: 16)
                .margin(bottom: 6)

            Row() {
                Text(trSource("Speaker"))
                    .fontSize(14)
                    .margin(right: 8)

                Toggle(ToggleType.Switch, isOn: this.isSpeaker)
                    .onChange({ isOn: Bool =>
                        let newRoute: AudioOutputRoute = if (isOn) {
                            AudioOutputRoute.Speaker
                        } else {
                            AudioOutputRoute.Earphone
                        }
                        TelegramAudioService.setOutputRoute(newRoute)
                        this.isSpeaker = isOn
                        this.routeLabel = if (isOn) { "Speaker" } else { "Earphone" }
                        this.statusMessage = "Route: ${this.routeLabel}"
                    })

                Text("Earphone")
                    .fontSize(14)
                    .margin(left: 8)
            }
            .padding(left: 16)
            .margin(bottom: 16)

            // 返回按钮
            Button(trSource("Back"))
                .onClick({ _ =>
                    routerPop()
                })
                .width(100)
                .margin(left: 16, bottom: 24)
        }
        .width(100.percent)
        .onAppear({ => this.ensureLoaded() })
    }
}
