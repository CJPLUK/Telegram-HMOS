package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getPendingLanguagePreviewIdentifier, setPendingLanguagePreviewIdentifier, getLanguageLinkPreviewService}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.getSafeAreaBottom

/**
 * LanguageLinkPreviewPage — t.me/setlanguage/<id> language pack sheet.
 *
 * iOS LanguageLinkPreviewController is presented over the chat (dim 0.5, sheet at the bottom),
 * not as a titled page. The shell is a DIALOG NavDestination; this renders the dim and sheet.
 *
 * The identifier is read when the page is constructed: the preview component loads in its own
 * aboutToAppear, which runs before this page's onAppear, so assigning it later (the previous
 * ensureLoaded) left the component with "" and "No language identifier" (S7-123).
 */
func languageLinkPreviewInitialIdentifier(): String {
    // ChatRoomPage.openWebUrl passes the identifier both as the route param and as the pending
    // preview identifier; prefer the route param.
    let routed = takePending("LanguageLinkPreviewPage").trimAscii()
    if (routed.size > 0 && !routed.startsWith("{")) { return routed }
    return getPendingLanguagePreviewIdentifier()
}

@HybridComponentEntry
@Component
public class LanguageLinkPreviewPage {
    @State var identifier: String = languageLinkPreviewInitialIdentifier()

    private func handleClose(): Unit {
        setPendingLanguagePreviewIdentifier("")
        routerPop()
    }

    /** LanguageLinkPreviewController.activate — downloadAndApplyLocalization; runs off the UI thread. */
    private func applyLanguage(langCode: String): Bool {
        let ok = getLanguageLinkPreviewService().downloadAndApply(langCode)
        Hilog.info(0, "CjTelegram", "[LanguageLinkPreviewPage] Language ${langCode} applied=${ok}")
        return ok
    }

    public func build() {
        Stack(alignContent: Alignment.Bottom) {
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0x80000000)
                .onClick({ _ => this.handleClose() })
            Column {
                LanguageLinkPreviewPageNode(
                    identifier: this.identifier,
                    onClose: { => this.handleClose() },
                    onApply: { code: String => this.applyLanguage(code) },
                    onApplied: { => this.handleClose() },
                    onOpenUrl: { _url: String => }
                )
            }
            .width(100.percent)
            .padding(left: 10, right: 10, bottom: 10.0 + getSafeAreaBottom())
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ =>
            Hilog.info(0, "CjTelegram", "[LanguageLinkPreviewPage] identifier=${this.identifier}")
        })
    }
}
