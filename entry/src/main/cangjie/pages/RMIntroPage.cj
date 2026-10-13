package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
/**
 * RMIntroPage — P2-437（混合工程迁移版）
 *
 * 首启引导动画轮播页（6页）。
 *
 * iOS 对应：submodules/RMIntro（OpenGL/GLKit 矢量动画 + scroll 进度驱动）
 *
 * GL N-A 诚实标注：
 *   iOS RMIntro 使用 OpenGL ES + GLKit 实现：
 *     - 纸飞机（animations.c: paper plane 逐帧变形）
 *     - 球体（sphere OpenGL mesh）
 *     - ∞ 无限符号（bezier 路径插值）
 *     - 相机（camera model 旋转）
 *     - 铅笔（pencil stroke 逐帧）
 *   Cangjie/HarmonyOS 无 GLKit 绑定，OpenGL ES 无直接 Cangjie API：
 *     每页使用 ArkUI Canvas 2D 几何近似 (圆形/路径/贝塞尔曲线) 替代 GL 3D 渲染。
 *     GL N-A：不能做 iOS 同等 3D mesh 动画；ArkUI Canvas 2D 是诚实可用替代方案。
 *
 * iOS scroll 进度驱动 → ArkUI Swiper 离散翻页（含 DotIndicator）
 *
 * 6页文案：
 *   page0: 纸飞机 — "Send Messages"
 *   page1: 球体   — "No Limits"
 *   page2: ∞      — "Fast & Secure"
 *   page3: 相机   — "Share Anything"
 *   page4: 铅笔   — "Huge Groups"
 *   page5: 完成   — "Welcome"
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack（appStack.pop() → routerPop()）
 *  - build() 根去掉 NavDestination 包裹，只留内部 Column（背景色下移到 Column 根）
 *  - aboutToAppear(triggerPlaneAnimation) → ensureLoaded() + .onAppear
 *
 * S-001 合规：animateTo 在 UI 线程；@State 写在 UI 线程回调中
 * S-005/D-116 合规：build() 内无 let/var
 * R-118 合规：fillStyle 使用 UInt32 (0xFFRRGGBB)
 * R-131 合规：.scale(x:y:z:) 参数使用 Float32
 */

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.utils.safeAnimateTo

// ============================================================
// 6页引导文案（iOS RMIntroPage 文案；正式多语言接入 LocalizationService）
// ============================================================

private let INTRO_TITLES: Array<String> = [
    "Send Messages",
    "No Limits",
    "Fast & Secure",
    "Share Anything",
    "Huge Groups",
    "Welcome"
]

private let INTRO_SUBTITLES: Array<String> = [
    "Send messages for free to anyone on Telegram.",
    "No limits on the size of your chats and media.",
    "Telegram delivers messages faster than any other application.",
    "Share files, photos, videos, and documents of any type.",
    "Group chats with up to 200,000 members.",
    "Telegram for HarmonyOS — fast, secure, free."
]

// 每页主题背景色（对应 iOS RMIntro 页面色调）
private let INTRO_BG_COLORS: Array<Int64> = [
    0xFF317AFF,
    0xFFFF6B35,
    0xFF34C759,
    0xFFAF52DE,
    0xFFFF9500,
    0xFF00B4D8
]

