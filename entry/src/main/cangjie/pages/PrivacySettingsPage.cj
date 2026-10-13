package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    getPrivacyEngineService, PrivacyEngineService,
    getRealAuthService,
    getAppLockService,
    getLocalizationService,
    parseLoginEmailPattern,
    getSettingsService
}
import ohos_app_cangjie_entry.components.{
    ItemListSectionHeader,
    ItemListSectionFooter,
    ItemListSeparator,
    ItemListDisclosureRow,
    ItemListNavBarBackground,
    itemListNavBarBackgroundAlpha255,
    ITEM_LIST_NAVBAR_H
}
import ohos_app_cangjie_entry.core.storage.{
    PresentationSnapshot,
    currentPresentation,
    PresentationStringsSnapshot,
    currentPresentationStrings
}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.utils.{safeAnimateTo, removePlus}
import ohos_app_cangjie_entry.core.mtproto.{getMTProtoClient, AccountGetPassword, PrivacyRulesResponse}
import std.collection.ArrayList
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

// RC-3（diag-suite_settings_privacy-TC-0131.md F2）：SelectivePrivacySettingsPage 改档位后
// pop 回本页时的回传槽位——是闭包槽位，不是"重新拉取"（源侧同样是子屏 willDisappear 把新值
// 推回父屏的 Promise，父屏零次额外网络请求）。形状同 core/storage/AppTheme.cj:289 的既有
// 先例（package-private top-level var + 调用式访问器）。注册方见 ensureLoaded()；写入方
// 归 SelectivePrivacySettingsPage.cj（set_selective_privacy 的 target_files，不在本文件）。
var _onSelectivePrivacyUpdated: Option<(String, String, Int64, Int64) -> Unit> = None
func notifySelectivePrivacyUpdated(kindParam: String, value: String, allowCount: Int64, disallowCount: Int64): Unit {
    match (_onSelectivePrivacyUpdated) {
        case Some(h) => h(kindParam, value, allowCount, disallowCount)
        case None => ()
    }
}

// FIX-4 / TC-0435-round2 增量 D-1：`Open Links in` 行右值的回传槽位。形状与上面
// _onSelectivePrivacyUpdated 完全同型（package-private top-level var + 调用式访问器，
// 源出 core/storage/AppTheme.cj:289 的既有先例）。
//
// 为什么需要它：本页的 NavDestination 在被 push 到 WebBrowserSettingsPage 之后仍然挂载，
// routerPop() 回来时不会仅因为重新可见就重新 build()（ets/pages/AppearanceSettingsPage.ets:60-68
// 对同一现象有完整记载）。ets/pages/PrivacySettingsPage.ets 不在本 feature 的 target_files 内，
// 不能照 AppearanceSettingsPage 的做法加 .onShown 转发，因此改用本包内既有的回传槽位：
// 写入方是 pages/WebBrowserSettingsPage.cj 的 applyState()，注册方见 ensureLoaded()。
var _onWebBrowserSelectionUpdated: Option<() -> Unit> = None
func notifyWebBrowserSelectionUpdated(): Unit {
    match (_onWebBrowserSelectionUpdated) {
        case Some(h) => h()
        case None => ()
    }
}

// F-2（diag-suite_settings_privacy-TC-0129.md）：GlobalAutoremoveScreen 改值后 pop 回本页的
// 回传槽位。形状与上面 _onSelectivePrivacyUpdated / _onWebBrowserSelectionUpdated 逐字同型
// （package-private top-level var + 调用式访问器）——本页的 NavDestination 在被 push 之后
// 仍挂载，routerPop() 回来不会重新 build()，同一根因见 :49-51 注释。写入方是
// pages/GlobalAutoremoveScreen.cj 的 selectValue()（归 feature_wiring 的 target_files，
// 不在本文件，接线走 emitted_integration_contracts[ic_privacy_autoremove_writeback]）。
var _onGlobalAutoremoveUpdated: Option<(Int32) -> Unit> = None
func notifyGlobalAutoremoveUpdated(seconds: Int32): Unit {
    match (_onGlobalAutoremoveUpdated) {
        case Some(h) => h(seconds)
        case None => ()
    }
}

/**
 * Privacy and Security Settings — 整页重构（diag-suite_settings_privacy-TC-0127.md P6）
 * + round-1 RC-1/RC-2/RC-3/RC-6/RC-7 + 本轮返修（TC-0127-round2/TC-0128/TC-0129/TC-0130/
 * TC-0131/TC-0143-round2，见各函数处注释）。
 *
 * 源侧对位：`PrivacyAndSecurityController.swift`
 * （`privacyAndSecurityControllerEntries` :647-829，`item()` :440-553）。
 *
 * 6 张固定卡片（按源 `section` 顺序）：
 *   1. 安全块（无分区头）：Blocked Users / Connected Websites(条件) / Passcode Lock /
 *      Two-Step Verification / Passkeys / Auto-Delete Messages（=`messageAutoremoveTimeout`，
 *      不是"If Away For"）+ 卡下脚注。
 *   2. Login Email（三条件析取门控，见 M2）+ 脚注（三态取决于是否已有 loginEmailPattern）。
 *   3. PRIVACY（12 行）+ 脚注。
 *   4. AUTOMATICALLY DELETE MY ACCOUNT：If Away For（=`accountTimeout`，bindPopup 锚定
 *      菜单，见 M-1~M-5）+ 脚注。
 *   5. Data Settings（无分区头，RC-6 接 `DataPrivacySettingsPage`）+ 脚注。
 *   6. Open Links in（无分区头）。
 * 本轮删除了 round-1 遗留的目标独有段 ACCOUNT ACTIONS（Log Out / Delete Account 直达
 * 按钮）——diag-suite_settings_privacy-TC-0129.md M-6 与 diag-...-TC-0127-round2.md RC-E
 * 已共同确认：源屏 entries 全表无对应物，是把源侧刻意藏在二级菜单后的破坏性操作提到了
 * 根屏一级，属净退化，按 D4.4 删除（详见 buildTtlMenuContent() 处注释）。
 *
 * RC-1（7 隐私类别行改就地循环为推屏）+ RC-2（D-125 值绑定）+ 新增 5 行（Bio/Gifts/
 * Birthday/Saved Music/Messages）：diag-suite_settings_privacy-E8-batch.md F-2（RC-1
 * 根屏半）—— `set_selective_privacy` 已按 F-1 把 `SelectivePrivacySettingsPage.kindParam`
 * 的识别范围从 7 个既有 kind（phone_number/last_seen/profile_photo/forwards/groups/
 * calls/voice_messages）扩到 11 个（新增 bio/birthday/saved_music/gifts），故本轮已把
 * 这 11 行全部接到该路由。`Messages` 例外：它不走 `getPrivacyRules`，源侧读写
 * `GlobalPrivacySettings.nonContactChatsPrivacy`，该字段尚未在
 * `core/mtproto/TLResponses.cj`/`TLMethods.cj`（归 `net_telegram_api`，不在任何人当前
 * allowlist）落地，`SelectivePrivacySettingsPage` 仍未识别该 kind（故意，未识别兜底
 * "last_seen"）——误触即写错分类隐私档位，属账号安全红线，故 Messages 行 onClick 刻意
 * 保持留空、只做真实取值展示，不导航；待 `net_telegram_api` 落地该字段后再补线。
 *
 * RC-1b（diag-suite_settings_privacy-TC-0131.md）：`net_telegram_api` 的 RC-1 已合入，
 * `PrivacyRulesResponse.primaryValue` 现在只承载三值域（everybody/contacts/nobody），
 * close_friends/premium/bots 三个旗标改由同名字段单独携带。本页 `loadAllPrivacySettings()`
 * 11 个读取点同步取出三旗标，`getPrivacyDisplayTextWithExceptions()`（B2，
 * diag-suite_settings_privacy-TC-0128-round2.md）按源侧 `stringForSelectiveSettings` 的
 * 分支优先级还原 13 种 label，并按 allow/disallow 两张独立名单的 Σ`userCount` 计数（B1）；
 * 并加 `parsed` 守卫，防止一次瞬时解析失败静默把整屏隐私行改写成同一个档位。
 *
 * RC-3（Default Message Timer → GlobalAutoremoveScreen）：目标屏
 * `pages/GlobalAutoremoveScreen.cj` 全仓不存在（`_legacy_target_files` 归
 * `set_selective_privacy`），跨 feature 缺口走 emit，本行 onClick 留空、真实值正常展示。
 */
