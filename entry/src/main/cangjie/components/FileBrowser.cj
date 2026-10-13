package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import ohos.business_exception.BusinessException
import std.collection.ArrayList
import ohos_app_cangjie_entry.utils.mimeTypeForExtension

/**
 * FileBrowser — 文件选择器组件（Phase H5.2）
 * 
 * 扫描应用沙箱目录中的文件，以列表形式展示，供用户选择发送。
 */

/**
 * 文件条目
 */
public class FileEntry {
    public var name: String = ""
    public var path: String = ""       // 完整路径
    public var size: Int64 = 0
    public var mimeType: String = ""
    
    public init() {}
    
    public init(name!: String, path!: String, size!: Int64, mimeType!: String) {
        this.name = name
        this.path = path
        this.size = size
        this.mimeType = mimeType
    }
}

/**
 * ForEach 需要 ToString 的包装
 */
public class FileEntryWrapper {
    public var entry: FileEntry = FileEntry()
    public var idx: Int64 = 0
    
    public init() {}
    
    public init(entry!: FileEntry, idx!: Int64) {
        this.entry = entry
        this.idx = idx
    }
    
    public func toString(): String {
        return "file_${this.idx}_${this.entry.name}"
    }
}

@Component
public class FileBrowser {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 应用文件目录
    public var filesDir: String = ""
    // 文件选择回调 (path, name, mimeType)
    public var onSelect: (String, String, String) -> Unit = { _p: String, _n: String, _m: String => }
    // 关闭回调
    public var onClose: () -> Unit = { => }
    
    // 文件列表
    @State var files: ArrayList<FileEntryWrapper> = ArrayList<FileEntryWrapper>()
    @State var isLoading: Bool = true
    
    protected override func aboutToAppear(): Unit {
        this.scanFiles()
    }
    
    /**
     * 扫描多个目录查找文件
     */
    private func scanFiles(): Unit {
        this.isLoading = true
        let result = ArrayList<FileEntryWrapper>()
        var idx: Int64 = 0
        
        // 扫描 documents/ 目录
        idx = this.scanDir(this.filesDir + "/documents", result, idx)
        // 扫描 videos/ 目录
        idx = this.scanDir(this.filesDir + "/videos", result, idx)
        // 扫描根文件目录
        idx = this.scanDir(this.filesDir, result, idx)
        
        this.files = result
        this.isLoading = false
        Hilog.info(0, "CjTelegram", "[FileBrowser] Found ${result.size} files")
    }
    
    /**
     * 扫描单个目录
     */
    private func scanDir(dirPath: String, result: ArrayList<FileEntryWrapper>, startIdx: Int64): Int64 {
        var idx = startIdx
        try {
            let dirExists = FileIo.access(dirPath)
            if (!dirExists) { return idx }
            
            let entries = FileIo.listFile(dirPath)
            for (entry in entries) {
                // 跳过隐藏文件和目录标志
                if (entry.startsWith(".")) { continue }
                
                let fullPath = dirPath + "/" + entry
                try {
                    let stat = FileIo.stat(fullPath)
                    // 只选择普通文件（大小 > 0）
                    if (stat.size > 0) {
                        let mime = mimeTypeForExtension(entry)
                        let fe = FileEntry(name: entry, path: fullPath, size: stat.size, mimeType: mime)
                        result.add(FileEntryWrapper(entry: fe, idx: idx))
                        idx += 1
                    }
                } catch (_e: Exception) {}
            }
        } catch (_e: Exception) {}
        return idx
    }
    
    /**
     * 获取文件类型图标
     */
    private func getFileIcon(mime: String): String {
        if (mime.contains("pdf")) { return "📕" }
        if (mime.contains("image")) { return "🖼" }
        if (mime.contains("video")) { return "🎬" }
        if (mime.contains("audio")) { return "🎵" }
        if (mime.contains("text")) { return "📝" }
        if (mime.contains("zip") || mime.contains("rar") || mime.contains("7z")) { return "📦" }
        if (mime.contains("word") || mime.contains("doc")) { return "📘" }
        if (mime.contains("sheet") || mime.contains("xls")) { return "📗" }
        return "📄"
    }
    
