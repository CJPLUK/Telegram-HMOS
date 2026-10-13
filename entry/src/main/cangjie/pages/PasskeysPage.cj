package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{
    PresentationSnapshot,
    currentPresentation,
    PresentationStringsSnapshot,
    currentPresentationStrings,
    trSource
}
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getRealAuthService, showToast, JsonParser}
import ohos_app_cangjie_entry.core.mtproto.{Base64, PasskeyInfo}
import ohos_app_cangjie_entry.interop.{callArkAsync, PASSKEY_REGISTER}
import ohos_app_cangjie_entry.utils.formatFullDate
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import std.collection.ArrayList

// CG-01：PasskeysPage 改动 passkeys 后把最新数量推回 PrivacySettingsPage 的 "Passkeys" 行
// （父屏在 push 子屏后仍挂载，pop 回来不会自动重 build）。形状同 PrivacySettingsPage.cj
// 的 _onGlobalAutoremoveUpdated（package-private top-level var + 调用式访问器）。
// 注册方：PrivacySettingsPage.ensureLoaded()；写入方：本页 applyList()。
var _onPasskeysUpdated: Option<(Int64) -> Unit> = None
func notifyPasskeysUpdated(count: Int64): Unit {
    match (_onPasskeysUpdated) {
        case Some(h) => h(count)
        case None => ()
    }
}

/**
 * PasskeysPage — 对位 iOS PasskeysScreen
 * (submodules/TelegramUI/Components/Settings/PasskeysScreen/Sources/PasskeysScreen.swift +
 *  PasskeysScreenIntroComponent.swift + PasskeysScreenListComponent.swift)。
 *
 * 两种状态（PasskeysScreen.swift:269/:286 以 passkeysData.isEmpty 分流）：
 *   - intro：无 passkey。key 图标 + "Protect your account" + "Log in safely and keep your
 *     account secure." + 三条特性行 + 底部 "Create Passkey" 按钮（Intro 组件 :98-:371）。
 *   - list：有 passkey。同一头部（标题改 "Passkeys"）+ 列表（名称 / "created <date>" 或
 *     "created <date> • used <date>"）+ 每条可 Delete + 数量未达上限时 "Create Passkey" 行 +
 *     页脚 "Your passkeys are stored securely in your password manager."（List 组件 :137-:306）。
 *
 * 数据：account.getPasskeys（RealAuthService.getPasskeys）；删除 account.deletePasskey；
 * 创建 = account.initPasskeyRegistration → 平台 WebAuthn ceremony（ArkTS fido2.register，
 * ets/interop/impls/PasskeyImpl.ets）→ account.registerPasskey，对位 PasskeysScreen.swift
 * createPasskey()/authorizationController(didCompleteWithAuthorization:) :83-:177。
 *
 * 文案一律取 iOS Localizable.strings 的 Passkeys.* 原文（含 "Face ID" / "iCloud Keychain"）。
 */
@HybridComponentEntry
@Component
public class PasskeysPage {
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @StorageLink["presentationStrings"] var strings: PresentationStringsSnapshot = currentPresentationStrings()
    @State var loaded: Bool = false
    @State var isLoading: Bool = true
    @State var isCreating: Bool = false
    @State var passkeyIds: Array<String> = Array<String>()
    @State var passkeyNames: Array<String> = Array<String>()
    @State var passkeySubtitles: Array<String> = Array<String>()
    // iOS PasskeysScreenListComponent.swift:102-105：passkeys_account_passkeys_max 缺省 5。
    @State var maxPasskeys: Int64 = 5

    public func aboutToAppear(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.reload()
    }

    // ─── data ───

    private func reload(): Unit {
        let _ = spawn {
            var list = ArrayList<PasskeyInfo>()
            try {
                list = getRealAuthService().getPasskeys().passkeys
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[PasskeysPage] getPasskeys error: ${e}")
            }
            this.applyList(list)
        }
    }

    private func applyList(list: ArrayList<PasskeyInfo>): Unit {
        let n = list.size
        let ids = Array<String>(n, repeat: "")
        let names = Array<String>(n, repeat: "")
        let subs = Array<String>(n, repeat: "")
        var i: Int64 = 0
        while (i < n) {
            let p = list[i]
            ids[i] = p.id
            // Passkeys.EmptyName = "Passkey"
            names[i] = if (p.name.isEmpty()) { this.strings.getOr("Passkeys_EmptyName", "Passkey") } else { p.name }
            subs[i] = this.subtitleFor(p)
            i = i + 1
        }
        spawn(UIThread) { =>
            this.passkeyIds = ids
            this.passkeyNames = names
            this.passkeySubtitles = subs
            this.isLoading = false
            this.isCreating = false
            // 父屏 @State 只能在 UI 线程写（S-001）。
            notifyPasskeysUpdated(n)
        }
    }

