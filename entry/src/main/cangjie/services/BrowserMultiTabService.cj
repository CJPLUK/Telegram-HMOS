package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos.web.webview.WebviewController

/**
 * BrowserTab — single browser tab model.
 *
 * P2-051: Multi-tab browsing.
 *
 * Each tab owns one WebviewController, url, title, and an optional snapshot title
 * (displayed in the tab bar when the page is not yet fully loaded).
 *
 * iOS analogue: BrowserScreen tabs via NavigationStackComponent / MinimizedContainer.
 * Cangjie: Multiple WebviewController instances confirmed feasible by KB
 * (nested-scrolling example: controller + controller2 coexist).
 * Tab switching is done by visibility control (`if activeTabIndex == i`) in build().
 *
 * Ctor grep: WebviewController() — confirmed in cj-apis-webview KB docs.
 */
public class BrowserTab {
    public var url: String = ""
    public var title: String = "New Tab"
    public var webController: WebviewController = WebviewController()
    public var isLoading: Bool = false
    public var snapshotTitle: String = ""

    public init() {}
}

// ── Singleton tab registry (used by BrowserScreen to carry tab state) ──

private var _globalTabs: Option<BrowserTabRegistry> = None

public func getBrowserTabRegistry(): BrowserTabRegistry {
    match (_globalTabs) {
        case Some(r) => return r
        case None =>
            let r = BrowserTabRegistry()
            _globalTabs = Some(r)
            return r
    }
}

/**
 * BrowserTabRegistry — holds the shared list of open tabs.
 * BrowserScreen reads/writes via this singleton to preserve tab state across
 * navigation pushes (e.g., when going to InstantPagePage and returning).
 *
 * Max tabs: 8 (reasonable cap for mobile; iOS has no hard cap but UI becomes
 * unwieldy beyond ~8).
 */
public class BrowserTabRegistry {
    public let maxTabs: Int64 = 8

    public var tabs: Array<BrowserTab> = [BrowserTab()]
    public var activeTabIndex: Int64 = 0

    public init() {}

    /**
     * Open a new tab with an optional initial URL.
     * Returns the index of the new tab.
     */
    public func openNewTab(url: String): Int64 {
        if (this.tabs.size >= this.maxTabs) {
            Hilog.info(0, "CjTelegram", "[BrowserTabRegistry] max tabs reached, replacing oldest non-active")
            // Replace the oldest non-active tab
            // Use let bindings before lambda (R-111: lambda can't capture var)
            var foundIdx: Int64 = 0
            var i: Int64 = 0
            while (i < this.tabs.size) {
                if (i != this.activeTabIndex) {
                    foundIdx = i
                    break
                }
                i = i + 1
            }
            let replaceIdx = foundIdx  // immutable copy for lambda capture
            let tab = BrowserTab()
            tab.url = url
            if (url.size > 0) { tab.title = url }
            let tabRef = tab
            let oldTabs = this.tabs
            var newTabs = Array<BrowserTab>(oldTabs.size, { idx: Int64 =>
                if (idx == replaceIdx) { tabRef } else { oldTabs[idx] }
            })
            this.tabs = newTabs
            this.activeTabIndex = replaceIdx
            return replaceIdx
        }
        let tab = BrowserTab()
        tab.url = url
        if (url.size > 0) { tab.title = url }
        let newSize = this.tabs.size + 1
        let insertIdx = newSize - 1
        let tabRef2 = tab
        let oldTabs2 = this.tabs
        var newTabs = Array<BrowserTab>(newSize, { idx: Int64 =>
            if (idx < oldTabs2.size) { oldTabs2[idx] } else { tabRef2 }
        })
        this.tabs = newTabs
        this.activeTabIndex = insertIdx
        return insertIdx
    }

    /**
     * Close tab at index.
     * If last tab, resets to a single blank tab.
     */
    public func closeTab(index: Int64): Unit {
        let n = this.tabs.size
        if (n <= 1) {
            // Last tab: reset to blank
            let blank = BrowserTab()
            this.tabs = [blank]
            this.activeTabIndex = 0
            Hilog.info(0, "CjTelegram", "[BrowserTabRegistry] last tab reset to blank")
            return
        }
        // Build new array without index (capture immutable refs per R-111)
        let oldTabsRef = this.tabs
        let closeIndex = index
        var newTabs = Array<BrowserTab>(n - 1, { idx: Int64 =>
            if (idx < closeIndex) { oldTabsRef[idx] } else { oldTabsRef[idx + 1] }
        })
        this.tabs = newTabs
        // Adjust active index
        if (this.activeTabIndex >= index) {
            let newActive = this.activeTabIndex - 1
            this.activeTabIndex = if (newActive < 0) { 0 } else { newActive }
        }
        Hilog.info(0, "CjTelegram", "[BrowserTabRegistry] closed tab ${index}, active=${this.activeTabIndex}")
    }

    /**
     * Switch to tab at index.
     */
    public func switchToTab(index: Int64): Unit {
        if (index >= 0 && index < this.tabs.size) {
            this.activeTabIndex = index
            Hilog.info(0, "CjTelegram", "[BrowserTabRegistry] switched to tab ${index}")
        }
    }

    /**
     * Update URL and title for the active tab.
     */
    public func updateActiveTab(url: String, title: String): Unit {
        if (this.activeTabIndex >= 0 && this.activeTabIndex < this.tabs.size) {
            this.tabs[this.activeTabIndex].url = url
            if (title.size > 0) { this.tabs[this.activeTabIndex].title = title }
        }
    }

    /**
     * Active tab accessor.
     */
    public func activeTab(): BrowserTab {
        if (this.activeTabIndex >= 0 && this.activeTabIndex < this.tabs.size) {
            return this.tabs[this.activeTabIndex]
        }
        return this.tabs[0]
    }

    public func tabCount(): Int64 {
        return this.tabs.size
    }
}
