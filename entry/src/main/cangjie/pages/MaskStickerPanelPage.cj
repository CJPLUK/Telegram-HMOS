package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.{
    StickerPackInfo,
    StickerInstallResult,
    getMaskStickerPanelService
}
import ohos_app_cangjie_entry.router.*

/**
 * MaskStickerPanelPage — 面具贴纸面板页（P2-374）（混合工程迁移版）
 *
 * iOS 对照:
 *   SettingsUI/InstalledStickerPacksController.swift (masks 分类)
 *   TelegramCore/ManagedSynchronizeInstalledStickerPacksOperations.swift masks=true 路径
 *
 * 功能:
 *   - 列出当前账号已安装的所有 mask 贴纸包（messages.getMaskStickers 真 TL）
 *   - 每行: 包名 + 贴纸数量 + 安装状态 + 安装/移除按钮
 *   - 点击包名 → 导航到 StickerPackPreviewPage 查看包内贴纸
 *
 * 真 TL: messages.getMaskStickers#640f82b8 hash:long = messages.AllStickers
 *
 * 路由注册: MainTabPage.pageMap "MaskStickerPanelPage"
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹与 .title/.hideTitleBar/.onReady，只留内容 + .onAppear
 *  - pageStack.pushPath(NavPathInfo(...)) 富参 → setPending("StickerPackPreviewPage", param) + routerPush
 *  - aboutToAppear 有实逻辑 → ensureLoaded()（loaded 守卫）
 */
