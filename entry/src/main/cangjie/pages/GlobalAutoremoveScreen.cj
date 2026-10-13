package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getPrivacyEngineService, PrivacyEngineService, showToast}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * GlobalAutoremoveScreen — 全局默认消息自毁计时器设置屏（ic_privacy_global_autoremove_screen）
 *
 * 对位源侧 globalAutoremoveScreen(context:initialValue:updated:)
 * (SettingsUI/Sources/Privacy and Security/GlobalAutoremoveScreen.swift)。真实数据源：
 * PrivacyEngineService.getDefaultHistoryTtlSeconds()/setDefaultHistoryTtlSeconds()
 * （messages.getDefaultHistoryTTL#658b7188 / messages.setDefaultHistoryTTL#9eb51445，与
 * 源侧 context.engine.privacy.updateGlobalMessageRemovalTimeout 同一 TL 协议）。
 *
 * Off/1 Day/1 Week/1 Month 四档，立即提交（本地 state 唯一权威，写入即发即忘，同
 * BirthdayPrivacyPage/SelectivePrivacySettingsPage 的 RC-2 范式，不回读覆盖）。
 *
 * 已知缺口（本任务不实现，按 D-148 精神三件套一起落但克制在最小可行范围）：
 *   1. "Set a Custom Time" 行（源侧 openCustomValue → ChatTimerScreen(mode: .autoremove)）：
 *      本工程未迁移任何自定义时长选择器（全仓 grep ChatTimerScreen/TimerScreen 零命中），
 *      新增该能力不在本任务范围，本屏不渲染该行。
 *   2. "Apply to All My Existing Chats" 批量应用链接（源侧 infoLinkAction →
 *      makeContactMultiselectionController）：同样依赖未迁移的多选联系人控制器，不在本屏。
 *   3. pages/PrivacySettingsPage.cj 的 "Auto-Delete Messages" 行 onClick 未指向本屏——该文件
 *      不在本任务 target_files 内，归其 owner feature（跨 feature 接线，非本任务范围）。
 */
@HybridComponentEntry
@Component
public class GlobalAutoremoveScreen {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var loaded: Bool = false
    @State var isLoading: Bool = true
    @State var currentValue: Int32 = 0

