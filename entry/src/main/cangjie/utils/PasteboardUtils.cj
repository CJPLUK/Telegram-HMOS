package ohos_app_cangjie_entry.utils

import kit.PerformanceAnalysisKit.Hilog

/**
 * PasteboardUtils — 统一系统剪贴板（纯文本）工具
 *
 * 对应 Telegram-iOS submodules/Pasteboard（语义）：复制/读取纯文本。
 *
 * 实现路径说明（实证依据）：
 *   cangjie-kb 多轮检索（pasteboard / BasicServicesKit / SystemPasteboard）确认：
 *   仓颉侧没有可直接调用的 ArkTS pasteboard（getSystemPasteboard / PasteData /
 *   createPlainTextData）绑定。工程现有真实剪贴板读取（services/
 *   MediaPasteboardService.cj 的 PasteboardBridge）正是通过 dlopen
 *   libpasteboard.so + libudmf.so 调系统 NDK C API 实现的。本工具沿用同一
 *   dlopen/dlsym 模式，针对「纯文本」走 UDMF PlainText 通道：
 *     写：OH_UdsPlainText_Create/SetContent → OH_UdmfRecord_Create/AddPlainText
 *         → OH_UdmfData_Create/AddRecord → OH_Pasteboard_Create/SetData
 *     读：OH_Pasteboard_GetData → OH_UdmfData_GetRecords
 *         → OH_UdmfRecord_GetPlainText → OH_UdsPlainText_GetContent
 *     存在性：OH_Pasteboard_HasData
 *     清空：OH_Pasteboard_ClearData
 *   （libpasteboard.so / libudmf.so 为 HarmonyOS NEXT 系统预装动态库，
 *    dlopen 按名加载；符号名取自 OHOS NDK oh_pasteboard.h / udmf.h。）
 *
 * 与工程现有 services.setClipboardText / getClipboardText（RealChatListService.cj
 * 内的进程内内存变量、非系统剪贴板）的关系：本工具是面向「系统剪贴板」的真实实现，
 * 不替换那两个内存桩（它们被多处页面引用，行为是进程内回显）；本单元只提供统一系统
 * 剪贴板能力供后续接入，不破坏既有调用点。
 *
 * 安全口径：所有 API 全程 try/catch + null 校验，失败返回 false / 空串，不崩。
 * 顶层符号加 pasteboard 前缀，避开 utils 包级命名冲突。
 */

// ─────────────────────────────────────────────────────────────────
// libc dl* 绑定（与同包其他 .cj 隔离：本文件独立声明，包内唯一）
// ─────────────────────────────────────────────────────────────────

foreign func dlopen(path: CString, flags: Int32): CPointer<Unit>
foreign func dlsym(handle: CPointer<Unit>, symbol: CString): CPointer<Unit>

let RTLD_NOW_PB_UTILS: Int32 = 2

// 从 CPointer<UInt8> 读取 null 结尾 C 字符串（最大 1MB 防越界），UTF-8 解码。
unsafe func pbuCPtrToString(cstr: CPointer<UInt8>): String {
    if (cstr.isNull()) {
        return ""
    }
    var len: Int64 = 0
    while ((cstr + len).read() != 0) {
        len = len + 1
        if (len > 1048576) {
            break
        }
    }
    if (len == 0) {
        return ""
    }
    let bytes = Array<Byte>(len, repeat: 0)
    var i: Int64 = 0
    while (i < len) {
        bytes[i] = (cstr + i).read()
        i = i + 1
    }
    try {
        return String.fromUtf8(bytes)
    } catch (_: Exception) {
        return ""
    }
}

// ─────────────────────────────────────────────────────────────────
// PasteboardTextBridge — native C API 桥接（dlopen/dlsym），单例
// ─────────────────────────────────────────────────────────────────

private var _pbTextBridgeInstance: Option<PasteboardTextBridge> = None

class PasteboardTextBridge {
    private var _pbHandle: CPointer<Unit> = CPointer<Unit>()
    private var _udmfHandle: CPointer<Unit> = CPointer<Unit>()
    private var _loaded: Bool = false

