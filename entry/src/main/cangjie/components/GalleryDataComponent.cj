package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.arkui.state_management.*
import ohos.arkui.component.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.GalleryDataService
import ohos_app_cangjie_entry.services.GalleryDataEntry
import ohos_app_cangjie_entry.services.GalleryMediaKind
import ohos_app_cangjie_entry.services.getGalleryDataService
import ohos_app_cangjie_entry.services.galleryMediaKindLabel
import std.collection.ArrayList

// GalleryDataComponent — 画廊数据网格组件（P2-219 gallery_data_model fidelity）
//
// 职责：
//   - 接收 peerType / peerId 参数，在 aboutToAppear 调用 GalleryDataService 加载聚合数据
//   - 以 3 列网格（columnsTemplate: "1fr 1fr 1fr"）展示图片/视频缩略图
//   - 在每格右上角显示媒体分类标签（photo/video/gif/voice/audio/sticker/video_note/document）
//   - collage 相册条目右上角额外显示成员数徽章（如 "×3"）（Gap ②）
//   - onTapItem 回调传出选中条目，供父页面（如 SharedMediaPage）打开大图/视频播放器
//
// P2-219 变更：
//   - 改用 loadAndAggregateGalleryData（per-message 路由 + collage 聚合）
//   - 新增 collage 徽章显示（isCollage=true 时）
//   - mediaType 细分徽章（gif/voice/audio/sticker/video_note 全覆盖）
//
// ArkUI 规则全套：
//   - aboutToAppear 中 @State 写用 launch{}（S-001）
//   - build() / @Builder 方法体内不使用 let 声明（S-005 / R-107）
//   - @Builder 不修饰 private func（S-013）
@Component
public class GalleryDataComponent {

    // 对端类型（"user" / "group" / "channel"）
    public var peerType: String = "user"
    // 对端 ID
    public var peerId: Int64 = 0
    // 每类媒体最大加载条目数
    public var loadLimit: Int32 = 50
    // 点击条目回调，传出条目索引与 GalleryDataEntry
    public var onTapItem: (Int64, GalleryDataEntry) -> Unit = { _idx, _entry => }

    // 当前已聚合条目列表（@State 触发刷新）
    @State
    var entries: ArrayList<GalleryDataEntry> = ArrayList<GalleryDataEntry>()

    // 是否正在加载
    @State
    var isLoading: Bool = false

    // 是否加载出错
    @State
    var hasError: Bool = false

    // ─── 生命周期 ──────────────────────────────────────────────────────────────

    public override func aboutToAppear(): Unit {
        let _ = spawn {
            // S-001: @State 写在 launch{} 内（UI 线程）
            launch {
                this.isLoading = true
                this.hasError = false
            }
            let svc = getGalleryDataService()
            // Gap ①②: 使用 loadAndAggregateGalleryData（per-message 路由 + collage 聚合）
            let loaded = svc.loadAndAggregateGalleryData(this.peerType, this.peerId, limit: this.loadLimit)
            launch {
                // @State temp-var + 整变量重赋值（S-001 集合突变规则）
                let tmp = loaded
                this.entries = tmp
                this.isLoading = false
                if (svc.lastError.size > 0) {
                    this.hasError = true
                }
            }
        }
    }

    public override func aboutToDisappear(): Unit {
        getGalleryDataService().clearEntries()
    }

    // ─── 辅助方法（避免 let 写在 build 体内 —— S-005 / R-107）─────────────────

    // 返回指定索引条目的分类标签
    private func kindLabelAt(idx: Int64): String {
        let count = Int64(this.entries.size)
        if (idx < 0 || idx >= count) {
            return ""
        }
        return this.entries[idx].typeLabel
    }

    // 返回指定索引条目的本地路径（空串代表尚未下载）
    private func localPathAt(idx: Int64): String {
        let count = Int64(this.entries.size)
        if (idx < 0 || idx >= count) {
            return ""
        }
        return this.entries[idx].item.localPath
    }

    // 是否是 collage/相册（Gap ②）
    private func isCollageAt(idx: Int64): Bool {
        let count = Int64(this.entries.size)
        if (idx < 0 || idx >= count) {
            return false
        }
        return this.entries[idx].isCollage
    }

    // 相册成员数（Gap ②）
    private func collageCountAt(idx: Int64): Int64 {
        let count = Int64(this.entries.size)
        if (idx < 0 || idx >= count) {
            return 1
        }
        return this.entries[idx].collageCount()
    }

    // 当前条目总数（Int64）
    private func totalCount(): Int64 {
        return Int64(this.entries.size)
    }

    // ─── UI 构建 ───────────────────────────────────────────────────────────────

    func build() {
        Column() {
            if (this.isLoading) {
                Column() {
                    Text("加载中...")
                        .fontSize(14)
                        .fontColor(0xFF8E8E93)
                }
                .width(100.percent)
                .height(120)
                .justifyContent(FlexAlign.Center)
            } else if (this.hasError) {
                Column() {
                    Text("加载失败，请重试")
                        .fontSize(14)
                        .fontColor(0xFFFF3B30)
                }
                .width(100.percent)
                .height(120)
                .justifyContent(FlexAlign.Center)
            } else if (this.totalCount() == 0) {
                Column() {
                    Text("暂无媒体内容")
                        .fontSize(14)
                        .fontColor(0xFF8E8E93)
                }
                .width(100.percent)
                .height(120)
                .justifyContent(FlexAlign.Center)
            } else {
                Grid() {
                    ForEach(
                        Array<Int64>(this.entries.size, { i: Int64 => i }),
                        itemGeneratorFunc: {
                            idx: Int64, _i: Int64 =>
                                GridItem() {
                                    this.buildGridCell(idx)
                                }
                        }
                    )
                }
                .columnsTemplate("1fr 1fr 1fr")
                .columnsGap(2)
                .rowsGap(2)
                .width(100.percent)
            }
        }
        .width(100.percent)
    }

    @Builder
    func buildGridCell(idx: Int64) {
        Stack() {
            if (this.localPathAt(idx).size > 0) {
                Image("file://" + this.localPathAt(idx))
                    .width(100.percent)
                    .height(120)
                    .objectFit(ImageFit.Cover)
            } else {
                Column() {
                    Text(this.kindLabelAt(idx))
                        .fontSize(12)
                        .fontColor(0xFFFFFFFF)
                }
                .width(100.percent)
                .height(120)
                .backgroundColor(0xFF3A3A3C)
                .justifyContent(FlexAlign.Center)
            }
            // 右上角徽章行：类型标签 + 相册成员数
            Row() {
                // Gap ③: 媒体类型细分标签
                Text(this.kindLabelAt(idx))
                    .fontSize(10)
                    .fontColor(0xFFFFFFFF)
                    .backgroundColor(0x88000000)
                    .padding(3)
                    .borderRadius(4)
                // Gap ②: collage 徽章（仅 isCollage=true 时显示）
                if (this.isCollageAt(idx)) {
                    Text("×" + this.collageCountAt(idx).toString())
                        .fontSize(10)
                        .fontColor(0xFFFFFFFF)
                        .backgroundColor(0x88000000)
                        .padding(3)
                        .borderRadius(4)
                }
            }
            .width(100.percent)
            .justifyContent(FlexAlign.End)
        }
        .width(100.percent)
        .height(120)
        .onClick({
            _ =>
                if (idx >= 0 && idx < this.totalCount()) {
                    let entry = this.entries[idx]
                    this.onTapItem(idx, entry)
                    Hilog.info(0, "CjTelegram", "[GalleryDataComponent] tapped idx=${idx}")
                }
        })
    }
}