    /**
     * 格式化文件大小
     */
    private func formatSize(bytes: Int64): String {
        if (bytes < 1024) { return "${bytes} B" }
        if (bytes < 1048576) { return "${bytes / 1024} KB" }
        if (bytes < 1073741824) {
            let mb = Float64(bytes) / 1048576.0
            let mbInt = Int64(mb * 10.0) 
            return "${mbInt / 10}.${mbInt % 10} MB"
        }
        let gb = Float64(bytes) / 1073741824.0
        let gbInt = Int64(gb * 10.0)
        return "${gbInt / 10}.${gbInt % 10} GB"
    }
    
    public func build() {
        Column {
            // 标题栏
            Row {
                Text("Select File")
                    .fontSize(18)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0x000000)
                    .layoutWeight(1)
                
                Text("✕")
                    .fontSize(20)
                    .fontColor(0x999999)
                    .width(40)
                    .height(40)
                    .textAlign(TextAlign.Center)
                    .onClick({ evt =>
                        this.onClose()
                    })
            }
            .width(100.percent)
            .padding(left: 16, right: 8, top: 12, bottom: 8)
            
            Divider().color(0xF0F0F0)
            
            // 文件列表
            if (this.isLoading) {
                Column {
                    LoadingProgress()
                        .width(40)
                        .height(40)
                    Text("Scanning files...")
                        .fontSize(14)
                        .fontColor(0x999999)
                        .margin(top: 12)
                }
                .width(100.percent)
                .height(200)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else if (this.files.size == 0) {
                Column {
                    Text("📂")
                        .fontSize(48)
                    Text("No files found")
                        .fontSize(14)
                        .fontColor(0x999999)
                        .margin(top: 8)
                    Text("Downloaded files will appear here")
                        .fontSize(12)
                        .fontColor(0xCCCCCC)
                        .margin(top: 4)
                }
                .width(100.percent)
                .height(200)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                Scroll {
                    Column {
                        ForEach(this.files, itemGenerator: { wrapper: FileEntryWrapper, _idx: Int64 =>
                            Row {
                                // 文件图标
                                Text(this.getFileIcon(wrapper.entry.mimeType))
                                    .fontSize(28)
                                    .width(44)
                                    .height(44)
                                    .textAlign(TextAlign.Center)
                                
                                // 文件信息
                                Column {
                                    Text(wrapper.entry.name)
                                        .fontSize(14)
                                        .fontColor(0x000000)
                                        .maxLines(1)
                                    Text(this.formatSize(wrapper.entry.size))
                                        .fontSize(11)
                                        .fontColor(0x999999)
                                        .margin(top: 2)
                                }
                                .alignItems(HorizontalAlign.Start)
                                .layoutWeight(1)
                                .margin(left: 8)
                                
                                // 发送按钮
                                Text(trSource("Send"))
                                    .fontSize(13)
                                    .fontColor(0xFFFFFF)
                                    .backgroundColor(0x317AFF)
                                    .padding(left: 12, right: 12, top: 6, bottom: 6)
                                    .borderRadius(14)
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 10, bottom: 10)
                            .onClick({ evt =>
                                this.onSelect(wrapper.entry.path, wrapper.entry.name, wrapper.entry.mimeType)
                            })
                            
                            Divider().color(0xF5F5F5).margin(left: 60)
                        })
                    }
                }
                .width(100.percent)
                .layoutWeight(1)
            }
        }
        .width(100.percent)
        .height(65.percent)
        .backgroundColor(0xFFFFFF)
        .borderRadius(16)
        .position(x: 0, y: 35.percent)
    }
}