    // ---- libpasteboard.so ----
    // OH_Pasteboard* OH_Pasteboard_Create()
    private var _fnPbCreate: CFunc<() -> CPointer<Unit>> =
        CFunc<() -> CPointer<Unit>>(CPointer<Unit>())
    // void OH_Pasteboard_Destroy(OH_Pasteboard*)
    private var _fnPbDestroy: CFunc<(CPointer<Unit>) -> Unit> =
        CFunc<(CPointer<Unit>) -> Unit>(CPointer<Unit>())
    // bool OH_Pasteboard_HasData(OH_Pasteboard*)
    private var _fnPbHasData: CFunc<(CPointer<Unit>) -> Bool> =
        CFunc<(CPointer<Unit>) -> Bool>(CPointer<Unit>())
    // int OH_Pasteboard_SetData(OH_Pasteboard*, OH_UdmfData*)
    private var _fnPbSetData: CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(CPointer<Unit>())
    // OH_UdmfData* OH_Pasteboard_GetData(OH_Pasteboard*, int* status)
    private var _fnPbGetData: CFunc<(CPointer<Unit>, CPointer<UInt8>) -> CPointer<Unit>> =
        CFunc<(CPointer<Unit>, CPointer<UInt8>) -> CPointer<Unit>>(CPointer<Unit>())
    // int OH_Pasteboard_ClearData(OH_Pasteboard*)
    private var _fnPbClearData: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())

    // ---- libudmf.so ----
    // OH_UdmfData* OH_UdmfData_Create()
    private var _fnUdmfCreate: CFunc<() -> CPointer<Unit>> =
        CFunc<() -> CPointer<Unit>>(CPointer<Unit>())
    // void OH_UdmfData_Destroy(OH_UdmfData*)
    private var _fnUdmfDestroy: CFunc<(CPointer<Unit>) -> Unit> =
        CFunc<(CPointer<Unit>) -> Unit>(CPointer<Unit>())
    // int OH_UdmfData_AddRecord(OH_UdmfData*, OH_UdmfRecord*)
    private var _fnUdmfAddRecord: CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(CPointer<Unit>())
    // OH_UdmfRecord** OH_UdmfData_GetRecords(OH_UdmfData*, unsigned int* count)
    private var _fnUdmfGetRecords: CFunc<(CPointer<Unit>, CPointer<UInt8>) -> CPointer<Unit>> =
        CFunc<(CPointer<Unit>, CPointer<UInt8>) -> CPointer<Unit>>(CPointer<Unit>())
    // OH_UdmfRecord* OH_UdmfRecord_Create()
    private var _fnRecordCreate: CFunc<() -> CPointer<Unit>> =
        CFunc<() -> CPointer<Unit>>(CPointer<Unit>())
    // void OH_UdmfRecord_Destroy(OH_UdmfRecord*)
    private var _fnRecordDestroy: CFunc<(CPointer<Unit>) -> Unit> =
        CFunc<(CPointer<Unit>) -> Unit>(CPointer<Unit>())
    // int OH_UdmfRecord_AddPlainText(OH_UdmfRecord*, OH_UdsPlainText*)
    private var _fnRecordAddPlainText: CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(CPointer<Unit>())
    // int OH_UdmfRecord_GetPlainText(OH_UdmfRecord*, OH_UdsPlainText*)
    private var _fnRecordGetPlainText: CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(CPointer<Unit>())
    // OH_UdsPlainText* OH_UdsPlainText_Create()
    private var _fnPlainCreate: CFunc<() -> CPointer<Unit>> =
        CFunc<() -> CPointer<Unit>>(CPointer<Unit>())
    // void OH_UdsPlainText_Destroy(OH_UdsPlainText*)
    private var _fnPlainDestroy: CFunc<(CPointer<Unit>) -> Unit> =
        CFunc<(CPointer<Unit>) -> Unit>(CPointer<Unit>())
    // int OH_UdsPlainText_SetContent(OH_UdsPlainText*, const char*)
    private var _fnPlainSetContent: CFunc<(CPointer<Unit>, CString) -> Int32> =
        CFunc<(CPointer<Unit>, CString) -> Int32>(CPointer<Unit>())
    // const char* OH_UdsPlainText_GetContent(OH_UdsPlainText*)
    private var _fnPlainGetContent: CFunc<(CPointer<Unit>) -> CPointer<UInt8>> =
        CFunc<(CPointer<Unit>) -> CPointer<UInt8>>(CPointer<Unit>())

    public init() {}

    static func getInstance(): PasteboardTextBridge {
        match (_pbTextBridgeInstance) {
            case Some(b) => return b
            case None =>
                let b = PasteboardTextBridge()
                b.load()
                _pbTextBridgeInstance = Some(b)
                return b
        }
    }

    func isLoaded(): Bool {
        return this._loaded
    }

    private func loadSym(handle: CPointer<Unit>, name: String): CPointer<Unit> {
        let cName = unsafe { LibC.mallocCString(name) }
        let sym = unsafe { dlsym(handle, cName) }
        unsafe { LibC.free(cName) }
        if (sym.isNull()) {
            Hilog.info(0, "CjTelegram", "[PasteboardUtils] dlsym failed: " + name)
        }
        return sym
    }

    private func load(): Unit {
        // libpasteboard.so
        let cPbPath = unsafe { LibC.mallocCString("libpasteboard.so") }
        let pbH = unsafe { dlopen(cPbPath, RTLD_NOW_PB_UTILS) }
        unsafe { LibC.free(cPbPath) }
        if (pbH.isNull()) {
            Hilog.info(0, "CjTelegram", "[PasteboardUtils] dlopen libpasteboard.so failed")
            return
        }
        this._pbHandle = pbH

        let sCreate = loadSym(pbH, "OH_Pasteboard_Create")
        if (!sCreate.isNull()) {
            this._fnPbCreate = CFunc<() -> CPointer<Unit>>(sCreate)
        }
        let sDestroy = loadSym(pbH, "OH_Pasteboard_Destroy")
        if (!sDestroy.isNull()) {
            this._fnPbDestroy = CFunc<(CPointer<Unit>) -> Unit>(sDestroy)
        }
        let sHas = loadSym(pbH, "OH_Pasteboard_HasData")
        if (!sHas.isNull()) {
            this._fnPbHasData = CFunc<(CPointer<Unit>) -> Bool>(sHas)
        }
        let sSet = loadSym(pbH, "OH_Pasteboard_SetData")
        if (!sSet.isNull()) {
            this._fnPbSetData = CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(sSet)
        }
        let sGet = loadSym(pbH, "OH_Pasteboard_GetData")
        if (!sGet.isNull()) {
            this._fnPbGetData = CFunc<(CPointer<Unit>, CPointer<UInt8>) -> CPointer<Unit>>(sGet)
        }
        let sClear = loadSym(pbH, "OH_Pasteboard_ClearData")
        if (!sClear.isNull()) {
            this._fnPbClearData = CFunc<(CPointer<Unit>) -> Int32>(sClear)
        }

        // libudmf.so
        let cUdmfPath = unsafe { LibC.mallocCString("libudmf.so") }
        let udmfH = unsafe { dlopen(cUdmfPath, RTLD_NOW_PB_UTILS) }
        unsafe { LibC.free(cUdmfPath) }
        if (udmfH.isNull()) {
            Hilog.info(0, "CjTelegram", "[PasteboardUtils] dlopen libudmf.so failed")
            return
        }
        this._udmfHandle = udmfH

        let sUC = loadSym(udmfH, "OH_UdmfData_Create")
        if (!sUC.isNull()) {
            this._fnUdmfCreate = CFunc<() -> CPointer<Unit>>(sUC)
        }
        let sUD = loadSym(udmfH, "OH_UdmfData_Destroy")
        if (!sUD.isNull()) {
            this._fnUdmfDestroy = CFunc<(CPointer<Unit>) -> Unit>(sUD)
        }
        let sUAR = loadSym(udmfH, "OH_UdmfData_AddRecord")
        if (!sUAR.isNull()) {
            this._fnUdmfAddRecord = CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(sUAR)
        }
        let sUGR = loadSym(udmfH, "OH_UdmfData_GetRecords")
        if (!sUGR.isNull()) {
            this._fnUdmfGetRecords = CFunc<(CPointer<Unit>, CPointer<UInt8>) -> CPointer<Unit>>(sUGR)
        }
        let sRC = loadSym(udmfH, "OH_UdmfRecord_Create")
        if (!sRC.isNull()) {
            this._fnRecordCreate = CFunc<() -> CPointer<Unit>>(sRC)
        }
        let sRD = loadSym(udmfH, "OH_UdmfRecord_Destroy")
        if (!sRD.isNull()) {
            this._fnRecordDestroy = CFunc<(CPointer<Unit>) -> Unit>(sRD)
        }
        let sRAP = loadSym(udmfH, "OH_UdmfRecord_AddPlainText")
        if (!sRAP.isNull()) {
            this._fnRecordAddPlainText = CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(sRAP)
        }
        let sRGP = loadSym(udmfH, "OH_UdmfRecord_GetPlainText")
        if (!sRGP.isNull()) {
            this._fnRecordGetPlainText = CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(sRGP)
        }
        let sPC = loadSym(udmfH, "OH_UdsPlainText_Create")
        if (!sPC.isNull()) {
            this._fnPlainCreate = CFunc<() -> CPointer<Unit>>(sPC)
        }
        let sPD = loadSym(udmfH, "OH_UdsPlainText_Destroy")
        if (!sPD.isNull()) {
            this._fnPlainDestroy = CFunc<(CPointer<Unit>) -> Unit>(sPD)
        }
        let sPSC = loadSym(udmfH, "OH_UdsPlainText_SetContent")
        if (!sPSC.isNull()) {
            this._fnPlainSetContent = CFunc<(CPointer<Unit>, CString) -> Int32>(sPSC)
        }
        let sPGC = loadSym(udmfH, "OH_UdsPlainText_GetContent")
        if (!sPGC.isNull()) {
            this._fnPlainGetContent = CFunc<(CPointer<Unit>) -> CPointer<UInt8>>(sPGC)
        }

        this._loaded = true
        Hilog.info(0, "CjTelegram", "[PasteboardUtils] bridge loaded")
    }

    // 写纯文本到系统剪贴板。成功返回 true。
    func setText(text: String): Bool {
        if (!this._loaded) {
            return false
        }
        try {
            // 构造 UDS PlainText
            let plain = unsafe { this._fnPlainCreate() }
            if (plain.isNull()) {
                return false
            }
            var ok = false
            let cText = unsafe { LibC.mallocCString(text) }
            let setRc = unsafe { this._fnPlainSetContent(plain, cText) }
            unsafe { LibC.free(cText) }
            if (setRc == 0) {
                // 构造 record 并挂载 PlainText
                let record = unsafe { this._fnRecordCreate() }
                if (!record.isNull()) {
                    let addRc = unsafe { this._fnRecordAddPlainText(record, plain) }
                    if (addRc == 0) {
                        // 构造 UDMF data 并加入 record
                        let data = unsafe { this._fnUdmfCreate() }
                        if (!data.isNull()) {
                            let addRec = unsafe { this._fnUdmfAddRecord(data, record) }
                            if (addRec == 0) {
                                let pb = unsafe { this._fnPbCreate() }
                                if (!pb.isNull()) {
                                    let wr = unsafe { this._fnPbSetData(pb, data) }
                                    ok = (wr == 0)
                                    unsafe { this._fnPbDestroy(pb) }
                                }
                            }
                            unsafe { this._fnUdmfDestroy(data) }
                        }
                    }
                    unsafe { this._fnRecordDestroy(record) }
                }
            }
            unsafe { this._fnPlainDestroy(plain) }
            return ok
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[PasteboardUtils] setText error")
            return false
        }
    }

    // 读系统剪贴板首条纯文本记录；无则空串。
    func getText(): String {
        if (!this._loaded) {
            return ""
        }
        try {
            let pb = unsafe { this._fnPbCreate() }
            if (pb.isNull()) {
                return ""
            }
            let data = unsafe { this._fnPbGetData(pb, CPointer<UInt8>()) }
            unsafe { this._fnPbDestroy(pb) }
            if (data.isNull()) {
                return ""
            }
            var out = ""
            // 取记录数组
            let countBuf = Array<Byte>(4, repeat: 0)
            let countHandle = unsafe { acquireArrayRawData(countBuf) }
            let recordsRaw = unsafe { this._fnUdmfGetRecords(data, countHandle.pointer) }
            unsafe { releaseArrayRawData(countHandle) }
            if (!recordsRaw.isNull()) {
                let recordCount: Int64 = Int64(countBuf[0]) | (Int64(countBuf[1]) << 8) |
                    (Int64(countBuf[2]) << 16) | (Int64(countBuf[3]) << 24)
                let recordsBase = CPointer<UInt8>(recordsRaw)
                var i: Int64 = 0
                while (i < recordCount && out.size == 0) {
                    let recordPtr: CPointer<Unit> = unsafe {
                        CPointer<CPointer<Unit>>(recordsBase + i * 8).read()
                    }
                    if (!recordPtr.isNull()) {
                        let plain = unsafe { this._fnPlainCreate() }
                        if (!plain.isNull()) {
                            let rc = unsafe { this._fnRecordGetPlainText(recordPtr, plain) }
                            if (rc == 0) {
                                let cContent = unsafe { this._fnPlainGetContent(plain) }
                                let s = unsafe { pbuCPtrToString(cContent) }
                                if (s.size > 0) {
                                    out = s
                                }
                            }
                            unsafe { this._fnPlainDestroy(plain) }
                        }
                    }
                    i = i + 1
                }
            }
            unsafe { this._fnUdmfDestroy(data) }
            return out
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[PasteboardUtils] getText error")
            return ""
        }
    }

    // 剪贴板是否有数据。
    func hasData(): Bool {
        if (!this._loaded) {
            return false
        }
        try {
            let pb = unsafe { this._fnPbCreate() }
            if (pb.isNull()) {
                return false
            }
            let has = unsafe { this._fnPbHasData(pb) }
            unsafe { this._fnPbDestroy(pb) }
            return has
        } catch (_: Exception) {
            return false
        }
    }

    // 清空剪贴板。成功返回 true。
    func clearData(): Bool {
        if (!this._loaded) {
            return false
        }
        try {
            let pb = unsafe { this._fnPbCreate() }
            if (pb.isNull()) {
                return false
            }
            let rc = unsafe { this._fnPbClearData(pb) }
            unsafe { this._fnPbDestroy(pb) }
            return rc == 0
        } catch (_: Exception) {
            return false
        }
    }
}

