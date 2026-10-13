package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import kit.ImageKit.{PixelMap, Region, ImageSource, ImageInfo, createImageSource}
import kit.ImageKit.Size as IKSize
import ohos.business_exception.BusinessException
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*

// CropEditorScreen — P2-084: 裁剪/旋转编辑页（混合工程迁移版）
//
// iOS 对应：
//   LegacyComponents/Sources/TGPhotoEditorController.m  — 裁剪/旋转/宽高比预设
//   LegacyComponents/Sources/PGPhotoEditor.m            — 裁剪矩形应用
//   MediaPickerUI/Sources/MediaPickerPhotoToolbarView.swift — 裁剪工具栏
//
// 功能：
//   - 可拖拽裁剪框（四角手柄拖动调整裁剪区域）
//   - 宽高比预设：Free / 1:1 / 4:3 / 3:4 / 16:9 / 9:16
//   - 旋转：+90° / -90° 档位旋转按钮 + 任意角度 Slider
//   - 头像圆形裁剪（isCircle = true 时渲染圆形 mask）
//   - 真实 PixelMap.crop(Region) + PixelMap.rotate(Float32) 变换（ImageKit，KB 验证）
//   - 结果存入 MediaEditService.lastCroppedPixelMap 供后续发送
//
// 混合迁移改动（recipe §12 Phase 4）：
//   - @Component → @HybridComponentEntry
//   - 去掉 @Consume NavPathStack
//   - build() 根去掉 NavDestination 包裹，只留内容（内部 Column）
//   - pageStack.pop(animated) → routerPop()
//   - .onReady 参数接收（assetUri）→ ensureLoaded() 内 takePending("CropEditorScreen")；
//     根 Column .onAppear 触发
//   - 源页 hideTitleBar(true)，故 ArkTS 壳 hideTitleBar(true)
//
// @State 规则：集合变更走 temp-var；Float64 直接赋值安全。

// 宽高比预设 enum
public enum CropAspectRatio {
    | Free
    | Square
    | Ratio4x3
    | Ratio3x4
    | Ratio16x9
    | Ratio9x16

    public func displayName(): String {
        match (this) {
            case Free => "Free"
            case Square => "1:1"
            case Ratio4x3 => "4:3"
            case Ratio3x4 => "3:4"
            case Ratio16x9 => "16:9"
            case Ratio9x16 => "9:16"
        }
    }

    public func ordinal(): Int32 {
        match (this) {
            case Free => 0
            case Square => 1
            case Ratio4x3 => 2
            case Ratio3x4 => 3
            case Ratio16x9 => 4
            case Ratio9x16 => 5
        }
    }

    public operator func ==(right: CropAspectRatio): Bool {
        return this.ordinal() == right.ordinal()
    }

    public operator func !=(right: CropAspectRatio): Bool {
        return this.ordinal() != right.ordinal()
    }

    // Returns (widthRatio, heightRatio) for aspect-fill crop, or (0, 0) for Free
    public func ratioWH(): (Float64, Float64) {
        match (this) {
            case Free => (0.0, 0.0)
            case Square => (1.0, 1.0)
            case Ratio4x3 => (4.0, 3.0)
            case Ratio3x4 => (3.0, 4.0)
            case Ratio16x9 => (16.0, 9.0)
            case Ratio9x16 => (9.0, 16.0)
        }
    }
}

@HybridComponentEntry
@Component
public class CropEditorScreen {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // Source asset URI (from route param)
    @State var assetUri: String = ""
    @State var loaded: Bool = false

    // Crop rectangle in image-relative coordinates [0.0..1.0]
    // cropLeft/cropTop = top-left corner, cropRight/cropBottom = bottom-right corner
    @State var cropLeft: Float64 = 0.0
    @State var cropTop: Float64 = 0.0
    @State var cropRight: Float64 = 1.0
    @State var cropBottom: Float64 = 1.0

    // Aspect ratio preset
    @State var selectedRatioIdx: Int32 = 0

    // Rotation angle (degrees, cumulative)
    @State var rotationAngle: Float64 = 0.0
    // Fine-tune rotation slider value (-45.0..45.0 degrees)
    @State var rotationSlider: Float64 = 0.0

