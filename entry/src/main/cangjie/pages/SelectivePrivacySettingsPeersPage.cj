package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    getPrivacyEngineService,
    PrivacyEngineService,
    getRealContactService,
    ContactDisplayData,
    getAvatarColorForPeer,
    getRealChatListService
}
import ohos_app_cangjie_entry.components.{
    ItemListSectionHeader,
    ItemListSeparator,
    ItemListButtonRow,
    ITEM_LIST_ACCENT,
    ContextMenuItem,
    ContextMenuView,
    SearchBar,
    ItemListNavBarBackground,
    itemListNavBarBackgroundAlpha255,
    ITEM_LIST_NAVBAR_H
}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.models.Chat
import std.collection.ArrayList
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

// inputPrivacyKeyPhoneP2P#db9e70d2，与 pages/SelectivePrivacySettingsPage.cj 同一常量
// （@Component 类内不允许 static 变量；两文件各自持有模块级字面量，不共享、不改
// services/PrivacyEngineService.cj，理由同该文件同名常量注释）。
let SELECTIVE_PRIVACY_PEERS_KEY_PHONE_P2P: UInt32 = 0xdb9e70d2

// inputPrivacyKeyNoPaidMessages#bdc597b4，与 pages/IncomingMessagePrivacyPage.cj 同一常量、
// 同一推导依据（该文件顶部注释）。G-6：Messages 隐私屏「Remove Fee」例外名单
// （routerPush("SelectivePrivacySettingsPeersPage", "messages|allow")）走的就是这一支——
// getPrivacyRules/setPrivacyWithUsers 是已有的通用签名，不需要改 PrivacyEngineService.cj。
let SELECTIVE_PRIVACY_PEERS_KEY_NO_PAID_MESSAGES: UInt32 = 0xbdc597b4

// diag-suite_settings_privacy-TC-0132-E13.md 修法方向 #1：本页私有 peer 模型，形状仿
// pages/SelectivePrivacySettingsPage.cj:94 class PickerCandidate，但独立声明（不跨文件复用
// 那个类）——两屏的候选/名单模型各自演进，不建立隐式耦合。isChat 区分用户/群组会话；
// subtitle 只有群组、且已知成员数时才非空（TC-0132 RC-9）。
public class PeerRowData {
    public var peerId: Int64 = 0
    public var isChat: Bool = false
    public var displayName: String = ""
    public var initial: String = "?"
    public var subtitle: String = ""

    public init(peerId!: Int64, isChat!: Bool, displayName!: String, initial!: String, subtitle!: String = "") {
        this.peerId = peerId
        this.isChat = isChat
        this.displayName = displayName
        this.initial = initial
        this.subtitle = subtitle
    }
}

// diag-suite_settings_privacy-TC-0132.md 修法方向 G-B.2（Diff-6）：本页私有头像渐变色表，
// 形状仿本文件已有的 PeerRowData 私有模型先例——本文件私有、不跨文件复用，不改
// services/ContactsPeerService.cj:35 getAvatarColorForPeer()（不在本 feature allowlist 内，
// 本页头像位只是不再用它；buildPickerCandidateRow 那处调用点不在本次失效路径上，未改，
// 理由同 :645 行高点，见下 buildPickerCandidateRow 注释）。
// 色对逐字照搬源侧 AvatarNode.swift:318-326 的 7 组双色对；索引对位 :84
// colorIndex=abs(peerId.id) + :178 gradientColors[colorIndex % 7]（不是现有 getAvatarColorForPeer
// 的 % 8）。方向对位 :1005-1008 CGGradient(colors:[c0,c1], locations:[1.0,0.0]) +
// drawLinearGradient(start:(0,0), end:(0,height))：location 1.0 落在终点(底)、location 0.0
// 落在起点(顶) ⇒ 顶=c1、底=c0；已用源帧像素反证（gradientColors[2] 顶0x82b1ff底0x665fff，
// gradientColors[6] 顶0xe0a2f3底0xd669ed），与本表逐项吻合。
// 硬边界：不得照抄 components/Avatar.cj:273-276 特殊态渐变的色序——该处色序与源侧相反。
// S-005：@Builder/build() 内禁止 let，故拆成三个无 let 局部变量的纯返回值函数，
// 供调用点 .linearGradient(...) 内联传参（对位 pages/ChatThemesPage.cj:366-374
// centerTopColor()/centerBottomColor() 同款拆分先例）。
private func peerAvatarColorIndex(peerId: Int64): Int64 {
    let absId = if (peerId < 0) { -peerId } else { peerId }
    return absId % 7
}

private func peerAvatarTopColor(peerId: Int64): UInt32 {
    let colors: Array<UInt32> = [
        0xFFff885e, 0xFFffcd6a, 0xFF82b1ff, 0xFFa0de7e, 0xFF00fcfd, 0xFF72d5fd, 0xFFe0a2f3
    ]
    return colors[peerAvatarColorIndex(peerId)]
}

private func peerAvatarBottomColor(peerId: Int64): UInt32 {
    let colors: Array<UInt32> = [
        0xFFff516a, 0xFFffa85c, 0xFF665fff, 0xFF54cb68, 0xFF4acccd, 0xFF2a9ef1, 0xFFd669ed
    ]
    return colors[peerAvatarColorIndex(peerId)]
}

