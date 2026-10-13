package ohos_app_cangjie_entry.auth

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.viewmodels.*
import ohos_app_cangjie_entry.services.{getGlobalAbilityContext, getAppFilesDir}
import ohos_app_cangjie_entry.components.SolidRoundedButton
import ohos_app_cangjie_entry.utils.readRawFileBytes
import kit.CoreFileKit.*
import ohos.business_exception.BusinessException
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import std.collection.ArrayList
import std.time.*

/**
 * 启动欢迎页面（RMIntro 忠实复现版 —— HI-AUTH-0001）
 *
 * 源参照：input/Telegram-iOS/submodules/RMIntro/Sources/core/animations.c（OpenGL ES2 + GLSL，
 * on_draw_frame() 逐帧驱动各页多元素纹理合成动画）。ArkUI 无法照搬 GL 着色器管线/蒙版混合，
 * 改用等价原语复现：每页拆分为多个独立 PNG 元素分层 Stack，每元素各自挂
 * .translate/.scale/.rotate/.opacity + .animation(AnimateParam) 属性动画，
 * 时序/时长参数取自 animations.c 对应页 on_draw_frame 分支（duration_const=.3s 为基准单位）。
 *
 * 6 页元素清单（对应 animations.c on_surface_created / on_draw_frame）：
 * - page0 Telegram: telegram_sphere（球体，入场缩放+淡入）+ telegram_plane（纸飞机，绕球体轨道飞行）
 * - page1 Fast: fast_body（表体，入场缩放）+ fast_spiral（螺旋速度表环，旋转）+
 *               fast_arrow_shadow + fast_arrow（指针+阴影，一起旋转，指针在阴影之上）
 * - page2 Free: free_knot1~4（4 个丝带结，四角入场缩放 + 轻微摆动，对应 GL 的 knot_delays 交错时序）
 * - page3 Powerful: powerful_infinity_white（∞ 图形，入场 + 脉冲）+ powerful_mask（蓝色底纹，淡入）+
 *                    星点轨道（自绘 4 颗圆点，绕中心公转，近似 star field 效果，PNG 版遮罩混合无法在
 *                    ArkUI 直接等价，用自绘轨道点近似）
 * - page4 Secure: private_door（保险门，缩放入场）+ private_screw ×4（四角螺丝，交错淡入）+
 *                 自绘描边圆环（对应 private_stroke，旋转入场，无对应 PNG）+
 *                 自绘锁孔（对应 private_keyhole_body，无 PNG 资源，用深色圆点+竖条近似）
 * - page5 Cloud: private_door/screw/锁孔淡出 + 云层背景色淡入 + 6 个图标（pin/cam/videocam/smile/
 *                bubble/pencil）交错弹入 + 各自小幅常驻动效（气泡三点脉冲、大头针摆动等）
 *
 * 功能：
 * - 引导轮播（6 页，对齐 iOS：Telegram/Fast/Free/Powerful/Secure/Cloud-Based）
 * - 页面指示点
 * - "Start Messaging" 按钮
 */
@HybridComponentEntry
@Component
public class SplashPage {
    // 混合迁移 auth-flow：
    //  - @Component → @HybridComponentEntry（作为独立 route "SplashPage" 被 AppRoot routerReplace 进入）
    //  - 删 @Prop pageStack: NavPathStack（混合嵌入无栈）；pushPathByName → routerPush
    //  - 删 @Consume tdAuthState/authError（无 @Provide 祖先）；改读 app 级单例 getAuthViewModel()
    //  - aboutToAppear 实逻辑 → ensureLoaded() 守卫，经根 .onAppear 触发
    //  - 去 NavDestination 外壳（.ets shell 承载 NavDestination）

    // 混合迁移：首次渲染守卫
    @State var loaded: Bool = false

    // 轮播当前页
    @State var slideIndex: Int64 = 0

    private let swiperController = SwiperController()

    // ---- rawfile 提取后的沙箱路径（每元素独立 PNG，对应 animations.c on_surface_created 纹理清单）----

    // page0 Telegram
    @State var imgTelegramSphere: String = ""
    @State var imgTelegramPlane: String = ""

    // page1 Fast
    @State var imgFastBody: String = ""
    @State var imgFastSpiral: String = ""
    @State var imgFastArrow: String = ""
    @State var imgFastArrowShadow: String = ""

    // page2 Free
    @State var imgFreeKnotUp: String = ""
    @State var imgFreeKnotDown: String = ""

    // page3 Powerful
    @State var imgPowerfulInfinityWhite: String = ""
    @State var imgPowerfulMask: String = ""

    // page4 Secure
    @State var imgPrivateDoor: String = ""
    @State var imgPrivateScrew: String = ""

    // page5 Cloud（复用 page4 的 door/screw 做淡出；6 个图标）
    @State var imgIcPin: String = ""
    @State var imgIcCam: String = ""
    @State var imgIcCamLens: String = ""
    @State var imgIcVideocam: String = ""
    @State var imgIcSmile: String = ""
    @State var imgIcSmileEye: String = ""
    @State var imgIcBubble: String = ""
    @State var imgIcBubbleDot: String = ""
    @State var imgIcPencil: String = ""

    // ============================================================
    // page0 Telegram 动画状态
    // ============================================================
    // 球体入场：缩放 0.8→1.0 + 透明度 0→1（一次性）
    @State var sphereEntranceScale: Float32 = 0.8
    @State var sphereEntranceOpacity: Float64 = 0.0

    // 纸飞机入场：从左上方飞入（平移 + 轻微旋转 + 淡入），一次性
    @State var planeEntranceX: Float64 = -60.0
    @State var planeEntranceY: Float64 = -40.0
    @State var planeEntranceRotate: Float32 = -25.0
    @State var planeEntranceOpacity: Float64 = 0.0

    // 纸飞机入场完成后常驻绕球体轨道飞行：外层容器旋转带动飞机公转（对齐 GL sin/cos 轨道运动），
    // 内层再叠加自旋，模拟纸飞机机头始终朝向切线方向
    @State var planeOrbitAngle: Float32 = 0.0
    @State var planeSelfSpin: Float32 = 0.0

    // ============================================================
    // page1 Fast 动画状态
    // ============================================================
    // 表体入场：缩放 0.95→1.0 + 淡入（对应 fast_body.params.scale t(.95,1,...)）
    @State var fastBodyEntranceScale: Float32 = 0.95
    @State var fastBodyEntranceOpacity: Float64 = 0.0

    // 螺旋速度表环：持续缓慢旋转（对应 change_segmented_square 旋转动画近似）
    @State var fastSpiralAngle: Float32 = 0.0

