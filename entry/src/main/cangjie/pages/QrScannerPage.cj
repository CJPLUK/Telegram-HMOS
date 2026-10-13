/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 */
package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.viewmodels.*
import ohos_app_cangjie_entry.bindings.getOhCameraSession
import ohos_app_cangjie_entry.interop.*
import kit.CoreFileKit.*
import kit.ImageKit.ComponentType
import ohos_app_cangjie_entry.router.*

/**
 * QrScannerPage — 相机 QR 码扫描页面 (P2-176)
 *
 * 对应 iOS QrCodeScanScreen（submodules/QrCodeUI/Sources/QrCodeScanScreen.swift）:
 *
 * 相机取帧：ohcamera C NDK 真 C FFI（dlopen libohcamera.so + OH_Camera* 符号）
 *   OH_Camera_GetCameraManager → OH_CameraManager_GetSupportedCameras（选后置）
 *   → OH_CameraManager_CreateCameraInput → OH_CameraInput_Open
 *   → createImageReceiver(640x480, JPEG) → getReceivingSurfaceId()
 *   → OH_CameraManager_CreatePreviewOutput(surfaceId)
 *   → OH_CaptureSession_BeginConfig/AddInput/AddPreviewOutput/CommitConfig/Start
 *   → 后台 spawn 轮询 receiver.readNextImage() 拉 JPEG 帧
 *
 * QR 解码（Phase 3 反转）：@kit.ScanKit detectBarcode（OHOS 无 C QR NDK, zxing/scan C NDK 不存在）
 *   KB 三轮检索（worker:P2-176）确认：没有仓颉原生 QR 解码 API，只有 ArkTS ScanKit。
 *   反转链路: frame → save to sandbox temp file →
 *     callArkAsync(SCAN_DECODE_FILE, {"uri":...}) → ScanDecodeImpl.ets → detectBarcode.decode({uri})。
 *   旧 arkinterop（JSRuntime/requireSystemNativeModule）已删，能力实现搬到 ArkTS 侧（反转模式 SSOT §5）。
 *
 * torch 手电筒：ohcamera C FFI（OH_CameraManager_SetTorchMode）
 *   CAMERA_TORCH_MODE_OFF=0, CAMERA_TORCH_MODE_ON=1
 *
 * 其余功能保持不变：
 *   - 从相册扫（Phase 3 反转：callArkAsync(SCAN_PICK_ALBUM) →
 *     photoAccessHelper.PhotoViewPicker + detectBarcode.decode）
 *   - 扫描框 UI + 扫描线往返动画（spawn loop + launch 驱动 @State）
 *   - 扫码结果路由:
 *       tg://login?token=<base64url>     → QR 登录 importLoginToken
 *       https://t.me/joinchat/<hash>     → 加群 checkChatInvite + importChatInvite
 *       https://t.me/+<hash>             → 加群（同上）
 *       https://t.me/<username>          → 显示 Telegram 链接
 *       其他                             → 显示原始内容
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack；@Consume isLoggedIn（跨页共享状态）改为本页 @State
 *    （无 @Provide 的 hybrid-embedded 页面无法 @Consume；全局登录态由 services 层持有，
 *    此处仅保留登录成功时的本地副作用赋值）
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - pageStack.pop() → routerPop()
 *  - aboutToAppear/aboutToDisappear 有实逻辑 → 移到 ensureLoaded()/cleanup()（.onAppear/.onDisAppear）
 */
