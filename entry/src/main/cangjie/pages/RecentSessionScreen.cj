package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.components.ItemListToggleRow

/**
 * RecentSessionScreen — 会话详情屏（TC-0135 A8）（混合工程迁移版）
 *
 * 对位源侧 RecentSessionScreen.swift:1178（RecentSessionScreen(context:subject:...)），
 * 本轮只实现 `.session` 一种 subject（`.connectedBot` 需 business bot、`.website` 需网站
 * 数据，两者在本账号下源侧同样不装配，随对应 case 另排——见
 * diag-suite_settings_privacy-TC-0135-0136-0137-round2.md §8.1 item1）。
 *
 * 路由注册：route_map.json "RecentSessionScreen"（非模态 push，不进
 * router/router.cj isModalRoute 与 ets/router/CustomTransition.ets MODAL_ROUTES——
 * diag-suite_settings_data_storage-TC-0435.md §231）。
 *
 * 路由参数格式（"|" 分隔字符串，经 ParamStore takePending 取回，与
 * DevicesPage.sessionRouteParam 字段口径一一对应）：
 *   "hash|isCurrent(1/0)|deviceModel|platform|systemVersion|appName|appVersion|country|dateActive"
 *
 * 调用链：DevicesPage.cj 当前会话行 + 其它会话行 onClick
 *   → routerPush("RecentSessionScreen", sessionRouteParam(device))
 *   → ensureLoaded()（.onAppear 触发）→ takePending("RecentSessionScreen") → parseRouteParam(raw)
 *
 * 屏内元素与源侧对位（case TC-0135 A1–A7，取值来源与 DevicesPage.cj 顶层共享格式化函数
 * 保持同一套口径，不另写一份格式化——见该文件顶部「包级共享格式化函数」注释）：
 *   A2 左上关闭按钮：真实矢量 nav_ic_close（非模态 push 天然无下滑关闭手势，满足 A1）。
 *   A3 顶部 92x92 图标块：圆角 20 + deviceIconTint 底色 + 通用矢量图形（品牌 Lottie/矢量集
 *      不在目标资源树，见已知限制）。
 *   A4 标题 = deviceModel；副标题 = activityLabel(device)（当前设备落 "online" 分支）。
 *   A5 Application / Location 两行 + 脚注。
 *   A7 底部终止按钮仅 !isCurrent 时装配，走与 DevicesPage 详情行左滑同一个
 *      ConfirmActionOverlay 组件（同包直接复用，不新造）。
 *
 * 已知限制：A6「Accept on This Device」开关分区本轮不装配——需要 AuthorizationInfo 新增
 * apiId/passwordPending/encryptedRequestsDisabled/callRequestsDisabled 字段，只能从
 * core/mtproto/TLResponses.cj 补齐解析，该文件不在本 feature 当前 allowlist 内。
 */
@HybridComponentEntry
@Component
public class RecentSessionScreen {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var loaded: Bool = false
    @State var hash: Int64 = 0
    @State var isCurrent: Bool = false
    @State var deviceModel: String = ""
    @State var platform: String = ""
    @State var systemVersion: String = ""
    @State var appName: String = ""
    @State var appVersion: String = ""
    @State var country: String = ""
    @State var dateActive: Int32 = 0
    @State var showTerminateConfirm: Bool = false
    // S7-133: "Accept on This Device" (RecentSessionScreen.swift:110-115, 961-1020): shown
    // unless the session is password-pending or apiId 22; the secret-chat row is absent for
    // apiId 2040/2496.
    @State var apiId: Int32 = 0
    @State var passwordPending: Bool = false
    @State var allowSecretChats: Bool = false
    @State var allowIncomingCalls: Bool = false

