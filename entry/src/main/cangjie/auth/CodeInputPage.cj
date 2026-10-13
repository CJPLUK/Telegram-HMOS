package ohos_app_cangjie_entry.auth

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.viewmodels.*
import ohos_app_cangjie_entry.core.mtproto.SentCodeType
import ohos_app_cangjie_entry.core.mtproto.AuthCodeNextType
import std.time.*
import ohos_app_cangjie_entry.core.services.getTelegramCore_AccountManagerService
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.app.signalAccountSwitched
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.utils.readRawFileBytes
import std.convert.*

/**
 * 验证码输入页面 — MTProto 真实认证
 *
 * Phase 7: 连接 MTProto 真实认证
 * P2-318f: 多账号添加流闭环 — addAccount 上下文传递与 completeAddAccount/cancelAddAccount 调用
 *
 * 流程（首次登录 / 正常路径）：
 * 1. 显示发送验证码的手机号
 * 2. 用户输入验证码
 * 3. 调用 AuthViewModel.verifyCode()
 * 4. MTProto 异步验证
 * 5. 成功 → isLoggedIn = true → 切换到 MainTabPage
 *    新用户 → 导航到 SignUpPage
 *
 * 流程（添加账号路径，addAccountContext 非空）：
 * 5. 成功 (Authorized) → completeAddAccount(newSlot, origSlot) → 重建 Settings root
 * 6. 用户返回 / 取消 → cancelAddAccount(newSlot, origSlot) → pop
 * 7. 2FA → PasswordInputPage（传递 addAccountContext 参数）
 *
 * 回归安全：addAccountContext 为空时完全不调用 complete/cancelAddAccount，原路径字节级不变。
 */
