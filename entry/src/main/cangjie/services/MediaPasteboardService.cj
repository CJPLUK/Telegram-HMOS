package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.utils.mimeTypeForExtension

// MediaPasteboardService - 媒体粘贴板服务（media_pasteboard / MPAST-API-1）
//
// iOS 对应：
//   submodules/MediaPasteboardUI/Sources/MediaPasteboardScreen.swift
//   mediaPasteboardScreen 工厂函数，封装剪贴板内已有图像/视频的预览 AttachmentController
//
// 本 feature 为 local_state，tl_methods=[]：
//   读取鸿蒙系统剪贴板（systemPasteboard）中的媒体数据，无 MTProto 依赖。
//
// 调用链（完整）：
//   MediaPasteboardUIComponent.aboutToAppear()
//     -> launch { MediaPasteboardService.readPasteboardItems() }
//       -> PasteboardBridge.getInstance().readMediaItems()
//         -> dlopen("libpasteboard.so") -> OH_Pasteboard_Create/HasData/GetData
//           -> dlopen("libudmf.so") -> OH_UdmfData_GetRecords -> OH_UdmfRecord_GetTypes
//             -> OH_UdmfRecord_GetFileUri -> OH_UdsFileUri_GetFileUri -> URI String
//               -> ArrayList<PasteboardItem>
//   MediaPasteboardUIComponent 状态刷新 -> ForEach 渲染预览网格
//   onConfirm(items) -> 调用方收到选中条目列表

// ─────────────────────────────────────────────────────────────────
// libc dlclose（dlopen/dlsym 已在同包 AudioCaptureService.cj 声明）
// ─────────────────────────────────────────────────────────────────

foreign func dlclose(handle: CPointer<Unit>): Int32

let RTLD_NOW_PASTEBOARD: Int32 = 2

// 从 CPointer<UInt8> 读取 null-terminated C 字符串（最大 4096 字节）
unsafe func pbCPtrToString(cstr: CPointer<UInt8>): String {
    if (cstr.isNull()) { return "" }
    var len: Int64 = 0
    while ((cstr + len).read() != 0) {
        len = len + 1
        if (len > 4096) { break }
    }
    if (len == 0) { return "" }
    let bytes = Array<Byte>(len, repeat: 0)
    var i: Int64 = 0
    while (i < len) {
        bytes[i] = (cstr + i).read()
        i = i + 1
    }
    return String.fromUtf8(bytes)
}

// ─────────────────────────────────────────────────────────────────
// 数据模型
// ─────────────────────────────────────────────────────────────────

// 粘贴板媒体条目
// 对应 iOS MediaPickerScreenImpl.Subject.Media 里的单个剪贴板媒体项
public class PasteboardItem {
    // 媒体 URI（file:// 路径 或 content:// URI）
    public var uri: String = ""
    // MIME 类型，例如 "image/jpeg"、"image/png"、"video/mp4"
    public var mimeType: String = ""
    // 显示名称（文件名）
    public var displayName: String = ""
    // 媒体类型字符串："image" | "video" | "unknown"
    public var mediaKind: String = "unknown"

    public init() {}
}

// ForEach 用唯一键包装
public class PasteboardItemWrapper {
    public var item: PasteboardItem = PasteboardItem()
    public var idx: Int64 = 0

    public init() {}

    public func toString(): String {
        return "paste_" + this.idx.toString() + "_" + this.item.uri
    }
}

// ─────────────────────────────────────────────────────────────────
// 服务单例
// ─────────────────────────────────────────────────────────────────

private var _mediaPasteboardServiceInstance: Option<MediaPasteboardService> = None

// 获取 MediaPasteboardService 单例
public func getMediaPasteboardService(): MediaPasteboardService {
    match (_mediaPasteboardServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = MediaPasteboardService()
            _mediaPasteboardServiceInstance = Some(inst)
            return inst
    }
}

// ─────────────────────────────────────────────────────────────────
// MediaPasteboardService
// ─────────────────────────────────────────────────────────────────

