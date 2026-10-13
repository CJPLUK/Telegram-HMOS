package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.resource.__GenerateResource__
import ohos_app_cangjie_entry.core.storage.*
import ohos_app_cangjie_entry.core.mtproto.{SHA256, ByteUtils}
import ohos_app_cangjie_entry.utils.getLocalAuthManager
import ohos_app_cangjie_entry.components.{PasscodeInputFieldComponent, ContextMenuView, ContextMenuItem}
import ohos_app_cangjie_entry.services.getAppLockService
import ohos_app_cangjie_entry.services.getAppLockStateService
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * Passcode Lock Settings Page (P2-266 / P2-267 / P2-268)（混合工程迁移版）
 *
 * P2-266: 设置/创建密码 — 点阵自绘键盘（数字密码用 PasscodeInputFieldComponent 圆点显示 + 自绘数字键盘）。
 *         设置/确认两步，与 change/disable 流程自洽。
 * P2-267: 密码类型选择 — 4位/6位数字 + 字母数字 alphanumeric 三选一。
 * P2-268: 解锁屏错误处理 — 改密/禁用流程内的错误触发点阵 shake（showError）。
 *
 * 密码类型常量（存储为 Int32）：
 *   PTYPE_DIGITS6 = 0  — 6位数字（默认）
 *   PTYPE_DIGITS4 = 1  — 4位数字
 *   PTYPE_ALPHA   = 2  — 字母数字（alphanumeric）
 *
 * iOS 对照: PasscodeSetupController / PasscodeSetupControllerNode / PasscodeSetupControllerMode
 *
 * @Builder 方法均无参数（D-115 约束：@Component 内 @Builder 带参数导致宏展开失败）。
 * 需要参数的逻辑通过 @State 流程状态字段和 private func 计算器替代。
 *
 * 流程状态（uiMode）:
 *   0 = 已禁用/未设置  1 = 设置新密码流程  2 = 已启用主界面  3 = 改密流程  4 = 进入闸门（entry，二次验证）
 *
 * 自绘数字键盘采用分流设计：uiMode 对应多套 append/backspace/submit 方法，
 * 公共 buildKeypadRows() 读取 uiMode 路由到对应方法（无需传参）。
 *
 * P2-266 补记（TC-0138 R1 返修）：iOS 侧 `passcodeOptionsAccessController` 在已设密码时
 * 强制走 `PasscodeSetupControllerMode.entry` 闸门，验证通过（`completion(true)`）才推出设置屏；
 * 三个源侧调用点（隐私与安全 / Logout Options / Delete Account Options）都经这道闸门。
 * 本迁移把闸门内建在本页面里（uiMode=4），`ensureLoaded()` 据 `isEnabled` 决定首屏落 4 还是 0，
 * 三个调用方 `routerPush("AppLockPage")` 保持裸跳转不变，自动共享同一道闸门。
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry；去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹（原 hideTitleBar(true)），只留内容
 *  - pageStack.pop() → routerPop()
 *  - aboutToAppear 实逻辑 → ensureLoaded()（.onAppear 触发）
 *  - localauth: getLocalAuthManager().isBiometricAvailable() 为已迁移 util 直调，编译期已过，保留原样
 */
