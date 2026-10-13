package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import ohos_app_cangjie_entry.core.storage.trOr
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.core.mtproto.ChatResponse
import std.collection.ArrayList
import std.sync.*
import std.time.*
import kit.CoreFileKit.*
import ohos_app_cangjie_entry.components.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.utils.{parsePhoneNumber, formatPhoneNumber}
import ohos_app_cangjie_entry.core.services.getTelegramCore_AccountManagerService
import ohos_app_cangjie_entry.app.{initAccountSwitchBridge, signalAccountSwitched, getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.viewmodels.*
import ohos_app_cangjie_entry.interop.*
import ohos.resource.__GenerateResource__
import ohos.resource.AppResource

/**
 * 编辑个人资料页面（P2-141 rebuild）（混合工程迁移版）
 *
 * 对照 iOS EditSettingsController / EditProfileController。
 * 功能:
 * - 编辑名字、姓氏 (account.updateProfile)
 * - 编辑 Bio 简介（限长 70 字，初始从 users.getFullUser 回填）
 * - 编辑用户名（account.checkUsername 可用性检查 + account.updateUsername）
 * - 头像更换（选图 / 拍照 / 删除，PhotoPicker + FileUploadService）
 * - 查看手机号（只读）
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容（内部 Stack）
 *  - pageStack.pop() → routerPop()（取消 / 保存后返回）
 *  - pushPathByName("EmojiStatusPickerPage","") → routerPush("EmojiStatusPickerPage")
 *  - aboutToAppear 有实逻辑（加载资料）→ ensureLoaded()，根 Stack .onAppear 触发
 *  - 源页 hideTitleBar(true)，故 ArkTS 壳 hideTitleBar(true)
 *
 * 防死状态：ensureLoaded 异步加载当前 first_name/last_name/username/bio，
 *           回填进输入框，保存时不会意外清空现有值。
 */
@HybridComponentEntry
@Component
public class EditProfilePage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 输入框绑定状态（已从 service 回填）
    @State var firstName: String = ""
    @State var lastName: String = ""
    @State var username: String = ""
    @State var bio: String = ""
    @State var phone: String = ""

    // 头像状态
    @State var avatarText: String = "U"
    @State var avatarLocalPath: String = ""
    @State var isUploadingPhoto: Bool = false
    @State var showPhotoOptions: Bool = false

    // 保存状态
    @State var isSaving: Bool = false
    @State var hasChanges: Bool = false

    // 用户名可用性检查状态
    @State var usernameStatus: String = ""
    @State var usernameStatusColor: UInt32 = 0x8E8E93
    @State var isCheckingUsername: Bool = false

    // 加载状态
    @State var isLoadingProfile: Bool = true
    @State var loaded: Bool = false

    // 源侧 Settings 编辑态底部的账号操作。
    @State var showLogoutDialog: Bool = false
    @State var isLoggingOut: Bool = false
    @State var accountActionMessage: String = ""
    @State var showBirthdayPicker: Bool = false
    @State var birthday: Option<BirthdayData> = Option<BirthdayData>.None
    @State var selectedBirthday: DateTime = DateTime.now()
    @State var isSavingBirthday: Bool = false
    // S7-48: personal channel (iOS PeerInfoSettingsItems.swift:480-495 ItemPeerPersonalChannel,
    // PeerInfoScreen.swift:4020-4052 editingOpenPersonalChannel → PeerSelectionScreen).
    @State var personalChannelId: Int64 = 0
    @State var personalChannelTitle: String = ""
    @State var personalChannelCandidates: ArrayList<ChatResponse> = ArrayList<ChatResponse>()
    @State var showPersonalChannelPicker: Bool = false
    // diag-suite_settings_root-TC-0074.md §4.5 F6：源侧 nameColor/effectiveProfileColor 均可空
    // （SyncCore_TelegramUser.swift:171 / PeerUtils.swift:363），"未设置过颜色"是独立于任何
    // 具体色号的语义。目标侧建模为 Option，None = 从未设置过。
    @State var profileColorIndex: Option<Int32> = Option<Int32>.None

    // 原始值（用于 hasChanges 检测）
    var originalFirstName: String = ""
    var originalLastName: String = ""
    var originalUsername: String = ""
    var originalBio: String = ""

    private func loadPersonalChannel(): Unit {
        let svc = getSettingsService()
        this.personalChannelId = svc.getPersonalChannelId()
        this.personalChannelTitle = svc.getPersonalChannelTitle()
        let _ = spawn {
            let candidates = getSettingsService().getPersonalChannelCandidates()
            launch { this.personalChannelCandidates = candidates }
        }
    }

    private func showsPersonalChannelRow(): Bool {
        return this.personalChannelId != 0 || !this.personalChannelCandidates.isEmpty()
    }

    private func personalChannelLabel(): String {
        if (this.personalChannelId != 0 && this.personalChannelTitle.size > 0) { return this.personalChannelTitle }
        return trSource("Add")
    }

    /** channel == None → Hide Channel. Toasts per PeerInfoScreen.swift:4035-4046. */
    private func selectPersonalChannel(channel: Option<ChatResponse>): Unit {
        this.showPersonalChannelPicker = false
        let previousId = this.personalChannelId
        var newId: Int64 = 0
        var accessHash: Int64 = 0
        var title = ""
        var username = ""
        var broadcast = true
        match (channel) {
            case Some(c) =>
                newId = c.id
                accessHash = c.accessHash
                title = c.title
                username = c.username
                broadcast = c.isBroadcast
            case None => ()
        }
        if (newId == previousId) { return }
        let toast = if (newId == 0) {
            "Personal channel removed."
        } else if (previousId != 0) {
            "Personal channel updated."
        } else {
            "Personal channel added."
        }
        let chosenId = newId
        let chosenHash = accessHash
        let chosenTitle = title
        let chosenUsername = username
        let chosenBroadcast = broadcast
        this.personalChannelId = chosenId
        this.personalChannelTitle = chosenTitle
        let _ = spawn {
            let ok = getSettingsService().updatePersonalChannel(chosenId, chosenHash)
            if (ok) {
                getSettingsService().savePersonalChannelInfo(chosenTitle, chosenUsername, chosenBroadcast)
            }
            launch {
                if (ok) {
                    showToast(toast)
                } else {
                    this.personalChannelId = previousId
                    this.personalChannelTitle = getSettingsService().getPersonalChannelTitle()
                    this.accountActionMessage = "Could not update personal channel. Please try again."
                }
            }
        }
    }

    @Builder
    func personalChannelPicker() {
        Column {
            Column { }
                .width(100.percent)
                .layoutWeight(1)
                .backgroundColor(0x66000000)
                .onClick({ _ => this.showPersonalChannelPicker = false })
            Column {
                Text(trSource("Channel"))
                    .fontSize(17).fontWeight(FontWeight.Bold).fontColor(0x000000)
                    .margin(top: 16)
                Text(trSource("select your channel"))
                    .fontSize(13).fontColor(0x8E8E93)
                    .margin(top: 2, bottom: 12)
                Scroll {
                    Column {
                        if (this.personalChannelId != 0) {
                            Row {
                                Text(trSource("Hide Channel"))
                                    .fontSize(17).fontColor(0xFF3B30).layoutWeight(1)
                            }
                            .width(100.percent).height(52).padding(left: 16, right: 16)
                            .onClick({ _ => this.selectPersonalChannel(None<ChatResponse>) })
                            ItemListSeparator(leftInset: 16)
                        }
                        ForEach(this.personalChannelCandidates, itemGenerator: { c: ChatResponse, _i: Int64 =>
                            Row {
                                Column {
                                    Text(c.title).fontSize(17).fontColor(0x000000).maxLines(1)
                                        .textOverflow(TextOverflow.Ellipsis)
                                    if (c.participantsCount > 0) {
                                        Text("${c.participantsCount} subscribers").fontSize(14).fontColor(0x8E8E93)
                                            .margin(top: 2)
                                    } else if (c.username.size > 0) {
                                        Text("@${c.username}").fontSize(14).fontColor(0x8E8E93).margin(top: 2)
                                    }
                                }
                                .alignItems(HorizontalAlign.Start)
                                .layoutWeight(1)
                                if (c.id == this.personalChannelId) {
                                    Image(@r(app.media.media_ic_check)).width(20).height(20).fillColor(0x317AFF)
                                }
                            }
                            .width(100.percent).height(60).padding(left: 16, right: 16)
                            .onClick({ _ => this.selectPersonalChannel(Some(c)) })
                        })
                    }
                    .width(100.percent)
                }
                .constraintSize(maxHeight: 420)
                .backgroundColor(0xFFFFFF)
                .borderRadius(12)
                .margin(left: 16, right: 16, bottom: 12)
                Text(trSource("Cancel"))
                    .fontSize(17).fontWeight(FontWeight.Medium).fontColor(0x317AFF)
                    .height(50)
                    .onClick({ _ => this.showPersonalChannelPicker = false })
            }
            .width(100.percent)
            .backgroundColor(0xF2F2F7)
            .borderRadius(topLeft: 14, topRight: 14)
            .padding(bottom: getSafeAreaBottom())
            .alignItems(HorizontalAlign.Center)
        }
        .width(100.percent)
        .height(100.percent)
        .position(x: 0, y: 0)
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadPersonalChannel()
        // 第一步：从本地 storage 填充 name/username/phone（同步，即时）
        let authService = getRealAuthService()
        match (authService.getCurrentUser()) {
            case Some(user) =>
                this.firstName = user.firstName
                this.lastName = user.lastName
                this.username = user.username
                this.phone = user.phone
                if (this.phone.size == 0 || this.username.size == 0) {
                    match (getAuthStorage().getUserData()) {
                        case Some(stored) =>
                            if (this.phone.size == 0) { this.phone = stored.phone }
                            if (this.username.size == 0) { this.username = stored.username }
                        case None => ()
                    }
                }
                this.avatarText = if (user.firstName.size > 0) {
                    user.firstName.toRuneArray()[0].toString()
                } else {
                    "U"
                }
                this.originalFirstName = user.firstName
                this.originalLastName = user.lastName
                this.originalUsername = user.username
                this.birthday = getSettingsService().getCachedBirthday()
                match (this.birthday) {
                    case Some(value) =>
                        let birthdayYear = if (value.year > 0) { Int64(value.year) } else { DateTime.now().year }
                        this.selectedBirthday = DateTime.of(
                            year: birthdayYear,
                            month: Int64(value.month),
                            dayOfMonth: Int64(value.day)
                        )
                    case None => ()
                }
                // diag-suite_settings_root-TC-0074-round3.md 修法 C-1：ic_profile_header_color_index_option
                // 仍 pending（服务端色值/精确 profile-vs-name 区分留给该契约），但"是否曾经设置过"
                // 这一缺席语义已有现成载体——AuthStorage.getProfileNameColor() 键不存在时返回 -1
                // （对位源侧 PeerInfoSettingsItems.swift:459-477 的 nameColor/effectiveProfileColor
                // 均为 Optional、未设不 append）。哨兵 >= 0 才说明本机记录过一次选择。
                let storedColor = getAuthStorage().getProfileNameColor()
                this.profileColorIndex = if (storedColor >= 0) {
                    Some(getThemesEngineService().getProfileHeaderColorIndex())
                } else {
                    Option<Int32>.None
                }
                if (user.username.size > 0) {
                    this.usernameStatus = "Current username"
                    this.usernameStatusColor = 0x8E8E93
                }
                let userId = user.id
                // 第二步：异步加载 bio + 头像路径
                spawn {
                    // 加载 bio (users.getFullUser)
                    let bioText = getPeerInfoService().getUserFullInfo(userId).bio
                    // 加载头像缓存路径
                    let photoPath = getUserPhotoService().getUserPhotoPath(userId)
                    launch {
                        this.bio = bioText
                        this.originalBio = bioText
                        if (photoPath.size > 0) {
                            this.avatarLocalPath = photoPath
                        }
                        this.isLoadingProfile = false
                    }
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[EditProfilePage] No current user")
                this.isLoadingProfile = false
        }
    }

    // M-1(diag-suite_settings_root-TC-0083.md round2): 格式化手机号展示——复用工程内既有
    // 格式化路径(pages/SettingsPage.cj displayPhoneNumber() 同款用法)，不新写格式化函数。
    // 对位源侧 formatPhoneNumber(context:number:)。this.phone.size==0 时返回空串——源侧
    // user.phone.flatMap{...} ?? "" 同样是"空 label + 行仍可点"，不保留旧的假占位文案。
    private func displayPhoneNumberFormatted(): String {
        if (this.phone.size == 0) { return "" }
        let parsed = parsePhoneNumber("+${this.phone}")
        if (parsed.countryCode.size > 0 && parsed.nationalNumber.size > 0) {
            return formatPhoneNumber(parsed.countryCode, parsed.nationalNumber)
        }
        return "+${this.phone}"
    }

    private func birthdayLabel(): String {
        match (this.birthday) {
            // iOS PeerInfoSettingsItems.swift:410 stringForCompactBirthday ("15 Mar 1990").
            case Some(value) => return compactBirthdayString(value)
            case None => return "Add"
        }
    }

    private func profileColorHex(index: Int32): UInt32 {
        if (index == 0) { return 0xcc5049 }
        if (index == 1) { return 0xd67722 }
        if (index == 2) { return 0x955cdb }
        if (index == 3) { return 0x40a920 }
        if (index == 4) { return 0x309eba }
        if (index == 5) { return 0x368ad1 }
        return 0xc7508b
    }

    private func hasProfileColorSet(): Bool {
        match (this.profileColorIndex) {
            case Some(_) => true
            case None => false
        }
    }

    private func saveBirthday(): Unit {
        if (this.isSavingBirthday) { return }
        this.isSavingBirthday = true
        let chosen = this.selectedBirthday
        let value = BirthdayData()
        value.day = Int32(chosen.dayOfMonth)
        value.month = Int32(chosen.month.toInteger())
        value.year = Int32(chosen.year)
        let _ = spawn {
            let ok = getSettingsService().updateBirthday(Some(value))
            launch {
                this.isSavingBirthday = false
                if (ok) {
                    this.birthday = Some(value)
                    this.showBirthdayPicker = false
                } else {
                    this.accountActionMessage = ""
                    showToast(birthdayUpdateErrorText())
                }
            }
        }
    }

    private func beginAddAccount(): Unit {
        let accountService = getTelegramCore_AccountManagerService()
        if (accountService.isAddingAccount()) {
            this.accountActionMessage = "Account login already in progress"
            return
        }

        // S7-16: same flow as the Settings row / tab long-press (iOS PeerInfoScreenSettingsActions
        // .addAccount, PSA:212-249): account limit → Premium limit screen, else phone entry.
        getAuthViewModel().errorMessage = ""
        match (startSettingsAddAccountFlow(
            isAddingAccount: { => accountService.isAddingAccount() },
            repairDuplicateAuthorizedSlots: { => accountService.repairDuplicateAuthorizedSlots() },
            addAccount: { => accountService.addAccount() }
        )) {
            case SettingsAddAccountOutcome.Started(newSlot, originalSlot) =>
                this.accountActionMessage = ""
                Hilog.info(0, "CjTelegram", "[EditProfilePage] add account: newSlot=${newSlot} originalSlot=${originalSlot}")
            case SettingsAddAccountOutcome.AlreadyInProgress =>
                this.accountActionMessage = "Account login already in progress"
            case SettingsAddAccountOutcome.LimitPresented => this.accountActionMessage = ""
        }
    }

    private func confirmLogoutCurrentAccount(): Unit {
        if (this.isLoggingOut) { return }
        this.showLogoutDialog = false
        this.isLoggingOut = true
        this.accountActionMessage = ""

        let _ = spawn {
            try {
                let nextSlot = getTelegramCore_AccountManagerService().logoutCurrentAccountAndSelectNext()
                launch {
                    this.isLoggingOut = false
                    if (nextSlot >= 0) {
                        // 重建主页面，确保所有账号相关 service/UI 都以新 activeSlot 初始化；
                        // switchingDataTab 让重建后的主页面仍停留在 Settings。
                        initAccountSwitchBridge()
                        signalAccountSwitched(true)
                        getAuthViewModel().isLoggedIn = true
                        getAuthViewModel().authState = AUTH_STATE_READY
                        routerReplace("MainTabPage", "{}")
                    } else {
                        getAuthViewModel().isLoggedIn = false
                        getAuthViewModel().authState = AUTH_STATE_WAIT_PHONE
                        routerReplace("SplashPage", "{}")
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[EditProfilePage] logout current account failed: ${e}")
                launch {
                    this.isLoggingOut = false
                    this.accountActionMessage = "Could not log out. Please try again."
                }
            }
        }
    }

    // 检测是否有变更
    func checkChanges(): Unit {
        this.hasChanges = (this.firstName != this.originalFirstName) ||
            (this.lastName != this.originalLastName) ||
            (this.username != this.originalUsername) ||
            (this.bio != this.originalBio)
    }

    // 异步检查用户名可用性（account.checkUsername）
    func triggerUsernameCheck(name: String): Unit {
        if (name == this.originalUsername) {
            this.usernameStatus = "Current username"
            this.usernameStatusColor = 0x8E8E93
            this.isCheckingUsername = false
            return
        }
        if (name.size == 0) {
            this.usernameStatus = ""
            this.isCheckingUsername = false
            return
        }
        if (name.size < 5) {
            this.usernameStatus = "A username must have at least 5 characters."
            this.usernameStatusColor = 0xFF3B30
            this.isCheckingUsername = false
            return
        }
        this.isCheckingUsername = true
        this.usernameStatus = "Checking..."
        this.usernameStatusColor = 0x8E8E93
        let nameCopy = name
        spawn {
            let result = getSettingsService().checkUsername(nameCopy)
            launch {
                this.isCheckingUsername = false
                if (result == 1) {
                    this.usernameStatus = "This username is available"
                    this.usernameStatusColor = 0x34C759
                } else if (result == 0) {
                    this.usernameStatus = "Sorry, this username is already taken."
                    this.usernameStatusColor = 0xFF3B30
                } else {
                    this.usernameStatus = "Failed to check availability, please try again."
                    this.usernameStatusColor = 0xFF9500
                }
            }
        }
    }

    // 执行保存：updateProfile + (如有变更) updateUsername
    func doSave(): Unit {
        if (!this.hasChanges || this.isSaving) {
            return
        }
        this.isSaving = true
        let fNameCopy = this.firstName
        let lNameCopy = this.lastName
        let bioCopy = this.bio
        let usernameCopy = this.username
        let usernameChanged = (usernameCopy != this.originalUsername)

        spawn {
            // 调用 SettingsService.updateProfile
            let profileOk = getSettingsService().updateProfile(
                Some(fNameCopy),
                Some(lNameCopy),
                Some(bioCopy)
            )
            Hilog.info(0, "CjTelegram", "[EditProfilePage] updateProfile result=${profileOk}")

            // 如果用户名也有变更，调用 updateUsername
            let usernameOk: Bool = if (usernameChanged && profileOk) {
                let r = getSettingsService().updateUsername(usernameCopy)
                Hilog.info(0, "CjTelegram", "[EditProfilePage] updateUsername result=${r}")
                r
            } else {
                true
            }

            if (profileOk && usernameOk) {
                getRealAuthService().applyLocalProfile(fNameCopy, lNameCopy, usernameCopy)
                launch {
                    this.isSaving = false
                    this.originalFirstName = fNameCopy
                    this.originalLastName = lNameCopy
                    this.originalBio = bioCopy
                    if (usernameChanged) {
                        this.originalUsername = usernameCopy
                        this.usernameStatus = "Current username"
                        this.usernameStatusColor = 0x8E8E93
                    }
                    this.hasChanges = false
                    routerPop()
                }
            } else {
                Hilog.info(0, "CjTelegram", "[EditProfilePage] Save failed: profile=${profileOk} username=${usernameOk}")
                launch { this.isSaving = false }
            }
        }
    }

    @Builder
    func buildAlignedPage() {
        // diag-suite_settings_root-TC-0074-round3.md 修法 B：对位源侧 PeerInfoScreen.swift:6556-6564
        // （导航栏 backgroundColor: .clear）+ PeerInfoHeaderNavigationButtonContainerNode.swift:35-72
        // （容器本身无背景，白色玻璃底属于左右两组按钮各自）。改为 Stack 浮层结构，逐字复用本工程
        // 已落地正确的常态导航栏结构 pages/SettingsPage.cj pinnedNavButtons() + 其挂载方式
        // Stack(alignContent: Alignment.TopStart)：内容 Scroll 在下，透明导航 Row 浮在最上层。
        Stack(alignContent: Alignment.TopStart) {
            Scroll {
                Column {
                    Column {
                        if (this.avatarLocalPath.size > 0) {
                            Image(this.avatarLocalPath)
                                .width(100).height(100).borderRadius(50)
                                .objectFit(ImageFit.Cover)
                        } else {
                            Column {
                                Image(@r(app.media.editprofile_ic_camera))
                                    .width(56).height(56)
                            }
                                .width(100).height(100).borderRadius(50)
                                .backgroundColor(0xDDEEFF)
                                .justifyContent(FlexAlign.Center)
                                .alignItems(HorizontalAlign.Center)
                        }
                        if (this.isUploadingPhoto) {
                            Row {
                                LoadingProgress().width(16).height(16).color(0x317AFF)
                                Text(trSource("Uploading...")).fontSize(15).fontColor(0x317AFF).margin(left: 8)
                            }.margin(top: 8)
                        } else {
                            Text(if (this.avatarLocalPath.size > 0) { "Change Photo" } else { "Set Photo" })
                                .fontSize(15).fontColor(0x317AFF).margin(top: 8)
                                .onClick({ _ => this.showPhotoOptions = !this.showPhotoOptions })
                        }
                    }
                    .width(100.percent)
                    .padding(top: 10, bottom: 12)
                    .alignItems(HorizontalAlign.Center)

                    Column {
                        // diag-suite_settings_root-TC-0074-round3.md 修法 D：对位源侧
                        // ItemListSingleLineInputItem.swift:293（占位符走独立主题槽
                        // itemPlaceholderTextColor，DefaultDayPresentationTheme.swift:483
                        // = 0xC8C8CE，比页脚 freeTextColor 0x6D6D72 浅得多）。
                        TextInput(text: this.firstName, placeholder: trSource("First Name"))
                            .height(44).backgroundColor(Color.Transparent).fontSize(17).fontColor(0x000000)
                            .placeholderColor(0xC8C8CE)
                            .padding(left: 16, right: 16)
                            .onChange({ value: String => this.firstName = value; this.checkChanges() })
                        ItemListSeparator(leftInset: 16)
                        TextInput(text: this.lastName, placeholder: trSource("Last Name"))
                            .height(44).backgroundColor(Color.Transparent).fontSize(17).fontColor(0x000000)
                            .placeholderColor(0xC8C8CE)
                            .padding(left: 16, right: 16)
                            .onChange({ value: String => this.lastName = value; this.checkChanges() })
                    }
                    // diag-suite_settings_root-TC-0074.md §4.5 F2：PresentationResourcesItemList.swift:391
                    // 的 glass item 固定圆角 26pt，不是"卡高/2"。
                    .backgroundColor(0xFFFFFF).borderRadius(26).clip(true)
                    .margin(left: 16, right: 16)
                    // diag-suite_settings_root-TC-0074-round4.md §4.3/修法C：数值 32 本来就对
                    // （源 PeerInfoScreenCommentItem.swift:91/166 sideInset+leftTextInset=32），
                    // 错的是水平量走 margin——在默认居中的 Column 下，width(100%)+水平margin会
                    // 撑出溢出的 margin 盒被居中放置，导致可见左缘偏移。改水平量为 padding
                    // （计入 100% 宽度内，不产生溢出）；纵向量与字体不变。
                    Text(trSource("Enter your name and add an optional profile photo."))
                        .fontSize(13).fontColor(0x8E8E93)
                        .margin(top: 7, bottom: 18).padding(left: 32, right: 24).width(100.percent)

                    Column {
                        // diag-suite_settings_root-TC-0074-round3.md 修法 D：对位源侧
                        // ItemListMultilineInputItem.swift:267（同一 itemPlaceholderTextColor
                        // 主题槽，0xC8C8CE，与页脚 0x8E8E93 是不同槽——占位符须比页脚浅）。
                        TextArea(text: this.bio, placeholder: trSource("Bio"))
                            .height(48).backgroundColor(Color.Transparent).fontSize(17).fontColor(0x000000)
                            .placeholderColor(0xC8C8CE)
                            .padding(left: 16, right: 16, top: 9, bottom: 7)
                            .onChange({ value: String =>
                                if (value.size <= 70) { this.bio = value; this.checkChanges() }
                            })
                    }
                    .backgroundColor(0xFFFFFF).borderRadius(26)
                    .margin(left: 16, right: 16)
                    // diag-suite_settings_root-TC-0074-round4.md §4.3/修法C：同上，margin→padding。
                    Text(trSource("A few words about you."))
                        .fontSize(13).fontColor(0x8E8E93)
                        .margin(top: 7, bottom: 18).padding(left: 32, right: 24).width(100.percent)

                    Column {
                        Row {
                            Image(@r(app.media.editprofile_ic_birthday))
                                .width(29).height(29).margin(right: 16)
                            Text("Birthday").fontSize(17).fontColor(0x000000).layoutWeight(1)
                            Text(this.birthdayLabel()).fontSize(17).fontColor(0x8E8E93)
                            // diag-suite_settings_root-TC-0074.md §4.5 F5：源侧 PeerInfoSettingsItems.swift:417-419
                            // 对 ItemBirthday 显式传 hasArrow: false，本行不出 chevron。
                        }
                        // diag-suite_settings_root-TC-0074-round4.md 修法D：源侧
                        // PeerInfoScreenDisclosureItem.swift:215 height=textSize.height+32=52，全屏
                        // 所有行（含本行）恒此高——同页账号三行已是 52，Birthday 此前手写 44 与
                        // 之自相矛盾，改回 52 对齐。
                        .width(100.percent).height(52).padding(left: 16, right: 12)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _ => this.showBirthdayPicker = !this.showBirthdayPicker })
                        if (this.showBirthdayPicker) {
                            ItemListSeparator(leftInset: 16)
                            DatePicker(
                                start: DateTime.of(year: 1900, month: 1, dayOfMonth: 1),
                                end: DateTime.now(),
                                selected: this.selectedBirthday
                            )
                                .height(190)
                                .onDateChange({ value => this.selectedBirthday = value })
                            Row {
                                Text(trSource("Remove")).fontSize(17).fontColor(0xFF3B30)
                                    .onClick({ _ =>
                                        let _ = spawn {
                                            let ok = getSettingsService().updateBirthday(None)
                                            launch {
                                                if (ok) { this.birthday = None; this.showBirthdayPicker = false }
                                                else { showToast(birthdayUpdateErrorText()) }
                                            }
                                        }
                                    })
                                Blank().layoutWeight(1)
                                if (this.isSavingBirthday) {
                                    LoadingProgress().width(20).height(20).color(0x317AFF)
                                } else {
                                    Text(trSource("Save")).fontSize(17).fontWeight(FontWeight.Medium).fontColor(0x317AFF)
                                        .onClick({ _ => this.saveBirthday() })
                                }
                            }.height(44).padding(left: 16, right: 16).alignItems(VerticalAlign.Center)
                        }
                    }
                    .backgroundColor(0xFFFFFF).borderRadius(26).clip(true)
                    .margin(left: 16, right: 16)
                    // diag-suite_settings_root-TC-0074.md §4.5 F3：源侧 markdown 链接 "[Change >]()"
                    // 渲染成正文灰 + 链接段蓝（PeerInfoScreenCommentItem.swift:104-125），点击走
                    // interaction.openBirthdatePrivacy()。本工程按段拆成两个 Text，链接段接
                    // PrivacySettingsPage（生日隐私三态子页缺失，已 emit ic_birthday_privacy_destination）。
                    // diag-suite_settings_root-TC-0074-round4.md §4.3/修法C：margin→padding，理由同上。
                    Row {
                        Text("Only your contacts can see your birthday. ")
                            .fontSize(13).fontColor(0x8E8E93)
                        Text("Change ›")
                            .fontSize(13).fontColor(0x007AFF)
                            .onClick({ _ => routerPush("PrivacySettingsPage", "") })
                    }
                        .margin(top: 7, bottom: 18).padding(left: 32, right: 24).width(100.percent)

                    // diag-suite_settings_root-TC-0074-round4.md 修法 F/G：行首图标槽对位源侧
                    // PeerInfoScreenDisclosureItem.swift:156（leftInset = sideInset+29+16）—— 图标
                    // 29x29、右边距 16（与本工程自己的 ItemListDisclosureRow 已有先例一致，
                    // ItemListComponents.cj:456-458）。行尾 chevron 换成工程内已转好的矢量资源
                    // item_list_disclosure_arrow.svg（PhoneInputComponent.cj:310-313 同款先例），
                    // 不再用字体字形冒充图形；色值取源侧 disclosureArrowColor=0xBAB9BE。
                    Column {
                        Row {
                            Image(@r(app.media.editprofile_ic_phone))
                                .width(29).height(29).margin(right: 16)
                            Text(trSource("Number")).fontSize(17).fontColor(0x000000).layoutWeight(1)
                            Text(this.displayPhoneNumberFormatted()).fontSize(17).fontColor(0x8E8E93)
                            Image(@r(app.media.item_list_disclosure_arrow))
                                .width(7).height(12).fillColor(0xBAB9BE).margin(left: 8)
                        }
                        .width(100.percent).height(52).padding(left: 16, right: 12)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _ => routerPush("ChangePhoneIntroPage", "{\"proceed\":\"replace_top\"}") })
                        ItemListSeparator(leftInset: 60)
                        Row {
                            Image(@r(app.media.editprofile_ic_username))
                                .width(29).height(29).margin(right: 16)
                            Text(trSource("Username")).fontSize(17).fontColor(0x000000).layoutWeight(1)
                            // diag-suite_settings_root-TC-0074.md §4.5 F4：源侧 PeerInfoSettingsItems.swift:449-455
                            // 用户名为空时 label 是空串，右侧不出任何值文本，没有占位词。
                            if (this.username.size > 0) {
                                Text("@${this.username}")
                                    .fontSize(17).fontColor(0x8E8E93)
                            }
                            Image(@r(app.media.item_list_disclosure_arrow))
                                .width(7).height(12).fillColor(0xBAB9BE).margin(left: 8)
                        }
                        .width(100.percent).height(52).padding(left: 16, right: 12)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _ => routerPush("UsernameSettingsPage", "") })
                        ItemListSeparator(leftInset: 60)
                        Row {
                            Image(@r(app.media.editprofile_ic_color))
                                .width(29).height(29).margin(right: 16)
                            Text(trSource("Your Color")).fontSize(17).fontColor(0x000000).layoutWeight(1)
                            // diag-suite_settings_root-TC-0074.md §4.5 F6：源侧 nameColor/effectiveProfileColor
                            // 均可空，两者皆空时画全透明图（视觉上无点），不是"画默认红点"。
                            if (this.hasProfileColorSet()) {
                                Column { }.width(22).height(22).borderRadius(11).backgroundColor(this.profileColorHex(this.profileColorIndex.getOrThrow()))
                            }
                            Image(@r(app.media.item_list_disclosure_arrow))
                                .width(7).height(12).fillColor(0xBAB9BE).margin(left: 8)
                        }
                        .width(100.percent).height(52).padding(left: 16, right: 12)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _ => routerPush("ProfileColorPage", "") })
                        ItemListSeparator(leftInset: 60)
                        if (this.showsPersonalChannelRow()) {
                            Row {
                                Image(@r(app.media.setroot_ds_channel))
                                    .width(29).height(29).margin(right: 16)
                                Text(trSource("Channel")).fontSize(17).fontColor(0x000000).layoutWeight(1)
                                Text(this.personalChannelLabel()).fontSize(17).fontColor(0x8E8E93)
                                    .maxLines(1).textOverflow(TextOverflow.Ellipsis).constraintSize(maxWidth: 180)
                                Image(@r(app.media.item_list_disclosure_arrow))
                                    .width(7).height(12).fillColor(0xBAB9BE).margin(left: 8)
                            }
                            .width(100.percent).height(52).padding(left: 16, right: 12)
                            .alignItems(VerticalAlign.Center)
                            .onClick({ _ => this.showPersonalChannelPicker = true })
                            ItemListSeparator(leftInset: 60)
                        }
                        Row {
                            Image(@r(app.media.editprofile_ic_automation))
                                .width(29).height(29).margin(right: 16)
                            Text(trSource("Chat Automation")).fontSize(17).fontColor(0x000000).layoutWeight(1)
                            Text(trSource("Off")).fontSize(17).fontColor(0x8E8E93)
                            Image(@r(app.media.item_list_disclosure_arrow))
                                .width(7).height(12).fillColor(0xBAB9BE).margin(left: 8)
                        }
                        .width(100.percent).height(52).padding(left: 16, right: 12)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _ => routerPush("ChatAutomationPage", "") })
                    }
                    .backgroundColor(0xFFFFFF).borderRadius(26).clip(true)
                    .margin(left: 16, right: 16)
                    // diag-suite_settings_root-TC-0074-round4.md §4.3/修法C：margin→padding，理由同上。
                    Text(trSource("Add a bot to reply to messages on your behalf."))
                        .fontSize(13).fontColor(0x8E8E93)
                        .margin(top: 7, bottom: 18).padding(left: 32, right: 24).width(100.percent)

                    // diag-suite_settings_root-TC-0074-round4.md 修法E：本页按钮行传 rowHeight:52
                    // （源 PeerInfoScreenActionItem.swift:130 height=textSize.height+32=52），走
                    // ItemListButtonRow 新增的带默认值参数，不改组件默认值（默认值迁移是独立工作，
                    // 见 §6.3-2，本轮不动其余 23 处调用点）。
                    Column {
                        ItemListButtonRow(
                            title: "Add Another Account",
                            centered: true,
                            rowHeight: 52,
                            onClick: { => this.beginAddAccount() }
                        )
                    }
                    .backgroundColor(0xFFFFFF).borderRadius(26).clip(true)
                    .margin(left: 16, right: 16)
                    // diag-suite_settings_root-TC-0074-round4.md §4.3/修法C：margin→padding，理由同上
                    // （两处，含错误提示行，写法同构）。
                    Text("You can connect multiple accounts with different phone numbers.")
                        .fontSize(13).fontColor(0x8E8E93)
                        .margin(top: 7).padding(left: 32, right: 24).width(100.percent)
                    if (this.accountActionMessage.size > 0) {
                        Text(this.accountActionMessage).fontSize(13).fontColor(0xFF3B30)
                            .margin(top: 7).padding(left: 32, right: 24).width(100.percent)
                    }
                    Column {
                        if (this.isLoggingOut) {
                            Row {
                                LoadingProgress().width(18).height(18).color(0xFF3B30)
                                Text("Logging Out...").fontSize(17).fontColor(0xFF3B30).margin(left: 8)
                            }.height(44).justifyContent(FlexAlign.Center)
                        } else {
                            ItemListButtonRow(
                                title: "Log Out",
                                destructive: true,
                                centered: true,
                                rowHeight: 52,
                                onClick: { => routerPush("LogoutOptionsPage", "") }
                            )
                        }
                    }
                    .backgroundColor(0xFFFFFF).borderRadius(26).clip(true)
                    .margin(left: 16, right: 16, top: 18, bottom: 32)
                }
                .width(100.percent)
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xF2F2F7)

            Row {
                // diag-suite_settings_root-TC-0074-round4.md §4.1：round1 的裁定（编辑态取
                // 56/28 以求和常态 pinnedNavButtons() 一致）被本轮推翻——源侧两态共用同一容器
                // 的常量其实是 buttonHeight=44 / cornerRadius=height*0.5=22
                // （PeerInfoHeaderNavigationButtonContainerNode.swift:361/331-337），round1 保的
                // 是目标内部自洽，代价是两态同时偏离源。本页编辑态改回 44/22 + 宽度随标签自适应
                // （PeerInfoHeaderNavigationButton.swift:315/343，textInset=12）。
                // 遗留（刻意、已追踪，勿"修回"）：pages/SettingsPage.cj pinnedNavButtons() 的常态
                // 按钮仍是 56/28——该文件同时在 set_root_and_search 的 allowlist 内且当前有
                // Worker 在里面，本轮不可touch；已记录为 set_root_and_search 下一轮的义务，
                // 目标同为 44/22（不改变现在的临时"两态不一致"状态，交 Coordinator 定后续批次）。
                Text(trSource("Cancel"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0x000000)
                    .height(44)
                    .borderRadius(22)
                    .padding(left: 12, right: 12)
                    .backgroundColor(0xFFFFFFFF)
                    .textAlign(TextAlign.Center)
                    .onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
                if (this.isSaving) {
                    LoadingProgress().width(24).height(24).color(0x317AFF)
                } else {
                    Text(trSource("Done"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(0x000000)
                        .height(44)
                        .borderRadius(22)
                        .padding(left: 12, right: 12)
                        .backgroundColor(0xFFFFFFFF)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ =>
                            if (this.hasChanges) { this.doSave() } else { routerPop() }
                        })
                }
            }
            // diag-suite_settings_root-TC-0074-round3.md 修法 B-2 / D-144：`0x00000000` 在本
            // SDK 下渲染为不透明黑，Color.Transparent 才是真透明（`ohos/base/color.cj` 的
            // `alphaAdapt` 只放行四参数构造器）——显式设 Color.Transparent，白药丸浮在浅灰
            // 内容区之上时自然可辨（对位源侧 backgroundColor: .clear）。
            .backgroundColor(Color.Transparent)
            .width(100.percent)
            .padding(left: 16, right: 16, top: 10)
            .alignItems(VerticalAlign.Center)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
    }

    public func build() {
        Stack {
        if (true) {
            this.buildAlignedPage()
        } else {
        Column {
            // 顶部导航栏
            Row {
                Text(trSource("Cancel"))
                    .fontSize(17)
                    .fontColor(0x317AFF)
                    .onClick({ _ =>
                        routerPop()
                    })

                Text(trSource("Edit Profile"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                    .layoutWeight(1)
                    .textAlign(TextAlign.Center)

                if (this.isSaving) {
                    LoadingProgress()
                        .width(24)
                        .height(24)
                        .color(0x317AFF)
                } else {
                    Text(trSource("Done"))
                        .fontSize(17)
                        .fontColor(if (this.hasChanges) { 0x317AFF } else { 0xC7C7CC })
                        .fontWeight(FontWeight.Medium)
                        .onClick({ _ =>
                            this.doSave()
                        })
                }
            }
            .width(100.percent)
            .height(56)
            .padding(left: 16, right: 16)
            .backgroundColor(0xFFFFFF)
            .alignItems(VerticalAlign.Center)

            // 滚动内容区
            Scroll {
                Column {
                    // 头像区域
                    Column {
                        if (this.avatarLocalPath.size > 0) {
                            Image(this.avatarLocalPath)
                                .width(100)
                                .height(100)
                                .borderRadius(50)
                                .objectFit(ImageFit.Cover)
                        } else {
                            Text(this.avatarText)
                                .fontSize(36)
                                .fontColor(0xFFFFFF)
                                .width(100)
                                .height(100)
                                .borderRadius(50)
                                .backgroundColor(0x317AFF)
                                .textAlign(TextAlign.Center)
                        }

                        if (this.isUploadingPhoto) {
                            Row {
                                LoadingProgress()
                                    .width(16)
                                    .height(16)
                                    .color(0x317AFF)
                                Text(trSource("Uploading..."))
                                    .fontSize(15)
                                    .fontColor(0x317AFF)
                                    .margin(left: 8)
                            }
                            .margin(top: 12)
                        } else {
                            Text(trSource("Change Photo"))
                                .fontSize(15)
                                .fontColor(0x317AFF)
                                .margin(top: 12)
                                .onClick({ _ =>
                                    Hilog.info(0, "CjTelegram", "[EditProfilePage] Change avatar tapped")
                                    this.showPhotoOptions = true
                                })
                        }
                    }
                    .width(100.percent)
                    .padding(top: 24, bottom: 24)
                    .backgroundColor(0xFFFFFF)
                    .alignItems(HorizontalAlign.Center)
                    .onClick({ _ =>
                        if (!this.isUploadingPhoto) {
                            this.showPhotoOptions = !this.showPhotoOptions
                        }
                    })

                    // ---- 姓名区域 ----
                    Text(trSource("Name"))
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(left: 16, top: 24, bottom: 8)
                        .width(100.percent)

                    Column {
                        // 名字
                        Row {
                            Text(trSource("First Name"))
                                .fontSize(17)
                                .fontColor(0x8E8E93)
                                .width(80)

                            // O2(TC-0083 diag round2): D-144 —— 0x00000000 在本 SDK 下被解析成
                            // 不透明黑，不是透明；Color.Transparent 才是本仓已验证生效的透明写法
                            // (VideoCallScreen.cj:1120-1125 先例；Coordinator 已澄清 0x00FFFFFF
                            // 同样不透明，只是白色，不采用 dev_pattern.md D-144 里那条已过时的建议)
                            TextInput(text: this.firstName, placeholder: "Required")
                                .layoutWeight(1)
                                .height(44)
                                .backgroundColor(Color.Transparent)
                                .fontSize(17)
                                .fontColor(0x000000)
                                .onChange({ value: String =>
                                    this.firstName = value
                                    this.checkChanges()
                                })
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16)

                        Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 96)

                        // 姓氏
                        Row {
                            Text(trSource("Last Name"))
                                .fontSize(17)
                                .fontColor(0x8E8E93)
                                .width(80)

                            // O2: 同上 D-144，Color.Transparent
                            TextInput(text: this.lastName, placeholder: trSource("Optional"))
                                .layoutWeight(1)
                                .height(44)
                                .backgroundColor(Color.Transparent)
                                .fontSize(17)
                                .fontColor(0x000000)
                                .onChange({ value: String =>
                                    this.lastName = value
                                    this.checkChanges()
                                })
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16)
                    }
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(10)
                    .margin(left: 16, right: 16)

                    // ---- 用户名区域 ----
                    Text(trSource("Username"))
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(left: 16, top: 24, bottom: 8)
                        .width(100.percent)

                    Column {
                        Row {
                            Text("@")
                                .fontSize(17)
                                .fontColor(0x8E8E93)

                            // O2: 同上 D-144，Color.Transparent。注意：本输入框不属于 TC-0082
                            // 的 ItemListInputRow 改造范围(诊断报告 M-3 边界明确排除本页输入字段)，
                            // 此处只做黑底修正，不接输入过滤管线。
                            TextInput(text: this.username, placeholder: trSource("username"))
                                .layoutWeight(1)
                                .height(48)
                                .backgroundColor(Color.Transparent)
                                .fontSize(17)
                                .fontColor(0x000000)
                                .onChange({ value: String =>
                                    this.username = value
                                    this.checkChanges()
                                    this.triggerUsernameCheck(value)
                                })
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16)

                        // 用户名状态提示行
                        if (this.isCheckingUsername) {
                            Row {
                                LoadingProgress()
                                    .width(14)
                                    .height(14)
                                    .color(0x8E8E93)
                                Text(trSource("Checking..."))
                                    .fontSize(13)
                                    .fontColor(0x8E8E93)
                                    .margin(left: 6)
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, bottom: 8)
                        } else if (this.usernameStatus.size > 0) {
                            Text(this.usernameStatus)
                                .fontSize(13)
                                .fontColor(this.usernameStatusColor)
                                .width(100.percent)
                                .padding(left: 16, right: 16, bottom: 8)
                        }
                    }
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(10)
                    .margin(left: 16, right: 16)

                    Text("You can choose a username on Telegram. If you do, people will be able to find you by this username and contact you without needing your phone number.")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(left: 16, right: 16, top: 8)
                        .width(100.percent)

                    // ---- Bio 区域 ----
                    Text(trSource("Bio"))
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(left: 16, top: 24, bottom: 8)
                        .width(100.percent)

                    Column {
                        if (this.isLoadingProfile) {
                            Row {
                                LoadingProgress()
                                    .width(16)
                                    .height(16)
                                    .color(0x317AFF)
                                Text(trSource("Loading..."))
                                    .fontSize(15)
                                    .fontColor(0x8E8E93)
                                    .margin(left: 8)
                            }
                            .width(100.percent)
                            .height(60)
                            .justifyContent(FlexAlign.Center)
                        } else {
                            // O2(TC-0083 diag round2): D-144，Color.Transparent(不用 0x00FFFFFF——
                            // Coordinator 已澄清那同样不透明，只是白色)
                            TextArea(text: this.bio, placeholder: trSource("Bio"))
                                .width(100.percent)
                                .height(100)
                                .backgroundColor(Color.Transparent)
                                .fontSize(17)
                                .fontColor(0x000000)
                                .padding(left: 16, right: 16, top: 12, bottom: 12)
                                .onChange({ value: String =>
                                    if (value.size <= 70) {
                                        this.bio = value
                                        this.checkChanges()
                                    }
                                })
                        }

                        Row {
                            Blank().layoutWeight(1)
                            Text("${this.bio.size}/70")
                                .fontSize(13)
                                .fontColor(if (this.bio.size >= 70) { 0xFF3B30 } else { 0x8E8E93 })
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, bottom: 8)
                    }
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(10)
                    .margin(left: 16, right: 16)

                    Text("You can add details like your age, occupation, or city. Example: 23-year-old designer from Beijing.")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(left: 16, right: 16, top: 8)
                        .width(100.percent)

                    // ---- P2-304: Emoji Status 入口 ----
                    Text(trSource("Premium"))
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(left: 16, top: 24, bottom: 8)
                        .width(100.percent)

                    // M-3(diag-suite_settings_root-TC-0083.md round2): 手搓 Row 改用共享原子
                    // ItemListDisclosureRow(装配方式统一；行为不变，仍跳 EmojiStatusPickerPage)。
                    // 不动本页输入字段(与 TC-0082 的 ItemListInputRow 改造分属两条线，边界已排除)。
                    Column {
                        ItemListDisclosureRow(
                            title: "Emoji Status",
                            value: "",
                            onClick: { => routerPush("EmojiStatusPickerPage") }
                        )
                    }
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(10)
                    .margin(left: 16, right: 16, bottom: 8)

                    Text("Requires Telegram Premium. Set an emoji as your status badge.")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(left: 16, right: 16, top: 0, bottom: 8)
                        .width(100.percent)

                    // ---- 手机号 ----
                    Text(trSource("Phone Number"))
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(left: 16, top: 24, bottom: 8)
                        .width(100.percent)

                    // M-1(diag-suite_settings_root-TC-0083.md round2): 手机号行此前整块无
                    // .onClick(结构性绕过共享原子，源侧 PeerInfoScreenDisclosureItem.action 是
                    // 构造函数必填参数，不可能未接线)。改用 components/ItemListComponents.cj:325
                    // ItemListDisclosureRow(同页 Emoji Status 行、pages/SettingsPage.cj:878 均已在用
                    // 该原子)。删除目标侧自造的"更改"文案与独立 chevron(源侧本行无此文案，chevron
                    // 由原子自带，二者都是多余/重复元素)。
                    Column {
                        ItemListDisclosureRow(
                            title: "Phone Number",
                            value: this.displayPhoneNumberFormatted(),
                            showChevron: true,
                            onClick: { => routerPush("ChangePhoneIntroPage", "{\"proceed\":\"replace_top\"}") }
                        )
                    }
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(10)
                    .margin(left: 16, right: 16)

                    // ---- 账号操作：对位源侧 settingsEditingItems.account/logout ----
                    Text("Account")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(left: 16, top: 24, bottom: 8)
                        .width(100.percent)

                    Column {
                        ItemListButtonRow(
                            title: "Add Another Account",
                            centered: true,
                            onClick: { => this.beginAddAccount() }
                        )
                    }
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(10)
                    .clip(true)
                    .margin(left: 16, right: 16)

                    Text("Connect another Telegram account and switch between accounts without logging out.")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(left: 16, right: 16, top: 8)
                        .width(100.percent)

                    if (this.accountActionMessage.size > 0) {
                        Text(this.accountActionMessage)
                            .fontSize(13)
                            .fontColor(0xFF3B30)
                            .margin(left: 16, right: 16, top: 8)
                            .width(100.percent)
                    }

                    Column {
                        if (this.isLoggingOut) {
                            Row {
                                LoadingProgress()
                                    .width(18)
                                    .height(18)
                                    .color(0xFF3B30)
                                Text("Logging Out...")
                                    .fontSize(17)
                                    .fontColor(0xFF3B30)
                                    .margin(left: 8)
                            }
                            .width(100.percent)
                            .height(44)
                            .justifyContent(FlexAlign.Center)
                        } else {
                            ItemListButtonRow(
                                title: "Log Out",
                                destructive: true,
                                centered: true,
                                onClick: { => this.showLogoutDialog = true }
                            )
                        }
                    }
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(10)
                    .clip(true)
                    .margin(left: 16, right: 16, top: 24, bottom: 32)
                }
                .width(100.percent)
            }
            .layoutWeight(1)
            .backgroundColor(0xF2F2F7)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        }

        if (this.showPhotoOptions) {
            Stack(alignContent: Alignment.Bottom) {
                Column { }
                    .width(100.percent)
                    .height(100.percent)
                    .backgroundColor(0x73000000)
                    .onClick({ _ => this.showPhotoOptions = false })
                Column {
                    Column {
                        Text("Set New Photo")
                            .fontSize(20).fontColor(0x0A84FF)
                            .width(100.percent).height(58).textAlign(TextAlign.Center)
                            .onClick({ _ =>
                                this.showPhotoOptions = false
                                this.pickProfilePhotoFromSystemAlbum()
                            })
                        Divider().color(0xE5E5EA).strokeWidth(1)
                        Text(trSource("Set Emoji"))
                            .fontSize(20).fontColor(0x0A84FF)
                            .width(100.percent).height(58).textAlign(TextAlign.Center)
                            .onClick({ _ =>
                                this.showPhotoOptions = false
                                routerPush("EmojiStatusPickerPage", "avatar")
                            })
                        if (this.avatarLocalPath.size > 0) {
                            Divider().color(0xE5E5EA).strokeWidth(1)
                            Text(trSource("Delete Photo"))
                                .fontSize(20).fontColor(0xFF3B30)
                                .width(100.percent).height(58).textAlign(TextAlign.Center)
                                .onClick({ _ =>
                                    this.showPhotoOptions = false
                                    this.deleteProfilePhoto()
                                })
                        }
                    }
                    .width(100.percent).backgroundColor(0xFFFFFF).borderRadius(14).clip(true)

                    Text(trSource("Cancel"))
                        .fontSize(20).fontWeight(FontWeight.Medium).fontColor(0x0A84FF)
                        .width(100.percent).height(58).textAlign(TextAlign.Center)
                        .backgroundColor(0xFFFFFF).borderRadius(14)
                        .margin(top: 8)
                        .onClick({ _ => this.showPhotoOptions = false })
                }
                .width(100.percent).padding(left: 10, right: 10, top: 10, bottom: 12)
                .backgroundColor(0xF2F2F7)
            }
            .width(100.percent).height(100.percent).position(x: 0, y: 0)
        }

        if (this.showPersonalChannelPicker) {
            this.personalChannelPicker()
        }

        if (this.showLogoutDialog) {
            Column {
                Column { }
                    .width(100.percent)
                    .layoutWeight(1)
                    .backgroundColor(0x66000000)
                    .onClick({ _ => this.showLogoutDialog = false })

                Column {
                    Text(trSource("Log Out"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0x000000)
                        .margin(top: 20, bottom: 8)

                    Text("Are you sure you want to log out of this account?")
                        .fontSize(15)
                        .fontColor(0x8E8E93)
                        .textAlign(TextAlign.Center)
                        .margin(left: 20, right: 20, bottom: 20)

                    Divider().color(0xE5E5EA).strokeWidth(1)

                    Row {
                        Button(trSource("Cancel"))
                            .layoutWeight(1)
                            .height(50)
                            .fontSize(17)
                            .fontColor(0x317AFF)
                            .backgroundColor(Color.Transparent)
                            .onClick({ _ => this.showLogoutDialog = false })

                        Divider()
                            .vertical(true)
                            .color(0xE5E5EA)
                            .strokeWidth(1)
                            .height(50)

                        Button(trSource("Log Out"))
                            .layoutWeight(1)
                            .height(50)
                            .fontSize(17)
                            .fontWeight(FontWeight.Bold)
                            .fontColor(0xFF3B30)
                            .backgroundColor(Color.Transparent)
                            .onClick({ _ => this.confirmLogoutCurrentAccount() })
                    }
                }
                .width(310)
                .backgroundColor(0xFFFFFF)
                .borderRadius(14)
                .alignItems(HorizontalAlign.Center)
                .margin(bottom: 200)
            }
            .width(100.percent)
            .height(100.percent)
            .justifyContent(FlexAlign.End)
            .alignItems(HorizontalAlign.Center)
            .position(x: 0, y: 0)
        }
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ =>
            this.ensureLoaded()
            // diag-suite_settings_root-TC-0074-round3.md 修法 C-2：保存/回填后的刷新点必须与
            // ensureLoaded() 的判据完全一致，否则保存一次后红点又会回来。
            let storedColor = getAuthStorage().getProfileNameColor()
            this.profileColorIndex = if (storedColor >= 0) {
                Some(getThemesEngineService().getProfileHeaderColorIndex())
            } else {
                Option<Int32>.None
            }
        })
    }

    /**
     * 上传选中的头像（PhotoPicker 回调）
     * 流程：读取文件字节 → FileUploadService 分片上传 → photos.uploadProfilePhoto
     */
    func pickProfilePhotoFromSystemAlbum(): Unit {
        callArkAsync(PICK_PHOTO_ALBUM, "{}", { result =>
            if (!editProfileJsonBool(result, "ok")) { return }
            if (editProfileJsonString(result, "status") != "picked") { return }
            let paths = editProfileJsonStringArray(result, "paths")
            if (paths.isEmpty()) { return }
            let path = paths[0]
            var fileName = "profile.jpg"
            match (path.lastIndexOf("/")) {
                case Some(index) => fileName = path[(index + 1)..path.size]
                case None => ()
            }
            let photo = SelectedPhoto(uri: path, fileName: fileName, fileSize: 0)
            launch { this.uploadSelectedPhoto(photo) }
        })
    }

    func uploadSelectedPhoto(photo: SelectedPhoto): Unit {
        this.isUploadingPhoto = true
        Hilog.info(0, "CjTelegram", "[EditProfilePage] Starting profile photo upload...")

        let uriCopy = photo.uri
        spawn {
            try {
                var realPath = uriCopy
                if (realPath.startsWith("file://")) {
                    realPath = realPath[7..]
                }

                // 相册原图常为数 MB 甚至更大，直接分片会长时间阻塞页面在
                // Uploading。与源端一样先生成头像用 JPEG，再走同一条 MTProto 上传链路。
                let photoData = getImageCompressionService().compressToMaxPixelSize(
                    realPath, Int32(1280), UInt8(86)
                )
                if (photoData.isEmpty()) {
                    Hilog.info(0, "CjTelegram", "[EditProfilePage] Photo decode/compression failed")
                    launch { this.isUploadingPhoto = false }
                    return
                }
                Hilog.info(0, "CjTelegram", "[EditProfilePage] Prepared avatar JPEG: ${photoData.size} bytes")

                let photoResult = getSettingsService().uploadAndSetProfilePhoto(photoData, "profile.jpg")

                if (photoResult.success) {
                    Hilog.info(0, "CjTelegram", "[EditProfilePage] Profile photo uploaded successfully")

                    // 本地缓存头像副本
                    let userId = getCurrentUserId()
                    if (userId > 0) {
                        let filesDir = getAppFilesDir()
                        if (filesDir.size > 0) {
                            let avatarDir = filesDir + "/avatars"
                            try { FileIo.mkdir(avatarDir) } catch (_e: Exception) {}
                            let avatarPath = avatarDir + "/avatar_${userId}.jpg"
                            try {
                                let outFile = FileIo.open(avatarPath, mode: 0o1101)
                                FileIo.write(outFile.fd, photoData)
                                FileIo.close(outFile)
                                let uri = "file://" + avatarPath
                                getUserPhotoService().setUserPhotoPath(userId, uri)
                                Hilog.info(0, "CjTelegram", "[EditProfilePage] Avatar cached locally")
                            } catch (e: Exception) {
                                Hilog.info(0, "CjTelegram", "[EditProfilePage] Cache save error: ${e}")
                            }
                        }
                    }

                    let visibleUri = if (uriCopy.startsWith("file://")) { uriCopy } else { "file://" + uriCopy }
                    launch {
                        this.avatarLocalPath = visibleUri
                        this.isUploadingPhoto = false
                    }
                } else {
                    Hilog.info(0, "CjTelegram", "[EditProfilePage] Profile photo upload failed")
                    launch { this.isUploadingPhoto = false }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[EditProfilePage] Upload failed: ${e}")
                launch { this.isUploadingPhoto = false }
            }
        }
    }

    /**
     * 删除当前头像 (via SettingsService.deleteOwnProfilePhoto — 内部取真实 photo id)
     */
    func deleteProfilePhoto(): Unit {
        this.isUploadingPhoto = true
        Hilog.info(0, "CjTelegram", "[EditProfilePage] Deleting profile photo...")

        spawn {
            try {
                let ok = getSettingsService().deleteOwnProfilePhoto()
                Hilog.info(0, "CjTelegram", "[EditProfilePage] deleteOwnProfilePhoto result=${ok}")

                if (ok) {
                    let userId = getCurrentUserId()
                    if (userId > 0) {
                        getUserPhotoService().clearUserPhoto(userId)
                    }
                }
                launch {
                    if (ok) {
                        this.avatarLocalPath = ""
                    }
                    this.isUploadingPhoto = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[EditProfilePage] Delete photo error: ${e}")
                launch { this.isUploadingPhoto = false }
            }
        }
    }
}

public func editProfileJsonBool(json: String, key: String): Bool {
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

public func editProfileJsonString(json: String, key: String): String {
    let needle = "\"${key}\""
    match (json.indexOf(needle)) {
        case Some(index) =>
            let tail = json[(index + needle.size)..json.size]
            match (tail.indexOf("\"")) {
                case Some(firstQuote) =>
                    let valueTail = tail[(firstQuote + 1)..tail.size]
                    match (valueTail.indexOf("\"")) {
                        case Some(lastQuote) => return valueTail[0..lastQuote]
                        case None => return ""
                    }
                case None => return ""
            }
        case None => return ""
    }
}

public func editProfileJsonStringArray(json: String, key: String): ArrayList<String> {
    let result = ArrayList<String>()
    let needle = "\"${key}\""
    match (json.indexOf(needle)) {
        case Some(index) =>
            let tail = json[(index + needle.size)..json.size]
            match (tail.indexOf("[")) {
                case Some(leftBracket) =>
                    match (tail.indexOf("]")) {
                        case Some(rightBracket) =>
                            if (rightBracket <= leftBracket) { return result }
                            var body = tail[(leftBracket + 1)..rightBracket]
                            while (true) {
                                match (body.indexOf("\"")) {
                                    case Some(firstQuote) =>
                                        let valueTail = body[(firstQuote + 1)..body.size]
                                        match (valueTail.indexOf("\"")) {
                                            case Some(lastQuote) =>
                                                result.add(valueTail[0..lastQuote])
                                                body = valueTail[(lastQuote + 1)..valueTail.size]
                                            case None => return result
                                        }
                                    case None => return result
                                }
                            }
                            return result
                        case None => return result
                    }
                case None => return result
            }
        case None => return result
    }
}

/**
 * PeerInfoScreen.swift:1741-1743: a FLOOD_WAIT on account.updateBirthday (UpdateBirthdayError.flood,
 * Birthdays.swift:92) presents Birthday_FloodError; other failures fall back to the generic error.
 */
func birthdayUpdateErrorText(): String {
    if (getSettingsService().lastBirthdayError.startsWith("FLOOD_WAIT")) {
        return trOr("Birthday.FloodError", "Sorry, you can\u{2019}t change your birthday so often.")
    }
    return trOr("Login.UnknownError", "An error occurred, please try again later.")
}
