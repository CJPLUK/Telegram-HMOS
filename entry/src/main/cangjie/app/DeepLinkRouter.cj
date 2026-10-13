package ohos_app_cangjie_entry.app

/**
 * DeepLinkRouter — tg:// / t.me / universal-link 接线层 (P2-004)
 *
 * iOS 对应:
 *   AppDelegate.application(_:open:options:) → openUrl(url) → openResolved(resolved)
 *   AppDelegate.application(_:continue:restorationHandler:) — universal link
 *   AccountContext.openUrl / openResolved → per-peer 落地
 *
 * HarmonyOS 等价链路:
 *   1. 外部 app / 系统调起 MainAbility → Want.uri 携带 tg:// 或 https://t.me/xxx
 *   2. MainAbility.onCreate / onNewWant 识别 Want.uri，存入 _pendingDeepLink
 *   3. MainTabPage.aboutToAppear / 后台轮询 检测 pendingDeepLink
 *   4. 调用 resolveDeepLink 解析 peer，pushPathByName("ChatRoomPage"/"PeerInfoPage") 落地
 *
 * 本模块只做 "URI 保存 + 提取 + 路径解析"，不做 MTProto 解析（MTProto 在 services 层）。
 * MainTabPage 负责消费 pending deeplink，通过 spawn + launch 完成异步解析 + UI 导航。
 *
 * 接线约束:
 *   - onForeground/onBackground 生命周期 → AppState (P2-006)
 *   - 深链落地 → MainTabPage.pageStack.pushPathByName (P2-004)
 *   - MTProto resolve → ResolveService.resolvePeerByName / resolveDeepLink (已有)
 */

import kit.PerformanceAnalysisKit.Hilog

// ==================== PendingDeepLink ====================

/**
 * 待处理的深链记录
 */
public class PendingDeepLink {
    public var rawUri: String = ""
    public var isValid: Bool = false
}

// 模块级 pending 深链（单件，类似 NotificationClickRouter）
private var _pendingDeepLink: Option<PendingDeepLink> = None

/**
 * 存入待处理深链
 */
public func setPendingDeepLink(uri: String) {
    if (uri.size == 0) { return }
    let link = PendingDeepLink()
    link.rawUri = uri
    link.isValid = true
    _pendingDeepLink = Some(link)
    Hilog.info(0, "CjTelegram", "[DeepLinkRouter] pending deeplink set: ${uri}")
}

/**
 * 读取待处理深链（不消费）
 */
public func getPendingDeepLink(): Option<PendingDeepLink> {
    return _pendingDeepLink
}

/**
 * 清除待处理深链
 */
public func clearPendingDeepLink() {
    _pendingDeepLink = None
    Hilog.info(0, "CjTelegram", "[DeepLinkRouter] pending deeplink cleared")
}

// ==================== DeepLinkRouter ====================

private var _deepLinkRouterInstance: Option<DeepLinkRouter> = None

public func getDeepLinkRouter(): DeepLinkRouter {
    match (_deepLinkRouterInstance) {
        case Some(r) => return r
        case None =>
            let r = DeepLinkRouter()
            _deepLinkRouterInstance = Some(r)
            return r
    }
}

/**
 * DeepLinkRouter — URI 识别与路径解析
 *
 * 职责:
 *   - 识别 tg:// / t.me/ / telegram.me/ URI 并写入 pending queue
 *   - 从 URI 中提取 username/domain，供 MainTabPage 驱动 MTProto 解析 + ArkUI 导航
 *
 * MainTabPage 消费 pending deeplink 的模式:
 *   1. 轮询检测 getPendingDeepLink()
 *   2. 调用 getDeepLinkRouter().extractUsername(uri) 得到 username
 *   3. 在 spawn {} 中调用 ResolveService.resolvePeerByName(username)
 *   4. 在 launch {} 中执行 pageStack.pushPathByName(...)
 */
public class DeepLinkRouter {

    public init() {}

