package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import kit.ImageKit.PixelMap
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*
import kit.CoreFileKit.*
import std.time.DateTime

// DrawingScreen — full drawing editor host page（混合工程迁移版）
// Adapted from iOS DrawingUI/Sources/DrawingScreen.swift
//
// Hosts DrawingScreenComponent (canvas) and provides navigation to ColorPickerScreen.
// The drawing result (strokes) is available via getDrawingService() after dismissal.
//
// 混合迁移改动（recipe §12 Phase 4）：
//  - @Component → @HybridComponentEntry
//  - 去掉 @Consume NavPathStack
//  - build() 根去掉 NavDestination 包裹，只留内容（内部 Column）
//  - pushPathByName("ColorPickerScreen","") → routerPush("ColorPickerScreen")
//  - pageStack.pop(animated) → routerPop()
//  - aboutToAppear（resetState + 读 color）+ .onReady 参数接收（base image URI）合并进
//    ensureLoaded()：param 经 takePending("DrawingScreen") 取；根 Column .onAppear 触发
//  - 源页 hideTitleBar(true)，故 ArkTS 壳 hideTitleBar(true)

@HybridComponentEntry
@Component
public class DrawingScreen {
    @State var strokeCount: Int64 = 0
    @State var colorPreviewARGB: UInt32 = 0xFF000000
    @State var isReady: Bool = false
    // P2-088: base asset URI (passed from MediaEditorScreen for base image flatten)
    @State var baseAssetUri: String = ""
    @State var loaded: Bool = false

    // Callback invoked when user taps "Done" (optional — caller can read DrawingService)
    public var onDone: () -> Unit = { => }
    // Callback invoked when user taps "Cancel"
    public var onCancel: () -> Unit = { => }

    private func svc(): DrawingService {
        return getDrawingService()
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true

        // 原 aboutToAppear 逻辑：重置绘制状态并回读当前颜色
        let service = this.svc()
        service.resetState()
        this.strokeCount = 0
        let color = service.getCurrentColor()
        this.colorPreviewARGB = color.toUInt32ARGB()

        // 原 .onReady 参数接收：base image URI（经 ParamStore takePending 取代 navDestination param）
        let uri = takePending("DrawingScreen")
        if (uri.size > 0) {
            // P2-088: load base image for flatten compositing
            let capturedUri = uri
            let _ = spawn {
                let pm = loadPixelMapFromUri(capturedUri)
                match (pm) {
                    case Some(pixelMap) =>
                        getDrawingService().setBasePixelMap(pixelMap)
                        Hilog.info(0, "CjTelegram", "[DrawingScreen] base image set uri=${capturedUri}")
                        launch { this.isReady = true }
                    case None =>
                        Hilog.info(0, "CjTelegram", "[DrawingScreen] no base image for uri=${capturedUri}")
                        launch { this.isReady = true }
                }
            }
        } else {
            this.isReady = true
        }
        this.baseAssetUri = uri
    }

    private func refreshColorPreview(): Unit {
        let color = this.svc().getCurrentColor()
        this.colorPreviewARGB = color.toUInt32ARGB()
    }

    private func openColorPicker(): Unit {
        routerPush("ColorPickerScreen")
    }

    private func finishDrawing(): Unit {
        let flatten = getDrawingFlattenService()
        flatten.invokeFlattenCallback()
        let composed = match (flatten.getLastResult()) {
            case Some(_) =>
                match (this.svc().getBasePixelMap()) {
                    case Some(base) => flatten.renderStrokesOntoBase(
                        base,
                        this.svc().getStrokes(),
                        this.svc().getCanvasWidth(),
                        this.svc().getCanvasHeight()
                    )
                    case None => flatten.getLastResult()
                }
            case None => None<PixelMap>
        }
        match (composed) {
            case Some(pixelMap) =>
                flatten.setLastResult(pixelMap)
                let bytes = getImageCompressionService().compressPixelMapToJpeg(pixelMap, UInt8(94))
                let filesDir = getAppFilesDir()
                if (!bytes.isEmpty() && !filesDir.isEmpty()) {
                    let editDir = filesDir + "/avatar_edits"
                    try { FileIo.mkdir(editDir) } catch (_e: Exception) {}
                    let stamp = DateTime.now().toUnixTimeStamp().toSeconds()
                    let path = editDir + "/avatar_draw_${stamp}.jpg"
                    try {
                        let outFile = FileIo.open(path, mode: 0o1101)
                        FileIo.write(outFile.fd, bytes)
                        FileIo.close(outFile)
                        flatten.setLastResultPath("file://" + path)
                    } catch (_e: Exception) {}
                }
            case None => ()
        }
        this.onDone()
        routerPop()
    }

    /** 相册素材以纯沙箱路径传入时，补齐 ArkUI 本地图片协议。 */
    private func previewAssetUri(): String {
        if (this.baseAssetUri.isEmpty() || this.baseAssetUri.startsWith("file://")) {
            return this.baseAssetUri
        }
        return "file://" + this.baseAssetUri
    }

    func build() {
        Column {
            if (this.isReady) {
                DrawingScreenComponent()
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x000000)
        .onAppear({ => this.ensureLoaded() })
    }
}
