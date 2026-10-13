package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.core.mtproto.ChatBannedRights

/**
 * GroupPermissionsPage — 群默认权限页
 *
 * 对位 iOS PeerInfoUI/ChannelPermissionsController.swift：
 *   - 权限开关列表 allGroupPermissionList(peer:expandMedia:)：
 *       Send Messages / Send Media(可展开 9 项) / Add Members / Pin Messages / Change Group Info
 *   - Slow Mode（超级群；普通群 iOS 会先 convertGroupToSupergroup，本页普通群不显示）
 *   - Removed Users 入口（超级群）+ Exceptions 列表（受限成员）
 *
 * 开关语义：Toggle ON = 允许 = chatBannedRights 对应位未置位；
 * 每次切换直接 messages.editChatDefaultBannedRights（iOS 同样即时提交）。
 *
 * chatBannedRights 位（telegram_api.tl）：
 *   send_media=2 send_stickers=3 send_gifs=4 embed_links=7 send_polls=8 change_info=10
 *   invite_users=15 pin_messages=17 send_photos=19 send_videos=20 send_roundvideos=21
 *   send_audios=22 send_voices=23 send_docs=24 send_plain=25
 */
@HybridComponentEntry
@Component
public class GroupPermissionsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var peerId: Int64 = 0
    @State var peerType: String = ""
    @State var accessHash: Int64 = 0
    @State var flags: Int32 = 0
    @State var mediaExpanded: Bool = false
    @State var slowmodeSeconds: Int32 = 0
    @State var exceptions: ArrayList<BannedParticipantEntry> = ArrayList<BannedParticipantEntry>()
    @State var kickedCount: Int32 = 0
    @State var isSaving: Bool = false
    @State var toastMessage: String = ""
    @State var showToast: Bool = false
    @State var loaded: Bool = false

    private let bitSendPlain: Int32 = 1 << 25
    private let bitSendMedia: Int32 = 1 << 2
    private let bitStickers: Int32 = 1 << 3
    private let bitGifs: Int32 = 1 << 4
    private let bitEmbedLinks: Int32 = 1 << 7
    private let bitPolls: Int32 = 1 << 8
    private let bitChangeInfo: Int32 = 1 << 10
    private let bitInviteUsers: Int32 = 1 << 15
    private let bitPin: Int32 = 1 << 17
    private let bitPhotos: Int32 = 1 << 19
    private let bitVideos: Int32 = 1 << 20
    private let bitRoundVideos: Int32 = 1 << 21
    private let bitAudios: Int32 = 1 << 22
    private let bitVoices: Int32 = 1 << 23
    private let bitDocs: Int32 = 1 << 24

    /** iOS banSendMediaSubList()：9 项子权限 */
    private func mediaSubBits(): Array<Int32> {
        return [this.bitPhotos, this.bitVideos, this.bitStickers | this.bitGifs, this.bitAudios,
                this.bitDocs, this.bitVoices, this.bitRoundVideos, this.bitEmbedLinks, this.bitPolls]
    }

    private func mediaSubTitles(): Array<String> {
        return ["Send Photos", "Send Videos", "Send Stickers & GIFs", "Send Music", "Send Files",
                "Send Voice Messages", "Send Video Messages", "Embed Links", "Send Polls"]
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.peerId = getSelectedChatId()
        this.peerType = getSelectedChatPeerType()
        match (getRealChatListService().getCachedChat(this.peerId)) {
            case Some(chat) =>
                this.accessHash = chat.accessHash
                this.flags = chat.defaultBannedRightsFlags
            case None => ()
        }
        Hilog.info(0, "CjTelegram", "[GroupPermissionsPage] loaded peer=${this.peerType}/${this.peerId} flags=${this.flags}")
        this.loadFullInfo()
    }

    private func loadFullInfo(): Unit {
        let pt = this.peerType
        let pid = this.peerId
        let hash = this.accessHash
        let _ = spawn {
            try {
                let info = getPeerInfoService().getGroupFullInfo(pt, pid)
                let slow = info.slowmodeSeconds
                let kicked = info.kickedCount
                var list = ArrayList<BannedParticipantEntry>()
                if (pt == "channel") {
                    let r = getPeersService().getBannedChannelParticipants(pid, hash, kicked: false)
                    for (e in r.participants) { list.add(e) }
                }
                let newList = list
                launch {
                    this.slowmodeSeconds = slow
                    this.kickedCount = kicked
                    this.exceptions = newList
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GroupPermissionsPage] loadFullInfo error: ${e}")
            }
        }
    }

    private func isAllowed(bit: Int32): Bool {
        return (this.flags & bit) == 0
    }

    /** iOS: 子项全部禁止时 Send Media 视为禁止；标签 "n/9" */
    private func mediaAllowedCount(): Int64 {
        var n: Int64 = 0
        for (b in this.mediaSubBits()) {
            if ((this.flags & b) == 0) { n = n + 1 }
        }
        return n
    }

    private func mediaLabel(): String {
        return "${this.mediaAllowedCount()}/9"
    }

    private func setBit(bit: Int32, allowed: Bool): Unit {
        var f = this.flags
        if (allowed) { f = f & (!bit) } else { f = f | bit }
        this.commitFlags(f)
    }

    private func setMedia(allowed: Bool): Unit {
        var f = this.flags
        var all = this.bitSendMedia
        for (b in this.mediaSubBits()) { all = all | b }
        if (allowed) { f = f & (!all) } else { f = f | all }
        this.commitFlags(f)
    }

    private func setMediaSub(bit: Int32, allowed: Bool): Unit {
        var f = this.flags
        if (allowed) { f = f & (!bit) } else { f = f | bit }
        var allBanned = true
        for (b in this.mediaSubBits()) {
            if ((f & b) == 0) { allBanned = false }
        }
        if (allBanned) { f = f | this.bitSendMedia } else { f = f & (!this.bitSendMedia) }
        this.commitFlags(f)
    }

    /**
     * 提交默认权限：messages.editChatDefaultBannedRights（iOS updateDefaultChannelMemberBannedRights）。
     * 乐观更新，失败回滚并 toast。
     */
    private func commitFlags(newFlags: Int32): Unit {
        let old = this.flags
        this.flags = newFlags
        this.isSaving = true
        let pt = this.peerType
        let pid = this.peerId
        let hash = this.accessHash
        let _ = spawn {
            try {
                let rights = ChatBannedRights()
                rights.flags = newFlags
                rights.untilDate = 0
                let r = getPeersService().editDefaultBannedRights(pt, pid, hash, rights)
                launch {
                    this.isSaving = false
                    if (r.success) {
                        match (getRealChatListService().getCachedChat(pid)) {
                            case Some(chat) => chat.defaultBannedRightsFlags = newFlags
                            case None => ()
                        }
                        notifyGroupDetailsChanged()
                    } else {
                        this.flags = old
                        this.showToastMsg("Failed to update permissions: ${r.errorCode}")
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GroupPermissionsPage] commitFlags error: ${e}")
                launch {
                    this.isSaving = false
                    this.flags = old
                    this.showToastMsg("Failed to update permissions")
                }
            }
        }
    }

    private func slowmodeOptions(): Array<Int32> {
        return [0, 10, 30, 60, 300, 900, 3600]
    }

    private func slowmodeLabel(seconds: Int32): String {
        if (seconds == 0) { return "Off" }
        if (seconds < 60) { return "${seconds}s" }
        if (seconds < 3600) { return "${seconds / 60}m" }
        return "${seconds / 3600}h"
    }

    private func slowmodeInfo(): String {
        if (this.slowmodeSeconds == 0) {
            return "Members will be able to send messages without restrictions."
        }
        return "Members will be able to send only one message every ${this.slowmodeLabel(this.slowmodeSeconds)}."
    }

    private func setSlowmode(seconds: Int32): Unit {
        let old = this.slowmodeSeconds
        if (old == seconds) { return }
        this.slowmodeSeconds = seconds
        let pid = this.peerId
        let hash = this.accessHash
        let _ = spawn {
            try {
                let r = getPeersService().toggleSlowMode(pid, hash, seconds)
                launch {
                    if (!r.success) {
                        this.slowmodeSeconds = old
                        this.showToastMsg("Failed to update slow mode: ${r.errorCode}")
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[GroupPermissionsPage] setSlowmode error: ${e}")
                launch { this.slowmodeSeconds = old }
            }
        }
    }

    private func showToastMsg(msg: String): Unit {
        this.toastMessage = msg
        this.showToast = true
    }

    private func removedUsersLabel(): String {
        if (this.kickedCount > 0) { return "${this.kickedCount}" }
        return ""
    }

    public func build() {
        Stack(alignContent: Alignment.TopStart) {
            Scroll {
                Column {
                    Text(trSource("WHAT CAN MEMBERS OF THIS GROUP DO?"))
                        .fontSize(13)
                        .fontColor(0xFF8E8E93)
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 24, bottom: 6)

                    Column {
                        this.permRow("Send Messages", this.bitSendPlain, false)
                        Divider().color(0xFFE5E5EA).strokeWidth(1).margin(left: 16)
                        Row {
                            Text(trSource("Send Media"))
                                .fontSize(16)
                                .fontColor(0xFF000000)
                            Text(this.mediaLabel())
                                .fontSize(14)
                                .fontColor(0xFF8E8E93)
                                .margin(left: 8)
                            Text(if (this.mediaExpanded) { "⌃" } else { "⌄" })
                                .fontSize(14)
                                .fontColor(0xFF8E8E93)
                                .margin(left: 6)
                            Blank().layoutWeight(1)
                            this.mediaSwitch()
                        }
                        .width(100.percent)
                        .height(48)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _ => this.mediaExpanded = !this.mediaExpanded })
                        if (this.mediaExpanded) {
                            ForEach(this.mediaSubBits(), itemGenerator: { bit: Int32, idx: Int64 =>
                                Divider().color(0xFFE5E5EA).strokeWidth(1).margin(left: 44)
                                this.permRow(this.mediaSubTitles()[idx], bit, true)
                            })
                        }
                        Divider().color(0xFFE5E5EA).strokeWidth(1).margin(left: 16)
                        this.permRow("Add Members", this.bitInviteUsers, false)
                        Divider().color(0xFFE5E5EA).strokeWidth(1).margin(left: 16)
                        this.permRow("Pin Messages", this.bitPin, false)
                        Divider().color(0xFFE5E5EA).strokeWidth(1).margin(left: 16)
                        this.permRow("Change Group Info", this.bitChangeInfo, false)
                    }
                    .width(100.percent)
                    .backgroundColor(0xFFFFFFFF)

                    if (this.peerType == "channel") {
                        Text("SLOW MODE")
                            .fontSize(13)
                            .fontColor(0xFF8E8E93)
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 24, bottom: 6)
                        Column {
                            Row {
                                ForEach(this.slowmodeOptions(), itemGenerator: { sec: Int32, _i: Int64 =>
                                    Text(this.slowmodeLabel(sec))
                                        .fontSize(14)
                                        .fontColor(if (sec == this.slowmodeSeconds) { 0xFFFFFFFF } else { 0xFF000000 })
                                        .backgroundColor(if (sec == this.slowmodeSeconds) { 0xFF007AFF } else { 0xFFF2F2F7 })
                                        .padding(left: 10, right: 10, top: 6, bottom: 6)
                                        .borderRadius(8)
                                        .onClick({ _ => this.setSlowmode(sec) })
                                })
                            }
                            .width(100.percent)
                            .padding(left: 12, right: 12, top: 12, bottom: 12)
                            .justifyContent(FlexAlign.SpaceBetween)
                        }
                        .width(100.percent)
                        .backgroundColor(0xFFFFFFFF)
                        Text(this.slowmodeInfo())
                            .fontSize(13)
                            .fontColor(0xFF8E8E93)
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 6)

                        Column {
                            Row {
                                Text(trSource("Removed Users"))
                                    .fontSize(16)
                                    .fontColor(0xFF000000)
                                    .layoutWeight(1)
                                Text(this.removedUsersLabel())
                                    .fontSize(14)
                                    .fontColor(0xFF8E8E93)
                                Text(" ›")
                                    .fontSize(18)
                                    .fontColor(0xFFC7C7CC)
                            }
                            .width(100.percent)
                            .height(48)
                            .padding(left: 16, right: 16)
                            .alignItems(VerticalAlign.Center)
                            .onClick({ _ =>
                                routerPush("BlacklistPage", "${this.peerId}|${this.accessHash}|${getSelectedChatName()}")
                            })
                        }
                        .width(100.percent)
                        .backgroundColor(0xFFFFFFFF)
                        .margin(top: 24)

                        Text(trSource("EXCEPTIONS"))
                            .fontSize(13)
                            .fontColor(0xFF8E8E93)
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 24, bottom: 6)
                        Column {
                            if (this.exceptions.size == 0) {
                                Text("No exceptions")
                                    .fontSize(15)
                                    .fontColor(0xFF8E8E93)
                                    .width(100.percent)
                                    .height(48)
                                    .padding(left: 16)
                            }
                            ForEach(this.exceptions, itemGenerator: { e: BannedParticipantEntry, _i: Int64 =>
                                Row {
                                    Text(e.displayName)
                                        .fontSize(16)
                                        .fontColor(0xFF000000)
                                        .layoutWeight(1)
                                        .maxLines(1)
                                }
                                .width(100.percent)
                                .height(48)
                                .padding(left: 16, right: 16)
                                .alignItems(VerticalAlign.Center)
                            })
                        }
                        .width(100.percent)
                        .backgroundColor(0xFFFFFFFF)
                    }
                    Blank().height(40)
                }
                .width(100.percent)
            }
            .align(Alignment.Top)
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFFF2F2F7)

            if (this.showToast) {
                Column {
                    Text(this.toastMessage)
                        .fontSize(14)
                        .fontColor(0xFFFFFFFF)
                        .padding(left: 20, right: 20, top: 10, bottom: 10)
                        .backgroundColor(0xFF333333)
                        .borderRadius(20)
                }
                .width(100.percent)
                .height(100.percent)
                .justifyContent(FlexAlign.End)
                .alignItems(HorizontalAlign.Center)
                .padding(bottom: 100)
                .onClick({ _ => this.showToast = false })
            }
        }
        .onAppear({ => this.ensureLoaded() })
    }

    /**
     * 纯状态驱动的开关（对位 UISwitch 外观）。
     * 不用 ArkUI Toggle（首帧后不跟随 @State）；也不把 isOn 当 @Builder 值参传入
     * （@Builder 值参在首帧固化，不随 @State 重算）——开关直接读 this.flags。
     */
    @Builder
    func bitSwitch(bit: Int32, sub: Bool) {
        Stack(alignContent: if (this.isAllowed(bit)) { Alignment.End } else { Alignment.Start }) {
            Column {}
                .width(27)
                .height(27)
                .borderRadius(13.5)
                .backgroundColor(0xFFFFFFFF)
                .margin(left: 2, right: 2)
                .shadow(radius: 2.0, color: 0x33000000, offsetX: 0.0, offsetY: 1.0)
        }
        .width(51)
        .height(31)
        .borderRadius(15.5)
        .backgroundColor(if (this.isAllowed(bit)) { 0xFF007AFF } else { 0xFFE9E9EA })
        .onClick({ _ =>
            if (sub) {
                this.setMediaSub(bit, !this.isAllowed(bit))
            } else {
                this.setBit(bit, !this.isAllowed(bit))
            }
        })
    }

    /** Send Media 总开关：任一子项允许即为 ON；点按整体开/关 9 项 */
    @Builder
    func mediaSwitch() {
        Stack(alignContent: if (this.mediaAllowedCount() > 0) { Alignment.End } else { Alignment.Start }) {
            Column {}
                .width(27)
                .height(27)
                .borderRadius(13.5)
                .backgroundColor(0xFFFFFFFF)
                .margin(left: 2, right: 2)
                .shadow(radius: 2.0, color: 0x33000000, offsetX: 0.0, offsetY: 1.0)
        }
        .width(51)
        .height(31)
        .borderRadius(15.5)
        .backgroundColor(if (this.mediaAllowedCount() > 0) { 0xFF007AFF } else { 0xFFE9E9EA })
        .onClick({ _ => this.setMedia(this.mediaAllowedCount() == 0) })
    }

    @Builder
    func permRow(title: String, bit: Int32, sub: Bool) {
        Row {
            Text(title)
                .fontSize(if (sub) { 15 } else { 16 })
                .fontColor(0xFF000000)
                .layoutWeight(1)
            this.bitSwitch(bit, sub)
        }
        .width(100.percent)
        .height(48)
        .padding(left: if (sub) { 44 } else { 16 }, right: 16)
        .alignItems(VerticalAlign.Center)
    }
}
