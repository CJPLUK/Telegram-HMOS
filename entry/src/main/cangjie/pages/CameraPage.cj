package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import kit.CameraKit.CameraPosition
import kit.ImageKit.{createImageSource, PixelMap}
import std.math.{sqrt}
import ohos_app_cangjie_entry.services.{
    getCameraService,
    CameraPreviewBridge,
    getPermissionsService,
    PermissionType
}
import ohos_app_cangjie_entry.components.{
    getCameraPreviewPixelMap,
    setCameraPreviewPixelMap,
    clearCameraPreviewPixelMap,
    hasCameraThumbnail,
    getCameraThumbnailPixelMap,
    setCameraThumbnailFromJpeg,
    clearCameraThumbnail
}
import ohos_app_cangjie_entry.router.*

/**
 * CameraPage — 相机拍照/录像界面
 *
 * 对应 iOS Telegram-iOS Camera 模块 (Camera.swift / CameraPreviewView.swift / CameraOutput.swift)
 *
 * 实现内容（P2-072 + P2-073 + P2-078）：
 *
 * P2-072 预览渲染：
 *   - ImageReceiver 帧轮询（100ms 间隔）→ createImageSource(bytes).createPixelMap() →
 *     存入 CameraPreviewHelper 全局变量 → @State previewFrameTick 驱动 Image 组件刷新
 *   - 前置摄像头：水平镜像 scaleX(-1.0) 显示
 *   - 平台限制标注：XComponent 在 Cangjie SDK 6.0 中无绑定，
 *     无法通过 XComponent.onLoad→surfaceId 做硬件直渲染；
 *     当前 ImageReceiver→Image 轮询是唯一可用路径（约 5~15 fps）
 *
 * P2-073 拍照：
 *   - PhotoOutput.capture(PhotoCaptureSetting) 真实拍照
 *   - 前置摄像头自动应用 mirror=true（isFrontCamera 检测）
 *   - 快门动效：按快门时 shutterFlashing=true → 白色全屏遮罩 → 150ms 后自动隐藏
 *   - 拍照后缩略图：读取保存的 JPEG → setCameraThumbnailFromJpeg → 左下角缩略图显示
 *
 * P2-078 相机模式（对应 iOS CameraMode + RecorderMode）：
 *   - photo：普通拍照
 *   - video：录像
 *   - square：方形裁切拍照（预览区显示方形取景框叠加层）
 *   - round：圆形视频消息（录像时显示圆形遮罩，对应 Telegram RoundVideo 核心功能）
 *
 * 导航：NavDestination 根容器（D-002）
 * 路由注册：index.cj pageMap "CameraPage" 分支
 *
 * @State 合规（S-001）：所有 @State 更新均在 launch {} 中
 * 无 dangling @State：所有 @State 字段均有读+写
 */
// ==================== 启动参数 / 结果回调（聊天页圆形视频消息入口）====================
// iOS VideoMessageCameraScreen：前置、进入即录、松手/点停即发送。这里由 ChatRoomPage 在
// routerPush 前设置模式与回调，CameraPage 录完调用回调并 routerPop 回聊天页。
var _cameraLaunchMode: String = ""
var _cameraLaunchFront: Bool = false
var _cameraLaunchAutoStart: Bool = false
var _cameraMediaHandler: Option<(String) -> Unit> = None

public func setCameraLaunchOptions(mode!: String, front!: Bool, autoStart!: Bool): Unit {
    _cameraLaunchMode = mode
    _cameraLaunchFront = front
    _cameraLaunchAutoStart = autoStart
}

public func registerCameraMediaHandler(handler: (String) -> Unit): Unit {
    _cameraMediaHandler = Some(handler)
}

func takeCameraMediaHandler(): Option<(String) -> Unit> {
    let h = _cameraMediaHandler
    _cameraMediaHandler = None
    return h
}

func clearCameraLaunchOptions(): Unit {
    _cameraLaunchMode = ""
    _cameraLaunchFront = false
    _cameraLaunchAutoStart = false
    _cameraMediaHandler = None
}

