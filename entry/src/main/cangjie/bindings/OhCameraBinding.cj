/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 */
package ohos_app_cangjie_entry.bindings

import kit.PerformanceAnalysisKit.Hilog
import kit.ImageKit.createImageReceiver
import kit.ImageKit.ImageReceiver
import kit.ImageKit.Size as ImageSize
import kit.ImageKit.ImageFormat
import kit.ImageKit.ComponentType

/**
 * OhCameraBinding — ohcamera C NDK 桥接层 (P2-176)
 *
 * 通过 dlopen libohcamera.so + dlsym 加载以下 NDK 符号
 * （来源: ohcamera/camera.h, camera_manager.h, camera_input.h,
 *  capture_session.h, preview_output.h）。
 *
 * 设计原则（对应 PasteboardUtils.cj 范本）：
 * - 所有符号通过 dlopen/dlsym 运行时加载；libohcamera.so 为系统库
 * - 加载失败不崩；公共 API 均 try/catch + 返回安全默认值
 * - foreign func 只声明 libc dlopen/dlsym；ohcamera 符号通过 CFunc 调用
 *
 * Camera_TorchMode 枚举（ohcamera/camera.h）：
 *   CAMERA_TORCH_MODE_OFF = 0
 *   CAMERA_TORCH_MODE_ON  = 1
 *   CAMERA_TORCH_MODE_AUTO = 2
 *
 * out-param 模式（Camera_Manager** 等）：
 *   Array<Byte>(8) + acquireArrayRawData → handle.pointer 传 C 作输出缓冲
 *   在 releaseArrayRawData 之前读 CPointer<CPointer<Unit>>(handle.pointer).read()
 *   提取写入的指针值，避免 Array.rawData() 不存在的问题。
 */

// ─────────────────────────────────────────────────────────────────
// libc dlopen/dlsym foreign func 声明（本包内唯一）
// ─────────────────────────────────────────────────────────────────

foreign func dlopen(path: CString, flags: Int32): CPointer<Unit>
foreign func dlsym(handle: CPointer<Unit>, symbol: CString): CPointer<Unit>
foreign func dlclose(handle: CPointer<Unit>): Int32

// RTLD_NOW = 2 on OHOS/Linux
let OHC_RTLD_NOW: Int32 = 2

// Camera_TorchMode 数值
let OHCAM_TORCH_OFF: Int32 = 0
let OHCAM_TORCH_ON: Int32 = 1

// ─────────────────────────────────────────────────────────────────
// OhCameraLib — 延迟加载 libohcamera.so 的函数指针表（单例）
// ─────────────────────────────────────────────────────────────────

private var _ohCamLibInstance: Option<OhCameraLib> = None

public class OhCameraLib {
    private var _handle: CPointer<Unit> = CPointer<Unit>()
    private var _loaded: Bool = false
    private var _loadFailed: Bool = false

