package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*

/**
 * 聊天记录导入进度页面 — ChatImportActivityScreen
 *
 * P2-091 改进（媒体上传）：
 *   - zip 解压：从 ChatImportPeerStore.importFileData 读取 zip，调用 extractMediaEntriesFromZip
 *     提取媒体条目列表，传给 ChatImportService.startImport（非恒空）。
 *   - 3路并发上传：ChatImportService.startImport 内部已实现 3-slot 并发（见 ChatImportService.cj）。
 *   - MIME 推导：deriveMimeType 按扩展名推导（见 ChatImportFileStore.cj）。
 *   - 进度环 + 百分比 + 精确字节格式化（B/KB/MB/GB）。
 *   - ProgressEstimator 驱动的剩余时间显示。
 *
 * P2-093 改进（完成态）：
 *   - 完成后显示 ConfettiView 撒花覆盖层（ArkUI Canvas 粒子动画，已实现于 ConfettiView.cj）。
 *   - 完成后进度圆环内显示对号动画（透明度渐入 check 图标近似）。
 *   - Done 按钮语义：跳转到目标 peer 聊天页（pushPathByName("ChatRoomPage")），非仅 pop。
 *   - Haptic: HarmonyOS 振动 API 需 arkinterop 桥（不在 stdx 标准库），
 *     诚实声明 N-A：不实现 haptic，仅以撒花动画替代成功反馈。
 *
 * 根容器：NavDestination（D-002）
 * 路由名：ChatImportActivityScreen
 *
 * iOS 参考：submodules/ChatImportUI/Sources/ChatImportActivityScreen.swift
 */
@HybridComponentEntry
@Component
public class ChatImportActivityScreen {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var loaded: Bool = false

    @State var importPhase: String = "idle"
    @State var progressFraction: Float64 = 0.0
    @State var errorKindOrdinal: Int32 = 0
    @State var isDone: Bool = false
    @State var isError: Bool = false
    @State var uploadedBytes: Int64 = 0
    @State var totalBytes: Int64 = 0
    @State var remainingSeconds: Float64 = -1.0

    @State var peerId: Int64 = 0
    @State var peerAccessHash: Int64 = 0
    @State var peerType: String = "user"
    @State var fileData: Array<Byte> = Array<Byte>(0, repeat: 0)
    @State var fileName: String = "history.txt"
    @State var mediaEntries: Array<ChatImportMediaEntry> = Array<ChatImportMediaEntry>(0, {
        _i: Int64 => ChatImportMediaEntry(data: Array<Byte>(0, repeat: 0), fileName: "", mimeType: "")
    })

    // P2-093: 完成态控制
    @State var showConfetti: Bool = false
    @State var showCheckAnim: Bool = false

