package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.getAppFilesDir
import ohos.resource.__GenerateResource__
import ohos.resource.AppResource

/**
 * PhotoPicker — 图片选择器组件（Phase H1.5）
 * 
 * 对应 TelegramHarmony PhotoPicker.ets (151 行)
 * 对应 Telegram-iOS MediaPickerScreen (系统 PhotoViewPicker)
 * 
 * 功能:
 * - 扫描 app 内部 photos/ 和 saved_photos/ 目录
 * - 显示图片网格（3 列）
 * - 支持多选（最多 9 张）
 * - 选中后回调到 ChatRoomPage
 * - iOS 风格底部弹出面板
 */

/**
 * 选中的照片信息
 */
public class SelectedPhoto {
    public var uri: String = ""        // 文件路径 (file://...)
    public var fileName: String = ""   // 文件名
    public var fileSize: Int64 = 0     // 文件大小（字节）
    
    public init() {}
    
    public init(uri!: String, fileName!: String, fileSize!: Int64) {
        this.uri = uri
        this.fileName = fileName
        this.fileSize = fileSize
    }
}

@Component
public class PhotoPicker {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 最大选择数量
    public var maxSelect: Int64 = 9
    // 选择完成回调
    public var onSelect: (ArrayList<SelectedPhoto>) -> Unit = { _photos: ArrayList<SelectedPhoto> => }
    // 关闭回调
    public var onClose: () -> Unit = { => }
    
    // 可用照片列表
    @State var availablePhotos: ArrayList<String> = ArrayList<String>()
    // 已选中的索引
    @State var selectedIndices: ArrayList<Int64> = ArrayList<Int64>()
    // 加载状态
    @State var isLoading: Bool = true
    
    protected override func aboutToAppear(): Unit {
        this.scanPhotos()
    }
    
    /**
     * 扫描照片目录
     */
    private func scanPhotos() {
        spawn {
            let photos = ArrayList<String>()
            let filesDir = getAppFilesDir()
            if (filesDir.size > 0) {
                let photoDir = filesDir + "/photos"
                this.scanDirectory(photoDir, photos)
                let savedDir = filesDir + "/saved_photos"
                this.scanDirectory(savedDir, photos)
            }
            launch {
                this.availablePhotos = photos
                this.isLoading = false
            }
            Hilog.info(0, "CjTelegram", "[PhotoPicker] Found ${photos.size} photos")
        }
    }
    
