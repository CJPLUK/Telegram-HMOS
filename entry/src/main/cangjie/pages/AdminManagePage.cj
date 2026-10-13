package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.models.AdminMemberData
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.components.SearchBar
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * P2-135b: 管理员管理页面 + 所有权转让 picker（混合工程迁移版）
 *
 * 功能:
 * - 管理员列表（channelParticipantsAdmins 过滤器，真实 RPC）
 * - 展开管理员：权限勾选（ChatAdminRights flags）+ 标题编辑 + 保存（channels.editAdmin#9a98ad68）
 * - Owner 不可编辑（显示只读权限摘要）
 * - 页面底部 "Transfer Ownership" 入口
 * - 所有权转让 picker：加载频道成员 → 选人 → 确认 → channels.editCreator#8f38cd1f
 *
 * ChatAdminRights flags（iOS Api4.swift / telegram_api.tl 核对）:
 *   bit 0  change_info   bit 1  post_messages  bit 2  edit_messages
 *   bit 3  delete_messages  bit 4  ban_users   bit 5  invite_users
 *   bit 7  pin_messages  bit 9  add_admins   bit 11 manage_call
 *   bit 13 manage_topics
 *
 * channels.editAdmin ctor: 0x9a98ad68 (iOS Api42:3500 verified)
 * channels.editCreator ctor: 0x8f38cd1f (iOS telegram_api.tl:2496 verified)
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry；去掉 @Consume NavPathStack（此页无栈依赖）
 *  - build() 根去掉 NavDestination 包裹（原 .title("Administrators") 无 hideTitleBar），只留内容
 *  - aboutToAppear 实逻辑 → ensureLoaded()（.onAppear 触发）
 */
