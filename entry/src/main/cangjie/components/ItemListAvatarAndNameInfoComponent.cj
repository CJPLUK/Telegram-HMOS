package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*

/**
 * ItemListAvatarAndNameInfoComponent — 资料头部项组件
 *
 * 对应 iOS ItemListAvatarAndNameInfoItemNode（ItemListAvatarAndNameItem.swift）
 *
 * 布局:
 * ┌─────────────────────────────────────────────────────────┐
 * │  [大头像 66px]   显示名称 (粗体 19pt)                   │
 * │                  状态文本 / 成员数 (灰色 15pt)           │
 * │  [编辑态: 名字输入框 / 频道标题输入框]                  │
 * └─────────────────────────────────────────────────────────┘
 *
 * 使用方:
 *   ItemListAvatarAndNameInfoComponent(
 *       peerId: 12345,
 *       peerType: "user",
 *       isEditing: this.isEditingProfile,
 *       onNameChanged: { name => this.pendingName = name },
 *       onAvatarTapped: { => this.openAvatarPicker() }
 *   )
 */
@Component
public class ItemListAvatarAndNameInfoComponent {
    // ---- 入参 ----
    var peerId: Int64 = 0
    var peerType: String = "user"
    var isEditing: Bool = false

    // 编辑完成回调：用户名称（user）或标题（channel/group）变更时触发
    public var onNameChanged: (String) -> Unit = { _name: String => }
    // 头像点击回调
    public var onAvatarTapped: () -> Unit = { => }
    // 编辑完成（按回车）回调
    public var onEditingCompleted: () -> Unit = { => }

    // ---- 展示状态 ----
    @State var displayName: String = ""
    @State var avatarUrl: String = ""
    @State var statusText: String = ""
    @State var isOnline: Bool = false
    @State var memberCount: Int64 = 0
    @State var isChannel: Bool = false

    // ---- 编辑态状态 ----
    @State var editFirstName: String = ""
    @State var editLastName: String = ""
    @State var editTitle: String = ""

    // ---- 更新结果 ----
    @State var isSaving: Bool = false
    @State var saveResult: String = ""

    public override func aboutToAppear(): Unit {
        this.loadData()
    }

    public override func aboutToDisappear(): Unit {
        // 清理即可，无需额外操作
    }

    private func loadData(): Unit {
        let service = getItemListAvatarAndNameInfoService()
        let data = service.getAvatarAndNameInfo(this.peerId, this.peerType)
        this.displayName = data.displayName
        this.avatarUrl = data.avatarUrl
        this.statusText = data.statusText
        this.isOnline = data.isOnline
        this.memberCount = data.memberCount
        this.isChannel = data.isChannel
        this.editFirstName = data.firstName
        this.editLastName = data.lastName
        this.editTitle = data.displayName
    }

    // ---- 编辑态提交 ----

    private func submitNameChange(): Unit {
        if (this.isSaving) { return }
        this.isSaving = true
        let firstName = this.editFirstName
        let lastName = this.editLastName
        let title = this.editTitle
        let isPerson = this.peerType == "user" || this.peerType == ""
        let peerId = this.peerId
        let accessHash = getItemListAvatarAndNameInfoService().getAvatarAndNameInfo(peerId, this.peerType).accessHash
        let isChannelCopy = this.isChannel

        let _ = spawn {
            let service = getItemListAvatarAndNameInfoService()
            let success = performNameUpdate(
                service,
                isPerson,
                firstName,
                lastName,
                peerId,
                accessHash,
                isChannelCopy,
                title
            )
            if (success) {
                let updatedName = computeUpdatedName(isPerson, firstName, lastName, title)
                launch {
                    this.isSaving = false
                    this.displayName = updatedName
                    this.onNameChanged(updatedName)
                    this.saveResult = "saved"
                    this.onEditingCompleted()
                }
            } else {
                launch {
                    this.isSaving = false
                    this.saveResult = "error"
                }
            }
        }
    }

    // ---- 头像颜色（基于 peerId 生成稳定颜色） ----

    private func getAvatarColor(): Int64 {
        let colors: Array<Int64> = [0xE17076, 0xF28C28, 0xE5B842, 0x6BBA6F, 0x64BEFF, 0x5F9AEE, 0xB98EEA, 0xEE7AAE]
        let idx = Int64(this.peerId % 8)
        return colors[idx]
    }