// MediaPasteboardService - 媒体粘贴板服务
//
// 封装鸿蒙 PasteboardKit 能力，读取系统剪贴板中的媒体条目（图片/视频 URI）。
// 无 MTProto 依赖（local_state）。
//
// 实现：通过 dlopen/dlsym 调用 libpasteboard.so + libudmf.so native C API
// 参考 syntax_error.md #68 的 dlopen/dlsym 模式和 core/voip/TgCallsBridge.cj 中的用法
//
// 关键 C API（来自 oh_pasteboard.h + udmf.h）：
//   OH_Pasteboard_Create() -> OH_Pasteboard*
//   OH_Pasteboard_HasData(pb) -> bool
//   OH_Pasteboard_GetData(pb, status*) -> OH_UdmfData*
//   OH_Pasteboard_Destroy(pb)
//   OH_UdmfData_GetRecords(data, count*) -> OH_UdmfRecord**
//   OH_UdmfRecord_GetTypes(record, count*) -> char**
//   OH_UdsFileUri_Create() -> OH_UdsFileUri*
//   OH_UdmfRecord_GetFileUri(record, fileUri*) -> int
//   OH_UdsFileUri_GetFileUri(fileUri) -> const char*
//   OH_UdsFileUri_GetFileType(fileUri) -> const char*
//   OH_UdsFileUri_Destroy(fileUri)
//   OH_UdmfData_Destroy(data)
public class MediaPasteboardService {

    public init() {}

    // 读取系统剪贴板中的媒体条目
    //
    // 通过 dlopen libpasteboard.so 调用真实系统剪贴板 API，读取 UDMF 记录，
    // 提取 general.file-uri / general.image / general.video 类型的条目。
    //
    // 应在后台线程（spawn/launch）中调用，避免阻塞主线程。
    // @return 媒体条目列表；剪贴板为空或无媒体时返回空列表
    public func readPasteboardItems(): ArrayList<PasteboardItem> {
        let result = ArrayList<PasteboardItem>()
        try {
            let bridge = PasteboardBridge.getInstance()
            if (!bridge.hasData()) {
                Hilog.info(0, "CjTelegram", "[MediaPasteboardService] no pasteboard data")
                return result
            }
            let items = bridge.readMediaItems()
            for (item in items) {
                result.add(item)
            }
            Hilog.info(0, "CjTelegram", "[MediaPasteboardService] found " + result.size.toString() + " media items")
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[MediaPasteboardService] readPasteboardItems error")
        }
        return result
    }

    // 检查剪贴板是否含有媒体数据
    // @return true - 剪贴板有内容（可能含媒体）
    public func hasPasteboardData(): Bool {
        try {
            let bridge = PasteboardBridge.getInstance()
            return bridge.hasData()
        } catch (_: Exception) {
            return false
        }
    }
}

// ─────────────────────────────────────────────────────────────────
// PasteboardBridge - native C API 桥接层（dlopen/dlsym 模式）
// ─────────────────────────────────────────────────────────────────
//
// 按照 syntax_error.md #68 的 dlopen/dlsym 模式实现（参照 TgCallsBridge.cj 写法）。
// 运行时通过 dlopen("libpasteboard.so") + dlopen("libudmf.so") 加载系统库，
// 通过 dlsym 获取函数指针并调用。
//
// libpasteboard.so 系统库路径：/system/lib64/libpasteboard.so
// libudmf.so 系统库路径：/system/lib64/libudmf.so
// （HarmonyOS NEXT 上以动态库形式预装在系统分区，dlopen 直接按名称加载）

private var _pasteboardBridgeInstance: Option<PasteboardBridge> = None

class PasteboardBridge {
    // Library handles
    private var _pbHandle: CPointer<Unit> = CPointer<Unit>()
    private var _udmfHandle: CPointer<Unit> = CPointer<Unit>()
    private var _loaded: Bool = false

