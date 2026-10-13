package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings, PresentationSnapshot, currentPresentation}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.ArkData.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getSaveToCameraRollService
import ohos_app_cangjie_entry.services.getGlobalAbilityContext
import ohos_app_cangjie_entry.services.{MediaAutoSaveException, encodeMediaAutoSaveExceptions, decodeMediaAutoSaveExceptions}
import ohos_app_cangjie_entry.services.getRealChatListService
import ohos_app_cangjie_entry.models.Chat
import ohos_app_cangjie_entry.components.{
    Avatar,
    SearchBar
}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import std.collection.ArrayList
import std.convert.*

/**
 * AutosaveExceptionPeerSelectionPage — diag-suite_settings_data_storage-TC-0424-round6.md
 * I-1 / TC-0423.md FIX-B「改动 2」的新建选择器屏（零归属新文件，2026-08-31 grant）。
 *
 * round7 F-1 拆分（diag-suite_settings_data_storage-TC-0424-round7.md）：本文件此前把
 * 源侧 `addPeer`(暂存态)/`peer`(编辑态) 两个 scope 收在同一个路由页内部的 `pickerPhase`
 * 假态里，导致该路由永远只能注册成 push（无法同时满足"选择器阶段 push、配置阶段
 * modal"两个互斥要求）、标题读错、缺首行头像块三处结构性缺陷。round7 起本文件**只保留
 * 选择器阶段**——选中候选后跳转到独立路由 `AutosaveExceptionConfigPage`（承载
 * `addPeer`/`peer` 两个 scope 的配置态，登记为 modal），本文件继续保持 push。
 *
 * 路由参数：
 *   `routerPush("AutosaveExceptionPeerSelectionPage", "<peerType>")` —— 唯一入口
 *   （`SaveIncomingMediaPage.openAddException`），进入即选择器。
 *
 * 出口（round7 F-2，对位源侧 :518-530 选中后判定 + `:558-571 dismissAll`）：
 *   候选已是例外（理论上因 F-2 起选择器不再过滤已是例外的候选而可达）⇒
 *   `routerReplaceTop("AutosaveExceptionConfigPage", "<peerType>|<peerId>")`（`.peer`
 *   scope，弹掉选择器自身、原地压入配置屏）；
 *   否则 ⇒ `routerPush("AutosaveExceptionConfigPage", "<peerType>|<peerId>|new")`
 *   （`.addPeer` scope，选择器仍留在栈上，供配置屏提交时 dismissAll 两次 pop）。
 */

private func containsId(list: ArrayList<Int64>, id: Int64): Bool {
    var i: Int64 = 0
    while (i < list.size) {
        if (list[i] == id) { return true }
        i += 1
    }
    return false
}

