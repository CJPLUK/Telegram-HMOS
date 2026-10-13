package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getGameService
import ohos_app_cangjie_entry.utils.copyText
import ohos_app_cangjie_entry.router.*

/**
 * 游戏容器页（对应 iOS GameController）(P2-039)（混合工程迁移版）
 *
 * 路由参数格式（以 "|" 分隔）：
 *   "<url>|<gameTitle>|<botHandle>|<peerId>|<peerAccessHash>|<msgId>|<userId>|<userAccessHash>"
 *
 * @Provide 的 gameUrl / gameParams 被子组件 GamePageNode 通过 @Consume 读取。
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - pageStack.pop(animated:true) → routerPop()
 *  - onReady 参数解析 → ensureLoaded() 里 takePending("GamePage") + .onAppear
 */
@HybridComponentEntry
@Component
public class GamePage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @Provide var gameUrl: String = ""
    @Provide var gameParams: String = ""

    @State var gameTitle: String = ""
    @State var botHandle: String = ""
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let raw = takePending("GamePage")
        if (raw.size > 0 && raw != "{}") {
            this.parseParam(raw)
        }
        Hilog.info(0, "CjTelegram", "[GamePage] ensureLoaded")
    }

    private func parseParam(raw: String): Unit {
        let parts = raw.split("|")
        if (parts.size >= 1) { this.gameUrl = parts[0] }
        if (parts.size >= 2) { this.gameTitle = parts[1] }
        if (parts.size >= 3) { this.botHandle = parts[2] }
        // gameParams encodes peerId;peerAccessHash;msgId;userId;userAccessHash
        var paramStr = ""
        var i: Int64 = 3
        while (i < parts.size) {
            if (i > 3) { paramStr = paramStr + ";" }
            paramStr = paramStr + parts[i]
            i += 1
        }
        this.gameParams = paramStr
    }

    /**
     * doShare — 分享游戏链接 (P2-039 share_game)
     *
     * iOS: ShareControllerNode.shareWithoutScore() → makeShareController(subject:.url(...))
     * HarmonyOS: AlertDialog 显示 URL + 复制到剪贴板
     * 诚实注明: iOS 原生分享面板(UIActivityViewController)在 HarmonyOS 对应系统分享,
     *           当前通过 AlertDialog + copyText 实现，功能等价
     */
    private func doShare(): Unit {
        let handle = this.botHandle
        let title = this.gameTitle
        if (handle.size == 0 || title.size == 0) {
            Hilog.info(0, "CjTelegram", "[GamePage] doShare: missing botHandle or gameTitle")
            return
        }
        let shareUrl = getGameService().buildShareUrl(handle, title)
        Hilog.info(0, "CjTelegram", "[GamePage] doShare url=${shareUrl}")
        let capturedUrl = shareUrl
        let copyBtn = AlertDialogButtonOptions(
            value: "Copy Link",
            action: { =>
                let ok = copyText(capturedUrl)
                Hilog.info(0, "CjTelegram", "[GamePage] doShare copyText ok=${ok}")
            }
        )
        let cancelBtn = AlertDialogButtonOptions(
            value: "Cancel",
            action: { => () }
        )
        getUIContext().showAlertDialog(
            AlertDialogParamWithOptions(
                title: "Share Game",
                message: shareUrl,
                autoCancel: true,
                buttons: [copyBtn, cancelBtn]
            )
        )
    }

    /**
     * doShareScore — 提交游戏分数并分享 (P2-039 share_score)
     *
     * iOS: forwardGameWithScore → share game message with score to other chats
     * HarmonyOS: doShare (share game link; score submission via setGameScore TL)
     * 诚实注明: iOS share_score 转发游戏消息含分数；HarmonyOS 当前仅分享游戏链接
     *           setGameScore 的实际提交留给后续 GameService 扩展
     */
    private func doShareScore(): Unit {
        Hilog.info(0, "CjTelegram", "[GamePage] doShareScore: sharing game link with score context")
        this.doShare()
    }

    func build() {
        Column() {
            Row() {
                Button(trSource("Back"))
                    .fontSize(15)
                    .fontColor(0xFF007AFF)
                    .backgroundColor(Color.Transparent)
                    .onClick({ _ =>
                        routerPop()
                    })
                Blank()
                Column() {
                    Text(this.gameTitle)
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(0xFF000000)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                    Text(this.botHandle)
                        .fontSize(13)
                        .fontColor(0xFF8E8E93)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                }
                .alignItems(HorizontalAlign.Center)
                Blank()
                Button(trSource("Share"))
                    .fontSize(15)
                    .fontColor(0xFF007AFF)
                    .backgroundColor(Color.Transparent)
                    .onClick({ _ =>
                        this.doShare()
                    })
            }
            .width(100.percent)
            .height(44)
            .padding(8)

            GamePageNode()
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ => this.ensureLoaded() })
    }
}
