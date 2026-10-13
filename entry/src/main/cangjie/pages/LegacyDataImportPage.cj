package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import std.collection.ArrayList
import ohos_app_cangjie_entry.router.*

/**
 * 旧数据导入页面 — LegacyDataImportPage（混合工程迁移版）
 *
 * 将其他 Telegram 客户端导出的聊天记录导入到指定对话。
 * 三步 MTProto 流程：
 *   1. 从沙箱读取导入文件
 *   2. messages.initHistoryImport → 获取 importId
 *   3. messages.startHistoryImport → 提交导入
 *
 * 路由注册：MainTabPage.pageMap "LegacyDataImportPage"
 *
 * iOS 参考：submodules/LegacyDataImport/Sources/LegacyDataImport.swift
 *           submodules/LegacyDataImport/Sources/LegacyDataImportSplash.swift
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹与 .hideTitleBar，只留内容 + .onAppear
 *  - pageStack.pop() → routerPop()
 *  - aboutToAppear 有实逻辑 → ensureLoaded()（loaded 守卫）
 */
@HybridComponentEntry
@Component
public class LegacyDataImportPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var selectedFilePath: String = ""
    @State var selectedFileName: String = ""
    @State var selectedFileSize: Int64 = 0
    @State var isImporting: Bool = false
    @State var importPhase: String = "idle"
    @State var importSuccess: Bool = false
    @State var errorMessage: String = ""
    @State var showError: Bool = false

    @State var targetPeerId: Int64 = 0
    @State var targetPeerHash: Int64 = 0
    @State var targetPeerType: String = "user"
    @State var targetPeerName: String = ""
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let storage = getAuthStorage()
        let userData = storage.getUserData()
        match (userData) {
            case Some(u) =>
                this.targetPeerId = u.id
                this.targetPeerHash = getRealMessageService().getAccessHashForUser(u.id)
                this.targetPeerType = "user"
                let displayName = if (u.firstName.size > 0) {
                    if (u.lastName.size > 0) { u.firstName + " " + u.lastName } else { u.firstName }
                } else {
                    u.username
                }
                this.targetPeerName = displayName
                Hilog.info(0, "CjTelegram", "[LegacyDataImportPage] ensureLoaded: peer=${this.targetPeerId}")
            case None =>
                Hilog.info(0, "CjTelegram", "[LegacyDataImportPage] ensureLoaded: no user data")
        }
    }

    private func selectImportFile(): Unit {
        let filesDir = getAppFilesDir()
        Hilog.info(0, "CjTelegram", "[LegacyDataImportPage] selectImportFile: filesDir=${filesDir}")

        let candidatePaths = ArrayList<String>()
        candidatePaths.add(filesDir + "/import_history.zip")
        candidatePaths.add(filesDir + "/telegram_export.zip")
        candidatePaths.add(filesDir + "/chat_export.txt")
        candidatePaths.add(filesDir + "/history_export.txt")

        var found = false
        for (p in candidatePaths) {
            let exists = FileIo.access(p)
            if (exists) {
                let st = FileIo.stat(p)
                if (st.size > 0) {
                    let parts = p.split("/")
                    let name = if (parts.size > 0) { parts[parts.size - 1] } else { "export.zip" }
                    let pSize = st.size
                    launch {
                        this.selectedFilePath = p
                        this.selectedFileName = name
                        this.selectedFileSize = pSize
                        this.errorMessage = ""
                        this.showError = false
                        Hilog.info(0, "CjTelegram", "[LegacyDataImportPage] File selected: ${name}, size=${pSize}")
                    }
                    found = true
                    break
                }
            }
        }
        if (!found) {
            launch {
                this.errorMessage = "No import file found in app documents directory. Place a .zip or .txt export file there and try again."
                this.showError = true
                Hilog.info(0, "CjTelegram", "[LegacyDataImportPage] No importable file found")
            }
        }
    }

    private func startImport(): Unit {
        if (this.selectedFilePath.size == 0) {
            launch {
                this.errorMessage = "Please select an import file first."
                this.showError = true
            }
            return
        }
        if (this.targetPeerId == 0) {
            launch {
                this.errorMessage = "No target peer selected. Please log in first."
                this.showError = true
            }
            return
        }

        launch {
            this.isImporting = true
            this.importPhase = "uploading"
            this.importSuccess = false
            this.showError = false
            this.errorMessage = ""
        }

        let filePath = this.selectedFilePath
        let fileName = this.selectedFileName
        let peerId = this.targetPeerId
        let peerHash = this.targetPeerHash
        let peerType = this.targetPeerType

        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[LegacyDataImportPage] Reading file: ${filePath}")

            var fileBytes: Array<Byte> = Array<Byte>(0, repeat: 0)
            var readOk = false
            try {
                let srcFile = FileIo.open(filePath, mode: 0o0)
                let st = FileIo.stat(srcFile.fd)
                if (st.size > 0) {
                    let buf = Array<Byte>(st.size, repeat: 0)
                    let _ = FileIo.read(srcFile.fd, buf)
                    FileIo.close(srcFile)
                    fileBytes = buf
                    readOk = true
                    Hilog.info(0, "CjTelegram", "[LegacyDataImportPage] Read ${st.size} bytes from ${fileName}")
                } else {
                    FileIo.close(srcFile)
                    Hilog.info(0, "CjTelegram", "[LegacyDataImportPage] File is empty: ${filePath}")
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[LegacyDataImportPage] File read error: ${e}")
            }

            if (!readOk || fileBytes.size == 0) {
                launch {
                    this.isImporting = false
                    this.importPhase = "failed"
                    this.errorMessage = "Failed to read the import file."
                    this.showError = true
                }
                return
            }

            launch { this.importPhase = "initializing" }

            let svc = getLegacyDataImportService()
            let progress = ImportProgress()

            let ok = svc.runImport(
                peerId: peerId,
                peerAccessHash: peerHash,
                peerType: peerType,
                fileData: fileBytes,
                fileName: fileName,
                progress: progress
            )

            let finalPhase = progress.phase
            let finalErr = progress.errorMessage
            let finalOk = ok

            launch {
                this.isImporting = false
                this.importPhase = finalPhase
                this.importSuccess = finalOk
                if (!finalOk) {
                    this.errorMessage = if (finalErr.size > 0) { finalErr } else { "Import failed. Please try again." }
                    this.showError = true
                }
                Hilog.info(0, "CjTelegram", "[LegacyDataImportPage] Import finished: success=${finalOk}, phase=${finalPhase}")
            }
        }
    }

    private func getPhaseLabel(): String {
        match (this.importPhase) {
            case "uploading" => return "Uploading file..."
            case "initializing" => return "Initializing import..."
            case "starting" => return "Starting import..."
            case "done" => return "Done"
            case "failed" => return "Failed"
            case _ => return "Ready"
        }
    }

    private func formatFileSize(size: Int64): String {
        if (size < 1024) {
            return "${size} B"
        } else if (size < 1048576) {
            let kb = size / 1024
            return "${kb} KB"
        } else {
            let mb = size / 1048576
            return "${mb} MB"
        }
    }

    public func build() {
        Column() {
            Row() {
                Text("Import Chat History")
                    .fontSize(20)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0xFF000000)
                    .layoutWeight(1)
                Button(trSource("Back"))
                    .fontSize(14)
                    .fontColor(0xFF007AFF)
                    .backgroundColor(Color.Transparent)
                    .onClick({ _ => routerPop() })
            }.width(100.percent).padding(16)

            Divider().color(0xFFE5E5EA).width(100.percent)

            Column() {
                Text("Import message history from another Telegram client export file.")
                    .fontSize(14)
                    .fontColor(0xFF8E8E93)
                    .textAlign(TextAlign.Center)
                    .padding(16)
                    .width(100.percent)

                if (this.importSuccess) {
                    Column() {
                        Text("Import complete! Your chat history has been submitted for processing.")
                            .fontSize(16)
                            .fontColor(0xFF34C759)
                            .fontWeight(FontWeight.Medium)
                            .textAlign(TextAlign.Center)
                            .padding(16)
                    }
                    .width(100.percent)
                    .padding(32)
                    .alignItems(HorizontalAlign.Center)
                } else if (this.isImporting) {
                    Column() {
                        LoadingProgress()
                            .width(48)
                            .height(48)
                            .color(0xFF007AFF)
                            .margin(bottom: 16)
                        Text(this.getPhaseLabel())
                            .fontSize(15)
                            .fontColor(0xFF1C1C1E)
                    }
                    .width(100.percent)
                    .padding(32)
                    .alignItems(HorizontalAlign.Center)
                } else {
                    Column() {
                        if (this.selectedFilePath.size == 0) {
                            Column() {
                                Text("No file selected")
                                    .fontSize(14)
                                    .fontColor(0xFF8E8E93)
                            }
                            .width(100.percent)
                            .alignItems(HorizontalAlign.Center)
                            .padding(top: 24, bottom: 24, left: 16, right: 16)
                        } else {
                            Row() {
                                Column() {
                                    Text(this.selectedFileName)
                                        .fontSize(15)
                                        .fontColor(0xFF1C1C1E)
                                        .fontWeight(FontWeight.Medium)
                                    Text(this.formatFileSize(this.selectedFileSize))
                                        .fontSize(13)
                                        .fontColor(0xFF8E8E93)
                                        .margin(top: 4)
                                }.alignItems(HorizontalAlign.Start)
                            }
                            .width(100.percent)
                            .padding(16)
                            .backgroundColor(0xFFF2F2F7)
                            .borderRadius(12)
                            .margin(left: 16, right: 16, top: 8, bottom: 8)
                        }

                        if (this.targetPeerName.size > 0) {
                            Row() {
                                Text("Target: ")
                                    .fontSize(14)
                                    .fontColor(0xFF8E8E93)
                                Text(this.targetPeerName)
                                    .fontSize(14)
                                    .fontColor(0xFF1C1C1E)
                                    .fontWeight(FontWeight.Medium)
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 4, bottom: 8)
                        }

                        if (this.showError) {
                            Text(this.errorMessage)
                                .fontSize(13)
                                .fontColor(0xFFFF3B30)
                                .padding(left: 16, right: 16, top: 4, bottom: 8)
                                .width(100.percent)
                        }

                        Button("Select Import File")
                            .width(100.percent)
                            .height(44)
                            .fontSize(16)
                            .fontColor(0xFF007AFF)
                            .backgroundColor(0xFFF2F2F7)
                            .borderRadius(12)
                            .margin(left: 16, right: 16, top: 8, bottom: 4)
                            .onClick({ _ =>
                                let _ = spawn { this.selectImportFile() }
                            })

                        Button("Start Import")
                            .width(100.percent)
                            .height(44)
                            .fontSize(16)
                            .fontColor(0xFFFFFFFF)
                            .backgroundColor(if (this.selectedFilePath.size > 0) { 0xFF007AFF } else { 0xFF8E8E93 })
                            .borderRadius(12)
                            .margin(left: 16, right: 16, top: 4, bottom: 16)
                            .enabled(this.selectedFilePath.size > 0)
                            .onClick({ _ => this.startImport() })
                    }.width(100.percent)
                }
            }
            .width(100.percent)
            .layoutWeight(1)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFFFF)
        .onAppear({ => this.ensureLoaded() })
    }
}