    public func aboutToAppear(): Unit {
        this.ensureLoaded()
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) {
            return
        }
        this.loaded = true
        this.refresh()
    }

    private func refresh(): Unit {
        let _ = spawn {
            let svc = getPrivacyEngineService()
            let period = svc.getDefaultHistoryTtlSeconds()
            launch {
                this.currentValue = period
                this.isLoading = false
            }
        }
    }

    // RC-2 范式（同 BirthdayPrivacyPage.selectValue）：本地 state 是唯一权威，立即乐观置位，
    // 网络写入不回读覆盖。
    // S7-72: iOS GlobalAutoremoveScreen.swift:230-296 — turning the timer on from Off first
    // asks "Self-Destruct Timer" → Enable Auto-Deletion / Cancel; changing between non-zero
    // values or back to Off applies directly. Applying updates the Privacy row (updated(timeout))
    // and shows the auto-delete toast.
    private func selectValue(newValue: Int32): Unit {
        if (this.currentValue == newValue) {
            return
        }
        if (newValue != 0 && this.currentValue == 0) {
            let strings = this.sourceLocalizationPresentation
            let valueText = this.valueLabel(newValue)
            let cancelBtn = AlertDialogButtonOptions(value: strings.getOr("Common_Cancel", "Cancel"), action: { => () })
            let enableBtn = AlertDialogButtonOptions(
                style: DialogButtonStyle.Highlight,
                value: strings.getOr("GlobalAutodeleteSettings_SetConfirmAction", "Enable Auto-Deletion"),
                action: { => this.applyValue(newValue) }
            )
            this.getUIContext().showAlertDialog(AlertDialogParamWithButtons(
                title: strings.getOr("GlobalAutodeleteSettings_SetConfirmTitle", "Self-Destruct Timer"),
                message: strings.getOr("GlobalAutodeleteSettings_SetConfirmText",
                    "Are you sure you want all messages in your new private chats and in new groups you create to be automatically deleted for everyone %@ after they have been sent?").replace("%@", valueText),
                primaryButton: enableBtn,
                secondaryButton: cancelBtn,
                autoCancel: true
            ))
            return
        }
        this.applyValue(newValue)
    }

    private func applyValue(newValue: Int32): Unit {
        let previous = this.currentValue
        this.currentValue = newValue
        notifyGlobalAutoremoveUpdated(newValue)
        let strings = this.sourceLocalizationPresentation
        if (newValue != 0) {
            showToast(strings.getOr("GlobalAutodeleteSettings_SetConfirmToastEnabled",
                "Messages in all new chats you start will be automatically deleted after %@.").replace("%@", this.valueLabel(newValue)))
        } else {
            showToast(strings.getOr("GlobalAutodeleteSettings_SetConfirmToastDisabled",
                "Messages in all new chats you start will not be automatically deleted."))
        }
        let _ = spawn {
            let svc = getPrivacyEngineService()
            let ok = svc.setDefaultHistoryTtlSeconds(newValue)
            if (!ok) {
                launch {
                    if (this.currentValue == newValue) {
                        this.currentValue = previous
                        notifyGlobalAutoremoveUpdated(previous)
                    }
                }
            }
        }
    }

    private func optionTitle(seconds: Int32): String {
        if (seconds <= 0) {
            return this.sourceLocalizationPresentation.getOr("Autoremove_OptionOff", "Off")
        }
        return this.sourceLocalizationPresentation.getOr("GlobalAutodeleteSettings_OptionTitle", "After %@")
            .replace("%@", this.valueLabel(seconds))
    }

    private func valueLabel(seconds: Int32): String {
        if (seconds <= 0) {
            return "Off"
        }
        if (seconds <= 86400) {
            return "1 day"
        }
        if (seconds <= 604800) {
            return "1 week"
        }
        return "1 month"
    }

    private func infoText(): String {
        if (this.currentValue <= 0) {
            return "If enabled, all new messages in chats you start will be automatically deleted for all participants after a period of time."
        }
        return "New messages in chats you start will be automatically deleted for everyone after ${this.valueLabel(this.currentValue)}."
    }

    @Builder
    func buildValueOption(label: String, value: Int32) {
        Row {
            Image(@r(app.media.media_ic_check))
                .width(20)
                .height(20)
                .fillColor(0x317AFF)
                .opacity(if (this.currentValue == value) { 1.0 } else { 0.0 })
                .margin(right: 12)
            Text(label)
                .fontSize(17)
                .fontColor(0x000000)
                .layoutWeight(1)
        }
        .width(100.percent)
        .height(44)
        .padding(left: 16, right: 16)
        .backgroundColor(0xFFFFFF)
        .onClick({ _ => this.selectValue(value) })
    }

    public func build() {
        Column {
            Row {
                Text(trSource("Back"))
                    .fontSize(16)
                    .fontColor(0x317AFF)
                    .onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
                Text(trSource("Auto-Delete Messages"))
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                Blank().layoutWeight(1)
                Row {}.width(60)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(0xFFFFFF)
            .alignItems(VerticalAlign.Center)

            Text("DEFAULT AUTO-DELETE TIMER")
                .fontSize(13)
                .fontColor(0x8E8E93)
                .width(100.percent)
                .padding(left: 16, right: 16, top: 16, bottom: 6)

            if (this.isLoading) {
                LoadingProgress()
                    .width(32)
                    .height(32)
                    .margin(top: 24)
            } else {
                Column {
                    this.buildValueOption(this.optionTitle(0), 0)
                    Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)
                    this.buildValueOption(this.optionTitle(86400), 86400)
                    Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)
                    this.buildValueOption(this.optionTitle(604800), 604800)
                    Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)
                    this.buildValueOption(this.optionTitle(2678400), 2678400)
                }
                .backgroundColor(0xFFFFFF)
                .borderRadius(12)
                .margin(left: 16, right: 16)
                .clip(true)

                Text(this.infoText())
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .width(100.percent)
                    .padding(left: 31, right: 31, top: 8)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
    }
}