@HybridComponentEntry
@Component
public class AppLockPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // ---- 全局状态 ----
    @State var isEnabled: Bool = false
    @State var autoLockIndex: Int64 = 1
    @State var statusMessage: String = ""
    @State var errorMessage: String = ""
    @State var biometricEnabled: Bool = false
    @State var biometricAvailable: Bool = false
    @State var passcodeType: Int32 = 0
    @State var autoLockDisclosure: String = "If away for 1 min"
    @State var showAutoLockMenu: Bool = false
    @State var showDisableSheet: Bool = false
    // 对位 PasscodeSetupControllerNode.modeButtonNode → selectPasscodeMode ActionSheet。
    @State var showModeSheet: Bool = false
    @State var introAnimationOpacity: Float64 = 0.0

    // ---- UI 流程模式 (0=disabled, 1=setup, 2=enabled, 3=change, 4=entry gate) ----
    @State var uiMode: Int64 = 2

    // ---- 新建密码流程 (uiMode=1) ----
    @State var setupStep: Int64 = 1
    @State var setupPasscode: String = ""
    @State var setupConfirm: String = ""
    @State var setupAlpha: String = ""
    @State var setupAlphaConfirm: String = ""
    @State var setupShowError: Bool = false

    // ---- 进入闸门 (uiMode=4，对位 iOS PasscodeSetupControllerMode.entry) ----
    // 只有验证通过这一条路径能把 uiMode 推到 2；不保留任何绕过分支（TC-0138 R1）。
    @State var entryCode: String = ""
    @State var entryAlpha: String = ""
    @State var entryShowError: Bool = false

    // ---- 改密流程 (uiMode=3) ----
    // 对位 iOS PasscodeSetupControllerMode.setup(change: true, ...)：只有两步（新 / 再输一遍），
    // 旧密码校验职责已下沉给 uiMode=4 的入口闸门，本流程不再单独收旧密码（TC-0139 R4）。
    @State var changeStep: Int64 = 2
    @State var changeNew: String = ""
    @State var changeConfirm: String = ""
    @State var changeAlpha: String = ""
    @State var changeAlphaNew: String = ""
    @State var changeAlphaConfirm: String = ""
    @State var changeShowError: Bool = false

    // ---- 禁用密码 (uiMode=2, disable sub-section) ----
    @State var disableCode: String = ""
    @State var disableShowError: Bool = false

    // ---- D-125 镜像字段 ----
    // PasscodeInputFieldComponent.filledCount 是子组件的 @Prop；@Prop 依赖追踪只认调用点上
    // 裸的 `this.<State字段>` 引用，函数调用返回值（setupFilledCount()/changeFilledCount()）
    // 和嵌套字段访问的类型转换包裹（Int32(this.entryCode.size)）都不会驱动子组件重新 build()
    // （dev_pattern.md D-125）。3 个 live 调用点各配一个裸 @State 镜像字段，在 build() 入口统一刷新
    // （见 refreshFilledCountMirrors() + build() 内零高度探针），调用点只传镜像字段本身。
    @State var setupFilledCountMirror: Int32 = 0
    @State var changeFilledCountMirror: Int32 = 0
    @State var entryFilledCountMirror: Int32 = 0

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let storage = getAuthStorage()
        this.isEnabled = storage.hasPasscode()
        // TC-0138 R1: 有密码 ⇒ 先进入口闸门（uiMode=4），对位 passcodeOptionsAccessController
        // 的 `if case .none = challenge` 判定（.none → 引导屏；否则 → .entry 闸门）。
        this.uiMode = if (this.isEnabled) { 4 } else { 0 }
        let minutes = storage.getAutoLockMinutes()
        this.autoLockIndex = this.minutesToIndex(minutes)
        this.autoLockDisclosure = this.autoLockDisclosureForIndex(this.autoLockIndex)
        this.biometricEnabled = storage.getBiometricEnabled()
        this.biometricAvailable = getLocalAuthManager().isBiometricAvailable()
        this.passcodeType = storage.getPasscodeType()
        Hilog.info(0, "CjTelegram", "[AppLockPage] Loaded: enabled=${this.isEnabled}, type=${this.passcodeType}")
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

    private func codeLength(): Int32 {
        if (this.passcodeType == 1) { return 4 }
        return 6
    }

    private func isAlphanumericMode(): Bool {
        return this.passcodeType == 2
    }

    private func passcodeTypeName(): String {
        if (this.passcodeType == 0) { return "6-Digit Code" }
        if (this.passcodeType == 1) { return "4-Digit Code" }
        return "Alphanumeric Code"
    }

    private func autoLockLabel(): String {
        if (this.autoLockIndex == 0) { return "Disabled" }
        if (this.autoLockIndex == 1) { return "1 minute" }
        if (this.autoLockIndex == 2) { return "5 minutes" }
        if (this.autoLockIndex == 3) { return "1 hour" }
        return "5 hours"
    }

    private func autoLockDisclosureForIndex(index: Int64): String {
        if (index == 0) { return "Disabled" }
        if (index == 1) { return "If away for 1 min" }
        if (index == 2) { return "If away for 5 min" }
        if (index == 3) { return "If away for 1 hour" }
        return "If away for 5 hours"
    }

    private func autoLockCheckIcon(index: Int64): ResourceStr {
        if (this.autoLockIndex == index) {
            return @r(app.media.media_ic_check)
        }
        return ""
    }

    // ---- Helper: filled count per mode ----

    private func setupFilledCount(): Int32 {
        if (this.setupStep == 1) { return Int32(this.setupPasscode.size) }
        return Int32(this.setupConfirm.size)
    }

    private func changeFilledCount(): Int32 {
        if (this.changeStep == 2) { return Int32(this.changeNew.size) }
        return Int32(this.changeConfirm.size)
    }

    // D-125 镜像刷新：build() 入口的零高度探针每次调用本函数，把 3 个 live filledCount 计算值
    // 写回裸 @State 镜像字段。返回值只为满足 D-116（@Builder 内不能用 let，只能是 UI 组件表达式）。
    private func refreshFilledCountMirrors(): String {
        this.setupFilledCountMirror = this.setupFilledCount()
        this.changeFilledCountMirror = this.changeFilledCount()
        this.entryFilledCountMirror = Int32(this.entryCode.size)
        return ""
    }

    private func setupStepTitle(): String {
        if (this.setupStep == 1) { return "Enter new passcode" }
        return "Re-enter passcode to confirm"
    }

    private func changeStepTitle(): String {
        // 对位源侧字面量：EnterPasscode.EnterNewPasscodeChange / EnterPasscode.RepeatNewPasscode
        // （Localizable.strings:1243/1244）。源侧改密流程没有「输入当前密码」这一步。
        if (this.changeStep == 2) { return "Enter your new passcode" }
        return "Re-enter your new passcode"
    }

    private func setupCurrentAlpha(): String {
        if (this.setupStep == 1) { return this.setupAlpha }
        return this.setupAlphaConfirm
    }

    private func changeCurrentAlpha(): String {
        if (this.changeStep == 2) { return this.changeAlphaNew }
        return this.changeAlphaConfirm
    }

    // ---- Keypad digit handlers ----

    private func onSetupDigit(d: String): Unit {
        this.errorMessage = ""
        this.setupShowError = false
        if (this.setupStep == 1) {
            if (Int64(this.setupPasscode.size) < Int64(this.codeLength())) {
                this.setupPasscode = this.setupPasscode + d
                if (Int64(this.setupPasscode.size) == Int64(this.codeLength())) {
                    this.setupStep = 2
                }
            }
        } else {
            if (Int64(this.setupConfirm.size) < Int64(this.codeLength())) {
                this.setupConfirm = this.setupConfirm + d
                if (Int64(this.setupConfirm.size) == Int64(this.codeLength())) {
                    this.doEnablePasscode()
                }
            }
        }
    }

    private func onSetupBackspace(): Unit {
        this.errorMessage = ""
        this.setupShowError = false
        if (this.setupStep == 2 && this.setupConfirm.size == 0) {
            this.setupStep = 1
        } else if (this.setupStep == 1 && this.setupPasscode.size > 0) {
            this.setupPasscode = this.setupPasscode[0..this.setupPasscode.size - 1]
        } else if (this.setupStep == 2 && this.setupConfirm.size > 0) {
            this.setupConfirm = this.setupConfirm[0..this.setupConfirm.size - 1]
        }
    }

    private func onChangeDigit(d: String): Unit {
        this.errorMessage = ""
        this.changeShowError = false
        if (this.changeStep == 2) {
            if (Int64(this.changeNew.size) < Int64(this.codeLength())) {
                this.changeNew = this.changeNew + d
                if (Int64(this.changeNew.size) == Int64(this.codeLength())) {
                    this.changeStep = 3
                }
            }
        } else {
            if (Int64(this.changeConfirm.size) < Int64(this.codeLength())) {
                this.changeConfirm = this.changeConfirm + d
                if (Int64(this.changeConfirm.size) == Int64(this.codeLength())) {
                    this.doChangePasscode()
                }
            }
        }
    }

    private func onChangeBackspace(): Unit {
        this.errorMessage = ""
        this.changeShowError = false
        if (this.changeStep == 2 && this.changeNew.size > 0) {
            this.changeNew = this.changeNew[0..this.changeNew.size - 1]
        } else if (this.changeStep == 3 && this.changeConfirm.size > 0) {
            this.changeConfirm = this.changeConfirm[0..this.changeConfirm.size - 1]
        }
    }

    // ---- 入口闸门 (uiMode=4) ----

    private func onEntryDigit(d: String): Unit {
        this.errorMessage = ""
        this.entryShowError = false
        if (Int64(this.entryCode.size) < Int64(this.codeLength())) {
            this.entryCode = this.entryCode + d
            if (Int64(this.entryCode.size) == Int64(this.codeLength())) {
                this.verifyEntry(this.entryCode)
            }
        }
    }

    private func onEntryBackspace(): Unit {
        this.errorMessage = ""
        this.entryShowError = false
        if (this.entryCode.size > 0) {
            this.entryCode = this.entryCode[0..this.entryCode.size - 1]
        }
    }

    // 对位源侧 check 回调：succeed ⇒ completion(true) 推设置屏；否则 animateError()。
    // 只有这一条路径能把 uiMode 推到 2（TC-0138 R1 边界：不得保留任何绕过分支）。
    private func verifyEntry(code: String): Unit {
        let storage = getAuthStorage()
        if (storage.verifyPasscode(code)) {
            if (this.isAlphanumericMode()) {
                this.changeAlpha = code
            } else {
                this.disableCode = code
            }
            this.uiMode = 2
            this.entryCode = ""
            this.entryAlpha = ""
            this.entryShowError = false
            this.errorMessage = ""
        } else {
            // 对位 PasscodeSetupControllerNode.animateError()（:270-275）：闸门验错只 reset 输入 +
            // 抖动，源侧既不写错误文案，也不调用失败计数——失败计数/锁定属于锁屏
            // PasscodeEntryController，不属于设置侧 .entry 闸门（TC-0139 修法 A）。
            this.entryShowError = true
            this.entryCode = ""
            this.entryAlpha = ""
        }
    }

    private func onDisableDigit(d: String): Unit {
        this.errorMessage = ""
        this.disableShowError = false
        if (Int64(this.disableCode.size) < Int64(this.codeLength())) {
            this.disableCode = this.disableCode + d
            if (Int64(this.disableCode.size) == Int64(this.codeLength())) {
                this.doDisablePasscode()
            }
        }
    }

    private func onDisableBackspace(): Unit {
        this.errorMessage = ""
        this.disableShowError = false
        if (this.disableCode.size > 0) {
            this.disableCode = this.disableCode[0..this.disableCode.size - 1]
        }
    }

    // ---- Core actions ----

    private func doEnablePasscode(): Unit {
        if (this.isAlphanumericMode()) {
            let code = this.setupAlpha
            let confirmCode = this.setupAlphaConfirm
            if (code.size == 0) {
                this.setupShowError = true
                this.errorMessage = "Enter a passcode"
                return
            }
            if (code != confirmCode) {
                this.setupShowError = true
                this.errorMessage = "Passcodes do not match"
                this.setupAlphaConfirm = ""
                return
            }
            let ok = getAppLockService().enablePasscodeWithType(code, confirmCode, this.passcodeType)
            if (ok) {
                this.isEnabled = true
                this.uiMode = 2
                this.autoLockIndex = this.minutesToIndex(getAppLockService().getAutoLockMinutes())
                this.autoLockDisclosure = this.autoLockDisclosureForIndex(this.autoLockIndex)
                this.setupAlpha = ""
                this.setupAlphaConfirm = ""
                this.setupStep = 1
                this.errorMessage = ""
                this.statusMessage = "Passcode lock enabled"
                Hilog.info(0, "CjTelegram", "[AppLockPage] Alphanumeric passcode enabled")
            }
        } else {
            let code = this.setupPasscode
            let confirmCode = this.setupConfirm
            if (code != confirmCode) {
                this.setupShowError = true
                this.errorMessage = "Passcodes do not match"
                this.setupConfirm = ""
                this.setupStep = 2
                return
            }
            let ok = getAppLockService().enablePasscodeWithType(code, confirmCode, this.passcodeType)
            if (ok) {
                this.isEnabled = true
                this.uiMode = 2
                this.autoLockIndex = this.minutesToIndex(getAppLockService().getAutoLockMinutes())
                this.autoLockDisclosure = this.autoLockDisclosureForIndex(this.autoLockIndex)
                this.setupPasscode = ""
                this.setupConfirm = ""
                this.setupStep = 1
                this.errorMessage = ""
                this.statusMessage = "Passcode lock enabled"
                Hilog.info(0, "CjTelegram", "[AppLockPage] Numeric passcode enabled type=${this.passcodeType}")
            }
        }
    }

    private func doDisablePasscode(): Unit {
        let code = if (this.isAlphanumericMode()) { this.changeAlpha } else { this.disableCode }
        let storage = getAuthStorage()
        if (!storage.verifyPasscode(code)) {
            // 与闸门同源：设置页内的本地校验失败只 reset + 抖动，不写文案、不把锁屏失败计数
            // 接到设置页（TC-0139 修法 A 边界）。
            this.disableShowError = true
            if (this.isAlphanumericMode()) { this.changeAlpha = "" } else { this.disableCode = "" }
            return
        }
        let ok = getAppLockService().disablePasscode(code)
        if (ok) {
            this.isEnabled = false
            this.uiMode = 0
            this.disableCode = ""
            this.changeAlpha = ""
            this.errorMessage = ""
            this.statusMessage = "Passcode lock disabled"
        }
    }

    // 对位源侧 PasscodeSetupControllerNode.activateNext() 的两态机：旧密码已由 uiMode=4 的
    // 入口闸门验过，本流程只比较「新 / 再输一遍」两遍是否一致；不一致时退回第一遍，不停在第三步
    // （TC-0139 R4：修掉 D1 退回语义 + D3 文案，且不再对这条路径调用 recordFailedAttempt）。
    private func doChangePasscode(): Unit {
        if (this.isAlphanumericMode()) {
            let newCode = this.changeAlphaNew
            let confirmCode = this.changeAlphaConfirm
            if (newCode.size == 0) {
                this.changeShowError = true
                this.errorMessage = "Enter a new passcode"
                return
            }
            if (newCode != confirmCode) {
                this.changeShowError = true
                this.errorMessage = "Passcodes don't match. Please try again."
                this.changeAlphaNew = ""
                this.changeAlphaConfirm = ""
                this.changeStep = 2
                return
            }
            let ok = getAppLockService().changePasscode(newCode)
            if (ok) {
                // 源侧 complete?(passcode, numerical) 会连类型一起落盘，改密时经 Passcode Options
                // 换过类型必须同步，否则下次闸门按旧类型算长度。
                getAppLockService().savePasscodeType(this.passcodeType)
                this.uiMode = 2
                this.changeStep = 2
                this.changeAlphaNew = ""
                this.changeAlphaConfirm = ""
                this.errorMessage = ""
                this.statusMessage = "Passcode changed"
                Hilog.info(0, "CjTelegram", "[AppLockPage] Passcode changed (alpha)")
            }
        } else {
            if (this.changeConfirm != this.changeNew) {
                this.changeShowError = true
                this.errorMessage = "Passcodes don't match. Please try again."
                this.changeNew = ""
                this.changeConfirm = ""
                this.changeStep = 2
                return
            }
            let ok = getAppLockService().changePasscode(this.changeNew)
            if (ok) {
                getAppLockService().savePasscodeType(this.passcodeType)
                this.uiMode = 2
                this.changeStep = 2
                this.changeNew = ""
                this.changeConfirm = ""
                this.errorMessage = ""
                this.statusMessage = "Passcode changed"
                Hilog.info(0, "CjTelegram", "[AppLockPage] Passcode changed")
            }
        }
    }

    private func saveAutoLock(index: Int64): Unit {
        this.autoLockIndex = index
        this.autoLockDisclosure = this.autoLockDisclosureForIndex(index)
        this.showAutoLockMenu = false
        let minutes = this.indexToMinutes(index)
        getAppLockService().saveAutoLockMinutes(minutes)
        Hilog.info(0, "CjTelegram", "[AppLockPage] Auto-lock set to ${minutes} min")
    }

    private func toggleBiometric(): Unit {
        this.biometricEnabled = !this.biometricEnabled
        getAppLockService().setBiometricEnabled(this.biometricEnabled)
        Hilog.info(0, "CjTelegram", "[AppLockPage] Biometric: ${this.biometricEnabled}")
    }

    private func startSetup(): Unit {
        this.uiMode = 1
        this.setupStep = 1
        this.setupPasscode = ""
        this.setupConfirm = ""
        this.setupAlpha = ""
        this.setupAlphaConfirm = ""
        this.setupShowError = false
        this.passcodeType = 0
        this.errorMessage = ""
    }

    // 对位 PasscodeSetupControllerNode.updateMode(_:)：换类型后重置输入并回到第一遍，
    // 新建流与改密流共用同一个 sheet（源侧同为 `.setup(change:_, type)` 的 mode 替换）。
    private func updateMode(newType: Int32): Unit {
        this.passcodeType = newType
        this.showModeSheet = false
        if (this.uiMode == 3) {
            this.changeStep = 2
            this.changeNew = ""
            this.changeConfirm = ""
            this.changeAlphaNew = ""
            this.changeAlphaConfirm = ""
            this.changeShowError = false
        } else {
            this.setupStep = 1
            this.setupPasscode = ""
            this.setupConfirm = ""
            this.setupAlpha = ""
            this.setupAlphaConfirm = ""
            this.setupShowError = false
        }
        this.errorMessage = ""
    }

    // 源侧 selectPasscodeMode 只列「当前类型以外」的两项 + Cancel
    // （PasscodeSetupController.swift:67-95）。
    private func modeSheetItems(): Array<ContextMenuItem> {
        let digits6 = ContextMenuItem(
            title: "6-Digit Numeric Code",
            onClick: { => this.updateMode(0) },
            centered: true
        )
        let digits4 = ContextMenuItem(
            title: "4-Digit Numeric Code",
            onClick: { => this.updateMode(1) },
            centered: true
        )
        let alphanumeric = ContextMenuItem(
            title: "Custom Alphanumeric Code",
            onClick: { => this.updateMode(2) },
            centered: true
        )
        let cancel = ContextMenuItem(
            title: "Cancel",
            onClick: { => this.showModeSheet = false },
            centered: true
        )
        if (this.passcodeType == 0) {
            return [digits4, alphanumeric, ContextMenuItem.separator(), cancel]
        }
        if (this.passcodeType == 1) {
            return [digits6, alphanumeric, ContextMenuItem.separator(), cancel]
        }
        return [digits6, digits4, ContextMenuItem.separator(), cancel]
    }

    private func startChange(): Unit {
        this.uiMode = 3
        this.changeStep = 2
        this.changeNew = ""
        this.changeConfirm = ""
        this.changeAlphaNew = ""
        this.changeAlphaConfirm = ""
        this.changeShowError = false
        this.errorMessage = ""
    }

    // ==================== Build ====================

    public func build() {
        Stack {
            Column {
                // D-125 零高度探针：先于本方法体内所有其它子树跑一遍，
                // 把 3 个镜像字段刷新到本次 build() 求到的最新值，再往下传给子组件。
                Text(this.refreshFilledCountMirrors()).height(0).fontSize(0)

                Row {
                    Column {
                        Image(@r(app.media.nav_back_arrow_legacy))
                            .width(13)
                            .height(22)
                            .fillColor(0x000000)
                    }
                    .width(52)
                    .height(52)
                    .borderRadius(26)
                    .backgroundColor(0xFFFFFF)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .onClick({ _ => routerPop() })
                    Blank().layoutWeight(1)
                    Text(trSource("Passcode Lock"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0x000000)
                    Blank().layoutWeight(1)
                    Row { }.width(52)
                }
                .width(100.percent)
                .height(64.0 + getSafeAreaTop())
                .padding(left: 16, right: 16, top: getSafeAreaTop())
                .backgroundColor(0xF2F2F7)
                .alignItems(VerticalAlign.Center)

                Scroll {
                    Column {
                        if (this.errorMessage.size > 0) {
                            Text(this.errorMessage)
                                .fontSize(14)
                                .fontColor(0xFF3B30)
                                .margin(left: 16, right: 16, top: 8)
                                .width(100.percent)
                        }

                        if (this.uiMode == 1) {
                            this.buildSetupFlow()
                        } else if (this.uiMode == 3) {
                            this.buildChangeFlow()
                        } else if (this.uiMode == 4) {
                            this.buildEntryScreen()
                        } else if (this.isEnabled) {
                            this.buildEnabledState()
                        } else {
                            this.buildDisabledState()
                        }
                    }
                }
                .layoutWeight(1)
                .backgroundColor(0xF2F2F7)
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xF2F2F7)
            .padding(bottom: getSafeAreaBottom())
            .onAppear({ => this.ensureLoaded() })

            if (this.showDisableSheet) {
                ContextMenuView(
                    items: this.disableSheetItems(),
                    onDismiss: { => this.showDisableSheet = false },
                    bottomInset: getSafeAreaBottom()
                )
            }

            if (this.showModeSheet) {
                ContextMenuView(
                    items: this.modeSheetItems(),
                    onDismiss: { => this.showModeSheet = false },
                    bottomInset: getSafeAreaBottom()
                )
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
    }

    // ---- P2-266 / P2-267: Setup flow (no @Builder params per D-115) ----

    // 类型切换只经底栏 Passcode Options sheet（源侧 modeButtonNode）；不再前置 PASSCODE TYPE
    // 分区——源 `.setup` 首屏只有标题 + 圆点 + 键盘 + 底栏按钮（TC-0139 修法 B 第 4 点）。
    @Builder
    func buildSetupFlow() {
        Column {
            Text(this.setupStepTitle())
                .fontSize(15)
                .fontColor(0x8E8E93)
                .margin(left: 16, top: 24, bottom: 12)
                .width(100.percent)

            if (this.isAlphanumericMode()) {
                this.buildSetupAlphaInput()
            } else {
                this.buildSetupNumericInput()
            }

            // 第二遍（确认）时源侧隐藏 modeButtonNode（PasscodeSetupControllerNode.swift:251-252），
            // 离开流程走页头 Back，不用 Cancel 顶替。
            if (this.setupStep == 1) {
                Button(trSource("Passcode Options"))
                    .width(100.percent)
                    .height(44)
                    .fontSize(17)
                    .fontColor(0x007AFF)
                    .backgroundColor(Color.Transparent)
                    .margin(left: 16, right: 16, top: 16, bottom: 32)
                    .onClick({ evt => this.showModeSheet = true })
            }
        }
        .width(100.percent)
    }

    @Builder
    func buildSetupAlphaInput() {
        Column {
            TextInput(text: this.setupCurrentAlpha(), placeholder: "Passcode")
                .width(100.percent)
                .height(44)
                .backgroundColor(Color.Transparent)
                .onChange({ value: String =>
                    if (this.setupStep == 1) {
                        this.setupAlpha = value
                    } else {
                        this.setupAlphaConfirm = value
                    }
                    this.errorMessage = ""
                    this.setupShowError = false
                })
        }
        .padding(left: 16, right: 16)
        .backgroundColor(0xFFFFFF)
        .borderRadius(12)
        .margin(left: 16, right: 16)

        if (this.setupStep == 1) {
            Button(trSource("Next"))
                .width(100.percent)
                .height(48)
                .fontSize(16)
                .fontColor(0xFFFFFF)
                .backgroundColor(0x007AFF)
                .borderRadius(12)
                .margin(left: 16, right: 16, top: 16)
                .enabled(this.setupAlpha.size > 0)
                .onClick({ evt =>
                    this.setupStep = 2
                    this.errorMessage = ""
                })
        } else {
            Button("Enable Passcode")
                .width(100.percent)
                .height(48)
                .fontSize(16)
                .fontColor(0xFFFFFF)
                .backgroundColor(0x007AFF)
                .borderRadius(12)
                .margin(left: 16, right: 16, top: 16)
                .enabled(this.setupAlphaConfirm.size > 0)
                .onClick({ evt => this.doEnablePasscode() })
        }
    }

    @Builder
    func buildSetupNumericInput() {
        Column {
            Row {
                PasscodeInputFieldComponent(
                    codeLength: this.codeLength(),
                    filledCount: this.setupFilledCountMirror,
                    showError: this.setupShowError
                )
            }
            .margin(top: 16, bottom: 16)

            this.buildSetupKeypad()
        }
        .padding(16)
        .backgroundColor(0xFFFFFF)
        .borderRadius(12)
        .margin(left: 16, right: 16)
    }

    @Builder
    func buildSetupKeypad() {
        Row {
            Button("1").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onSetupDigit("1") })
            Button("2").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onSetupDigit("2") })
            Button("3").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).onClick({ evt => this.onSetupDigit("3") })
        }
        .width(100.percent)
        .margin(top: 8)

        Row {
            Button("4").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onSetupDigit("4") })
            Button("5").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onSetupDigit("5") })
            Button("6").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).onClick({ evt => this.onSetupDigit("6") })
        }
        .width(100.percent)
        .margin(top: 8)

        Row {
            Button("7").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onSetupDigit("7") })
            Button("8").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onSetupDigit("8") })
            Button("9").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).onClick({ evt => this.onSetupDigit("9") })
        }
        .width(100.percent)
        .margin(top: 8)

        Row {
            Blank().layoutWeight(1)
            Button("0").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(left: 4).onClick({ evt => this.onSetupDigit("0") })
            Button("DEL").fontSize(16).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(left: 4).onClick({ evt => this.onSetupBackspace() })
        }
        .width(100.percent)
        .margin(top: 8)
    }

    // ---- P2-268: Change passcode flow ----

    @Builder
    func buildChangeFlow() {
        Column {
            Text(this.changeStepTitle())
                .fontSize(15)
                .fontColor(0x8E8E93)
                .margin(left: 16, top: 24, bottom: 12)
                .width(100.percent)

            if (this.isAlphanumericMode()) {
                this.buildChangeAlphaInput()
            } else {
                this.buildChangeNumericInput()
            }

            // 改密第一遍显示 Passcode Options（源 `.setup(change: true, …)` 的 modeButtonNode）；
            // 第二遍隐藏（:251-252），返回统一走页头 Back。
            if (this.changeStep == 2) {
                Button(trSource("Passcode Options"))
                    .width(100.percent)
                    .height(44)
                    .fontSize(17)
                    .fontColor(0x007AFF)
                    .backgroundColor(Color.Transparent)
                    .margin(left: 16, right: 16, top: 12, bottom: 32)
                    .onClick({ evt => this.showModeSheet = true })
            }
        }
        .width(100.percent)
    }

    @Builder
    func buildChangeAlphaInput() {
        Column {
            TextInput(text: this.changeCurrentAlpha(), placeholder: "Passcode")
                .width(100.percent)
                .height(44)
                .backgroundColor(Color.Transparent)
                .onChange({ value: String =>
                    if (this.changeStep == 2) {
                        this.changeAlphaNew = value
                    } else {
                        this.changeAlphaConfirm = value
                    }
                    this.errorMessage = ""
                    this.changeShowError = false
                })
        }
        .padding(left: 16, right: 16)
        .backgroundColor(0xFFFFFF)
        .borderRadius(12)
        .margin(left: 16, right: 16)

        Row {
            if (this.changeStep == 2) {
                Button(trSource("Next"))
                    .fontSize(16)
                    .fontColor(0x007AFF)
                    .backgroundColor(Color.Transparent)
                    .enabled(this.changeAlphaNew.size > 0)
                    .onClick({ evt => this.changeStep = 3 })
            } else {
                Button(trSource("Change"))
                    .fontSize(16)
                    .fontColor(0x007AFF)
                    .backgroundColor(Color.Transparent)
                    .enabled(this.changeAlphaConfirm.size > 0)
                    .onClick({ evt => this.doChangePasscode() })
            }
        }
        .width(100.percent)
        .margin(left: 16, right: 16, top: 12)
    }

    @Builder
    func buildChangeNumericInput() {
        Column {
            Row {
                PasscodeInputFieldComponent(
                    codeLength: this.codeLength(),
                    filledCount: this.changeFilledCountMirror,
                    showError: this.changeShowError
                )
            }
            .margin(top: 16, bottom: 16)

            this.buildChangeKeypad()
        }
        .padding(16)
        .backgroundColor(0xFFFFFF)
        .borderRadius(12)
        .margin(left: 16, right: 16)
    }

    @Builder
    func buildChangeKeypad() {
        Row {
            Button("1").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onChangeDigit("1") })
            Button("2").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onChangeDigit("2") })
            Button("3").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).onClick({ evt => this.onChangeDigit("3") })
        }
        .width(100.percent)
        .margin(top: 8)

        Row {
            Button("4").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onChangeDigit("4") })
            Button("5").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onChangeDigit("5") })
            Button("6").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).onClick({ evt => this.onChangeDigit("6") })
        }
        .width(100.percent)
        .margin(top: 8)

        Row {
            Button("7").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onChangeDigit("7") })
            Button("8").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onChangeDigit("8") })
            Button("9").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).onClick({ evt => this.onChangeDigit("9") })
        }
        .width(100.percent)
        .margin(top: 8)

        Row {
            Blank().layoutWeight(1)
            Button("0").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(left: 4).onClick({ evt => this.onChangeDigit("0") })
            Button("DEL").fontSize(16).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(left: 4).onClick({ evt => this.onChangeBackspace() })
        }
        .width(100.percent)
        .margin(top: 8)
    }

    // ---- P2-266 补记: 入口闸门 (uiMode=4，对位 iOS PasscodeSetupControllerMode.entry) ----
    // 闸门屏不出现 Passcode Options / 类型切换入口（对位 PasscodeSetupControllerNode.swift:113-115
    // 的 modeButtonNode.isHidden = true）；页面顶部的 Back 已是唯一的离开路径，直接 routerPop()，
    // 不落到 uiMode=2（TC-0138 R1 修法 1 第 5 点）。

    // 闸门无锁定态：源侧 PasscodeSetupController.checkPasscode（:125-127）只把明文转发给
    // 本地 `==` 比较，没有节流/倒计时，所以这里恒渲染输入区（TC-0139 修法 A 第 4 点）。
    @Builder
    func buildEntryScreen() {
        Column {
            Text(trSource("Enter your Telegram Passcode"))
                .fontSize(15)
                .fontColor(0x8E8E93)
                .margin(left: 16, top: 24, bottom: 12)
                .width(100.percent)

            if (this.isAlphanumericMode()) {
                this.buildEntryAlphaInput()
            } else {
                this.buildEntryNumericInput()
            }
        }
        .width(100.percent)
    }

    @Builder
    func buildEntryNumericInput() {
        Column {
            Row {
                PasscodeInputFieldComponent(
                    codeLength: this.codeLength(),
                    filledCount: this.entryFilledCountMirror,
                    showError: this.entryShowError
                )
            }
            .margin(top: 16, bottom: 16)

            this.buildEntryKeypad()
        }
        .padding(16)
        .backgroundColor(0xFFFFFF)
        .borderRadius(12)
        .margin(left: 16, right: 16)
    }

    @Builder
    func buildEntryKeypad() {
        Row {
            Button("1").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onEntryDigit("1") })
            Button("2").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onEntryDigit("2") })
            Button("3").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).onClick({ evt => this.onEntryDigit("3") })
        }
        .width(100.percent)
        .margin(top: 8)

        Row {
            Button("4").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onEntryDigit("4") })
            Button("5").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onEntryDigit("5") })
            Button("6").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).onClick({ evt => this.onEntryDigit("6") })
        }
        .width(100.percent)
        .margin(top: 8)

        Row {
            Button("7").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onEntryDigit("7") })
            Button("8").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onEntryDigit("8") })
            Button("9").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).onClick({ evt => this.onEntryDigit("9") })
        }
        .width(100.percent)
        .margin(top: 8)

        Row {
            Blank().layoutWeight(1)
            Button("0").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(left: 4).onClick({ evt => this.onEntryDigit("0") })
            Button("DEL").fontSize(16).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(left: 4).onClick({ evt => this.onEntryBackspace() })
        }
        .width(100.percent)
        .margin(top: 8)
    }

    @Builder
    func buildEntryAlphaInput() {
        Column {
            TextInput(text: this.entryAlpha, placeholder: "Passcode")
                .width(100.percent)
                .height(44)
                .backgroundColor(Color.Transparent)
                .onChange({ value: String =>
                    this.entryAlpha = value
                    this.errorMessage = ""
                    this.entryShowError = false
                })
        }
        .padding(left: 16, right: 16)
        .backgroundColor(0xFFFFFF)
        .borderRadius(12)
        .margin(left: 16, right: 16)

        Button(trSource("Unlock"))
            .width(100.percent)
            .height(48)
            .fontSize(16)
            .fontColor(0xFFFFFF)
            .backgroundColor(0x007AFF)
            .borderRadius(12)
            .margin(left: 16, right: 16, top: 16)
            .enabled(this.entryAlpha.size > 0)
            .onClick({ evt => this.verifyEntry(this.entryAlpha) })
    }

    /*
     * Legacy enabled/disabled view retained for reconstruction history.
     * It rendered STATUS/TYPE cards, a permanently expanded Auto-Lock list,
     * and an inline passcode keypad for disabling. The active builders below
     * replace this whole view with the source ItemList structure.
     */
    /*

    @Builder
    func buildEnabledState() {
        Column {
            Text("STATUS")
                .fontSize(13)
                .fontColor(0x8E8E93)
                .margin(left: 16, top: 16, bottom: 8)
                .width(100.percent)

            Column {
                Row {
                    Text(trSource("Passcode Lock"))
                        .fontSize(17)
                        .fontColor(0x000000)
                        .layoutWeight(1)
                    Text(trSource("On"))
                        .fontSize(15)
                        .fontColor(0x34C759)
                }
                .width(100.percent)
                .height(44)
                .padding(left: 16, right: 16)
                .alignItems(VerticalAlign.Center)

                Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16)

                Row {
                    Text("Type")
                        .fontSize(17)
                        .fontColor(0x000000)
                        .layoutWeight(1)
                    Text(this.passcodeTypeName())
                        .fontSize(15)
                        .fontColor(0x8E8E93)
                }
                .width(100.percent)
                .height(44)
                .padding(left: 16, right: 16)
                .alignItems(VerticalAlign.Center)
            }
            .backgroundColor(0xFFFFFF)
            .borderRadius(12)
            .margin(left: 16, right: 16)

            if (this.biometricAvailable) {
                Text("BIOMETRIC UNLOCK")
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .margin(left: 16, top: 24, bottom: 8)
                    .width(100.percent)

                Column {
                    Row {
                        Text("Biometric Unlock")
                            .fontSize(17)
                            .fontColor(0x000000)
                            .layoutWeight(1)
                        Toggle(ToggleType.Switch, isOn: this.biometricEnabled)
                            .onChange({ isOn: Bool => this.toggleBiometric() })
                    }
                    .width(100.percent)
                    .height(56)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                }
                .backgroundColor(0xFFFFFF)
                .borderRadius(12)
                .margin(left: 16, right: 16)
            }

            Text("AUTO-LOCK")
                .fontSize(13)
                .fontColor(0x8E8E93)
                .margin(left: 16, top: 24, bottom: 8)
                .width(100.percent)

            Column {
                Row {
                    Text(trSource("Disabled")).fontSize(17).fontColor(0x000000).layoutWeight(1)
                    if (this.autoLockIndex == 0) { Text("v").fontSize(17).fontColor(0x007AFF) }
                }
                .width(100.percent).height(44).padding(left: 16, right: 16).alignItems(VerticalAlign.Center)
                .onClick({ evt => this.saveAutoLock(0) })
                Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16)
                Row {
                    Text(trSource("1 minute")).fontSize(17).fontColor(0x000000).layoutWeight(1)
                    if (this.autoLockIndex == 1) { Text("v").fontSize(17).fontColor(0x007AFF) }
                }
                .width(100.percent).height(44).padding(left: 16, right: 16).alignItems(VerticalAlign.Center)
                .onClick({ evt => this.saveAutoLock(1) })
                Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16)
                Row {
                    Text("5 minutes").fontSize(17).fontColor(0x000000).layoutWeight(1)
                    if (this.autoLockIndex == 2) { Text("v").fontSize(17).fontColor(0x007AFF) }
                }
                .width(100.percent).height(44).padding(left: 16, right: 16).alignItems(VerticalAlign.Center)
                .onClick({ evt => this.saveAutoLock(2) })
                Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16)
                Row {
                    Text(trSource("1 hour")).fontSize(17).fontColor(0x000000).layoutWeight(1)
                    if (this.autoLockIndex == 3) { Text("v").fontSize(17).fontColor(0x007AFF) }
                }
                .width(100.percent).height(44).padding(left: 16, right: 16).alignItems(VerticalAlign.Center)
                .onClick({ evt => this.saveAutoLock(3) })
                Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16)
                Row {
                    Text("5 hours").fontSize(17).fontColor(0x000000).layoutWeight(1)
                    if (this.autoLockIndex == 4) { Text("v").fontSize(17).fontColor(0x007AFF) }
                }
                .width(100.percent).height(44).padding(left: 16, right: 16).alignItems(VerticalAlign.Center)
                .onClick({ evt => this.saveAutoLock(4) })
            }
            .backgroundColor(0xFFFFFF)
            .borderRadius(12)
            .margin(left: 16, right: 16)

            Text("CHANGE PASSCODE")
                .fontSize(13)
                .fontColor(0x8E8E93)
                .margin(left: 16, top: 24, bottom: 8)
                .width(100.percent)

            Button(trSource("Change Passcode"))
                .width(100.percent)
                .height(48)
                .fontSize(16)
                .fontColor(0x007AFF)
                .backgroundColor(Color.Transparent)
                .borderRadius(12)
                .margin(left: 16, right: 16)
                .onClick({ evt => this.startChange() })

            Text("TURN OFF")
                .fontSize(13)
                .fontColor(0x8E8E93)
                .margin(left: 16, top: 24, bottom: 8)
                .width(100.percent)

            if (getAuthStorage().isLockedOut()) {
                Text("Too many failed attempts. Try again in ${getAuthStorage().getLockoutRemainingSeconds()} seconds.")
                    .fontSize(14)
                    .fontColor(0xFF3B30)
                    .margin(left: 16, right: 16, top: 8, bottom: 16)
                    .width(100.percent)
            } else if (this.isAlphanumericMode()) {
                Column {
                    TextInput(text: this.changeAlpha, placeholder: "Enter current passcode to disable")
                        .width(100.percent)
                        .height(44)
                        .backgroundColor(Color.Transparent)
                        .onChange({ value: String =>
                            this.changeAlpha = value
                            this.errorMessage = ""
                        })
                }
                .padding(left: 16, right: 16)
                .backgroundColor(0xFFFFFF)
                .borderRadius(12)
                .margin(left: 16, right: 16)

                Button("Turn Off Passcode")
                    .width(100.percent)
                    .height(48)
                    .fontSize(16)
                    .fontColor(0xFF3B30)
                    .backgroundColor(Color.Transparent)
                    .borderRadius(12)
                    .borderWidth(1)
                    .borderColor(0xFF3B30)
                    .margin(left: 16, right: 16, top: 16, bottom: 32)
                    .enabled(this.changeAlpha.size > 0)
                    .onClick({ evt => this.doDisablePasscode() })
            } else {
                Column {
                    Row {
                        PasscodeInputFieldComponent(
                            codeLength: this.codeLength(),
                            filledCount: Int32(this.disableCode.size),
                            showError: this.disableShowError
                        )
                    }
                    .margin(top: 12, bottom: 12)

                    this.buildDisableKeypad()
                }
                .padding(16)
                .backgroundColor(0xFFFFFF)
                .borderRadius(12)
                .margin(left: 16, right: 16, bottom: 32)
            }
        }
        .width(100.percent)
    }

    @Builder
    func buildDisableKeypad() {
        Row {
            Button("1").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onDisableDigit("1") })
            Button("2").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onDisableDigit("2") })
            Button("3").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).onClick({ evt => this.onDisableDigit("3") })
        }
        .width(100.percent)
        .margin(top: 8)

        Row {
            Button("4").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onDisableDigit("4") })
            Button("5").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onDisableDigit("5") })
            Button("6").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).onClick({ evt => this.onDisableDigit("6") })
        }
        .width(100.percent)
        .margin(top: 8)

        Row {
            Button("7").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onDisableDigit("7") })
            Button("8").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(right: 4).onClick({ evt => this.onDisableDigit("8") })
            Button("9").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).onClick({ evt => this.onDisableDigit("9") })
        }
        .width(100.percent)
        .margin(top: 8)

        Row {
            Blank().layoutWeight(1)
            Button("0").fontSize(22).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(left: 4).onClick({ evt => this.onDisableDigit("0") })
            Button("DEL").fontSize(16).layoutWeight(1).height(60).backgroundColor(0xE5E5EA).fontColor(0x000000).borderRadius(8).margin(left: 4).onClick({ evt => this.onDisableBackspace() })
        }
        .width(100.percent)
        .margin(top: 8)
    }

    @Builder
    func buildDisabledState() {
        Column {
            Text("Passcode lock is off. Set a passcode to protect your account.")
                .fontSize(14)
                .fontColor(0x8E8E93)
                .margin(left: 16, right: 16, top: 24, bottom: 16)
                .width(100.percent)

            Button("Turn On Passcode")
                .width(100.percent)
                .height(50)
                .fontSize(17)
                .fontColor(0xFFFFFF)
                .backgroundColor(0x007AFF)
                .borderRadius(12)
                .margin(left: 16, right: 16)
                .onClick({ evt => this.startSetup() })
        }
        .width(100.percent)
    }
    */

    private func disableSheetItems(): Array<ContextMenuItem> {
        return [
            ContextMenuItem(
                title: "Turn Passcode Off",
                destructive: true,
                onClick: { => this.doDisablePasscode() },
                centered: true
            ),
            ContextMenuItem.separator(),
            ContextMenuItem(
                title: "Cancel",
                onClick: { => this.showDisableSheet = false },
                centered: true
            )
        ]
    }

    @Builder
    func autoLockMenuContent() {
        Menu {
            MenuItem(startIcon: "", content: "Disabled", endIcon: this.autoLockCheckIcon(0), labelInfo: "", builder: None<() -> Unit>)
                .onClick({ _ => this.saveAutoLock(0) })
            MenuItem(startIcon: "", content: "If away for 1 min", endIcon: this.autoLockCheckIcon(1), labelInfo: "", builder: None<() -> Unit>)
                .onClick({ _ => this.saveAutoLock(1) })
            MenuItem(startIcon: "", content: "If away for 5 min", endIcon: this.autoLockCheckIcon(2), labelInfo: "", builder: None<() -> Unit>)
                .onClick({ _ => this.saveAutoLock(2) })
            MenuItem(startIcon: "", content: "If away for 1 hour", endIcon: this.autoLockCheckIcon(3), labelInfo: "", builder: None<() -> Unit>)
                .onClick({ _ => this.saveAutoLock(3) })
            MenuItem(startIcon: "", content: "If away for 5 hours", endIcon: this.autoLockCheckIcon(4), labelInfo: "", builder: None<() -> Unit>)
                .onClick({ _ => this.saveAutoLock(4) })
        }
    }

    @Builder
    func buildEnabledState() {
        Column {
            Column {
                Row {
                    Text(trSource("Turn Passcode Off"))
                        .fontSize(17)
                        .fontColor(0x007AFF)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Start)
                }
                .width(100.percent)
                .height(52)
                .padding(left: 16, right: 16)
                .alignItems(VerticalAlign.Center)
                .onClick({ _ => this.showDisableSheet = true })

                Divider().color(0xE5E5EA).strokeWidth(0.5).margin(left: 16)

                Row {
                    Text(trSource("Change Passcode"))
                        .fontSize(17)
                        .fontColor(0x007AFF)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Start)
                }
                .width(100.percent)
                .height(52)
                .padding(left: 16, right: 16)
                .alignItems(VerticalAlign.Center)
                .onClick({ _ => this.startChange() })
            }
            .width(100.percent)
            .backgroundColor(0xFFFFFF)
            .borderRadius(24)
            .clip(true)
            .margin(left: 16, right: 16, top: 24)

            Text("When a passcode is set, a lock icon appears above your chat list. Tap it to lock your Telegram app.")
                .fontSize(14)
                .fontColor(0x6D6D72)
                .textAlign(TextAlign.Start)
                .width(100.percent)
                .margin(left: 32, right: 32, top: 10)

            Text("Note: if you forget your passcode, you'll need to reinstall the app. All your Secret Chats will be lost.")
                .fontSize(14)
                .fontColor(0x6D6D72)
                .textAlign(TextAlign.Start)
                .width(100.percent)
                .margin(left: 32, right: 32, top: 16)

            Row {
                Text(trSource("Auto-Lock"))
                    .fontSize(17)
                    .fontColor(0x000000)
                    .layoutWeight(1)
                    .textAlign(TextAlign.Start)
                Text(this.autoLockDisclosure)
                    .fontSize(17)
                    .fontColor(0x8E8E93)
                    .margin(right: 8)
                    .opacity(if (this.showAutoLockMenu) { 0.5 } else { 1.0 })
                Image(@r(app.media.item_list_disclosure_arrow))
                    .width(7)
                    .height(12)
                    .fillColor(0x8E8E93)
                    .opacity(if (this.showAutoLockMenu) { 0.5 } else { 1.0 })
            }
            .width(100.percent)
            .height(52)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .backgroundColor(0xFFFFFF)
            .borderRadius(26)
            .margin(left: 16, right: 16, top: 28)
            .onClick({ _ => this.showAutoLockMenu = true })
            .bindPopup(
                this.showAutoLockMenu,
                CustomPopupOptions(
                    builder: bind(this.autoLockMenuContent, this),
                    placement: Placement.Bottom,
                    popupColor: Color.Transparent,
                    enableArrow: false,
                    autoCancel: true,
                    radius: 24.vp,
                    onStateChange: Option.Some({ evt: PopupStateChangeParam =>
                        if (!evt.isVisible) { this.showAutoLockMenu = false }
                    })
                )
            )

            if (this.biometricAvailable) {
                Row {
                    Text("Unlock with Biometrics")
                        .fontSize(17)
                        .fontColor(0x000000)
                        .layoutWeight(1)
                    Toggle(ToggleType.Switch, isOn: this.biometricEnabled)
                        .selectedColor(0x34C759)
                        .onChange({ _on: Bool => this.toggleBiometric() })
                }
                .width(100.percent)
                .constraintSize(minHeight: 52)
                .padding(left: 16, right: 16, top: 8, bottom: 8)
                .alignItems(VerticalAlign.Center)
                .backgroundColor(0xFFFFFF)
                .borderRadius(26)
                .margin(left: 16, right: 16, top: 16, bottom: 32)
            }
        }
        .width(100.percent)
    }

    @Builder
    func buildDisabledState() {
        Column {
            Column {
                Row {
                    Column {}
                        .width(31)
                        .height(42)
                        .borderWidth(2)
                        .borderColor(0xB7B7BA)
                        .borderRadius(5)
                    Column {}
                        .width(31)
                        .height(42)
                        .borderWidth(2)
                        .borderColor(0xB7B7BA)
                        .borderRadius(5)
                        .margin(left: 5)
                    Column {}
                        .width(31)
                        .height(42)
                        .borderWidth(2)
                        .borderColor(0xB7B7BA)
                        .borderRadius(5)
                        .margin(left: 5)
                    Column {}
                        .width(31)
                        .height(42)
                        .borderWidth(2)
                        .borderColor(0xB7B7BA)
                        .borderRadius(5)
                        .margin(left: 5)
                }
                .justifyContent(FlexAlign.Center)

                Image(@r(app.media.logout_ic_passcode))
                    .width(130)
                    .height(130)
                    .margin(top: 8)
            }
            .width(190)
            .height(190)
            .opacity(this.introAnimationOpacity)
            .animation(AnimateParam(duration: 500, curve: Curve.EaseOut))
            .onAppear({ => this.introAnimationOpacity = 1.0 })
            .margin(top: 170)

            Text(trSource("Passcode Lock"))
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor(0x6D6D72)
                .textAlign(TextAlign.Center)
                .width(100.percent)
                .margin(top: 24)

            Text("When a passcode is set, a lock icon appears above your chat list. Tap it to lock your Telegram app.")
                .fontSize(16)
                .fontColor(0x6D6D72)
                .textAlign(TextAlign.Center)
                .width(100.percent)
                .padding(left: 32, right: 32)
                .margin(top: 16)

            Button(trSource("Turn Passcode On"))
                .width(100.percent)
                .height(52)
                .fontSize(17)
                .fontColor(0x007AFF)
                .backgroundColor(0xFFFFFF)
                .borderRadius(26)
                .margin(left: 16, right: 16, top: 48)
                .onClick({ _ => this.startSetup() })

            Text("Note: if you forget your passcode, you'll need to reinstall the app. All your Secret Chats will be lost.")
                .fontSize(14)
                .fontColor(0x6D6D72)
                .textAlign(TextAlign.Center)
                .width(100.percent)
                .padding(left: 32, right: 32)
                .margin(top: 48, bottom: 32)
        }
        .width(100.percent)
        .alignItems(HorizontalAlign.Center)
    }
}

