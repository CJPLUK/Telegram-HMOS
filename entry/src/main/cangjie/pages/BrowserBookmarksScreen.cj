package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getBrowserService, BrowserBookmark}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * BrowserBookmarksScreen — 浏览器书签列表页面（混合工程迁移版）。
 *
 * 对应 iOS BrowserBookmarksScreen.swift。
 *
 * 功能：
 *   - 展示通过 BrowserService 持久化存储的书签列表
 *   - 点击书签跳回 BrowserScreen 并加载对应 URL
 *   - 长按 / 删除按钮删除书签（调用 BrowserService.removeBookmark → Preferences.flush）
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - pageStack.pop() → routerPop()；pushPathByName("BrowserScreen", url) → routerPush("BrowserScreen", url)
 *  - aboutToAppear 有实逻辑（reloadBookmarks）→ 移到首次 build（.onAppear）
 */
@HybridComponentEntry
@Component
public class BrowserBookmarksScreen {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var bookmarks: Array<BrowserBookmark> = Array<BrowserBookmark>()
    @State var searchText: String = ""
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        Hilog.info(0, "CjTelegram", "[BrowserBookmarksScreen] onAppear")
        this.reloadBookmarks()
    }

    private func reloadBookmarks(): Unit {
        // 过滤逻辑委托给 BrowserService.filterBookmarks，避免在 @Component 内部捕获 mutable 变量（S-77）
        this.bookmarks = getBrowserService().filterBookmarks(this.searchText)
    }

    private func deleteBookmark(url: String): Unit {
        getBrowserService().removeBookmark(url)
        Hilog.info(0, "CjTelegram", "[BrowserBookmarksScreen] Bookmark deleted")
        this.reloadBookmarks()
    }

    private func openBookmark(url: String): Unit {
        // Pop 回 BrowserScreen，然后通过新的 push 打开该 URL
        routerPop()
        routerPush("BrowserScreen", url)
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
                Text(trSource("Bookmarks"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0x000000)
                    .layoutWeight(1)
                    .textAlign(TextAlign.Center)
                Blank()
                    .width(44)
                    .height(44)
            }
            .width(100.percent)
            .height(44.0 + getSafeAreaTop())
            .padding(left: 4, right: 4, top: getSafeAreaTop(), bottom: 0)
            .backgroundColor(0xF7F7F7)
            .border(width: 1, color: 0xE0E0E0)

            // 搜索栏（hint text 为底层 Text，TextInput 在顶层接受触摸）
            Row {
                Stack {
                    if (this.searchText.size == 0) {
                        Text("Search bookmarks")
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .padding(left: 12, right: 8, top: 0, bottom: 0)
                            .width(100.percent)
                    }
                    TextInput(text: this.searchText)
                        .fontSize(14)
                        .fontColor(0x000000)
                        .backgroundColor(Color.Transparent)
                        .padding(left: 8, right: 8, top: 4, bottom: 4)
                        .height(36)
                        .width(100.percent)
                        .onChange({ val: String =>
                            this.searchText = val
                            this.reloadBookmarks()
                        })
                }
                .height(36)
                .layoutWeight(1)
                .backgroundColor(0xF2F2F7)
                .borderRadius(8)
            }
            .width(100.percent)
            .padding(left: 12, right: 12, top: 8, bottom: 8)
            .backgroundColor(0xF7F7F7)

            // 书签列表或空态
            if (this.bookmarks.size == 0) {
                Column {
                    Text("No bookmarks yet")
                        .fontSize(16)
                        .fontColor(0x8E8E93)
                        .margin(bottom: 8)
                    Text("Tap the star icon while browsing to save a page.")
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
                    ForEach(this.bookmarks, itemGenerator: { bm: BrowserBookmark, _idx: Int64 =>
                        ListItem {
                            Row {
                                Column {
                                    Text(if (bm.title.size > 0) { bm.title } else { bm.url })
                                        .fontSize(15)
                                        .fontColor(0x000000)
                                        .maxLines(1)
                                        .width(100.percent)
                                    Text(getBrowserService().extractDisplayHost(bm.url))
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
                                        let url = bm.url
                                        this.deleteBookmark(url)
                                    })
                            }
                            .width(100.percent)
                            .height(60)
                            .padding(left: 16, right: 8, top: 8, bottom: 8)
                            .alignItems(VerticalAlign.Center)
                            .onClick({ _e: ClickEvent =>
                                let url = bm.url
                                this.openBookmark(url)
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