    func build() {
        Column {
            Row {
                // ---- 大头像（66×66，可点击） ----
                Stack(alignContent: Alignment.BottomEnd) {
                    if (this.avatarUrl.size > 0) {
                        Image(this.avatarUrl)
                            .width(66)
                            .height(66)
                            .borderRadius(33)
                            .objectFit(ImageFit.Cover)
                    } else {
                        Column {
                            Text(this.getInitials())
                                .fontSize(28)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0xFFFFFF)
                        }
                        .width(66)
                        .height(66)
                        .borderRadius(33)
                        .backgroundColor(this.getAvatarColor())
                        .justifyContent(FlexAlign.Center)
                    }

                    if (this.isOnline && (this.peerType == "user" || this.peerType == "")) {
                        Column {}
                            .width(17)
                            .height(17)
                            .borderRadius(9)
                            .backgroundColor(0xFF4CD964)
                            .border(width: 2, color: 0xFFFFFFFF)
                    }
                }
                .width(66)
                .height(66)
                .onClick({ _evt =>
                    this.onAvatarTapped()
                })
                .margin(right: 15)

                // ---- 右侧内容区 ----
                Column {
                    if (this.isEditing) {
                        // 编辑态：显示输入框
                        if (this.peerType == "user" || this.peerType == "") {
                            // 个人：名字 + 姓氏
                            TextInput(text: this.editFirstName)
                                .fontSize(19)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0x000000)
                                .backgroundColor(Color.Transparent)
                                .maxLines(1)
                                .width(100.percent)
                                .onChange({ val: String =>
                                    this.editFirstName = val
                                    let lastName = this.editLastName
                                    let combined = if (val.size > 0 && lastName.size > 0) {
                                        val + " " + lastName
                                    } else if (val.size > 0) {
                                        val
                                    } else {
                                        lastName
                                    }
                                    this.onNameChanged(combined)
                                })
                                .onSubmit({ _key: EnterKeyType =>
                                    this.submitNameChange()
                                })
                            TextInput(text: this.editLastName)
                                .fontSize(17)
                                .fontColor(0x000000)
                                .backgroundColor(Color.Transparent)
                                .maxLines(1)
                                .width(100.percent)
                                .margin(top: 4)
                                .onChange({ val: String =>
                                    this.editLastName = val
                                    let firstName = this.editFirstName
                                    let combined = if (firstName.size > 0 && val.size > 0) {
                                        firstName + " " + val
                                    } else if (firstName.size > 0) {
                                        firstName
                                    } else {
                                        val
                                    }
                                    this.onNameChanged(combined)
                                })
                                .onSubmit({ _key: EnterKeyType =>
                                    this.submitNameChange()
                                })
                        } else {
                            // 群/频道：标题
                            TextInput(text: this.editTitle)
                                .fontSize(19)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0x000000)
                                .backgroundColor(Color.Transparent)
                                .maxLines(1)
                                .width(100.percent)
                                .onChange({ val: String =>
                                    this.editTitle = val
                                    this.onNameChanged(val)
                                })
                                .onSubmit({ _key: EnterKeyType =>
                                    this.submitNameChange()
                                })
                        }
                        if (this.saveResult.size > 0) {
                            Text(if (this.saveResult == "saved") { "Saved" } else { "Save failed" })
                                .fontSize(12)
                                .fontColor(if (this.saveResult == "saved") { 0x34C759 } else { 0xFF3B30 })
                                .margin(top: 4)
                        }
                    } else {
                        // 查看态：显示名称 + 状态
                        Text(this.displayName)
                            .fontSize(19)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0x000000)
                            .maxLines(1)
                            .textOverflow(TextOverflow.Ellipsis)
                            .width(100.percent)
                        if (this.statusText.size > 0) {
                            Text(this.statusText)
                                .fontSize(15)
                                .fontColor(if (this.isOnline) { 0x007AFF } else { 0x8E8E93 })
                                .margin(top: 3)
                                .maxLines(1)
                                .textOverflow(TextOverflow.Ellipsis)
                                .width(100.percent)
                        }
                    }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .justifyContent(FlexAlign.Center)
            }
            .width(100.percent)
            .padding(left: 15, right: 15, top: 11, bottom: 11)
            .backgroundColor(0xFFFFFF)
        }
        .width(100.percent)
    }

    private func getInitials(): String {
        if (this.displayName.size > 0) {
            let runes = this.displayName.toRuneArray()
            return String(runes[0]).toAsciiUpper()
        }
        return "?"
    }
}

/**
 * 调用 Service 执行名称更新（抽取为顶层函数，避免 spawn 内 mutable 捕获问题）
 */
/**
 * 根据更新类型计算新的显示名称
 */
func computeUpdatedName(isPerson: Bool, firstName: String, lastName: String, title: String): String {
    if (isPerson) {
        if (firstName.size > 0 && lastName.size > 0) {
            return firstName + " " + lastName
        }
        if (firstName.size > 0) {
            return firstName
        }
        return lastName
    }
    return title
}

/**
 * 调用 Service 执行名称更新（抽取为顶层函数，避免 spawn 内 mutable 捕获问题）
 */
func performNameUpdate(
    service: ItemListAvatarAndNameInfoService,
    isPerson: Bool,
    firstName: String,
    lastName: String,
    peerId: Int64,
    accessHash: Int64,
    isChannel: Bool,
    title: String
): Bool {
    if (isPerson) {
        return service.updateUserName(firstName, lastName)
    }
    return service.updateChatTitle(peerId, accessHash, isChannel, title)
}