@HybridComponentEntry
@Component
public class AutosaveExceptionPeerSelectionPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @State var peerType: String = "private"
    @State var paramParsed: Bool = false
    @State var loaded: Bool = false

    @State var candidates: ArrayList<Chat> = ArrayList<Chat>()
    @State var candidatesLoading: Bool = false
    @State var pickerQuery: String = ""

    private func parseRouteParamOnce(): Unit {
        if (this.paramParsed) { return }
        this.paramParsed = true
        let raw = takePending("AutosaveExceptionPeerSelectionPage")
        if (raw.size == 0 || raw == "{}") { return }
        let trimmed = raw.trimAscii()
        let parts = trimmed.split("|")
        if (parts.size >= 1 && parts[0].size > 0) {
            let pt = parts[0]
            if (pt == "groups" || pt == "channels") {
                this.peerType = pt
            } else {
                this.peerType = "private"
            }
        }
    }

    // ── 候选列表（对位源侧 :505-514 三种 peerType 过滤规则）。round7 F-2：不再额外过滤
    // 「已是例外」的候选 —— 源侧 filter 只有 [.excludeRecent, .doNotSearchMessages,
    // .removeSearchHeader] + 类型项，「已是例外」的判定发生在选中之后（见 selectCandidate），
    // 不是列表过滤条件。 ──
    private func loadCandidates(): Unit {
        this.candidatesLoading = true
        let pt = this.peerType
        let _ = spawn {
            let chats = getRealChatListService().getDialogsLocalFirst(limit: 200)
            let out = ArrayList<Chat>()
            for (chat in chats) {
                var match_ = false
                if (pt == "private") {
                    match_ = chat.peerType == "user" && !chat.isSecretChat && !chat.isSavedMessages
                } else if (pt == "groups") {
                    match_ = chat.isGroup
                } else {
                    match_ = chat.isChannel && !chat.isGroup
                }
                if (match_) {
                    out.add(chat)
                }
            }
            let result = out
            spawn(UIThread) {
                =>
                this.candidates = result
                this.candidatesLoading = false
            }
        }
    }

    // round7 F-2：保留 —— selectCandidate 的分叉判定要用。
    private func loadExceptionPeerIds(): ArrayList<Int64> {
        let out = ArrayList<Int64>()
        let raw = getSaveToCameraRollService().getMediaSettingString(
            "${this.peerType}_exceptions", "")
        for (e in decodeMediaAutoSaveExceptions(raw)) {
            out.add(e.peerId)
        }
        return out
    }

    private func filteredCandidates(): ArrayList<Chat> {
        if (this.pickerQuery.size == 0) { return this.candidates }
        let q = this.pickerQuery.toAsciiLower()
        let out = ArrayList<Chat>()
        for (c in this.candidates) {
            if (c.name.toAsciiLower().contains(q)) { out.add(c) }
        }
        return out
    }

    // round7 F-2：选中后两分叉，逐字对位源侧 :518-530——「已是例外」的判定从"列表过滤"
    // 挪到"选中之后"。不要用 routerReplace（会把到达点标成栈底，抹掉返回入口），必须用
    // routerReplaceTop（弹出栈顶一层、原地 push，更下层历史不动）。
    private func selectCandidate(chat: Chat): Unit {
        if (containsId(this.loadExceptionPeerIds(), chat.id)) {
            routerReplaceTop("AutosaveExceptionConfigPage", "${this.peerType}|${chat.id}")
        } else {
            routerPush("AutosaveExceptionConfigPage", "${this.peerType}|${chat.id}|new")
        }
    }

    @Builder
    func buildCandidateRow(entry: Chat) {
        Row {
            Avatar(
                avatarUrl: entry.avatarLocalPath,
                displayName: entry.name,
                avatarSize: 40,
                peerId: entry.id
            )
            Row {
                Text(entry.name)
                    .fontSize(17).fontColor(this.presentation.textColor)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                    .flexShrink(1)
                if (entry.isVerified) {
                    Image(@r(app.media.clist_ic_verified))
                        .width(17).height(17).margin(left: 4)
                        .fillColor(this.presentation.accentColor)
                }
            }
            .layoutWeight(1)
            .margin(left: 12)
        }
        .width(100.percent)
        .height(56)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.selectCandidate(entry) })
    }

    @Builder
    func buildPickerPhase() {
        Column {
            SearchBar(
                loading: false,
                backArrow: false,
                text: this.pickerQuery,
                hint: trSource("Search"),
                onChange: { s: String => this.pickerQuery = s }
            )
            if (this.candidatesLoading) {
                Column {
                    LoadingProgress().width(32).height(32)
                }
                .width(100.percent).layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                List {
                    ForEach(this.filteredCandidates(), itemGenerator: { entry: Chat, _idx: Int64 =>
                        ListItem {
                            this.buildCandidateRow(entry)
                        }
                    }, keyGeneratorFunc: { entry: Chat, _idx: Int64 => "candidate_${entry.id}" })
                }
                .layoutWeight(1)
            }
        }
        .width(100.percent)
        .layoutWeight(1)
    }

    public func build() {
        Column {
            Row {
                Row { Image(@r(app.media.callui_ic_close)).width(18).height(18).fillColor(this.presentation.accentColor) }
                    .width(44).height(44).borderRadius(22)
                    .backgroundColor(if (this.presentation.isDark) { 0x663A3A3C } else { 0x99FFFFFF })
                    .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
                    .onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
                Text(trSource("Add Exception"))
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.presentation.textColor)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                Blank().layoutWeight(1)
                Row { }.width(60)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(this.presentation.navBarColor)
            .alignItems(VerticalAlign.Center)

            this.buildPickerPhase()
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.presentation.backgroundColor)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ =>
            this.parseRouteParamOnce()
            if (!this.loaded) {
                this.loaded = true
                this.loadCandidates()
            }
        })
    }
}
