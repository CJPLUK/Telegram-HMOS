package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * MediaGroupsScreen — 相册分组列表页面（P2-208）（混合工程迁移版）
 *
 * iOS 对应：
 *   submodules/MediaPickerUI/Sources/MediaGroupsScreen.swift
 *   submodules/MediaPickerUI/Sources/MediaGroupsAlbumItem.swift
 *
 * 功能（P2-208 相册分组切换）：
 *   - 列举用户相册分组（含系统相册：Camera Roll / Favorites / Videos）
 *   - 每行显示相册封面缩略图 + 名称 + 媒体数量
 *   - 点击相册进入 MediaPickerScreen（路由参数为 albumUri）
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容 + .onAppear
 *  - aboutToAppear 有实逻辑（fetchAlbumGroups）→ ensureLoaded()
 *  - pushPathByName → routerPush
 */
@HybridComponentEntry
@Component
public class MediaGroupsScreen {
    @State var albumGroups: ArrayList<MediaAlbumGroup> = ArrayList<MediaAlbumGroup>()
    @State var isLoading: Bool = false
    @State var errorMessage: String = ""
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let _ = spawn {
            launch {
                this.isLoading = true
                this.errorMessage = ""
            }
            let ctx = getGlobalAbilityContext()
            match (ctx) {
                case None =>
                    Hilog.info(0, "CjTelegram", "[MediaGroupsScreen] no ability context, skipping fetchAlbumGroups")
                    launch { this.isLoading = false }
                case Some(abilityCtx) =>
                    let groups = getMediaPickerService().fetchAlbumGroups(abilityCtx)
                    launch {
                        var t = ArrayList<MediaAlbumGroup>()
                        for (g in groups) {
                            t.add(g)
                        }
                        this.albumGroups = t
                        this.isLoading = false
                    }
            }
        }
    }

    public func build() {
        Column {
            if (this.isLoading) {
                this.buildLoadingView()
            } else if (this.errorMessage.size > 0) {
                this.buildErrorView()
            } else if (this.albumGroups.size == 0) {
                this.buildEmptyView()
            } else {
                this.buildAlbumList()
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFF)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }

    @Builder
    func buildLoadingView() {
        Column {
            Text("Loading albums...")
                .fontSize(16)
                .fontColor(0x8E8E93)
        }
        .width(100.percent)
        .height(100.percent)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    func buildErrorView() {
        Column {
            Text(this.errorMessage)
                .fontSize(14)
                .fontColor(0xFF3B30)
                .textAlign(TextAlign.Center)
                .margin(16)
        }
        .width(100.percent)
        .height(100.percent)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    func buildEmptyView() {
        Column {
            Text("No albums found")
                .fontSize(16)
                .fontColor(0x8E8E93)
        }
        .width(100.percent)
        .height(100.percent)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    func buildAlbumList() {
        List {
            ForEach(
                Array<MediaAlbumGroup>(this.albumGroups.size, { i: Int64 => this.albumGroups[i] }),
                itemGenerator: { group: MediaAlbumGroup, idx: Int64 =>
                    ListItem {
                        this.buildAlbumRow(group)
                    }
                }
            )
        }
        .width(100.percent)
        .layoutWeight(1)
        .divider(ListDividerOptions(strokeWidth: 1, color: 0xE5E5EA, startMargin: 16, endMargin: 0))
    }

    @Builder
    func buildAlbumRow(group: MediaAlbumGroup) {
        Row {
            // 相册封面缩略图（P2-208：真实 coverUri；空时用灰色占位）
            Stack {
                if (group.coverUri.size > 0) {
                    Image(group.coverUri)
                        .width(56)
                        .height(56)
                        .objectFit(ImageFit.Cover)
                        .borderRadius(8)
                } else {
                    Column {
                        Text(this.albumIcon(group.albumName))
                            .fontSize(24)
                            .fontColor(0x8E8E93)
                    }
                    .width(56)
                    .height(56)
                    .backgroundColor(0xF2F2F7)
                    .borderRadius(8)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                }
            }
            .width(56)
            .height(56)
            .margin(right: 12)

            // 相册名称和数量
            Column {
                Text(group.albumName)
                    .fontSize(16)
                    .fontColor(0x000000)
                    .fontWeight(FontWeight.Medium)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)

                Text(this.albumCountLabel(group))
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .margin(top: 4)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            // 右箭头
            Text(">")
                .fontSize(16)
                .fontColor(0xC7C7CC)
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 12, bottom: 12)
        .alignItems(VerticalAlign.Center)
        .onClick({ evt =>
            this.onTapAlbum(group.albumName, group.albumUri)
        })
    }

    private func onTapAlbum(albumName: String, albumUri: String) {
        Hilog.info(0, "CjTelegram", "[MediaGroupsScreen] tapped album: " + albumName)
        routerPush("MediaPickerScreen", albumUri)
    }

    /**
     * 系统相册使用文字图标，用户相册使用通用图标
     */
    private func albumIcon(albumName: String): String {
        if (albumName == "Camera Roll") {
            return "C"
        } else if (albumName == "Favorites") {
            return "*"
        } else if (albumName == "Videos") {
            return "V"
        }
        return "A"
    }

    /**
     * 相册计数标签
     */
    private func albumCountLabel(group: MediaAlbumGroup): String {
        if (group.imageCount > 0 || group.videoCount > 0) {
            if (group.videoCount == 0) {
                return group.imageCount.toString() + " photos"
            } else if (group.imageCount == 0) {
                return group.videoCount.toString() + " videos"
            }
            return group.imageCount.toString() + " photos, " + group.videoCount.toString() + " videos"
        }
        return group.totalCount.toString() + " items"
    }
}
