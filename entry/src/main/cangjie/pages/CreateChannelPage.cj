package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.viewmodels.getChatListVM
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * Phase P5-7: 创建频道页面（增强版）（混合工程迁移版）
 *
 * 功能:
 * - 频道名称 + 描述表单
 * - 公开/私有切换
 * - 公开时输入用户名
 * - 调用 channels.createChannel API
 * - 公开频道: 额外调用 channels.updateUsername
 * - 错误处理: CHANNELS_TOO_MUCH, USERNAME_INVALID 等
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹（去掉 .title），只留内容
 *  - 源页无 hideTitleBar(true)（用 .title），故 ArkTS 壳 hideTitleBar(false)
 */
@HybridComponentEntry
@Component
public class CreateChannelPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var channelName: String = ""
    @State var channelDescription: String = ""
    @State var isPublic: Bool = false
    @State var channelUsername: String = ""
    @State var isCreating: Bool = false
    @State var resultText: String = ""
    // S5 (WP-E)：频道已建好但用户名未能设置时记住它 —— 再次点按钮只重试 channels.updateUsername，
    // 绝不重复 createChannel 建出第二个频道。
    @State var createdChannelId: Int64 = 0
    @State var createdAccessHash: Int64 = 0

    /**
     * 读一条 RPC 响应的错误串：非错误返回 ""（空串 = 成功）。
     * 空响应按 NETWORK_ERROR 处理，与 services/PeersService.cj 的约定一致。
     */
    private func rpcErrorOf(responseData: Array<Byte>): String {
        if (responseData.size < 4) { return "NETWORK_ERROR" }
        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            return d.readString()
        }
        return ""
    }

    /**
     * S5 (WP-E)：建公开频道前先做 channels.checkUsername(inputChannelEmpty, name)
     * —— iOS ChannelVisibilityController 在 Next 可用前就靠 addressNameAvailability 校验，
     * 公开频道不会在用户名不可用时静默建成私有频道。返回 ""=可用，否则为 iOS 文案。
     */
    private func checkUsernameBeforeCreate(client: MTProtoClient, username: String): String {
        let req = ChannelsCheckUsername()
        req.channel = InputChannelEmpty()
        req.username = username
        let resp = client.sendRequest(req.toBytes())
        if (resp.size < 4) { return channelUsernameServerError("NETWORK_ERROR") }
        let d = TLDeserializer(resp)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.BOOL_TRUE) { return "" }
        if (ctor == TLConstructors.BOOL_FALSE) {
            Hilog.info(0, "CjTelegram", "[CreateChannel] checkUsername @${username}: taken")
            return channelUsernameServerError("USERNAME_OCCUPIED")
        }
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let code = d.readInt32()
            let msg = d.readString()
            Hilog.info(0, "CjTelegram", "[CreateChannel] checkUsername @${username} error: ${code} ${msg}")
            return channelUsernameServerError(msg)
        }
        return ""
    }

    private func createChannel(): Unit {
        if (this.channelName.isEmpty()) { return }
        this.isCreating = true
        this.resultText = ""
        let nameCopy = this.channelName
        let descCopy = this.channelDescription
        let isPublicCopy = this.isPublic
        let usernameCopy = this.channelUsername
        let existingChannelId = this.createdChannelId
        let existingAccessHash = this.createdAccessHash
        spawn {
            var result = ""
            var newChannelId: Int64 = existingChannelId
            var newAccessHash: Int64 = existingAccessHash
            // 用户名步骤是否失败：失败时留在本页显示错误（频道已存在，见 createdChannelId）。
            var usernameFailed = false
            try {
                let client = getMTProtoClient()

                // 1) 公开频道：先本地格式校验，再向服务端 checkUsername；不可用就不建频道。
                if (newChannelId == 0 && isPublicCopy && usernameCopy.size > 0) {
                    result = channelUsernameFormatError(usernameCopy)
                    if (result.isEmpty()) {
                        result = this.checkUsernameBeforeCreate(client, usernameCopy)
                    }
                }

                // 2) 建频道（用户名重试时跳过）。
                if (result.isEmpty() && newChannelId == 0) {
                    let req = ChannelsCreateChannel()
                    req.broadcast = true
                    req.title = nameCopy
                    req.about = descCopy

                    Hilog.info(0, "CjTelegram", "[CreateChannel] Creating channel: ${nameCopy}")
                    let responseData = client.sendRequest(req.toBytes())
                    let err = this.rpcErrorOf(responseData)
                    if (!err.isEmpty()) {
                        result = this.formatError(err)
                        Hilog.info(0, "CjTelegram", "[CreateChannel] RPC error: ${err}")
                    } else {
                        Hilog.info(0, "CjTelegram", "[CreateChannel] Channel created successfully!")
                        match (this.extractCreatedChannel(responseData, nameCopy)) {
                            case Some(created) =>
                                newChannelId = created.id
                                newAccessHash = created.accessHash
                                // 新频道立刻可打开：peer 与 access hash 入缓存，Updates 交给
                                // UpdatesManager（对位 iOS createChannel 里 stateManager.addUpdates）。
                                getRealChatListService().cacheChatResponse(created)
                            case None =>
                                Hilog.info(0, "CjTelegram", "[CreateChannel] Could not locate created channel in response")
                        }
                        getUpdatesManager().handleRawUpdate(responseData)

                        // 创建新 peer 是显式结构变更，完成后只执行一次权威列表刷新；
                        // 普通消息更新不再走该全量路径。
                        match (getChatListVM()) {
                            case Some(vm) => launch { vm.refreshWithPullDown() }
                            case None => ()
                        }
                    }
                }

                // 3) 设置用户名（iOS 创建后进入 ChannelVisibilityController → updateAddressName）。
                if (result.isEmpty() && isPublicCopy && usernameCopy.size > 0 && newChannelId > 0) {
                    Hilog.info(0, "CjTelegram", "[CreateChannel] Setting username: @${usernameCopy} channel=${newChannelId}")
                    let usernameReq = ChannelsUpdateUsername()
                    let ch = InputChannel()
                    ch.channelId = newChannelId
                    ch.accessHash = newAccessHash
                    usernameReq.channel = ch
                    usernameReq.username = usernameCopy
                    let uErr = this.rpcErrorOf(client.sendRequest(usernameReq.toBytes()))
                    if (!uErr.isEmpty() && !uErr.contains("USERNAME_NOT_MODIFIED")) {
                        usernameFailed = true
                        result = channelUsernameServerError(uErr)
                        Hilog.info(0, "CjTelegram", "[CreateChannel] Username error: ${uErr}")
                    } else {
                        Hilog.info(0, "CjTelegram", "[CreateChannel] Username set: @${usernameCopy}")
                    }
                } else if (result.isEmpty() && isPublicCopy && usernameCopy.size > 0 && newChannelId == 0) {
                    // 频道建了但没在响应里定位到 id：用户名无法设置，不能装作成功。
                    usernameFailed = true
                    result = channelUsernameServerError("CHANNEL_INVALID")
                    Hilog.info(0, "CjTelegram", "[CreateChannel] Username skipped: created channel id unknown")
                }
            } catch (e: Exception) {
                result = "${channelUsernameServerError("EXCEPTION")} (${e})"
                Hilog.info(0, "CjTelegram", "[CreateChannel] Exception: ${e}")
            }
            let finalResult = result
            let openChannelId = newChannelId
            let openAccessHash = newAccessHash
            let stayForUsername = usernameFailed
            launch {
                this.isCreating = false
                if (openChannelId > 0) {
                    this.createdChannelId = openChannelId
                    this.createdAccessHash = openAccessHash
                }
                if (openChannelId > 0 && !stayForUsername) {
                    // iOS CreateChannelController 创建成功后直接进入新频道
                    // （ComposeController → createChannel → navigateToChatController）。
                    setSelectedChat(openChannelId, nameCopy, "channel")
                    setSelectedChatDraft("")
                    setSelectedChatUsername(if (isPublicCopy) { usernameCopy } else { "" })
                    routerReplaceTop("ChatRoomPage", "")
                    return
                }
                this.resultText = finalResult
            }
        }
    }

    /** channels.createChannel 错误 → iOS CreateChannelController.swift:488-499 的提示文案。 */
    private func formatError(msg: String): String {
        if (msg.contains("USER_RESTRICTED")) {
            // iOS .restricted → Common.ActionNotAllowedError
            return "Sorry, you are not allowed to do this."
        }
        if (msg.contains("CHANNELS_TOO_MUCH")) {
            // iOS .tooMuchJoined 进入 oldChannelsController（本端无该页），用其 OldChannels.NoticeCreateText 文案
            return "Sorry, you are member of too many groups and channels.\nPlease leave some before creating a new one."
        }
        if (msg.contains("CHAT_TITLE_EMPTY")) {
            return "Channel name cannot be empty"
        }
        if (msg.contains("NETWORK_ERROR")) {
            return "An error occurred, please try again later."
        }
        // iOS .generic → Login.UnknownError；括号里保留服务端错误码便于排查（FLOOD_WAIT_x 等）。
        return "An error occurred, please try again later. (${msg})"
    }

    /**
     * 在 channels.createChannel 返回的 Updates 里定位新频道对象。
     * 逐字节找 ChatResponse.deserializeBoxed 认识的任一 channel 构造器（小端）后完整解析，
     * 再用「是频道 + 标题相同」确认，避免把响应里偶然出现的同样 4 字节当成频道。
     * 做法同 PeersService.extractCreatedBasicGroupId。
     * WP-E：此前只认 channel#fe685355 —— 服务端按层回别的 channel 构造器时定位失败，
     * 用户名步骤被静默跳过；现与 TLResponses.cj:777/828 的构造器集合保持一致。
     */
    private func extractCreatedChannel(data: Array<Byte>, title: String): Option<ChatResponse> {
        let ctors: Array<UInt32> = [0xfe685355, 0x1c32b11c, 0x17d493d5]
        var pos: Int64 = 4
        while (pos + 16 <= data.size) {
            let word: UInt32 = UInt32(data[pos]) | (UInt32(data[pos + 1]) << 8) |
                (UInt32(data[pos + 2]) << 16) | (UInt32(data[pos + 3]) << 24)
            var known = false
            for (c in ctors) { if (c == word) { known = true } }
            if (known) {
                try {
                    let candidate = ChatResponse.deserializeBoxed(TLDeserializer(ByteUtils.slice(data, pos, data.size)))
                    if (candidate.id > 0 && candidate.isChannel && candidate.title == title) {
                        return Some(candidate)
                    }
                } catch (_e: Exception) {}
            }
            pos += 1
        }
        return None
    }

    // Public type needs a link: iOS ChannelVisibilityController.swift:1911-1931 keeps Next
    // disabled for .publicChannel until the address name validates, so a public channel is never
    // created silently as private. Format floor per _internal_checkAddressNameFormat (length >= 4).
    private func canCreate(): Bool {
        if (this.channelName.isEmpty() || this.isCreating) { return false }
        if (this.isPublic && this.channelUsername.size < 4) { return false }
        return true
    }

    /** iOS updateEditingName：title 截到 255 字符（CreateChannelController.swift:416）。 */
    private func onChannelNameChanged(value: String): Unit {
        let runes = value.toRuneArray()
        this.channelName = if (runes.size > 255) { String(runes[0..255]) } else { value }
    }

    // onClick 回调（显式 Unit 返回类型，避免宏把 spawn{} 末尾推断为 Future）
    private func onCreateChannelClick(): Unit {
        if (!this.canCreate()) { return }
        this.createChannel()
    }

    public func build() {
        Column {
                // Channel Name
                Text(trSource("Channel Name"))
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .margin(top: 16, bottom: 4)
                    .alignSelf(ItemAlign.Start)

                TextInput(text: this.channelName, placeholder: "Enter channel name")
                    .width(100.percent)
                    .height(48)
                    .margin(bottom: 12)
                    .backgroundColor(0xF5F5F5)
                    .borderRadius(8)
                    .padding(left: 16, right: 16)
                    .maxLength(255)
                    .onChange({ value: String => this.onChannelNameChanged(value) })

                // Description
                Text(trSource("Description"))
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .margin(bottom: 4)
                    .alignSelf(ItemAlign.Start)

                TextInput(text: this.channelDescription, placeholder: "Describe your channel (optional)")
                    .width(100.percent)
                    .height(48)
                    .margin(bottom: 16)
                    .backgroundColor(0xF5F5F5)
                    .borderRadius(8)
                    .padding(left: 16, right: 16)
                    .onChange({ value: String => this.channelDescription = value })

                // Public/Private toggle
                Row {
                    Column {
                        Text("Public Channel")
                            .fontSize(16)
                            .fontColor(0x000000)
                        Text("Anyone can find and join your channel")
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    Toggle(ToggleType.Switch, isOn: this.isPublic)
                        .onChange({ isOn: Bool =>
                            this.isPublic = isOn
                        })
                }
                .width(100.percent)
                .padding(top: 12, bottom: 12)

                // Username field (visible only when public)
                if (this.isPublic) {
                    Text("Channel Link")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(top: 8, bottom: 4)
                        .alignSelf(ItemAlign.Start)

                    Row {
                        Text("t.me/")
                            .fontSize(16)
                            .fontColor(0x8E8E93)
                            .margin(right: 4)

                        TextInput(placeholder: trSource("username"))
                            .layoutWeight(1)
                            .height(44)
                            .backgroundColor(0xF5F5F5)
                            .borderRadius(8)
                            .padding(left: 12, right: 12)
                            .onChange({ value: String => this.channelUsername = value })
                    }
                    .width(100.percent)
                    .alignItems(VerticalAlign.Center)
                    .margin(bottom: 16)
                }

                // Info text
                Text("Channels are for broadcasting messages to an unlimited audience.")
                    .fontSize(13)
                    .fontColor(0x999999)
                    .margin(top: 8, bottom: 20)

                // Create button：iOS CreateChannelController.swift:667-680 的 Next 按钮
                // enabled = !editingName.composedTitle.isEmpty && !creating。直接在本页读
                // channelName 构建，名称一变按钮立即可用（不经子组件 @Prop 转发）。
                Button(if (this.isCreating) { "Creating..." } else { "Create Channel" })
                    .width(100.percent)
                    .height(48)
                    .borderRadius(24)
                    .backgroundColor(if (this.canCreate()) { 0x317AFF } else { 0xCCCCCC })
                    .fontColor(0xFFFFFF)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .enabled(this.canCreate())
                    .onClick({ _ => this.onCreateChannelClick() })

                // Result text
                if (this.resultText.size > 0) {
                    Text(this.resultText)
                        .fontSize(14)
                        .fontColor(if (this.resultText.contains("Error") || this.resultText.contains("failed") || this.resultText.contains("too many") || this.resultText.contains("Invalid") || this.resultText.contains("taken")) { 0xFF3B30 } else { 0x34C759 })
                        .margin(top: 16)
                        .textAlign(TextAlign.Center)
                }
        }
        .width(100.percent)
        .height(100.percent)
        .padding(left: 16, right: 16)
        .backgroundColor(0xFFFFFF)
        .padding(bottom: getSafeAreaBottom())
    }
}

