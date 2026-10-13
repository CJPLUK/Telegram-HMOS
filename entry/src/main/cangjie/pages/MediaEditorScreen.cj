package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import kit.AbilityKit.*
import kit.ImageKit.PixelMap
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import std.time.DateTime
import std.math.*
import std.sync.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.components.getEmptyAnimatedEmojiPixelMap
import ohos_app_cangjie_entry.interop.subscribe

private func editorPageClamp(value: Float64): Float64 {
    return if (value < 0.0) { 0.0 } else if (value > 1.0) { 1.0 } else { value }
}

private func initialAvatarCurveValues(): Array<Float64> {
    return Array<Float64>(20, { index: Int64 => Float64(index % 5) * 0.25 })
}

/**
 * MediaEditorScreen — 单项媒体编辑入口页（P2-210）（混合工程迁移版）
 *
 * iOS 对应：
 *   submodules/TelegramUI/Components/MediaEditorScreen/Sources/MediaEditorScreen.swift
 *   submodules/MediaPickerUI/Sources/MediaPickerPhotoToolbarView.swift  — 编辑工具栏
 *   LegacyMediaPickerGallery → TGPhotoEditorController（crop/draw）
 *
 * 功能：
 *   - 接收路由参数 assetUri（媒体资产 URI）
 *   - 顶部显示媒体缩略图预览
 *   - 底部工具栏三个编辑 tab：Crop / Draw / Trim
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容 + .onAppear
 *  - onReady param → takePending("MediaEditorScreen") 经 ensureLoaded()
 *  - pushPathByName → routerPush；pop → routerPop
 */
@HybridComponentEntry
@Component
public class MediaEditorScreen {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    /** 路由传入的资产 URI */
    @State var assetUri: String = ""

    /** 当前激活的编辑 tab："crop" / "draw" / "trim" */
    @State var activeTab: String = "crop"

    /** 是否已完成路由参数读取 */
    @State var didLoad: Bool = false
    @State var isAvatarMode: Bool = false
    @State var isSavingAvatar: Bool = false
    @State var avatarEditedPreview: ?PixelMap = None<PixelMap>
    @State var avatarMirrored: Bool = false
    @State var avatarQuarterTurns: Int64 = 0
    @State var avatarViewportScale: Float32 = Float32(1.0)
    @State var avatarViewportOffsetX: Float64 = 0.0
    @State var avatarViewportOffsetY: Float64 = 0.0
    @State var avatarImageWidth: Float64 = 1.0
    @State var avatarImageHeight: Float64 = 1.0
    @State var avatarEditorMode: String = "main"
    @State var adjustmentCategory: Int64 = 0
    @State var enhanceValue: Float64 = 0.0
    @State var brightnessValue: Float64 = 0.0
    @State var contrastValue: Float64 = 0.0
    @State var saturationValue: Float64 = 0.0
    @State var warmthValue: Float64 = 0.0
    @State var fadeValue: Float64 = 0.0
    @State var highlightsValue: Float64 = 0.0
    @State var shadowsValue: Float64 = 0.0
    @State var grainValue: Float64 = 0.0
    @State var vignetteValue: Float64 = 0.0
    @State var shadowsTintValue: Float64 = 0.0
    @State var highlightsTintValue: Float64 = 0.0
    @State var tintTarget: Int64 = 0
    @State var shadowsTintColor: Int64 = 0
    @State var highlightsTintColor: Int64 = 0
    @State var blurMode: Int64 = 0
    @State var blurValue: Float64 = 0.5
    @State var blurPositionX: Float64 = 0.5
    @State var blurPositionY: Float64 = 0.5
    @State var blurSize: Float64 = 0.24
    @State var blurFalloff: Float64 = 0.12
    @State var blurRotation: Float64 = 0.0
    @State var curveChannel: Int64 = 0
    @State var curveRevision: Int64 = 0
    private var initialEnhanceValue: Float64 = 0.0
    private var initialBrightnessValue: Float64 = 0.0
    private var initialContrastValue: Float64 = 0.0
    private var initialSaturationValue: Float64 = 0.0
    private var initialWarmthValue: Float64 = 0.0
    private var initialFadeValue: Float64 = 0.0
    private var initialHighlightsValue: Float64 = 0.0
    private var initialShadowsValue: Float64 = 0.0
    private var initialGrainValue: Float64 = 0.0
    private var initialVignetteValue: Float64 = 0.0
    private var initialShadowsTintValue: Float64 = 0.0
    private var initialHighlightsTintValue: Float64 = 0.0
    private var initialShadowsTintColor: Int64 = 0
    private var initialHighlightsTintColor: Int64 = 0
    private var initialBlurMode: Int64 = 0
    private var initialBlurValue: Float64 = 0.5
    private var initialBlurPositionX: Float64 = 0.5
    private var initialBlurPositionY: Float64 = 0.5
    private var initialBlurSize: Float64 = 0.24
    private var initialBlurFalloff: Float64 = 0.12
    private var initialBlurRotation: Float64 = 0.0
    private var blurTouchStartX: Float64 = 0.0
    private var blurTouchStartY: Float64 = 0.0
    private var blurStartPositionX: Float64 = 0.5
    private var blurStartPositionY: Float64 = 0.5
    private var blurLastPinchDistance: Float64 = 0.0
    private var blurActiveControl: Int64 = 0
    private var blurStartDistance: Float64 = 0.0
    private var blurStartRadius: Float64 = 0.0
    private var blurPreviewWidth: Float64 = 440.0
    private var blurPreviewHeight: Float64 = 440.0
    private var blurContext: CanvasRenderingContext2D = CanvasRenderingContext2D(
        RenderingContextSettings(antialias: true)
    )
    private var curveValues: Array<Float64> = initialAvatarCurveValues()
    private var initialCurveValues: Array<Float64> = initialAvatarCurveValues()
    private var curveSelectedField: Int64 = -1
    private var curveLastTouchY: Float64 = 0.0
    private var curveTouchMoved: Bool = false
    private var curveTapCount: Int32 = 0
    private var curveTapVersion: Int32 = 0
    private var curvePreviewWidth: Float64 = 440.0
    private var curvePreviewHeight: Float64 = 440.0
    private var curveHistogram: Array<Float64> = Array<Float64>(1024, repeat: 0.0)
    private var curvePreviewContext: CanvasRenderingContext2D = CanvasRenderingContext2D(
        RenderingContextSettings(antialias: true)
    )
    private var curveHistogramContext: CanvasRenderingContext2D = CanvasRenderingContext2D(
        RenderingContextSettings(antialias: true)
    )
    private var mediaToolsBase: ?PixelMap = None<PixelMap>
    private var avatarCropLastPinchDistance: Float64 = 0.0
    private var avatarCropTouchStartX: Float64 = 0.0
    private var avatarCropTouchStartY: Float64 = 0.0
    private var avatarCropBaseOffsetX: Float64 = 0.0
    private var avatarCropBaseOffsetY: Float64 = 0.0
    private var avatarViewportContext: CanvasRenderingContext2D = CanvasRenderingContext2D(
        RenderingContextSettings(antialias: true)
    )

    @State var loaded: Bool = false
    private let mediaEditorShownEvent: String = "settings.mediaEditor.shown"

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        subscribe(this.mediaEditorShownEvent, { _payload: String =>
            this.refreshAvatarEditedPreview()
        })

