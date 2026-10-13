package ohos_app_cangjie_entry.services

import kit.CameraKit.*
import kit.CameraKit.Point as CameraPoint
import kit.ImageKit.createImageReceiver
import kit.ImageKit.ImageReceiver
import kit.ImageKit.ReceiveType
import kit.ImageKit.Size as ImageSize
import kit.ImageKit.ImageFormat
import kit.ImageKit.ComponentType
import kit.PerformanceAnalysisKit.Hilog
import kit.AbilityKit.UIAbilityContext
import kit.CoreFileKit.*
import ohos.business_exception.BusinessException
import ohos.callback_invoke.Callback0Argument
import std.time.DateTime
import ohos_app_cangjie_entry.core.mtproto.TLObject
import ohos_app_cangjie_entry.interop.*

// P2-072: 相机模式枚举 (photo / video / square / round)
public enum CameraMode {
    | Photo
    | Video
    | Square
    | Round

    public func ordinal(): Int32 {
        match (this) {
            case Photo => 0
            case Video => 1
            case Square => 2
            case Round => 3
        }
    }

    public operator func ==(right: CameraMode): Bool {
        return this.ordinal() == right.ordinal()
    }

    public operator func !=(right: CameraMode): Bool {
        return this.ordinal() != right.ordinal()
    }
}

/**
 * CameraService — 鸿蒙相机拍照/录像服务
 *
 * 封装 HarmonyOS Camera Kit（import kit.CameraKit.*）：
 * - 预览：getCameraManager → createPreviewOutput(previewProfiles[0], previewSurfaceId)
 * - 拍照：
 *     1. 建立独立 photoReceiver（大尺寸 ImageReceiver，capacity=1）
 *     2. 为 photoReceiver 创建第二路 PreviewOutput（photoPreviewOut，使用 previewProfiles[0]）
 *        并添加到 session，使相机同时向 photoReceiver 推送帧
 *     3. 注册 photoReceiver.on(ImageArrival, _photoArrivalCb)
 *     4. capturePhotoWithMirror() 设 pendingPhotoCapture=true → pOut.capture(setting)
 *     5. 快门触发后 photoReceiver 收到新帧 → _photoArrivalCb 被调用
 *     6. 在回调里读 photoReceiver.readLatestImage()，保存为 JPEG，触发 onPhotoSaved
 *
 * 权限：ohos.permission.CAMERA（module.json5 已声明）
 * 在页面初始化时通过 PermissionsService.ensurePermission(Camera, ...) 请求。
 *
 * 调用链：
 *   CameraService.initCamera(position)
 *     → getCameraManager(ctx)
 *     → getSupportedCameras() → getSupportedSceneModes() → createSession(mode)
 *     → createCameraInput(position, type) → open()
 *     → createPreviewOutput(previewProfile, previewSurfaceId)   [live preview]
 *     → createPreviewOutput(previewProfile, photoSurfaceId)     [photo capture surface]
 *     → createPhotoOutput(profile)                              [trigger capture]
 *     → session.beginConfig → addInput → addOutput(×3) → commitConfig → start
 *     → photoReceiver.on(ImageArrival, _photoArrivalCb)
 *   CameraService.capturePhoto() / capturePhotoWithMirror(mirror)
 *     → pendingPhotoCapture = true
 *     → pOut.capture(setting)
 *     ← _photoArrivalCb.invoke() (async, when frame arrives in photoReceiver)
 *     → readLatestImage() → saveToFile → onPhotoSaved(path)
 *   CameraService.startVideoRecording()
 *     → createVideoOutput(profile, surfaceId)
 *     → session reconfigure → videoOutput.start → onVideoSaved(path) on stop
 *   CameraService.uploadPhoto(path) / uploadVideo(path)
 *     → getFileUploadService().uploadFile(data, fileName)
 */

private var _cameraServiceInstance: Option<CameraService> = None

public func getCameraService(): CameraService {
    match (_cameraServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = CameraService()
            _cameraServiceInstance = Some(inst)
            return inst
    }
}

/**
 * PhotoArrivalCb — ImageReceiver.on(ImageArrival, ...) 的回调实现。
 *
 * 持有 CameraService 弱引用（直接持 CameraService 实例以在回调中操作 pendingPhotoCapture）。
 * 当 photoReceiver 收到新帧时触发：若 pendingPhotoCapture==true 则消费该帧保存到文件。
 */
class PhotoArrivalCb <: Callback0Argument {
    private var _service: CameraService

    public init(service: CameraService) {
        this._service = service
    }

    public override func invoke(err: ?BusinessException): Unit {
        this._service.onPhotoReceiverImageArrived()
    }
}

public class CameraService {

    // 当前相机位置（前置/后置）
    private var currentPosition: CameraPosition = CameraPosition.CameraPositionBack
    /** 录像预设："" 普通录像（1280×720，videoProfiles[0]）/ "videomsg" 圆形视频消息（近方形小档、相机方向旋转） */
    public var videoPreset: String = ""
    private var pendingVideoProfileIndex: Int64 = 0
    /**
     * 建会话时用视频场景（getSupportedSceneModes()[1]，与 doAttachVideoOutputAndStart 取 videoProfiles
     * 的场景一致）。此前一律用 modes[0]（拍照场景）建会话，再 addOutput(VideoOutput) 时
     * "Camera service fatal error"（真机 2026-09-11），录像从未真正跑通。
     */
    public var preferVideoSession: Bool = false
    public var sessionIsVideo: Bool = false

    // Camera Kit 核心对象
    private var cameraInput: Option<CameraInput> = None
    private var photoOutput: Option<PhotoOutput> = None
    private var videoOutput: Option<VideoOutput> = None
    private var previewOutput: Option<PreviewOutput> = None
    private var photoPreviewOut: Option<PreviewOutput> = None
    private var captureSession: Option<Session> = None

    // previewReceiver：用于 live preview 帧轮询（readPreviewFrameBytes），不再用于拍照
    private var previewReceiver: Option<ImageReceiver> = None

    // photoReceiver：专用于拍照成片（P2-073 修复：独立 ImageReceiver，不与预览共享）
    // 通过第二路 PreviewOutput 接收与快门同步的帧
    private var photoReceiver: Option<ImageReceiver> = None

    // photoArrivalCb：持有 Callback0Argument 实例以便 off() 时释放
    private var photoArrivalCb: Option<PhotoArrivalCb> = None

    // 拍照待处理标志：capturePhotoWithMirror 设 true → photoArrivalCb 消费一帧后重置
    var pendingPhotoCapture: Bool = false

    // 视频用 ImageReceiver
    private var videoReceiver: Option<ImageReceiver> = None

    // 录像状态
    private var isRecording: Bool = false

    // P2-074：录像暂停状态
    private var isPausedRecording: Bool = false

    // P2-074：录像已用时间（毫秒，spawn loop 累积）
    var recordingElapsedMs: Int64 = 0

    // P2-074：AVRecorder 通过 ArkTS 反转桥接获取的 surfaceId（真 mp4 录像）
    // AVRecorder 实例本体现由 ArkTS 侧 (CameraImpl.ets) 持有（模块级），仓颉只经
    // callArkAsync(CAMERA_REC_*) 驱动其离散操作 (prepare/start/pause/resume/stop)。
    private var avRecorderSurfaceId: String = ""

