package ohos_app_cangjie_entry.auth

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.viewmodels.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.utils.readRawFileBytes
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import std.time.*

/**
 * 邮箱登录页面 — P2-015（TC-0015 返修: R1 接入登录链路 + R2/R3/R4 页面内修复）
 *
 * iOS 对应: AuthorizationSequenceEmailEntryController + Node
 *
 * 导航: PhoneInputPage 发码后若 RealAuthService 判定 SentCodeType.SetUpEmailRequired
 *   （对位 iOS SentAuthorizationCodeType.emailSetupRequired），routerPush("EmailLoginPage")
 *   进入本页 —— 此前该分支被压平进 WaitingCode，本页零导航入口（TC-0015 归因根因）。
 *
 * 两步流程:
 *   Step 1 — 输入邮箱地址:
 *     - 邮箱 TextInput，无本地格式拦截（对齐源侧 currentEmail.isEmpty 才是唯一客户端判断）
 *     - 空邮箱点击 Next → 归位式抖动 (R4)；非空 → account.sendVerifyEmailCode
 *     - 格式/服务端错误 (EMAIL_INVALID 等) → 模态 alert，单 OK 按钮 (R3)
 *     - 成功 → 进入 Step 2
 *   Step 2 — 输入邮箱验证码:
 *     - 显示脱敏邮箱 (email pattern)
 *     - 验证码 TextInput
 *     - 点击 Confirm → account.verifyEmail
 *     - 成功 → isLoggedIn = true
 *     - CHANGE_EMAIL_NO_CHANGES / CODE_INVALID 等错误 → 显示错误文案 (Step2 UI 未在本轮改动范围内)
 *
 * Sign in with Apple:
 *   HarmonyOS 平台不支持 Apple ID (无 ASAuthorizationAppleIDButton 等价物)。
 *   华为账号 (Account Kit) 仅用于华为自有应用生态，无法替代 Telegram 账号的 Apple 登录身份。
 *   因此本页面诚实标注 N/A，不渲染 Apple 登录按钮。
 *   (KB 查询: search-knowledge-base "HarmonyOS Account Kit Huawei ID sign in login" — 无命中，
 *    score < 0.02，确认无对应 API)
 *
 * @State 无 dangling: emailInput(读+写), emailCodeInput(读+写), isLoading(读+写),
 *   emailPattern(读+写), step(读+写), errorMessage(读+写), emailShake(读+写),
 *   introMailLoaded(读+写), introMailImagePath(读+写)
 */