    // OH_Camera_GetCameraManager(Camera_Manager** out) -> Camera_ErrorCode
    var fn_getCameraManager: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())

    // OH_Camera_DeleteCameraManager(Camera_Manager*) -> Camera_ErrorCode
    var fn_deleteCameraManager: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())

    // OH_CameraManager_GetSupportedCameras(mgr, Camera_Device** cameras, uint32_t* size) -> Camera_ErrorCode
    var fn_getSupportedCameras: CFunc<(CPointer<Unit>, CPointer<Unit>, CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>, CPointer<Unit>, CPointer<Unit>) -> Int32>(CPointer<Unit>())

    // OH_CameraManager_DeleteSupportedCameras(mgr, Camera_Device*, uint32_t size) -> Camera_ErrorCode
    var fn_deleteSupportedCameras: CFunc<(CPointer<Unit>, CPointer<Unit>, UInt32) -> Int32> =
        CFunc<(CPointer<Unit>, CPointer<Unit>, UInt32) -> Int32>(CPointer<Unit>())

    // OH_CameraManager_GetSupportedCameraOutputCapability(mgr, camera*, capability**) -> Camera_ErrorCode
    var fn_getOutputCapability: CFunc<(CPointer<Unit>, CPointer<Unit>, CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>, CPointer<Unit>, CPointer<Unit>) -> Int32>(CPointer<Unit>())

    // OH_CameraManager_DeleteSupportedCameraOutputCapability(mgr, capability*) -> Camera_ErrorCode
    var fn_deleteOutputCapability: CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(CPointer<Unit>())

    // OH_CameraManager_CreateCameraInput(mgr, camera*, Camera_Input**) -> Camera_ErrorCode
    var fn_createCameraInput: CFunc<(CPointer<Unit>, CPointer<Unit>, CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>, CPointer<Unit>, CPointer<Unit>) -> Int32>(CPointer<Unit>())

    // OH_CameraInput_Open(Camera_Input*) -> Camera_ErrorCode
    var fn_openInput: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())

    // OH_CameraInput_Close(Camera_Input*) -> Camera_ErrorCode
    var fn_closeInput: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())

    // OH_CameraManager_CreatePreviewOutput(mgr, profile*, surfaceId(CString), Camera_PreviewOutput**) -> Camera_ErrorCode
    var fn_createPreviewOutput: CFunc<(CPointer<Unit>, CPointer<Unit>, CString, CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>, CPointer<Unit>, CString, CPointer<Unit>) -> Int32>(CPointer<Unit>())

    // OH_PreviewOutput_Release(Camera_PreviewOutput*) -> Camera_ErrorCode
    var fn_releasePreviewOutput: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())

    // OH_CameraManager_CreateCaptureSession(mgr, Camera_CaptureSession**) -> Camera_ErrorCode
    var fn_createCaptureSession: CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(CPointer<Unit>())

    // OH_CaptureSession_BeginConfig(Camera_CaptureSession*) -> Camera_ErrorCode
    var fn_sessionBeginConfig: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())

    // OH_CaptureSession_AddInput(session*, Camera_Input*) -> Camera_ErrorCode
    var fn_sessionAddInput: CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(CPointer<Unit>())

    // OH_CaptureSession_AddPreviewOutput(session*, Camera_PreviewOutput*) -> Camera_ErrorCode
    var fn_sessionAddPreviewOutput: CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(CPointer<Unit>())

    // OH_CaptureSession_CommitConfig(session*) -> Camera_ErrorCode
    var fn_sessionCommitConfig: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())

    // OH_CaptureSession_Start(session*) -> Camera_ErrorCode
    var fn_sessionStart: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())

    // OH_CaptureSession_Stop(session*) -> Camera_ErrorCode
    var fn_sessionStop: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())

    // OH_CaptureSession_Release(session*) -> Camera_ErrorCode
    var fn_sessionRelease: CFunc<(CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>) -> Int32>(CPointer<Unit>())

    // OH_CameraManager_IsTorchSupported(mgr, bool*) -> Camera_ErrorCode
    var fn_isTorchSupported: CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32> =
        CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(CPointer<Unit>())

    // OH_CameraManager_SetTorchMode(mgr, Camera_TorchMode) -> Camera_ErrorCode
    var fn_setTorchMode: CFunc<(CPointer<Unit>, Int32) -> Int32> =
        CFunc<(CPointer<Unit>, Int32) -> Int32>(CPointer<Unit>())

    public init() {}

    public static func getInstance(): OhCameraLib {
        match (_ohCamLibInstance) {
            case Some(lib) => return lib
            case None =>
                let lib = OhCameraLib()
                lib.load()
                _ohCamLibInstance = Some(lib)
                return lib
        }
    }

    public func isLoaded(): Bool {
        return this._loaded
    }

    private func loadSym(name: String): CPointer<Unit> {
        let cName = unsafe { LibC.mallocCString(name) }
        let sym = unsafe { dlsym(this._handle, cName) }
        unsafe { LibC.free(cName) }
        if (sym.isNull()) {
            Hilog.info(0, "CjTelegram", "[OhCameraBinding] dlsym miss: " + name)
        }
        return sym
    }

    private func load(): Unit {
        if (this._loadFailed) { return }
        let cPath = unsafe { LibC.mallocCString("libohcamera.so") }
        let h = unsafe { dlopen(cPath, OHC_RTLD_NOW) }
        unsafe { LibC.free(cPath) }
        if (h.isNull()) {
            Hilog.info(0, "CjTelegram", "[OhCameraBinding] dlopen libohcamera.so failed")
            this._loadFailed = true
            return
        }
        this._handle = h
        Hilog.info(0, "CjTelegram", "[OhCameraBinding] dlopen libohcamera.so OK")

        var sym: CPointer<Unit>

        sym = loadSym("OH_Camera_GetCameraManager")
        if (!sym.isNull()) {
            this.fn_getCameraManager = CFunc<(CPointer<Unit>) -> Int32>(sym)
        }

        sym = loadSym("OH_Camera_DeleteCameraManager")
        if (!sym.isNull()) {
            this.fn_deleteCameraManager = CFunc<(CPointer<Unit>) -> Int32>(sym)
        }

        sym = loadSym("OH_CameraManager_GetSupportedCameras")
        if (!sym.isNull()) {
            this.fn_getSupportedCameras = CFunc<(CPointer<Unit>, CPointer<Unit>, CPointer<Unit>) -> Int32>(sym)
        }

        sym = loadSym("OH_CameraManager_DeleteSupportedCameras")
        if (!sym.isNull()) {
            this.fn_deleteSupportedCameras = CFunc<(CPointer<Unit>, CPointer<Unit>, UInt32) -> Int32>(sym)
        }

        sym = loadSym("OH_CameraManager_GetSupportedCameraOutputCapability")
        if (!sym.isNull()) {
            this.fn_getOutputCapability = CFunc<(CPointer<Unit>, CPointer<Unit>, CPointer<Unit>) -> Int32>(sym)
        }

        sym = loadSym("OH_CameraManager_DeleteSupportedCameraOutputCapability")
        if (!sym.isNull()) {
            this.fn_deleteOutputCapability = CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(sym)
        }

        sym = loadSym("OH_CameraManager_CreateCameraInput")
        if (!sym.isNull()) {
            this.fn_createCameraInput = CFunc<(CPointer<Unit>, CPointer<Unit>, CPointer<Unit>) -> Int32>(sym)
        }

        sym = loadSym("OH_CameraInput_Open")
        if (!sym.isNull()) {
            this.fn_openInput = CFunc<(CPointer<Unit>) -> Int32>(sym)
        }

        sym = loadSym("OH_CameraInput_Close")
        if (!sym.isNull()) {
            this.fn_closeInput = CFunc<(CPointer<Unit>) -> Int32>(sym)
        }

        sym = loadSym("OH_CameraManager_CreatePreviewOutput")
        if (!sym.isNull()) {
            this.fn_createPreviewOutput = CFunc<(CPointer<Unit>, CPointer<Unit>, CString, CPointer<Unit>) -> Int32>(sym)
        }

        sym = loadSym("OH_PreviewOutput_Release")
        if (!sym.isNull()) {
            this.fn_releasePreviewOutput = CFunc<(CPointer<Unit>) -> Int32>(sym)
        }

        sym = loadSym("OH_CameraManager_CreateCaptureSession")
        if (!sym.isNull()) {
            this.fn_createCaptureSession = CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(sym)
        }

        sym = loadSym("OH_CaptureSession_BeginConfig")
        if (!sym.isNull()) {
            this.fn_sessionBeginConfig = CFunc<(CPointer<Unit>) -> Int32>(sym)
        }

        sym = loadSym("OH_CaptureSession_AddInput")
        if (!sym.isNull()) {
            this.fn_sessionAddInput = CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(sym)
        }

        sym = loadSym("OH_CaptureSession_AddPreviewOutput")
        if (!sym.isNull()) {
            this.fn_sessionAddPreviewOutput = CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(sym)
        }

        sym = loadSym("OH_CaptureSession_CommitConfig")
        if (!sym.isNull()) {
            this.fn_sessionCommitConfig = CFunc<(CPointer<Unit>) -> Int32>(sym)
        }

        sym = loadSym("OH_CaptureSession_Start")
        if (!sym.isNull()) {
            this.fn_sessionStart = CFunc<(CPointer<Unit>) -> Int32>(sym)
        }

        sym = loadSym("OH_CaptureSession_Stop")
        if (!sym.isNull()) {
            this.fn_sessionStop = CFunc<(CPointer<Unit>) -> Int32>(sym)
        }

        sym = loadSym("OH_CaptureSession_Release")
        if (!sym.isNull()) {
            this.fn_sessionRelease = CFunc<(CPointer<Unit>) -> Int32>(sym)
        }

        sym = loadSym("OH_CameraManager_IsTorchSupported")
        if (!sym.isNull()) {
            this.fn_isTorchSupported = CFunc<(CPointer<Unit>, CPointer<Unit>) -> Int32>(sym)
        }

        sym = loadSym("OH_CameraManager_SetTorchMode")
        if (!sym.isNull()) {
            this.fn_setTorchMode = CFunc<(CPointer<Unit>, Int32) -> Int32>(sym)
        }

        this._loaded = true
        Hilog.info(0, "CjTelegram", "[OhCameraBinding] libohcamera.so fully loaded")
    }
}

