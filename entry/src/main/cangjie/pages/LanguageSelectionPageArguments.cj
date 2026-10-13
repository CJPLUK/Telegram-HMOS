package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * LanguageSelectionPageArguments — 翻译目标语言选择页 (P2-399)
 *
 * 对应 iOS LanguageSelectionController
 * 展示 popular 热门分组（12 条）+ 完整 104 条语言列表
 * 支持搜索过滤
 *
 * 路由参数（param: Any）: 暂不使用；按 D-011 模式解包。
 */
@HybridComponentEntry
@Component
public class LanguageSelectionPageArguments {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var languages: ArrayList<TranslateLanguage> = ArrayList<TranslateLanguage>()
    @State var popularLanguages: ArrayList<TranslateLanguage> = ArrayList<TranslateLanguage>()
    @State var searchQuery: String = ""
    // P2-399: 过滤后的列表（@State 使 build() 可以直接引用）
    @State var filteredPopular: ArrayList<TranslateLanguage> = ArrayList<TranslateLanguage>()
    @State var filteredAll: ArrayList<TranslateLanguage> = ArrayList<TranslateLanguage>()
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.languages = getSupportedLanguages()
        this.popularLanguages = getPopularLanguages()
        this.filteredPopular = this.popularLanguages
        this.filteredAll = this.languages
    }

    private func applySearch(query: String): Unit {
        if (query.size == 0) {
            this.filteredPopular = this.popularLanguages
            this.filteredAll = this.languages
            return
        }
        let q = query.toAsciiLower()
        let newPop = ArrayList<TranslateLanguage>()
        for (lang in this.popularLanguages) {
            if (lang.name.toAsciiLower().contains(q) || lang.code.toAsciiLower().contains(q)) {
                newPop.add(lang)
            }
        }
        this.filteredPopular = newPop
        let newAll = ArrayList<TranslateLanguage>()
        for (lang in this.languages) {
            if (lang.name.toAsciiLower().contains(q) || lang.code.toAsciiLower().contains(q)) {
                newAll.add(lang)
            }
        }
        this.filteredAll = newAll
    }

    private func selectLanguage(lang: TranslateLanguage) {
        setSelectedTranslateLang(lang.code)
        routerPop()
    }

    public func build() {
        Column {
                // 导航栏
                Row {
                    Text(trSource("Cancel"))
                        .fontSize(17)
                        .fontColor(0x0088CC)
                        .padding(left: 16, right: 8, top: 12, bottom: 12)
                        .onClick({ evt =>
                            routerPop()
                        })

                    Blank()

                    Text("Translate to")
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)

                    Blank()

                    Text("         ")
                        .fontSize(17)
                        .padding(left: 8, right: 16, top: 12, bottom: 12)
                }
                .width(100.percent)
                .height(56.0 + getSafeAreaTop())
                .padding(top: getSafeAreaTop())
                .backgroundColor(0xF2F2F7)

                // 搜索栏
                Stack {
                    TextInput(text: this.searchQuery)
                        .width(100.percent)
                        .height(36)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(10)
                        .padding(left: 12, right: 12, top: 0, bottom: 0)
                        .fontSize(15)
                        .onChange({ val: String =>
                            this.searchQuery = val
                            this.applySearch(val)
                        })
                    if (this.searchQuery.size == 0) {
                        Text("Search language")
                            .fontSize(15)
                            .fontColor(0xAAAAAA)
                            .width(100.percent)
                            .padding(left: 16)
                            .enabled(false)
                    }
                }
                .width(100.percent)
                .height(36)
                .margin(left: 16, right: 16, top: 8, bottom: 8)

                // 语言列表（popular 热门置顶 + 完整列表）
                Scroll() {
                    Column {
                        // P2-399: Popular 热门分组（对应 iOS popularTranslationLanguages 12 条）
                        if (this.filteredPopular.size > 0) {
                            Row {
                                Text("POPULAR LANGUAGES")
                                    .fontSize(13)
                                    .fontColor(0x8E8E93)
                                    .fontWeight(FontWeight.Medium)
                            }
                            .width(100.percent)
                            .height(32)
                            .padding(left: 16)
                            .alignItems(VerticalAlign.Center)
                            .backgroundColor(0xF2F2F7)

                            Column {
                                ForEach(this.filteredPopular, itemGenerator: { lang: TranslateLanguage, idx: Int64 =>
                                    Row {
                                        Text(lang.name)
                                            .fontSize(16)
                                            .fontColor(0x000000)
                                            .layoutWeight(1)
                                        Text(lang.code)
                                            .fontSize(14)
                                            .fontColor(0x8E8E93)
                                        if (lang.code == getSelectedTranslateLang()) {
                                            Text(" ✓")
                                                .fontSize(16)
                                                .fontColor(0x0088CC)
                                                .margin(left: 6)
                                        }
                                    }
                                    .width(100.percent)
                                    .height(50)
                                    .padding(left: 16, right: 16)
                                    .backgroundColor(0xFFFFFF)
                                    .onClick({ evt =>
                                        let l = lang
                                        this.selectLanguage(l)
                                    })
                                    if (idx < this.filteredPopular.size - 1) {
                                        Divider()
                                            .strokeWidth(1)
                                            .color(0xE5E5EA)
                                            .margin(left: 16)
                                    }
                                })
                            }
                            .width(100.percent)
                            .backgroundColor(0xFFFFFF)

                            // 分隔
                            Row {}
                                .width(100.percent)
                                .height(8)
                                .backgroundColor(0xF2F2F7)
                        }

                        // 完整 104 条语言列表
                        if (this.filteredAll.size > 0) {
                            Row {
                                Text("ALL LANGUAGES")
                                    .fontSize(13)
                                    .fontColor(0x8E8E93)
                                    .fontWeight(FontWeight.Medium)
                            }
                            .width(100.percent)
                            .height(32)
                            .padding(left: 16)
                            .alignItems(VerticalAlign.Center)
                            .backgroundColor(0xF2F2F7)

                            Column {
                                ForEach(this.filteredAll, itemGenerator: { lang: TranslateLanguage, idx: Int64 =>
                                    Row {
                                        Text(lang.name)
                                            .fontSize(16)
                                            .fontColor(0x000000)
                                            .layoutWeight(1)
                                        Text(lang.code)
                                            .fontSize(14)
                                            .fontColor(0x8E8E93)
                                        if (lang.code == getSelectedTranslateLang()) {
                                            Text(" ✓")
                                                .fontSize(16)
                                                .fontColor(0x0088CC)
                                                .margin(left: 6)
                                        }
                                    }
                                    .width(100.percent)
                                    .height(50)
                                    .padding(left: 16, right: 16)
                                    .backgroundColor(0xFFFFFF)
                                    .onClick({ evt =>
                                        let l = lang
                                        this.selectLanguage(l)
                                    })
                                    if (idx < this.filteredAll.size - 1) {
                                        Divider()
                                            .strokeWidth(1)
                                            .color(0xE5E5EA)
                                            .margin(left: 16)
                                    }
                                })
                            }
                            .width(100.percent)
                            .backgroundColor(0xFFFFFF)
                        }
                    }
                    .width(100.percent)
                }
                .width(100.percent)
                .layoutWeight(1)
                .scrollBar(BarState.Auto)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}

// getSelectedTranslateLang / setSelectedTranslateLang 已迁移至 TranslateService.cj（同包 services.*）
// LanguageSelectionPageArguments 通过 import ohos_app_cangjie_entry.services.* 访问
