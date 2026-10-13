package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getAppLockService

/**
 * AppLockComponent — 应用锁设置组件
 *
 * 对应 iOS AppLockContextImpl / passcodeSettings 设置区域。
 * 封装 AppLockService 调用，提供：
 *   - 启用/禁用密码锁（显示当前状态，点击跳转到完整设置页）
 *   - 自动锁定超时选择（Disabled / 1m / 5m / 1h / 5h）
 *   - 生物识别解锁开关
 *
 * iOS 覆盖：autolockTimeout / enableBiometrics / isManuallyLocked / invalidAttempts
 * 平台差异：iOS PasscodeEntryController UI 层由 AppLockPage.cj 处理；
 *           MTProto AccountManager/SignalKit 无 HarmonyOS 对等 API，标 N/A。
 */
@Component
public class AppLockComponent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    public var onNavigateToFullPage: () -> Unit = { => }

    @State var hasPasscode: Bool = false
    @State var autoLockIndex: Int64 = 0
    @State var biometricEnabled: Bool = false
    @State var biometricAvailable: Bool = false
    @State var showAutoLockPicker: Bool = false

    public func aboutToAppear(): Unit {
        this.refreshState()
    }

    private func refreshState(): Unit {
        let svc = getAppLockService()
        this.hasPasscode = svc.hasPasscode()
        let minutes = svc.getAutoLockMinutes()
        this.autoLockIndex = this.minutesToIndex(minutes)
        this.biometricEnabled = svc.getBiometricEnabled()
        this.biometricAvailable = svc.isBiometricAvailable()
    }

    private func minutesToIndex(minutes: Int32): Int64 {
        if (minutes <= 0) { return 0 }
        if (minutes <= 1) { return 1 }
        if (minutes <= 5) { return 2 }
        if (minutes <= 60) { return 3 }
        return 4
    }

    private func indexToMinutes(index: Int64): Int32 {
        if (index == 0) { return 0 }
        if (index == 1) { return 1 }
        if (index == 2) { return 5 }
        if (index == 3) { return 60 }
        return 300
    }

    private func getAutoLockLabel(): String {
        if (this.autoLockIndex == 0) { return "Disabled" }
        if (this.autoLockIndex == 1) { return "1 minute" }
        if (this.autoLockIndex == 2) { return "5 minutes" }
        if (this.autoLockIndex == 3) { return "1 hour" }
        return "5 hours"
    }

    private func applyAutoLockIndex(idx: Int64): Unit {
        let minutes = this.indexToMinutes(idx)
        getAppLockService().saveAutoLockMinutes(minutes)
        this.autoLockIndex = idx
        let lbl = this.getAutoLockLabel()
        Hilog.info(0, "CjTelegram", "[AppLockComponent] Auto-lock set to %{public}s", [lbl])
    }

    private func toggleBiometric(): Unit {
        let newVal = !this.biometricEnabled
        getAppLockService().setBiometricEnabled(newVal)
        this.biometricEnabled = newVal
        let valStr = "${newVal}"
        Hilog.info(0, "CjTelegram", "[AppLockComponent] Biometric enabled: %{public}s", [valStr])
    }

    public func build() {
        Column {
            Row {
                Text(trSource("Passcode Lock"))
                    .fontSize(17)
                    .fontColor(0x000000)
                    .layoutWeight(1)
                Text(if (this.hasPasscode) { "On" } else { "Off" })
                    .fontSize(15)
                    .fontColor(if (this.hasPasscode) { 0x34C759 } else { 0x8E8E93 })
            }
            .width(100.percent)
            .height(56)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .onClick({ _evt =>
                this.onNavigateToFullPage()
            })

            if (this.hasPasscode) {
                Divider()
                    .color(0xE5E5EA)
                    .strokeWidth(1)
                    .margin(left: 16)

                Row {
                    Text(trSource("Auto-Lock"))
                        .fontSize(17)
                        .fontColor(0x000000)
                        .layoutWeight(1)
                    Text(this.getAutoLockLabel())
                        .fontSize(15)
                        .fontColor(0x8E8E93)
                }
                .width(100.percent)
                .height(50)
                .padding(left: 16, right: 16)
                .alignItems(VerticalAlign.Center)
                .onClick({ _evt =>
                    this.showAutoLockPicker = !this.showAutoLockPicker
                })

                if (this.showAutoLockPicker) {
                    Column {
                        Row {
                            Text(trSource("Disabled"))
                                .fontSize(15)
                                .fontColor(if (this.autoLockIndex == 0) { 0x007AFF } else { 0x000000 })
                                .layoutWeight(1)
                        }
                        .width(100.percent)
                        .height(44)
                        .padding(left: 32, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _evt => this.applyAutoLockIndex(0) })

                        Row {
                            Text(trSource("1 minute"))
                                .fontSize(15)
                                .fontColor(if (this.autoLockIndex == 1) { 0x007AFF } else { 0x000000 })
                                .layoutWeight(1)
                        }
                        .width(100.percent)
                        .height(44)
                        .padding(left: 32, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _evt => this.applyAutoLockIndex(1) })

                        Row {
                            Text("5 minutes")
                                .fontSize(15)
                                .fontColor(if (this.autoLockIndex == 2) { 0x007AFF } else { 0x000000 })
                                .layoutWeight(1)
                        }
                        .width(100.percent)
                        .height(44)
                        .padding(left: 32, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _evt => this.applyAutoLockIndex(2) })

                        Row {
                            Text(trSource("1 hour"))
                                .fontSize(15)
                                .fontColor(if (this.autoLockIndex == 3) { 0x007AFF } else { 0x000000 })
                                .layoutWeight(1)
                        }
                        .width(100.percent)
                        .height(44)
                        .padding(left: 32, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _evt => this.applyAutoLockIndex(3) })

                        Row {
                            Text("5 hours")
                                .fontSize(15)
                                .fontColor(if (this.autoLockIndex == 4) { 0x007AFF } else { 0x000000 })
                                .layoutWeight(1)
                        }
                        .width(100.percent)
                        .height(44)
                        .padding(left: 32, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _evt => this.applyAutoLockIndex(4) })
                    }
                    .width(100.percent)
                    .backgroundColor(0xF2F2F7)
                }

                if (this.biometricAvailable) {
                    Divider()
                        .color(0xE5E5EA)
                        .strokeWidth(1)
                        .margin(left: 16)

                    Row {
                        Text("Biometric Unlock")
                            .fontSize(17)
                            .fontColor(0x000000)
                            .layoutWeight(1)
                        Toggle(ToggleType.Switch, isOn: this.biometricEnabled)
                            .onChange({ isOn: Bool =>
                                this.toggleBiometric()
                            })
                    }
                    .width(100.percent)
                    .height(50)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                }
            }
        }
        .width(100.percent)
        .backgroundColor(0xFFFFFF)
        .borderRadius(12)
    }
}
