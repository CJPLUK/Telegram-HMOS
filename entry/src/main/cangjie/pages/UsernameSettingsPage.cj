package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.time.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.components.{
    ItemListSectionHeader,
    ItemListInputRow,
    ItemListInputType,
    ItemListActivityFootnote,
    ITEM_LIST_TEXT_PRIMARY
}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.interop.{callArkAsync, SHARE_LINK}
import ohos.resource.__GenerateResource__
import ohos.resource.AppResource
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * Username Settings Page (J4)（混合工程迁移版）
 * Set or change Telegram username.
 * P3-2: Real API integration with account.checkUsername + account.updateUsername
 * P2-RETRO-settings-b: hand-rolled Cancel/Done nav buttons → ProgressNavButton atoms
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - pageStack.pop() → routerPop()
 *
 * TC-0082/TC-0086 返修轮修复：原 recipe 惯例"aboutToAppear 实逻辑 → ensureLoaded()
 * + .onAppear"在本页引入回归——components/ItemListComponents.cj 的 ItemListInputRow.text
 * 改为 `@Prop` 后（同批次 ItemListToggleRow.isOn 同型修复，见 dev_pattern.md D-125），
 * 首帧显示依赖 `this.username` 在首次 build() 前已有值；.onAppear 晚于首次 build()，会让
 * 输入框首帧渲染空白。username 的读取本身是同步的（无网络/spawn），故整体提前到
 * aboutToAppear()（参照 pages/ArchiveSettingsPage.cj 同批次同型修法），不再经
 * ensureLoaded()/.onAppear/`loaded` 一次性守卫（aboutToAppear() 本身按框架语义只在组件
 * 首次创建时触发一次，守卫已无必要）。
 *
 * diag-suite_settings_root-TC-0081.md 整页重构（§6-A + §6-B）：
 *  - §A：骨架/控件层按源 UsernameSetupController.swift(mode:.account) 重画——modal sheet
 *    呈现（router.cj:96 isModalRoute() 新增本页）、分区头 "USERNAME"、输入行标题改回
 *    "Username"（删 "@" 前缀误用）、占位文案清空、输入框内清除按钮（ItemListInputRow
 *    新增 showClearButton）、说明文字改真富文本(粗体分段+可点 t.me 链接)、导航栏
 *    Cancel/Done 由纯文字换成图形图标(资源 Phase 2 补建，见 resources/base/media/
 *    username_nav_ic_close.svg / username_nav_ic_done.svg)。
 *  - §B：isDoneEnabled() 删除自造的 hasChanges 门（源侧只看校验状态一个门）；新增裸
 *    @State 镜像字段 doneEnabled 让值真正流到按钮（原 `enabled: this.isDoneEnabled()`
 *    传函数调用返回值给子组件无装饰器 var 会冻结在首帧，dev_pattern.md D-125；本轮改为
 *    导航栏在本页 build() 内直接画图标 + 读裸字段 this.doneEnabled，绕开该冻结面）。
 *  - 业务逻辑（校验/去抖/保存/checkAddressNameFormat 清洗管线）原样保留，只重新接线。
 */
