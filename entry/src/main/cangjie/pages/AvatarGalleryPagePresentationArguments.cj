package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*

/**
 * AvatarGalleryPagePresentationArguments — 头像画廊参数展示页（PAVG-UI-1）（混合工程迁移版）
 *
 * 对应 iOS AvatarGalleryControllerPresentationArguments：
 * 封装打开头像画廊所需的所有参数，并提供一个预览卡片 UI，
 * 让调用方可在跳转前预览参数并确认进入。
 *
 * 路由注册：route_map.json "AvatarGalleryPagePresentationArguments"（RouteName = 类名）
 *
 * 路由参数格式（JSON 字符串，经 ParamStore takePending 取回）：
 *   "userId|accessHash|peerName|initialIndex"
 *   例："-1001234567890|-9876543210|John Doe|0"
 *
 * 调用链：
 *   ensureLoaded()  (.onAppear 触发)
 *     → takePending("AvatarGalleryPagePresentationArguments")
 *     → parseRouteParam(raw)        // 解析 userId / accessHash / peerName / initialIndex
 *     → PeerAvatarGalleryService.getCurrentAvatarPath(userId) // 当前头像（预览用）
 *
 * 进入画廊：
 *   Button("View All Photos").onClick
 *     → routerPush("AvatarGalleryPage", routeParam)
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry；去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹（原 .title(...)/.hideTitleBar(false)/.onReady），只留内容
 *  - appStack.pushPathByName("AvatarGalleryPage", param) → routerPush("AvatarGalleryPage", param)
 *  - onReady param 接收 → ensureLoaded() 内 takePending()
 */
@HybridComponentEntry
@Component
public class AvatarGalleryPagePresentationArguments {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var userId: Int64 = 0
    @State var accessHash: Int64 = 0
    @State var peerName: String = ""
    @State var initialIndex: Int32 = 0
    @State var currentAvatarPath: String = ""
    @State var isReady: Bool = false

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let raw = takePending("AvatarGalleryPagePresentationArguments")
        let param = if (raw == "{}") { "" } else { raw }
        this.parseRouteParam(param)
    }

    public func build() {
        Column {
            if (this.isReady) {
                this.buildContent()
            } else {
                Column {
                    Text(trSource("Loading..."))
                        .fontSize(15)
                        .fontColor(0x8E8E93)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x1C1C1E)
        .onAppear({ => this.ensureLoaded() })
    }

    @Builder private func buildContent(): Unit {
        Column {
            // 头像预览区域
            Stack {
                if (this.currentAvatarPath.size > 0) {
                    Image(this.currentAvatarPath)
                        .width(120)
                        .height(120)
                        .borderRadius(60)
                        .objectFit(ImageFit.Cover)
                } else {
                    Column {
                        Text(this.getAvatarPlaceholder())
                            .fontSize(48)
                            .fontColor(0xFFFFFF)
                            .textAlign(TextAlign.Center)
                    }
                    .width(120)
                    .height(120)
                    .borderRadius(60)
                    .backgroundColor(0x3A3A3C)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                }
            }
            .width(120)
            .height(120)
            .margin(top: 40, bottom: 16)

            // 用户名
            Text(if (this.peerName.size > 0) { this.peerName } else { "Unknown" })
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor(0xFFFFFF)
                .textAlign(TextAlign.Center)
                .margin(bottom: 8)

            // 说明文字
            Text("Tap below to view all profile photos")
                .fontSize(14)
                .fontColor(0x8E8E93)
                .textAlign(TextAlign.Center)
                .margin(bottom: 40)

            // 进入画廊按钮
            Button("View All Photos")
                .fontSize(16)
                .fontColor(0xFFFFFF)
                .backgroundColor(0x0A84FF)
                .borderRadius(10)
                .height(48)
                .width(200)
                .onClick({ _ =>
                    this.openAvatarGallery()
                })

            Blank()
                .layoutWeight(1)
        }
        .width(100.percent)
        .height(100.percent)
        .alignItems(HorizontalAlign.Center)
    }

    // ─── 私有辅助方法 ─────────────────────────────────────────────────────────

    /**
     * 解析路由参数字符串 "userId|accessHash|peerName|initialIndex"
     */
    private func parseRouteParam(raw: String): Unit {
        if (raw.size == 0) {
            Hilog.info(0, "CjTelegram", "[AvatarGalleryArgs] no route param, using defaults")
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
            let idxStr = parts[3]
            this.initialIndex = Int32(this.parseInt64(idxStr))
        }
        Hilog.info(0, "CjTelegram", "[AvatarGalleryArgs] uid=${this.userId} name=${this.peerName}")
        // 触发当前头像加载
        let path = getPeerAvatarGalleryService().getCurrentAvatarPath(this.userId)
        launch {
            this.currentAvatarPath = path
            this.isReady = true
        }
    }

    /** 打开 AvatarGalleryPage 大图浏览 */
    private func openAvatarGallery(): Unit {
        let param = this.userId.toString() + "|" + this.accessHash.toString() + "|" +
                    this.peerName + "|" + this.initialIndex.toString()
        routerPush("AvatarGalleryPage", param)
    }

    /** 生成头像占位文字（取名字首字母）*/
    private func getAvatarPlaceholder(): String {
        if (this.peerName.size == 0) { return "?" }
        let runes = this.peerName.toRuneArray()
        if (runes.size > 0) { return String(runes[0]) }
        return "?"
    }

    /** 将字符串解析为 Int64 */
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
