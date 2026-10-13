package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import kit.MediaLibraryKit.*
import kit.AbilityKit.*
import ohos.business_exception.BusinessException
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

// ─────────────────────────────────────────────────────────────────
// 包级辅助函数（避免在 class 方法里用可重赋值 var 被 launch 捕获）
// ─────────────────────────────────────────────────────────────────

/**
 * 构建新的选中 URI 列表（不可重赋值，可安全传入 launch）
 */
func buildNewSelectedUris(current: ArrayList<String>, targetUri: String, wasSelected: Bool): ArrayList<String> {
    let result = ArrayList<String>()
    if (wasSelected) {
        for (uri in current) {
            if (uri != targetUri) {
                result.add(uri)
            }
        }
    } else {
        for (uri in current) {
            result.add(uri)
        }
        result.add(targetUri)
    }
    return result
}

/**
 * 重建 assets 列表并根据 orderedUris 重算每项的 selectionOrder
 */
func rebuildAssetsWithOrder(assets: ArrayList<MediaPickerAsset>, orderedUris: ArrayList<String>): ArrayList<MediaPickerAsset> {
    let result = ArrayList<MediaPickerAsset>()
    for (a in assets) {
        let updated = MediaPickerAsset()
        updated.uri = a.uri
        updated.displayName = a.displayName
        updated.mediaType = a.mediaType
        var order: Int32 = 0
        var orderIdx: Int32 = 0
        for (selectedUri in orderedUris) {
            orderIdx += 1
            if (selectedUri == a.uri) {
                order = orderIdx
                break
            }
        }
        updated.isSelected = order > 0
        updated.selectionOrder = order
        result.add(updated)
    }
    return result
}

/**
 * 将 selectedUris 中 fromIdx 位置的元素移到 toIdx（P2-212 重排辅助）
 */
func reorderSelectedUris(current: ArrayList<String>, fromIdx: Int64, toIdx: Int64): ArrayList<String> {
    let n = current.size
    if (fromIdx < 0 || fromIdx >= n || toIdx < 0 || toIdx >= n || fromIdx == toIdx) {
        let copy = ArrayList<String>()
        for (u in current) { copy.add(u) }
        return copy
    }
    let arr = ArrayList<String>()
    for (u in current) { arr.add(u) }
    let moved = arr[fromIdx]
    if (fromIdx < toIdx) {
        var i: Int64 = fromIdx
        while (i < toIdx) {
            arr[i] = arr[i + 1]
            i = i + 1
        }
    } else {
        var i: Int64 = fromIdx
        while (i > toIdx) {
            arr[i] = arr[i - 1]
            i = i - 1
        }
    }
    arr[toIdx] = moved
    return arr
}

/**
 * MediaPickerScreen — 相册内媒体多选页面（混合工程迁移版）
 * P2-206 / P2-207 / P2-209 / P2-210 / P2-212 / P2-213
 *
 * iOS 对应：
 *   submodules/MediaPickerUI/Sources/MediaPickerScreen.swift
 *   submodules/MediaPickerUI/Sources/MediaPickerGridItem.swift
 *   submodules/MediaPickerUI/Sources/MediaPickerSelectedListNode.swift
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹 + .title/.hideTitleBar，只留内容 + .onAppear/.onDisAppear
 *  - aboutToDisappear 有清理逻辑（相机释放）→ cleanup() + .onDisAppear
 *  - onReady param(albumUri) → takePending("MediaPickerScreen") 经 ensureLoaded()
 *  - pushPathByName → routerPush；pop → routerPop
 *
 * 路由参数（albumUri）：
 *   "system:all" / 空 → Camera Roll；"system:favorite"/"system:video" → 系统相册；其他 → 用户相册
 */
@HybridComponentEntry
@Component
public class MediaPickerScreen {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    /** 资产列表（从系统相册加载，真实数据）*/
    @State var assets: ArrayList<MediaPickerAsset> = ArrayList<MediaPickerAsset>()
    @State var isLoading: Bool = false
    @State var albumUri: String = ""

    /** 有序选中 URI 列表（P2-207 / P2-212）*/
    @State var selectedUris: ArrayList<String> = ArrayList<String>()

