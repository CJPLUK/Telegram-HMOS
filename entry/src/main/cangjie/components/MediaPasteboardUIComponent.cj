package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.PasteboardItem
import ohos_app_cangjie_entry.services.PasteboardItemWrapper
import ohos_app_cangjie_entry.services.getMediaPasteboardService
import ohos.resource.__GenerateResource__
import ohos.resource.AppResource

// MediaPasteboardUIComponent — 媒体粘贴板预览组件（media_pasteboard / MPAST-UI-1）
//
// iOS 对应：
//   submodules/MediaPasteboardUI/Sources/MediaPasteboardScreen.swift
//   — mediaPasteboardScreen() 工厂函数返回的 AttachmentController
//     展示剪贴板媒体条目（已粘贴的图像/视频），支持全选/取消，最终传给发送流程
//
// 功能：
//   - aboutToAppear 触发后台读取剪贴板媒体条目
//   - Grid 网格预览每个媒体条目（图像显示缩略路径，视频显示播放图标）
//   - 支持逐项切换选中/取消选中状态
//   - 底部操作栏：「全选」和「发送」按钮
//   - onConfirm 回调将选中条目传给调用方（ChatRoomPage）
//   - onCancel 回调关闭面板
//
// 调用链（完整）：
//   aboutToAppear()
//     → launch { getMediaPasteboardService().readPasteboardItems() }
//       → this.pasteItems = ...（@State 刷新）
//         → ForEach(wrapItems()) 渲染网格
//   GridItem.onClick()
//     → toggleSelection(idx)
//       → this.selectedIndices 更新 → UI 刷新
//   sendButton.onClick()
//     → collectSelected() → onConfirm(selected)
@Component
public class MediaPasteboardUIComponent {
    // 确认发送回调，传入选中的媒体条目列表
    public var onConfirm: (ArrayList<PasteboardItem>) -> Unit = { _items: ArrayList<PasteboardItem> => }
    // 取消/关闭回调
    public var onCancel: () -> Unit = { => }

    @State
    var pasteItems: ArrayList<PasteboardItem> = ArrayList<PasteboardItem>()
    @State
    var selectedIndices: ArrayList<Int64> = ArrayList<Int64>()
    @State
    var isLoading: Bool = true
    @State
    var hasNoItems: Bool = false

    public override func aboutToAppear(): Unit {
        let _ = spawn {
            let svc = getMediaPasteboardService()
            let items = svc.readPasteboardItems()
            launch {
                this.pasteItems = items
                this.isLoading = false
                this.hasNoItems = items.size == 0
                if (items.size > 0) {
                    var i: Int64 = 0
                    while (i < items.size) {
                        this.selectedIndices.add(i)
                        i += 1
                    }
                }
            }
        }
    }

    public func build() {
        Column {
            buildDragHandle()
            buildHeader()
            if (this.isLoading) {
                buildLoadingView()
            } else if (this.hasNoItems) {
                buildEmptyView()
            } else {
                buildItemGrid()
            }
            buildBottomBar()
        }
        .width(100.percent)
        .backgroundColor(0xF2F2F7)
        .borderRadius(16)
    }

    @Builder
    func buildDragHandle() {
        Row {
            Column {}
                .width(36)
                .height(4)
                .backgroundColor(0xD1D1D6)
                .borderRadius(2)
        }
        .width(100.percent)
        .justifyContent(FlexAlign.Center)
        .padding(top: 8, bottom: 8)
    }

    @Builder
    func buildHeader() {
        Row {
            Text("粘贴板媒体")
                .fontSize(17)
                .fontColor(0xFF000000)
                .fontWeight(FontWeight.Bold)
        }
        .width(100.percent)
        .justifyContent(FlexAlign.Center)
        .padding(top: 4, bottom: 12)
    }

