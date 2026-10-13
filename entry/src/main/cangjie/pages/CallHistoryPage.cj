package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getCallService, getCallListService, getCallListSettingsService, getCallsService, getPeerInfoService, ActiveGroupCallPeer, isCallsTabShown, setCallsTabShown, showToast}
import ohos_app_cangjie_entry.utils.{copyText, localDayIndexOf}
import ohos_app_cangjie_entry.interop.{callArkAsync, SHARE_LINK}
import ohos_app_cangjie_entry.services.getUserPhotoService
import ohos_app_cangjie_entry.services.setSelectedChat
import ohos_app_cangjie_entry.services.{getRealContactService, ContactDisplayData}
import ohos_app_cangjie_entry.models.CallRecord
import ohos_app_cangjie_entry.components.{ContextMenuView, ContextMenuItem}
import std.collection.ArrayList
import std.convert.*
import std.sync.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.utils.safeAnimateTo
import ohos.arkui.ui_context.{MeasureUtils, MeasureOptions}
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation, PresentationStringsSnapshot, currentPresentationStrings}

// TC-0018 返修（§B4）：Calls tab 新建通话一次性命令通道，对位源侧
// CallListController.tabBarActivateSearch() -> beginCallImpl()（一次性动作，非可持续搜索态，
// 源侧无 tabBarDeactivateSearch 覆写）。CallHistoryPage 同时是独立可路由的
// @HybridComponentEntry 页面（SettingsPage "Recent Calls" 直接 push 零参构造），@Prop
// 要求父组件构造时提供初值、与该零参构造路径冲突（cjpm 编译期 argc 不匹配），故不用 @Prop——
// 改用与 ChatRoomPage.cj:24-39（requestChatSearchOnReturn/registerChatSearchHandler）同款的
// 「模块级处理器注册 + host 触发」通道：处理器直接调用子组件自身方法，真实响应式。
private var _callsNewCallHandler: Option<() -> Unit> = None

public func fireCallsNewCallRequest(): Unit {
    match (_callsNewCallHandler) {
        case Some(handler) => handler()
        case None => ()
    }
}

private func registerCallsNewCallHandler(handler: () -> Unit): Unit {
    _callsNewCallHandler = Some(handler)
}

// CallRecord is a plain (non-observed) class and does not implement ToString, so ForEach's default
// key is the bare index: when the list switches All -> Missed or a row is deleted, rows at unchanged
// indices keep their old content (and an opened swipe action). iOS diffs CallListNodeEntry by
// message index (CallListNodeEntries.swift stableId), so the key carries the row's messages and
// every field the row renders.
private func callRowKey(call: CallRecord, idx: Int64): String {
    var ids = ""
    for (m in call.groupMsgIds) { ids = ids + "${m}," }
    return "c_${idx}_${call.msgId}_${ids}_${call.peerId}_${call.peerName}_${call.isMissed}_${call.isOutgoing}_${call.mediaType}_${call.duration}_${call.timestamp}"
}

/**
 * 通话记录页面 (Phase K5 + T fix: auto-sync)（混合工程迁移版）
 *
 * 对应 TelegramHarmony CallHistoryPage.ets
 *
 * 功能：
 * - All / Missed 筛选
 * - 通话记录列表（头像 + 姓名 + 通话类型图标 + 时间戳）
 * - 点击通话按钮发起新通话
 * - 空列表提示
 * - 自动同步：定期从 API 刷新 + 检测 CallService 变更
 */