@HybridComponentEntry
@Component
public class QrScannerPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var isLoggedIn: Bool = false

    // ── 扫描状态 ──
    @State var scanStatus: String = "正在启动相机扫描..."
    @State var scannedResult: String = ""
    @State var isProcessing: Bool = false
    @State var torchOn: Bool = false
    @State var scanLineOffset: Float64 = 0.0
    @State var animRunning: Bool = false
    @State var codeResolved: Bool = false
    @State var isScanning: Bool = false
    @State var loaded: Bool = false

    // ── 生命周期 ──

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.codeResolved = false
        this.isScanning = false
        this.animRunning = true
        this.startScanLineAnimation()
        this.startCameraScan()
    }

    private func cleanup(): Unit {
        this.animRunning = false
        this.isScanning = false
        this.performStopTorch()
        spawn {
            // TODO(P2-cpp): ohcamera C NDK FFI (getOhCameraSession) — Phase 2 cpp
            getOhCameraSession().stop()
        }
    }

    // ── 扫描线动画（spawn loop + launch 更新 @State）──

    private func startScanLineAnimation(): Unit {
        spawn {
            var going = true
            var pos: Float64 = 0.0
            while (this.animRunning) {
                if (going) {
                    pos = pos + 2.0
                    if (pos >= 220.0) { going = false }
                } else {
                    pos = pos - 2.0
                    if (pos <= 0.0) { going = true }
                }
                let curPos = pos
                launch {
                    this.scanLineOffset = curPos
                }
                sleep(Duration.millisecond * 8)
            }
        }
    }

    // ── 真相机 QR 扫描（ohcamera C NDK FFI 取帧 + ArkTS scanBarcode 解码）──
    //
    // 架构：
    //   1. getOhCameraSession().open() — dlopen libohcamera.so → C NDK 建立相机管道
    //      返回 ImageReceiver；帧通过 surfaceId 写入 ImageReceiver 缓冲区
    //   2. 后台 spawn 轮询 receiver.readNextImage() 拉 JPEG 帧字节
    //   3. 将帧 JPEG 写入沙箱临时文件（sandbox path via getGlobalAbilityContext）
    //   4. ArkTS scanBarcode.decode({uri}) 解析 QR 码（OHOS 无 C QR NDK）
    //
    // 诚实记录：QR 解码使用 ArkTS arkinterop（OHOS 无 zxing/scan C NDK，KB 三轮确认）

    private func startCameraScan(): Unit {
        launch {
            this.scanStatus = "正在启动相机..."
            this.isScanning = true
        }
        spawn {
            // TODO(P2-cpp): ohcamera C NDK FFI (getOhCameraSession) — Phase 2 cpp
            let camSession = getOhCameraSession()
            let receiverOpt = camSession.open()
            match (receiverOpt) {
                case None =>
                    Hilog.warn(0, "CjTelegram", "[QrScannerPage] ohcamera open failed")
                    launch {
                        this.scanStatus = "相机启动失败，请检查权限后重试"
                        this.isScanning = false
                    }
                case Some(receiver) =>
                    launch {
                        this.scanStatus = "请将 QR 码对准扫描框"
                    }
                    // 轮询帧并解码（后台线程）
                    var frameCount: Int64 = 0
                    while (this.isScanning && !this.codeResolved) {
                        try {
                            let img = receiver.readNextImage()
                            let comp = img.getComponent(ComponentType.Jpeg)
                            let frameBytes: Array<UInt8> = comp.byteBuffer
                            img.release()
                            if (frameBytes.size > 0) {
                                frameCount = frameCount + 1
                                // 每 3 帧尝试一次解码（降低 ArkTS 调用频率）
                                if (frameCount % 3 == 0) {
                                    let filePath = this.saveFrameToSandbox(frameBytes)
                                    if (filePath.size > 0 && !this.codeResolved) {
                                        this.decodeQrFromFile(filePath)
                                    }
                                }
                            }
                        } catch (_: Exception) {
                            // readNextImage 无帧时抛出异常，正常
                            sleep(Duration.millisecond * 50)
                        }
                    }
            }
        }
    }

    // 将 JPEG 帧字节写入沙箱临时文件，返回 file:// URI；失败返回空串
    // 使用 getAppFilesDir() + FileIo（kit.CoreFileKit 模式，同 MediaResourcesService.cj）
    private func saveFrameToSandbox(data: Array<UInt8>): String {
        try {
            let filesDir = getAppFilesDir()
            if (filesDir.isEmpty()) { return "" }
            let filePath = filesDir + "/qr_frame_tmp.jpg"
            // mode: 0o1101 = O_WRONLY|O_CREAT|O_TRUNC（同 MediaResourcesService）
            let f = FileIo.open(filePath, mode: 0o1101)
            let _ = FileIo.write(f.fd, data)
            FileIo.close(f)
            return "file://" + filePath
        } catch (e: Exception) {
            Hilog.warn(0, "CjTelegram", "[QrScannerPage] saveFrame error: ${e}")
            return ""
        }
    }

    // Phase 3 反转：@kit.ScanKit detectBarcode.decode({uri}) → QR 解码
    // 反转链路: callArkAsync(SCAN_DECODE_FILE, {"uri":fileUri}) → ScanDecodeImpl.ets
    //   → detectBarcode.decode({uri}) → ScanResult[0].originalValue。
    // 线程 hop 在 interop 层完成，此处不再触碰 JSRuntime；单帧解码失败静默返回不影响轮询。
    private func decodeQrFromFile(fileUri: String): Unit {
        let argJson = "{\"uri\":\"${jsonEscapeQr(fileUri)}\"}"
        callArkAsync(SCAN_DECODE_FILE, argJson, { res =>
            let ok = jsonBoolFieldQr(res, "ok")
            if (!ok) { return }
            let code = jsonStringFieldQr(res, "code")
            if (code.size > 0 && !this.codeResolved && this.isScanning) {
                let codeVal = code
                launch {
                    this.scannedResult = codeVal
                    this.isScanning = false
                }
                spawn {
                    this.handleScannedCode(codeVal)
                }
            }
        })
    }

    // ── torch（手电筒）── ohcamera C FFI OH_CameraManager_SetTorchMode ──
    //
    // Camera_TorchMode: OFF=0, ON=1, AUTO=2（ohcamera/camera.h）
    // getOhCameraSession().setTorchMode(on) → lib.fn_setTorchMode(mgr, 1|0) → rc==0 表成功
    // 需要相机管道已 open()（mgr 不为 null）；未 open 则 setTorchMode 返回 false

    private func toggleTorch(): Unit {
        let newState = !this.torchOn
        spawn {
            let camSession = getOhCameraSession()
            let ok = camSession.setTorchMode(newState)
            if (ok) {
                launch {
                    this.torchOn = newState
                }
            } else {
                Hilog.warn(0, "CjTelegram", "[QrScannerPage] toggleTorch setTorchMode failed (lib not loaded or mgr null)")
            }
        }
    }

    private func performStopTorch(): Unit {
        if (!this.torchOn) { return }
        spawn {
            let camSession = getOhCameraSession()
            let _ = camSession.setTorchMode(false)
        }
    }

    // ── 从相册扫（Phase 3 反转：@kit.MediaLibraryKit photoAccessHelper + @kit.ScanKit detectBarcode）──
    // 反转链路: callArkAsync(SCAN_PICK_ALBUM, {}) → ScanDecodeImpl.ets
    //   → PhotoViewPicker.select(image) → detectBarcode.decode(pickedUri) → originalValue。
    // ArkTS 侧一次往返完成「选图 + 解码」；result.status 区分 decoded/empty/cancelled/error。
    private func pickFromAlbumAndScan(): Unit {
        callArkAsync(SCAN_PICK_ALBUM, "{}", { res =>
            let ok = jsonBoolFieldQr(res, "ok")
            let status = jsonStringFieldQr(res, "status")
            if (!ok) {
                Hilog.warn(0, "CjTelegram", "[QrScannerPage] pickFromAlbumAndScan failed status=${status}")
                launch { this.scanStatus = "相册访问失败，请检查权限" }
                return
            }
            if (status == "cancelled") {
                launch { this.scanStatus = "未选择图片" }
            } else if (status == "empty") {
                launch { this.scanStatus = "未能从图片识别 QR 码" }
            } else if (status == "decoded") {
                let code = jsonStringFieldQr(res, "code")
                if (code.size > 0) {
                    let codeVal = code
                    launch { this.scannedResult = codeVal }
                    spawn { this.handleScannedCode(codeVal) }
                } else {
                    launch { this.scanStatus = "未能从图片识别 QR 码" }
                }
            } else {
                launch { this.scanStatus = "图片 QR 识别失败" }
            }
        })
    }

    // ── 扫码结果路由（对应 iOS resolveCode + openResolved）──

    private func handleScannedCode(code: String): Unit {
        if (this.codeResolved) { return }
        Hilog.info(0, "CjTelegram", "[QrScannerPage] handleScannedCode: ${code}")
        let lower = code.toAsciiLower()

        if (lower.startsWith("tg://login?token=") || lower.startsWith("tg://login/?token=")) {
            launch { this.codeResolved = true }
            this.doQrLogin(code)
        } else if (lower.startsWith("https://t.me/joinchat/") || lower.startsWith("http://t.me/joinchat/")) {
            launch { this.codeResolved = true }
            this.doJoinChatInvite(extractJoinChatHash(code))
        } else if (lower.startsWith("https://t.me/+") || lower.startsWith("http://t.me/+")) {
            launch { this.codeResolved = true }
            this.doJoinChatInvite(extractPlusHash(code))
        } else if (lower.startsWith("https://t.me/") || lower.startsWith("http://t.me/")) {
            launch {
                this.scanStatus = "已扫描 Telegram 链接，正在跳转..."
                this.isProcessing = false
            }
        } else {
            launch {
                this.scanStatus = "扫描结果: ${code}"
                this.isProcessing = false
            }
        }
    }

    private func doQrLogin(code: String): Unit {
        launch {
            this.isProcessing = true
            this.scanStatus = "正在处理登录 Token..."
        }
        let tokenStr = extractTokenFromUrl(code)
        if (tokenStr.size == 0) {
            launch {
                this.scanStatus = "Token 格式无效"
                this.isProcessing = false
                this.codeResolved = false
            }
            return
        }
        let tokenBytes = Base64.decodeBase64Url(tokenStr)
        if (tokenBytes.size == 0) {
            launch {
                this.scanStatus = "Token 解码失败"
                this.isProcessing = false
                this.codeResolved = false
            }
            return
        }
        spawn {
            let authService = getRealAuthService()
            authService.setCallback(AuthViewModelCallback(viewModel: getAuthViewModel()))
            var resp = authService.importLoginToken(tokenBytes)
            if (resp.kind == "migrateTo") {
                resp = authService.importLoginToken(resp.token)
            }
            if (resp.kind == "success") {
                match (resp.authorization) {
                    case Some(user) =>
                        authService.completeQrLogin(user)
                        launch {
                            // 混合迁移 auth-flow：写 app 级单例 SSOT + routerReplace 进主 tab
                            getAuthViewModel().isLoggedIn = true
                            this.isLoggedIn = true
                            this.isProcessing = false
                            this.scanStatus = "登录成功"
                            routerReplace("MainTabPage", "{}")
                        }
                    case None =>
                        launch {
                            this.scanStatus = "登录失败，请重试"
                            this.isProcessing = false
                            this.codeResolved = false
                        }
                }
            } else {
                launch {
                    this.scanStatus = "登录失败，请重试"
                    this.isProcessing = false
                    this.codeResolved = false
                }
            }
        }
    }

    private func doJoinChatInvite(hash: String): Unit {
        if (hash.size == 0) {
            launch {
                this.scanStatus = "邀请链接格式无效"
                this.isProcessing = false
                this.codeResolved = false
            }
            return
        }
        launch {
            this.isProcessing = true
            this.scanStatus = "正在验证群组邀请..."
        }
        spawn {
            let joinSvc = getJoinLinkPreviewService()
            let checkInfo = joinSvc.checkChatInvite(hash)
            if (checkInfo.invalidHash) {
                launch {
                    this.scanStatus = "邀请链接无效或已过期"
                    this.isProcessing = false
                    this.codeResolved = false
                }
                return
            }
            if (checkInfo.alreadyJoined) {
                launch {
                    this.scanStatus = "你已经是该群组成员"
                    this.isProcessing = false
                    routerPop()
                }
                return
            }
            let joinOk = joinSvc.importChatInvite(hash)
            launch {
                this.isProcessing = false
                if (joinOk) {
                    this.scanStatus = "已成功加入: ${checkInfo.title}"
                    routerPop()
                } else {
                    this.scanStatus = "加入群组失败，请重试"
                    this.codeResolved = false
                }
            }
        }
    }

    // ── @Builder 子构建器（无 let/var，仅 UI 表达式和方法调用）──

    @Builder
    func buildScanFrame() {
        Stack(alignContent: Alignment.Center) {
            Column {}
                .width(240)
                .height(240)
                .borderRadius(16)
                .border(width: 3, color: 0xFFFFFF)
                .opacity(0.6)

            Column {}
                .width(236)
                .height(3)
                .backgroundColor(0x317AFF)
                .opacity(0.85)
                .offset(x: 0, y: Int64(this.scanLineOffset))
        }
        .width(240)
        .height(240)
    }

    @Builder
    func buildStatusRow() {
        Column {
            if (this.isProcessing) {
                LoadingProgress()
                    .width(32)
                    .height(32)
                    .color(0xFFFFFF)
                    .margin(bottom: 8)
            }
            Text(this.scanStatus)
                .fontSize(14)
                .fontColor(0xFFFFFF)
                .textAlign(TextAlign.Center)
                .maxLines(3)
                .padding(left: 24, right: 24)
        }
        .alignItems(HorizontalAlign.Center)
        .justifyContent(FlexAlign.Center)
    }

    @Builder
    func buildControlRow() {
        Row {
            Column {
                Text(if (this.torchOn) { "关闭手电筒" } else { "手电筒" })
                    .fontSize(13)
                    .fontColor(0xFFFFFF)
                    .textAlign(TextAlign.Center)
            }
            .width(90)
            .height(56)
            .borderRadius(28)
            .backgroundColor(if (this.torchOn) { 0xFFCC00 } else { 0x444444 })
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .margin(left: 16, right: 16)
            .onClick({ _ => this.toggleTorch() })

            Column {
                Text("从相册扫")
                    .fontSize(13)
                    .fontColor(0xFFFFFF)
                    .textAlign(TextAlign.Center)
            }
            .width(90)
            .height(56)
            .borderRadius(28)
            .backgroundColor(0x444444)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .margin(left: 16, right: 16)
            .onClick({ _ => this.pickFromAlbumAndScan() })
        }
        .justifyContent(FlexAlign.Center)
        .width(100.percent)
        .padding(top: 24, bottom: 32)
    }

    func build() {
        Column {
            Row {
                Button(trSource("Back"))
                    .width(60)
                    .height(36)
                    .borderRadius(18)
                    .backgroundColor(0x555555)
                    .fontColor(0xFFFFFF)
                    .fontSize(14)
                    .onClick({ _ =>
                        this.animRunning = false
                        this.isScanning = false
                        routerPop()
                    })
                Blank()
                Text(trSource("Scan QR Code"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0xFFFFFF)
                Blank()
                Column {}.width(60)
            }
            .width(100.percent)
            .padding(top: 16, left: 16, right: 16, bottom: 8)
            .alignItems(VerticalAlign.Center)

            Column {}.height(40)

            this.buildScanFrame()

            Column {}.height(32)

            this.buildStatusRow()

            if (this.scannedResult.size > 0) {
                Column {
                    Text("扫描内容:")
                        .fontSize(12)
                        .fontColor(0x999999)
                        .margin(bottom: 4)
                    Text(this.scannedResult)
                        .fontSize(12)
                        .fontColor(0xCCCCCC)
                        .maxLines(2)
                        .textOverflow(TextOverflow.Ellipsis)
                        .textAlign(TextAlign.Center)
                        .padding(left: 16, right: 16)
                }
                .alignItems(HorizontalAlign.Center)
                .margin(top: 16)
            }

            Blank()

            this.buildControlRow()
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x000000)
        .alignItems(HorizontalAlign.Center)
        .onAppear({ => this.ensureLoaded() })
        .onDisAppear({ => this.cleanup() })
    }
}