// ─────────────────────────────────────────────────────────────────
// OhCameraSession — ohcamera C NDK 相机会话封装
//
// 用途：QR 扫描 → 打开后置摄像头 → 输出帧到 ImageReceiver.surfaceId
// 调用方从 ImageReceiver.readNextImage() 读取 JPEG 帧，喂给 scanBarcode 解码
//
// 生命周期：
//   open() → OH_Camera_GetCameraManager
//          → OH_CameraManager_GetSupportedCameras（选后置设备）
//          → OH_CameraManager_CreateCameraInput
//          → OH_CameraInput_Open
//          → createImageReceiver(640x480, JPEG) → getReceivingSurfaceId()
//          → OH_CameraManager_GetSupportedCameraOutputCapability（取 profile）
//          → OH_CameraManager_CreatePreviewOutput(surfaceId)
//          → OH_CameraManager_CreateCaptureSession
//          → BeginConfig → AddInput → AddPreviewOutput → CommitConfig → Start
//   stop() → OH_CaptureSession_Stop → OH_CaptureSession_Release
//          → OH_PreviewOutput_Release → OH_CameraInput_Close
//          → OH_Camera_DeleteCameraManager
// ─────────────────────────────────────────────────────────────────

private var _ohCamSessionInstance: Option<OhCameraSession> = None