    /**
     * 扫描指定目录中的图片文件
     */
    private func scanDirectory(dirPath: String, results: ArrayList<String>) {
        try {
            let exists = FileIo.access(dirPath)
            if (!exists) { return }
            
            let entries = FileIo.listFile(dirPath)
            for (entry in entries) {
                let lower = entry.toAsciiLower()
                if (lower.endsWith(".jpg") || lower.endsWith(".jpeg") || lower.endsWith(".png") || lower.endsWith(".webp")) {
                    let filePath = dirPath + "/" + entry
                    results.add("file://" + filePath)
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PhotoPicker] Scan error: ${e}")
        }
    }
    
    /**
     * 切换照片选中状态
     */
    private func toggleSelection(index: Int64) {
        // 检查是否已选中
        var foundAt: Int64 = -1
        for (i in 0..this.selectedIndices.size) {
            if (this.selectedIndices[i] == index) {
                foundAt = i
                break
            }
        }
        
        let newSelection = ArrayList<Int64>()
        if (foundAt >= 0) {
            // 取消选中
            for (i in 0..this.selectedIndices.size) {
                if (i != foundAt) {
                    newSelection.add(this.selectedIndices[i])
                }
            }
        } else {
            // 选中（检查上限）
            for (idx in this.selectedIndices) { newSelection.add(idx) }
            if (newSelection.size < this.maxSelect) {
                newSelection.add(index)
            }
        }
        this.selectedIndices = newSelection
    }
    
    /**
     * 检查索引是否已选中
     */
    private func isSelected(index: Int64): Bool {
        for (idx in this.selectedIndices) {
            if (idx == index) { return true }
        }
        return false
    }
    
    /**
     * 确认选择
     */
    private func confirmSelection() {
        let results = ArrayList<SelectedPhoto>()
        for (idx in this.selectedIndices) {
            if (idx >= 0 && idx < this.availablePhotos.size) {
                let uri = this.availablePhotos[idx]
                // 从 URI 中提取文件名
                var fileName = "photo.jpg"
                let parts = uri.split("/")
                if (parts.size > 0) {
                    fileName = parts[parts.size - 1]
                }
                // 获取文件大小
                var fileSize: Int64 = 0
                try {
                    var realPath = uri
                    if (realPath.startsWith("file://")) {
                        realPath = realPath[7..]
                    }
                    let stat = FileIo.stat(realPath)
                    fileSize = stat.size
                } catch (_e: Exception) {}
                
                results.add(SelectedPhoto(uri: uri, fileName: fileName, fileSize: fileSize))
            }
        }
        Hilog.info(0, "CjTelegram", "[PhotoPicker] Selected ${results.size} photos")
        this.onSelect(results)
    }
    
    public func build() {
        Column {
            // 拖动条
            Row {
                Column {}
                    .width(36)
                    .height(4)
                    .backgroundColor(0xD1D1D6)
                    .borderRadius(2)
            }
            .width(100.percent)
            .justifyContent(FlexAlign.Center)
            .padding(top: 8, bottom: 8)
            
            // 标题栏
            Row {
                Text(trSource("Photos"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
                
                Blank()
                
                if (!this.selectedIndices.isEmpty()) {
                    Text("Send (${this.selectedIndices.size})")
                        .fontSize(16)
                        .fontColor(0x0088CC)
                        .fontWeight(FontWeight.Medium)
                        .onClick({ evt =>
                            this.confirmSelection()
                        })
                }
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 4, bottom: 12)
            
            // 照片网格
            if (this.isLoading) {
                Column {
                    Text("Loading photos...")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                }
                .width(100.percent)
                .height(200)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else if (this.availablePhotos.isEmpty()) {
                Column {
                    Text("📷")
                        .fontSize(48)
                    Text("No photos found")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 8)
                    Text("Photos will appear here after\ndownloading in chat")
                        .fontSize(12)
                        .fontColor(0xC7C7CC)
                        .margin(top: 4)
                        .textAlign(TextAlign.Center)
                }
                .width(100.percent)
                .height(200)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                // 照片网格（3列 Grid）
                Scroll {
                    Flex(wrap: FlexWrap.Wrap) {
                        ForEach(this.availablePhotos.toArray(), itemGenerator: { photoUri: String, index: Int64 =>
                            Stack {
                                Image(photoUri)
                                    .width(100.percent)
                                    .height(100.percent)
                                    .objectFit(ImageFit.Cover)
                                    .borderRadius(4)
                                
                                // 选中指示器（资源保真修复：Media Gallery/Check.imageset/checkattach_30.pdf 转 SVG）
                                if (this.isSelected(index)) {
                                    Column {
                                        Image(@r(app.media.media_ic_check))
                                            .width(14)
                                            .height(14)
                                            .fillColor(0xFFFFFF)
                                    }
                                    .width(24)
                                    .height(24)
                                    .backgroundColor(0x0088CC)
                                    .borderRadius(12)
                                    .justifyContent(FlexAlign.Center)
                                    .alignItems(HorizontalAlign.Center)
                                    .position(x: 75.percent, y: 4)
                                } else {
                                    Column {}
                                        .width(24)
                                        .height(24)
                                        .backgroundColor(Color.Transparent)
                                        .borderRadius(12)
                                        .borderWidth(2)
                                        .borderColor(0xFFFFFF)
                                        .position(x: 75.percent, y: 4)
                                }
                            }
                            .width(31.percent)
                            .height(110)
                            .margin(left: 1.percent, bottom: 4)
                            .clip(true)
                            .onClick({ evt =>
                                this.toggleSelection(index)
                            })
                        })
                    }
                    .width(100.percent)
                }
                .width(100.percent)
                .constraintSize(maxHeight: 340)
            }
            
            // 取消按钮
            Button(trSource("Cancel"))
                .width(90.percent)
                .height(50)
                .fontSize(17)
                .fontColor(0x0088CC)
                .backgroundColor(0xF2F2F7)
                .borderRadius(12)
                .margin(top: 12, bottom: 16)
                .onClick({ evt =>
                    this.onClose()
                })
        }
        .width(100.percent)
        .backgroundColor(0xFFFFFF)
        .borderRadius(topLeft: 16, topRight: 16)
    }
}

// getAppFilesDir 已在 services 包中定义，通过 import 使用