    // Circle crop mode (avatar use case)
    @State var isCircleCrop: Bool = false

    // Processing state
    @State var isProcessing: Bool = false
    @State var resultMessage: String = ""

    // Drag handle state for crop frame — tracks which corner is being dragged
    // cornerIdx: 0=TL, 1=TR, 2=BL, 3=BR; -1 = none
    @State var draggingCorner: Int32 = -1

    // P2-084: preview area dimensions (set via onAreaChange) for pixel-accurate crop overlay
    @State var overlayViewW: Float64 = 320.0
    @State var overlayViewH: Float64 = 320.0
    @State var sourceAspectRatio: Float64 = 1.0

    // Derived crop frame pixel positions (computed from normalized crop rect + view size)
    // Used by @Builder buildCropOverlay (no-param, reads from @State)
    @State var frameLeftPx: Float64 = 0.0
    @State var frameTopPx: Float64 = 0.0
    @State var frameWidthPx: Float64 = 320.0
    @State var frameHeightPx: Float64 = 320.0

    // Callback invoked with result PixelMap (stored in MediaEditService)
    public var onCropDone: (Option<PixelMap>) -> Unit = { _pm: Option<PixelMap> => }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        // 原 .onReady 参数接收：assetUri（经 ParamStore takePending 取代 navDestination param）
        let raw = takePending("CropEditorScreen")
        this.assetUri = raw
        Hilog.info(0, "CjTelegram", "[CropEditorScreen] loaded uri=${raw}")
        let _ = spawn {
            match (loadPixelMapFromUri(raw)) {
                case Some(pixelMap) =>
                    let info = pixelMap.getImageInfo()
                    let width = Float64(info.size.width)
                    let height = Float64(info.size.height)
                    pixelMap.release()
                    if (width > 0.0 && height > 0.0) {
                        let aspect = width / height
                        launch { this.sourceAspectRatio = aspect }
                    }
                case None => ()
            }
        }
    }

    // Recompute derived frame pixel positions from @State crop rect + overlay size
    private func recomputeFramePx(): Unit {
        let fL = this.cropLeft * this.overlayViewW
        let fT = this.cropTop * this.overlayViewH
        let fW = (this.cropRight - this.cropLeft) * this.overlayViewW
        let fH = (this.cropBottom - this.cropTop) * this.overlayViewH
        launch {
            this.frameLeftPx = fL
            this.frameTopPx = fT
            this.frameWidthPx = fW
            this.frameHeightPx = fH
        }
    }

    private func ratioPresets(): Array<CropAspectRatio> {
        return [CropAspectRatio.Free, CropAspectRatio.Square, CropAspectRatio.Ratio4x3,
                CropAspectRatio.Ratio3x4, CropAspectRatio.Ratio16x9, CropAspectRatio.Ratio9x16]
    }

    private func selectedRatio(): CropAspectRatio {
        let presets = this.ratioPresets()
        let idx = Int64(this.selectedRatioIdx)
        if (idx >= 0 && idx < presets.size) {
            return presets[idx]
        }
        return CropAspectRatio.Free
    }

    // Apply aspect ratio constraint to current crop rect
    private func applyAspectRatio(ratio: CropAspectRatio): Unit {
        // R-117: no .0/.1 tuple access — use match destructuring
        let (rw, rh) = ratio.ratioWH()
        if (rw <= 0.0 || rh <= 0.0) {
            // Free mode — no constraint
            return
        }
        let centerX = (this.cropLeft + this.cropRight) / 2.0
        let centerY = (this.cropTop + this.cropBottom) / 2.0
        let currentW = this.cropRight - this.cropLeft
        let currentH = this.cropBottom - this.cropTop
        // cropLeft...Bottom 是归一化坐标，不能直接拿归一化宽高比当像素宽高比。
        // 例如 1280x854 原图的 1:1 裁剪，归一化目标宽高比应为 1/1.499。
        let sourceAspect = if (this.sourceAspectRatio > 0.0) { this.sourceAspectRatio } else { 1.0 }
        let targetRatio = (rw / rh) / sourceAspect
        let newW: Float64
        let newH: Float64
        if (currentW / currentH > targetRatio) {
            newH = currentH
            newW = currentH * targetRatio
        } else {
            newW = currentW
            newH = currentW / targetRatio
        }
        let halfW = newW / 2.0
        let halfH = newH / 2.0
        let left = if (centerX - halfW < 0.0) { 0.0 } else { centerX - halfW }
        let top = if (centerY - halfH < 0.0) { 0.0 } else { centerY - halfH }
        let right = if (left + newW > 1.0) { 1.0 } else { left + newW }
        let bottom = if (top + newH > 1.0) { 1.0 } else { top + newH }
        let frameL = left * this.overlayViewW
        let frameT = top * this.overlayViewH
        let frameW = (right - left) * this.overlayViewW
        let frameH = (bottom - top) * this.overlayViewH
        launch {
            this.cropLeft = left
            this.cropTop = top
            this.cropRight = right
            this.cropBottom = bottom
            this.frameLeftPx = frameL
            this.frameTopPx = frameT
            this.frameWidthPx = frameW
            this.frameHeightPx = frameH
        }
    }

    // Rotate by +90 degrees
    private func rotateRight(): Unit {
        let angle = this.rotationAngle + 90.0
        let newAngle = if (angle >= 360.0) { angle - 360.0 } else { angle }
        launch {
            this.rotationAngle = newAngle
            // Swap crop W/H after 90° rotation
            let cl = this.cropLeft
            let ct = this.cropTop
            let cr = this.cropRight
            let cb = this.cropBottom
            this.cropLeft = ct
            this.cropTop = 1.0 - cr
            this.cropRight = cb
            this.cropBottom = 1.0 - cl
        }
        Hilog.info(0, "CjTelegram", "[CropEditorScreen] rotateRight -> ${newAngle}")
    }

    // Rotate by -90 degrees
    private func rotateLeft(): Unit {
        let angle = this.rotationAngle - 90.0
        let newAngle = if (angle < 0.0) { angle + 360.0 } else { angle }
        launch {
            this.rotationAngle = newAngle
        }
        Hilog.info(0, "CjTelegram", "[CropEditorScreen] rotateLeft -> ${newAngle}")
    }

    // Reset crop to full image
    private func resetCrop(): Unit {
        launch {
            this.cropLeft = 0.0
            this.cropTop = 0.0
            this.cropRight = 1.0
            this.cropBottom = 1.0
            this.rotationAngle = 0.0
            this.rotationSlider = 0.0
            this.isCircleCrop = false
            this.selectedRatioIdx = 0
        }
    }

    // MARK: - Apply crop+rotate to PixelMap and return result
    private func applyCropAndRotate(): Unit {
        let capturedUri = this.assetUri
        let cropL = this.cropLeft
        let cropT = this.cropTop
        let cropR = this.cropRight
        let cropB = this.cropBottom
        let angle = this.rotationAngle + this.rotationSlider
        let isCircle = this.isCircleCrop

        launch { this.isProcessing = true }

        let _ = spawn {
            try {
                // Load source PixelMap from URI
                let pm = loadPixelMapFromUri(capturedUri)
                match (pm) {
                    case None =>
                        Hilog.info(0, "CjTelegram", "[CropEditorScreen] failed to load PixelMap from ${capturedUri}")
                        launch {
                            this.isProcessing = false
                            this.resultMessage = "Failed to load image"
                        }
                    case Some(pixelMap) =>
                        // 1. Rotate (PixelMap.rotate takes Float32 angle in degrees)
                        let totalAngle = angle
                        if (totalAngle != 0.0) {
                            let safeAngle = Float32(totalAngle)
                            pixelMap.rotate(safeAngle)
                        }

                        // 2. Crop: compute pixel Region from normalized rect
                        let info = pixelMap.getImageInfo()
                        let srcW = Int32(info.size.width)
                        let srcH = Int32(info.size.height)
                        let regionX = Int32(cropL * Float64(srcW))
                        let regionY = Int32(cropT * Float64(srcH))
                        let regionW = Int32((cropR - cropL) * Float64(srcW))
                        let regionH = Int32((cropB - cropT) * Float64(srcH))
                        let safeW: Int32 = if (regionW < Int32(1)) { Int32(1) } else { regionW }
                        let safeH: Int32 = if (regionH < Int32(1)) { Int32(1) } else { regionH }
                        let safeX: Int32 = if (regionX < Int32(0)) { Int32(0) } else { regionX }
                        let safeY: Int32 = if (regionY < Int32(0)) { Int32(0) } else { regionY }
                        Hilog.info(0, "CjTelegram",
                            "[CropEditorScreen] source=${srcW}x${srcH} region=${safeX},${safeY},${safeW}x${safeH}")
                        // ImageKit 在部分 JPEG PixelMap 上拒绝“与原图完全相同”的 crop
                        // Region（Cropping exceptions）。全幅裁剪本来就是 no-op，直接跳过；
                        // 只有边界真实变化时才调用 crop。
                        let isFullRegion = safeX == 0 && safeY == 0 && safeW >= srcW && safeH >= srcH
                        if (!isFullRegion) {
                            // IKSize = kit.ImageKit.Size (aliased to avoid ArkUI.Size ambiguity)
                            let boundedW = if (safeX + safeW > srcW) { srcW - safeX } else { safeW }
                            let boundedH = if (safeY + safeH > srcH) { srcH - safeY } else { safeH }
                            let region = Region(IKSize(boundedW, boundedH), safeX, safeY)
                            pixelMap.crop(region)
                        }

                        // 3. Circular mask (avatar use case): modify alpha channel per pixel
                        if (isCircle) {
                            applyCircularMask(pixelMap)
                        }

                        // 4. Store result and notify
                        getDrawingFlattenService().setLastResult(pixelMap)

                        let capturedPm = pixelMap
                        launch {
                            this.isProcessing = false
                            this.resultMessage = "Crop applied"
                            // iOS 的 Apply 完成后返回编辑器；旧实现停留在裁剪页，用户无法
                            // 判断结果已提交，也无法继续贴纸编辑流程。
                            routerPop()
                        }
                        this.onCropDone(Some(capturedPm))
                        Hilog.info(0, "CjTelegram", "[CropEditorScreen] crop+rotate done, uri=${capturedUri}")
                }
            } catch (e: BusinessException) {
                Hilog.info(0, "CjTelegram", "[CropEditorScreen] applyCropAndRotate error: ${e.message}")
                launch {
                    this.isProcessing = false
                    this.resultMessage = "Error: crop failed"
                }
                this.onCropDone(None)
            }
        }
    }

    // Ratio label text for a preset
    private func ratioLabel(idx: Int32): String {
        let presets = this.ratioPresets()
        let idxL = Int64(idx)
        if (idxL >= 0 && idxL < presets.size) {
            return presets[idxL].displayName()
        }
        return "Free"
    }

    // Crop overlay: draw the crop frame with corner handles
    // P2-084: @Builder must have no params (D-115); reads from @State frameLeftPx etc.
    @Builder
    func buildCropOverlay() {
        // Draw crop rectangle using Stack + absolute positioning
        Stack(alignContent: Alignment.TopStart) {
            // 预览遮罩；裁剪框由白色边线与四角手柄明确标识。
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0x66000000)

            // Crop frame border
            Column {
                Column {}
                    .width(this.frameWidthPx)
                    .height(this.frameHeightPx)
                    .border(width: 2, color: 0xFFFFFFFF, style: BorderStyle.Solid)
                    .backgroundColor(Color.Transparent)
            }
            .width(100.percent)
            .height(100.percent)
            .padding(left: this.frameLeftPx, top: this.frameTopPx)
            .alignItems(HorizontalAlign.Start)

            // Corner handles TL/TR/BL/BR — Column positioned absolutely
            Column {}
                .width(20).height(20)
                .backgroundColor(0xFFFFFFFF)
                .borderRadius(3)
                .position(x: this.frameLeftPx - 5.0, y: this.frameTopPx - 5.0)

            Column {}
                .width(20).height(20)
                .backgroundColor(0xFFFFFFFF)
                .borderRadius(3)
                .position(x: this.frameLeftPx + this.frameWidthPx - 15.0, y: this.frameTopPx - 5.0)

            Column {}
                .width(20).height(20)
                .backgroundColor(0xFFFFFFFF)
                .borderRadius(3)
                .position(x: this.frameLeftPx - 5.0, y: this.frameTopPx + this.frameHeightPx - 15.0)

            Column {}
                .width(20).height(20)
                .backgroundColor(0xFFFFFFFF)
                .borderRadius(3)
                .position(x: this.frameLeftPx + this.frameWidthPx - 15.0, y: this.frameTopPx + this.frameHeightPx - 15.0)
        }
        .width(100.percent)
        .height(100.percent)
        .onTouch({ event: TouchEvent =>
            if (event.touches.size > 0) {
                let tx = event.touches[0].x
                let ty = event.touches[0].y
                let vw = this.overlayViewW
                let vh = this.overlayViewH
                match (event.eventType) {
                    case TouchType.Down =>
                        this.handleCropTouchDown(tx, ty, vw, vh)
                        this.recomputeFramePx()
                    case TouchType.Move =>
                        this.handleCropTouchMove(tx, ty, vw, vh)
                        this.recomputeFramePx()
                    case TouchType.Up =>
                        this.draggingCorner = -1
                    case _ => ()
                }
            }
        })
    }

    // Touch began: find which corner was tapped (within 30px tolerance)
    private func handleCropTouchDown(tx: Float64, ty: Float64, viewW: Float64, viewH: Float64): Unit {
        let frameLeft = this.cropLeft * viewW
        let frameTop = this.cropTop * viewH
        let frameRight = this.cropRight * viewW
        let frameBottom = this.cropBottom * viewH
        let tolerance = 30.0

        if (tx < frameLeft + tolerance && ty < frameTop + tolerance) {
            this.draggingCorner = 0  // TL
        } else if (tx > frameRight - tolerance && ty < frameTop + tolerance) {
            this.draggingCorner = 1  // TR
        } else if (tx < frameLeft + tolerance && ty > frameBottom - tolerance) {
            this.draggingCorner = 2  // BL
        } else if (tx > frameRight - tolerance && ty > frameBottom - tolerance) {
            this.draggingCorner = 3  // BR
        } else {
            this.draggingCorner = -1
        }
    }

    // Touch moved: update crop rect based on dragged corner
    private func handleCropTouchMove(tx: Float64, ty: Float64, viewW: Float64, viewH: Float64): Unit {
        if (this.draggingCorner < 0 || viewW <= 0.0 || viewH <= 0.0) { return }

        let nx = tx / viewW
        let ny = ty / viewH
        let minSize = 0.1

        let corner = this.draggingCorner
        if (corner == 0) {
            // TL: move left+top, keep right+bottom
            let newL = if (nx < 0.0) { 0.0 } else if (nx > this.cropRight - minSize) { this.cropRight - minSize } else { nx }
            let newT = if (ny < 0.0) { 0.0 } else if (ny > this.cropBottom - minSize) { this.cropBottom - minSize } else { ny }
            this.cropLeft = newL
            this.cropTop = newT
        } else if (corner == 1) {
            // TR: move right+top, keep left+bottom
            let newR = if (nx > 1.0) { 1.0 } else if (nx < this.cropLeft + minSize) { this.cropLeft + minSize } else { nx }
            let newT = if (ny < 0.0) { 0.0 } else if (ny > this.cropBottom - minSize) { this.cropBottom - minSize } else { ny }
            this.cropRight = newR
            this.cropTop = newT
        } else if (corner == 2) {
            // BL: move left+bottom, keep right+top
            let newL = if (nx < 0.0) { 0.0 } else if (nx > this.cropRight - minSize) { this.cropRight - minSize } else { nx }
            let newB = if (ny > 1.0) { 1.0 } else if (ny < this.cropTop + minSize) { this.cropTop + minSize } else { ny }
            this.cropLeft = newL
            this.cropBottom = newB
        } else if (corner == 3) {
            // BR: move right+bottom, keep left+top
            let newR = if (nx > 1.0) { 1.0 } else if (nx < this.cropLeft + minSize) { this.cropLeft + minSize } else { nx }
            let newB = if (ny > 1.0) { 1.0 } else if (ny < this.cropTop + minSize) { this.cropTop + minSize } else { ny }
            this.cropRight = newR
            this.cropBottom = newB
        }
    }

    /** 路由参数可能是纯沙箱路径，预览层统一转换为 ArkUI 可读取的 file URI。 */
    private func previewAssetUri(): String {
        if (this.assetUri.isEmpty() || this.assetUri.startsWith("file://")) {
            return this.assetUri
        }
        return "file://" + this.assetUri
    }

    func build() {
            Column {
                // Preview area with crop overlay
                Stack(alignContent: Alignment.Center) {
                    if (this.assetUri.size > 0) {
                        Image(this.previewAssetUri())
                            .width(100.percent)
                            .height(100.percent)
                            .objectFit(ImageFit.Contain)
                            .rotate(angle: Float32(this.rotationAngle + this.rotationSlider))
                    } else {
                        Text("No image")
                            .fontSize(16)
                            .fontColor(0xAAAAAA)
                    }

                    // Crop frame overlay (gesture-driven, no-param per D-115)
                    this.buildCropOverlay()

                    // Circle mode overlay indicator
                    if (this.isCircleCrop) {
                        Column {}
                            .width(260)
                            .height(260)
                            .borderRadius(130)
                            .border(width: 3, color: 0xFFFFFF, style: BorderStyle.Solid)
                            .backgroundColor(Color.Transparent)
                    }
                }
                .width(100.percent)
                .layoutWeight(1)
                .backgroundColor(0x000000)
                .onAreaChange({ _: Area, newArea: Area =>
                    // P2-084: update overlay dimensions + recompute frame pixel positions
                    let nw = newArea.width.value
                    let nh = newArea.height.value
                    launch {
                        this.overlayViewW = nw
                        this.overlayViewH = nh
                    }
                    this.recomputeFramePx()
                })

                // Aspect ratio presets row
                Row {
                    ForEach(
                        Array<Int32>(6, { i: Int64 => Int32(i) }),
                        itemGenerator: { ratioVal: Int32, _listIdx: Int64 =>
                            Column {
                                Text(this.ratioLabel(ratioVal))
                                    .fontSize(12)
                                    .fontColor(if (this.selectedRatioIdx == ratioVal) { 0x007AFF } else { 0x8E8E93 })
                                    .fontWeight(if (this.selectedRatioIdx == ratioVal) { FontWeight.Bold } else { FontWeight.Normal })
                                    .textAlign(TextAlign.Center)
                            }
                            .width(48)
                            .height(36)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                            .onClick({ _evt =>
                                launch {
                                    this.selectedRatioIdx = ratioVal
                                }
                                this.applyAspectRatio(this.ratioPresets()[Int64(ratioVal)])
                            })
                        }
                    )
                }
                .width(100.percent)
                .height(44)
                .backgroundColor(0x1A1A1A)
                .justifyContent(FlexAlign.SpaceAround)
                .padding(left: 4, right: 4)

                // Rotation fine-tune slider
                Row {
                    Text("Angle: ${Int64(this.rotationSlider)}°")
                        .fontSize(12)
                        .fontColor(0xCCCCCC)
                        .width(80)
                    Slider(
                        value: this.rotationSlider,
                        min: -45.0,
                        max: 45.0,
                        style: SliderStyle.OutSet
                    )
                    .trackColor(0x555555)
                    .selectedColor(0x007AFF)
                    .layoutWeight(1)
                    .onChange({ value: Float64, _mode: SliderChangeMode =>
                        this.rotationSlider = value
                    })
                }
                .width(100.percent)
                .height(40)
                .backgroundColor(0x1A1A1A)
                .padding(left: 8, right: 8)

                // Rotation buttons + circle mode + reset
                Row {
                    Button("- 90°")
                        .fontSize(13)
                        .fontColor(0xFFFFFF)
                        .backgroundColor(0x333333)
                        .height(36)
                        .onClick({ _evt => this.rotateLeft() })

                    Blank()

                    Button("Circle")
                        .fontSize(12)
                        .fontColor(if (this.isCircleCrop) { 0x007AFF } else { 0x8E8E93 })
                        .backgroundColor(Color.Transparent)
                        .onClick({ _evt =>
                            launch { this.isCircleCrop = !this.isCircleCrop }
                        })

                    Blank()

                    Button(trSource("Reset"))
                        .fontSize(12)
                        .fontColor(0xFFD700)
                        .backgroundColor(Color.Transparent)
                        .onClick({ _evt => this.resetCrop() })

                    Blank()

                    Button("+ 90°")
                        .fontSize(13)
                        .fontColor(0xFFFFFF)
                        .backgroundColor(0x333333)
                        .height(36)
                        .onClick({ _evt => this.rotateRight() })
                }
                .width(100.percent)
                .height(48)
                .padding(left: 12, right: 12)
                .backgroundColor(0x1A1A1A)

                // Bottom action bar
                Row {
                    Button(trSource("Cancel"))
                        .fontSize(15)
                        .fontColor(0xFFFFFF)
                        .backgroundColor(Color.Transparent)
                        .onClick({ _evt =>
                            routerPop()
                        })

                    Blank()

                    if (this.isProcessing) {
                        LoadingProgress()
                            .width(28)
                            .height(28)
                            .color(0x007AFF)
                    } else if (this.resultMessage.size > 0) {
                        Text(this.resultMessage)
                            .fontSize(13)
                            .fontColor(0x34C759)
                    }

                    Blank()

                    Button(trSource("Apply"))
                        .fontSize(15)
                        .fontColor(0x007AFF)
                        .backgroundColor(Color.Transparent)
                        .enabled(!this.isProcessing)
                        .onClick({ _evt =>
                            this.applyCropAndRotate()
                        })
                }
                .width(100.percent)
                .height(52)
                .padding(left: 16, right: 16)
                .backgroundColor(0x000000)
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0x000000)
            .onAppear({ => this.ensureLoaded() })
    }
}

