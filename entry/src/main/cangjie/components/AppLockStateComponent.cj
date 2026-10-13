package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.services.getAppLockStateService
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.utils.getLocalAuthManager

/**
 * App Lock State Component (app_lock_state) — P2-268 upgraded
 *
 * Reusable lock screen overlay. Uses AppLockStateService.
 * Shows lock screen when app is locked. Can be embedded in root view.
 *
 * P2-268 changes:
 *   - Replaced plain Text("**") display with PasscodeInputFieldComponent dot-matrix
 *   - Added @State showError: Bool for shake animation on wrong passcode
 *   - Auto-submit for numeric mode when digit count reaches codeLength
 *   - Alphanumeric mode: plain TextInput + Unlock button
 *
 * Usage: Parent passes showBiometricButton prop, sets onUnlock callback.
 *
 * Haptic feedback: N/A — HarmonyOS has no direct equivalent of iOS HapticFeedback.
 * Success animation: onUnlock is called immediately; parent handles transition.
 */
@Component
public class AppLockStateComponent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var lockError: String = ""
    var showBiometricButton: Bool = false
    public var onUnlock: () -> Unit = { => }

    @State var passcode: String = ""
    // P2-268: shake animation state
    @State var showError: Bool = false

    private func getCodeLength(): Int32 {
        let ptype = getAuthStorage().getPasscodeType()
        if (ptype == 1) { return 4 }
        return 6
    }

    private func isAlphanumeric(): Bool {
        return getAuthStorage().getPasscodeType() == 2
    }

    private func appendDigit(d: String): Unit {
        this.passcode = this.passcode + d
        this.lockError = ""
        this.showError = false
        // P2-268: auto-submit numeric passcode when full
        if (Int32(this.passcode.size) >= this.getCodeLength()) {
            this.submitPasscode()
        }
    }

    private func backspaceDigit(): Unit {
        this.lockError = ""
        this.showError = false
        if (this.passcode.size > 0) {
            this.passcode = this.passcode[0..this.passcode.size - 1]
        }
    }

    private func submitPasscode(): Unit {
        if (this.passcode.size == 0) {
            return
        }
        let service = getAppLockStateService()
        let storage = getAuthStorage()
        if (storage.isLockedOut()) {
            this.lockError = "Too many failed attempts. Try again in ${storage.getLockoutRemainingSeconds()} seconds."
            return
        }
        let success = service.verifyAndUnlock(this.passcode)
        if (success) {
            this.passcode = ""
            this.lockError = ""
            this.showError = false
            this.onUnlock()
        } else {
            service.recordFailedAttempt()
            this.lockError = "Incorrect passcode"
            this.passcode = ""
            // P2-268: trigger shake animation, reset after 100ms
            this.showError = true
            spawn {
                sleep(Duration.millisecond * 100)
                launch { this.showError = false }
            }
        }
    }

    private func doBiometricUnlock(): Unit {
        getLocalAuthManager().authenticateWithBiometric("Unlock CJ Telegram", { success: Bool, msg: String =>
            launch {
                if (success) {
                    getAppLockStateService().unlock()
                    this.passcode = ""
                    this.lockError = ""
                    this.showError = false
                    this.onUnlock()
                } else {
                    this.lockError = if (msg.size > 0) { msg } else { "Biometric failed" }
                }
            }
        })
    }

    public func build() {
        Column {
            Column {
                Text("lock")
                    .fontSize(40)
                    .fontColor(0x8E8E93)
            }
            .width(80)
            .height(80)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .margin(top: 120, bottom: 24)

            Text("CJ Telegram is Locked")
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .margin(bottom: 8)

            Text("Enter your passcode to unlock")
                .fontSize(14)
                .fontColor(0x8E8E93)
                .margin(bottom: 24)

            if (this.lockError.size > 0) {
                Text(this.lockError)
                    .fontSize(14)
                    .fontColor(0xFF3B30)
                    .margin(bottom: 16)
            }

            if (getAuthStorage().isLockedOut()) {
                Text("Too many failed attempts. Try again in ${getAuthStorage().getLockoutRemainingSeconds()} seconds.")
                    .fontSize(14)
                    .fontColor(0xFF3B30)
                    .margin(bottom: 16)
            } else if (this.isAlphanumeric()) {
                Column {
                    TextInput(text: this.passcode, placeholder: "Enter passcode")
                        .width(240)
                        .height(44)
                        .onChange({ value: String =>
                            this.passcode = value
                            this.lockError = ""
                            this.showError = false
                        })
                }
                .margin(bottom: 16)

                Button(trSource("Unlock"))
                    .width(200)
                    .height(44)
                    .margin(top: 8)
                    .borderRadius(22)
                    .backgroundColor(if (this.passcode.size > 0) { 0x007AFF } else { 0xCCCCCC })
                    .fontColor(0xFFFFFF)
                    .fontSize(16)
                    .enabled(this.passcode.size > 0)
                    .onClick({ evt => this.submitPasscode() })
            } else {
                // P2-268: dot-matrix passcode display with shake on error
                Column {
                    Row {
                        PasscodeInputFieldComponent(
                            codeLength: this.getCodeLength(),
                            filledCount: Int32(this.passcode.size),
                            showError: this.showError
                        )
                    }
                    .margin(bottom: 16)

                    Row {
                        Button("1").fontSize(22).width(64).height(64).backgroundColor(0xE5E5EA).fontColor(0x000000)
                            .onClick({ evt => this.appendDigit("1") })
                        Button("2").fontSize(22).width(64).height(64).backgroundColor(0xE5E5EA).fontColor(0x000000)
                            .onClick({ evt => this.appendDigit("2") })
                        Button("3").fontSize(22).width(64).height(64).backgroundColor(0xE5E5EA).fontColor(0x000000)
                            .onClick({ evt => this.appendDigit("3") })
                    }
                    .width(220).margin(top: 8)
                    Row {
                        Button("4").fontSize(22).width(64).height(64).backgroundColor(0xE5E5EA).fontColor(0x000000)
                            .onClick({ evt => this.appendDigit("4") })
                        Button("5").fontSize(22).width(64).height(64).backgroundColor(0xE5E5EA).fontColor(0x000000)
                            .onClick({ evt => this.appendDigit("5") })
                        Button("6").fontSize(22).width(64).height(64).backgroundColor(0xE5E5EA).fontColor(0x000000)
                            .onClick({ evt => this.appendDigit("6") })
                    }
                    .width(220).margin(top: 8)
                    Row {
                        Button("7").fontSize(22).width(64).height(64).backgroundColor(0xE5E5EA).fontColor(0x000000)
                            .onClick({ evt => this.appendDigit("7") })
                        Button("8").fontSize(22).width(64).height(64).backgroundColor(0xE5E5EA).fontColor(0x000000)
                            .onClick({ evt => this.appendDigit("8") })
                        Button("9").fontSize(22).width(64).height(64).backgroundColor(0xE5E5EA).fontColor(0x000000)
                            .onClick({ evt => this.appendDigit("9") })
                    }
                    .width(220).margin(top: 8)
                    Row {
                        Blank().width(64).height(64)
                        Button("0").fontSize(22).width(64).height(64).backgroundColor(0xE5E5EA).fontColor(0x000000)
                            .onClick({ evt => this.appendDigit("0") })
                        Button("DEL").fontSize(16).width(64).height(64).backgroundColor(0xE5E5EA).fontColor(0x000000)
                            .onClick({ evt => this.backspaceDigit() })
                    }
                    .width(220).margin(top: 8)
                }
                .margin(bottom: 16)
            }

            if (this.showBiometricButton) {
                Button("Unlock with biometric")
                    .width(200)
                    .height(44)
                    .margin(top: 12)
                    .borderRadius(22)
                    .backgroundColor(0xF2F2F7)
                    .fontColor(0x007AFF)
                    .fontSize(14)
                    .onClick({ evt =>
                        this.doBiometricUnlock()
                    })
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFF)
        .alignItems(HorizontalAlign.Center)
    }
}