/**
 * 将密码字符串转为 UTF-8 字节数组
 */
func passcodeToBytes(code: String): Array<Byte> {
    let runes = code.toRuneArray()
    let result = Array<Byte>(runes.size, repeat: 0)
    var i: Int64 = 0
    while (i < runes.size) {
        result[i] = UInt8(UInt32(runes[i]) & 0xFF)
        i = i + 1
    }
    return result
}

// ==================== 全局锁状态管理 ====================

private var _appLocked: Bool = true

/**
 * 检查 app 是否被锁定
 */
public func isAppLocked(): Bool {
    let storage = getAuthStorage()
    if (!storage.hasPasscode()) {
        return false
    }
    return _appLocked
}

/**
 * 设置 app 锁定状态
 */
public func setAppLocked(locked: Bool): Unit {
    _appLocked = locked
}

/**
 * 验证密码并解锁
 */
public func verifyAndUnlock(code: String): Bool {
    let bytes = passcodeToBytes(code)
    let hash = SHA256.hash(bytes)
    let hexHash = ByteUtils.toHex(hash)
    let storage = getAuthStorage()
    let storedHash = storage.getPasscodeHash()
    if (hexHash == storedHash) {
        _appLocked = false
        Hilog.info(0, "CjTelegram", "[AppLock] Passcode verified, unlocked")
        return true
    }
    Hilog.info(0, "CjTelegram", "[AppLock] Passcode incorrect")
    return false
}