    // Function pointers - libpasteboard.so
    // OH_Pasteboard* OH_Pasteboard_Create()
    private var _fnCreate: CFunc<() -> CPointer<Unit>> =
        CFunc<() -> CPointer<Unit>>(CPointer<Unit>())
    // void OH_Pasteboard_Destroy(OH_Pasteboard*)
    private var _fnDestroy: CFunc<(CPointer<Unit>) -> Unit> =
        CFunc<(CPointer<Unit>) -> Unit>(CPointer<Unit>())
    // bool OH_Pasteboard_HasData(OH_Pasteboard*)
    private var _fnHasData: CFunc<(CPointer<Unit>) -> Bool> =
        CFunc<(CPointer<Unit>) -> Bool>(CPointer<Unit>())
    // OH_UdmfData* OH_Pasteboard_GetData(OH_Pasteboard*, int* status)
    // status param declared as CPointer<UInt8>; caller passes null (CPointer<UInt8>()) to skip
    private var _fnGetData: CFunc<(CPointer<Unit>, CPointer<UInt8>) -> CPointer<Unit>> =
        CFunc<(CPointer<Unit>, CPointer<UInt8>) -> CPointer<Unit>>(CPointer<Unit>())
    private var _hasCreate: Bool = false
    private var _hasDestroy: Bool = false
    private var _hasHasData: Bool = false
    private var _hasGetData: Bool = false

    // Function pointers - libudmf.so
    // void OH_UdmfData_Destroy(OH_UdmfData*)
    private var _fnUdmfDataDestroy: CFunc<(CPointer<Unit>) -> Unit> =
        CFunc<(CPointer<Unit>) -> Unit>(CPointer<Unit>())
    // OH_UdmfRecord** OH_UdmfData_GetRecords(OH_UdmfData*, unsigned int* count)
    // count param as CPointer<UInt8>; caller reads via Array<Byte>(4) + acquireArrayRawData
    private var _fnUdmfDataGetRecords: CFunc<(CPointer<Unit>, CPointer<UInt8>) -> CPointer<Unit>> =
        CFunc<(CPointer<Unit>, CPointer<UInt8>) -> CPointer<Unit>>(CPointer<Unit>())
    // char** OH_UdmfRecord_GetTypes(OH_UdmfRecord*, unsigned int* count)
    private var _fnUdmfRecordGetTypes: CFunc<(CPointer<Unit>, CPointer<UInt8>) -> CPointer<Unit>> =
        CFunc<(CPointer<Unit>, CPointer<UInt8>) -> CPointer<Unit>>(CPointer<Unit>())
    // OH_UdsFileUri* OH_UdsFileUri_Create()
    private var _fnUdsFileUriCreate: CFunc<() -> CPointer<Unit>> =
        CFunc<() -> CPointer<Unit>>(CPointer<Unit>())
    // void OH_UdsFileUri_Destroy(OH_UdsFileUri*)
    private var _fnUdsFileUriDestroy: CFunc<(CPointer<Unit>) -> Unit> =
        CFunc<(CPointer<Unit>) -> Unit>(CPointer<Unit>())
    // int OH_UdmfRecord_GetFileUri(OH_UdmfRecord*, OH_UdsFileUri*)
    private var _fnUdmfRecordGetFileUri: CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(CPointer<Unit>())
    // const char* OH_UdsFileUri_GetFileUri(OH_UdsFileUri*)
    private var _fnUdsFileUriGetUri: CFunc<(CPointer<Unit>) -> CPointer<UInt8>> =
        CFunc<(CPointer<Unit>) -> CPointer<UInt8>>(CPointer<Unit>())
    // const char* OH_UdsFileUri_GetFileType(OH_UdsFileUri*)
    private var _fnUdsFileUriGetFileType: CFunc<(CPointer<Unit>) -> CPointer<UInt8>> =
        CFunc<(CPointer<Unit>) -> CPointer<UInt8>>(CPointer<Unit>())
    private var _hasUdmf: Bool = false

    public init() {}

    static func getInstance(): PasteboardBridge {
        match (_pasteboardBridgeInstance) {
            case Some(b) => return b
            case None =>
                let b = PasteboardBridge()
                b.load()
                _pasteboardBridgeInstance = Some(b)
                return b
        }
    }