@HybridComponentEntry
@Component
public class CameraPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var loaded: Bool = false

    // 相机 surfaceId（CameraService.initCamera 返回，非空表示相机就绪）
    @State var surfaceId: String = ""

    // 当前模式：photo / video / square / round（P2-078）
    @State var captureMode: String = "photo"

    // 录像状态
    @State var isRecording: Bool = false

    // 拍照结果路径
    @State var capturedPhotoPath: String = ""

    // 录像结果路径
    @State var capturedVideoPath: String = ""

    // 权限状态
    @State var hasPermission: Bool = false

    // 提示文本
    @State var statusText: String = "Requesting permission..."

    // 是否正在初始化
    @State var isInitializing: Bool = true

    // P2-072：预览帧版本计数器（自增驱动 Image 组件刷新，类比 SoftwareVideoComponent.frameVersion）
    @State var previewFrameTick: Int64 = 0

    // P2-072：预览帧轮询是否运行中（用于 aboutToDisappear 时停止循环）
    @State var previewLoopRunning: Bool = false

    // P2-073：快门白闪动效状态
    @State var shutterFlashing: Bool = false

    // P2-073：快门白闪透明度（0.0=完全透明，1.0=不透明）
    @State var shutterOpacity: Float32 = 0.0

    // P2-073：缩略图刷新计数器（自增时缩略图 Image 重绘）
    @State var capturedThumbnailTick: Int64 = 0

    // P2-075：闪光灯模式 "off" / "on" / "auto" / "always"（手电筒常亮）
    @State var flashMode: String = "off"

    // P2-076：当前变焦比（Float64，1.0=原焦）
    @State var zoomRatio: Float64 = 1.0

    // P2-076：捏合手势起始变焦比（pinch 手势 scale 的基准值）
    @State var pinchBaseZoom: Float64 = 1.0

    // P2-076：变焦范围 [min, max]（从 CameraService.getZoomRatioRange() 获取）
    @State var zoomMin: Float64 = 1.0

    // P2-076：变焦范围最大值
    @State var zoomMax: Float64 = 4.0

    // P2-077：对焦框是否可见
    @State var focusRingVisible: Bool = false

    // P2-077：对焦框在屏幕上的 x 位置（px）
    @State var focusRingX: Float64 = 0.0

    // P2-077：对焦框在屏幕上的 y 位置（px）
    @State var focusRingY: Float64 = 0.0

    // P2-077：曝光补偿值（-4.0 ~ +4.0，步长 0.5）
    @State var exposureBias: Float64 = 0.0

    // P2-077：曝光补偿滑块是否显示
    @State var exposureSliderVisible: Bool = false

    // P2-076：捏合手势上一帧双指距离（用于 onTouch fallback 实现 pinch zoom）
    @State var lastPinchDist: Float64 = 0.0

    // P2-074：录像已用时间（毫秒，每 100ms 由 CameraService.onRecordingDurationUpdate 回调更新）
    @State var recordingDurationMs: Int64 = 0

    // P2-074：录像是否暂停中
    @State var isRecordingPaused: Bool = false

    // P2-079：双摄能力查询结果（0=未查，1=有超广角，2=有长焦）
    @State var dualCameraCapability: Int32 = -1

    // P2-079：慢动作最大帧率（-1=未查，0=不支持高帧率，>0=实际最大 fps）
    @State var maxSlowMoFps: Int32 = -1

    // 媒体捕获完成回调（供父组件接收文件路径）
    public var onMediaCaptured: (String) -> Unit = { _ => }

    // 关闭页面回调
    public var onClose: () -> Unit = { => }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        Hilog.info(0, "CjTelegram", "[CameraPage] ensureLoaded mode=${_cameraLaunchMode} front=${_cameraLaunchFront}")
        if (_cameraLaunchMode.size > 0) {
            this.captureMode = _cameraLaunchMode
        }
        this.requestCameraPermissionAndInit()
    }

    private func onLeave(): Unit {
        Hilog.info(0, "CjTelegram", "[CameraPage] onLeave")
        launch {
            this.previewLoopRunning = false
        }
        clearCameraPreviewPixelMap()
        clearCameraThumbnail()
        getCameraService().releaseCamera()
        clearCameraLaunchOptions()
    }

    /** 圆形视频消息：录完回调给聊天页并退出相机页 */
    private func deliverToLaunchHandler(path: String): Bool {
        match (takeCameraMediaHandler()) {
            case Some(h) =>
                launch {
                    this.previewLoopRunning = false
                    clearCameraPreviewPixelMap()
                    clearCameraThumbnail()
                    getCameraService().releaseCamera()
                    routerPop()
                    h(path)
                }
                return true
            case None => return false
        }
    }

    // 请求 CAMERA 权限后初始化相机
    private func requestCameraPermissionAndInit(): Unit {
        let permSvc = getPermissionsService()
        permSvc.ensurePermission(
            PermissionType.Camera,
            { granted: Bool =>
                launch {
                    if (granted) {
                        this.hasPermission = true
                        this.statusText = "Initializing camera..."
                        this.initCamera()
                    } else {
                        this.hasPermission = false
                        this.isInitializing = false
                        this.statusText = "Camera permission denied"
                    }
                }
            }
        )
    }

    // 初始化 CameraService，绑定回调，相机就绪后启动预览帧轮询
    private func initCamera(): Unit {
        let svc = getCameraService()
        svc.onPhotoSaved = { path: String =>
            launch {
                this.capturedPhotoPath = path
                this.statusText = "Photo saved"
                this.onMediaCaptured(path)
            }
            // P2-073：后台解码缩略图
            let _ = spawn {
                this.loadThumbnailFromPath(path)
            }
        }
        svc.onVideoSaved = { path: String =>
            launch {
                this.capturedVideoPath = path
                this.isRecording = false
                this.statusText = "Video saved"
                this.onMediaCaptured(path)
            }
            let _ = this.deliverToLaunchHandler(path)
        }
        svc.onError = { msg: String =>
            launch {
                this.statusText = "Error: " + msg
                this.isInitializing = false
            }
        }
        let _ = spawn {
            let position = if (_cameraLaunchFront) { CameraPosition.CameraPositionFront } else { CameraPosition.CameraPositionBack }
            // 录像/圆形视频要视频场景会话（拍照场景会话挂不上 VideoOutput）
            let mode = this.captureMode
            svc.preferVideoSession = (mode == "video" || mode == "round")
            // 取景面：XComponent 垫在页面下方，先等它的 surface（≤3 s），拿不到退回 JPEG 轮询预览
            let isSquare = (mode == "round" || mode == "square")
            CameraPreviewBridge.pushLayout(mode == "round", mode == "square")
            let xcSurface = CameraPreviewBridge.waitSurfaceId(3000)
            let hintW: Int64 = if (isSquare) { 480 } else { 1920 }
            let hintH: Int64 = if (isSquare) { 480 } else { 1080 }
            let sid = svc.initCamera(position, xcSurfaceId: xcSurface, hintW: hintW, hintH: hintH)
            // P2-076：查询变焦范围（在相机就绪后）
            let zrange = svc.getZoomRatioRange()
            launch {
                this.surfaceId = sid
                this.isInitializing = false
                if (sid.size > 0) {
                    this.statusText = "Camera ready"
                    // 圆形视频消息：进入即录（iOS 按住即录），点快门停止并发送
                    if (_cameraLaunchAutoStart && this.captureMode == "round" && !this.isRecording) {
                        this.doCapture()
                    }
                    // P2-076：更新变焦范围
                    if (zrange.size >= 2) {
                        let zMin = zrange[0]
                        let zMax = zrange[1]
                        this.zoomMin = zMin
                        this.zoomMax = zMax
                        this.zoomRatio = zMin
                    }
                    // P2-072：启动预览帧轮询循环
                    this.previewLoopRunning = true
                    this.startPreviewLoop()
                    // P2-079：查询双摄/慢动作能力（异步，结果更新 @State）
                    this.queryP2079Capabilities()
                } else {
                    this.statusText = "Camera unavailable"
                }
            }
        }
    }

    // P2-072：后台预览帧轮询循环
    // 每 100ms 从 CameraService.readPreviewFrameBytes() 读取 JPEG 帧，
    // 解码为 PixelMap → setCameraPreviewPixelMap → 自增 previewFrameTick 驱动 UI 刷新。
    private func startPreviewLoop(): Unit {
        let _ = spawn {
            while (this.previewLoopRunning) {
                let frameOpt = getCameraService().readPreviewFrameBytes()
                match (frameOpt) {
                    case Some(bytes) =>
                        let pmOpt = this.decodeJpegToPixelMap(bytes)
                        match (pmOpt) {
                            case Some(pm) =>
                                setCameraPreviewPixelMap(pm)
                                launch {
                                    let next = this.previewFrameTick + 1
                                    this.previewFrameTick = next
                                }
                            case None => ()
                        }
                    case None => ()
                }
                sleep(Duration.millisecond * 100)
            }
        }
    }

    // JPEG 字节 → PixelMap（后台调用，不得在主线程执行）
    private func decodeJpegToPixelMap(bytes: Array<UInt8>): Option<PixelMap> {
        if (bytes.size == 0) {
            return None
        }
        try {
            let src = createImageSource(bytes)
            let pm = src.createPixelMap()
            return Some(pm)
        } catch (e: Exception) {
            return None
        }
    }

    // P2-073：从保存的照片路径读取 JPEG 并解码为缩略图（后台调用）
    private func loadThumbnailFromPath(path: String): Unit {
        try {
            let svc = getCameraService()
            let bytes = svc.readPhotoBytes(path)
            if (bytes.size > 0) {
                setCameraThumbnailFromJpeg(bytes)
                launch {
                    let next = this.capturedThumbnailTick + 1
                    this.capturedThumbnailTick = next
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CameraPage] loadThumbnailFromPath error")
        }
    }

    // P2-075：切换闪光灯模式（off→on→auto→off 循环）
    private func cycleFlashMode(): Unit {
        let next = if (this.flashMode == "off") {
            "on"
        } else if (this.flashMode == "on") {
            "auto"
        } else {
            "off"
        }
        launch {
            this.flashMode = next
        }
        let _ = spawn { getCameraService().setFlashMode(next) }
    }

    // P2-075：切换手电筒（录像时常亮补光）
    private func toggleTorch(): Unit {
        let next = if (this.flashMode == "always") { "off" } else { "always" }
        launch {
            this.flashMode = next
        }
        let active = (next == "always")
        let _ = spawn { getCameraService().setTorchActive(active) }
    }

    // P2-075：获取闪光灯图标文字
    private func flashLabel(): String {
        if (this.flashMode == "on") {
            return "FL:ON"
        } else if (this.flashMode == "auto") {
            return "FL:A"
        } else if (this.flashMode == "always") {
            return "TORCH"
        } else {
            return "FL:OFF"
        }
    }

    // P2-076：统一预览区触摸处理（onTouch fallback，PinchGesture 在 SDK 6.0 未导出）
    // 单指 Down → 点按对焦（P2-077）；双指 Move → 捏合变焦（P2-076）
    // onTouch 本身在 UI 线程，直接写 @State 合规（S-001）
    private func handlePreviewTouch(event: TouchEvent): Unit {
        let tc = event.touches.size
        if (tc >= 2) {
            let t0 = event.touches[0]
            let t1 = event.touches[1]
            let dx = t1.x - t0.x
            let dy = t1.y - t0.y
            let dist = sqrt(dx * dx + dy * dy)
            if (dist < 1.0) { return }
            if (event.eventType == TouchType.Down) {
                this.lastPinchDist = dist
                this.pinchBaseZoom = this.zoomRatio
                return
            }
            if (this.lastPinchDist > 1.0 && event.eventType == TouchType.Move) {
                let scale = dist / this.lastPinchDist
                this.applyPinchZoom(this.pinchBaseZoom * scale)
            }
            this.lastPinchDist = dist
            if (event.eventType == TouchType.Up || event.eventType == TouchType.Cancel) {
                this.lastPinchDist = 0.0
                this.pinchBaseZoom = this.zoomRatio
            }
        } else if (tc == 1 && event.eventType == TouchType.Down) {
            let tx = Float64(event.touches[0].x)
            let ty = Float64(event.touches[0].y)
            let areaW = event.target.getOrThrow().area.width.value
            let areaH = event.target.getOrThrow().area.height.value
            this.onTapFocus(tx, ty, areaW, areaH)
        }
    }

    // P2-076：应用捏合变焦（直接传入目标变焦比，已含基准乘法）
    private func applyPinchZoom(targetRatio: Float64): Unit {
        let minZ = this.zoomMin
        let maxZ = this.zoomMax
        var next = targetRatio
        if (next < minZ) { next = minZ }
        if (next > maxZ) { next = maxZ }
        this.zoomRatio = next
        let zr = next
        let _ = spawn { getCameraService().setZoomRatio(zr) }
    }

    // P2-076：切換档位变焦（1x / 2x / max）
    private func setZoomPreset(ratio: Float64): Unit {
        let minZ = this.zoomMin
        let maxZ = this.zoomMax
        var tmp = ratio
        if (tmp < minZ) { tmp = minZ }
        if (tmp > maxZ) { tmp = maxZ }
        let zr = tmp
        launch {
            this.zoomRatio = zr
            this.pinchBaseZoom = zr
        }
        let _ = spawn { getCameraService().setZoomRatio(zr) }
    }

    // P2-077：点按预览区触发对焦（坐标转换为 0-1 归一化）
    private func onTapFocus(tapX: Float64, tapY: Float64, viewW: Float64, viewH: Float64): Unit {
        let nx = if (viewW > 0.0) { tapX / viewW } else { 0.5 }
        let ny = if (viewH > 0.0) { tapY / viewH } else { 0.5 }
        let fx = if (nx < 0.0) { 0.0 } else if (nx > 1.0) { 1.0 } else { nx }
        let fy = if (ny < 0.0) { 0.0 } else if (ny > 1.0) { 1.0 } else { ny }
        // 同步更新测光点与对焦点
        let _ = spawn {
            getCameraService().setFocusPoint(fx, fy)
            getCameraService().setMeteringPoint(fx, fy)
        }
        // 显示对焦框动画
        launch {
            this.focusRingX = tapX
            this.focusRingY = tapY
            this.focusRingVisible = true
            this.exposureSliderVisible = true
        }
        // 3 秒后自动隐藏对焦框，恢复连续自动对焦
        let _ = spawn {
            sleep(Duration.millisecond * 3000)
            launch {
                this.focusRingVisible = false
                this.exposureSliderVisible = false
            }
            getCameraService().resetAutoFocus()
        }
    }

    // P2-077：调整曝光补偿
    private func adjustExposureBias(bias: Float64): Unit {
        var clamped = bias
        if (clamped < -4.0) { clamped = -4.0 }
        if (clamped > 4.0) { clamped = 4.0 }
        let biasVal = clamped
        launch {
            this.exposureBias = biasVal
        }
        let _ = spawn { getCameraService().setExposureBias(biasVal) }
    }

    // 触发拍照或切换录像
    private func doCapture(): Unit {
        let mode = this.captureMode
        if (mode == "photo" || mode == "square") {
            // P2-073：快门白闪动效
            launch {
                this.shutterFlashing = true
                this.shutterOpacity = 1.0
            }
            this.statusText = "Capturing..."
            let _ = spawn { getCameraService().capturePhoto() }
            // 150ms 后隐藏白闪
            let _ = spawn {
                sleep(Duration.millisecond * 150)
                launch {
                    this.shutterOpacity = 0.0
                    let _ = spawn {
                        sleep(Duration.millisecond * 300)
                        launch {
                            this.shutterFlashing = false
                        }
                    }
                }
            }
        } else if (mode == "video" || mode == "round") {
            if (this.isRecording) {
                // P2-074: 停止真录像（AVRecorder → mp4）
                this.statusText = "Stopping..."
                launch {
                    this.isRecording = false
                    this.recordingDurationMs = 0
                    this.isRecordingPaused = false
                }
                let _ = spawn { getCameraService().stopVideoRecordingReal() }
            } else {
                // P2-074: 启动真录像（AVRecorder via arkinterop）
                getCameraService().videoPreset = if (this.captureMode == "round") { "videomsg" } else { "" }
                this.statusText = "Recording..."
                launch {
                    this.isRecording = true
                    this.recordingDurationMs = 0
                    this.isRecordingPaused = false
                }
                // 注册时长更新回调（S-001：launch{} 更新 @State）
                let roundMode = (this.captureMode == "round")
                getCameraService().onRecordingDurationUpdate = { ms: Int64 =>
                    launch { this.recordingDurationMs = ms }
                    // iOS 圆形视频上限 60 s，到点自动停止并发送
                    if (roundMode && ms >= 60000) {
                        getCameraService().onRecordingDurationUpdate = { _ms: Int64 => }
                        launch {
                            if (this.isRecording) { this.doCapture() }
                        }
                    }
                }
                // 注册录像保存回调
                getCameraService().onVideoSaved = { path: String =>
                    launch { this.capturedVideoPath = path }
                    this.onMediaCaptured(path)
                    // 圆形视频消息入口：交回聊天页并退出（此处的重新赋值会覆盖 initCamera 里的那份）
                    let _ = this.deliverToLaunchHandler(path)
                }
                let _ = spawn { getCameraService().startVideoRecordingReal() }
            }
        }
    }

    // P2-074：暂停/恢复录像
    private func doPauseResumeRecording(): Unit {
        if (!this.isRecording) { return }
        let svc = getCameraService()
        if (this.isRecordingPaused) {
            svc.resumeVideoRecording()
            launch { this.isRecordingPaused = false }
        } else {
            svc.pauseVideoRecording()
            launch { this.isRecordingPaused = true }
        }
    }

    // P2-079：查询双摄和慢动作能力（在 initCamera 后调用）
    private func queryP2079Capabilities(): Unit {
        let _ = spawn {
            let svc = getCameraService()
            let dualResult = svc.queryDualCameraSupport()
            let slowResult = svc.querySlowMotionSupport()
            launch {
                this.dualCameraCapability = dualResult[2]
                this.maxSlowMoFps = slowResult[0]
            }
        }
    }

    // 切换前后置摄像头
    private func doSwitchCamera(): Unit {
        if (this.isRecording) { return }
        this.statusText = "Switching camera..."
        launch {
            this.isInitializing = true
            this.previewLoopRunning = false
        }
        clearCameraPreviewPixelMap()
        let _ = spawn {
            let svc = getCameraService()
            let sid = svc.switchCamera()
            let zrange = svc.getZoomRatioRange()
            launch {
                this.surfaceId = sid
                this.isInitializing = false
                this.statusText = if (sid.size > 0) { "Camera ready" } else { "Switch failed" }
                if (sid.size > 0) {
                    // P2-076：切换后重置变焦范围和当前比例
                    if (zrange.size >= 2) {
                        let zMin = zrange[0]
                        let zMax = zrange[1]
                        this.zoomMin = zMin
                        this.zoomMax = zMax
                        this.zoomRatio = zMin
                        this.pinchBaseZoom = zMin
                    }
                    // P2-075：重置闪光灯
                    this.flashMode = "off"
                    this.previewLoopRunning = true
                    this.startPreviewLoop()
                }
            }
        }
    }

    // P2-078：切换到指定模式
    private func selectMode(mode: String): Unit {
        if (this.isRecording) { return }
        launch {
            this.captureMode = mode
        }
        CameraPreviewBridge.pushLayout(mode == "round", mode == "square")
        // 切到录像/圆形视频而当前是拍照场景会话 → 重建为视频场景会话（反之不必：视频会话也能拍照）
        let needsVideo = (mode == "video" || mode == "round")
        let svc = getCameraService()
        if (needsVideo && !svc.sessionIsVideo && this.surfaceId.size > 0) {
            svc.preferVideoSession = true
            launch {
                this.previewLoopRunning = false
                this.isInitializing = true
                this.statusText = "Switching to video session..."
            }
            let _ = spawn {
                svc.releaseCamera()
                launch { this.initCamera() }
            }
        }
        let label = if (mode == "photo") {
            "Photo mode"
        } else if (mode == "video") {
            "Video mode"
        } else if (mode == "square") {
            "Square mode"
        } else {
            "Round video mode"
        }
        this.statusText = label
    }

    // 获取快门/录像按钮图标文字
    private func getShutterLabel(): String {
        let mode = this.captureMode
        if (mode == "photo" || mode == "square") {
            return "O"
        }
        if (this.isRecording) {
            return "STOP"
        }
        return "REC"
    }

    // 快门按钮是否为录像停止状态
    private func isStopRecording(): Bool {
        let mode = this.captureMode
        return (mode == "video" || mode == "round") && this.isRecording
    }

    // 当前是否前置摄像头（P2-072：镜像翻转判断）
    private func isCurrentFrontCamera(): Bool {
        return getCameraService().isFrontCamera()
    }

    // ─────────────────── build() ────────────────────────────────────

    public func build() {
        Stack() {

                // ========== 相机预览层（P2-072）==========
                this.buildPreviewLayer()

                // ========== 快门白闪动效层（P2-073）==========
                if (this.shutterFlashing) {
                    this.buildShutterFlash()
                }

                // ========== P2-077 对焦框动画层 ==========
                if (this.focusRingVisible) {
                    this.buildFocusRing()
                }

                // ========== 控制叠加层 ==========
                this.buildControlsLayer()

        }
        .width(100.percent)
        .height(100.percent)
        // 透明：取景 XComponent 在 ArkTS 壳里垫在本页下方。必须 Color.Transparent——
        // 数值 0x00000000 会被 ArkUI 补成 #FF000000（VideoCallScreen.cj:1123 实锤）
        .backgroundColor(Color.Transparent)
        .onAppear({ => this.ensureLoaded() })
        .onDisAppear({ => this.onLeave() })
    }

    // P2-072：预览区（相机帧 Image / 加载中 / 无权限 / 不可用）
    @Builder
    func buildPreviewLayer() {
        if (this.isInitializing) {
            Column {
                LoadingProgress()
                    .width(48)
                    .height(48)
                    .color(0xFFFFFF)
                Text("Initializing Camera...")
                    .fontSize(16)
                    .fontColor(0xFFFFFF)
                    .margin(top: 12)
            }
            .width(100.percent)
            .height(100.percent)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor(0x1A1A1A)
        } else if (!this.hasPermission) {
            Column {
                Text("Camera permission required")
                    .fontSize(18)
                    .fontColor(0xFFFFFF)
                Text("Please grant camera access in system settings.")
                    .fontSize(14)
                    .fontColor(0xAAAAAA)
                    .margin(top: 8)
            }
            .width(100.percent)
            .height(100.percent)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor(0x1A1A1A)
        } else if (this.surfaceId.size == 0) {
            Column {
                Text("Camera unavailable")
                    .fontSize(18)
                    .fontColor(0xFFFFFF)
            }
            .width(100.percent)
            .height(100.percent)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor(0x1A1A1A)
        } else {
            // 相机已就绪：显示从 ImageReceiver 轮询得到的实时预览帧
            // previewFrameTick 变化时 Image 组件重新获取 getCameraPreviewPixelMap() 渲染新帧
            Stack() {
                // 取景由 CameraPage.ets 壳的 XComponent 直渲（垫在本页下方，此处透明透出）；
                // 只有拿不到 XComponent surface 时才回退到 ImageReceiver 轮询帧
                if (this.previewFrameTick > 0) {
                    Image(getCameraPreviewPixelMap())
                        .width(100.percent)
                        .height(100.percent)
                        .objectFit(ImageFit.Cover)
                        .scale(
                            x: if (this.isCurrentFrontCamera()) { Float32(-1.0) } else { Float32(1.0) },
                            y: Float32(1.0)
                        )
                }

                // P2-078 square 模式：方形取景框叠加
                if (this.captureMode == "square") {
                    this.buildSquareOverlay()
                }

                // P2-078 round 模式：圆形遮罩叠加
                if (this.captureMode == "round") {
                    this.buildRoundOverlay()
                }
            }
            .width(100.percent)
            .height(100.percent)
            .onTouch({ event: TouchEvent =>
                this.handlePreviewTouch(event)
            })
        }
    }

    // P2-073：快门白闪遮罩（白色全屏，shutterOpacity 驱动淡入/淡出）
    @Builder
    func buildShutterFlash() {
        Column {}
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFFFFFFFF)
            .opacity(Float64(this.shutterOpacity))
    }

    // P2-078 square 模式取景框叠加（四角标记的方形框）
    @Builder
    func buildSquareOverlay() {
        Stack(alignContent: Alignment.Center) {
            // 半透明暗色遮挡（上下区域）
            Column {
                Column {}
                    .width(100.percent)
                    .height(50)
                    .backgroundColor(0xAA000000)
                Blank()
                Column {}
                    .width(100.percent)
                    .height(50)
                    .backgroundColor(0xAA000000)
            }
            .width(100.percent)
            .height(100.percent)

            // 方形取景框边角线
            Stack(alignContent: Alignment.TopStart) {
                // 左上角
                Row {
                    Column {}
                        .width(24)
                        .height(3)
                        .backgroundColor(0xFFFFFFFF)
                }
                .alignItems(VerticalAlign.Top)

                // 方形框轮廓（仅边框，内部透明）
                Column {}
                    .width(280)
                    .height(280)
                    .border(width: 2, color: 0xFFFFFFFF, style: BorderStyle.Solid)
                    .borderRadius(4)
            }
            .width(280)
            .height(280)
        }
        .width(100.percent)
        .height(100.percent)
    }

    // P2-078 round 模式圆形遮罩（圆形显示区 + 圆外半透明黑色遮罩）
    @Builder
    func buildRoundOverlay() {
        Stack(alignContent: Alignment.Center) {
            // 圆形以外区域半透明遮罩
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0xAA000000)

            // 圆形取景框（透明内部 + 白色边框）
            Circle()
                .width(300)
                .height(300)
                .fill(Color.Transparent)
                .stroke(0xFFFFFFFF)
                .strokeWidth(2)

            // 录像中：红色录像状态圆点
            if (this.isRecording) {
                Stack(alignContent: Alignment.TopEnd) {
                    Column {}
                        .width(300)
                        .height(300)
                    Circle()
                        .width(16)
                        .height(16)
                        .fill(0xFFFF3B30)
                        .margin(top: 8, right: 8)
                }
                .width(300)
                .height(300)
            }
        }
        .width(100.percent)
        .height(100.percent)
    }

    // P2-077：对焦框动画（黄色方框 + 对焦指示）
    // 注意：对焦框叠加在全屏 Stack 上，通过绝对定位偏移到点击位置
    @Builder
    func buildFocusRing() {
        Stack(alignContent: Alignment.TopStart) {
            Column {}
                .width(80)
                .height(80)
                .border(width: 2, color: 0xFFFFCC00, style: BorderStyle.Solid)
                .borderRadius(4)
                .offset(x: Int64(this.focusRingX) - 40, y: Int64(this.focusRingY) - 40)
        }
        .width(100.percent)
        .height(100.percent)
    }

    // 控制叠加层（顶部工具栏 + 变焦控制 + 曝光滑块 + 底部模式选择 + 底部控制区）
    @Builder
    func buildControlsLayer() {
        Column {
            // ── 顶部工具栏 ──
            Row {
                Button("X")
                    .fontSize(16)
                    .fontColor(0xFFFFFF)
                    .backgroundColor(0x66000000)
                    .borderRadius(20)
                    .width(40)
                    .height(40)
                    .onClick({ _ =>
                        launch {
                            this.previewLoopRunning = false
                        }
                        clearCameraPreviewPixelMap()
                        getCameraService().releaseCamera()
                        routerPop()
                        this.onClose()
                    })

                Blank()

                // P2-075：闪光灯/手电筒按钮
                Button(this.flashLabel())
                    .fontSize(12)
                    .fontColor(if (this.flashMode == "off") { 0xAAFFFFFF } else { 0xFFFFCC00 })
                    .backgroundColor(0x66000000)
                    .borderRadius(20)
                    .padding(left: 10, right: 10, top: 6, bottom: 6)
                    .margin(right: 8)
                    .onClick({ _ =>
                        let mode = this.captureMode
                        if (mode == "video" || mode == "round") {
                            this.toggleTorch()
                        } else {
                            this.cycleFlashMode()
                        }
                    })

                // 前/后置切换
                Button(trSource("Flip"))
                    .fontSize(14)
                    .fontColor(0xFFFFFF)
                    .backgroundColor(0x66000000)
                    .borderRadius(20)
                    .padding(left: 12, right: 12, top: 6, bottom: 6)
                    .onClick({ _ => this.doSwitchCamera() })
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 16, bottom: 8)

            // P2-076：变焦档位按钮（1x / 2x + 当前比例显示）
            this.buildZoomControls()

            // P2-077：曝光补偿滑块（点按对焦后显示）
            if (this.exposureSliderVisible) {
                this.buildExposureSlider()
            }

            Blank()

            // ── 状态文本 ──
            if (this.statusText.size > 0) {
                Text(this.statusText)
                    .fontSize(13)
                    .fontColor(0xFFFFFF)
                    .backgroundColor(0x66000000)
                    .padding(left: 12, right: 12, top: 6, bottom: 6)
                    .borderRadius(8)
                    .margin(bottom: 4)
            }

            // ── P2-079 双摄/慢动作能力信息（诚实标注，dualCameraCapability/maxSlowMoFps 读取）──
            if (this.dualCameraCapability >= 0 || this.maxSlowMoFps >= 0) {
                Text(this.buildCapabilityLabel())
                    .fontSize(11)
                    .fontColor(0xAAFFFFFF)
                    .backgroundColor(0x44000000)
                    .padding(left: 8, right: 8, top: 3, bottom: 3)
                    .borderRadius(4)
                    .margin(bottom: 4)
            }

            // ── 拍照结果路径（P2-073，@State read 保持 non-dangling）──
            if (this.capturedPhotoPath.size > 0) {
                Text(this.capturedPhotoPath)
                    .fontSize(10)
                    .fontColor(0x88FF88)
                    .backgroundColor(0x44000000)
                    .padding(left: 8, right: 8, top: 4, bottom: 4)
                    .borderRadius(4)
                    .margin(bottom: 4)
                    .maxLines(1)
            }
            if (this.capturedVideoPath.size > 0) {
                Text(this.capturedVideoPath)
                    .fontSize(10)
                    .fontColor(0x8888FF)
                    .backgroundColor(0x44000000)
                    .padding(left: 8, right: 8, top: 4, bottom: 4)
                    .borderRadius(4)
                    .margin(bottom: 4)
                    .maxLines(1)
            }

            // ── P2-074 录像时长 + 暂停/恢复 ──
            if (this.isRecording) {
                this.buildDurationBar()
            }

            // ── P2-078 模式选择条 ──
            this.buildModeSelector()

            // ── 底部控制区 ──
            this.buildBottomControls()
        }
        .width(100.percent)
        .height(100.percent)
    }

    // P2-076：变焦档位按钮（1x / 2x / max）+ 当前变焦比数值
    @Builder
    func buildZoomControls() {
        if (this.surfaceId.size > 0 && !this.isInitializing) {
            Row {
                // 1x 档
                Button("1x")
                    .fontSize(13)
                    .fontColor(if (this.zoomRatio < 1.5) { 0xFFFFCC00 } else { 0xAAFFFFFF })
                    .backgroundColor(if (this.zoomRatio < 1.5) { 0x44FFCC00 } else { 0x44000000 })
                    .borderRadius(16)
                    .padding(left: 10, right: 10, top: 4, bottom: 4)
                    .onClick({ _ => this.setZoomPreset(1.0) })

                // 2x 档
                Button("2x")
                    .fontSize(13)
                    .fontColor(if (this.zoomRatio >= 1.5 && this.zoomRatio < 3.0) { 0xFFFFCC00 } else { 0xAAFFFFFF })
                    .backgroundColor(if (this.zoomRatio >= 1.5 && this.zoomRatio < 3.0) { 0x44FFCC00 } else { 0x44000000 })
                    .borderRadius(16)
                    .padding(left: 10, right: 10, top: 4, bottom: 4)
                    .margin(left: 8)
                    .onClick({ _ => this.setZoomPreset(2.0) })

                // 当前变焦比（格式：1.0x）
                Text(this.zoomRatioLabel())
                    .fontSize(13)
                    .fontColor(0xFFFFFFFF)
                    .backgroundColor(0x44000000)
                    .borderRadius(12)
                    .padding(left: 8, right: 8, top: 4, bottom: 4)
                    .margin(left: 12)
            }
            .padding(left: 16, bottom: 4)
        }
    }

    // P2-076：变焦比显示文字（保留一位小数 + "x"）
    private func zoomRatioLabel(): String {
        let v = this.zoomRatio
        let intPart = Int64(v)
        let fracPart = Int64((v - Float64(intPart)) * 10.0)
        return intPart.toString() + "." + fracPart.toString() + "x"
    }

    // P2-077：曝光补偿滑块（点按对焦后显示，+/- 按钮手动调节）
    @Builder
    func buildExposureSlider() {
        Row {
            Text("EV")
                .fontSize(11)
                .fontColor(0xFFFFCC00)
                .margin(right: 6)

            // 减少曝光
            Button("-")
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor(0xFFFFFFFF)
                .backgroundColor(0x44000000)
                .borderRadius(16)
                .width(32)
                .height(32)
                .onClick({ _ => this.adjustExposureBias(this.exposureBias - 0.5) })

            Text(this.exposureBiasLabel())
                .fontSize(13)
                .fontColor(0xFFFFCC00)
                .backgroundColor(0x44000000)
                .borderRadius(8)
                .padding(left: 8, right: 8, top: 3, bottom: 3)
                .margin(left: 4, right: 4)

            // 增加曝光
            Button("+")
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor(0xFFFFFFFF)
                .backgroundColor(0x44000000)
                .borderRadius(16)
                .width(32)
                .height(32)
                .onClick({ _ => this.adjustExposureBias(this.exposureBias + 0.5) })
        }
        .padding(left: 16, bottom: 4)
    }

    // P2-077：曝光补偿显示（+1.5 / -0.5 格式）
    private func exposureBiasLabel(): String {
        let v = this.exposureBias
        if (v >= 0.0) {
            let intPart = Int64(v)
            let fracPart = Int64((v - Float64(intPart)) * 10.0)
            return "+" + intPart.toString() + "." + fracPart.toString()
        } else {
            let abs_v = -v
            let intPart = Int64(abs_v)
            let fracPart = Int64((abs_v - Float64(intPart)) * 10.0)
            return "-" + intPart.toString() + "." + fracPart.toString()
        }
    }

    // P2-078：四模式选择条（photo / video / square / round）
    // 注意：@Builder func 不能带参数（D-115），各模式 Tab 直接内联（S-005 build 内无 let/var）
    @Builder
    func buildModeSelector() {
        Row {
            // Photo tab
            Text(trSource("PHOTO"))
                .fontSize(12)
                .fontColor(if (this.captureMode == "photo") { 0xFFFF9500 } else { 0xAAFFFFFF })
                .fontWeight(if (this.captureMode == "photo") { FontWeight.Bold } else { FontWeight.Normal })
                .padding(left: 10, right: 10, top: 6, bottom: 6)
                .borderRadius(12)
                .backgroundColor(if (this.captureMode == "photo") { 0x33FF9500 } else { Color.Transparent })
                .onClick({ _ =>
                    if (!this.isRecording) { this.selectMode("photo") }
                })
            // Video tab
            Text(trSource("VIDEO"))
                .fontSize(12)
                .fontColor(if (this.captureMode == "video") { 0xFFFF9500 } else { 0xAAFFFFFF })
                .fontWeight(if (this.captureMode == "video") { FontWeight.Bold } else { FontWeight.Normal })
                .padding(left: 10, right: 10, top: 6, bottom: 6)
                .borderRadius(12)
                .backgroundColor(if (this.captureMode == "video") { 0x33FF9500 } else { Color.Transparent })
                .onClick({ _ =>
                    if (!this.isRecording) { this.selectMode("video") }
                })
            // Square tab
            Text(trSource("SQUARE"))
                .fontSize(12)
                .fontColor(if (this.captureMode == "square") { 0xFFFF9500 } else { 0xAAFFFFFF })
                .fontWeight(if (this.captureMode == "square") { FontWeight.Bold } else { FontWeight.Normal })
                .padding(left: 10, right: 10, top: 6, bottom: 6)
                .borderRadius(12)
                .backgroundColor(if (this.captureMode == "square") { 0x33FF9500 } else { Color.Transparent })
                .onClick({ _ =>
                    if (!this.isRecording) { this.selectMode("square") }
                })
            // Round tab
            Text("ROUND")
                .fontSize(12)
                .fontColor(if (this.captureMode == "round") { 0xFFFF9500 } else { 0xAAFFFFFF })
                .fontWeight(if (this.captureMode == "round") { FontWeight.Bold } else { FontWeight.Normal })
                .padding(left: 10, right: 10, top: 6, bottom: 6)
                .borderRadius(12)
                .backgroundColor(if (this.captureMode == "round") { 0x33FF9500 } else { Color.Transparent })
                .onClick({ _ =>
                    if (!this.isRecording) { this.selectMode("round") }
                })
        }
        .width(100.percent)
        .justifyContent(FlexAlign.SpaceEvenly)
        .padding(bottom: 12)
    }

    // P2-074：录像时长 + 暂停/恢复 条（仅录像时显示）
    // 注意：@Builder 不能有 let/var（D-116），通过 recordingDurationMs 直接计算
    @Builder
    func buildDurationBar() {
        Row {
            // 录制指示灯（红色闪烁用 isRecordingPaused 区分）
            Text(if (this.isRecordingPaused) { "||" } else { "⦿" })
                .fontSize(14)
                .fontColor(if (this.isRecordingPaused) { 0xFFAAAAAA } else { 0xFFFF3B30 })
                .margin(right: 8)

            // 时长显示 mm:ss
            Text(this.formatDuration(this.recordingDurationMs))
                .fontSize(16)
                .fontColor(0xFFFFFFFF)
                .fontWeight(FontWeight.Bold)
                .margin(right: 12)

            // 暂停/恢复按钮（P2-074：iOS VideoRecorder pauseRecording/resumeRecording）
            Button(if (this.isRecordingPaused) { "Resume" } else { "Pause" })
                .fontSize(13)
                .fontColor(0xFFFFFFFF)
                .backgroundColor(0x66000000)
                .borderRadius(16)
                .padding(left: 12, right: 12, top: 5, bottom: 5)
                .onClick({ _ => this.doPauseResumeRecording() })
        }
        .width(100.percent)
        .padding(left: 24, right: 24, top: 4, bottom: 4)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
    }

    @Builder
    func buildBottomControls() {
        Row {
            // P2-073：左侧缩略图（上次拍照结果）
            this.buildThumbnailArea()

            Blank()

            // 快门/录像按钮
            Button(this.getShutterLabel())
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor(if (this.isStopRecording()) { 0xFFFFFFFF } else { 0xFF000000 })
                .width(76)
                .height(76)
                .borderRadius(38)
                .backgroundColor(if (this.isStopRecording()) { 0xFFFF3B30 } else { 0xFFFFFFFF })
                .border(width: 4, color: 0xFFFFFFFF, style: BorderStyle.Solid)
                .enabled(this.hasPermission && !this.isInitializing)
                .onClick({ _ => this.doCapture() })

            Blank()

            // 右侧占位（均衡布局）
            Column {}
                .width(72)
                .height(72)
        }
        .width(100.percent)
        .padding(left: 24, right: 24, bottom: 48, top: 8)
        .alignItems(VerticalAlign.Center)
    }

    // P2-079：双摄/慢动作能力标签（在 Text() 中展示，诚实标注 Camera Kit 能力）
    private func buildCapabilityLabel(): String {
        let dualStr = if (this.dualCameraCapability > 1) {
            "Dual-camera: " + this.dualCameraCapability.toString() + " lenses"
        } else {
            "Dual-camera: N-A"
        }
        let slowStr = if (this.maxSlowMoFps >= 120) {
            "SlowMo: " + this.maxSlowMoFps.toString() + "fps"
        } else {
            "SlowMo: N-A (" + this.maxSlowMoFps.toString() + "fps max)"
        }
        return dualStr + "  " + slowStr
    }

    // P2-074：将毫秒时长转换为 MM:SS 显示字符串
    // 注意：不可在 @Builder 中调用（D-116 禁止 let/var in build），必须在普通方法中调用
    private func formatDuration(ms: Int64): String {
        let totalSec = ms / 1000
        let minutes = totalSec / 60
        let seconds = totalSec - minutes * 60
        let minStr = if (minutes < 10) { "0" + minutes.toString() } else { minutes.toString() }
        let secStr = if (seconds < 10) { "0" + seconds.toString() } else { seconds.toString() }
        return minStr + ":" + secStr
    }

    // P2-073：拍照缩略图区（左下角）
    // 注意：@Builder 不能有 let/var（S-005/D-116），通过 hasCameraThumbnail()/getCameraThumbnailPixelMap() 访问
    @Builder
    func buildThumbnailArea() {
        if (this.capturedThumbnailTick > 0 && hasCameraThumbnail()) {
            Image(getCameraThumbnailPixelMap())
                .width(60)
                .height(60)
                .borderRadius(8)
                .objectFit(ImageFit.Cover)
                .border(width: 2, color: 0xFFFFFFFF, style: BorderStyle.Solid)
        } else {
            Column {}
                .width(60)
                .height(60)
        }
    }
}
