package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    getContactsService,
    setDeviceContactsSyncEnabled,
    isDeviceContactsSyncEnabled,
    getMiscSettingsStore,
    getPaymentsService,
    getRealMessageService
}
import ohos_app_cangjie_entry.components.{
    ItemListSectionHeader,
    ItemListSectionFooter,
    ItemListSeparator,
    ItemListToggleRow,
    ItemListNavBarBackground,
    itemListNavBarBackgroundAlpha255,
    ITEM_LIST_NAVBAR_H,
    ITEM_LIST_ACCENT,
    ITEM_LIST_TEXT_SECONDARY,
    ITEM_LIST_BG_GROUPED
}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.utils.safeAnimateTo
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * DataPrivacySettingsPage — 数据隐私设置屏（RC-6 修法 P4 + diag-suite_settings_privacy-
 * TC-0130.md 本轮返修）
 *
 * diag-suite_settings_privacy-round1-batch.md §10.2 P4：`Data and Storage` 行此前接错
 * 存储与流量屏；本页是它真正应接的目标——对位源侧
 * `DataPrivacySettingsController.swift`（`dataPrivacyControllerEntries` :308-334 +
 * `item()` :242-298），四个固定分区卡（CONTACTS / 无标题 Suggest Frequent Contacts 卡 /
 * CHATS / PAYMENTS / SECRET CHATS，按源 entries 顺序）+ 条件 `Bot Settings` 行。
 *
 * `Bot Settings` 行本轮未落地：源侧门控条件 `hasBotSettings` 来自
 * `context.engine.peers.botsWithBiometricState()`（"当前账号是否有带生物识别权限的
 * bot"），本工程没有对等信号源，且目标屏 `context.sharedContext.makeBotSettingsScreen`
 * 本身也未迁移——按"条件未知时默认不展示"处理，不臆造门控结果、不展示死链接。
 *
 * 三个破坏性操作各自的确认宿主（diag-...-TC-0130.md RC-2/RC-3 修正 round-1 的误读——
 * round-1 文件头曾称"源侧该行为是一次清两者，单一按钮无分别开关"，与源码相反，见下）：
 *   - Delete Synced Contacts：居中 AlertDialog，Cancel/Delete 两键横排（对位
 *     `textAlertController(title:nil, text:..., actions:[Cancel, Delete])`）。
 *   - Clear payment & shipping info：贴底 sheet，两个可分别勾选的 checkbox
 *     （Payment Info / Shipping Info）+ Clear（对位源侧两个 `ActionSheetCheckboxItem` +
 *     按勾选结果组装 flags 的 Clear 行，`payments.clearSavedInfo` 底层本身就是逐位可选的
 *     掩码，见 `core/mtproto/TLMethods.cj:PaymentsClearSavedInfo`）+ 另一张卡的 Cancel。
 *   - Delete All Cloud Drafts：贴底 sheet，单个红色确认行（无正文）+ 另一张卡的 Cancel
 *     （对位源侧单钮 `ActionSheetButtonItem`）。
 *
 * RC-1（P0，diag-...-TC-0130.md）：Suggest Frequent Contacts 开启态下开关本体禁止交互，
 * 改由整行捕获层接管点击，只弹确认框、不先自行翻转视觉——修复"Cancel 后界面显示已关闭，
 * 但设置仍是开、数据仍在被收集"的隐私状态撒谎问题。
 * RC-4：导航栏与破坏性行常态色接入本 feature 家族已落地的容器契约（同批
 * pages/PrivacySettingsPage.cj），标题串改回源串 "Data Settings"。
 */
