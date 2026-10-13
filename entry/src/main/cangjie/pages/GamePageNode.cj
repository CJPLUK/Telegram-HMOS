package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.web.webview.WebviewController
import ohos.business_exception.BusinessException
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getGameService
import ohos_app_cangjie_entry.services.GameHighScore
import ohos_app_cangjie_entry.utils.copyText
import std.collection.ArrayList

/**
 * 游戏内容区组件（对应 iOS GameControllerNode）(P2-039)
 *
 * 核心功能：
 * - 使用 ArkUI Web 组件真实加载 game URL（对应 iOS WKWebView）
 * - 初始化时拉取排行榜（messages.getGameHighScores）
 * - JS 桥 TelegramWebviewProxy.postEvent → handleGameEvent
 *   - share_game → GamePage.doShare() (via @Provide/@Consume 共享状态 + 回调)
 *   - share_score → GamePage.doShareScore()
 *
 * 从 @Consume 读取 GamePage 共享的游戏参数（避免 @Component 跨调用的参数包装问题）。
 *
 * S-001: @State 写入必须在 UIThread — 用 spawn(UIThread) 包裹，不用 launch{}
 *
 * 调用链：
 *   GamePageNode.aboutToAppear()
 *     → registerGameJSBridge()  [TelegramWebviewProxy.postEvent 注册]
 *     → getGameService().getHighScores(peerId, peerAccessHash, msgId, userId, userAccessHash)
 *       → getMTProtoClient().sendRequest() [messages.getGameHighScores#e822649d]
 *   JS share_game/share_score → handleGameEvent → shareTrigger @State → GamePage 反应
 */
@Component
public class GamePageNode {
    @Consume var gameUrl: String
    @Consume var gameParams: String

    @State var highScores: ArrayList<GameHighScore> = ArrayList<GameHighScore>()
    @State var isLoadingScores: Bool = false

    let webController: WebviewController = WebviewController()

    public func aboutToAppear(): Unit {
        this.registerGameJSBridge()
        this.isLoadingScores = true
        let params = this.gameParams
        let parsed = parseGameParams(params)
        let pId = parsed[0]
        let pHash = parsed[1]
        let mId = Int32(parsed[2])
        let uId = parsed[3]
        let uHash = parsed[4]
        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[GamePageNode] Fetching high scores via messages.getGameHighScores")
            let scores = getGameService().getHighScores(
                pId,
                pHash,
                mId,
                uId,
                uHash
            )
            let fetchedScores = scores
            spawn(UIThread) { =>
                this.highScores = fetchedScores
                this.isLoadingScores = false
                Hilog.info(0, "CjTelegram", "[GamePageNode] Scores loaded count=${fetchedScores.size}")
            }
        }
    }

    /**
     * registerGameJSBridge — 注册 TelegramWebviewProxy JS 桥
     *
     * 对应 iOS GameControllerNode WKScriptMessageHandler "performAction"
     * 注入 JS: TelegramWebviewProxy.postEvent(eventName, eventData)
     * 处理 share_game 和 share_score 事件
     */
    private func registerGameJSBridge(): Unit {
        let postEventHandler: (String) -> String = { msg: String =>
            Hilog.info(0, "CjTelegram", "[GamePageNode] JSBridge msg_len=${msg.size}")
            let msgCopy = msg
            spawn(UIThread) { =>
                this.handleGameEvent(msgCopy)
            }
            return ""
        }
        let methodList: Array<String> = ["postEvent"]
        let funcs: Array<(String) -> String> = [postEventHandler]
        try {
            this.webController.registerJavaScriptProxy(funcs, "TelegramWebviewProxy", methodList)
            Hilog.info(0, "CjTelegram", "[GamePageNode] TelegramWebviewProxy registered")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[GamePageNode] JSBridge registration failed: ${e}")
        }
    }

    /**
     * handleGameEvent — 处理游戏 JS 事件 (P2-039)
     *
     * iOS: GameControllerNode.handleScriptMessage — share_game/share_score
     * share_game  → 分享游戏链接（不含分数）shareWithoutScore()
     * share_score → 含分数分享（iOS: forwardGameWithScore to selected chats）
     *
     * HarmonyOS 实现: AlertDialog 显示游戏链接 + copyText 复制到剪贴板
     * 诚实注明: iOS share_score 使用 forwardGameWithScore 转发游戏消息;
     *           HarmonyOS 当前显示链接分享对话框
     *
     * 必须在 UIThread 调用 (spawn(UIThread) 包裹)
     */
    private func handleGameEvent(payload: String): Unit {
        let eventName = extractGameEventName(payload)
        Hilog.info(0, "CjTelegram", "[GamePageNode] handleGameEvent: ${eventName}")
        if (eventName == "share_game") {
            Hilog.info(0, "CjTelegram", "[GamePageNode] share_game: showing share dialog")
            this.showShareDialog(false)
        } else if (eventName == "share_score") {
            Hilog.info(0, "CjTelegram", "[GamePageNode] share_score: showing share dialog with score context")
            this.showShareDialog(true)
        } else {
            Hilog.info(0, "CjTelegram", "[GamePageNode] unhandled game event: ${eventName}")
        }
    }

    /**
     * showShareDialog — 显示游戏分享对话框 (P2-039)
     *
     * 从 @Consume gameUrl / gameParams 中提取 botHandle/gameName (encoded in gameUrl)
     * 使用 AlertDialog 显示 share URL + copyText 复制
     * 必须在 UIThread 调用
     */
    private func showShareDialog(withScore: Bool): Unit {
        let url = this.gameUrl
        let isScore = withScore
        Hilog.info(0, "CjTelegram", "[GamePageNode] showShareDialog url=${url} withScore=${isScore}")
        let capturedUrl = url
        let copyBtn = AlertDialogButtonOptions(
            value: "Copy Link",
            action: { =>
                let ok = copyText(capturedUrl)
                Hilog.info(0, "CjTelegram", "[GamePageNode] share copyText ok=${ok}")
            }
        )
        let cancelBtn = AlertDialogButtonOptions(
            value: "Cancel",
            action: { => () }
        )
        let dialogTitle = if (isScore) { "Share Score" } else { "Share Game" }
        getUIContext().showAlertDialog(
            AlertDialogParamWithOptions(
                title: dialogTitle,
                message: capturedUrl,
                autoCancel: true,
                buttons: [copyBtn, cancelBtn]
            )
        )
    }

    func build() {
        Column() {
            // P2-039: Loading indicator while high scores are being fetched
            if (this.isLoadingScores) {
                Row() {
                    Text("Loading scores...")
                        .fontSize(12)
                        .fontColor(0xFF8E8E93)
                        .padding(4)
                }
                .width(100.percent)
                .height(20)
                .justifyContent(FlexAlign.End)
            } else if (this.highScores.size > 0) {
                Row() {
                    Text("Top score: #1")
                        .fontSize(12)
                        .fontColor(0xFF8E8E93)
                        .padding(4)
                }
                .width(100.percent)
                .height(20)
                .justifyContent(FlexAlign.End)
            }
            Web(src: this.gameUrl, controller: this.webController)
                .width(100.percent)
                .layoutWeight(1)
                .domStorageAccess(true)
                .onPageBegin({ _evt =>
                    Hilog.info(0, "CjTelegram", "[GamePageNode] Page load started")
                })
                .onPageEnd({ _evt =>
                    Hilog.info(0, "CjTelegram", "[GamePageNode] Page load complete")
                })
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFFFF)
    }
}