    private func loadSym(handle: CPointer<Unit>, name: String): CPointer<Unit> {
        let cName = unsafe { LibC.mallocCString(name) }
        let sym = unsafe { dlsym(handle, cName) }
        unsafe { LibC.free(cName) }
        if (sym.isNull()) {
            Hilog.info(0, "CjTelegram", "[PasteboardBridge] dlsym failed: " + name)
        }
        return sym
    }

    private func load(): Unit {
        // Load libpasteboard.so
        let cPbPath = unsafe { LibC.mallocCString("libpasteboard.so") }
        let pbH = unsafe { dlopen(cPbPath, RTLD_NOW_PASTEBOARD) }
        unsafe { LibC.free(cPbPath) }

        if (pbH.isNull()) {
            Hilog.info(0, "CjTelegram", "[PasteboardBridge] dlopen libpasteboard.so failed")
            return
        }
        this._pbHandle = pbH

        let symCreate = loadSym(pbH, "OH_Pasteboard_Create")
        if (!symCreate.isNull()) {
            this._fnCreate = CFunc<() -> CPointer<Unit>>(symCreate)
            this._hasCreate = true
        }

        let symDestroy = loadSym(pbH, "OH_Pasteboard_Destroy")
        if (!symDestroy.isNull()) {
            this._fnDestroy = CFunc<(CPointer<Unit>) -> Unit>(symDestroy)
            this._hasDestroy = true
        }

        let symHasData = loadSym(pbH, "OH_Pasteboard_HasData")
        if (!symHasData.isNull()) {
            this._fnHasData = CFunc<(CPointer<Unit>) -> Bool>(symHasData)
            this._hasHasData = true
        }

        let symGetData = loadSym(pbH, "OH_Pasteboard_GetData")
        if (!symGetData.isNull()) {
            this._fnGetData = CFunc<(CPointer<Unit>, CPointer<UInt8>) -> CPointer<Unit>>(symGetData)
            this._hasGetData = true
        }

        // Load libudmf.so
        let cUdmfPath = unsafe { LibC.mallocCString("libudmf.so") }
        let udmfH = unsafe { dlopen(cUdmfPath, RTLD_NOW_PASTEBOARD) }
        unsafe { LibC.free(cUdmfPath) }

        if (udmfH.isNull()) {
            Hilog.info(0, "CjTelegram", "[PasteboardBridge] dlopen libudmf.so failed")
            this._loaded = this._hasCreate && this._hasHasData && this._hasGetData
            return
        }
        this._udmfHandle = udmfH

        let sUdmfDestroy = loadSym(udmfH, "OH_UdmfData_Destroy")
        if (!sUdmfDestroy.isNull()) {
            this._fnUdmfDataDestroy = CFunc<(CPointer<Unit>) -> Unit>(sUdmfDestroy)
        }

        let sGetRecords = loadSym(udmfH, "OH_UdmfData_GetRecords")
        if (!sGetRecords.isNull()) {
            this._fnUdmfDataGetRecords = CFunc<(CPointer<Unit>, CPointer<UInt8>) -> CPointer<Unit>>(sGetRecords)
        }

        let sGetTypes = loadSym(udmfH, "OH_UdmfRecord_GetTypes")
        if (!sGetTypes.isNull()) {
            this._fnUdmfRecordGetTypes = CFunc<(CPointer<Unit>, CPointer<UInt8>) -> CPointer<Unit>>(sGetTypes)
        }

        let sUriCreate = loadSym(udmfH, "OH_UdsFileUri_Create")
        if (!sUriCreate.isNull()) {
            this._fnUdsFileUriCreate = CFunc<() -> CPointer<Unit>>(sUriCreate)
        }

        let sUriDestroy = loadSym(udmfH, "OH_UdsFileUri_Destroy")
        if (!sUriDestroy.isNull()) {
            this._fnUdsFileUriDestroy = CFunc<(CPointer<Unit>) -> Unit>(sUriDestroy)
        }

        let sGetFileUri = loadSym(udmfH, "OH_UdmfRecord_GetFileUri")
        if (!sGetFileUri.isNull()) {
            this._fnUdmfRecordGetFileUri = CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(sGetFileUri)
        }

        let sGetUri = loadSym(udmfH, "OH_UdsFileUri_GetFileUri")
        if (!sGetUri.isNull()) {
            this._fnUdsFileUriGetUri = CFunc<(CPointer<Unit>) -> CPointer<UInt8>>(sGetUri)
        }

        let sGetFT = loadSym(udmfH, "OH_UdsFileUri_GetFileType")
        if (!sGetFT.isNull()) {
            this._fnUdsFileUriGetFileType = CFunc<(CPointer<Unit>) -> CPointer<UInt8>>(sGetFT)
        }

        this._hasUdmf = true
        this._loaded = this._hasCreate && this._hasHasData && this._hasGetData && this._hasUdmf
        Hilog.info(0, "CjTelegram", "[PasteboardBridge] loaded=" + this._loaded.toString())
    }

