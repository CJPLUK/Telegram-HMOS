package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation}
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getLanguageLinkPreviewService, getPendingLanguagePreviewIdentifier, LocalizationPreviewInfo}
import std.collection.ArrayList

/**
 * LanguageLinkPreviewComponent — t.me/setlanguage/<id> "Change Language?" sheet.
 *
 * iOS: LanguageLinkPreviewController (requestLocalizationPreview → setData / activate →
 * downloadAndApplyLocalization → dismiss), LanguageLinkPreviewControllerNode (dim 0.5, content
 * card + "Change" action 57pt, separate "Cancel" button 57pt, 16pt corners, width - 20) and
 * LanguageLinkPreviewContentNode (title medium 18, markdown body regular/semibold 15, centered).
 */
@Component
public class LanguageLinkPreviewComponent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    public var identifier: String = ""
    public var onClose: () -> Unit = { => }
    /** Runs the download + apply off the UI thread and reports success. */
    public var onApply: (String) -> Bool = { _: String => false }
    public var onApplied: () -> Unit = { => }
    public var onOpenUrl: (String) -> Unit = { _: String => }

    @State var previewInfo: Option<LocalizationPreviewInfo> = None<LocalizationPreviewInfo>
    @State var isLoading: Bool = true
    @State var inProgress: Bool = false
    // Replaces the content when iOS would present a text alert instead of the preview.
    @State var messageText: String = ""

    protected override func aboutToAppear(): Unit {
        if (this.identifier.size == 0) {
            this.identifier = getPendingLanguagePreviewIdentifier()
        }
        this.loadPreview()
    }

    private func str(key: String, fallback: String): String {
        return this.sourceLocalizationPresentation.getOr(key, fallback)
    }

    private func loadPreview(): Unit {
        Hilog.info(0, "CjTelegram", "[LanguageLinkPreview] loadPreview identifier=${this.identifier}")
        if (this.identifier.size == 0) {
            this.isLoading = false
            this.messageText = this.str("ApplyLanguage_LanguageNotSupportedError", "Sorry, this language doesn't seem to exist.")
            return
        }
        this.isLoading = true
        let id = this.identifier
        spawn {
            let result = getLanguageLinkPreviewService().requestPreview(id)
            launch {
                this.isLoading = false
                match (result) {
                    case Some(info) =>
                        // LanguageLinkPreviewController.swift:71-73 — the active language only
                        // gets the "already active" alert.
                        if (info.langCode == getAuthStorage().getLangCode()) {
                            this.messageText = this.str("ApplyLanguage_ChangeLanguageAlreadyActive", "The language %1$@ is already active.")
                                .replace("%1$@", info.title)
                        } else {
                            this.previewInfo = Some(info)
                        }
                    case None =>
                        this.messageText = this.str("ApplyLanguage_LanguageNotSupportedError", "Sorry, this language doesn't seem to exist.")
                }
            }
        }
    }

    /** LanguageLinkPreviewContentNode.swift:32 */
    private func completionScore(info: LocalizationPreviewInfo): Int32 {
        let total: Int32 = if (info.totalStringCount > 1) { info.totalStringCount } else { 1 }
        let score: Int32 = info.translatedStringCount * 100 / total
        return if (score > 100) { 100 } else { score }
    }

    private func titleText(): String {
        match (this.previewInfo) {
            case Some(info) =>
                if (info.totalStringCount == 0) {
                    return this.str("ApplyLanguage_UnsufficientDataTitle", "Insufficient Data")
                }
                return this.str("ApplyLanguage_ChangeLanguageTitle", "Change Language?")
            case None => return ""
        }
    }

    /** LanguageLinkPreviewContentNode.swift:35-45 */
    private func bodyText(): String {
        if (this.messageText.size > 0) { return this.messageText }
        match (this.previewInfo) {
            case Some(info) =>
                if (info.totalStringCount == 0) {
                    return this.str("ApplyLanguage_UnsufficientDataText",
                        "Unfortunately, this custom language pack (%1$@) doesn't contain data for Telegram iOS. You can contribute to this language pack using the [translations platform]()")
                        .replace("%1$@", info.title)
                }
                if (!info.isOfficial) {
                    return this.str("ApplyLanguage_ChangeLanguageUnofficialText",
                        "You are about to apply a custom language pack **%1$@** that is %2$@% complete.\n\nThis will translate the entire interface. You can suggest corrections in the [translation panel]().\n\nYou can change your language back at any time in Settings.")
                        .replace("%1$@", info.title).replace("%2$@", "${this.completionScore(info)}")
                }
                return this.str("ApplyLanguage_ChangeLanguageOfficialText",
                    "You are about to apply a language pack **%1$@**.\n\nThis will translate the entire interface. You can suggest corrections in the [translation panel]().\n\nYou can change your language back at any time in Settings.")
                    .replace("%1$@", info.title)
            case None => return ""
        }
    }

    /** Markdown subset used by these strings: **bold** (kind 1) and [link]() (kind 2). */
    private func bodySegments(): ArrayList<(String, Int64)> {
        let segments = ArrayList<(String, Int64)>()
        var remaining = this.bodyText()
        var bold = false
        while (remaining.size > 0) {
            let boldIdx = remaining.indexOf("**")
            let linkIdx = remaining.indexOf("[")
            var next: Int64 = remaining.size
            var isLink = false
            match (boldIdx) { case Some(i) => next = i; case None => () }
            match (linkIdx) {
                case Some(i) => if (i < next) { next = i; isLink = true }
                case None => ()
            }
            if (next > 0) {
                segments.add((remaining[0..next], if (bold) { 1 } else { 0 }))
            }
            if (next >= remaining.size) { break }
            if (isLink) {
                let rest = remaining[(next + 1)..]
                match (rest.indexOf("](")) {
                    case Some(close) =>
                        segments.add((rest[0..close], 2))
                        let afterLabel = rest[(close + 2)..]
                        remaining = match (afterLabel.indexOf(")")) {
                            case Some(paren) => afterLabel[(paren + 1)..]
                            case None => afterLabel
                        }
                    case None =>
                        segments.add(("[", if (bold) { 1 } else { 0 }))
                        remaining = rest
                }
            } else {
                bold = !bold
                remaining = remaining[(next + 2)..]
            }
        }
        return segments
    }

    /** LanguageLinkPreviewControllerNode.swift:455-467 — the action is hidden without strings. */
    private func canApply(): Bool {
        if (this.messageText.size > 0) { return false }
        match (this.previewInfo) {
            case Some(info) => return info.totalStringCount != 0
            case None => return false
        }
    }

    private func translationUrl(): String {
        match (this.previewInfo) {
            case Some(info) => return "https://translations.telegram.org/${info.langCode}/"
            case None => return ""
        }
    }

    /** LanguageLinkPreviewController.swift:108-130 */
    private func activate(): Unit {
        if (this.inProgress) { return }
        let code = match (this.previewInfo) {
            case Some(info) => info.langCode
            case None => return
        }
        this.inProgress = true
        let apply = this.onApply
        spawn {
            let ok = apply(code)
            launch {
                this.inProgress = false
                Hilog.info(0, "CjTelegram", "[LanguageLinkPreview] activate ${code} ok=${ok}")
                if (ok) {
                    this.onApplied()
                } else {
                    this.previewInfo = None
                    this.messageText = this.str("Login_UnknownError", "An error occurred. Please try again later.")
                }
            }
        }
    }

    public func build() {
        Column {
        Column {
            Column {
                if (this.isLoading) {
                    LoadingProgress()
                        .width(40)
                        .height(40)
                        .color(this.presentation.accentColor)
                        .margin(top: 24, bottom: 24)
                } else {
                    if (this.titleText().size > 0) {
                        Text(this.titleText())
                            .fontSize(18)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(this.presentation.textColor)
                            .textAlign(TextAlign.Center)
                            .margin(bottom: 8)
                    }
                    Text() {
                        ForEach(this.bodySegments(), itemGenerator: { seg: (String, Int64), _i: Int64 =>
                            Span(seg[0])
                                .fontSize(15)
                                .fontWeight(if (seg[1] == 1) { FontWeight.W600 } else { FontWeight.Regular })
                                .fontColor(if (seg[1] == 2) { this.presentation.accentColor } else { this.presentation.textColor })
                                .onClick({ _ => if (seg[1] == 2) { this.onOpenUrl(this.translationUrl()) } })
                        })
                    }
                    .textAlign(TextAlign.Center)
                    .width(100.percent)
                }
            }
            .width(100.percent)
            .padding(left: 10, right: 10, top: 12, bottom: 12)
            .alignItems(HorizontalAlign.Center)

            if (this.canApply()) {
                Divider().strokeWidth(1).color(this.presentation.dividerColor)
                Row {
                    if (this.inProgress) {
                        LoadingProgress().width(22).height(22).color(this.presentation.accentColor)
                    } else {
                        Text(this.str("ApplyLanguage_ChangeLanguageAction", "Change"))
                            .fontSize(20)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(this.presentation.accentColor)
                    }
                }
                .width(100.percent)
                .height(57)
                .justifyContent(FlexAlign.Center)
                .onClick({ _ => this.activate() })
            }
        }
        .width(100.percent)
        .backgroundColor(this.presentation.cardColor)
        .borderRadius(16)
        .clip(true)

        Row {
            Text(if (this.messageText.size > 0 && this.previewInfo.isNone()) { this.str("Common_OK", "OK") } else { this.str("Common_Cancel", "Cancel") })
                .fontSize(20)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.presentation.accentColor)
        }
        .width(100.percent)
        .height(57)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.presentation.cardColor)
        .borderRadius(16)
        .margin(top: 8)
        .onClick({ _ => if (!this.inProgress) { this.onClose() } })
        }
        .width(100.percent)
    }
}