public func getOhCameraSession(): OhCameraSession {
    match (_ohCamSessionInstance) {
        case Some(s) => return s
        case None =>
            let s = OhCameraSession()
            _ohCamSessionInstance = Some(s)
            return s
    }
}

public class OhCameraSession {
    private var _mgr: CPointer<Unit> = CPointer<Unit>()
    private var _camInput: CPointer<Unit> = CPointer<Unit>()
    private var _previewOut: CPointer<Unit> = CPointer<Unit>()
    private var _session: CPointer<Unit> = CPointer<Unit>()
    private var _active: Bool = false

    // ImageReceiver 持有 surfaceId 并用于读帧
    private var _receiver: Option<ImageReceiver> = None

    public init() {}

    /**
     * open — 打开后置摄像头，建立 ohcamera C FFI 会话，帧输出到 ImageReceiver.
     * 返回 ImageReceiver 供调用方 readNextImage() 拉帧；None = 失败。
     */
    public func open(): Option<ImageReceiver> {
        if (this._active) {
            Hilog.info(0, "CjTelegram", "[OhCameraSession] already active, reusing receiver")
            return this._receiver
        }
        let lib = OhCameraLib.getInstance()
        if (!lib.isLoaded()) {
            Hilog.info(0, "CjTelegram", "[OhCameraSession] lib not loaded, open failed")
            return None
        }
        try {
            return this.doOpen(lib)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[OhCameraSession] open exception: ${e}")
            return None
        }
    }