    // iOS PasskeysScreenListComponent.swift:143-147 + :176-181：dateStyle .medium（"Oct 2, 2026"）；
    // Passkeys.PasskeyCreatedPattern = "created %@"，
    // Passkeys.PasskeyCreatedAndUsedPattern = "created %1$@ • used %2$@"。
    private func subtitleFor(p: PasskeyInfo): String {
        let created = formatFullDate(Int64(p.date))
        if (p.hasLastUsageDate && p.lastUsageDate > 0) {
            let used = formatFullDate(Int64(p.lastUsageDate))
            return this.strings.getOr("Passkeys_PasskeyCreatedAndUsedPattern", "created %1$@ • used %2$@")
                .replace("%1$@", created).replace("%2$@", used)
        }
        return this.strings.getOr("Passkeys_PasskeyCreatedPattern", "created %@").replace("%@", created)
    }

    // ─── delete（PasskeysScreen.swift:181-213 displayDeletePasskey / deletePasskey）───

    private func confirmDelete(id: String): Unit {
        let cancelBtn = AlertDialogButtonOptions(
            value: this.strings.getOr("Common_Cancel", "Cancel"),
            action: { => () }
        )
        let deleteBtn = AlertDialogButtonOptions(
            value: this.strings.getOr("Passkeys_DeleteAlert_Action", "Delete"),
            fontColor: 0xFF3B30,
            action: { => this.deletePasskey(id) }
        )
        this.getUIContext().showAlertDialog(AlertDialogParamWithButtons(
            title: this.strings.getOr("Passkeys_DeleteAlert_Title", "Delete Passkey?"),
            message: this.strings.getOr("Passkeys_DeleteAlert_Text",
                "Once deleted, this passkey can't be used to log in.\n\nDon't forget to remove it from your password manager too."),
            primaryButton: cancelBtn,
            secondaryButton: deleteBtn,
            autoCancel: true
        ))
    }

    private func deletePasskey(id: String): Unit {
        // 源侧先本地移除再发请求（:209-213）；这里乐观移除后以服务端列表为准回填。
        let keepIds = ArrayList<String>()
        let keepNames = ArrayList<String>()
        let keepSubs = ArrayList<String>()
        var i: Int64 = 0
        while (i < this.passkeyIds.size) {
            if (this.passkeyIds[i] != id) {
                keepIds.add(this.passkeyIds[i])
                keepNames.add(this.passkeyNames[i])
                keepSubs.add(this.passkeySubtitles[i])
            }
            i = i + 1
        }
        this.passkeyIds = keepIds.toArray()
        this.passkeyNames = keepNames.toArray()
        this.passkeySubtitles = keepSubs.toArray()
        notifyPasskeysUpdated(Int64(this.passkeyIds.size))
        let _ = spawn {
            try {
                let ok = getRealAuthService().deletePasskey(id)
                Hilog.info(0, "CjTelegram", "[PasskeysPage] deletePasskey ok=${ok}")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[PasskeysPage] deletePasskey error: ${e}")
            }
            var list = ArrayList<PasskeyInfo>()
            try {
                list = getRealAuthService().getPasskeys().passkeys
            } catch (_e: Exception) {}
            this.applyList(list)
        }
    }

    // ─── create（PasskeysScreen.swift:118-177 createPasskey + :83-:113 didCompleteWithAuthorization）───

    private func createPasskey(): Unit {
        if (this.isCreating) { return }
        this.isCreating = true
        let _ = spawn {
            var optionsJson = ""
            try {
                optionsJson = getRealAuthService().initPasskeyRegistration()
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[PasskeysPage] initPasskeyRegistration error: ${e}")
            }
            if (optionsJson.isEmpty()) {
                spawn(UIThread) { =>
                    this.isCreating = false
                    showToast("Could not start passkey registration. Please try again.")
                }
                return
            }
            // 两段都走标准 base64，避免引号/反斜杠经过简化版 JsonParser（契约见 interop.cj PASSKEY_REGISTER）。
            let argJson = "{\"optionsB64\":\"${Base64.encode(optionsJson.toArray())}\"}"
            callArkAsync(PASSKEY_REGISTER, argJson, { res =>
                // JS 回调线程上不做网络；hop 到工作线程完成 account.registerPasskey。
                let _ = spawn { this.finishRegistration(res) }
            })
        }
    }