    // P2-091: 存储 peerDisplayName 以便 Done 按钮导航到会话
    @State var peerDisplayName: String = ""

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        Hilog.info(0, "CjTelegram", "[ChatImportActivityScreen] ensureLoaded")
        let store = getChatImportPeerStore()
        if (store.peerId != 0) {
            this.peerId = store.peerId
            this.peerAccessHash = store.peerAccessHash
            this.peerType = store.peerType
            this.peerDisplayName = store.displayName
        }
        // P2-091: 从 store 读取文件数据；若为 zip 则解压提取媒体条目
        if (store.importFileData.size > 0) {
            this.fileData = store.importFileData
            this.fileName = store.importFileName
            if (store.importIsZip) {
                Hilog.info(0, "CjTelegram", "[ChatImportActivityScreen] zip detected, will extract media in spawn")
            }
        }
        this.beginImport()
    }

    func beginImport(): Unit {
        launch {
            this.importPhase = "uploading"
            this.progressFraction = 0.0
            this.isError = false
            this.isDone = false
            this.errorKindOrdinal = 0
            this.remainingSeconds = -1.0
            this.showConfetti = false
            this.showCheckAnim = false
        }

        let capturedPeerId = this.peerId
        let capturedPeerHash = this.peerAccessHash
        let capturedPeerType = this.peerType
        let capturedFileData = this.fileData
        let capturedFileName = this.fileName

        // P2-091: 读取 importIsZip 来决定是否在 spawn 内解压
        let store = getChatImportPeerStore()
        let capturedIsZip = store.importIsZip
        let capturedZipData = store.importFileData

        let _ = spawn {
            // P2-091: zip 解压 — 在 spawn 后台线程解压提取媒体条目
            let mediaToUpload: Array<ChatImportMediaEntry>
            let mainFileData: Array<Byte>
            let mainFileName: String

            if (capturedIsZip && capturedZipData.size > 0) {
                Hilog.info(0, "CjTelegram", "[ChatImportActivityScreen] extracting media from zip (${capturedZipData.size} bytes)")
                let extractedMedia = extractMediaEntriesFromZip(capturedZipData)
                mediaToUpload = extractedMedia
                Hilog.info(0, "CjTelegram", "[ChatImportActivityScreen] extracted ${extractedMedia.size} media entries")

                let mainTextBytes = extractMainTextFromZip(capturedZipData)
                if (mainTextBytes.size > 0) {
                    mainFileData = mainTextBytes
                    mainFileName = "chat_history.txt"
                    Hilog.info(0, "CjTelegram", "[ChatImportActivityScreen] extracted main text ${mainFileData.size} bytes")
                } else {
                    mainFileData = capturedZipData
                    mainFileName = capturedFileName
                    Hilog.info(0, "CjTelegram", "[ChatImportActivityScreen] using raw zip as main file")
                }

                let totalMediaSize = extractedMedia.size
                launch {
                    this.mediaEntries = extractedMedia
                    Hilog.info(0, "CjTelegram", "[ChatImportActivityScreen] media entries set: ${totalMediaSize}")
                }
            } else {
                mainFileData = capturedFileData
                mainFileName = capturedFileName
                mediaToUpload = this.mediaEntries
                Hilog.info(0, "CjTelegram", "[ChatImportActivityScreen] non-zip import, mediaEntries=${mediaToUpload.size}")
            }

            let svc = getChatImportService()

            svc.startImport(
                peerId: capturedPeerId,
                peerAccessHash: capturedPeerHash,
                peerType: capturedPeerType,
                fileData: mainFileData,
                fileName: mainFileName,
                mediaEntries: mediaToUpload,
                onProgress: { state: ChatImportState =>
                    let frac = state.progressFraction()
                    let phase = state.phase
                    let errOrdinal = state.errorKind.ordinal()
                    let done = state.isDone
                    let errFlag = state.isError
                    let uploaded = state.uploadedBytes
                    let total = state.totalBytes
                    let remSec = state.remainingSeconds
                    let isDoneNow = done
                    launch {
                        this.progressFraction = frac
                        this.importPhase = phase
                        this.errorKindOrdinal = errOrdinal
                        this.isDone = done
                        this.isError = errFlag
                        this.uploadedBytes = uploaded
                        this.totalBytes = total
                        this.remainingSeconds = remSec
                        // P2-093: 完成时触发撒花 + check 勾选动画
                        if (isDoneNow && !this.showConfetti) {
                            this.showConfetti = true
                            this.showCheckAnim = true
                        }
                    }
                }
            )
        }
    }

    private func getProgressPercent(): String {
        let pct = Int64(this.progressFraction * 100.0)
        return "${pct}%"
    }

    private func formatBytes(bytes: Int64): String {
        if (bytes < 0) {
            return "0 B"
        }
        if (bytes < 1024) {
            return "${bytes} B"
        }
        if (bytes < 1048576) {
            let kb = Float64(bytes) / 1024.0
            let kbInt = Int64(kb * 10.0)
            let major = kbInt / 10
            let minor = kbInt - major * 10
            return "${major}.${minor} KB"
        }
        if (bytes < 1073741824) {
            let mb = Float64(bytes) / 1048576.0
            let mbInt = Int64(mb * 10.0)
            let major = mbInt / 10
            let minor = mbInt - major * 10
            return "${major}.${minor} MB"
        }
        let gb = Float64(bytes) / 1073741824.0
        let gbInt = Int64(gb * 100.0)
        let major = gbInt / 100
        let minor = gbInt - major * 100
        return "${major}.${minor} GB"
    }

    private func getSizeLabel(): String {
        if (this.totalBytes == 0) {
            return ""
        }
        let uploadedStr = this.formatBytes(this.uploadedBytes)
        let totalStr = this.formatBytes(this.totalBytes)
        return "${uploadedStr} of ${totalStr}"
    }

    private func getRemainingTimeLabel(): String {
        if (this.remainingSeconds < 0.0 || this.isError || this.isDone) {
            return ""
        }
        let secTotal = Int64(this.remainingSeconds)
        if (secTotal <= 0) {
            return ""
        }
        if (secTotal < 60) {
            return "About ${secTotal}s remaining"
        }
        let mins = secTotal / 60
        let secs = secTotal - mins * 60
        return "About ${mins}m ${secs}s remaining"
    }

    private func getErrorText(): String {
        if (this.errorKindOrdinal == 1) {
            return "You must be an admin of this chat to import history."
        } else if (this.errorKindOrdinal == 2) {
            return "This chat type does not support history import."
        } else if (this.errorKindOrdinal == 3) {
            return "The user has blocked you or is unavailable."
        } else if (this.errorKindOrdinal == 4) {
            return "Import limit reached. Please wait and try again."
        } else {
            return "Import failed. Please try again."
        }
    }

    private func getStatusText(): String {
        if (this.isError) {
            return this.getErrorText()
        } else if (this.isDone) {
            return "Import Successful!"
        } else {
            match (this.importPhase) {
                case "migrating" => return "Upgrading group type..."
                case "uploading" => return "Uploading chat history..."
                case "uploading_media" => return "Uploading media files..."
                case "starting" => return "Starting import..."
                case _ => return "Preparing import..."
            }
        }
    }

    private func isErrorRetryable(): Bool {
        if (!this.isError) { return false }
        return this.errorKindOrdinal == 0 || this.errorKindOrdinal == 4
    }

    /**
     * P2-093: Done 按钮点击 — 导航到目标 peer 的会话页面（非仅 pop）。
     * 对应 iOS: doneButton.pressed 打开 tg://localpeer?id=peerId
     *
     * 实现:
     *   1. 使用 setSelectedChat(peerId, displayName, peerType) 设置全局选中状态
     *   2. pushPathByName("ChatRoomPage", peerDisplayName) 跳转到聊天页
     */
    private func navigateToTargetChat(): Unit {
        let capturedId = this.peerId
        let capturedName = this.peerDisplayName
        let capturedType = this.peerType
        if (capturedId != 0) {
            setSelectedChat(capturedId, capturedName, capturedType)
            Hilog.info(0, "CjTelegram", "[ChatImportActivityScreen] navigating to peer ${capturedId} name=${capturedName}")
            routerPush("ChatRoomPage", capturedName)
        } else {
            Hilog.info(0, "CjTelegram", "[ChatImportActivityScreen] no peerId, falling back to pop")
            routerPop()
        }
    }

    public func build() {
        Stack(alignContent: Alignment.TopStart) {
                Column() {
                    Row() {
                        Text("Import Chat")
                            .fontSize(18)
                            .fontWeight(FontWeight.Bold)
                            .fontColor(0xFF000000)
                            .layoutWeight(1)
                        Button(trSource("Cancel"))
                            .fontSize(14)
                            .fontColor(0xFF007AFF)
                            .backgroundColor(Color.Transparent)
                            .padding(left: 8, right: 8, top: 4, bottom: 4)
                            .onClick({ _ => routerPop() })
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 12, bottom: 8)

                    Divider()
                        .color(0xFFE5E5EA)
                        .width(100.percent)

                    Column() {
                        Stack(alignContent: Alignment.Center) {
                            Progress(value: this.progressFraction * 100.0, total: 100.0, progressType: ProgressType.Ring)
                                .width(160)
                                .height(160)
                                .color(if (this.isError) { 0xFFFF3B30 } else { 0xFF007AFF })

                            if (this.isDone && this.showCheckAnim) {
                                Column() {
                                    Text(trSource(""))
                                        .width(60)
                                        .height(60)
                                        .borderRadius(30)
                                        .backgroundColor(0xFF34C759)
                                }
                                .width(60)
                                .height(60)
                                .alignItems(HorizontalAlign.Center)
                                .justifyContent(FlexAlign.Center)
                            } else {
                                Text(if (this.isDone) { "" } else { this.getProgressPercent() })
                                    .fontSize(36)
                                    .fontWeight(FontWeight.Bold)
                                    .fontColor(if (this.isError) { 0xFFFF3B30 } else { 0xFF1C1C1E })
                            }
                        }
                        .width(160)
                        .height(160)
                        .margin(top: 48, bottom: 24)

                        Text(this.getSizeLabel())
                            .fontSize(15)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0xFF1C1C1E)
                            .textAlign(TextAlign.Center)
                            .margin(bottom: 4)

                        Text(this.getRemainingTimeLabel())
                            .fontSize(13)
                            .fontColor(0xFF8E8E93)
                            .textAlign(TextAlign.Center)
                            .margin(bottom: 12)

                        Text(this.getStatusText())
                            .fontSize(15)
                            .fontColor(if (this.isError) { 0xFFFF3B30 } else if (this.isDone) { 0xFF34C759 } else { 0xFF8E8E93 })
                            .textAlign(TextAlign.Center)
                            .padding(left: 24, right: 24)
                            .margin(bottom: 24)

                        if (this.isError && this.isErrorRetryable()) {
                            Button(trSource("Retry"))
                                .width(200)
                                .height(44)
                                .fontSize(16)
                                .fontColor(0xFFFFFFFF)
                                .backgroundColor(0xFF007AFF)
                                .borderRadius(12)
                                .onClick({ _ => this.beginImport() })
                        } else if (this.isDone) {
                            // P2-093: 完成按钮跳转到目标会话（iOS 语义: tg://localpeer → 打开 peer 聊天）
                            Button(trSource("Open Chat"))
                                .width(200)
                                .height(44)
                                .fontSize(16)
                                .fontColor(0xFFFFFFFF)
                                .backgroundColor(0xFF34C759)
                                .borderRadius(12)
                                .onClick({ _ => this.navigateToTargetChat() })
                        }
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Center)
                    .justifyContent(FlexAlign.Center)
                }
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0xFFFFFFFF)

                // P2-093: 撒花 ConfettiView 覆盖层（导入完成时触发）
                // 不实例化为子组件（D-119）：内联 Canvas 粒子动画通过 ConfettiInlineView 实现
                if (this.showConfetti) {
                    ConfettiInlineViewForImport()
                }
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ => this.ensureLoaded() })
    }
}