@HybridComponentEntry
@Component
public class DataPrivacySettingsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var syncContactsEnabled: Bool = false
    @State var suggestFrequentContactsEnabled: Bool = true
    @State var secretChatLinkPreviewsEnabled: Bool = true

    @State var isDeletingContacts: Bool = false
    @State var isClearingPayment: Bool = false
    @State var isDeletingDrafts: Bool = false

    @State var toastMessage: String = ""
    @State var showToast: Bool = false

    @State var loaded: Bool = false

    // RC-2（diag-suite_settings_privacy-TC-0130.md）：Clear payment & shipping info 贴底
    // sheet 的两个可分别勾选项。
    @State var showPaymentsSheet: Bool = false
    @State var clearPaymentInfoTicked: Bool = true
    @State var clearShippingInfoTicked: Bool = true

    // RC-3：Delete All Cloud Drafts 贴底 sheet 开关。
    @State var showDraftsSheet: Bool = false

    // F-9 补充（diag-suite_settings_privacy-E8-batch.md RC-7 第二条）：Suggest Frequent
    // Contacts 锁定态捕获层的点击/拖动区分——不参与渲染，普通实例字段即可（同形状本类
    // 上方 :91 prevScrollOffsetVp 一类不驱动 UI 的记账字段，非 @State）。
    private var suggestToggleTouchStartX: Float64 = 0.0
    private var suggestToggleTouchStartY: Float64 = 0.0
    private var suggestToggleDragExceeded: Bool = false

    // ── RC-4：容器导航栏渐显契约（同批 pages/PrivacySettingsPage.cj 同一形状）──
    private var contentScroller: Scroller = Scroller()
    @State var navBarAlpha255: UInt32 = 0
    private var prevScrollOffsetVp: Float64 = 0.0

    // RC-1(P0) 改动 1-b：isDeviceContactsSyncEnabled()/getMiscSettingsStore() 三处读取全
    // 同步（Preferences 直读，无 spawn/launch），提前到 aboutToAppear()（首次 build() 之前），
    // 保证首帧构造 If/else 分支时读到的已是持久化真值，而不是 suggestFrequentContactsEnabled
    // 的初值 true。同一范式已在 pages/ArchiveSettingsPage.cj（TC-0086 round-2 F2-c）落地。
    public override func aboutToAppear(): Unit {
        this.ensureLoaded()
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.syncContactsEnabled = isDeviceContactsSyncEnabled()
        let store = getMiscSettingsStore()
        this.suggestFrequentContactsEnabled = store.getSuggestFrequentContacts()
        this.secretChatLinkPreviewsEnabled = store.getSecretChatLinkPreviews()
    }

    /**
     * TC-0130 UI-DS-1 RC-1（diag-suite_settings_privacy-TC-0130-ee94bf8c.md）：
     * 返回 chevron 的 Path 命令串。方法体逐字照抄 pages/PrivacySettingsPage.cj:272-283。
     *
     * ArkUI Path 的 commands 坐标按 px 消费，不随 .width/.height 的 vp 自动换算；
     * 漏乘 scale 会把箭头缩到 1/density 并锚在框左上角（S-138：densityPixels 须 Float64()）。
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

    private func showTemporaryToast(msg: String): Unit {
        this.toastMessage = msg
        this.showToast = true
        let _ = spawn {
            sleep(Duration.millisecond * 2000)
            spawn(UIThread) { => this.showToast = false }
        }
    }

    private func deleteSyncedContactsLabel(): String {
        if (this.isDeletingContacts) { return "Deleting..." }
        return "Delete Synced Contacts"
    }

    private func clearPaymentInfoLabel(): String {
        if (this.isClearingPayment) { return "Clearing..." }
        return "Clear payment & shipping info"
    }

    private func deleteCloudDraftsLabel(): String {
        if (this.isDeletingDrafts) { return "Deleting..." }
        return "Delete All Cloud Drafts"
    }

    // RC-4：非 in-flight 常态色改 accent 蓝（对位 ItemListActionItem.swift:171-172
    // .generic → itemAccentColor；三处调用点传的都是 .generic，不是 .destructive）。
    // in-flight 灰不变（对位 .disabled）。
    private func actionColor(inProgress: Bool): UInt32 {
        if (inProgress) { return 0x8E8E93 }
        return ITEM_LIST_ACCENT
    }

    // RC-3（diag-suite_settings_privacy-TC-0130.md）：不再传 title（源侧两处调用都是
    // textAlertController(title: nil, ...)）；buttonDirection 改 Horizontal（源侧两键横排）；
    // confirmColor 由调用点决定（Delete Synced Contacts 是 destructive 红，Suggest Frequent
    // Contacts 的 OK 是源侧 .defaultAction 蓝，不是 destructive）。
    // F3-c（diag-suite_settings_privacy-TC-0130-round2.md §6.3）：buttons 顺序改为
    // [cancelBtn, confirmBtn]，对位源侧 textAlertController(actions:[Cancel, 主操作])——
    // Cancel 在左；confirmBtn 补 style: DialogButtonStyle.Highlight，对位源侧主操作的实心
    // 强调键（cancelBtn 不传 style，保持 Default）。message/autoCancel/buttonDirection/
    // textStyle 与两个调用点的 confirmColor 取值不动。
    // F-9（diag-suite_settings_privacy-E8-batch.md RC-7）：新增 confirmIsDestructive 入参。
    // 源侧 .defaultDestructiveAction 在渲染层是「destructive 配色 + semibold」的一体化语义
    // （TextAlertController.swift:112-126），此前把它拆成「强调键底(蓝) + 只染红字」，底色
    // 承载主操作语义、字色承载破坏性语义，两者互相抵消。改为 true 时不传 style，让红底白字
    // 自己独立承载 destructive 语义（cancelBtn 同时改灰底黑字，不再是纯蓝文字无底）；false
    // 时保持现状（蓝色强调键实心胶囊），对位源侧 .defaultAction。
    private func confirmAction(
        message!: String, confirmText!: String, confirmColor!: UInt32,
        confirmIsDestructive!: Bool, onConfirm!: () -> Unit
    ): Unit {
        let uiCtx = getUIContext()
        let confirmBtn = if (confirmIsDestructive) {
            AlertDialogButtonOptions(
                value: confirmText, fontColor: 0xFFFFFFFF, backgroundColor: 0xFFFF3B30,
                action: { => onConfirm() }
            )
        } else {
            AlertDialogButtonOptions(
                value: confirmText, fontColor: confirmColor, style: DialogButtonStyle.Highlight,
                action: { => onConfirm() }
            )
        }
        // diag-suite_settings_privacy-E12-batch.md G-2（RC-E12-6）：Cancel 的灰胶囊+黑字不
        // 取决于 confirmIsDestructive——源侧 Cancel 恒为 .genericAction
        // （DataPrivacySettingsController.swift:494 与同文件 ContactsReset alert 一致），两个
        // 调用点的 Cancel 因此逐像素相同。F-9 把它误挂到了 confirm 键的语义上，这里去分支化。
        let cancelBtn = AlertDialogButtonOptions(
            value: "Cancel", fontColor: 0xFF000000, backgroundColor: 0xFFE5E5EA, action: { => () }
        )
        uiCtx.showAlertDialog(AlertDialogParamWithOptions(
            message: message,
            autoCancel: true,
            buttons: [cancelBtn, confirmBtn],
            buttonDirection: DialogButtonDirection.Horizontal,
            textStyle: WordBreak.BreakWord
        ))
    }

    private func onDeleteSyncedContacts(): Unit {
        if (this.isDeletingContacts) { return }
        this.confirmAction(
            message: "This will remove your contacts from the Telegram servers.\nIf 'Sync Contacts' is enabled, contacts will be re-synced.",
            confirmText: "Delete",
            confirmColor: 0xFF3B30,
            confirmIsDestructive: true,
            onConfirm: {=>
                this.isDeletingContacts = true
                setDeviceContactsSyncEnabled(false)
                this.syncContactsEnabled = false
                let _ = spawn {
                    let ok = getContactsService().deleteAllContacts()
                    Hilog.info(0, "CjTelegram", "[DataPrivacy] deleteAllContacts ok=${ok}")
                    spawn(UIThread) {
                        =>
                        this.isDeletingContacts = false
                        if (ok) {
                            this.showTemporaryToast("All synced contacts deleted.")
                        }
                    }
                }
            }
        )
    }

    private func onToggleSyncContacts(enabled: Bool): Unit {
        this.syncContactsEnabled = enabled
        setDeviceContactsSyncEnabled(enabled)
    }

    // RC-1(P0) 改动 1-c：函数体不动——ON 态经捕获层以 false 进入，OFF 态经 onChange 以 true
    // 进入，语义与源侧 :484-501 的 if !value { 弹框 } else { apply() } 逐支对齐。
    // F-9 补充（diag-suite_settings_privacy-E8-batch.md RC-7 第二条）：ON 态这条 !enabled
    // 分支的触发源是 ItemListToggleRow 的 onActivatedWhileDisabled 捕获层（
    // components/ItemListComponents.cj，不在本 feature allowlist）——它对命中区域内任何
    // 完成的触点一律视为激活，不像源侧真实 UISwitch 那样按拖动是否越过阈值分流（源侧
    // DataPrivacySettingsController.swift:484-501 只在 updated: 真正产生新值时才进入
    // if !value 分支，拖动不越阈值不触发）。既不能改共享组件，改在本页用 onTouch 记录位移
    // （见 suggestToggleDragExceeded 字段与下方 build() 内 onTouch 挂载），越过阈值判定为
    // 拖动意图而非点击，直接吞掉本次回调、不弹确认框。
    private func onToggleSuggestFrequentContacts(enabled: Bool): Unit {
        if (!enabled) {
            if (this.suggestToggleDragExceeded) {
                this.suggestToggleDragExceeded = false
                return
            }
            // 对位源侧：关闭时先警示会清空最近联系人数据，OK 才真正生效。
            this.confirmAction(
                message: "This will delete all data about the people you message frequently as well the inline bots you are likely to use.",
                confirmText: "OK",
                confirmColor: ITEM_LIST_ACCENT,
                confirmIsDestructive: false,
                onConfirm: {=>
                    this.suggestFrequentContactsEnabled = false
                    getMiscSettingsStore().saveSuggestFrequentContacts(false)
                }
            )
        } else {
            this.suggestFrequentContactsEnabled = true
            getMiscSettingsStore().saveSuggestFrequentContacts(true)
        }
    }

    private func onToggleSecretChatLinkPreviews(enabled: Bool): Unit {
        this.secretChatLinkPreviewsEnabled = enabled
        getMiscSettingsStore().saveSecretChatLinkPreviews(enabled)
    }

    // RC-2 改动 2-c：职责改为重置勾选态 + 打开贴底 sheet（对位源侧每次 var values = [true,
    // true] 重新起算），真正的清除动作在 performClearPaymentInfo()。
    private func onClearPaymentInfo(): Unit {
        if (this.isClearingPayment) { return }
        this.clearPaymentInfoTicked = true
        this.clearShippingInfoTicked = true
        this.showPaymentsSheet = true
    }

    private func performClearPaymentInfo(): Unit {
        this.showPaymentsSheet = false
        this.isClearingPayment = true
        let paymentTicked = this.clearPaymentInfoTicked
        let shippingTicked = this.clearShippingInfoTicked
        let _ = spawn {
            let ok = getPaymentsService().clearSavedInfo(paymentInfo: paymentTicked, shippingInfo: shippingTicked)
            Hilog.info(0, "CjTelegram", "[DataPrivacy] clearSavedInfo ok=${ok}")
            spawn(UIThread) {
                =>
                this.isClearingPayment = false
                if (ok) {
                    this.showTemporaryToast("Payment and shipping info cleared.")
                }
            }
        }
    }

    private func onDeleteCloudDrafts(): Unit {
        if (this.isDeletingDrafts) { return }
        this.showDraftsSheet = true
    }

    private func performDeleteCloudDrafts(): Unit {
        this.showDraftsSheet = false
        this.isDeletingDrafts = true
        let _ = spawn {
            let ok = getRealMessageService().clearCloudDrafts()
            Hilog.info(0, "CjTelegram", "[DataPrivacy] clearCloudDrafts ok=${ok}")
            spawn(UIThread) {
                =>
                this.isDeletingDrafts = false
                if (ok) {
                    this.showTemporaryToast("All cloud drafts deleted.")
                }
            }
        }
    }

    // RC-2 改动 2-c：贴底 sheet 内容，两行可分别勾选 + Clear（两项都未勾选时置灰且不挂
    // onClick，对位源侧 :374-376）+ 另一张卡的 Cancel。
    @Builder
    func buildPaymentsSheet() {
        Column {
            Column {
                Row {
                    if (this.clearPaymentInfoTicked) {
                        Image(@r(app.media.media_ic_check)).width(20).height(20).fillColor(ITEM_LIST_ACCENT).margin(right: 10)
                    }
                    Text(trSource("Payment Info")).fontSize(17).fontColor(0x000000).layoutWeight(1)
                }
                .width(100.percent).height(50).padding(left: 16, right: 16)
                .alignItems(VerticalAlign.Center)
                .onClick({ _ => this.clearPaymentInfoTicked = !this.clearPaymentInfoTicked })

                ItemListSeparator()

                Row {
                    if (this.clearShippingInfoTicked) {
                        Image(@r(app.media.media_ic_check)).width(20).height(20).fillColor(ITEM_LIST_ACCENT).margin(right: 10)
                    }
                    Text(trSource("Shipping Info")).fontSize(17).fontColor(0x000000).layoutWeight(1)
                }
                .width(100.percent).height(50).padding(left: 16, right: 16)
                .alignItems(VerticalAlign.Center)
                .onClick({ _ => this.clearShippingInfoTicked = !this.clearShippingInfoTicked })

                ItemListSeparator()

                Row {
                    Text(trSource("Clear"))
                        .fontSize(17)
                        .fontColor(if (this.clearPaymentInfoTicked || this.clearShippingInfoTicked) { ITEM_LIST_ACCENT } else { ITEM_LIST_TEXT_SECONDARY })
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                }
                .width(100.percent).height(50).padding(left: 16, right: 16)
                .alignItems(VerticalAlign.Center)
                .onClick({ _ =>
                    if (this.clearPaymentInfoTicked || this.clearShippingInfoTicked) {
                        this.performClearPaymentInfo()
                    }
                })
            }
            .backgroundColor(0xFFFFFF).borderRadius(12).clip(true).margin(left: 8, right: 8, top: 8)

            Column {
                Row {
                    Text(trSource("Cancel")).fontSize(17).fontColor(ITEM_LIST_ACCENT).layoutWeight(1).textAlign(TextAlign.Center)
                }
                .width(100.percent).height(50).padding(left: 16, right: 16)
                .alignItems(VerticalAlign.Center)
                .onClick({ _ => this.showPaymentsSheet = false })
            }
            .backgroundColor(0xFFFFFF).borderRadius(12).clip(true).margin(left: 8, right: 8, top: 8, bottom: 8)
        }
        .width(100.percent)
        // F3-b（diag-suite_settings_privacy-TC-0130-round2.md）：源侧两组 item group 是浮在
        // 被压暗页面上的两张独立圆角卡，没有灰色底板；两张内层卡自身的 0xFFFFFF +
        // borderRadius(12) + margin 不动。
        .backgroundColor(Color.Transparent)
    }

    // RC-3：贴底 sheet，单个红色确认行（无正文，对位源侧单钮 ActionSheetButtonItem）+
    // 另一张卡的 Cancel。
    @Builder
    func buildDraftsSheet() {
        Column {
            Column {
                Row {
                    Text(trSource("Delete All Cloud Drafts")).fontSize(17).fontColor(0xFF3B30).layoutWeight(1).textAlign(TextAlign.Center)
                }
                .width(100.percent).height(50).padding(left: 16, right: 16)
                .alignItems(VerticalAlign.Center)
                .onClick({ _ => this.performDeleteCloudDrafts() })
            }
            .backgroundColor(0xFFFFFF).borderRadius(12).clip(true).margin(left: 8, right: 8, top: 8)

            Column {
                Row {
                    Text(trSource("Cancel")).fontSize(17).fontColor(ITEM_LIST_ACCENT).layoutWeight(1).textAlign(TextAlign.Center)
                }
                .width(100.percent).height(50).padding(left: 16, right: 16)
                .alignItems(VerticalAlign.Center)
                .onClick({ _ => this.showDraftsSheet = false })
            }
            .backgroundColor(0xFFFFFF).borderRadius(12).clip(true).margin(left: 8, right: 8, top: 8, bottom: 8)
        }
        .width(100.percent)
        // F3-b（同上）：drafts sheet 同样去掉灰色底板。
        .backgroundColor(Color.Transparent)
    }

    // F2-a（diag-suite_settings_privacy-TC-0130-round2.md §6.2）：`.bindSheet` 一个节点
    // 只有一个 sheet 槽（SDK 声明为 "Binds **a** sheet page to the component"，单数）——
    // payments 与 drafts 两条链之前挂在同一个最外层 Stack 上，后声明的 drafts 覆盖了
    // payments，宿主槽位被吃掉。新增一层只为 payments 提供槽位的外层 Stack，原最外层
    // Stack（含其内容与 drafts 的 bindSheet）整体不动地降一级、成为该外层 Stack 的唯一
    // 子节点。新外层 Stack 不设 backgroundColor（保持透明），确保视觉零变化。
    public func build() {
        Stack {
        Stack {
            Stack(alignContent: Alignment.TopStart) {
                Scroll(this.contentScroller) {
                    Column {
                        // ── CONTACTS ──
                        ItemListSectionHeader(title: "CONTACTS")
                        Column {
                            Row {
                                Text(this.deleteSyncedContactsLabel())
                                    .fontSize(17)
                                    .fontColor(this.actionColor(this.isDeletingContacts))
                                    .layoutWeight(1)
                            }
                            .width(100.percent).height(44)
                            .padding(left: 16, right: 16)
                            .alignItems(VerticalAlign.Center)
                            .onClick({ _evt => this.onDeleteSyncedContacts() })
                            ItemListSeparator()
                            ItemListToggleRow(
                                title: "Sync Contacts",
                                isOn: this.syncContactsEnabled,
                                onChange: { isOn: Bool => this.onToggleSyncContacts(isOn) }
                            )
                        }
                        .backgroundColor(0xFFFFFF).borderRadius(12).clip(true).margin(left: 16, right: 16)

                        ItemListSectionFooter(text: "Turn on to continuously sync contacts from this device with your account.")

                        // ── Suggest Frequent Contacts（源侧无分区头，独立卡）──
                        // RC-1(P0)：两个源码位置不同的 if/else 分支迫使 ArkUI-Cangjie 按
                        // branchId 重建子树，是本工程唯一验证过的强制刷新普通 var
                        // （enableInteractiveChanges）手段（dev_pattern.md D-160）。
                        Column {
                            if (this.suggestFrequentContactsEnabled) {
                                ItemListToggleRow(
                                    title: "Suggest Frequent Contacts",
                                    isOn: this.suggestFrequentContactsEnabled,
                                    enableInteractiveChanges: false,
                                    onActivatedWhileDisabled: { => this.onToggleSuggestFrequentContacts(false) }
                                )
                            } else {
                                ItemListToggleRow(
                                    title: "Suggest Frequent Contacts",
                                    isOn: this.suggestFrequentContactsEnabled,
                                    enableInteractiveChanges: true,
                                    onChange: { isOn: Bool => this.onToggleSuggestFrequentContacts(isOn) }
                                )
                            }
                        }
                        .backgroundColor(0xFFFFFF).borderRadius(12).clip(true).margin(left: 16, right: 16, top: 24)
                        // F-9 补充（RC-7 第二条）：记录本卡范围内的触点位移，供
                        // onToggleSuggestFrequentContacts() 区分点击/拖动意图（见该函数
                        // 与 suggestToggleDragExceeded 字段处注释）。只记录，不拦截、不
                        // 消费事件，锁定态捕获层与非锁定态真实 Toggle 的既有交互逐字不变。
                        .onTouch({ evt =>
                            match (evt.eventType) {
                                case TouchType.Down =>
                                    if (evt.touches.size > 0) {
                                        this.suggestToggleTouchStartX = evt.touches[0].x
                                        this.suggestToggleTouchStartY = evt.touches[0].y
                                    }
                                    this.suggestToggleDragExceeded = false
                                case TouchType.Move =>
                                    if (evt.touches.size > 0) {
                                        let dx = evt.touches[0].x - this.suggestToggleTouchStartX
                                        let dy = evt.touches[0].y - this.suggestToggleTouchStartY
                                        if (dx * dx + dy * dy > 100.0) {
                                            this.suggestToggleDragExceeded = true
                                        }
                                    }
                                case _ => ()
                            }
                        })

                        ItemListSectionFooter(text: "Display people you message frequently at the top of the search section for quick access.")

                        // ── CHATS ──
                        ItemListSectionHeader(title: "CHATS", topPad: 24)
                        Column {
                            Row {
                                Text(this.deleteCloudDraftsLabel())
                                    .fontSize(17)
                                    .fontColor(this.actionColor(this.isDeletingDrafts))
                                    .layoutWeight(1)
                            }
                            .width(100.percent).height(44)
                            .padding(left: 16, right: 16)
                            .alignItems(VerticalAlign.Center)
                            .onClick({ _evt => this.onDeleteCloudDrafts() })
                        }
                        .backgroundColor(0xFFFFFF).borderRadius(12).clip(true).margin(left: 16, right: 16)

                        // ── PAYMENTS ──
                        ItemListSectionHeader(title: "PAYMENTS", topPad: 24)
                        Column {
                            Row {
                                Text(this.clearPaymentInfoLabel())
                                    .fontSize(17)
                                    .fontColor(this.actionColor(this.isClearingPayment))
                                    .layoutWeight(1)
                            }
                            .width(100.percent).height(44)
                            .padding(left: 16, right: 16)
                            .alignItems(VerticalAlign.Center)
                            .onClick({ _evt => this.onClearPaymentInfo() })
                        }
                        .backgroundColor(0xFFFFFF).borderRadius(12).clip(true).margin(left: 16, right: 16)

                        ItemListSectionFooter(text: "You can delete your shipping info and instruct all payment providers to remove your saved credit cards. Note that Telegram never stores your credit card data.")

                        // ── SECRET CHATS ──
                        ItemListSectionHeader(title: "SECRET CHATS", topPad: 24)
                        Column {
                            ItemListToggleRow(
                                title: "Link Previews",
                                isOn: this.secretChatLinkPreviewsEnabled,
                                onChange: { isOn: Bool => this.onToggleSecretChatLinkPreviews(isOn) }
                            )
                        }
                        .backgroundColor(0xFFFFFF).borderRadius(12).clip(true).margin(left: 16, right: 16)

                        ItemListSectionFooter(text: "Link previews will be generated on Telegram servers. We do not store data about the links you send.")

                        Text(trSource("")).height(32)
                    }
                    .padding(top: ITEM_LIST_NAVBAR_H)
                }
                .width(100.percent).height(100.percent)
                .backgroundColor(0xF2F2F7)
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

                // RC-4（diag-suite_settings_privacy-TC-0130.md）：接入本 feature 家族已落地
                // 的容器导航栏契约（同批 pages/PrivacySettingsPage.cj:934-960 同一形状），
                // 消掉蓝色文字 "Back" + 不透明白条两条不符；标题串改回源串 "Data Settings"
                // （Localizable.strings:3601，与源应用渲染一致）。
                Stack(alignContent: Alignment.TopStart) {
                    ItemListNavBarBackground(alpha255: this.navBarAlpha255)

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
                        .onClick({ _ => routerPop() })
                        Blank().layoutWeight(1)
                        Text(trSource("Data Settings"))
                            .fontSize(18).fontWeight(FontWeight.Bold)
                        Blank().layoutWeight(1)
                        Row { }.width(44)
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

            if (this.showToast) {
                Text(this.toastMessage)
                    .fontSize(14)
                    .fontColor(0xFFFFFF)
                    .backgroundColor(0xCC333333)
                    .padding(left: 16, right: 16, top: 8, bottom: 8)
                    .borderRadius(8)
                    .position(x: 0, y: 0)
                    .margin(top: 600)
                    .width(100.percent)
                    .textAlign(TextAlign.Center)
            }
        }
        .width(100.percent).height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        // F3-a（同上报告 §6.3）：drafts sheet 的 chrome 参数——height/preferType/showClose/
        // dragBar 之前全留 None 取 ArkUI 默认（近满屏 + 系统 X + 拖拽带），改为 FitContent +
        // Bottom + 关闭 X/拖拽带；maskColor 保持不传（ArkUI 默认遮罩对位源侧的 dim 层）；
        // detents 保持不传（只用 height，两者同传会互相覆盖）。backgroundColor:
        // Color.Transparent 必须用该常量，不得写 0x00xxxxxx 数值字面量（D-144：首字节为 0
        // 的数值颜色会被强制补 alpha=FF）。
        .bindSheet(this.showDraftsSheet, this.buildDraftsSheet, options: SheetOptions(
            backgroundColor: Color.Transparent,
            onDisappear: { => launch { this.showDraftsSheet = false } },
            height: SheetSize.FitContent,
            preferType: SheetType.Bottom,
            showClose: false,
            dragBar: false
        ))
        .onAppear({ => this.ensureLoaded() })
        }
        .width(100.percent).height(100.percent)
        // F3-a：payments sheet 同款 chrome 参数，理由同上。
        .bindSheet(this.showPaymentsSheet, this.buildPaymentsSheet, options: SheetOptions(
            backgroundColor: Color.Transparent,
            onDisappear: { => launch { this.showPaymentsSheet = false } },
            height: SheetSize.FitContent,
            preferType: SheetType.Bottom,
            showClose: false,
            dragBar: false
        ))
    }
}