    // 指针+阴影一起摆动（对应 fast_arrow.rotation 在 rr..rr-180-160 之间摆动），
    // 常驻缓慢来回摆动近似速度表指针読数变化
    @State var fastArrowAngle: Float32 = -40.0
    @State var fastArrowEntranceOpacity: Float64 = 0.0

    // ============================================================
    // page2 Free 动画状态（4 个绳结，对应 knot_delays 交错入场）
    // ============================================================
    @State var knot1Scale: Float32 = 0.0
    @State var knot2Scale: Float32 = 0.0
    @State var knot3Scale: Float32 = 0.0
    @State var knot4Scale: Float32 = 0.0
    // 入场完成后的常驻轻微摆动（模拟丝带飘动）
    @State var knotSwayAngle: Float32 = -6.0

    // ============================================================
    // page3 Powerful 动画状态
    // ============================================================
    // 脉冲缩放：1.0 → 1.08 → 1.0 循环
    @State var powerfulScale: Float32 = 1.0
    // ∞ 图形入场：缩放 0→1 + 淡入（对应 change_infinity 0→0.99）
    @State var powerfulInfinityScale: Float32 = 0.3
    @State var powerfulInfinityOpacity: Float64 = 0.0
    // 底纹淡入
    @State var powerfulMaskOpacity: Float64 = 0.0
    // 星点轨道角度：绕 ∞ 中心公转 0→360，循环（近似 GL star field）
    @State var starOrbitAngle: Float32 = 0.0

    // ============================================================
    // page4 Secure 动画状态
    // ============================================================
    // 保险门入场：缩放 0.5→1.0 + 淡入（对应 private_door.scale t(.5,1,...)）
    @State var doorEntranceScale: Float32 = 0.5
    @State var doorEntranceOpacity: Float64 = 0.0
    // 4 角螺丝交错淡入（对应 draw_safe 四个 screw_distance 角）
    @State var screw1Opacity: Float64 = 0.0
    @State var screw2Opacity: Float64 = 0.0
    @State var screw3Opacity: Float64 = 0.0
    @State var screw4Opacity: Float64 = 0.0
    // 自绘描边圆环（对应 private_stroke）：旋转 -90→0 入场
    @State var strokeRotate: Float32 = -90.0
    @State var strokeOpacity: Float64 = 0.0
    // 自绘锁孔淡入（无对应 PNG，Shape 近似）
    @State var keyholeOpacity: Float64 = 0.0
    @State var keyholeScale: Float32 = 0.5

