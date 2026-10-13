package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.getPrivacyEngineService
import ohos_app_cangjie_entry.core.mtproto.WebAuthorizationInfo
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.components.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * WebSessionsPage — 已连接 Web/网站会话管理页 (P2-331b)（混合工程迁移版）
 *
 * 真实 TL 调用：account.getWebAuthorizations / resetWebAuthorization / resetWebAuthorizations。
 * iOS ref: TelegramCore Engine.Sessions.requestWebSessions / RecentSessionsController.swift
 * 的 websitesOnly 形态。
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹（含 .hideTitleBar），只留内容 + 末尾 .onAppear
 *  - pageStack.pop() → routerPop()
 *  - aboutToAppear 有实逻辑（loadSessions）→ ensureLoaded()（.onAppear 触发）
 *
 * TC-0136 round2 返修（diag-suite_settings_privacy-TC-0135-0136-0137-round2.md §5/§8.4）：
 * 归属核验见该报告 §5.0（归 set_recent_sessions，非 core_engine_privacy）。
 *  - 删除自造空态分支（源侧 emptyStateItem 恒 nil，永不渲染空态），改为数据加载完成 +
 *    列表为空 + 已上屏后自动 routerPop()（对位源侧 :664-677 的 autoDismissDisposable 链路）。
 *  - 删除自造全屏 loading（源侧此屏无任何 loading 指示器形态）。
 *  - 标题/脚注/断开全部行三处字面量改为源码值。
 *  - 单条网站断开确认层整块删除（源侧 removeWebSessionImpl 故意无确认），改为直接执行；
 *    "断开全部网站" 改走 DevicesPage.cj 定义的共享确认入口 ConfirmActionOverlay
 *    （TC-0135 §3.3/§8.2 的"统一入口"硬约束，两页同包 ohos_app_cangjie_entry.pages 直接复用）。
 *
 * TC-0136 round3 静态白盒返修（diag-suite_settings_privacy-TC-0136-round3.md §3.4/§6.1，
 * 随 TC-0134/TC-0137 一并进入 set_recent_sessions 的返修范围；TC-0136 本身零 FAIL、判
 * blocked，不在本轮 case_ids）：
 *  - 正确终态是"两个共享入口"，不是一个——源侧对"断开全部网站"用的是底部
 *    ActionSheetController，不是 textAlertController。改用工程内已有的
 *    components/ContextMenu.cj ContextMenuView（底部 action-sheet 原语），把此前喂进
 *    ConfirmActionOverlay 的三条源码零命中自造串（标题/正文/破坏性按钮文案）换成源码值
 *    "Disconnect All Websites"；不再传标题/正文（源侧动作表两者皆无）。设备屏两处
 *    ConfirmActionOverlay 调用点形态与源侧 textAlertController 已对上，不动。
 */