    private func finishRegistration(res: String): Unit {
        var ok = false
        var cancelled = false
        var msg = ""
        var id = ""
        var rawId = ""
        var clientDataJson = ""
        var attestation = Array<Byte>(0, repeat: 0)
        try {
            let obj = JsonParser.parseObject(res)
            ok = obj.getBool("ok")
            if (ok) {
                id = obj.getString("id")
                rawId = obj.getString("rawId")
                clientDataJson = String.fromUtf8(Base64.decode(obj.getString("clientDataB64")))
                attestation = Base64.decode(obj.getString("attestationB64"))
            } else {
                cancelled = obj.getBool("cancelled")
                msg = obj.getString("msg")
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PasskeysPage] register result parse error: ${e}")
            ok = false
        }
        if (!ok || id.isEmpty() || attestation.size == 0) {
            Hilog.info(0, "CjTelegram", "[PasskeysPage] platform ceremony failed cancelled=${cancelled} msg=${msg}")
            let wasCancelled = cancelled
            let toastText = if (msg.isEmpty()) { "Passkey creation failed." } else { msg }
            spawn(UIThread) { =>
                this.isCreating = false
                // 源侧 didCompleteWithError 对用户取消静默（PasskeysScreen.swift:115-117）。
                if (!wasCancelled) {
                    showToast(toastText)
                }
            }
            return
        }
        var created: Option<PasskeyInfo> = None
        try {
            created = getRealAuthService().registerPasskey(id, rawId, clientDataJson, attestation)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PasskeysPage] registerPasskey error: ${e}")
        }
        match (created) {
            case Some(_) =>
                var list = ArrayList<PasskeyInfo>()
                try {
                    list = getRealAuthService().getPasskeys().passkeys
                } catch (_e: Exception) {}
                this.applyList(list)
            case None =>
                spawn(UIThread) { =>
                    this.isCreating = false
                    showToast("Telegram could not register this passkey. Please try again.")
                }
        }
    }

    // ─── UI ───

    @Builder
    func buildHeader(titleText: String) {
        // 共同头部（Intro :98-:170 / List :117-:190）：124pt key 图标 + 27pt 粗体标题 + 16pt 副标题。
        Column {
            Image(@r(app.media.privacy_ic_key))
                .width(124)
                .height(124)
            Text(titleText)
                .fontSize(27)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.presentation.textColor)
                .textAlign(TextAlign.Center)
                .margin(top: 10)
            Text(this.strings.getOr("Passkeys_Subtitle", "Log in safely and keep your account secure."))
                .fontSize(16)
                .fontColor(this.presentation.textColor)
                .textAlign(TextAlign.Center)
                .margin(top: 10, left: 16, right: 16)
        }
        .width(100.percent)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    func buildIntroItem(icon: ResourceStr, titleText: String, bodyText: String, topPad: Int64) {
        // Intro :205-:299：icon 列 40pt，标题 semibold 15，正文 15 secondary，行距 2，行间距 24。
        Row {
            Image(icon)
                .width(28)
                .height(28)
                .margin(top: 2)
            Column {
                Text(titleText)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.presentation.textColor)
                Text(bodyText)
                    .fontSize(15)
                    .fontColor(this.presentation.secondaryTextColor)
                    .margin(top: 2)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .margin(left: 12)
        }
        .width(100.percent)
        .alignItems(VerticalAlign.Top)
        .padding(left: 36, right: 36)
        .margin(top: topPad)
    }

    @Builder
    func buildIntro() {
        Column {
            Scroll {
                Column {
                    this.buildHeader(this.strings.getOr("Passkeys_Into_Title", "Protect your account"))
                    Column {
                        this.buildIntroItem(@r(app.media.privacy_ic_key),
                            this.strings.getOr("Passkeys_Into_Title0", "Create a Passkey"),
                            this.strings.getOr("Passkeys_Into_Text0", "Make a passkey to sign in easily and safely."),
                            0)
                        this.buildIntroItem(@r(app.media.privacy_ic_faceid),
                            this.strings.getOr("Passkeys_Into_Title1", "Log in with Face ID"),
                            this.strings.getOr("Passkeys_Into_Text1", "Use Face ID, Touch ID, or your passcode to sign in."),
                            24)
                        this.buildIntroItem(@r(app.media.privacy_ic_lock),
                            this.strings.getOr("Passkeys_Into_Title2", "Store Passkey Securely"),
                            this.strings.getOr("Passkeys_Into_Text2", "Your passkey is safely kept in your iCloud Keychain."),
                            24)
                    }
                    .width(100.percent)
                    .margin(top: 47)
                }
                .width(100.percent)
                .padding(top: 24, bottom: 24)
            }
            .width(100.percent)
            .layoutWeight(1)
            .scrollBar(BarState.Off)

            // Intro :301-:323：ButtonComponent 高 52、圆角 26、侧边距 32，Passkeys.ButtonCreate。
            Button(this.strings.getOr("Passkeys_ButtonCreate", "Create Passkey"))
                .width(100.percent)
                .height(52)
                .fontSize(17)
                .fontWeight(FontWeight.Medium)
                .fontColor(0xFFFFFF)
                .backgroundColor(this.presentation.accentColor)
                .borderRadius(26)
                .opacity(if (this.isCreating) { 0.6 } else { 1.0 })
                // 源侧 concentricInsets(bottomInset: safeBottom)：按钮底边贴安全区上沿；外层
                // Column 已 padding(bottom: getSafeAreaBottom())，这里再留 24 让按钮与手势条分开。
                .margin(left: 32, right: 32, top: 8, bottom: 24)
                .onClick({ _ => this.createPasskey() })
        }
        .width(100.percent)
        // R12：不能再 height(100.percent)——外层 Column 已占去头部 56+safeTop 与底部 inset，
        // 整屏高的子块会把按钮推到屏幕外；用 layoutWeight(1) 吃掉剩余高度即可。
        .layoutWeight(1)
    }

    @Builder
    func buildListRow(idx: Int64) {
        // List :183-:244：左 passkeys 图标，名称 17 + 副标题 14 secondary；contextOption "Delete"。
        Row {
            Image(@r(app.media.privacy_ic_key))
                .width(29)
                .height(29)
            Column {
                Text(this.passkeyNames[idx])
                    .fontSize(17)
                    .fontColor(this.presentation.textColor)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                Text(this.passkeySubtitles[idx])
                    .fontSize(14)
                    .fontColor(this.presentation.secondaryTextColor)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                    .margin(top: 2)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .margin(left: 12)
            Text(this.strings.getOr("Common_Delete", "Delete"))
                .fontSize(17)
                .fontColor(0xFF3B30)
                .padding(left: 8)
                .onClick({ _ => this.confirmDelete(this.passkeyIds[idx]) })
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 10, bottom: 10)
        .alignItems(VerticalAlign.Center)
    }

    @Builder
    func buildList() {
        Scroll {
            Column {
                this.buildHeader(this.strings.getOr("Passkeys_Title", "Passkeys"))
                Column {
                    ForEach(this.passkeyIds, itemGenerator: { _id: String, idx: Int64 =>
                        Column {
                            this.buildListRow(idx)
                            if (idx < Int64(this.passkeyIds.size) - 1 || Int64(this.passkeyIds.size) < this.maxPasskeys) {
                                Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 57)
                            }
                        }
                    })
                    if (Int64(this.passkeyIds.size) < this.maxPasskeys) {
                        // List :246-:273：Passkeys.AddPasskey 行（accent 色 + 加号图标）。
                        Row {
                            Image(@r(app.media.itemlist_ic_plus))
                                .width(29)
                                .height(29)
                                .fillColor(this.presentation.accentColor)
                            Text(this.strings.getOr("Passkeys_AddPasskey", "Create Passkey"))
                                .fontSize(17)
                                .fontColor(this.presentation.accentColor)
                                .layoutWeight(1)
                                .margin(left: 12)
                        }
                        .width(100.percent)
                        .height(50)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .opacity(if (this.isCreating) { 0.6 } else { 1.0 })
                        .onClick({ _ => this.createPasskey() })
                    }
                }
                .width(100.percent)
                .backgroundColor(this.presentation.cardColor)
                .borderRadius(12)
                .clip(true)
                .margin(top: 32)
                // Passkeys.ListFooter
                Text(this.strings.getOr("Passkeys_ListFooter", "Your passkeys are stored securely in your password manager."))
                    .fontSize(13)
                    .fontColor(this.presentation.secondaryTextColor)
                    .width(100.percent)
                    .padding(left: 15, right: 15, top: 8)
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 8, bottom: 32)
        }
        .width(100.percent)
        // R12：同 buildIntro——layoutWeight(1) 而非 height(100.percent)，列表底部才落在 inset 之上。
        .layoutWeight(1)
        .scrollBar(BarState.Off)
    }

    public func build() {
        Column {
            // 源侧 navigationBarAppearance: .transparent，仅返回键；本工程子屏头部惯例同 GlobalAutoremoveScreen。
            Row {
                Text(trSource("Back"))
                    .fontSize(16)
                    .fontColor(this.presentation.accentColor)
                    .onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
                Row {}.width(60)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .alignItems(VerticalAlign.Center)

            if (this.isLoading) {
                // PasskeysScreen.swift:323-343：passkeysData == nil 时居中 activity indicator。
                Column {
                    LoadingProgress().width(32).height(32)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
            } else if (this.passkeyIds.size == 0) {
                this.buildIntro()
            } else {
                this.buildList()
            }
        }
        .width(100.percent)
        .height(100.percent)
        // intro 用 plainBackgroundColor（白底），list 用 blocksBackgroundColor（分组底色）。
        .backgroundColor(if (!this.isLoading && this.passkeyIds.size > 0) { this.presentation.backgroundColor } else { this.presentation.cardColor })
        .padding(bottom: getSafeAreaBottom())
    }
}
