package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.sync.*
import std.time.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*
import ohos.resource.__GenerateResource__
import ohos.resource.AppResource

/**
 * SecretMediaPreviewPage — 阅后即焚媒体预览页（GALL-UI-2）（混合工程迁移版）
 *
 * 对应 iOS SecretMediaPreviewController + SecretMediaPreviewControllerNode
 *
 * 功能：
 *   - 展示单张阅后即焚媒体（图片/视频）
 *   - 自毁计时器：倒计时结束后自动关闭页面（对应 RadialStatusNode timeoutNode）
 *   - 计时器由 Timer.repeat 驱动，每秒 tick 一次，写 @State 通过 launch{}
 *   - 支持路由参数："timeout|mediaPath|mediaType"（如 "10|file:///...|photo"）
 *
 * 路由参数格式："selfDestructSeconds|localPath|mediaType"
 *   selfDestructSeconds = 0 表示无自毁计时（view-once 仍关闭）
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - onReady param(NavDestinationContext) → takePending("SecretMediaPreviewPage")
 *  - appStack.pop() → routerPop()
 *  - aboutToAppear(实逻辑：解析参数 + 启动倒计时) → ensureLoaded() + .onAppear
 *  - aboutToDisappear(cancelTimer) → cleanup() + .onDisAppear
 */
@HybridComponentEntry
@Component
public class SecretMediaPreviewPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var mediaPath: String = ""
    @State var mediaType: String = ""
    @State var selfDestructSeconds: Int32 = 0
    @State var countdown: Int32 = 0
    @State var timerActive: Bool = false
    @State var loaded: Bool = false

    private var countdownTimer: Option<Timer> = None

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let raw = takePending("SecretMediaPreviewPage")
        this.parseRouteParam(raw)
        if (this.selfDestructSeconds > 0) {
            this.startCountdown()
        }
        Hilog.info(0, "CjTelegram", "[SecretMediaPreviewPage] appear: timeout=${this.selfDestructSeconds}")
    }

    private func cleanup(): Unit {
        this.cancelTimer()
        Hilog.info(0, "CjTelegram", "[SecretMediaPreviewPage] disappear")
    }

    public func build() {
        Stack {
            // 深色背景
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0x000000)

            // 媒体内容
            if (this.mediaPath.size > 0) {
                Image(this.mediaPath)
                    .width(100.percent)
                    .height(100.percent)
                    .objectFit(ImageFit.Contain)
            } else {
                // 资源保真修复：Chat/Context Menu/Lock.imageset/Lock.pdf 转 SVG
                Column {
                    Image(@r(app.media.media_ic_lock))
                        .width(64)
                        .height(64)
                        .fillColor(0x8E8E93)
                    Text("Secret Media")
                        .fontSize(16)
                        .fontColor(0x8E8E93)
                        .margin(top: 8)
                }
                .width(100.percent)
                .height(100.percent)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            }

            // 顶部栏：标题 + 倒计时 + 关闭
            Column {
                Row {
                    Text("Secret Media")
                        .fontSize(16)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xFFFFFF)
                        .layoutWeight(1)

                    if (this.selfDestructSeconds > 0) {
                        Row {
                            Text(this.getCountdownLabel())
                                .fontSize(14)
                                .fontColor(this.getCountdownColor())
                                .margin(right: 8)
                        }
                    }

                    Button(trSource("Close"))
                        .fontSize(14)
                        .fontColor(0xFFFFFF)
                        .backgroundColor(Color.Transparent)
                        .onClick({ _ =>
                            this.cancelTimer()
                            routerPop()
                        })
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 12, bottom: 12)
                .backgroundColor(0x80000000)
            }
            .width(100.percent)
            .alignItems(HorizontalAlign.Start)
            .position(x: 0, y: 0)

            // 底部提示
            Column {
                Text("This message will self-destruct")
                    .fontSize(12)
                    .fontColor(0x8E8E93)
                    .padding(bottom: 8)
            }
            .width(100.percent)
            .alignItems(HorizontalAlign.Center)
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ => this.ensureLoaded() })
        .onDisAppear({ => this.cleanup() })
    }

    // ─── 私有辅助方法 ──────────────────────────────────────────────────────────

    private func parseRouteParam(raw: String): Unit {
        if (raw.size == 0) { return }
        let parts = raw.split("|")
        if (parts.size >= 1) {
            this.selfDestructSeconds = parseI32(parts[0])
            this.countdown = this.selfDestructSeconds
        }
        if (parts.size >= 2) {
            this.mediaPath = parts[1]
        }
        if (parts.size >= 3) {
            this.mediaType = parts[2]
        }
        Hilog.info(0, "CjTelegram", "[SecretMediaPreviewPage] param: timeout=${this.selfDestructSeconds} type=${this.mediaType}")
    }

    private func parseI32(s: String): Int32 {
        var result: Int32 = 0
        let runes = s.toRuneArray()
        var i: Int64 = 0
        while (i < Int64(runes.size)) {
            let d = Int32(UInt32(runes[i])) - 48
            if (d < 0 || d > 9) { break }
            result = result * 10 + d
            i = i + 1
        }
        return result
    }

    private func startCountdown(): Unit {
        this.timerActive = true
        let timer = Timer.repeat(
            Duration.second * 1,
            Duration.second * 1,
            { =>
                launch {
                    if (this.countdown > 0) {
                        this.countdown = this.countdown - 1
                    }
                    if (this.countdown <= 0) {
                        this.timerActive = false
                        this.cancelTimer()
                        routerPop()
                        Hilog.info(0, "CjTelegram", "[SecretMediaPreviewPage] Self-destructed")
                    }
                }
            },
            style: CatchupStyle.Skip
        )
        this.countdownTimer = Some(timer)
    }

    private func cancelTimer(): Unit {
        if (this.countdownTimer.isSome()) {
            this.countdownTimer.getOrThrow().cancel()
            this.countdownTimer = None<Timer>
            this.timerActive = false
        }
    }

    private func getCountdownLabel(): String {
        return "${this.countdown}s"
    }

    private func getCountdownColor(): Int64 {
        if (this.countdown <= 3) { return 0xFF3B30 }
        if (this.countdown <= 10) { return 0xFF9500 }
        return 0xFFFFFF
    }
}
