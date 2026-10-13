package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getTelegramUpdateService, getGlobalAbilityContext}
import kit.AbilityKit.Want
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * UpdateInfoPage — 应用更新信息页面（混合工程迁移版）
 *
 * 对应 iOS UpdateInfoController (TelegramUpdateUI)
 * 展示:
 *   1. 当前版本号 (currentVersion from TelegramUpdateService.getCurrentAppVersion)
 *   2. 检查更新结果 (checkForUpdate via MTProto help.getAppUpdate)
 *   3. Changelog/text (来自 help.appUpdate.text)
 *   4. 更新入口(HarmonyOS 平台 honest-defer: 引导至 AppGallery, 无应用内自更新)
 *
 * 防死状态: currentVersion 在 ensureLoaded 同步填充(真实版本常量);
 *           hasUpdate/text/version 在后台 spawn+launch 填充.
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - pageStack.pop() → routerPop()
 *  - aboutToAppear 有实逻辑（版本填充 + loadUpdateInfo）→ ensureLoaded() + .onAppear
 *
 * TL: help.getAppUpdate#522d5a7d
 */
@HybridComponentEntry
@Component
public class UpdateInfoPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 当前安装版本 — ensureLoaded 同步填充，不依赖网络
    @State var currentVersion: String = ""
    // 远端更新版本 — spawn checkForUpdate 填充
    @State var remoteVersion: String = ""
    @State var changelogText: String = ""
    @State var updateUrl: String = ""
    @State var isBlocking: Bool = false
    @State var isLoading: Bool = true
    @State var hasUpdate: Bool = false
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        // 同步填充当前版本 — 真实版本常量，无网络依赖，无死状态
        let service = getTelegramUpdateService()
        this.currentVersion = service.getCurrentAppVersion()
        // 异步检查远端更新
        this.loadUpdateInfo()
    }

    private func loadUpdateInfo(): Unit {
        this.isLoading = true
        this.hasUpdate = false
        this.remoteVersion = ""
        this.changelogText = ""
        this.updateUrl = ""
        this.isBlocking = false
        let _ = spawn {
            let service = getTelegramUpdateService()
            let result = service.checkForUpdate("settings")
            launch {
                this.isLoading = false
                this.hasUpdate = result.hasUpdate
                this.remoteVersion = result.version
                this.changelogText = result.text
                this.updateUrl = result.url
                this.isBlocking = result.blocking
                if (result.hasUpdate) {
                    Hilog.info(0, "CjTelegram", "[UpdateInfoPage] Update available: v${result.version}, blocking=${result.blocking}")
                } else {
                    Hilog.info(0, "CjTelegram", "[UpdateInfoPage] No update available, current v${this.currentVersion}")
                }
            }
        }
    }

    /**
     * HarmonyOS 平台 honest-defer:
     * 鸿蒙无应用内自更新 API，引导用户前往 AppGallery。
     * 若 update.url 有效则尝试 openUri（仅打开外部链接），否则打开 AppGallery 默认 URI。
     * 绝不返回假的"安装成功"。
     */
    private func handleOpenAppGallery(): Unit {
        let targetUrl = if (this.updateUrl.size > 0) {
            this.updateUrl
        } else {
            "appgallery://details?id=org.telegram.messenger"
        }
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let want = Want(action: "ohos.want.action.viewData", uri: targetUrl)
                    ctx.startAbility(want)
                    Hilog.info(0, "CjTelegram", "[UpdateInfoPage] Opened AppGallery: ${targetUrl}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[UpdateInfoPage] openAppGallery failed: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[UpdateInfoPage] No context for openAppGallery")
        }
    }

    private func handleSkip(): Unit {
        if (!this.isBlocking) {
            routerPop()
        }
    }

    private func getUpdateVersionTitle(): String {
        if (this.remoteVersion.size > 0) {
            return "Version " + this.remoteVersion + " Available"
        }
        return "Update Available"
    }

    public func build() {
        Column {
            // Header row
            Row {
                if (!this.isBlocking) {
                    Text(trSource("Back"))
                        .fontSize(17)
                        .fontColor(0x317AFF)
                        .onClick({ _evt =>
                            routerPop()
                        })
                }
                Blank().layoutWeight(1)
                Text("App Update")
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
                Blank().layoutWeight(1)
                if (!this.isBlocking) {
                    Text(trSource("Skip"))
                        .fontSize(17)
                        .fontColor(0x317AFF)
                        .onClick({ _evt => this.handleSkip() })
                } else {
                    // Placeholder to balance flex
                    Text("     ").fontSize(17)
                }
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(0xF7F7F7)
            .alignItems(VerticalAlign.Center)

            Divider().color(0xE5E5EA).strokeWidth(0.5)

            // Current version info row (always visible, filled from real version constant)
            Row {
                Text("Current Version:")
                    .fontSize(14)
                    .fontColor(0x8E8E93)
                Blank().layoutWeight(1)
                Text(this.currentVersion)
                    .fontSize(14)
                    .fontColor(0x3C3C43)
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 10, bottom: 10)
            .backgroundColor(0xFFFFFF)

            Divider().color(0xE5E5EA).strokeWidth(0.5)

            if (this.isLoading) {
                Column {
                    LoadingProgress().width(32).height(32).color(0x317AFF)
                    Text("Checking for updates...")
                        .fontSize(14)
                        .fontColor(0x999999)
                        .margin(top: 8)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else if (this.hasUpdate) {
                Scroll {
                    Column {
                        // Update header
                        Row {
                            Column {
                                Text(trSource("NEW"))
                                    .fontSize(11)
                                    .fontWeight(FontWeight.Bold)
                                    .fontColor(0xFFFFFF)
                            }
                            .width(62)
                            .height(62)
                            .borderRadius(12)
                            .backgroundColor(0x34C759)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                            .margin(right: 16)

                            Column {
                                Text(this.getUpdateVersionTitle())
                                    .fontSize(17)
                                    .fontWeight(FontWeight.Bold)
                                    .fontColor(0x000000)
                                if (this.isBlocking) {
                                    Text("This update is required")
                                        .fontSize(13)
                                        .fontColor(0xFF3B30)
                                        .margin(top: 4)
                                }
                            }
                            .layoutWeight(1)
                            .alignItems(HorizontalAlign.Start)
                        }
                        .width(100.percent)
                        .padding(16)
                        .alignItems(VerticalAlign.Center)

                        // Changelog text
                        if (this.changelogText.size > 0) {
                            Column {
                                Text("What's New")
                                    .fontSize(13)
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(0x8E8E93)
                                    .margin(bottom: 8)
                                Text(this.changelogText)
                                    .fontSize(15)
                                    .fontColor(0x3C3C43)
                                    .maxLines(30)
                                    .textOverflow(TextOverflow.Ellipsis)
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, bottom: 16)
                            .alignItems(HorizontalAlign.Start)
                        }

                        // HarmonyOS honest-defer: AppGallery update button
                        // 鸿蒙无应用内自更新; 引导至 AppGallery
                        Column {
                            Button("Update on AppGallery")
                                .width(100.percent)
                                .height(50)
                                .fontSize(17)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0xFFFFFF)
                                .backgroundColor(0x317AFF)
                                .borderRadius(10)
                                .onClick({ _evt => this.handleOpenAppGallery() })
                            Text("Updates are distributed via Huawei AppGallery")
                                .fontSize(12)
                                .fontColor(0x8E8E93)
                                .margin(top: 8)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 8, bottom: 32)
                        .alignItems(HorizontalAlign.Center)
                    }
                    .width(100.percent)
                }
                .layoutWeight(1)
                .scrollBar(BarState.Off)
            } else {
                // No update: "You're up to date"
                Column {
                    Text("Telegram is up to date")
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(0x000000)
                        .margin(top: 12)
                    Text("Version " + this.currentVersion)
                        .fontSize(15)
                        .fontColor(0x8E8E93)
                        .margin(top: 4)
                    Text("Check for updates on AppGallery")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(top: 16)
                    Button("Open AppGallery")
                        .height(40)
                        .fontSize(15)
                        .fontColor(0x317AFF)
                        .backgroundColor(0xF2F2F7)
                        .borderRadius(8)
                        .padding(left: 20, right: 20)
                        .margin(top: 8)
                        .onClick({ _evt => this.handleOpenAppGallery() })
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFF)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
