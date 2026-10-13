package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import std.collection.ArrayList

/**
 * PeerInfoAvatarListComponent — 资料页头像轮播组件
 *
 * 对应 iOS PeerInfoAvatarListNode
 *
 * 功能:
 * - 顶部分段进度条：每段对应一张头像，当前头像对应段高亮
 * - Swiper 左右滑动多张头像（photos.getUserPhotos 拉取）
 * - 头像不存在时显示文字缩写圆形占位符
 * - aboutToAppear 时异步加载头像列表
 *
 * 调用链:
 * PeerInfoAvatarListComponent.aboutToAppear()
 *   → spawn → PeerInfoAvatarListService.fetchUserPhotos()
 *     → MTProtoClient.sendRequest(photos.getUserPhotos)
 *     → FileDownloadService.downloadUserPhoto()
 *   → photos Array<String> → Swiper renders
 *
 * S-64: public override func aboutToAppear(): Unit { let _ = spawn { ... } }
 */
@Component
public class PeerInfoAvatarListComponent {
    // Caller must set: user ID
    var peerId: Int64 = 0
    // Caller must set: user access_hash (needed for MTProto call)
    var accessHash: Int64 = 0
    // Fallback avatar text (first letter of name)
    var avatarText: String = "?"
    // Size of the avatar display area (vp)
    var avatarSize: Int64 = 320

    // Internal state — no access modifiers with @State (syntax_error)
    @State var photos: Array<String> = []
    @State var currentIndex: Int64 = 0
    @State var isLoading: Bool = true

    private let swiperController = SwiperController()

    public override func aboutToAppear(): Unit {
        let peerIdCopy = this.peerId
        let accessHashCopy = this.accessHash
        let _ = spawn {
            let service = getPeerInfoAvatarListService()
            let photoList = service.fetchUserPhotos(peerIdCopy, accessHashCopy, limit: 10)
            let arr = Array<String>(photoList.size, { i: Int64 => photoList[i] })
            launch {
                this.photos = arr
                this.isLoading = false
                Hilog.info(0, "CjTelegram", "[PeerInfoAvatarListComp] loaded ${arr.size} photos uid=${peerIdCopy}")
            }
        }
    }

    // Returns total slide count (at least 1 for fallback)
    private func getSlideCount(): Int64 {
        if (this.photos.size > 0) {
            return Int64(this.photos.size)
        }
        return 1
    }

    // Returns whether there are multiple slides to show the progress bar
    private func hasMultipleSlides(): Bool {
        return this.getSlideCount() > 1
    }

    // Returns the cached strippedThumb path for loading state
    private func getCachedAvatarPath(): String {
        return getUserPhotoService().getUserPhotoPath(this.peerId)
    }

    // Returns fontSize based on avatarSize
    private func getAvatarFontSize(): Int64 {
        return this.avatarSize / 4
    }

    // Build the segmented progress bar at the top
    @Builder
    private func buildProgressBar() {
        Row {
            ForEach(Array<Int64>(this.getSlideCount(), { i: Int64 => i }),
                itemGenerator: { idx: Int64, _: Int64 =>
                    Column {}
                        .layoutWeight(1)
                        .height(3)
                        .backgroundColor(if (idx == this.currentIndex) { 0xFFFFFF } else { 0x80FFFFFF })
                        .borderRadius(1)
                        .margin(left: 2, right: 2)
                })
        }
        .width(100.percent)
        .padding(top: 8, left: 8, right: 8)
        .justifyContent(FlexAlign.Start)
        .alignItems(VerticalAlign.Center)
    }

    // 构建加载中视图（strippedThumb 缓存图或文字缩写兜底）
    @Builder
    private func buildLoadingView() {
        if (this.getCachedAvatarPath().size > 0) {
            Image(this.getCachedAvatarPath())
                .width(100.percent)
                .height(100.percent)
                .objectFit(ImageFit.Cover)
        } else {
            Text(this.avatarText)
                .fontSize(this.getAvatarFontSize())
                .fontColor(0xFFFFFF)
                .width(100.percent)
                .height(100.percent)
                .textAlign(TextAlign.Center)
                .backgroundColor(0x317AFF)
        }
    }

    // Build text fallback slide (no photos loaded)
    @Builder
    private func buildFallbackSlide() {
        Stack {
            Text(this.avatarText)
                .fontSize(this.getAvatarFontSize())
                .fontColor(0xFFFFFF)
                .textAlign(TextAlign.Center)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x317AFF)
    }

    public func build() {
        Stack {
            if (this.isLoading) {
                this.buildLoadingView()
            } else {
                Column {
                    Swiper(controller: this.swiperController) {
                        if (this.photos.size > 0) {
                            ForEach(this.photos,
                                itemGenerator: { photoUrl: String, _: Int64 =>
                                    Image(photoUrl)
                                        .width(100.percent)
                                        .height(100.percent)
                                        .objectFit(ImageFit.Cover)
                                })
                        } else {
                            this.buildFallbackSlide()
                        }
                    }
                    .width(100.percent)
                    .height(100.percent)
                    .loop(false)
                    .indicator(false)
                    .index(UInt32(this.currentIndex))
                    .onChange({ index: Int32 =>
                        this.currentIndex = Int64(index)
                    })
                }
                .width(100.percent)
                .height(100.percent)
            }

            // Segmented progress bar overlay (only shown when >1 photo)
            if (this.hasMultipleSlides()) {
                Column {
                    this.buildProgressBar()
                }
                .width(100.percent)
                .alignItems(HorizontalAlign.Start)
            }
        }
        .width(this.avatarSize)
        .height(this.avatarSize)
        .borderRadius(this.avatarSize / 2)
        .clip(true)
    }
}