@HybridComponentEntry
@Component
public class PrivacySettingsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @StorageLink["presentationStrings"] var strings: PresentationStringsSnapshot = currentPresentationStrings()

    private func text(key: String, fallback: String): String {
        return this.strings.getOr(key, fallback)
    }
    // TC-0541 C2: subscribe to the published PresentationSnapshot so Dark All day
    // rebuilds this page's chrome (page/card/nav/row colors). Same key as
    // DataStorageSettingsPage / ItemListSection — do not introduce a second snapshot.
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()

    // --- Privacy rules（12 类，含 4 个本轮新增：bio/gifts/birthday/savedMusic）---
    @State var phoneNumberPrivacy: String = "everybody"
    @State var lastSeenPrivacy: String = "everybody"
    @State var profilePhotoPrivacy: String = "everybody"
    @State var bioPrivacy: String = "everybody"
    @State var giftsPrivacy: String = "everybody"
    @State var birthdayPrivacy: String = "everybody"
    @State var savedMusicPrivacy: String = "everybody"
    @State var forwardsPrivacy: String = "everybody"
    @State var groupsPrivacy: String = "everybody" // Invites
    @State var callsPrivacy: String = "everybody"
    @State var voiceMessagesPrivacy: String = "everybody"

    // Exception counts（diag-suite_settings_privacy-TC-0128-round2.md B1）：Always/Never
    // 两张逻辑独立的名单必须分别承载，不得再折叠成一个标量——档位与名单的绑定关系由
    // getPrivacyDisplayTextWithExceptions() 的分支表决定，源侧 Everybody 档只认 disallow
    // （Never）计数、其余档只认 allow（Always）计数。
    // index: 0=phone,1=lastSeen,2=photo,3=fwd,4=groups,5=calls,6=voice — 既有 7 类
    @State var privacyAllowCounts: Array<Int64> = Array<Int64>(7, repeat: 0)
    @State var privacyDisallowCounts: Array<Int64> = Array<Int64>(7, repeat: 0)
    // 新增 4 类各自独立计数字段（不复用上面数组，避免打乱既有下标含义）
    @State var bioAllowCount: Int64 = 0
    @State var bioDisallowCount: Int64 = 0
    @State var giftsAllowCount: Int64 = 0
    @State var giftsDisallowCount: Int64 = 0
    @State var birthdayAllowCount: Int64 = 0
    @State var birthdayDisallowCount: Int64 = 0
    @State var savedMusicAllowCount: Int64 = 0
    @State var savedMusicDisallowCount: Int64 = 0

    // RC-1b（diag-suite_settings_privacy-TC-0131.md）：close_friends/premium/bots 三旗标，
    // 7 类既有行沿用 privacyAllowCounts/privacyDisallowCounts 的下标形状；bio/gifts/
    // birthday/savedMusic 4 类各自独立字段，与其既有 xxxAllowCount/xxxDisallowCount 同型。
    @State var privacyCloseFriendsFlags: Array<Bool> = Array<Bool>(7, repeat: false)
    @State var privacyPremiumFlags: Array<Bool> = Array<Bool>(7, repeat: false)
    @State var privacyBotsFlags: Array<Bool> = Array<Bool>(7, repeat: false)
    @State var bioHasCloseFriends: Bool = false
    @State var bioHasPremium: Bool = false
    @State var bioHasBots: Bool = false
    @State var giftsHasCloseFriends: Bool = false
    @State var giftsHasPremium: Bool = false
    @State var giftsHasBots: Bool = false
    @State var birthdayHasCloseFriends: Bool = false
    @State var birthdayHasPremium: Bool = false
    @State var birthdayHasBots: Bool = false
    @State var savedMusicHasCloseFriends: Bool = false
    @State var savedMusicHasPremium: Bool = false
    @State var savedMusicHasBots: Bool = false

    // "Messages" 行（noPaidMessages/nonContactChatsPrivacy）——源侧不是独立 privacy key，
    // 是 GlobalPrivacySettings 派生值（見 messagePrivacy 计算，本文件 messagesLabel()）。
    @State var nonContactChatsRequirePremium: Bool = false
    @State var nonContactChatsPaidStars: Int64 = 0

    // Security counters
    @State var blockedCount: Int32 = 0
    @State var webSessionsCount: Int32 = 0

    // Auto-Delete Messages（=messageAutoremoveTimeout，安全块内，非 If Away For）
    @State var autoDeleteSeconds: Int32 = 0

    // Account TTL（If Away For）
    @State var accountTtlDays: Int32 = 180

    // Passkeys
    @State var passkeys: Array<String> = Array<String>()
    @State var passkeyIds: Array<String> = Array<String>()

    // Two-Step Verification 三态
    @State var hasTwoStepAuth: Bool = false

    // Login Email 三态
    @State var loginEmailPattern: String = ""
    // M2 门控三项析取输入（diag-suite_settings_privacy-TC-0143-round2.md）：本地手机号
    // （去 "+" 后的完整国际号）与当前语言的 baseLanguageCode。
    @State var accountPhone: String = ""
    @State var appBaseLangCode: String = ""

    // RC-B（diag-suite_settings_privacy-TC-0127-round2.md）：Passcode Lock 是本地同步值，
    // 不经 loadAllPrivacySettings() 的网络 spawn，见 ensureLoaded()。
    @State var hasPasscode: Bool = false

    // 全量数据是否已回流（TC-0127 §6.3-7：列表结构常驻渲染，仅动态值文案在未回流时
    // 显示行内 "Loading..."，不再整块换成全屏遮罩）。
    @State var dataLoaded: Bool = false
    @State var loaded: Bool = false

    // round2 §6.6：入口分叉重入闸，防止连点在配置未返回前重复发起 RPC。
    @State var isCheckingTwoStepEntry: Bool = false

    // If Away For：bindPopup 锚定菜单状态（M-1~M-4，diag-suite_settings_privacy-TC-0129.md）。
    @State var showTtlMenu: Bool = false
    @State var updatingAccountTtl: Bool = false
    @State var ttlRowPressed: Bool = false

    // ── D-125 镜像字段：所有传给 ItemListDisclosureRow.value:/ItemListSectionHeader.title:
    // 的动态计算值，一律先落到这些裸 @State 字段，调用点只传字段本身（dev_pattern.md D-125）。
    // 由 refreshDerivedState() 在每次 build() 入口统一刷新。──
    @State var passcodeValueText: String = ""
    @State var phoneNumberValueText: String = ""
    @State var lastSeenValueText: String = ""
    @State var profilePhotoValueText: String = ""
    @State var bioValueText: String = ""
    @State var giftsValueText: String = ""
    @State var birthdayValueText: String = ""
    @State var savedMusicValueText: String = ""
    @State var forwardsValueText: String = ""
    @State var groupsValueText: String = ""
    @State var callsValueText: String = ""
    @State var voiceMessagesValueText: String = ""
    @State var messagesValueText: String = ""
    @State var blockedCountValueText: String = ""
    @State var webSessionsValueTextMirror: String = ""
    @State var passkeysValueText: String = ""
    @State var twoStepValueText: String = ""
    @State var autoDeleteValueText: String = ""
    @State var accountTtlValueText: String = ""
    @State var loginEmailValueText: String = ""
    @State var loginEmailFooterText: String = ""
    // FIX-4 / round2 增量 D-1：`Open Links in` 行右值。由 webBrowserSelectionLabel()
    // （pages/WebBrowserSettingsPage.cj，本包内）推导，与 Web Browser 屏内的选中勾同源。
    @State var openLinksInValueText: String = "Telegram"

    // ── 容器导航栏渐显契约（uif_itemlist_core，TC-0127 §6.3-6）──
    private var contentScroller: Scroller = Scroller()
    @State var navBarAlpha255: UInt32 = 0
    private var prevScrollOffsetVp: Float64 = 0.0

    /**
     * TC-0127-round4 §6.1（diag-suite_settings_privacy-TC-0127-round4.md）：返回 chevron 的
     * Path 命令串。
     *
     * ArkUI Path 的 commands 坐标按 **px** 消费（`ohos.arkui.component.path.cj.d:52` 的签名
     * 是裸 ResourceStr，字符串不携带单位；Path 上没有任何 viewBox/viewPort 入口，viewPort
     * 只存在于 Shape），而同组件的 .width/.height/.strokeWidth 是 Length，默认单位 vp。源侧
     * glassBackArrowImage（NavigationButtonNode.swift:8-23）把点坐标画进 DrawingContext，由
     * 框架按 deviceScale 放大，这一次乘法在 ArkUI 侧必须由调用方自己补，否则图形缩到
     * 1/density 并锚在组件框左上角（先例 pages/DevicesPage.cj:658-683，TC-0134-round5 N1'）。
     *
     * 坐标取值逐一对位源侧：44×44 画布，topRightPoint (24.6,14)，centerPoint (17,22)，
     * 第三点 (24.6,30)。
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

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        // RC-B（diag-suite_settings_privacy-TC-0127-round2.md）：hasPasscode 是本地同步值
        // （getAppLockService().hasPasscode() 不发网络请求），不进 loadAllPrivacySettings()
        // 的异步 spawn，也不参与 refreshDerivedState() 的 !dataLoaded 占位分支。
        this.hasPasscode = getAppLockService().hasPasscode()
        // RC-3（diag-suite_settings_privacy-TC-0131.md F2）：注册子屏改动回传通道，闩内只
        // 注册一次，避免多次 pop/push 累积重复 handler。
        _onSelectivePrivacyUpdated = Some({ kindParam, value, allowCount, disallowCount =>
            this.applySelectiveUpdate(kindParam, value, allowCount, disallowCount)
        })
        // FIX-4 / round2 增量 D-1：同型回传槽位——WebBrowserSettingsPage 改完默认浏览器后
        // 立刻把新 label 推回本页，不等冷启动、也不额外发一次网络请求。
        // 首次进屏的初值同样在这里同步取（webBrowserSelectionLabel() 只读本地 Preferences
        // 缓存，无网络往返，可以直接在 UI 线程上调用——R-138）。
        _onWebBrowserSelectionUpdated = Some({ =>
            this.openLinksInValueText = webBrowserSelectionLabel()
        })
        // F-2（diag-suite_settings_privacy-TC-0129.md）：GlobalAutoremoveScreen 改值后回灌
        // autoDeleteSeconds。只写这一个 @State；autoDeleteValueText 由 refreshDerivedState()
        // 在每次 build() 入口统一从 autoDeleteSeconds 派生（:831），无需在此处重复计算。
        _onGlobalAutoremoveUpdated = Some({ seconds =>
            this.autoDeleteSeconds = seconds
        })
        // CG-01：PasskeysPage 增删 passkey 后回灌数量；passkeysValueText 由 refreshDerivedState()
        // 在 build() 入口从 passkeys.size 派生（passkeysLabel），与 iOS updatedHasPasskeys 同义。
        _onPasskeysUpdated = Some({ count =>
            this.passkeys = Array<String>(count, repeat: "")
        })
        this.openLinksInValueText = webBrowserSelectionLabel()
        // RC-A（diag-suite_settings_data_storage-TC-0435-round3.md F-A）：上面这行只读本地
        // Preferences 缓存；缓存的唯一写入方是 WebBrowserSettingsPage 自己的 ensureLoaded()，
        // 用户没进过那一屏时 hasWebBrowserSettingsCache() 恒为 false，本行恒读 "Telegram"，
        // 与账号真实值无关。源侧 PrivacyAndSecurityController.swift:1583-1584/:1619-1636 是
        // 订阅式常驻数据源，不依赖用户是否进过 Web Browser 设置屏——对位这一属性，这里补一次
        // 账号级装载，让缓存在进入本屏时就已可得，不必等用户先手动进 Web Browser 屏。
        this.refreshWebBrowserSelection()
        this.loadAllPrivacySettings()
    }

    /**
     * RC-A（diag-suite_settings_data_storage-TC-0435-round3.md F-A）：装载账号级
     * `openExternalBrowser` 并回灌 `openLinksInValueText`。R-138：网络往返只能在 spawn 里跑，
     * 回写经 spawn(UIThread) 收敛回 UI 线程（S-001）。
     *
     * 边界条件（F-A 明确要求）：
     * - 不改用 `services/BrowserService.cj` 的本地 `open_external_browser` 键——那是
     *   round2 那条矛盾的成因（见 currentOpenExternalBrowser() 头部注释）。
     * - 不删 `currentOpenExternalBrowser()` 的"无缓存 ⇒ false"兜底；本函数只是让缓存
     *   更早存在，不改兜底语义。
     * - 首帧仍先用缓存值渲染（上面 `this.openLinksInValueText = webBrowserSelectionLabel()`），
     *   本函数只在网络回包后就地更新，不加 loading 态（源侧首帧同样是
     *   `?? AccountWebBrowserSettings.defaultSettings`）。
     */
    private func refreshWebBrowserSelection(): Unit {
        let _ = spawn {
            let _ = getSettingsService().getWebBrowserSettings(false)
            spawn(UIThread) { => this.openLinksInValueText = webBrowserSelectionLabel() }
        }
    }

    // RC-3 F2（diag-suite_settings_privacy-TC-0131.md）：SelectivePrivacySettingsPage 改档位
    // 后通过 _onSelectivePrivacyUpdated 闭包槽把新值推回本页，替代"pop 后重新拉一遍"的整屏
    // 刷新（那会引入源侧没有的额外网络请求）。kindParam 取值域是该页路由参数 SSOT 的 11 个
    // kind 字符串（7 个既有 + bio/gifts/birthday/saved_music）；未识别值静默忽略，不误改
    // 其它行。
    // B3（diag-suite_settings_privacy-TC-0128-round2.md）：allowCount/disallowCount 各自写回
    // 各自的数组下标，不再合并成一个 total——合并会把 B2 的分支表重新打散回一个标量。
    // diag-suite_settings_privacy-E12-batch.md G-1（RC-E12-1）：bio/gifts/birthday/
    // saved_music 4 类不进 privacyAllowCounts/privacyDisallowCounts 这两个 7 元数组（下标
    // 形状与 privacyCloseFriendsFlags/PremiumFlags/BotsFlags 一一对应，扩容会打散既有下标
    // 语义），改写各自在 :130-140 已声明、且已被 refreshDerivedState() 消费的独立字段，写完
    // 立即 return，不流入下面 7 类共用的数组写回尾段。
    private func applySelectiveUpdate(kindParam: String, value: String, allowCount: Int64, disallowCount: Int64): Unit {
        var allowArr = this.privacyAllowCounts
        var disallowArr = this.privacyDisallowCounts
        if (kindParam == "phone_number") {
            this.phoneNumberPrivacy = value
            allowArr[0] = allowCount; disallowArr[0] = disallowCount
        } else if (kindParam == "last_seen") {
            this.lastSeenPrivacy = value
            allowArr[1] = allowCount; disallowArr[1] = disallowCount
        } else if (kindParam == "profile_photo") {
            this.profilePhotoPrivacy = value
            allowArr[2] = allowCount; disallowArr[2] = disallowCount
        } else if (kindParam == "forwards") {
            this.forwardsPrivacy = value
            allowArr[3] = allowCount; disallowArr[3] = disallowCount
        } else if (kindParam == "groups") {
            this.groupsPrivacy = value
            allowArr[4] = allowCount; disallowArr[4] = disallowCount
        } else if (kindParam == "calls") {
            this.callsPrivacy = value
            allowArr[5] = allowCount; disallowArr[5] = disallowCount
        } else if (kindParam == "voice_messages") {
            this.voiceMessagesPrivacy = value
            allowArr[6] = allowCount; disallowArr[6] = disallowCount
        } else if (kindParam == "bio") {
            this.bioPrivacy = value
            this.bioAllowCount = allowCount; this.bioDisallowCount = disallowCount
            return
        } else if (kindParam == "gifts") {
            this.giftsPrivacy = value
            this.giftsAllowCount = allowCount; this.giftsDisallowCount = disallowCount
            return
        } else if (kindParam == "birthday") {
            this.birthdayPrivacy = value
            this.birthdayAllowCount = allowCount; this.birthdayDisallowCount = disallowCount
            return
        } else if (kindParam == "saved_music") {
            this.savedMusicPrivacy = value
            this.savedMusicAllowCount = allowCount; this.savedMusicDisallowCount = disallowCount
            return
        } else {
            return
        }
        this.privacyAllowCounts = allowArr
        this.privacyDisallowCounts = disallowArr
    }

    // B1（diag-suite_settings_privacy-TC-0128-round2.md）：对位源侧
    // countForSelectivePeers（PrivacyAndSecurityController.swift:576-582）。userIds 命中
    // r.peerUserIds 记权重 1，chatIds 命中 r.peerChatUserCounts 记其群/频道人数；任一 id
    // 在两张表里都查不到即静默跳过，对位源侧 peers[id] 查不到即丢弃的行为（不是兜底近似，
    // 是逐字复刻——见 TLResponses.cj PrivacyRulesResponse 的字段注释）。
    private func countForSelectivePeers(userIds: ArrayList<Int64>, chatIds: ArrayList<Int64>, r: PrivacyRulesResponse): Int64 {
        var total: Int64 = 0
        for (uid in userIds) {
            match (r.peerUserIds.get(uid)) {
                case Some(_) => total = total + 1
                case None => ()
            }
        }
        for (cid in chatIds) {
            match (r.peerChatUserCounts.get(cid)) {
                case Some(w) => total = total + w
                case None => ()
            }
        }
        return total
    }

    private func loadAllPrivacySettings(): Unit {
        // RC-1b 防退化基线（diag-suite_settings_privacy-TC-0131.md M-1b 第4条）：11 类
        // primaryValue 与 3 个旗标数组的回退基线取当前 @State 值（UI 线程读取），
        // parsed==false 时保留原值，不被覆盖成默认档位。
        let basePhone = this.phoneNumberPrivacy; let baseLastSeen = this.lastSeenPrivacy
        let basePhoto = this.profilePhotoPrivacy
        let baseBio = this.bioPrivacy; let baseGifts = this.giftsPrivacy
        let baseBirthday = this.birthdayPrivacy; let baseSavedMusic = this.savedMusicPrivacy
        let baseFwd = this.forwardsPrivacy; let baseGroups = this.groupsPrivacy
        let baseCalls = this.callsPrivacy; let baseVoice = this.voiceMessagesPrivacy
        let baseCF = this.privacyCloseFriendsFlags
        let basePM = this.privacyPremiumFlags
        let baseBT = this.privacyBotsFlags
        let baseBioCF = this.bioHasCloseFriends; let baseBioPM = this.bioHasPremium; let baseBioBT = this.bioHasBots
        let baseGiftsCF = this.giftsHasCloseFriends; let baseGiftsPM = this.giftsHasPremium; let baseGiftsBT = this.giftsHasBots
        let baseBirthdayCF = this.birthdayHasCloseFriends; let baseBirthdayPM = this.birthdayHasPremium; let baseBirthdayBT = this.birthdayHasBots
        let baseSavedMusicCF = this.savedMusicHasCloseFriends; let baseSavedMusicPM = this.savedMusicHasPremium; let baseSavedMusicBT = this.savedMusicHasBots
        let basePhoneVal = this.accountPhone
        let baseLangVal = this.appBaseLangCode

        let _ = spawn {
            let svc = getPrivacyEngineService()
            var phone = basePhone; var lastSeen = baseLastSeen; var photo = basePhoto
            var bio = baseBio; var gifts = baseGifts; var birthday = baseBirthday
            var savedMusic = baseSavedMusic
            var fwd = baseFwd; var groups = baseGroups; var calls = baseCalls
            var voice = baseVoice; var blocked: Int32 = 0; var webCount: Int32 = 0
            var ttlDays: Int32 = 180
            var pkNames: ArrayList<String> = ArrayList<String>()
            var pkIds: ArrayList<String> = ArrayList<String>()
            var autoDelSecs: Int32 = 0
            var excAllowCounts: Array<Int64> = Array<Int64>(7, repeat: 0)
            var excDisallowCounts: Array<Int64> = Array<Int64>(7, repeat: 0)
            var bioAllowExc: Int64 = 0; var bioDisallowExc: Int64 = 0
            var giftsAllowExc: Int64 = 0; var giftsDisallowExc: Int64 = 0
            var birthdayAllowExc: Int64 = 0; var birthdayDisallowExc: Int64 = 0
            var savedMusicAllowExc: Int64 = 0; var savedMusicDisallowExc: Int64 = 0
            var nonContactRequirePremium = false
            var nonContactPaidStars: Int64 = 0
            var hasTwoStep = false
            var emailPattern = ""
            var accountPhoneVal = basePhoneVal
            var appBaseLangCodeVal = baseLangVal
            var cfArr: Array<Bool> = baseCF
            var pmArr: Array<Bool> = basePM
            var btArr: Array<Bool> = baseBT
            var bioCF = baseBioCF; var bioPM = baseBioPM; var bioBT = baseBioBT
            var giftsCF = baseGiftsCF; var giftsPM = baseGiftsPM; var giftsBT = baseGiftsBT
            var birthdayCF = baseBirthdayCF; var birthdayPM = baseBirthdayPM; var birthdayBT = baseBirthdayBT
            var savedMusicCF = baseSavedMusicCF; var savedMusicPM = baseSavedMusicPM; var savedMusicBT = baseSavedMusicBT

            try {
                let r = svc.getPrivacyRules(PrivacyEngineService.KEY_PHONE_NUMBER)
                if (r.parsed) {
                    phone = r.primaryValue
                    cfArr[0] = r.hasCloseFriends; pmArr[0] = r.hasPremiumOnly; btArr[0] = r.hasBots
                }
                excAllowCounts[0] = this.countForSelectivePeers(r.allowUsers, r.allowChats, r)
                excDisallowCounts[0] = this.countForSelectivePeers(r.disallowUsers, r.disallowChats, r)
            } catch (_e: Exception) {}
            try {
                let r = svc.getPrivacyRules(PrivacyEngineService.KEY_LAST_SEEN)
                if (r.parsed) {
                    lastSeen = r.primaryValue
                    cfArr[1] = r.hasCloseFriends; pmArr[1] = r.hasPremiumOnly; btArr[1] = r.hasBots
                }
                excAllowCounts[1] = this.countForSelectivePeers(r.allowUsers, r.allowChats, r)
                excDisallowCounts[1] = this.countForSelectivePeers(r.disallowUsers, r.disallowChats, r)
            } catch (_e: Exception) {}
            try {
                let r = svc.getPrivacyRules(PrivacyEngineService.KEY_PROFILE_PHOTO)
                if (r.parsed) {
                    photo = r.primaryValue
                    cfArr[2] = r.hasCloseFriends; pmArr[2] = r.hasPremiumOnly; btArr[2] = r.hasBots
                }
                excAllowCounts[2] = this.countForSelectivePeers(r.allowUsers, r.allowChats, r)
                excDisallowCounts[2] = this.countForSelectivePeers(r.disallowUsers, r.disallowChats, r)
            } catch (_e: Exception) {}
            try {
                let r = svc.getPrivacyRules(PrivacyEngineService.KEY_ABOUT)
                if (r.parsed) {
                    bio = r.primaryValue
                    bioCF = r.hasCloseFriends; bioPM = r.hasPremiumOnly; bioBT = r.hasBots
                }
                bioAllowExc = this.countForSelectivePeers(r.allowUsers, r.allowChats, r)
                bioDisallowExc = this.countForSelectivePeers(r.disallowUsers, r.disallowChats, r)
            } catch (_e: Exception) {}
            try {
                let r = svc.getPrivacyRules(PrivacyEngineService.KEY_STAR_GIFTS_AUTO_SAVE)
                if (r.parsed) {
                    gifts = r.primaryValue
                    giftsCF = r.hasCloseFriends; giftsPM = r.hasPremiumOnly; giftsBT = r.hasBots
                }
                giftsAllowExc = this.countForSelectivePeers(r.allowUsers, r.allowChats, r)
                giftsDisallowExc = this.countForSelectivePeers(r.disallowUsers, r.disallowChats, r)
            } catch (_e: Exception) {}
            try {
                let r = svc.getPrivacyRules(PrivacyEngineService.KEY_BIRTHDAY)
                if (r.parsed) {
                    birthday = r.primaryValue
                    birthdayCF = r.hasCloseFriends; birthdayPM = r.hasPremiumOnly; birthdayBT = r.hasBots
                }
                birthdayAllowExc = this.countForSelectivePeers(r.allowUsers, r.allowChats, r)
                birthdayDisallowExc = this.countForSelectivePeers(r.disallowUsers, r.disallowChats, r)
            } catch (_e: Exception) {}
            try {
                let r = svc.getPrivacyRules(PrivacyEngineService.KEY_SAVED_MUSIC)
                if (r.parsed) {
                    savedMusic = r.primaryValue
                    savedMusicCF = r.hasCloseFriends; savedMusicPM = r.hasPremiumOnly; savedMusicBT = r.hasBots
                }
                savedMusicAllowExc = this.countForSelectivePeers(r.allowUsers, r.allowChats, r)
                savedMusicDisallowExc = this.countForSelectivePeers(r.disallowUsers, r.disallowChats, r)
            } catch (_e: Exception) {}
            try {
                let r = svc.getPrivacyRules(PrivacyEngineService.KEY_FORWARDS)
                if (r.parsed) {
                    fwd = r.primaryValue
                    cfArr[3] = r.hasCloseFriends; pmArr[3] = r.hasPremiumOnly; btArr[3] = r.hasBots
                }
                excAllowCounts[3] = this.countForSelectivePeers(r.allowUsers, r.allowChats, r)
                excDisallowCounts[3] = this.countForSelectivePeers(r.disallowUsers, r.disallowChats, r)
            } catch (_e: Exception) {}
            try {
                let r = svc.getPrivacyRules(PrivacyEngineService.KEY_GROUPS)
                if (r.parsed) {
                    groups = r.primaryValue
                    cfArr[4] = r.hasCloseFriends; pmArr[4] = r.hasPremiumOnly; btArr[4] = r.hasBots
                }
                excAllowCounts[4] = this.countForSelectivePeers(r.allowUsers, r.allowChats, r)
                excDisallowCounts[4] = this.countForSelectivePeers(r.disallowUsers, r.disallowChats, r)
            } catch (_e: Exception) {}
            try {
                let r = svc.getPrivacyRules(PrivacyEngineService.KEY_CALLS)
                if (r.parsed) {
                    calls = r.primaryValue
                    cfArr[5] = r.hasCloseFriends; pmArr[5] = r.hasPremiumOnly; btArr[5] = r.hasBots
                }
                excAllowCounts[5] = this.countForSelectivePeers(r.allowUsers, r.allowChats, r)
                excDisallowCounts[5] = this.countForSelectivePeers(r.disallowUsers, r.disallowChats, r)
            } catch (_e: Exception) {}
            try {
                let r = svc.getPrivacyRules(PrivacyEngineService.KEY_VOICE_MESSAGES)
                if (r.parsed) {
                    voice = r.primaryValue
                    cfArr[6] = r.hasCloseFriends; pmArr[6] = r.hasPremiumOnly; btArr[6] = r.hasBots
                }
                excAllowCounts[6] = this.countForSelectivePeers(r.allowUsers, r.allowChats, r)
                excDisallowCounts[6] = this.countForSelectivePeers(r.disallowUsers, r.disallowChats, r)
            } catch (_e: Exception) {}

            try { blocked = svc.getBlockedCount() } catch (_e: Exception) {}
            try {
                let webResp = svc.getWebSessions()
                webCount = Int32(webResp.sessions.size)
            } catch (_e: Exception) {}
            try {
                let gps = svc.getGlobalPrivacySettings()
                nonContactRequirePremium = gps.newNoncontactPeersRequirePremium
                nonContactPaidStars = gps.noncontactPeersPaidStars
            } catch (_e: Exception) {}
            try { ttlDays = svc.getAccountTtlDays() } catch (_e: Exception) {}
            try { autoDelSecs = svc.getDefaultHistoryTtlSeconds() } catch (_e: Exception) {}
            try {
                let pkResp = svc.getPasskeysList()
                var i: Int64 = 0
                while (i < pkResp.passkeys.size) {
                    pkNames.add(pkResp.passkeys[i].name)
                    pkIds.add(pkResp.passkeys[i].id)
                    i = i + 1
                }
            } catch (_e: Exception) {}
            try {
                let authService = getRealAuthService()
                hasTwoStep = authService.getPasswordInfo().hasPassword
            } catch (_e: Exception) {}
            try {
                let client = getMTProtoClient()
                let req = AccountGetPassword()
                let data = client.sendRequest(req.toBytes())
                emailPattern = parseLoginEmailPattern(data)
            } catch (_e: Exception) {}
            try {
                // M2（diag-suite_settings_privacy-TC-0143-round2.md）：Login Email 卡片
                // 三条件析取门控之一——本地手机号（去 "+"）。
                match (getRealAuthService().getCurrentUser()) {
                    case Some(u) => accountPhoneVal = removePlus(u.phone)
                    case None => ()
                }
            } catch (_e: Exception) {}
            try {
                // M2 三条件析取门控之二——当前语言的 baseLanguageCode；查不到则取语言码本身
                // （对位源侧 strings.baseLanguageCode：有 base pack 取 base，否则就是自身）。
                let langCode = getLocalizationService().getCurrentLangCode()
                var baseCode = langCode
                let state = getLocalizationService().getLocalizationListState()
                var li: Int64 = 0
                while (li < state.availableOfficialLocalizations.size) {
                    let info = state.availableOfficialLocalizations[li]
                    if (info.languageCode == langCode && info.baseLanguageCode.size > 0) {
                        baseCode = info.baseLanguageCode
                    }
                    li = li + 1
                }
                appBaseLangCodeVal = baseCode
            } catch (_e: Exception) {}

            let p = phone; let ls = lastSeen; let ph = photo
            let bi2 = bio; let gi2 = gifts; let bd2 = birthday; let sm2 = savedMusic
            let f = fwd; let gr = groups; let cl = calls; let v = voice; let bl = blocked
            let wc = webCount; let td = ttlDays; let ads = autoDelSecs
            let excAllow = excAllowCounts; let excDisallow = excDisallowCounts
            let biAllowExc = bioAllowExc; let biDisallowExc = bioDisallowExc
            let giAllowExc = giftsAllowExc; let giDisallowExc = giftsDisallowExc
            let bdAllowExc = birthdayAllowExc; let bdDisallowExc = birthdayDisallowExc
            let smAllowExc = savedMusicAllowExc; let smDisallowExc = savedMusicDisallowExc
            let ncrp = nonContactRequirePremium; let ncps = nonContactPaidStars
            let hts = hasTwoStep; let lep = emailPattern
            let apVal = accountPhoneVal; let ablVal = appBaseLangCodeVal
            let cfFinal = cfArr; let pmFinal = pmArr; let btFinal = btArr
            let bioCFf = bioCF; let bioPMf = bioPM; let bioBTf = bioBT
            let giftsCFf = giftsCF; let giftsPMf = giftsPM; let giftsBTf = giftsBT
            let birthdayCFf = birthdayCF; let birthdayPMf = birthdayPM; let birthdayBTf = birthdayBT
            let savedMusicCFf = savedMusicCF; let savedMusicPMf = savedMusicPM; let savedMusicBTf = savedMusicBT
            let pnArr: Array<String> = Array<String>(pkNames.size, repeat: "")
            var ci: Int64 = 0
            while (ci < pkNames.size) { pnArr[ci] = pkNames[ci]; ci = ci + 1 }
            let piArr: Array<String> = Array<String>(pkIds.size, repeat: "")
            var di: Int64 = 0
            while (di < pkIds.size) { piArr[di] = pkIds[di]; di = di + 1 }

            spawn(UIThread) {
                =>
                this.phoneNumberPrivacy = p; this.lastSeenPrivacy = ls
                this.profilePhotoPrivacy = ph
                this.bioPrivacy = bi2; this.giftsPrivacy = gi2
                this.birthdayPrivacy = bd2; this.savedMusicPrivacy = sm2
                this.forwardsPrivacy = f; this.groupsPrivacy = gr
                this.callsPrivacy = cl; this.voiceMessagesPrivacy = v
                this.privacyAllowCounts = excAllow; this.privacyDisallowCounts = excDisallow
                this.bioAllowCount = biAllowExc; this.bioDisallowCount = biDisallowExc
                this.giftsAllowCount = giAllowExc; this.giftsDisallowCount = giDisallowExc
                this.birthdayAllowCount = bdAllowExc; this.birthdayDisallowCount = bdDisallowExc
                this.savedMusicAllowCount = smAllowExc; this.savedMusicDisallowCount = smDisallowExc
                this.nonContactChatsRequirePremium = ncrp; this.nonContactChatsPaidStars = ncps
                this.blockedCount = bl; this.webSessionsCount = wc
                this.accountTtlDays = td
                this.autoDeleteSeconds = ads
                this.passkeys = pnArr; this.passkeyIds = piArr
                this.hasTwoStepAuth = hts
                this.loginEmailPattern = lep
                this.accountPhone = apVal
                this.appBaseLangCode = ablVal
                this.privacyCloseFriendsFlags = cfFinal
                this.privacyPremiumFlags = pmFinal
                this.privacyBotsFlags = btFinal
                this.bioHasCloseFriends = bioCFf; this.bioHasPremium = bioPMf; this.bioHasBots = bioBTf
                this.giftsHasCloseFriends = giftsCFf; this.giftsHasPremium = giftsPMf; this.giftsHasBots = giftsBTf
                this.birthdayHasCloseFriends = birthdayCFf; this.birthdayHasPremium = birthdayPMf; this.birthdayHasBots = birthdayBTf
                this.savedMusicHasCloseFriends = savedMusicCFf; this.savedMusicHasPremium = savedMusicPMf; this.savedMusicHasBots = savedMusicBTf
                this.dataLoaded = true
            }
        }
    }

    // B2（diag-suite_settings_privacy-TC-0128-round2.md）：判定优先级 + 分支表逐字照抄源侧
    // stringForSelectiveSettings（PrivacyAndSecurityController.swift:584-644）。档位决定
    // 哪张名单（allow=Always / disallow=Never）参与显示——不是"一个标量 + 恒定 +/- 后缀"。
    // primaryValue 现在只可能是 everybody/contacts/nobody（net_telegram_api RC-1 已合入）。
    // 取代原 getPrivacyDisplayText()：裸档位分支已并入本函数的分支表，不再保留两份互相矛盾
    // 的档位判定。
    private func getPrivacyDisplayTextWithExceptions(value: String, allowCount: Int64, disallowCount: Int64, closeFriends: Bool, premium: Bool, bots: Bool): String {
        if (value == "everybody") {
            // 对位 .enableEveryone：只认 Never（disallow）名单，Always（allow）名单被源侧
            // withEnabledPeers 直接丢弃。
            if (disallowCount == 0) { return "Everybody" }
            return "Everybody (-${disallowCount})"
        }
        if (value == "contacts") {
            if (premium) { return "Premium & Contacts" }
            if (bots) { return "Mini Apps" }
            if (allowCount > 0 && disallowCount > 0) { return "My Contacts (-${disallowCount}, +${allowCount})" }
            if (allowCount > 0) { return "My Contacts (+${allowCount})" }
            if (disallowCount > 0) { return "My Contacts (-${disallowCount})" }
            return "My Contacts"
        }
        // "nobody"（及任何未识别取值，对位 .disableEveryone default）：只认 Always（allow）
        // 名单，Never（disallow）名单被源侧 withDisabledPeers 直接丢弃。
        if (allowCount == 0 && !closeFriends && !premium && !bots) { return "Nobody" }
        if (closeFriends && premium) {
            if (allowCount == 0) { return "Close Friends, Premium" }
            return "Close Friends, Premium +${allowCount}"
        }
        if (premium) {
            if (allowCount == 0) { return "Premium Users" }
            return "Premium Users +${allowCount}"
        }
        if (bots) {
            if (allowCount == 0) { return "Mini Apps" }
            return "Mini Apps +${allowCount}"
        }
        if (closeFriends) {
            // ⚠ 源侧既有笔误（PrivacyAndSecurityController.swift:608-613，两分支写反）：
            // 忠实复刻是本轮要求（case §3「只记录不判定」），不得"顺手修正"。
            if (allowCount == 0) { return "Close Friends (+${allowCount})" }
            return "Close Friends"
        }
        if (allowCount == 0) { return "Nobody" }
        return "Nobody (+${allowCount})"
    }

    private func autoDeleteLabel(seconds: Int32): String {
        if (seconds <= 0) { return this.text("Notifications.Off", "Off") }
        if (seconds <= 86400) { return this.text("MessageTimer.Days_1", "%@ day").replace("%@", "1") }
        if (seconds <= 604800) { return this.text("MessageTimer.Weeks_1", "%@ week").replace("%@", "1") }
        return this.text("MessageTimer.Months_1", "%@ month").replace("%@", "1")
    }

    // 对位源侧 MessageTimer_Months(max(1, days/30))：源侧固定用"月"表述 If Away For 的值，
    // 6 档 [30,90,180,365,548,730] 天分别对应 [1,3,6,12,18,24] 月，含单复数规则
    // （MessageTimer.Months_1 = "%@ month"，其余 = "%@ months"）。
    private func ttlMonthsLabel(days: Int32): String {
        var months = days / 30
        if (months < 1) { months = 1 }
        if (months == 1) {
            return this.text("MessageTimer.Months_1", "%@ month").replace("%@", "1")
        }
        let fallback = this.text("MessageTimer.Months", "%@ months")
        return this.text("MessageTimer.Months_any", fallback).replace("%@", "${months}")
    }

    private func messagesLabel(): String {
        if (this.nonContactChatsPaidStars > 0) { return "Paid" }
        if (this.nonContactChatsRequirePremium) { return "Contacts and Premium" }
        return "Everybody"
    }

    private func blockedCountLabel(): String {
        if (this.blockedCount == 0) { return "None" }
        return "${this.blockedCount}"
    }

    private func webSessionsLabel(): String {
        if (this.webSessionsCount > 0) { return "${this.webSessionsCount}" }
        return ""
    }

    private func passkeysLabel(): String {
        if (this.passkeys.size > 0) { return "On" }
        return "Off"
    }

    private func twoStepLabel(): String {
        if (this.hasTwoStepAuth) { return "On" }
        return "Off"
    }

    // RC-B（diag-suite_settings_privacy-TC-0127-round2.md）：对位源侧 passcodeValue
    // （accessChallengeData == .none ? PrivacySettings_PasscodeOff : ...On，本地值、无网络
    // 等待）。
    private func passcodeLabel(): String {
        if (this.hasPasscode) { return "On" }
        return "Off"
    }

    // RC-C（diag-suite_settings_privacy-TC-0127-round2.md）：源侧该行 label 是字面空串，
    // 与 loginEmailPattern 是否存在无关；邮箱状态只流向 action 参数与脚注文案。
    private func loginEmailLabel(): String {
        return ""
    }

    // M3（diag-suite_settings_privacy-TC-0143-round2.md）：hasLoginEmail 判据补"不含空格"
    // 那一层，对位源侧 :733-736（"含空格的 pattern" 在源侧被当作未设置处理，脚注取
    // Setup… 变体；这一层不套用到 M2 的门控条件①——门控只判 pattern 非空）。
    private func loginEmailFooterLabel(): String {
        if (this.loginEmailPattern.size > 0 && !this.loginEmailPattern.contains(" ")) {
            return "Change your email address for Telegram login codes."
        }
        return "Setup your email address for Telegram login codes."
    }

    /**
     * D-125 唯一刷新入口：在 build() 顶部通过零高度探针调用，把全部动态值算好写回裸
     * @State 字段。
     *
     * TC-0128 A1（diag-suite_settings_privacy-TC-0128.md）：未回流（!dataLoaded）时不再
     * 无差别显示 "Loading..."——源侧未回流态是"每行绑自己的信号 + 每行自己的 nil 文案"，
     * 只有受 privacySettings 门控的那批行（12 行 PRIVACY + Auto-Delete Messages +
     * If Away For）取 "Loading..."；Blocked Users/Web Sessions/Passkeys/Two-Step/
     * Login Email 五行受各自独立 optional 门控，未回流态是空串（:422 的 loginEmailValueText
     * 与 RC-C 的改动是同一次编辑：loginEmailLabel() 已恒返回空串，此处显式同步，不留互相
     * 打架的两条指令）。Passcode Lock 是本地同步值，不进本分支（见上方赋值）。
     */
    private func refreshDerivedState(): String {
        this.passcodeValueText = this.passcodeLabel()
        if (!this.dataLoaded) {
            let loading = "Loading..."
            this.phoneNumberValueText = loading
            this.lastSeenValueText = loading
            this.profilePhotoValueText = loading
            this.bioValueText = loading
            this.giftsValueText = loading
            this.birthdayValueText = loading
            this.savedMusicValueText = loading
            this.forwardsValueText = loading
            this.groupsValueText = loading
            this.callsValueText = loading
            this.voiceMessagesValueText = loading
            this.messagesValueText = loading
            this.blockedCountValueText = ""
            this.webSessionsValueTextMirror = ""
            this.passkeysValueText = ""
            this.twoStepValueText = ""
            this.autoDeleteValueText = loading
            this.accountTtlValueText = loading
            this.loginEmailValueText = ""
            this.loginEmailFooterText = ""
            return ""
        }
        this.phoneNumberValueText = this.getPrivacyDisplayTextWithExceptions(this.phoneNumberPrivacy, this.privacyAllowCounts[0], this.privacyDisallowCounts[0], this.privacyCloseFriendsFlags[0], this.privacyPremiumFlags[0], this.privacyBotsFlags[0])
        this.lastSeenValueText = this.getPrivacyDisplayTextWithExceptions(this.lastSeenPrivacy, this.privacyAllowCounts[1], this.privacyDisallowCounts[1], this.privacyCloseFriendsFlags[1], this.privacyPremiumFlags[1], this.privacyBotsFlags[1])
        this.profilePhotoValueText = this.getPrivacyDisplayTextWithExceptions(this.profilePhotoPrivacy, this.privacyAllowCounts[2], this.privacyDisallowCounts[2], this.privacyCloseFriendsFlags[2], this.privacyPremiumFlags[2], this.privacyBotsFlags[2])
        this.bioValueText = this.getPrivacyDisplayTextWithExceptions(this.bioPrivacy, this.bioAllowCount, this.bioDisallowCount, this.bioHasCloseFriends, this.bioHasPremium, this.bioHasBots)
        this.giftsValueText = this.getPrivacyDisplayTextWithExceptions(this.giftsPrivacy, this.giftsAllowCount, this.giftsDisallowCount, this.giftsHasCloseFriends, this.giftsHasPremium, this.giftsHasBots)
        this.birthdayValueText = this.getPrivacyDisplayTextWithExceptions(this.birthdayPrivacy, this.birthdayAllowCount, this.birthdayDisallowCount, this.birthdayHasCloseFriends, this.birthdayHasPremium, this.birthdayHasBots)
        this.savedMusicValueText = this.getPrivacyDisplayTextWithExceptions(this.savedMusicPrivacy, this.savedMusicAllowCount, this.savedMusicDisallowCount, this.savedMusicHasCloseFriends, this.savedMusicHasPremium, this.savedMusicHasBots)
        this.forwardsValueText = this.getPrivacyDisplayTextWithExceptions(this.forwardsPrivacy, this.privacyAllowCounts[3], this.privacyDisallowCounts[3], this.privacyCloseFriendsFlags[3], this.privacyPremiumFlags[3], this.privacyBotsFlags[3])
        this.groupsValueText = this.getPrivacyDisplayTextWithExceptions(this.groupsPrivacy, this.privacyAllowCounts[4], this.privacyDisallowCounts[4], this.privacyCloseFriendsFlags[4], this.privacyPremiumFlags[4], this.privacyBotsFlags[4])
        this.callsValueText = this.getPrivacyDisplayTextWithExceptions(this.callsPrivacy, this.privacyAllowCounts[5], this.privacyDisallowCounts[5], this.privacyCloseFriendsFlags[5], this.privacyPremiumFlags[5], this.privacyBotsFlags[5])
        this.voiceMessagesValueText = this.getPrivacyDisplayTextWithExceptions(this.voiceMessagesPrivacy, this.privacyAllowCounts[6], this.privacyDisallowCounts[6], this.privacyCloseFriendsFlags[6], this.privacyPremiumFlags[6], this.privacyBotsFlags[6])
        this.messagesValueText = this.messagesLabel()
        this.blockedCountValueText = this.blockedCountLabel()
        this.webSessionsValueTextMirror = this.webSessionsLabel()
        this.passkeysValueText = this.passkeysLabel()
        this.twoStepValueText = this.twoStepLabel()
        this.autoDeleteValueText = this.autoDeleteLabel(this.autoDeleteSeconds)
        this.accountTtlValueText = this.ttlMonthsLabel(this.accountTtlDays)
        this.loginEmailValueText = this.loginEmailLabel()
        this.loginEmailFooterText = this.loginEmailFooterLabel()
        return ""
    }

    /**
     * round2 §6.6 入口分叉：对位源侧 PrivacyAndSecurityController.swift:1276-1305
     * `openTwoStepVerification`——先取账号 2FA 配置，`hasPassword==false &&
     * emailUnconfirmedPattern.isEmpty`（`.notSet`）时跳现代引导屏 `TwoFactorAuthSplashPage`
     * （ic_two_factor_splash_entry_wiring：该页已存在且已注册路由，TC-0141 的入口链本轮
     * 接上）；其余情形 ⇒ `TwoFactorAuthPage`（mode 初值 Access，由该页 `loadPasswordState()`
     * 自行按 config 三态分类）。边界条件：配置读取失败/异常 ⇒ 保守走 `TwoFactorAuthPage`，
     * 不卡在根屏。
     */
    private func openTwoStepVerification(): Unit {
        if (this.isCheckingTwoStepEntry) { return }
        this.isCheckingTwoStepEntry = true
        let _ = spawn {
            var notSetNoPendingEmail = false
            try {
                let authService = getRealAuthService()
                let info = authService.getPasswordInfo()
                notSetNoPendingEmail = !info.hasPassword && info.emailUnconfirmedPattern.size == 0
            } catch (_e: Exception) {
                notSetNoPendingEmail = false
            }
            let goToModernSplash = notSetNoPendingEmail

            spawn(UIThread) {
                =>
                this.isCheckingTwoStepEntry = false
                if (goToModernSplash) {
                    routerPush("TwoFactorAuthSplashPage")
                } else {
                    routerPush("TwoFactorAuthPage")
                }
            }
        }
    }

    // M2（diag-suite_settings_privacy-TC-0143-round2.md）：Login Email 三条件析取门控，
    // 对位源侧 :725-730 showLoginEmail = loginEmail != nil || user.phone.hasPrefix("7") ||
    // strings.baseLanguageCode == "ru"。
    private func showLoginEmailCard(): Bool {
        return this.loginEmailPattern.size > 0 || this.accountPhone.startsWith("7") || this.appBaseLangCode == "ru"
    }

    // M5(a)（diag-suite_settings_privacy-TC-0143-round2.md）：对位源侧 openEmailSettings
    // （PrivacyAndSecurityController.swift:1463-1479）二分支——已绑定且不含空格 ⇒ 先弹二次
    // 确认 alert（title=pattern 本身），确认才 push；否则直接 push（未绑定 setup 分支）。
    // 消息文案取 Localizable.strings:8130 PrivacySettings.LoginEmailAlertText 字面。
    private func openLoginEmailSettings(): Unit {
        if (this.loginEmailPattern.size > 0 && !this.loginEmailPattern.contains(" ")) {
            let pattern = this.loginEmailPattern
            let uiCtx = getUIContext()
            let cancelBtn = AlertDialogButtonOptions(value: "Cancel", action: {=> ()})
            let confirmBtn = AlertDialogButtonOptions(
                value: "Change Email",
                action: {=>
                    routerPush("EmailLoginPage", "{\"mode\":\"change\",\"emailPattern\":\"${pattern}\"}")
                }
            )
            // M-B（diag-suite_settings_privacy-TC-0143-round3.md §修法方向）：换用带
            // buttonDirection/textStyle 的重载，写法照抄同仓已落地先例
            // DataStorageSettingsPage.cj:638-645。buttons 顺序对位源侧 actionLayout:.vertical
            // 下 actions 数组顺序（Change 在前、Cancel 在后，PrivacyAndSecurityController.swift:
            // 1467-1474），不加 fontColor——源侧 Change 是 .defaultAction（系统默认强调色），
            // 不是 destructive 红。
            uiCtx.showAlertDialog(AlertDialogParamWithOptions(
                title: pattern,
                message: "This email address will be used every time you login to your Telegram account from a new device.",
                autoCancel: true,
                buttons: [confirmBtn, cancelBtn],
                buttonDirection: DialogButtonDirection.Vertical,
                textStyle: WordBreak.BreakWord
            ))
        } else {
            routerPush("EmailLoginPage", "{\"mode\":\"setup\"}")
        }
    }

    // ==================== If Away For — bindPopup 锚定菜单 ====================
    // diag-suite_settings_privacy-TC-0129.md M-1~M-5：同构先例 pages/DevicesPage.cj 的
    // "If Inactive For" 行（:942-988 锚定行 + :599-629 ttlMenuContent）。

    private func updateAccountTtl(days: Int32): Unit {
        let _ = spawn {
            let svc = getPrivacyEngineService()
            let _ = svc.setAccountTtlDays(days)
            spawn(UIThread) { => this.updatingAccountTtl = false }
        }
    }

    private func selectTtl(days: Int32): Unit {
        this.accountTtlDays = days          // 乐观回显
        this.updatingAccountTtl = true      // 与乐观回显同一次状态更新内置位（源侧同一个 updateState）
        this.showTtlMenu = false            // 选中即关菜单（源侧 f(.default)）
        this.updateAccountTtl(days)
    }

    /**
     * M-3：6 档 + 8vp 分隔带 + destructive「Delete Account Now」，图标位恒预留（未选中项
     * opacity(0.0) 占位而非省略节点，对位源侧 icon 闭包恒返回 UIImage()）。勾选色黑
     * （源侧 theme.contextMenu.primaryColor 实测为黑，不是 DevicesPage 那份先例用的
     * 0x0088CC accent 蓝）。
     */
    @Builder
    private func ttlMenuContent() {
        Column {
            ForEach([Int32(30), Int32(90), Int32(180), Int32(365), Int32(548), Int32(730)], itemGenerator: { days: Int32, idx: Int64 =>
                Column {
                    Row {
                        Image(@r(app.media.media_ic_check))
                            .width(18).height(18)
                            .fillColor(this.presentation.textColor)
                            .opacity(if (days == this.accountTtlDays) { 1.0 } else { 0.0 })
                            .margin(right: 10)
                        Text(this.ttlMonthsLabel(days))
                            .fontSize(17).fontColor(this.presentation.textColor)
                    }
                    .width(100.percent).height(42).padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _ => this.selectTtl(days) })

                    if (idx < 5) {
                        Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 16)
                    }
                }
            })
            Row { }.width(100.percent).height(8).backgroundColor(this.presentation.dividerColor)
            // 对位源侧 PrivacyAndSecurityController.swift:1404-1419：f(.default) 关菜单后
            // pushControllerImpl(deleteAccountOptionsController)。pages/DeleteAccountOptionsScreen.cj
            // 已落地（diag-suite_settings_privacy-TC-0129-round2.md §6 M-1），destructive 项
            // icon:{_ in nil} 不发射图标节点，与上面时长项的空图占位是源侧刻意的区别。
            Row {
                Text(trSource("Delete Account Now")).fontSize(17).fontColor(0xFF3B30)
            }
            .width(100.percent).height(42).padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .onClick({ _ => this.showTtlMenu = false; routerPush("DeleteAccountOptionsScreen", "") })
        }
        .width(220).backgroundColor(this.presentation.cardColor).borderRadius(14)
    }

    public func build() {
        Stack {
            Text(this.refreshDerivedState()).height(0).fontSize(0)

            // 容器导航栏渐显契约（uif_itemlist_core，TC-0127 §6.3-6）：列表铺满整屏 +
            // .padding(top: ITEM_LIST_NAVBAR_H)，导航栏叠在同一 Stack 上层。
            Stack(alignContent: Alignment.TopStart) {
                Scroll(this.contentScroller) {
                    Column {
                        // ══════════ CARD 1 — 安全块（无分区头）══════════
                        Column {
                            ItemListDisclosureRow(
                                title: "Blocked Users",
                                value: this.blockedCountValueText,
                                icon: @r(app.media.privacy_ic_block),
                                onClick: { => routerPush("BlacklistPage") }
                            )
                            if (this.webSessionsCount > 0) {
                                ItemListSeparator(leftInset: 61)
                                ItemListDisclosureRow(
                                    title: "Connected Websites",
                                    value: this.webSessionsValueTextMirror,
                                    icon: @r(app.media.privacy_ic_websessions),
                                    onClick: { => routerPush("WebSessionsPage") }
                                )
                            }
                            ItemListSeparator(leftInset: 61)
                            // RC-B（diag-suite_settings_privacy-TC-0127-round2.md）：Passcode
                            // Lock 并回共享行原语，与同卡另外几行完全同构（此前用自绘 Row 内联
                            // AppLockComponent 导致标题多缩进 56px 且缺 chevron）。二级设置
                            // （Auto-Lock/Biometric Unlock）已在 AppLockPage.cj 完整实现，不
                            // 丢能力，只是把入口收回它在源侧本来就该在的子屏。
                            ItemListDisclosureRow(
                                title: "Passcode Lock",
                                value: this.passcodeValueText,
                                icon: @r(app.media.privacy_ic_faceid),
                                onClick: { => routerPush("AppLockPage") }
                            )
                            ItemListSeparator(leftInset: 61)
                            ItemListDisclosureRow(
                                title: "Two-Step Verification",
                                value: this.twoStepValueText,
                                icon: @r(app.media.privacy_ic_lock),
                                onClick: { => this.openTwoStepVerification() }
                            )
                            ItemListSeparator(leftInset: 61)
                            // CG-01：对位源侧 PrivacyAndSecurityController.swift:507-510
                            // openPasskeys → PasskeysScreen（intro / 列表 + 删除 + 创建），本工程
                            // 落在 pages/PasskeysPage.cj；行值 On/Off 由 getPasskeys 真实列表派生
                            // （:697-702 hasPasskeys ? PasscodeOn : PasscodeOff），子屏改动经
                            // notifyPasskeysUpdated 回灌。
                            ItemListDisclosureRow(
                                title: "Passkeys",
                                value: this.passkeysValueText,
                                icon: @r(app.media.privacy_ic_key),
                                onClick: { => routerPush("PasskeysPage") }
                            )
                            ItemListSeparator(leftInset: 61)
                            // Auto-Delete Messages = messageAutoremoveTimeout（不是 If Away For）。
                            // 源侧（PrivacyAndSecurityController.swift:1443 setupMessageAutoremove）
                            // 只 push 子屏 GlobalAutoremoveScreen，不做就地切档/写操作。
                            // ic_privacy_global_autoremove_screen 已落地（子屏本体 + ArkTS 壳 +
                            // route_map.json 条目三件套齐备，见 diag-suite_settings_privacy-
                            // TC-0129.md §3），本行按 F-1 接线；不做任何就地写（回传见
                            // notifyGlobalAutoremoveUpdated，写入方归 feature_wiring）。
                            ItemListDisclosureRow(
                                title: "Auto-Delete Messages",
                                value: this.autoDeleteValueText,
                                icon: @r(app.media.privacy_ic_timer),
                                onClick: { => routerPush("GlobalAutoremoveScreen") }
                            )
                        }
                        .backgroundColor(this.presentation.cardColor).borderRadius(12).clip(true)
                        .margin(left: 16, right: 16, top: 16)

                        ItemListSectionFooter(text: "Automatically delete messages for everyone after a period of time in all new chats you start.")

                        // ══════════ CARD 2 — Login Email（M2 三条件析取门控）══════════
                        if (this.showLoginEmailCard()) {
                            Column {
                                ItemListDisclosureRow(
                                    title: "Login Email",
                                    value: this.loginEmailValueText,
                                    icon: @r(app.media.privacy_ic_email),
                                    onClick: { => this.openLoginEmailSettings() }
                                )
                            }
                            .backgroundColor(this.presentation.cardColor).borderRadius(12).clip(true)
                            .margin(left: 16, right: 16, top: 24)

                            ItemListSectionFooter(text: this.loginEmailFooterText)
                        }

                        // ══════════ CARD 3 — PRIVACY（12 行）══════════
                        ItemListSectionHeader(title: "PRIVACY", topPad: 24)

                        Column {
                            ItemListDisclosureRow(
                                title: "Phone Number",
                                value: this.phoneNumberValueText,
                                onClick: { => routerPush("SelectivePrivacySettingsPage", "phone_number") }
                            )
                            ItemListSeparator()
                            ItemListDisclosureRow(
                                title: this.text("PrivacySettings.LastSeen", "Last Seen"),
                                value: this.lastSeenValueText,
                                onClick: { => routerPush("SelectivePrivacySettingsPage", "last_seen") }
                            )
                            ItemListSeparator()
                            ItemListDisclosureRow(
                                title: this.text("Privacy.ProfilePhoto", "Profile Photo"),
                                value: this.profilePhotoValueText,
                                onClick: { => routerPush("SelectivePrivacySettingsPage", "profile_photo") }
                            )
                            ItemListSeparator()
                            // Bio/Gifts/Birthday/Saved Music：diag-suite_settings_privacy-
                            // E8-batch.md F-2（RC-1 根屏半）—— set_selective_privacy 已按
                            // F-1 把这四个 kind 从"未识别"变成"已识别"
                            // （SelectivePrivacySettingsPage.kindParam/keyConstructor()/
                            // computeHeaderText() 等均已补齐分支），故本轮接线，形状与上方
                            // 已接线行逐字同型。Messages 不在此列——见文件头注释。
                            ItemListDisclosureRow(
                                title: "Bio",
                                value: this.bioValueText,
                                onClick: { => routerPush("SelectivePrivacySettingsPage", "bio") }
                            )
                            ItemListSeparator()
                            ItemListDisclosureRow(
                                title: "Gifts",
                                value: this.giftsValueText,
                                onClick: { => routerPush("SelectivePrivacySettingsPage", "gifts") }
                            )
                            ItemListSeparator()
                            ItemListDisclosureRow(
                                title: this.text("Privacy.Birthday", "Date of Birth"),
                                value: this.birthdayValueText,
                                onClick: { => routerPush("SelectivePrivacySettingsPage", "birthday") }
                            )
                            ItemListSeparator()
                            ItemListDisclosureRow(
                                title: "Saved Music",
                                value: this.savedMusicValueText,
                                onClick: { => routerPush("SelectivePrivacySettingsPage", "saved_music") }
                            )
                            ItemListSeparator()
                            ItemListDisclosureRow(
                                title: "Forwarded Messages",
                                value: this.forwardsValueText,
                                onClick: { => routerPush("SelectivePrivacySettingsPage", "forwards") }
                            )
                            ItemListSeparator()
                            ItemListDisclosureRow(
                                title: "Calls",
                                value: this.callsValueText,
                                onClick: { => routerPush("SelectivePrivacySettingsPage", "calls") }
                            )
                            ItemListSeparator()
                            ItemListDisclosureRow(
                                title: "Voice Messages",
                                value: this.voiceMessagesValueText,
                                onClick: { => routerPush("SelectivePrivacySettingsPage", "voice_messages") }
                            )
                            ItemListSeparator()
                            // Messages：与上方四行不同类——源侧走 GlobalPrivacySettings.
                            // nonContactChatsPrivacy 而非 getPrivacyRules（见 messagesLabel()）。
                            // diag-suite_settings_privacy-E12-batch.md G-7（RC-E12-2 根屏半）：
                            // 详情屏 pages/IncomingMessagePrivacyPage.cj 已由 set_selective_privacy
                            // 落地（G-6），路由名 "IncomingMessagePrivacyPage" 与其注册一致，本行
                            // 接回该屏，不再误触 SelectivePrivacySettingsPage 的 kind 兜底分支。
                            ItemListDisclosureRow(
                                title: "Messages",
                                value: this.messagesValueText,
                                onClick: { => routerPush("IncomingMessagePrivacyPage", "") }
                            )
                            ItemListSeparator()
                            ItemListDisclosureRow(
                                title: "Invites",
                                value: this.groupsValueText,
                                onClick: { => routerPush("SelectivePrivacySettingsPage", "groups") }
                            )
                        }
                        .backgroundColor(this.presentation.cardColor).borderRadius(12).clip(true)
                        .margin(left: 16, right: 16)

                        ItemListSectionFooter(text: "You can restrict which users are allowed to add you to groups and channels.")

                        // ══════════ CARD 4 — AUTOMATICALLY DELETE MY ACCOUNT ══════════
                        ItemListSectionHeader(title: this.text("PrivacySettings.DeleteAccountTitle", "DELETE MY ACCOUNT"), topPad: 24)

                        Column {
                            // M-1（diag-suite_settings_privacy-TC-0129.md）：内联为本文件 Row
                            // （不用 ItemListDisclosureRow——bindPopup 须挂在右值节点上，共享
                            // 组件不在 allowlist 内），形状逐字复刻
                            // components/ItemListComponents.cj:654-723 单行分支（icon=None/
                            // badgeText=""/showChevron=true 组合）；同构先例
                            // pages/DevicesPage.cj 的 "If Inactive For" 行。
                            Row {
                                Text(trSource("If Away For"))
                                    .fontSize(17).fontColor(this.presentation.textColor).layoutWeight(1)
                                // M-2：菜单开合期间只有右值与 chevron 两个节点 alpha 0.5（对位
                                // ItemListDisclosureItem.swift:305-315 updateHasContextMenu，
                                // 源侧只碰这两个节点，标题/行底色/页面其余部分零变化，也不加
                                // 全屏压暗——源侧 .reference 呈现下页面压暗为零，双帧逐点比对
                                // 已证实）。
                                Text(this.accountTtlValueText)
                                    .fontSize(17).fontColor(this.presentation.secondaryTextColor).margin(right: 6)
                                    .opacity(if (this.showTtlMenu) { 0.5 } else { 1.0 })
                                    .bindPopup(
                                        this.showTtlMenu,
                                        CustomPopupOptions(
                                            builder: bind(this.ttlMenuContent, this),
                                            placement: Placement.Bottom,
                                            popupColor: Color.Transparent,
                                            enableArrow: false,
                                            autoCancel: true,
                                            radius: 14.vp,
                                            onStateChange: Option.Some({ evt: PopupStateChangeParam =>
                                                if (!evt.isVisible) { this.showTtlMenu = false }
                                            })
                                        )
                                    )
                                // diag-suite_settings_privacy-E8-batch.md RC-11/F-A：本行
                                // 为 bindPopup 锚定菜单手搓，绕过了 ItemListDisclosureRow，
                                // 没吃到 TC-0439-round2 已落地的矢量资源修法（组件侧
                                // components/ItemListComponents.cj:721-724），改成同一矢量
                                // 资源节点，形状逐字照抄该先例。取色读
                                // this.presentation.secondaryTextColor（TC-0541 C2）。
                                Image(@r(app.media.item_list_disclosure_arrow))
                                    .width(7).height(12)
                                    .fillColor(this.presentation.secondaryTextColor)
                                    .opacity(if (this.showTtlMenu) { 0.5 } else { 1.0 })
                            }
                            .width(100.percent).height(44).padding(left: 16, right: 16)
                            .alignItems(VerticalAlign.Center)
                            .backgroundColor(if (!this.ttlRowPressed) { Color.Transparent } else { this.presentation.itemHighlightedBackgroundColor })
                            .onClick({ _ => this.showTtlMenu = true })
                            .onTouch({ evt =>
                                match (evt.eventType) {
                                    case TouchType.Down => this.ttlRowPressed = true
                                    case TouchType.Up =>
                                        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 250, curve: Curve.EaseInOut), { =>
                                            this.ttlRowPressed = false
                                        })
                                    case _ => this.ttlRowPressed = false
                                }
                            })
                        }
                        .backgroundColor(this.presentation.cardColor).borderRadius(12).clip(true)
                        .margin(left: 16, right: 16)

                        ItemListSectionFooter(text: this.text("PrivacySettings.DeleteAccountHelp", "If you do not log in at least once within this period, your account will be deleted along with all groups, messages and contacts."))

                        // ══════════ CARD 5 — Data Settings（无分区头，RC-6）══════════
                        Column {
                            ItemListDisclosureRow(
                                title: "Data Settings",
                                value: "",
                                onClick: { => routerPush("DataPrivacySettingsPage") }
                            )
                        }
                        .backgroundColor(this.presentation.cardColor).borderRadius(12).clip(true)
                        .margin(left: 16, right: 16, top: 24)

                        ItemListSectionFooter(text: "Control which of your data is stored in the cloud and used by Telegram to enable advanced features.")

                        // ══════════ CARD 6 — Open Links in（无分区头）══════════
                        // FIX-4（diag-suite_settings_data_storage-TC-0435.md §6.4）+ round2 增量 D-1：
                        // 目标屏 pages/WebBrowserSettingsPage.cj 已于本轮（R2/R3）落地并注册进
                        // resources/base/profile/route_map.json，本行接真实路由。
                        // 右值不再是硬编码 "Safari"（那个字面量不读任何状态，是 round2 记录的
                        // 第二个失效点位，也是"入口读 Safari 而 IN-APP BROWSER 开关读 OFF"那条
                        // 矛盾的成因）：改走 webBrowserSelectionLabel()，与屏内选中勾**同一个**
                        // 取值口径（账号级 AccountWebBrowserSettings，不是 BrowserService 的本地
                        // open_external_browser 私有键）。
                        // D-125：ItemListDisclosureRow.value 是 @Prop，调用点必须传裸 @State 字段。
                        Column {
                            ItemListDisclosureRow(
                                title: "Open Links in",
                                value: this.openLinksInValueText,
                                onClick: { => routerPush("WebBrowserSettingsPage") }
                            )
                        }
                        .backgroundColor(this.presentation.cardColor).borderRadius(12).clip(true)
                        .margin(left: 16, right: 16, top: 24)

                        // CG-01：源侧本页没有 passkeys 列表卡；查看/删除/创建全部在 PasskeysPage。

                        Text(trSource("")).height(32)
                    }
                    .padding(top: ITEM_LIST_NAVBAR_H)
                }
                .width(100.percent).height(100.percent)
                .backgroundColor(this.presentation.backgroundColor)
                .onDidScroll({ _xDelta: Float64, _yDelta: Float64, _scrollState: ScrollState =>
                    let cur = this.contentScroller.currentOffset()
                    if (cur.isSome()) {
                        let off = cur.getOrThrow().yOffset
                        let target = itemListNavBarBackgroundAlpha255(off)
                        if (this.prevScrollOffsetVp >= 30.0 && off <= 0.0) {
                            safeAnimateTo({ => this.getUIContext() },
                                AnimateParam(duration: 200, curve: Curve.EaseInOut),
                                { => this.navBarAlpha255 = target })
                        } else {
                            this.navBarAlpha255 = target
                        }
                        this.prevScrollOffsetVp = off
                    }
                })

                Stack(alignContent: Alignment.TopStart) {
                    ItemListNavBarBackground(alpha255: this.navBarAlpha255)

                    Row {
                        // TC-0127-round4（diag-suite_settings_privacy-TC-0127-round4.md
                        // §6）：返回控件字形换成代码绘制的矢量折线，逐坐标对位源侧
                        // NavigationButtonNode.swift:8-23 glassBackArrowImage（44×44 画布，
                        // (24.6,14)→(17,22)→(24.6,30)，lineWidth=2，round cap/join）。坐标
                        // 换算按 vp2px 密度缩放，写法照抄同仓已落地先例
                        // pages/DevicesPage.cj:658-683 backArrowCommands()（TC-0134-round5
                        // §6.1-6.2）：ArkUI Path 的 commands 坐标按 px 消费，不随 .width/
                        // .height 的 vp 单位自动换算，漏缩放会把箭头缩到 1/density 且锚在
                        // 组件框左上角。
                        Stack {
                            Path()
                                .width(44)
                                .height(44)
                                .commands(this.backArrowCommands())
                                .fill(Color.Transparent)
                                .stroke(this.presentation.accentColor)
                                .strokeWidth(2)
                                .strokeLineCap(LineCapStyle.Round)
                                .strokeLineJoin(LineJoinStyle.Round)
                        }
                        .width(44).height(44)
                        .borderRadius(22)
                        .backgroundColor(this.presentation.cardColor)
                        .alignContent(Alignment.Center)
                        .onClick({ _ => routerPop() })
                        Blank().layoutWeight(1)
                        Text(trSource("Privacy and Security"))
                            .fontSize(18).fontWeight(FontWeight.Bold)
                            .fontColor(this.presentation.textColor)
                        Blank().layoutWeight(1)
                        // M-4（diag-suite_settings_privacy-TC-0129.md）：右槽在首屏加载中或
                        // If Away For 请求在途时显示转圈，对位源侧 :1611
                        // privacySettings == nil || state.updatingAccountTimeoutValue != nil。
                        // 只有 If Away For 这一条路径可以置 updatingAccountTtl；其它行（含
                        // Auto-Delete Messages）源侧刻意不设 updating* state，不得触发本控件。
                        Row {
                            if (!this.dataLoaded || this.updatingAccountTtl) {
                                LoadingProgress().width(20).height(20)
                            }
                        }.width(44)
                    }
                    .width(100.percent)
                    .height(ITEM_LIST_NAVBAR_H)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                }
                .width(100.percent)
                .height(ITEM_LIST_NAVBAR_H)
            }
            .width(100.percent).height(100.percent)
        }
        .width(100.percent).height(100.percent).backgroundColor(this.presentation.backgroundColor)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
