package ohos_app_cangjie_entry.pages

/**
 * LocationDetailPage — 应用内地图详情页（P2-183）
 *
 * iOS 对应:
 *   submodules/LocationUI/Sources/LocationViewController.swift
 *   submodules/LocationUI/Sources/LocationViewControllerNode.swift
 *
 * 功能:
 *   - 显示静态地图快照（通过 LocationResourcesService.fetchMapSnapshot）
 *   - 显示坐标与反向地理编码地址
 *   - 导航按钮（调用 LocationDistanceService.openInMaps）
 *   - 返回按钮
 *
 * Gap 修复 (P2-183):
 *   - 原 MessageBubble locationContent 点击 "View on Map" → 开外部 Google Maps URL
 *   - 修复后: 点击 → pageStack.pushPathByName("LocationDetailPage", "${lat}|${lng}|${title}")
 *             → LocationDetailPage 应用内显示静态快照 + 坐标 + 地址 + 导航按钮
 *
 * 调用链 (P2-183 完整):
 *   MessageBubble.locationContent.onClick
 *     → onLocationTap(lat, lng, title)
 *       → pageStack.pushPathByName("LocationDetailPage", "${lat}|${lng}|${title}")
 *         → LocationDetailPage.onReady → parseParam → loadSnapshot + reverseGeocode
 *           → LocationResourcesService.fetchMapSnapshot(lat, lng, 320, 200)
 *           → reverseGeocodeLocation(lat, lng, onResult)
 *
 * P2-192 快照接线:
 *   LocationDetailPage.loadSnapshot → fetchMapSnapshot → LocationResourcesService (缓存 → OSM HTTP)
 *
 * D-002: 根容器为 NavDestination
 * S-001: 异步 @State 更新须在 launch{} 内
 */

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import std.convert.*
import ohos_app_cangjie_entry.services.{
    getLocationResourcesService,
    getLocationDistanceService,
    reverseGeocodeLocation
}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

@HybridComponentEntry
@Component
public class LocationDetailPage {
    @State var loaded: Bool = false

    // 位置参数（通过 NavDestinationContext.pathInfo.param 传入，格式 "lat|lng|title"）
    @State var locationLat: Float64 = 0.0
    @State var locationLng: Float64 = 0.0
    @State var locationTitle: String = ""

    // 地图快照状态
    @State var snapshotPath: String = ""
    @State var isLoadingSnapshot: Bool = false
    @State var snapshotError: Bool = false