// ─────────────────────────────────────────────────────────────────
// 公共 API（顶层函数，pasteboard 前缀避包级冲突）
// ─────────────────────────────────────────────────────────────────

/**
 * 写纯文本到系统剪贴板。成功返回 true；桥接未加载 / 系统调用失败返回 false，不崩。
 */
public func copyText(text: String): Bool {
    try {
        return PasteboardTextBridge.getInstance().setText(text)
    } catch (_: Exception) {
        return false
    }
}

/**
 * 读系统剪贴板纯文本；无内容 / 读失败返回空串，不崩。
 */
public func readText(): String {
    try {
        return PasteboardTextBridge.getInstance().getText()
    } catch (_: Exception) {
        return ""
    }
}

/**
 * 系统剪贴板是否有数据。读失败返回 false，不崩。
 */
public func hasText(): Bool {
    try {
        return PasteboardTextBridge.getInstance().hasData()
    } catch (_: Exception) {
        return false
    }
}

/**
 * 清空系统剪贴板。成功返回 true；失败返回 false，不崩。
 */
public func clear(): Bool {
    try {
        return PasteboardTextBridge.getInstance().clearData()
    } catch (_: Exception) {
        return false
    }
}

// ─────────────────────────────────────────────────────────────────
// 自检（结构性，纯逻辑）
// ─────────────────────────────────────────────────────────────────

/**
 * pasteboardSelfCheck — 结构性自检。
 *
 * 注：真实剪贴板读写需运行时（系统 libpasteboard.so/libudmf.so + 前台焦点），
 * 属非常驻能力，无法在纯逻辑单测里断言。此处只验证：
 *   - 桥接获取不抛异常；
 *   - 在桥接未加载（如单测进程无系统库）时，四个 API 均安全降级
 *     （copyText/hasText/clear 返回 false，readText 返回空串），不崩。
 */
public func pasteboardSelfCheck(): Bool {
    let bridge = PasteboardTextBridge.getInstance()
    if (!bridge.isLoaded()) {
        // 降级路径必须安全
        if (copyText("x")) {
            return false
        }
        if (hasText()) {
            return false
        }
        if (clear()) {
            return false
        }
        if (readText().size != 0) {
            return false
        }
        return true
    }
    // 桥接已加载（运行时设备）：仅验证调用不崩，不对系统剪贴板状态做强断言
    // （前台焦点 / 权限等运行时因素不可控）。
    let _ = hasText()
    return true
}