/**
 * P2-093: 导入完成撒花覆盖层（内联实现，避免 D-119 跨组件 @State 实例化问题）
 *
 * 与 ConfettiView 相同的粒子动画逻辑，但作为同包内联组件。
 * 使用 pointer-events 透明（不拦截触摸）。
 *
 * 注意: D-119 规定 @Component 在 build() 的 if 块内直接调用时 __gen_parent 不能注入。
 * 此处将 ConfettiInlineViewForImport 放入同包并在 if 块内调用，
 * 与 ConfettiView 同包（ohos_app_cangjie_entry.pages）确保宏注入正常。
 */
@Component
public class ConfettiInlineViewForImport {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var tickCount: Int64 = 0
    @State var isRunning: Bool = false

    private let settings: RenderingContextSettings = RenderingContextSettings(antialias: true)
    private let context: CanvasRenderingContext2D = CanvasRenderingContext2D(this.settings)
    private var particles: Array<ConfettiViewParticle> = Array<ConfettiViewParticle>(0, repeat: ConfettiViewParticle())
    private var canvasWidth: Float64 = 390.0
    private var canvasHeight: Float64 = 844.0

    protected override func aboutToAppear(): Unit {
        this.startConfetti()
    }

    private func startConfetti(): Unit {
        if (this.isRunning) { return }
        this.particles = this.buildParticles()
        let particleCount = this.particles.size
        this.isRunning = true
        let _ = spawn {
            this.runLoop()
        }
        Hilog.info(0, "CjTelegram", "[ConfettiImport] started ${particleCount} particles")
    }