@HybridComponentEntry
@Component
public class CodeInputPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 手机号（从 @Consume 获取）
    @State var phoneNumber: String = ""

    // 验证码
    @State var code: String = ""

    // 加载状态
    @State var isLoading: Bool = false

    // 重发倒计时（秒）
    @State var resendTimerSeconds: Int32 = 0

    // P2-013: 投递类型（从 RealAuthService 读取，aboutToAppear 时赋值）
    @State var deliveryType: SentCodeType = SentCodeType.Unknown

    // 验证码位数：来自服务端 sentCodeType.length（中国短信 6 位）。
    // 此前写死 5，导致 6 位码填不满/无法自动提交。ensureLoaded / 切换投递方式时刷新。
    @State var codeLength: Int64 = 5

    // P2-014: 下一个可用投递方式（NoneNext = 服务器未提供 nextType，不显示切换按钮）
    @State var nextDeliveryType: AuthCodeNextType = AuthCodeNextType.NoneNext

    // P2-014: 切换投递方式时的加载标记
    @State var isSwitchingMethod: Bool = false

    // P2-020: FLOOD_WAIT 倒计时秒数（> 0 时显示）
    @State var floodWaitSeconds: Int32 = 0

    // 混合迁移：首次渲染守卫
    @State var loaded: Bool = false

    // 混合迁移 auth-flow：原 EntryView @Consume（isLoggedIn/tdAuthState/authError/authPhoneNumber）
    // 在隔离嵌入页无 provider，全部改读写 app 级单例 getAuthViewModel()。
    // 登录成功后本页直接 routerReplace("MainTabPage")（原 EntryView 监听 isLoggedIn 切栈的替代）。

    // P2-318f: addAccount 上下文，从 onReady 解析路由参数
    // 格式 "addaccount:<newSlot>:<origSlot>"，正常登录时为 ""
    @State var addAccountContext: String = ""

    // P2-318f: 解析后的槽号（addAccountContext 非空时有效）
    @State var addAccountNewSlot: Int32 = -1
    @State var addAccountOriginalSlot: Int32 = -1
    // A completed code value can be emitted again while the component is being
    // rebuilt. Keep a non-visual one-shot lock until an actual verification error
    // occurs; isLoading is reset during successful navigation and is not sufficient.
    private var codeSubmissionLocked: Bool = false

    // fix/TC-0010: 顶部投递类型插画（对应 iOS AuthorizationSequenceCodeEntryControllerNode
    // .animationNode: AnimatedStickerNodeLocalFileSource(name: animationName)）沙箱提取路径
    // （rawfile/intro_message|letter|fragment.png 提取到 filesDir/intro/ 后的 file:// 路径）。
    // 空串代表尚未提取成功，build() 侧据此判空回退，避免加载失败留白裂图（写法对齐
    // PhoneInputPage.imgIntroPhone / SplashPage.imgXxx 已验证的 rawfile 提取模式）。
    @State var introImagePath: String = ""

    // 插画常驻循环轻微摆动角度（对应 iOS AnimatedStickerNode 循环播放动效近似；写法对齐
    // PhoneInputPage.phoneIconTiltAngle 已验证模式）。
    // 注意（诊断报告 diag-suite_auth_login-TC-0010.md 修法方向 §5 已确认可接受的降级）：
    // 源侧 IntroMessage/IntroLetter 的 playbackMode 均为 .once（播完停末帧），IntroFragment
    // 为 .count(3)（播 3 次后停末帧）；这里用 iterations:-1 的静态帧摆动只是循环观感的近似，
    // 不是对源侧一次性/三次播放语义的复刻。刻意保持与 PhoneInputPage 相同的摆动幅度，
    // 不应加大或引入更强动效，以免比源侧"播完即停"更抢注意力。
    @State var introIconTiltAngle: Float32 = 0.0

    func build() {
        Column {
                // fix/TC-0010: 顶部投递类型插画 —— 对应 iOS AuthorizationSequenceCodeEntryControllerNode
                // .animationNode（AnimatedStickerNodeLocalFileSource，100×100 vp，
                // spacingBefore weight10/max10、spacingAfter weight0/max0，即紧贴标题上方，
                // AuthorizationSequenceCodeEntryControllerNode.swift:634-641）。此前 build() 顶部
                // 完全没有该节点（e2e TC-0010 B1：图形资源未迁移，判 FAIL，归因本 feature）。
                // 真实资源：用 rlottie 对源仓 IntroMessage/IntroLetter/IntroFragment.tgs 做矢量渲染
                // 取静止帧，落盘为 rawfile/intro_message|letter|fragment.png，非占位色块/emoji
                // （诊断报告 B2 硬纪律）。提取链路见 extractIntroImage()。
                if (this.introImagePath.size > 0) {
                    Column {
                        Image(this.introImagePath)
                            .width(100)
                            .height(100)
                            .objectFit(ImageFit.Contain)
                    }
                    .margin(top: 10)
                    .rotate(angle: this.introIconTiltAngle)
                    .animation(AnimateParam(
                        duration: 900,
                        curve: Curve.EaseInOut,
                        iterations: -1,
                        playMode: PlayMode.Alternate
                    ))
                }

                // 标题 —— 对齐 iOS AuthorizationSequenceCodeEntryControllerNode.containerLayoutUpdated()
                // 的 titleNode 分支：missedCall 用 Login_EnterMissingDigits（"Enter Missing Digits"），
                // 其余全部投递类型（sms/app/call/flashCall/fragment/email 等）落 default 分支 Login_EnterCodeTelegramTitle
                // /Login_EnterCodeSMSTitle 等，英文文案均为 "Enter Code"，故此前固定 "Enter Code" 对非 missedCall
                // 分支已是 1:1；仅 missedCall 分支之前遗漏未做区分，此处补上。
                // fix/TC-0010: top margin 60→18，对齐源侧 default 分支 titleNode 的
                // spacingBefore weight18/max18（紧接顶部插画之后，AuthorizationSequenceCodeEntryControllerNode
                // .swift:668）——此前的 60 是"没有插画时"用一个数字近似补偿两段空白的错误取值。
                Text(this.deliveryType.titleText())
                    .fontSize(24)
                    .fontWeight(FontWeight.Bold)
                    .margin(top: 18, bottom: 8)

                // P2-013: 投递类型专属标题文案（非硬编码 "via Telegram"）
                Text(this.deliveryType.deliveryTitle())
                    .fontSize(14)
                    .fontColor(0x999999)
                    .margin(bottom: 4)
                    .textAlign(TextAlign.Center)
                    .padding(left: 24, right: 24)

                // 显示手机号（投递类型不需要显示号码时隐藏）
                if (this.deliveryType.showsPhoneNumber()) {
                    Text(if (getAuthViewModel().phoneNumber.size > 0) { getAuthViewModel().phoneNumber } else { this.phoneNumber })
                        .fontSize(16)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(0x317AFF)
                        .margin(bottom: 8)
                }

                // P2-013: 投递类型标签（如 "via SMS" / "via Telegram"）
                Text(this.deliveryType.deliveryDescription())
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .margin(bottom: 32)

                // 错误信息显示
                if (getAuthViewModel().errorMessage.size > 0) {
                    Text(getAuthViewModel().errorMessage)
                        .fontSize(13)
                        .fontColor(0xFF3B30)
                        .margin(bottom: 16)
                        .padding(left: 24, right: 24)
                        .width(100.percent)
                }

                // 验证码输入框 / 加载中
                if (this.isLoading) {
                    Column {
                        LoadingProgress()
                            .width(32)
                            .height(32)
                            .color(0x317AFF)
                        Text("正在验证...")
                            .fontSize(14)
                            .fontColor(0x999999)
                            .margin(top: 8)
                    }
                } else {
                    Column {
                        this.buildCodeInputBoxes()
                    }
                }

                // 底部提示
                Text("Enter the code you received")
                    .fontSize(13)
                    .fontColor(0x999999)
                    .margin(top: 16)

                // P2-020: FLOOD_WAIT 倒计时提示
                if (this.floodWaitSeconds > 0) {
                    Text("Too many attempts. Please try again in ${this.floodWaitSeconds}s.")
                        .fontSize(13)
                        .fontColor(0xFF9500)
                        .margin(top: 8)
                        .padding(left: 24, right: 24)
                        .textAlign(TextAlign.Center)
                }

                // QA #6-fix: next-option 单槽位区 —— 对齐 iOS AuthorizationSequenceCodeEntryControllerNode
                // 的 nextOptionButtonNode：iOS 只有一个语义槽位，要么显示不可点的倒计时文案
                // （authorizationNextOptionText() timeout>0 分支，"mm:ss" 格式，非 "Xs"），要么显示
                // 一个可点击的单一动作（"Get code via X" 切换投递方式 / 无 nextType 时的
                // "Didn't get the code?"）。此前实现是两个独立按钮（"Didn't receive the code?" 走
                // 同投递方式重发 + 单独的 "切换方式" 按钮），与 iOS 单槽位语义不符——已收敛为单槽位。
                Column {
                    if (this.isSwitchingMethod) {
                        LoadingProgress()
                            .width(24)
                            .height(24)
                            .color(0x317AFF)
                            .margin(top: 30)
                    } else if (this.resendTimerSeconds > 0) {
                        // 倒计时态：不可点，mm:ss 格式（对齐 authorizationNextOptionText()
                        // "%d:%.02d" timeout 分支，而非之前的裸秒数 "Resend code in Xs"）
                        Text(formatMinSec(this.resendTimerSeconds))
                            .fontSize(14)
                            .fontColor(0x999999)
                            .margin(top: 30)
                    } else if (this.nextDeliveryType != AuthCodeNextType.NoneNext) {
                        // 倒计时结束 + 服务端提供了下一投递方式：单一可点击动作，切换投递方式
                        // （对齐 iOS requestNextOption → resendAuthorizationCode）
                        Button(this.nextDeliveryType.switchButtonLabel())
                            .fontSize(14)
                            .fontColor(0x317AFF)
                            .backgroundColor(Color.Transparent)
                            .margin(top: 30)
                            .onClick({ evt =>
                                this.switchCodeMethod()
                            })
                    } else {
                        // 服务端未提供 nextType（对齐 iOS Login_HaveNotReceivedCodeInternal 分支）。
                        // iOS 点击后走 reportMissingCode RPC + 客服引导 UI（AuthorizationSequenceController
                        // .presentDidNotGetCodeUI），该 RPC 未在本仓 MTProto 层实现，属已知限制
                        // （见 CodeInputPage.md Hand-off）；此处点击回退为同投递方式重发，保证按钮不是死按钮。
                        Button(trSource("Didn't get the code?"))
                            .fontSize(14)
                            .fontColor(0x317AFF)
                            .backgroundColor(Color.Transparent)
                            .margin(top: 30)
                            .onClick({ evt =>
                                this.resendCode()
                            })
                    }
                }

                // P2-318f: 添加账号流 — 取消按钮（仅 addAccount 上下文下显示）
                if (this.addAccountContext.size > 0) {
                    Button(trSource("Cancel"))
                        .width(100.percent)
                        .height(44)
                        .margin(top: 20, left: 24, right: 24)
                        .borderRadius(22)
                        .backgroundColor(0xE5E5EA)
                        .fontColor(0xFF3B30)
                        .fontSize(16)
                        .onClick({ evt =>
                            this.cancelAddAccountFlow()
                        })
                }
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFFFFFF)
            .alignItems(HorizontalAlign.Center)
            .onAppear({ => this.ensureLoaded() })
    }

    // 混合迁移：首次渲染时 — 解析 addAccount 上下文（经 takePending）+ 读取投递类型/倒计时
    // （原 onReady param 接收 + 原 aboutToAppear 实逻辑合并进此守卫，只跑一次）
    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true

        // P2-318f: 解析 addAccount 上下文参数（"addaccount:<newSlot>:<origSlot>"，空串走原路径）
        let rawParam = takePending("CodeInputPage")
        if (rawParam.size > 0 && rawParam.startsWith("addaccount:")) {
            this.addAccountContext = rawParam
            let (ns, os) = this.parseAddAccountParam(rawParam)
            this.addAccountNewSlot = ns
            this.addAccountOriginalSlot = os
            Hilog.info(0, "CjTelegram", "[CodeInputPage] addAccount context detected: newSlot=${this.addAccountNewSlot} origSlot=${this.addAccountOriginalSlot}")
        }

        let authService = getRealAuthService()
        let timeout = authService.getCodeTimeoutSeconds()

        // P2-013: 读取投递类型（来自上一步 sendCode 的 AuthSentCodeResponse.codeType）
        let sentType = authService.getSentCodeType()
        this.deliveryType = sentType
        Hilog.info(0, "CjTelegram", "[CodeInputPage] deliveryType=${this.deliveryType.deliveryDescription()}")

        // fix/TC-0010: 按当前投递类型提取顶部插画，并触发常驻摆动动效
        // （写法对齐 PhoneInputPage.ensureLoaded() 触发 phoneIconTiltAngle 的方式）
        this.extractIntroImage()
        this.introIconTiltAngle = 8.0

        // 读取验证码位数（服务端返回，中国短信 6 位；未知回退 5）
        this.codeLength = authService.getCodeLength()
        Hilog.info(0, "CjTelegram", "[CodeInputPage] codeLength=${this.codeLength}")

        // P2-014: 读取 nextType（服务端提供时显示切换按钮）
        let nextType = authService.getSentCodeNextType()
        this.nextDeliveryType = nextType
        Hilog.info(0, "CjTelegram", "[CodeInputPage] nextDeliveryType=${this.nextDeliveryType.switchButtonLabel()}")

        if (timeout > 0) {
            this.resendTimerSeconds = timeout
            let _ = spawn {
                var remaining = Int32(timeout)
                while (remaining > 0) {
                    sleep(Duration.second)
                    remaining = remaining - 1
                    let val = remaining
                    launch {
                        this.resendTimerSeconds = val
                    }
                }
            }
        }
    }

    /**
     * fix/TC-0010: 投递类型 → 顶部插画 rawfile 资源名。
     * 对应 iOS AuthorizationSequenceCodeEntryControllerNode.containerLayoutUpdated() 的
     * animationName 分发（swift:521-541）：默认 "IntroMessage"，.email 分支 "IntroLetter"，
     * .fragment 分支 "IntroFragment"，其余分支（missedCall/sms/call/flashCall/firebase/
     * setUpEmailRequired/word/phrase/unknown）沿用默认值不覆盖。
     * 注：SentCodeType 定义于 core/mtproto/TLResponses.cj，不在本 feature 的 target_files
     * allowlist 内，故在本文件内独立 match 而非给 SentCodeType 新增扩展方法。
     */
    private func introImageAssetName(): String {
        match (this.deliveryType) {
            case SentCodeType.Email => "intro_letter.png"
            case SentCodeType.Fragment => "intro_fragment.png"
            case _ => "intro_message.png"
        }
    }

    /**
     * fix/TC-0010: 将当前投递类型对应的 rawfile/intro_*.png 提取到 filesDir/intro/ 沙箱目录，
     * 写入 this.introImagePath 供 build() 渲染。
     * 写法对齐 SplashPage.extractOne() / PhoneInputPage.extractPhoneIllustration() 已验证模式：
     * 用 ResourceManager.getRawFileContent() 运行时读取，避免在 @Component build() 中使用
     * @rawfile() 宏（该宏生成 __GenerateResource__ native 符号调用，在 CJ so 加载时无法解析，
     * 导致 SIGSEGV，见 SplashPage.cj:284-286 注释）。
     */
    private func extractIntroImage(): Unit {
        let assetName = this.introImageAssetName()
        match (getGlobalAbilityContext()) {
            case None =>
                Hilog.info(0, "CjTelegram", "[CodeInputPage] extractIntroImage: no ability context")
            case Some(ctx) =>
                let filesDir = ctx.filesDir
                let introDir = filesDir + "/intro"
                try { FileIo.mkdir(introDir) } catch (_e: Exception) {}
                let targetPath = introDir + "/" + assetName
                match (readRawFileBytes(assetName)) {
                    case None =>
                        Hilog.info(0, "CjTelegram",
                            "[CodeInputPage] extractIntroImage: readRawFileBytes returned None for ${assetName}")
                    case Some(data) =>
                        if (data.size > 0) {
                            try {
                                let file = FileIo.open(targetPath, mode: 0o1101)
                                let _ = FileIo.write(file.fd, data)
                                FileIo.close(file)
                                this.introImagePath = "file://" + targetPath
                            } catch (_e: Exception) {
                                Hilog.info(0, "CjTelegram",
                                    "[CodeInputPage] extractIntroImage: write failed for ${assetName}")
                            }
                        }
                }
        }
    }

    // P2-318f: 解析 "addaccount:<newSlot>:<origSlot>" 参数
    // 返回 (newSlot, origSlot)，解析失败返回 (-1, -1)
    private func parseAddAccountParam(param: String): (Int32, Int32) {
        let parts = param.split(":")
        if (parts.size >= 3) {
            let newSlotStr = parts[1]
            let origSlotStr = parts[2]
            var newSlot: Int32 = -1
            var origSlot: Int32 = -1
            try {
                newSlot = Int32(Int64.parse(newSlotStr))
                origSlot = Int32(Int64.parse(origSlotStr))
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[CodeInputPage] parseAddAccountParam failed: ${e}")
            }
            return (newSlot, origSlot)
        }
        return (-1, -1)
    }

    // P2-318f: 取消添加账号流 — 调用 cancelAddAccount 恢复原 slot 并清除废 slot
    // 仅在 addAccountContext 非空时调用（addAccount 路径）
    private func cancelAddAccountFlow(): Unit {
        let newSlot = this.addAccountNewSlot
        let origSlot = this.addAccountOriginalSlot
        if (newSlot >= 0 && origSlot >= 0) {
            Hilog.info(0, "CjTelegram", "[CodeInputPage] cancelAddAccount: newSlot=${newSlot} origSlot=${origSlot}")
            let _ = spawn {
                let svc = getTelegramCore_AccountManagerService()
                svc.cancelAddAccount(newSlot, origSlot)
                Hilog.info(0, "CjTelegram", "[CodeInputPage] cancelAddAccount complete: restored origSlot=${origSlot}")
            }
        }
        routerPop()
    }

    // P2-318f: 完成添加账号流 — 调用 completeAddAccount 恢复原 slot 活跃状态
    // 新账号保留在 newSlot，用户可通过 switchAccount(newSlot) 切换
    private func completeAddAccountFlow(): Unit {
        let newSlot = this.addAccountNewSlot
        let origSlot = this.addAccountOriginalSlot
        if (newSlot >= 0 && origSlot >= 0) {
            Hilog.info(0, "CjTelegram", "[CodeInputPage] completeAddAccount: newSlot=${newSlot} origSlot=${origSlot}")
            let _ = spawn {
                let svc = getTelegramCore_AccountManagerService()
                // The phone-entry screen blocks known numbers before sendCode. Keep a
                // second identity-level guard here for formatted/changed phone numbers
                // and server-side aliases: one Telegram user may never occupy two slots.
                var duplicateSlot: Int32 = -1
                match (getAuthStorage().getUserDataForSlot(newSlot)) {
                    case Some(newUser) =>
                        duplicateSlot = svc.findOtherAuthorizedSlotForUser(newUser.id, newSlot)
                    case None => ()
                }
                if (duplicateSlot >= 0) {
                    svc.cancelAddAccount(newSlot, origSlot)
                    if (duplicateSlot != origSlot) {
                        let _ = svc.switchAccount(duplicateSlot)
                    }
                    let _ = getRealAuthService().tryRestoreLogin()
                    Hilog.info(0, "CjTelegram", "[CodeInputPage] Duplicate authorized identity rejected; switched to slot=${duplicateSlot}")
                    launch {
                        signalAccountSwitched(false)
                        routerReplace("MainTabPage", "{}")
                    }
                    return
                }
                svc.completeAddAccount(newSlot, origSlot)
                // S7-16: completeAddAccount switches to the new account (iOS makes the
                // added account current). Restore the auth singleton from the now-active
                // slot before rebuilding the root for it.
                let _ = getRealAuthService().tryRestoreLogin()
                Hilog.info(0, "CjTelegram", "[CodeInputPage] completeAddAccount done: newSlot=${newSlot} is now current (origSlot=${origSlot})")
                launch {
                    // Recreate the account-scoped tab pages for the new account. Two
                    // immediate routerPop() calls can race the navigation stack and leave
                    // an empty NavDestination after a successful add-account login.
                    signalAccountSwitched(false)
                    routerReplace("MainTabPage", "{}")
                }
            }
        } else {
            signalAccountSwitched(true)
            routerReplace("MainTabPage", "{}")
        }
    }

    /**
     * 提交验证码
     */
    private func submitCode(code: String) {
        // TextInput can emit the completed value more than once while its visual
        // cells rebuild. Only one auth.signIn request may own this submission.
        if (this.isLoading || this.codeSubmissionLocked) { return }
        if (this.addAccountContext.size > 0 &&
            getAuthStorage().getPendingAuthSlot() != this.addAccountNewSlot) {
            Hilog.info(0, "CjTelegram", "[CodeInputPage] Ignored stale add-account code submission")
            return
        }
        this.codeSubmissionLocked = true
        this.isLoading = true
        getAuthViewModel().errorMessage = ""

        // P2-318f: 捕获 addAccount 上下文供 spawn 闭包使用
        let capturedAddCtx = this.addAccountContext

        spawn {
            try {
                let authService = getRealAuthService()
                authService.verifyCode(code)

                let state = authService.getState()
                let lastErr = authService.getLastError()
                launch {
                    // A failed request must win over a stale Authorized state. In an
                    // add-account flow the original account may be restored by an
                    // account listener while this request is finishing; treating that
                    // original account's state as this login's success creates a slot
                    // whose auth key is not registered on the server.
                    if (lastErr.size > 0) {
                        this.codeSubmissionLocked = false
                        this.handleAuthError(lastErr)
                        Hilog.info(0, "CjTelegram", "[CodeInputPage] Verification failed: ${lastErr}")
                    } else {
                        match (state) {
                        case RealAuthState.Authorized =>
                            this.isLoading = false
                            if (capturedAddCtx.size > 0) {
                                // P2-318f: addAccount 路径 — completeAddAccount + 重建 Settings root
                                // 不设置 isLoggedIn (正常登录已是 true)，不切换到 MainTabPage
                                this.completeAddAccountFlow()
                                Hilog.info(0, "CjTelegram", "[CodeInputPage] addAccount complete — new account added (addCtx='${capturedAddCtx}')")
                            } else {
                                // 正常首次登录路径 — 混合迁移：写单例 + routerReplace 进主 tab
                                getAuthViewModel().isLoggedIn = true
                                getAuthViewModel().authState = AUTH_STATE_READY
                                routerReplace("MainTabPage", "{}")
                                Hilog.info(0, "CjTelegram", "[CodeInputPage] Verification successful, user is logged in")
                            }
                        case RealAuthState.WaitingSignUp =>
                            this.isLoading = false
                            getAuthViewModel().authState = AUTH_STATE_WAIT_REGISTRATION
                            routerPush("SignUpPage", capturedAddCtx)
                            Hilog.info(0, "CjTelegram", "[CodeInputPage] Sign up required, navigating to SignUpPage")
                        case RealAuthState.WaitingPassword =>
                            this.isLoading = false
                            getAuthViewModel().authState = AUTH_STATE_WAIT_PASSWORD
                            // P2-318f: 传递 addAccount 上下文给 PasswordInputPage
                            routerPush("PasswordInputPage", capturedAddCtx)
                            Hilog.info(0, "CjTelegram", "[CodeInputPage] 2FA required, navigating to PasswordInputPage (addCtx='${capturedAddCtx}')")
                        case RealAuthState.AwaitingAccountReset =>
                            // TC-0012/D5a 修法: AwaitingAccountReset 此前只写 authState，无导航消费者，
                            // 页面 auth/AccountResetPage.cj 永不可达。补齐 feature md 遗留的 Hand-off。
                            this.isLoading = false
                            let waitSec = authService.getAccountResetWaitSeconds()
                            getAuthViewModel().accountResetWaitSeconds = waitSec
                            getAuthViewModel().authState = AUTH_STATE_AWAITING_ACCOUNT_RESET
                            getAuthViewModel().shouldNavigateToAccountReset = true
                            let resetPhone = getAuthViewModel().phoneNumber
                            // AccountResetPage.cj:65-66 takePending 解析约定 "<waitSeconds>:<phone>"
                            routerPush("AccountResetPage", "${waitSec}:${resetPhone}")
                            Hilog.info(0, "CjTelegram", "[CodeInputPage] Account reset required, navigating to AccountResetPage (wait=${waitSec})")
                        case _ =>
                            // P2-020: delegate to full auth error classification
                            this.codeSubmissionLocked = false
                            this.isLoading = false
                            getAuthViewModel().errorMessage = "Code verification failed, please try again"
                            Hilog.info(0, "CjTelegram", "[CodeInputPage] Verification failed: ${lastErr}")
                        }
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[CodeInputPage] verifyCode exception")
                launch {
                    this.codeSubmissionLocked = false
                    this.isLoading = false
                    getAuthViewModel().errorMessage = "验证失败: ${e}"
                }
            }
        }
    }

    /**
     * 重新发送验证码
     */
    private func resendCode() {
        if (this.resendTimerSeconds > 0) { return }
        this.isLoading = true
        getAuthViewModel().errorMessage = ""
        spawn {
            try {
                let authService = getRealAuthService()
                let authVM = getAuthViewModel()
                let phone = authVM.getFullPhoneNumber()
                if (phone.size > 0) {
                    authService.sendCode(phone)
                    let timeout = authService.getCodeTimeoutSeconds()
                    let initSeconds = if (timeout > 0) { timeout } else { Int32(60) }
                    launch {
                        this.isLoading = false
                        this.resendTimerSeconds = initSeconds
                    }
                    let _ = spawn {
                        var remaining = initSeconds
                        while (remaining > 0) {
                            sleep(Duration.second)
                            remaining = remaining - 1
                            let val = remaining
                            launch {
                                this.resendTimerSeconds = val
                            }
                        }
                    }
                    Hilog.info(0, "CjTelegram", "[CodeInputPage] Code resent")
                } else {
                    launch {
                        this.isLoading = false
                        getAuthViewModel().errorMessage = "手机号不可用，请返回重新输入"
                    }
                }
            } catch (e: Exception) {
                launch {
                    this.isLoading = false
                    getAuthViewModel().errorMessage = "重发验证码失败: ${e}"
                }
            }
        }
    }

    private func getCodeDigitAt(idx: Int64): String {
        let runes = this.code.toRuneArray()
        if (idx >= 0 && idx < Int64(runes.size)) {
            return runes[idx].toString()
        }
        return ""
    }

    private func isCodeBoxActive(idx: Int64): Bool {
        return idx == Int64(this.code.size)
    }

    @Builder
    func buildCodeInputBoxes() {
        Stack() {
            Row() {
                ForEach(Array<Int64>(this.codeLength, { i: Int64 => i }), itemGenerator: { idx: Int64, _i: Int64 =>
                    Column() {
                        Text(this.getCodeDigitAt(idx))
                            .fontSize(24)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0x000000)
                    }
                    .width(48)
                    .height(56)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .border(width: 2, color: if (this.isCodeBoxActive(idx)) { 0x317AFF } else { 0xE0E0E0 })
                    .borderRadius(8)
                    .margin(right: if (idx < this.codeLength - 1) { 8 } else { 0 })
                })
            }
            .width(100.percent)
            .height(56)
            .justifyContent(FlexAlign.Center)

            TextInput(text: this.code, placeholder: "")
                .width(100.percent)
                .height(56)
                .fontSize(24)
                .inputFilter("[0-9]", error: { _: String => })
                .opacity(0.001)
                .onChange({ value: String =>
                    this.handleCodeInputChange(value)
                })
        }
        .width(100.percent)
        .height(56)
        .alignContent(Alignment.Center)
    }

    private func filterDigitsOnly(value: String): String {
        let runes = value.toRuneArray()
        var out = ""
        for (r in runes) {
            let c = UInt32(r)
            if (c >= 48 && c <= 57) {
                out = out + r.toString()
            }
        }
        return out
    }

    private func handleCodeInputChange(value: String): Unit {
        let filtered = this.filterDigitsOnly(value)
        // 截断到服务端返回的位数（中国短信 6 位），此前写死 5
        let maxLen = this.codeLength
        let truncated = if (Int64(filtered.size) > maxLen) {
            let runes = filtered.toRuneArray()
            var acc = ""
            var i: Int64 = 0
            while (i < maxLen) {
                acc = acc + runes[i].toString()
                i = i + 1
            }
            acc
        } else {
            filtered
        }
        this.code = truncated
        if (getAuthViewModel().errorMessage.size > 0) {
            getAuthViewModel().errorMessage = ""
        }
        // 填满即自动提交（位数由服务端决定）
        if (Int64(truncated.size) == maxLen) {
            this.submitCode(truncated)
        }
    }

    /**
     * P2-020: 解析 FLOOD_WAIT_X 错误中的等待秒数，启动倒计时
     * 返回通用错误文案（具体数字通过 floodWaitSeconds 显示）
     */
    private func handleFloodWait(err: String): String {
        let parts = err.split("_")
        var seconds: Int32 = 60
        if (parts.size >= 3) {
            let secStr = parts[2]
            var sec: Int32 = 0
            var valid = true
            for (ch in secStr) {
                let code = UInt32(ch)
                if (code >= 48 && code <= 57) {
                    sec = sec * 10 + Int32(code - 48)
                } else {
                    valid = false
                    break
                }
            }
            if (valid && sec > 0) { seconds = sec }
        }
        let capturedSeconds = seconds
        launch {
            this.floodWaitSeconds = capturedSeconds
        }
        let _ = spawn {
            var remaining = capturedSeconds
            while (remaining > 0) {
                sleep(Duration.second)
                remaining = remaining - 1
                let val = remaining
                launch {
                    this.floodWaitSeconds = val
                }
            }
        }
        return "Too many attempts. Please wait before trying again."
    }

    /**
     * P2-020: 全局认证错误分类处理
     * 对应 iOS AuthorizationCodeRequestError 各 case 的专属 UI/文案/动作
     */
    private func handleAuthError(err: String): Unit {
        if (err == "PHONE_NUMBER_BANNED" || err == "PHONE_BANNED") {
            // P2-020: PHONE_BANNED → alert with support email
            launch {
                this.isLoading = false
                this.isSwitchingMethod = false
                getUIContext().showAlertDialog(
                    AlertDialogParamWithButtons(
                        message: "This phone number has been banned from Telegram. If you think this is a mistake, please contact support@telegram.org.",
                        title: "Account Banned",
                        primaryButton: AlertDialogButtonOptions(
                            value: "OK",
                            action: {=>
                                Hilog.info(0, "CjTelegram", "[CodeInputPage] PHONE_BANNED alert dismissed")
                            }
                        ),
                        secondaryButton: AlertDialogButtonOptions(
                            value: "Contact Support",
                            action: {=>
                                Hilog.info(0, "CjTelegram", "[CodeInputPage] PHONE_BANNED: user chose contact support")
                            }
                        )
                    )
                )
            }
        } else if (err.startsWith("FLOOD_WAIT_")) {
            // P2-020: FLOOD_WAIT_X → countdown
            let msg = this.handleFloodWait(err)
            launch {
                this.isLoading = false
                this.isSwitchingMethod = false
                getAuthViewModel().errorMessage = msg
            }
        } else if (err == "PHONE_NUMBER_FLOOD") {
            // P2-020: too many phone numbers tried
            launch {
                this.isLoading = false
                this.isSwitchingMethod = false
                getAuthViewModel().errorMessage = "Too many attempts to request a code to this number. Please try again later."
            }
        } else if (err == "PHONE_CODE_INVALID" || err == "CODE_INVALID") {
            // P2-020: invalid code
            launch {
                this.isLoading = false
                this.isSwitchingMethod = false
                getAuthViewModel().errorMessage = "Invalid code. Please check and try again."
            }
        } else if (err == "PHONE_CODE_EXPIRED" || err == "CODE_EXPIRED") {
            // P2-020: code expired → reset to phone screen
            launch {
                this.isLoading = false
                this.isSwitchingMethod = false
                getAuthViewModel().errorMessage = "Code expired. Returning to phone number entry..."
            }
            let _ = spawn {
                sleep(Duration.second * 2)
                launch {
                    routerPop()
                }
            }
        } else if (err == "UPDATE_APP_TO_LOGIN" || err == "APP_OUTDATED") {
            // P2-020: APP_OUTDATED → store link alert
            launch {
                this.isLoading = false
                this.isSwitchingMethod = false
                getUIContext().showAlertDialog(
                    AlertDialogParamWithButtons(
                        message: "Please update the app to sign in. Visit the app store to get the latest version.",
                        title: "Update Required",
                        primaryButton: AlertDialogButtonOptions(
                            value: "OK",
                            action: {=>
                                Hilog.info(0, "CjTelegram", "[CodeInputPage] APP_OUTDATED alert dismissed")
                            }
                        ),
                        secondaryButton: AlertDialogButtonOptions(
                            value: "Update App",
                            action: {=>
                                Hilog.info(0, "CjTelegram", "[CodeInputPage] APP_OUTDATED: user chose update")
                            }
                        )
                    )
                )
            }
        } else {
            // Generic fallback
            launch {
                this.isLoading = false
                this.isSwitchingMethod = false
                getAuthViewModel().errorMessage = err
            }
        }
    }

    private func mapCodeError(err: String): String {
        if (err.startsWith("FLOOD_WAIT_")) {
            return "Too many attempts. Please try again later."
        }
        if (err == "PHONE_CODE_INVALID" || err == "CODE_INVALID") {
            return "Invalid code. Please check and try again."
        }
        if (err == "PHONE_CODE_EXPIRED" || err == "CODE_EXPIRED") {
            return "Code expired. Please request a new one."
        }
        return err
    }

    /**
     * P2-014: 切换验证方式 — 调用 auth.resendCode 切换到 nextType 投递方式
     * iOS: resendAuthorizationCode 当 nextType != nil 时调用 auth.resendCode
     */
    private func switchCodeMethod() {
        if (this.isSwitchingMethod || this.isLoading) { return }
        this.isSwitchingMethod = true
        getAuthViewModel().errorMessage = ""
        spawn {
            try {
                let authService = getRealAuthService()
                let ok = authService.resendCodeToSwitch()
                if (ok) {
                    let newType = authService.getSentCodeType()
                    let newNextType = authService.getSentCodeNextType()
                    let newTimeout = authService.getCodeTimeoutSeconds()
                    let newCodeLength = authService.getCodeLength()
                    launch {
                        this.isSwitchingMethod = false
                        this.deliveryType = newType
                        this.nextDeliveryType = newNextType
                        this.codeLength = newCodeLength
                        this.code = ""
                        // fix/TC-0010: 切换投递方式后重新选图（例如切到 email 需要 IntroLetter）
                        this.extractIntroImage()
                        if (newTimeout > 0) {
                            this.resendTimerSeconds = newTimeout
                        }
                        Hilog.info(0, "CjTelegram", "[CodeInputPage] switched to ${newType.deliveryDescription()}")
                    }
                    let initSeconds = if (newTimeout > 0) { newTimeout } else { Int32(0) }
                    if (initSeconds > 0) {
                        let _ = spawn {
                            var remaining = initSeconds
                            while (remaining > 0) {
                                sleep(Duration.second)
                                remaining = remaining - 1
                                let val = remaining
                                launch {
                                    this.resendTimerSeconds = val
                                }
                            }
                        }
                    }
                } else {
                    let lastErr = authService.getLastError()
                    this.handleAuthError(if (lastErr.size > 0) { lastErr } else { "Switch failed" })
                }
            } catch (e: Exception) {
                launch {
                    this.isSwitchingMethod = false
                    getAuthViewModel().errorMessage = "Failed to switch method: ${e}"
                }
            }
        }
    }
}

// QA #6-fix: mm:ss 倒计时格式化 —— 对齐 iOS authorizationNextOptionText() 的
// `String(format: "%d:%.02d", minutes, seconds)`（而非之前 CJ 侧裸秒数 "Xs"）。
// 顶层函数（非 class 成员）：build() 内 @Builder 表达式上下文只能调用返回值被 UI 组件消费的
// 普通函数，写成自由函数即可复用，无需绑定实例状态。
func formatMinSec(totalSeconds: Int32): String {
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    let secStr = if (seconds < 10) { "0${seconds}" } else { "${seconds}" }
    return "${minutes}:${secStr}"
}
