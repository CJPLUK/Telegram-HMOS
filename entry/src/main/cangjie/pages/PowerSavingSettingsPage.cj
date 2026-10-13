package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.battery_info.BatteryInfo
import ohos.resource.{__GenerateResource__, AppResource}
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getTelegramCoreSettingsService, getUndoToastService}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation, PresentationStringsSnapshot, currentPresentationStrings}

/**
 * Power Saving Settings Page（混合工程迁移版）
 *
 * iOS reference: EnergySavingSettingsScreen.swift
 *
 * Master toggle: activation threshold slider (0-100).
 *   threshold <= 4  => power saving never activates (always off mode)
 *   threshold >= 96 => power saving always active
 *   else            => activates when battery drops below threshold %
 *
 * Per-feature energy toggles (correspond to EnergyUsageSettings fields):
 *   autoplayVideo, autoplayGif, loopStickers, loopEmoji,
 *   fullTranslucency, extendBgWork, autodownloadBg
 *
 * All state is back-filled from TelegramCoreSettingsService in ensureLoaded.
 * Persisted via AuthStorage (Preferences).
 *
 * Consumer defer: the per-feature flags are stored and available to consumers
 * (e.g. MediaPlayer, StickerView) via getTelegramCoreSettingsService().getPsAutoplayVideo()
 * etc., but wiring into actual playback/animation call sites is deferred to respective
 * feature units. This page owns the settings storage; consumption is cross-feature.
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹 + .hideTitleBar(true)，只留内容
 *  - pageStack.pop() → routerPop()
 *  - aboutToAppear 有实逻辑（读服务）→ ensureLoaded()+.onAppear
 */
@HybridComponentEntry
@Component
public class PowerSavingSettingsPage {
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @StorageLink["presentationStrings"] var strings: PresentationStringsSnapshot = currentPresentationStrings()

    private func text(key: String, fallback: String): String {
        return this.strings.getOr(key, fallback)
    }
    // Master threshold (0-100). Default 15 (iOS default).
    @State var psThreshold: Float64 = Float64(getTelegramCoreSettingsService().getPsThreshold())

    // Per-feature toggles (true = feature is enabled / NOT reduced)
    @State var autoplayVideo: Bool = getTelegramCoreSettingsService().getPsAutoplayVideo()
    @State var autoplayGif: Bool = getTelegramCoreSettingsService().getPsAutoplayGif()
    @State var loopStickers: Bool = getTelegramCoreSettingsService().getPsLoopStickers()
    @State var loopEmoji: Bool = getTelegramCoreSettingsService().getPsLoopEmoji()
    @State var fullTranslucency: Bool = getTelegramCoreSettingsService().getPsFullTranslucency()
    @State var extendBgWork: Bool = getTelegramCoreSettingsService().getPsExtendBgWork()
    @State var autodownloadBg: Bool = getTelegramCoreSettingsService().getPsAutodownloadBg()
    @State var batterySoc: Int32 = BatteryInfo.batterySoc
    @State var loaded: Bool = false

    // S7-156/S7-157: load the persisted values before the first build. Toggle(isOn:) keeps
    // the value it was created with, so loading in onAppear (after the first frame) left every
    // switch showing its default On after re-entry even though the stored value was Off.
    public override func aboutToAppear(): Unit {
        this.ensureLoaded()
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let svc = getTelegramCoreSettingsService()
        this.psThreshold = Float64(svc.getPsThreshold())
        this.autoplayVideo = svc.getPsAutoplayVideo()
        this.autoplayGif = svc.getPsAutoplayGif()
        this.loopStickers = svc.getPsLoopStickers()
        this.loopEmoji = svc.getPsLoopEmoji()
        this.fullTranslucency = svc.getPsFullTranslucency()
        this.extendBgWork = svc.getPsExtendBgWork()
        this.autodownloadBg = svc.getPsAutodownloadBg()
        this.batterySoc = BatteryInfo.batterySoc
    }

    private func saveThreshold(value: Float64): Unit {
        let clamped: Int32 = if (value < 4.0) {
            4
        } else if (value > 96.0) {
            96
        } else {
            Int32(value)
        }
        let svc = getTelegramCoreSettingsService()
        svc.savePsThreshold(clamped)
        this.psThreshold = Float64(clamped)
        Hilog.info(0, "CjTelegram", "[PowerSaving] threshold=${clamped}")
    }

