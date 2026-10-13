package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.mtproto.{SHA1, SHA256}
import ohos_app_cangjie_entry.utils.{secretChatKeyColorGridFromBytes, secretChatKeyEmojiFingerprint}
import ohos_app_cangjie_entry.bindings.{EncryptionKeyVisualizationBinding, KeyColorGrid}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * PassportKeyFingerprintPage — P2-285
 *
 * 显示 Telegram Passport SecureId 密钥的可视化指纹：
 * - 12×12 颜色网格（Canvas 绘制，4 种蓝/白调色板）
 * - 4 个 emoji（从 SHA1 前 8 字节映射）
 *
 * 密钥来源：getCachedSecureIdAccessContext().secret
 * SHA1(secret) → sha1Bytes → emoji + grid 第一半
 * SHA256(secret) → sha256Bytes → grid 第二半
 *
 * 对标 iOS: EncryptionKeyVisualization.swift → secretChatKeyImage(_:size:)
 * Canvas R-118: fillStyle 赋值使用 Int64 ARGB 值，禁止用 String
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - pageStack.pop() → routerPop()
 *  - aboutToAppear 有实逻辑（computeFingerprint）→ 移到 ensureLoaded()，.onAppear 触发
 */
@HybridComponentEntry
@Component
public class PassportKeyFingerprintPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    let settings: RenderingContextSettings = RenderingContextSettings(antialias: true)
    let context: CanvasRenderingContext2D = CanvasRenderingContext2D(this.settings)

    @State var emojiRow: String = ""
    @State var secretLoaded: Bool = false
    @State var noContextError: Bool = false
    // Grid data: stores Int64 ARGB values for each cell (12*12 = 144 elements)
    @State var cellColors: Array<Int64> = Array<Int64>(0, repeat: 0)
    @State var gridSize: Int32 = 12
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.computeFingerprint()
    }

    private func computeFingerprint(): Unit {
        let ctxOpt = getCachedSecureIdAccessContext()
        match (ctxOpt) {
            case None =>
                Hilog.info(0, "CjTelegram", "[PassportKeyFingerprintPage] No cached context")
                launch {
                    this.noContextError = true
                    this.secretLoaded = true
                }
            case Some(ctx) =>
                let secretBytes = ctx.secret
                let sha1 = SHA1.hash(secretBytes)
                let sha256 = SHA256.hash(secretBytes)
                let grid = secretChatKeyColorGridFromBytes(sha1, sha256)
                let emoji = secretChatKeyEmojiFingerprint(sha1)
                let flatColors = EncryptionKeyVisualizationBinding.flattenToArgbArray(grid)
                let gs = grid.gridSize
                launch {
                    this.emojiRow = emoji
                    this.cellColors = flatColors
                    this.gridSize = gs
                    this.secretLoaded = true
                }
        }
    }

    private func drawGrid(): Unit {
        let gs = Int64(this.gridSize)
        if (gs == 0) { return }
        let canvasWidth: Float64 = 240.0
        let cellSize: Float64 = canvasWidth / Float64(gs)
        var row: Int64 = 0
        while (row < gs) {
            var col: Int64 = 0
            while (col < gs) {
                let idx = row * gs + col
                if (idx < this.cellColors.size) {
                    let colorVal = this.cellColors[idx]
                    this.context.fillStyle = colorVal
                    this.context.fillRect(
                        Float64(col) * cellSize,
                        Float64(row) * cellSize,
                        cellSize,
                        cellSize
                    )
                }
                col++
            }
            row++
        }
    }

    public func build() {
        Column {
            // Navigation bar
            Row {
                Text("← Back")
                    .fontSize(17)
                    .fontColor(0x0088CC)
                    .onClick({ evt =>
                        routerPop()
                    })
                Blank()
                Text("Passport Key")
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                Blank()
                Text(trSource(""))
                    .fontSize(17)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 8, right: 8, top: getSafeAreaTop())
            .backgroundColor(0xFFFFFF)
            .alignItems(VerticalAlign.Center)

            Scroll() {
                Column {
                    if (!this.secretLoaded) {
                        LoadingProgress()
                            .width(40)
                            .height(40)
                            .margin(top: 40)
                    } else if (this.noContextError) {
                        Text("🔒 Passport Not Unlocked")
                            .fontSize(18)
                            .fontWeight(FontWeight.Medium)
                            .margin(top: 40, bottom: 12)
                        Text("Please unlock your Passport first by entering your password.")
                            .fontSize(15)
                            .fontColor(0x8E8E93)
                            .textAlign(TextAlign.Center)
                            .margin(bottom: 24)
                        Button("Go Back")
                            .width(200)
                            .height(44)
                            .fontSize(16)
                            .fontColor(0xFFFFFF)
                            .backgroundColor(0x0088CC)
                            .borderRadius(8)
                            .onClick({ evt =>
                                routerPop()
                            })
                    } else {
                        Text(trSource("Encryption Key"))
                            .fontSize(20)
                            .fontWeight(FontWeight.Bold)
                            .margin(top: 32, bottom: 8)

                        Text("This visual fingerprint confirms your Passport encryption key is secure and matches on both ends.")
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .textAlign(TextAlign.Center)
                            .margin(bottom: 24)

                        // Canvas: 12×12 color grid (240×240 pts)
                        Canvas(this.context)
                            .width(240)
                            .height(240)
                            .borderRadius(12)
                            .onReady({
                                =>
                                this.drawGrid()
                            })
                            .margin(bottom: 20)

                        // 4 emoji fingerprint row
                        Text(this.emojiRow)
                            .fontSize(32)
                            .textAlign(TextAlign.Center)
                            .margin(bottom: 32)

                        Text("Passport identity key fingerprint")
                            .fontSize(13)
                            .fontColor(0xC7C7CC)
                            .textAlign(TextAlign.Center)
                            .margin(bottom: 48)

                        Button(trSource("Done"))
                            .width(100.percent)
                            .height(48)
                            .fontSize(17)
                            .fontColor(0xFFFFFF)
                            .backgroundColor(0x0088CC)
                            .borderRadius(8)
                            .onClick({ evt =>
                                routerPop()
                            })
                    }
                }
                .width(100.percent)
                .padding(16)
                .alignItems(HorizontalAlign.Center)
            }
            .layoutWeight(1)
            .scrollBar(BarState.Off)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
