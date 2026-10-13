package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*

/**
 * RankInfoSheet — 成员头衔说明 sheet（S212）
 *
 * 对位 iOS ChatRankInfoScreen
 * （TelegramUI/Components/Chat/ChatRankInfoScreen/Sources/ChatRankInfoScreen.swift）。
 *
 * iOS 语义（源文件 :138-155 与 Localizable.strings 的 RankInfo.* 组）：
 *   三种角色各有独立标题与正文，且颜色语义固定——
 *     Owner  紫色 tag → "Owner Tag"  / "This purple tag [x] is A's owner tag. A is the owner of C."
 *     Admin  绿色 tag → "Admin Tag"  / "This green tag [x] is A's admin tag. A is an administrator of C."
 *     Member 灰色 tag → "Member Tag" / "This gray tag [x] is A's member tag. A is a member of C."
 *   canChange=false 时附加说明 RankInfo.ChangeInfo：
 *     "Only admins can assign member tags in this group."
 *   canChange=true 时给出 RankInfo.SetMyTag 动作。
 *
 * 入口差异（有意为之，非遗漏）：
 *   iOS 从聊天内点成员头衔徽章唤起（ChatController.swift:5888）。本工程 MessageBubble
 *   尚未渲染头衔徽章，那个入口不存在；而 GroupMembersPage 的成员副标题真实展示头衔
 *   （getMemberRole，:301-308）。故把入口落在成员列表的头衔上——这是本工程实际存在
 *   的头衔展示点。待气泡补上徽章渲染后，可在那里复用本组件。
 */

/** 角色枚举，对位 iOS ChatRankInfoScreenRole */
public enum RankRole {
    | RankOwner
    | RankAdmin
    | RankMember
}

@Component
public class RankInfoSheet {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 头衔文本（可为空：无自定义头衔时 iOS 用默认角色名占位）
    public var rank: String = ""
    public var role: RankRole = RankRole.RankMember
    public var userName: String = ""
    public var chatName: String = ""
    // 当前账号能否改这个头衔（仅管理员可指派）
    public var canChange: Bool = false

    public var onClose: () -> Unit = { => }
    public var onSetTag: () -> Unit = { => }

    /** 对位 RankInfo.{Owner,Admin,Member}.Title */
    private func titleText(): String {
        match (this.role) {
            case RankOwner => "Owner Tag"
            case RankAdmin => "Admin Tag"
            case RankMember => "Member Tag"
        }
    }

    /** 头衔徽章底色，对位 iOS 的 purple / green / gray 三态 */
    private func tagColor(): UInt32 {
        match (this.role) {
            case RankOwner => 0xFF8E7CC3
            case RankAdmin => 0xFF4FAE6B
            case RankMember => 0xFF8E8E93
        }
    }

    /** 徽章文本：有自定义头衔用之，否则回落到角色名（对位 iOS 无 rank 时的展示） */
    private func tagText(): String {
        if (this.rank.size > 0) { return this.rank }
        match (this.role) {
            case RankOwner => "owner"
            case RankAdmin => "admin"
            case RankMember => "member"
        }
    }

    /**
     * 对位 RankInfo.{Owner,Admin,Member}.Text 的四个占位：
     *   %1$@ 头衔  %2$@ 用户名（所有格）  %3$@ 用户名  %4$@ 群名
     * 仓颉侧不做富文本加粗，按纯文本拼接，保持语义与措辞一致。
     */
    private func bodyText(): String {
        let u = if (this.userName.size > 0) { this.userName } else { "This user" }
        let c = if (this.chatName.size > 0) { this.chatName } else { "this group" }
        let t = this.tagText()
        match (this.role) {
            case RankOwner => "This purple tag ${t} is ${u}'s owner tag. ${u} is the owner of ${c}."
            case RankAdmin => "This green tag ${t} is ${u}'s admin tag. ${u} is an administrator of ${c}."
            case RankMember => "This gray tag ${t} is ${u}'s member tag. ${u} is a member of ${c}."
        }
    }

    public func build() {
        Column {
            // 头衔徽章
            Text(this.tagText())
                .fontSize(13)
                .fontColor(0xFFFFFFFF)
                .backgroundColor(this.tagColor())
                .borderRadius(9)
                .padding(left: 10, right: 10, top: 3, bottom: 3)
                .margin(top: 20)

            Text(this.titleText())
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor(0xFF000000)
                .margin(top: 12)

            Text(this.bodyText())
                .fontSize(15)
                .fontColor(0xFF3C3C43)
                .textAlign(TextAlign.Center)
                .padding(left: 24, right: 24)
                .margin(top: 10)

            // 对位 RankInfo.ChangeInfo：无权指派时说明原因
            if (!this.canChange) {
                Text(trSource("Only admins can assign member tags in this group."))
                    .fontSize(13)
                    .fontColor(0xFF8E8E93)
                    .textAlign(TextAlign.Center)
                    .padding(left: 24, right: 24)
                    .margin(top: 10)
            }

            // 对位 RankInfo.SetMyTag
            if (this.canChange) {
                Button(trSource("Set My Tag"))
                    .fontSize(16)
                    .fontColor(0xFFFFFFFF)
                    .backgroundColor(0xFF317AFF)
                    .borderRadius(10)
                    .height(46)
                    .width(100.percent)
                    .margin(top: 18)
                    .onClick({ _evt =>
                        this.onSetTag()
                    })
            }

            Button(trSource("Close"))
                .fontSize(16)
                .fontColor(0xFF317AFF)
                .backgroundColor(0xFFF2F2F7)
                .borderRadius(10)
                .height(46)
                .width(100.percent)
                .margin(top: 10, bottom: 20)
                .onClick({ _evt =>
                    this.onClose()
                })
        }
        .width(100.percent)
        .padding(left: 20, right: 20)
        .backgroundColor(0xFFFFFFFF)
        .borderRadius(16)
        .alignItems(HorizontalAlign.Center)
    }
}