    /** 是否已触发加载 */
    @State var didLoad: Bool = false

    @State var loaded: Bool = false

    /** 达到选择上限时的提示文字 */
    @State var limitTipVisible: Bool = false

    /** 相册访问权限状态（P2-213）：0=未知 1=已授权 2=拒绝/受限 */
    @State var photoPermStatus: Int32 = 0

    /** 重排拖拽源索引（P2-212），-1 表示无重排进行中 */
    @State var dragSourceIdx: Int32 = -1

    /** P2-089 Caption 面板 */
    @State var captionText: String = ""

    private let gridColumns: Int32 = 3

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        // 原 .onReady 参数接收：albumUri（经 ParamStore takePending 取代 navDestination param）
        if (!this.didLoad) {
            let taken = takePending("MediaPickerScreen")
            let raw = if (taken.size > 0 && taken != "{}") { taken } else { MEDIA_ALBUM_URI_ALL }
            this.albumUri = raw
            this.didLoad = true
            this.isLoading = true
            this.checkAndRequestPhotoPermission(raw)
        }
    }

    /**
     * P2-209 可见性驱动相机资源释放（省电）
     * 原 aboutToDisappear → cleanup() + 根容器 .onDisAppear
     */
    private func cleanup(): Unit {
        let _ = spawn {
            getCameraService().releaseCamera()
        }
        Hilog.info(0, "CjTelegram", "[MediaPickerScreen] cleanup: camera released")
    }

    /**
     * P2-209：点击相机 tile → 进入全屏相机页
     */
    private func openCameraPage(): Unit {
        Hilog.info(0, "CjTelegram", "[MediaPickerScreen] openCameraPage")
        routerPush("CameraPage", "")
    }

    /**
     * P2-210：点击 Edit 按钮 → 进入媒体编辑页
     */
    private func openEditPage(assetUri: String): Unit {
        Hilog.info(0, "CjTelegram", "[MediaPickerScreen] openEditPage uri=" + assetUri)
        routerPush("MediaEditorScreen", assetUri)
    }

    /**
     * P2-213：检查相册权限，必要时请求，授权后触发 fetchAssets。
     */
    private func checkAndRequestPhotoPermission(capturedUri: String) {
        let _ = spawn {
            try {
                let atManager = AbilityAccessCtrl.createAtManager()
                let bundleInfo = BundleManager.getBundleInfoForSelf(BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
                let tokenID = bundleInfo.appInfo.accessTokenId
                let granted = atManager.checkAccessToken(tokenID, "ohos.permission.READ_IMAGEVIDEO")
                if (granted == GrantStatus.PermissionGranted) {
                    Hilog.info(0, "CjTelegram", "[MediaPickerScreen] READ_IMAGEVIDEO already granted")
                    launch { this.photoPermStatus = 1 }
                    this.fetchAssets(capturedUri)
                } else {
                    Hilog.info(0, "CjTelegram", "[MediaPickerScreen] READ_IMAGEVIDEO not granted, requesting...")
                    match (getGlobalAbilityContext()) {
                        case Some(context) =>
                            let permissions: Array<String> = ["ohos.permission.READ_IMAGEVIDEO"]
                            atManager.requestPermissionsFromUser(
                                context,
                                permissions,
                                { errCode: Option<BusinessException>, data: Option<PermissionRequestResult> =>
                                    match (errCode) {
                                        case Some(e) =>
                                            Hilog.info(0, "CjTelegram", "[MediaPickerScreen] requestPermission error: ${e.message}")
                                            launch { this.photoPermStatus = 2 }
                                        case _ =>
                                            match (data) {
                                                case Some(result) =>
                                                    let wasGranted = result.authResults.size > 0 && result.authResults[0] == 0
                                                    if (wasGranted) {
                                                        Hilog.info(0, "CjTelegram", "[MediaPickerScreen] READ_IMAGEVIDEO GRANTED by user")
                                                        launch { this.photoPermStatus = 1 }
                                                        this.fetchAssets(capturedUri)
                                                    } else {
                                                        Hilog.info(0, "CjTelegram", "[MediaPickerScreen] READ_IMAGEVIDEO DENIED by user")
                                                        launch { this.photoPermStatus = 2 }
                                                    }
                                                case _ =>
                                                    Hilog.info(0, "CjTelegram", "[MediaPickerScreen] requestPermission no result")
                                                    launch { this.photoPermStatus = 2 }
                                            }
                                    }
                                }
                            )
                        case None =>
                            Hilog.info(0, "CjTelegram", "[MediaPickerScreen] No UIAbilityContext, cannot request permission")
                            launch { this.photoPermStatus = 2 }
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[MediaPickerScreen] checkAndRequestPhotoPermission error: ${e}")
                launch { this.photoPermStatus = 2 }
            }
        }
    }

    /**
     * 按 albumUri 路由到对应的 fetch 方法并更新 @State assets。
     */
    private func fetchAssets(resolvedUri: String) {
        let capturedUri = resolvedUri
        let _ = spawn {
            launch { this.isLoading = true }
            let ctx = getGlobalAbilityContext()
            match (ctx) {
                case None =>
                    Hilog.info(0, "CjTelegram", "[MediaPickerScreen] no ability context")
                    launch { this.isLoading = false }
                case Some(abilityCtx) =>
                    let svc = getMediaPickerService()
                    let items = if (capturedUri == MEDIA_ALBUM_URI_FAVORITE) {
                        svc.fetchSystemAlbumAssets(abilityCtx, AlbumSubtype.Favorite)
                    } else if (capturedUri == MEDIA_ALBUM_URI_VIDEO) {
                        svc.fetchSystemAlbumAssets(abilityCtx, AlbumSubtype.Video)
                    } else if (!capturedUri.contains("system:")) {
                        svc.fetchAssetsInAlbum(abilityCtx, capturedUri)
                    } else {
                        svc.fetchAllAssets(abilityCtx)
                    }
                    launch {
                        var t = ArrayList<MediaPickerAsset>()
                        for (item in items) {
                            t.add(item)
                        }
                        this.assets = t
                        this.isLoading = false
                    }
            }
        }
    }

    public func build() {
        Column {
            if (this.isLoading) {
                this.buildLoadingView()
            } else if (this.photoPermStatus == 2) {
                this.buildPermissionDeniedView()
            } else if (this.assets.size > 0) {
                this.buildGridView()
            } else if (this.photoPermStatus == 1) {
                this.buildEmptyView()
            } else {
                this.buildLoadingView()
            }
            if (this.limitTipVisible) {
                this.buildLimitTip()
            }
            // P2-212：已选横向列表（有选中时显示）
            if (this.selectedUris.size > 0) {
                this.buildSelectedList()
            }
            // P2-089: caption 输入面板（有选中时显示）
            if (this.selectedUris.size > 0) {
                this.buildCaptionPanel()
            }
            this.buildBottomBar()
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFF)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
        .onDisAppear({ => this.cleanup() })
    }

    @Builder
    func buildLoadingView() {
        Column {
            LoadingProgress()
                .width(40)
                .height(40)
                .color(0x007AFF)
        }
        .width(100.percent)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    func buildEmptyView() {
        Column {
            Text("No photos or videos found")
                .fontSize(16)
                .fontColor(0x8E8E93)
                .textAlign(TextAlign.Center)
                .margin(16)
        }
        .width(100.percent)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    /**
     * P2-213 无权限占位 UI
     */
    @Builder
    func buildPermissionDeniedView() {
        Column {
            Text("Photo Access Required")
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor(0x000000)
                .textAlign(TextAlign.Center)
                .margin(bottom: 12)

            Text("Please allow Telegram to access your photos in Settings to select media.")
                .fontSize(15)
                .fontColor(0x8E8E93)
                .textAlign(TextAlign.Center)
                .margin(left: 32, right: 32, bottom: 24)

            Button(trSource("Go to Settings"))
                .width(200)
                .height(44)
                .borderRadius(22)
                .backgroundColor(0x007AFF)
                .fontColor(0xFFFFFF)
                .fontSize(16)
                .onClick({ _evt =>
                    this.openAppSettings()
                })
        }
        .width(100.percent)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    /**
     * P2-209 相机入口 tile（网格第一格）
     */
    @Builder
    func buildCameraTile() {
        Stack(alignContent: Alignment.Center) {
            Column {
                Text("[cam]")
                    .fontSize(28)
                    .fontColor(0xFFFFFF)
                    .textAlign(TextAlign.Center)

                Text(trSource("Camera"))
                    .fontSize(11)
                    .fontColor(0xCCCCCC)
                    .textAlign(TextAlign.Center)
                    .margin(top: 6)
            }
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
        }
        .width(100.percent)
        .aspectRatio(1.0)
        .backgroundColor(0x1A1A1A)
        .onClick({ _evt =>
            this.openCameraPage()
        })
    }

    @Builder
    func buildGridView() {
        Grid {
            // P2-209: 第一格为相机快捷拍摄入口 tile
            GridItem {
                this.buildCameraTile()
            }
            ForEach(
                Array<MediaPickerAsset>(this.assets.size, { i: Int64 => this.assets[i] }),
                itemGenerator: { asset: MediaPickerAsset, idx: Int64 =>
                    GridItem {
                        this.buildAssetCell(asset, idx)
                    }
                }
            )
        }
        .columnsTemplate("1fr 1fr 1fr")
        .columnsGap(2)
        .rowsGap(2)
        .width(100.percent)
        .layoutWeight(1)
    }

    /**
     * 单个媒体资产网格单元（P2-206 + P2-207）
     */
    @Builder
    func buildAssetCell(asset: MediaPickerAsset, idx: Int64) {
        Stack(alignContent: Alignment.TopEnd) {
            Image(asset.uri)
                .width(100.percent)
                .height(100.percent)
                .objectFit(ImageFit.Cover)

            // 视频时长标记（右下角）
            if (asset.mediaType == "video") {
                Stack(alignContent: Alignment.BottomStart) {
                    Text(trSource("video"))
                        .fontSize(10)
                        .fontColor(0xFFFFFF)
                        .backgroundColor(0x66000000)
                        .padding(left: 4, right: 4, top: 2, bottom: 2)
                        .borderRadius(3)
                }
                .width(100.percent)
                .height(100.percent)
            }

            // P2-207 选中序号角标（右上角）
            if (asset.isSelected) {
                Column {
                    Text(asset.selectionOrder.toString())
                        .fontSize(12)
                        .fontColor(0xFFFFFF)
                        .fontWeight(FontWeight.Bold)
                        .textAlign(TextAlign.Center)
                }
                .width(24)
                .height(24)
                .backgroundColor(0x007AFF)
                .borderRadius(12)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .margin(top: 4, right: 4)
            } else {
                Column {}
                    .width(22)
                    .height(22)
                    .borderRadius(11)
                    .border(width: 1.5, color: 0xFFFFFF, style: BorderStyle.Solid)
                    .margin(top: 4, right: 4)
                    .backgroundColor(0x33000000)
            }
        }
        .width(100.percent)
        .aspectRatio(1.0)
        .onClick({ evt =>
            this.toggleAssetSelection(idx)
        })
    }

    /**
     * P2-212 底部已选横向缩略图列表（可重排）
     */
    @Builder
    func buildSelectedList() {
        List(space: 8) {
            ForEach(
                Array<String>(this.selectedUris.size, { i: Int64 => this.selectedUris[i] }),
                itemGenerator: { uri: String, listIdx: Int64 =>
                    ListItem {
                        this.buildSelectedThumbnail(uri, listIdx)
                    }
                }
            )
        }
        .listDirection(Axis.Horizontal)
        .height(88)
        .width(100.percent)
        .padding(left: 8, right: 8, top: 4, bottom: 4)
        .backgroundColor(0xF2F2F7)
        .scrollBar(BarState.Off)
    }

    /**
     * P2-212 单个已选缩略图（横向列表项）
     */
    @Builder
    func buildSelectedThumbnail(uri: String, idx: Int64) {
        Stack(alignContent: Alignment.TopEnd) {
            Image(uri)
                .width(72)
                .height(72)
                .objectFit(ImageFit.Cover)
                .borderRadius(6)
                .opacity(if (this.dragSourceIdx == Int32(idx)) { 0.45 } else { 1.0 })
                .border(
                    width: if (this.dragSourceIdx == Int32(idx)) { 2 } else { 0 },
                    color: if (this.dragSourceIdx == Int32(idx)) { 0x007AFF } else { Color.Transparent },
                    style: BorderStyle.Solid
                )

            // 视频角标（右下角）
            if (this.isVideoUri(uri)) {
                Stack(alignContent: Alignment.BottomStart) {
                    Text(trSource("video"))
                        .fontSize(9)
                        .fontColor(0xFFFFFF)
                        .backgroundColor(0x66000000)
                        .padding(left: 3, right: 3, top: 1, bottom: 1)
                        .borderRadius(2)
                }
                .width(72)
                .height(72)
            }

            // "×" 取消角标（右上角）— 点击取消选中
            Column {
                Text("x")
                    .fontSize(11)
                    .fontColor(0xFFFFFF)
                    .fontWeight(FontWeight.Bold)
                    .textAlign(TextAlign.Center)
            }
            .width(20)
            .height(20)
            .backgroundColor(0x99000000)
            .borderRadius(10)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .margin(top: 2, right: 2)
            .onClick({ _evt =>
                if (this.dragSourceIdx >= 0) {
                    this.dragSourceIdx = -1
                }
                this.removeSelectedByUri(uri)
            })
        }
        .width(72)
        .height(72)
        .onClick({ _evt =>
            if (this.dragSourceIdx < 0) {
                this.dragSourceIdx = Int32(idx)
                Hilog.info(0, "CjTelegram", "[MediaPickerScreen] reorder pick idx=" + idx.toString())
            } else if (this.dragSourceIdx == Int32(idx)) {
                this.dragSourceIdx = -1
            } else {
                this.doReorder(Int64(this.dragSourceIdx), idx)
            }
        })
    }

    /**
     * 上限提示条（P2-207）
     */
    @Builder
    func buildLimitTip() {
        Row {
            Text("You can select up to " + MEDIA_PICKER_SELECTION_LIMIT.toString() + " items")
                .fontSize(13)
                .fontColor(0xFFFFFF)
                .textAlign(TextAlign.Center)
        }
        .width(100.percent)
        .height(36)
        .backgroundColor(0xCC000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
    }

    /**
     * P2-089: Caption 文字输入面板
     */
    @Builder
    func buildCaptionPanel() {
        Row {
            TextInput(
                placeholder: trSource("Add a caption..."),
                text: this.captionText
            )
            .width(100.percent)
            .height(40)
            .backgroundColor(0xF2F2F7)
            .borderRadius(20)
            .padding(left: 16, right: 16)
            .fontSize(15)
            .fontColor(0x000000)
            .placeholderFont(size: 15)
            .placeholderColor(0x8E8E93)
            .maxLength(200)
            .onChange({ value: String =>
                this.captionText = value
            })
        }
        .width(100.percent)
        .height(52)
        .padding(left: 12, right: 12, top: 6, bottom: 6)
        .backgroundColor(0xFFFFFF)
        .border(width: 0.5, color: 0xE5E5EA, style: BorderStyle.Solid)
    }

    @Builder
    func buildBottomBar() {
        Row {
            Column {
                Text(this.getSelectionCountText())
                    .fontSize(14)
                    .fontColor(0x8E8E93)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // P2-210：单项编辑入口
            if (this.selectedUris.size == 1) {
                Button(trSource("Edit"))
                    .width(60)
                    .height(36)
                    .borderRadius(18)
                    .backgroundColor(0x34C759)
                    .fontColor(0xFFFFFF)
                    .fontSize(14)
                    .margin(right: 8)
                    .onClick({ _evt =>
                        let uri = this.selectedUris[0]
                        this.openEditPage(uri)
                    })
            }

            Button(trSource("Send"))
                .width(80)
                .height(36)
                .borderRadius(18)
                .backgroundColor(if (this.selectedUris.size > 0) { 0x007AFF } else { 0xC7C7CC })
                .fontColor(0xFFFFFF)
                .fontSize(15)
                .enabled(this.selectedUris.size > 0)
                .onClick({ evt =>
                    this.confirmSelection()
                })
        }
        .width(100.percent)
        .height(60)
        .padding(left: 16, right: 16)
        .backgroundColor(0xF2F2F7)
        .alignItems(VerticalAlign.Center)
    }

    /**
     * 切换资产选中状态（P2-207）
     */
    private func toggleAssetSelection(idx: Int64) {
        if (idx < 0 || idx >= Int64(this.assets.size)) { return }

        let asset = this.assets[idx]

        if (!asset.isSelected && Int32(this.selectedUris.size) >= MEDIA_PICKER_SELECTION_LIMIT) {
            this.limitTipVisible = true
            Hilog.info(0, "CjTelegram", "[MediaPickerScreen] selection limit reached (" + MEDIA_PICKER_SELECTION_LIMIT.toString() + ")")
            return
        }

        if (this.limitTipVisible) {
            this.limitTipVisible = false
        }

        let newUris = buildNewSelectedUris(this.selectedUris, asset.uri, asset.isSelected)
        let newAssets = rebuildAssetsWithOrder(this.assets, newUris)

        let capturedUris = newUris
        let capturedAssets = newAssets

        launch {
            this.selectedUris = capturedUris
            this.assets = capturedAssets
        }

        Hilog.info(0, "CjTelegram", "[MediaPickerScreen] toggled idx=" + idx.toString() + " selectedCount=" + newUris.size.toString())
    }

    /**
     * P2-212：点击"×"取消某个已选资产
     */
    private func removeSelectedByUri(uri: String) {
        let newUris = buildNewSelectedUris(this.selectedUris, uri, true)
        let newAssets = rebuildAssetsWithOrder(this.assets, newUris)
        let capturedUris = newUris
        let capturedAssets = newAssets
        launch {
            this.selectedUris = capturedUris
            this.assets = capturedAssets
        }
        Hilog.info(0, "CjTelegram", "[MediaPickerScreen] removed uri from selected list")
    }

    /**
     * P2-212：执行已选列表重排
     */
    private func doReorder(fromIdx: Int64, toIdx: Int64) {
        let newUris = reorderSelectedUris(this.selectedUris, fromIdx, toIdx)
        let newAssets = rebuildAssetsWithOrder(this.assets, newUris)
        let capturedUris = newUris
        let capturedAssets = newAssets
        launch {
            this.selectedUris = capturedUris
            this.assets = capturedAssets
            this.dragSourceIdx = -1
        }
        Hilog.info(0, "CjTelegram", "[MediaPickerScreen] reorder " + fromIdx.toString() + " -> " + toIdx.toString())
    }

    /**
     * P2-213：打开系统设置（相册权限拒绝时引导用户手动授权）
     */
    private func openAppSettings() {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let want = Want(action: "ohos.want.action.APPLICATION_DETAILS_SETTINGS", uri: "package:ohos_app_cangjie_entry")
                    ctx.startAbility(want)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[MediaPickerScreen] openAppSettings failed: ${e}")
                }
            case None => ()
        }
    }

    /**
     * 判断 URI 是否对应视频资产
     */
    private func isVideoUri(uri: String): Bool {
        for (asset in this.assets) {
            if (asset.uri == uri) {
                return asset.mediaType == "video"
            }
        }
        return false
    }

    private func confirmSelection() {
        var uris = ArrayList<String>()
        for (uri in this.selectedUris) {
            uris.add(uri)
        }
        let caption = this.captionText
        Hilog.info(0, "CjTelegram", "[MediaPickerScreen] confirmed ${uris.size} assets caption=${caption.size}chars")
        launch { this.captionText = "" }
        routerPop()
    }

    private func getTitle(): String {
        let count = Int32(this.selectedUris.size)
        if (count > 0) {
            return count.toString() + " Selected"
        }
        return "Select Photos"
    }

    private func getSelectionCountText(): String {
        let count = Int32(this.selectedUris.size)
        if (count == 0) {
            return "Tap to select"
        }
        return count.toString() + " of " + MEDIA_PICKER_SELECTION_LIMIT.toString() + " selected"
    }

}