    // ============================================================
    // page5 Cloud 动画状态
    // ============================================================
    // door/screw/锁孔/描边圆环淡出（承接 page4 元素反向动画，对应 GL alpha t(1,0,...)）
    @State var cloudDoorFadeOpacity: Float64 = 1.0
    @State var cloudCoverOpacity: Float64 = 0.0
    // 6 个图标交错弹入（对应 draw_ic 逐图标 t_y beginY→0 弹簧衰减曲线，用 EaseOut+delay 近似）
    @State var icPinY: Float64 = 60.0
    @State var icPinOpacity: Float64 = 0.0
    @State var icCamY: Float64 = 60.0
    @State var icCamOpacity: Float64 = 0.0
    @State var icSmileY: Float64 = 60.0
    @State var icSmileOpacity: Float64 = 0.0
    @State var icBubbleY: Float64 = 60.0
    @State var icBubbleOpacity: Float64 = 0.0
    @State var icVideocamY: Float64 = 60.0
    @State var icVideocamOpacity: Float64 = 0.0
    @State var icVideocamAngle: Float32 = -30.0
    @State var icPencilY: Float64 = 60.0
    @State var icPencilOpacity: Float64 = 0.0
    // 常驻小动效：气泡三点脉冲缩放、大头针轻微摆动、铅笔书写摆动
    @State var icBubbleDotScale: Float32 = 0.7
    @State var icPinSway: Float32 = -4.0
    @State var icSmileEyeScale: Float32 = 1.0
    @State var icPencilSway: Float32 = 0.0

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.extractIntroImages()
        this.startPageAnimations()
    }

    /**
     * 触发全部 6 页动画：一次性入场 + 常驻循环。
     * 状态变化后 .animation() 修饰符检测差异并按各自 AnimateParam 时长/曲线插值。
     */
    private func startPageAnimations(): Unit {
        // page0 Telegram：球体缩放淡入 + 飞机飞入
        this.sphereEntranceScale = 1.0
        this.sphereEntranceOpacity = 1.0
        this.planeEntranceX = 0.0
        this.planeEntranceY = 0.0
        this.planeEntranceRotate = 0.0
        this.planeEntranceOpacity = 1.0

        // page1 Fast：表体缩放淡入 + 指针淡入
        this.fastBodyEntranceScale = 1.0
        this.fastBodyEntranceOpacity = 1.0
        this.fastArrowEntranceOpacity = 1.0

        // page2 Free：4 个绳结交错缩放入场
        this.knot1Scale = 1.0
        this.knot2Scale = 1.0
        this.knot3Scale = 1.0
        this.knot4Scale = 1.0

        // page3 Powerful：∞ 图形 + 底纹淡入 + 脉冲 + 星点轨道
        this.powerfulScale = 1.08
        this.starOrbitAngle = 360.0
        this.powerfulInfinityScale = 1.0
        this.powerfulInfinityOpacity = 1.0
        this.powerfulMaskOpacity = 0.55

        // page4 Secure：保险门 + 4 螺丝 + 描边圆环 + 锁孔 入场
        this.doorEntranceScale = 1.0
        this.doorEntranceOpacity = 1.0
        this.screw1Opacity = 1.0
        this.screw2Opacity = 1.0
        this.screw3Opacity = 1.0
        this.screw4Opacity = 1.0
        this.strokeRotate = 0.0
        this.strokeOpacity = 1.0
        this.keyholeOpacity = 1.0
        this.keyholeScale = 1.0

        // page5 Cloud：door/锁孔淡出 + 云层淡入 + 6 图标弹入
        this.cloudDoorFadeOpacity = 0.0
        this.cloudCoverOpacity = 1.0
        this.icPinY = 0.0
        this.icPinOpacity = 1.0
        this.icCamY = 0.0
        this.icCamOpacity = 1.0
        this.icSmileY = 0.0
        this.icSmileOpacity = 1.0
        this.icBubbleY = 0.0
        this.icBubbleOpacity = 1.0
        this.icVideocamY = 0.0
        this.icVideocamOpacity = 1.0
        this.icVideocamAngle = 0.0
        this.icPencilY = 0.0
        this.icPencilOpacity = 1.0

        // 入场结束后启动各页常驻循环动效（略晚于入场动画时长，与 duration_const≈0.3s 基准对齐）
        let _ = spawn {
            sleep(Duration.millisecond * 900)
            launch {
                // page0：飞机绕球体常驻公转
                this.planeOrbitAngle = 360.0
                this.planeSelfSpin = -360.0
                // page1：螺旋环持续旋转 + 指针来回摆动
                this.fastSpiralAngle = 360.0
                this.fastArrowAngle = 40.0
                // page2：绳结常驻轻微摆动
                this.knotSwayAngle = 6.0
                // page4：锁孔呼吸缩放
                this.keyholeScale = 1.1
                // page5：气泡三点脉冲 + 大头针摆动 + 微笑眨眼 + 铅笔书写摆动
                this.icBubbleDotScale = 1.0
                this.icPinSway = 4.0
                this.icSmileEyeScale = 0.15
                this.icPencilSway = -5.0
            }
        }
    }

    /**
     * 将 rawfile/intro_*.png 提取到 filesDir/intro/ 目录。
     *
     * 使用 ResourceManager.getRawFileContent() 运行时读取——避免在 @Component build() 中
     * 使用 @rawfile() 宏（该宏生成 __GenerateResource__ native 符号调用，在 CJ so 加载时
     * 无法解析，导致 SIGSEGV）。
     */
    private func extractIntroImages(): Unit {
        match (getGlobalAbilityContext()) {
            case None => return
            case Some(ctx) =>
                let filesDir = ctx.filesDir
                let introDir = filesDir + "/intro"
                try { FileIo.mkdir(introDir) } catch (_e: Exception) {}

                // page0 Telegram
                match (this.extractOne(introDir, "intro_telegram_sphere.png")) {
                    case Some(p) => this.imgTelegramSphere = p
                    case None => ()
                }
                match (this.extractOne(introDir, "intro_telegram_plane.png")) {
                    case Some(p) => this.imgTelegramPlane = p
                    case None => ()
                }

                // page1 Fast
                match (this.extractOne(introDir, "intro_fast_body.png")) {
                    case Some(p) => this.imgFastBody = p
                    case None => ()
                }
                match (this.extractOne(introDir, "intro_fast_spiral.png")) {
                    case Some(p) => this.imgFastSpiral = p
                    case None => ()
                }
                match (this.extractOne(introDir, "intro_fast_arrow.png")) {
                    case Some(p) => this.imgFastArrow = p
                    case None => ()
                }
                match (this.extractOne(introDir, "intro_fast_arrow_shadow.png")) {
                    case Some(p) => this.imgFastArrowShadow = p
                    case None => ()
                }

                // page2 Free
                match (this.extractOne(introDir, "intro_free_knot_up.png")) {
                    case Some(p) => this.imgFreeKnotUp = p
                    case None => ()
                }
                match (this.extractOne(introDir, "intro_free_knot_down.png")) {
                    case Some(p) => this.imgFreeKnotDown = p
                    case None => ()
                }

                // page3 Powerful
                match (this.extractOne(introDir, "intro_powerful_infinity_white.png")) {
                    case Some(p) => this.imgPowerfulInfinityWhite = p
                    case None => ()
                }
                match (this.extractOne(introDir, "intro_powerful_mask.png")) {
                    case Some(p) => this.imgPowerfulMask = p
                    case None => ()
                }

                // page4 Secure（door/screw 也被 page5 复用做淡出）
                match (this.extractOne(introDir, "intro_private_door.png")) {
                    case Some(p) => this.imgPrivateDoor = p
                    case None => ()
                }
                match (this.extractOne(introDir, "intro_private_screw.png")) {
                    case Some(p) => this.imgPrivateScrew = p
                    case None => ()
                }

                // page5 Cloud 图标（对应 draw_ic type=1 分支 6 个元素）
                match (this.extractOne(introDir, "intro_ic_pin.png")) {
                    case Some(p) => this.imgIcPin = p
                    case None => ()
                }
                match (this.extractOne(introDir, "intro_ic_cam.png")) {
                    case Some(p) => this.imgIcCam = p
                    case None => ()
                }
                match (this.extractOne(introDir, "intro_ic_cam_lens.png")) {
                    case Some(p) => this.imgIcCamLens = p
                    case None => ()
                }
                match (this.extractOne(introDir, "intro_ic_videocam.png")) {
                    case Some(p) => this.imgIcVideocam = p
                    case None => ()
                }
                match (this.extractOne(introDir, "intro_ic_smile.png")) {
                    case Some(p) => this.imgIcSmile = p
                    case None => ()
                }
                match (this.extractOne(introDir, "intro_ic_smile_eye.png")) {
                    case Some(p) => this.imgIcSmileEye = p
                    case None => ()
                }
                match (this.extractOne(introDir, "intro_ic_bubble.png")) {
                    case Some(p) => this.imgIcBubble = p
                    case None => ()
                }
                match (this.extractOne(introDir, "intro_ic_bubble_dot.png")) {
                    case Some(p) => this.imgIcBubbleDot = p
                    case None => ()
                }
                match (this.extractOne(introDir, "intro_ic_pencil.png")) {
                    case Some(p) => this.imgIcPencil = p
                    case None => ()
                }
        }
    }

    /**
     * 提取单个 rawfile/<name> 到 <introDir>/<name>，返回 "file://<path>"（成功）或 None（失败）。
     */
    private func extractOne(introDir: String, name: String): Option<String> {
        let targetPath = introDir + "/" + name

        // Always extract from rawfile and overwrite the sandbox copy so that
        // upgraded HAP assets replace any stale cached file from a prior install.
        match (readRawFileBytes(name)) {
            case None =>
                Hilog.info(0, "CjTelegram",
                    "[SplashPage] extractOne: readRawFileBytes returned None for ${name}")
                return None
            case Some(data) =>
                if (data.size > 0) {
                    try {
                        let file = FileIo.open(targetPath, mode: 0o1101)
                        let _ = FileIo.write(file.fd, data)
                        FileIo.close(file)
                        return Some("file://" + targetPath)
                    } catch (_e: Exception) {
                        Hilog.info(0, "CjTelegram",
                            "[SplashPage] extractOne: write failed for ${name}")
                        return None
                    }
                }
                return None
        }
    }

    // SolidRoundedButton onClick 回调（显式 Unit 返回类型，避免宏推断问题）
    //
    // QA-3 fix (Part 1): 原先用 routerPush 把 PhoneInputPage 压在 Splash 之上，导致 Navigation
    // 出现"返回"箭头，点击会弹回 Splash（iOS 用 setViewControllers 整体替换，且
    // AuthorizationSequencePhoneEntryController 单账号场景下 attemptNavigation 恒为 false，
    // 没有返回按钮）。改用 routerReplace 使 Splash 离开栈，不再有"返回到 Splash"的路径。
    //
    // QA-3 fix (Part 2): 在离开 Splash 前持久化 onboardingStarted=true，供 AppRoot 下次启动时
    // 判断"用户已经进入登录流程但尚未登录完成"，从而恢复到 PhoneInputPage 而不是重新展示 intro。
    private func onStartMessagingClick(): Unit {
        getAuthStorage().setOnboardingStarted(true)
        routerReplace("PhoneInputPage", "")
    }

    private func getSlideTitle(idx: Int64): String {
        match (idx) {
            case 0 => "Telegram"
            case 1 => "Fast"
            case 2 => "Free"
            case 3 => "Powerful"
            case 4 => "Secure"
            case 5 => "Cloud-Based"
            case _ => "Telegram"
        }
    }

    // 对齐 iOS Localizable.strings Tour.Text1~6（**word** 标记加粗关键词，
    // 对应 RMIntroPageView.m 用 "**" 定界符解析出 boldRanges 后应用 boldSystemFont 的逻辑）。
    private func getSlideSubtitle(idx: Int64): String {
        match (idx) {
            case 0 => "The world's **fastest** messaging app. It is **free** and **secure**."
            case 1 => "**Telegram** delivers messages faster than any other application."
            case 2 => "**Telegram** provides free unlimited cloud storage for chats and media."
            case 3 => "**Telegram** has no limits on the size of your media and chats."
            case 4 => "**Telegram** keeps your messages safe from hacker attacks."
            case 5 => "**Telegram** lets you access your messages from multiple devices."
            case _ => ""
        }
    }

    // 把形如 "The world's **fastest** messaging app." 的字符串拆成 (text, isBold) 分段，
    // 用 "**" 作为定界符——直接对应 iOS RMIntroPageView.m 的 boldRanges 解析算法。
    private func splitBoldSegments(raw: String): ArrayList<(String, Bool)> {
        let segments = ArrayList<(String, Bool)>()
        var remaining = raw
        var bold = false
        while (remaining.size > 0) {
            let markerIdx = remaining.indexOf("**")
            match (markerIdx) {
                case None =>
                    segments.add((remaining, bold))
                    remaining = ""
                case Some(idx) =>
                    if (idx > 0) {
                        segments.add((remaining[0..idx], bold))
                    }
                    remaining = remaining[(idx + 2)..remaining.size]
                    bold = !bold
            }
        }
        return segments
    }

    private func isDotSelected(dotIdx: Int64): Bool {
        this.slideIndex == dotIdx
    }

    // 用 Text{Span...} 渲染带加粗关键词的 subtitle，对齐 iOS Tour.Text1~6 的 **word** 标记
    @Builder
    func slideSubtitleText(idx: Int64) {
        Text() {
            ForEach(this.splitBoldSegments(this.getSlideSubtitle(idx)), itemGenerator: { seg: (String, Bool), _i: Int64 =>
                Span(seg[0])
                    .fontSize(14)
                    .fontColor(0x666666)
                    .fontWeight(if (seg[1]) { FontWeight.Bold } else { FontWeight.Regular })
            })
        }
        .textAlign(TextAlign.Center)
        .width(100.percent)
        .padding(left: 32, right: 32)
    }

    // ================================================================
    // page0 Telegram：球体 + 纸飞机绕轨道飞行
    // ================================================================
    @Builder
    func pageTelegram() {
        Stack {
            if (this.imgTelegramSphere.size > 0) {
                Column {
                    Image(this.imgTelegramSphere)
                        .width(148)
                        .height(148)
                        .objectFit(ImageFit.Contain)
                }
                .scale(x: this.sphereEntranceScale, y: this.sphereEntranceScale)
                .opacity(this.sphereEntranceOpacity)
                .animation(AnimateParam(duration: 700, curve: Curve.EaseOut))
            }
            if (this.imgTelegramPlane.size > 0) {
                // 外层容器负责一次性飞入（平移+旋转+淡入）
                Column {
                    // 中层容器：绕 Stack 中心公转（旋转带动子节点沿圆周运动，
                    // 与 page3 星点轨道同一原语），半径通过 padding(top:) 控制
                    Column {
                        Column {
                            Image(this.imgTelegramPlane)
                                .width(82)
                                .height(74)
                                .objectFit(ImageFit.Contain)
                        }
                        .rotate(angle: this.planeSelfSpin)
                        .animation(AnimateParam(
                            duration: 2200,
                            curve: Curve.Linear,
                            iterations: -1,
                            playMode: PlayMode.Normal
                        ))
                    }
                    .width(150)
                    .height(150)
                    .alignItems(HorizontalAlign.Center)
                    .padding(top: 4)
                    .rotate(angle: this.planeOrbitAngle)
                    .animation(AnimateParam(
                        duration: 2200,
                        curve: Curve.Linear,
                        iterations: -1,
                        playMode: PlayMode.Normal
                    ))
                }
                .translate(x: this.planeEntranceX, y: this.planeEntranceY)
                .rotate(angle: this.planeEntranceRotate)
                .opacity(this.planeEntranceOpacity)
                .animation(AnimateParam(duration: 650, curve: Curve.EaseOut))
            }
        }
        .width(150)
        .height(150)
        .margin(bottom: 16)
    }

    // ================================================================
    // page1 Fast 螺旋刻度盘：自绘 12 个深色短刻度沿圆周排布，整体随 fastSpiralAngle 旋转，
    // 替代 fast_spiral.png（红底+白色 Pac-Man 镂空，整图裁圆后仍是红色月牙伪影，见 pageFast 注释）。
    // 复用 pagePowerful 星点公转同款技巧：每个刻度用独立 180x180 容器 + padding(top) 把刻度
    // 顶到圆周上，再对容器整体 .rotate(固定角度偏移) 摆到 12 个方位，最外层统一叠加旋转动画。
    // 刻度色取 fast_body.png 表体深蓝描边色 (33,52,72)，因表体内圆是近白色，白色刻度会看不见。
    // ================================================================
    @Builder
    func buildFastSpiralTicks() {
        Stack {
            ForEach(Array<Int64>(12, { i: Int64 => i }), itemGenerator: { tickIdx: Int64, _i: Int64 =>
                Column {
                    Column {}
                        .width(3)
                        .height(14)
                        .borderRadius(1.5)
                        .backgroundColor(0x213448)
                }
                .width(102)
                .height(102)
                .alignItems(HorizontalAlign.Center)
                .padding(top: 4)
                .rotate(angle: Float32(tickIdx) * 30.0)
            })
        }
        .width(102)
        .height(102)
        .opacity(this.fastArrowEntranceOpacity)
        .rotate(angle: this.fastSpiralAngle)
        .animation(AnimateParam(
            duration: 4200,
            curve: Curve.Linear,
            iterations: -1,
            playMode: PlayMode.Normal
        ))
    }

    // ================================================================
    // page1 Fast：表体 + 螺旋速度表环 + 指针/阴影一起旋转
    // ================================================================
    @Builder
    func pageFast() {
        Stack {
            if (this.imgFastBody.size > 0) {
                Column {
                    Image(this.imgFastBody)
                        .width(148)
                        .height(148)
                        .objectFit(ImageFit.Contain)
                }
                .scale(x: this.fastBodyEntranceScale, y: this.fastBodyEntranceScale)
                .opacity(this.fastBodyEntranceOpacity)
                .animation(AnimateParam(duration: 600, curve: Curve.EaseInOut))
            }
            // fast_spiral 源图（RMIntro fast_spiral@2x.png）是配合 GL create_segmented_square()
            // 逐段裁出螺旋刻度的方形纹理（红底 + 白色 Pac-Man 镂空），iOS 端从不整张贴图显示，
            // 而是被切成多段窄弧带按帧动态旋转拼接成"螺旋刻度盘"视觉。ArkUI 无该逐段裁切几何：
            // 直接整图 clip 圆形试验后发现只剩一个红色月牙块（仍是伪影，且红色与深色表体/白色
            // 内圆撞色），故弃用 PNG，改自绘 12 个白色刻度短线沿圆周排布（buildFastSpiralTicks()），
            // 整体随 fastSpiralAngle 旋转，视觉近似"螺旋速度表刻度盘持续转动"，且不再引入方角/月牙伪影。
            this.buildFastSpiralTicks()
            // 指针阴影（略微偏移，位于指针之下）
            if (this.imgFastArrowShadow.size > 0) {
                Column {
                    Column {
                        Image(this.imgFastArrowShadow)
                            .width(82)
                            .height(22)
                            .objectFit(ImageFit.Contain)
                    }
                    .rotate(angle: this.fastArrowAngle)
                    .animation(AnimateParam(
                        duration: 1500,
                        curve: Curve.EaseInOut,
                        iterations: -1,
                        playMode: PlayMode.Alternate
                    ))
                }
                .translate(x: 1.0, y: 2.0)
                .opacity(this.fastArrowEntranceOpacity)
                .animation(AnimateParam(duration: 600, curve: Curve.EaseInOut))
            }
            // 指针（在阴影之上）
            if (this.imgFastArrow.size > 0) {
                Column {
                    Column {
                        Image(this.imgFastArrow)
                            .width(82)
                            .height(22)
                            .objectFit(ImageFit.Contain)
                    }
                    .rotate(angle: this.fastArrowAngle)
                    .animation(AnimateParam(
                        duration: 1500,
                        curve: Curve.EaseInOut,
                        iterations: -1,
                        playMode: PlayMode.Alternate
                    ))
                }
                .opacity(this.fastArrowEntranceOpacity)
                .animation(AnimateParam(duration: 600, curve: Curve.EaseInOut))
            }
        }
        .width(180)
        .height(180)
        .margin(bottom: 16)
    }

    // ================================================================
    // page2 Free：红色底色（对应 free_bg，绳结 PNG 为白色，需红底才可见）+
    // 4 个绳结四角交错入场 + 常驻轻微摆动（对应 knot_delays 交错时序）
    // ================================================================
    @Builder
    func pageFree() {
        Stack {
            // free_bg 红色底色（对应 on_surface_created free_bg_color = {246,73,55}）
            Column {}
                .width(180)
                .height(180)
                .borderRadius(90)
                .backgroundColor(0xF64937)
                .opacity(Float64(this.knot1Scale))
                .animation(AnimateParam(duration: 500, curve: Curve.EaseOut))

            if (this.imgFreeKnotUp.size > 0) {
                // 左上结
                Column {
                    Column {
                        Image(this.imgFreeKnotUp)
                            .width(46)
                            .height(46)
                            .objectFit(ImageFit.Contain)
                    }
                    .rotate(angle: this.knotSwayAngle)
                    .animation(AnimateParam(
                        duration: 1600,
                        curve: Curve.EaseInOut,
                        delay: 900,
                        iterations: -1,
                        playMode: PlayMode.Alternate
                    ))
                }
                .position(x: 24, y: 24)
                .scale(x: this.knot1Scale, y: this.knot1Scale)
                .animation(AnimateParam(duration: 450, curve: Curve.EaseOut, delay: 195))

                // 右上结（镜像位置，共用贴图）
                Column {
                    Column {
                        Image(this.imgFreeKnotUp)
                            .width(46)
                            .height(46)
                            .objectFit(ImageFit.Contain)
                    }
                    .rotate(angle: -this.knotSwayAngle)
                    .animation(AnimateParam(
                        duration: 1700,
                        curve: Curve.EaseInOut,
                        delay: 1050,
                        iterations: -1,
                        playMode: PlayMode.Alternate
                    ))
                }
                .position(x: 110, y: 24)
                .scale(x: this.knot2Scale, y: this.knot2Scale)
                .animation(AnimateParam(duration: 450, curve: Curve.EaseOut, delay: 240))
            }
            if (this.imgFreeKnotDown.size > 0) {
                // 左下结
                Column {
                    Column {
                        Image(this.imgFreeKnotDown)
                            .width(50)
                            .height(50)
                            .objectFit(ImageFit.Contain)
                    }
                    .rotate(angle: this.knotSwayAngle)
                    .animation(AnimateParam(
                        duration: 1500,
                        curve: Curve.EaseInOut,
                        delay: 1150,
                        iterations: -1,
                        playMode: PlayMode.Alternate
                    ))
                }
                .position(x: 22, y: 108)
                .scale(x: this.knot3Scale, y: this.knot3Scale)
                .animation(AnimateParam(duration: 450, curve: Curve.EaseOut, delay: 285))

                // 右下结
                Column {
                    Column {
                        Image(this.imgFreeKnotDown)
                            .width(50)
                            .height(50)
                            .objectFit(ImageFit.Contain)
                    }
                    .rotate(angle: -this.knotSwayAngle)
                    .animation(AnimateParam(
                        duration: 1800,
                        curve: Curve.EaseInOut,
                        delay: 780,
                        iterations: -1,
                        playMode: PlayMode.Alternate
                    ))
                }
                .position(x: 108, y: 108)
                .scale(x: this.knot4Scale, y: this.knot4Scale)
                .animation(AnimateParam(duration: 450, curve: Curve.EaseOut, delay: 105))
            }
        }
        .width(180)
        .height(180)
        .margin(bottom: 16)
    }

    // ================================================================
    // page3 Powerful：∞ 图形（PNG）+ 蓝色底纹遮罩 + 自绘星点轨道公转
    // GL 原版用蒙版混合（rglMaskDraw + powerful_mask 纹理）合成 ∞ 挖空效果——
    // ArkUI 无逐像素蒙版混合，改用「底纹淡入 + ∞ 白色图形叠加」近似，非逐像素等价（见交付说明）。
    // ================================================================
    @Builder
    func pagePowerful() {
        Stack {
            // 星点轨道层：dot1~dot4（正上方起始，不同周期错开，近似 star field 公转）
            Column {
                Column {}
                    .width(6)
                    .height(6)
                    .borderRadius(3)
                    .backgroundColor(0x317AFF)
            }
            .width(180)
            .height(180)
            .alignItems(HorizontalAlign.Center)
            .padding(top: 8)
            .rotate(angle: this.starOrbitAngle)
            .animation(AnimateParam(
                duration: 3200,
                curve: Curve.Linear,
                iterations: -1,
                playMode: PlayMode.Normal
            ))

            Column {
                Column {}
                    .width(5)
                    .height(5)
                    .borderRadius(3)
                    .backgroundColor(0x5EABFF)
            }
            .width(180)
            .height(180)
            .alignItems(HorizontalAlign.Center)
            .padding(top: 8)
            .rotate(angle: this.starOrbitAngle)
            .animation(AnimateParam(
                duration: 2800,
                curve: Curve.Linear,
                delay: 700,
                iterations: -1,
                playMode: PlayMode.Normal
            ))

            Column {
                Column {}
                    .width(4)
                    .height(4)
                    .borderRadius(2)
                    .backgroundColor(0x317AFF)
            }
            .width(180)
            .height(180)
            .alignItems(HorizontalAlign.Center)
            .padding(top: 8)
            .rotate(angle: this.starOrbitAngle)
            .animation(AnimateParam(
                duration: 3600,
                curve: Curve.Linear,
                delay: 1400,
                iterations: -1,
                playMode: PlayMode.Normal
            ))

            Column {
                Column {}
                    .width(5)
                    .height(5)
                    .borderRadius(3)
                    .backgroundColor(0x5EABFF)
            }
            .width(180)
            .height(180)
            .alignItems(HorizontalAlign.Center)
            .padding(top: 8)
            .rotate(angle: this.starOrbitAngle)
            .animation(AnimateParam(
                duration: 3000,
                curve: Curve.Linear,
                delay: 2100,
                iterations: -1,
                playMode: PlayMode.Normal
            ))

            // 蓝色底座（对应 powerful_bg_color = {47,90,131}，实心蓝底，
            // powerful_mask.png 本身是白色蒙版图形，需不透明深色底才可见，
            // 直接铺一层不透明蓝底座保证核心层可见——PNG 遮罩混合仅做叠加纹理近似）
            Column {}
                .width(150)
                .height(90)
                .borderRadius(45)
                .backgroundColor(0x2F5A83)
                .opacity(this.powerfulMaskOpacity)
                .animation(AnimateParam(duration: 800, curve: Curve.EaseOut))

            if (this.imgPowerfulMask.size > 0) {
                Column {
                    Image(this.imgPowerfulMask)
                        .width(150)
                        .height(150)
                        .objectFit(ImageFit.Cover)
                        .borderRadius(45)
                        .opacity(0.18)
                }
                .width(150)
                .height(90)
                .borderRadius(45)
                .opacity(this.powerfulMaskOpacity)
                .animation(AnimateParam(duration: 800, curve: Curve.EaseOut))
            }

            // 核心层：∞ 白色图形（PNG，白色图形叠在不透明蓝底座上），带入场缩放 + 常驻脉冲
            if (this.imgPowerfulInfinityWhite.size > 0) {
                Column {
                    Image(this.imgPowerfulInfinityWhite)
                        .width(122)
                        .height(60)
                        .objectFit(ImageFit.Contain)
                }
                .scale(x: this.powerfulInfinityScale, y: this.powerfulInfinityScale)
                .opacity(this.powerfulInfinityOpacity)
                .animation(AnimateParam(duration: 750, curve: Curve.EaseOut))
            } else {
                Column {
                    Text("\u{221E}")
                        .fontSize(72)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xFFFFFF)
                }
                .scale(x: this.powerfulInfinityScale, y: this.powerfulInfinityScale)
                .opacity(this.powerfulInfinityOpacity)
                .animation(AnimateParam(duration: 750, curve: Curve.EaseOut))
            }

            // 脉冲缩放层（叠加在核心层之上，制造呼吸感，独立 .animation 节点）
            Column {}
                .width(150)
                .height(90)
                .scale(x: this.powerfulScale, y: this.powerfulScale)
                .animation(AnimateParam(
                    duration: 1200,
                    curve: Curve.EaseInOut,
                    iterations: -1,
                    playMode: PlayMode.Alternate
                ))
        }
        .width(180)
        .height(180)
        .margin(bottom: 16)
    }

    // ================================================================
    // page4 Secure：保险门缩放入场 + 4 角螺丝交错淡入 + 自绘描边圆环 + 自绘锁孔
    // 锁孔（private_keyhole_body）在源资源目录中无对应 PNG（已用 find 遍历确认缺失），
    // 用深色圆孔 + 竖条自绘近似，非像素级等价（见交付说明）。
    // ================================================================
    @Builder
    func pageSecure() {
        Stack {
            // 保险门主体
            if (this.imgPrivateDoor.size > 0) {
                Column {
                    Image(this.imgPrivateDoor)
                        .width(136)
                        .height(136)
                        .objectFit(ImageFit.Contain)
                }
                .scale(x: this.doorEntranceScale, y: this.doorEntranceScale)
                .opacity(this.doorEntranceOpacity)
                .animation(AnimateParam(duration: 700, curve: Curve.EaseOut))
            }

            // 自绘描边圆环（对应 private_stroke，旋转入场）
            Column {}
                .width(150)
                .height(150)
                .borderRadius(75)
                .borderWidth(3)
                .borderColor(0xFFFFFF)
                .rotate(angle: this.strokeRotate)
                .opacity(this.strokeOpacity)
                .animation(AnimateParam(duration: 700, curve: Curve.EaseOut))

            // 自绘锁孔（无 PNG，深色圆孔 + 竖条近似 private_keyhole_body 外观）
            Column {
                Column {}
                    .width(14)
                    .height(14)
                    .borderRadius(7)
                    .backgroundColor(0x2F5A83)
                Column {}
                    .width(6)
                    .height(12)
                    .backgroundColor(0x2F5A83)
                    .margin(top: -2)
            }
            .alignItems(HorizontalAlign.Center)
            .scale(x: this.keyholeScale, y: this.keyholeScale)
            .opacity(this.keyholeOpacity)
            .animation(AnimateParam(
                duration: 1400,
                curve: Curve.EaseInOut,
                delay: 700,
                iterations: -1,
                playMode: PlayMode.Alternate
            ))

            // 4 角螺丝
            if (this.imgPrivateScrew.size > 0) {
                Column {
                    Image(this.imgPrivateScrew)
                        .width(10)
                        .height(10)
                        .objectFit(ImageFit.Contain)
                }
                .position(x: 30, y: 30)
                .opacity(this.screw1Opacity)
                .animation(AnimateParam(duration: 400, curve: Curve.Linear, delay: 100))

                Column {
                    Image(this.imgPrivateScrew)
                        .width(10)
                        .height(10)
                        .objectFit(ImageFit.Contain)
                }
                .position(x: 140, y: 30)
                .opacity(this.screw2Opacity)
                .animation(AnimateParam(duration: 400, curve: Curve.Linear, delay: 175))

                Column {
                    Image(this.imgPrivateScrew)
                        .width(10)
                        .height(10)
                        .objectFit(ImageFit.Contain)
                }
                .position(x: 30, y: 140)
                .opacity(this.screw3Opacity)
                .animation(AnimateParam(duration: 400, curve: Curve.Linear, delay: 250))

                Column {
                    Image(this.imgPrivateScrew)
                        .width(10)
                        .height(10)
                        .objectFit(ImageFit.Contain)
                }
                .position(x: 140, y: 140)
                .opacity(this.screw4Opacity)
                .animation(AnimateParam(duration: 400, curve: Curve.Linear, delay: 325))
            }
        }
        .width(180)
        .height(180)
        .margin(bottom: 16)
    }

    // ================================================================
    // page5 Cloud：保险门/螺丝/锁孔淡出 + 云层色块淡入 + 6 个图标交错弹入 + 常驻小动效
    // ================================================================
    @Builder
    func pageCloud() {
        Stack {
            // 云层背景色块淡入（对应 cloud_bg 纯色矩形，无 PNG，直接用色块）
            Column {}
                .width(180)
                .height(180)
                .borderRadius(24)
                .backgroundColor(0x2AB4F7)
                .opacity(this.cloudCoverOpacity)
                .animation(AnimateParam(duration: 700, curve: Curve.EaseOut))

            // 保险门淡出残影（承接 page4，制造场景过渡感）
            if (this.imgPrivateDoor.size > 0) {
                Column {
                    Image(this.imgPrivateDoor)
                        .width(120)
                        .height(120)
                        .objectFit(ImageFit.Contain)
                }
                .opacity(this.cloudDoorFadeOpacity)
                .animation(AnimateParam(duration: 500, curve: Curve.EaseIn))
            }

            // 大头针（pin）：左上，带弹入 + 常驻摆动
            if (this.imgIcPin.size > 0) {
                Column {
                    Column {
                        Image(this.imgIcPin)
                            .width(30)
                            .height(40)
                            .objectFit(ImageFit.Contain)
                    }
                    .rotate(angle: this.icPinSway)
                    .animation(AnimateParam(
                        duration: 1600,
                        curve: Curve.EaseInOut,
                        delay: 900,
                        iterations: -1,
                        playMode: PlayMode.Alternate
                    ))
                }
                .position(x: 22, y: 30)
                .translate(y: this.icPinY)
                .opacity(this.icPinOpacity)
                .animation(AnimateParam(duration: 500, curve: Curve.EaseOut, delay: 50))
            }

            // 相机（cam + 镜头）：右上
            if (this.imgIcCam.size > 0) {
                Column {
                    Image(this.imgIcCam)
                        .width(36)
                        .height(32)
                        .objectFit(ImageFit.Contain)
                    if (this.imgIcCamLens.size > 0) {
                        Image(this.imgIcCamLens)
                            .width(12)
                            .height(12)
                            .objectFit(ImageFit.Contain)
                            .margin(top: -22)
                    }
                }
                .position(x: 122, y: 26)
                .translate(y: this.icCamY)
                .opacity(this.icCamOpacity)
                .animation(AnimateParam(duration: 500, curve: Curve.EaseOut, delay: 150))
            }

            // 摄像机（videocam）：左下，带轻微旋转
            if (this.imgIcVideocam.size > 0) {
                Column {
                    Image(this.imgIcVideocam)
                        .width(48)
                        .height(28)
                        .objectFit(ImageFit.Contain)
                }
                .position(x: 16, y: 118)
                .translate(y: this.icVideocamY)
                .rotate(angle: this.icVideocamAngle)
                .opacity(this.icVideocamOpacity)
                .animation(AnimateParam(duration: 500, curve: Curve.EaseOut, delay: 250))
            }

            // 微笑（smile + 眨眼双眼）：中间偏右
            if (this.imgIcSmile.size > 0) {
                Column {
                    Image(this.imgIcSmile)
                        .width(40)
                        .height(40)
                        .objectFit(ImageFit.Contain)
                    if (this.imgIcSmileEye.size > 0) {
                        Row {
                            Image(this.imgIcSmileEye)
                                .width(4)
                                .height(4)
                                .objectFit(ImageFit.Contain)
                                .scale(x: 1.0, y: this.icSmileEyeScale)
                                .animation(AnimateParam(
                                    duration: 3200,
                                    curve: Curve.EaseInOut,
                                    delay: 2000,
                                    iterations: -1,
                                    playMode: PlayMode.Alternate
                                ))
                            Image(this.imgIcSmileEye)
                                .width(4)
                                .height(4)
                                .objectFit(ImageFit.Contain)
                                .margin(left: 12)
                                .scale(x: 1.0, y: this.icSmileEyeScale)
                                .animation(AnimateParam(
                                    duration: 3200,
                                    curve: Curve.EaseInOut,
                                    delay: 2000,
                                    iterations: -1,
                                    playMode: PlayMode.Alternate
                                ))
                        }
                        .margin(top: -26)
                    }
                }
                .position(x: 118, y: 108)
                .translate(y: this.icSmileY)
                .opacity(this.icSmileOpacity)
                .animation(AnimateParam(duration: 500, curve: Curve.EaseOut, delay: 350))
            }

            // 气泡（bubble + 三点脉冲）：底部居中
            if (this.imgIcBubble.size > 0) {
                Column {
                    Image(this.imgIcBubble)
                        .width(34)
                        .height(34)
                        .objectFit(ImageFit.Contain)
                    if (this.imgIcBubbleDot.size > 0) {
                        Row {
                            Image(this.imgIcBubbleDot)
                                .width(4)
                                .height(4)
                                .objectFit(ImageFit.Contain)
                                .scale(x: this.icBubbleDotScale, y: this.icBubbleDotScale)
                                .animation(AnimateParam(
                                    duration: 500,
                                    curve: Curve.EaseInOut,
                                    iterations: -1,
                                    playMode: PlayMode.Alternate
                                ))
                            Image(this.imgIcBubbleDot)
                                .width(4)
                                .height(4)
                                .objectFit(ImageFit.Contain)
                                .margin(left: 4)
                                .scale(x: this.icBubbleDotScale, y: this.icBubbleDotScale)
                                .animation(AnimateParam(
                                    duration: 500,
                                    curve: Curve.EaseInOut,
                                    delay: 120,
                                    iterations: -1,
                                    playMode: PlayMode.Alternate
                                ))
                            Image(this.imgIcBubbleDot)
                                .width(4)
                                .height(4)
                                .objectFit(ImageFit.Contain)
                                .margin(left: 4)
                                .scale(x: this.icBubbleDotScale, y: this.icBubbleDotScale)
                                .animation(AnimateParam(
                                    duration: 500,
                                    curve: Curve.EaseInOut,
                                    delay: 240,
                                    iterations: -1,
                                    playMode: PlayMode.Alternate
                                ))
                        }
                        .margin(top: -16)
                    }
                }
                .position(x: 70, y: 130)
                .translate(y: this.icBubbleY)
                .opacity(this.icBubbleOpacity)
                .animation(AnimateParam(duration: 500, curve: Curve.EaseOut, delay: 450))
            }

            // 铅笔（pencil）：右下/中下偏右，6 组图标中最后一个弹入，带轻微书写摆动
            if (this.imgIcPencil.size > 0) {
                Column {
                    Column {
                        Image(this.imgIcPencil)
                            .width(28)
                            .height(28)
                            .objectFit(ImageFit.Contain)
                    }
                    .rotate(angle: this.icPencilSway)
                    .animation(AnimateParam(
                        duration: 1600,
                        curve: Curve.EaseInOut,
                        delay: 950,
                        iterations: -1,
                        playMode: PlayMode.Alternate
                    ))
                }
                .position(x: 118, y: 150)
                .translate(y: this.icPencilY)
                .opacity(this.icPencilOpacity)
                .animation(AnimateParam(duration: 500, curve: Curve.EaseOut, delay: 550))
            }
        }
        .width(180)
        .height(180)
        .margin(bottom: 16)
    }

    func build() {
        Column {
                // 上方弹性空白：与下方 Spacer 对称，将内容区（Swiper+dots）垂直居中
                // P1 fix: top symmetric spacer so content zone is centered on screen
                Column {}
                    .layoutWeight(1)

                // 引导轮播（Telegram / Fast / Free / Powerful / Secure / Cloud-Based）
                // Swiper 不设 layoutWeight，按内容高度自适应
                Swiper(controller: this.swiperController) {
                    ForEach(Array<Int64>(6, { i: Int64 => i }), itemGenerator: { idx: Int64, _i: Int64 =>
                        Column {
                            if (idx == 0) {
                                this.pageTelegram()
                            } else if (idx == 1) {
                                this.pageFast()
                            } else if (idx == 2) {
                                this.pageFree()
                            } else if (idx == 3) {
                                this.pagePowerful()
                            } else if (idx == 4) {
                                this.pageSecure()
                            } else {
                                this.pageCloud()
                            }
                            Text(this.getSlideTitle(idx))
                                .fontSize(20)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0x000000)
                                .margin(bottom: 8)
                            this.slideSubtitleText(idx)
                        }
                        .width(100.percent)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                        .padding(top: 16, bottom: 16)
                    })
                }
                .indicator(false)
                .loop(false)
                .index(UInt32(0))
                .onChange({ index: Int32 =>
                    this.slideIndex = Int64(index)
                })
                .width(100.percent)

                // 分页指示点（自绘 Row，紧随 slide 内容正下方，对齐 iOS dots 位置）
                // R3: dots 在内容组（Swiper 与 Spacer 之间）
                Row {
                    ForEach(Array<Int64>(6, { i: Int64 => i }), itemGenerator: { dotIdx: Int64, _i: Int64 =>
                        Column {}
                            .width(if (this.isDotSelected(dotIdx)) { 8 } else { 6 })
                            .height(if (this.isDotSelected(dotIdx)) { 8 } else { 6 })
                            .borderRadius(if (this.isDotSelected(dotIdx)) { 4 } else { 3 })
                            .backgroundColor(if (this.isDotSelected(dotIdx)) { 0x317AFF } else { 0xC8C8C8 })
                            .margin(left: 4, right: 4)
                    })
                }
                .justifyContent(FlexAlign.Center)
                .width(100.percent)
                .margin(top: 8, bottom: 8)

                // 下方弹性空白：把按钮撑到底部，dots 保持在内容组
                // R3: Spacer(layoutWeight:1) 在 dots 与按钮间
                Column {}
                    .layoutWeight(1)

                // MTProto 状态提示（仅在初始化中显示加载行）
                if (getAuthViewModel().authState == "initializing") {
                    Row {
                        LoadingProgress()
                            .width(16)
                            .height(16)
                            .color(0x999999)
                        Text("正在连接 Telegram 服务器...")
                            .fontSize(12)
                            .fontColor(0x999999)
                            .margin(left: 8)
                    }
                    .margin(bottom: 12)
                }

                // 错误信息
                if (getAuthViewModel().errorMessage.size > 0) {
                    Text(getAuthViewModel().errorMessage)
                        .fontSize(12)
                        .fontColor(0xFF3B30)
                        .margin(bottom: 12)
                        .padding(left: 24, right: 24)
                }

                // 底部按钮
                Column {
                    // 主按钮（SolidRoundedButton 原子）
                    // enabled: tdAuthState == AUTH_STATE_WAIT_PHONE（与原一致）
                    // 默认 backgroundColor/disabledColor/cornerRadius/height/textColor 与原值一致
                    Column {
                        SolidRoundedButton(
                            title: "Start Messaging",
                            onClick: this.onStartMessagingClick,
                            loading: false,
                            enabled: getAuthViewModel().authState == AUTH_STATE_WAIT_PHONE
                        )
                    }
                    .margin(left: 24, right: 24, bottom: 40)
                    .width(100.percent)
                }
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFFFFFF)
            .onAppear({ => this.ensureLoaded() })
    }
}