// ==================== S5 (WP-E)：频道用户名校验与错误文案（CreateChannelPage / GroupDetailsPage 共用） ====================

/**
 * 本地格式校验，对位 iOS AddressNames.swift _internal_checkAddressNameFormat（长度 < 4 即 tooShort，
 * 只允许 a-z A-Z 0-9 _，不能以数字或下划线开头、不能以下划线结尾）。
 * 返回 "" 表示格式合法，否则为 Localizable.strings 里 Channel.Username.* 的提示文案。
 */
public func channelUsernameFormatError(name: String): String {
    var index: Int64 = 0
    let length = Int64(name.toRuneArray().size)
    for (ch in name.runes()) {
        if (ch == r'_') {
            if (index == 0) { return "Channel names can't start with an underscore." }
            if (index == length - 1) {
                return if (length < 4) { "Channel names must have at least 5 characters." } else { "Channel names can't end with an underscore." }
            }
        }
        if (index == 0 && ch >= r'0' && ch <= r'9') { return "Channel names can't start with a number." }
        let ok = (ch >= r'a' && ch <= r'z') || (ch >= r'A' && ch <= r'Z') || (ch >= r'0' && ch <= r'9') || ch == r'_'
        if (!ok) { return "Sorry, this name is invalid." }
        index += 1
    }
    if (length < 4) { return "Channel names must have at least 5 characters." }
    return ""
}

/**
 * channels.checkUsername / channels.updateUsername 的服务端错误 → iOS 文案
 * （AddressNames.swift：USERNAME_OCCUPIED → taken、USERNAME_PURCHASE_AVAILABLE → purchaseAvailable、
 * 其余 → invalid；ChannelVisibilityController 更新失败弹 Login.UnknownError）。
 */
public func channelUsernameServerError(code: String): String {
    if (code.contains("USERNAME_OCCUPIED")) { return "Sorry, this name is already taken." }
    if (code.contains("USERNAME_PURCHASE_AVAILABLE")) {
        return "This username is already taken. However, it is currently available for purchase."
    }
    if (code.contains("USERNAME_INVALID")) { return "Sorry, this name is invalid." }
    if (code.contains("USERNAMES_UNAVAILABLE") || code.contains("CHANNELS_ADMIN_PUBLIC_TOO_MUCH")) {
        return "You can revoke the link from one of your older groups or channels, or create a private channel instead."
    }
    if (code.contains("NETWORK_ERROR") || code.contains("EXCEPTION")) {
        return "An error occurred, please try again later."
    }
    return "An error occurred, please try again later. (${code})"
}
