package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * InstantPageSettingsPage — Instant View reading settings panel (P2-215)
 *
 * Allows user to change:
 *   - Font size: XXSmall / XSmall / Small / Standard / Large / XLarge / XXLarge
 *   - Theme: Light / Sepia / Dark / Night
 *   - Font family: Sans-Serif (default) / Serif
 *
 * Settings are persisted to Preferences via saveInstantPageSettings()
 * and become effective immediately when user returns to InstantPagePage
 * (page calls refreshSettings() in ensureLoaded).
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry；去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹（.title/.hideTitleBar 一并去掉），只留内部 Scroll
 *  - aboutToAppear 有实逻辑（loadInstantPageSettings）→ ensureLoaded()（.onAppear 触发）
 */
@HybridComponentEntry
@Component
public class InstantPageSettingsPage {
    @State var currentTheme: InstantPageTheme = InstantPageTheme.Light
    @State var currentFontSize: InstantPageFontSize = InstantPageFontSize.Standard
    @State var currentForceSerif: Bool = false
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let s = loadInstantPageSettings()
        this.currentTheme = s.theme
        this.currentFontSize = s.fontSize
        this.currentForceSerif = s.forceSerif
    }

    // Preview background / text colors derived from currentTheme
    private func previewBg(): Int64 {
        return match (this.currentTheme) {
            case InstantPageTheme.Light => 0xFFFFFF
            case InstantPageTheme.Sepia => 0xFBF0D9
            case InstantPageTheme.Dark  => 0x2B2B2B
            case InstantPageTheme.Night => 0x000000
        }
    }

    private func previewText(): Int64 {
        return match (this.currentTheme) {
            case InstantPageTheme.Light => 0x222222
            case InstantPageTheme.Sepia => 0x3D2B1F
            case InstantPageTheme.Dark  => 0xDDDDDD
            case InstantPageTheme.Night => 0xCCCCCC
        }
    }

    private func fontSizeName(sz: InstantPageFontSize): String {
        return match (sz) {
            case InstantPageFontSize.XXSmall  => "XXS"
            case InstantPageFontSize.XSmall   => "XS"
            case InstantPageFontSize.Small    => "S"
            case InstantPageFontSize.Standard => "A"
            case InstantPageFontSize.Large    => "L"
            case InstantPageFontSize.XLarge   => "XL"
            case InstantPageFontSize.XXLarge  => "XXL"
        }
    }

    private func fontSizeVp(sz: InstantPageFontSize): Float64 {
        return match (sz) {
            case InstantPageFontSize.XXSmall  => 12.0
            case InstantPageFontSize.XSmall   => 13.0
            case InstantPageFontSize.Small    => 14.0
            case InstantPageFontSize.Standard => 16.0
            case InstantPageFontSize.Large    => 19.0
            case InstantPageFontSize.XLarge   => 22.0
            case InstantPageFontSize.XXLarge  => 26.0
        }
    }

    private func themeLabel(t: InstantPageTheme): String {
        return match (t) {
            case InstantPageTheme.Light => "Light"
            case InstantPageTheme.Sepia => "Sepia"
            case InstantPageTheme.Dark  => "Dark"
            case InstantPageTheme.Night => "Night"
        }
    }

    private func themeBgColor(t: InstantPageTheme): Int64 {
        return match (t) {
            case InstantPageTheme.Light => 0xFFFFFF
            case InstantPageTheme.Sepia => 0xFBF0D9
            case InstantPageTheme.Dark  => 0x2B2B2B
            case InstantPageTheme.Night => 0x000000
        }
    }

    private func isCurrentTheme(t: InstantPageTheme): Bool {
        return match (t) {
            case InstantPageTheme.Light =>
                match (this.currentTheme) { case InstantPageTheme.Light => true; case _ => false }
            case InstantPageTheme.Sepia =>
                match (this.currentTheme) { case InstantPageTheme.Sepia => true; case _ => false }
            case InstantPageTheme.Dark =>
                match (this.currentTheme) { case InstantPageTheme.Dark => true; case _ => false }
            case InstantPageTheme.Night =>
                match (this.currentTheme) { case InstantPageTheme.Night => true; case _ => false }
        }
    }

    private func isCurrentFontSize(sz: InstantPageFontSize): Bool {
        return match (sz) {
            case InstantPageFontSize.XXSmall =>
                match (this.currentFontSize) { case InstantPageFontSize.XXSmall => true; case _ => false }
            case InstantPageFontSize.XSmall =>
                match (this.currentFontSize) { case InstantPageFontSize.XSmall => true; case _ => false }
            case InstantPageFontSize.Small =>
                match (this.currentFontSize) { case InstantPageFontSize.Small => true; case _ => false }
            case InstantPageFontSize.Standard =>
                match (this.currentFontSize) { case InstantPageFontSize.Standard => true; case _ => false }
            case InstantPageFontSize.Large =>
                match (this.currentFontSize) { case InstantPageFontSize.Large => true; case _ => false }
            case InstantPageFontSize.XLarge =>
                match (this.currentFontSize) { case InstantPageFontSize.XLarge => true; case _ => false }
            case InstantPageFontSize.XXLarge =>
                match (this.currentFontSize) { case InstantPageFontSize.XXLarge => true; case _ => false }
        }
    }

    func applyAndSave(): Unit {
        let s = InstantPageSettings()
        s.theme = this.currentTheme
        s.fontSize = this.currentFontSize
        s.forceSerif = this.currentForceSerif
        let _ = spawn {
            saveInstantPageSettings(s)
        }
        Hilog.info(0, "CjTelegram", "[IPSettings] applied and saving")
    }

    private func previewFontSize(): Float64 { return this.fontSizeVp(this.currentFontSize) }
    private func previewFontFamily(): String {
        if (this.currentForceSerif) { return "serif" } else { return "sans-serif" }
    }

    // ── Font size button builders ──

    @Builder
    func fontSizeButton(sz: InstantPageFontSize) {
        Button(this.fontSizeName(sz))
            .onClick({ _ =>
                let newSz = sz
                this.currentFontSize = newSz
                this.applyAndSave()
            })
            .backgroundColor(if (this.isCurrentFontSize(sz)) { 0x2563EB } else { 0xF0F0F0 })
            .fontColor(if (this.isCurrentFontSize(sz)) { 0xFFFFFF } else { 0x333333 })
            .fontSize(this.fontSizeVp(sz))
            .width(44)
            .height(44)
            .borderRadius(8)
    }

    // ── Theme picker builder ──

    @Builder
    func themeButton(t: InstantPageTheme) {
        Column {
            Column {}
                .width(44)
                .height(44)
                .backgroundColor(this.themeBgColor(t))
                .borderRadius(8)
                .borderWidth(if (this.isCurrentTheme(t)) { 2 } else { 1 })
                .borderColor(if (this.isCurrentTheme(t)) { 0x2563EB } else { 0xCCCCCC })
            Text(this.themeLabel(t))
                .fontSize(11)
                .fontColor(0x555555)
                .textAlign(TextAlign.Center)
                .margin(top: 4)
        }
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ =>
            let newT = t
            this.currentTheme = newT
            this.applyAndSave()
        })
    }

    public func build() {
        Scroll() {
            Column {
                // Preview area
                Column {
                    Text("The quick brown fox jumps over the lazy dog.")
                        .fontSize(this.previewFontSize())
                        .fontColor(this.previewText())
                        .fontFamily(this.previewFontFamily())
                        .textAlign(TextAlign.Start)
                        .width(100.percent)
                }
                .width(100.percent)
                .backgroundColor(this.previewBg())
                .padding(left: 16, right: 16, top: 16, bottom: 16)
                .margin(bottom: 16)
                .borderRadius(10)

                // Font size row
                Column {
                    Text("Font Size")
                        .fontSize(13)
                        .fontColor(0x888888)
                        .textAlign(TextAlign.Start)
                        .width(100.percent)
                        .margin(bottom: 12)
                    Row {
                        this.fontSizeButton(InstantPageFontSize.XXSmall)
                        this.fontSizeButton(InstantPageFontSize.XSmall)
                        this.fontSizeButton(InstantPageFontSize.Small)
                        this.fontSizeButton(InstantPageFontSize.Standard)
                        this.fontSizeButton(InstantPageFontSize.Large)
                        this.fontSizeButton(InstantPageFontSize.XLarge)
                        this.fontSizeButton(InstantPageFontSize.XXLarge)
                    }
                    .width(100.percent)
                    .justifyContent(FlexAlign.SpaceAround)
                }
                .width(100.percent)
                .backgroundColor(0xFFFFFF)
                .padding(left: 16, right: 16, top: 14, bottom: 14)
                .borderRadius(10)
                .margin(bottom: 12)

                // Theme picker row
                Column {
                    Text("Theme")
                        .fontSize(13)
                        .fontColor(0x888888)
                        .textAlign(TextAlign.Start)
                        .width(100.percent)
                        .margin(bottom: 12)
                    Row {
                        this.themeButton(InstantPageTheme.Light)
                        this.themeButton(InstantPageTheme.Sepia)
                        this.themeButton(InstantPageTheme.Dark)
                        this.themeButton(InstantPageTheme.Night)
                    }
                    .width(100.percent)
                    .justifyContent(FlexAlign.SpaceAround)
                }
                .width(100.percent)
                .backgroundColor(0xFFFFFF)
                .padding(left: 16, right: 16, top: 14, bottom: 14)
                .borderRadius(10)
                .margin(bottom: 12)

                // Serif toggle
                Column {
                    Row {
                        Text("Serif Font")
                            .fontSize(16)
                            .fontColor(0x222222)
                            .layoutWeight(1)
                        Toggle(ToggleType.Switch, isOn: this.currentForceSerif)
                            .onChange({ isOn: Bool =>
                                this.currentForceSerif = isOn
                                this.applyAndSave()
                            })
                            .selectedColor(0x2563EB)
                    }
                    .width(100.percent)
                }
                .width(100.percent)
                .backgroundColor(0xFFFFFF)
                .padding(left: 16, right: 16, top: 14, bottom: 14)
                .borderRadius(10)
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 16, bottom: 32)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