@HybridComponentEntry
@Component
public class AdminManagePage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // ---- 管理员列表 ----
    @State var admins: ArrayList<AdminMemberData> = ArrayList<AdminMemberData>()
    @State var isLoading: Bool = true
    @State var selectedAdmin: Int64 = 0
    @State var isSaving: Bool = false
    @State var saveResult: String = ""

    // ---- 当前编辑中的权限 flags（展开某管理员时复制，修改后保存） ----
    @State var editingFlags: Int32 = 0
    @State var editingRank: String = ""

    // ---- 所有权转让 picker ----
    // channelAccessHash: ensureLoaded 中由 getCachedChat 回填，editCreator 使用
    @State var channelAccessHash: Int64 = 0
    @State var showOwnerPicker: Bool = false
    @State var pickerMembers: ArrayList<ContactDisplayData> = ArrayList<ContactDisplayData>()
    @State var pickerLoading: Bool = false
    @State var pickerSearchText: String = ""
    @State var selectedNewOwnerName: String = ""
    @State var selectedNewOwnerId: Int64 = 0
    @State var selectedNewOwnerHash: Int64 = 0
    @State var showTransferConfirm: Bool = false
    @State var transferStatus: String = ""
    @State var isTransferring: Bool = false
    @State var transferPassword: String = ""
    @State var peerType: String = "channel"
    @State var isCreator: Bool = false

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.peerType = getSelectedChatPeerType()
        this.loadAccessHashFromCache()
        this.loadAdmins()
    }

    private func loadAccessHashFromCache(): Unit {
        let pid = getSelectedChatId()
        let chatListSvc = getRealChatListService()
        match (chatListSvc.getCachedChat(pid)) {
            case Some(chat) =>
                this.channelAccessHash = chat.accessHash
                this.isCreator = chat.isCreator
            case None => ()
        }
    }

    // ==================== 数据加载 ====================

    private func loadAdmins(): Unit {
        this.isLoading = true
        let peerId = getSelectedChatId()
        let _ = spawn {
            try {
                let adminList = ArrayList<AdminMemberData>()
                if (this.peerType == "chat") {
                    let members = getPeerInfoService().getParticipantsByFilter(peerId, "admins", 0, 200, "")
                    for (member in members.members) {
                        let admin = AdminMemberData()
                        admin.userId = member.userId
                        admin.userAccessHash = member.accessHash
                        admin.firstName = member.firstName
                        admin.lastName = member.lastName
                        admin.rank = member.rank
                        admin.isCreator = member.isCreator
                        admin.adminFlags = if (member.isAdmin) { 1 } else { 0 }
                        adminList.add(admin)
                    }
                } else {
                    for (admin in getRealMessageService().getChannelAdmins(peerId)) { adminList.add(admin) }
                }
                Hilog.info(0, "CjTelegram", "[AdminManagePage] Loaded ${adminList.size} admins")
                launch {
                    this.admins = adminList
                    this.isLoading = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[AdminManagePage] loadAdmins failed: ${e}")
                launch { this.isLoading = false }
            }
        }
    }

    private func loadPickerMembers(): Unit {
        this.pickerLoading = true
        let peerId = getSelectedChatId()
        let _ = spawn {
            try {
                let msgService = getRealMessageService()
                let members = msgService.getChannelMembers(peerId, "recent")
                Hilog.info(0, "CjTelegram", "[AdminManagePage] Picker loaded ${members.size} members")
                launch {
                    this.pickerMembers = members
                    this.pickerLoading = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[AdminManagePage] loadPickerMembers failed: ${e}")
                launch { this.pickerLoading = false }
            }
        }
    }

    // ==================== 管理员权限编辑 ====================

    private func getAdminEntries(): Array<AdminMemberData> {
        return this.admins.toArray()
    }

    private func isExpanded(userId: Int64): Bool {
        return this.selectedAdmin == userId
    }

    private func toggleExpand(userId: Int64, admin: AdminMemberData): Unit {
        if (this.selectedAdmin == userId) {
            this.selectedAdmin = 0
        } else {
            this.selectedAdmin = userId
            this.editingFlags = admin.adminFlags
            this.editingRank = admin.rank
            this.saveResult = ""
        }
    }

    private func togglePermissionBit(bit: Int32): Unit {
        if ((this.editingFlags & bit) != 0) {
            this.editingFlags = this.editingFlags ^ bit
        } else {
            this.editingFlags = this.editingFlags | bit
        }
    }

    private func hasEditingPermission(bit: Int32): Bool {
        return (this.editingFlags & bit) != 0
    }

    private func saveAdminRights(admin: AdminMemberData): Unit {
        this.isSaving = true
        this.saveResult = ""
        let peerId = getSelectedChatId()
        let userId = admin.userId
        let userHash = admin.userAccessHash
        let flags = this.editingFlags
        let rank = this.editingRank

        let _ = spawn {
            try {
                let msgService = getRealMessageService()
                let success = if (this.peerType == "chat") {
                    msgService.editBasicGroupAdmin(peerId, userId, userHash, flags != 0)
                } else {
                    msgService.editAdmin(peerId, userId, userHash, flags, rank)
                }
                if (success) {
                    admin.adminFlags = flags
                    admin.rank = rank
                    Hilog.info(0, "CjTelegram", "[AdminManagePage] editAdmin success")
                    let updatedList = ArrayList<AdminMemberData>()
                    for (a in this.admins) { updatedList.add(a) }
                    launch {
                        this.saveResult = "Saved"
                        this.admins = updatedList
                        this.isSaving = false
                        getPeerInfoService().invalidateGroupFullInfo(peerId)
                        notifyPeerInfoChanged()
                    }
                } else {
                    Hilog.info(0, "CjTelegram", "[AdminManagePage] editAdmin returned false")
                    launch {
                        this.saveResult = "Failed"
                        this.isSaving = false
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[AdminManagePage] editAdmin error: ${e}")
                launch {
                    this.saveResult = "Error"
                    this.isSaving = false
                }
            }
        }
    }

    // ==================== 所有权转让 ====================

    private func openOwnerPicker(): Unit {
        this.showOwnerPicker = true
        this.pickerSearchText = ""
        this.selectedNewOwnerName = ""
        this.selectedNewOwnerId = 0
        this.selectedNewOwnerHash = 0
        this.showTransferConfirm = false
        this.transferStatus = ""
        if (this.pickerMembers.size == 0) {
            this.loadPickerMembers()
        }
    }

    private func selectNewOwner(member: ContactDisplayData): Unit {
        this.selectedNewOwnerId = member.userId
        this.selectedNewOwnerHash = member.accessHash
        let displayName = if (member.firstName.size > 0 || member.lastName.size > 0) {
            if (member.lastName.size > 0) {
                "${member.firstName} ${member.lastName}"
            } else {
                member.firstName
            }
        } else {
            "@${member.username}"
        }
        this.selectedNewOwnerName = displayName
        this.showTransferConfirm = true
    }

    private func confirmTransfer(): Unit {
        this.isTransferring = true
        this.transferStatus = ""
        let peerId = getSelectedChatId()
        let newOwnerId = this.selectedNewOwnerId
        let newOwnerHash = this.selectedNewOwnerHash
        let password = this.transferPassword

        let _ = spawn {
            try {
                let svc = getPeersService()
                let channelHash = this.channelAccessHash
                let pwd = getRealAuthService().computeCurrentPasswordSRP(password)
                let result = svc.editCreator(peerId, channelHash, newOwnerId, newOwnerHash, pwd)
                Hilog.info(0, "CjTelegram", "[AdminManagePage] editCreator result: ${result.success}")
                if (result.success) {
                    launch {
                        this.transferStatus = "Ownership transferred"
                        this.isTransferring = false
                        this.showTransferConfirm = false
                        this.showOwnerPicker = false
                        this.loadAdmins()
                    }
                } else {
                    let code = result.errorCode
                    Hilog.info(0, "CjTelegram", "[AdminManagePage] editCreator error: ${code}")
                    launch {
                        this.transferStatus = if (code == "PASSWORD_HASH_INVALID" || code == "SRP_ID_INVALID") {
                            "Incorrect password or expired verification session"
                        } else {
                            "Transfer failed: ${code}"
                        }
                        this.isTransferring = false
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[AdminManagePage] editCreator exception: ${e}")
                launch {
                    this.transferStatus = "Transfer error"
                    this.isTransferring = false
                }
            }
        }
    }

    private func getFilteredPickerMembers(): Array<ContactDisplayData> {
        let all = this.pickerMembers.toArray()
        if (this.pickerSearchText.size == 0) {
            return all
        }
        let q = this.pickerSearchText
        let filtered = ArrayList<ContactDisplayData>()
        for (m in all) {
            let name = "${m.firstName} ${m.lastName} ${m.username}"
            if (name.contains(q)) {
                filtered.add(m)
            }
        }
        return filtered.toArray()
    }

    private func getMemberInitial(m: ContactDisplayData): String {
        if (m.firstName.size > 0) {
            return m.firstName.toRuneArray()[0].toString()
        }
        if (m.username.size > 0) {
            return m.username.toRuneArray()[0].toString()
        }
        return "?"
    }

    private func getMemberName(m: ContactDisplayData): String {
        if (m.firstName.size > 0 || m.lastName.size > 0) {
            if (m.lastName.size > 0) {
                return "${m.firstName} ${m.lastName}"
            }
            return m.firstName
        }
        return "@${m.username}"
    }

    // ==================== Build ====================

    public func build() {
        Stack {
            Column {
                if (this.isLoading) {
                    Column {
                        Text("Loading admins...")
                            .fontSize(15)
                            .fontColor(0x8E8E93)
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                } else {
                    Scroll {
                        Column {
                            Text("ADMINISTRATORS")
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .margin(left: 16, top: 16, bottom: 8)
                                .width(100.percent)

                            Column {
                                ForEach(this.getAdminEntries(), itemGenerator: { admin: AdminMemberData, _idx: Int64 =>
                                    Column {
                                        Row {
                                            Row {
                                                Text(this.getAdminInitial(admin))
                                                    .fontSize(16)
                                                    .fontWeight(FontWeight.Bold)
                                                    .fontColor(0xFFFFFF)
                                            }
                                            .width(40)
                                            .height(40)
                                            .borderRadius(20)
                                            .backgroundColor(this.getAdminColor(admin))
                                            .justifyContent(FlexAlign.Center)
                                            .margin(right: 12)

                                            Column {
                                                Text(admin.getDisplayName())
                                                    .fontSize(16)
                                                    .fontColor(0x000000)
                                                Text(admin.getRoleLabel())
                                                    .fontSize(13)
                                                    .fontColor(this.getRoleLabelColor(admin))
                                                    .margin(top: 2)
                                            }
                                            .alignItems(HorizontalAlign.Start)
                                            .layoutWeight(1)

                                            Text(this.getChevron(admin.userId))
                                                .fontSize(14)
                                                .fontColor(0xCCCCCC)
                                        }
                                        .width(100.percent)
                                        .padding(left: 16, right: 16, top: 12, bottom: 12)
                                        .onClick({ _evt =>
                                            this.toggleExpand(admin.userId, admin)
                                        })

                                        if (this.isExpanded(admin.userId)) {
                                            Column {
                                                if (admin.isCreator) {
                                                    Text("Owner has all permissions")
                                                        .fontSize(13)
                                                        .fontColor(0x8E8E93)
                                                        .margin(top: 4, bottom: 8)
                                                } else {
                                                    if (this.peerType == "chat") {
                                                        Button(if (this.isSaving) { "Saving..." } else { "Remove Admin" })
                                                            .fontSize(15)
                                                            .fontColor(0xFFFFFF)
                                                            .backgroundColor(if (this.isSaving) { 0xB0B0B0 } else { 0xFF3B30 })
                                                            .borderRadius(8)
                                                            .height(40)
                                                            .width(100.percent)
                                                            .enabled(!this.isSaving)
                                                            .onClick({ _evt =>
                                                                this.editingFlags = 0
                                                                this.saveAdminRights(admin)
                                                            })
                                                    } else {
                                                    this.editablePermRow("Change Info", 1)
                                                    this.editablePermRow("Post Messages", 2)
                                                    this.editablePermRow("Edit Messages", 4)
                                                    this.editablePermRow("Delete Messages", 8)
                                                    this.editablePermRow("Ban Users", 16)
                                                    this.editablePermRow("Invite Users", 32)
                                                    this.editablePermRow("Pin Messages", 128)
                                                    this.editablePermRow("Add Admins", 512)
                                                    this.editablePermRow("Manage Calls", 2048)
                                                    this.editablePermRow("Manage Topics", 8192)

                                                    Row {
                                                        Text(trSource("Title"))
                                                            .fontSize(14)
                                                            .fontColor(0x333333)
                                                            .margin(right: 12)
                                                        TextInput(text: this.editingRank, placeholder: "Custom title...")
                                                            .layoutWeight(1)
                                                            .fontSize(14)
                                                            .onChange({ value: String =>
                                                                this.editingRank = value
                                                            })
                                                    }
                                                    .width(100.percent)
                                                    .height(44)
                                                    .alignItems(VerticalAlign.Center)
                                                    .padding(top: 4)

                                                    Row {
                                                        Button(if (this.isSaving) { "Saving..." } else { "Save Changes" })
                                                            .fontSize(15)
                                                            .fontColor(0xFFFFFF)
                                                            .backgroundColor(if (this.isSaving) { 0xB0B0B0 } else { 0x317AFF })
                                                            .borderRadius(8)
                                                            .height(40)
                                                            .width(100.percent)
                                                            .enabled(!this.isSaving)
                                                            .onClick({ _evt =>
                                                                this.saveAdminRights(admin)
                                                            })
                                                    }
                                                    .width(100.percent)
                                                    .padding(top: 12)

                                                    if (this.saveResult.size > 0) {
                                                        Text(this.saveResult)
                                                            .fontSize(13)
                                                            .fontColor(if (this.saveResult == "Saved") { 0x34C759 } else { 0xFF3B30 })
                                                            .margin(top: 4)
                                                    }
                                                    }
                                                }
                                            }
                                            .width(100.percent)
                                            .padding(left: 52, right: 16, top: 4, bottom: 12)
                                            .backgroundColor(0xF8F8F8)
                                        }
                                    }
                                })
                            }
                            .backgroundColor(0xFFFFFF)
                            .borderRadius(12)
                            .margin(left: 16, right: 16)

                            Text("Admins can manage messages, members, and group settings based on their permissions.")
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .margin(left: 16, right: 16, top: 8)

                            if (this.peerType == "channel" && this.isCreator) {
                            Column {
                                Button("Transfer Ownership")
                                    .fontSize(15)
                                    .fontColor(0xFF3B30)
                                    .backgroundColor(0xFFFFFF)
                                    .borderRadius(12)
                                    .height(50)
                                    .width(100.percent)
                                    .onClick({ _evt =>
                                        this.openOwnerPicker()
                                    })
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 12, bottom: 40)
                            }
                        }
                        .width(100.percent)
                    }
                    .align(Alignment.Top)
                    .layoutWeight(1)
                }
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xF2F2F7)
            .padding(bottom: getSafeAreaBottom())

            if (this.showOwnerPicker) {
                this.ownerPickerOverlay()
            }
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ => this.ensureLoaded() })
    }

    // ==================== @Builder 子构建器 ====================

    @Builder
    func editablePermRow(label: String, bit: Int32) {
        Row {
            Text(label)
                .fontSize(14)
                .fontColor(0x333333)
                .layoutWeight(1)
            Toggle(ToggleType.Switch, isOn: this.hasEditingPermission(bit))
                .width(48)
                .height(28)
                .onChange({ isOn: Bool =>
                    this.togglePermissionBit(bit)
                })
        }
        .width(100.percent)
        .height(40)
        .alignItems(VerticalAlign.Center)
    }

    @Builder
    func ownerPickerOverlay() {
        Column {
            Column {
                Row {
                    Text("Transfer Ownership")
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(0x000000)
                        .layoutWeight(1)
                    Button(trSource("Cancel"))
                        .fontSize(15)
                        .fontColor(0x317AFF)
                        .backgroundColor(Color.Transparent)
                        .onClick({ _evt =>
                            this.showOwnerPicker = false
                            this.showTransferConfirm = false
                            this.transferStatus = ""
                        })
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 16, bottom: 12)

                if (!this.showTransferConfirm) {
                    // P2-RETRO-search-c: 手搓 TextInput → SearchBar 原子
                    // SearchBar 是 @Component，不能直接链内置属性（D-120），外包 Column 添加 margin
                    Column {
                        SearchBar(
                            loading: false,
                            backArrow: false,
                            text: this.pickerSearchText,
                            hint: "Search members...",
                            onChange: { value: String =>
                                this.pickerSearchText = value
                            }
                        )
                    }
                    .width(100.percent)
                    .margin(bottom: 8)

                    if (this.pickerLoading) {
                        Column {
                            Text("Loading members...")
                                .fontSize(14)
                                .fontColor(0x8E8E93)
                        }
                        .width(100.percent)
                        .height(120)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                    } else {
                        Scroll {
                            Column {
                                ForEach(this.getFilteredPickerMembers(), itemGenerator: { m: ContactDisplayData, _idx: Int64 =>
                                    Row {
                                        Row {
                                            Text(this.getMemberInitial(m))
                                                .fontSize(14)
                                                .fontWeight(FontWeight.Bold)
                                                .fontColor(0xFFFFFF)
                                        }
                                        .width(36)
                                        .height(36)
                                        .borderRadius(18)
                                        .backgroundColor(0x317AFF)
                                        .justifyContent(FlexAlign.Center)
                                        .margin(right: 12)

                                        Text(this.getMemberName(m))
                                            .fontSize(15)
                                            .fontColor(0x000000)
                                            .layoutWeight(1)
                                    }
                                    .width(100.percent)
                                    .height(52)
                                    .padding(left: 16, right: 16)
                                    .alignItems(VerticalAlign.Center)
                                    .onClick({ _evt =>
                                        this.selectNewOwner(m)
                                    })
                                })
                            }
                            .width(100.percent)
                        }
                        .height(300)
                    }
                } else {
                    Column {
                        Text("Transfer ownership to")
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .margin(bottom: 4)
                        Text(this.selectedNewOwnerName)
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0x000000)
                            .margin(bottom: 12)
                        Text("The new owner will have full control of this channel. This action cannot be undone.")
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .margin(bottom: 16)

                        TextInput(text: this.transferPassword, placeholder: "2-Step Verification password")
                            .width(100.percent)
                            .height(44)
                            .fontSize(15)
                            .backgroundColor(0xFFF2F2F7)
                            .borderRadius(10)
                            .padding(left: 12, right: 12)
                            .margin(bottom: 12)
                            .onChange({ value: String => this.transferPassword = value })

                        if (this.transferStatus.size > 0) {
                            Text(this.transferStatus)
                                .fontSize(13)
                                .fontColor(if (this.transferStatus == "Ownership transferred") { 0x34C759 } else { 0xFF3B30 })
                                .margin(bottom: 12)
                        }

                        Row {
                            Button(trSource("Back"))
                                .fontSize(15)
                                .fontColor(0x317AFF)
                                .backgroundColor(0xF0F0F5)
                                .borderRadius(10)
                                .height(44)
                                .layoutWeight(1)
                                .margin(right: 8)
                                .onClick({ _evt =>
                                    this.showTransferConfirm = false
                                    this.transferStatus = ""
                                })

                            Button(if (this.isTransferring) { "Transferring..." } else { "Transfer" })
                                .fontSize(15)
                                .fontColor(0xFFFFFF)
                                .backgroundColor(if (this.isTransferring) { 0xB0B0B0 } else { 0xFF3B30 })
                                .borderRadius(10)
                                .height(44)
                                .layoutWeight(1)
                                .enabled(!this.isTransferring && this.transferPassword.size > 0)
                                .onClick({ _evt =>
                                    this.confirmTransfer()
                                })
                        }
                        .width(100.percent)
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, bottom: 16)
                    .alignItems(HorizontalAlign.Center)
                }
            }
            .width(100.percent)
            .backgroundColor(0xFFFFFF)
            .borderRadius(16)
            .margin(left: 8, right: 8, bottom: 8)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x80000000)
        .justifyContent(FlexAlign.End)
        .onClick({ _evt =>
            this.showOwnerPicker = false
        })
    }

    // ==================== Helper functions ====================

    private func getAdminInitial(admin: AdminMemberData): String {
        if (admin.firstName.size > 0) {
            return admin.firstName.toRuneArray()[0].toString()
        }
        return "?"
    }

    private func getAdminColor(admin: AdminMemberData): Int64 {
        if (admin.isCreator) { return 0xFF9800 }
        return 0x317AFF
    }

    private func getRoleLabelColor(admin: AdminMemberData): Int64 {
        if (admin.isCreator) { return 0xFF9800 }
        return 0x0088CC
    }

    private func getChevron(userId: Int64): String {
        if (this.selectedAdmin == userId) { return "▼" }
        return "▶"
    }
}