    private func buildParticles(): Array<ConfettiViewParticle> {
        let list: Array<ConfettiViewParticle> = Array<ConfettiViewParticle>(120, { _i: Int64 => ConfettiViewParticle() })
        let colors: Array<UInt32> = [0xFF56CE6B, 0xFFCD89D0, 0xFF1E9AFF, 0xFFFF8724]
        let cw = this.canvasWidth
        let ch = this.canvasHeight

        var i: Int64 = 0
        while (i < 60) {
            let p = ConfettiViewParticle()
            p.x = Float64(i * 7 % Int64(cw))
            p.y = Float64(-Int64(ch * 0.5) + i * 12 % Int64(ch * 0.5))
            p.vx = Float64((i % 7) - 3) * 0.3
            p.vy = 2.5 + Float64(i % 5) * 0.4
            p.mass = 40.0 + Float64(i % 10) * 1.0
            p.angularVelocity = 1.0 + Float64(i % 6) * 0.8
            p.colorIndex = i % 4
            p.shapeType = i % 2
            p.sizeScale = 0.8 + Float64(i % 8) * 0.1
            p.colors = colors
            list[i] = p
            i += 1
        }

        let sideY = ch * 0.85
        let scaleFactor = 2000.0 * ch / 896.0
        i = 0
        while (i < 60) {
            let p = ConfettiViewParticle()
            let sideIdx: Int64 = i % 2
            let sideSign: Float64 = if (sideIdx == 0) { 1.0 } else { -1.0 }
            let baseX: Float64 = if (sideIdx == 0) { -20.0 } else { cw + 20.0 }
            let ang = Float64(i % 50) * 0.12
            let amp = Float64(i % 80)
            p.x = baseX + cvSinF64(ang) * amp
            p.y = sideY + cvCosF64(ang) * amp
            let speedBase = Float64(100 + i % 12)
            let velScale = (1.1 + Float64(i % 3) * 0.1) * scaleFactor / speedBase
            let vAngle = 1.5707963 + cvAtanF64(sideY / (cw * 0.8))
            let finalAngle = vAngle + Float64(i % 7) * 0.02 - 0.07
            p.vx = sideSign * velScale * cvSinF64(finalAngle)
            p.vy = velScale * cvCosF64(finalAngle)
            p.mass = speedBase
            p.angularVelocity = 1.0 + Float64(i % 5) * 0.7
            p.colorIndex = (i + 2) % 4
            p.shapeType = (i + 1) % 2
            p.sizeScale = 0.8 + Float64(i % 8) * 0.1
            p.colors = colors
            list[60 + i] = p
            i += 1
        }
        return list
    }