@HybridComponentEntry
@Component
public class UsernameSettingsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    private let usernameInputId: String = "username_settings_input"
    @State var username: String = ""
    @State var originalUsername: String = ""
    @State var availabilityStatus: String = ""
    @State var statusColor: UInt32 = 0x8E8E93
    @State var isSaving: Bool = false
    @State var isChecking: Bool = false
    @State var isUsernameValid: Bool = false
    @State var checkVersion: Int64 = 0
    // diag-suite_settings_root-TC-0081.md §6-B2：裸 @State 镜像字段，导航栏直接读它
    // （不再经函数调用/子组件无装饰器参数），每次影响 isDoneEnabled() 结果的状态变化
    // 处都同步调用 `this.doneEnabled = this.isDoneEnabled()`。初值 true 对位源侧
    // "未编辑过 ⇒ 可点"（矩阵第 1 行）。
    @State var doneEnabled: Bool = true

    // TC-0082/TC-0086 返修轮修复：同步读取 authStorage 提前到 aboutToAppear()（首次 build()
    // 之前），配合 ItemListInputRow.text 改 @Prop（见本类头注释 + dev_pattern.md D-125）。
    // 无 spawn/网络调用，读取本身是同步的，不需要 ensureLoaded()/.onAppear 的守卫模式。
    public override func aboutToAppear(): Unit {
        let authStorage = getAuthStorage()
        match (authStorage.getUserData()) {
            case Some(userData) =>
                this.username = userData.username
                this.originalUsername = userData.username
                if (userData.username.size > 0) {
                    this.availabilityStatus = "This is your current username"
                    this.statusColor = 0x8E8E93
                    this.isUsernameValid = true
                }
            case None => ()
        }
        this.doneEnabled = this.isDoneEnabled()
    }

    // TC-0082 R3 修法 F1-b：目标侧自造的 validateUsernameFormat（阈值 5、>32 上限、
    // "必须字母开头"、禁止连续下划线四条自造规则）整体删除，改调
    // services/PeersService.cj 的 checkAddressNameFormat（逐行照抄源侧 AddressNames.swift）。
    private func formatErrorMessage(err: AddressNameFormatError): String {
        match (err) {
            case AddressNameFormatError.TooShort => "A username must have at least 5 characters."
            case AddressNameFormatError.StartsWithDigit => "Sorry, a username can't start with a number."
            case AddressNameFormatError.StartsWithUnderscore => "Sorry, a username can't start with an underscore."
            case AddressNameFormatError.EndsWithUnderscore => "Sorry, a username can't end with an underscore."
            case AddressNameFormatError.InvalidCharacters => "Sorry, this username is invalid."
        }
    }

    // TC-0082 R2/F2-b: ItemListInputRow(inputType: Username) 的 onChange 目标——
    // value 已经过该原子的清洗管线(折叠/空格转下划线/非法字符丢弃)。
    private func handleUsernameInputChange(value: String): Unit {
        this.username = value
        this.checkVersion += 1

        if (value.size == 0) {
            this.availabilityStatus = ""
            this.statusColor = 0x8E8E93
            this.isUsernameValid = true
            this.isChecking = false
            this.doneEnabled = this.isDoneEnabled()
            return
        }

        match (checkAddressNameFormat(value)) {
            case Some(err) =>
                this.availabilityStatus = this.formatErrorMessage(err)
                this.statusColor = 0xFF3B30
                this.isUsernameValid = false
                // TC-0090 round3 F2-b：不是 checking 态，复位指示器真值。
                this.isChecking = false
                this.doneEnabled = this.isDoneEnabled()
                return
            case None => ()
        }

        if (value == this.originalUsername) {
            this.availabilityStatus = "This is your current username"
            this.statusColor = 0x8E8E93
            this.isUsernameValid = true
            // TC-0090 round3 F2-b：不是 checking 态，复位指示器真值。
            this.isChecking = false
            this.doneEnabled = this.isDoneEnabled()
            return
        }

        this.availabilityStatus = "Checking username..."
        this.statusColor = 0x8E8E93
        this.isUsernameValid = false
        // TC-0090 round3 F2-b：与 checking 文案同一拍置位（而不是等 500ms 去抖后到
        // checkUsernameAvailability() 里才置真）——对位源侧 UsernameSetupController.swift
        // `case .checking: textColor = .generic; displayActivity = true` 的同步赋值，
        // 消除"文案已现、转圈未现"的写死 500ms 窗口。去抖本身不动。
        this.isChecking = true
        this.doneEnabled = this.isDoneEnabled()
        this.scheduleAvailabilityCheck(this.checkVersion)
    }

    private func scheduleAvailabilityCheck(version: Int64) {
        spawn {
            sleep(Duration.millisecond * 500)
            let stillCurrent = this.checkVersion == version
            if (stillCurrent) {
                launch { this.checkUsernameAvailability() }
            }
        }
    }

    // TC-0082 R3 修法 F1-b 点 3：结果映射改为源侧四态(Available/Taken/Invalid/PurchaseAvailable)，
    // 删除目标侧自造的 "Error checking availability" / "Invalid username format" 两态——
    // 异常/未知一律并入 Invalid（对齐 AddressNames.swift:72-74 的 else → .invalid）。
    private func checkUsernameAvailability() {
        let nameCopy = this.username
        if (nameCopy.size == 0) {
            // TC-0090 round3 F2-b：早退路径同样复位指示器真值。
            this.isChecking = false
            this.doneEnabled = this.isDoneEnabled()
            return
        }

        if (nameCopy == this.originalUsername) {
            this.availabilityStatus = "This is your current username"
            this.statusColor = 0x8E8E93
            this.isUsernameValid = true
            this.isChecking = false
            this.doneEnabled = this.isDoneEnabled()
            return
        }

        this.isChecking = true
        spawn {
            let result = getPeersService().checkUsernameAvailabilityDetailed(nameCopy)
            var status = ""
            var color: UInt32 = 0x8E8E93
            var valid = false
            match (result) {
                case AddressNameAvailability.Available =>
                    status = "${nameCopy} is available."
                    color = 0x34C759
                    valid = true
                case AddressNameAvailability.Taken =>
                    status = "Sorry, this username is already taken."
                    color = 0xFF3B30
                    valid = false
                case AddressNameAvailability.PurchaseAvailable =>
                    // 源侧 Username.UsernamePurchaseAvailable 正文(markdown 已去除格式符号，
                    // 本页无 markdown/链接渲染能力，保留可读文字部分)
                    status = "This username is already taken. However, it is currently available for purchase."
                    color = 0x8E8E93
                    valid = false
                case AddressNameAvailability.Invalid =>
                    status = "Sorry, this username is invalid."
                    color = 0xFF3B30
                    valid = false
            }
            let finalStatus = status
            let finalColor = color
            let finalValid = valid
            launch {
                this.availabilityStatus = finalStatus
                this.statusColor = finalColor
                this.isUsernameValid = finalValid
                this.isChecking = false
                this.doneEnabled = this.isDoneEnabled()
            }
        }
    }

    private func saveUsername() {
        if (this.isSaving) {
            return
        }

        let nameCopy = this.username

        if (nameCopy == this.originalUsername) {
            routerPop()
            return
        }

        if (nameCopy.size > 0 && !this.isUsernameValid) {
            return
        }

        this.isSaving = true
        this.doneEnabled = this.isDoneEnabled()
        Hilog.info(0, "CjTelegram", "[Username] Saving username...")

        spawn {
            var errStatus = ""
            var needPop = false
            try {
                let client = getMTProtoClient()
                let req = AccountUpdateUsername()
                req.username = nameCopy
                let responseData = client.sendRequest(req.toBytes())

                if (responseData.size >= 4) {
                    let deser = TLDeserializer(responseData)
                    let ctor = deser.readUInt32()

                    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                        let errCode = deser.readInt32()
                        let errMsg = deser.readString()
                        Hilog.info(0, "CjTelegram", "[Username] RPC Error saving: ${errCode} - ${errMsg}")

                        if (errMsg.contains("USERNAME_INVALID")) {
                            errStatus = "Invalid username format"
                        } else if (errMsg.contains("USERNAME_OCCUPIED")) {
                            errStatus = "This username is already taken"
                        } else if (errMsg.contains("USERNAME_NOT_MODIFIED")) {
                            Hilog.info(0, "CjTelegram", "[Username] Username not modified, treating as success")
                            needPop = true
                        } else {
                            errStatus = "Failed to save: ${errMsg}"
                        }
                    } else {
                        Hilog.info(0, "CjTelegram", "[Username] Username updated successfully")
                        let authStorage = getAuthStorage()
                        match (authStorage.getUserData()) {
                            case Some(userData) =>
                                userData.username = nameCopy
                                authStorage.saveUserData(userData)
                                getRealAuthService().applyLocalProfile(
                                    userData.firstName,
                                    userData.lastName,
                                    nameCopy
                                )
                            case None => ()
                        }
                        needPop = true
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[Username] Save error: ${e}")
                errStatus = "Save failed, please try again"
            }
            let finalErrStatus = errStatus
            let finalNeedPop = needPop
            launch {
                if (finalErrStatus.size > 0) {
                    this.availabilityStatus = finalErrStatus
                    this.statusColor = 0xFF3B30
                    this.isUsernameValid = false
                }
                this.isSaving = false
                this.doneEnabled = this.isDoneEnabled()
                if (finalNeedPop) {
                    routerPop()
                }
            }
        }
    }

    // diag-suite_settings_root-TC-0081.md §6-B1：只以校验状态为唯一判据，逐行对位源
    // UsernameSetupController.swift:554-567：无校验状态(未编辑过/已清空/回原值，三者
    // 均把 isUsernameValid 置 true) ⇒ 可点；available ⇒ 可点；其余(checking/invalid/
    // taken/purchaseAvailable，均把 isUsernameValid 置 false) ⇒ 禁用。删除了目标侧
    // 自造的 hasChanges 门(源侧没有这一条)；getHasChanges() 已无其它调用点，一并删除。
    private func isDoneEnabled(): Bool {
        if (this.isSaving) { return false }
        if (this.username.size > 0 && !this.isUsernameValid) { return false }
        return true
    }

    private func onCancelClick(): Unit {
        routerPop()
    }

    private func onDoneClick(): Unit {
        this.saveUsername()
    }

    // diag-suite_settings_root-TC-0081.md §4 表#6：源侧 shareLink(:467-495) —— 当前值
    // 为空时什么都不做；非空时走系统分享，分享完成后源侧弹 linkCopied UndoOverlay，
    // 本页降级为分享失败时才提示(与 InviteMembersSheet.cj:178-194 shareLink() 同一条
    // 真实反转链路 callArkAsync(SHARE_LINK,...) → ShareLinkImpl.ets systemShare，
    // 失败时诚实降级复制到剪贴板，不新造第二套分享通路)。
    private func onLinkTap(): Unit {
        if (this.username.size == 0) { return }
        let link = "https://t.me/${this.username}"
        let argJson = "{\"url\":\"${usernamePageJsonEscape(link)}\",\"title\":\"Username\"}"
        callArkAsync(SHARE_LINK, argJson, { res =>
            let ok = usernamePageJsonBool(res, "ok")
            Hilog.info(0, "CjTelegram", "[UsernameSettingsPage] shareLink ok=${ok}")
            if (!ok) {
                setClipboardText(link)
            }
        })
    }

    // diag-suite_settings_root-TC-0081.md §6-A5：源侧 Username_Help 富文本(粗体 **Telegram**
    // /**a-z**/**0-9**/**5**) + "\n\n" + Username_LinkHint(提示句 + 可点 t.me 链接，空值时
    // 也显示 "https://t.me/")。字面量按 Localizable.strings:938/1217 源码逐字抄写
    // (diag-language-pack-override-impact-audit.md：以源码为准，不以参照设备实测文案为准)。
    @Builder
    func buildHelpText() {
        Text() {
            Span("You can choose a username on ")
                .fontColor(0x8E8E93)
            Span(trSource("Telegram"))
                .fontColor(ITEM_LIST_TEXT_PRIMARY)
                .fontWeight(FontWeight.Medium)
            Span(". If you do, other people will be able to find you by this username and contact you without knowing your phone number.\n\nYou can use ")
                .fontColor(0x8E8E93)
            Span("a-z")
                .fontColor(ITEM_LIST_TEXT_PRIMARY)
                .fontWeight(FontWeight.Medium)
            Span(trSource(", "))
                .fontColor(0x8E8E93)
            Span("0-9")
                .fontColor(ITEM_LIST_TEXT_PRIMARY)
                .fontWeight(FontWeight.Medium)
            Span(" and underscores. Minimum length is ")
                .fontColor(0x8E8E93)
            Span("5")
                .fontColor(ITEM_LIST_TEXT_PRIMARY)
                .fontWeight(FontWeight.Medium)
            Span(" characters.\n\nThis link opens a chat with you in Telegram:\n")
                .fontColor(0x8E8E93)
            Span("https://t.me/${this.username}")
                .fontColor(0x007AFF)
                .onClick({ _ => this.onLinkTap() })
        }
        .fontSize(13)
        .lineHeight(18)
        // diag-suite_settings_root-TC-0081-round6.md F-4+F-6：ItemListTextItem.swift:162-164
        // topInset/bottomInset=7.0、leftInset=15.0+params.leftInset(16)=31；本页脚注与输入行
        // 同 section ⇒ ItemListItem.swift:157-158 的 topInset 外层量为 0，总纵距即 7。水平量
        // 改用 padding(不是 margin)——D-165：width(100.percent) 子节点在默认居中的 Column 下
        // 叠加水平 margin 会摞出溢出盒、被居中重新摆放，可见左缘偏成 (left-right)/2；对称
        // 16/16 时正好顶到屏幕边(0vp)，与本轮实测的偏差现象逐位吻合。
        .margin(top: 7, bottom: 7)
        .padding(left: 31, right: 31)
        .width(100.percent)
    }

    // diag-suite_settings_root-TC-0081-round2-dynamic.md §6-G1/G2：呈现为 modal sheet 的
    // 顶部圆角与 10vp 缩进已迁到 ArkTS 壳(ets/pages/UsernameSettingsPage.ets 的
    // NavDestinationMode.DIALOG + CJHybridComponent 承载层)，本页内不再自绘任何模态几何——
    // round1 的页根 justifyContent(FlexAlign.End) + 内层 borderRadius/clip 只是在 STANDARD
    // 模式(下层 destination 不渲染)下够不着的近似，已按动态归因结论删除。本页只负责铺满
    // 内容，遮罩由 ets/pages/Home.ets 的 CustomTransition dim 驱动。router/router.cj:96
    // isModalRoute() 已含本页；ets/router/CustomTransition.ets:11 MODAL_ROUTES 的同名登记
    // 不在本 feature allowlist 内(owner shell_settings_misc)，已 emit
    // ic_username_settings_modal_route 契约。
    public func build() {
        Column {
            Column {
                // ── Navigation bar：图标按钮(§6-A/A-8)，不再用 ProgressNavButton(D-125 冻结面) ──
                Row {
                    // diag-suite_settings_root-TC-0081-round3.md F-1：裸 22×22 Image 补
                    // 32vp 圆形底片，照抄仓内已批 ProxySettingsPage.cj:buildLeftNavControl
                    // 的形状（Stack + borderRadius=边长/2 + backgroundColor）；onClick 移到
                    // 整枚圆盘上（源侧命中区是整枚按钮，不是字形）。
                    Stack(alignContent: Alignment.Center) {
                        Image(@r(app.media.username_nav_ic_close))
                            .width(18)
                            .height(18)
                            .fillColor(0x000000)
                    }
                    .width(32)
                    .height(32)
                    .borderRadius(16)
                    // diag-suite_settings_root-TC-0081-round4.md F-3：底片改白，对位源侧
                    // GlassBackgroundView 的 .panel tint（浅色主题 UIColor(white:1.0, alpha:0.7)）
                    // ⇒「灰页上的白盘」。round3 F-1 落地时误把 ProxySettingsPage 的取色一并照
                    // 抄成页面灰，此处更正为白。
                    .backgroundColor(0xFFFFFF)
                    .onClick({ _ => this.onCancelClick() })

                    Blank().layoutWeight(1)
                    Text(trSource("Username"))
                        .fontSize(18)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0x000000)
                    Blank().layoutWeight(1)

                    // F-2：右上 Done 补实心蓝圆底 + 前景反色。颜色取值不新选——就是原三目
                    // 里的 0x007AFF/0xC7C7CC，只是从前景移到底片；前景恒为白，禁用态不改
                    // 前景色（否则得到「灰底灰勾」不可读态）。isSaving 分支同样包底片，
                    // 对齐禁用/启用两态的容器尺寸，避免三态间跳动。
                    if (this.isSaving) {
                        Stack(alignContent: Alignment.Center) {
                            LoadingProgress().width(18).height(18).color(0xFFFFFF)
                        }
                        .width(32)
                        .height(32)
                        .borderRadius(16)
                        .backgroundColor(0x007AFF)
                    } else {
                        Stack(alignContent: Alignment.Center) {
                            Image(@r(app.media.username_nav_ic_done))
                                .width(18)
                                .height(18)
                                .fillColor(0xFFFFFF)
                        }
                        .width(32)
                        .height(32)
                        .borderRadius(16)
                        .backgroundColor(if (this.doneEnabled) { 0x007AFF } else { 0xC7C7CC })
                        .onClick({ _ => if (this.doneEnabled) { this.onDoneClick() } })
                    }
                }
                .width(100.percent)
                .height(56.0)
                .padding(left: 16, right: 16)
                // diag-suite_settings_root-TC-0081-round4.md F-2：导航行改与页面/Scroll 同底色，
                // 消除 y=367px 处的硬分界（源侧初始态 alpha=0，随滚动渐显是另一独立面，未在
                // 本轮实现，见 known_issues）。
                .backgroundColor(0xF2F2F7)
                .alignItems(VerticalAlign.Center)

                Scroll {
                    Column {
                        ItemListSectionHeader(title: "USERNAME", topPad: 24)

                        // §6-A2/A3/A4：左固定标题改回 "Username"(删 "@" 前缀误用)，
                        // 占位文案清空，接管清洗管线不变，新增输入框内清除按钮。
                        Column {
                            ItemListInputRow(
                                title: "Username",
                                inputId: this.usernameInputId,
                                text: this.username,
                                placeholder: "",
                                inputType: ItemListInputType.Username,
                                onChange: this.handleUsernameInputChange,
                                showClearButton: true
                            )
                        }
                        .backgroundColor(0xFFFFFF)
                        // diag-suite_settings_root-TC-0081-round6.md F-1：
                        // PresentationResourcesItemList.swift:392 glass ? 26.0 : 11.0，
                        // 本页 systemStyle: .glass ⇒ 26，不是旧的整页重构前常量 10。
                        .borderRadius(26)
                        .margin(left: 16, right: 16)
                        .onAppear({ => FocusControl.requestFocus(this.usernameInputId) })

                        // diag-suite_settings_root-TC-0090.md round3 F2-a：裸 Text + 独立
                        // Checking 行合并为共享条目 ItemListActivityFootnote(已在
                        // components/ItemListComponents.cj:186 落地)，对位源侧
                        // ItemListActivityTextItem。三个具名参数须传裸 @State 字段(D-125)。
                        if (this.availabilityStatus.size > 0) {
                            ItemListActivityFootnote(
                                text: this.availabilityStatus,
                                textColor: this.statusColor,
                                displayActivity: this.isChecking
                            )
                        }

                        this.buildHelpText()
                    }
                    .width(100.percent)
                }
                // diag-suite_settings_root-TC-0081-round4.md F-1：Scroll 的通用 align 默认
                // Alignment.Center，短内容被垂直居中；同型先例 pages/ProxySettingsPage.cj 已批
                // .align(Alignment.Top)，源侧 ItemListController 的 ListView 短内容永远顶对齐。
                .align(Alignment.Top)
                .layoutWeight(1)
                .backgroundColor(0xF2F2F7)
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xF2F2F7)
            .padding(bottom: getSafeAreaBottom())
        }
        .width(100.percent)
        .height(100.percent)
    }

    /* ════════════════════════════════════════════════════════════════════
     * 历史留痕（diag-suite_settings_root-TC-0081.md §6-A 整页重构前的旧视图，
     * verdict=reconstruct；按 ui-page-reconstruct/SKILL.md Phase 4.1 整体注释保留，
     * 不删文件、不在活跃路径参与渲染）：
     *
     * public func build_OLD() {
     *     Column {
     *         // ── Navigation bar with ProgressNavButton atoms ──
     *         Row {
     *             // Cancel button (left)
     *             Row {
     *                 ProgressNavButton(
     *                     title: "Cancel",
     *                     onClick: this.onCancelClick,
     *                     loading: false,
     *                     enabled: true
     *                 )
     *             }
     *             Blank().layoutWeight(1)
     *             Text(trSource("Username"))
     *                 .fontSize(18)
     *                 .fontWeight(FontWeight.Bold)
     *                 .fontColor(0x000000)
     *             Blank().layoutWeight(1)
     *             // Done button (right)
     *             Row {
     *                 ProgressNavButton(
     *                     title: "Done",
     *                     onClick: this.onDoneClick,
     *                     loading: this.isSaving,
     *                     enabled: this.isDoneEnabled()
     *                 )
     *             }
     *         }
     *         .width(100.percent)
     *         .height(56)
     *         .padding(left: 16, right: 16)
     *         .backgroundColor(0xFFFFFF)
     *         .alignItems(VerticalAlign.Center)
     *
     *         Scroll {
     *             Column {
     *                 ItemListSectionHeader(title: "Username", topPad: 24)
     *
     *                 Column {
     *                     ItemListInputRow(
     *                         title: "@",
     *                         inputId: this.usernameInputId,
     *                         text: this.username,
     *                         placeholder: trSource("username"),
     *                         inputType: ItemListInputType.Username,
     *                         onChange: this.handleUsernameInputChange
     *                     )
     *                 }
     *                 .backgroundColor(0xFFFFFF)
     *                 .borderRadius(10)
     *                 .margin(left: 16, right: 16)
     *                 .onAppear({ => FocusControl.requestFocus(this.usernameInputId) })
     *
     *                 if (this.availabilityStatus.size > 0) {
     *                     ItemListActivityFootnote(
     *                         text: this.availabilityStatus,
     *                         textColor: this.statusColor,
     *                         displayActivity: this.isChecking
     *                     )
     *                 }
     *
     *                 Text("You can choose a username on Telegram. If you do, people will be able to find you by this username and contact you without needing your phone number.\n\nYou can use a-z, 0-9 and underscores. Minimum length is 5 characters.")
     *                     .fontSize(13)
     *                     .fontColor(0x8E8E93)
     *                     .margin(left: 16, right: 16, top: 24)
     *                     .width(100.percent)
     *
     *                 if (this.username.size > 0) {
     *                     Text("t.me/${this.username}")
     *                         .fontSize(15)
     *                         .fontColor(0x007AFF)
     *                         .margin(left: 16, top: 16)
     *                         .width(100.percent)
     *                 }
     *             }
     *         }
     *         .layoutWeight(1)
     *         .backgroundColor(0xF2F2F7)
     *     }
     *     .width(100.percent)
     *     .height(100.percent)
     *     .backgroundColor(0xF2F2F7)
     * }
     * ════════════════════════════════════════════════════════════════════ */
}

// 本页专用极简 JSON 字段读取(与 pages/InviteMembersSheet.cj jsonBoolFieldInvite/
// jsonEscapeInvite、pages/EditProfilePage.cj editProfileJsonBool 同一手写风格；各调用点各自
//持有一份文件本地小工具，不跨文件耦合)。
private func usernamePageJsonBool(json: String, key: String): Bool {
    let needle = "\"${key}\""
    match (json.indexOf(needle)) {
        case Some(index) =>
            let tail = json[(index + needle.size)..json.size]
            match (tail.indexOf("true")) {
                case Some(trueIndex) =>
                    match (tail.indexOf("false")) {
                        case Some(falseIndex) => return trueIndex < falseIndex
                        case None => return true
                    }
                case None => return false
            }
        case None => return false
    }
}

private func usernamePageJsonEscape(s: String): String {
    var result = ""
    for (ch in s.runes()) {
        if (ch == r'"') {
            result += "\\\""
        } else if (ch == r'\\') {
            result += "\\\\"
        } else {
            result += ch.toString()
        }
    }
    return result
}