    // 反向地理编码地址
    @State var resolvedAddress: String = ""
    @State var isResolvingAddress: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        // 混合迁移：原 onReady 经 NavDestination param 取参，改为 takePending。
        let raw = takePending("LocationDetailPage")
        if (raw.size > 0 && raw != "{}") {
            this.parseRouteParam(raw)
        }
    }

    public func build() {
        Column {
                // 导航栏
                Row {
                    Text("← 返回")
                        .fontSize(17)
                        .fontColor(0x0088CC)
                        .onClick({ _evt =>
                            routerPop()
                        })
                    Blank()
                    Text(if (this.locationTitle.size > 0) { this.locationTitle } else { "位置" })
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                    Blank()
                    Row {}.width(60)
                }
                .width(100.percent)
                .height(56.0 + getSafeAreaTop())
                .padding(left: 16, right: 16, top: getSafeAreaTop())
                .backgroundColor(0xFFFFFF)
                .alignItems(VerticalAlign.Center)

                // 地图快照区域 (P2-192 + P2-183)
                Stack(alignContent: Alignment.Center) {
                    if (this.snapshotPath.size > 0) {
                        // 真实快照图片
                        Image(this.snapshotPath)
                            .width(100.percent)
                            .height(240)
                            .objectFit(ImageFit.Cover)
                    } else {
                        // 占位 + 加载状态
                        Column {
                            if (this.isLoadingSnapshot) {
                                LoadingProgress()
                                    .width(40)
                                    .height(40)
                                    .color(0x0088CC)
                                Text("加载地图...")
                                    .fontSize(13)
                                    .fontColor(0x8E8E93)
                                    .margin(top: 8)
                            } else if (this.snapshotError) {
                                // 资源保真修复：真实矢量图标（Item List/Icons/Location.imageset/location.pdf 转 SVG）替代 emoji 字形
                                Image(@r(app.media.loc_ic_maprow))
                                    .width(48)
                                    .height(48)
                                    .fillColor(0x8E8E93)
                                Text("地图加载失败")
                                    .fontSize(13)
                                    .fontColor(0x8E8E93)
                                    .margin(top: 8)
                            } else {
                                Column {}
                                    .width(100.percent)
                                    .height(240)
                                    .backgroundColor(0xC8D8E8)
                            }
                        }
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                    }

                    // 位置 pin 叠加层
                    // 资源保真修复：真实矢量图标（Item List/Icons/Location.imageset/location.pdf 转 SVG）替代 emoji 字形
                    Column {
                        Image(@r(app.media.loc_ic_maprow))
                            .width(36)
                            .height(36)
                            .fillColor(0xFF3B30)
                        Column {}
                            .width(8)
                            .height(4)
                            .backgroundColor(0x33000000)
                            .borderRadius(4)
                            .margin(top: 2)
                    }
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                }
                .width(100.percent)
                .height(240)
                .backgroundColor(0xC8D8E8)
                .clip(true)

                // 位置信息区域
                Column {
                    // 地址行
                    // 资源保真修复：真实矢量图标（Item List/Icons/Location.imageset/location.pdf 转 SVG）替代 emoji 字形
                    Row {
                        Image(@r(app.media.loc_ic_maprow))
                            .width(20)
                            .height(20)
                            .fillColor(0xFF3B30)
                            .margin(right: 12)
                        Column {
                            if (this.resolvedAddress.size > 0) {
                                Text(this.resolvedAddress)
                                    .fontSize(16)
                                    .fontColor(0x000000)
                                    .maxLines(2)
                            } else if (this.isResolvingAddress) {
                                Text("正在解析地址...")
                                    .fontSize(14)
                                    .fontColor(0x8E8E93)
                            } else {
                                Text(this.getCoordinatesText())
                                    .fontSize(14)
                                    .fontColor(0x8E8E93)
                            }
                            Text(this.getCoordinatesText())
                                .fontSize(12)
                                .fontColor(0xC7C7CC)
                                .margin(top: 2)
                        }
                        .alignItems(HorizontalAlign.Start)
                        .layoutWeight(1)
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 14, bottom: 14)
                    .alignItems(VerticalAlign.Center)

                    Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)

                    // 导航按钮行
                    // 资源保真修复：真实矢量图标（Location/GoTo.imageset/goto.pdf 转 SVG）替代 emoji 字形
                    Row {
                        Image(@r(app.media.loc_ic_goto))
                            .width(20)
                            .height(20)
                            .fillColor(0x0088CC)
                            .margin(right: 12)
                        Text("导航到此处")
                            .fontSize(17)
                            .fontColor(0x0088CC)
                        Blank()
                        Text("›")
                            .fontSize(20)
                            .fontColor(0xC7C7CC)
                    }
                    .width(100.percent)
                    .height(56)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _evt =>
                        this.openNavigation()
                    })
                }
                .backgroundColor(0xFFFFFF)
                .borderRadius(12)
                .margin(left: 16, right: 16, top: 16)
            }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }

    // ==================== 路由参数解析 ====================

    private func parseRouteParam(paramStr: String): Unit {
        if (paramStr.size == 0) { return }

        // 格式: "lat|lng|title"
        let parts = paramStr.split("|")
        if (parts.size >= 2) {
            let lat = try { Float64.parse(parts[0]) } catch (_: Exception) { 0.0 }
            let lng = try { Float64.parse(parts[1]) } catch (_: Exception) { 0.0 }
            let title = if (parts.size >= 3) { parts[2] } else { "" }
            launch {
                this.locationLat = lat
                this.locationLng = lng
                this.locationTitle = title
            }
            Hilog.info(0, "CjTelegram", "[LocationDetailPage] param parsed OK")
            this.loadMapSnapshot(lat, lng)
            this.loadAddress(lat, lng)
        }
    }

    // ==================== 地图快照加载 (P2-192) ====================

    /**
     * 加载地图静态快照
     * 调用链: loadMapSnapshot → getLocationResourcesService().fetchMapSnapshot
     *         → LocationResourcesService (缓存 → OSM HTTP GET → 磁盘写)
     */
    private func loadMapSnapshot(lat: Float64, lng: Float64): Unit {
        launch { this.isLoadingSnapshot = true }
        let _ = spawn {
            let svc = getLocationResourcesService()
            let result = svc.fetchMapSnapshot(lat, lng, 640, 480, zoom: 15)
            if (result.success) {
                let path = result.localPath
                launch {
                    this.snapshotPath = path
                    this.isLoadingSnapshot = false
                }
                Hilog.info(0, "CjTelegram", "[LocationDetailPage] snapshot loaded")
            } else {
                launch {
                    this.isLoadingSnapshot = false
                    this.snapshotError = true
                }
                Hilog.info(0, "CjTelegram", "[LocationDetailPage] snapshot failed")
            }
        }
    }

    // ==================== 反向地理编码 (P2-190) ====================

    /**
     * 异步反向地理编码
     * 调用链: loadAddress → reverseGeocodeLocation → GeocodingService → ArkTS geoLocationManager
     */
    private func loadAddress(lat: Float64, lng: Float64): Unit {
        launch { this.isResolvingAddress = true }
        reverseGeocodeLocation(lat, lng, { addrOpt: Option<String> =>
            match (addrOpt) {
                case Some(addr) =>
                    launch {
                        this.resolvedAddress = addr
                        this.isResolvingAddress = false
                    }
                    Hilog.info(0, "CjTelegram", "[LocationDetailPage] address resolved")
                case None =>
                    launch { this.isResolvingAddress = false }
                    Hilog.info(0, "CjTelegram", "[LocationDetailPage] address resolve failed")
            }
        })
    }

    // ==================== 导航 ====================

    private func openNavigation(): Unit {
        let svc = getLocationDistanceService()
        let label = if (this.resolvedAddress.size > 0) { this.resolvedAddress } else { this.getCoordinatesText() }
        svc.openInMaps(this.locationLat, this.locationLng, label)
        Hilog.info(0, "CjTelegram", "[LocationDetailPage] openInMaps")
    }

    // ==================== 辅助 ====================

    private func getCoordinatesText(): String {
        let latStr = "${this.locationLat}"
        let lngStr = "${this.locationLng}"
        let shortLat = if (latStr.size > 8) { latStr[0..8] } else { latStr }
        let shortLng = if (lngStr.size > 8) { lngStr[0..8] } else { lngStr }
        return shortLat + ", " + shortLng
    }
}