    // P2-074：AVRecorder 是否处于活动状态（ArkTS 侧持有实例，本侧仅记录活动标志）
    private var avRecorderActive: Bool = false

    // 照片保存目录（files/photos/）
    private var photosDir: String = ""

    // 视频保存目录（files/videos/）
    private var videosDir: String = ""

    // 当前录像文件路径（stop 时回调用）
    private var currentVideoPath: String = ""

    // 回调：拍照保存完成后返回本地文件路径
    public var onPhotoSaved: (String) -> Unit = { _ => }

    // 回调：录像停止后返回本地文件路径
    public var onVideoSaved: (String) -> Unit = { _ => }

    // 回调：发生错误时返回描述文本
    public var onError: (String) -> Unit = { _ => }

    // 回调：录像时长更新（毫秒）
    public var onRecordingDurationUpdate: (Int64) -> Unit = { _ => }

    /**
     * 初始化相机管理器，配置预览会话。
     * 返回 surfaceId，由调用方（CameraPage）传给 XComponent 绑定预览流。
     * position: CameraPositionBack / CameraPositionFront
     */
    public func initCamera(position: CameraPosition, xcSurfaceId!: String = "",
                           hintW!: Int64 = 0, hintH!: Int64 = 0): String {
        Hilog.info(0, "CjTelegram", "[CameraService] initCamera surface=${xcSurfaceId.size > 0} hint=${hintW}x${hintH}")
        this.currentPosition = position
        this.ensureDirectories()

        match (getGlobalAbilityContext()) {
            case None =>
                Hilog.info(0, "CjTelegram", "[CameraService] No UIAbilityContext")
                this.onError("No context")
                return ""
            case Some(ctx) =>
                return this.doInitCamera(ctx, xcSurfaceId, hintW, hintH)
        }
    }

