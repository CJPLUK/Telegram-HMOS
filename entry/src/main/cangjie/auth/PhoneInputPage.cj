package ohos_app_cangjie_entry.auth

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.viewmodels.*
import ohos_app_cangjie_entry.components.{PhoneInputComponent, SolidRoundedButton}
import ohos_app_cangjie_entry.utils.*
import ohos_app_cangjie_entry.core.services.getTelegramCore_AccountManagerService
import ohos_app_cangjie_entry.app.signalAccountSwitched
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.interop.subscribe
import std.convert.*
import std.time.*

/**
 * 手机号输入页面 — MTProto 真实认证
 *
 * Phase 7: 连接 MTProto 真实认证
 * Phase P5-16: 国家代码选择器
 * P2-318f: 多账号添加流闭环 — 支持 addAccount 上下文传递
 *
 * 流程（首次登录 / 正常路径）：
 * 1. 用户点击国家代码 → 导航到 CountrySelectionPage
 * 2. 搜索/选择国家 → 回填国家代码
 * 3. 输入手机号
 * 4. 点击 Next → 通过 AuthViewModel.sendPhoneNumber() 发送
 * 5. MTProto 异步发送验证码
 * 6. 收到 onCodeSent 回调 → 导航到 CodeInputPage
 *
 * 流程（添加账号路径，addAccountContext 非空）：
 * 1-6. 同上，登录流在 newSlot 中执行
 * 7. 成功跳 CodeInputPage 时，传递 addAccountContext 参数
 * 8. 用户点击返回 / 取消 → cancelAddAccount(newSlot, origSlot) + pop
 *
 * 回归安全：addAccountContext 为空时完全不调用 complete/cancelAddAccount，原路径字节级不变。
 */