// ── 辅助函数（包级私有）──

private func extractTokenFromUrl(url: String): String {
    let parts = url.split("token=")
    if (parts.size >= 2) {
        let tokenPart = parts[1]
        let endParts = tokenPart.split("&")
        return endParts[0]
    }
    return ""
}

private func extractJoinChatHash(url: String): String {
    let prefix1 = "https://t.me/joinchat/"
    let prefix2 = "http://t.me/joinchat/"
    if (url.startsWith(prefix1)) {
        return url[prefix1.size..]
    }
    if (url.startsWith(prefix2)) {
        return url[prefix2.size..]
    }
    return ""
}

private func extractPlusHash(url: String): String {
    let prefix1 = "https://t.me/+"
    let prefix2 = "http://t.me/+"
    if (url.startsWith(prefix1)) {
        return url[prefix1.size..]
    }
    if (url.startsWith(prefix2)) {
        return url[prefix2.size..]
    }
    return ""
}

// ── 轻量 JSON 读取 / 转义（仅解析 interop 回传的扁平 result 对象）──

private func jsonBoolFieldQr(json: String, key: String): Bool {
    let needle = "\"${key}\""
    match (json.indexOf(needle)) {
        case Some(i) =>
            let rest = json[(i + needle.size)..json.size]
            match (rest.indexOf("true")) {
                case Some(t) =>
                    match (rest.indexOf("false")) {
                        case Some(f) => return t < f
                        case None => return true
                    }
                case None => return false
            }
        case None => return false
    }
}

private func jsonStringFieldQr(json: String, key: String): String {
    let needle = "\"${key}\""
    match (json.indexOf(needle)) {
        case Some(i) =>
            let afterKey = json[(i + needle.size)..json.size]
            match (afterKey.indexOf("\"")) {
                case Some(q1) =>
                    let valStart = afterKey[(q1 + 1)..afterKey.size]
                    match (valStart.indexOf("\"")) {
                        case Some(q2) => return valStart[0..q2]
                        case None => return ""
                    }
                case None => return ""
            }
        case None => return ""
    }
}

private func jsonEscapeQr(s: String): String {
    var result = ""
    for (ch in s.runes()) {
        if (ch == r'"') {
            result += "\\\""
        } else if (ch == r'\\') {
            result += "\\\\"
        } else {
            result += ch.toString()
        }
    }
    return result
}