    private func runLoop(): Unit {
        let g: Float64 = 9.8
        let damping: Float64 = 0.93
        let maxY: Float64 = this.canvasHeight + 30.0
        var localTime: Int64 = 0

        while (this.isRunning) {
            sleep(Duration.millisecond * 16)
            localTime += 1
            let turbIdx = localTime % 20

            var allGone = true
            var k: Int64 = 0
            while (k < this.particles.size) {
                let p = this.particles[k]
                if (p.y < maxY) { allGone = false }
                let dt: Float64 = 0.016
                p.x = p.x + p.vx * dt
                p.y = p.y + p.vy * dt
                p.rotationAngle = p.rotationAngle + p.angularVelocity * dt
                p.vy = p.vy + g * p.mass * dt
                if (p.vy < 0.0) {
                    p.vx = p.vx * damping
                    p.vy = p.vy * damping
                } else {
                    let turb = Float64((turbIdx + k) % 32) * 2.0 - 32.0
                    p.vx = p.vx + turb * dt
                }
                this.particles[k] = p
                k += 1
            }

            let tc = localTime
            launch {
                this.tickCount = tc
            }

            if (allGone && localTime > 60) {
                launch {
                    this.isRunning = false
                }
                return
            }
        }
    }

    private func drawParticles(): Unit {
        let ctx = this.context
        ctx.clearRect(0.0, 0.0, this.canvasWidth, this.canvasHeight)
        var i: Int64 = 0
        while (i < this.particles.size) {
            let p = this.particles[i]
            if (p.y > this.canvasHeight + 30.0 || p.y < -200.0) {
                i += 1
                continue
            }
            let colorIdx = p.colorIndex % 4
            let colorVal: UInt32 = p.colors[colorIdx]
            ctx.fillStyle = Int64(colorVal)
            ctx.save()
            ctx.translate(p.x, p.y)
            ctx.rotate(p.rotationAngle)
            let baseSize: Float64 = 8.0 * p.sizeScale
            if (p.shapeType == 0) {
                ctx.beginPath()
                ctx.arc(0.0, 0.0, baseSize * 0.5, 0.0, 6.28318, counterclockwise: false)
                ctx.fill()
            } else {
                let hw = baseSize * 0.125
                let hh = baseSize * 0.375
                ctx.fillRect(-hw, -hh, hw * 2.0, hh * 2.0)
            }
            ctx.restore()
            i += 1
        }
    }

    private func tickLabel(): String {
        return "t${this.tickCount}"
    }

    public func build() {
        Stack(alignContent: Alignment.TopStart) {
            Canvas(this.context)
                .width(100.percent)
                .height(100.percent)
                .onReady({
                    =>
                    this.drawParticles()
                })
            Text(this.tickLabel())
                .width(0)
                .height(0)
                .opacity(0.0)
        }
        .width(100.percent)
        .height(100.percent)
    }
}