/**
 * SelectivePrivacySettingsPeersPage — 例外名单屏。
 *
 * 对位源侧 SelectivePrivacySettingsPeersController.swift（`selectivePrivacyPeersController`）。
 *
 * 返修历史：diag-suite_settings_privacy-TC-0132.md RC-1~RC-8——
 *   RC-1 Add 行加号换真实矢量、去掉自造实心圆底；
 *   RC-2 空名单改模态多选浮层（本屏自身「+」按钮同款浮层，删掉旧 isPicking 整屏即时加人面）；
 *   RC-3 分组头改计数串，导航栏标题与分组头解耦（各自独立取值）；
 *   RC-4 删除凭空多出的脚注；
 *   RC-5 补 Edit 编辑态 + 侧滑露出删除，删常驻 Remove 文本按钮；
 *   RC-6 Delete All 改贴底 ActionSheet（ContextMenuView）+ 两条删空路径补自动关闭；
 *   RC-7（详情屏侧，见 pages/SelectivePrivacySettingsPage.cj）；
 *   RC-8 两张圆角卡补 .clip(true)。
 *   RC-9（diag-suite_settings_privacy-TC-0132-E13.md）——本轮：群组类 peer 既不渲染成员行/
 *   副标题、分组头计数也未计入（B1/B4/D2 同根因：`peers` 此前只是纯用户模型）；同时代码推导
 *   出更严重的静默数据破坏——`commit()` 未传 `allowChatIds!`/`disallowChatIds!`，服务端已有的
 *   群组例外会被本屏任何一次写操作整体清空。改用 `PeerRowData`（isChat 区分）统一承载用户与
 *   群组两种 peer，`fetchAndApply()`/`commit()` 补群组两路读写，`openPicker()` 候选源扩展为
 *   联系人 ∪ 会话列表（过滤规则沿用兄弟页 `SelectivePrivacySettingsPage.cj:845
 *   loadPickerCandidates()` 已落地的那一套）。`computeSectionHeaderText()` 按源侧
 *   `peers.count`（条数，不是成员数之和）计，本轮未改——两侧口径本就一致，数字错只是因为
 *   列表少了一条群组行，随渲染补齐自动纠正。
 *
 * 路由参数（由 SelectivePrivacySettingsPage / IncomingMessagePrivacyPage push 入口传入）：
 *   routerPush("SelectivePrivacySettingsPeersPage", "<kindParam>|<mode>")
 *   mode ∈ {"allow", "disallow"}：allow=Always Share/Allow 名单；disallow=Never Share/Allow 名单。
 *   kindParam == "calls_p2p" 时读写 P2P 例外名单（SelectivePrivacySettingsPage §6.7 P9 区块）。
 *   kindParam == "messages" 时读写 Messages「Remove Fee」例外名单（G-6，
 *   IncomingMessagePrivacyPage.cj 唯一 push 入口，恒 mode="allow"——源侧
 *   IncomingMessagePrivacyScreen.swift 的 openExceptions() 只有 enableFor，没有 disableFor 分支）。
 *
 * 数据来源与提交：本屏自己独立 getPrivacyRules(key) 取 baseValue + 两个名单（用户+群组）的
 * 服务端真值（不依赖 S1 通过路由参数传入初值，避免任何过期/漂移风险），编辑的只是 `mode`
 * 对应的 own 名单，另一侧 other 名单（含 other 的群组例外）在本屏生命周期内保持只读快照；
 * 每次增/删成员立即 setPrivacyWithUsers(key, baseValue, allow, disallow, allowChatIds:,
 * disallowChatIds:) 落服务端（own+other 的用户与群组四路组装成完整四元组，对齐
 * PrivacyEngineService.setPrivacyWithUsers 的"整份规则向量"语义，不能只发增量）。
 *
 * 已知限制（如实登记，见 <feature_id>.md Hand-off）：源侧本屏还支持把 "Premium Users" /
 * "Bots" 作为可与具名成员共存的例外类别（`enableForPremium`/`enableForBots`），但
 * `PrivacyEngineService.setPrivacyWithUsers`（services/PrivacyEngineService.cj，不在本
 * feature target_files 内）不接受这两个标志位、`PrivacyRulesResponse`
 * （core/mtproto/TLResponses.cj，同样不在本 feature target_files 内）也不解析对应规则
 * 构造子，本屏未实现这两个类别——需要另开 allowlist 授权改那两个文件才能补全。
 */