    private func thresholdLabel(): String {
        if (this.psThreshold <= 4.0) {
            return this.text("PowerSaving.AllDescriptionNever", "Don’t disable all resource-intensive processes even when the battery is low.")
        } else if (this.psThreshold >= 96.0) {
            return this.text("PowerSaving.AllDescriptionAlways", "Always disable all resource-intensive processes, regardless of the battery charge level.")
        } else {
            return this.text("PowerSaving.AllDescriptionLimit", "Automatically disable all resource-intensive processes when your battery is below %@%.")
                .replace("%@", "${Int64(this.psThreshold)}")
        }
    }

    private func masterHeaderLabel(): String {
        if (this.psThreshold <= 4.0) {
            return this.text("PowerSavingScreen.ToggleHeaderEmpty", "POWER SAVING MODE")
        } else if (this.psThreshold >= 96.0) {
            return this.text("PowerSavingScreen.ToggleHeaderEmpty", "POWER SAVING MODE")
        } else if (this.powerSavingIsOn()) {
            return this.text("PowerSavingScreen.ToggleHeaderOn", "POWER SAVING MODE (ON)")
        } else {
            return this.text("PowerSavingScreen.ToggleHeaderOff", "POWER SAVING MODE (OFF)")
        }
    }

    private func powerSavingIsOn(): Bool {
        if (this.psThreshold <= 4.0) { return false }
        if (this.psThreshold >= 96.0) { return true }
        if (this.batterySoc < 0) { return false }
        return this.batterySoc <= Int32(this.psThreshold)
    }

    /**
     * S7-151：iOS EnergySavingSettingsScreen.swift:244-252 itemsEnabled —— 滑块拖到最右端
     * （>= 96，Always On）时下方各开关不可切换；点按只弹 PowerSavingScreen_OptionChangeAlertAlways。
     * 阈值 <= 4（Always Off）可切换；区间内只在省电模式未因电量激活时可切换。
     * 必须在 builder 内直接读 @State（经参数传入会在 Toggle 首帧固化）。
     */
    private func itemsEnabled(): Bool {
        if (this.psThreshold <= 4.0) { return true }
        if (this.psThreshold >= 96.0) { return false }
        return !this.powerSavingIsOn()
    }

    private func thresholdCenterLabel(): String {
        if (this.psThreshold <= 4.0) {
            return this.text("PowerSaving.BatteryLevelLimit.AlwaysOff", "Always Off")
        }
        if (this.psThreshold >= 96.0) {
            return this.text("PowerSaving.BatteryLevelLimit.AlwaysOn", "Always On")
        }
        return this.text("PowerSaving.BatteryLevelLimit.WhenBelow", "When Below %@%")
            .replace("%@", "${Int64(this.psThreshold)}")
    }

    private func displayDisabledTooltip(): Unit {
        let message = if (this.psThreshold >= 96.0) {
            this.text("PowerSavingScreen.OptionChangeAlertAlways", "Turn off Power Saving Mode to change these settings.")
        } else {
            this.text("PowerSavingScreen.OptionChangeAlertConditional", "Turn off Power Saving Mode or charge your phone to change these settings.")
        }
        getUndoToastService().showUndo(
            message,
            iconRes: Some(@r(app.media.callui_ic_toast_battery)),
            durationMs: 5000,
            showProgress: false,
            showAction: false,
            onUndo: { => () },
            onCommit: { => () }
        )
    }

    private func saveAutoplayVideo(v: Bool): Unit {
        getTelegramCoreSettingsService().savePsAutoplayVideo(v)
        this.autoplayVideo = v
    }

    private func saveAutoplayGif(v: Bool): Unit {
        getTelegramCoreSettingsService().savePsAutoplayGif(v)
        this.autoplayGif = v
    }
    private func saveLoopStickers(v: Bool): Unit {
        getTelegramCoreSettingsService().savePsLoopStickers(v)
        this.loopStickers = v
    }
    private func saveLoopEmoji(v: Bool): Unit {
        getTelegramCoreSettingsService().savePsLoopEmoji(v)
        this.loopEmoji = v
    }
    private func saveFullTranslucency(v: Bool): Unit {
        getTelegramCoreSettingsService().savePsFullTranslucency(v)
        this.fullTranslucency = v
    }
    private func saveExtendBgWork(v: Bool): Unit {
        getTelegramCoreSettingsService().savePsExtendBgWork(v)
        this.extendBgWork = v
    }
    private func saveAutodownloadBg(v: Bool): Unit {
        getTelegramCoreSettingsService().savePsAutodownloadBg(v)
        this.autodownloadBg = v
    }

