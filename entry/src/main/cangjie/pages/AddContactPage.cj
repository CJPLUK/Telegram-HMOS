package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.bindings.*
import ohos_app_cangjie_entry.components.SegmentedControl
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.utils.{getCountryList, searchCountries}
import ohos_app_cangjie_entry.viewmodels.getAuthViewModel

/**
 * AddContactPage — 添加联系人页面（P2-145 + 原有 AddContact）（混合工程迁移版）
 *
 * 双模式：
 *   A. 搜索模式（isDeviceContactMode = false，无 route param 或 param = ""）
 *      对应 iOS TelegramUI ContactAddController。
 *      通过手机号或用户名搜索并添加 Telegram 联系人。
 *
 *   B. 设备联系人信息屏（isDeviceContactMode = true，route param = "name|phone"）
 *      对应 iOS PeerInfoUI DeviceContactInfoController（P2-145）。
 *      展示设备通讯录中某联系人的详情（名/电话）。
 *      操作：
 *        - "Add to Telegram"：importContact(phone, firstName, lastName)
 *          成功后显示 Telegram 用户卡并提供 "Send Message"
 *        - "Invite via SMS"：ContactsHelperUtils.sendSmsInvite([phone], inviteLink)
 *          拉起系统短信 App（对应 iOS DeviceContactInfoAction.invite）
 *
 * 路由参数约定（模式 B）：
 *   `routerPush("AddContactPage", "displayName|phoneNumber")`
 *   页面在 ensureLoaded 中经 takePending 解析 param，"|" 分隔 displayName 和 phoneNumber。
 *   若 param 为 "" 或解析失败，降级为搜索模式。
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry；去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹（原 .title("Add Contact") 无 hideTitleBar），只留内容
 *  - pageStack.pop()/pushPathByName → routerPop()/routerPush()
 *  - onReady param 接收 → ensureLoaded()（.onAppear 触发）内 takePending("AddContactPage")
 */