@HybridComponentEntry
@Component
public class PhoneInputPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 混合迁移 auth-flow：原 EntryView @Provide/@Consume（countryCode/countryName/tdAuthState/
    // authError/authPhoneNumber）在隔离嵌入页无 provider，全部改读写 app 级单例 getAuthViewModel()。
    // CountrySelectionPage 直接写 getAuthViewModel().countryCode/.countryName，本页读回。
    //
    // 反应性修复（两缺陷共同根因）：AuthViewModel 是 @Observed，字段是 @Publish，
    // 但只有当本组件把它的实例持有在 @State 字段里，框架才会把这个单例实例纳入
    // 本组件的依赖追踪（对照 CangjieUI "@Observed宏和@Publish宏" 文档 Example 3/4：
    // @State var Time: TimeClass = TimeClass(...) 持有单例后 this.Time.time 的嵌套
    // 属性变化才能感知）。此前 build() 内联调用 getAuthViewModel().countryCode 只是
    // 读一次快照，CountrySelectionPage pop-back 后本页不会重新渲染。
    @State var authVM: AuthViewModel = getAuthViewModel()

    // 手机号
    @State var phoneNumber: String = ""

    // 加载状态
    @State var isLoading: Bool = false

    // 混合迁移：首次渲染守卫
    @State var loaded: Bool = false

    // P2-011: 联系人同步开关（对应 iOS PhoneInputNode contacts sync toggle）
    // 允许用户选择是否同步联系人（默认 true，符合 iOS 行为）
    @State var syncContacts: Bool = true

    // P2-318f: addAccount 上下文，从 onReady 解析路由参数
    // 格式 "addaccount:<newSlot>:<origSlot>"，正常登录时为 ""
    @State var addAccountContext: String = ""

    // P2-318f: 解析后的槽号（addAccountContext 非空时有效）
    @State var addAccountNewSlot: Int32 = -1
    @State var addAccountOriginalSlot: Int32 = -1

    // ic_change_phone_reuse_phone_entry_screen: "changenumber" 路由参数前缀（与
    // "addaccount:" 前缀同一解析点、互斥）——ChangePhonePage 换号流程复用本屏采集新号码，
    // 提交时改走 account.sendChangePhoneCode 而非登录 sendCode RPC 路径。
    @State var changeNumberMode: Bool = false

    // QA #5-UI: sendCode 请求代际计数器 —— 每次 submitPhoneNumber() 自增，用于让客户端
    // 超时看门狗和真实 sendCode 回调互相判断"我是否还是最新的那一次请求"，避免旧请求的
    // 看门狗在新请求已经成功/失败之后误触发（或反过来，超时已判定失败后迟到的成功回调
    // 又把 isLoading 拉回 true）。sendCode 本身无取消 API，用代际号做协作式忽略。
    @State var sendCodeRequestSeq: Int64 = 0

    // 子组件 @Prop 镜像字段（真机 hilog 实测根因，见下方 refreshDerivedState() 注释）：
    // SolidRoundedButton.enabled / PhoneInputComponent.countryCode|countryName 都是 @Prop，
    // 但调用点分别传入「函数调用返回值」（this.canSubmit()）和「嵌套字段访问」
    // （this.authVM.countryCode）。真机 hilog 实测两者都不会让子组件在依赖变化后重新
    // build()：canSubmit() 场景下父组件重新 build 但 SolidRoundedButton 的 build()/
    // isInteractive() 不再执行、@Prop enabled 停在构造时的初值；countryCode 场景下父组件
    // 用新值重新 build（authVM.countryCode 已是 +33），但 PhoneInputComponent.build() 干脆
    // 不会重新执行，UI 上仍显示旧国家。唯一在两个场景都被验证有效的传参形态是「调用点直接
    // 引用本组件自己的裸 @State 字段」（对照本文件历史修复：countryName/countryCode 从
    // getAuthViewModel() 内联调用改成 this.authVM 字段后，父组件自身的重渲染立刻恢复）。
    // 修复：把三个 @Prop 源都镜像进本组件自己的 @State 字段，每次 build() 用一个返回值被
    // UI 组件参数消费的普通函数（避免 D-116 build() 内裸语句限制）刷新，调用点只传镜像字段。
    @State var nextEnabled: Bool = false
    @State var displayCountryCode: String = "+86"
    @State var displayCountryName: String = "China mainland"

    // test_failed 返修（F4, diag-suite_auth_login-TC-0007.md）：+999 服务号在本地号为空时
    // 点击 Continue，源侧 addShakeAnimation() 让 countryCodeField/numberField 各做一次左右
    // 位移抖动（幅度 3pt / 时长 0.3s / 4 次 / 不衰减，无红色无文字）。鸿蒙侧无等价的
    // CAKeyframeAnimation 抖动 API（同 EmailLoginPage.emailShake / PasscodeInputFieldComponent
    // 已有先例的平台限制），按本项目既有惯例做单次归位式简化：@State 偏移量 + .translate(x:) +
    // .animation() 声明式补间，包在宿主 Row 上（同时覆盖两个输入框，不改 PhoneInputComponent.cj）。
    @State var phoneEntryShakeOffset: Float64 = 0.0

    // 插画常驻循环轻微摆动角度（对应 iOS AnimatedStickerNodeLocalFileSource("IntroPhone")
    // 循环播放动效；混合迁移用 ArkUI 属性动画近似替代 Lottie 循环动效）
    // -8°→8° 来回摆动，playMode: Alternate，iterations: -1（写法对齐 SplashPage page4 已验证模式）
    @State var phoneIconTiltAngle: Float32 = 0.0

    // fix/phone-illustration: 电话插画真实图片资源（rawfile/intro_phone.png 提取到沙箱后的
    // file:// 路径）。空串代表尚未提取成功，build() 侧据此判空回退，避免图片加载失败时留白。
    // 提取方式仿 SplashPage.extractIntroImages()/extractOne()：用 ResourceManager.getRawFileContent()
    // 运行时读取，禁止用 @rawfile() 宏（该宏在 CJ so 中会 SIGSEGV，见 SplashPage.cj:284-286 注释）。
    @State var imgIntroPhone: String = ""

    // QA #4-fix: 号码确认弹窗 —— 严格对齐 iOS PhoneConfirmationController
    // (AuthorizationSequencePhoneEntryControllerNode.swift:782+)：居中白色圆角卡片，
    // 压暗背景，卡片内容为「按国家分组格式化的大号粗体号码」+ 灰字说明 +
    // 「Edit」文字链 + 「Continue」实心全宽按钮竖排。
    // 用页面自身 @State 驱动的内联 Stack 叠加层实现（D-119 选项 2：
    // 内联 overlay/动画把状态字段和 @Builder 方法直接声明在父组件类中，
    // 不新建 @Component 实例——CustomDialogController 需要 @CustomDialog 宏 +
    // CustomView 绑定，本页更适合复用 PromptDialog.cj 已验证的「Stack 内联叠加层」范式）。
    @State var showConfirmDialog: Bool = false

    // Entering a phone number that already belongs to an authorized local account
    // is resolved locally before auth.sendCode, matching Telegram iOS. The keyboard
    // stays visible and the alert offers switching to that existing account.
    @State var showDuplicateAccountDialog: Bool = false
    @State var duplicateAccountSlot: Int32 = -1

    // 弹窗展示用的格式化号码（按国家分组加空格，如 "+44 7356 072 757"）
    @State var confirmDialogNumberText: String = ""

    // QA #6-fix: 手机号输入框控制器 —— 弹确认弹窗前主动调用 stopEditing() 收起软键盘
    // （对应 iOS PhoneConfirmationController 弹出前 numberField.resignFirstResponder()，
    // 确认弹窗为居中全屏压暗卡片，键盘不收起会遮挡卡片底部按钮）。
    // 非 @State：控制器本身不是可观察渲染状态，只是命令式句柄，写法对齐 CangjieUI
    // TextInputController 示例（普通 var 持有，跨 build() 复用同一实例）。
    var phoneInputController: TextInputController = TextInputController()

    // M4 返修（diag-suite_auth_login-TC-0006.md round2 修法1 / diag-suite_auth_login-TC-0008.md
    // round2 N-2）：号码框的 FocusControl 寻址 id，字面量对照
    // components/PhoneInputComponent.cj:192 `private let numberFieldId = "phone-input-number-field"`
    // （该常量当前是 private，组件文件本轮不可改——见 emitted_integration_contracts
    // [ic_phone_number_field_id_export]，待该契约落地后应改为消费组件导出的常量/取值方法，
    // 不再自持一份字面量）。
    private let phoneNumberFieldId: String = "phone-input-number-field"

    // M4 返修 round2（diag: auth_phone_entry_screen review round2 反证 onPageShow 假设不成立
    // 后的替代机制）：事件名字面量须与 entry/src/main/ets/pages/PhoneInputPage.ets 内
    // dispatchEvent(PHONE_INPUT_SHOWN_EVENT, ...) 逐字一致——本轮 scope 只允许改本文件与
    // 该 .ets 文件，interop.cj 不在 target_files 内，故不新增共享常量，两侧各自持有同一
    // 字面量，交叉引用见双方注释。
    private let phoneInputShownEvent: String = "auth.phoneInputPage.shown"

    // 混合迁移：首次渲染时经 takePending 解析 addAccount 上下文参数
    // 参数格式: "addaccount:<newSlot>:<origSlot>" (添加账号路径)
    // 空串或无参数 → 正常首次登录路径，完全不影响原有行为
    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        // M4 返修 round2：注册一次性的跨语言事件订阅（D6「生命周期按需通信」范式，对照
        // app/AppStartup.cj:133 subscribe(EVT_FOREGROUND_CHANGED, ...) 的既有先例）——
        // ArkTS 侧 PhoneInputPage.ets 的 NavDestinationAttribute.onShown 在本 NavDestination
        // 每次（重新）成为栈内可见节点时（含冷启动 + 从 CountrySelectionPage 返回的三条
        // 路径：选中/取消/系统返回，见该文件 onShown 处的完整证据注释）经 dispatchEvent
        // 转发到这里，调用 activateInput() 恢复焦点。ensureLoaded() 本身由 this.loaded
        // 守卫只执行一次，故本订阅注册也只会发生一次，不会随重复触发的 .onAppear 累积
        // 重复 handler。
        subscribe(this.phoneInputShownEvent, { _payload: String => this.activateInput() })
        let rawParam = takePending("PhoneInputPage")
        if (rawParam.size > 0 && rawParam.startsWith("addaccount:")) {
            this.addAccountContext = rawParam
            let (ns, os) = this.parseAddAccountParam(rawParam)
            this.addAccountNewSlot = ns
            this.addAccountOriginalSlot = os
            Hilog.info(0, "CjTelegram", "[PhoneInputPage] addAccount context detected: newSlot=${this.addAccountNewSlot} origSlot=${this.addAccountOriginalSlot}")
        } else if (rawParam == "changenumber") {
            // ic_change_phone_reuse_phone_entry_screen: ChangePhonePage 换号入口，与
            // addaccount 路径互斥（同一个 takePending 槽位，二选一）。
            this.changeNumberMode = true
            Hilog.info(0, "CjTelegram", "[PhoneInputPage] changeNumber mode detected")
        }
        // 触发插画常驻循环摆动动效：改变状态值使 .animation() 修饰符检测到变化并启动循环动效
        // （与 SplashPage.ensureLoaded() 触发 page4 动效的写法一致）
        this.phoneIconTiltAngle = 8.0
        this.extractPhoneIllustration()
    }

    /**
     * 将 rawfile/intro_phone.png 提取到 filesDir/intro/ 目录（沙箱路径）。
     *
     * 使用 ResourceManager.getRawFileContent() 运行时读取——避免在 @Component build() 中
     * 使用 @rawfile() 宏（该宏生成 __GenerateResource__ native 符号调用，在 CJ so 加载时
     * 无法解析，导致 SIGSEGV，见 SplashPage.cj:284-286 同一坑的详细注释）。
     * 复用 AppBundleUtils.readRawFileBytes() 全局 helper 读取字节，写法对齐
     * 资源已经提取过时直接复用沙箱文件；首次提取放到后台任务，避免
     * rawfile 读取和写盘占用 UI 线程。这些工作与页面的首帧展示没有数据依赖。
     */
    private func extractPhoneIllustration(): Unit {
        match (getGlobalAbilityContext()) {
            case None => return
            case Some(ctx) =>
                let filesDir = ctx.filesDir
                let introDir = filesDir + "/intro"
                try { FileIo.mkdir(introDir) } catch (_e: Exception) {}
                let name = "intro_phone.png"
                let targetPath = introDir + "/" + name
                try {
                    if (FileIo.access(targetPath) && FileIo.stat(targetPath).size > 0) {
                        this.imgIntroPhone = "file://" + targetPath
                        return
                    }
                } catch (_e: Exception) {}
                let _ = spawn {
                    match (readRawFileBytes(name)) {
                        case None =>
                            Hilog.info(0, "CjTelegram",
                                "[PhoneInputPage] extractPhoneIllustration: readRawFileBytes returned None for ${name}")
                        case Some(data) =>
                            if (data.size > 0) {
                                try {
                                    let file = FileIo.open(targetPath, mode: 0o1101)
                                    let _ = FileIo.write(file.fd, data)
                                    FileIo.close(file)
                                    launch { this.imgIntroPhone = "file://" + targetPath }
                                } catch (_e: Exception) {
                                    Hilog.info(0, "CjTelegram",
                                        "[PhoneInputPage] extractPhoneIllustration: write failed for ${name}")
                                }
                            }
                    }
                }
        }
    }

    // M4 返修（diag-suite_auth_login-TC-0006.md round2「修法1」/
    // diag-suite_auth_login-TC-0008.md round2 N-2/D4）：源侧 `activateInput()` 的仓颉对应，
    // 对照 AuthorizationSequencePhoneEntryControllerNode.swift:672-674
    // （`phoneAndCountryNode.phoneInputNode.numberField.textField.becomeFirstResponder()`）。
    // 必须幂等（源侧本来就在四个调用点各自独立调用，重复请求同一 id 的焦点无副作用），
    // 因此不加"只执行一次"守卫；号码确认覆盖层展示期间不会触发本方法所在的任何调用点
    // （见下方两个调用点各自的说明），故不需要专门的 showConfirmDialog 早退判断。
    private func activateInput(): Unit {
        FocusControl.requestFocus(this.phoneNumberFieldId)
    }

    // M4 返修（同上两份报告）：源侧 `viewWillAppear`/`viewDidAppear` 双保险语义
    // （AuthorizationSequencePhoneEntryController.swift:326-348）与
    // `completeWithCountryCode`/`dismissed` 两条国家选择返回闭包（Controller:180/184）
    // 共四个调用点，都只做一件事——重新调用 `activateInput()`。
    //
    // M4 返修 round2（如实改写，纠正上一轮注释的过度确信）：上一轮此处曾写"本工程实测该
    // 钩子存在故不采用"备选方案，措辞暗示做过设备实测——实际并未做过针对返回路径的设备
    // 实测，依据仅是 cangjie-kb 对 SDK 文档字面的静态阅读 + 冷启动首帧的观感，从未验证过
    // "从 CountrySelectionPage 返回"这条路径是否真的触发 onPageShow()。Reviewer 已用
    // SDK 声明文件反证：~/.cangjie-sdk/6.1/cangjie/api/modules/linux_ohos_aarch64_cjnative/
    // ohos/ohos.arkui.component.custom_view.cj.d:48-57 字面限定该回调"仅对 @Entry 装饰的
    // 组件生效"，而本页宿主 PhoneInputPageShell（entry/src/main/ets/pages/PhoneInputPage.ets）
    // 是普通 @Component、未声明 @Entry，与该限定不匹配；本工程 MIGRATION_ARCHITECTURE.md
    // §7/§4 D6 也明写混合仓颉页"无完整生命周期""不全量转发"；全仓颉源码此前无
    // onPageShow/onPageHide 既有先例可佐证。
    //
    // 因此本覆写点**不再**作为覆盖三条返回路径的机制——真正的机制改为 ArkTS 侧
    // NavDestinationAttribute.onShown 显式转发（entry/src/main/ets/pages/PhoneInputPage.ets
    // 的 .onShown(...) + ensureLoaded() 内的 subscribe(this.phoneInputShownEvent, ...)）。
    // 保留本覆写仅作冗余：若它在某些场景下确实触发，重复调用幂等的 activateInput() 无副作用；
    // 是否真的触发，本工程未经验证，不作为任何路径的依赖前提。
    protected override func onPageShow(): Unit {
        this.activateInput()
    }

    // 每次 build() 入口刷新三个 @Prop 镜像字段；返回值被零高度 Text 消费以满足 D-116
    // （build() 方法体只能是 UI 组件表达式，不能直接写裸语句/let）。
    private func refreshDerivedState(): String {
        this.nextEnabled = this.canSubmit()
        this.displayCountryCode = this.authVM.countryCode
        this.displayCountryName = this.authVM.countryName
        return ""
    }

    func build() {
        Stack(alignContent: Alignment.Bottom) {
            Column {
                // 零高度探针：仅用于让 refreshDerivedState() 的返回值被 UI 组件参数消费，
                // 从而绕过 build() 内不能写裸语句的限制（不可省略，删掉后镜像字段不会刷新）。
                Text(this.refreshDerivedState()).height(0).fontSize(0)
                Column {
                    // 电话插画（对应 iOS AuthorizationSequencePhoneEntryControllerNode 的
                    // animationNode: AnimatedStickerNodeLocalFileSource(name: "IntroPhone")）。
                    // fix/phone-illustration: 换成从 iOS 渲染帧裁出的真实 PNG（rawfile/intro_phone.png
                    // 运行时提取到沙箱，Image(file://...) 渲染），替换此前的系统 ☎️ emoji 占位——
                    // emoji 依赖设备字体渲染、非 1:1 保真。保留原有的常驻循环轻微摆动动效近似
                    // Lottie 循环播放观感（写法对齐 SplashPage page4 已验证的单节点单 .animation() 模式）；
                    // imgIntroPhone 为空（提取失败兜底）时不渲染，避免加载失败留白裂图。
                    Column {
                        if (this.imgIntroPhone.size > 0) {
                            Image(this.imgIntroPhone)
                                .width(88)
                                .height(88)
                                .objectFit(ImageFit.Contain)
                        }
                    }
                    .width(88)
                    .height(88)
                    .margin(top: 24, bottom: 8)
                    .rotate(angle: this.phoneIconTiltAngle)
                    .animation(AnimateParam(
                        duration: 900,
                        curve: Curve.EaseInOut,
                        iterations: -1,
                        playMode: PlayMode.Alternate
                    ))

                    // 标题
                    Text(trSource("Your Phone"))
                        .fontSize(24)
                        .fontWeight(FontWeight.Bold)
                        .margin(top: 16, bottom: 8)

                    Text("Please confirm your country code and enter your phone number.")
                        .fontSize(14)
                        .fontColor(0x999999)
                        .margin(bottom: 30)
                        .padding(left: 24, right: 24)
                        .textAlign(TextAlign.Center)

                    // 可复用电话输入组件（国家选择 + 手机号，自动格式化）
                    //
                    // M4 对照（diag-suite_auth_login-TC-0007.md 第4轮「M4」第1点，源侧
                    // customFormatter = { number in lookupCountryIdByNumber(number, ...)?.0.code }，
                    // …ControllerNode.swift:196-202）：未显式传入 customFormatter 参数，沿用
                    // components/PhoneInputComponent.cj:153-158 的默认实现——
                    // `{ number => lookupCountryIdByNumber(number)?.code }`，与源侧逐字等价（同一
                    // utils/CountryData.lookupCountryIdByNumber 权威表、同一"后写覆盖"最长前缀
                    // 匹配语义）。在本文件显式重复注入同一个闭包不会改变任何可观察行为，只会
                    // 制造一份将来容易与组件默认值漂移的重复实现，故选择不注入；若组件默认值
                    // 未来变化，应视为组件自身职责变化，本页不应该也不需要跟着改。
                    Row {
                        PhoneInputComponent(
                            countryCode: this.displayCountryCode,
                            countryName: this.displayCountryName,
                            phoneNumber: this.phoneNumber,
                            controller: this.phoneInputController,
                            onCountryTap: { =>
                                routerPush("CountrySelectionPage")
                            },
                            // M4 对照（diag-suite_auth_login-TC-0007.md 第4轮「M4」第3点，源侧
                            // numberTextUpdated 闭包 …ControllerNode.swift:134-146）：源侧先调
                            // processNumberChange(number) 用"完整号码"重新查表刷新标题与 mask，
                            // 再算 isServiceNumber、最后调 hasNumberUpdated(...)。本页把这三件事
                            // 拆到三处已有机制里，不在本回调内重复实现：
                            // 1) 标题/mask 刷新——PhoneInputComponent.customFormatter 默认实现
                            //    （M3 默认值，本页未覆盖，理由见下方 PhoneInputComponent 调用点
                            //    说明）已经是对"完整拼接文本"调用 lookupCountryIdByNumber，
                            //    updateNumber() 步骤 f 因此在完整号码的识别结果变化时才会触发
                            //    onCountryCodeChanged（先于本回调，M3 step f→g 顺序），标题已由
                            //    applyCountryCodeUpdate() 刷新在前；mask 由组件按同一张权威表
                            //    自行重算，本页不持有 mask 状态，无需另行处理。
                            // 2) isServiceNumber——isServiceNumberCode() 已按"完整号码前缀"
                            //    语义读 authVM.countryCode，无需在本回调内重复计算。
                            // 3) hasNumberUpdated(...)——本页用响应式 canSubmit()/nextEnabled
                            //    （每次 build() 经 refreshDerivedState() 重算，见该方法注释）达到
                            //    与命令式 notify 相同的最终态，不需要在这里显式调用。
                            onPhoneNumberChanged: { value: String =>
                                this.phoneNumber = value
                            },
                            // test_failed 返修（F2 / TC-0504 B 组）：区号段可编辑后，组件内部
                            // 识别出新国家时通过这个回调把 (拨号代码, 国家名) 写回 AuthViewModel
                            // 单例 SSOT——refreshDerivedState() 下一帧会把它镜像回
                            // displayCountryCode/displayCountryName，driving 组件的 @Prop 重渲染
                            // （D-125 已验证的裸 @State 字段回路，本调用点未变）。
                            //
                            // M4 返修（diag-suite_auth_login-TC-0007.md 第4轮「M4 —— 宿主接线」）：
                            // 对照源侧 countryCodeUpdated 闭包
                            // AuthorizationSequencePhoneEntryControllerNode.swift:147-192。回调签名
                            // 是 (dialDigits, countryName)——PhoneInputComponent.updateNumber() 步骤 f
                            // （M3，components/PhoneInputComponent.cj:503-508）在识别与未识别两种
                            // 情况下都会调用，未识别时 name 为空串。**删除**旧的「name 为空就不覆盖
                            // countryName」前向兼容写法——它正是 TC-0007 报告 C2(a)/C3 陈旧标题
                            // 的直接成因（该前向兼容写于 M3 组件引擎尚未统一通知语义之前；组件
                            // round7 收口后未识别分支已与识别分支走同一条通知路径，不再需要旧
                            // 写法兜底，继续保留反而制造陈旧标题）。三分支逻辑见 applyCountryCodeUpdate()。
                            onCountryCodeChanged: { dialDigits: String, name: String =>
                                this.applyCountryCodeUpdate(dialDigits, name)
                            }
                        )
                    }
                    .width(100.percent)
                    .margin(bottom: 8)
                    // F4：+999 服务号点击 Continue 时的错误抖动落点（见 phoneEntryShakeOffset 注释）。
                    .translate(x: this.phoneEntryShakeOffset)
                    .animation(AnimateParam(duration: 80, curve: Curve.Linear))

                    // 错误信息显示
                    if (this.authVM.errorMessage.size > 0) {
                        Text(this.authVM.errorMessage)
                            .fontSize(13)
                            .fontColor(0xFF3B30)
                            .margin(top: 12, left: 24, right: 24)
                            .width(100.percent)
                    }

                    // P2-011 澄清（对照 iOS AuthorizationSequencePhoneEntryControllerNode.swift 源码实测）：
                    // ContactSyncNode 在 iOS 首次登录路径下 `isHidden = true`，只有 hasOtherAccounts==true
                    // （即"添加账号"流程，已登录过至少一个账号）时才在 containerLayoutUpdated() 里插入显示。
                    // 首次登录 phone-entry 屏幕不展示该开关；本页复用 addAccountContext 是否非空
                    // 作为 hasOtherAccounts 的等价判定，与 iOS 语义一致。
                    if (this.addAccountContext.size > 0) {
                        Row {
                            Text(trSource("Sync Contacts"))
                                .fontSize(15)
                                .fontColor(0x000000)
                                .layoutWeight(1)
                            Toggle(ToggleType.Switch, isOn: this.syncContacts)
                                .onChange({ val: Bool =>
                                    this.syncContacts = val
                                })
                        }
                        .width(100.percent)
                        .padding(left: 24, right: 24)
                        .alignItems(VerticalAlign.Center)
                        .margin(top: 8, bottom: 4)

                    }

                    // 连接状态提示
                    if (this.authVM.authState == "initializing") {
                        Text("正在连接 Telegram 服务器...")
                            .fontSize(13)
                            .fontColor(0x999999)
                            .margin(top: 12)
                    }

                }
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0xFFFFFF)
                .alignItems(HorizontalAlign.Center)
                // 源侧的 layoutAuthorizationItems 会再扣除 proceedNode 的高度与底边距，
                // 使中央内容不会与独立贴底的 Continue 重叠。
                .padding(bottom: 80)
                // iOS layoutAuthorizationItems 把这组内容放在扣除键盘后的
                // 可用高度中弹性居中。键盘出现时容器变矮，内容连续上移；
                // 收起键盘后自然回到整页居中，不保留“压缩态”。
                .justifyContent(FlexAlign.Center)
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFFFFFF)
            // M4：冷启动首次挂载时 onPageShow() 是否先于/后于 onAppear 触发未经真机验证
            // （二者语义不同：onAppear 是节点挂载钩子，onPageShow 是页面级钩子），此处
            // 保留一次 activateInput() 调用作为双保险——该方法幂等，与 onPageShow() 重复
            // 调用无副作用，任一钩子先触发都能让号码框在首帧拿到焦点。
            .onAppear({ =>
                this.ensureLoaded()
                this.activateInput()
            })

            // 对齐 iOS proceedNode：Continue 不参与中央内容的排版，
            // 始终独立贴在当前可用区域底部（键盘出现时即键盘上方）。
            Column {
                SolidRoundedButton(
                    title: "Continue",
                    onClick: this.onNextClick,
                    loading: this.isLoading,
                    enabled: this.nextEnabled
                )
            }
            .width(100.percent)
            .padding(left: 24, right: 24, bottom: 24)

            if (this.addAccountContext.size > 0) {
                Text("×")
                    .fontSize(42).fontColor(0x000000)
                    .width(52).height(52).borderRadius(26)
                    .backgroundColor(0xF5F5F7).textAlign(TextAlign.Center)
                    .position(x: 16, y: 16)
                    .onClick({ _ => this.cancelAddAccountFlow() })
            }

            // QA #4-fix: 号码确认弹窗覆盖层（严格对齐 iOS PhoneConfirmationController）
            if (this.showConfirmDialog) {
                this.buildPhoneConfirmOverlay()
            }
            if (this.showDuplicateAccountDialog) {
                this.buildDuplicateAccountOverlay()
            }
        }
        .width(100.percent)
        .height(100.percent)
    }

    // ==================== 号码确认弹窗（iOS PhoneConfirmationController 1:1）====================
    //
    // 对照 AuthorizationSequencePhoneEntryControllerNode.swift:782-1122：
    //   - dimNode: 黑色半透明 0.4 alpha 压暗背景，点击=取消（对应本页 Edit 行为）
    //   - backgroundNode: 白色圆角卡片（iOS cornerRadius 42，居中）
    //   - codeTargetNode + phoneTargetNode: 拼接后的号码，34pt（窄屏 30pt）粗体等宽数字
    //   - textNode: "Is this the correct number?"（Login_PhoneNumberConfirmation），17pt regular 居中
    //   - cancelButton: "Edit"（Login_Edit），19pt regular 文字链，itemAccentColor
    //   - proceedNode: "Continue"（Login_Continue），SolidRoundedButton 全宽实心圆角，height 50
    //   竖向堆叠顺序：号码 → 说明文字 → Edit 链 → Continue 按钮（与本 overlay 一致）
    @Builder
    private func buildPhoneConfirmOverlay() {
        Stack(alignContent: Alignment.Center) {
            // 压暗背景（对应 dimNode alpha 0.4），点击=取消（对应 iOS dimTapped → cancelPressed）
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0x66000000)
                .onClick({ _ => this.dismissConfirmDialog() })

            // 居中白色圆角卡片（对应 backgroundNode，iOS cornerRadius 42）
            Column {
                // 号码：大号粗体等宽数字，按国家分组加空格（对应 codeTargetNode + phoneTargetNode）
                Text(this.confirmDialogNumberText)
                    .fontSize(30)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
                    .textAlign(TextAlign.Center)
                    .margin(top: 30, bottom: 20)

                // 说明文字（对应 textNode strings.Login_PhoneNumberConfirmation）
                Text(trSource("Is this the correct number?"))
                    .fontSize(17)
                    .fontColor(0x000000)
                    .textAlign(TextAlign.Center)
                    .margin(bottom: 25)

                // Edit 文字链（对应 cancelButton strings.Login_Edit，itemAccentColor）
                Text(trSource("Edit"))
                    .fontSize(19)
                    .fontColor(0x317AFF)
                    .textAlign(TextAlign.Center)
                    .margin(bottom: 18)
                    .onClick({ _ => this.dismissConfirmDialog() })

                // Continue 实心全宽按钮（对应 proceedNode SolidRoundedButtonNode height 50）
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
            // 阻止卡片点击冒泡到遮障层（避免点卡片区域触发取消）
            .onClick({ _ => () })
        }
        .width(100.percent)
        .height(100.percent)
    }

    // 展示号码确认弹窗：格式化按国家分组的号码 → 写入 @State → 打开弹窗
    private func openConfirmDialog(formattedNumber: String): Unit {
        this.confirmDialogNumberText = formattedNumber
        this.showConfirmDialog = true
    }

    // 关闭弹窗（对应 iOS Edit / dimTapped → cancelPressed，仅退出确认态，不清空已输入号码）
    private func dismissConfirmDialog(): Unit {
        this.showConfirmDialog = false
        Hilog.info(0, "CjTelegram", "[PhoneInputPage] phone confirmation dismissed (Edit)")
    }

    // Continue：关闭弹窗并真正提交号码（对应 iOS confirmationController.proceed）
    private func confirmPhoneNumber(): Unit {
        this.showConfirmDialog = false
        this.submitPhoneNumber()
    }

    @Builder
    private func buildDuplicateAccountOverlay() {
        Stack(alignContent: Alignment.Center) {
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0x66000000)

            Column {
                Text(trSource("This account is already logged in from this app."))
                    .fontSize(17)
                    .fontColor(0x000000)
                    .textAlign(TextAlign.Start)
                    .width(100.percent)
                    .padding(left: 22, right: 22, top: 22, bottom: 20)

                Row {
                    Text(trSource("Switch"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0x000000)
                        .height(46)
                        .layoutWeight(1)
                        .borderRadius(23)
                        .backgroundColor(0xE4E7EB)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.switchToDuplicateAccount() })

                    Text(trSource("OK"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xFFFFFF)
                        .height(46)
                        .layoutWeight(1)
                        .borderRadius(23)
                        .backgroundColor(0x0A84FF)
                        .textAlign(TextAlign.Center)
                        .margin(left: 8)
                        .onClick({ _ => this.showDuplicateAccountDialog = false })
                }
                .width(100.percent)
                .padding(left: 14, right: 14, bottom: 14)
            }
            .width(84.percent)
            .borderRadius(24)
            .backgroundColor(0xF7F7F9)
            .translate(y: -24.0)
            .onClick({ _ => () })
        }
        .width(100.percent)
        .height(100.percent)
        .zIndex(200)
    }

    private func findExistingAccountSlot(fullPhone: String): Int32 {
        let normalized = removePlus(cleanPhoneNumber(fullPhone))
        if (normalized.size == 0) { return -1 }
        let accounts = getTelegramCoreAccountManagerService().getLoggedInAccounts()
        for (account in accounts) {
            if (account.slot != this.addAccountNewSlot &&
                removePlus(cleanPhoneNumber(account.phone)) == normalized) {
                return account.slot
            }
        }
        return -1
    }

    private func switchToDuplicateAccount(): Unit {
        let targetSlot = this.duplicateAccountSlot
        let newSlot = this.addAccountNewSlot
        let originalSlot = this.addAccountOriginalSlot
        this.showDuplicateAccountDialog = false
        if (targetSlot < 0 || newSlot < 0 || originalSlot < 0) { return }
        let _ = spawn {
            let coreSvc = getTelegramCore_AccountManagerService()
            coreSvc.cancelAddAccount(newSlot, originalSlot)
            if (targetSlot != originalSlot) {
                let _ = coreSvc.switchAccount(targetSlot)
            }
            let _ = getRealAuthService().tryRestoreLogin()
            launch {
                signalAccountSwitched(false)
                routerReplace("MainTabPage", "{}")
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
                Hilog.info(0, "CjTelegram", "[PhoneInputPage] parseAddAccountParam failed: ${e}")
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
            Hilog.info(0, "CjTelegram", "[PhoneInputPage] cancelAddAccount: newSlot=${newSlot} origSlot=${origSlot}")
            let _ = spawn {
                let svc = getTelegramCore_AccountManagerService()
                svc.cancelAddAccount(newSlot, origSlot)
                Hilog.info(0, "CjTelegram", "[PhoneInputPage] cancelAddAccount complete: restored origSlot=${origSlot}")
            }
        }
        this.authVM.isLoggedIn = true
        this.authVM.authState = AUTH_STATE_READY
        this.authVM.errorMessage = ""
        routerPop()
    }

    // R1 返修（diag-suite_auth_login-TC-0007.md 第5轮「R1」）：逐段移植源侧带分支的
    // codeAndNumber getter（PhoneInputNode.swift:133-146）第三元的取值逻辑——
    //   分支一（区号框文本 <=4 rune 且可解析为整数，对照 `text.count <= 4, let number =
    //   Int(removePlus(text))`）：返回 cleanPhoneNumber(本地号码)；
    //   分支二（否则，对照 else 分支）：返回 cleanPhoneNumber(区号框文本 + 本地号码文本)——
    //   两者拼接后传给 cleanPhoneNumber（removePlus=false 默认），结果保留最靠前的一个 "+"，
    //   因此区号框超过 4 字符且本地号码为空时（如 "+99999"）第三元仍然非空。
    // 上一轮（第4轮 M4）留下的 this.phoneNumber.size==0 扁平判据只在分支一下与源侧等价，
    // 在分支二下与源侧分歧：源侧此时第三元非空 ⇒ 弹确认层，旧判据仍判"空" ⇒ 只抖动
    // （第5轮报告 N1，反例即 C2 探针 "+99999"）。M4 注释里"该等价性已在全部可达输入组合下
    // 核实"的断言据此撤销。
    private func currentLocalNumber(): String {
        let codeText = this.authVM.countryCode
        let digits = removePlus(codeText)
        var isNumeric = digits.size > 0
        if (isNumeric) {
            for (r in digits.toRuneArray()) {
                let code = UInt32(r)
                if (code < 48 || code > 57) {
                    isNumeric = false
                    break
                }
            }
        }
        if (codeText.toRuneArray().size <= 4 && isNumeric) {
            return cleanPhoneNumber(this.phoneNumber)
        }
        return cleanPhoneNumber(codeText + this.phoneNumber)
    }

    // SolidRoundedButton onClick 回调（显式 Unit 返回类型，避免宏类型推断把 spawn{} 末尾推断为 Future）
    // QA #4: 对齐 iOS AuthorizationSequencePhoneEntryController.swift:420-428
    // （strings.Login_PhoneNumberConfirmation）—— 点 Continue 后先弹确认对话框展示
    // 格式化后的完整号码，用户确认后才真正调用 submitPhoneNumber() 发码。
    private func onNextClick(): Unit {
        // R1 返修：判据改用 currentLocalNumber()（源侧 codeAndNumber.2 的移植），取代旧的
        // this.phoneNumber.size==0 扁平判据（见上方 currentLocalNumber() 注释）——本地号为空
        // 则只触感+抖动，不弹确认层；非空则弹确认层。对照源侧 nextPressed()
        // （AuthorizationSequencePhoneEntryController.swift:384-434，:388/:429-431）
        // `let (_, _, number) = codeAndNumber; if !number.isEmpty { … } else { hapticFeedback
        // .error(); animateError() }`。
        if (this.currentLocalNumber().size == 0) {
            this.triggerPhoneEntryShake()
            return
        }
        if (this.addAccountContext.size > 0) {
            let fullPhone = normalizePhoneNumber(this.authVM.countryCode + " " + this.phoneNumber)
            let existingSlot = this.findExistingAccountSlot(fullPhone)
            if (existingSlot >= 0) {
                this.duplicateAccountSlot = existingSlot
                this.showDuplicateAccountDialog = true
                Hilog.info(0, "CjTelegram", "[PhoneInputPage] Existing account phone matched slot=${existingSlot}; sendCode skipped")
                return
            }
        }
        this.showPhoneConfirmationDialog()
    }

    // M4 返修（diag-suite_auth_login-TC-0007.md 第4轮「M4」第2点）：对照源侧
    // countryCodeUpdated 闭包 AuthorizationSequencePhoneEntryControllerNode.swift:147-192。
    //
    // 本页只从 PhoneInputComponent.onCountryCodeChanged 收到 (dialDigits, name) 二元组
    // （M3 updateNumber 步骤 f，components/PhoneInputComponent.cj:503-508），不掌握源侧
    // preferredCountryIdForCode / iso2 身份随行信息（那部分移植属 auth_phone_input_node 名下
    // components/PhoneInputComponent.cj 的另案缺口，diag-suite_auth_login-TC-0006.md round2
    // 「修法3」，本轮不改该文件）。源侧 branch1(processNumberChange 命中)/branch2(code+id 精确
    // 匹配)/branch3(先写胜兜底) 三条在本页因此收敛为同一处理——只要 name 非空即视为"已识别"，
    // 组件已用其内部查表给出确定名称；未来 PhoneInputComponent 完成"身份随行"移植后本页
    // 无需改动即可自动获得更精确的结果（本页只消费 name 字符串，不关心它来自哪张表）。
    // FT/888（源侧 :157-159/:170-172/:220-222 三处特例）在本页收敛为一处判断
    // （isAnonymousNumberCode），localizedName 覆盖为 Login_AnonymousNumbers（对照
    // strings.Login_AnonymousNumbers）。
    private func applyCountryCodeUpdate(dialDigits: String, name: String): Unit {
        // 无条件写回原始拨号代码（含未识别情形，如 "+999"/"+99999"）——isServiceNumberCode()
        // 与 canSubmit() 的 hasCountry 判定（isValidCountryCode）都依赖这里始终是最新值。
        this.authVM.countryCode = "+" + dialDigits
        if (name.size == 0) {
            // 未识别分支（源侧 :178-183 else）：一次做完三件事——
            // 1) hasCountry=false：本页不单独存布尔，canSubmit() 现算 isValidCountryCode()
            //    对未识别的 authVM.countryCode 恒返回 false，效果等价；
            // 2) 标题回落 "Country"（源 strings.Login_SelectCountry）；
            // 3) mask=nil：组件 placeholderText()/updateNumber 步骤 d 都用同一张
            //    lookupPatternByNumber(dialDigits) 现查——未识别的 dialDigits 查不到 pattern，
            //    组件下一帧重渲染时 mask 自然为空，本页无需另行清空。
            // 删除旧的「name 为空就不覆盖 countryName」前向兼容写法——它正是 TC-0007 报告
            // C2(a)/C3 陈旧标题的直接成因。
            this.authVM.countryName = "Country"
            return
        }
        if (this.isAnonymousNumberCode(dialDigits)) {
            this.authVM.countryName = "Anonymous Numbers"
        } else {
            this.authVM.countryName = name
        }
    }

    // M4 FT/888 特例：对照源侧三处 `if id == "FT"` / `if name == "FT"` 判断
    // （…ControllerNode.swift:157-159/:170-172/:220-222）。
    //
    // M4 返修 round2（顺手改，非阻塞项）：改用 lookupCanonicalCountryByCode——本函数只
    // 拿到裸 dialDigits（不含身份随行信息），属于"只知道拨号代码、要显示一个规范国家"
    // 场景，按 utils/CountryData.cj:824-834 的表选用指引应查"先写胜"表
    // lookupCanonicalCountryByCode，而不是留给 mask/customFormatter 调用点专用的
    // "后写覆盖"表 lookupCountryIdByNumber（M4 first round 曾用错表，见 featureX.json
    // review.required_fixes 该条 kb_cross_check，因 888/FT 在表中唯一无歧义而结果无害，
    // 但用错表正是 D1 类缺陷的成因，故仍按语义纠正）。"888" 在 PhoneCountries.txt 里是
    // 唯一一行（无同代码多国共用的消歧需求），两张表对此输入结果依旧一致。
    private func isAnonymousNumberCode(dialDigits: String): Bool {
        match (lookupCanonicalCountryByCode(dialDigits)) {
            case Some((iso2, _name)) => iso2 == "FT"
            case None => false
        }
    }

    // F4：完整号码是否以 "+999" 开头（源侧 isServiceNumber = number.hasPrefix("+999")）。
    // applyCountryCodeUpdate() 现在无条件把原始拨号代码（含未识别情形）写回
    // authVM.countryCode，因此该 startsWith 判据在识别/未识别两种情形下都能正确读到最新值
    // （全数字号码里 countryCode 恒是完整号码的前缀，两者 hasPrefix("+999") 等价）。
    private func isServiceNumberCode(): Bool {
        return this.authVM.countryCode.startsWith("+999")
    }

    // F4：+999 错误反馈——归位式简化抖动（同 EmailLoginPage.triggerEmailShake /
    // PasscodeInputFieldComponent 已验证先例），幅度对齐源侧 addShakeAnimation() 默认实参
    // 3.0pt，无红色、无文字提示，屏不跳转、不弹 alert。
    private func triggerPhoneEntryShake(): Unit {
        this.phoneEntryShakeOffset = 3.0
        spawn {
            sleep(Duration.millisecond * 300)
            launch {
                this.phoneEntryShakeOffset = 0.0
            }
        }
    }

    // QA #4-fix: 展示手机号确认对话框 —— 严格对齐 iOS PhoneConfirmationController：
    // 自定义居中卡片（buildPhoneConfirmOverlay），号码按国家分组格式化展示
    // （如英国 +44 → "+44 7356 072 757"，通过 utils/PhoneNumberFormatter.cj 的
    // formatPhoneNumber 按国家 pattern 分组，而非 normalizePhoneNumber 去空格后的裸数字串）。
    // 原用原生 showAlertDialog 展示未格式化号码 + 横排 Edit/Continue 与 iOS 差异明显，已废弃。
    private func showPhoneConfirmationDialog(): Unit {
        // QA #6-fix: 弹窗前主动收起软键盘（对应 iOS resignFirstResponder），
        // 确认弹窗是居中压暗全屏卡片，键盘不收起会挡住卡片底部的 Continue 按钮。
        this.phoneInputController.stopEditing()
        let formatted = formatPhoneNumber(this.authVM.countryCode, this.phoneNumber)
        this.openConfirmDialog(formatted)
    }

    // test_failed 返修（F4, diag-suite_auth_login-TC-0007.md E1-E3/E5/E8）：对齐源侧
    // …ControllerNode 的 hasNumberUpdated → proceedNode.isEnabled 判定表——
    // 已识别国家 && 本地号非空 → 启用；已识别国家 && 本地号为空 → 禁用；国家不可识别 → 禁用；
    // 完整号码以 "+999" 开头 → 启用（绕过国家识别，唯一例外）。
    // authState==AUTH_STATE_WAIT_PHONE && !isLoading 是目标侧独有的网络就绪门（UB-0011 已登记），
    // 本轮不动，继续作为额外必要条件叠加在判定表之上。
    private func canSubmit(): Bool {
        let hasCountry = isValidCountryCode(this.authVM.countryCode)
        let isServiceNumber = this.isServiceNumberCode()
        let gateOpen = if (isServiceNumber) {
            true
        } else if (hasCountry) {
            this.phoneNumber.size > 0
        } else {
            false
        }
        // ic_change_phone_reuse_phone_entry_screen: changeNumber 模式下账号已登录态
        // （authState 恒非 AUTH_STATE_WAIT_PHONE），不受登录流网络就绪门约束。
        let loginFlowReady = this.addAccountContext.size > 0 || this.changeNumberMode || this.authVM.authState == AUTH_STATE_WAIT_PHONE
        return gateOpen && loginFlowReady && !this.isLoading
    }

    private func submitPhoneNumber() {
        let fullPhone = normalizePhoneNumber(this.authVM.countryCode + " " + this.phoneNumber)

        // ic_change_phone_reuse_phone_entry_screen: 换号模式走 account.sendChangePhoneCode
        // （AuthViewModel.sendChangePhoneCode，与 pages/ChangePhonePage.cj 既有换号流程同一条
        // RPC 路径），不进入下方登录 sendCode 分支。成功后 authVM.changePhoneStep 被置 2、
        // changePhoneCodeHash 写入共享单例，供换号流程下一步（校验验证码）消费；本页职责到此
        // 为止，routerPop() 交回调用方。
        if (this.changeNumberMode) {
            this.isLoading = true
            this.authVM.changePhoneError = ""
            this.authVM.sendChangePhoneCode(fullPhone)
            spawn {
                // sendChangePhoneCode 本身异步经 launch{} 回写 authVM；这里轮询等待完成，
                // 与本文件其余 spawn/launch 回调范式一致（无跨线程共享可变闭包变量）。
                var waited: Int64 = 0
                while (this.authVM.isLoading && waited < 28000) {
                    sleep(Duration.millisecond * 100)
                    waited += 100
                }
                launch {
                    this.isLoading = false
                    if (this.authVM.changePhoneCodeHash.size > 0) {
                        Hilog.info(0, "CjTelegram", "[PhoneInputPage] changeNumber sendChangePhoneCode ok, returning to caller")
                        routerPop()
                    } else if (this.authVM.changePhoneError.size > 0) {
                        this.authVM.errorMessage = this.mapPhoneError(this.authVM.changePhoneError)
                    } else {
                        this.authVM.errorMessage = "连接超时，请检查网络后重试"
                    }
                }
            }
            return
        }

        // 更新共享手机号（供 CodeInputPage 显示）
        this.authVM.phoneNumber = this.authVM.countryCode + " " + this.phoneNumber

        // 显示加载状态
        this.isLoading = true
        this.authVM.errorMessage = ""

        // P2-318f: 捕获 addAccount 上下文供 spawn 闭包使用
        let capturedAddCtx = this.addAccountContext

        // QA #5-UI: 新请求代际号。真实 sendCode 走 MTProto 握手 + RPC，可能阻塞近 150s
        // （鉴权密钥协商 + 多级超时重试），本页没有底层可取消的 API，只能用代际号协作式
        // 忽略过期回调 —— 客户端侧看门狗到点后若代际号未变（仍是本次请求）才判定超时，
        // 真实回调落地时也检查代际号是否还是自己发起的这次，防止旧请求的回调在新请求
        // 已经开始后才姗姗来迟地覆盖状态。
        this.sendCodeRequestSeq = this.sendCodeRequestSeq + 1
        let mySeq = this.sendCodeRequestSeq

        // QA #5-UI: 客户端侧超时看门狗 —— sendCode 可能因深层 MTProto 握手/RPC 超时而
        // 长时间阻塞（真机实测可达 ~150s），若 28s 内还没有产生导航或错误，视为连接超时，
        // 主动收起 spinner 并给出可理解的错误提示，避免 UI 无限转圈看起来像卡死。
        // 真正的深层可达性/握手问题超出本任务范围（需要真机复现），此处只做客户端超时兜底。
        spawn {
            sleep(Duration.second * 28)
            launch {
                if (this.sendCodeRequestSeq == mySeq && this.isLoading) {
                    this.isLoading = false
                    this.authVM.errorMessage = "连接超时，请检查网络后重试"
                    Hilog.info(0, "CjTelegram", "[PhoneInputPage] sendCode client-side timeout (seq=${mySeq})")
                }
            }
        }

        spawn {
            try {
                let authService = getRealAuthService()
                authService.sendCode(fullPhone)

                let state = authService.getState()
                let lastErr = authService.getLastError()
                launch {
                    // 若代际号已变（用户已触发过新一轮请求）或本次已被超时看门狗判定失败
                    // 并收起 spinner（isLoading==false），这条迟到的真实回调不再生效。
                    if (this.sendCodeRequestSeq != mySeq) {
                        Hilog.info(0, "CjTelegram", "[PhoneInputPage] sendCode callback stale (seq=${mySeq}, current=${this.sendCodeRequestSeq}), ignored")
                    } else {
                        match (state) {
                            case RealAuthState.WaitingCode =>
                                this.isLoading = false
                                this.authVM.authState = AUTH_STATE_WAIT_CODE
                                // P2-318f: 传递 addAccount 上下文给 CodeInputPage
                                // 正常登录时 capturedAddCtx="" → CodeInputPage 走原路径
                                routerPush("CodeInputPage", capturedAddCtx)
                                Hilog.info(0, "CjTelegram", "[PhoneInputPage] Navigated to CodeInputPage (addCtx='${capturedAddCtx}')")
                            case RealAuthState.WaitingSetupEmail =>
                                // R1 (TC-0015 返修): 对位 iOS AuthorizationSequenceController.swift:1289-1292
                                // 的 emailSetupRequired 建栈分支 —— 服务端还没真的发出手机验证码，先要求
                                // 设置登录邮箱。此前该态被压平进 WaitingCode，把用户送进一个永远等不到
                                // 验证码的 CodeInputPage；现在正确路由到 EmailLoginPage。
                                this.isLoading = false
                                this.authVM.authState = AUTH_STATE_WAIT_EMAIL_SETUP
                                routerPush("EmailLoginPage", capturedAddCtx)
                                Hilog.info(0, "CjTelegram", "[PhoneInputPage] Email setup required, navigating to EmailLoginPage (addCtx='${capturedAddCtx}')")
                            case _ =>
                                this.isLoading = false
                                if (lastErr.size > 0) {
                                    this.authVM.errorMessage = this.mapPhoneError(lastErr)
                                } else {
                                    this.authVM.errorMessage = "发送验证码失败，请重试"
                                }
                                Hilog.info(0, "CjTelegram", "[PhoneInputPage] sendCode failed, error: ${lastErr}")
                        }
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[PhoneInputPage] sendCode exception: ${e}")
                launch {
                    if (this.sendCodeRequestSeq == mySeq) {
                        this.isLoading = false
                        this.authVM.errorMessage = "发送验证码失败: ${e}"
                    }
                }
            }
        }
    }

    private func mapPhoneError(err: String): String {
        if (err.startsWith("FLOOD_WAIT_")) {
            return "Too many attempts. Please try again later."
        }
        if (err == "PHONE_NUMBER_INVALID") {
            return "Invalid phone number. Please check and try again."
        }
        if (err.startsWith("PHONE_MIGRATE_") || err.startsWith("NETWORK_MIGRATE_")) {
            return "Connecting to server..."
        }
        return err
    }
}