    @Builder
    func buildToggleRow(
        rowIcon: AppResource,
        rowIconColor: UInt32,
        rowLabel: String,
        rowSubtitle: String,
        rowIsOn: Bool,
        rowOnChanged: (Bool) -> Unit
    ) {
        Column {
            Row {
                Stack(alignContent: Alignment.Center) {
                    Row {}.width(30).height(30).borderRadius(8).backgroundColor(rowIconColor)
                    Image(rowIcon).width(30).height(30).objectFit(ImageFit.Contain)
                }.width(30).height(30).margin(right: 14)
                Column {
                    Text(rowLabel)
                        .fontSize(17)
                        .fontColor(this.presentation.textColor)
                        .width(100.percent)
                    Text(rowSubtitle)
                        .fontSize(13)
                        .fontColor(this.presentation.secondaryTextColor)
                        .width(100.percent)
                        .margin(top: 2)
                }
                .layoutWeight(1)
                // iOS EnergySavingSettingsScreen.swift:257：value = 存储值 && itemsEnabled，
                // 省电生效时只是“显示为关”，存储值不动。
                Toggle(ToggleType.Switch, isOn: rowIsOn && this.itemsEnabled())
                    .selectedColor(0x34C759)
                    // S7-151：省电模式生效时开关不可切换（在 builder 内直接读 @State，不经参数）
                    .enabled(this.itemsEnabled())
                    .onChange({ value: Bool =>
                        // isOn 被 itemsEnabled 程序化翻成 false 时 Toggle 也会回调 onChange(false)；
                        // 此时不得写库，否则滑块回到阈值内后各项停留在 OFF（S7-151 回归）。
                        if (this.itemsEnabled()) {
                            rowOnChanged(value)
                        }
                    })
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 12, bottom: 12)
            .alignItems(VerticalAlign.Center)
            .opacity(if (this.itemsEnabled()) { 1.0 } else { 0.5 })
            .onClick({ _ =>
                if (!this.itemsEnabled()) { this.displayDisabledTooltip() }
            })
        }
        .width(100.percent)
        .backgroundColor(this.presentation.cardColor)
    }

    @Builder
    func buildDivider() {
        Row {
            Row { }
                .layoutWeight(1)
                .height(1)
                .backgroundColor(this.presentation.dividerColor)
        }
        .width(100.percent)
        .padding(left: 60)
    }

    @Builder
    func batteryIndicator() {
        Stack(alignContent: Alignment.Start) {
            Row {}
                .width(25).height(12).border(width: 1, color: this.presentation.secondaryTextColor)
                .borderRadius(4)
            Row {}
                .width(if (this.psThreshold <= 0.0) { 2.0 } else { 21.0 * this.psThreshold / 100.0 })
                .height(8).borderRadius(2)
                .backgroundColor(if (this.psThreshold <= 20.0) { 0xFFFF3B30 } else { 0xFF34C759 })
                .margin(left: 2)
            Row {}.width(2).height(5).borderRadius(1)
                .backgroundColor(this.presentation.secondaryTextColor).position(x: 26, y: 5)
        }.width(30).height(16)
    }