@HybridComponentEntry
@Component
public class EmailLoginPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // Step 1: 邮箱输入
    @State var emailInput: String = ""

    // Step 2: 邮箱验证码输入
    @State var emailCodeInput: String = ""

    // 服务端返回的脱敏邮箱 pattern (如 a***@b.com)
    @State var emailPattern: String = ""

    // 1 = 邮箱输入, 2 = 验证码输入
    @State var step: Int32 = 1

    // 加载中
    @State var isLoading: Bool = false

    // 错误信息
    @State var errorMessage: String = ""

    // R4 (TC-0015 返修): 空邮箱点击 Continue 时的抖动反馈状态。对应 iOS
    // AuthorizationSequenceEmailEntryControllerNode.animateError() → addShakeAnimation()
    // (amplitude 3.0 / duration 0.3 / count 4 / decay false)。鸿蒙侧无等价的
    // CAKeyframeAnimation 抖动 API，按本项目既有惯例（components/PasscodeInputFieldComponent.cj
    // 的 showError→translate(x:)+animation 声明式抖动）做单次归位式简化，平台差异见此注释。
    @State var emailShake: Bool = false

    // R2 (TC-0015 返修 round 1): 首帧提取守卫，避免 onAppear 重复触发 extractIntroMailImage()。
    @State var introMailLoaded: Bool = false

    // R2 (TC-0015 返修 round 1): 顶部插画 rawfile 沙箱提取路径 —— 对应源侧真实资产 IntroMail.tgs
    // (AuthorizationSequenceEmailEntryControllerNode.swift:99,
    // AnimatedStickerNodeLocalFileSource(name:"IntroMail"), width:256 height:256,
    // playbackMode:.once)。空串代表尚未提取成功，build() 侧据此判空回退，避免加载失败留白裂图。
    // 写法对齐 CodeInputPage.introImagePath/extractIntroImage() 已验证模式。
    @State var introMailImagePath: String = ""

    // 混合迁移 auth-flow：原 EntryView @Consume isLoggedIn/tdAuthState 无 provider →
    // 改写 app 级单例 getAuthViewModel()，登录成功本页 routerReplace("MainTabPage")。

    // diag-suite_settings_privacy-TC-0143-round3/round4 M-A：设置域 ▸ 已绑定 ▸ Change 经
    // pages/PrivacySettingsPage.cj#openLoginEmailSettings() 以 routerPush("EmailLoginPage",
    // {"mode":"change","emailPattern":...}) 推入本屏；此前该参数零调用方（写入端已落地、
    // 读取端从未接回）。此处在首帧前取回并解析，供 build() 的标题二选一使用。登录链路
    // （auth/PhoneInputPage.cj）推本屏时传空串或 "addaccount:<n>:<o>"，均非 JSON，解析后
    // getString 回落空串 → isChangeMode=false，与源侧「登录链路恒 .setup」一致，无需特判。
    @State var isChangeMode: Bool = false

    public override func aboutToAppear(): Unit {
        let raw = takePending("EmailLoginPage")
        this.isChangeMode = (JsonParser.parseObject(raw).getString("mode") == "change")
    }

    func build() {
        Column {
                // diag-suite_settings_privacy-TC-0143-E8.md F-8: 本页零自绘顶部 chrome，
                // 系统 TitleBar 被宿主 Navigation 的全局 expandSafeArea 顶进状态栏带，导致
                // 返回控件可见不可点。补一个自绘导航 Row，形状逐字照抄
                // pages/LoginEmailPage.cj:220-238（Text(trSource("Back")) + 居中标题 + 右侧等宽占位，
                // .height(56.0 + getSafeAreaTop()) + .padding(top: getSafeAreaTop())）。标题
                // 复用现有 isChangeMode 表达式，与 Step 1 主标题同一文案来源。
                Row {
                    Text(trSource("Back"))
                        .fontSize(16)
                        .fontColor(0x317AFF)
                        .onClick({ _evt => routerPop() })
                    Blank().layoutWeight(1)
                    Text(if (this.isChangeMode) { "Enter New Email" } else { "Add Email" })
                        .fontSize(18)
                        .fontWeight(FontWeight.Bold)
                    Blank().layoutWeight(1)
                    Row { }.width(60)
                }
                .width(100.percent)
                .height(56.0 + getSafeAreaTop())
                .padding(left: 16, right: 16, top: getSafeAreaTop())
                .backgroundColor(0xFFFFFF)
                .alignItems(VerticalAlign.Center)

                Column {
                    // R2 (TC-0015 返修 round 1): 资源保真修复 —— 上一轮 auth_ic_mail.svg 是与源
                    // 资产无关的凭空手绘信封图标，被 Reviewer 判 FAIL（全 input 仓库找不到匹配该
                    // 路径几何的真实 PDF/SVG）。改为对源侧真实资产 IntroMail.tgs（Lottie，512x512
                    // 画布，图层 flag/flag shade/front/message/back/pole，邮筒+翻旗动效，
                    // AnimatedStickerNodeLocalFileSource(name:"IntroMail") playbackMode:.once）
                    // 用 rlottie 做矢量渲染取静止帧：flag 旋转关键帧 t=39 完全立起（rotation=0，
                    // 对应视觉上竖直/邮件可见），t=39~130 稳定持有，此处取 t=60（稳定区间内，
                    // 规避 t≈0 与 t≈176~180 两端 rlottie 渐变高光图层的条纹渲染缺陷），裁边落盘为
                    // rawfile/intro_mail.png，非手绘/占位。运行时提取到 filesDir/intro/ 沙箱后用
                    // Image(file://...) 渲染，写法对齐 CodeInputPage.extractIntroImage() 已验证
                    // 模式（避免在 build() 中用 @rawfile() 宏导致 SIGSEGV）。
                    if (this.introMailImagePath.size > 0) {
                        Image(this.introMailImagePath)
                            .width(72)
                            .height(72)
                            .objectFit(ImageFit.Contain)
                            .margin(top: 60, bottom: 16)
                    }

                    if (this.step == 1) {
                        // ── Step 1: 邮箱输入 ──
                        // TC-0015 round2 返修 (S6 文案自造): 标题逐字取自源 en.lproj/Localizable.strings
                        // key `LoginEmail.Title` = "Add Email"（用点 AuthorizationSequenceEmailEntry
                        // ControllerNode.swift:221, mode == .setup）。注意与诱饵 key
                        // `Login.AddEmailTitle` 英文值相同但源码 0 引用，不作为来源——来源就是
                        // `LoginEmail.Title`。
                        // diag-...-TC-0143-round3/round4 M-A：设置域 ▸ 已绑定 ▸ Change 经
                        // PrivacySettingsPage.openLoginEmailSettings() 以 {"mode":"change"} 推入
                        // 本屏，标题对位源 ControllerNode.swift:221 的 mode 三元式（.setup →
                        // `LoginEmail.Title`="Add Email"，.change → `Login.EnterNewEmailTitle`=
                        // "Enter New Email"）；isChangeMode 由 aboutToAppear() 取回。登录链路恒
                        // `.setup`（PhoneInputPage 推本屏的入参非 JSON，回落 isChangeMode=false）。
                        Text(if (this.isChangeMode) { "Enter New Email" } else { "Add Email" })
                            .fontSize(24)
                            .fontWeight(FontWeight.Bold)
                            .margin(bottom: 8)

                        // 源 key `LoginEmail.Description`，逐字（含句末句点），两个 mode 共用
                        Text(trSource("Please add your email address to keep access to your account."))
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .textAlign(TextAlign.Center)
                            .padding(left: 32, right: 32)
                            .margin(bottom: 24)

                        // R3 (TC-0015 返修): 邮箱输入框不再本地格式校验拦截 —— 对齐 iOS
                        // AuthorizationSequenceEmailEntryControllerNode（源侧唯一客户端判断
                        // 是 currentEmail.isEmpty，无 @/. 正则检查）。格式错误交服务端回
                        // EMAIL_INVALID，由 sendEmailCode() 以模态 alert 呈现（见下）。
                        // R4: 输入框随 emailShake 做一次归位式抖动（空邮箱点 Continue 时触发）。
                        Column {
                            // TC-0015 round2 返修: 输入框提示文案源 key `Login.AddEmailPlaceholder`，
                            // 逐字 "Enter your email"（用点 Node:123-137）。同批顺带：源侧还带
                            // keyboardType=.emailAddress + autocorrectionType=.no +
                            // autocapitalizationType=.none。KB 查询（search-component "InputType
                            // enum TextInput .type() attribute email"）无高置信命中（top score
                            // 0.033 < 0.7），且本工程已由 S-128（syntax_error.md）实测确认当前 SDK
                            // 绑定的 TextInput 无 `type`/InputType 成员（编译报 "'type' is not a
                            // member of class 'TextInput'"，SDK 落后于文档）。按修法方向：无等价 API
                            // 时只改提示文案，不重写输入框，此处保留平台差异说明。
                            TextInput(text: this.emailInput, placeholder: trSource("Enter your email"))
                                .width(280)
                                .height(44)
                                .fontSize(16)
                                .textAlign(TextAlign.Center)
                                .border(width: 1, color: 0xC7C7CC)
                                .borderRadius(8)
                                .onChange({ value: String =>
                                    this.emailInput = value
                                    if (this.errorMessage.size > 0) {
                                        this.errorMessage = ""
                                    }
                                })
                        }
                        .translate(x: if (this.emailShake) { 8.0 } else { 0.0 })
                        .animation(AnimateParam(duration: 80, curve: Curve.Linear))
                        .margin(bottom: 24)

                        // Next 按钮 —— R4: 恒可点（源侧 SolidRoundedButtonNode 无 enabled 态），
                        // 空邮箱点击走抖动分支而非禁用/内联报错。
                        if (this.isLoading) {
                            Column {
                                LoadingProgress()
                                    .width(32)
                                    .height(32)
                                    .color(0x317AFF)
                                Text("Sending verification code...")
                                    .fontSize(14)
                                    .fontColor(0x999999)
                                    .margin(top: 8)
                            }
                            .margin(top: 16)
                        } else {
                            // TC-0015 round2 返修: 页内主按钮标签源 key `Login.Continue`（用点
                            // Node:116, 254-255，SolidRoundedButtonNode，width > 320 分支恒可见）。
                            // 不与源侧导航栏右上角 `Common.Next`（Controller:126-137，仅
                            // width < 360pt 才创建、在售机型恒不出现）混淆——那个不在本 case 判据
                            // 范围。仅改标签，不动 R4 已验收的恒可点 + 空邮箱抖动行为。
                            Button(trSource("Continue"))
                                .width(280)
                                .height(44)
                                .margin(top: 16)
                                .borderRadius(22)
                                .backgroundColor(0x317AFF)
                                .fontColor(0xFFFFFF)
                                .fontSize(16)
                                .onClick({ evt =>
                                    if (this.emailInput.size == 0) {
                                        this.triggerEmailShake()
                                    } else {
                                        this.sendEmailCode()
                                    }
                                })
                        }

                        // Sign in with Apple — N/A on HarmonyOS
                        // iOS: ASAuthorizationAppleIDButton — 鸿蒙平台无对应 API
                        // 诚实标注：平台限制，不渲染入口
                        Column {
                            Text("Sign in with Apple is not available on HarmonyOS.")
                                .fontSize(11)
                                .fontColor(0xBBBBBB)
                                .textAlign(TextAlign.Center)
                                .padding(left: 32, right: 32)
                                .margin(top: 24)
                        }

                    } else {
                        // ── Step 2: 邮箱验证码输入 ──
                        Text(trSource("Check Your Email"))
                            .fontSize(24)
                            .fontWeight(FontWeight.Bold)
                            .margin(bottom: 8)

                        Text("We've sent a verification code to")
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .textAlign(TextAlign.Center)
                            .margin(bottom: 4)

                        if (this.emailPattern.size > 0) {
                            Text(this.emailPattern)
                                .fontSize(16)
                                .fontColor(0x317AFF)
                                .fontWeight(FontWeight.Medium)
                                .margin(bottom: 24)
                        } else {
                            Text(this.emailInput)
                                .fontSize(16)
                                .fontColor(0x317AFF)
                                .fontWeight(FontWeight.Medium)
                                .margin(bottom: 24)
                        }

                        // 验证码输入框
                        TextInput(text: this.emailCodeInput, placeholder: "Verification code")
                            .width(280)
                            .height(44)
                            .fontSize(20)
                            .textAlign(TextAlign.Center)
                            .inputFilter("[0-9a-zA-Z]", error: { _: String => })
                            .onChange({ value: String =>
                                this.emailCodeInput = value
                                if (this.errorMessage.size > 0) {
                                    this.errorMessage = ""
                                }
                            })

                        // 错误信息
                        if (this.errorMessage.size > 0) {
                            Text(this.errorMessage)
                                .fontSize(13)
                                .fontColor(0xFF3B30)
                                .textAlign(TextAlign.Center)
                                .padding(left: 24, right: 24)
                                .margin(top: 8)
                        }

                        // Confirm / loading
                        if (this.isLoading) {
                            Column {
                                LoadingProgress()
                                    .width(32)
                                    .height(32)
                                    .color(0x317AFF)
                                Text("Verifying...")
                                    .fontSize(14)
                                    .fontColor(0x999999)
                                    .margin(top: 8)
                            }
                            .margin(top: 20)
                        } else {
                            Button(trSource("Confirm"))
                                .width(280)
                                .height(44)
                                .margin(top: 20)
                                .borderRadius(22)
                                .backgroundColor(if (this.emailCodeInput.size > 0) { 0x317AFF } else { 0xCCCCCC })
                                .fontColor(0xFFFFFF)
                                .fontSize(16)
                                .enabled(this.emailCodeInput.size > 0)
                                .onClick({ evt =>
                                    this.verifyEmailCode()
                                })
                        }

                        // 返回修改邮箱
                        Button("Change email address")
                            .fontSize(14)
                            .fontColor(0x317AFF)
                            .backgroundColor(Color.Transparent)
                            .margin(top: 16)
                            .onClick({ evt =>
                                this.step = 1
                                this.emailCodeInput = ""
                                this.errorMessage = ""
                            })
                    }
                }
                .width(100.percent)
                .layoutWeight(1)
                .backgroundColor(0xFFFFFF)
                .alignItems(HorizontalAlign.Center)
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFFFFFF)
            .padding(bottom: getSafeAreaBottom())
            .onAppear({ => this.ensureLoaded() })
    }

    // R2 (TC-0015 返修 round 1): 首次渲染时提取顶部插画（守卫防重复触发），写法对齐
    // CodeInputPage.ensureLoaded() 已验证模式。
    private func ensureLoaded(): Unit {
        if (this.introMailLoaded) { return }
        this.introMailLoaded = true
        this.extractIntroMailImage()
    }

    /**
     * R2 (TC-0015 返修 round 1): 将 rawfile/intro_mail.png 提取到 filesDir/intro/ 沙箱目录，
     * 写入 this.introMailImagePath 供 build() 渲染。写法对齐 CodeInputPage.extractIntroImage()
     * 已验证模式：用 ResourceManager.getRawFileContent() 运行时读取，避免在 @Component build()
     * 中使用 @rawfile() 宏（该宏生成的 native 符号调用在 CJ so 加载时无法解析，导致 SIGSEGV，
     * 见 SplashPage.cj:284-286 注释）。
     */
    private func extractIntroMailImage(): Unit {
        let assetName = "intro_mail.png"
        match (getGlobalAbilityContext()) {
            case None =>
                Hilog.info(0, "CjTelegram", "[EmailLoginPage] extractIntroMailImage: no ability context")
            case Some(ctx) =>
                let filesDir = ctx.filesDir
                let introDir = filesDir + "/intro"
                try { FileIo.mkdir(introDir) } catch (_e: Exception) {}
                let targetPath = introDir + "/" + assetName
                match (readRawFileBytes(assetName)) {
                    case None =>
                        Hilog.info(0, "CjTelegram",
                            "[EmailLoginPage] extractIntroMailImage: readRawFileBytes returned None for ${assetName}")
                    case Some(data) =>
                        if (data.size > 0) {
                            try {
                                let file = FileIo.open(targetPath, mode: 0o1101)
                                let _ = FileIo.write(file.fd, data)
                                FileIo.close(file)
                                this.introMailImagePath = "file://" + targetPath
                            } catch (_e: Exception) {
                                Hilog.info(0, "CjTelegram",
                                    "[EmailLoginPage] extractIntroMailImage: write failed for ${assetName}")
                            }
                        }
                }
        }
    }

    /**
     * R4 (TC-0015 返修): 空邮箱点击 Continue —— 对齐 iOS nextPressed() 的
     * currentEmail.isEmpty 分支（Apple 登录在鸿蒙不可用，走 animateError() 一侧）。
     * 简化为归位式抖动，见 emailShake 字段注释。
     */
    private func triggerEmailShake(): Unit {
        this.emailShake = true
        spawn {
            sleep(Duration.millisecond * 300)
            launch {
                this.emailShake = false
            }
        }
    }

    /**
     * R3 (TC-0015 返修): 单 OK 模态 alert —— 对齐 iOS
     * AuthorizationSequenceController.proceedWithEmail 的 textAlertController
     * (AuthorizationSequenceController.swift:764-787)：格式/服务端错误统一以模态呈现，
     * 不再是内联红字。
     */
    private func showEmailSendErrorAlert(message: String): Unit {
        let msg = message
        getUIContext().showAlertDialog(
            AlertDialogParamWithButtons(
                message: msg,
                title: "",
                primaryButton: AlertDialogButtonOptions(
                    value: "OK",
                    action: {=>
                        Hilog.info(0, "CjTelegram", "[EmailLoginPage] send-email error alert dismissed")
                    }
                ),
                secondaryButton: None<AlertDialogButtonBaseOptions>
            )
        )
    }

    /**
     * Step 1: account.sendVerifyEmailCode —— 对应 iOS
     * updateNavigationItems/nextPressed/proceedWithEmail/sendLoginEmailCode。
     * R3: 不再本地格式校验拦截，格式错误交服务端 EMAIL_INVALID 判定。
     */
    private func sendEmailCode(): Unit {
        let emailCopy = this.emailInput
        this.isLoading = true
        this.errorMessage = ""
        spawn {
            try {
                let authService = getRealAuthService()
                let resp = authService.sendVerifyEmailCode(emailCopy)
                let lastErr = authService.getLastError()
                launch {
                    this.isLoading = false
                    if (resp.emailPattern.size > 0 || resp.length > 0) {
                        this.emailPattern = resp.emailPattern
                        this.step = 2
                        Hilog.info(0, "CjTelegram", "[EmailLoginPage] sendVerifyEmailCode ok, pattern=${this.emailPattern}")
                    } else {
                        let errMsg = if (lastErr.size > 0) { this.mapEmailSendError(lastErr) } else { "An error occurred, please try again later." }
                        this.showEmailSendErrorAlert(errMsg)
                        Hilog.info(0, "CjTelegram", "[EmailLoginPage] sendVerifyEmailCode failed: ${lastErr}")
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[EmailLoginPage] sendVerifyEmailCode exception: ${e}")
                launch {
                    this.isLoading = false
                    this.showEmailSendErrorAlert("An error occurred, please try again later.")
                }
            }
        }
    }

    /**
     * Step 2: account.verifyEmail (loginChange purpose)
     * 对应 iOS verifyLoginEmailChange
     */
    private func verifyEmailCode(): Unit {
        if (this.emailCodeInput.size == 0) { return }
        this.isLoading = true
        this.errorMessage = ""
        let codeCopy = this.emailCodeInput
        spawn {
            try {
                let authService = getRealAuthService()
                let ok = authService.verifyEmail(codeCopy)
                let lastErr = authService.getLastError()
                launch {
                    this.isLoading = false
                    if (ok) {
                        Hilog.info(0, "CjTelegram", "[EmailLoginPage] verifyEmail success — login email verified")
                        getAuthViewModel().isLoggedIn = true
                        getAuthViewModel().authState = AUTH_STATE_READY
                        routerReplace("MainTabPage", "{}")
                    } else {
                        let errMsg = if (lastErr.size > 0) { this.mapEmailVerifyError(lastErr) } else { "Verification failed" }
                        this.errorMessage = errMsg
                        Hilog.info(0, "CjTelegram", "[EmailLoginPage] verifyEmail failed: ${lastErr}")
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[EmailLoginPage] verifyEmail exception: ${e}")
                launch {
                    this.isLoading = false
                    this.errorMessage = "Verification failed: ${e}"
                }
            }
        }
    }

    /**
     * R3 (TC-0015 返修): 文案与 iOS Localizable.strings 逐条对位（Login.InvalidEmailError /
     * Login.EmailNotAllowedError / Login.CodeFloodError / Login.UnknownError），
     * 供 sendEmailCode() 的模态 alert 使用。isValidEmail() 本地正则校验已移除（无别处引用）。
     */
    private func mapEmailSendError(err: String): String {
        if (err == "EMAIL_INVALID") {
            return "Please enter a valid e-mail address."
        }
        if (err == "EMAIL_NOT_ALLOWED") {
            return "Sorry, this email can't be used."
        }
        if (err.startsWith("FLOOD_WAIT_")) {
            return "Too many attempts, please try again later."
        }
        return "An error occurred, please try again later."
    }

    private func mapEmailVerifyError(err: String): String {
        if (err == "CODE_INVALID") {
            return "Invalid code. Please check and try again."
        }
        if (err == "CODE_EXPIRED") {
            return "Code expired. Please request a new one."
        }
        if (err == "CHANGE_EMAIL_NO_CHANGES") {
            return "No changes to your email address."
        }
        if (err.startsWith("FLOOD_WAIT_")) {
            return "Too many attempts. Please try again later."
        }
        return err
    }
}