@HybridComponentEntry
@Component
public class WebSessionsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var sessions: ArrayList<WebAuthorizationInfo> = ArrayList<WebAuthorizationInfo>()
    @State var isLoading: Bool = true
    @State var isRevoking: Bool = false
    @State var showRevokeAllConfirm: Bool = false

    @State var loaded: Bool = false
    // TC-0136 §8.4 item14：自动关闭链路的一次性 + 挂载守卫状态，对位源侧
    // filter{!isLoadingMore && sessions.isEmpty} |> take(1) |> (didAppear |> filter |> take(1))。
    @State var hasAppeared: Bool = false
    @State var autoDismissed: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadSessions()
    }

    // 边界条件（照源侧链路逐条对应）：①仅在加载已完成时判定；②一次性（autoDismissed
    // 一旦置真不再触发）；③必须已上屏（hasAppeared）才允许 pop，数据先到则挂起等上屏；
    // ④只在本页（websitesOnly 语义）挂，不影响 DevicesPage。
    private func maybeAutoDismiss(): Unit {
        if (this.autoDismissed) { return }
        if (this.isLoading) { return }
        if (!this.sessions.isEmpty()) { return }
        if (!this.hasAppeared) { return }
        this.autoDismissed = true
        routerPop()
    }

    private func loadSessions(): Unit {
        let _ = spawn {
            let svc = getPrivacyEngineService()
            var loaded: ArrayList<WebAuthorizationInfo> = ArrayList<WebAuthorizationInfo>()
            try {
                let resp = svc.getWebSessions()
                var idx: Int64 = 0
                while (idx < resp.sessions.size) {
                    loaded.add(resp.sessions[idx])
                    idx = idx + 1
                }
                Hilog.info(0, "CjTelegram", "[WebSessions] loaded ${loaded.size} sessions")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[WebSessions] loadSessions error: ${e}")
            }
            let result = loaded
            spawn(UIThread) {
                =>
                this.sessions = result
                this.isLoading = false
                this.maybeAutoDismiss()
            }
        }
    }

    // TC-0136 §8.4 item13：单条网站断开确认层整块删除（源侧 removeWebSessionImpl 无确认），
    // 断开直接执行，不再经过 showRevokeConfirm。
    private func revokeSession(hash: Int64): Unit {
        let _ = spawn {
            let svc = getPrivacyEngineService()
            var ok = false
            try {
                ok = svc.terminateWebSession(hash)
                Hilog.info(0, "CjTelegram", "[WebSessions] terminateWebSession hash=${hash} ok=${ok}")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[WebSessions] terminateWebSession error: ${e}")
            }
            let success = ok
            let targetHash = hash
            spawn(UIThread) {
                =>
                if (success) {
                    let remaining = ArrayList<WebAuthorizationInfo>()
                    var ri: Int64 = 0
                    while (ri < this.sessions.size) {
                        if (this.sessions[ri].hash != targetHash) {
                            remaining.add(this.sessions[ri])
                        }
                        ri = ri + 1
                    }
                    this.sessions = remaining
                    this.maybeAutoDismiss()
                }
            }
        }
    }

    private func revokeAllSessions(): Unit {
        let _ = spawn {
            let svc = getPrivacyEngineService()
            var ok = false
            try {
                ok = svc.terminateAllWebSessions()
                Hilog.info(0, "CjTelegram", "[WebSessions] terminateAllWebSessions ok=${ok}")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[WebSessions] terminateAllWebSessions error: ${e}")
            }
            let success = ok
            spawn(UIThread) {
                =>
                if (success) {
                    this.sessions = ArrayList<WebAuthorizationInfo>()
                    this.maybeAutoDismiss()
                }
                this.isRevoking = false
            }
        }
    }

    private func formatDate(epoch: Int32): String {
        if (epoch <= 0) { return "Unknown" }
        return "Active recently"
    }

    public func build() {
        Stack {
            Column {
                Row {
                    Text(trSource("Back"))
                        .fontSize(16)
                        .fontColor(0x317AFF)
                        .onClick({ _evt => routerPop() })
                    Blank().layoutWeight(1)
                    // TC-0136 §5.2：标题字面量改为源码值 AuthSessions.LoggedIn = "Websites"。
                    Text(trSource("Websites"))
                        .fontSize(18)
                        .fontWeight(FontWeight.Bold)
                    Blank().layoutWeight(1)
                    Row { }.width(60)
                }
                .width(100.percent)
                .height(56.0 + getSafeAreaTop())
                .padding(left: 16, right: 16, top: getSafeAreaTop())
                .backgroundColor(0xFFFFFF)
                .alignItems(VerticalAlign.Center)

                // TC-0136 §8.4 item13/17：删除自造空态分支与自造全屏 loading 分支
                // （源侧 emptyStateItem 恒 nil、此屏无 loading 指示器形态）。空列表由
                // maybeAutoDismiss() 自动 routerPop() 处理，不在此渲染任何空态 UI。
                Scroll {
                    Column {
                        Text(trSource("CONNECTED WEBSITES"))
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .margin(left: 16, top: 16, bottom: 8)
                            .width(100.percent)

                        Column {
                            this.buildSessionRows()
                        }
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(12)
                        .margin(left: 16, right: 16)

                        // TC-0136 §5.3：脚注字面量改为源码值 AuthSessions.LogOutApplicationsHelp。
                        Text(trSource("You can log in on websites that support signing in with Telegram."))
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .margin(left: 16, right: 16, top: 8)
                            .width(100.percent)

                        Row {
                            if (this.isRevoking) {
                                LoadingProgress().width(20).height(20)
                            } else {
                                // TC-0136 §5.3：断开全部行文案改为源码值 AuthSessions.LogOutApplications。
                                Text(trSource("Disconnect All Websites"))
                                    .fontSize(17)
                                    .fontColor(0xFF3B30)
                                    .layoutWeight(1)
                                    .textAlign(TextAlign.Center)
                            }
                        }
                        .width(100.percent)
                        .height(56)
                        .padding(left: 16, right: 16)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(12)
                        .margin(left: 16, right: 16, top: 24)
                        .onClick({ _evt =>
                            if (!this.isRevoking) {
                                this.showRevokeAllConfirm = true
                            }
                        })

                        Text(trSource("")).height(32)
                    }
                }
                .layoutWeight(1)
                .backgroundColor(0xF2F2F7)
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xF2F2F7)
            .padding(bottom: getSafeAreaBottom())

            // TC-0136-round3 §3.4/§6.1：正确终态是"两个共享入口"，不是一个——源侧本就是
            // 两种呈现原语（textAlertController 用于设备屏两处，ActionSheetController 用于
            // 本处"断开全部网站"）。此前把本处也塞进 ConfirmActionOverlay（居中 alert）是
            // 收敛过头，且喂了三条源码里零命中的自造串（"Revoke All Web Sessions" /
            // "Revoke all connected web sessions?" / "Revoke All"）。改用工程内已有的底部
            // 动作表原语 ContextMenuView（components/ContextMenu.cj:236-310，其文档自述即
            // "底部 action-sheet 式锚定：全屏半透明遮罩 + 底部圆角白卡片 + 竖排菜单项列表；
            // 破坏性项标红"），对位源侧 ActionSheetController + 两个 ActionSheetItemGroup +
            // presentationAnimation:.modalSheet（RecentSessionsController.swift:868-895）。
            // 不保留标题/正文——源侧动作表既无 title item 也无 text item。
            if (this.showRevokeAllConfirm) {
                ContextMenuView(
                    items: [
                        ContextMenuItem(
                            title: "Disconnect All Websites",
                            destructive: true,
                            onClick: { =>
                                this.showRevokeAllConfirm = false
                                this.isRevoking = true
                                this.revokeAllSessions()
                            }
                        ),
                        ContextMenuItem.separator(),
                        ContextMenuItem(title: "Cancel", onClick: { => })
                    ],
                    onDismiss: { => this.showRevokeAllConfirm = false }
                )
            }
        }
        .onAppear({ =>
            this.hasAppeared = true
            this.ensureLoaded()
            this.maybeAutoDismiss()
        })
    }

    @Builder
    func buildSessionRows() {
        ForEach(this.sessions.toArray(), itemGenerator: { session: WebAuthorizationInfo, idx: Int64 =>
            Column {
                if (idx > 0) {
                    Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16)
                }
                Row {
                    Column {
                        Text(session.domain)
                            .fontSize(17)
                            .fontColor(0x000000)
                            .fontWeight(FontWeight.Medium)
                            .maxLines(1)
                        Text("${session.browser} · ${session.platform}")
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .margin(top: 2)
                            .maxLines(1)
                        Text("${session.ip} · ${session.region}")
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .maxLines(1)
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    Blank().layoutWeight(1)
                    Text(trSource("Revoke"))
                        .fontSize(15)
                        .fontColor(0xFF3B30)
                        .onClick({ _evt =>
                            this.revokeSession(session.hash)
                        })
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 12, bottom: 12)
                .alignItems(VerticalAlign.Center)
            }
        })
    }
}