@HybridComponentEntry
@Component
public class RMIntroPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 当前页码（Swiper onChange 写入）
    @State var currentPage: Int32 = 0

    // page0 纸飞机入场动画（水平偏移 + 透明度）
    @State var planeOffset: Int64 = -80
    @State var planeOpacity: Float64 = 0.0

    // page2/4 ∞脉冲动画（scale + 透明度）
    @State var pulseScale: Float32 = Float32(0.8)
    @State var pulseOpacity: Float64 = 1.0

    @State var loaded: Bool = false

    // Canvas contexts（必须是 let 字段，不能在 build 中内联创建）
    private let ctx0: CanvasRenderingContext2D = CanvasRenderingContext2D(RenderingContextSettings(antialias: true))
    private let ctx1: CanvasRenderingContext2D = CanvasRenderingContext2D(RenderingContextSettings(antialias: true))
    private let ctx2: CanvasRenderingContext2D = CanvasRenderingContext2D(RenderingContextSettings(antialias: true))
    private let ctx3: CanvasRenderingContext2D = CanvasRenderingContext2D(RenderingContextSettings(antialias: true))
    private let ctx4: CanvasRenderingContext2D = CanvasRenderingContext2D(RenderingContextSettings(antialias: true))

    // onDismiss 回调（首启完成 → 注册/登录）
    public var onDismiss: () -> Unit = { => }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.triggerPlaneAnimation()
    }

    // ============================================================
    // 动画触发（UI 线程回调，S-001 exempt）
    // ============================================================

    private func triggerPlaneAnimation(): Unit {
        safeAnimateTo({ => getUIContext() }, AnimateParam(duration: 900, curve: Curve.EaseOut), {
            =>
            this.planeOffset = 0
            this.planeOpacity = 1.0
        })
    }

    private func triggerPulseAnimation(): Unit {
        // Reset to start state before animating
        this.pulseScale = Float32(0.8)
        this.pulseOpacity = 1.0
        // Pulse out: scale up + fade out
        safeAnimateTo({ => getUIContext() }, AnimateParam(duration: 1100, curve: Curve.EaseInOut), {
            =>
            this.pulseScale = Float32(1.35)
            this.pulseOpacity = 0.0
        })
    }

    private func onPageChanged(page: Int32): Unit {
        this.currentPage = page
        if (page == 0) { this.triggerPlaneAnimation() }
        if (page == 2) { this.triggerPulseAnimation() }
        if (page == 4) { this.triggerPulseAnimation() }
        Hilog.info(0, "CjTelegram", "[RMIntroPage] page=${page}")
    }

    // ============================================================
    // 辅助方法（不在 build 中使用 let，S-005/D-116 合规）
    // ============================================================

    private func pageTitle(idx: Int32): String {
        if (idx < 0 || Int64(idx) >= INTRO_TITLES.size) { return "" }
        return INTRO_TITLES[Int64(idx)]
    }

    private func pageSubtitle(idx: Int32): String {
        if (idx < 0 || Int64(idx) >= INTRO_SUBTITLES.size) { return "" }
        return INTRO_SUBTITLES[Int64(idx)]
    }

    private func pageBgColor(idx: Int32): Int64 {
        if (idx < 0 || Int64(idx) >= INTRO_BG_COLORS.size) { return 0xFF317AFF }
        return INTRO_BG_COLORS[Int64(idx)]
    }

    private func currentBgColor(): Int64 {
        return this.pageBgColor(this.currentPage)
    }

    // ============================================================
    // build()
    // ============================================================

    public func build() {
        Column {
            Swiper() {
                this.buildPage0()
                this.buildPage1()
                this.buildPage2()
                this.buildPage3()
                this.buildPage4()
                this.buildPage5()
            }
            .loop(false)
            .indicator(true)
            .onChange({ idx: Int32 =>
                this.onPageChanged(idx)
            })
            .layoutWeight(1)

            // 底部 "Start Messaging" 按钮
            Column {
                Button(trSource("Start Messaging"))
                    .width(280)
                    .height(50)
                    .borderRadius(25)
                    .fontSize(17)
                    .fontColor(0xFFFFFFFF)
                    .backgroundColor(
                        if (this.currentPage == 5) { 0xFF317AFF } else { 0x50FFFFFF })
                    .onClick({ _evt =>
                        Hilog.info(0, "CjTelegram", "[RMIntroPage] Start Messaging tapped")
                        this.onDismiss()
                        routerPop()
                    })
            }
            .width(100.percent)
            .height(80)
            .padding(top: 12, bottom: 16)
            .alignItems(HorizontalAlign.Center)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(0xFF000000)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFF000000)
        .onAppear({ => this.ensureLoaded() })
    }

    // ============================================================
    // 6页 @Builder（各带 Canvas 几何动画；GL N-A 诚实标注）
    // ============================================================

    @Builder
    func buildPage0() {
        // page0: 纸飞机 — Canvas 三角形路径模拟 + offset 入场动画
        // GL N-A: iOS = OpenGL 逐帧纸飞机 3D 展开变形；
        //         Cangjie = Canvas 2D 三角几何 + offset 平移入场
        Column {
            Canvas(this.ctx0)
                .width(200)
                .height(160)
                .onReady({ =>
                    this.drawPaperPlane(this.ctx0)
                })
                .offset(x: this.planeOffset, y: 0)
                .opacity(this.planeOpacity)
                .margin(bottom: 8)

            Text(this.pageTitle(0))
                .fontSize(26)
                .fontColor(0xFFFFFFFF)
                .fontWeight(FontWeight.Bold)
                .margin(top: 20)
                .textAlign(TextAlign.Center)

            Text(this.pageSubtitle(0))
                .fontSize(15)
                .fontColor(0xCCFFFFFF)
                .textAlign(TextAlign.Center)
                .padding(left: 36, right: 36)
                .margin(top: 10)
                .maxLines(3)
        }
        .width(100.percent)
        .height(100.percent)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.pageBgColor(0))
    }

    @Builder
    func buildPage1() {
        // page1: 球体 — Canvas 同心圆 + 弧线经纬线近似
        // GL N-A: iOS = OpenGL sphere mesh 3D 渲染；
        //         Cangjie = Canvas 2D fillCircle + arc 弧线
        Column {
            Canvas(this.ctx1)
                .width(180)
                .height(180)
                .onReady({ =>
                    this.drawSphere(this.ctx1)
                })
                .margin(bottom: 8)

            Text(this.pageTitle(1))
                .fontSize(26)
                .fontColor(0xFFFFFFFF)
                .fontWeight(FontWeight.Bold)
                .margin(top: 20)
                .textAlign(TextAlign.Center)

            Text(this.pageSubtitle(1))
                .fontSize(15)
                .fontColor(0xCCFFFFFF)
                .textAlign(TextAlign.Center)
                .padding(left: 36, right: 36)
                .margin(top: 10)
                .maxLines(3)
        }
        .width(100.percent)
        .height(100.percent)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.pageBgColor(1))
    }

    @Builder
    func buildPage2() {
        // page2: ∞ 无限符号脉冲（Canvas 贝塞尔曲线 + scale/opacity 动画）
        // GL N-A: iOS = OpenGL ∞ bezier 路径插值动画；
        //         Cangjie = Canvas 2D bezierCurveTo + animateTo scale
        Column {
            Stack(alignContent: Alignment.Center) {
                Canvas(this.ctx2)
                    .width(220)
                    .height(110)
                    .onReady({ =>
                        this.drawInfinity(this.ctx2)
                    })
                    .scale(x: this.pulseScale, y: this.pulseScale, z: Float32(1.0))
                    .opacity(this.pulseOpacity)
            }
            .width(220)
            .height(110)
            .margin(bottom: 8)

            Text(this.pageTitle(2))
                .fontSize(26)
                .fontColor(0xFFFFFFFF)
                .fontWeight(FontWeight.Bold)
                .margin(top: 20)
                .textAlign(TextAlign.Center)

            Text(this.pageSubtitle(2))
                .fontSize(15)
                .fontColor(0xCCFFFFFF)
                .textAlign(TextAlign.Center)
                .padding(left: 36, right: 36)
                .margin(top: 10)
                .maxLines(3)
        }
        .width(100.percent)
        .height(100.percent)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.pageBgColor(2))
    }

    @Builder
    func buildPage3() {
        // page3: 相机 — Canvas 矩形 + 圆 近似相机图标
        // GL N-A: iOS = OpenGL 相机 3D 模型旋转；
        //         Cangjie = Canvas 2D fillRect + arc 圆形镜头轮廓
        Column {
            Canvas(this.ctx3)
                .width(200)
                .height(150)
                .onReady({ =>
                    this.drawCamera(this.ctx3)
                })
                .margin(bottom: 8)

            Text(this.pageTitle(3))
                .fontSize(26)
                .fontColor(0xFFFFFFFF)
                .fontWeight(FontWeight.Bold)
                .margin(top: 20)
                .textAlign(TextAlign.Center)

            Text(this.pageSubtitle(3))
                .fontSize(15)
                .fontColor(0xCCFFFFFF)
                .textAlign(TextAlign.Center)
                .padding(left: 36, right: 36)
                .margin(top: 10)
                .maxLines(3)
        }
        .width(100.percent)
        .height(100.percent)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.pageBgColor(3))
    }

    @Builder
    func buildPage4() {
        // page4: 铅笔描绘（Canvas 折线 + scale 脉冲）
        // GL N-A: iOS = OpenGL 铅笔 stroke 逐帧展开 + ∞ mesh；
        //         Cangjie = Canvas 2D moveTo/lineTo 折线 + animateTo scale
        Column {
            Stack(alignContent: Alignment.Center) {
                Canvas(this.ctx4)
                    .width(200)
                    .height(160)
                    .onReady({ =>
                        this.drawPencil(this.ctx4)
                    })
                    .scale(x: this.pulseScale, y: this.pulseScale, z: Float32(1.0))
                    .opacity(this.pulseOpacity)
            }
            .width(200)
            .height(160)
            .margin(bottom: 8)

            Text(this.pageTitle(4))
                .fontSize(26)
                .fontColor(0xFFFFFFFF)
                .fontWeight(FontWeight.Bold)
                .margin(top: 20)
                .textAlign(TextAlign.Center)

            Text(this.pageSubtitle(4))
                .fontSize(15)
                .fontColor(0xCCFFFFFF)
                .textAlign(TextAlign.Center)
                .padding(left: 36, right: 36)
                .margin(top: 10)
                .maxLines(3)
        }
        .width(100.percent)
        .height(100.percent)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.pageBgColor(4))
    }

    @Builder
    func buildPage5() {
        // page5: 完成页 — 静态 ArkUI 布局（Telegram 品牌色 + 纸飞机 emoji 图标）
        Column {
            Column {
                Row {
                    Text("✈")
                        .fontSize(56)
                        .fontColor(0xFFFFFFFF)
                }
                .width(96)
                .height(96)
                .backgroundColor(0xFF317AFF)
                .borderRadius(48)
                .justifyContent(FlexAlign.Center)
            }

            Text(this.pageTitle(5))
                .fontSize(28)
                .fontColor(0xFFFFFFFF)
                .fontWeight(FontWeight.Bold)
                .margin(top: 24)
                .textAlign(TextAlign.Center)

            Text(this.pageSubtitle(5))
                .fontSize(15)
                .fontColor(0xCCFFFFFF)
                .textAlign(TextAlign.Center)
                .padding(left: 36, right: 36)
                .margin(top: 10)
                .maxLines(3)
        }
        .width(100.percent)
        .height(100.percent)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.pageBgColor(5))
    }

    // ============================================================
    // Canvas 绘制方法（普通 private func，非 @Builder，可用 let）
    // ============================================================

    /**
     * page0: 纸飞机三角形路径（ArkUI Canvas 2D 几何近似）
     * R-118: fillStyle 用 UInt32 (0xFFRRGGBB)
     */
    private func drawPaperPlane(c: CanvasRenderingContext2D): Unit {
        c.fillStyle = 0xFFFFFFFF
        c.strokeStyle = 0xFFFFFFFF
        c.lineWidth = 2.5

        // 主机身三角形
        c.beginPath()
        c.moveTo(100.0, 20.0)
        c.lineTo(20.0, 90.0)
        c.lineTo(60.0, 80.0)
        c.lineTo(80.0, 140.0)
        c.lineTo(100.0, 20.0)
        c.fill()

        // 折叠线（纸飞机特征）
        c.beginPath()
        c.moveTo(60.0, 80.0)
        c.lineTo(180.0, 50.0)
        c.lineTo(100.0, 20.0)
        c.fill()

        // 翼尖
        c.beginPath()
        c.moveTo(100.0, 20.0)
        c.lineTo(180.0, 50.0)
        c.lineTo(80.0, 140.0)
        c.closePath()
        c.stroke()
    }

    /**
     * page1: 球体 — 同心圆 + 椭圆弧模拟经纬线
     * R-118: fillStyle 用 UInt32
     */
    private func drawSphere(c: CanvasRenderingContext2D): Unit {
        let cx = 90.0
        let cy = 90.0
        let r = 75.0

        // 填充圆（球体主体）
        c.fillStyle = 0x33FFFFFF
        c.beginPath()
        c.arc(cx, cy, r, 0.0, 6.2831)
        c.fill()

        // 轮廓线
        c.strokeStyle = 0xFFFFFFFF
        c.lineWidth = 2.0
        c.beginPath()
        c.arc(cx, cy, r, 0.0, 6.2831)
        c.stroke()

        // 经线（用多段 arc 近似经线路径）
        c.beginPath()
        c.arc(cx, cy, 35.0, 0.0, 6.2831)
        c.stroke()

        // 赤道（较小圆弧近似纬线）
        c.beginPath()
        c.arc(cx, cy - 20.0, 70.0, 0.0, 3.1415)
        c.stroke()

        // 另一条纬线
        c.beginPath()
        c.arc(cx, cy + 20.0, 70.0, 3.1415, 6.2831)
        c.stroke()
    }

    /**
     * page2: ∞ 无限符号 — 贝塞尔曲线
     * R-118: strokeStyle 用 UInt32
     */
    private func drawInfinity(c: CanvasRenderingContext2D): Unit {
        c.strokeStyle = 0xFFFFFFFF
        c.lineWidth = 6.0
        c.lineCap = "round"

        // ∞ 左环（贝塞尔近似）
        c.beginPath()
        c.moveTo(110.0, 55.0)
        c.bezierCurveTo(90.0, 10.0, 20.0, 10.0, 20.0, 55.0)
        c.bezierCurveTo(20.0, 100.0, 90.0, 100.0, 110.0, 55.0)
        c.stroke()

        // ∞ 右环
        c.beginPath()
        c.moveTo(110.0, 55.0)
        c.bezierCurveTo(130.0, 10.0, 200.0, 10.0, 200.0, 55.0)
        c.bezierCurveTo(200.0, 100.0, 130.0, 100.0, 110.0, 55.0)
        c.stroke()
    }

    /**
     * page3: 相机 — fillRect 机身 + arc 镜头
     * R-118: fillStyle 用 UInt32
     */
    private func drawCamera(c: CanvasRenderingContext2D): Unit {
        c.fillStyle = 0xFFFFFFFF
        c.strokeStyle = 0xFFFFFFFF
        c.lineWidth = 2.5

        // 相机机身
        c.fillRect(20.0, 45.0, 160.0, 90.0)

        // 取景窗凸出
        c.fillRect(80.0, 25.0, 50.0, 25.0)

        // 镜头（圆形）— 用黑色填充后白色环
        c.fillStyle = 0xFF317AFF
        c.beginPath()
        c.arc(100.0, 90.0, 30.0, 0.0, 6.2831)
        c.fill()

        c.strokeStyle = 0xFFFFFFFF
        c.lineWidth = 4.0
        c.beginPath()
        c.arc(100.0, 90.0, 30.0, 0.0, 6.2831)
        c.stroke()

        // 内圆（镜片）
        c.beginPath()
        c.arc(100.0, 90.0, 16.0, 0.0, 6.2831)
        c.stroke()

        // 闪光灯
        c.fillStyle = 0xFFFFFFFF
        c.fillRect(148.0, 55.0, 18.0, 12.0)
    }

    /**
     * page4: 铅笔 — moveTo/lineTo 折线形态
     * R-118: strokeStyle 用 UInt32
     */
    private func drawPencil(c: CanvasRenderingContext2D): Unit {
        c.strokeStyle = 0xFFFFFFFF
        c.fillStyle = 0xFFFFFFFF
        c.lineWidth = 4.0
        c.lineJoin = "round"
        c.lineCap = "round"

        // 铅笔主体（斜矩形路径）
        c.beginPath()
        c.moveTo(40.0, 20.0)
        c.lineTo(170.0, 20.0)
        c.lineTo(170.0, 50.0)
        c.lineTo(40.0, 50.0)
        c.closePath()
        c.fill()

        // 铅笔橡皮擦部分
        c.fillStyle = 0xCCFFFFFF
        c.fillRect(150.0, 20.0, 20.0, 30.0)

        // 铅笔尖
        c.fillStyle = 0xFFFFFFFF
        c.beginPath()
        c.moveTo(20.0, 35.0)
        c.lineTo(40.0, 20.0)
        c.lineTo(40.0, 50.0)
        c.closePath()
        c.fill()

        // 书写线条（象征铅笔书写）
        c.strokeStyle = 0xAAFFFFFF
        c.lineWidth = 2.0
        for (yOff in [80, 100, 120, 140]) {
            c.beginPath()
            c.moveTo(40.0, Float64(yOff))
            c.lineTo(160.0, Float64(yOff))
            c.stroke()
        }
    }
}
