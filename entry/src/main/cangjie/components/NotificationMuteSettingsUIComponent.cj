package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getNotificationMuteSettingsService}

/**
 * 通知静音设置弹窗组件 (P2-334 静音时长 UI)
 *
 * 对应 iOS notificationMuteSettingsController ActionSheet:
 *   选项: unmute, 1h, 8h, 2d, forever — 真存 muteUntil Unix 时间戳，非本地映射
 *
 * currentMuteUntil 用于高亮当前已选项（从 getExceptionForPeer 拉取回填，防死状态）。
 *
 * 用法：父组件通过 @State showMuteSheet 控制显示，传入 userId 和回调
 */
@Component
public class NotificationMuteSettingsUIComponent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    public var userId: Int64 = 0
    public var onClose: () -> Unit = { => }
    public var onMuteApplied: (Int32) -> Unit = { _muteUntil: Int32 => }

    @State var isApplying: Bool = false
    // P2-334: 当前已存的 muteUntil 值，从 service 回填，用于高亮选中选项
    @State var currentMuteUntil: Int32 = -1

    public func aboutToAppear(): Unit {
        this.loadCurrentMuteState()
    }

    /**
     * 从 NotificationMuteSettingsService 拉取当前 peer 的静音状态，回填 currentMuteUntil。
     * S-001: spawn{} + launch{} 保证 @State 更新在主线程。
     */
    private func loadCurrentMuteState(): Unit {
        if (this.userId == 0) { return }
        let uid = this.userId
        let _ = spawn {
            let svc = getNotificationMuteSettingsService()
            let opt = svc.getExceptionForPeer(uid)
            let muteVal: Int32 = match (opt) {
                case Some(v) => v
                case None => 0
            }
            launch {
                this.currentMuteUntil = muteVal
            }
        }
    }

    private func applyMuteAndClose(muteUntil: Int32): Unit {
        if (this.userId == 0) {
            this.onClose()
            return
        }
        this.isApplying = true
        let uid = this.userId
        let muteVal = muteUntil
        let closeCb = this.onClose
        let appliedCb = this.onMuteApplied
        let _ = spawn {
            let service = getNotificationMuteSettingsService()
            let success = service.updateNotifySettings(uid, muteVal)
            launch {
                this.isApplying = false
                if (success) {
                    appliedCb(muteVal)
                }
                closeCb()
            }
        }
    }

    /**
     * 判断当前选项是否被选中（用于高亮显示）
     * currentMuteUntil == 0 → "unmute" 选中
     * currentMuteUntil == 2147483647 → "forever" 选中
     * currentMuteUntil > 0 && < 2147483647 → 任何有时限选项均视为"选中中"（精确匹配不可靠，因时间戳变化）
     * 注意：R-107 禁止在 @Builder 内用 let/var，此逻辑外移到 private func
     */
    private func isOptionSelected(durationSeconds: Int64): Bool {
        if (this.currentMuteUntil < 0) { return false }
        if (durationSeconds == 0) { return this.currentMuteUntil == 0 }
        if (durationSeconds == 2147483647) { return this.currentMuteUntil == 2147483647 }
        return this.currentMuteUntil > 0 && this.currentMuteUntil < 2147483647
    }

    public func build() {
        Column {
            Column { }
                .width(100.percent)
                .layoutWeight(1)
                .backgroundColor(0x66000000)
                .onClick({ _ => this.onClose() })

            Column {
                Text("Mute Duration")
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
                    .margin(top: 20, bottom: 16)

                if (this.isApplying) {
                    LoadingProgress()
                        .width(32)
                        .height(32)
                        .margin(bottom: 16)
                } else {
                    Column {
                        this.buildMuteOption("Unmute", 0)
                        Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16)
                        this.buildMuteOption("1 Hour", 3600)
                        Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16)
                        this.buildMuteOption("8 Hours", 28800)
                        Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16)
                        this.buildMuteOption("2 Days", 172800)
                        Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16)
                        this.buildMuteOption("Mute Forever", 2147483647)
                    }
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(12)
                    .margin(left: 16, right: 16)
                }

                Button(trSource("Cancel"))
                    .fontSize(17)
                    .fontColor(0x317AFF)
                    .backgroundColor(Color.Transparent)
                    .width(100.percent)
                    .height(44)
                    .margin(top: 16, bottom: 24)
                    .onClick({ _ => this.onClose() })
            }
            .width(100.percent)
            .backgroundColor(0xF2F2F7)
            .borderRadius(16)
            .alignItems(HorizontalAlign.Center)
        }
        .width(100.percent)
        .height(100.percent)
        .justifyContent(FlexAlign.End)
        .alignItems(HorizontalAlign.Center)
    }

    /**
     * 单个静音选项行 (@Builder)
     * R-107: @Builder 内禁止 let/var — 判断逻辑外移至 isOptionSelected()/computeMuteUntil()
     */
    @Builder
    func buildMuteOption(label: String, durationSeconds: Int64) {
        Row {
            Text(label)
                .fontSize(17)
                .fontColor(if (this.isOptionSelected(durationSeconds)) { 0x317AFF } else { 0x000000 })
                .layoutWeight(1)
            if (this.isOptionSelected(durationSeconds)) {
                Text("✓")
                    .fontSize(17)
                    .fontColor(0x317AFF)
            }
        }
        .width(100.percent)
        .height(56)
        .padding(left: 16, right: 16)
        .backgroundColor(if (this.isOptionSelected(durationSeconds)) { 0xF0F8FF } else { Color.Transparent })
        .onClick({ _ => this.applyMuteAndClose(this.computeMuteUntil(durationSeconds)) })
    }

    private func computeMuteUntil(durationSeconds: Int64): Int32 {
        if (durationSeconds <= 0) { return 0 }
        if (durationSeconds >= 2147483647) { return 2147483647 }
        let service = getNotificationMuteSettingsService()
        return service.muteUntilForDuration(durationSeconds)
    }
}