/**
 * extractGameEventName — 从 JS postEvent 消息中提取 eventName
 * 格式: {"eventName":"share_game","eventData":"..."} 或直接 "share_game"
 */
func extractGameEventName(payload: String): String {
    let needle = "\"eventName\":"
    let runes = payload.toRuneArray()
    let needleRunes = needle.toRuneArray()
    let nLen = needleRunes.size
    let jLen = runes.size
    var i: Int64 = 0
    while (i <= jLen - nLen) {
        var matched = true
        var k: Int64 = 0
        while (k < nLen) {
            if (runes[i + k] != needleRunes[k]) {
                matched = false
                break
            }
            k += 1
        }
        if (matched) {
            var j = i + nLen
            while (j < jLen && (runes[j] == r' ' || runes[j] == r'\t')) {
                j += 1
            }
            if (j < jLen && runes[j] == r'"') {
                j += 1
                var end = j
                while (end < jLen && runes[end] != r'"') {
                    end += 1
                }
                if (end <= jLen) {
                    return String(runes[j..end])
                }
            }
            break
        }
        i += 1
    }
    return payload
}

/**
 * 解析 gameParams 字符串（格式：peerId;peerAccessHash;msgId;userId;userAccessHash）
 * 返回 [peerId, peerAccessHash, msgId, userId, userAccessHash]
 */
func parseGameParams(params: String): Array<Int64> {
    let result = Array<Int64>(5, repeat: 0)
    let parts = params.split(";")
    var i: Int64 = 0
    while (i < parts.size && i < 5) {
        result[i] = parseI64Str(parts[i])
        i += 1
    }
    return result
}

func parseI64Str(s: String): Int64 {
    var result: Int64 = 0
    var negative = false
    let runes = s.toRuneArray()
    var start: Int64 = 0
    if (runes.size > 0 && runes[0] == r'-') {
        negative = true
        start = 1
    }
    var i: Int64 = start
    while (i < runes.size) {
        let c = UInt32(runes[i])
        if (c >= 48u32 && c <= 57u32) {
            result = result * 10 + Int64(c - 48u32)
        }
        i += 1
    }
    return if (negative) { -result } else { result }
}