@HybridComponentEntry
@Component
public class AddContactPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // ===== iOS NewContactScreen 模式（Contacts 页右上角 +）=====
    @State var isNewContactMode: Bool = false
    @State var syncContactToPhone: Bool = true
    // iOS NewContactScreen PhoneInputItem：国家行 + 区号前缀，提交号码 = 区号 + 本地号码
    @State var ncCountryName: String = "China mainland"
    @State var ncCountryCode: String = "+86"
    @State var ncCountryFlag: String = "🇨🇳"
    @State var showNcCountryPicker: Bool = false
    @State var ncCountrySearch: String = ""
    @State var ncCountryIndices: Array<Int64> = []

    // ===== 模式 A：搜索模式 =====
    @State var searchMode: Int32 = 0
    @State var username: String = ""
    @State var phoneNumber: String = ""
    @State var firstName: String = ""
    @State var lastName: String = ""
    @State var isSearching: Bool = false
    @State var errorText: String = ""
    @State var hasResult: Bool = false
    @State var resultUserId: Int64 = 0
    @State var resultAccessHash: Int64 = 0
    @State var resultDisplayName: String = ""
    @State var resultUsername: String = ""
    @State var resultPhone: String = ""
    @State var resultInitial: String = ""
    @State var resultFirstName: String = ""
    @State var resultLastName: String = ""
    @State var isAdding: Bool = false
    @State var addSuccess: Bool = false

    // ===== 模式 B：设备联系人信息屏（P2-145）=====
    @State var isDeviceContactMode: Bool = false
    @State var deviceDisplayName: String = ""
    @State var devicePhone: String = ""
    @State var deviceInitial: String = ""
    @State var isImporting: Bool = false
    @State var importError: String = ""
    @State var importHasResult: Bool = false
    @State var importResultUserId: Int64 = 0
    @State var importResultAccessHash: Int64 = 0
    @State var importResultDisplayName: String = ""
    @State var importResultUsername: String = ""
    @State var importResultInitial: String = ""
    @State var importAddSuccess: Bool = false
    @State var importAddError: String = ""
    @State var isSmsInviteSent: Bool = false

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let raw = takePending("AddContactPage")
        if (raw == "new") {
            this.isNewContactMode = true
            // 与 Contacts 页 "+" 表单同源：默认国家取登录号码所在国家。
            let auth = getAuthViewModel()
            if (auth.countryCode.size > 0) {
                this.ncCountryName = auth.countryName
                this.ncCountryCode = auth.countryCode
                this.ncCountryFlag = this.findNcCountryFlag(auth.countryName, auth.countryCode)
            }
            this.ncCountryIndices = searchCountries("")
            return
        }
        if (raw.size > 0 && raw != "{}" && !raw.isEmpty()) {
            this.parseRouteParam(raw)
        }
    }

    private func newContactInputValid(): Bool {
        let local = this.phoneNumber.trimAscii()
        return !this.firstName.trimAscii().isEmpty() && !local.isEmpty() &&
            (local.startsWith("+") || !this.ncCountryCode.trimAscii().isEmpty())
    }

    /** 本地号码拼上区号得到国际号码（已带 "+" 的输入原样使用）。 */
    private func newContactFullPhone(): String {
        let local = this.phoneNumber.trimAscii()
        if (local.startsWith("+")) { return local }
        return this.ncCountryCode.trimAscii() + local
    }

    private func findNcCountryFlag(name: String, code: String): String {
        let countries = getCountryList()
        for (country in countries) {
            if (country[0] == name && country[1] == code) { return country[2] }
        }
        for (country in countries) {
            if (country[1] == code) { return country[2] }
        }
        return "🌐"
    }

    private func updateNcCountryCode(value: String): Unit {
        let entered = value.trimAscii()
        this.ncCountryCode = if (entered.isEmpty() || entered.startsWith("+")) { entered } else { "+" + entered }
        for (country in getCountryList()) {
            if (country[1] == this.ncCountryCode) {
                this.ncCountryName = country[0]
                this.ncCountryFlag = country[2]
                return
            }
        }
    }

    private func ncCountryFieldAt(index: Int64, field: Int64): String {
        let countries = getCountryList()
        if (index >= 0 && index < Int64(countries.size)) { return countries[index][field] }
        return ""
    }

    private func selectNcCountry(index: Int64): Unit {
        let countries = getCountryList()
        if (index >= 0 && index < Int64(countries.size)) {
            this.ncCountryName = countries[index][0]
            this.ncCountryCode = countries[index][1]
            this.ncCountryFlag = countries[index][2]
            this.ncCountrySearch = ""
            this.ncCountryIndices = searchCountries("")
            this.showNcCountryPicker = false
        }
    }

    @Builder
    private func buildNcCountryRow(index: Int64) {
        Row {
            Text(this.ncCountryFieldAt(index, 2))
                .fontSize(24)
                .width(38)
            Text(this.ncCountryFieldAt(index, 0))
                .fontSize(17)
                .fontColor(0xFF000000)
                .layoutWeight(1)
            Text(this.ncCountryFieldAt(index, 1))
                .fontSize(17)
                .fontColor(0xFF8E8E93)
        }
        .width(100.percent)
        .height(50)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.selectNcCountry(index) })
    }

    /**
     * iOS NewContactScreen.complete 的本地等价流程：
     * 1. importContact 写 Telegram；2. Sync to Phone 开启时写系统通讯录；
     * 任一路径成功即完成，Telegram 导入成功时通知 Contacts 列表刷新。
     */
    private func saveNewContact(): Unit {
        if (this.isAdding || !this.newContactInputValid()) { return }
        let first = this.firstName.trimAscii()
        let last = this.lastName.trimAscii()
        let phone = this.newContactFullPhone()
        let syncToPhone = this.syncContactToPhone
        this.isAdding = true
        this.errorText = ""
        let _ = spawn {
            let imported = getRealContactService().importContact(phone, first, last)
            let savedToPhone = if (syncToPhone) {
                getContactsHelperUtils().addSystemContact(first, last, phone)
            } else {
                false
            }
            let importedToTelegram = imported.isSome()
            if (importedToTelegram) {
                setContactsNeedRefresh()
            }
            launch {
                this.isAdding = false
                if (importedToTelegram || savedToPhone) {
                    routerPop()
                } else {
                    this.errorText = "This phone number is not registered on Telegram."
                }
            }
        }
    }

    /**
     * 解析路由参数："displayName|phoneNumber"
     * 成功时进入模式 B，失败时留在模式 A
     */
    func parseRouteParam(raw: String) {
        if (raw.isEmpty()) { return }
        let idx = this.findPipeIndex(raw)
        if (idx < 0) {
            this.deviceDisplayName = raw
            this.devicePhone = ""
        } else {
            this.deviceDisplayName = raw[0..idx]
            if (idx + 1 < raw.size) {
                this.devicePhone = raw[(idx + 1)..]
            } else {
                this.devicePhone = ""
            }
        }
        this.deviceInitial = this.extractInitial(this.deviceDisplayName)
        this.isDeviceContactMode = true
    }

    private func findPipeIndex(s: String): Int64 {
        let runes = s.toRuneArray()
        for (i in 0..runes.size) {
            if (runes[i] == r'|') { return i }
        }
        return -1
    }

    private func extractInitial(name: String): String {
        if (name.isEmpty()) { return "?" }
        let runes = name.toRuneArray()
        return String(runes[0..1])
    }

    // ===== 模式 B 操作：importContact (Add to Telegram) =====
    func importToTelegram() {
        if (this.devicePhone.isEmpty()) {
            this.importError = "No phone number available"
            return
        }
        this.isImporting = true
        this.importError = ""
        this.importHasResult = false
        this.importAddSuccess = false
        let nameParts = this.splitName(this.deviceDisplayName)
        let fnCopy = nameParts[0]
        let lnCopy = nameParts[1]
        let phoneCopy = this.devicePhone
        let _ = spawn {
            try {
                let service = getRealContactService()
                let result = service.importContact(phoneCopy, fnCopy, lnCopy)
                match (result) {
                    case Some(contact) =>
                        let uid = contact.userId
                        let hash = contact.accessHash
                        let displayName = contact.getDisplayName()
                        let uname = contact.username
                        let initial = contact.getInitial()
                        setContactsNeedRefresh()
                        launch {
                            this.importResultUserId = uid
                            this.importResultAccessHash = hash
                            this.importResultDisplayName = displayName
                            this.importResultUsername = uname
                            this.importResultInitial = initial
                            this.importHasResult = true
                            this.isImporting = false
                        }
                    case None =>
                        launch {
                            this.importError = "Phone '${phoneCopy}' is not registered on Telegram"
                            this.isImporting = false
                        }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[AddContactPage] importToTelegram error: ${e}")
                launch {
                    this.importError = "Import failed"
                    this.isImporting = false
                }
            }
        }
    }

    func addImportedContact() {
        this.importAddError = ""
        let uidCopy = this.importResultUserId
        let hashCopy = this.importResultAccessHash
        let nameParts = this.splitName(this.importResultDisplayName)
        let fnCopy = nameParts[0]
        let lnCopy = nameParts[1]
        let phoneCopy = this.devicePhone
        let _ = spawn {
            try {
                let service = getRealContactService()
                let ok = service.addContact(uidCopy, hashCopy, fnCopy, lnCopy, phoneCopy)
                if (ok) {
                    setContactsNeedRefresh()
                    launch {
                        this.importAddSuccess = true
                    }
                } else {
                    launch {
                        this.importAddError = "Failed to add contact"
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[AddContactPage] addImportedContact error: ${e}")
                launch {
                    this.importAddError = "Failed to add contact"
                }
            }
        }
    }

    func inviteDeviceContactViaSms() {
        if (this.devicePhone.isEmpty()) { return }
        let phones = ArrayList<String>()
        phones.add(this.devicePhone)
        let inviteText = getInviteText()
        let utils = getContactsHelperUtils()
        utils.sendSmsInvite(phones, inviteText)
        launch {
            this.isSmsInviteSent = true
        }
        let _ = spawn {
            sleep(Duration.second * 2)
            launch {
                this.isSmsInviteSent = false
            }
        }
    }

    private func splitName(fullName: String): Array<String> {
        let runes = fullName.toRuneArray()
        var spacePos: Int64 = -1
        for (i in 0..runes.size) {
            if (runes[i] == r' ') {
                spacePos = i
                break
            }
        }
        if (spacePos < 0) {
            return [fullName, ""]
        }
        let fn = fullName[0..spacePos]
        let ln = if (spacePos + 1 < fullName.size) { fullName[(spacePos + 1)..] } else { "" }
        return [fn, ln]
    }

    // ===== 模式 A 操作 =====
    func searchByUsername() {
        if (this.username.isEmpty()) { return }
        this.isSearching = true
        this.errorText = ""
        this.hasResult = false
        this.addSuccess = false
        let usernameCopy = this.username
        let _ = spawn {
            try {
                let service = getRealContactService()
                let result = service.resolveUsername(usernameCopy)
                match (result) {
                    case Some(contact) =>
                        let uid = contact.userId
                        let hash = contact.accessHash
                        let displayName = contact.getDisplayName()
                        let uname = contact.username
                        let phone = contact.phone
                        let initial = contact.getInitial()
                        let fname = contact.firstName
                        let lname = contact.lastName
                        launch {
                            this.resultUserId = uid
                            this.resultAccessHash = hash
                            this.resultDisplayName = displayName
                            this.resultUsername = uname
                            this.resultPhone = phone
                            this.resultInitial = initial
                            this.resultFirstName = fname
                            this.resultLastName = lname
                            this.hasResult = true
                            this.isSearching = false
                        }
                    case None =>
                        launch {
                            this.hasResult = false
                            this.errorText = "User '@${usernameCopy}' not found"
                            this.isSearching = false
                        }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[AddContactPage] Search error: ${e}")
                launch {
                    this.errorText = "Search failed"
                    this.isSearching = false
                }
            }
        }
    }

    func searchByPhone() {
        if (this.phoneNumber.isEmpty()) { return }
        if (this.firstName.isEmpty()) {
            this.errorText = "Please enter a first name"
            return
        }
        this.isSearching = true
        this.errorText = ""
        this.hasResult = false
        this.addSuccess = false
        let phoneCopy = this.phoneNumber
        let firstNameCopy = this.firstName
        let lastNameCopy = this.lastName
        let _ = spawn {
            try {
                let service = getRealContactService()
                let result = service.importContact(phoneCopy, firstNameCopy, lastNameCopy)
                match (result) {
                    case Some(contact) =>
                        let uid = contact.userId
                        let hash = contact.accessHash
                        let displayName = contact.getDisplayName()
                        let uname = contact.username
                        let phone = contact.phone
                        let initial = contact.getInitial()
                        let fname = contact.firstName
                        let lname = contact.lastName
                        setContactsNeedRefresh()
                        Hilog.info(0, "CjTelegram", "[AddContactPage] importContact succeeded, refresh signal sent")
                        launch {
                            this.resultUserId = uid
                            this.resultAccessHash = hash
                            this.resultDisplayName = displayName
                            this.resultUsername = uname
                            this.resultPhone = phone
                            this.resultInitial = initial
                            this.resultFirstName = fname
                            this.resultLastName = lname
                            this.hasResult = true
                            this.isSearching = false
                        }
                    case None =>
                        launch {
                            this.hasResult = false
                            this.errorText = "Phone '${phoneCopy}' is not registered on Telegram"
                            this.isSearching = false
                        }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[AddContactPage] Phone search error: ${e}")
                launch {
                    this.errorText = "Search failed"
                    this.isSearching = false
                }
            }
        }
    }

    func doAddContact() {
        this.isAdding = true
        let userIdCopy = this.resultUserId
        let accessHashCopy = this.resultAccessHash
        let firstNameCopy = this.resultFirstName
        let lastNameCopy = this.resultLastName
        let phoneCopy = this.resultPhone
        let _ = spawn {
            try {
                let service = getRealContactService()
                let success = service.addContact(userIdCopy, accessHashCopy, firstNameCopy, lastNameCopy, phoneCopy)
                if (success) {
                    setContactsNeedRefresh()
                    Hilog.info(0, "CjTelegram", "[AddContactPage] Contact added successfully: ${firstNameCopy} ${lastNameCopy}")
                    launch {
                        this.addSuccess = true
                        this.isAdding = false
                    }
                } else {
                    launch {
                        this.errorText = "Failed to add contact"
                        this.isAdding = false
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[AddContactPage] Add contact error: ${e}")
                launch {
                    this.errorText = "Failed to add contact"
                    this.isAdding = false
                }
            }
        }
    }

    // ===== Build: 模式 B — 设备联系人信息屏 =====
    @Builder
    func buildDeviceContactInfoScreen() {
        Column {
            Row {
                Text("<")
                    .fontSize(17)
                    .fontColor(0x317AFF)
                    .onClick({ evt =>
                        routerPop()
                    })
                Blank().layoutWeight(1)
                Text(trSource("Contact Info"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
                Blank().layoutWeight(1)
                Text(trSource("")).width(32)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(0xF7F7F7)
            .alignItems(VerticalAlign.Center)

            Divider().color(0xE5E5EA).strokeWidth(0.5)

            Column {
                Row {
                    Row {
                        Text(this.deviceInitial)
                            .fontSize(28)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0xFFFFFF)
                    }
                    .width(72)
                    .height(72)
                    .borderRadius(36)
                    .backgroundColor(0x317AFF)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(VerticalAlign.Center)
                    .margin(bottom: 12)
                }
                .width(100.percent)
                .justifyContent(FlexAlign.Center)

                Text(this.deviceDisplayName)
                    .fontSize(22)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
                    .textAlign(TextAlign.Center)

                if (this.devicePhone.size > 0) {
                    Text(this.devicePhone)
                        .fontSize(16)
                        .fontColor(0x8E8E93)
                        .margin(top: 4)
                        .textAlign(TextAlign.Center)
                }
            }
            .width(100.percent)
            .padding(top: 32, bottom: 24, left: 16, right: 16)
            .alignItems(HorizontalAlign.Center)

            Divider().color(0xE5E5EA).strokeWidth(0.5)

            Column {
                if (!this.importHasResult) {
                    if (this.isImporting) {
                        Row {
                            LoadingProgress()
                                .width(20)
                                .height(20)
                                .color(0x317AFF)
                            Text("Checking Telegram...")
                                .fontSize(15)
                                .fontColor(0x8E8E93)
                                .margin(left: 8)
                        }
                        .margin(top: 16)
                        .justifyContent(FlexAlign.Center)
                    } else {
                        if (this.importError.size > 0) {
                            Text(this.importError)
                                .fontSize(14)
                                .fontColor(0xFF3B30)
                                .margin(top: 8, bottom: 8)
                                .textAlign(TextAlign.Center)
                        }
                        Button("Add to Telegram")
                            .width(100.percent)
                            .height(48)
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0xFFFFFF)
                            .backgroundColor(0x317AFF)
                            .borderRadius(12)
                            .margin(bottom: 10)
                            .onClick({ evt =>
                                this.importToTelegram()
                            })
                        Button("Invite via SMS")
                            .width(100.percent)
                            .height(48)
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0x317AFF)
                            .backgroundColor(0xF2F2F7)
                            .borderRadius(12)
                            .onClick({ evt =>
                                this.inviteDeviceContactViaSms()
                            })
                    }
                } else {
                    Column {
                        Row {
                            Row {
                                Text(this.importResultInitial)
                                    .fontSize(20)
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(0xFFFFFF)
                            }
                            .width(48)
                            .height(48)
                            .borderRadius(24)
                            .backgroundColor(0x34C759)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(VerticalAlign.Center)
                            .margin(right: 12)

                            Column {
                                Text(this.importResultDisplayName)
                                    .fontSize(17)
                                    .fontColor(0x000000)
                                    .fontWeight(FontWeight.Medium)
                                if (this.importResultUsername.size > 0) {
                                    Text("@${this.importResultUsername}")
                                        .fontSize(14)
                                        .fontColor(0x8E8E93)
                                        .margin(top: 2)
                                }
                            }
                            .layoutWeight(1)
                            .alignItems(HorizontalAlign.Start)
                        }
                        .width(100.percent)
                        .alignItems(VerticalAlign.Center)
                        .margin(bottom: 16)

                        if (this.importAddError.size > 0) {
                            Text(this.importAddError)
                                .fontSize(14)
                                .fontColor(0xFF3B30)
                                .margin(bottom: 8)
                                .textAlign(TextAlign.Center)
                        }

                        Row {
                            if (!this.importAddSuccess) {
                                Button("Save to Contacts")
                                    .layoutWeight(1)
                                    .height(44)
                                    .fontSize(15)
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(0xFFFFFF)
                                    .backgroundColor(0x34C759)
                                    .borderRadius(10)
                                    .margin(right: 8)
                                    .onClick({ evt =>
                                        this.addImportedContact()
                                    })
                            } else {
                                Row {
                                    Text("Saved!")
                                        .fontSize(15)
                                        .fontColor(0x34C759)
                                        .fontWeight(FontWeight.Medium)
                                }
                                .layoutWeight(1)
                                .height(44)
                                .justifyContent(FlexAlign.Center)
                                .alignItems(VerticalAlign.Center)
                                .margin(right: 8)
                            }

                            Button(trSource("Send Message"))
                                .layoutWeight(1)
                                .height(44)
                                .fontSize(15)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0xFFFFFF)
                                .backgroundColor(0x317AFF)
                                .borderRadius(10)
                                .onClick({ evt =>
                                    setSelectedChat(this.importResultUserId, this.importResultDisplayName, "user")
                                    routerPush("ChatRoomPage", this.importResultDisplayName)
                                })
                        }
                        .width(100.percent)
                    }
                    .width(100.percent)
                    .padding(top: 16, bottom: 16, left: 16, right: 16)
                    .backgroundColor(0xF9F9F9)
                    .borderRadius(14)
                    .margin(bottom: 12)
                }

                if (this.isSmsInviteSent) {
                    Text("SMS app opened")
                        .fontSize(14)
                        .fontColor(0x34C759)
                        .margin(top: 8)
                        .textAlign(TextAlign.Center)
                }
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 16, bottom: 24)

            Blank().layoutWeight(1)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFF)
        .padding(bottom: getSafeAreaBottom())
    }

    private func newContactInitial(): String {
        let trimmed = this.firstName.trimAscii()
        if (trimmed.isEmpty()) { return "+" }
        let runes = trimmed.toRuneArray()
        if (runes.isEmpty()) { return "+" }
        return runes[0].toString()
    }

    // ===== Build: iOS NewContactScreen（Contacts 页右上角 +）=====
    @Builder
    func buildNewContactScreen() {
        Column {
            // iOS NewContactScreen 自绘导航栏：左关闭、居中标题、右完成。
            Row {
                Stack {
                    Text("×")
                        .fontSize(24)
                        .fontColor(0xFF1C1C1E)
                }
                .width(44)
                .height(44)
                .borderRadius(22)
                .backgroundColor(0xFFF0F0F2)
                .alignContent(Alignment.Center)
                .onClick({ _evt => routerPop() })

                Text(trSource("New Contact"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0xFF000000)
                    .layoutWeight(1)
                    .textAlign(TextAlign.Center)

                Stack {
                    if (this.isAdding) {
                        LoadingProgress()
                            .width(20)
                            .height(20)
                            .color(0xFFFFFFFF)
                    } else {
                        Image(@r(app.media.callui_ic_check))
                            .width(17)
                            .height(17)
                            .fillColor(0xFFFFFFFF)
                    }
                }
                .width(44)
                .height(44)
                .borderRadius(22)
                .backgroundColor(if (this.newContactInputValid()) { 0xFF007AFF } else { 0xFFB8C7D9 })
                .opacity(if (this.newContactInputValid()) { 1.0 } else { 0.55 })
                .alignContent(Alignment.Center)
                .enabled(this.newContactInputValid() && !this.isAdding)
                .onClick({ _evt => this.saveNewContact() })
            }
            .width(100.percent)
            .height(68.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: 8.0 + getSafeAreaTop())
            .alignItems(VerticalAlign.Center)
            .backgroundColor(0xFFF7F7F8)

            Scroll {
                Column {
                    // 姓名卡：66pt 头像 + First/Last Name，匹配 iOS nameSection。
                    Row {
                        Stack {
                            Text(this.newContactInitial())
                                .fontSize(27)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0xFFFFFFFF)
                        }
                        .width(66)
                        .height(66)
                        .borderRadius(33)
                        .backgroundColor(0xFFB8BEC8)
                        .alignContent(Alignment.Center)
                        .margin(right: 14)

                        Column {
                            TextInput(text: this.firstName, placeholder: trSource("First Name"))
                                .fontSize(17)
                                .height(50)
                                .backgroundColor(Color.Transparent)
                                .padding(left: 0, right: 8)
                                .onChange({ value: String => this.firstName = value })
                            Divider()
                                .color(0xFFE5E5EA)
                                .strokeWidth(0.5)
                            TextInput(text: this.lastName, placeholder: trSource("Last Name"))
                                .fontSize(17)
                                .height(50)
                                .backgroundColor(Color.Transparent)
                                .padding(left: 0, right: 8)
                                .onChange({ value: String => this.lastName = value })
                        }
                        .layoutWeight(1)
                    }
                    .width(100.percent)
                    .padding(left: 15, right: 8, top: 8, bottom: 8)
                    .backgroundColor(0xFFFFFFFF)
                    .borderRadius(16)
                    .alignItems(VerticalAlign.Center)

                    // iOS PhoneInputItem 独立 section：国家行（点开国家列表）+ 区号 | 本地号码。
                    Column {
                        Row {
                            Text(this.ncCountryFlag)
                                .fontSize(23)
                                .width(34)
                            Text(this.ncCountryName)
                                .fontSize(17)
                                .fontColor(0xFF000000)
                                .layoutWeight(1)
                            Text("›")
                                .fontSize(24)
                                .fontColor(0xFFC7C7CC)
                                .margin(left: 8)
                        }
                        .width(100.percent)
                        .height(50)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _ =>
                            this.ncCountrySearch = ""
                            this.ncCountryIndices = searchCountries("")
                            this.showNcCountryPicker = true
                        })
                        Divider()
                            .color(0xFFE5E5EA)
                            .strokeWidth(0.5)
                        Row {
                            TextInput(text: this.ncCountryCode, placeholder: "+")
                                .fontSize(17)
                                .fontColor(0xFF000000)
                                .height(44)
                                .width(72)
                                .backgroundColor(Color.Transparent)
                                .padding(left: 0, right: 4)
                                .onChange({ value: String => this.updateNcCountryCode(value) })
                            TextInput(text: this.phoneNumber, placeholder: trSource("Phone Number"))
                                .fontSize(17)
                                .height(44)
                                .layoutWeight(1)
                                .backgroundColor(Color.Transparent)
                                .padding(left: 0, right: 8)
                                .onChange({ value: String => this.phoneNumber = value })
                        }
                        .width(100.percent)
                        .alignItems(VerticalAlign.Center)
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 8, top: 4, bottom: 4)
                    .backgroundColor(0xFFFFFFFF)
                    .borderRadius(16)
                    .margin(top: 12)

                    // iOS 默认开启 Sync to Phone。
                    Row {
                        Text("Sync to Phone")
                            .fontSize(17)
                            .fontColor(0xFF000000)
                            .layoutWeight(1)
                        Toggle(ToggleType.Switch, isOn: this.syncContactToPhone)
                            .selectedColor(0xFF34C759)
                            .onChange({ value: Bool => this.syncContactToPhone = value })
                    }
                    .width(100.percent)
                    .height(52)
                    .padding(left: 16, right: 12)
                    .backgroundColor(0xFFFFFFFF)
                    .borderRadius(16)
                    .margin(top: 12)
                    .alignItems(VerticalAlign.Center)

                    if (this.errorText.size > 0) {
                        Text(this.errorText)
                            .fontSize(13)
                            .fontColor(0xFFFF3B30)
                            .width(100.percent)
                            .margin(top: 10)
                            .padding(left: 8, right: 8)
                    }
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 16, bottom: 32)
            }
            .width(100.percent)
            .layoutWeight(1)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFF2F2F7)
        .padding(bottom: getSafeAreaBottom())
    }

    // ===== Build: 模式 A — 搜索模式 =====
    @Builder
    func buildSearchScreen() {
        Column {
            Column {
                SegmentedControl(
                    segments: ["Phone Number", "Username"],
                    selectedIndex: Int64(this.searchMode),
                    onChange: { idx: Int64 =>
                        this.searchMode = Int32(idx)
                        this.hasResult = false
                        this.errorText = ""
                        this.addSuccess = false
                    }
                )
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 16, bottom: 16)

            if (this.searchMode == 0) {
                Column {
                    Text("Search by Phone Number")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(bottom: 8)

                    TextInput(placeholder: "+1234567890")
                        .width(100.percent)
                        .height(44)
                        .backgroundColor(0xF2F2F7)
                        .borderRadius(10)
                        .padding(left: 14, right: 14)
                        .margin(bottom: 10)
                        .onChange({ value: String =>
                            this.phoneNumber = value
                        })

                    Row {
                        TextInput(placeholder: "First name")
                            .layoutWeight(1)
                            .height(44)
                            .backgroundColor(0xF2F2F7)
                            .borderRadius(10)
                            .padding(left: 14, right: 14)
                            .margin(right: 6)
                            .onChange({ value: String =>
                                this.firstName = value
                            })

                        TextInput(placeholder: "Last name")
                            .layoutWeight(1)
                            .height(44)
                            .backgroundColor(0xF2F2F7)
                            .borderRadius(10)
                            .padding(left: 14, right: 14)
                            .margin(left: 6)
                            .onChange({ value: String =>
                                this.lastName = value
                            })
                    }
                    .width(100.percent)
                    .margin(bottom: 16)

                    Button(trSource("Search"))
                        .width(100.percent)
                        .height(44)
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(0xFFFFFF)
                        .backgroundColor(if (this.phoneNumber.isEmpty() || this.firstName.isEmpty() || this.isSearching) { 0xC7C7CC } else { 0x317AFF })
                        .borderRadius(10)
                        .onClick({ evt =>
                            this.searchByPhone()
                        })
                }
                .width(100.percent)
                .padding(left: 16, right: 16)
            }

            if (this.searchMode == 1) {
                Column {
                    Text("Search by Username")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(bottom: 8)

                    Row {
                        Text("@")
                            .fontSize(18)
                            .fontColor(0x8E8E93)
                            .margin(right: 6)

                        TextInput(placeholder: trSource("username"))
                            .layoutWeight(1)
                            .height(44)
                            .backgroundColor(0xF2F2F7)
                            .borderRadius(10)
                            .padding(left: 14, right: 14)
                            .onChange({ value: String =>
                                this.username = value
                            })

                        Button(trSource("Search"))
                            .width(80)
                            .height(44)
                            .fontSize(15)
                            .fontColor(0xFFFFFF)
                            .backgroundColor(if (this.username.isEmpty() || this.isSearching) { 0xC7C7CC } else { 0x317AFF })
                            .borderRadius(10)
                            .margin(left: 10)
                            .onClick({ evt =>
                                this.searchByUsername()
                            })
                    }
                    .width(100.percent)
                    .alignItems(VerticalAlign.Center)
                }
                .width(100.percent)
                .padding(left: 16, right: 16)
            }

            if (this.isSearching) {
                Row {
                    LoadingProgress()
                        .width(20)
                        .height(20)
                        .color(0x317AFF)
                    Text(trSource("Searching..."))
                        .fontSize(15)
                        .fontColor(0x8E8E93)
                        .margin(left: 8)
                }
                .margin(top: 24)
                .justifyContent(FlexAlign.Center)
            }

            if (this.errorText.size > 0 && !this.isSearching) {
                Text(this.errorText)
                    .fontSize(15)
                    .fontColor(0xFF3B30)
                    .margin(top: 24)
                    .padding(left: 16, right: 16)
                    .textAlign(TextAlign.Center)
            }

            if (this.hasResult) {
                Column {
                    Row {
                        Row {
                            Text(this.resultInitial)
                                .fontSize(22)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0xFFFFFF)
                        }
                        .width(56)
                        .height(56)
                        .borderRadius(28)
                        .backgroundColor(0x317AFF)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(VerticalAlign.Center)
                        .margin(right: 16)

                        Column {
                            Text(this.resultDisplayName)
                                .fontSize(17)
                                .fontColor(0x000000)
                                .fontWeight(FontWeight.Medium)

                            if (this.resultUsername.size > 0) {
                                Text("@${this.resultUsername}")
                                    .fontSize(14)
                                    .fontColor(0x8E8E93)
                                    .margin(top: 2)
                            }

                            if (this.resultPhone.size > 0) {
                                Text(this.resultPhone)
                                    .fontSize(14)
                                    .fontColor(0x8E8E93)
                                    .margin(top: 2)
                            }
                        }
                        .layoutWeight(1)
                        .alignItems(HorizontalAlign.Start)
                    }
                    .width(100.percent)
                    .alignItems(VerticalAlign.Center)

                    Row {
                        if (!this.addSuccess) {
                            Button(if (this.isAdding) { "Adding..." } else { "Add Contact" })
                                .layoutWeight(1)
                                .height(44)
                                .fontSize(15)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0xFFFFFF)
                                .backgroundColor(if (this.isAdding) { 0xC7C7CC } else { 0x34C759 })
                                .borderRadius(10)
                                .margin(right: 8)
                                .onClick({ evt =>
                                    if (!this.isAdding) {
                                        this.doAddContact()
                                    }
                                })
                        }

                        if (this.addSuccess) {
                            Row {
                                Text("Added!")
                                    .fontSize(15)
                                    .fontColor(0x34C759)
                                    .fontWeight(FontWeight.Medium)
                            }
                            .layoutWeight(1)
                            .height(44)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(VerticalAlign.Center)
                            .margin(right: 8)
                        }

                        Button(trSource("Send Message"))
                            .layoutWeight(1)
                            .height(44)
                            .fontSize(15)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0xFFFFFF)
                            .backgroundColor(0x317AFF)
                            .borderRadius(10)
                            .onClick({ evt =>
                                setSelectedChat(this.resultUserId, this.resultDisplayName, "user")
                                routerPush("ChatRoomPage", this.resultDisplayName)
                            })
                    }
                    .width(100.percent)
                    .margin(top: 20)
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 24, bottom: 24)
                .margin(top: 16, left: 16, right: 16)
                .backgroundColor(0xF9F9F9)
                .borderRadius(14)
            }

            Blank().layoutWeight(1)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFF)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
    }

    // 国家选择列表（Contacts 页 "+" 表单同款），覆盖在 New Contact 表单之上。
    @Builder
    func buildNcCountryPicker() {
        Column {
            Row {
                Text("‹")
                    .fontSize(32)
                    .fontColor(0xFF007AFF)
                    .width(38)
                    .onClick({ _ => this.showNcCountryPicker = false })
                Text(trSource("Country"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0xFF000000)
                    .layoutWeight(1)
                    .textAlign(TextAlign.Center)
                Blank().width(38)
            }
            .width(100.percent)
            .height(52.0 + getSafeAreaTop())
            .padding(left: 12, right: 12, top: getSafeAreaTop())
            .alignItems(VerticalAlign.Center)

            TextInput(text: this.ncCountrySearch, placeholder: trSource("Search"))
                .fontSize(16)
                .height(38)
                .width(100.percent)
                .backgroundColor(0xFFE9E9ED)
                .borderRadius(10)
                .padding(left: 12, right: 12)
                .margin(left: 16, right: 16, bottom: 8)
                .onChange({ value: String =>
                    this.ncCountrySearch = value
                    this.ncCountryIndices = searchCountries(value)
                })

            Divider().color(0xFFE5E5EA).strokeWidth(0.5)

            Scroll {
                Column {
                    ForEach(this.ncCountryIndices, itemGenerator: { index: Int64, _position: Int64 =>
                        this.buildNcCountryRow(index)
                        Divider()
                            .color(0xFFE5E5EA)
                            .strokeWidth(0.5)
                            .margin(left: 54)
                    })
                }
                .width(100.percent)
            }
            .width(100.percent)
            .layoutWeight(1)
            .scrollable(ScrollDirection.Vertical)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFFFF)
        .padding(bottom: getSafeAreaBottom())
    }

    public func build() {
        Column {
            if (this.isNewContactMode && this.showNcCountryPicker) {
                this.buildNcCountryPicker()
            } else if (this.isNewContactMode) {
                this.buildNewContactScreen()
            } else if (this.isDeviceContactMode) {
                this.buildDeviceContactInfoScreen()
            } else {
                this.buildSearchScreen()
            }
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ => this.ensureLoaded() })
    }
}
