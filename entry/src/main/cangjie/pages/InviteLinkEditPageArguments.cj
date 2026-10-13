package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.time.DateTime
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * 邀请链接编辑页面（Invite Link Edit Page）（混合工程迁移版）
 *
 * 路由名 "InviteLinkEditPage"（MainTabPage.pageMap）→ 类 InviteLinkEditPageArguments。
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹（.title 由 ArkTS 壳提供）
 *  - pageStack.pop() → routerPop()
 *  - aboutToAppear 有实逻辑（getPendingInviteLinkEdit）→ ensureLoaded()/.onAppear
 */
@HybridComponentEntry
@Component
public class InviteLinkEditPageArguments {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var linkTitle: String = ""
    @State var expireDays: Int32 = 0
    @State var usageLimit: Int32 = 0
    @State var requestNeeded: Bool = false
    @State var isEditing: Bool = false
    @State var existingLink: String = ""
    @State var isSubmitting: Bool = false
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let link = getPendingInviteLinkEdit()
        if (link.size > 0) {
            this.existingLink = link
            this.isEditing = true
        }
    }

    private func parseNonNegativeInt(s: String): Int32 {
        var result: Int64 = 0
        for (r in s.toRuneArray()) {
            let c = r.toString()
            if (c == "0") { result = result * 10 }
            else if (c == "1") { result = result * 10 + 1 }
            else if (c == "2") { result = result * 10 + 2 }
            else if (c == "3") { result = result * 10 + 3 }
            else if (c == "4") { result = result * 10 + 4 }
            else if (c == "5") { result = result * 10 + 5 }
            else if (c == "6") { result = result * 10 + 6 }
            else if (c == "7") { result = result * 10 + 7 }
            else if (c == "8") { result = result * 10 + 8 }
            else if (c == "9") { result = result * 10 + 9 }
            else { break }
        }
        if (result > 2147483647) { result = 2147483647 }
        return Int32(result)
    }

    private func saveLink(): Unit {
        if (this.isSubmitting) { return }
        this.isSubmitting = true

        let peerType = getSelectedChatPeerType()
        let peerId = getSelectedChatId()
        let title = this.linkTitle
        let limit = this.usageLimit
        let needApproval = this.requestNeeded
        let expDays = this.expireDays

                spawn {
                    try {
                        let svc = getInviteLinksService()
                        var ok = false
                        if (this.isEditing && this.existingLink.size > 0) {
                            let expireDate: Int32 = if (expDays > 0) {
                                let now = Int32(DateTime.now().toUnixTimeStamp().toMilliseconds() / 1000)
                                now + expDays * 86400
                            } else { 0 }
                            ok = svc.editExportedChatInvite(
                                peerType, peerId, this.existingLink,
                                title: title,
                                expireDate: expireDate,
                                usageLimit: limit,
                                requestNeeded: needApproval,
                                setRequestNeeded: true
                            )
                        } else {
                            let expireDate: Int32 = if (expDays > 0) {
                                let now = Int32(DateTime.now().toUnixTimeStamp().toMilliseconds() / 1000)
                                now + expDays * 86400
                            } else { 0 }
                            let newLink = svc.exportChatInvite(
                                peerType, peerId,
                                title: title,
                                expireDate: expireDate,
                                usageLimit: limit,
                                requestNeeded: needApproval
                            )
                            ok = newLink.size > 0
                        }
                        let okVal = ok
                        launch {
                            this.isSubmitting = false
                            if (okVal) {
                                notifyInviteLinksChanged()
                                routerPop()
                            }
                        }
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[InviteLinkEdit] Save error")
                        launch { this.isSubmitting = false }
                    }
                }
    }

    public func build() {
        Scroll {
            Column {
                Text(trSource("Link Name"))
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .margin(left: 16, top: 16, bottom: 4)
                    .width(100.percent)

                TextInput(text: this.linkTitle, placeholder: "Optional name for this link")
                    .onChange({ value: String => this.linkTitle = value })
                    .fontSize(16)
                    .height(44)
                    .margin(left: 16, right: 16, bottom: 16)
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(8)

                Text("Expire (days)")
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .margin(left: 16, top: 8, bottom: 4)
                    .width(100.percent)

                TextInput(text: if (this.expireDays == 0) { "" } else { "${this.expireDays}" }, placeholder: "0 = never")
                    .onChange({ value: String =>
                        this.expireDays = this.parseNonNegativeInt(value)
                    })
                    .fontSize(16)
                    .height(44)
                    .margin(left: 16, right: 16, bottom: 16)
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(8)

                Text("Usage limit")
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .margin(left: 16, top: 8, bottom: 4)
                    .width(100.percent)

                TextInput(text: if (this.usageLimit == 0) { "" } else { "${this.usageLimit}" }, placeholder: "0 = unlimited")
                    .onChange({ value: String =>
                        this.usageLimit = this.parseNonNegativeInt(value)
                    })
                    .fontSize(16)
                    .height(44)
                    .margin(left: 16, right: 16, bottom: 16)
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(8)

                Row {
                    Text("Require approval to join")
                        .fontSize(16)
                        .fontColor(0x000000)
                        .layoutWeight(1)
                    Toggle(ToggleType.Switch, isOn: this.requestNeeded)
                        .onChange({ isOn: Bool => this.requestNeeded = isOn })
                }
                .width(100.percent)
                .height(56)
                .padding(left: 16, right: 16)
                .backgroundColor(0xFFFFFF)
                .borderRadius(8)
                .margin(left: 16, right: 16, bottom: 24)

                Button(trSource("Save"))
                    .fontSize(17)
                    .fontColor(0xFFFFFF)
                    .width(90.percent)
                    .height(48)
                    .backgroundColor(0x0088CC)
                    .borderRadius(24)
                    .margin(top: 16, bottom: 40)
                    .enabled(!this.isSubmitting)
                    .onClick({ evt =>
                        this.saveLink()
                    })
            }
            .width(100.percent)
        }
        .layoutWeight(1)
        .backgroundColor(0xF2F2F7)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
