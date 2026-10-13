package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.services.{getCallService, getGroupCallSession, getRealChatListService}
import ohos_app_cangjie_entry.models.formatCallDuration
import ohos_app_cangjie_entry.router.*

/**
 * CallActiveBanner — 离开通话屏后的常驻顶部 Banner (P2-057)（混合工程迁移版）
 *
 * 对应 iOS CallController 中悬浮通话条行为:
 * 用户在通话中按 Home / 返回离开 CallScreen 时,
 * 顶部显示一条绿色 banner 指示通话状态 + 时长,
 * 点击 banner 返回 CallScreen.
 *
 * 覆盖层组件（非导航页）：由 MainTabPage 在其共享 overlay 区域直接渲染。
 * 混合迁移改动（recipe §Phase 4，overlay 处理）：
 *  - 保留 @Component（无 @HybridComponentEntry，无 .ets 壳，无 route_map 条目）
 *  - 删 @Consume NavPathStack（覆盖层不持有 NavDestination 栈）
 *  - pageStack.pushPathByName("CallScreen", "") → routerPush("CallScreen")
 *  - aboutToAppear（有实逻辑：启动轮询 spawn）→ ensureLoaded()（loaded 守卫）+ 根 .onAppear
 *  - aboutToDisappear（cleanup：停轮询）→ cleanup() + 根 .onDisAppear
 *
 * 使用方式:
 *   在 MainTabPage 顶层 overlay 区域首行放置:
 *     if (isCallBannerVisible()) {
 *         CallActiveBanner()
 *     }
 */
@Component
public class CallActiveBanner {
    @State var callDuration: Int64 = 0
    @State var peerName: String = ""
    // 默认 false：MainTabPage 无条件把本 banner 放进 overlay，靠 isActive 自门控。
    // 此前默认 true → 每次启动先闪现一条绿色通话条（无通话），1s 后轮询才隐藏。
    @State var isActive: Bool = false
    @State var loaded: Bool = false
    // 群 Video Chat 最小化后的顶条（iOS CallStatusBarNode 的 groupCall 分支：标题 + 人数；
    // 静音蓝、开麦绿，CallStatusBarNode.swift 背景随 isMuted 切换）。
    @State var groupActive: Bool = false
    @State var groupTitle: String = ""
    @State var groupSubtitle: String = ""
    @State var groupMuted: Bool = true
    private var _pollRunning: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true

        // 首帧即按当前 banner 可见性初始化（若已在通话中离开通话屏返回此处）
        this.isActive = isCallBannerVisible()
        this.peerName = callBannerPeerName()
        this._pollRunning = true

        // 每秒同步 banner 可见性 + 通话时长。持续运行（跟随 isCallBannerVisible()），
        // 不再在无通话时自我终止——否则正常启动后轮询即死、真正离开通话时 banner
        // 永不出现。仅 cleanup(onDisAppear) 停止。
        let _ = spawn {
            while (this._pollRunning) {
                sleep(Duration.second * 1)
                let svc = getCallService()
                let callOpt = svc.getCurrentCall()
                // 通话终止 / 无活跃通话 → 确保 banner 关闭
                match (callOpt) {
                    case Some(c) => if (c.state == "terminated") { setCallBannerVisible(false, "") }
                    case None => if (isCallBannerVisible()) { setCallBannerVisible(false, "") }
                }
                // dur 用 match 表达式算成不可变 let（launch 闭包不能捕获可变 var）
                let dur: Int64 = match (callOpt) {
                    case Some(c) => if (c.state == "terminated") { 0 } else { c.duration }
                    case None => 0
                }
                let nowVisible = isCallBannerVisible()
                let nm = callBannerPeerName()
                let gs = getGroupCallSession()
                let gActive = gs.isActive() && !isGroupCallScreenVisible()
                // iOS：通话没起标题时用群名
                let gTitle = if (gs.title().size > 0) { gs.title() } else {
                    match (getRealChatListService().getCachedChat(gs.chatPeerType(), gs.chatPeerId())) {
                        case Some(c) => if (c.title.size > 0) { c.title } else { "Video Chat" }
                        case None => "Video Chat"
                    }
                }
                let count = gs.memberCount()
                let gSub = if (gs.state() != "connected") { "connecting..." }
                    else if (count == 1) { "1 participant" } else { "${count} participants" }
                let gMuted = gs.isMuted()
                launch {
                    this.callDuration = dur
                    this.peerName = nm
                    this.isActive = nowVisible
                    this.groupActive = gActive
                    this.groupTitle = gTitle
                    this.groupSubtitle = gSub
                    this.groupMuted = gMuted
                }
            }
        }
    }

    private func cleanup(): Unit {
        this._pollRunning = false
    }

    private func handleReturnToCall(): Unit {
        setCallBannerVisible(false, "")
        routerPush("CallScreen")
    }

    private func handleReturnToGroupCall(): Unit {
        this.groupActive = false
        // 空参数：GroupCallScreen 发现 session 在通话中会直接接管那一通
        routerPush("GroupCallScreen", "")
    }

    public func build() {
        // iOS CallStatusBarNode 形态（CallStatusBarNode.swift）：
        //  - 从屏幕最顶端起、覆盖状态栏区域的整宽亮绿条（green 0x33c659）
        //  - 内容行贴条底（verticalOrigin = height - contentHeight），白字 名字+时长
        //  - 整条可点返回通话；无按钮无指示点
        // 注意：宿主 overlay Stack 默认 Center 对齐——必须 position(0,0) 锚定顶部
        //（此前绿条悬浮屏幕中间即此因）。
        Column {
            if (this.isActive) {
                Column {
                    Blank()
                    Row {
                        Text(this.peerName)
                            .fontSize(13)
                            .fontColor(0xFFFFFF)
                            .fontWeight(FontWeight.Medium)
                        Text(formatCallDuration(this.callDuration))
                            .fontSize(13)
                            .fontColor(0xFFFFFF)
                            .margin(left: 6)
                    }
                    .justifyContent(FlexAlign.Center)
                    .width(100.percent)
                    .height(28)
                }
                .width(100.percent)
                .height(CALLUI_SAFE_TOP + 28.0)
                .backgroundColor(0xFF33C659)
                .onClick({ evt => this.handleReturnToCall() })
            } else if (this.groupActive) {
                Column {
                    Blank()
                    Row {
                        Text(this.groupTitle)
                            .fontSize(13)
                            .fontColor(0xFFFFFF)
                            .fontWeight(FontWeight.Medium)
                            .maxLines(1)
                        Text(this.groupSubtitle)
                            .fontSize(13)
                            .fontColor(0xFFFFFF)
                            .margin(left: 6)
                    }
                    .justifyContent(FlexAlign.Center)
                    .width(100.percent)
                    .height(28)
                }
                .width(100.percent)
                .height(CALLUI_SAFE_TOP + 28.0)
                .backgroundColor(if (this.groupMuted) { 0xFF2D8CEB } else { 0xFF33C659 })
                .onClick({ evt => this.handleReturnToGroupCall() })
            }
        }
        .width(100.percent)
        .position(x: 0, y: 0)
        .onAppear({ => this.ensureLoaded() })
        .onDisAppear({ => this.cleanup() })
    }
}