// ─────────────────────────────────────────────────────────────────
// Package-level helpers (P2-084)
// ─────────────────────────────────────────────────────────────────

// Load PixelMap from a URI string (file:// or sandbox path)
// Uses ImageSource from ImageKit (KB verified: createImageSource + createPixelMap)
func loadPixelMapFromUri(uri: String): Option<PixelMap> {
    if (uri.size == 0) { return None }
    try {
        let path = if (uri.startsWith("file://")) { uri[7..] } else { uri }
        let imageSource = createImageSource(path)
        let pm = imageSource.createPixelMap()
        return Some(pm)
    } catch (e: BusinessException) {
        Hilog.info(0, "CjTelegram", "[loadPixelMapFromUri] failed for uri=${uri}: ${e.message}")
        return None
    }
}

// Apply circular mask to a PixelMap by zeroing alpha for pixels outside center circle.
// This is the HarmonyOS equivalent of iOS CIContext masking for avatar round crop.
// Result is a circular image with transparent corners (requires RGBA_8888 format).
func applyCircularMask(pm: PixelMap): Unit {
    try {
        let info = pm.getImageInfo()
        let w = Int64(info.size.width)
        let h = Int64(info.size.height)
        if (w <= 0 || h <= 0) { return }

        let totalBytes = Int64(pm.getPixelBytesNumber())
        let buf = Array<UInt8>(totalBytes, repeat: 0)
        pm.readPixelsToBuffer(buf)

        let cx = Float64(w) / 2.0
        let cy = Float64(h) / 2.0
        let radius = if (cx < cy) { cx } else { cy }
        let radiusSq = radius * radius

        var py: Int64 = 0
        while (py < h) {
            var px: Int64 = 0
            while (px < w) {
                let dx = Float64(px) - cx
                let dy = Float64(py) - cy
                let distSq = dx * dx + dy * dy
                if (distSq > radiusSq) {
                    let offset = (py * w + px) * 4
                    // Set alpha to 0 (transparent) for pixels outside circle
                    // BGRA_8888: bytes are B, G, R, A
                    if (offset + 3 < totalBytes) {
                        buf[offset + 3] = 0
                    }
                }
                px = px + 1
            }
            py = py + 1
        }

        pm.writeBufferToPixels(buf)
        Hilog.info(0, "CjTelegram", "[applyCircularMask] applied ${w}x${h}")
    } catch (e: BusinessException) {
        Hilog.info(0, "CjTelegram", "[applyCircularMask] error: ${e.message}")
    }
}