    private func doInitCamera(ctx: UIAbilityContext, xcSurfaceId: String, hintW: Int64, hintH: Int64): String {
        try {
            let mgr = getCameraManager(ctx)

            // 枚举设备，选择目标位置
            let devices = mgr.getSupportedCameras()
            if (devices.size == 0) {
                Hilog.info(0, "CjTelegram", "[CameraService] no devices")
                this.onError("No camera")
                return ""
            }
            var chosenDevice: CameraDevice = devices[0]
            for (i in 0..devices.size) {
                let dev = devices[i]
                if (dev.cameraPosition == this.currentPosition) {
                    chosenDevice = dev
                }
            }

            // 获取 SceneMode（首选 index 0）
            let modes = mgr.getSupportedSceneModes(chosenDevice)
            if (modes.size == 0) {
                Hilog.info(0, "CjTelegram", "[CameraService] no scene modes")
                this.onError("No scene modes")
                return ""
            }
            let useVideo = this.preferVideoSession && modes.size > 1
            let mode = if (useVideo) { modes[1] } else { modes[0] }
            this.sessionIsVideo = useVideo
            Hilog.info(0, "CjTelegram", "[CameraService] scene modes=${modes.size}, videoSession=${useVideo}")
            let capability = mgr.getSupportedOutputCapability(chosenDevice, mode)

            // ── 预览 surface：优先 XComponent（CameraPreviewBridge，直渲）；没有时退回
            //    ImageReceiver JPEG 轮询（视频场景会话下解不出帧，仅作兜底）──
            var previewSurfaceIdLocal = xcSurfaceId
            if (previewSurfaceIdLocal.size == 0) {
                let previewSize = ImageSize(1920, 1080)
                let previewRec = createImageReceiver(previewSize, ImageFormat.Jpeg, 8)
                this.previewReceiver = Some(previewRec)
                previewSurfaceIdLocal = previewRec.getReceivingSurfaceId()
            } else {
                this.previewReceiver = None
            }
            let previewSurfaceId = previewSurfaceIdLocal

            // ── 拍照专用 ImageReceiver（P2-073 修复：独立 surface，不从预览读照片）──
            // 使用与预览相同尺寸（1920×1080），capacity=1（每次快门最多消费一帧）
            // photoReceiver 通过第二路 PreviewOutput 接收相机帧；
            // createPhotoOutput 在 Cangjie SDK 6.0 无 surfaceId 重载（KB 确认），
            // 因此采用独立 PreviewOutput 作为拍照专用 surface 的接线方式。
            let photoSize = ImageSize(1920, 1080)
            let photoRec = createImageReceiver(photoSize, ImageFormat.Jpeg, 1)
            this.photoReceiver = Some(photoRec)
            let photoSurfaceId = photoRec.getReceivingSurfaceId()

            // 注册 photoReceiver 的 ImageArrival 回调（KB：ImageReceiver.on 签名确认）
            let arrivalCb = PhotoArrivalCb(this)
            this.photoArrivalCb = Some(arrivalCb)
            photoRec.on(ImageArrival, arrivalCb)
            Hilog.info(0, "CjTelegram", "[CameraService] photoReceiver ImageArrival callback registered")

            // 创建 PreviewOutput（live preview）
            if (capability.previewProfiles.size == 0) {
                Hilog.info(0, "CjTelegram", "[CameraService] no preview profiles")
                this.onError("No preview profile")
                return ""
            }
            // 预览档位：按取景面尺寸提示选（round 1:1 → 480x480 等；竖屏 → 1920x1080），
            // XComponent SURFACE 会把缓冲拉伸到自身尺寸，比例不匹配就变形
            var pIdx: Int64 = 0
            if (hintW > 0 && hintH > 0) {
                var listing = ""
                var bestScore: Int64 = Int64.Max
                let n = capability.previewProfiles.size
                for (i in 0..n) {
                    let pp = capability.previewProfiles[i]
                    let w = Int64(pp.size.width)
                    let h = Int64(pp.size.height)
                    listing = listing + "${w}x${h} "
                    // 比例差 × 大权重 + 面积差
                    let ratioDiff = if (w * hintH > h * hintW) { w * hintH - h * hintW } else { h * hintW - w * hintH }
                    let areaDiff = if (w * h > hintW * hintH) { w * h - hintW * hintH } else { hintW * hintH - w * h }
                    let score = ratioDiff * 1000 + areaDiff / 1000
                    if (score < bestScore) { bestScore = score; pIdx = i }
                }
                Hilog.info(0, "CjTelegram", "[CameraService] previewProfiles: ${listing}→ #${pIdx}")
            }
            let prevOut = mgr.createPreviewOutput(capability.previewProfiles[pIdx], previewSurfaceId)
            this.previewOutput = Some(prevOut)

            // 创建第二路 PreviewOutput（拍照专用 surface，接 photoReceiver）
            // 使用 previewProfiles[0] 确保兼容性；photoProfiles 为 Profile 类型但其
            // 分辨率可能超过 PreviewOutput 支持范围，保守选用 previewProfiles[0]
            let photoPrevOut = mgr.createPreviewOutput(capability.previewProfiles[0], photoSurfaceId)
            this.photoPreviewOut = Some(photoPrevOut)
            Hilog.info(0, "CjTelegram", "[CameraService] photoPreviewOut created for dedicated photo surface")

            // 创建 CameraInput
            let cInput = mgr.createCameraInput(chosenDevice.cameraPosition, chosenDevice.cameraType)
            this.cameraInput = Some(cInput)
            cInput.open()

            // 创建 PhotoOutput（快门触发用，Cangjie SDK 6.0 profile-only 重载）
            if (capability.photoProfiles.size > 0) {
                let pOut = mgr.createPhotoOutput(profile: capability.photoProfiles[0])
                this.photoOutput = Some(pOut)
            }

            // 建立 Session：添加 input + previewOut（live）+ photoPreviewOut（拍照 surface）+ photoOut（快门）
            let sess = mgr.createSession(mode)
            this.captureSession = Some(sess)
            sess.beginConfig()
            sess.addInput(cInput)
            sess.addOutput(prevOut)
            sess.addOutput(photoPrevOut)
            match (this.photoOutput) {
                case Some(pOut) => sess.addOutput(pOut)
                case None => Hilog.info(0, "CjTelegram", "[CameraService] no photoOutput")
            }
            sess.commitConfig()
            sess.start()

            Hilog.info(0, "CjTelegram", "[CameraService] init OK, previewSurfaceId=${previewSurfaceId}")
            return previewSurfaceId
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[CameraService] init BE: ${e.message}")
            this.onError("Init failed")
            return ""
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CameraService] init exception")
            this.onError("Init error")
            return ""
        }
    }

    /**
     * 触发拍照（P2-073：自动检测前置摄像头应用镜像）。
     * 内部调用 PhotoOutput.capture(PhotoCaptureSetting)，
     * 设置 pendingPhotoCapture=true，当 photoReceiver 收到新帧时（ImageArrival 回调）
     * 读取 JPEG 帧并写入 files/photos/ 目录。
     * 完成后通过 onPhotoSaved(filePath) 回调通知调用方。
     * 前置摄像头：mirror=true（符合 iOS 前摄镜像行为）。
     */
    public func capturePhoto(): Unit {
        Hilog.info(0, "CjTelegram", "[CameraService] capturePhoto")
        let useMirror = (this.currentPosition == CameraPosition.CameraPositionFront)
        this.capturePhotoWithMirror(useMirror)
    }

    /**
     * 指定镜像设置触发拍照（P2-073）。
     * square/round 模式可由 UI 层覆盖此参数。
     * 修复（P2-073 r1）：
     * - 不再同步调用 readAndSavePhoto()（原实现从 previewReceiver 读预览帧，画质/时序错）
     * - 改为设置 pendingPhotoCapture=true，由 photoReceiver 的 ImageArrival 回调异步消费帧
     */
    public func capturePhotoWithMirror(mirror: Bool): Unit {
        match (this.photoOutput) {
            case None =>
                Hilog.info(0, "CjTelegram", "[CameraService] photoOutput not ready")
                this.onError("Photo not ready")
            case Some(pOut) =>
                try {
                    let setting = PhotoCaptureSetting(
                        quality: QualityLevel.QualityLevelHigh,
                        rotation: ImageRotation.Rotation0,
                        mirror: mirror
                    )
                    // 先标记待处理，再触发快门：ImageArrival 回调会在帧到达后读取 photoReceiver
                    this.pendingPhotoCapture = true
                    pOut.capture(setting)
                    Hilog.info(0, "CjTelegram", "[CameraService] capture triggered mirror=${mirror}, pendingPhotoCapture=true")
                } catch (e: BusinessException) {
                    this.pendingPhotoCapture = false
                    Hilog.info(0, "CjTelegram", "[CameraService] capture BE: ${e.message}")
                    this.onError("Capture failed")
                } catch (e: Exception) {
                    this.pendingPhotoCapture = false
                    Hilog.info(0, "CjTelegram", "[CameraService] capture exception")
                    this.onError("Capture error")
                }
        }
    }

    /**
     * photoReceiver 的 ImageArrival 回调入口（由 PhotoArrivalCb.invoke 调用）。
     * 若 pendingPhotoCapture==true，则消费 photoReceiver 中的最新帧保存为 JPEG。
     * 读取自 photoReceiver（非 previewReceiver），确保是拍照对应的帧而非普通预览帧。
     */
    public func onPhotoReceiverImageArrived(): Unit {
        if (!this.pendingPhotoCapture) {
            return
        }
        this.pendingPhotoCapture = false
        match (this.photoReceiver) {
            case None =>
                Hilog.info(0, "CjTelegram", "[CameraService] onPhotoReceiverImageArrived: no photoReceiver")
            case Some(receiver) =>
                try {
                    let image = receiver.readLatestImage()
                    let comp = image.getComponent(ComponentType.Jpeg)
                    let rawData: Array<UInt8> = comp.byteBuffer
                    image.release()

                    if (rawData.size == 0) {
                        Hilog.info(0, "CjTelegram", "[CameraService] photo frame empty, skip save")
                        this.onError("Photo frame empty")
                        return
                    }

                    let ts = DateTime.now().toUnixTimeStamp().toMilliseconds()
                    let filePath = this.photosDir + "/photo_${ts}.jpg"
                    this.saveBytesToFile(filePath, rawData)
                    Hilog.info(0, "CjTelegram", "[CameraService] photo saved from photoReceiver: ${filePath}")
                    this.onPhotoSaved(filePath)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CameraService] onPhotoReceiverImageArrived error")
                    this.onError("Photo save error")
                }
        }
    }

    /**
     * 开始录像。
     * 在已有的预览 session 中追加 VideoOutput 并调用 start()。
     * 录像中 currentVideoPath 记录文件路径，停止后通过 onVideoSaved 回调。
     */
    public func startVideoRecording(): Unit {
        if (this.isRecording) {
            Hilog.info(0, "CjTelegram", "[CameraService] already recording")
            return
        }
        match (getGlobalAbilityContext()) {
            case None =>
                Hilog.info(0, "CjTelegram", "[CameraService] no ctx for video")
                this.onError("No context")
            case Some(ctx) =>
                try {
                    this.doStartVideo(ctx)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CameraService] startVideo exception")
                    this.onError("Video error")
                }
        }
    }

    private func doStartVideo(ctx: UIAbilityContext): Unit {
        try {
            let mgr = getCameraManager(ctx)
            let devices = mgr.getSupportedCameras()
            if (devices.size == 0) {
                this.onError("No device")
                return
            }
            var chosenDevice: CameraDevice = devices[0]
            for (i in 0..devices.size) {
                let dev = devices[i]
                if (dev.cameraPosition == this.currentPosition) {
                    chosenDevice = dev
                }
            }

            let modes = mgr.getSupportedSceneModes(chosenDevice)
            if (modes.size == 0) {
                this.onError("No scene modes for video")
                return
            }
            // 选择最后一个 mode（通常为 video mode）或 index 1
            let videoMode = if (modes.size > 1) { modes[1] } else { modes[0] }
            let capability = mgr.getSupportedOutputCapability(chosenDevice, videoMode)

            if (capability.videoProfiles.size == 0) {
                this.onError("No video profiles")
                return
            }

            // 创建录像用 ImageReceiver（1280×720）
            let vidSize = ImageSize(1280, 720)
            let vidReceiver = createImageReceiver(vidSize, ImageFormat.Jpeg, 8)
            this.videoReceiver = Some(vidReceiver)
            let videoSurfaceId = vidReceiver.getReceivingSurfaceId()

            let vOut = mgr.createVideoOutput(capability.videoProfiles[0], videoSurfaceId)
            this.videoOutput = Some(vOut)

            // 重新配置 session 以追加 VideoOutput
            let sess = match (this.captureSession) {
                case Some(s) => s
                case None =>
                    this.onError("No session for video")
                    return
            }
            sess.stop()
            sess.beginConfig()
            sess.addOutput(vOut)
            sess.commitConfig()
            sess.start()
            vOut.start()

            this.isRecording = true
            let ts = DateTime.now().toUnixTimeStamp().toMilliseconds()
            this.currentVideoPath = this.videosDir + "/video_${ts}.mp4"
            Hilog.info(0, "CjTelegram", "[CameraService] video started: ${this.currentVideoPath}")
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[CameraService] doStartVideo BE: ${e.message}")
            this.onError("Video start failed")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CameraService] doStartVideo exception")
            this.onError("Video start error")
        }
    }

    /**
     * 停止录像。
     * 调用 videoOutput.stop()，然后触发 onVideoSaved(currentVideoPath) 回调。
     */
    public func stopVideoRecording(): Unit {
        if (!this.isRecording) {
            Hilog.info(0, "CjTelegram", "[CameraService] not recording")
            return
        }
        match (this.videoOutput) {
            case None =>
                Hilog.info(0, "CjTelegram", "[CameraService] no videoOutput")
                this.isRecording = false
            case Some(vOut) =>
                try {
                    vOut.stop()
                    this.isRecording = false
                    let savedPath = this.currentVideoPath
                    this.currentVideoPath = ""
                    Hilog.info(0, "CjTelegram", "[CameraService] video stopped: ${savedPath}")
                    this.onVideoSaved(savedPath)
                } catch (e: BusinessException) {
                    Hilog.info(0, "CjTelegram", "[CameraService] stopVideo BE: ${e.message}")
                    this.onError("Stop video failed")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CameraService] stopVideo exception")
                    this.onError("Stop video error")
                }
        }
    }

    /**
     * 切换前/后置摄像头。
     * 释放当前相机，以对面位置重新初始化。
     * 返回新的 surfaceId。
     */
    public func switchCamera(): String {
        let next = if (this.currentPosition == CameraPosition.CameraPositionBack) {
            CameraPosition.CameraPositionFront
        } else {
            CameraPosition.CameraPositionBack
        }
        this.releaseCamera()
        return this.initCamera(next)
    }

    /**
     * 释放所有相机资源（页面退出时调用）。
     */
    public func releaseCamera(): Unit {
        Hilog.info(0, "CjTelegram", "[CameraService] releaseCamera")
        if (this.isRecording) {
            this.stopVideoRecording()
        }
        // 清除 pendingPhotoCapture，避免 release 后 ImageArrival 回调仍尝试读帧
        this.pendingPhotoCapture = false
        match (this.captureSession) {
            case Some(sess) =>
                try {
                    sess.stop()
                    sess.release()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CameraService] sess release error")
                }
            case None => Hilog.info(0, "CjTelegram", "[CameraService] no session")
        }
        match (this.cameraInput) {
            case Some(ci) =>
                try { ci.close() } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CameraService] cameraInput close error")
                }
            case None => Hilog.info(0, "CjTelegram", "[CameraService] no cameraInput")
        }
        this.captureSession = None
        this.cameraInput = None
        this.photoOutput = None
        this.videoOutput = None
        this.previewOutput = None
        this.photoPreviewOut = None
        this.previewReceiver = None
        this.photoReceiver = None
        this.photoArrivalCb = None
        this.videoReceiver = None
        Hilog.info(0, "CjTelegram", "[CameraService] released OK")
    }

    /**
     * 当前是否正在录像。
     */
    public func getIsRecording(): Bool {
        return this.isRecording
    }

    /**
     * 获取当前相机位置。
     */
    public func getCurrentPosition(): CameraPosition {
        return this.currentPosition
    }

    /**
     * 当前是否为前置摄像头（P2-072/073：用于 UI 镜像判断）。
     */
    public func isFrontCamera(): Bool {
        return this.currentPosition == CameraPosition.CameraPositionFront
    }

    /**
     * 从 previewReceiver 读取下一帧 JPEG 字节（P2-072：live 预览帧轮询）。
     * 在后台线程调用，不写文件，仅返回原始 JPEG 字节供 UI 解码为 PixelMap 显示。
     * 注意：此方法仅供 live 预览，拍照成片通过 photoReceiver + onPhotoSaved 回调获取。
     * 返回 None 表示暂无可用帧（队列空或 receiver 未就绪）。
     */
    public func readPreviewFrameBytes(): Option<Array<UInt8>> {
        match (this.previewReceiver) {
            case None => return None
            case Some(receiver) =>
                try {
                    let image = receiver.readNextImage()
                    let comp = image.getComponent(ComponentType.Jpeg)
                    let rawData: Array<UInt8> = comp.byteBuffer
                    image.release()
                    if (rawData.size > 0) {
                        return Some(rawData)
                    }
                    return None
                } catch (e: Exception) {
                    return None
                }
        }
    }

    /**
     * 上传照片到 Telegram（通过 FileUploadService.uploadFile）。
     * 返回 TLObject (InputFile) Option，用于后续 sendMedia 调用。
     */
    public func uploadPhoto(photoPath: String): Option<TLObject> {
        Hilog.info(0, "CjTelegram", "[CameraService] uploadPhoto: ${photoPath}")
        try {
            let data = this.readFileBytes(photoPath)
            if (data.size == 0) {
                Hilog.info(0, "CjTelegram", "[CameraService] empty photo file")
                return None
            }
            let ts = DateTime.now().toUnixTimeStamp().toMilliseconds()
            let fileName = "photo_${ts}.jpg"
            return getFileUploadService().uploadFile(data, fileName)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CameraService] uploadPhoto error")
            return None
        }
    }

    /**
     * 上传视频到 Telegram（通过 FileUploadService.uploadFile）。
     * 返回 TLObject (InputFile) Option，用于后续 sendMedia 调用。
     */
    public func uploadVideo(videoPath: String): Option<TLObject> {
        Hilog.info(0, "CjTelegram", "[CameraService] uploadVideo: ${videoPath}")
        try {
            let data = this.readFileBytes(videoPath)
            if (data.size == 0) {
                Hilog.info(0, "CjTelegram", "[CameraService] empty video file")
                return None
            }
            let ts = DateTime.now().toUnixTimeStamp().toMilliseconds()
            let fileName = "video_${ts}.mp4"
            return getFileUploadService().uploadFile(data, fileName)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CameraService] uploadVideo error")
            return None
        }
    }

    /**
     * 读取已保存照片文件的全部字节（P2-073：供缩略图解码使用）。
     * 返回 Array<Byte>，失败时返回空数组。
     */
    public func readPhotoBytes(path: String): Array<Byte> {
        try {
            return this.readFileBytes(path)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CameraService] readPhotoBytes error for ${path}")
            return Array<Byte>(0, repeat: 0)
        }
    }

    // ==================== P2-075 闪光灯/手电筒控制 ====================

    /**
     * setFlashMode — 设置拍照闪光灯模式（P2-075）。
     * 通过 PhotoSession 接口（KB 确认：session as PhotoSession → setFlashMode(FlashMode)）。
     * flashMode: "off" / "on" / "auto" / "always"
     */
    public func setFlashMode(flashMode: String): Unit {
        match (this.captureSession) {
            case None =>
                Hilog.info(0, "CjTelegram", "[CameraService] setFlashMode: no session")
            case Some(sess) =>
                try {
                    let photoSessOpt = sess as PhotoSession
                    match (photoSessOpt) {
                        case Some(photoSess) =>
                            let mode = this.flashModeFromString(flashMode)
                            photoSess.setFlashMode(mode)
                            Hilog.info(0, "CjTelegram", "[CameraService] setFlashMode=${flashMode}")
                        case None =>
                            Hilog.info(0, "CjTelegram", "[CameraService] setFlashMode: not PhotoSession")
                    }
                } catch (e: BusinessException) {
                    Hilog.info(0, "CjTelegram", "[CameraService] setFlashMode BE: ${e.message}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CameraService] setFlashMode exception")
                }
        }
    }

    private func flashModeFromString(s: String): FlashMode {
        if (s == "on") {
            return FlashMode.FlashModeOpen
        } else if (s == "auto") {
            return FlashMode.FlashModeAuto
        } else if (s == "always") {
            return FlashMode.FlashModeAlwaysOpen
        } else {
            return FlashMode.FlashModeClose
        }
    }

    /**
     * setTorchActive — 开/关手电筒常亮模式（P2-075，录像/暗光补光）。
     * 通过 PhotoSession 接口：FlashMode.FlashModeAlwaysOpen = 手电常亮；
     * FlashMode.FlashModeClose = 关闭。
     */
    public func setTorchActive(active: Bool): Unit {
        match (this.captureSession) {
            case None =>
                Hilog.info(0, "CjTelegram", "[CameraService] setTorchActive: no session")
            case Some(sess) =>
                try {
                    let photoSessOpt = sess as PhotoSession
                    match (photoSessOpt) {
                        case Some(photoSess) =>
                            let mode = if (active) {
                                FlashMode.FlashModeAlwaysOpen
                            } else {
                                FlashMode.FlashModeClose
                            }
                            photoSess.setFlashMode(mode)
                            Hilog.info(0, "CjTelegram", "[CameraService] setTorchActive=${active}")
                        case None =>
                            Hilog.info(0, "CjTelegram", "[CameraService] setTorchActive: not PhotoSession")
                    }
                } catch (e: BusinessException) {
                    Hilog.info(0, "CjTelegram", "[CameraService] setTorchActive BE: ${e.message}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CameraService] setTorchActive exception")
                }
        }
    }

    // ==================== P2-076 变焦控制 ====================

    /**
     * setZoomRatio — 设置变焦比（P2-076）。
     * PhotoSession.setZoomRatio(Float64) — KB 确认：精度最高小数点后两位。
     */
    public func setZoomRatio(ratio: Float64): Unit {
        match (this.captureSession) {
            case None =>
                Hilog.info(0, "CjTelegram", "[CameraService] setZoomRatio: no session")
            case Some(sess) =>
                try {
                    let photoSessOpt = sess as PhotoSession
                    match (photoSessOpt) {
                        case Some(photoSess) =>
                            photoSess.setZoomRatio(ratio)
                            Hilog.info(0, "CjTelegram", "[CameraService] setZoomRatio=${ratio}")
                        case None =>
                            Hilog.info(0, "CjTelegram", "[CameraService] setZoomRatio: not PhotoSession")
                    }
                } catch (e: BusinessException) {
                    Hilog.info(0, "CjTelegram", "[CameraService] setZoomRatio BE: ${e.message}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CameraService] setZoomRatio exception")
                }
        }
    }

    /**
     * getZoomRatioRange — 获取支持的变焦范围（P2-076）。
     * 返回 [minZoom, maxZoom]；失败时返回 [1.0, 1.0]。
     */
    public func getZoomRatioRange(): Array<Float64> {
        match (this.captureSession) {
            case None =>
                return Array<Float64>(2, { i => if (i == 0) { 1.0 } else { 1.0 } })
            case Some(sess) =>
                try {
                    let photoSessOpt = sess as PhotoSession
                    match (photoSessOpt) {
                        case Some(photoSess) =>
                            let r = photoSess.getZoomRatioRange()
                            if (r.size >= 2) { return r }
                            return Array<Float64>(2, { i => if (i == 0) { 1.0 } else { 1.0 } })
                        case None =>
                            return Array<Float64>(2, { i => if (i == 0) { 1.0 } else { 1.0 } })
                    }
                } catch (e: Exception) {
                    return Array<Float64>(2, { i => if (i == 0) { 1.0 } else { 1.0 } })
                }
        }
    }

    // ==================== P2-077 对焦/曝光控制 ====================

    /**
     * setFocusPoint — 点按对焦：设置对焦模式为 Manual/Auto 并指定焦点坐标（P2-077）。
     * point(x, y) 应在 0-1 坐标系内（左上角 {0,0}，右下角 {1,1}）。
     * KB 确认：PhotoSession.setFocusMode(FocusMode) + setFocusPoint(Point)。
     */
    public func setFocusPoint(x: Float64, y: Float64): Unit {
        match (this.captureSession) {
            case None =>
                Hilog.info(0, "CjTelegram", "[CameraService] setFocusPoint: no session")
            case Some(sess) =>
                try {
                    let photoSessOpt = sess as PhotoSession
                    match (photoSessOpt) {
                        case Some(photoSess) =>
                            photoSess.setFocusMode(FocusMode.FocusModeManual)
                            let pt = CameraPoint(x, y)
                            photoSess.setFocusPoint(pt)
                            Hilog.info(0, "CjTelegram", "[CameraService] setFocusPoint x=${x} y=${y}")
                        case None =>
                            Hilog.info(0, "CjTelegram", "[CameraService] setFocusPoint: not PhotoSession")
                    }
                } catch (e: BusinessException) {
                    Hilog.info(0, "CjTelegram", "[CameraService] setFocusPoint BE: ${e.message}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CameraService] setFocusPoint exception")
                }
        }
    }

    /**
     * resetAutoFocus — 恢复连续自动对焦模式（P2-077）。
     * 对焦框消失后或用户取消手动对焦时调用。
     */
    public func resetAutoFocus(): Unit {
        match (this.captureSession) {
            case None =>
                Hilog.info(0, "CjTelegram", "[CameraService] resetAutoFocus: no session")
            case Some(sess) =>
                try {
                    let photoSessOpt = sess as PhotoSession
                    match (photoSessOpt) {
                        case Some(photoSess) =>
                            photoSess.setFocusMode(FocusMode.FocusModeContinuousAuto)
                            Hilog.info(0, "CjTelegram", "[CameraService] resetAutoFocus: ContinuousAuto")
                        case None =>
                            Hilog.info(0, "CjTelegram", "[CameraService] resetAutoFocus: not PhotoSession")
                    }
                } catch (e: BusinessException) {
                    Hilog.info(0, "CjTelegram", "[CameraService] resetAutoFocus BE: ${e.message}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CameraService] resetAutoFocus exception")
                }
        }
    }

    /**
     * setExposureBias — 设置曝光补偿（P2-077）。
     * exposureBias: Float64，范围由 getExposureBiasRange() 决定（通常 -4.0 ~ +4.0）。
     * KB 确认：PhotoSession.setExposureBias(Float64)。
     */
    public func setExposureBias(bias: Float64): Unit {
        match (this.captureSession) {
            case None =>
                Hilog.info(0, "CjTelegram", "[CameraService] setExposureBias: no session")
            case Some(sess) =>
                try {
                    let photoSessOpt = sess as PhotoSession
                    match (photoSessOpt) {
                        case Some(photoSess) =>
                            photoSess.setExposureBias(bias)
                            Hilog.info(0, "CjTelegram", "[CameraService] setExposureBias=${bias}")
                        case None =>
                            Hilog.info(0, "CjTelegram", "[CameraService] setExposureBias: not PhotoSession")
                    }
                } catch (e: BusinessException) {
                    Hilog.info(0, "CjTelegram", "[CameraService] setExposureBias BE: ${e.message}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CameraService] setExposureBias exception")
                }
        }
    }

    /**
     * setMeteringPoint — 设置测光点，与 setExposureBias 联动（P2-077）。
     * point(x, y) 在 0-1 坐标系内。
     * KB 确认：AutoExposure.setExposureMode + setMeteringPoint(Point)。
     */
    public func setMeteringPoint(x: Float64, y: Float64): Unit {
        match (this.captureSession) {
            case None =>
                Hilog.info(0, "CjTelegram", "[CameraService] setMeteringPoint: no session")
            case Some(sess) =>
                try {
                    let photoSessOpt = sess as PhotoSession
                    match (photoSessOpt) {
                        case Some(photoSess) =>
                            photoSess.setExposureMode(ExposureMode.ExposureModeContinuousAuto)
                            let pt = CameraPoint(x, y)
                            photoSess.setMeteringPoint(pt)
                            Hilog.info(0, "CjTelegram", "[CameraService] setMeteringPoint x=${x} y=${y}")
                        case None =>
                            Hilog.info(0, "CjTelegram", "[CameraService] setMeteringPoint: not PhotoSession")
                    }
                } catch (e: BusinessException) {
                    Hilog.info(0, "CjTelegram", "[CameraService] setMeteringPoint BE: ${e.message}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CameraService] setMeteringPoint exception")
                }
        }
    }

    // ==================== P2-074 真录像（AVRecorder via arkinterop）====================

    /**
     * startVideoRecordingReal — 使用 AVRecorder（@kit.MediaKit）产出可播 mp4。
     *
     * 架构（对应 iOS VideoRecorder.swift；Phase 3 反转模式, SSOT §5）：
     *   1. callArkAsync(CAMERA_REC_PREPARE, {"path"}) → ArkTS CameraImpl.ets：
     *      media.createAVRecorder() → prepare(config) → getInputSurface() → surfaceId
     *   2. 用返回的 surfaceId 创建 VideoOutput 并追加进 CameraSession（native kit.CameraKit，本侧）
     *   3. callArkAsync(CAMERA_REC_START, {}) → avRecorder.start()（ArkTS 侧）
     *
     * 诚实记录：
     *   - AVRecorder 仅有 ArkTS binding（Cangjie kit.MediaKit 不暴露 AVRecorder，KB 三轮确认），
     *     故 AVRecorder 生命周期全在 ArkTS 侧 (CameraImpl.ets)，仓颉经 callArkAsync 驱动离散操作。
     *   - Camera Kit 相机侧（预览/拍照/session/VideoOutput 绑定）仍是 native kit.CameraKit，未反转。
     *   - 需要 MICROPHONE 权限（module.json5 声明）。
     *   - 输出文件由 ArkTS 侧按传入 path 用 fileIo.openSync 创建 fd 并管理关闭。
     *
     * 契约 (D3)：
     *   CAMERA_REC_PREPARE arg {"path": <mp4路径>} → {"ok": <bool>, "surfaceId": <string>}
     *   CAMERA_REC_START   arg {} → {"ok": <bool>}
     *
     * 输出文件路径通过 onVideoSaved(path) 回调返回（在 stopVideoRecordingReal 中触发）。
     */
    public func startVideoRecordingReal(): Unit {
        if (this.isRecording) {
            Hilog.info(0, "CjTelegram", "[CameraService] startVideoReal: already recording")
            return
        }
        this.ensureDirectories()
        let ts = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let outPath = this.videosDir + "/video_${ts}.mp4"
        this.currentVideoPath = outPath
        this.recordingElapsedMs = 0
        this.isPausedRecording = false

        Hilog.info(0, "CjTelegram", "[CameraService] startVideoReal path=${outPath} preset=${this.videoPreset}")

        // 先选 VideoProfile（AVRecorder 的宽高必须与之一致），再 prepare
        let picked = this.pickVideoProfile(this.videoPreset)
        this.pendingVideoProfileIndex = picked[0]
        // 旋转元数据：竖持手机时后置 sensor 90°、前置 270°（Cangjie CameraKit 未暴露 cameraOrientation）
        let rotation: Int64 = if (this.videoPreset == "videomsg") {
            if (this.currentPosition == CameraPosition.CameraPositionFront) { 270 } else { 90 }
        } else { 0 }

        // Step 1: ArkTS 侧创建/prepare AVRecorder 并回传 inputSurface
        let escapedPath = escapeJsonString(outPath)
        let argJson = "{\"path\":\"${escapedPath}\",\"preset\":\"${this.videoPreset}\",\"width\":${picked[1]},\"height\":${picked[2]},\"rotation\":${rotation}}"
        callArkAsync(CAMERA_REC_PREPARE, argJson) { resJson =>
            // D1: 后续 VideoOutput 绑定/启动是重活，放 spawn{} 里跑
            spawn {
                let json = JsonParser.parseObject(resJson)
                if (json.getBool("ok")) {
                    let sid = json.getString("surfaceId")
                    if (sid.size > 0) {
                        Hilog.info(0, "CjTelegram", "[CameraService] avRecorder surfaceId=${sid}")
                        this.avRecorderActive = true
                        this.avRecorderSurfaceId = sid
                        this.doAttachVideoOutputAndStart(sid)
                    } else {
                        Hilog.info(0, "CjTelegram", "[CameraService] avRecorder empty surfaceId")
                        this.onError("AVRecorder surfaceId empty")
                    }
                } else {
                    Hilog.info(0, "CjTelegram", "[CameraService] avRecorder prepare/create failed")
                    this.onError("AVRecorder prepare failed")
                }
            }
        }
    }

    // 将 AVRecorder surfaceId 绑定到 VideoOutput（native kit.CameraKit），加入 session，启动录像
    private func doAttachVideoOutputAndStart(surfaceId: String): Unit {
        match (getGlobalAbilityContext()) {
            case None =>
                this.onError("No ctx for video output")
                return
            case Some(ctx) =>
                try {
                    let mgr = getCameraManager(ctx)
                    let devices = mgr.getSupportedCameras()
                    if (devices.size == 0) { this.onError("No device"); return }
                    var chosenDevice: CameraDevice = devices[0]
                    for (i in 0..devices.size) {
                        let dev = devices[i]
                        if (dev.cameraPosition == this.currentPosition) {
                            chosenDevice = dev
                        }
                    }
                    let modes = mgr.getSupportedSceneModes(chosenDevice)
                    if (modes.size == 0) { this.onError("No scene modes"); return }
                    let videoMode = if (modes.size > 1) { modes[1] } else { modes[0] }
                    let capability = mgr.getSupportedOutputCapability(chosenDevice, videoMode)
                    if (capability.videoProfiles.size == 0) { this.onError("No video profile"); return }

                    var profileIdx = this.pendingVideoProfileIndex
                    if (profileIdx < 0 || profileIdx >= capability.videoProfiles.size) { profileIdx = 0 }
                    let vOut = mgr.createVideoOutput(capability.videoProfiles[profileIdx], surfaceId)
                    this.videoOutput = Some(vOut)

                    let sess = match (this.captureSession) {
                        case Some(s) => s
                        case None => this.onError("No session"); return
                    }
                    sess.stop()
                    sess.beginConfig()
                    sess.addOutput(vOut)
                    sess.commitConfig()
                    sess.start()
                    vOut.start()

                    // Step 3: ArkTS 侧启动 AVRecorder（CAMERA_REC_START）
                    callArkAsync(CAMERA_REC_START, "{}") { resJson =>
                        let sj = JsonParser.parseObject(resJson)
                        if (sj.getBool("ok")) {
                            Hilog.info(0, "CjTelegram", "[CameraService] avRecorder started")
                        } else {
                            Hilog.info(0, "CjTelegram", "[CameraService] avRecorder start failed")
                        }
                    }

                    this.isRecording = true
                    Hilog.info(0, "CjTelegram", "[CameraService] video recording started via AVRecorder")
                    this.startDurationTimer()
                } catch (e: BusinessException) {
                    Hilog.info(0, "CjTelegram", "[CameraService] doAttachVideoOutput BE: ${e.message}")
                    this.onError("Video attach failed")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CameraService] doAttachVideoOutput exception")
                    this.onError("Video attach error")
                }
        }
    }

    // P2-074：时长计时器 spawn loop（100ms tick，累积 recordingElapsedMs）
    private func startDurationTimer(): Unit {
        spawn {
            while (this.isRecording) {
                sleep(Duration.millisecond * 100)
                if (!this.isPausedRecording && this.isRecording) {
                    let next = this.recordingElapsedMs + 100
                    this.recordingElapsedMs = next
                    let elapsed = next
                    this.onRecordingDurationUpdate(elapsed)
                }
            }
        }
    }

    /**
     * stopVideoRecordingReal — 停止 AVRecorder 录像，触发 onVideoSaved(path)。
     */
    public func stopVideoRecordingReal(): Unit {
        if (!this.isRecording) {
            Hilog.info(0, "CjTelegram", "[CameraService] stopVideoReal: not recording")
            return
        }
        this.isRecording = false
        this.isPausedRecording = false

        match (this.videoOutput) {
            case Some(vOut) =>
                try { vOut.stop() } catch (_: Exception) {}
            case None => ()
        }

        let savedPath = this.currentVideoPath
        let wasActive = this.avRecorderActive
        this.avRecorderActive = false
        this.avRecorderSurfaceId = ""
        this.currentVideoPath = ""

        if (wasActive) {
            // ArkTS 侧 stop() → release() → 关闭 fd（CAMERA_REC_STOP）。
            // onVideoSaved 放到 stop 回调之后：此前在 stop 尚未落盘时就回调，圆形视频转码会读到半截 mp4。
            callArkAsync(CAMERA_REC_STOP, "{}") { resJson =>
                let sj = JsonParser.parseObject(resJson)
                if (sj.getBool("ok")) {
                    Hilog.info(0, "CjTelegram", "[CameraService] avRecorder stopped+released")
                } else {
                    Hilog.info(0, "CjTelegram", "[CameraService] avRecorder stop failed")
                }
                Hilog.info(0, "CjTelegram", "[CameraService] video stopped real: ${savedPath}")
                this.onVideoSaved(savedPath)
            }
        } else {
            Hilog.info(0, "CjTelegram", "[CameraService] video stopped real: ${savedPath}")
            this.onVideoSaved(savedPath)
        }
    }

    /**
     * 选录像档位 → [index, width, height]。
     * videomsg：优先 1:1；否则短边落在 480..1080 里最小的（裁方后仍 ≥ 400）；再否则最小档。
     * 其它预设：videoProfiles[0]（沿用既有行为，AVRecorder 侧 1280×720）。
     */
    private func pickVideoProfile(preset: String): Array<Int64> {
        var result = Array<Int64>(3, repeat: 0)
        result[1] = 1280
        result[2] = 720
        match (getGlobalAbilityContext()) {
            case None => return result
            case Some(ctx) =>
                try {
                    let mgr = getCameraManager(ctx)
                    let devices = mgr.getSupportedCameras()
                    if (devices.size == 0) { return result }
                    var chosenDevice: CameraDevice = devices[0]
                    for (i in 0..devices.size) {
                        if (devices[i].cameraPosition == this.currentPosition) { chosenDevice = devices[i] }
                    }
                    let modes = mgr.getSupportedSceneModes(chosenDevice)
                    if (modes.size == 0) { return result }
                    let videoMode = if (modes.size > 1) { modes[1] } else { modes[0] }
                    let capability = mgr.getSupportedOutputCapability(chosenDevice, videoMode)
                    let n = capability.videoProfiles.size
                    if (n == 0) { return result }
                    var listing = ""
                    var bestIdx: Int64 = 0
                    var bestScore: Int64 = Int64.Max
                    for (i in 0..n) {
                        let vp = capability.videoProfiles[i]
                        let w = Int64(vp.size.width)
                        let h = Int64(vp.size.height)
                        listing = listing + "${w}x${h}@${Int32(vp.frameRateRange.min)}-${Int32(vp.frameRateRange.max)} "
                        if (preset != "videomsg") { continue }
                        let short = if (w < h) { w } else { h }
                        let long = if (w < h) { h } else { w }
                        // 分数越小越好：方形 0 段；短边 480..1080 段按面积；其余段按面积再加大偏移
                        let score: Int64 = if (w == h) { w * h } else if (short >= 480 && short <= 1080) { 10_000_000 + long * short } else { 100_000_000 + long * short }
                        if (score < bestScore) { bestScore = score; bestIdx = i }
                    }
                    Hilog.info(0, "CjTelegram", "[CameraService] videoProfiles(${this.currentPosition == CameraPosition.CameraPositionFront}): ${listing}")
                    if (preset == "videomsg") {
                        let vp = capability.videoProfiles[bestIdx]
                        result[0] = bestIdx
                        result[1] = Int64(vp.size.width)
                        result[2] = Int64(vp.size.height)
                        Hilog.info(0, "CjTelegram", "[CameraService] videomsg profile #${bestIdx}: ${result[1]}x${result[2]}")
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CameraService] pickVideoProfile failed: ${e}")
                }
        }
        return result
    }

    /**
     * pauseVideoRecording — 暂停录像（P2-074 iOS: pauseRecording）。
     * 经 callArkAsync(CAMERA_REC_PAUSE) 调 ArkTS 侧 avRecorder.pause()。
     */
    public func pauseVideoRecording(): Unit {
        if (!this.isRecording || this.isPausedRecording) { return }
        this.isPausedRecording = true
        if (this.avRecorderActive) {
            callArkAsync(CAMERA_REC_PAUSE, "{}") { _ => () }
        }
        Hilog.info(0, "CjTelegram", "[CameraService] recording paused")
    }

    /**
     * resumeVideoRecording — 恢复录像（P2-074 iOS: resumeRecording）。
     */
    public func resumeVideoRecording(): Unit {
        if (!this.isRecording || !this.isPausedRecording) { return }
        this.isPausedRecording = false
        if (this.avRecorderActive) {
            callArkAsync(CAMERA_REC_RESUME, "{}") { _ => () }
        }
        Hilog.info(0, "CjTelegram", "[CameraService] recording resumed")
    }

    /**
     * getIsPausedRecording — 当前是否处于暂停状态。
     */
    public func getIsPausedRecording(): Bool {
        return this.isPausedRecording
    }

    /**
     * getRecordingElapsedMs — 当前录像已用时间（毫秒）。
     */
    public func getRecordingElapsedMs(): Int64 {
        return this.recordingElapsedMs
    }

    // ==================== P2-079 双摄/慢动作能力查询 ====================

    /**
     * queryDualCameraSupport — 查询设备是否支持多摄并发（P2-079）。
     *
     * Camera Kit 6.0 查询结果（诚实标注）：
     * - 枚举 getSupportedCameras() 可以看到 CameraTypeUltraWide / CameraTypeWideAngle / CameraTypeTelephoto
     *   表示设备具有多个后置镜头，但 Camera Kit Cangjie SDK 每次只支持一个 CameraInput，
     *   不提供并发双路输入接口（无等价于 iOS AVCaptureMultiCamSession 的 API）。
     * - 因此：双摄检测 = 能否枚举到多个后置摄像头类型（CameraTypeWideAngle + CameraTypeUltraWide）
     *   但无法并发使用两路流。返回有多少后置摄像头可枚举。
     *
     * 返回 [hasUltraWide: 0/1, hasTelephoto: 0/1, backCameraCount: N]
     */
    public func queryDualCameraSupport(): Array<Int32> {
        match (getGlobalAbilityContext()) {
            case None => return Array<Int32>(3, repeat: 0)
            case Some(ctx) =>
                try {
                    let mgr = getCameraManager(ctx)
                    let devices = mgr.getSupportedCameras()
                    var hasUltraWide: Int32 = 0
                    var hasTelephoto: Int32 = 0
                    var backCount: Int32 = 0
                    for (i in 0..devices.size) {
                        let d = devices[i]
                        if (d.cameraPosition == CameraPosition.CameraPositionBack) {
                            backCount = backCount + 1
                            if (d.cameraType == CameraType.CameraTypeUltraWide) {
                                hasUltraWide = 1
                            } else if (d.cameraType == CameraType.CameraTypeTelephoto) {
                                hasTelephoto = 1
                            }
                        }
                    }
                    return [hasUltraWide, hasTelephoto, backCount]
                } catch (_: Exception) {
                    return Array<Int32>(3, repeat: 0)
                }
        }
    }

    /**
     * querySlowMotionSupport — 查询视频 profile 中是否有高帧率（>=120fps）支持（P2-079）。
     *
     * 诚实标注：Camera Kit Cangjie SDK 6.0 暴露 VideoProfile.frameRateRange: FrameRateRange，
     * 但 FrameRateRange 只有 min/max 字段。真实慢动作（slow-motion 录制）需要 AVRecorder 侧
     * 同步支持高帧率视频编码（120fps/240fps），Cangjie AVRecorder 无法直接确认（KB 无 AVRecorder）。
     * 因此返回相机侧能力：是否有 frameRateRange.max >= 120 的 videoProfile。
     *
     * 返回 [maxFps, hasHighFps: 0/1]
     */
    public func querySlowMotionSupport(): Array<Int32> {
        match (getGlobalAbilityContext()) {
            case None => return Array<Int32>(2, repeat: 0)
            case Some(ctx) =>
                try {
                    let mgr = getCameraManager(ctx)
                    let devices = mgr.getSupportedCameras()
                    if (devices.size == 0) { return Array<Int32>(2, repeat: 0) }
                    var chosenDevice: CameraDevice = devices[0]
                    for (i in 0..devices.size) {
                        let d = devices[i]
                        if (d.cameraPosition == this.currentPosition) { chosenDevice = d }
                    }
                    let modes = mgr.getSupportedSceneModes(chosenDevice)
                    var maxFps: Int32 = 30
                    for (mi in 0..modes.size) {
                        let cap = mgr.getSupportedOutputCapability(chosenDevice, modes[mi])
                        for (vi in 0..cap.videoProfiles.size) {
                            let vp = cap.videoProfiles[vi]
                            let vpMax = Int32(vp.frameRateRange.max)
                            if (vpMax > maxFps) { maxFps = vpMax }
                        }
                    }
                    let hasHighFps: Int32 = if (maxFps >= 120) { 1 } else { 0 }
                    return [maxFps, hasHighFps]
                } catch (_: Exception) {
                    return Array<Int32>(2, repeat: 0)
                }
        }
    }

    // ==================== 私有辅助 ====================

    // 确保 photos/ 和 videos/ 目录存在
    private func ensureDirectories(): Unit {
        let filesDir = getAppFilesDir()
        this.photosDir = filesDir + "/photos"
        this.videosDir = filesDir + "/videos"
        try { FileIo.mkdir(this.photosDir) } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CameraService] mkdir photos: exists")
        }
        try { FileIo.mkdir(this.videosDir) } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CameraService] mkdir videos: exists")
        }
    }

    // 将 Array<UInt8> 写入文件（创建 + 写入模式 0o1101）
    private func saveBytesToFile(path: String, data: Array<UInt8>): Unit {
        let f = FileIo.open(path, mode: 0o1101)
        let _ = FileIo.write(f.fd, data)
        FileIo.close(f)
    }

    // 从文件读取全部字节（打开 + 读入 buffer）
    private func readFileBytes(path: String): Array<Byte> {
        let f = FileIo.open(path, mode: 0o0)
        let stat = FileIo.stat(f.fd)
        if (stat.size <= 0) {
            FileIo.close(f)
            return Array<Byte>(0, repeat: 0)
        }
        let buf = Array<Byte>(stat.size, repeat: 0)
        let _ = FileIo.read(f.fd, buf)
        FileIo.close(f)
        return buf
    }
}
