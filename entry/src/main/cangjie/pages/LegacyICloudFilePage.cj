package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*

/**
 * LegacyICloudFilePage — iCloud 文件列表页面（HarmonyOS 本地等效实现）（混合工程迁移版）
 *
 * iOS 对应：LegacyICloudFilePicker.swift → LegacyICloudFileController
 *
 * 功能：
 * - 展示应用沙盒中的本地文件列表（对应 iOS iCloud Drive 文件列表）
 * - 支持按文件类型过滤（图片 / 文档 / 全部）
 * - 支持点击选择单个文件
 * - 支持多选模式（allowsMultipleSelection=true 等效：长按进入多选）
 *
 * 平台说明：
 *   iOS LegacyICloudFileController 使用 NSMetadataQuery 检测 iCloud 文件同步状态，
 *   HarmonyOS 无 iCloud 等效，直接读取应用沙盒 filesDir 中的本地文件。
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack（appStack）
 *  - build() 根去掉 NavDestination 包裹与 .title/.hideTitleBar，只留内容 + .onAppear
 *  - appStack.pop(animated:) → routerPop()
 *  - appStack.pushPathByName("ShareControllerPage", "") → routerPush("ShareControllerPage")
 *  - aboutToAppear 有实逻辑 → ensureLoaded()（loaded 守卫）
 */