@HybridComponentEntry
@Component
public class MaskStickerPanelPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // ---- 面具贴纸包列表 ----
    @State var maskPacks: Array<StickerPackInfo> = Array<StickerPackInfo>()
    @State var isLoading: Bool = true
    @State var loadError: Bool = false

    // ---- 操作状态 ----
    @State var operatingPackId: Int64 = -1

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        Hilog.info(0, "CjTelegram", "[MaskStickerPanelPage] onAppear")
        this.loadMaskPacks()
    }

    // ==================== 数据加载 ====================

    /**
     * 从 MaskStickerPanelService.getMaskPacks() 加载已安装 mask 贴纸包列表
     * 真 TL: messages.getMaskStickers#640f82b8 hash:long = messages.AllStickers
     */
    private func loadMaskPacks(): Unit {
        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[MaskStickerPanelPage] loadMaskPacks start")
            let svc = getMaskStickerPanelService()
            let result = svc.getMaskPacks()
            let packs = result.packs
            let total = packs.size
            let arr = Array<StickerPackInfo>(total, { j: Int64 => packs[j] })
            Hilog.info(0, "CjTelegram", "[MaskStickerPanelPage] loadMaskPacks done count=${total}")
            launch {
                if (result.success) {
                    this.maskPacks = arr
                    this.loadError = false
                } else {
                    this.loadError = true
                }
                this.isLoading = false
            }
        }
    }

    // ==================== 操作 ====================

    /**
     * 安装面具贴纸包
     * TL: messages.installStickerSet#c78fe460 (复用 StickersService via MaskStickerPanelService)
     */
    private func doInstall(packId: Int64, accessHash: Int64): Unit {
        if (this.operatingPackId != -1) { return }
        launch { this.operatingPackId = packId }
        let pidLocal = packId
        let ahLocal = accessHash
        let _ = spawn {
            let svc = getMaskStickerPanelService()
            let result: StickerInstallResult = svc.installMaskPack(pidLocal, ahLocal)
            launch {
                if (result.success) {
                    this.updatePackInstallState(pidLocal, true)
                }
                this.operatingPackId = -1
            }
            Hilog.info(0, "CjTelegram", "[MaskStickerPanelPage] install done packId=${pidLocal} success=${result.success}")
        }
    }

    /**
     * 卸载面具贴纸包
     * TL: messages.uninstallStickerSet#f96e55de (复用 StickersService via MaskStickerPanelService)
     */
    private func doUninstall(packId: Int64, accessHash: Int64): Unit {
        if (this.operatingPackId != -1) { return }
        launch { this.operatingPackId = packId }
        let pidLocal = packId
        let ahLocal = accessHash
        let _ = spawn {
            let svc = getMaskStickerPanelService()
            let result: StickerInstallResult = svc.uninstallMaskPack(pidLocal, ahLocal)
            launch {
                if (result.success) {
                    this.updatePackInstallState(pidLocal, false)
                }
                this.operatingPackId = -1
            }
            Hilog.info(0, "CjTelegram", "[MaskStickerPanelPage] uninstall done packId=${pidLocal} success=${result.success}")
        }
    }

    /**
     * 更新 maskPacks 中指定包的 isInstalled 状态
     * @State 集合突变必须用 temp-var + 整重赋值（S-001 / dev_pattern temp-var 模式）
     */
    private func updatePackInstallState(packId: Int64, installed: Bool): Unit {
        let current = this.maskPacks
        let newArr = Array<StickerPackInfo>(current.size, { j: Int64 =>
            let p = current[j]
            if (p.id == packId) {
                p.isInstalled = installed
            }
            p
        })
        this.maskPacks = newArr
    }

    /**
     * 跳转到 StickerPackPreviewPage 查看面具包内容
     * 路由参数格式: "packId|accessHash|shortName"（富参走 ParamStore setPending）
     */
    private func openPackPreview(pack: StickerPackInfo): Unit {
        let param = pack.id.toString() + "|" + pack.accessHash.toString() + "|" + pack.shortName
        setPending("StickerPackPreviewPage", param)
        routerPush("StickerPackPreviewPage")
        Hilog.info(0, "CjTelegram", "[MaskStickerPanelPage] openPackPreview packId=${pack.id}")
    }

    // ==================== UI ====================

    public func build() {
        Column {
            if (this.isLoading) {
                this.buildLoadingView()
            } else if (this.loadError) {
                this.buildErrorView()
            } else if (this.maskPacks.size == 0) {
                this.buildEmptyView()
            } else {
                this.buildPackList()
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFF2F2F7)
        .onAppear({ => this.ensureLoaded() })
    }

    @Builder
    private func buildLoadingView(): Unit {
        Column {
            LoadingProgress()
                .width(40)
                .height(40)
                .color(0xFF007AFF)
            Text("Loading mask stickers...")
                .fontSize(14)
                .fontColor(0xFF8E8E93)
                .margin(top: 12)
        }
        .width(100.percent)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    private func buildErrorView(): Unit {
        Column {
            Text("Failed to load mask sticker packs")
                .fontSize(15)
                .fontColor(0xFF8E8E93)
                .textAlign(TextAlign.Center)
                .margin(bottom: 16)
            Button(trSource("Retry"))
                .fontSize(15)
                .fontColor(0xFFFFFFFF)
                .backgroundColor(0xFF007AFF)
                .borderRadius(8)
                .height(40)
                .width(120)
                .onClick({ _ =>
                    launch {
                        this.isLoading = true
                        this.loadError = false
                    }
                    this.loadMaskPacks()
                })
        }
        .width(100.percent)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    private func buildEmptyView(): Unit {
        Column {
            Text("🎭")
                .fontSize(48)
                .textAlign(TextAlign.Center)
            Text("No mask sticker packs installed")
                .fontSize(15)
                .fontColor(0xFF8E8E93)
                .textAlign(TextAlign.Center)
                .margin(top: 12)
            Text("Browse the sticker store to find mask packs")
                .fontSize(13)
                .fontColor(0xFFAEAEB2)
                .textAlign(TextAlign.Center)
                .margin(top: 4)
        }
        .width(100.percent)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    private func buildPackList(): Unit {
        List { ForEach(this.maskPacks, itemGeneratorFunc: { pack: StickerPackInfo, _idx: Int64 =>
            ListItem {
                this.buildPackRow(pack)
            }
            .backgroundColor(0xFFFFFFFF)
            .borderRadius(0)
        }) }
        .divider(ListDividerOptions(strokeWidth: 0.5, color: 0xFFE5E5EA, startMargin: 16, endMargin: 0))
        .width(100.percent)
        .layoutWeight(1)
        .backgroundColor(0xFFF2F2F7)
    }

    @Builder
    private func buildPackRow(pack: StickerPackInfo): Unit {
        Row {
            Column {
                Text(pack.title)
                    .fontSize(16)
                    .fontColor(0xFF000000)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                    .fontWeight(FontWeight.Medium)
                Row {
                    Text(Int64(pack.count).toString() + " stickers")
                        .fontSize(13)
                        .fontColor(0xFF8E8E93)
                    if (pack.isAnimated) {
                        Text("  ·  Animated")
                            .fontSize(13)
                            .fontColor(0xFF8E8E93)
                    }
                }
                .margin(top: 2)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .onClick({ _ =>
                this.openPackPreview(pack)
            })

            if (this.operatingPackId == pack.id) {
                LoadingProgress()
                    .width(24)
                    .height(24)
                    .color(0xFF007AFF)
                    .margin(left: 8)
            } else if (pack.isInstalled) {
                Button(trSource("Remove"))
                    .fontSize(14)
                    .fontColor(0xFFFF3B30)
                    .backgroundColor(0xFFFFEBE9)
                    .borderRadius(8)
                    .height(32)
                    .padding(left: 12, right: 12)
                    .margin(left: 8)
                    .onClick({ _ =>
                        this.doUninstall(pack.id, pack.accessHash)
                    })
            } else {
                Button(trSource("Add"))
                    .fontSize(14)
                    .fontColor(0xFF007AFF)
                    .backgroundColor(0xFFE5F0FF)
                    .borderRadius(8)
                    .height(32)
                    .padding(left: 12, right: 12)
                    .margin(left: 8)
                    .onClick({ _ =>
                        this.doInstall(pack.id, pack.accessHash)
                    })
            }
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 12, bottom: 12)
        .alignItems(VerticalAlign.Center)
    }
}
