package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.utils.*
import ohos_app_cangjie_entry.viewmodels.getAuthViewModel
import ohos_app_cangjie_entry.components.SolidRoundedButton
import std.unicode.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * 更改手机号页面 (Phase P6-10)
 *
 * 流程：
 * 1. 输入新手机号（含国家代码）
 * 2. account.sendChangePhoneCode → 获取 phone_code_hash
 * 3. 输入短信验证码
 * 4. account.changePhone → 完成更改
 * 5. 更新 AuthStorage
 */
@HybridComponentEntry
@Component
public class ChangePhonePage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // Step 1: 输入新手机号
    @State var newPhone: String = ""
    @State var countryCode: String = "+1"
    @State var countryName: String = "United States"

    // Step 2: 输入验证码
    @State var verificationCode: String = ""
    @State var phoneCodeHash: String = ""

    // 状态管理
    @State var currentStep: Int32 = 1  // 1 = 输入手机号, 2 = 输入验证码
    @State var isLoading: Bool = false
    @State var errorMessage: String = ""
    @State var successMessage: String = ""

    // test_failed 返修（diag-suite_settings_root-TC-0084-round2.md M1-M5）：换号页原来没有
    // 源侧 AuthorizationSequencePhoneEntryController.nextPressed() 那个单一提交汇聚点——
    // 键盘 return 无反应（A3）、主按钮直连网络发码、没有二次确认层（B5）。以下字段 + 方法
    // 逐条照搬同仓已 review 通过的 auth/PhoneInputPage.cj 移植先例，建立同形的汇聚点。
    //
    // M4：号码框抖动偏移量（对位 auth/PhoneInputPage.cj:103 phoneEntryShakeOffset）
    @State var phoneEntryShakeOffset: Float64 = 0.0

    // M5：号码二次确认弹窗状态（对位 auth/PhoneInputPage.cj:124/127）
    @State var showConfirmDialog: Bool = false
    @State var confirmDialogNumberText: String = ""

    // M5：号码输入框控制器 —— 弹确认弹窗前收起软键盘，避免遮住卡片底部按钮
    // （对位 auth/PhoneInputPage.cj:134 phoneInputController，先例 QA #6-fix）
    var phoneFieldController: TextInputController = TextInputController()

    // 混合迁移：一次性初始化守卫（对齐本工程其余 @HybridComponentEntry 页面用
    // .onAppear(){ ensureLoaded() } 的既有惯例，而非 aboutToAppear —— 见 ensureLoaded() 注释）
    @State var loaded: Bool = false

    // test_failed 返修（diag-suite_settings_root-TC-0083.md 归因 F3）：区号初值按本账号号码
    // 反查国家，对位源侧 ChangePhoneNumberController.swift:189-200
    // `lookupCountryIdByNumber(user.phone)`。查表用 utils/CountryData.cj 的
    // lookupCountryIdByNumber——与 components/PhoneInputComponent.cj 的 customFormatter 默认
    // 实现同一张权威表，不另建掩码表/特判表。
    //
    // 边界（诊断报告 A-4 明确约束，不得违反）：源侧兜底分支是
    // `AuthorizationSequenceCountrySelectionController.defaultCountryCode()`（纯 locale 推导），
    // 本工程侧对应实现是 viewmodels/AuthViewModel.cj:63 `resolveDefaultCountryFromLocale()`——
    // 该函数目前是 `private func`，本 feature 的 allowlist 不含 viewmodels/AuthViewModel.cj，
    // 跨包无法调用。诊断报告明确禁止"在换号页里重写一遍 locale 解析"（避免逻辑漂移出现两份），
    // 因此本轮只接通"账号号码可识别国家"这条主路径；识别失败或账号无手机号时保留
    // countryCode 现有初值不变（不新增猜测性兜底）。真正的 locale 兜底需等
    // resolveDefaultCountryFromLocale 改 public 后接入，已按 emitted_integration_contracts[]
    // 交给 auth_phone_entry_screen（详见 featureX.md Hand-off）。
    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        match (getAuthStorage().getUserData()) {
            case Some(userData) =>
                let digits = removePlus(userData.phone).trim()
                if (digits.size > 0) {
                    match (lookupCountryIdByNumber(digits)) {
                        case Some((code, _iso2, _pattern, name)) =>
                            this.countryCode = "+" + code
                            this.countryName = name
                        case None => ()
                    }
                }
            case None => ()
        }
        getAuthViewModel().countryCode = removePlus(this.countryCode)
        getAuthViewModel().countryName = this.countryName
    }

    private func syncSelectedCountry(): Unit {
        let vm = getAuthViewModel()
        if (vm.countryCode.size > 0 && vm.countryName.size > 0) {
            this.countryCode = "+" + removePlus(vm.countryCode)
            this.countryName = vm.countryName
        }
    }

    private func getFullPhoneNumber(): String {
        var code = this.countryCode
        if (code.size > 0 && code.toRuneArray()[0].toString() == "+") {
            let runes = code.toRuneArray()
            var result = ""
            var i: Int64 = 1
            while (i < runes.size) {
                result = result + runes[i].toString()
                i = i + 1
            }
            code = result
        }
        return cleanPhoneNumber("${code}${this.newPhone}")
    }

    // M1 建立单一提交汇聚点（对位源侧 nextPressed()，逐条照搬
    // auth/PhoneInputPage.cj:622-634 onNextClick() 的判定形状）：键盘 return（M2）与主提交
    // 按钮（M3）都调用这一个函数，不得各写一份。判空只看本地号码，不把区号计入判空
    // （对位源侧 codeAndNumber.2）。
    private func onPhoneEntrySubmit(): Unit {
        if (cleanPhoneNumber(this.newPhone).size == 0) {
            this.triggerChangePhoneShake()
            return
        }
        this.phoneFieldController.stopEditing()
        this.openConfirmDialog(formatPhoneNumber(this.countryCode, this.newPhone))
    }

    // M4 抖动（对位源侧 animateError() + addShakeAnimation()，逐字对齐
    // auth/PhoneInputPage.cj:703-712 triggerPhoneEntryShake()）：幅度 3.0 来自源侧
    // addShakeAnimation() 默认实参，不自选数值。空分支只做抖动，不写错误信息、不弹 toast、
    // 不跳转、不发请求。
    private func triggerChangePhoneShake(): Unit {
        this.phoneEntryShakeOffset = 3.0
        spawn {
            sleep(Duration.millisecond * 300)
            launch {
                this.phoneEntryShakeOffset = 0.0
            }
        }
    }

    // M5 号码二次确认覆盖层三件套（对位源侧 PhoneConfirmationController，逐条照搬
    // auth/PhoneInputPage.cj:532-546）。
    //
    // 展示弹窗：格式化按国家分组的号码 → 写入 @State → 打开弹窗
    private func openConfirmDialog(formattedNumber: String): Unit {
        this.confirmDialogNumberText = formattedNumber
        this.showConfirmDialog = true
    }

    // 关闭弹窗（对应 iOS Edit / dimTapped → cancelPressed，仅退出确认态，不清空已输入号码——
    // 案文 B4：Edit 返回后号码必须保留）
    private func dismissConfirmDialog(): Unit {
        this.showConfirmDialog = false
    }

    // Continue：关闭弹窗并真正提交号码（对应 iOS confirmationController.proceed）——
    // 这是本页唯一允许触发真实发码的地方
    private func confirmPhoneNumber(): Unit {
        this.showConfirmDialog = false
        this.sendChangePhoneCode()
    }

    private func sendChangePhoneCode(): Unit {
        let fullPhone = this.getFullPhoneNumber()
        if (fullPhone.size < 5) {
            this.errorMessage = "Please enter a valid phone number"
            return
        }
        this.isLoading = true
        this.errorMessage = ""

        let _ = spawn {
            var hash = ""
            var step: Int32 = 1
            var errMsg = ""
            var success = false
            try {
                let client = getMTProtoClient()
                let req = AccountSendChangePhoneCode()
                req.phoneNumber = fullPhone
                Hilog.info(0, "CjTelegram", "[ChangePhone] Sending code to ${fullPhone}...")

                let responseData = client.sendRequest(req.toBytes())
                if (responseData.size >= 4) {
                    let d = TLDeserializer(responseData)
                    let ctor = d.readUInt32()

                    // RPC Error
                    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                        let errCode = d.readInt32()
                        let errMsgRaw = d.readString()
                        Hilog.info(0, "CjTelegram", "[ChangePhone] RPC Error: ${errCode} ${errMsgRaw}")
                        if (errMsgRaw == "PHONE_NUMBER_INVALID") {
                            errMsg = "Invalid phone number"
                        } else if (errMsgRaw == "PHONE_NUMBER_OCCUPIED") {
                            errMsg = "This number is already in use by another account"
                        } else {
                            errMsg = "Error: ${errMsgRaw}"
                        }
                    } else if (ctor == 0x5e002502) {
                        let flags = d.readInt32()
                        let typeCtor = d.readUInt32()
                        skipSentCodeType(d, typeCtor)
                        hash = d.readString()
                        step = 2
                        success = true
                        Hilog.info(0, "CjTelegram", "[ChangePhone] Code sent, hash=${hash.size}ch")
                    } else {
                        Hilog.info(0, "CjTelegram", "[ChangePhone] Unknown response ctor: 0x${UInt32ToHexStr(ctor)}")
                        errMsg = "Unexpected server response"
                    }
                } else {
                    errMsg = "Empty response from server"
                }
            } catch (e: Exception) {
                errMsg = "Network error: ${e}"
                Hilog.info(0, "CjTelegram", "[ChangePhone] Exception: ${e}")
            }
            let finalHash = hash
            let finalStep = step
            let finalErrMsg = errMsg
            let finalSuccess = success
            launch {
                if (finalSuccess) {
                    this.phoneCodeHash = finalHash
                    this.currentStep = finalStep
                    this.errorMessage = ""
                } else {
                    this.errorMessage = finalErrMsg
                }
                this.isLoading = false
            }
        }
    }

    private func confirmChangePhone(): Unit {
        if (this.verificationCode.size < 3) {
            this.errorMessage = "Please enter the verification code"
            return
        }
        this.isLoading = true
        this.errorMessage = ""

        let fullPhone = this.getFullPhoneNumber()

        let _ = spawn {
            var errMsg = ""
            var successMsg = ""
            var needPop = false
            try {
                let client = getMTProtoClient()
                let req = AccountChangePhone()
                req.phoneNumber = fullPhone
                req.phoneCodeHash = this.phoneCodeHash
                req.phoneCode = this.verificationCode
                Hilog.info(0, "CjTelegram", "[ChangePhone] Confirming phone change...")

                let responseData = client.sendRequest(req.toBytes())
                if (responseData.size >= 4) {
                    let d = TLDeserializer(responseData)
                    let ctor = d.readUInt32()

                    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                        let errCode = d.readInt32()
                        let errMsgRaw = d.readString()
                        Hilog.info(0, "CjTelegram", "[ChangePhone] Confirm error: ${errCode} ${errMsgRaw}")
                        if (errMsgRaw == "PHONE_CODE_INVALID") {
                            errMsg = "Invalid verification code"
                        } else if (errMsgRaw == "PHONE_CODE_EXPIRED") {
                            errMsg = "Verification code expired, please request a new one"
                        } else {
                            errMsg = "Error: ${errMsgRaw}"
                        }
                    } else {
                        // Success — response is User object
                        let storage = getAuthStorage()
                        match (storage.getUserData()) {
                            case Some(userData) =>
                                userData.phone = fullPhone
                                storage.saveUserData(userData)
                            case None =>
                                Hilog.info(0, "CjTelegram", "[ChangePhone] No stored user data to update")
                        }
                        successMsg = "Phone number changed successfully!"
                        Hilog.info(0, "CjTelegram", "[ChangePhone] Phone changed to ${fullPhone}")
                        sleep(Duration.second * 2)
                        needPop = true
                    }
                } else {
                    errMsg = "Empty response from server"
                }
            } catch (e: Exception) {
                errMsg = "Network error: ${e}"
                Hilog.info(0, "CjTelegram", "[ChangePhone] Confirm exception: ${e}")
            }
            let finalErrMsg = errMsg
            let finalSuccessMsg = successMsg
            let finalNeedPop = needPop
            launch {
                this.isLoading = false
                if (finalErrMsg.size > 0) {
                    this.errorMessage = finalErrMsg
                } else {
                    this.errorMessage = ""
                    this.successMessage = finalSuccessMsg
                }
                if (finalNeedPop) {
                    routerPop()
                }
            }
        }
    }

    // M5.4 号码确认弹窗覆盖层（1:1 复制 auth/PhoneInputPage.cj:477-528 buildPhoneConfirmOverlay()
    // 的节点树与样式常量，只替换号码来源与调用点）。文案三处逐字对齐
    // Login.PhoneNumberConfirmation / Login.Edit / Login.Continue。
    @Builder
    private func buildPhoneConfirmOverlay() {
        Stack(alignContent: Alignment.Center) {
            // 压暗背景，点击=取消（对应 iOS dimTapped → cancelPressed）
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0x66000000)
                .onClick({ _ => this.dismissConfirmDialog() })

            // 居中白色圆角卡片
            Column {
                Text(this.confirmDialogNumberText)
                    .fontSize(30)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
                    .textAlign(TextAlign.Center)
                    .margin(top: 30, bottom: 20)

                Text(trSource("Is this the correct number?"))
                    .fontSize(17)
                    .fontColor(0x000000)
                    .textAlign(TextAlign.Center)
                    .margin(bottom: 25)

                Text(trSource("Edit"))
                    .fontSize(19)
                    .fontColor(0x317AFF)
                    .textAlign(TextAlign.Center)
                    .margin(bottom: 18)
                    .onClick({ _ => this.dismissConfirmDialog() })

                SolidRoundedButton(
                    title: "Continue",
                    onClick: this.confirmPhoneNumber,
                    loading: false,
                    enabled: true,
                    height: 50
                )
            }
            .width(86.percent)
            .padding(left: 18, right: 18, top: 0, bottom: 18)
            .borderRadius(24)
            .backgroundColor(0xFFFFFF)
            // 阻止卡片点击冒泡到遮障层
            .onClick({ _ => () })
        }
        .width(100.percent)
        .height(100.percent)
    }

    public func build() {
        // M5.5：根容器整体包进 Stack，承载号码确认覆盖层（结构先例
        // auth/PhoneInputPage.cj:263-264 + :458-460）；原有 .onAppear(...) 留在内层 Column 上。
        Stack {
        Column {
                // 导航栏
                Row {
                    Text("‹")
                        .fontSize(36)
                        .fontColor(0x000000)
                        .width(52)
                        .height(52)
                        .borderRadius(26)
                        .backgroundColor(0xF2F2F7)
                        .textAlign(TextAlign.Center)
                        .onClick({ evt =>
                            if (this.currentStep == 2) {
                                this.currentStep = 1
                                this.errorMessage = ""
                                this.verificationCode = ""
                            } else {
                                routerPop()
                            }
                        })

                    Blank().layoutWeight(1)
                }
                .width(100.percent)
                .height(56.0 + getSafeAreaTop())
                .padding(left: 8, right: 8, top: getSafeAreaTop())
                .backgroundColor(0xFFFFFF)
                .alignItems(VerticalAlign.Center)

                Scroll {
                    Column {
                        if (this.currentStep == 1) {
                            // ===== Step 1: 输入新手机号 =====
                            Column {
                                Image(@r(app.media.changephone_ic_handset))
                                    .width(104)
                                    .height(104)
                                    .margin(top: 82)

                                Text(trSource("New Number"))
                                    .fontSize(30)
                                    .fontWeight(FontWeight.Bold)
                                    .margin(top: 22)

                                Text("Your new number will receive a confirmation code via call or SMS.")
                                    .fontSize(17)
                                    .fontColor(0x000000)
                                    .textAlign(TextAlign.Center)
                                    .margin(top: 18, left: 44, right: 44, bottom: 34)

                                Divider().color(0xE5E5EA).strokeWidth(1)
                                Row {
                                    Text(this.countryName)
                                        .fontSize(20).fontColor(0x0A84FF).layoutWeight(1)
                                    Text("›").fontSize(30).fontColor(0xB8B8BD).margin(right: 18)
                                }
                                .width(100.percent).height(58).alignItems(VerticalAlign.Center)
                                .padding(left: 18)
                                .onClick({ _ =>
                                    getAuthViewModel().countryCode = removePlus(this.countryCode)
                                    getAuthViewModel().countryName = this.countryName
                                    routerPush("CountrySelectionPage", "")
                                })
                                Divider().color(0xE5E5EA).strokeWidth(1)

                                Row {
                                    Row {
                                        Text("+").fontSize(21).fontColor(0x000000)
                                        TextInput(text: removePlus(this.countryCode))
                                            .fontSize(21).fontColor(0x000000)
                                            .width(54).height(58)
                                            .padding(left: 0, right: 0)
                                            .backgroundColor(Color.Transparent)
                                            .inputFilter("[0-9]", error: { _: String => })
                                            .onChange({ value: String =>
                                                this.countryCode = "+" + value
                                                this.errorMessage = ""
                                            })
                                    }.width(88).height(58).alignItems(VerticalAlign.Center)
                                        .justifyContent(FlexAlign.Center)
                                    TextInput(placeholder: "00 0000 0000", text: this.newPhone, controller: this.phoneFieldController)
                                        .layoutWeight(1)
                                        .height(58)
                                        .fontSize(21)
                                        .backgroundColor(Color.Transparent)
                                        .inputFilter("[0-9 ]", error: { _: String => })
                                        .onChange({ value: String =>
                                            this.newPhone = value
                                            this.errorMessage = ""
                                        })
                                        // M2：键盘 return 触发边（对位 PhoneInputNode.textFieldShouldReturn
                                        // → returnAction → checkPhone，写法先例 components/SearchBar.cj:148-150、
                                        // pages/ChatAutomationPage.cj:107）。区号 TextInput 不加（源侧
                                        // textFieldShouldReturn 只对 numberField 生效）。
                                        .onSubmit({ _key: EnterKeyType => this.onPhoneEntrySubmit() })
                                }
                                .width(100.percent)
                                // M4：抖动作用范围就是这一行（包住区号框与号码框的 Row），对位源侧
                                // animateError() 只抖 countryCodeField/numberField 两个 layer，不抖标题/
                                // 国家行（写法先例 auth/PhoneInputPage.cj:371-372）。
                                .translate(x: this.phoneEntryShakeOffset)
                                .animation(AnimateParam(duration: 80, curve: Curve.Linear))
                                Divider().color(0xE5E5EA).strokeWidth(1)

                                // 错误信息
                                if (this.errorMessage.size > 0) {
                                    Text(this.errorMessage)
                                        .fontSize(14)
                                        .fontColor(0xFF3B30)
                                        .margin(top: 16)
                                        .textAlign(TextAlign.Center)
                                        .padding(left: 24, right: 24)
                                }

                                Blank().layoutWeight(1)
                                Button(if (this.isLoading) { "Sending..." } else { "Continue" })
                                    .width(100.percent)
                                    .height(52)
                                    .borderRadius(26)
                                    .backgroundColor(if (this.newPhone.size >= 5 && !this.isLoading) { 0x0A84FF } else { 0xEFEFF1 })
                                    .fontColor(if (this.newPhone.size >= 5 && !this.isLoading) { 0xFFFFFF } else { 0xA6A6AA })
                                    .fontSize(18)
                                    .fontWeight(FontWeight.Medium)
                                    .margin(left: 24, right: 24, bottom: 28)
                                    .enabled(this.newPhone.size >= 5 && !this.isLoading)
                                    // M3：把主提交按钮改接汇聚点（对位 proceedNode.pressed = { checkPhone?() }）——
                                    // .enabled(...) 门与颜色表达式保持原样不动，sendChangePhoneCode() 只在
                                    // confirmPhoneNumber() 内被调用。
                                    .onClick({ evt =>
                                        this.onPhoneEntrySubmit()
                                    })
                            }
                            .width(100.percent)
                            .alignItems(HorizontalAlign.Center)
                        } else {
                            // ===== Step 2: 输入验证码 =====
                            Column {
                                // 资源保真修复：真实矢量图标（Item List/Icons/Chat.imageset 转 SVG）替代 emoji 字形
                                Image(@r(app.media.set2_ic_chatbubble))
                                    .width(64)
                                    .height(64)
                                    .fillColor(0x007AFF)
                                    .margin(top: 40)

                                Text("Verification Code")
                                    .fontSize(22)
                                    .fontWeight(FontWeight.Bold)
                                    .margin(top: 20)

                                Text("We've sent an SMS with a code to ${this.countryCode}${this.newPhone}")
                                    .fontSize(14)
                                    .fontColor(0x8E8E93)
                                    .textAlign(TextAlign.Center)
                                    .margin(top: 8, left: 32, right: 32, bottom: 32)

                                TextInput(placeholder: trSource("Code"), text: this.verificationCode)
                                    .width(200)
                                    .height(48)
                                    .fontSize(24)
                                    .textAlign(TextAlign.Center)
                                    .backgroundColor(0xF2F2F7)
                                    .borderRadius(10)
                                    .inputFilter("[0-9]", error: { _: String => })
                                    .onChange({ value: String =>
                                        this.verificationCode = value
                                        this.errorMessage = ""
                                    })

                                // 错误信息
                                if (this.errorMessage.size > 0) {
                                    Text(this.errorMessage)
                                        .fontSize(14)
                                        .fontColor(0xFF3B30)
                                        .margin(top: 16)
                                        .textAlign(TextAlign.Center)
                                        .padding(left: 24, right: 24)
                                }

                                // 成功信息
                                if (this.successMessage.size > 0) {
                                    Text(this.successMessage)
                                        .fontSize(16)
                                        .fontColor(0x34C759)
                                        .fontWeight(FontWeight.Medium)
                                        .margin(top: 16)
                                }

                                // 确认按钮
                                Button(if (this.isLoading) { "Verifying..." } else { "Confirm" })
                                    .width(200)
                                    .height(48)
                                    .borderRadius(24)
                                    .backgroundColor(if (this.verificationCode.size >= 3 && !this.isLoading) { 0x007AFF } else { 0xCCCCCC })
                                    .fontColor(0xFFFFFF)
                                    .fontSize(17)
                                    .fontWeight(FontWeight.Medium)
                                    .margin(top: 32)
                                    .enabled(this.verificationCode.size >= 3 && !this.isLoading)
                                    .onClick({ evt =>
                                        this.confirmChangePhone()
                                    })

                                // 重新发送
                                Text("Didn't receive the code? Resend")
                                    .fontSize(14)
                                    .fontColor(0x317AFF)
                                    .margin(top: 24)
                                    .onClick({ evt =>
                                        this.currentStep = 1
                                        this.verificationCode = ""
                                        this.errorMessage = ""
                                    })
                            }
                            .width(100.percent)
                            .alignItems(HorizontalAlign.Center)
                        }
                    }
                    .width(100.percent)
                }
                .width(100.percent)
                .layoutWeight(1)
                .backgroundColor(0xFFFFFF)
        }
        // Rework round 2 (reviewer required_fixes): round 1 moved the padding onto this Column
        // (correct node — it holds both the self-drawn nav bar Row at line 382-407 and the Scroll
        // as siblings) but the Column had no explicit size, so it was an auto-sized child centered
        // by the outer Stack's default `alignContent: Alignment.Center` (see build() at line 379 —
        // no explicit alignContent passed). Asymmetric top/bottom padding on a center-aligned,
        // unsized Stack child only shifts content by (top-bottom)/2, not by `top` — it does not
        // reliably clear the status bar since getSafeAreaTop()/getSafeAreaBottom() are independent
        // values (app/AppStartup.cj:45-60). Fix: give this Column the same explicit
        // width(100%)/height(100%) as the outer Stack so it exactly fills the Stack regardless of
        // alignContent, making the padding's effect 1:1 instead of centered-and-halved.
        // (Earlier round's citation of CountrySelectionPage.cj:410-419 as "identical shape" was
        // inaccurate: there the padding sits on the SAME element that already carries
        // width(100%)/height(100%) — this Column previously did not, hence the halving bug.)
        .width(100.percent)
        .height(100.percent)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ =>
            this.ensureLoaded()
            this.syncSelectedCountry()
        })

        // M5.6：号码确认弹窗覆盖层，只可能由 onPhoneEntrySubmit() 置 true
        if (this.showConfirmDialog) {
            this.buildPhoneConfirmOverlay()
        }
        }
        .width(100.percent)
        .height(100.percent)
    }
}