        // 原 .onReady 参数接收：assetUri（经 ParamStore takePending 取代 navDestination param）
        if (!this.didLoad) {
            let raw = takePending("MediaEditorScreen")
            if (raw.startsWith("avatar|")) {
                this.isAvatarMode = true
                this.assetUri = raw[7..raw.size]
                getDrawingFlattenService().clearLastResult()
                getDrawingService().resetState()
                this.setAvatarSystemBars(true)
            } else {
                this.assetUri = raw
            }
            this.didLoad = true
            Hilog.info(0, "CjTelegram", "[MediaEditorScreen] loaded uri=" + this.assetUri)
        }
    }

    /**
     * 打开绘制编辑器（DrawingScreen，P2-202/203 已实现）
     * P2-088: passes assetUri as base image for DrawingService
     */
    private func openDrawingEditor(): Unit {
        Hilog.info(0, "CjTelegram", "[MediaEditorScreen] openDrawingEditor uri=${this.assetUri}")
        if (!this.isAvatarMode) {
            routerPush("DrawingScreen", this.assetUri)
            return
        }
        // MediaEditor on iOS keeps one immutable subject and reuses the same drawing state.
        // Reopening Drawing must not use the previously flattened preview as a new base, or
        // every visit bakes the existing entities into the image a second time.
        match (getDrawingService().getBasePixelMap()) {
            case Some(_) =>
                this.avatarEditorMode = "drawing"
                return
            case None => ()
        }
        let uri = this.assetUri
        let _ = spawn {
            let source = match (getDrawingFlattenService().getLastResult()) {
                case Some(pixelMap) => Some(pixelMap)
                case None => loadPixelMapFromUri(uri)
            }
            match (source) {
                case Some(pixelMap) =>
                    // Gallery decoders can return RGBA while the compositor operates on BGRA.
                    // Normalize through the decoder only; crop rotation/mirroring remain values.
                    let normalized = normalizeAvatarPixelMap(pixelMap)
                    getDrawingService().setBasePixelMap(normalized)
                    launch { this.avatarEditorMode = "drawing" }
                case None => ()
            }
        }
    }

    /** 源端每次点击都在当前 cropRotation 上继续逆时针旋转九十度。 */
    private func rotateAvatar(): Unit {
        this.avatarQuarterTurns = (this.avatarQuarterTurns + 1) % 4
        this.clampAvatarViewportOffset()
    }

    /** 普通媒体编辑仍使用原裁剪器；头像模式不会调用该路由。 */
    private func openCropEditor(): Unit {
        routerPush("CropEditorScreen", this.assetUri)
    }

    /**
     * 连续编辑时把当前 PixelMap 固化为下一工具的输入；否则 Mirror/Draw/Crop 会各自
     * 从最初 URI 重开，后一步覆盖前一步。普通媒体模式仍直接沿用原路由。
     */
    private func openAvatarSubEditor(route: String): Unit {
        if (!this.isAvatarMode) {
            routerPush(route, this.assetUri)
            return
        }
        match (getDrawingFlattenService().getLastResult()) {
            case None => routerPush(route, this.assetUri)
            case Some(pixelMap) =>
                let _ = spawn {
                    let bytes = getImageCompressionService().compressPixelMapToJpeg(pixelMap, UInt8(94))
                    if (bytes.isEmpty()) { return }
                    let filesDir = getAppFilesDir()
                    if (filesDir.isEmpty()) { return }
                    let editDir = filesDir + "/avatar_edits"
                    try { FileIo.mkdir(editDir) } catch (_e: Exception) {}
                    let stamp = DateTime.now().toUnixTimeStamp().toSeconds()
                    let path = editDir + "/avatar_stage_${stamp}.jpg"
                    try {
                        let outFile = FileIo.open(path, mode: 0o1101)
                        FileIo.write(outFile.fd, bytes)
                        FileIo.close(outFile)
                        launch {
                            this.assetUri = "file://" + path
                            getDrawingFlattenService().clearLastResult()
                            routerPush(route, this.assetUri)
                        }
                    } catch (_e: Exception) {}
                }
        }
    }

    private func previewAssetUri(): String {
        if (this.assetUri.isEmpty() || this.assetUri.startsWith("file://")) {
            return this.assetUri
        }
        return "file://" + this.assetUri
    }

    private func refreshAvatarEditedPreview(): Unit {
        let resultPath = getDrawingFlattenService().getLastResultPath()
        if (!resultPath.isEmpty()) {
            let _ = spawn {
                match (loadPixelMapFromUri(resultPath)) {
                    case Some(pixelMap) =>
                        getDrawingFlattenService().setLastResult(pixelMap)
                        let info = pixelMap.getImageInfo()
                        launch {
                            this.assetUri = resultPath
                            this.avatarEditedPreview = Some(pixelMap)
                            this.avatarImageWidth = Float64(info.size.width)
                            this.avatarImageHeight = Float64(info.size.height)
                            this.clampAvatarViewportOffset()
                        }
                    case None => ()
                }
            }
            return
        }
        match (getDrawingFlattenService().getLastResult()) {
            case Some(pixelMap) =>
                let info = pixelMap.getImageInfo()
                this.avatarEditedPreview = Some(pixelMap)
                this.avatarImageWidth = Float64(info.size.width)
                this.avatarImageHeight = Float64(info.size.height)
                this.clampAvatarViewportOffset()
            case None => ()
        }
    }

    /** 源端 Mirror 在编辑器内直接切换镜像状态，不产生新页面。 */
    private func mirrorAvatar(): Unit {
        this.avatarMirrored = !this.avatarMirrored
    }

    private func ensureAvatarSourceMetadata(): Unit {
        if (!this.isAvatarMode || this.assetUri.isEmpty()) { return }
        let uri = this.assetUri
        let _ = spawn {
            let source = match (getDrawingFlattenService().getLastResult()) {
                case Some(pixelMap) => Some(pixelMap)
                case None => loadPixelMapFromUri(uri)
            }
            match (source) {
                case Some(pixelMap) =>
                    try {
                        let info = pixelMap.getImageInfo()
                        launch {
                            this.avatarImageWidth = Float64(info.size.width)
                            this.avatarImageHeight = Float64(info.size.height)
                            this.clampAvatarViewportOffset()
                        }
                    } catch (_: Exception) {}
                case None => ()
            }
        }
    }

    private func avatarSourceAspectFilledWidth(): Float64 {
        if (this.avatarImageWidth >= this.avatarImageHeight) {
            return 440.0 * this.avatarImageWidth / this.avatarImageHeight
        }
        return 440.0
    }

    private func avatarSourceAspectFilledHeight(): Float64 {
        if (this.avatarImageHeight >= this.avatarImageWidth) {
            return 440.0 * this.avatarImageHeight / this.avatarImageWidth
        }
        return 440.0
    }

    private func avatarAspectFilledWidth(): Float64 {
        return if (this.avatarQuarterTurns % 2 == 0) {
            this.avatarSourceAspectFilledWidth()
        } else {
            this.avatarSourceAspectFilledHeight()
        }
    }

    private func avatarAspectFilledHeight(): Float64 {
        return if (this.avatarQuarterTurns % 2 == 0) {
            this.avatarSourceAspectFilledHeight()
        } else {
            this.avatarSourceAspectFilledWidth()
        }
    }

    private func avatarPreviewScaleX(): Float32 {
        return if (this.avatarMirrored) { -this.avatarViewportScale } else { this.avatarViewportScale }
    }

    private func avatarPreviewRotation(): Float32 {
        return Float32(-90.0 * Float64(this.avatarQuarterTurns % 4))
    }

    private func clampAvatarViewportOffset(): Unit {
        let scale = Float64(this.avatarViewportScale)
        let maxX = max(0.0, (this.avatarAspectFilledWidth() * scale - 440.0) * 0.5)
        let maxY = max(0.0, (this.avatarAspectFilledHeight() * scale - 440.0) * 0.5)
        if (this.avatarViewportOffsetX < -maxX) { this.avatarViewportOffsetX = -maxX }
        if (this.avatarViewportOffsetX > maxX) { this.avatarViewportOffsetX = maxX }
        if (this.avatarViewportOffsetY < -maxY) { this.avatarViewportOffsetY = -maxY }
        if (this.avatarViewportOffsetY > maxY) { this.avatarViewportOffsetY = maxY }
    }

    /** CropScrollView.swift: minimumZoomScale 1, maximum 4, centered content and fast panning. */
    private func drawAvatarViewportHitLayer(): Unit {
        this.avatarViewportContext.clearRect(0.0, 0.0, 440.0, 440.0)
        this.avatarViewportContext.fillStyle = 0x01000000
        this.avatarViewportContext.fillRect(0.0, 0.0, 440.0, 440.0)
    }

    private func handleAvatarViewportTouch(event: TouchEvent): Unit {
        let count = event.touches.size
        if (count >= 2) {
            let first = event.touches[0]
            let second = event.touches[1]
            let dx = second.x - first.x
            let dy = second.y - first.y
            let distance = sqrt(dx * dx + dy * dy)
            if (event.eventType == TouchType.Down) {
                this.avatarCropLastPinchDistance = distance
            } else if (event.eventType == TouchType.Move && this.avatarCropLastPinchDistance > 1.0) {
                var nextScale = Float64(this.avatarViewportScale) * distance / this.avatarCropLastPinchDistance
                if (nextScale < 1.0) { nextScale = 1.0 }
                if (nextScale > 4.0) { nextScale = 4.0 }
                this.avatarViewportScale = Float32(nextScale)
                this.avatarCropLastPinchDistance = distance
                this.clampAvatarViewportOffset()
            }
            if (event.eventType == TouchType.Up || event.eventType == TouchType.Cancel) {
                this.avatarCropLastPinchDistance = 0.0
                this.clampAvatarViewportOffset()
            }
            return
        }
        if (count != 1) { return }
        let touch = event.touches[0]
        if (event.eventType == TouchType.Down) {
            this.avatarCropTouchStartX = touch.x
            this.avatarCropTouchStartY = touch.y
            this.avatarCropBaseOffsetX = this.avatarViewportOffsetX
            this.avatarCropBaseOffsetY = this.avatarViewportOffsetY
            this.avatarCropLastPinchDistance = 0.0
        } else if (event.eventType == TouchType.Move) {
            this.avatarViewportOffsetX = this.avatarCropBaseOffsetX + touch.x - this.avatarCropTouchStartX
            this.avatarViewportOffsetY = this.avatarCropBaseOffsetY + touch.y - this.avatarCropTouchStartY
            this.clampAvatarViewportOffset()
        } else if (event.eventType == TouchType.Up || event.eventType == TouchType.Cancel) {
            this.clampAvatarViewportOffset()
        }
    }

    private func hasAvatarEditedPreview(): Bool {
        return this.avatarEditedPreview.isSome()
    }

    /** MediaToolsScreen 在进入时保存 initialValues；Back reset，Done 保留。 */
    private func openMediaTools(): Unit {
        this.initialEnhanceValue = this.enhanceValue
        this.initialBrightnessValue = this.brightnessValue
        this.initialContrastValue = this.contrastValue
        this.initialSaturationValue = this.saturationValue
        this.initialWarmthValue = this.warmthValue
        this.initialFadeValue = this.fadeValue
        this.initialHighlightsValue = this.highlightsValue
        this.initialShadowsValue = this.shadowsValue
        this.initialGrainValue = this.grainValue
        this.initialVignetteValue = this.vignetteValue
        this.initialShadowsTintValue = this.shadowsTintValue
        this.initialHighlightsTintValue = this.highlightsTintValue
        this.initialShadowsTintColor = this.shadowsTintColor
        this.initialHighlightsTintColor = this.highlightsTintColor
        this.initialBlurMode = this.blurMode
        this.initialBlurValue = this.blurValue
        this.initialBlurPositionX = this.blurPositionX
        this.initialBlurPositionY = this.blurPositionY
        this.initialBlurSize = this.blurSize
        this.initialBlurFalloff = this.blurFalloff
        this.initialBlurRotation = this.blurRotation
        this.initialCurveValues = Array<Float64>(20, { index: Int64 => this.curveValues[index] })
        this.adjustmentCategory = 0
        match (this.mediaToolsBase) {
            case Some(pixelMap) =>
                this.refreshCurveHistogram(pixelMap)
                this.avatarEditorMode = "adjustments"
            case None =>
                match (getDrawingFlattenService().getLastResult()) {
                    case Some(pixelMap) =>
                        this.mediaToolsBase = Some(pixelMap)
                        this.refreshCurveHistogram(pixelMap)
                        this.avatarEditorMode = "adjustments"
                    case None =>
                        let uri = this.assetUri
                        let _ = spawn {
                            match (loadPixelMapFromUri(uri)) {
                                case Some(pixelMap) => launch {
                                    this.mediaToolsBase = Some(pixelMap)
                                    this.refreshCurveHistogram(pixelMap)
                                    this.avatarEditorMode = "adjustments"
                                }
                                case None => ()
                            }
                        }
                }
        }
    }

    /**
     * Our PixelMap backend flattens rotate/mirror/drawing into the rendered frame. Resetting the
     * retained tool values here prevents reopening MediaTools from applying the same values twice.
     */
    private func resetMediaToolsAfterFlattening(): Unit {
        this.enhanceValue = 0.0
        this.brightnessValue = 0.0
        this.contrastValue = 0.0
        this.saturationValue = 0.0
        this.warmthValue = 0.0
        this.fadeValue = 0.0
        this.highlightsValue = 0.0
        this.shadowsValue = 0.0
        this.grainValue = 0.0
        this.vignetteValue = 0.0
        this.shadowsTintValue = 0.0
        this.highlightsTintValue = 0.0
        this.shadowsTintColor = 0
        this.highlightsTintColor = 0
        this.blurMode = 0
        this.blurValue = 0.5
        this.blurPositionX = 0.5
        this.blurPositionY = 0.5
        this.blurSize = 0.24
        this.blurFalloff = 0.12
        this.blurRotation = 0.0
        this.curveValues = initialAvatarCurveValues()
        this.curveRevision += 1
        this.mediaToolsBase = None<PixelMap>
    }

    private func cancelMediaTools(): Unit {
        this.enhanceValue = this.initialEnhanceValue
        this.brightnessValue = this.initialBrightnessValue
        this.contrastValue = this.initialContrastValue
        this.saturationValue = this.initialSaturationValue
        this.warmthValue = this.initialWarmthValue
        this.fadeValue = this.initialFadeValue
        this.highlightsValue = this.initialHighlightsValue
        this.shadowsValue = this.initialShadowsValue
        this.grainValue = this.initialGrainValue
        this.vignetteValue = this.initialVignetteValue
        this.shadowsTintValue = this.initialShadowsTintValue
        this.highlightsTintValue = this.initialHighlightsTintValue
        this.shadowsTintColor = this.initialShadowsTintColor
        this.highlightsTintColor = this.initialHighlightsTintColor
        this.blurMode = this.initialBlurMode
        this.blurValue = this.initialBlurValue
        this.blurPositionX = this.initialBlurPositionX
        this.blurPositionY = this.initialBlurPositionY
        this.blurSize = this.initialBlurSize
        this.blurFalloff = this.initialBlurFalloff
        this.blurRotation = this.initialBlurRotation
        this.curveValues = Array<Float64>(20, { index: Int64 => this.initialCurveValues[index] })
        this.curveRevision += 1
        // The adjustment backend is preview-only until its renderer can preserve the complete
        // source reliably. Leaving either action restores the last committed editor subject.
        match (getDrawingFlattenService().getLastResult()) {
            case Some(pixelMap) => this.avatarEditedPreview = Some(pixelMap)
            case None => this.avatarEditedPreview = None<PixelMap>
        }
        this.avatarEditorMode = "main"
    }

    private func discardAvatarDrawing(): Unit {
        getDrawingService().resetState()
        this.avatarEditorMode = "main"
    }

    private func currentMediaToolValues(): AvatarMediaToolValues {
        let values = AvatarMediaToolValues()
        values.enhance = this.enhanceValue
        values.brightness = this.brightnessValue
        values.contrast = this.contrastValue
        values.saturation = this.saturationValue
        values.warmth = this.warmthValue
        values.fade = this.fadeValue
        values.highlights = this.highlightsValue
        values.shadows = this.shadowsValue
        values.grain = this.grainValue
        values.vignette = this.vignetteValue
        values.shadowsTintIntensity = this.shadowsTintValue
        values.highlightsTintIntensity = this.highlightsTintValue
        values.shadowsTintColor = this.shadowsTintColor
        values.highlightsTintColor = this.highlightsTintColor
        values.blurMode = this.blurMode
        values.blurIntensity = this.blurValue
        values.blurPositionX = this.blurPositionX
        values.blurPositionY = this.blurPositionY
        values.blurSize = this.blurSize
        values.blurFalloff = this.blurFalloff
        values.blurRotation = this.blurRotation
        var curveIndex: Int64 = 0
        while (curveIndex < 20) {
            values.curves[curveIndex] = this.curveValues[curveIndex]
            curveIndex += 1
        }
        return values
    }

    private func renderMediaTools(commit: Bool): Unit {
        match (this.mediaToolsBase) {
            case Some(base) =>
                let values = this.currentMediaToolValues()
                let _ = spawn {
                    match (renderAvatarMediaTools(base, values)) {
                        case Some(rendered) => launch {
                            this.avatarEditedPreview = Some(rendered)
                            if (commit) {
                                getDrawingFlattenService().setLastResult(rendered)
                                this.avatarEditorMode = "main"
                            }
                        }
                        case None => ()
                    }
                }
            case None => ()
        }
    }

    private func avatarEditedPreviewOrEmpty(): PixelMap {
        match (this.avatarEditedPreview) {
            case Some(pixelMap) => pixelMap
            case None => getEmptyAnimatedEmojiPixelMap()
        }
    }

    func build() {
        if (this.isAvatarMode) {
            this.buildAvatarEditor()
        } else {
            this.buildGenericMediaEditor()
        }
    }

    @Builder
    func buildGenericMediaEditor() {
        Column {
            // ── 媒体预览区 ──────────────────────────────────────────
            Stack(alignContent: Alignment.Center) {
                if (this.assetUri.size > 0) {
                    Image(this.previewAssetUri())
                        .width(100.percent)
                        .height(100.percent)
                        .objectFit(ImageFit.Contain)
                } else {
                    Text(trSource("Loading..."))
                        .fontSize(16)
                        .fontColor(0xAAAAAA)
                }

                // 激活编辑模式标签（overlay）
                if (this.activeTab == "crop") {
                    this.buildCropOverlay()
                } else if (this.activeTab == "trim") {
                    this.buildTrimOverlay()
                }
            }
            .width(100.percent)
            .layoutWeight(1)
            .backgroundColor(0x000000)

            // ── 编辑工具栏（Crop / Draw / Trim）────────────────────
            this.buildEditToolbar()
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x000000)
        .onAppear({ => this.ensureLoaded() })
    }

    private func setAvatarSystemBars(active: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(context) =>
                let _ = spawn {
                    try {
                        let window = getLastWindow(context)
                        window.setWindowSystemBarProperties(SystemBarProperties(
                            statusBarColor: if (active) { "#FF000000" } else { "#00000000" },
                            isStatusBarLightIcon: active,
                            statusBarContentColor: if (active) { "#FFFFFFFF" } else { "#FF000000" },
                            navigationBarColor: if (active) { "#FF000000" } else { "#00000000" },
                            isNavigationBarLightIcon: active,
                            navigationBarContentColor: if (active) { "#FFFFFFFF" } else { "#FF000000" }
                        ))
                    } catch (_: Exception) {}
                }
            case None => ()
        }
    }

    @Builder
    func buildAvatarEditor() {
        Stack(alignContent: Alignment.Center) {
            this.buildAvatarMainEditor()

            if (this.avatarEditorMode == "adjustments") {
                this.buildAvatarAdjustments()
            } else if (this.avatarEditorMode == "drawing") {
                DrawingScreenComponent(
                    baseQuarterTurns: this.avatarQuarterTurns,
                    baseMirrored: this.avatarMirrored,
                    persistResult: false,
                    onClose: { => this.discardAvatarDrawing() },
                    onDone: { => this.discardAvatarDrawing() }
                )
            }
        }
        .width(100.percent)
        .height(100.percent)
    }

    @Builder
    func buildAvatarMainEditor() {
        Column {
            Blank()

            Stack(alignContent: Alignment.Center) {
                if (this.hasAvatarEditedPreview()) {
                    Image(this.avatarEditedPreviewOrEmpty())
                        .width(this.avatarSourceAspectFilledWidth())
                        .height(this.avatarSourceAspectFilledHeight())
                        .objectFit(ImageFit.Fill)
                        .scale(x: this.avatarPreviewScaleX(), y: this.avatarViewportScale)
                        .rotate(angle: this.avatarPreviewRotation())
                        .translate(x: this.avatarViewportOffsetX, y: this.avatarViewportOffsetY)
                        .opacity(0.30)
                    Stack(alignContent: Alignment.Center) {
                        Image(this.avatarEditedPreviewOrEmpty())
                            .width(this.avatarSourceAspectFilledWidth())
                            .height(this.avatarSourceAspectFilledHeight())
                            .objectFit(ImageFit.Fill)
                            .scale(x: this.avatarPreviewScaleX(), y: this.avatarViewportScale)
                            .rotate(angle: this.avatarPreviewRotation())
                            .translate(x: this.avatarViewportOffsetX, y: this.avatarViewportOffsetY)
                            .onTouch({ event: TouchEvent => this.handleAvatarViewportTouch(event) })
                    }.width(100.percent).height(100.percent).borderRadius(1000).clip(true)
                } else {
                    Image(this.previewAssetUri())
                        .width(this.avatarSourceAspectFilledWidth())
                        .height(this.avatarSourceAspectFilledHeight())
                        .objectFit(ImageFit.Fill)
                        .scale(x: this.avatarPreviewScaleX(), y: this.avatarViewportScale)
                        .rotate(angle: this.avatarPreviewRotation())
                        .translate(x: this.avatarViewportOffsetX, y: this.avatarViewportOffsetY)
                        .opacity(0.30)
                    Stack(alignContent: Alignment.Center) {
                        Image(this.previewAssetUri())
                            .width(this.avatarSourceAspectFilledWidth())
                            .height(this.avatarSourceAspectFilledHeight())
                            .objectFit(ImageFit.Fill)
                            .scale(x: this.avatarPreviewScaleX(), y: this.avatarViewportScale)
                            .rotate(angle: this.avatarPreviewRotation())
                            .translate(x: this.avatarViewportOffsetX, y: this.avatarViewportOffsetY)
                            .onTouch({ event: TouchEvent => this.handleAvatarViewportTouch(event) })
                    }.width(100.percent).height(100.percent).borderRadius(1000).clip(true)
                }

                Circle()
                    .width(100.percent)
                    .height(100.percent)
                    .fill(Color.Transparent)
                    .stroke(0x55FFFFFF)
                    .strokeWidth(1)
                Canvas(this.avatarViewportContext)
                    .width(100.percent).height(100.percent)
                    .onReady({ => this.drawAvatarViewportHitLayer() })
                    .onTouch({ event: TouchEvent => this.handleAvatarViewportTouch(event) })
                    .onClick({ _ => () })
            }
            .width(100.percent)
            .aspectRatio(1.0)
            .clip(true)

            Blank()

            Row {
                Column {
                    Image(@r(app.media.avatar_editor_back))
                        .width(28).height(28).fillColor(0xFFFFFFFF)
                }
                .width(44).height(44).borderRadius(22)
                .backgroundColor(0xFF1C1C1E)
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .onClick({ _ =>
                    this.setAvatarSystemBars(false)
                    routerPop()
                })

                Blank()

                Row {
                    Column {
                        Image(@r(app.media.avatar_editor_crop))
                            .width(30).height(30).objectFit(ImageFit.Contain).fillColor(0xFFD8D8DC)
                    }
                    .width(44).height(44).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                    .onClick({ _ => this.rotateAvatar() })

                    Blank().width(10)

                    Column {
                        Image(@r(app.media.avatar_editor_mirror))
                            .width(30).height(30).objectFit(ImageFit.Contain).fillColor(0xFFD8D8DC)
                    }
                    .width(44).height(44).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                    .onClick({ _ => this.mirrorAvatar() })

                    Blank().width(10)

                    Column {
                        Image(@r(app.media.avatar_editor_pencil))
                            .width(30).height(30).objectFit(ImageFit.Contain).fillColor(0xFFD8D8DC)
                    }
                    .width(44).height(44).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                    .onClick({ _ => this.openDrawingEditor() })

                    Blank().width(10)

                    Column {
                        Image(@r(app.media.avatar_editor_adjustments))
                            .width(30).height(30).objectFit(ImageFit.Contain).fillColor(0xFFD8D8DC)
                    }
                    .width(44).height(44).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                    .onClick({ _ => this.openMediaTools() })
                }
                .width(206)
                .height(44)
                .borderRadius(22)
                .backgroundColor(0xFF1C1C1E)

                Blank()

                Column {
                    Image(@r(app.media.avatar_editor_done))
                        .width(30).height(30).fillColor(0xFFFFFFFF)
                }
                .width(44).height(44).borderRadius(22)
                .backgroundColor(0xFF0A84FF)
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .opacity(if (this.isSavingAvatar) { 0.45 } else { 1.0 })
                .onClick({ _ => this.commitAvatarEdit() })
            }
            .width(100.percent)
            .height(60)
            .padding(left: 16, right: 16, bottom: 8)
            .alignItems(VerticalAlign.Center)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFF000000)
        .onAppear({ =>
            this.ensureLoaded()
            this.refreshAvatarEditedPreview()
            this.ensureAvatarSourceMetadata()
        })
    }

    @Builder
    func buildAvatarAdjustments() {
        Stack(alignContent: Alignment.Bottom) {
            Column {
            Blank().height(163)

            Stack(alignContent: Alignment.Center) {
                if (this.hasAvatarEditedPreview()) {
                    Image(this.avatarEditedPreviewOrEmpty())
                        .width(this.avatarSourceAspectFilledWidth()).height(this.avatarSourceAspectFilledHeight())
                        .objectFit(ImageFit.Fill)
                        .scale(x: this.avatarPreviewScaleX(), y: this.avatarViewportScale)
                        .rotate(angle: this.avatarPreviewRotation())
                        .translate(x: this.avatarViewportOffsetX, y: this.avatarViewportOffsetY)
                        .opacity(0.30)
                    Stack(alignContent: Alignment.Center) {
                        Image(this.avatarEditedPreviewOrEmpty())
                            .width(this.avatarSourceAspectFilledWidth()).height(this.avatarSourceAspectFilledHeight())
                            .objectFit(ImageFit.Fill)
                            .scale(x: this.avatarPreviewScaleX(), y: this.avatarViewportScale)
                            .rotate(angle: this.avatarPreviewRotation())
                            .translate(x: this.avatarViewportOffsetX, y: this.avatarViewportOffsetY)
                    }.width(100.percent).height(100.percent).borderRadius(1000).clip(true)
                } else {
                    Image(this.previewAssetUri())
                        .width(this.avatarSourceAspectFilledWidth()).height(this.avatarSourceAspectFilledHeight())
                        .objectFit(ImageFit.Fill)
                        .scale(x: this.avatarPreviewScaleX(), y: this.avatarViewportScale)
                        .rotate(angle: this.avatarPreviewRotation())
                        .translate(x: this.avatarViewportOffsetX, y: this.avatarViewportOffsetY)
                        .opacity(0.30)
                    Stack(alignContent: Alignment.Center) {
                        Image(this.previewAssetUri())
                            .width(this.avatarSourceAspectFilledWidth()).height(this.avatarSourceAspectFilledHeight())
                            .objectFit(ImageFit.Fill)
                            .scale(x: this.avatarPreviewScaleX(), y: this.avatarViewportScale)
                            .rotate(angle: this.avatarPreviewRotation())
                            .translate(x: this.avatarViewportOffsetX, y: this.avatarViewportOffsetY)
                    }.width(100.percent).height(100.percent).borderRadius(1000).clip(true)
                }
                Circle().width(100.percent).height(100.percent)
                    .fill(Color.Transparent).stroke(0x55FFFFFF).strokeWidth(1)
                if (this.adjustmentCategory == 2 && this.blurMode != 0) {
                    this.buildBlurPreviewOverlay()
                } else if (this.adjustmentCategory == 3) {
                    this.buildCurvePreviewOverlay()
                }
            }
            .width(100.percent).aspectRatio(1.0).clip(true)

            Blank()
            }
            .width(100.percent).height(100.percent)

            Column {

            if (this.adjustmentCategory == 0) {
                Scroll {
                Column {
                    this.buildAdjustmentSlider("Enhance", this.enhanceValue, 0)
                    this.buildAdjustmentSlider("Brightness", this.brightnessValue, 1)
                    this.buildAdjustmentSlider("Contrast", this.contrastValue, 2)
                    this.buildAdjustmentSlider("Saturation", this.saturationValue, 3)
                    this.buildAdjustmentSlider("Warmth", this.warmthValue, 4)
                    this.buildAdjustmentSlider("Fade", this.fadeValue, 5)
                    this.buildAdjustmentSlider("Highlights", this.highlightsValue, 6)
                    this.buildAdjustmentSlider("Shadows", this.shadowsValue, 7)
                    this.buildAdjustmentSlider("Grain", this.grainValue, 8)
                    this.buildAdjustmentSlider("Vignette", this.vignetteValue, 9)
                }
                .padding(left: 28, right: 28)
                }.height(180).scrollBar(BarState.Off)
            } else if (this.adjustmentCategory == 1) {
                this.buildTintControls()
            } else if (this.adjustmentCategory == 2) {
                this.buildBlurControls()
            } else {
                this.buildCurveControls()
            }

            Row {
                Column {
                    Image(@r(app.media.avatar_editor_back)).width(28).height(28).fillColor(0xFFFFFFFF)
                }
                .width(44).height(44).borderRadius(22).backgroundColor(0xFF1C1C1E)
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .onClick({ _ => this.cancelMediaTools() })

                Blank()

                Row {
                    Column {
                        Stack(alignContent: Alignment.Center) {
                            Circle().width(33).height(33)
                                .fill(if (this.adjustmentCategory == 0) { 0xFFF2F2F7 } else { Color.Transparent })
                            Image(if (this.adjustmentCategory == 0) { @r(app.media.avatar_editor_adjustments) }
                                else if (this.hasAdjustmentValues()) { @r(app.media.avatar_editor_adjustments_active) }
                                else { @r(app.media.avatar_editor_adjustments_white) }).width(30).height(30)
                        }.width(44).height(44)
                    }
                        .width(44).height(44).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                        .onClick({ _ => this.adjustmentCategory = 0 })
                    Blank().width(10)
                    Column {
                        Stack(alignContent: Alignment.Center) {
                            Circle().width(33).height(33)
                                .fill(if (this.adjustmentCategory == 1) { 0xFFF2F2F7 } else { Color.Transparent })
                            Image(if (this.adjustmentCategory == 1) { @r(app.media.avatar_adjust_tint) }
                                else if (this.hasTintValues()) { @r(app.media.avatar_adjust_tint_active) }
                                else { @r(app.media.avatar_adjust_tint_white) }).width(30).height(30)
                        }.width(44).height(44)
                    }
                        .width(44).height(44).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                        .onClick({ _ => this.adjustmentCategory = 1 })
                    Blank().width(10)
                    Column {
                        Stack(alignContent: Alignment.Center) {
                            Circle().width(33).height(33)
                                .fill(if (this.adjustmentCategory == 2) { 0xFFF2F2F7 } else { Color.Transparent })
                            Image(if (this.adjustmentCategory == 2) { @r(app.media.avatar_adjust_blur) }
                                else if (this.hasBlurValues()) { @r(app.media.avatar_adjust_blur_active) }
                                else { @r(app.media.avatar_adjust_blur_white) }).width(30).height(30)
                        }.width(44).height(44)
                    }
                        .width(44).height(44).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                        .onClick({ _ => this.adjustmentCategory = 2 })
                    Blank().width(10)
                    Column {
                        Stack(alignContent: Alignment.Center) {
                            Circle().width(33).height(33)
                                .fill(if (this.adjustmentCategory == 3) { 0xFFF2F2F7 } else { Color.Transparent })
                            Image(if (this.adjustmentCategory == 3) { @r(app.media.avatar_adjust_curves) }
                                else if (this.hasCurveValues()) { @r(app.media.avatar_adjust_curves_active) }
                                else { @r(app.media.avatar_adjust_curves_white) }).width(30).height(30)
                        }.width(44).height(44)
                    }
                        .width(44).height(44).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                        .onClick({ _ =>
                            this.adjustmentCategory = 3
                            this.redrawCurveViews()
                        })
                }
                .width(206).height(44).borderRadius(22).backgroundColor(0xFF1C1C1E)

                Blank()

                Column {
                    Image(@r(app.media.avatar_editor_done)).width(30).height(30).fillColor(0xFFFFFFFF)
                }
                .width(44).height(44).borderRadius(22).backgroundColor(0xFF0A84FF)
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .onClick({ _ => this.cancelMediaTools() })
            }
            .width(100.percent).height(60).padding(left: 16, right: 16, bottom: 8)
            .alignItems(VerticalAlign.Center)
            }
            .width(100.percent)
        }
        .width(100.percent).height(100.percent).backgroundColor(0xFF000000)
        .onAppear({ => this.ensureLoaded() })
    }

    private func hasAdjustmentValues(): Bool {
        return this.enhanceValue != 0.0 || this.brightnessValue != 0.0 ||
            this.contrastValue != 0.0 || this.saturationValue != 0.0 ||
            this.warmthValue != 0.0 || this.fadeValue != 0.0 ||
            this.highlightsValue != 0.0 || this.shadowsValue != 0.0 ||
            this.grainValue != 0.0 || this.vignetteValue != 0.0
    }

    private func hasTintValues(): Bool {
        return (this.shadowsTintColor != 0 && this.shadowsTintValue != 0.0) ||
            (this.highlightsTintColor != 0 && this.highlightsTintValue != 0.0)
    }

    private func hasBlurValues(): Bool {
        return this.blurMode != 0 && this.blurValue != 0.0
    }

    @Builder
    func buildAdjustmentSlider(label: String, value: Float64, index: Int64) {
        Column {
            Row {
                Text(label).fontSize(13).fontWeight(FontWeight.Bold)
                    .fontColor(if (this.adjustmentValueFor(index) > 0.005 || this.adjustmentValueFor(index) < -0.005) { 0xFFFFFFFF } else { 0xFF808080 })
                Blank()
                Text(this.adjustmentValueText(this.adjustmentValueFor(index))).fontSize(13).fontWeight(FontWeight.Medium)
                    .fontColor(0xFFFFD300)
            }.width(100.percent).padding(left: 2, right: 2)
            Slider(value: value, min: if (index == 0 || index == 5 || index == 8 || index == 9) { 0.0 } else { -1.0 }, max: 1.0, style: SliderStyle.OutSet)
                .trackColor(0x1AFFFFFF).selectedColor(0xFFFFFFFF).blockColor(0xFFFFFFFF)
                .width(100.percent)
                .onChange({ updated: Float64, mode: SliderChangeMode =>
                    if (index == 0) { this.enhanceValue = updated }
                    else if (index == 1) { this.brightnessValue = updated }
                    else if (index == 2) { this.contrastValue = updated }
                    else if (index == 3) { this.saturationValue = updated }
                    else if (index == 4) { this.warmthValue = updated }
                    else if (index == 5) { this.fadeValue = updated }
                    else if (index == 6) { this.highlightsValue = updated }
                    else if (index == 7) { this.shadowsValue = updated }
                    else if (index == 8) { this.grainValue = updated }
                    else { this.vignetteValue = updated }
                    if (mode == SliderChangeMode.End) { this.renderMediaTools(false) }
                })
        }
        .width(100.percent).height(60)
    }

    private func adjustmentValueFor(index: Int64): Float64 {
        if (index == 0) { return this.enhanceValue }
        if (index == 1) { return this.brightnessValue }
        if (index == 2) { return this.contrastValue }
        if (index == 3) { return this.saturationValue }
        if (index == 4) { return this.warmthValue }
        if (index == 5) { return this.fadeValue }
        if (index == 6) { return this.highlightsValue }
        if (index == 7) { return this.shadowsValue }
        if (index == 8) { return this.grainValue }
        return this.vignetteValue
    }

    private func adjustmentValueText(value: Float64): String {
        if (value <= 0.005 && value >= -0.005) { return "" }
        let scaled = Int64(value * 100.0)
        let absolute = if (scaled < 0) { -scaled } else { scaled }
        let fraction = absolute % 100
        let fractionText = if (fraction < 10) { "0${fraction}" } else { "${fraction}" }
        let prefix = if (scaled > 0) { "+" } else if (scaled < 0) { "-" } else { "" }
        return "${prefix}${absolute / 100}.${fractionText}"
    }

    @Builder
    func buildTintControls() {
        Column {
            Row {
                Text(trSource("Shadows")).fontSize(15).fontWeight(FontWeight.Medium)
                    .fontColor(if (this.tintTarget == 0) { 0xFFFFFFFF } else { 0xFF8E8E93 })
                    .onClick({ _ => this.tintTarget = 0 })
                Blank()
                Text(trSource("Highlights")).fontSize(15).fontWeight(FontWeight.Medium)
                    .fontColor(if (this.tintTarget == 1) { 0xFFFFFFFF } else { 0xFF8E8E93 })
                    .onClick({ _ => this.tintTarget = 1 })
            }.width(100.percent).padding(left: 72, right: 72)
            Row {
                this.tintDot(0, Color.Transparent)
                this.tintDot(1, if (this.tintTarget == 0) { 0xFFFF4D4D } else { 0xFFEF9286 })
                this.tintDot(2, if (this.tintTarget == 0) { 0xFFF48022 } else { 0xFFEACEA2 })
                this.tintDot(3, if (this.tintTarget == 0) { 0xFFFFCD00 } else { 0xFFF2E17C })
                this.tintDot(4, if (this.tintTarget == 0) { 0xFF81D281 } else { 0xFFA4EDAE })
                this.tintDot(5, if (this.tintTarget == 0) { 0xFF71C5D6 } else { 0xFF89DCE5 })
                this.tintDot(6, if (this.tintTarget == 0) { 0xFF0072BC } else { 0xFF2E8BC8 })
                this.tintDot(7, if (this.tintTarget == 0) { 0xFF662D91 } else { 0xFFCD98E5 })
            }.width(100.percent).height(48).justifyContent(FlexAlign.SpaceAround)
            Slider(value: this.currentTintValue(), min: 0.0, max: 1.0, style: SliderStyle.OutSet)
                .trackColor(0x1AFFFFFF).selectedColor(0xFFFFFFFF).blockColor(0xFFFFFFFF)
                .width(88.percent).onChange({ value: Float64, _ =>
                    if (this.tintTarget == 0) { this.shadowsTintValue = value }
                    else { this.highlightsTintValue = value }
                    this.renderMediaTools(false)
                })
        }.height(180).justifyContent(FlexAlign.SpaceAround)
    }

    @Builder
    func tintDot(index: Int64, color: ResourceColor) {
        Circle().width(28).height(28).fill(color)
            .stroke(if (this.currentTintColor() == index) { 0xFFFFFFFF } else { 0xFF808080 })
            .strokeWidth(if (this.currentTintColor() == index) { 3 } else { 1 })
            .onClick({ _ =>
                if (this.tintTarget == 0) { this.shadowsTintColor = index }
                else { this.highlightsTintColor = index }
                this.renderMediaTools(false)
            })
    }

    private func currentTintValue(): Float64 {
        return if (this.tintTarget == 0) { this.shadowsTintValue } else { this.highlightsTintValue }
    }

    private func currentTintColor(): Int64 {
        return if (this.tintTarget == 0) { this.shadowsTintColor } else { this.highlightsTintColor }
    }

    @Builder
    func buildBlurControls() {
        Column {
            Text(trSource("Blur")).fontSize(13).fontWeight(FontWeight.Bold).fontColor(0xFF808080)
            Row {
                this.blurModeButton(0, "Off")
                this.blurModeButton(1, "Radial")
                this.blurModeButton(2, "Linear")
            }.width(246).justifyContent(FlexAlign.SpaceBetween)
            Slider(value: this.blurValue, min: 0.0, max: 1.0, style: SliderStyle.OutSet)
                .trackColor(0x1AFFFFFF)
                .selectedColor(if (this.blurMode == 0) { 0xFFFFFFFF } else { 0xFFFFD300 })
                .blockColor(0xFFFFFFFF)
                .enabled(this.blurMode != 0)
                .width(88.percent).onChange({ value: Float64, mode: SliderChangeMode =>
                    this.blurValue = value
                    if (mode == SliderChangeMode.End) { this.renderMediaTools(false) }
                })
        }.height(164).padding(top: 11).justifyContent(FlexAlign.SpaceBetween).alignItems(HorizontalAlign.Center)
    }

    @Builder
    func blurModeButton(index: Int64, label: String) {
        Column {
            if (index == 0) {
                Image(if (this.blurMode == index) { @r(app.media.avatar_blur_off_active) }
                    else { @r(app.media.avatar_blur_off_white) }).width(30).height(30)
            } else if (index == 1) {
                Image(if (this.blurMode == index) { @r(app.media.avatar_blur_radial_active) }
                    else { @r(app.media.avatar_blur_radial_white) }).width(30).height(30)
            } else {
                Image(if (this.blurMode == index) { @r(app.media.avatar_blur_linear_active) }
                    else { @r(app.media.avatar_blur_linear_white) }).width(30).height(30)
            }
            Text(label).fontSize(13).fontWeight(FontWeight.Bold)
                .fontColor(if (this.blurMode == index) { 0xFFFFD300 } else { 0xFF808080 })
                .margin(top: 3)
        }.width(66).onClick({ _ =>
            this.blurMode = index
            this.drawBlurPreviewOverlay()
            this.renderMediaTools(false)
        })
    }

    @Builder
    func buildBlurPreviewOverlay() {
        Canvas(this.blurContext)
            .width(100.percent).height(100.percent)
            .onReady({ => this.drawBlurPreviewOverlay() })
            .onTouch({ event => this.handleBlurPreviewTouch(event) })
    }

    private func drawBlurPreviewOverlay(): Unit {
        let width = this.blurPreviewWidth
        let height = this.blurPreviewHeight
        let shorter = if (width < height) { width } else { height }
        let centerX = this.blurPositionX * width
        let centerY = this.blurPositionY * height
        let inner = shorter * this.blurFalloff
        let outer = shorter * this.blurSize
        let ctx = this.blurContext
        ctx.clearRect(0.0, 0.0, width, height)
        ctx.strokeStyle = 0xFFFFFFFF
        ctx.fillStyle = 0xFFFFFFFF
        ctx.lineWidth = 1.5
        if (this.blurMode == 1) {
            var index: Int64 = 0
            while (index < 22) {
                let start = Float64(index) * 6.283185307179586 / 22.0
                ctx.beginPath(); ctx.arc(centerX, centerY, inner, start, start + 0.18); ctx.stroke()
                index += 1
            }
            index = 0
            while (index < 64) {
                let start = Float64(index) * 6.283185307179586 / 64.0
                ctx.beginPath(); ctx.arc(centerX, centerY, outer, start, start + 0.055); ctx.stroke()
                index += 1
            }
        } else {
            let lineHalf = width
            let sinValue = sin(this.blurRotation)
            let cosValue = cos(this.blurRotation)
            for (radius in [inner, outer]) {
                let dx = cosValue * lineHalf
                let dy = sinValue * lineHalf
                let nx = -sinValue * radius
                let ny = cosValue * radius
                ctx.beginPath(); ctx.moveTo(centerX - dx + nx, centerY - dy + ny)
                ctx.lineTo(centerX + dx + nx, centerY + dy + ny); ctx.stroke()
                ctx.beginPath(); ctx.moveTo(centerX - dx - nx, centerY - dy - ny)
                ctx.lineTo(centerX + dx - nx, centerY + dy - ny); ctx.stroke()
            }
        }
        ctx.beginPath(); ctx.arc(centerX, centerY, 8.0, 0.0, 6.283185307179586); ctx.fill()
    }

    private func handleBlurPreviewTouch(event: TouchEvent): Unit {
        let count = event.touches.size
        if (count >= 2) {
            let first = event.touches[0]
            let second = event.touches[1]
            let dx = second.x - first.x
            let dy = second.y - first.y
            let distance = sqrt(dx * dx + dy * dy)
            if (this.blurLastPinchDistance > 1.0 && event.eventType == TouchType.Move) {
                let ratio = distance / this.blurLastPinchDistance
                this.blurSize = this.blurSize * ratio
                this.blurFalloff = this.blurFalloff * ratio
                if (this.blurFalloff < 0.1) { this.blurFalloff = 0.1 }
                if (this.blurSize < this.blurFalloff + 0.02) { this.blurSize = this.blurFalloff + 0.02 }
                this.drawBlurPreviewOverlay()
            }
            this.blurLastPinchDistance = distance
            if (event.eventType == TouchType.Up || event.eventType == TouchType.Cancel) {
                this.blurLastPinchDistance = 0.0
                this.renderMediaTools(false)
            }
            return
        }
        if (count != 1) { return }
        let touch = event.touches[0]
        let area = event.target.getOrThrow().area
        this.blurPreviewWidth = area.width.value
        this.blurPreviewHeight = area.height.value
        let shorter = if (this.blurPreviewWidth < this.blurPreviewHeight) { this.blurPreviewWidth } else { this.blurPreviewHeight }
        let centerX = this.blurPositionX * this.blurPreviewWidth
        let centerY = this.blurPositionY * this.blurPreviewHeight
        let dx = touch.x - centerX
        let dy = touch.y - centerY
        let radialDistance = sqrt(dx * dx + dy * dy)
        let innerRadius = shorter * this.blurFalloff
        let outerRadius = shorter * this.blurSize
        if (event.eventType == TouchType.Down) {
            this.blurTouchStartX = touch.x
            this.blurTouchStartY = touch.y
            this.blurStartPositionX = this.blurPositionX
            this.blurStartPositionY = this.blurPositionY
            this.blurStartDistance = radialDistance
            if (radialDistance < 30.0) { this.blurActiveControl = 1 }
            else if (abs(radialDistance - innerRadius) < 30.0) {
                this.blurActiveControl = 2; this.blurStartRadius = innerRadius
            } else if (abs(radialDistance - outerRadius) < 30.0) {
                this.blurActiveControl = 3; this.blurStartRadius = outerRadius
            } else if (this.blurMode == 2) { this.blurActiveControl = 4 }
            else { this.blurActiveControl = 0 }
            return
        }
        if (event.eventType == TouchType.Move) {
            let moveX = touch.x - this.blurTouchStartX
            let moveY = touch.y - this.blurTouchStartY
            if (this.blurActiveControl == 1) {
                this.blurPositionX = editorPageClamp(this.blurStartPositionX + moveX / this.blurPreviewWidth)
                this.blurPositionY = editorPageClamp(this.blurStartPositionY + moveY / this.blurPreviewHeight)
            } else if (this.blurActiveControl == 2) {
                this.blurFalloff = (this.blurStartRadius + radialDistance - this.blurStartDistance) / shorter
                if (this.blurFalloff < 0.1) { this.blurFalloff = 0.1 }
                if (this.blurFalloff > this.blurSize - 0.02) { this.blurFalloff = this.blurSize - 0.02 }
            } else if (this.blurActiveControl == 3) {
                this.blurSize = (this.blurStartRadius + radialDistance - this.blurStartDistance) / shorter
                if (this.blurSize < this.blurFalloff + 0.02) { this.blurSize = this.blurFalloff + 0.02 }
            } else if (this.blurActiveControl == 4) {
                this.blurRotation += moveX * 0.004
                this.blurTouchStartX = touch.x
            }
            this.drawBlurPreviewOverlay()
        }
        if (event.eventType == TouchType.Up || event.eventType == TouchType.Cancel) {
            this.blurActiveControl = 0
            this.renderMediaTools(false)
        }
    }

    private func hasCurveValues(): Bool {
        let _ = this.curveRevision
        var index: Int64 = 0
        while (index < 20) {
            if (abs(this.curveValues[index] - Float64(index % 5) * 0.25) > 0.0001) { return true }
            index += 1
        }
        return false
    }

    private func curveColor(): Int64 {
        return match (this.curveChannel) {
            case 1 => 0xFFED3D4C
            case 2 => 0xFF10EE9D
            case 3 => 0xFF3377FB
            case _ => 0xFFFFFFFF
        }
    }

    private func curveValue(field: Int64): Float64 {
        let _ = this.curveRevision
        return this.curveValues[this.curveChannel * 5 + field]
    }

    private func curveValueText(field: Int64): String {
        let hundredths = Int64(this.curveValue(field) * 100.0 + 0.5)
        let fraction = hundredths % 100
        let suffix = if (fraction < 10) { "0${fraction}" } else { "${fraction}" }
        return "${hundredths / 100}.${suffix}"
    }

    /** Catmull-Rom sampling is the curveThroughPoints interpolation used by the source. */
    private func curveDisplaySample(input: Float64): Float64 {
        var sampleIndex = Int64(editorPageClamp(input) * 200.0)
        if (sampleIndex > 199) { sampleIndex = 199 }
        let segment = sampleIndex / 50
        let sample = sampleIndex % 50
        let t = Float64(sample * 2 + 1) / 100.0
        let t2 = t * t
        let t3 = t2 * t
        let offset = this.curveChannel * 5
        let first = if (segment == 0) { this.curveValues[offset] } else { this.curveValues[offset + segment - 1] }
        let second = this.curveValues[offset + segment]
        let third = this.curveValues[offset + segment + 1]
        let fourth = if (segment >= 3) { this.curveValues[offset + 4] } else { this.curveValues[offset + segment + 2] }
        return editorPageClamp(0.5 * (2.0 * second + (third - first) * t +
            (2.0 * first - 5.0 * second + 4.0 * third - fourth) * t2 +
            (3.0 * second - first - 3.0 * third + fourth) * t3))
    }

    private func drawCurvePreview(): Unit {
        let ctx = this.curvePreviewContext
        let width = this.curvePreviewWidth
        let height = this.curvePreviewHeight
        ctx.clearRect(0.0, 0.0, width, height)
        ctx.strokeStyle = 0x80FFFFFF
        ctx.lineWidth = 1.0
        var divider: Int64 = 1
        while (divider < 5) {
            let x = width * Float64(divider) / 5.0
            ctx.beginPath(); ctx.moveTo(x, 0.0); ctx.lineTo(x, height); ctx.stroke()
            divider += 1
        }
        var guideX: Float64 = 0.0
        while (guideX < width) {
            let endX = min(width, guideX + 7.0)
            ctx.beginPath()
            ctx.moveTo(guideX, height - guideX * height / width)
            ctx.lineTo(endX, height - endX * height / width)
            ctx.stroke()
            guideX += 11.0
        }
        ctx.strokeStyle = this.curveColor()
        ctx.lineWidth = 2.0
        ctx.beginPath()
        var point: Int64 = 0
        while (point <= 200) {
            let x = width * Float64(point) / 200.0
            let y = height * (1.0 - this.curveDisplaySample(Float64(point) / 200.0))
            if (point == 0) { ctx.moveTo(x, y) } else { ctx.lineTo(x, y) }
            point += 1
        }
        ctx.stroke()
    }

    private func drawCurveHistogram(): Unit {
        let ctx = this.curveHistogramContext
        let width: Float64 = 360.0
        let height: Float64 = 85.0
        ctx.clearRect(0.0, 0.0, width, height)
        ctx.fillStyle = this.curveColor()
        ctx.beginPath(); ctx.moveTo(0.0, height)
        let offset = this.curveChannel * 256
        var index: Int64 = 0
        while (index < 256) {
            let x = width * Float64(index) / 255.0
            let y = height * (1.0 - this.curveHistogram[offset + index])
            ctx.lineTo(x, y)
            index += 1
        }
        ctx.lineTo(width, height); ctx.closePath(); ctx.fill()
    }

    private func redrawCurveViews(): Unit {
        this.drawCurvePreview()
        this.drawCurveHistogram()
    }

    /** MediaEditorHistogram.swift uses 256 bins for RGB and Rec.601 luminance. */
    private func refreshCurveHistogram(pixelMap: PixelMap): Unit {
        let _ = spawn {
            try {
                let info = pixelMap.getImageInfo()
                let width = Int64(info.size.width)
                let height = Int64(info.size.height)
                let pixels = Array<UInt8>(Int64(pixelMap.getPixelBytesNumber()), repeat: 0)
                pixelMap.readPixelsToBuffer(pixels)
                let bins = Array<Int64>(1024, repeat: 0)
                var pixel: Int64 = 0
                while (pixel < width * height) {
                    let byte = pixel * 4
                    let blue = Int64(pixels[byte])
                    let green = Int64(pixels[byte + 1])
                    let red = Int64(pixels[byte + 2])
                    let luma = (red * 299 + green * 587 + blue * 114) / 1000
                    bins[red] += 1
                    bins[256 + green] += 1
                    bins[512 + blue] += 1
                    bins[768 + luma] += 1
                    pixel += 1
                }
                let normalized = Array<Float64>(1024, repeat: 0.0)
                var channel: Int64 = 0
                while (channel < 4) {
                    var maximum: Int64 = 1
                    var bin: Int64 = 0
                    while (bin < 256) {
                        maximum = max(maximum, bins[channel * 256 + bin])
                        bin += 1
                    }
                    bin = 0
                    while (bin < 256) {
                        normalized[channel * 256 + bin] = Float64(bins[channel * 256 + bin]) / Float64(maximum)
                        bin += 1
                    }
                    channel += 1
                }
                let ordered = Array<Float64>(1024, repeat: 0.0)
                var bin: Int64 = 0
                while (bin < 256) {
                    ordered[bin] = normalized[768 + bin]
                    ordered[256 + bin] = normalized[bin]
                    ordered[512 + bin] = normalized[256 + bin]
                    ordered[768 + bin] = normalized[512 + bin]
                    bin += 1
                }
                launch {
                    this.curveHistogram = ordered
                    this.drawCurveHistogram()
                }
            } catch (_: Exception) {
                Hilog.info(0, "CjTelegram", "[MediaEditorScreen] histogram generation failed")
            }
        }
    }

    private func handleCurveTouch(event: TouchEvent): Unit {
        if (event.touches.size != 1) { return }
        let touch = event.touches[0]
        let area = event.target.getOrThrow().area
        this.curvePreviewWidth = area.width.value
        this.curvePreviewHeight = area.height.value
        if (event.eventType == TouchType.Down) {
            var field = Int64(touch.x / (this.curvePreviewWidth / 5.0))
            if (field < 0) { field = 0 }
            if (field > 4) { field = 4 }
            this.curveSelectedField = field
            this.curveLastTouchY = touch.y
            this.curveTouchMoved = false
        } else if (event.eventType == TouchType.Move && this.curveSelectedField >= 0) {
            let translation = touch.y - this.curveLastTouchY
            let delta = min(2.0, -translation / 8.0) / 100.0
            let index = this.curveChannel * 5 + this.curveSelectedField
            this.curveValues[index] = editorPageClamp(this.curveValues[index] + delta)
            this.curveLastTouchY = touch.y
            this.curveTouchMoved = true
            this.curveRevision += 1
            this.drawCurvePreview()
        } else if (event.eventType == TouchType.Up || event.eventType == TouchType.Cancel) {
            if (this.curveTouchMoved) { this.renderMediaTools(false) }
            this.curveSelectedField = -1
        }
    }

    private func handleCurveTap(): Unit {
        if (this.curveTouchMoved) { this.curveTouchMoved = false; return }
        this.curveTapCount += 1
        this.curveTapVersion += 1
        let version = this.curveTapVersion
        if (this.curveTapCount >= 2) {
            this.curveTapCount = 0
            var field: Int64 = 0
            while (field < 5) {
                this.curveValues[this.curveChannel * 5 + field] = Float64(field) * 0.25
                field += 1
            }
            this.curveRevision += 1
            this.drawCurvePreview()
            this.renderMediaTools(false)
        } else {
            let _ = spawn {
                sleep(Duration.millisecond * 300)
                launch { if (this.curveTapVersion == version) { this.curveTapCount = 0 } }
            }
        }
    }

    @Builder
    func buildCurvePreviewOverlay() {
        Stack(alignContent: Alignment.Bottom) {
            Canvas(this.curvePreviewContext)
                .width(100.percent).height(100.percent)
                .onReady({ => this.drawCurvePreview() })
                .onTouch({ event: TouchEvent => this.handleCurveTouch(event) })
                .onClick({ _ => this.handleCurveTap() })
            Row {
                Text(this.curveValueText(0)).fontSize(13).fontWeight(FontWeight.Medium).fontColor(0xBFFFFFFF)
                Text(this.curveValueText(1)).fontSize(13).fontWeight(FontWeight.Medium).fontColor(0xBFFFFFFF)
                Text(this.curveValueText(2)).fontSize(13).fontWeight(FontWeight.Medium).fontColor(0xBFFFFFFF)
                Text(this.curveValueText(3)).fontSize(13).fontWeight(FontWeight.Medium).fontColor(0xBFFFFFFF)
                Text(this.curveValueText(4)).fontSize(13).fontWeight(FontWeight.Medium).fontColor(0xBFFFFFFF)
            }
            .width(100.percent).padding(bottom: 5).justifyContent(FlexAlign.SpaceAround)
        }.width(100.percent).height(100.percent).borderRadius(1000).clip(true)
    }

    @Builder
    func buildCurveControls() {
        Column {
            Row {
                this.curveChannelButton(0, "All")
                this.curveChannelButton(1, "Red")
                this.curveChannelButton(2, "Green")
                this.curveChannelButton(3, "Blue")
            }.width(100.percent).height(27).justifyContent(FlexAlign.SpaceEvenly)
            Canvas(this.curveHistogramContext)
                .width(100.percent).height(85)
                .onReady({ => this.drawCurveHistogram() })
                .margin(top: 3)
        }.height(126).padding(left: 24, right: 24, top: 11)
    }

    @Builder
    func curveChannelButton(index: Int64, label: String) {
        Text(label).fontSize(13).fontWeight(FontWeight.Bold)
            .fontColor(if (this.curveChannel == index) { 0xFFFFFFFF } else { 0xFF808080 })
            .width(64).height(27).textAlign(TextAlign.Center)
            .onClick({ _ =>
                this.curveChannel = index
                this.redrawCurveViews()
            })
    }

    /**
     * Crop 模式叠加层
     */
    @Builder
    func buildCropOverlay() {
        Stack(alignContent: Alignment.Center) {
            Column {}
                .width(80.percent)
                .height(80.percent)
                .border(width: 2, color: 0xFFFFFF, style: BorderStyle.Solid)
        }
        .width(100.percent)
        .height(100.percent)
    }

    /**
     * Trim 模式叠加层 — 视频时间轴占位
     */
    @Builder
    func buildTrimOverlay() {
        Column {
            Blank()
            Text("[Trim: video timeline — deferred]")
                .fontSize(11)
                .fontColor(0xCCCCCC)
                .backgroundColor(0x88000000)
                .padding(left: 8, right: 8, top: 4, bottom: 4)
                .borderRadius(4)
                .textAlign(TextAlign.Center)
                .margin(bottom: 8)
        }
        .width(100.percent)
        .height(100.percent)
        .alignItems(HorizontalAlign.Center)
    }

    /**
     * 底部编辑工具栏
     */
    @Builder
    func buildEditToolbar() {
        Column {
            // 操作栏：Cancel / Done
            Row {
                Button(trSource("Cancel"))
                    .fontSize(15)
                    .fontColor(0xFFFFFF)
                    .backgroundColor(Color.Transparent)
                    .onClick({ _evt =>
                        if (this.isAvatarMode) { this.setAvatarSystemBars(false) }
                        routerPop()
                        Hilog.info(0, "CjTelegram", "[MediaEditorScreen] cancelled")
                    })

                Blank()

                Button(trSource("Done"))
                    .fontSize(15)
                    .fontColor(0x007AFF)
                    .backgroundColor(Color.Transparent)
                    .onClick({ _evt =>
                        if (this.isAvatarMode) {
                            this.commitAvatarEdit()
                            return
                        }
                        // P2-088: check if flatten result available (from drawing or crop editor)
                        let flattenSvc = getDrawingFlattenService()
                        let hasResult = match (flattenSvc.getLastResult()) {
                            case Some(_) => true
                            case None => false
                        }
                        Hilog.info(0, "CjTelegram", "[MediaEditorScreen] done hasEditResult=${hasResult} uri=${this.assetUri}")
                        if (hasResult && getMiscSettingsStore().getSaveEditedPhotos()) {
                            this.saveEditedPhotoToGallery()
                        }
                        routerPop()
                    })
                    .enabled(!this.isSavingAvatar)
            }
            .width(100.percent)
            .height(44)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)

            // Tab 行：Crop / Draw / Trim
            Row {
                this.buildTabButton("crop", "Crop")
                Blank()
                this.buildTabButton("draw", "Draw")
                Blank()
                this.buildTabButton("trim", "Trim")
            }
            .width(100.percent)
            .height(56)
            .padding(left: 24, right: 24, bottom: 8)
            .alignItems(VerticalAlign.Center)
        }
        .width(100.percent)
        .backgroundColor(0x1A1A1A)
    }

    private func saveEditedPhotoToGallery(): Unit {
        let edited = getDrawingFlattenService().getLastResult()
        match (edited) {
            case None => ()
            case Some(pixelMap) =>
                let _ = spawn {
                    let bytes = getImageCompressionService().compressPixelMapToJpeg(pixelMap, UInt8(92))
                    if (bytes.isEmpty()) { return }
                    let filesDir = getAppFilesDir()
                    if (filesDir.isEmpty()) { return }
                    let editedDir = filesDir + "/edited"
                    try { FileIo.mkdir(editedDir) } catch (_e: Exception) {}
                    let stamp = DateTime.now().toUnixTimeStamp().toMilliseconds()
                    let editedPath = editedDir + "/edited_${stamp}.jpg"
                    try {
                        let file = FileIo.open(editedPath, mode: 0o1101)
                        FileIo.write(file.fd, bytes)
                        FileIo.close(file)
                        getSaveToCameraRollService().saveImageToGallery(editedPath, { ok: Bool =>
                            Hilog.info(0, "CjTelegram", "[MediaEditorScreen] save edited photo result=${ok}")
                        })
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[MediaEditorScreen] save edited photo failed: ${e}")
                    }
                }
        }
    }

    /**
     * 单个 tab 按钮（Crop / Draw / Trim）
     */
    @Builder
    func buildTabButton(tabId: String, label: String) {
        Column {
            Text(label)
                .fontSize(14)
                .fontColor(if (this.activeTab == tabId) { 0x007AFF } else { 0x8E8E93 })
                .fontWeight(if (this.activeTab == tabId) { FontWeight.Bold } else { FontWeight.Normal })
                .textAlign(TextAlign.Center)

            Column {}
                .width(4)
                .height(4)
                .borderRadius(2)
                .backgroundColor(if (this.activeTab == tabId) { 0x007AFF } else { Color.Transparent })
                .margin(top: 3)
        }
        .width(64)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _evt =>
            if (tabId == "draw") {
                this.openDrawingEditor()
            } else if (tabId == "crop") {
                this.openCropEditor()
            } else {
                launch {
                    this.activeTab = tabId
                }
                Hilog.info(0, "CjTelegram", "[MediaEditorScreen] tab=" + tabId)
            }
        })
    }

    private func commitAvatarEdit(): Unit {
        if (this.isSavingAvatar || this.assetUri.size == 0) { return }
        this.isSavingAvatar = true
        let uri = this.assetUri
        let viewportScale = Float64(this.avatarViewportScale)
        let viewportOffsetX = this.avatarViewportOffsetX
        let viewportOffsetY = this.avatarViewportOffsetY
        let quarterTurns = this.avatarQuarterTurns
        let mirrored = this.avatarMirrored
        let _ = spawn {
            var bytes = Array<UInt8>(0, repeat: 0)
            let source = match (getDrawingFlattenService().getLastResult()) {
                case Some(pixelMap) => Some(pixelMap)
                case None => loadPixelMapFromUri(uri)
            }
            match (source) {
                case Some(pixelMap) =>
                    match (renderAvatarViewportCrop(pixelMap, viewportScale,
                        viewportOffsetX, viewportOffsetY, 440.0, quarterTurns, mirrored)) {
                        case Some(cropped) =>
                            let info = cropped.getImageInfo()
                            if (info.size.width > 1280 || info.size.height > 1280) {
                                let factor = Float32(1280.0) / Float32(max(info.size.width, info.size.height))
                                cropped.scale(factor, factor)
                            }
                            bytes = getImageCompressionService().compressPixelMapToJpeg(cropped, UInt8(88))
                        case None => ()
                    }
                case None => ()
            }
            if (!bytes.isEmpty()) {
                let result = getSettingsService().uploadAndSetProfilePhoto(bytes, "profile.jpg")
                Hilog.info(0, "CjTelegram", "[MediaEditorScreen] avatar upload success=${result.success}")
                if (result.success) {
                    match (getRealAuthService().getCurrentUser()) {
                        case Some(user) =>
                            let filesDir = getAppFilesDir()
                            if (!filesDir.isEmpty()) {
                                let avatarDir = filesDir + "/avatars"
                                try { FileIo.mkdir(avatarDir) } catch (_e: Exception) {}
                                let stamp = DateTime.now().toUnixTimeStamp().toMilliseconds()
                                let avatarPath = avatarDir + "/avatar_${user.id}_${stamp}.jpg"
                                try {
                                    let outFile = FileIo.open(avatarPath, mode: 0o1101)
                                    FileIo.write(outFile.fd, bytes)
                                    FileIo.close(outFile)
                                    getUserPhotoService().setUserPhotoPath(user.id, "file://" + avatarPath)
                                } catch (e: Exception) {
                                    Hilog.info(0, "CjTelegram", "[MediaEditorScreen] avatar cache save error: ${e}")
                                }
                            }
                        case None => ()
                    }
                    getDrawingFlattenService().clearLastResult()
                    launch {
                        this.isSavingAvatar = false
                        this.setAvatarSystemBars(false)
                        routerPop()
                    }
                    return
                }
            }
            launch { this.isSavingAvatar = false }
        }
    }
}
