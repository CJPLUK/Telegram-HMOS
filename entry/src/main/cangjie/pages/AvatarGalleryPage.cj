package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.math.{sqrt, floor}
import std.time.DateTime
import std.sync.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.interop.*
import ohos_app_cangjie_entry.utils.{formatClockHHMM, localDayIndexOf, formatShortDateSlashed}
import kit.CoreFileKit.*

/**
 * AvatarGalleryPage — 头像大图画廊浏览页（PAVG-UI-2 + P2-143b）（混合工程迁移版）
 *
 * 对应 iOS AvatarGalleryController（GalleryControllerNode + Swiper 浏览）。
 *
 * 功能：
 *   - Swiper 全屏浏览用户全部头像（圆形 → 大图）
 *   - Footer：当前序号 / 总数 + 删除 / Set as Main / 返回按钮
 *   - 双指捏合缩放（onTouch 双指距离跟踪 + .scale(x:y:)）
 *   - 双击图片重置缩放到 1.0
 *
 * 路由参数格式（字符串）：
 *   "userId|accessHash|peerName|initialIndex"
 *   例："123456789|-987654321|Alice|0"
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack (appStack)
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - appStack.pop(animated:true) → routerPop()
 *  - onReady 参数解析 + aboutToAppear 实逻辑 → ensureLoaded() (takePending + fetch) + .onAppear
 */