    /**
     * 从 Want.uri 中识别并缓存深链
     * 支持:
     *   - tg:// scheme（telegram custom scheme）
     *   - https://t.me/xxx  （telegram universal link）
     *   - https://telegram.me/xxx（旧域名）
     *
     * 调用方: MainAbility.onCreate / onNewWant
     */
    public func handleWantUri(uri: String): Bool {
        if (uri.size == 0) { return false }
        let lower = uri.toAsciiLower()
        let isTg = lower.startsWith("tg://")
        let isTme = lower.startsWith("https://t.me/") || lower.startsWith("http://t.me/")
        let isTelegramMe = lower.startsWith("https://telegram.me/") || lower.startsWith("http://telegram.me/")

        if (isTg || isTme || isTelegramMe) {
            Hilog.info(0, "CjTelegram", "[DeepLinkRouter] recognized deeplink URI: ${uri}")
            setPendingDeepLink(uri)
            return true
        }
        Hilog.info(0, "CjTelegram", "[DeepLinkRouter] URI not a telegram deeplink, skip: ${uri}")
        return false
    }

    /**
     * 从 URI 中提取 username / domain
     * 供 MainTabPage 消费 pending deeplink 时驱动 MTProto 解析
     *
     * 支持:
     *   tg://resolve?domain=durov        → "durov"
     *   tg://msg?to=durov                → "durov"
     *   https://t.me/durov               → "durov"
     *   https://t.me/durov/123           → "durov"
     *   https://telegram.me/durov        → "durov"
     *
     * @return username（空串表示非 username 类型深链，调用方应忽略或降级处理）
     */
    public func extractUsername(uri: String): String {
        // tg:// scheme
        if (uri.startsWith("tg://")) {
            return extractFromTgScheme(uri)
        }
        // https://t.me/xxx  (13 chars prefix for https, 12 for http)
        if (uri.startsWith("https://t.me/") || uri.startsWith("http://t.me/")) {
            let prefix: Int64 = if (uri.startsWith("https://")) { 13 } else { 12 }
            if (prefix >= uri.size) { return "" }
            let path = uri[prefix..uri.size]
            return extractFirstPathSegment(path)
        }
        // https://telegram.me/xxx (20 chars for https, 19 for http)
        if (uri.startsWith("https://telegram.me/") || uri.startsWith("http://telegram.me/")) {
            let prefix: Int64 = if (uri.startsWith("https://")) { 20 } else { 19 }
            if (prefix >= uri.size) { return "" }
            let path = uri[prefix..uri.size]
            return extractFirstPathSegment(path)
        }
        return ""
    }

    /**
     * 提取机器人深链的交互式 start payload。
     * 对应 iOS UrlHandling.ParsedInternalPeerUrlParameter.botStart：
     * tg://resolve?domain=PremiumBot&start=12 → "12"
     */
    public func extractBotStartPayload(uri: String): String {
        match (uri.indexOf("start=")) {
            case Some(idx) =>
                let start: Int64 = idx + 6
                if (start >= uri.size) { return "" }
                return extractUpToDelimiter(uri[start..uri.size])
            case None => return ""
        }
    }

    /**
     * 从 tg:// URI 中提取 domain/username
     * tg://resolve?domain=xxx → "xxx"
     * tg://msg?to=xxx         → "xxx"
     */
    private func extractFromTgScheme(uri: String): String {
        match (uri.indexOf("domain=")) {
            case Some(idx) =>
                let start: Int64 = idx + 7
                if (start >= uri.size) { return "" }
                let rest = uri[start..uri.size]
                return extractUpToDelimiter(rest)
            case None => ()
        }
        match (uri.indexOf("to=")) {
            case Some(idx) =>
                let start: Int64 = idx + 3
                if (start >= uri.size) { return "" }
                let rest = uri[start..uri.size]
                return extractUpToDelimiter(rest)
            case None => ()
        }
        return ""
    }

    /**
     * 取路径第一段（遇 / 或 ? 截断）
     */
    private func extractFirstPathSegment(path: String): String {
        var end: Int64 = path.size
        match (path.indexOf("/")) {
            case Some(i) => if (i < end) { end = i }
            case None => ()
        }
        match (path.indexOf("?")) {
            case Some(i) => if (i < end) { end = i }
            case None => ()
        }
        if (end <= 0) { return "" }
        let seg = path[0..end]
        if (seg.startsWith("@")) {
            return seg[1..seg.size]
        }
        return seg
    }

    /**
     * 取值到 & 或 # 截断
     */
    private func extractUpToDelimiter(s: String): String {
        var end: Int64 = s.size
        match (s.indexOf("&")) {
            case Some(i) => if (i < end) { end = i }
            case None => ()
        }
        match (s.indexOf("#")) {
            case Some(i) => if (i < end) { end = i }
            case None => ()
        }
        if (end <= 0) { return "" }
        return s[0..end]
    }
}