/**
 * Skip auth_SentCodeType during deserialization
 */
func skipSentCodeType(d: TLDeserializer, ctor: UInt32): Unit {
    // auth.sentCodeTypeApp#3dbb5986 length:int
    if (ctor == 0x3dbb5986) {
        let _ = d.readInt32()
        return
    }
    // auth.sentCodeTypeSms#c000bba2 length:int
    if (ctor == 0xc000bba2) {
        let _ = d.readInt32()
        return
    }
    // auth.sentCodeTypeCall#5353e5a7 length:int
    if (ctor == 0x5353e5a7) {
        let _ = d.readInt32()
        return
    }
    // auth.sentCodeTypeFlashCall#ab03c6d9 pattern:string
    if (ctor == 0xab03c6d9) {
        let _ = d.readString()
        return
    }
    // Default: skip 4 bytes (length)
    let _ = d.readInt32()
}

func UInt32ToHexStr(value: UInt32): String {
    let hexArr = ["0", "1", "2", "3", "4", "5", "6", "7",
                  "8", "9", "a", "b", "c", "d", "e", "f"]
    var result = ""
    var v = value
    var i = 0
    while (i < 8) {
        let nibble = Int64((v >> UInt32(28)) & 0xF)
        result = result + hexArr[nibble]
        v = v << 4
        i = i + 1
    }
    return result
}