    /**
     * stop — 停止并释放所有 ohcamera 资源。
     */
    public func stop(): Unit {
        if (!this._active) { return }
        this._active = false
        let lib = OhCameraLib.getInstance()
        try {
            if (lib.isLoaded()) {
                if (!this._session.isNull()) {
                    let _ = unsafe { lib.fn_sessionStop(this._session) }
                    let _ = unsafe { lib.fn_sessionRelease(this._session) }
                    this._session = CPointer<Unit>()
                }
                if (!this._previewOut.isNull()) {
                    let _ = unsafe { lib.fn_releasePreviewOutput(this._previewOut) }
                    this._previewOut = CPointer<Unit>()
                }
                if (!this._camInput.isNull()) {
                    let _ = unsafe { lib.fn_closeInput(this._camInput) }
                    this._camInput = CPointer<Unit>()
                }
                if (!this._mgr.isNull()) {
                    let _ = unsafe { lib.fn_deleteCameraManager(this._mgr) }
                    this._mgr = CPointer<Unit>()
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[OhCameraSession] stop error: ${e}")
        }
        this._receiver = None
        Hilog.info(0, "CjTelegram", "[OhCameraSession] stopped")
    }

    public func isActive(): Bool {
        return this._active
    }

    /**
     * setTorchMode — 通过 C FFI 控制手电筒（OH_CameraManager_SetTorchMode）。
     * on=true → CAMERA_TORCH_MODE_ON(1)；on=false → OFF(0)。
     * 返回 true 表示调用成功（rc==0）。
     */
    public func setTorchMode(on: Bool): Bool {
        let lib = OhCameraLib.getInstance()
        if (!lib.isLoaded() || this._mgr.isNull()) { return false }
        try {
            let mode: Int32 = if (on) { OHCAM_TORCH_ON } else { OHCAM_TORCH_OFF }
            let rc: Int32 = unsafe { lib.fn_setTorchMode(this._mgr, mode) }
            Hilog.info(0, "CjTelegram", "[OhCameraSession] setTorchMode on=${on} rc=${rc}")
            return rc == 0
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[OhCameraSession] setTorchMode error: ${e}")
            return false
        }
    }

    /**
     * isTorchSupported — 查询设备是否支持手电筒。
     */
    public func isTorchSupported(): Bool {
        let lib = OhCameraLib.getInstance()
        if (!lib.isLoaded() || this._mgr.isNull()) { return false }
        try {
            // bool* 出参：Array<Byte>(1) + acquireArrayRawData
            let supportedBuf = Array<Byte>(1, repeat: 0)
            var rc: Int32 = 0
            unsafe {
                let handle = acquireArrayRawData(supportedBuf)
                rc = lib.fn_isTorchSupported(this._mgr, CPointer<Unit>(handle.pointer))
                releaseArrayRawData(handle)
            }
            if (rc != 0) { return false }
            return supportedBuf[0] != 0
        } catch (e: Exception) {
            return false
        }
    }

    // ─────── 内部 doOpen ───────

    private func doOpen(lib: OhCameraLib): Option<ImageReceiver> {
        var rc: Int32 = 0

        // ── 1. OH_Camera_GetCameraManager(Camera_Manager** out) ──
        // 用 Array<Byte>(8) 作 Camera_Manager** 输出缓冲（aarch64: 指针宽度 8 字节）
        // 关键：在 releaseArrayRawData 之前通过 handle.pointer 读取写入的指针值
        let mgrPtrBuf = Array<Byte>(8, repeat: 0)
        unsafe {
            let mgrHandle = acquireArrayRawData(mgrPtrBuf)
            rc = lib.fn_getCameraManager(CPointer<Unit>(mgrHandle.pointer))
            if (rc == 0) {
                this._mgr = CPointer<CPointer<Unit>>(mgrHandle.pointer).read()
            }
            releaseArrayRawData(mgrHandle)
        }
        if (rc != 0 || this._mgr.isNull()) {
            Hilog.info(0, "CjTelegram", "[OhCameraSession] GetCameraManager rc=${rc}")
            return None
        }
        Hilog.info(0, "CjTelegram", "[OhCameraSession] CameraManager acquired")

        // ── 2. OH_CameraManager_GetSupportedCameras(mgr, Camera_Device** cameras, uint32_t* size) ──
        let camerasPtrBuf = Array<Byte>(8, repeat: 0)
        let sizeBuf = Array<Byte>(4, repeat: 0)
        var camerasRawPtr: CPointer<Unit> = CPointer<Unit>()
        unsafe {
            let camHandle = acquireArrayRawData(camerasPtrBuf)
            let sizeHandle = acquireArrayRawData(sizeBuf)
            rc = lib.fn_getSupportedCameras(this._mgr, CPointer<Unit>(camHandle.pointer), CPointer<Unit>(sizeHandle.pointer))
            if (rc == 0) {
                camerasRawPtr = CPointer<CPointer<Unit>>(camHandle.pointer).read()
            }
            releaseArrayRawData(sizeHandle)
            releaseArrayRawData(camHandle)
        }
        if (rc != 0 || camerasRawPtr.isNull()) {
            Hilog.info(0, "CjTelegram", "[OhCameraSession] GetSupportedCameras rc=${rc}")
            return None
        }

        // 小端序读取 uint32_t camsSize（4 字节）
        let camsSize: Int64 = Int64(sizeBuf[0]) | (Int64(sizeBuf[1]) << 8) |
            (Int64(sizeBuf[2]) << 16) | (Int64(sizeBuf[3]) << 24)
        if (camsSize <= 0) {
            Hilog.info(0, "CjTelegram", "[OhCameraSession] no cameras found")
            return None
        }
        Hilog.info(0, "CjTelegram", "[OhCameraSession] cameras count=${camsSize}")

        // ── 3. 选后置摄像头（Camera_Position_Back = 1）──
        // Camera_Device 结构（ohcamera/camera.h）：
        //   char* cameraId;             (8 bytes, aarch64)
        //   Camera_Position position;   (int32, 4 bytes) at offset 8
        //   Camera_Type type;           (int32, 4 bytes) at offset 12
        //   Camera_Connection connection;(int32, 4 bytes) at offset 16
        // sizeof(Camera_Device) = 24 bytes（含末尾对齐）
        let devStructSize: Int64 = 24
        var chosenCamera: CPointer<Unit> = camerasRawPtr
        unsafe {
            var i: Int64 = 1
            while (i < camsSize) {
                let devPtr = CPointer<UInt8>(camerasRawPtr) + i * devStructSize
                // cameraPosition 在 offset 8
                let posPtr = devPtr + 8
                let posVal: Int32 = Int32(posPtr.read()) |
                    (Int32((posPtr + 1).read()) << 8) |
                    (Int32((posPtr + 2).read()) << 16) |
                    (Int32((posPtr + 3).read()) << 24)
                if (posVal == 1) {
                    chosenCamera = CPointer<Unit>(devPtr)
                }
                i = i + 1
            }
        }
        Hilog.info(0, "CjTelegram", "[OhCameraSession] chosen camera selected")

        // ── 4. OH_CameraManager_CreateCameraInput(mgr, camera*, Camera_Input**) ──
        let inputPtrBuf = Array<Byte>(8, repeat: 0)
        unsafe {
            let inHandle = acquireArrayRawData(inputPtrBuf)
            rc = lib.fn_createCameraInput(this._mgr, chosenCamera, CPointer<Unit>(inHandle.pointer))
            if (rc == 0) {
                this._camInput = CPointer<CPointer<Unit>>(inHandle.pointer).read()
            }
            releaseArrayRawData(inHandle)
        }
        if (rc != 0 || this._camInput.isNull()) {
            Hilog.info(0, "CjTelegram", "[OhCameraSession] CreateCameraInput rc=${rc}")
            return None
        }
        Hilog.info(0, "CjTelegram", "[OhCameraSession] CameraInput created")

        // ── 5. OH_CameraInput_Open(Camera_Input*) ──
        unsafe {
            rc = lib.fn_openInput(this._camInput)
        }
        Hilog.info(0, "CjTelegram", "[OhCameraSession] CameraInput_Open rc=${rc}")

        // ── 6. 创建 ImageReceiver（640x480 JPEG，8 帧 capacity）── kit.ImageKit API
        let previewSize = ImageSize(640, 480)
        let receiver = createImageReceiver(previewSize, ImageFormat.Jpeg, 8)
        let surfaceId = receiver.getReceivingSurfaceId()
        this._receiver = Some(receiver)
        Hilog.info(0, "CjTelegram", "[OhCameraSession] ImageReceiver surfaceId=${surfaceId}")

        // ── 7. OH_CameraManager_GetSupportedCameraOutputCapability 取首个 previewProfile ──
        var profilePtr: CPointer<Unit> = CPointer<Unit>()
        let capPtrBuf = Array<Byte>(8, repeat: 0)
        unsafe {
            let capHandle = acquireArrayRawData(capPtrBuf)
            rc = lib.fn_getOutputCapability(this._mgr, chosenCamera, CPointer<Unit>(capHandle.pointer))
            if (rc == 0) {
                let capPtr = CPointer<CPointer<Unit>>(capHandle.pointer).read()
                if (!capPtr.isNull()) {
                    // Camera_OutputCapability 首字段 previewProfiles = Camera_Profile**（8B ptr）
                    let profilesPtr: CPointer<Unit> = CPointer<CPointer<Unit>>(CPointer<UInt8>(capPtr)).read()
                    if (!profilesPtr.isNull()) {
                        // 第一个 Camera_Profile*
                        profilePtr = CPointer<CPointer<Unit>>(CPointer<UInt8>(profilesPtr)).read()
                    }
                }
            }
            releaseArrayRawData(capHandle)
        }
        Hilog.info(0, "CjTelegram", "[OhCameraSession] previewProfile null=${profilePtr.isNull()}")

        // ── 8. OH_CameraManager_CreatePreviewOutput(mgr, profile*, surfaceId, Camera_PreviewOutput**) ──
        let prevOutPtrBuf = Array<Byte>(8, repeat: 0)
        let cSurfaceId = unsafe { LibC.mallocCString(surfaceId) }
        unsafe {
            let prevHandle = acquireArrayRawData(prevOutPtrBuf)
            rc = lib.fn_createPreviewOutput(this._mgr, profilePtr, cSurfaceId, CPointer<Unit>(prevHandle.pointer))
            if (rc == 0) {
                this._previewOut = CPointer<CPointer<Unit>>(prevHandle.pointer).read()
            }
            releaseArrayRawData(prevHandle)
            LibC.free(cSurfaceId)
        }
        if (rc != 0 || this._previewOut.isNull()) {
            Hilog.info(0, "CjTelegram", "[OhCameraSession] CreatePreviewOutput rc=${rc}")
            return None
        }
        Hilog.info(0, "CjTelegram", "[OhCameraSession] PreviewOutput created")

        // ── 9. OH_CameraManager_CreateCaptureSession(mgr, Camera_CaptureSession**) ──
        let sessionPtrBuf = Array<Byte>(8, repeat: 0)
        unsafe {
            let sessHandle = acquireArrayRawData(sessionPtrBuf)
            rc = lib.fn_createCaptureSession(this._mgr, CPointer<Unit>(sessHandle.pointer))
            if (rc == 0) {
                this._session = CPointer<CPointer<Unit>>(sessHandle.pointer).read()
            }
            releaseArrayRawData(sessHandle)
        }
        if (rc != 0 || this._session.isNull()) {
            Hilog.info(0, "CjTelegram", "[OhCameraSession] CreateCaptureSession rc=${rc}")
            return None
        }
        Hilog.info(0, "CjTelegram", "[OhCameraSession] CaptureSession created")

        // ── 10. BeginConfig → AddInput → AddPreviewOutput → CommitConfig → Start ──
        unsafe {
            rc = lib.fn_sessionBeginConfig(this._session)
        }
        Hilog.info(0, "CjTelegram", "[OhCameraSession] BeginConfig rc=${rc}")

        unsafe {
            rc = lib.fn_sessionAddInput(this._session, this._camInput)
        }
        Hilog.info(0, "CjTelegram", "[OhCameraSession] AddInput rc=${rc}")

        unsafe {
            rc = lib.fn_sessionAddPreviewOutput(this._session, this._previewOut)
        }
        Hilog.info(0, "CjTelegram", "[OhCameraSession] AddPreviewOutput rc=${rc}")

        unsafe {
            rc = lib.fn_sessionCommitConfig(this._session)
        }
        Hilog.info(0, "CjTelegram", "[OhCameraSession] CommitConfig rc=${rc}")

        unsafe {
            rc = lib.fn_sessionStart(this._session)
        }
        Hilog.info(0, "CjTelegram", "[OhCameraSession] Start rc=${rc}")

        if (rc != 0) {
            Hilog.info(0, "CjTelegram", "[OhCameraSession] session start failed rc=${rc}")
            return None
        }

        this._active = true
        Hilog.info(0, "CjTelegram", "[OhCameraSession] ohcamera C FFI session active")
        return this._receiver
    }
}