@HybridComponentEntry
@Component
public class SelectivePrivacySettingsPeersPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var kindParam: String = "last_seen"
    @State var mode: String = "allow"
    @State var paramParsed: Bool = false
    @State var hasLoadedOnce: Bool = false
    @State var isLoading: Bool = true

    @State var baseValue: String = "everybody"
    @State var otherIds: ArrayList<Int64> = ArrayList<Int64>()
    // TC-0132 RC-9：other 侧的群组例外快照——commit() 组装完整四元组时必须带上，否则
    // other 侧已有的群组例外会被本屏任何一次写操作静默清空（与用户侧 otherIds 同构）。
    @State var otherChatIds: ArrayList<Int64> = ArrayList<Int64>()
    // TC-0132 RC-9：own 名单统一用 PeerRowData（isChat 区分用户/群组），不再只装用户。
    @State var peers: ArrayList<PeerRowData> = ArrayList<PeerRowData>()

    @State var titleText: String = "Always Share"
    @State var sectionHeaderText: String = "EXCEPTIONS"

    @State var editing: Bool = false
    @State var swipeRowIdx: Int32 = -1
    @State var showDeleteAllConfirm: Bool = false

    // RC-2：本屏自己的「+」行改弹模态多选浮层，替代旧的整屏即时加人面。
    @State var showPicker: Bool = false
    @State var pickerLoading: Bool = false
    // TC-0132 RC-9：候选源扩展为联系人 ∪ 会话列表（含群组），统一用 PeerRowData 承载。
    @State var pickerCandidates: ArrayList<PeerRowData> = ArrayList<PeerRowData>()
    @State var pickerQuery: String = ""
    @State var pickedIds: ArrayList<Int64> = ArrayList<Int64>()
    // TC-0132 RC-9：picker 内被选中的群组候选，与 pickedIds（用户）分开——commitPicker()
    // 提交时按各自 id 空间在 pickerCandidates 里查回对应 PeerRowData。
    @State var pickedChatIds: ArrayList<Int64> = ArrayList<Int64>()

    // diag-suite_settings_privacy-TC-0132-round2.md RC-1：导航栏底衬叠层版式所需的滚动器与
    // 渐显 alpha，形状同父屏 pages/SelectivePrivacySettingsPage.cj:252-253（不抄它的第三个字段
    // prevScrollOffsetVp——本页不做回弹动画，见 RC-1 边界条件 4）。
    private var contentScroller: Scroller = Scroller()
    @State var navBarAlpha255: UInt32 = 0

    private func parseRouteParamOnce(): Unit {
        if (this.paramParsed) {
            return
        }
        this.paramParsed = true
        let raw = takePending("SelectivePrivacySettingsPeersPage")
        if (raw.size > 0 && raw != "{}") {
            let parts = raw.trimAscii().split("|")
            if (parts.size >= 1 && parts[0].size > 0) {
                this.kindParam = parts[0]
            }
            if (parts.size >= 2 && (parts[1] == "allow" || parts[1] == "disallow")) {
                this.mode = parts[1]
            }
        }
        this.titleText = this.computeNavTitle()
        this.sectionHeaderText = this.computeSectionHeaderText()
    }

    private func keyConstructor(): UInt32 {
        if (this.kindParam == "calls_p2p") {
            return SELECTIVE_PRIVACY_PEERS_KEY_PHONE_P2P
        }
        if (this.kindParam == "messages") {
            return SELECTIVE_PRIVACY_PEERS_KEY_NO_PAID_MESSAGES
        }
        if (this.kindParam == "phone_number") {
            return PrivacyEngineService.KEY_PHONE_NUMBER
        }
        if (this.kindParam == "profile_photo") {
            return PrivacyEngineService.KEY_PROFILE_PHOTO
        }
        if (this.kindParam == "forwards") {
            return PrivacyEngineService.KEY_FORWARDS
        }
        if (this.kindParam == "groups") {
            return PrivacyEngineService.KEY_GROUPS
        }
        if (this.kindParam == "calls") {
            return PrivacyEngineService.KEY_CALLS
        }
        if (this.kindParam == "voice_messages") {
            return PrivacyEngineService.KEY_VOICE_MESSAGES
        }
        // F-1（diag-suite_settings_privacy-E8-batch.md，TC-0128 RC-1 详情屏半）：与
        // pages/SelectivePrivacySettingsPage.cj 的 keyConstructor() 同步补齐，否则
        // 这 4 个新 kind 进本屏会兜底成 KEY_LAST_SEEN，把例外名单写进错的隐私分类。
        if (this.kindParam == "bio") {
            return PrivacyEngineService.KEY_ABOUT
        }
        if (this.kindParam == "birthday") {
            return PrivacyEngineService.KEY_BIRTHDAY
        }
        if (this.kindParam == "saved_music") {
            return PrivacyEngineService.KEY_SAVED_MUSIC
        }
        if (this.kindParam == "gifts") {
            return PrivacyEngineService.KEY_STAR_GIFTS_AUTO_SAVE
        }
        return PrivacyEngineService.KEY_LAST_SEEN
    }

    private func isAllowLike(): Bool {
        return this.kindParam == "forwards" || this.kindParam == "groups" ||
            this.kindParam == "calls" || this.kindParam == "voice_messages" ||
            this.kindParam == "calls_p2p" || this.kindParam == "gifts"
    }

    // RC-3：导航栏标题与分组头是源侧两个独立的字符串 key，各自取值，互不消费。
    // G-6：messages 支源侧标题固定是 Privacy_Messages_Exceptions_Title="Remove Fee"，
    // 不走下面 allow/disallow 通用推导（那套是 last_seen 等经典三档屏的命名）。
    private func computeNavTitle(): String {
        if (this.kindParam == "messages") {
            return "Remove Fee"
        }
        if (this.mode == "allow") {
            if (this.isAllowLike()) {
                return "Always Allow"
            }
            return "Always Share"
        }
        if (this.isAllowLike()) {
            return "Never Allow"
        }
        return "Never Share"
    }

    // diag-suite_settings_privacy-TC-0132-E13.md 修法方向 #7：本函数按源侧
    // `peers.isEmpty ? Privacy_Exceptions : Privacy_ExceptionsCount(peers.count)`——按条数，
    // 不是成员数之和——两侧口径本就一致，不要改成加权求和（那是根屏/详情屏的口径，不是本屏
    // 的）。this.peers 补齐群组行后，条数自然纠正。
    private func computeSectionHeaderText(): String {
        if (this.peers.size == 0) {
            return "EXCEPTIONS"
        }
        if (this.peers.size == 1) {
            return "1 EXCEPTION"
        }
        return "${this.peers.size} EXCEPTIONS"
    }

    /**
     * diag-suite_settings_privacy-TC-0132-round2.md 前置·3：返回 chevron 的 Path 命令串，
     * 方法体逐字照抄 pages/PrivacySettingsPage.cj:254-265（同 allowlist、已落地、已过审），
     * 对位源侧 NavigationButtonNode.swift:8-23 glassBackArrowImage（44×44 画布，
     * topRightPoint (24.6,14)，centerPoint (17,22)，第三点 (24.6,30)）。
     *
     * ArkUI Path 的 commands 坐标按 px 消费，不随 .width/.height 的 vp 单位自动换算，漏乘
     * scale 会把箭头缩到 1/density 并锚在组件框左上角。
     */
    private func backArrowCommands(): String {
        let scale: Float64 = match (this.getUIContext().vp2px(1.0.vp)) {
            case Some(len) => len.value
            case None => Float64(getDefaultDisplaySync().densityPixels)
        }
        let xRight: Float64 = 24.6 * scale
        let xApex: Float64 = 17.0 * scale
        let yTop: Float64 = 14.0 * scale
        let yMid: Float64 = 22.0 * scale
        let yBottom: Float64 = 30.0 * scale
        return "M${xRight} ${yTop} L${xApex} ${yMid} L${xRight} ${yBottom}"
    }

    private func snapshotIds(list: ArrayList<Int64>): ArrayList<Int64> {
        let out = ArrayList<Int64>()
        for (v in list) {
            out.add(v)
        }
        return out
    }

    private func peerUserIds(list: ArrayList<PeerRowData>): ArrayList<Int64> {
        let out = ArrayList<Int64>()
        for (c in list) {
            if (!c.isChat) {
                out.add(c.peerId)
            }
        }
        return out
    }

    private func peerChatIds(list: ArrayList<PeerRowData>): ArrayList<Int64> {
        let out = ArrayList<Int64>()
        for (c in list) {
            if (c.isChat) {
                out.add(c.peerId)
            }
        }
        return out
    }

    private func containsId(list: ArrayList<Int64>, id: Int64): Bool {
        var i: Int64 = 0
        while (i < list.size) {
            if (list[i] == id) {
                return true
            }
            i = i + 1
        }
        return false
    }

    private func refresh(): Unit {
        if (!this.hasLoadedOnce) {
            this.isLoading = true
        }
        this.fetchAndApply()
    }

    // round2 required_fix #1/#2/#4：拉最新三元组（baseValue + 双名单），据 mode 拆出
    // own/other，解析 own 的展示名，回填到 @State。既是首屏加载(refresh)也是每次写操作后
    // 的服务端真值纠正(commit)的唯一数据源。
    // TC-0132 RC-9：三元组实际是用户+群组四路（allowUsers/disallowUsers/allowChats/
    // disallowChats）——之前只读了用户两路，群组例外读了也没用（既不显示也不回传 commit()），
    // 本轮把 allowChats/disallowChats 接进同一份 own/other 拆分逻辑。
    private func fetchAndApply(): Unit {
        let key = this.keyConstructor()
        let modeSnapshot = this.mode
        let _ = spawn {
            let svc = getPrivacyEngineService()
            let rules = svc.getPrivacyRules(key)
            let ownUserRaw = ArrayList<Int64>()
            let otherUserRaw = ArrayList<Int64>()
            let ownChatRaw = ArrayList<Int64>()
            let otherChatRaw = ArrayList<Int64>()
            if (modeSnapshot == "allow") {
                for (id in rules.allowUsers) { ownUserRaw.add(id) }
                for (id in rules.disallowUsers) { otherUserRaw.add(id) }
                for (id in rules.allowChats) { ownChatRaw.add(id) }
                for (id in rules.disallowChats) { otherChatRaw.add(id) }
            } else {
                for (id in rules.disallowUsers) { ownUserRaw.add(id) }
                for (id in rules.allowUsers) { otherUserRaw.add(id) }
                for (id in rules.disallowChats) { ownChatRaw.add(id) }
                for (id in rules.allowChats) { otherChatRaw.add(id) }
            }

            let contactsSvc = getRealContactService()
            let contacts = contactsSvc.getContacts()
            let resolved = ArrayList<PeerRowData>()
            var oi: Int64 = 0
            while (oi < ownUserRaw.size) {
                let uid = ownUserRaw[oi]
                var found: ?ContactDisplayData = None
                var ci: Int64 = 0
                while (ci < contacts.size) {
                    if (contacts[ci].userId == uid) {
                        found = contacts[ci]
                        break
                    }
                    ci = ci + 1
                }
                match (found) {
                    case Some(c) =>
                        resolved.add(PeerRowData(peerId: uid, isChat: false, displayName: c.getDisplayName(), initial: c.getInitial()))
                    case None =>
                        // 不在联系人缓存里的例外成员（服务端有此 id，但从未同步为联系人）——
                        // 用一个只填 userId 的裸对象兜底：ContactDisplayData.getDisplayName()
                        // 在 firstName/lastName/username 全空时自动回退 "User ${userId}"，
                        // 真实、非占位（RealContactService.cj:200-211 已有的既定行为）。
                        let unresolvedPeer = ContactDisplayData()
                        unresolvedPeer.userId = uid
                        resolved.add(PeerRowData(peerId: uid, isChat: false, displayName: unresolvedPeer.getDisplayName(), initial: unresolvedPeer.getInitial()))
                }
                oi = oi + 1
            }

            // diag 修法方向 #2：群组展示名不在 PrivacyRulesResponse 里（trailing chats vector
            // 只把 participantsCount 折进 peerChatUserCounts，title 被丢弃——见
            // TLResponses.cj PrivacyRulesResponse.deserialize() 只取 chat.id/userCount，不留
            // chat.title），需要另查本地会话缓存（getCachedChat，与 AdminManagePage.cj/
            // GroupDetailsPage.cj/PeerInfoPage.cj 等既有调用点同一 API）。成员数查不到 ⇒
            // 副标题整行不渲染（不编造数字）；显示名查不到 ⇒ 沿用同款"只填 id 的裸兜底"。
            let chatListSvc = getRealChatListService()
            var chi: Int64 = 0
            while (chi < ownChatRaw.size) {
                let cid = ownChatRaw[chi]
                var weight: Int64 = 0
                match (rules.peerChatUserCounts.get(cid)) {
                    case Some(w) => weight = w
                    case None => ()
                }
                let subtitle = if (weight == 1) {
                    "1 member"
                } else if (weight > 1) {
                    "${weight} members"
                } else {
                    ""
                }
                match (chatListSvc.getCachedChat(cid)) {
                    case Some(chat) =>
                        let name = if (chat.title.size > 0) { chat.title } else { "Group ${cid}" }
                        let initial = if (name.size > 0) { name.toRuneArray()[0].toString() } else { "G" }
                        resolved.add(PeerRowData(peerId: cid, isChat: true, displayName: name, initial: initial, subtitle: subtitle))
                    case None =>
                        resolved.add(PeerRowData(peerId: cid, isChat: true, displayName: "Group ${cid}", initial: "G", subtitle: subtitle))
                }
                chi = chi + 1
            }

            let bv = rules.primaryValue
            let ownForContinue = resolved
            let otherUserForContinue = otherUserRaw
            let otherChatForContinue = otherChatRaw
            spawn(UIThread) {
                =>
                this.baseValue = bv
                this.peers = ownForContinue
                this.otherIds = otherUserForContinue
                this.otherChatIds = otherChatForContinue
                this.sectionHeaderText = this.computeSectionHeaderText()
                this.isLoading = false
                this.hasLoadedOnce = true
            }
        }
    }

    // 每次增删后立即落服务端（own=this.peers 拆出的用户/群组 id 集合，
    // other=this.otherIds/this.otherChatIds 快照）。
    // round2 required_fix #1/#2/#4：写完必须重新拉一次服务端真值并回填 @State（fetchAndApply()）。
    // TC-0132 RC-9（诊断代码推导，本轮已独立复核确认成立——见交付报告）：此前没传
    // allowChatIds!/disallowChatIds! 具名参数——两者在 PrivacyEngineService.setPrivacyWithUsers
    // 里默认空表，而该函数每次都据传入的四个列表重新拼装完整规则向量（不是增量 patch），
    // 漏传即等价于"两个群组名单清空"，服务端已有的群组例外会被本屏任何一次写操作（包括仅删
    // 一个用户）静默抹掉。本轮同 own/other 一起把群组两路带上，四路组装成完整四元组再发。
    private func commit(): Unit {
        let key = this.keyConstructor()
        let bv = this.baseValue
        let ownUserIds = this.peerUserIds(this.peers)
        let ownChatIds = this.peerChatIds(this.peers)
        let otherUserIdsSnap = this.snapshotIds(this.otherIds)
        let otherChatIdsSnap = this.snapshotIds(this.otherChatIds)
        let av = if (this.mode == "allow") { ownUserIds } else { otherUserIdsSnap }
        let dv = if (this.mode == "disallow") { ownUserIds } else { otherUserIdsSnap }
        let acv = if (this.mode == "allow") { ownChatIds } else { otherChatIdsSnap }
        let dcv = if (this.mode == "disallow") { ownChatIds } else { otherChatIdsSnap }
        let ownCount = ownUserIds.size + ownChatIds.size
        let modeSnap = this.mode
        let _ = spawn {
            let svc = getPrivacyEngineService()
            let _ = svc.setPrivacyWithUsers(key, bv, av, dv, allowChatIds: acv, disallowChatIds: dcv)
            Hilog.info(0, "CjTelegram", "[SelectivePrivacyPeers] commit sent mode=${modeSnap} own=${ownCount}; re-syncing from server")
            spawn(UIThread) { => this.fetchAndApply() }
        }
    }

    // RC-6a：删空后自动返回上一屏（对位源侧 removePeer/deleteAll 两条路径各自 dismissImpl?()）。
    private func removePeerAt(idx: Int64): Unit {
        if (idx < 0 || idx >= this.peers.size) {
            return
        }
        let newList = ArrayList<PeerRowData>()
        var i: Int64 = 0
        while (i < this.peers.size) {
            if (i != idx) {
                newList.add(this.peers[i])
            }
            i = i + 1
        }
        this.peers = newList
        this.sectionHeaderText = this.computeSectionHeaderText()
        this.commit()
        if (this.peers.size == 0) {
            routerPop()
        }
    }

    private func deleteAll(): Unit {
        this.peers = ArrayList<PeerRowData>()
        this.sectionHeaderText = this.computeSectionHeaderText()
        this.commit()
        routerPop()
    }

    // ==================== RC-2 / TC-0132 RC-9：模态多选浮层（本屏「+」行入口）====================

    // diag 修法方向 #6：候选源扩展为联系人 ∪ 会话列表（含群组），过滤规则逐字沿用兄弟页
    // pages/SelectivePrivacySettingsPage.cj:845 loadPickerCandidates() 已落地的那一套：
    // 联系人侧排除 self/bot，会话侧保留 isGroup（含 megagroup）、剔除 isChannel/isSecretChat/
    // isSavedMessages/bot，且都排除已在本屏 own 名单中的 peer（含群组）。是否也排除 other 侧
    // 名单里的 peer 本轮未改动（诊断报告将其列为需 Supervisor 另行裁定的可选项）。
    private func openPicker(): Unit {
        this.showPicker = true
        this.pickerLoading = true
        this.pickerCandidates = ArrayList<PeerRowData>()
        this.pickedIds = ArrayList<Int64>()
        this.pickedChatIds = ArrayList<Int64>()
        this.pickerQuery = ""
        let ownUserIds = this.peerUserIds(this.peers)
        let ownChatIds = this.peerChatIds(this.peers)
        let _ = spawn {
            let contactsSvc = getRealContactService()
            let contacts = contactsSvc.getContacts()
            let candidates = ArrayList<PeerRowData>()
            let seenUserIds = ArrayList<Int64>()
            var i: Int64 = 0
            while (i < contacts.size) {
                let c = contacts[i]
                if (!c.isSelf && !c.isBot && !this.containsId(ownUserIds, c.userId)) {
                    candidates.add(PeerRowData(peerId: c.userId, isChat: false, displayName: c.getDisplayName(), initial: c.getInitial()))
                    seenUserIds.add(c.userId)
                }
                i = i + 1
            }
            let chats = getRealChatListService().getDialogsLocalFirst(limit: 200)
            for (chat in chats) {
                if (chat.isSecretChat || chat.isSavedMessages) {
                    continue
                }
                if (chat.isGroup) {
                    // isGroup 同时覆盖普通群与 megagroup；纯频道 isChannel=true 且
                    // isGroup=false，不落进本分支（对位兄弟页同一过滤规则的注释）。
                    if (this.containsId(ownChatIds, chat.id)) {
                        continue
                    }
                    let subtitle = if (chat.participantsCount == 1) {
                        "1 member"
                    } else {
                        "${chat.participantsCount} members"
                    }
                    let initial = if (chat.name.size > 0) { chat.name.toRuneArray()[0].toString() } else { "G" }
                    candidates.add(PeerRowData(peerId: chat.id, isChat: true, displayName: chat.name, initial: initial, subtitle: subtitle))
                } else if (chat.peerType == "user" && !chat.isBot && !this.containsId(seenUserIds, chat.id)) {
                    if (this.containsId(ownUserIds, chat.id)) {
                        continue
                    }
                    let initial = if (chat.name.size > 0) { chat.name.toRuneArray()[0].toString() } else { "U" }
                    candidates.add(PeerRowData(peerId: chat.id, isChat: false, displayName: chat.name, initial: initial))
                    seenUserIds.add(chat.id)
                }
            }
            let result = candidates
            spawn(UIThread) {
                =>
                this.pickerCandidates = result
                this.pickerLoading = false
            }
        }
    }

    private func filteredPickerCandidates(): ArrayList<PeerRowData> {
        if (this.pickerQuery.size == 0) {
            return this.pickerCandidates
        }
        let q = this.pickerQuery.toAsciiLower()
        let out = ArrayList<PeerRowData>()
        for (c in this.pickerCandidates) {
            if (c.displayName.toAsciiLower().contains(q)) {
                out.add(c)
            }
        }
        return out
    }

    private func isPicked(id: Int64, isChat: Bool): Bool {
        if (isChat) {
            return this.containsId(this.pickedChatIds, id)
        }
        return this.containsId(this.pickedIds, id)
    }

    private func togglePicked(id: Int64, isChat: Bool): Unit {
        let source = if (isChat) { this.pickedChatIds } else { this.pickedIds }
        let out = ArrayList<Int64>()
        var found = false
        for (v in source) {
            if (v == id) {
                found = true
            } else {
                out.add(v)
            }
        }
        if (!found) {
            out.add(id)
        }
        if (isChat) {
            this.pickedChatIds = out
        } else {
            this.pickedIds = out
        }
    }

    private func cancelPicker(): Unit {
        this.showPicker = false
        this.pickedIds = ArrayList<Int64>()
        this.pickedChatIds = ArrayList<Int64>()
        this.pickerQuery = ""
    }

    private func commitPicker(): Unit {
        if (this.pickedIds.size == 0 && this.pickedChatIds.size == 0) {
            this.cancelPicker()
            return
        }
        let newPeers = ArrayList<PeerRowData>()
        for (p in this.peers) {
            newPeers.add(p)
        }
        for (id in this.pickedIds) {
            var found: ?PeerRowData = None
            var i: Int64 = 0
            while (i < this.pickerCandidates.size) {
                if (!this.pickerCandidates[i].isChat && this.pickerCandidates[i].peerId == id) {
                    found = this.pickerCandidates[i]
                    break
                }
                i = i + 1
            }
            match (found) {
                case Some(c) => newPeers.add(c)
                case None => ()
            }
        }
        for (id in this.pickedChatIds) {
            var found: ?PeerRowData = None
            var i: Int64 = 0
            while (i < this.pickerCandidates.size) {
                if (this.pickerCandidates[i].isChat && this.pickerCandidates[i].peerId == id) {
                    found = this.pickerCandidates[i]
                    break
                }
                i = i + 1
            }
            match (found) {
                case Some(c) => newPeers.add(c)
                case None => ()
            }
        }
        this.peers = newPeers
        this.sectionHeaderText = this.computeSectionHeaderText()
        this.cancelPicker()
        this.commit()
    }

    // diag-suite_settings_privacy-TC-0132.md 裁定：本 Builder 的行高（64/56，下方
    // .height(...)）与头像取色（getAvatarColorForPeer(entry.peerId)，下方 .backgroundColor(...)）
    // 未随 G-B 一并改。理由：S12 UI 对照失败步测的证据（screenshot.png、
    // frames/step_06_peers_screen.png、frames/step_09_edit_mode_on.png、view.json 53 节点）
    // 全部取自主列表屏（本屏 build() 常驻区），不含本 Builder 所属的模态多选浮层
    // （buildPickerOverlay，仅 showPicker=true 时挂载）；诊断报告 §三/§四/§七 逐条归因也只
    // 覆盖 buildPeerRow()/buildPeerRowEditing() 这对 Builder，未提及本 Builder。本 Builder 不
    // 在本轮 S12 的失效路径上，故不动；若 picker 内头像/行高本身另有偏差，需另开一轮针对该
    // 弹层的 UI 对照取证，不能沿用本轮证据代判。
    @Builder
    func buildPickerCandidateRow(entry: PeerRowData) {
        Row {
            Column {
                Text(entry.initial)
                    .fontSize(18).fontColor(0xFFFFFF).fontWeight(FontWeight.Medium)
            }
            .width(40).height(40).borderRadius(20)
            .backgroundColor(getAvatarColorForPeer(entry.peerId))
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)

            Column {
                Text(entry.displayName)
                    .fontSize(17).fontColor(0x000000)
                if (entry.subtitle.size > 0) {
                    Text(entry.subtitle)
                        .fontSize(13).fontColor(0x8E8E93)
                }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1).margin(left: 12)

            Stack(alignContent: Alignment.Center) {
                if (this.isPicked(entry.peerId, entry.isChat)) {
                    Image(@r(app.media.media_ic_check)).width(20).height(20).fillColor(ITEM_LIST_ACCENT)
                }
            }
            .width(28).height(28).borderRadius(14)
            .backgroundColor(if (this.isPicked(entry.peerId, entry.isChat)) { Color.Transparent } else { 0xE5E5EA })
        }
        .width(100.percent)
        .height(if (entry.subtitle.size > 0) { 64 } else { 56 })
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _evt => this.togglePicked(entry.peerId, entry.isChat) })
    }

    @Builder
    func buildPickerOverlay() {
        Column {
            Column {}
                .width(100.percent)
                .layoutWeight(1)
                .backgroundColor(0x66000000)
                .onClick({ _evt => this.cancelPicker() })

            Column {
                Row {
                    Text(trSource("Cancel"))
                        .fontSize(16).fontColor(ITEM_LIST_ACCENT)
                        .onClick({ _evt => this.cancelPicker() })
                    Blank().layoutWeight(1)
                    Text(trSource("Add Users"))
                        .fontSize(17).fontWeight(FontWeight.Bold)
                    Blank().layoutWeight(1)
                    Text(trSource("Done"))
                        .fontSize(16).fontColor(ITEM_LIST_ACCENT)
                        .onClick({ _evt => this.commitPicker() })
                }
                .width(100.percent).height(56)
                .padding(left: 16, right: 16)
                .alignItems(VerticalAlign.Center)

                SearchBar(
                    loading: false,
                    backArrow: false,
                    text: this.pickerQuery,
                    hint: trSource("Search users and groups"),
                    onChange: { s: String => this.pickerQuery = s }
                )

                if (this.pickerLoading) {
                    Column {
                        LoadingProgress().width(32).height(32)
                    }
                    .width(100.percent).layoutWeight(1)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                } else {
                    List {
                        ForEach(this.filteredPickerCandidates(), itemGenerator: { entry: PeerRowData, _idx: Int64 =>
                            ListItem {
                                this.buildPickerCandidateRow(entry)
                            }
                        }, keyGeneratorFunc: { entry: PeerRowData, _idx: Int64 =>
                            let prefix = if (entry.isChat) { "c" } else { "u" }
                            "picker_${prefix}_${entry.peerId}"
                        })
                    }
                    .layoutWeight(1)
                }
            }
            .width(100.percent)
            .layoutWeight(9)
            .backgroundColor(0xFFFFFF)
            .borderRadius(topLeft: 14, topRight: 14)
        }
        .width(100.percent)
        .height(100.percent)
        .position(x: 0, y: 0)
    }

    // ==================== RC-1：Add 行 ====================

    @Builder
    func buildAddRow() {
        Row {
            Image(@r(app.media.itemlist_ic_plus))
                .width(30).height(30)
                .fillColor(ITEM_LIST_ACCENT)
                .margin(left: 4)
            // F-11（diag-suite_settings_privacy-E8-batch.md RC-9）：仓内源码值
            // en.lproj/Localizable.strings:4504 "Privacy.AddNewPeer" = "Add Users or Groups"，
            // 不是服务端语言包漂移。同文件 :471 是模态多选浮层标题（TC-0132 A1 已判 PASS），
            // 不动。TC-0132 RC-9 起本行文案与实际候选源（含群组）终于一致。
            Text(trSource("Add Users or Groups"))
                .fontSize(17).fontColor(ITEM_LIST_ACCENT).layoutWeight(1).margin(left: 15)
        }
        .width(100.percent).height(48)
        .padding(right: 16)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(0xFFFFFF)
        .onClick({ _ => this.openPicker() })
    }

    // ==================== RC-5：成员行（非编辑态，左滑删除）====================

    // D-135 边界：分隔线与行内容必须收进同一个 Column，swipeAction 分支下 ListItem 只保留
    // 第一个子节点，顶层 divider+Row 两个兄弟节点会被丢弃第二个。
    // TC-0132 RC-9：entry 改成 PeerRowData（用户+群组统一承载）；群组行带成员数副标题，
    // 用户行不渲空行占位（对位 SelectivePrivacySettingsPage.cj buildPickerCandidateRow 同款
    // subtitle 判断）。
    @Builder
    func buildPeerRow(entry: PeerRowData, idx: Int64) {
        Column {
            ItemListSeparator(leftInset: 68)
            Row {
                Column {
                    Text(entry.initial)
                        .fontSize(18).fontColor(0xFFFFFF).fontWeight(FontWeight.Medium)
                }
                .width(40).height(40).borderRadius(20)
                .linearGradient(angle: 180.0, colors: [
                    (Color(peerAvatarTopColor(entry.peerId)), 0.0),
                    (Color(peerAvatarBottomColor(entry.peerId)), 1.0)
                ])
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)

                Column {
                    Text(entry.displayName)
                        .fontSize(17).fontColor(0x000000)
                    if (entry.subtitle.size > 0) {
                        Text(entry.subtitle)
                            .fontSize(13).fontColor(0x8E8E93)
                    }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1).margin(left: 12)
            }
            .width(100.percent).height(if (entry.subtitle.size > 0) { 60 } else { 52 })
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .backgroundColor(0xFFFFFF)
        }
    }

    // swipeAction end 槽：行身份镜像的唯一写入点是 onOffsetChange（build() 内 ForEach
    // itemGenerator 处），本 @Builder 体内禁止任何 this.xxx = ... 赋值（D-135）。
    @Builder
    func buildPeerSwipeEndPanel() {
        Column {
            Text(trSource("Delete"))
                .fontSize(15)
                .fontColor(0xFFFFFFFF)
        }
        .width(74)
        .height(100.percent)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(0xFF3B30)
        .onClick({ _ =>
            this.removePeerAt(Int64(this.swipeRowIdx))
        })
    }

    // ==================== RC-5：成员行（编辑态，红色减号删除）====================

    @Builder
    func buildPeerRowEditing(entry: PeerRowData, idx: Int64) {
        Column {
            ItemListSeparator(leftInset: 98)
            Row {
                Stack(alignContent: Alignment.Center) {
                    Divider().vertical(false).strokeWidth(2).color(0xFFFFFF).width(11)
                }
                .width(22).height(22).borderRadius(11)
                .backgroundColor(0xFF3B30)
                .margin(right: 8)
                .onClick({ _ => this.removePeerAt(idx) })

                Column {
                    Text(entry.initial)
                        .fontSize(18).fontColor(0xFFFFFF).fontWeight(FontWeight.Medium)
                }
                .width(40).height(40).borderRadius(20)
                .linearGradient(angle: 180.0, colors: [
                    (Color(peerAvatarTopColor(entry.peerId)), 0.0),
                    (Color(peerAvatarBottomColor(entry.peerId)), 1.0)
                ])
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)

                Column {
                    Text(entry.displayName)
                        .fontSize(17).fontColor(0x000000)
                    if (entry.subtitle.size > 0) {
                        Text(entry.subtitle)
                            .fontSize(13).fontColor(0x8E8E93)
                    }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1).margin(left: 12)
            }
            .width(100.percent).height(if (entry.subtitle.size > 0) { 60 } else { 52 })
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .backgroundColor(0xFFFFFF)
        }
    }

    public func build() {
        Stack {
            // diag-suite_settings_privacy-TC-0132-round2.md RC-1：把导航栏与内容从兄弟排布
            // 改成叠层，接上共享渐显引擎 itemListNavBarBackgroundAlpha255()，形状同父屏
            // pages/SelectivePrivacySettingsPage.cj:1289 + :1611-1628 + :1630-1656。
            Stack(alignContent: Alignment.TopStart) {
                if (this.isLoading) {
                    Column {
                        LoadingProgress().width(32).height(32)
                        Text(trSource("Loading..."))
                            .fontSize(14).fontColor(0x8E8E93).margin(top: 8)
                    }
                    .width(100.percent).height(100.percent)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                } else {
                    // RC-1：List(scroller:) + Scroller.currentOffset() + onDidScroll 两参签名，
                    // 与 pages/SettingsPage.cj:943 + :1455-1461 同形（List 兼容 Scroller 的既定先例）。
                    // 顶部用首个空 ListItem 内缩（对位源侧 ItemListControllerNode.swift:652-653
                    // insets.top += navigationBarHeight），不能改用 Scroll + .padding(top:)——
                    // 会打掉本页已 PASS 的 .swipeAction（D4.5 无净退化）。
                    List(scroller: this.contentScroller) {
                        ListItem {
                            Row { }.height(ITEM_LIST_NAVBAR_H)
                        }

                        ListItem {
                            ItemListSectionHeader(title: this.sectionHeaderText)
                        }

                        ListItemGroup {
                            ListItem {
                                this.buildAddRow()
                            }
                            if (this.editing) {
                                ForEach(this.peers, itemGenerator: { entry: PeerRowData, idx: Int64 =>
                                    ListItem {
                                        this.buildPeerRowEditing(entry, idx)
                                    }
                                }, keyGeneratorFunc: { entry: PeerRowData, _idx: Int64 =>
                                    let prefix = if (entry.isChat) { "c" } else { "u" }
                                    "peer_${prefix}_${entry.peerId}"
                                })
                            } else {
                                ForEach(this.peers, itemGenerator: { entry: PeerRowData, idx: Int64 =>
                                    ListItem {
                                        this.buildPeerRow(entry, idx)
                                    }
                                    .swipeAction(
                                        end: { => bind(this.buildPeerSwipeEndPanel, this)() },
                                        onOffsetChange: { offset: Float64 =>
                                            if (offset != 0.0) {
                                                this.swipeRowIdx = Int32(idx)
                                            }
                                        }
                                    )
                                }, keyGeneratorFunc: { entry: PeerRowData, _idx: Int64 =>
                                    let prefix = if (entry.isChat) { "c" } else { "u" }
                                    "peer_${prefix}_${entry.peerId}"
                                })
                            }
                        }
                        .borderRadius(12)
                        .backgroundColor(0xFFFFFF)
                        .clip(true)
                        .margin(left: 16, right: 16)

                        if (this.peers.size > 0) {
                            ListItemGroup {
                                ListItem {
                                    Column {
                                        ItemListButtonRow(
                                            title: "Delete All Exceptions",
                                            destructive: true,
                                            centered: true,
                                            onClick: { => this.showDeleteAllConfirm = true }
                                        )
                                    }
                                }
                            }
                            .borderRadius(12)
                            .backgroundColor(0xFFFFFF)
                            .clip(true)
                            .margin(left: 16, right: 16, top: 24)
                        }

                        ListItem {
                            Text(trSource("")).height(32)
                        }
                    }
                    .width(100.percent).height(100.percent)
                    .backgroundColor(0xF2F2F7)
                    .onDidScroll({ _delta: Float64, _st: ScrollState =>
                        let cur = this.contentScroller.currentOffset()
                        if (cur.isSome()) {
                            this.navBarAlpha255 = itemListNavBarBackgroundAlpha255(cur.getOrThrow().yOffset)
                        }
                    })
                }

                Stack(alignContent: Alignment.TopStart) {
                    ItemListNavBarBackground(alpha255: this.navBarAlpha255)

                    // diag-suite_settings_privacy-TC-0132-round2.md RC-2/RC-3：返回矢量托盘 + 右侧
                    // Edit/Done 托盘 + 屏居中标题骨架，逐字对位仓内先例 pages/DevicesPage.cj:868-922
                    // （屏居中）+ pages/PrivacySettingsPage.cj:1347-1362（返回箭头）+
                    // pages/DevicesPage.cj:728-754（Edit pill）。验收口径是这些代码常量本身，不是
                    // 占屏宽百分比——两侧逻辑屏宽不等价（402pt/377.14vp=1.0659，代码不可修的逻辑
                    // 单位系数），标题改对后占屏宽仍会停在约 28.4%（源 26.62%），不据此判红。
                    Stack(alignContent: Alignment.Center) {
                        Text(this.titleText)
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)

                        Row {
                            Stack {
                                Path()
                                    .width(44)
                                    .height(44)
                                    .commands(this.backArrowCommands())
                                    .fill(Color.Transparent)
                                    .stroke(0x000000)
                                    .strokeWidth(2)
                                    .strokeLineCap(LineCapStyle.Round)
                                    .strokeLineJoin(LineJoinStyle.Round)
                            }
                            .width(44).height(44)
                            .borderRadius(22)
                            .backgroundColor(0xFFFFFF)
                            .alignContent(Alignment.Center)
                            .onClick({ _evt => routerPop() })

                            Blank()

                            if (this.peers.size == 0) {
                                Row { }.width(55)
                            } else if (this.editing) {
                                Row {
                                    Image(@r(app.media.username_nav_ic_done))
                                        .width(24).height(24)
                                        .fillColor(0x317AFF)
                                        .onClick({ _evt => this.editing = false })
                                }
                                .width(44).height(44)
                                .borderRadius(22)
                                .backgroundColor(0xFFFFFF)
                                .justifyContent(FlexAlign.Center)
                                .alignItems(VerticalAlign.Center)
                            } else {
                                Row {
                                    Text(trSource("Edit"))
                                        .fontSize(17)
                                        .fontWeight(FontWeight.Medium)
                                        .fontColor(0x000000)
                                        .onClick({ _evt => this.editing = true })
                                }
                                .height(44)
                                .padding(left: 14, right: 14)
                                .borderRadius(22)
                                .backgroundColor(0xFFFFFF)
                                .justifyContent(FlexAlign.Center)
                                .alignItems(VerticalAlign.Center)
                            }
                        }
                        .width(100.percent).height(ITEM_LIST_NAVBAR_H)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                    }
                    .width(100.percent)
                    .height(ITEM_LIST_NAVBAR_H)
                }
                .width(100.percent)
                .height(ITEM_LIST_NAVBAR_H)
            }
            .width(100.percent).height(100.percent)
            .backgroundColor(0xF2F2F7)

            if (this.showPicker) {
                this.buildPickerOverlay()
            }

            // RC-6b：Delete All 确认层改贴底 ActionSheet（ContextMenuView），文案逐字取源
            // （Localizable.strings Privacy_Exceptions_DeleteAllConfirmation / _DeleteAll /
            // Common_Cancel），不保留自造正文，不保留居中 alert 的标题行。
            if (this.showDeleteAllConfirm) {
                ContextMenuView(
                    items: [
                        ContextMenuItem.text(title: "Are you sure you want to delete all exceptions?"),
                        ContextMenuItem(
                            title: "Delete All",
                            destructive: true,
                            onClick: { => this.deleteAll() },
                            centered: true
                        ),
                        ContextMenuItem.separator(),
                        ContextMenuItem(title: "Cancel", onClick: { => }, centered: true)
                    ],
                    onDismiss: { => this.showDeleteAllConfirm = false }
                )
            }
        }
        .width(100.percent).height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        .onAppear({
            =>
            this.parseRouteParamOnce()
            this.refresh()
        })
    }
}