    public func build() {
        Column {
            Row {
                Stack(alignContent: Alignment.Center) {
                    Image(@r(app.media.callui_v2_back))
                        .width(10).height(18).fillColor(this.presentation.textColor)
                }
                .width(44).height(44).borderRadius(22)
                .backgroundColor(this.presentation.cardColor)
                .onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
                Text(trSource("Power Saving"))
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.presentation.textColor)
                Blank().layoutWeight(1)
                Row { }.width(44)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(this.presentation.backgroundColor)
            .alignItems(VerticalAlign.Center)

            Scroll {
                Column {
                    // Section: Master threshold slider
                    Text(this.masterHeaderLabel())
                        .fontSize(13)
                        .fontColor(this.presentation.secondaryTextColor)
                        .margin(left: 16, top: 16, bottom: 8)
                        .width(100.percent)

                    Column {
                        Row {
                            Text(this.text("PowerSaving.BatteryLevelLimit.Off", "Off"))
                                .fontSize(13)
                                .fontColor(this.presentation.secondaryTextColor)
                            Blank().layoutWeight(1)
                            Row {
                                Text(this.thresholdCenterLabel())
                                    .fontSize(17).fontColor(this.presentation.textColor)
                                this.batteryIndicator()
                            }.alignItems(VerticalAlign.Center).margin(left: 8, right: 8)
                            Blank().layoutWeight(1)
                            Text(this.text("PowerSaving.BatteryLevelLimit.On", "On"))
                                .fontSize(13)
                                .fontColor(this.presentation.secondaryTextColor)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 12, bottom: 4)

                        Slider(
                            value: this.psThreshold,
                            min: 4.0,
                            max: 96.0,
                            step: 1.0,
                            style: SliderStyle.OutSet
                        )
                        .selectedColor(this.presentation.accentColor)
                        .trackColor(this.presentation.dividerColor)
                        .width(100.percent)
                        .padding(left: 16, right: 16, bottom: 12)
                        .onChange({ value: Float64, mode: SliderChangeMode =>
                            this.saveThreshold(value)
                        })
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(10)
                    .clip(true)
                    .margin(left: 16, right: 16)

                    Text(this.thresholdLabel())
                        .fontSize(13)
                        .fontColor(this.presentation.secondaryTextColor)
                        .margin(left: 32, right: 32, top: 8, bottom: 16)
                        .width(100.percent)

                    // Section: Per-feature energy toggles
                    Text(this.text("PowerSavingScreen.OptionsHeader", "RESOURCE-INTENSIVE PROCESSES"))
                        .fontSize(13)
                        .fontColor(this.presentation.secondaryTextColor)
                        .margin(left: 16, top: 0, bottom: 8)
                        .width(100.percent)

                    Column {
                        this.buildToggleRow(
                            @r(app.media.powersave_video), 0xFFFF453A,
                            this.text("PowerSavingScreen.OptionAutoplayVideoTitle", "Autoplay Videos"),
                            this.text("PowerSavingScreen.OptionAutoplayVideoText", "Autoplay and loop videos and video messages in chats."),
                            this.autoplayVideo,
                            { v: Bool => this.saveAutoplayVideo(v) }
                        )
                        this.buildDivider()
                        this.buildToggleRow(
                            @r(app.media.powersave_gif), 0xFFFF9F0A,
                            this.text("PowerSavingScreen.OptionAutoplayGifTitle", "Autoplay GIFs"),
                            this.text("PowerSavingScreen.OptionAutoplayGifText", "Autoplay and loop GIFs in chats and in the keyboard."),
                            this.autoplayGif,
                            { v: Bool => this.saveAutoplayGif(v) }
                        )
                        this.buildDivider()
                        this.buildToggleRow(
                            @r(app.media.powersave_sticker), 0xFF34C759,
                            this.text("PowerSavingScreen.OptionAutoplayStickersTitle", "Sticker Animations"),
                            this.text("PowerSavingScreen.OptionAutoplayStickersText", "Loop animated stickers, play full-screen premium effects."),
                            this.loopStickers,
                            { v: Bool => this.saveLoopStickers(v) }
                        )
                        this.buildDivider()
                        this.buildToggleRow(
                            @r(app.media.powersave_emoji), 0xFF00C7BE,
                            this.text("PowerSavingScreen.OptionAutoplayEmojiTitle", "Emoji Animations"),
                            this.text("PowerSavingScreen.OptionAutoplayEmojiText", "Loop animated emoji in messages, reactions, statuses."),
                            this.loopEmoji,
                            { v: Bool => this.saveLoopEmoji(v) }
                        )
                        this.buildDivider()
                        this.buildToggleRow(
                            @r(app.media.powersave_effect), 0xFF32ADE6,
                            this.text("PowerSavingScreen.OptionAutoplayEffectsTitle", "Interface Effects"),
                            this.text("PowerSavingScreen.OptionAutoplayEffectsText", "Various effects and animations that make Telegram look amazing."),
                            this.fullTranslucency,
                            { v: Bool => this.saveFullTranslucency(v) }
                        )
                        this.buildDivider()
                        this.buildToggleRow(
                            @r(app.media.powersave_photo), 0xFF0079FF,
                            this.text("PowerSavingScreen.OptionPreloadTitle", "Preload Media"),
                            this.text("PowerSavingScreen.OptionPreloadText", "Start loading media while in the chat list for faster access."),
                            this.autodownloadBg,
                            { v: Bool => this.saveAutodownloadBg(v) }
                        )
                        this.buildDivider()
                        this.buildToggleRow(
                            @r(app.media.powersave_clock), 0xFFAF52DE,
                            this.text("PowerSavingScreen.OptionBackgroundTitle", "Extended Background Time"),
                            this.text("PowerSavingScreen.OptionBackgroundText", "Update chats faster when switching between apps."),
                            this.extendBgWork,
                            { v: Bool => this.saveExtendBgWork(v) }
                        )
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(10)
                    .clip(true)
                    .margin(left: 16, right: 16)

                }
                .width(100.percent)
            }
            .layoutWeight(1)
            .backgroundColor(this.presentation.backgroundColor)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.presentation.backgroundColor)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
