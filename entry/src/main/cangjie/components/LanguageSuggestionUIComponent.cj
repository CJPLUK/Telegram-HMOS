package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getLanguageSuggestionService}
import ohos_app_cangjie_entry.models.LanguageInfo
import ohos.resource.__GenerateResource__

/**
 * Language Suggestion UI Component (LanguageSuggestionUI)
 *
 * Banner/prompt suggesting a language change based on system locale.
 * Shows when a different language is suggested (e.g. system is zh-Hans, app is en).
 *
 * iOS source: Telegram-iOS/submodules/LanguageSuggestionUI/LanguageSuggestionController.swift
 *
 * Usage: Embed in Settings or first-run flow. onDismiss/onApply callbacks.
 */
@Component
public class LanguageSuggestionUIComponent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    public var onDismiss: () -> Unit = { => }
    public var onApply: (String) -> Unit = { _: String => }

    @State var suggestedTitle: String = ""
    @State var suggestedSubtitle: String = ""
    @State var suggestedCode: String = ""
    @State var isLoading: Bool = true
    @State var isApplying: Bool = false

    protected override func aboutToAppear(): Unit {
        this.loadSuggestion()
    }

    private func loadSuggestion(): Unit {
        this.isLoading = true
        this.suggestedTitle = ""
        this.suggestedSubtitle = ""
        this.suggestedCode = ""
        spawn {
            let service = getLanguageSuggestionService()
            let result = service.getSuggestedLanguage()
            launch {
                this.isLoading = false
                match (result) {
                    case Some(lang) =>
                        this.suggestedTitle = "Switch to " + lang.nativeName + "?"
                        this.suggestedSubtitle = "Your language (" + lang.name + ") is available."
                        this.suggestedCode = lang.langCode
                    case None =>
                        ()
                }
            }
        }
    }

    private func handleApply(): Unit {
        if (this.suggestedCode.size == 0) {
            this.onDismiss()
            return
        }
        this.isApplying = true
        let code = this.suggestedCode
        let dismissCb = this.onDismiss
        let applyCb = this.onApply
        spawn {
            let service = getLanguageSuggestionService()
            let _ = service.applyLanguage(code)
            launch {
                this.isApplying = false
                applyCb(code)
                dismissCb()
            }
        }
    }

    private func hasSuggestion(): Bool {
        return this.suggestedCode.size > 0
    }

    public func build() {
        if (this.isLoading) {
            Column { }
        } else if (this.hasSuggestion()) {
            Column {
                Row {
                    Column {
                        // 资源保真修复：真实矢量图标（Item List/Icons/Language.imageset 转 SVG）替代 emoji 字形
                        Image(@r(app.media.misc_ic_globe))
                            .width(16)
                            .height(16)
                            .fillColor(0xFFFFFFFF)
                    }
                    .width(40)
                    .height(40)
                    .borderRadius(8)
                    .backgroundColor(0x5856D6)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .margin(right: 12)

                    Column {
                        Text(this.suggestedTitle)
                            .fontSize(16)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0x000000)
                        Text(this.suggestedSubtitle)
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .margin(top: 2)
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    if (this.isApplying) {
                        LoadingProgress()
                            .width(24)
                            .height(24)
                    } else {
                        Row {
                            Text("Not now")
                                .fontSize(15)
                                .fontColor(0x8E8E93)
                                .onClick({ evt => this.onDismiss() })
                            Text(trSource("Switch"))
                                .fontSize(15)
                                .fontColor(0x317AFF)
                                .fontWeight(FontWeight.Medium)
                                .margin(left: 16)
                                .onClick({ evt => this.handleApply() })
                        }
                    }
                }
                .width(100.percent)
                .padding(16)
                .backgroundColor(0xFFFFFF)
                .borderRadius(12)
                .alignItems(VerticalAlign.Center)
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 8, bottom: 8)
        } else {
            Column { }
        }
    }
}