    // M10（diag-suite_settings_privacy-TC-0135.md §7）：交互式下拖关闭。
    private let panelScroller: Scroller = Scroller()
    @State var dragOffsetVp: Float64 = 0.0      // 面板跟手位移，向下为正
    @State var dragTracking: Bool = false       // 已进入交互式关闭
    @State var dragStartY: Float64 = 0.0        // Down 时的 screenY
    @State var dragStartX: Float64 = 0.0        // Down 时的 screenX
    @State var lastMoveY: Float64 = 0.0         // 上一个 Move 采样的 screenY
    @State var lastMoveTs: Int64 = 0            // 上一个 Move 采样的 TouchEvent.timestamp（ns）

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let raw = takePending("RecentSessionScreen")
        if (raw.size == 0 || raw == "{}") { return }
        this.parseRouteParam(raw)
    }

    private func parseRouteParam(raw: String): Unit {
        let parts = raw.split("|")
        if (parts.size >= 1) { this.hash = this.parseInt64(parts[0]) }
        if (parts.size >= 2) { this.isCurrent = parts[1] == "1" }
        if (parts.size >= 3) { this.deviceModel = parts[2] }
        if (parts.size >= 4) { this.platform = parts[3] }
        if (parts.size >= 5) { this.systemVersion = parts[4] }
        if (parts.size >= 6) { this.appName = parts[5] }
        if (parts.size >= 7) { this.appVersion = parts[6] }
        if (parts.size >= 8) { this.country = parts[7] }
        if (parts.size >= 9) { this.dateActive = Int32(this.parseInt64(parts[8])) }
        if (parts.size >= 10) { this.apiId = Int32(this.parseInt64(parts[9])) }
        if (parts.size >= 11) { this.passwordPending = parts[10] == "1" }
        if (parts.size >= 12) { this.allowSecretChats = parts[11] != "1" }
        if (parts.size >= 13) { this.allowIncomingCalls = parts[12] != "1" }
        Hilog.info(0, "CjTelegram", "[RecentSessionScreen] loaded hash=${this.hash} current=${this.isCurrent}")
    }

    private func parseInt64(s: String): Int64 {
        var result: Int64 = 0
        var negative = false
        var start: Int64 = 0
        let runes = s.toRuneArray()
        if (runes.size > 0 && runes[0] == r'-') {
            negative = true
            start = 1
        }
        var i = start
        while (i < Int64(runes.size)) {
            let d = Int64(UInt32(runes[i])) - 48
            if (d < 0 || d > 9) { break }
            result = result * 10 + d
            i = i + 1
        }
        if (negative) { return -result }
        return result
    }

    // 把已解析的裸字段重建成 AuthorizationInfo，调 DevicesPage.cj 顶层共享的 activityLabel()
    // ——严格复用同一套函数，不重新实现分支语义（round2 §8.1 item2 硬约束）。
    private func toDeviceRecord(): AuthorizationInfo {
        let info = AuthorizationInfo()
        info.isCurrent = this.isCurrent
        info.hash = this.hash
        info.deviceModel = this.deviceModel
        info.platform = this.platform
        info.systemVersion = this.systemVersion
        info.appName = this.appName
        info.appVersion = this.appVersion
        info.country = this.country
        info.dateActive = this.dateActive
        return info
    }

    // A7：底部终止按钮走的确认层与 DevicesPage 列表行左滑 reveal 面板同一个入口
    // （ConfirmActionOverlay，本文件不重新声明，直接用同包 DevicesPage.cj 里的定义）。
    // 确认后直接调用服务层 terminateSession（本页是独立实例，不依赖 DevicesPage 是否仍挂载），
    // 成功后 routerPop() 回列表——对位源侧 removeSessionImpl 成功后关闭详情弹层。
    private func terminateSession(): Unit {
        this.showTerminateConfirm = false
        let hashVal = this.hash
        let _ = spawn {
            var ok = false
            try {
                ok = getPrivacyEngineService().terminateSession(hashVal)
                Hilog.info(0, "CjTelegram", "[RecentSessionScreen] terminateSession result=${ok}")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[RecentSessionScreen] terminateSession error")
            }
            let success = ok
            launch {
                if (success) {
                    routerPop()
                }
            }
        }
    }

    private func showsAcceptOptions(): Bool {
        return !this.passwordPending && this.apiId != 22
    }

    private func showsSecretChatsOption(): Bool {
        return this.showsAcceptOptions() && this.apiId != 2040 && this.apiId != 2496
    }

    /**
     * iOS updateAcceptSecretChats / updateAcceptIncomingCalls →
     * account.changeAuthorizationSettings (RecentAccountSessions.swift:77/87):
     * encrypted_requests_disabled / call_requests_disabled = !accepts.
     */
    private func updateAccept(secretChats: Bool, value: Bool): Unit {
        if (secretChats) { this.allowSecretChats = value } else { this.allowIncomingCalls = value }
        let hashVal = this.hash
        let _ = spawn {
            let ok = getPrivacyEngineService().changeSessionSettings(
                hashVal, false,
                secretChats, !value,
                !secretChats, !value)
            launch {
                if (!ok) {
                    if (secretChats) { this.allowSecretChats = !value } else { this.allowIncomingCalls = !value }
                }
            }
        }
    }

    public func build() {
        // diag-suite_settings_privacy-TC-0135.md §8 M1：对位源 RecentSessionScreen.swift:1215
        // .flatModal + ResizableSheetComponent——压暗设备屏 + 底部面板，不整屏推屏。
        // 最外层 Stack 不设 backgroundColor（保持透明，让下层 DevicesPage 透出）。
        Stack(alignContent: Alignment.Bottom) {
            Column {
                // A2：左上关闭按钮，真实矢量（非 "✕"/"X" 字形顶替）。M2：44vp 玻璃圆钮 +
                // 白色圆托盘（源 RecentSessionScreen.swift:1104-1118 GlassBarButtonComponent
                // 44x44 包 Navigation/Close 30x30pt）。
                Row {
                    Stack(alignContent: Alignment.Center) {
                        Image(@r(app.media.nav_ic_close))
                            .width(30)
                            .height(30)
                            .fillColor(0x8E8E93)
                    }
                    .width(44)
                    .height(44)
                    .borderRadius(22)
                    .backgroundColor(0xFFFFFFFF)
                    .onClick({ evt => routerPop() })

                    Blank()
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 12, bottom: 4)
                .alignItems(VerticalAlign.Center)

                Scroll(this.panelScroller) {
                    Column {
                        // A3：顶部 92x92 图标块，与列表行（DevicesPage.cj:1088-1108）同一套
                        // deviceIconAsset/deviceIconIsWhiteGlyph/deviceIconTint 分支表——源侧
                        // 详情屏与列表行调的是同一个 iconForSession()（RecentSessionScreen.swift:309
                        // 与 ItemListRecentSessionItem.swift:310），本页不得另抄一份分支。
                        // diag-suite_settings_privacy-TC-0135.md §8 M3。
                        if (deviceIconIsWhiteGlyph(this.platform, this.deviceModel, this.systemVersion)) {
                            Column {
                                Image(deviceIconAsset(this.platform, this.deviceModel, this.systemVersion))
                                    .width(92)
                                    .height(92)
                                    .fillColor(0xFFFFFFFF)
                            }
                            .width(92)
                            .height(92)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                            .backgroundColor(deviceIconTint(this.platform, this.deviceModel, this.systemVersion))
                            .borderRadius(20)
                            .margin(top: 8, bottom: 16)
                        } else {
                            Image(deviceIconAsset(this.platform, this.deviceModel, this.systemVersion))
                                .width(92)
                                .height(92)
                                .borderRadius(20)
                                .margin(top: 8, bottom: 16)
                        }

                        // A4：标题 = deviceModel，最多 2 行。
                        Text(this.deviceModel)
                            .fontSize(24)
                            .fontWeight(FontWeight.Bold)
                            .textAlign(TextAlign.Center)
                            .maxLines(2)
                            .width(100.percent)
                            .padding(left: 24, right: 24)

                        // 副标题：当前设备 → activityLabel 的 "online" 分支（强调色）；
                        // 否则 → 相对活跃时间（次色）。严格调同一个 activityLabel()，
                        // 不在本页重新分支判断 isCurrent。
                        Text(activityLabel(this.toDeviceRecord()))
                            .fontSize(15)
                            .fontColor(if (this.isCurrent) { 0x0088CC } else { 0x8E8E93 })
                            .margin(top: 4, bottom: 24)

                        // A5：Application / Location 两行。diag-...-TC-0135.md §8 M4：源侧两行都是
                        // ListActionItemComponent，标题 maximumNumberOfLines:1，右值 accessory 右对齐、
                        // insets(left:8, right:14)——去掉 Blank()，值改 layoutWeight(1) 右对齐 + 省略。
                        Column {
                            Row {
                                Text(trSource("Application"))
                                    .fontSize(17)
                                    .fontColor(0x000000)
                                    .maxLines(1)
                                Text(this.appName + " " + cleanAppVersion(this.appVersion))
                                    .fontSize(17)
                                    .fontColor(0x8E8E93)
                                    .layoutWeight(1)
                                    .textAlign(TextAlign.End)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                                    .margin(left: 8)
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 12, bottom: 12)
                            .alignItems(VerticalAlign.Center)
                            .constraintSize(minHeight: 52)

                            Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16, right: 16)

                            Row {
                                Text(trSource("Location"))
                                    .fontSize(17)
                                    .fontColor(0x000000)
                                    .maxLines(1)
                                Text(trimmedLocation(this.country))
                                    .fontSize(17)
                                    .fontColor(0x8E8E93)
                                    .layoutWeight(1)
                                    .textAlign(TextAlign.End)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                                    .margin(left: 8)
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 12, bottom: 12)
                            .alignItems(VerticalAlign.Center)
                            .constraintSize(minHeight: 52)
                        }
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(12)
                        .margin(left: 16, right: 16)

                        Row {
                            Text(trSource("This location estimate is based on the IP address and may not always be accurate."))
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16)
                        .margin(top: 8, bottom: 32)

                        // S7-133: ACCEPT ON THIS DEVICE (New Secret Chats / Incoming Calls).
                        if (this.showsAcceptOptions()) {
                            Text(trSource("Accept on This Device").toAsciiUpper())
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .width(100.percent)
                                .padding(left: 32, right: 16)
                                .margin(bottom: 6)
                            Column {
                                if (this.showsSecretChatsOption()) {
                                    ItemListToggleRow(
                                        title: trSource("New Secret Chats"),
                                        isOn: this.allowSecretChats,
                                        onChange: { v: Bool => this.updateAccept(true, v) }
                                    )
                                    Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16, right: 16)
                                }
                                ItemListToggleRow(
                                    title: trSource("Incoming Calls"),
                                    isOn: this.allowIncomingCalls,
                                    onChange: { v: Bool => this.updateAccept(false, v) }
                                )
                            }
                            .backgroundColor(0xFFFFFF)
                            .borderRadius(12)
                            .clip(true)
                            .margin(left: 16, right: 16, bottom: 32)
                        }

                        // A7：!isCurrent 时才装配底部终止按钮；当前设备详情屏没有该按钮。
                        // diag-...-TC-0135.md §8 M5：源侧实测 x=30 y=792 w=342 h=52（屏宽 402 ⇒
                        // 左右各 30vp）+ 整宽 pill。内缩必须由外层 padding 承担，不能给带
                        // width(100%) 的 Row 加水平 margin——那正是当前 bug 的成因。
                        if (!this.isCurrent) {
                            Column {
                                Row {
                                    Text(trSource("Terminate Session"))
                                        .fontSize(17)
                                        // D-113：FontWeight.SemiBold 不存在，改用 FontWeight.Medium。
                                        .fontWeight(FontWeight.Medium)
                                        .fontColor(0xFFFFFFFF)
                                }
                                .width(100.percent)
                                .height(52)
                                .justifyContent(FlexAlign.Center)
                                .alignItems(VerticalAlign.Center)
                                .backgroundColor(0xFF3B30)
                                .borderRadius(26)
                                .onClick({ evt =>
                                    this.showTerminateConfirm = true
                                })
                            }
                            .width(100.percent)
                            .padding(left: 30, right: 30)
                            .margin(bottom: 24)
                        }
                    }
                    .width(100.percent)
                    .alignItems(HorizontalAlign.Center)
                }
                .layoutWeight(1)
                .enableScrollInteraction(!this.dragTracking)
            }
            .width(100.percent)
            // diag-...-TC-0135.md §8 M1：面板占 72%（源侧 sheet 顶边实测 pt 240.3 / 屏高 874 =
            // 27.5% ⇒ 72.5%，取整 72）。A6 开关分区将来补上后仍是 72%，不做内容自适应。
            .height(72.percent)
            .backgroundColor(0xF2F2F7)
            .borderRadius(topLeft: 10, topRight: 10)
            .clip(true)
            // 面板顶边已在状态栏下方 240pt 处，顶部安全区补偿会多顶出一段空白，故只留 bottom。
            .padding(bottom: getSafeAreaBottom())
            .translate(y: this.dragOffsetVp)
            .animation(AnimateParam(duration: if (this.dragTracking) { 0 } else { 200 }, curve: Curve.EaseInOut))
            .onTouch({ evt: TouchEvent => this.onPanelTouch(evt) })

            // B1/B2：与列表行左滑 reveal 面板同一个确认入口（ConfirmActionOverlay，定义在
            // 同包 DevicesPage.cj），无标题、正文不拼设备名、纵向按钮、破坏性文案
            // "Terminate session"（小写 s，round2 §8.2 item6 第一条同一口径）。
            if (this.showTerminateConfirm) {
                ConfirmActionOverlay(
                    hasTitle: false,
                    titleText: "",
                    bodyText: "Are you sure you want to terminate this session?",
                    destructiveText: "Terminate session",
                    cancelText: "Cancel",
                    onDestructive: { =>
                        this.terminateSession()
                    },
                    onCancel: { =>
                        this.showTerminateConfirm = false
                    }
                )
            }
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ => this.ensureLoaded() })
    }

    // M10（diag-suite_settings_privacy-TC-0135.md §7 M10-d）：面板交互式下拖关闭。
    // 对位源侧 ResizableSheetComponent.swift:437-471 dismissPanGesture(.changed/.ended)。
    // 挂在面板 Column（build() 内 .onTouch），不挂最外层 Stack，避免面板外空白区响应。
    private func onPanelTouch(evt: TouchEvent): Unit {
        match (evt.eventType) {
            case TouchType.Down =>
                if (evt.touches.size > 0) {
                    this.dragStartY = evt.touches[0].screenY
                    this.dragStartX = evt.touches[0].screenX
                    this.dragTracking = false
                    this.dragOffsetVp = 0.0
                    this.lastMoveY = this.dragStartY
                    this.lastMoveTs = evt.timestamp
                }
            case TouchType.Move =>
                if (evt.touches.size > 0) {
                    let dy = evt.touches[0].screenY - this.dragStartY
                    let dx = if (evt.touches[0].screenX - this.dragStartX < 0.0) {
                        this.dragStartX - evt.touches[0].screenX
                    } else {
                        evt.touches[0].screenX - this.dragStartX
                    }
                    if (!this.dragTracking) {
                        let atTop = match (this.panelScroller.currentOffset()) {
                            case Some(off) => off.yOffset <= 0.5
                            case None => false
                        }
                        if (dy > 0.0 && dy > dx && atTop) {
                            this.dragTracking = true
                        }
                    }
                    if (this.dragTracking) {
                        this.dragOffsetVp = if (dy > 0.0) { dy } else { 0.0 }
                    }
                    this.lastMoveY = evt.touches[0].screenY
                    this.lastMoveTs = evt.timestamp
                }
            case TouchType.Up =>
                if (!this.dragTracking) {
                    this.dragOffsetVp = 0.0
                } else if (evt.changedTouches.size > 0) {
                    let dt = evt.timestamp - this.lastMoveTs
                    let velocity = if (dt > 0) {
                        (evt.changedTouches[0].screenY - this.lastMoveY) / Float64(dt) * 1_000_000_000.0
                    } else {
                        0.0
                    }
                    // 速度阈值假设 TouchEvent.timestamp 为纳秒（与诊断报告及 ArkUI 平台惯例一致）；
                    // 但已安装 SDK 的 common.cj.d:9989 注释写的是"毫秒"。二者冲突未解决（cangjie-kb 不可达）。
                    // 此处的 8vp 距离下限使行为不依赖该结论——删除它之前必须先把单位问题查实。
                    let shouldDismiss = this.dragOffsetVp > 180.0 || (velocity > 1000.0 && this.dragOffsetVp > 8.0)
                    this.dragTracking = false
                    if (shouldDismiss) {
                        routerPop()
                    } else {
                        this.dragOffsetVp = 0.0
                    }
                } else {
                    this.dragTracking = false
                    this.dragOffsetVp = 0.0
                }
            case TouchType.Cancel =>
                this.dragTracking = false
                this.dragOffsetVp = 0.0
            case _ => ()
        }
    }
}