@HybridComponentEntry
@Component
public class AvatarGalleryPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var photos: ArrayList<String> = ArrayList<String>()
    @State var isLoading: Bool = false
    @State var currentIndex: Int32 = 0
    @State var peerName: String = ""
    @State var userId: Int64 = 0
    @State var accessHash: Int64 = 0
    @State var initialIndex: Int32 = 0
    @State var showDeleteConfirm: Bool = false
    @State var showChrome: Bool = true
    @State var showEditMenu: Bool = false
    @State var showEditRemoveConfirm: Bool = false
    @State var isUploadingPhoto: Bool = false
    @State var galleryWidthVp: Float64 = 402.0
    @State var galleryHeightVp: Float64 = 874.0

    // AvatarGalleryController presents its own ShareControllerNode over the
    // current photo.  Keep this state local so the gallery never navigates
    // away when the share action is opened.
    @State var showShareSheet: Bool = false
    @State var shareSearchVisible: Bool = false
    @State var shareSearchText: String = ""
    @State var shareTargets: ArrayList<ShareTarget> = ArrayList<ShareTarget>()
    @State var selectedShareTargets: ArrayList<ShareTarget> = ArrayList<ShareTarget>()
    @State var shareTargetsLoading: Bool = false
    @State var shareSending: Bool = false

    // ─── set-as-main 状态 ───────────────────────────────────────────────────────
    @State var isCurrentMain: Bool = true
    @State var isSettingMain: Bool = false
    @State var setMainSuccess: Bool = false

    // ─── 缩放状态 ────────────────────────────────────────────────────────────────
    @State var imageScale: Float32 = Float32(1.0)
    @State var imageOffsetX: Float64 = 0.0
    @State var imageOffsetY: Float64 = 0.0
    private var lastPinchDist: Float64 = 0.0
    private var tapCount: Int32 = 0
    private var tapVersion: Int32 = 0
    private var singleTouchStartX: Float64 = 0.0
    private var singleTouchStartY: Float64 = 0.0
    private var singleTouchBaseOffsetX: Float64 = 0.0
    private var singleTouchBaseOffsetY: Float64 = 0.0
    private var singleTouchTracking: Bool = false
    private var singleTouchMoved: Bool = false

    private var photoMetas: ArrayList<AvatarPhotoInfo> = ArrayList<AvatarPhotoInfo>()

    private var swiperController: SwiperController = SwiperController()

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let raw = takePending("AvatarGalleryPage")
        if (raw.size > 0 && raw != "{}") {
            this.parseRouteParam(raw)
        }
        let uid = this.userId
        let ah = this.accessHash
        let idx = this.initialIndex
        let _ = spawn {
            let svc = getPeerAvatarGalleryService()
            launch {
                this.isLoading = true
            }
            // 单一数据源：仅构建 photoMetas；photos 从中派生，保证 photos[i] === photoMetas[i].downloadedPath
            let metas = this.normalizeGalleryMetas(svc.fetchAvatarPhotoMetas(uid, ah, limit: 20))
            let derivedPaths = ArrayList<String>()
            for (m in metas) {
                derivedPaths.add(m.downloadedPath)
            }
            launch {
                this.photoMetas = metas
                this.photos = derivedPaths
                this.isLoading = false
                if (idx >= 0 && Int64(idx) < Int64(derivedPaths.size)) {
                    this.currentIndex = idx
                }
                // 初始化 isCurrentMain：index 0 为主头像
                this.isCurrentMain = (this.currentIndex == 0)
                Hilog.info(0, "CjTelegram", "[AvatarGalleryPage] loaded ${derivedPaths.size} photos (single source) uid=${uid}")
            }
        }
    }

    public func build() {
        Stack(alignContent: Alignment.TopStart) {
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0x000000)

            if (this.isLoading) {
                this.buildLoadingView()
            } else if (this.getPhotoCount() == 0) {
                this.buildEmptyView()
            } else {
                this.buildGalleryView()
            }

            if (!this.isLoading && this.getPhotoCount() > 0 && this.showChrome) {
                this.buildTopChrome()
                this.buildThumbnailStrip()
                this.buildBottomActions()
            }

            if (this.showDeleteConfirm) {
                this.buildDeleteConfirm()
            }

            if (this.showShareSheet) {
                this.buildShareSheet()
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x000000)
        .onAreaChange({ _: Area, area: Area =>
            this.galleryWidthVp = area.width.value
            this.galleryHeightVp = area.height.value
        })
        .onAppear({ => this.setGallerySystemBars(true); this.ensureLoaded() })
        .onDisAppear({ => this.setGallerySystemBars(false) })
    }

    @Builder func buildLoadingView(): Unit {
        Column {
            Text("Loading photos...")
                .fontSize(16)
                .fontColor(0x8E8E93)
        }
        .width(100.percent)
        .height(100.percent)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder func buildEmptyView(): Unit {
        Column {
            Text("No profile photos")
                .fontSize(16)
                .fontColor(0x8E8E93)
                .margin(bottom: 24)
            Button(trSource("Back"))
                .fontSize(15)
                .fontColor(0x0A84FF)
                .backgroundColor(Color.Transparent)
                .onClick({ _ =>
                    routerPop()
                })
        }
        .width(100.percent)
        .height(100.percent)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder func buildGalleryView(): Unit {
        Swiper(controller: this.swiperController) {
            ForEach(this.getPhotosArray(), itemGenerator: { path: String, _idx: Int64 =>
                this.buildPhotoItem(path)
            })
        }
        .index(UInt32(this.currentIndex))
        .loop(false)
        .effectMode(EdgeEffect.None)
        .disableSwipe(this.imageScale > Float32(1.01))
        .indicator(false)
        .width(100.percent)
        .height(100.percent)
        .onChange({ idx: Int32 =>
            this.currentIndex = idx
            // 切页时重置缩放并更新 isCurrentMain
            this.imageScale = Float32(1.0)
            this.imageOffsetX = 0.0
            this.imageOffsetY = 0.0
            this.tapCount = 0
            this.tapVersion = this.tapVersion + 1
            this.lastPinchDist = 0.0
            this.isCurrentMain = (idx == 0)
        })
    }

    @Builder func buildPhotoItem(path: String): Unit {
        Column {
            if (path.size > 0) {
                Image(path)
                    .width(100.percent)
                    .height(100.percent)
                    .objectFit(ImageFit.Contain)
                    .scale(x: this.imageScale, y: this.imageScale)
                    .translate(x: this.imageOffsetX, y: this.imageOffsetY)
                    .onTouch({ event =>
                        this.handleTouchZoom(event)
                    })
                    .onClick({ _ => this.handlePhotoTapGesture() })
            } else {
                Column {
                    Text("?")
                        .fontSize(80)
                        .fontColor(0xFFFFFF)
                        .textAlign(TextAlign.Center)
                }
                .width(100.percent)
                .height(100.percent)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(0x3A3A3C)
            }
        }
        .width(100.percent)
        .height(100.percent)
    }

    @Builder func buildTopChrome(): Unit {
        Row {
            Column {
                Image(@r(app.media.nav_back_arrow_glass))
                    .width(22)
                    .height(22)
            }
            .width(44)
            .height(44)
            .borderRadius(22)
            .backgroundColor(0xFF1C1C1E)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .onClick({ _ => routerPop() })

            Column {
                Text(this.buildTitle())
                    .fontSize(18)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0xFFFFFFFF)
                    .maxLines(1)
                Text(this.buildPhotoSubtitle())
                    .fontSize(13)
                    .fontColor(0xFF8E8E93)
                    .margin(top: 1)
            }
            .width(184)
            .height(44)
            .borderRadius(22)
            .backgroundColor(0xFF1C1C1E)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)

            Text(trSource("Edit"))
                .fontSize(17)
                .fontColor(0xFFFFFFFF)
                .width(54)
                .height(44)
                .borderRadius(22)
                .backgroundColor(0xFF1C1C1E)
                .textAlign(TextAlign.Center)
                .onClick({ _ => this.showEditMenu = !this.showEditMenu })
                .bindPopup(
                    this.showEditMenu,
                    CustomPopupOptions(
                        builder: bind(this.buildEditMenu, this),
                        placement: Placement.Bottom,
                        popupColor: Color.Transparent,
                        enableArrow: false,
                        autoCancel: true,
                        radius: 18.vp,
                        onStateChange: Option.Some({ event: PopupStateChangeParam =>
                            if (!event.isVisible) {
                                this.showEditMenu = false
                                this.showEditRemoveConfirm = false
                            }
                        })
                    )
                )
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: getSafeAreaTop() + 10.0)
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .position(x: 0, y: 0)
    }

    @Builder func buildEditMenu(): Unit {
        Column {
            if (this.showEditRemoveConfirm) {
                Row {
                    Text(trSource("Remove"))
                        .fontSize(17)
                        .fontColor(0xFFFF453A)
                }
                .width(196)
                .height(54)
                .padding(left: 18, right: 18)
                .alignItems(VerticalAlign.Center)
                .onClick({ _ =>
                    this.showEditMenu = false
                    this.showEditRemoveConfirm = false
                    this.performDeleteCurrentPhoto()
                })
            } else {
                Row {
                    Image(@r(app.media.gallery_ic_replace_source))
                        .width(24)
                        .height(24)
                        .fillColor(0xFFFFFFFF)
                    Text(if (this.isUploadingPhoto) { "Uploading..." } else { "Set New Photo" })
                        .fontSize(17)
                        .fontColor(0xFFFFFFFF)
                        .margin(left: 12)
                }
                .width(196)
                .height(52)
                .padding(left: 16, right: 16)
                .onClick({ _ =>
                    if (!this.isUploadingPhoto) {
                        this.showEditMenu = false
                        this.pickAndUploadNewPhoto()
                    }
                })

                if (!this.isCurrentMain) {
                    Divider().color(0xFF343436).margin(left: 52)
                    Row {
                        Image(@r(app.media.gallery_ic_setmain_source))
                            .width(24)
                            .height(24)
                            .fillColor(0xFFFFFFFF)
                        Text(if (this.isSettingMain) { "Setting..." } else { "Set as Main Photo" })
                            .fontSize(17)
                            .fontColor(0xFFFFFFFF)
                            .margin(left: 12)
                    }
                    .width(196)
                    .height(52)
                    .padding(left: 16, right: 16)
                    .onClick({ _ =>
                        if (this.canSetAsMain()) {
                            this.showEditMenu = false
                            this.performSetAsMain()
                        }
                    })
                }

                Divider().color(0xFF343436).margin(left: 52)
                Row {
                    Image(@r(app.media.gallery_ic_trash))
                        .width(24)
                        .height(24)
                        .fillColor(0xFFFF453A)
                    Text(trSource("Remove Photo"))
                        .fontSize(17)
                        .fontColor(0xFFFF453A)
                        .margin(left: 12)
                }
                .width(196)
                .height(52)
                .padding(left: 16, right: 16)
                .onClick({ _ => this.showEditRemoveConfirm = true })
            }
        }
        .width(196)
        .backgroundColor(0xFF1C1C1E)
        .borderRadius(18)
    }

    @Builder func buildThumbnailStrip(): Unit {
        Row {
            ForEach(this.getPhotosArray(), itemGenerator: { path: String, idx: Int64 =>
                Image(path)
                    .width(32)
                    .height(48)
                    .objectFit(ImageFit.Cover)
                    .borderRadius(3)
                    .border(width: if (idx == Int64(this.currentIndex)) { 2 } else { 0 },
                        color: 0xFFFFFFFF)
                    .opacity(if (idx == Int64(this.currentIndex)) { 1.0 } else { 0.72 })
                    .margin(left: 2, right: 2)
                    .onClick({ _ => this.currentIndex = Int32(idx) })
            })
        }
        .width(100.percent)
        .height(52)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .position(x: 0, y: 100.percent)
        .translate(y: -(getSafeAreaBottom() + 112.0))
    }

    @Builder func buildBottomActions(): Unit {
        Row {
            Column {
                Image(@r(app.media.gallery_ic_forward))
                    .width(25)
                    .height(25)
                    .fillColor(0xFFFFFFFF)
            }
            .width(44)
            .height(44)
            .borderRadius(22)
            .backgroundColor(0xFF1C1C1E)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .onClick({ _ => this.shareCurrentPhoto() })

            Column {
                Image(@r(app.media.gallery_ic_trash))
                    .width(25)
                    .height(25)
                    .fillColor(0xFFFFFFFF)
            }
            .width(44)
            .height(44)
            .borderRadius(22)
            .backgroundColor(0xFF1C1C1E)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .onClick({ _ => this.showDeleteConfirm = true })
        }
        .width(100.percent)
        .padding(left: 24, right: 24)
        .justifyContent(FlexAlign.SpaceBetween)
        .position(x: 0, y: 100.percent)
        .translate(y: -(getSafeAreaBottom() + 64.0))
    }

    @Builder func buildDeleteConfirm(): Unit {
        Stack(alignContent: Alignment.Bottom) {
            Column { }
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0x22000000)
                .onClick({ _ => this.showDeleteConfirm = false })

            Row {
                Text(trSource("Remove"))
                    .fontSize(18)
                    .fontColor(0xFFFF453A)
            }
            .width(218)
            .height(58)
            .padding(left: 18, right: 18)
            .backgroundColor(0xFF1C1C1E)
            .borderRadius(29)
            .alignItems(VerticalAlign.Center)
            .onClick({ _ => this.performDeleteCurrentPhoto() })
            .position(x: 100.percent, y: 100.percent)
            .translate(x: -234.0, y: -(getSafeAreaBottom() + 120.0))
        }
        .width(100.percent)
        .height(100.percent)
    }

    private func handlePhotoTap(): Unit {
        let width = this.galleryWidthVp
        let sixth = floor(width / 6.0)
        let edge = if (sixth < 44.0) { sixth } else { 44.0 }
        let canUseEdgeNavigation = getThemesEngineService().getShowNextMediaOnTap() &&
            this.imageScale <= Float32(1.01)
        if (canUseEdgeNavigation && this.singleTouchStartX < edge && this.currentIndex > 0) {
            this.selectPreviousPhoto()
        } else if (canUseEdgeNavigation && this.singleTouchStartX > width - edge &&
            Int64(this.currentIndex) + 1 < this.getPhotoCount()) {
            this.selectNextPhoto()
        } else {
            this.showChrome = !this.showChrome
            this.showEditMenu = false
            this.showEditRemoveConfirm = false
        }
    }

    private func setGallerySystemBars(active: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                spawn {
                    try {
                        let win = getLastWindow(ctx)
                        win.setWindowSystemBarProperties(
                            SystemBarProperties(
                                statusBarColor: if (active) { "#FF000000" } else { "#00000000" },
                                isStatusBarLightIcon: active,
                                statusBarContentColor: if (active) { "#FFFFFFFF" } else { "#FF000000" },
                                navigationBarColor: if (active) { "#FF000000" } else { "#00000000" },
                                isNavigationBarLightIcon: active,
                                navigationBarContentColor: if (active) { "#FFFFFFFF" } else { "#FF000000" },
                                enableStatusBarAnimation: true
                            )
                        )
                    } catch (e: Exception) {
                        Hilog.warn(0, "CjTelegram", "[AvatarGalleryPage] system bar update failed: ${e}")
                    }
                }
            case None => ()
        }
    }

    private func shareCurrentPhoto(): Unit {
        let idx = Int64(this.currentIndex)
        if (idx < 0 || idx >= Int64(this.photos.size)) { return }
        if (this.photos[idx].size == 0) { return }
        this.showEditMenu = false
        this.showDeleteConfirm = false
        this.shareSearchVisible = false
        this.shareSearchText = ""
        this.selectedShareTargets = ArrayList<ShareTarget>()
        this.showShareSheet = true
        this.loadShareTargets()
    }

    private func loadShareTargets(): Unit {
        if (this.shareTargetsLoading || !this.shareTargets.isEmpty()) { return }
        this.shareTargetsLoading = true
        let _ = spawn {
            let loadedTargets = getShareControllerService().getMergedTargetsForShare(limit: 30)
            let visibleTargets = ArrayList<ShareTarget>()
            let saved = ShareTarget()
            saved.peerType = "user"
            saved.peerId = this.userId
            saved.name = "Saved Messages"
            saved.avatarText = ""
            saved.avatarColor = 0xFF34AADC
            visibleTargets.add(saved)
            for (target in loadedTargets) {
                if (!(target.peerType == saved.peerType && target.peerId == saved.peerId)) {
                    visibleTargets.add(target)
                }
            }
            launch {
                this.shareTargets = visibleTargets
                this.shareTargetsLoading = false
            }
        }
    }

    private func isShareTargetSelected(target: ShareTarget): Bool {
        for (selected in this.selectedShareTargets) {
            if (selected.peerType == target.peerType && selected.peerId == target.peerId) { return true }
        }
        return false
    }

    private func toggleShareTarget(target: ShareTarget): Unit {
        let updated = ArrayList<ShareTarget>()
        var removed = false
        for (selected in this.selectedShareTargets) {
            if (selected.peerType == target.peerType && selected.peerId == target.peerId) {
                removed = true
            } else {
                updated.add(selected)
            }
        }
        if (!removed) { updated.add(target) }
        this.selectedShareTargets = updated
    }

    private func getVisibleShareTargets(): ArrayList<ShareTarget> {
        if (this.shareSearchText.size == 0) { return this.shareTargets }
        let query = this.shareSearchText.toAsciiLower()
        let filtered = ArrayList<ShareTarget>()
        for (target in this.shareTargets) {
            if (target.name.toAsciiLower().contains(query)) { filtered.add(target) }
        }
        return filtered
    }

    private func currentPhotoPath(): String {
        let idx = Int64(this.currentIndex)
        if (idx < 0 || idx >= Int64(this.photos.size)) { return "" }
        return this.photos[idx]
    }

    private func shareCurrentPhotoExternally(): Unit {
        let rawPath = this.currentPhotoPath()
        if (rawPath.size == 0) { return }
        let path = if (rawPath.startsWith("file://")) { rawPath[7..rawPath.size] } else { rawPath }
        let argJson = "{\"filePath\":\"" + path + "\",\"title\":\"Photo\",\"isVideo\":false}"
        callArkAsync(SHARE_LINK, argJson, { _ => () })
    }

    private func saveCurrentPhoto(): Unit {
        let path = this.currentPhotoPath()
        if (path.size == 0) { return }
        getSaveToCameraRollService().saveImageToGallery(path, { ok: Bool =>
            if (ok) { launch { this.showShareSheet = false } }
        })
    }

    private func sendCurrentPhoto(): Unit {
        if (this.shareSending || this.selectedShareTargets.isEmpty()) { return }
        var path = this.currentPhotoPath()
        if (path.startsWith("file://")) { path = path[7..path.size] }
        if (path.size == 0) { return }
        let raw = ExternalContentItem()
        raw.kind = "image"
        raw.filePath = path
        let rawItems = ArrayList<ExternalContentItem>()
        rawItems.add(raw)
        let normalized = getExternalContentNormalizationService().normalizeItems(rawItems)
        let targets = ArrayList<ShareTarget>()
        for (target in this.selectedShareTargets) { targets.add(target) }
        this.shareSending = true
        let _ = spawn {
            let ok = getShareControllerService().sendExternalContentToMultiPeers(
                normalized,
                targets,
                { _: String, _: Int32, _: Int32 => () },
                silently: false
            )
            launch {
                this.shareSending = false
                if (ok) { this.showShareSheet = false }
            }
        }
    }

    @Builder func buildShareSheet(): Unit {
        Stack(alignContent: Alignment.Bottom) {
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0x24000000)
                .onClick({ _ => this.showShareSheet = false })

            Column {
                Column {
                    if (this.shareSearchVisible) {
                        Row {
                            Image(@r(app.media.chatroom_ic_search))
                                .width(23)
                                .height(23)
                                .fillColor(0xFF0A84FF)
                                .margin(left: 15, right: 9)
                            TextInput(text: this.shareSearchText, placeholder: trSource("Search"))
                                .layoutWeight(1)
                                .height(46)
                                .fontSize(17)
                                .fontColor(0xFFFFFFFF)
                                .placeholderColor(0xFF8E8E93)
                                .backgroundColor(Color.Transparent)
                                .onChange({ value: String => this.shareSearchText = value })
                            Text(trSource("Cancel"))
                                .fontSize(17)
                                .fontColor(0xFF0A84FF)
                                .padding(left: 10, right: 15)
                                .onClick({ _ =>
                                    this.shareSearchText = ""
                                    this.shareSearchVisible = false
                                })
                        }
                        .width(100.percent)
                        .height(66)
                    } else {
                        Row {
                            Image(@r(app.media.chatroom_ic_search))
                                .width(28)
                                .height(28)
                                .fillColor(0xFF0A84FF)
                                .onClick({ _ => this.shareSearchVisible = true })
                            Column {
                                Text("Share with")
                                    .fontSize(21)
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(0xFFFFFFFF)
                                Text(trSource("Select chats"))
                                    .fontSize(14)
                                    .fontColor(0xFF8E8E93)
                                    .margin(top: 1)
                            }
                            .layoutWeight(1)
                            .alignItems(HorizontalAlign.Center)
                            Image(@r(app.media.media_ic_share))
                                .width(28)
                                .height(28)
                                .fillColor(0xFF0A84FF)
                                .onClick({ _ => this.shareCurrentPhotoExternally() })
                        }
                        .width(100.percent)
                        .height(76)
                        .padding(left: 24, right: 24)
                        .alignItems(VerticalAlign.Center)
                    }

                    if (this.shareTargetsLoading) {
                        Text(trSource("Loading..."))
                            .fontSize(14)
                            .fontColor(0xFF8E8E93)
                            .height(100)
                    } else {
                        Scroll {
                            Row {
                                ForEach(this.getVisibleShareTargets().toArray(), itemGenerator: { target: ShareTarget, _idx: Int64 =>
                                    SharePageGridSectionNode(
                                        target: target,
                                        isSelected: this.isShareTargetSelected(target),
                                        darkStyle: true,
                                        onTap: { => this.toggleShareTarget(target) }
                                    )
                                })
                            }
                            .padding(left: 9, right: 9)
                        }
                        .width(100.percent)
                        .height(106)
                        .scrollable(ScrollDirection.Horizontal)
                        .scrollBar(BarState.Off)
                    }

                    Column {}.layoutWeight(1)
                    Divider().color(0xFF343436)
                    Text(if (this.selectedShareTargets.isEmpty()) { "Save Image" } else if (this.shareSending) { "Sending..." } else { "Send" })
                        .fontSize(20)
                        .fontColor(0xFF0A84FF)
                        .width(100.percent)
                        .height(58)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ =>
                            if (this.selectedShareTargets.isEmpty()) {
                                this.saveCurrentPhoto()
                            } else {
                                this.sendCurrentPhoto()
                            }
                        })
                }
                .width(100.percent)
                .height(420)
                .backgroundColor(0xFF1C1C1E)
                .borderRadius(18)

                Text(trSource("Cancel"))
                    .fontSize(20)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0xFF0A84FF)
                    .width(100.percent)
                    .height(58)
                    .textAlign(TextAlign.Center)
                    .backgroundColor(0xFF1C1C1E)
                    .borderRadius(18)
                    .margin(top: 8)
                    .onClick({ _ => this.showShareSheet = false })
            }
            .width(100.percent)
            .padding(left: 10, right: 10, bottom: getSafeAreaBottom() + 6.0)
        }
        .width(100.percent)
        .height(100.percent)
    }

    private func pickAndUploadNewPhoto(): Unit {
        requestAvatarPickerPresentation()
        routerPop()
    }

    private func uploadNewPhoto(uri: String): Unit {
        if (this.isUploadingPhoto) { return }
        this.isUploadingPhoto = true
        let uid = this.userId
        let ah = this.accessHash
        spawn {
            try {
                var realPath = uri
                if (realPath.startsWith("file://")) { realPath = realPath[7..] }
                let photoData = getImageCompressionService().compressToMaxPixelSize(
                    realPath, Int32(1280), UInt8(86)
                )
                if (photoData.isEmpty()) {
                    launch { this.isUploadingPhoto = false }
                    return
                }
                let result = getSettingsService().uploadAndSetProfilePhoto(photoData, "profile.jpg")
                if (!result.success) {
                    launch { this.isUploadingPhoto = false }
                    return
                }
                let svc = getPeerAvatarGalleryService()
                // Drop both the downloaded-history cache and the previous current
                // avatar before publishing the freshly selected local copy.
                svc.invalidateAvatarCache(uid)
                let filesDir = getAppFilesDir()
                if (filesDir.size > 0 && uid > 0) {
                    let avatarDir = filesDir + "/avatars"
                    try { FileIo.mkdir(avatarDir) } catch (_e: Exception) {}
                    let uniquePhotoId = if (result.photoId != 0) { result.photoId } else { DateTime.now().toUnixTimeStamp().toSeconds() }
                    let avatarPath = avatarDir + "/avatar_${uid}_${uniquePhotoId}.jpg"
                    let outFile = FileIo.open(avatarPath, mode: 0o1101)
                    FileIo.write(outFile.fd, photoData)
                    FileIo.close(outFile)
                    getUserPhotoService().setUserPhotoPath(uid, "file://" + avatarPath)
                }
                let metas = this.normalizeGalleryMetas(svc.fetchAvatarPhotoMetas(uid, ah, limit: 20))
                let refreshedPaths = ArrayList<String>()
                for (m in metas) { refreshedPaths.add(m.downloadedPath) }
                launch {
                    this.photoMetas = metas
                    this.photos = refreshedPaths
                    this.currentIndex = 0
                    this.isCurrentMain = true
                    this.isUploadingPhoto = false
                }
            } catch (e: Exception) {
                Hilog.warn(0, "CjTelegram", "[AvatarGalleryPage] upload failed: ${e}")
                launch { this.isUploadingPhoto = false }
            }
        }
    }

    // ─── Set-as-main 辅助方法 ────────────────────────────────────────────────────

    private func getSetMainButtonText(): String {
        if (this.isSettingMain) {
            return "Setting..."
        }
        if (this.isCurrentMain) {
            return "Main Photo"
        }
        return "Set as Main"
    }

    private func canSetAsMain(): Bool {
        if (this.isSettingMain) { return false }
        if (this.isCurrentMain) { return false }
        let idx = Int64(this.currentIndex)
        if (idx < 0 || idx >= Int64(this.photoMetas.size)) { return false }
        let meta = this.photoMetas[idx]
        if (meta.photoId == 0) { return false }
        return true
    }

    private func performSetAsMain(): Unit {
        let idx = Int64(this.currentIndex)
        if (idx < 0 || idx >= Int64(this.photoMetas.size)) { return }
        let meta = this.photoMetas[idx]
        if (meta.photoId == 0) { return }

        let capturedPhotoId = meta.photoId
        let capturedAccessHash = meta.accessHash
        let capturedFileRef = meta.fileReference
        let selectedPath = meta.downloadedPath
        let uid = this.userId
        Hilog.info(0, "CjTelegram", "[AvatarGalleryPage] setAsMain photoId=${capturedPhotoId} uid=${uid}")
        this.isSettingMain = true
        this.setMainSuccess = false

        let _ = spawn {
            let svc = getPeerAvatarGalleryService()
            let ok = svc.setAsMainPhoto(capturedPhotoId, capturedAccessHash, capturedFileRef)
            if (ok) {
                svc.invalidateAvatarCache(uid)
                getUserPhotoService().setUserPhotoPath(uid, selectedPath)
                let refreshedMetas = this.prioritizePhotoAsMain(
                    this.normalizeGalleryMetas(svc.fetchAvatarPhotoMetas(uid, this.accessHash, limit: 20)),
                    capturedPhotoId,
                    selectedPath
                )
                let refreshedPaths = ArrayList<String>()
                for (m in refreshedMetas) { refreshedPaths.add(m.downloadedPath) }
                launch {
                    this.photoMetas = refreshedMetas
                    this.photos = refreshedPaths
                    this.currentIndex = 0
                    this.imageScale = Float32(1.0)
                    this.imageOffsetX = 0.0
                    this.imageOffsetY = 0.0
                    this.isCurrentMain = true
                    this.isSettingMain = false
                    this.setMainSuccess = true
                    Hilog.info(0, "CjTelegram", "[AvatarGalleryPage] setAsMain success, refreshed ${refreshedPaths.size} photos")
                }
            } else {
                launch {
                    this.isSettingMain = false
                    this.setMainSuccess = false
                    Hilog.info(0, "CjTelegram", "[AvatarGalleryPage] setAsMain failed uid=${uid} photoId=${capturedPhotoId}")
                }
            }
        }
    }

    // ─── 双指捏合缩放（onTouch 实现）──────────────────────────────────────────────

    private func handleTouchZoom(event: TouchEvent): Unit {
        let touchCount = event.touches.size
        if (touchCount >= 2) {
            this.singleTouchTracking = false
            let t0 = event.touches[0]
            let t1 = event.touches[1]
            let dx = t1.x - t0.x
            let dy = t1.y - t0.y
            let dist = sqrt(dx * dx + dy * dy)
            if (dist < 1.0) { return }

            if (this.lastPinchDist > 1.0) {
                let ratio = Float32(dist / this.lastPinchDist)
                let newScale = this.imageScale * ratio
                if (newScale < Float32(1.0)) {
                    this.imageScale = Float32(1.0)
                } else if (newScale > Float32(4.0)) {
                    this.imageScale = Float32(4.0)
                } else {
                    this.imageScale = newScale
                }
            }
            this.lastPinchDist = dist
            if (event.eventType == TouchType.Up || event.eventType == TouchType.Cancel) {
                this.lastPinchDist = 0.0
                this.clampImageOffset()
            }
            return
        }

        if (touchCount == 1) {
            let touch = event.touches[0]
            if (event.eventType == TouchType.Down) {
                this.singleTouchStartX = touch.x
                this.singleTouchStartY = touch.y
                this.singleTouchBaseOffsetX = this.imageOffsetX
                this.singleTouchBaseOffsetY = this.imageOffsetY
                this.singleTouchTracking = true
                this.singleTouchMoved = false
                this.lastPinchDist = 0.0
                return
            }
            if (event.eventType == TouchType.Move && this.singleTouchTracking) {
                let dx = touch.x - this.singleTouchStartX
                let dy = touch.y - this.singleTouchStartY
                let absDx = if (dx < 0.0) { -dx } else { dx }
                let absDy = if (dy < 0.0) { -dy } else { dy }
                if (absDx > 6.0 || absDy > 6.0) { this.singleTouchMoved = true }
                if (this.imageScale > Float32(1.01)) {
                    this.imageOffsetX = this.singleTouchBaseOffsetX + dx
                    this.imageOffsetY = this.singleTouchBaseOffsetY + dy
                }
                return
            }
            if ((event.eventType == TouchType.Up || event.eventType == TouchType.Cancel) &&
                this.singleTouchTracking) {
                this.singleTouchTracking = false
                if (this.imageScale > Float32(1.01)) { this.clampImageOffset() }
                return
            }
        }

        if (event.eventType == TouchType.Up || event.eventType == TouchType.Cancel) {
            this.lastPinchDist = 0.0
            this.singleTouchTracking = false
        }
    }

    private func selectPreviousPhoto(): Unit {
        if (this.currentIndex <= 0) { return }
        this.currentIndex = this.currentIndex - 1
        this.imageScale = Float32(1.0)
    }

    private func selectNextPhoto(): Unit {
        if (Int64(this.currentIndex) + 1 >= this.getPhotoCount()) { return }
        this.currentIndex = this.currentIndex + 1
        this.imageScale = Float32(1.0)
    }

    private func handlePhotoTapGesture(): Unit {
        if (this.singleTouchMoved) {
            this.singleTouchMoved = false
            return
        }
        this.tapCount = this.tapCount + 1
        this.tapVersion = this.tapVersion + 1
        let version = this.tapVersion
        if (this.tapCount >= 2) {
            this.tapCount = 0
            this.tapVersion = this.tapVersion + 1
            if (this.imageScale > Float32(1.01)) {
                this.imageScale = Float32(1.0)
                this.imageOffsetX = 0.0
                this.imageOffsetY = 0.0
            } else {
                this.imageScale = Float32(4.0)
                let localX = this.singleTouchStartX - this.galleryWidthVp / 2.0
                let localY = this.singleTouchStartY - this.galleryHeightVp / 2.0
                this.imageOffsetX = -localX * 3.0
                this.imageOffsetY = -localY * 3.0
                this.clampImageOffset()
            }
            return
        }
        let _ = spawn {
            sleep(Duration.millisecond * 600)
            launch {
                if (this.tapVersion == version && this.tapCount == 1) {
                    this.tapCount = 0
                    this.handlePhotoTap()
                }
            }
        }
    }

    private func clampImageOffset(): Unit {
        let scaleDelta = Float64(this.imageScale) - 1.0
        if (scaleDelta <= 0.0) {
            this.imageOffsetX = 0.0
            this.imageOffsetY = 0.0
            return
        }
        let maxX = this.galleryWidthVp * scaleDelta / 2.0
        let maxY = this.galleryHeightVp * scaleDelta / 2.0
        if (this.imageOffsetX > maxX) { this.imageOffsetX = maxX }
        if (this.imageOffsetX < -maxX) { this.imageOffsetX = -maxX }
        if (this.imageOffsetY > maxY) { this.imageOffsetY = maxY }
        if (this.imageOffsetY < -maxY) { this.imageOffsetY = -maxY }
    }

    // ─── 私有辅助方法 ─────────────────────────────────────────────────────────────

    /**
     * 解析路由参数 "userId|accessHash|peerName|initialIndex"
     */
    private func parseRouteParam(raw: String): Unit {
        if (raw.size == 0) {
            Hilog.info(0, "CjTelegram", "[AvatarGalleryPage] no route param")
            return
        }
        let parts = raw.split("|")
        if (parts.size >= 1) {
            this.userId = this.parseInt64(parts[0])
        }
        if (parts.size >= 2) {
            this.accessHash = this.parseInt64(parts[1])
        }
        if (parts.size >= 3) {
            this.peerName = parts[2]
        }
        if (parts.size >= 4) {
            this.initialIndex = Int32(this.parseInt64(parts[3]))
            this.currentIndex = this.initialIndex
        }
        this.isCurrentMain = (this.currentIndex == 0)
        Hilog.info(0, "CjTelegram", "[AvatarGalleryPage] uid=${this.userId} name=${this.peerName}")
    }

    private func performDeleteCurrentPhoto(): Unit {
        this.showDeleteConfirm = false
        let uid = this.userId
        let ah = this.accessHash
        let idx = this.currentIndex
        Hilog.info(0, "CjTelegram", "[AvatarGalleryPage] delete photo idx=${idx} uid=${uid}")
        let count = this.getPhotoCount()
        if (count == 0) {
            routerPop()
            return
        }

        var deletePhotoId: Int64 = 0
        var deleteAccessHash: Int64 = 0
        var deleteFileRef: Array<Byte> = Array<Byte>(0, repeat: 0)
        let metaIdx = Int64(idx)
        if (metaIdx >= 0 && metaIdx < Int64(this.photoMetas.size)) {
            let meta = this.photoMetas[metaIdx]
            deletePhotoId = meta.photoId
            deleteAccessHash = meta.accessHash
            deleteFileRef = meta.fileReference
        }

        let newMetas = ArrayList<AvatarPhotoInfo>()
        var mi: Int64 = 0
        while (mi < Int64(this.photoMetas.size)) {
            if (mi != metaIdx) {
                newMetas.add(this.photoMetas[mi])
            }
            mi = mi + 1
        }
        let newPhotos = ArrayList<String>()
        for (m in newMetas) {
            newPhotos.add(m.downloadedPath)
        }

        let capturedPhotoId = deletePhotoId
        let capturedAccessHash = deleteAccessHash
        let capturedFileRef = deleteFileRef
        if (newPhotos.isEmpty()) {
            getUserPhotoService().clearUserPhoto(uid)
        } else if (idx == 0) {
            getUserPhotoService().setUserPhotoPath(uid, newPhotos[0])
        }
        let _ = spawn {
            let svc = getPeerAvatarGalleryService()
            if (capturedPhotoId != 0) {
                let idsToDelete = ArrayList<Int64>()
                idsToDelete.add(capturedPhotoId)
                let hashesToDelete = ArrayList<Int64>()
                hashesToDelete.add(capturedAccessHash)
                let refsToDelete = ArrayList<Array<Byte>>()
                refsToDelete.add(capturedFileRef)
                let deleted = svc.deletePhotos(idsToDelete, hashesToDelete, refsToDelete)
                Hilog.info(0, "CjTelegram", "[AvatarGalleryPage] deletePhotos RPC: ${deleted.size} confirmed uid=${uid} photoId=${capturedPhotoId}")
            } else {
                Hilog.info(0, "CjTelegram", "[AvatarGalleryPage] deletePhotos: no meta for idx=${idx}, skip RPC uid=${uid}")
            }
            svc.invalidateAvatarCache(uid)
            if (!newPhotos.isEmpty()) {
                getUserPhotoService().setUserPhotoPath(uid, newPhotos[0])
            }
            let metas = this.normalizeGalleryMetas(svc.fetchAvatarPhotoMetas(uid, ah, limit: 20))
            let refreshedPaths = ArrayList<String>()
            for (m in metas) {
                refreshedPaths.add(m.downloadedPath)
            }
            launch {
                this.photoMetas = metas
                this.photos = refreshedPaths
                this.imageScale = Float32(1.0)
                if (refreshedPaths.isEmpty()) {
                    routerPop()
                } else {
                    let newIdx = Int32(if (Int64(idx) >= Int64(refreshedPaths.size)) { Int64(refreshedPaths.size) - 1 } else { Int64(idx) })
                    this.currentIndex = newIdx
                    this.isCurrentMain = (newIdx == 0)
                }
            }
        }

        // 乐观 UI 更新
        this.photos = newPhotos
        this.photoMetas = newMetas
        this.imageScale = Float32(1.0)
        if (newPhotos.isEmpty()) {
            routerPop()
        } else {
            let newIdx = Int32(if (Int64(idx) >= Int64(newPhotos.size)) { Int64(newPhotos.size) - 1 } else { Int64(idx) })
            this.currentIndex = newIdx
            this.isCurrentMain = (newIdx == 0)
        }
    }

    private func buildTitle(): String {
        if (this.peerName.size > 0) {
            return this.peerName
        }
        return "Photos"
    }

    private func buildPhotoSubtitle(): String {
        let idx = Int64(this.currentIndex)
        if (idx < 0 || idx >= Int64(this.photoMetas.size)) { return "Profile Photo" }
        let timestamp = Int64(this.photoMetas[idx].date)
        if (timestamp <= 0) { return "Profile Photo" }
        let now = DateTime.now().toUnixTimeStamp().toSeconds()
        let photoDay = localDayIndexOf(timestamp)
        let today = localDayIndexOf(now)
        let clock = formatClockHHMM(timestamp)
        if (photoDay == today) { return "today at ${clock}" }
        if (photoDay == today - 1) { return "yesterday at ${clock}" }
        return "${formatShortDateSlashed(timestamp)} at ${clock}"
    }

    private func normalizeGalleryMetas(raw: ArrayList<AvatarPhotoInfo>): ArrayList<AvatarPhotoInfo> {
        if (raw.size <= 1 || raw[0].photoId != 0) { return raw }

        // The local current-avatar entry is the visible main photo, while the
        // matching server entry is the first item in the newest-first result.
        // Merge its RPC metadata into the local entry and omit that duplicate;
        // this preserves current-photo-first ordering and keeps Remove working.
        let current = raw[0]
        let serverCurrent = raw[1]
        current.photoId = serverCurrent.photoId
        current.accessHash = serverCurrent.accessHash
        current.dcId = serverCurrent.dcId
        current.date = serverCurrent.date
        current.fileReference = serverCurrent.fileReference
        current.thumbSize = serverCurrent.thumbSize

        let result = ArrayList<AvatarPhotoInfo>()
        result.add(current)
        var i: Int64 = 2
        while (i < Int64(raw.size)) {
            result.add(raw[i])
            i = i + 1
        }
        return result
    }

    private func prioritizePhotoAsMain(
        metas: ArrayList<AvatarPhotoInfo>,
        photoId: Int64,
        selectedPath: String
    ): ArrayList<AvatarPhotoInfo> {
        var selected: Option<AvatarPhotoInfo> = None
        for (item in metas) {
            if (item.photoId == photoId) {
                selected = Some(item)
                break
            }
        }
        match (selected) {
            case None => return metas
            case Some(selectedItem) =>
                selectedItem.downloadedPath = selectedPath
                let ordered = ArrayList<AvatarPhotoInfo>()
                ordered.add(selectedItem)
                for (item in metas) {
                    if (item.photoId != photoId) { ordered.add(item) }
                }
                return ordered
        }
    }

    private func getIndexText(): String {
        let total = this.getPhotoCount()
        if (total == 0) { return "" }
        return "${Int64(this.currentIndex) + 1} of ${total}"
    }

    private func getPhotoCount(): Int64 {
        return Int64(this.photos.size)
    }

    private func getPhotosArray(): Array<String> {
        return this.photos.toArray()
    }

    private func parseInt64(s: String): Int64 {
        var result: Int64 = 0
        var negative = false
        var start: Int64 = 0
        let runes = s.toRuneArray()
        if (runes.size > 0 && runes[0] == r'-') {
            negative = true
            start = 1
        }
        var i = start
        while (i < Int64(runes.size)) {
            let d = Int64(UInt32(runes[i])) - 48
            if (d < 0 || d > 9) { break }
            result = result * 10 + d
            i = i + 1
        }
        if (negative) { return -result }
        return result
    }
}