    // 检查剪贴板是否有数据
    func hasData(): Bool {
        if (!this._loaded || !this._hasCreate || !this._hasHasData) {
            return false
        }
        let pb = unsafe { this._fnCreate() }
        if (pb.isNull()) {
            return false
        }
        let has = unsafe { this._fnHasData(pb) }
        if (this._hasDestroy) {
            unsafe { this._fnDestroy(pb) }
        }
        return has
    }

    // 读取剪贴板中的媒体条目（general.file-uri / general.image / general.video 类型）
    // 通过 libpasteboard.so + libudmf.so native C API 实现真实读取
    func readMediaItems(): ArrayList<PasteboardItem> {
        let result = ArrayList<PasteboardItem>()
        if (!this._loaded) {
            Hilog.info(0, "CjTelegram", "[PasteboardBridge] not loaded, returning empty")
            return result
        }

        let pb = unsafe { this._fnCreate() }
        if (pb.isNull()) {
            return result
        }

        // 传入 null status 指针（不需要具体错误码，检查返回值是否为 null 即可）
        let udmfData = unsafe { this._fnGetData(pb, CPointer<UInt8>()) }

        if (this._hasDestroy) {
            unsafe { this._fnDestroy(pb) }
        }

        if (udmfData.isNull()) {
            Hilog.info(0, "CjTelegram", "[PasteboardBridge] GetData returned null")
            return result
        }

        // 获取 UDMF 记录数组
        // Array<Byte>(4) 用作 unsigned int* 输出缓冲（小端序 UInt32 = 4 bytes）
        let countBuf = Array<Byte>(4, repeat: 0)
        let countHandle = unsafe { acquireArrayRawData(countBuf) }
        let recordsRaw = unsafe { this._fnUdmfDataGetRecords(udmfData, countHandle.pointer) }
        unsafe { releaseArrayRawData(countHandle) }
        if (recordsRaw.isNull()) {
            unsafe { this._fnUdmfDataDestroy(udmfData) }
            return result
        }
        // 从小端字节读取 UInt32 记录数
        let recordCount: Int64 = Int64(countBuf[0]) | (Int64(countBuf[1]) << 8) |
            (Int64(countBuf[2]) << 16) | (Int64(countBuf[3]) << 24)

        Hilog.info(0, "CjTelegram", "[PasteboardBridge] records=" + recordCount.toString())

        // recordsRaw: CPointer<Unit> 实际指向 OH_UdmfRecord**（指针数组）
        // 每个元素为 8 字节指针（aarch64）；通过 CPointer<UInt8> 做字节步进再强转读取
        let recordsBase = CPointer<UInt8>(recordsRaw)
        var i: Int64 = 0
        while (i < recordCount) {
            // 步进 i * 8 字节，将该位置解释为 CPointer<CPointer<Unit>> 并读取
            let recordPtrVal: CPointer<Unit> = unsafe {
                CPointer<CPointer<Unit>>(recordsBase + i * 8).read()
            }

            if (recordPtrVal.isNull()) {
                i += 1
                continue
            }

            // 获取此记录的类型列表
            let tcBuf = Array<Byte>(4, repeat: 0)
            let tcHandle = unsafe { acquireArrayRawData(tcBuf) }
            let typesRaw = unsafe { this._fnUdmfRecordGetTypes(recordPtrVal, tcHandle.pointer) }
            unsafe { releaseArrayRawData(tcHandle) }
            if (typesRaw.isNull()) {
                i += 1
                continue
            }
            let typeCount: Int64 = Int64(tcBuf[0]) | (Int64(tcBuf[1]) << 8) |
                (Int64(tcBuf[2]) << 16) | (Int64(tcBuf[3]) << 24)

            // typesRaw: CPointer<Unit> 实际指向 char**（字符串指针数组）
            // 每个元素为 8 字节指针，步进同上
            let typesBase = CPointer<UInt8>(typesRaw)
            var isMedia = false
            var recordKind = "image"
            var j: Int64 = 0
            while (j < typeCount) {
                let typeStrPtr: CPointer<UInt8> = unsafe {
                    CPointer<CPointer<UInt8>>(typesBase + j * 8).read()
                }
                let typeStr = unsafe { pbCPtrToString(typeStrPtr) }
                if (typeStr == "general.file-uri" || typeStr == "general.image" || typeStr == "general.video") {
                    isMedia = true
                }
                if (typeStr == "general.video") {
                    recordKind = "video"
                }
                j += 1
            }

            if (isMedia) {
                // 尝试获取 file URI
                let fileUriObj = unsafe { this._fnUdsFileUriCreate() }
                if (!fileUriObj.isNull()) {
                    let rc = unsafe { this._fnUdmfRecordGetFileUri(recordPtrVal, fileUriObj) }
                    if (rc == 0) {
                        let uriPtr = unsafe { this._fnUdsFileUriGetUri(fileUriObj) }
                        let fileTypePtr = unsafe { this._fnUdsFileUriGetFileType(fileUriObj) }
                        let uriStr = unsafe { pbCPtrToString(uriPtr) }
                        let fileTypeStr = unsafe { pbCPtrToString(fileTypePtr) }
                        if (uriStr.size > 0) {
                            let item = PasteboardItem()
                            item.uri = uriStr
                            // 根据 fileType 或 recordKind 判断媒体类型
                            let ftLower = fileTypeStr.toAsciiLower()
                            if (recordKind == "video" || ftLower.contains("video")) {
                                item.mediaKind = "video"
                                item.mimeType = "video/mp4"
                            } else {
                                item.mediaKind = "image"
                                item.mimeType = "image/jpeg"
                            }
                            // 从 URI 路径推断扩展名和 MIME 类型
                            let uriLower = uriStr.toAsciiLower()
                            if (uriLower.contains(".png")) {
                                item.mimeType = "image/png"
                                item.mediaKind = "image"
                                item.displayName = "image_" + i.toString() + ".png"
                            } else if (uriLower.contains(".jpg") || uriLower.contains(".jpeg")) {
                                item.mimeType = "image/jpeg"
                                item.mediaKind = "image"
                                item.displayName = "image_" + i.toString() + ".jpg"
                            } else if (uriLower.contains(".gif")) {
                                item.mimeType = "image/gif"
                                item.mediaKind = "image"
                                item.displayName = "image_" + i.toString() + ".gif"
                            } else if (uriLower.contains(".webp")) {
                                item.mimeType = mimeTypeForExtension("webp")
                                item.mediaKind = "image"
                                item.displayName = "image_" + i.toString() + ".webp"
                            } else if (uriLower.contains(".mp4")) {
                                item.mimeType = "video/mp4"
                                item.mediaKind = "video"
                                item.displayName = "video_" + i.toString() + ".mp4"
                            } else if (uriLower.contains(".mov")) {
                                item.mimeType = "video/mp4"
                                item.mediaKind = "video"
                                item.displayName = "video_" + i.toString() + ".mov"
                            } else if (item.mediaKind == "video") {
                                item.displayName = "video_" + i.toString() + ".mp4"
                            } else {
                                item.displayName = "image_" + i.toString() + ".jpg"
                            }
                            result.add(item)
                        }
                    }
                    unsafe { this._fnUdsFileUriDestroy(fileUriObj) }
                }
            }

            i += 1
        }

        // 销毁 UDMF 数据
        unsafe { this._fnUdmfDataDestroy(udmfData) }

        return result
    }
}
