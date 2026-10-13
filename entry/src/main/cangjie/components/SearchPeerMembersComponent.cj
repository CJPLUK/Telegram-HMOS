package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*

/**
 * SearchPeerMembersComponent — 群成员搜索组件
 *
 * 对应 iOS SearchPeerMembers.swift 的 UI 层：
 *   - TextInput 接受关键词输入
 *   - 调用 SearchPeerMembersService.searchPeerMembers() 向服务器查询或本地过滤
 *   - 以列表渲染搜索结果（头像首字母 + 全名 + 用户名/角色）
 *
 * 使用方：在 GroupMembersPage 等页面 import 后嵌入，传入 peerId / peerType / accessHash
 */
@Component
public class SearchPeerMembersComponent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 目标 peer 信息（调用方通过属性赋值传入）
    public var peerId: Int64 = 0
    public var peerType: String = "channel"       // "channel" | "supergroup" | "chat"
    public var accessHash: Int64 = 0

    @State var searchText: String = ""
    @State var results: ArrayList<ContactDisplayData> = ArrayList<ContactDisplayData>()
    @State var isLoading: Bool = false
    @State var hasSearched: Bool = false

    // 可选：成员点击回调
    public var onMemberSelected: (ContactDisplayData) -> Unit = { _m => }

    public override func aboutToAppear(): Unit {
        // 预热：缓存 accessHash 到服务
        if (this.peerId != 0 && this.accessHash != 0) {
            getSearchPeerMembersService().cacheChannelAccessHash(this.peerId, this.accessHash)
        }
    }

    private func doSearch(query: String): Unit {
        if (this.peerId == 0) { return }
        this.isLoading = true
        let pid = this.peerId
        let ptype = this.peerType
        let ahash = this.accessHash
        let q = query
        let _ = spawn {
            try {
                let res = getSearchPeerMembersService().searchPeerMembers(pid, q, ptype, ahash)
                Hilog.info(0, "CjTelegram", "[SearchPeerMembersComponent] got ${res.size} results")
                launch {
                    this.results = res
                    this.isLoading = false
                    this.hasSearched = true
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[SearchPeerMembersComponent] search error: ${e}")
                launch {
                    this.isLoading = false
                    this.hasSearched = true
                }
            }
        }
    }

    private func getAvatarColor(member: ContactDisplayData): Int64 {
        let colors: Array<Int64> = [0xFF5C9CE6, 0xFFE57373, 0xFF81C784, 0xFFFFB74D, 0xFFBA68C8, 0xFF4DD0E1, 0xFFFFD54F, 0xFF4DB6AC]
        let idx = Int64(member.userId % 8)
        if (idx < 0) { return colors[0] }
        return colors[idx]
    }

    private func getRoleLabel(member: ContactDisplayData): String {
        if (member.role == "creator") { return "Owner" }
        if (member.role == "admin") { return "Admin" }
        if (member.role == "bot") { return "Bot" }
        if (member.isBot) { return "Bot" }
        if (member.username.size > 0) { return "@" + member.username }
        return ""
    }

    public func build() {
        Column {
            // 搜索框
            TextInput(placeholder: "Search members...")
                .width(100.percent)
                .height(36)
                .margin(left: 12, right: 12, top: 8, bottom: 4)
                .backgroundColor(0xF0F0F0)
                .borderRadius(18)
                .padding(left: 16, right: 16)
                .onChange({ value: String =>
                    this.searchText = value
                    this.doSearch(value)
                })

            // 加载提示
            if (this.isLoading) {
                Row {
                    Text(trSource("Searching..."))
                        .fontSize(14)
                        .fontColor(0x999999)
                }
                .width(100.percent)
                .height(44)
                .justifyContent(FlexAlign.Center)
            } else if (this.hasSearched && this.results.size == 0) {
                // 无结果提示
                Row {
                    Text("No members found")
                        .fontSize(14)
                        .fontColor(0x999999)
                }
                .width(100.percent)
                .height(60)
                .justifyContent(FlexAlign.Center)
            } else {
                // 结果列表
                List {
                    ForEach(this.results, itemGenerator: { member: ContactDisplayData, _idx: Int64 =>
                        ListItem {
                            Row {
                                // 头像（首字母圆形）
                                Column {
                                    Text(member.getAvatarInitials())
                                        .fontSize(18)
                                        .fontColor(0xFFFFFF)
                                        .fontWeight(FontWeight.Medium)
                                }
                                .width(44)
                                .height(44)
                                .borderRadius(22)
                                .backgroundColor(this.getAvatarColor(member))
                                .justifyContent(FlexAlign.Center)
                                .alignItems(HorizontalAlign.Center)
                                .margin(left: 12, right: 12)

                                // 名称 + 副标题
                                Column {
                                    Text(member.getDisplayName())
                                        .fontSize(16)
                                        .fontColor(0x1C1C1E)
                                        .fontWeight(FontWeight.Medium)
                                        .maxLines(1)
                                        .textOverflow(TextOverflow.Ellipsis)
                                        .width(100.percent)

                                    Text(this.getRoleLabel(member))
                                        .fontSize(13)
                                        .fontColor(0x8E8E93)
                                        .maxLines(1)
                                        .textOverflow(TextOverflow.Ellipsis)
                                        .width(100.percent)
                                }
                                .layoutWeight(1)
                                .alignItems(HorizontalAlign.Start)
                                .justifyContent(FlexAlign.Center)

                                // 在线指示点
                                if (member.isOnline) {
                                    Column {}
                                        .width(10)
                                        .height(10)
                                        .borderRadius(5)
                                        .backgroundColor(0x34C759)
                                        .margin(right: 16)
                                }
                            }
                            .width(100.percent)
                            .height(64)
                            .alignItems(VerticalAlign.Center)
                            .onClick({ _evt =>
                                this.onMemberSelected(member)
                            })
                        }
                    })
                }
                .width(100.percent)
                .layoutWeight(1)
                .divider(ListDividerOptions(strokeWidth: 0.5, color: 0xE5E5EA, startMargin: 68, endMargin: 0))
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFF)
    }
}