@HybridComponentEntry
@Component
public class CallHistoryPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // rework1 修复（D-142 required_fix #2）：CallHistoryPage 同时是 MainTabPage TabContent
    // 常驻单例 + routerPush("CallHistoryPage", "") 独立压栈打开的页面（SettingsPage.cj:913
    // 「Recent Calls」）。模块级 _callsNewCallHandler 只允许被"容器常驻实例"注册，独立压栈实例
    // 跳过 register，避免其在 pop 销毁后把模块级 handler 永久劫持为悬挂闭包（见
    // dev_pattern.md D-142）。MainTabPage 直接实例化时显式传 isTabHosted: true；routerPush
    // 走 ArkTS CJHybridComponent 零参桥接，无法传参，默认落到 false，天然跳过 register。
    public var isTabHosted: Bool = false
    // TC-0540 / HI-0006 B2：Calls 根 Tab 此前零订阅 presentation，系统深色下
    // 只有 MainTabPage chrome 变深、本页背景/空态/行色停在浅色字面量。写法对位
    // ChatListPage / SettingsPage：本组件自己订 AppStorage["presentation"]。
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @StorageLink["presentationStrings"] var presentationStrings: PresentationStringsSnapshot = currentPresentationStrings()
    @State var filterType: String = "all"  // "all" | "missed"
    @State var calls: ArrayList<CallRecord> = ArrayList<CallRecord>()
    @State var callsVersion: Int64 = 0  // 强制 UI 刷新计数器
    // Mirrors CallListControllerNode.updateEmptyPlaceholder: list and empty
    // content crossfade over 250ms when the selected call scope changes.
    @State var contentOpacity: Float64 = Float64(1.0)
    // 混合迁移：删除 @Consume var pageStack（NavDestination 由 ArkTS 壳提供，导航经 router.*）

    @State var isEditMode: Bool = false
    // CTL-CALLS-005: 编辑态红色减号控件滑入位移（0→38，iOS ItemListEditableControl 38pt）
    @State var editShift: Float64 = 0.0
    // CTL-CALLS-005: 点减号后展开右侧 Delete 按钮的行下标
    @State var revealedDeleteIdx: Int64 = -1
    // CTL-SHARED-002: 行按压高亮（瞬时进入 / 0.4s 淡出）
    @State var pressedCallIdx: Int64 = -1
    // CTL-CALLS-004: ⓘ 按钮按压 alpha 0.4（瞬时）/ 0.2s 释放
    @State var pressedInfoIdx: Int64 = -1
    // CTL-CALLS-002: 分段控件白色滑块位置/宽度（All: x3 w62 / Missed: x65 w74）
    @State var thumbX: Float64 = 3.0
    @State var thumbW: Float64 = 62.0
    // CTL-CALLS-003: Start New Call 底部 sheet
    @State var showNewCallSheet: Bool = false
    @State var callSheetDim: Float64 = 0.0
    @State var callSheetShift: Float64 = 2000.0
    @State var callSheetContacts: ArrayList<ContactDisplayData> = ArrayList<ContactDisplayData>()
    // CTL-CALLS-001: Edit/Done 标签交叉淡入
    @State var editBtnAlpha: Float64 = 1.0
    @State var avatarVersion: Int64 = 0
    
    @State var showContextMenu: Bool = false
    @State var contextMenuIdx: Int64 = -1

    // S8-23: "ACTIVE VOICE CHATS" rows (CallListNodeEntries.swift:227-238, tab mode + All only)
    @State var groupCallPeers: ArrayList<ActiveGroupCallPeer> = ArrayList<ActiveGroupCallPeer>()
    var _joiningGroupCall: Bool = false
    // S8-26: "Show Calls Tab" switch, only when opened from Settings (CallListNodeEntries.swift:244-246)
    @State var showCallsTabSetting: Bool = isCallsTabShown()
    // S8-22: delete confirmation action sheet (CallListControllerNode.swift:353-396)
    @State var showDeleteSheet: Bool = false
    @State var deleteSheetName: String = ""
    @State var deleteSheetDim: Float64 = 0.0
    @State var deleteSheetShift: Float64 = 600.0
    var deleteSheetMsgIds: ArrayList<Int32> = ArrayList<Int32>()
    // S8-19: Create Call Link (CallListController.swift:239-345)
    @State var creatingCallLink: Bool = false
    @State var showLinkSheet: Bool = false
    @State var callLink: String = ""
    // S8-19: link field width (vp) for the middle truncation below.
    @State var callLinkBoxWidth: Float64 = 0.0
    @State var linkSheetDim: Float64 = 0.0
    @State var linkSheetShift: Float64 = 900.0
    
    var _syncActive: Bool = false
    // filterType mirror readable from the sync loop thread
    var _filterMissed: Bool = false
    var _photoCallbackRegistered: Bool = false
    // 长按开菜单后抑制同一手势触发的 onClick 回拨
    var _suppressRowClick: Bool = false

    @State var isLoading: Bool = true
    @State var _touchDownTime: Int64 = 0
    @State var _touchIdx: Int64 = -1

    // ContextMenuView items（由 openCallMenu() 填充）
    var callMenuItems: Array<ContextMenuItem> = Array<ContextMenuItem>()

    @State var loaded: Bool = false
    @State var showCallsTab: Bool = true

    // iOS parity（TC-SCROLL）：内容区视口高（vp），由 onAreaChange 回填。
    // 用于：①空态撑满视口使 Spring 可回弹；②短列表底部填充高度计算。
    @State var contentVH: Float64 = 0.0
    // 短内容过滚后弹回用 scroller
    private let callsListScroller: Scroller = Scroller()
    private let callsEmptyScroller: Scroller = Scroller()

    // 混合迁移：aboutToAppear 有实逻辑 → ensureLoaded()（.onAppear 触发，守卫只跑一次）
    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.showCallsTab = getCallListSettingsService().getShowTab()
        Hilog.info(0, "CjTelegram", "[CallHistory] onAppear — 自管理数据")
        // TC-0018 返修（§B4）：注册"新建通话"一次性命令处理器，供 MainTabPage 的
        // activateSearchOnCurrentTab() 在 Calls tab 上触发（fireCallsNewCallRequest()）。
        // rework1 修复（D-142）：只有容器常驻实例（isTabHosted=true）才 register，独立
        // routerPush 压栈打开的实例（isTabHosted 默认 false）跳过——避免其覆盖常驻实例的
        // 绑定后又在 pop 销毁时留下悬挂闭包。
        if (this.isTabHosted) {
            registerCallsNewCallHandler({ => this.openNewCallSheet() })
        }
        this.registerPhotoCallback()
        this.startSyncLoop()
        this.refreshGroupCalls()
        let svc = getCallListService()
        svc.setCallListChangedCallback({ newCalls: ArrayList<CallRecord> =>
            let fresh = ArrayList<CallRecord>()
            for (c in newCalls) { fresh.add(c) }
            launch {
                this.calls = fresh
                this.callsVersion = this.callsVersion + 1
                this.isLoading = false
            }
        })
        this.isLoading = true
        svc.getCallList(this.filterType == "missed")
        let current = svc.getCallList()
        let fresh = ArrayList<CallRecord>()
        for (c in current) { fresh.add(c) }
        launch {
            this.calls = fresh
            this.callsVersion = this.callsVersion + 1
            this.isLoading = false
            this.triggerPhotoDownloads()
        }
    }

    private func updateShowCallsTab(show: Bool): Unit {
        this.showCallsTab = show
        getCallListSettingsService().setShowTab(show)
    }

    @Builder
    private func callsTabSetting() {
        if (!this.isTabHosted) {
            Column {
                Text(this.presentationStrings.getOr("CallSettings_TabIconDescription", "A call icon will appear in the tab bar."))
                    .fontSize(13)
                    .fontColor(this.presentation.secondaryTextColor)
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 9, bottom: 7)
                Row {
                    Text(this.presentationStrings.getOr("CallSettings_TabIcon", "Show Calls Tab"))
                        .fontSize(17)
                        .fontColor(this.presentation.textColor)
                        .layoutWeight(1)
                    Toggle(ToggleType.Switch, isOn: this.showCallsTab)
                        .selectedColor(0xFF34C759)
                        .onChange({ show: Bool => this.updateShowCallsTab(show) })
                }
                .width(100.percent)
                .height(50)
                .padding(left: 16, right: 16)
                .alignItems(VerticalAlign.Center)
                .backgroundColor(this.presentation.cardColor)
            }
            .width(100.percent)
            .backgroundColor(this.presentation.backgroundColor)
        }
    }
    
    private func registerPhotoCallback(): Unit {
        if (this._photoCallbackRegistered) { return }
        this._photoCallbackRegistered = true
        getUserPhotoService().addPhotoReadyCallback({ _userId: Int64, _dataUrl: String =>
            launch { this.avatarVersion = this.avatarVersion + 1 }
        })
    }
    
    private func triggerPhotoDownloads(): Unit {
        let userIds = ArrayList<Int64>()
        for (c in this.calls) {
            if (c.peerId > 0) { userIds.add(c.peerId) }
        }
        if (!userIds.isEmpty()) {
            getUserPhotoService().requestFullPhotosForUsers(userIds)
        }
    }
    
    // 混合迁移：aboutToDisappear 有实清理逻辑 → cleanup()，经根容器组件级 .onDisAppear 触发
    private func cleanup(): Unit {
        Hilog.info(0, "CjTelegram", "[CallHistory] onDisAppear — cleaning up")
        this._syncActive = false
        getCallListService().clearCallListChangedCallback()
    }
    
    /**
     * 后台同步循环 — 作为回调机制的备用
     * 每 15 秒从 API 刷新一次，确保数据最终一致
     * 主要更新路径是通过 CallService callback，不依赖此循环
     */
    private func startSyncLoop(): Unit {
        if (this._syncActive) { return }
        this._syncActive = true
        spawn {
            Hilog.info(0, "CjTelegram", "[CallHistory] Sync loop started")
            var tickCount: Int64 = 0
            while (this._syncActive) {
                sleep(Duration.second * 5)
                tickCount = tickCount + 1
                
                try {
                    let service = getCallService()
                    
                    // 检查 flag（本地通话结束 / UpdatesManager 推送）
                    if (service.getCallHistoryNeedsRefresh()) {
                        service.clearCallHistoryNeedsRefresh()
                        sleep(Duration.second * 2)  // 等待服务器持久化
                        service.loadRealCallHistory(this._filterMissed)
                        // loadRealCallHistory 会通过 callback 推送
                        Hilog.info(0, "CjTelegram", "[CallHistory] Sync: refreshed via flag")
                        continue
                    }
                    
                    // 每 15 秒 (~3 ticks) 做一次 API 全量刷新
                    if (tickCount % 3 == 0) {
                        service.loadRealCallHistory(this._filterMissed)
                        if (this.isTabHosted) {
                            let peers = getCallListService().loadActiveGroupCallPeers()
                            launch { this.groupCallPeers = peers }
                        }
                        Hilog.info(0, "CjTelegram", "[CallHistory] Sync: periodic refresh done")
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CallHistory] Sync loop error: ${e}")
                }
            }
            Hilog.info(0, "CjTelegram", "[CallHistory] Sync loop stopped")
        }
    }

    /**
     * iOS parity（TC-SCROLL-003）：短列表底部填充——使内容略超视口，Spring 恒可回弹，
     * 且末行静止于悬浮 tab bar 之上（88 = bar 带高，对应 iOS intrinsicInsets.bottom）。
     * 内容估算：Start New Call 52 + RECENT CALLS 头 29 + 每行 ~66。
     */
    private func callsBottomFillerH(): Float64 {
        let content = 52.0 + 29.0 + 66.0 * Float64(this.getFilteredCount())
        let want = this.contentVH - content + 88.0
        if (want > 88.0) { return want }
        return 88.0
    }

    private func toggleEditMode(): Unit {
        this.isEditMode = !this.isEditMode
        this.revealedDeleteIdx = -1
        // CTL-CALLS-001: Edit/Done 标签交换交叉淡入（iOS UIBarButtonItem crossfade）
        this.editBtnAlpha = 0.0
        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 200, curve: Curve.EaseInOut), { =>
            this.editBtnAlpha = 1.0
        })
        // CTL-CALLS-005: 红色减号 38pt 编辑控件 0.4s 弹性滑入，内容整体右移（iOS 无选择圆圈）
        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 400, curve: Curve.EaseOut), { =>
            this.editShift = if (this.isEditMode) { 38.0 } else { 0.0 }
        })
    }

    // CTL-CALLS-005: 减号 → Delete 按钮 → 删除该组全部（iOS 合并组内所有通话一并删）
    private func deleteGroupRecords(call: CallRecord): Unit {
        this.revealedDeleteIdx = -1
        this.openDeleteSheet(call.peerName, call.groupMsgIds)
    }

    // S8-22: CallListControllerNode.swift:353-396 — ActionSheet: text CallList_DeleteConfirmation,
    // "Delete for me and <peer>" (.forEveryone → revoke), "Delete for me" (.forLocalPeer), Cancel group.
    private func openDeleteSheet(peerName: String, msgIds: ArrayList<Int32>): Unit {
        if (msgIds.size == 0) { return }
        let ids = ArrayList<Int32>()
        for (m in msgIds) { ids.add(m) }
        this.deleteSheetMsgIds = ids
        this.deleteSheetName = peerName
        this.deleteSheetDim = 0.0
        this.deleteSheetShift = 600.0
        this.showDeleteSheet = true
        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 300, curve: Curve.EaseOut), { =>
            this.deleteSheetDim = 0.4
            this.deleteSheetShift = 0.0
        })
    }

    private func closeDeleteSheet(): Unit {
        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 250, curve: Curve.EaseInOut), { =>
            this.deleteSheetDim = 0.0
            this.deleteSheetShift = 600.0
        })
        let _ = spawn {
            sleep(Duration.millisecond * 260)
            launch { this.showDeleteSheet = false }
        }
    }

    private func confirmDelete(revoke: Bool): Unit {
        let ids = this.deleteSheetMsgIds
        this.deleteSheetMsgIds = ArrayList<Int32>()
        this.closeDeleteSheet()
        let _ = spawn {
            let ok = getCallListService().deleteCallRecords(ids, revoke)
            Hilog.info(0, "CjTelegram", "[CallHistory] delete count=${ids.size} revoke=${revoke} ok=${ok}")
            // iOS removes the entries from the call list view as soon as the messages are deleted
            // (CallListControllerNode.swift:353-396). The service callback is page-global and may be
            // held by the other CallHistoryPage instance, so this page drops the rows itself too.
            if (ok) {
                launch { this.removeCallsLocally(ids) }
            }
        }
    }

    private func removeCallsLocally(ids: ArrayList<Int32>): Unit {
        let remaining = ArrayList<CallRecord>()
        for (c in this.calls) {
            var hit = false
            for (m in ids) {
                if (c.msgId == m) {
                    hit = true
                    break
                }
            }
            if (!hit) { remaining.add(c) }
        }
        if (remaining.size != this.calls.size) {
            this.calls = remaining
            this.callsVersion = this.callsVersion + 1
        }
    }

    // S8-23: CallListControllerNode.swift:408-465 openGroupCall — current GroupCallDescription of the
    // peer (full info), then join. Same GroupCallScreen parameter format as PeerInfoPage.doStartVideoChat.
    private func refreshGroupCalls(): Unit {
        if (!this.isTabHosted) { return }
        let _ = spawn {
            let peers = getCallListService().loadActiveGroupCallPeers()
            launch { this.groupCallPeers = peers }
        }
    }

    private func openGroupCall(peer: ActiveGroupCallPeer): Unit {
        if (this._joiningGroupCall) { return }
        this._joiningGroupCall = true
        let pType = peer.peerType
        let pid = peer.peerId
        let canManage = peer.canManageCall
        let _ = spawn {
            getPeerInfoService().invalidateGroupFullInfo(pid)
            let full = getPeerInfoService().getGroupFullInfo(pType, pid)
            launch {
                this._joiningGroupCall = false
                if (full.activeCallId != 0) {
                    routerPush("GroupCallScreen", "${full.activeCallId}:${full.activeCallAccessHash}::${pType}:${pid}:${if (canManage) { "1" } else { "0" }}")
                } else {
                    // The call ended meanwhile: iOS joins nothing; drop the stale row.
                    this.refreshGroupCalls()
                }
            }
        }
    }

    // S8-26: CallListControllerNode.swift:397-406 updateShowCallsTab
    private func onShowCallsTabChanged(value: Bool): Unit {
        this.showCallsTabSetting = value
        setCallsTabShown(value)
    }

    // S8-19: CallListController.swift:566 option "Create Call Link" → createGroupCall(peerIds: [])
    // → engine.calls.createConferenceCall → InviteLinkInviteController(.groupCall) with the link.
    private func createCallLink(): Unit {
        if (this.creatingCallLink) { return }
        this.creatingCallLink = true
        let _ = spawn {
            let created = getCallsService().createConferenceCallLink()
            launch {
                this.creatingCallLink = false
                match (created) {
                    case Some((_, _, link)) => this.openLinkSheet(link)
                    case None => Hilog.info(0, "CjTelegram", "[CallHistory] createConferenceCall failed")
                }
            }
        }
    }

    private func openLinkSheet(link: String): Unit {
        this.callLink = link
        this.linkSheetDim = 0.0
        this.linkSheetShift = 900.0
        this.showLinkSheet = true
        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 400, curve: Curve.EaseOut), { =>
            this.linkSheetDim = 0.4
            this.linkSheetShift = 0.0
        })
    }

    private func closeLinkSheet(): Unit {
        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 300, curve: Curve.EaseInOut), { =>
            this.linkSheetDim = 0.0
            this.linkSheetShift = 900.0
        })
        let _ = spawn {
            sleep(Duration.millisecond * 310)
            launch { this.showLinkSheet = false }
        }
    }

    // InviteLinkInviteController copyLink: pasteboard, dismiss, completed(.linkCopied) → toast
    // CallList_ToastCallLinkCopied_Text (CallListController.swift:327-330).
    private func copyCallLink(): Unit {
        let _ = copyText(this.callLink)
        this.closeLinkSheet()
        showToast(this.presentationStrings.getOr("CallList_ToastCallLinkCopied_Text", "Call link copied"))
    }

    private func shareCallLink(): Unit {
        let link = this.callLink
        if (link.size == 0) { return }
        let escaped = link.replace("\\", "\\\\").replace("\"", "\\\"")
        callArkAsync(SHARE_LINK, "{\"url\":\"${escaped}\",\"title\":\"Call Link\"}", { res =>
            Hilog.info(0, "CjTelegram", "[CallHistory] share call link result=${res}")
        })
    }

    // ItemListPermanentInviteLinkItem.swift:337 lays the address out on one line with
    // truncationType: .middle. ArkUI's Text only truncates at word boundaries (no
    // wordBreak/ellipsisMode in this binding), so "t.me/call/<slug>" collapsed to
    // "t.me/call/…" and looked like the link never loaded. Keep head + tail around a
    // middle ellipsis that fits the field, measured with the field's own font.
    private func displayCallLink(): String {
        let full = this.callLink.replace("https://", "")
        let boxVp = this.callLinkBoxWidth - 32.0
        if (full.size == 0 || boxVp <= 0.0) { return full }
        let budget = match (this.getUIContext().vp2px(boxVp.vp)) {
            case Some(v) => v.value
            case None => 0.0
        }
        if (budget <= 0.0) { return full }
        let mu = this.getUIContext().getMeasureUtils()
        if (this.measureLink(mu, full) <= budget) { return full }
        let runes = full.toRuneArray()
        var lo: Int64 = 0
        var hi: Int64 = runes.size
        var best = "\u{2026}"
        while (lo <= hi) {
            let keep = (lo + hi) / 2
            let cand = this.middleElided(runes, keep)
            if (this.measureLink(mu, cand) <= budget) {
                best = cand
                lo = keep + 1
            } else {
                hi = keep - 1
            }
        }
        return best
    }

    private func measureLink(mu: MeasureUtils, t: String): Float64 {
        mu.measureText(MeasureOptions(textContent: t, fontSize: 17.0.vp))
    }

    private func middleElided(runes: Array<Rune>, keep: Int64): String {
        let head = (keep + 1) / 2
        let tail = keep - head
        var out = ""
        var i: Int64 = 0
        while (i < head) { out += runes[i].toString(); i++ }
        out += "\u{2026}"
        var j: Int64 = runes.size - tail
        while (j < runes.size) { out += runes[j].toString(); j++ }
        out
    }

    private func visibleGroupCallCount(): Int64 {
        if (this.isTabHosted && this.filterType == "all") { return Int64(this.groupCallPeers.size) }
        return 0
    }

    // iOS parity（CallListNodeEntries: view.items 把相邻同一 peer 的通话合并成一组，
    // CallListCallItem.swift:481 名字后加 " (N)"）。渲染前对可见列表做相邻同 peerId 合并。
    // 返回"代表"CallRecord（组内最近一次），其 groupCount/groupMsgIds 瞬态字段被填充；
    // 用瞬态字段而非独立组类型，是为避免 ForEach 闭包体（build 上下文）内出现 let（项目规则禁止）。
    private func groupedVisibleCalls(): ArrayList<CallRecord> {
        let reps = ArrayList<CallRecord>()
        for (c in this.calls) {
            if (!this.isCallVisible(c)) { continue }
            // iOS AccountViewTracker.callListView groupingPredicate (2452-2505): same peer, same
            // local day, same missed/other status and same media kind.
            if (reps.size > 0 && reps[reps.size - 1].peerId == c.peerId
                && localDayIndexOf(Int64(reps[reps.size - 1].date)) == localDayIndexOf(Int64(c.date))
                && reps[reps.size - 1].isMissed == c.isMissed
                && reps[reps.size - 1].mediaType == c.mediaType) {
                let rep = reps[reps.size - 1]
                rep.groupCount = rep.groupCount + 1
                if (c.msgId > 0) { rep.groupMsgIds.add(c.msgId) }
            } else {
                c.groupCount = 1
                c.groupMsgIds = ArrayList<Int32>()
                if (c.msgId > 0) { c.groupMsgIds.add(c.msgId) }
                reps.add(c)
            }
        }
        return reps
    }

    // CTL-CALLS-001: 编辑态右上 Delete All → 菜单 For Me / For Everyone（iOS ContextController）
    private func openDeleteAllMenu(): Unit {
        this.callMenuItems = [
            ContextMenuItem(
                title: "Delete For Me",
                destructive: true,
                onClick: { =>
                    this.showContextMenu = false
                    this.deleteAllRecords()
                }
            ),
            ContextMenuItem(
                title: "Delete For Everyone",
                destructive: true,
                onClick: { =>
                    this.showContextMenu = false
                    this.deleteAllRecords()
                }
            )
        ]
        this.showContextMenu = true
    }

    private func deleteAllRecords(): Unit {
        let msgIds = ArrayList<Int32>()
        for (c in this.calls) {
            if (c.msgId > 0) { msgIds.add(c.msgId) }
        }
        this.toggleEditMode()
        if (msgIds.size > 0) {
            let _ = spawn {
                let ok = getCallListService().deleteCallRecords(msgIds)
                Hilog.info(0, "CjTelegram", "[CallHistory] deleteAllRecords count=${msgIds.size} ok=${ok}")
            }
        }
    }

    // CTL-CALLS-003 / CTL-SHARED-004: Start New Call → 底部 sheet 联系人选择
    // （iOS ContactMultiselection navigationPresentation=.modal，非整页 push）
    private func openNewCallSheet(): Unit {
        this.callSheetDim = 0.0
        this.callSheetShift = 2000.0
        this.showNewCallSheet = true
        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 500, curve: Curve.EaseOut), { =>
            this.callSheetDim = 0.25
            this.callSheetShift = 0.0
        })
        let _ = spawn {
            // 命中 RealContactService last-good 缓存（并发合并守卫），通常即时返回
            let list = getRealContactService().getContacts()
            let fresh = ArrayList<ContactDisplayData>()
            for (c in list) {
                if (!c.isSelf && !c.isBot) { fresh.add(c) }
            }
            launch { this.callSheetContacts = fresh }
        }
    }

    private func closeNewCallSheet(): Unit {
        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 300, curve: Curve.EaseInOut), { =>
            this.callSheetDim = 0.0
            this.callSheetShift = 2000.0
        })
        let _ = spawn {
            sleep(Duration.millisecond * 310)
            launch { this.showNewCallSheet = false }
        }
    }

    private func callContact(c: ContactDisplayData): Unit {
        this.closeNewCallSheet()
        let _ = getCallService().requestCall(c.userId, c.accessHash, c.getDisplayName(), false)
        routerPush("CallScreen", "")
    }

    private func makeCall(call: CallRecord): Unit {
        let isVideo = call.mediaType == "video"
        let _ = getCallService().requestCall(call.peerId, 0, call.peerName, isVideo)
        let screenName = if (isVideo) { "VideoCallScreen" } else { "CallScreen" }
        routerPush(screenName, "")
    }

    private func doManualRefresh(): Unit {
        let filterMissed = this.filterType == "missed"
        this._filterMissed = filterMissed
        // Network off the UI thread; the list arrives through the CallListChanged callback.
        let _ = spawn {
            getCallListService().getCallList(filterMissed)
            let userIds = ArrayList<Int64>()
            for (c in getCallService().getCallHistory()) {
                if (c.peerId > 0) { userIds.add(c.peerId) }
            }
            if (!userIds.isEmpty()) {
                getUserPhotoService().requestFullPhotosForUsers(userIds)
            }
        }
    }

    private func onFilterTabClick(newFilter: String): Unit {
        if (this.filterType == newFilter) { return }
        let uiCtx = this.getUIContext()
        // CTL-CALLS-002: 白色滑块 0.4s 弹性滑动到目标段（iOS HorizontalTabsComponent spring 0.4）
        safeAnimateTo({ => uiCtx }, AnimateParam(duration: 400, curve: Curve.EaseOut), { =>
            if (newFilter == "missed") {
                this.thumbX = 65.0
                this.thumbW = 74.0
            } else {
                this.thumbX = 3.0
                this.thumbW = 62.0
            }
        })
        safeAnimateTo({ => uiCtx }, AnimateParam(duration: 125, curve: Curve.EaseInOut), { =>
            this.contentOpacity = Float64(0.0)
        })
        let _ = spawn {
            sleep(Duration.millisecond * 125)
            launch {
                this.filterType = newFilter
                this.doManualRefresh()
                safeAnimateTo({ => uiCtx }, AnimateParam(duration: 125, curve: Curve.EaseInOut), { =>
                    this.contentOpacity = Float64(1.0)
                })
            }
        }
    }

    private func onCallItemLongPress(call: CallRecord, idx: Int64): Unit {
        this.contextMenuIdx = idx
        this.openCallMenu(call)
    }

    // S8-21: CallListController openInfo(peer, messages) → PeerInfoScreen(callMessages: messages); the
    // info page lists the row's calls on top (PeerInfoProfileItems.swift:118-120, ItemListCallListItem).
    private func openCallInfo(call: CallRecord): Unit {
        if (call.peerId <= 0) { return }
        let records = ArrayList<CallRecord>()
        for (c in this.calls) {
            for (m in call.groupMsgIds) {
                if (c.msgId == m) {
                    records.add(c)
                    break
                }
            }
        }
        if (records.size == 0) { records.add(call) }
        setUserProfileCallRecords(call.peerId, records)
        setSelectedChat(call.peerId, call.peerName, "user")
        routerPush("UserProfilePage", "")
    }

    private func openCallMenu(call: CallRecord): Unit {
        let isVideo = call.mediaType == "video"
        this.callMenuItems = [
            ContextMenuItem(
                title: if (isVideo) { "Video Call Back" } else { "Call Back" },
                onClick: { =>
                    this.makeCall(call)
                    this.showContextMenu = false
                }
            ),
            ContextMenuItem(
                title: "Info",
                onClick: { =>
                    this.openCallInfo(call)
                    this.showContextMenu = false
                }
            ),
            ContextMenuItem(
                title: "Delete",
                destructive: true,
                onClick: { =>
                    this.showContextMenu = false
                    this.openDeleteSheet(call.peerName, call.groupMsgIds)
                }
            )
        ]
        this.showContextMenu = true
    }

    private func closeContextMenu(): Unit {
        this.showContextMenu = false
        this.contextMenuIdx = -1
    }

    private func getContextMenuCall(): Option<CallRecord> {
        if (this.contextMenuIdx >= 0 && this.contextMenuIdx < Int64(this.calls.size)) {
            return Some(this.calls[this.contextMenuIdx])
        }
        return None
    }

    private func isCallVisible(call: CallRecord): Bool {
        if (this.filterType == "missed") { return call.isMissed }
        return true
    }

    // 视觉行数 = 合并分组数（用于空态判断与底部 filler 高度估算）
    private func getFilteredCount(): Int64 {
        return Int64(this.groupedVisibleCalls().size)
    }

    // 资源保真修复：原 getCallTypeIcon() 返回 emoji 字形（📵/↗/↙），已删除；
    // 改为在 build() 渲染点用组件级 if/else 直接选 Image(@r(...))（对齐 D-133）。
    // 呼入/呼出箭头图标复用同一对形状，miss 状态仅通过 getCallTypeColor() 变红区分
    // （iOS Telegram 通话记录同样不为 missed 单独出一套图标，只变色）。

    private func getCallTypeColor(c: CallRecord): Int64 {
        if (c.isMissed) { return 0xFF3B30 }
        return 0x34C759
    }

    private func getNameColor(c: CallRecord): UInt32 {
        if (c.isMissed) { return 0xFF3B30 }
        return this.presentation.textColor
    }

    /**
     * iOS parity: 时长显示 "21 sec" / "5 min"（iOS CallListCallItem 风格），
     * 输入为既有 "M:SS" / "H:MM:SS" 字符串。解析失败原样返回。
     */
    private func formatDurationIOS(d: String): String {
        let parts = d.split(":")
        var total: Int64 = 0
        for (p in parts) {
            try {
                total = total * 60 + Int64.parse(p.trimAscii())
            } catch (_: Exception) {
                return d
            }
        }
        if (total < 60) { return "${total} sec" }
        return "${total / 60} min"
    }

    private func getCallTypeText(c: CallRecord): String {
        if (c.isMissed) { return "Missed" }
        if (c.isOutgoing) { return "Outgoing" }
        return "Incoming"
    }

    private func getAvatarColor(peerId: Int64): UInt32 {
        let colors: Array<UInt32> = [
            0xE91E63, 0x9C27B0, 0x3F51B5, 0x03A9F4,
            0x009688, 0x4CAF50, 0xFF9800, 0xFF5722
        ]
        let index = Int64(peerId % 8)
        if (index < 0) { return colors[Int64(-index)] }
        return colors[index]
    }

    private func getInitialChar(name: String): String {
        if (name.size > 0) {
            return name.toRuneArray()[0].toString()
        }
        return "?"
    }

    public func build() {
        Stack {
        Column {
            // ==================== 导航栏 ====================
            Row {
                if (this.isTabHosted) {
                    Text(if (this.isEditMode) { this.presentationStrings.getOr("Common_Done", "Done") } else { this.presentationStrings.getOr("Common_Edit", "Edit") })
                        .fontSize(17)
                        .fontColor(this.presentation.textColor)
                        .fontWeight(if (this.isEditMode) { FontWeight.Bold } else { FontWeight.Regular })
                        .height(36)
                        .padding(left: 12, right: 12)
                        .borderRadius(18)
                        .backgroundColor(this.presentation.cardColor)
                        .textAlign(TextAlign.Center)
                        .opacity(this.editBtnAlpha)
                        .onClick({ _ => this.toggleEditMode() })
                } else {
                    Stack(alignContent: Alignment.Center) {
                        Image(@r(app.media.callui_v2_back))
                            .width(13)
                            .height(22)
                            .fillColor(this.presentation.textColor)
                    }
                    .width(44)
                    .height(44)
                    .borderRadius(22)
                    .backgroundColor(this.presentation.cardColor)
                    .shadow(radius: 12.0, color: 0x14000000, offsetX: 0.0, offsetY: 3.0)
                    .onClick({ _ => routerPop() })
                }

                Blank().layoutWeight(1)

                // CTL-CALLS-002: iOS 玻璃胶囊分段控件（h44 / radius h/2 / 内衬 3），
                // 白色滑块随选中段弹性滑动（非瞬时背景交换），字重恒 medium15
                Stack(alignContent: Alignment.Start) {
                    // G-01: iOS 实拍为白底胶囊 + 浅灰选中块(此前做反了)
                    Row {}
                        .width(this.thumbW)
                        .height(38)
                        .borderRadius(19)
                        .backgroundColor(this.presentation.itemHighlightedBackgroundColor)
                        .margin(left: this.thumbX)
                    Row {
                        Text(this.presentationStrings.getOr("Calls_All", "All"))
                            .fontSize(15)
                            .fontColor(this.presentation.textColor)
                            .fontWeight(FontWeight.Medium)
                            .width(62)
                            .height(38)
                            .textAlign(TextAlign.Center)
                            .onClick({ evt => this.onFilterTabClick("all") })

                        Text(this.presentationStrings.getOr("Calls_Missed", "Missed"))
                            .fontSize(15)
                            .fontColor(this.presentation.textColor)
                            .fontWeight(FontWeight.Medium)
                            .width(74)
                            .height(38)
                            .textAlign(TextAlign.Center)
                            .onClick({ evt => this.onFilterTabClick("missed") })
                    }
                    .padding(left: 3)
                    .alignItems(VerticalAlign.Center)
                }
                .width(142)
                .height(44)
                // G-01: 白底胶囊,靠柔和阴影与白色导航区分(iOS Liquid Glass 近似)
                .backgroundColor(this.presentation.cardColor)
                .borderRadius(22)
                .shadow(radius: 12.0, color: 0x14000000, offsetX: 0.0, offsetY: 3.0)

                Blank().layoutWeight(1)
                if (this.isEditMode) {
                    // CTL-CALLS-001: 编辑态右上 = Delete All（medium17 红色）
                    Text(trSource("Delete All"))
                        .fontSize(17)
                        .fontColor(0xFF3B30)
                        .fontWeight(FontWeight.Medium)
                        .onClick({ evt => this.openDeleteAllMenu() })
                } else if (!this.isTabHosted && !this.isLoading && this.getFilteredCount() > 0) {
                    Text(this.presentationStrings.getOr("Common_Edit", "Edit"))
                        .fontSize(17)
                        .fontColor(this.presentation.textColor)
                        .height(36)
                        .padding(left: 12, right: 12)
                        .borderRadius(18)
                        .backgroundColor(this.presentation.cardColor)
                        .onClick({ _ => this.toggleEditMode() })
                } else {
                    Row {}.width(44).height(44)
                }
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .alignItems(VerticalAlign.Center)
            .backgroundColor(this.presentation.navBarColor)

            Divider().color(this.presentation.dividerColor).strokeWidth(1)

            // ==================== 内容区域 ====================
            // 通话记录列表（CallListService），loading/empty/list 内联
            Column {
                if (this.isLoading) {
                    Column {
                        LoadingProgress().width(40).height(40)
                        Text("Loading calls...")
                            .fontSize(15)
                            .fontColor(this.presentation.secondaryTextColor)
                            .margin(top: 12)
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                } else if (this.getFilteredCount() == 0 && this.visibleGroupCallCount() == 0) {
                    // iOS parity（TC-SCROLL）：空态也可回弹（iOS ListView alwaysBounceVertical）。
                    // Scroll 无 edgeEffect（wrapper 缺口）→ List 包单条 + 测量高内容 + 末尾 40vp
                    // 使内容 > 视口，Spring 生效。
                    List(scroller: this.callsEmptyScroller) {
                    ListItem {
                    Column {
                        // iOS parity (TC-CALLS-003): CallsPlaceholder.tgs → GIF（148×148 循环，3s，
                        // 由 python-lottie/cairosvg 从 iOS 原始 tgs 渲染），ArkUI Image 原生播放 GIF。
                        Image(@r(app.media.callui_anim_placeholder))
                            .width(148)
                            .height(148)
                            .margin(bottom: 13)
                        Text(if (this.filterType == "missed") { this.presentationStrings.getOr("Calls_NoMissedCallsPlacehoder", "You have no missed calls") } else { this.presentationStrings.getOr("Calls_NoVoiceAndVideoCallsPlaceholder", "Your recent voice and video calls will appear here.") })
                            .fontSize(16)
                            .fontColor(this.presentation.secondaryTextColor)
                            .textAlign(TextAlign.Center)
                            .lineHeight(22)

                        Row {
                            Image(@r(app.media.callui_ic_phone))
                                .width(20)
                                .height(20)
                                .fillColor(0xFF007AFF)
                                .margin(right: 10)
                            Text(this.presentationStrings.getOr("Calls_StartNewCall", "Start New Call"))
                                .fontSize(17)
                                .fontColor(0xFF007AFF)
                        }
                        .margin(top: 23)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _ => this.openNewCallSheet() })
                    }
                    .width(100.percent)
                    .height(if (this.contentVH > 100.0) { this.contentVH } else { 600.0 })
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    }
                    ListItem {
                        Row {}.height(40)
                    }
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .scrollBar(BarState.Off)
                    .edgeEffect(EdgeEffect.Spring)
                    .onAreaChange({ _: Area, newArea: Area =>
                        this.contentVH = newArea.height.value
                    })
                    .onScrollStop({ =>
                        if (this.callsBottomFillerH() > 88.5) {
                            this.callsListScroller.scrollTo(xOffset: 0.0, yOffset: 0.0, animation: true)
                        }
                    })
                } else {
                    List(scroller: this.callsListScroller) {
                        // S8-26: Recent Calls opened from Settings (mode .navigation → showSettings):
                        // displayTab switch on top, displayTabInfo footer below (CallListNodeEntries.swift:244-246).
                        if (!this.isTabHosted) {
                            ListItem {
                                Column {
                                    Row {
                                        Text(this.presentationStrings.getOr("CallSettings_TabIcon", "Show Calls Tab"))
                                            .fontSize(17)
                                            .fontColor(this.presentation.textColor)
                                            .layoutWeight(1)
                                        Toggle(ToggleType.Switch, isOn: this.showCallsTabSetting)
                                            .selectedColor(0x34C759)
                                            .onChange({ isOn: Bool => this.onShowCallsTabChanged(isOn) })
                                    }
                                    .width(100.percent)
                                    .height(52)
                                    .padding(left: 16, right: 16)
                                    .borderRadius(12)
                                    .backgroundColor(this.presentation.cardColor)
                                    .alignItems(VerticalAlign.Center)
                                    Text(this.presentationStrings.getOr("CallSettings_TabIconDescription", "A call icon will appear in the tab bar."))
                                        .fontSize(13)
                                        .fontColor(this.presentation.secondaryTextColor)
                                        .width(100.percent)
                                        .padding(left: 16, right: 16, top: 7, bottom: 14)
                                }
                                .width(100.percent)
                                .padding(left: 16, right: 16, top: 16)
                            }
                        }
                        // iOS displayOpenNewCall: type == .all (CallListControllerNode.swift:545)
                        if (!this.isEditMode && this.filterType == "all") {
                            ListItem {
                                Row {
                                    Image(@r(app.media.callui_ic_phone))
                                        .width(22)
                                        .height(22)
                                        .fillColor(0xFF007AFF)
                                        .margin(right: 14)
                                    Text(this.presentationStrings.getOr("Calls_StartNewCall", "Start New Call"))
                                        .fontSize(17)
                                        .fontColor(0xFF007AFF)
                                        .layoutWeight(1)
                                }
                                .width(100.percent)
                                .height(50)
                                .padding(left: 16, right: 16)
                                .backgroundColor(0xFFFFFF)
                                .alignItems(VerticalAlign.Center)
                                .onClick({ _ => this.openNewCallSheet() })
                            }
                        }
                        // S8-23: groupCall entries (CallListNodeEntries.swift:227-238), header .activeVoiceChats
                        if (!this.isEditMode && this.visibleGroupCallCount() > 0) {
                            ListItem {
                                Text(this.presentationStrings.getOr("CallList_ActiveVoiceChatsHeader", "ACTIVE VOICE CHATS"))
                                    .fontSize(13)
                                    .fontColor(0x8E8E93)
                                    .width(100.percent)
                                    .padding(left: 16, top: 10, bottom: 6)
                                    .backgroundColor(this.presentation.backgroundColor)
                            }
                            ForEach(this.groupCallPeers.toArray(), itemGeneratorFunc: { gp: ActiveGroupCallPeer, _gi: Int64 =>
                                ListItem {
                                    Row {
                                        if (getUserPhotoService().getChatPhotoPath(gp.peerId).size > 0) {
                                            Image(getUserPhotoService().getChatPhotoPath(gp.peerId))
                                                .width(40)
                                                .height(40)
                                                .borderRadius(20)
                                                .objectFit(ImageFit.Cover)
                                                .margin(left: 25, right: 12)
                                        } else {
                                            Stack {
                                                Text(this.getInitialChar(gp.title))
                                                    .fontSize(18)
                                                    .fontColor(0xFFFFFF)
                                                    .fontWeight(FontWeight.Medium)
                                            }
                                            .width(40)
                                            .height(40)
                                            .borderRadius(20)
                                            .backgroundColor(this.getAvatarColor(gp.peerId))
                                            .alignContent(Alignment.Center)
                                            .margin(left: 25, right: 12)
                                        }
                                        Text(gp.title)
                                            .fontSize(17)
                                            .fontColor(this.presentation.textColor)
                                            .maxLines(1)
                                            .textOverflow(TextOverflow.Ellipsis)
                                            .layoutWeight(1)
                                        // CallListGroupCallItem.swift:330 VoiceChat_PanelJoin.uppercased(), semibold 15, h28
                                        Text(this.presentationStrings.getOr("VoiceChat_PanelJoin", "Join").toAsciiUpper())
                                            .fontSize(15)
                                            .fontWeight(FontWeight.Medium)
                                            .fontColor(0xFFFFFF)
                                            .height(28)
                                            .padding(left: 10, right: 10)
                                            .borderRadius(14)
                                            .backgroundColor(this.presentation.accentColor)
                                            .onClick({ _ => this.openGroupCall(gp) })
                                    }
                                    .width(100.percent)
                                    .padding(left: 16, right: 13, top: 11, bottom: 11)
                                    .alignItems(VerticalAlign.Center)
                                    .backgroundColor(this.presentation.backgroundColor)
                                    .onClick({ _ => this.openGroupCall(gp) })
                                }
                            }, keyGeneratorFunc: { gp: ActiveGroupCallPeer, _gi: Int64 => "g_${gp.peerType}_${gp.peerId}_${gp.title}" })
                        }
                        // displayHeader = !showSettings && isRecentCalls (CallListNodeEntries.swift:223)
                        if (!this.isEditMode && this.isTabHosted && this.filterType == "all" && this.getFilteredCount() > 0) {
                            ListItem {
                                Text(this.presentationStrings.getOr("CallList_RecentCallsHeader", "RECENT CALLS"))
                                    .fontSize(13)
                                    .fontColor(0x8E8E93)
                                    .width(100.percent)
                                    .padding(left: 16, top: 10, bottom: 6)
                                    .backgroundColor(this.presentation.backgroundColor)
                            }
                        }
                        ForEach(this.groupedVisibleCalls().toArray(), itemGeneratorFunc: { call: CallRecord, idx: Int64 =>
                            if (true) {
                                ListItem {
                                    Column {
                                        Row {
                                            // CTL-CALLS-005: iOS 编辑态无选择圆圈——红色减号 38pt 槽位
                                            // 从左滑入（宽度 0→38 随 editShift 动画），内容右移
                                            Stack {
                                                Stack {
                                                    Row {}
                                                        .width(12)
                                                        .height(2)
                                                        .backgroundColor(0xFFFFFF)
                                                }
                                                .width(22)
                                                .height(22)
                                                .borderRadius(11)
                                                .backgroundColor(0xFF3B30)
                                                .alignContent(Alignment.Center)
                                                .opacity(this.editShift / 38.0)
                                            }
                                            .width(this.editShift)
                                            // S8-16: ItemListEditableControlNode spans the whole row height (38pt x
                                            // contentSize.height), so the minus hit area is the full-height left slot,
                                            // not only the 22pt glyph. Row height stays 60 (was 40 + 2 x 10 padding).
                                            .height(60)
                                            .clip(true)
                                            .alignContent(Alignment.Start)
                                            .onClick({ evt =>
                                                if (!this.isEditMode) { return }
                                                // 减号 → 揭示右侧 Delete（iOS minus 揭示 swipe 删除项）
                                                safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 300, curve: Curve.EaseOut), { =>
                                                    this.revealedDeleteIdx = if (this.revealedDeleteIdx == idx) { -1 } else { idx }
                                                })
                                            })

                                            // iOS parity: 呼叫方向箭头在头像左侧行首（灰色 0x8E8E93，missed 红）
                                            if (call.isOutgoing) {
                                                Image(@r(app.media.callui_ic_outgoing))
                                                    .width(14)
                                                    .height(14)
                                                    .fillColor(if (call.isMissed) { 0xFF3B30 } else { 0x8E8E93 })
                                                    .margin(right: 11)
                                            } else {
                                                Image(@r(app.media.callui_ic_incoming))
                                                    .width(14)
                                                    .height(14)
                                                    .fillColor(if (call.isMissed) { 0xFF3B30 } else { 0x8E8E93 })
                                                    .margin(right: 11)
                                            }

                                            if (getUserPhotoService().getUserPhotoPath(call.peerId).size > 0) {
                                                Image(getUserPhotoService().getUserPhotoPath(call.peerId))
                                                    .width(40)
                                                    .height(40)
                                                    .borderRadius(20)
                                                    .objectFit(ImageFit.Cover)
                                                    .margin(right: 12)
                                            } else {
                                                Stack {
                                                    Text(this.getInitialChar(call.peerName))
                                                        .fontSize(18)
                                                        .fontColor(0xFFFFFF)
                                                        .fontWeight(FontWeight.Medium)
                                                }
                                                .width(40)
                                                .height(40)
                                                .borderRadius(20)
                                                .backgroundColor(this.getAvatarColor(call.peerId))
                                                .margin(right: 12)
                                                .alignContent(Alignment.Center)
                                            }

                                            Column {
                                                // iOS parity: 通话行名称 medium17;合并组 >1 时名字后加 " (N)"
                                                Text(if (call.groupCount > 1) { call.peerName + " (${call.groupCount})" } else { call.peerName })
                                                    .fontSize(17)
                                                    .fontWeight(FontWeight.Medium)
                                                    .fontColor(this.getNameColor(call))
                                                    .maxLines(1)

                                                Row {
                                                    // iOS parity: 副行为纯文本 label（方向箭头已移至头像左侧行首）；
                                                    // video 通话保留小相机图标区分
                                                    if (call.mediaType == "video") {
                                                        Image(@r(app.media.callui_ic_video))
                                                            .width(12)
                                                            .height(12)
                                                            .fillColor(0x8E8E93)
                                                            .margin(right: 4)
                                                    }

                                                    Text(this.getCallTypeText(call))
                                                        .fontSize(13)
                                                        .fontColor(0x8E8E93)
                                                        .margin(right: 6)

                                                    // iOS parity: 时长格式 "(21 sec)"/"(5 min)"（非 "0:21"）
                                                    if (call.duration.size > 0) {
                                                        Text("(${this.formatDurationIOS(call.duration)})")
                                                            .fontSize(13)
                                                            .fontColor(0x8E8E93)
                                                            .margin(right: 6)
                                                    }
                                                }
                                                .margin(top: 2)
                                            }
                                            .alignItems(HorizontalAlign.Start)
                                            .layoutWeight(1)

                                            // iOS parity: 日期右对齐（独立于副行），后跟蓝色 ⓘ
                                            if (!this.isEditMode) {
                                                Text(call.timestamp)
                                                    .fontSize(15)
                                                    .fontColor(0x8E8E93)
                                                    .margin(right: 10)
                                                // iOS parity: ⓘ 为 accent 蓝（CallListCallItem infoButton）
                                                // CTL-CALLS-004: 按压 alpha 0.4 瞬时 / 0.2s 释放
                                                Image(@r(app.media.callui_ic_info))
                                                    .width(18)
                                                    .height(18)
                                                    .fillColor(0x007AFF)
                                                    .opacity(if (this.pressedInfoIdx == idx) { 0.4 } else { 1.0 })
                                                    .onClick({ evt => this.openCallInfo(call) })
                                                    .onTouch({ evt =>
                                                        match (evt.eventType) {
                                                            case TouchType.Down => this.pressedInfoIdx = idx
                                                            case _ =>
                                                                safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 200, curve: Curve.EaseInOut), { =>
                                                                    this.pressedInfoIdx = -1
                                                                })
                                                        }
                                                    })
                                            }
                                            // CTL-CALLS-005: 减号点击后揭示的红色 Delete 按钮
                                            if (this.isEditMode && this.revealedDeleteIdx == idx) {
                                                Text(trSource("Delete"))
                                                    .fontSize(17)
                                                    .fontColor(0xFFFFFF)
                                                    .height(36)
                                                    .padding(left: 14, right: 14)
                                                    .borderRadius(8)
                                                    .backgroundColor(0xFF3B30)
                                                    .onClick({ evt => this.deleteGroupRecords(call) })
                                            }
                                        }
                                        .width(100.percent)
                                        .padding(left: 16, right: 16)
                                        // CTL-SHARED-002: 行按压高亮 0xE5E5EA（瞬时进入 / 0.4s 淡出）
                                        .backgroundColor(if (this.pressedCallIdx == idx && !this.isEditMode) { this.presentation.itemHighlightedBackgroundColor } else { this.presentation.backgroundColor })
                                        .onClick({ evt =>
                                            // CTL-CALLS-004: iOS 通话行点按 = 直接回拨（无导航）；编辑态点行无动作
                                            if (!this.isEditMode && !this._suppressRowClick) {
                                                this.makeCall(call)
                                            }
                                            this._suppressRowClick = false
                                        })
                                        .onTouch({ evt =>
                                            match (evt.eventType) {
                                                case TouchType.Down =>
                                                    this._touchDownTime = evt.timestamp
                                                    this._touchIdx = idx
                                                    if (!this.isEditMode) { this.pressedCallIdx = idx }
                                                case TouchType.Up =>
                                                    let duration = evt.timestamp - this._touchDownTime
                                                    if (duration > 500_000_000 && this._touchIdx == idx) {
                                                        // 长按开菜单时抑制随后的 onClick 回拨
                                                        this._suppressRowClick = true
                                                        this.onCallItemLongPress(call, idx)
                                                    }
                                                    safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 400, curve: Curve.EaseInOut), { =>
                                                        this.pressedCallIdx = -1
                                                    })
                                                case _ => this.pressedCallIdx = -1
                                            }
                                        })
                                    }
                                }
                                // S8-22: CallListCallItem.swift:788 reveal option Common_Delete → interaction.delete
                                .swipeAction(
                                    end: { =>
                                        Button(this.presentationStrings.getOr("Common_Delete", "Delete"))
                                            .fontSize(17)
                                            .fontColor(0xFFFFFFFF)
                                            .backgroundColor(0xFFFF3B30)
                                            .borderRadius(0)
                                            .width(80)
                                            .height(100.percent)
                                            .onClick({ _ => this.openDeleteSheet(call.peerName, call.groupMsgIds) })
                                    }
                                )
                            }
                        }, keyGeneratorFunc: { call: CallRecord, idx: Int64 => callRowKey(call, idx) })

                        // iOS parity（TC-SCROLL）：底部 content inset 占位（悬浮 tab bar 不挡末条；
                        // 测量式高度使短内容也超视口 → Spring 恒可回弹）
                        ListItem {
                            Row {}.height(this.callsBottomFillerH())
                        }
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .backgroundColor(this.presentation.backgroundColor)
                    // CTL-CALLS-005: 编辑态内容右移 38 → 分隔线缩进 78+38
                    .divider(ListDividerOptions(strokeWidth: 1, color: 0xE5E5EA, startMargin: if (this.isEditMode) { 116 } else { 78 }, endMargin: 0))
                    // iOS parity：alwaysBounceVertical（ListView.swift:508）
                    .edgeEffect(EdgeEffect.Spring)
                    .onAreaChange({ _: Area, newArea: Area =>
                        this.contentVH = newArea.height.value
                    })
                    .onScrollStop({ =>
                        // iOS parity：内容短于视口时，过滚松手后动画弹回顶（rubber-band settle）
                        if (this.callsBottomFillerH() > 88.5) {
                            this.callsListScroller.scrollTo(xOffset: 0.0, yOffset: 0.0, animation: true)
                        }
                    })
                }

                // CTL-CALLS-005: iOS 编辑态无底部批量删除栏——逐行减号删除 + 右上 Delete All
            }
            .width(100.percent)
            .layoutWeight(1)
            .backgroundColor(this.presentation.backgroundColor)
            .opacity(this.contentOpacity)
            this.callsTabSetting()
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.presentation.backgroundColor)
        .padding(bottom: getSafeAreaBottom())
        if (this.showContextMenu) {
            Column {
                ContextMenuView(
                    items: this.callMenuItems,
                    onDismiss: { =>
                        this.showContextMenu = false
                        this.contextMenuIdx = -1
                    }
                )
            }
            .width(100.percent)
            .height(100.percent)
        }

        // ==================== New Call 底部 sheet（CTL-CALLS-003 / CTL-SHARED-004）====================
        if (this.showNewCallSheet) {
            Stack(alignContent: Alignment.TopStart) {
                Column { }
                    .width(100.percent)
                    .height(100.percent)
                    .backgroundColor(0x000000)
                    .opacity(this.callSheetDim)
                    .onClick({ evt => this.closeNewCallSheet() })

                Column {
                    Row {
                        Stack {
                            Text("✕")
                                .fontSize(15)
                                .fontColor(0x000000)
                        }
                        .width(30)
                        .height(30)
                        .borderRadius(15)
                        .backgroundColor(0xF0F0F0)
                        .alignContent(Alignment.Center)
                        .onClick({ evt => this.closeNewCallSheet() })

                        Text(trSource("New Call"))
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0x000000)
                            .layoutWeight(1)
                            .textAlign(TextAlign.Center)

                        Row {}.width(30).height(30)
                    }
                    .width(100.percent)
                    .height(56)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)

                    // S8-19: ContactListAdditionalOption CallList_NewCallLink + link icon (CallListController.swift:566)
                    Row {
                        Image(@r(app.media.vc_ic_link))
                            .width(24)
                            .height(24)
                            .fillColor(0x007AFF)
                            .margin(left: 8, right: 20)
                        Text(this.presentationStrings.getOr("CallList_NewCallLink", "Create Call Link"))
                            .fontSize(17)
                            .fontColor(0x007AFF)
                            .layoutWeight(1)
                    }
                    .width(100.percent)
                    .height(50)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ evt =>
                        this.closeNewCallSheet()
                        this.createCallLink()
                    })
                    Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 68)

                    if (this.callSheetContacts.size == 0) {
                        Column {
                            LoadingProgress().width(32).height(32)
                        }
                        .width(100.percent)
                        .padding(top: 40)
                        .alignItems(HorizontalAlign.Center)
                    } else {
                        List {
                            ForEach(this.callSheetContacts.toArray(), itemGeneratorFunc: { c: ContactDisplayData, _i: Int64 =>
                                ListItem {
                                    Row {
                                        if (getUserPhotoService().getUserPhotoPath(c.userId).size > 0) {
                                            Image(getUserPhotoService().getUserPhotoPath(c.userId))
                                                .width(40)
                                                .height(40)
                                                .borderRadius(20)
                                                .objectFit(ImageFit.Cover)
                                                .margin(right: 12)
                                        } else {
                                            Stack {
                                                Text(c.getAvatarInitials())
                                                    .fontSize(15)
                                                    .fontColor(0xFFFFFF)
                                                    .fontWeight(FontWeight.Medium)
                                            }
                                            .width(40)
                                            .height(40)
                                            .borderRadius(20)
                                            .backgroundColor(this.getAvatarColor(c.userId))
                                            .alignContent(Alignment.Center)
                                            .margin(right: 12)
                                        }
                                        Column {
                                            Text(c.getDisplayName())
                                                .fontSize(17)
                                                .fontColor(0x000000)
                                                .maxLines(1)
                                            Text(c.getLastSeenText())
                                                .fontSize(13)
                                                .fontColor(if (c.isOnline) { 0x317AFF } else { 0x8E8E93 })
                                                .margin(top: 2)
                                                .maxLines(1)
                                        }
                                        .layoutWeight(1)
                                        .alignItems(HorizontalAlign.Start)
                                    }
                                    .width(100.percent)
                                    .height(54)
                                    .padding(left: 16, right: 16)
                                    .alignItems(VerticalAlign.Center)
                                    .onClick({ evt => this.callContact(c) })
                                }
                            })
                        }
                        .width(100.percent)
                        .layoutWeight(1)
                        .divider(ListDividerOptions(strokeWidth: 1, color: 0xE5E5EA, startMargin: 68, endMargin: 0))
                        .edgeEffect(EdgeEffect.Spring)
                    }
                }
                .width(100.percent)
                .height(88.percent)
                .backgroundColor(0xFFFFFF)
                .borderRadius(10)
                .alignItems(HorizontalAlign.Start)
                .margin(top: 100.0 + this.callSheetShift)
            }
            .width(100.percent)
            .height(100.percent)
            .onAppear({ => reportTabModalOverlay(true) })
            .onDisAppear({ => reportTabModalOverlay(false) })
        }

        // S8-19: OverlayStatusController(.loading) while createConferenceCall runs
        if (this.creatingCallLink) {
            Stack {
                LoadingProgress().width(44).height(44).color(0xFFFFFF)
            }
            .width(100)
            .height(100)
            .borderRadius(14)
            .backgroundColor(0xB3000000)
            .alignContent(Alignment.Center)
        }

        // ==================== S8-19: Call Link sheet (InviteLinkInviteController .groupCall) ====================
        if (this.showLinkSheet) {
            Stack(alignContent: Alignment.Bottom) {
                Column { }
                    .width(100.percent)
                    .height(100.percent)
                    .backgroundColor(0x000000)
                    .opacity(this.linkSheetDim)
                    .onClick({ evt => this.closeLinkSheet() })

                Column {
                    Row {
                        Stack {
                            Text("✕")
                                .fontSize(15)
                                .fontColor(this.presentation.textColor)
                        }
                        .width(30)
                        .height(30)
                        .borderRadius(15)
                        .backgroundColor(this.presentation.itemHighlightedBackgroundColor)
                        .alignContent(Alignment.Center)
                        .onClick({ evt => this.closeLinkSheet() })
                        Blank().layoutWeight(1)
                    }
                    .width(100.percent)
                    .height(54)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)

                    Stack {
                        Image(@r(app.media.vc_ic_link))
                            .width(44)
                            .height(44)
                            .fillColor(0xFFFFFF)
                    }
                    .width(92)
                    .height(92)
                    .borderRadius(46)
                    .backgroundColor(0x007AFF)
                    .alignContent(Alignment.Center)

                    Text(this.presentationStrings.getOr("InviteLink_CallLinkTitle", "Call Link"))
                        .fontSize(24)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(this.presentation.textColor)
                        .margin(top: 16)
                    Text(this.presentationStrings.getOr("InviteLink_GroupCallLinkHelp", "Anyone on Telegram can join your call by following the link below."))
                        .fontSize(15)
                        .fontColor(this.presentation.textColor)
                        .textAlign(TextAlign.Center)
                        .margin(top: 8)
                        .padding(left: 32, right: 32)

                    Text(this.displayCallLink())
                        .fontSize(17)
                        .fontColor(this.presentation.textColor)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                        .textAlign(TextAlign.Center)
                        .width(100.percent)
                        .height(52)
                        .padding(left: 16, right: 16)
                        .borderRadius(12)
                        .backgroundColor(this.presentation.itemHighlightedBackgroundColor)
                        .margin(top: 24)
                        .onAreaChange({ _: Area, newArea: Area => this.callLinkBoxWidth = newArea.width.value })
                        .onClick({ evt => this.copyCallLink() })

                    Row {
                        Text(this.presentationStrings.getOr("InviteLink_CopyShort", "Copy"))
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0xFFFFFF)
                            .textAlign(TextAlign.Center)
                            .layoutWeight(1)
                            .height(50)
                            .borderRadius(12)
                            .backgroundColor(0x007AFF)
                            .onClick({ evt => this.copyCallLink() })
                        Text(this.presentationStrings.getOr("InviteLink_ShareShort", "Share"))
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0xFFFFFF)
                            .textAlign(TextAlign.Center)
                            .layoutWeight(1)
                            .height(50)
                            .borderRadius(12)
                            .backgroundColor(0x007AFF)
                            .margin(left: 12)
                            .onClick({ evt => this.shareCallLink() })
                    }
                    .width(100.percent)
                    .margin(top: 12)
                }
                .width(100.percent)
                .padding(left: 16, right: 16, bottom: 24.0 + getSafeAreaBottom())
                .backgroundColor(this.presentation.cardColor)
                .borderRadius(topLeft: 12, topRight: 12)
                .alignItems(HorizontalAlign.Center)
                .translate(y: this.linkSheetShift)
            }
            .width(100.percent)
            .height(100.percent)
            .onAppear({ => reportTabModalOverlay(true) })
            .onDisAppear({ => reportTabModalOverlay(false) })
        }

        // ==================== S8-22: delete confirmation action sheet ====================
        if (this.showDeleteSheet) {
            Stack(alignContent: Alignment.Bottom) {
                Column { }
                    .width(100.percent)
                    .height(100.percent)
                    .backgroundColor(0x000000)
                    .opacity(this.deleteSheetDim)
                    .onClick({ evt => this.closeDeleteSheet() })

                Column {
                    Column {
                        Text(this.presentationStrings.getOr("CallList_DeleteConfirmation", "Do you want to delete the information about this call?"))
                            .fontSize(13)
                            .fontColor(this.presentation.secondaryTextColor)
                            .textAlign(TextAlign.Center)
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 14, bottom: 14)
                        Divider().color(this.presentation.dividerColor).strokeWidth(1)
                        Text(this.presentationStrings.getOr("Conversation_DeleteMessagesFor", "Delete for me and %@").replace("%@", this.deleteSheetName))
                            .fontSize(20)
                            .fontColor(0xFF3B30)
                            .maxLines(1)
                            .textOverflow(TextOverflow.Ellipsis)
                            .textAlign(TextAlign.Center)
                            .width(100.percent)
                            .height(57)
                            .padding(left: 16, right: 16)
                            .onClick({ evt => this.confirmDelete(true) })
                        Divider().color(this.presentation.dividerColor).strokeWidth(1)
                        Text(this.presentationStrings.getOr("Conversation_DeleteMessagesForMe", "Delete for me"))
                            .fontSize(20)
                            .fontColor(0xFF3B30)
                            .textAlign(TextAlign.Center)
                            .width(100.percent)
                            .height(57)
                            .onClick({ evt => this.confirmDelete(false) })
                    }
                    .width(100.percent)
                    .borderRadius(14)
                    .backgroundColor(this.presentation.cardColor)

                    Text(this.presentationStrings.getOr("Common_Cancel", "Cancel"))
                        .fontSize(20)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(0x007AFF)
                        .textAlign(TextAlign.Center)
                        .width(100.percent)
                        .height(57)
                        .borderRadius(14)
                        .backgroundColor(this.presentation.cardColor)
                        .margin(top: 8)
                        .onClick({ evt => this.closeDeleteSheet() })
                }
                .width(100.percent)
                .padding(left: 8, right: 8, bottom: 8.0 + getSafeAreaBottom())
                .translate(y: this.deleteSheetShift)
            }
            .width(100.percent)
            .height(100.percent)
            .onAppear({ => reportTabModalOverlay(true) })
            .onDisAppear({ => reportTabModalOverlay(false) })
        }
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ => this.ensureLoaded() })
        .onDisAppear({ => this.cleanup() })
        // S8-23: iOS feeds the Calls tab from live views (chatList for .hasActiveVoiceChat,
        // callListView for the records; CallListControllerNode.swift:514-532), so a call started
        // or joined elsewhere shows up as soon as the tab is on screen. The tab page is created
        // once and otherwise only polls every 15 s, so re-read both when it becomes visible.
        .onVisibleAreaChange([0.0], { isVisibleNow: Bool, _ratio: Float64 =>
            if (isVisibleNow && this.loaded) {
                this.refreshGroupCalls()
                this.doManualRefresh()
            }
        })
    }
}
