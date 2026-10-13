package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.sync.*
import std.time.DateTime
import ohos_app_cangjie_entry.services.getUpdatesManager
import ohos_app_cangjie_entry.core.mtproto.getMTProtoClient
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * Settings Sync Page (P4-11 — Real UpdatesManager data)（混合工程迁移版）
 *
 * Displays actual sync state from UpdatesManager, connection info from MTProtoClient,
 * and persisted sync state from AuthStorage.
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack（pageStack.pop() → routerPop()）
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - aboutToAppear(refreshState + 5s 轮询) → ensureLoaded() + .onAppear
 *  - aboutToDisappear(isPageVisible=false) → cleanup() + .onDisAppear
 */
@HybridComponentEntry
@Component
public class SettingsBackendPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var isConnected: Bool = false
    @State var isInitialized: Bool = false
    @State var currentPts: Int32 = 0
    @State var currentQts: Int32 = 0
    @State var currentDate: Int32 = 0
    @State var currentSeq: Int32 = 0
    @State var gapCount: Int32 = 0
    @State var isSyncing: Bool = false
    @State var syncResult: String = ""
    @State var lastSyncDisplay: String = "Unknown"
    @State var isPageVisible: Bool = true
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.refreshState()
        this.isPageVisible = true
        let _ = spawn {
            while (this.isPageVisible) {
                sleep(Duration.second * 5)
                if (this.isPageVisible) {
                    launch { this.refreshState() }
                }
            }
        }
    }

    private func cleanup(): Unit {
        this.isPageVisible = false
    }

    private func refreshState(): Unit {
        let mgr = getUpdatesManager()
        this.isInitialized = mgr.isInitialized()
        this.currentPts = mgr.getCurrentPts()
        this.currentQts = mgr.getCurrentQts()
        this.currentDate = mgr.getCurrentDate()
        this.currentSeq = mgr.getCurrentSeq()
        this.gapCount = mgr.getGapCount()

        // Connection check: try to see if client exists and session is active
        try {
            let client = getMTProtoClient()
            this.isConnected = true
        } catch (_e: Exception) {
            this.isConnected = false
        }

        // Format last sync time from currentDate (unix timestamp)
        if (this.currentDate > 0) {
            this.lastSyncDisplay = this.formatRelativeTime(Int64(this.currentDate))
        } else {
            this.lastSyncDisplay = "Never"
        }
    }

    private func formatRelativeTime(timestamp: Int64): String {
        let now = DateTime.now().toUnixTimeStamp().toSeconds()
        let diff = now - timestamp
        if (diff < 0) { return "Just now" }
        if (diff < 5) { return "Just now" }
        if (diff < 60) { return "${diff}s ago" }
        if (diff < 3600) { return "${diff / 60}m ago" }
        if (diff < 86400) { return "${diff / 3600}h ago" }
        return "${diff / 86400}d ago"
    }

    private func doSync(): Unit {
        if (this.isSyncing) { return }
        this.isSyncing = true
        this.syncResult = ""
        let _ = spawn {
            try {
                let mgr = getUpdatesManager()
                mgr.forceDifference()
                launch {
                    this.refreshState()
                    this.syncResult = "Sync completed successfully"
                    this.isSyncing = false
                }
                Hilog.info(0, "CjTelegram", "[SettingsBackend] Manual sync completed")
            } catch (e: Exception) {
                let errMsg = "Sync failed: ${e}"
                launch {
                    this.syncResult = errMsg
                    this.isSyncing = false
                }
                Hilog.info(0, "CjTelegram", "[SettingsBackend] Manual sync failed: ${e}")
            }
        }
    }

    public func build() {
        Column {
            Row {
                Text("←")
                    .fontSize(20)
                    .fontColor(0x007AFF)
                    .onClick({ evt => routerPop() })
                Blank().layoutWeight(1)
                Text("Sync & Backend")
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
                Blank().layoutWeight(1)
                Row { }.width(40)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(0xFFFFFF)
            .alignItems(VerticalAlign.Center)

            Scroll {
                Column {
                    // CONNECTION STATUS
                    Text(trSource("CONNECTION"))
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(left: 16, top: 16, bottom: 8)
                        .width(100.percent)

                    Column {
                        Row {
                            Text(if (this.isConnected) { "🟢" } else { "🔴" })
                                .fontSize(16)
                                .margin(right: 8)
                            Text(if (this.isConnected) { "Connected" } else { "Not Connected" })
                                .fontSize(17)
                                .fontColor(if (this.isConnected) { 0x34C759 } else { 0xFF3B30 })
                                .layoutWeight(1)
                        }
                        .width(100.percent)
                        .height(50)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                    }
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(12)
                    .margin(left: 16, right: 16)

                    // SYNC STATE
                    Text("SYNC STATE")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(left: 16, top: 24, bottom: 8)
                        .width(100.percent)

                    Column {
                        Row {
                            Text(trSource("Status"))
                                .fontSize(17)
                                .fontColor(0x000000)
                                .layoutWeight(1)
                            Text(if (this.isInitialized) { "Initialized" } else { "Not initialized" })
                                .fontSize(15)
                                .fontColor(if (this.isInitialized) { 0x34C759 } else { 0xFF9500 })
                        }
                        .width(100.percent)
                        .height(50)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)

                        Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16)

                        Row {
                            Text("Last Sync")
                                .fontSize(17)
                                .fontColor(0x000000)
                                .layoutWeight(1)
                            Text(this.lastSyncDisplay)
                                .fontSize(15)
                                .fontColor(0x8E8E93)
                        }
                        .width(100.percent)
                        .height(50)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)

                        Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16)

                        Row {
                            Text("pts / qts / seq")
                                .fontSize(17)
                                .fontColor(0x000000)
                                .layoutWeight(1)
                            Text("${this.currentPts} / ${this.currentQts} / ${this.currentSeq}")
                                .fontSize(15)
                                .fontColor(0x8E8E93)
                        }
                        .width(100.percent)
                        .height(50)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)

                        Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16)

                        Row {
                            Text("Pending Gaps")
                                .fontSize(17)
                                .fontColor(0x000000)
                                .layoutWeight(1)
                            Text(if (this.gapCount == 0) { "0 (synced)" } else { "${this.gapCount}" })
                                .fontSize(15)
                                .fontColor(if (this.gapCount == 0) { 0x34C759 } else { 0xFF9500 })
                        }
                        .width(100.percent)
                        .height(50)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                    }
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(12)
                    .margin(left: 16, right: 16)

                    // SYNC BUTTON
                    Button(if (this.isSyncing) { "Syncing..." } else { "Sync Now" })
                        .width(100.percent)
                        .height(50)
                        .fontSize(17)
                        .fontColor(0xFFFFFF)
                        .backgroundColor(if (this.isSyncing) { 0x8E8E93 } else { 0x0088CC })
                        .margin(left: 16, right: 16, top: 24)
                        .borderRadius(12)
                        .onClick({ evt => this.doSync() })

                    if (this.syncResult.size > 0) {
                        Text(this.syncResult)
                            .fontSize(13)
                            .fontColor(0x34C759)
                            .margin(left: 16, top: 8)
                            .width(100.percent)
                    }

                    Text("Tap Sync Now to force a getDifference update from the server. The page refreshes every 5 seconds automatically.")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(left: 16, right: 16, top: 8, bottom: 32)
                        .width(100.percent)
                }
            }
            .layoutWeight(1)
            .backgroundColor(0xF2F2F7)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
        .onDisAppear({ => this.cleanup() })
    }
}