@HybridComponentEntry
@Component
public class LegacyICloudFilePage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var allFiles: ArrayList<DocumentFileInfo> = ArrayList<DocumentFileInfo>()
    @State var displayList: ArrayList<DocumentFileInfo> = ArrayList<DocumentFileInfo>()
    @State var isLoading: Bool = false
    @State var filterMode: String = "all"
    @State var multiSelectMode: Bool = false
    @State var selectedFilePath: String = ""
    @State var selectedPaths: ArrayList<String> = ArrayList<String>()
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadFiles()
    }

    private func loadFiles(): Unit {
        this.isLoading = true
        let svc = getLegacyMediaPickerService()
        let filesDir = getAppFilesDir()
        let _ = spawn {
            let items = svc.scanDocumentFiles(filesDir)
            launch {
                this.allFiles = items
                this.applyFilter(this.filterMode)
                this.isLoading = false
                Hilog.info(0, "CjTelegram", "[LegacyICloudFilePage] Loaded " + items.size.toString() + " files")
            }
        }
    }

    private func applyFilter(mode: String): Unit {
        this.filterMode = mode
        let filtered = ArrayList<DocumentFileInfo>()
        for (f in this.allFiles) {
            if (mode == "all") {
                filtered.add(f)
            } else if (mode == "images" && f.isImage) {
                filtered.add(f)
            } else if (mode == "docs" && !f.isImage && !f.isVideo) {
                filtered.add(f)
            } else if (mode == "video" && f.isVideo) {
                filtered.add(f)
            }
        }
        this.displayList = filtered
        Hilog.info(0, "CjTelegram", "[LegacyICloudFilePage] filter=" + mode + " count=" + filtered.size.toString())
    }

    private func onSelectFile(info: DocumentFileInfo): Unit {
        if (this.multiSelectMode) {
            let path = info.filePath
            var alreadySelected = false
            for (p in this.selectedPaths) {
                if (p == path) {
                    alreadySelected = true
                }
            }
            if (alreadySelected) {
                let newList = ArrayList<String>()
                for (p in this.selectedPaths) {
                    if (p != path) {
                        newList.add(p)
                    }
                }
                this.selectedPaths = newList
            } else {
                this.selectedPaths.add(path)
            }
        } else {
            this.selectedFilePath = info.filePath
            Hilog.info(0, "CjTelegram", "[LegacyICloudFilePage] Selected: " + info.filePath)
            routerPop()
        }
    }

    private func onConfirmMultiSelect(): Unit {
        Hilog.info(0, "CjTelegram", "[LegacyICloudFilePage] Confirm multi-select count=" + this.selectedPaths.size.toString())
        if (this.selectedPaths.isEmpty()) {
            routerPop()
            return
        }
        // P2-357: 将多选文件路径存入 pending 队列，再路由到 ShareControllerPage 完成发送流
        // iOS 对应：LegacyICloudFileController.completion([URL]) → ShareController 接收
        let pathsCopy = ArrayList<String>()
        for (p in this.selectedPaths) {
            pathsCopy.add(p)
        }
        setPendingExternalFilePaths(pathsCopy)
        this.selectedPaths = ArrayList<String>()
        routerPop()
        routerPush("ShareControllerPage")
        Hilog.info(0, "CjTelegram", "[LegacyICloudFilePage] onConfirmMultiSelect: routed ${pathsCopy.size} files to ShareControllerPage")
    }

    private func isSelected(path: String): Bool {
        for (p in this.selectedPaths) {
            if (p == path) { return true }
        }
        return false
    }

    private func formatSize(info: DocumentFileInfo): String {
        return getLegacyMediaPickerService().formatFileSize(info.fileSize)
    }

    private func typeLabel(info: DocumentFileInfo): String {
        return getLegacyMediaPickerService().fileTypeLabel(info)
    }

    private func hasFiles(): Bool {
        return this.displayList.size > 0
    }

    private func getDisplayItems(): Array<DocumentFileInfo> {
        return this.displayList.toArray()
    }

    public func build() {
        Column {
            // 过滤栏
            Row {
                Text(trSource("All"))
                    .fontSize(13)
                    .fontColor(if (this.filterMode == "all") { 0xFF007AFF } else { 0xFF8E8E93 })
                    .backgroundColor(if (this.filterMode == "all") { 0x1A007AFF } else { Color.Transparent })
                    .padding(left: 12, right: 12, top: 6, bottom: 6)
                    .borderRadius(16)
                    .onClick({ _ => this.applyFilter("all") })
                Text(trSource("Images"))
                    .fontSize(13)
                    .fontColor(if (this.filterMode == "images") { 0xFF007AFF } else { 0xFF8E8E93 })
                    .backgroundColor(if (this.filterMode == "images") { 0x1A007AFF } else { Color.Transparent })
                    .padding(left: 12, right: 12, top: 6, bottom: 6)
                    .borderRadius(16)
                    .margin(left: 8)
                    .onClick({ _ => this.applyFilter("images") })
                Text(trSource("Docs"))
                    .fontSize(13)
                    .fontColor(if (this.filterMode == "docs") { 0xFF007AFF } else { 0xFF8E8E93 })
                    .backgroundColor(if (this.filterMode == "docs") { 0x1A007AFF } else { Color.Transparent })
                    .padding(left: 12, right: 12, top: 6, bottom: 6)
                    .borderRadius(16)
                    .margin(left: 8)
                    .onClick({ _ => this.applyFilter("docs") })
                Text(trSource("Video"))
                    .fontSize(13)
                    .fontColor(if (this.filterMode == "video") { 0xFF007AFF } else { 0xFF8E8E93 })
                    .backgroundColor(if (this.filterMode == "video") { 0x1A007AFF } else { Color.Transparent })
                    .padding(left: 12, right: 12, top: 6, bottom: 6)
                    .borderRadius(16)
                    .margin(left: 8)
                    .onClick({ _ => this.applyFilter("video") })
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 8, bottom: 8)
            .backgroundColor(0xFFFFFFFF)

            if (this.isLoading) {
                Column {
                    LoadingProgress()
                        .width(48)
                        .height(48)
                    Text("Loading files...")
                        .fontSize(14)
                        .fontColor(0xFF999999)
                        .margin(top: 8)
                }
                .width(100.percent)
                .height(200)
                .justifyContent(FlexAlign.Center)
            } else if (!this.hasFiles()) {
                Column {
                    Text("No files available")
                        .fontSize(16)
                        .fontColor(0xFF999999)
                    Text("Files saved to this device will appear here")
                        .fontSize(13)
                        .fontColor(0xFFAAAAAA)
                        .margin(top: 8)
                }
                .width(100.percent)
                .height(300)
                .justifyContent(FlexAlign.Center)
            } else {
                List {
                    ForEach(this.getDisplayItems(), itemGenerator: { item: DocumentFileInfo, _idx: Int64 =>
                        ListItem {
                            Row {
                                if (this.multiSelectMode) {
                                    Text(if (this.isSelected(item.filePath)) { "✓" } else { "" })
                                        .fontSize(16)
                                        .fontColor(0xFF007AFF)
                                        .width(24)
                                }
                                Column {
                                    Text(item.fileName)
                                        .fontSize(16)
                                        .fontColor(0xFF1C1C1E)
                                        .maxLines(1)
                                        .textOverflow(TextOverflow.Ellipsis)
                                    Row {
                                        Text(this.typeLabel(item))
                                            .fontSize(12)
                                            .fontColor(0xFF007AFF)
                                            .backgroundColor(0x1A007AFF)
                                            .padding(left: 6, right: 6, top: 2, bottom: 2)
                                            .borderRadius(4)
                                        Text(this.formatSize(item))
                                            .fontSize(12)
                                            .fontColor(0xFF8E8E93)
                                            .margin(left: 8)
                                    }
                                    .margin(top: 4)
                                }
                                .alignItems(HorizontalAlign.Start)
                                .layoutWeight(1)
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 12, bottom: 12)
                            .onClick({ _ => this.onSelectFile(item) })
                        }
                    })
                }
                .width(100.percent)
                .layoutWeight(1)
                .divider(ListDividerOptions(strokeWidth: 0.5, color: 0xFFE5E5EA, startMargin: 16, endMargin: 0))
            }

            if (this.multiSelectMode && this.selectedPaths.size > 0) {
                Row {
                    Text("Attach " + this.selectedPaths.size.toString() + " files")
                        .fontSize(16)
                        .fontColor(0xFFFFFFFF)
                    Blank()
                    Text(trSource("Done"))
                        .fontSize(16)
                        .fontColor(0xFFFFFFFF)
                        .onClick({ _ => this.onConfirmMultiSelect() })
                }
                .width(100.percent)
                .padding(left: 20, right: 20, top: 14, bottom: 14)
                .backgroundColor(0xFF007AFF)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFF2F2F7)
        .onAppear({ => this.ensureLoaded() })
    }
}
