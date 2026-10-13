package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getBrowserService, BrowserHistoryEntry}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * BrowserHistoryScreen — 浏览器最近访问历史页面（混合工程迁移版）。
 *
 * 对应 iOS BrowserRecentlyVisited.swift + BrowserScreen 历史入口。
 *
 * P2-047: 最近访问历史 Preferences 持久化真实消费端：
 *   - 读取 BrowserService.getRecentHistory()（从 Preferences 持久化存储加载）
 *   - 点击条目：pop 回 BrowserScreen + push("BrowserScreen", url) 重访
 *   - 删除单条：BrowserService.removeHistoryEntry(url) + 刷新列表
 *   - 清空全部：BrowserService.clearHistory() + 刷新列表
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - pageStack.pop() → routerPop()；pushPathByName("BrowserScreen", url) → routerPush("BrowserScreen", url)
 *  - aboutToAppear 有实逻辑（reloadHistory）→ 移到首次 build（.onAppear）
 */
@HybridComponentEntry
@Component
public class BrowserHistoryScreen {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var historyItems: Array<BrowserHistoryEntry> = Array<BrowserHistoryEntry>()
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        Hilog.info(0, "CjTelegram", "[BrowserHistoryScreen] onAppear")
        this.reloadHistory()
    }

    private func reloadHistory(): Unit {
        // 从 BrowserService 读取（Preferences 持久化）
        let raw = getBrowserService().getRecentHistory()
        // 倒序显示：最新访问在最上方
        let n = raw.size
        let reversed: Array<BrowserHistoryEntry> = Array<BrowserHistoryEntry>(n, { i: Int64 =>
            raw[n - 1 - i]
        })
        this.historyItems = reversed
        Hilog.info(0, "CjTelegram", "[BrowserHistoryScreen] reloadHistory: count=${n}")
    }

    private func openHistoryItem(url: String): Unit {
        // Pop 回 BrowserScreen 后 push 新的 BrowserScreen 加载该 URL
        routerPop()
        routerPush("BrowserScreen", url)
        Hilog.info(0, "CjTelegram", "[BrowserHistoryScreen] openHistoryItem: ${url}")
    }

    private func deleteHistoryItem(url: String): Unit {
        getBrowserService().removeHistoryEntry(url)
        this.reloadHistory()
        Hilog.info(0, "CjTelegram", "[BrowserHistoryScreen] deleteHistoryItem: ${url}")
    }

    private func clearAllHistory(): Unit {
        getBrowserService().clearHistory()
        this.reloadHistory()
        Hilog.info(0, "CjTelegram", "[BrowserHistoryScreen] clearAllHistory done")
    }

    private func displayTitle(he: BrowserHistoryEntry): String {
        if (he.title.size > 0 && he.title != he.url) {
            return he.title
        }
        return getBrowserService().extractDisplayHost(he.url)
    }

    func build() {
        Column {
            // 标题栏
            Row {
                Button("←")
                    .fontSize(18)
                    .fontColor(0x007AFF)
                    .backgroundColor(Color.Transparent)
                    .width(44)
                    .height(44)
                    .onClick({ _e: ClickEvent =>
                        routerPop()
                    })
                Text(trSource("History"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0x000000)
                    .layoutWeight(1)
                    .textAlign(TextAlign.Center)
                // 清空全部历史按钮
                Button(trSource("Clear"))
                    .fontSize(14)
                    .fontColor(if (this.historyItems.size > 0) { 0xFF3B30 } else { 0xC0C0C0 })
                    .backgroundColor(Color.Transparent)
                    .width(60)
                    .height(44)
                    .enabled(this.historyItems.size > 0)
                    .onClick({ _e: ClickEvent =>
                        this.clearAllHistory()
                    })
            }
            .width(100.percent)
            .height(44.0 + getSafeAreaTop())
            .padding(left: 4, right: 4, top: getSafeAreaTop(), bottom: 0)
            .backgroundColor(0xF7F7F7)
            .border(width: 1, color: 0xE0E0E0)

            // 历史列表或空态
            if (this.historyItems.size == 0) {
                Column {
                    Text("No history yet")
                        .fontSize(16)
                        .fontColor(0x8E8E93)
                        .margin(bottom: 8)
                    Text("Pages you visit will appear here.")
                        .fontSize(13)
                        .fontColor(0xC7C7CC)
                        .textAlign(TextAlign.Center)
                        .padding(left: 32, right: 32, top: 0, bottom: 0)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                List {
                    ForEach(this.historyItems, itemGenerator: { he: BrowserHistoryEntry, _idx: Int64 =>
                        ListItem {
                            Row {
                                Column {
                                    Text(this.displayTitle(he))
                                        .fontSize(15)
                                        .fontColor(0x000000)
                                        .maxLines(1)
                                        .width(100.percent)
                                    Text(getBrowserService().extractDisplayHost(he.url))
                                        .fontSize(12)
                                        .fontColor(0x8E8E93)
                                        .maxLines(1)
                                        .width(100.percent)
                                        .margin(top: 2)
                                }
                                .layoutWeight(1)
                                .alignItems(HorizontalAlign.Start)

                                Button("✕")
                                    .fontSize(14)
                                    .fontColor(0xFF3B30)
                                    .backgroundColor(Color.Transparent)
                                    .width(36)
                                    .height(36)
                                    .onClick({ _e: ClickEvent =>
                                        let url = he.url
                                        this.deleteHistoryItem(url)
                                    })
                            }
                            .width(100.percent)
                            .height(60)
                            .padding(left: 16, right: 8, top: 8, bottom: 8)
                            .alignItems(VerticalAlign.Center)
                            .onClick({ _e: ClickEvent =>
                                let url = he.url
                                this.openHistoryItem(url)
                            })
                        }
                    })
                }
                .width(100.percent)
                .layoutWeight(1)
                .divider(ListDividerOptions(strokeWidth: 1, color: 0xE5E5EA, startMargin: 16, endMargin: 0))
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFF)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