    @Builder
    func buildLoadingView() {
        Column {
            LoadingProgress()
                .width(40)
                .height(40)
                .color(0xFF007AFF)
            Text("正在读取剪贴板...")
                .fontSize(14)
                .fontColor(0xFF8E8E93)
                .margin(top: 8)
        }
        .width(100.percent)
        .height(200)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    func buildEmptyView() {
        Column {
            Text("📋")
                .fontSize(48)
            Text("剪贴板中没有图片或视频")
                .fontSize(15)
                .fontColor(0xFF8E8E93)
                .margin(top: 12)
        }
        .width(100.percent)
        .height(200)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    func buildItemGrid() {
        Grid {
            ForEach(wrapItems(), itemGenerator: { wrapper: PasteboardItemWrapper, _idx: Int64 =>
                GridItem {
                    buildMediaCell(wrapper.item, wrapper.idx)
                }
            })
        }
        .columnsTemplate("1fr 1fr 1fr")
        .columnsGap(2)
        .rowsGap(2)
        .width(100.percent)
        .height(300)
        .padding(left: 8, right: 8, top: 4, bottom: 4)
    }

    @Builder
    func buildMediaCell(item: PasteboardItem, idx: Int64) {
        Stack {
            if (item.mediaKind == "image" && item.uri.size > 0) {
                Image(item.uri)
                    .width(100.percent)
                    .height(100.percent)
                    .objectFit(ImageFit.Cover)
                    .borderRadius(8)
            } else if (item.mediaKind == "video") {
                // 资源保真修复：Media Gallery/PlayButton.imageset/ic_play.pdf 转 SVG
                Column {
                    Image(@r(app.media.media_ic_play))
                        .width(32)
                        .height(32)
                        .fillColor(0xFFFFFFFF)
                }
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0xFF2C2C2E)
                .borderRadius(8)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                // 资源保真修复：Chat/Attach Menu/File.imageset/Type=Default-2.pdf 转 SVG
                Column {
                    Image(@r(app.media.media_ic_attach_file))
                        .width(32)
                        .height(32)
                        .fillColor(0xFF8E8E93)
                }
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0xFFE5E5EA)
                .borderRadius(8)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            }
            if (isIndexSelected(idx)) {
                // 资源保真修复：Media Gallery/Check.imageset/checkattach_30.pdf 转 SVG
                Column {
                    Column {
                        Image(@r(app.media.media_ic_check))
                            .width(14)
                            .height(14)
                            .fillColor(0xFFFFFFFF)
                    }
                    .width(24)
                    .height(24)
                    .backgroundColor(0xFF007AFF)
                    .borderRadius(12)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                }
                .width(100.percent)
                .height(100.percent)
                .alignItems(HorizontalAlign.End)
                .justifyContent(FlexAlign.Start)
                .padding(top: 4, right: 4)
            }
        }
        .width(100.percent)
        .height(110)
        .onClick({ _evt =>
            this.toggleSelection(idx)
        })
    }

    @Builder
    func buildBottomBar() {
        Row {
            Button("全选")
                .fontSize(15)
                .fontColor(0xFF007AFF)
                .backgroundColor(0xFFFFFFFF)
                .borderRadius(8)
                .padding(left: 16, right: 16, top: 8, bottom: 8)
                .onClick({ _evt =>
                    this.selectAll()
                })
            Blank()
            Button("发送 " + selectedCountLabel())
                .fontSize(15)
                .fontColor(0xFFFFFFFF)
                .backgroundColor(if (this.selectedIndices.size == 0) { 0xFFAAAAAA } else { 0xFF007AFF })
                .borderRadius(8)
                .padding(left: 16, right: 16, top: 8, bottom: 8)
                .onClick({ _evt =>
                    if (this.selectedIndices.size > 0) {
                        let selected = this.collectSelected()
                        this.onConfirm(selected)
                    }
                })
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 12, bottom: 20)
        .backgroundColor(0xFFFFFFFF)
    }

    // ── 私有辅助方法 ──────────────────────────────────────────────────

    private func wrapItems(): ArrayList<PasteboardItemWrapper> {
        let wrapped = ArrayList<PasteboardItemWrapper>()
        var i: Int64 = 0
        for (item in this.pasteItems) {
            let w = PasteboardItemWrapper()
            w.item = item
            w.idx = i
            wrapped.add(w)
            i += 1
        }
        return wrapped
    }

    private func isIndexSelected(idx: Int64): Bool {
        for (si in this.selectedIndices) {
            if (si == idx) {
                return true
            }
        }
        return false
    }

    private func toggleSelection(idx: Int64): Unit {
        let newList = ArrayList<Int64>()
        var found = false
        for (si in this.selectedIndices) {
            if (si == idx) {
                found = true
            } else {
                newList.add(si)
            }
        }
        if (!found) {
            newList.add(idx)
        }
        this.selectedIndices = newList
    }

    private func selectAll(): Unit {
        let newList = ArrayList<Int64>()
        var i: Int64 = 0
        while (i < this.pasteItems.size) {
            newList.add(i)
            i += 1
        }
        this.selectedIndices = newList
    }

    private func collectSelected(): ArrayList<PasteboardItem> {
        let result = ArrayList<PasteboardItem>()
        var i: Int64 = 0
        for (item in this.pasteItems) {
            if (isIndexSelected(i)) {
                result.add(item)
            }
            i += 1
        }
        return result
    }

    private func selectedCountLabel(): String {
        let cnt = this.selectedIndices.size
        if (cnt == 0) {
            return ""
        }
        return "(" + cnt.toString() + ")"
    }
}
