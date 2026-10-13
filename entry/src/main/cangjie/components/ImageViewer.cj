package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.sync.*
import std.math.sqrt
import kit.MediaLibraryKit.*
import kit.ArkData.{Preferences, PreferencesValueType}
import ohos.callback_invoke.*
import ohos.business_exception.BusinessException
import ohos_app_cangjie_entry.services.getGlobalAbilityContext
import ohos_app_cangjie_entry.services.getSaveToCameraRollService
import ohos_app_cangjie_entry.interop.*
import ohos.resource.__GenerateResource__
import ohos.resource.AppResource

/**
 * ImageViewer — 全屏图片查看器（Phase H2 + P2-194/195/198/199）
 *
 * 对应 TelegramHarmony ImageViewer.ets (255 行)
 * 对应 Telegram-iOS GalleryController (全屏媒体查看器)
 *
 * 功能:
 * - 全屏黑色背景查看图片
 * - Swiper 支持多图滑动浏览
 * - P2-194: 捏合缩放（onTouch 双指距离追踪 + .scale(x:y:)）+ 双击切换 1.0↔2.0 + 缩放后平移
 * - P2-195: 下拉关闭手势（单指向下拖动渐透明+缩小，超阈值关闭，未超回弹）
 * - P2-198: 单击切换顶/底 chrome（toolbar）显隐 + 3 秒无操作自动隐藏
 * - P2-199: 底部 caption 文字（来自 ImageItem.caption），长 caption 可滚动
 * - TC-0023/TC-0024 返修：顶部工具栏（关闭、标题[发送者/时间或图片计数]、更多）；
 *   底部工具栏（分享、保存、编辑、删除）；关闭按钮命中区放大到 48x48
 * - 图片说明文字
 * - 保存到系统相册（TC-0024 rework2：photoAccessHelper.showAssetsCreationDialog 用户确认弹窗，
 *   免 WRITE_IMAGEVIDEO 常驻权限声明，见 saveCurrentImage() 文档注释）
 *
 * fallback 说明（P2-194）:
 *   Cangjie SDK 6.0 kit.ArkUI.* 未导出 PinchGesture 命名类型。
 *   使用 onTouch TouchEvent.touches 双指欧氏距离差实现等效捏合缩放。
 *   参照 AvatarGalleryPage.cj 已验证的同一方案。
 *
 * TC-0024 rework1 返修（P0，本文件专属）:
 *   诊断（diag-suite_chat_core_messaging-TC-0024-rework1.md）确认 Save 按钮渲染正确但 11 次
 *   点击零响应——build() 顶层 Stack 内，全屏图片区域（buildImageArea 产出的 Image/Swiper，
 *   自带 onClick/onTouch）与底部工具栏（.position(y:75%)）空间重叠，实测命中测试未按声明顺序
 *   把优先级让给后声明的工具栏。修复：显式 .zIndex(...) 声明层叠优先级（对齐 CallScreen.cj
 *   等既有全屏 Stack 覆盖层惯例）——图片区域 zIndex(0)，顶/底工具栏 zIndex(100)，
 *   确保工具栏始终在图片层之上参与命中测试，不再依赖隐式声明顺序假设。
 */

/**
 * 图片数据项
 */
public class ImageItem {
    public var url: String = ""
    public var width: Int32 = 0
    public var height: Int32 = 0
    public var caption: String = ""
    public var photoId: Int64 = 0
    // imgmenu 批次：所属消息 id（转发/删除按钮需要定位原始消息；0 = 无消息上下文，
    // 此时 Forward/Delete 操作不可用）。由 ChatRoomPage.openImageViewer 填充。
    public var msgId: Int64 = 0
    // 顶部标题栏用：发送者名 + 时间（对应 iOS GalleryController 导航标题 "sender / time"）
    // 由调用方（如 ChatRoomPage.openImageViewer）可选填充；未填充时标题栏不显示发送者行。
    public var senderName: String = ""
    public var timeText: String = ""

    public init() {}

    public init(url!: String, photoId!: Int64 = 0, caption!: String = "", senderName!: String = "", timeText!: String = "", msgId!: Int64 = 0) {
        this.url = url
        this.photoId = photoId
        this.caption = caption
        this.senderName = senderName
        this.timeText = timeText
        this.msgId = msgId
    }
}

@Component
public class ImageViewer {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 图片列表
    public var images: ArrayList<ImageItem> = ArrayList<ImageItem>()
    // 初始显示索引
    public var initialIndex: Int64 = 0
    // 关闭回调
    public var onClose: () -> Unit = { => }
    // imgmenu 批次：转发/删除请求回调（参数 = 当前图片所属消息 id）。
    // 转发/删除涉及消息级业务（forward picker / messages.deleteMessages），由宿主页
    // （ChatRoomPage）承接；查看器只上报意图。未注入时按钮点击为 no-op（msgId==0 时按钮隐藏）。
    public var onForwardRequest: (Int64) -> Unit = { _msgId: Int64 => }
    public var onDeleteRequest: (Int64) -> Unit = { _msgId: Int64 => }

    // 当前显示索引
    @State var displayIndex: Int64 = 0
    // imgmenu 批次：顶部"更多"下拉菜单显隐（自绘 overlay；本工程无 bindMenu 已验证先例，
    // 用条件渲染 + zIndex 顶层 Stack 子项实现，同 chrome 工具栏惯例）
    @State var showMoreMenu: Bool = false
    // P2-194 缩放状态
    @State var zoomScale: Float32 = Float32(1.0)
    // P2-194 平移偏移（dp）
    @State var offsetX: Float64 = 0.0
    @State var offsetY: Float64 = 0.0
    // P2-195 下拉关闭进度（0.0~1.0）
    @State var dismissProgress: Float64 = 0.0
    // P2-198 是否显示 chrome（顶/底工具栏）
    @State var showControls: Bool = true
    // 保存状态提示
    @State var saveStatus: String = ""
    // Swiper 控制器
    private let swiperController = SwiperController()

    // ─── P2-194 手势追踪（不驱动 UI，不加 @State）───────────────────────────────
    // 双指距离追踪
    private var lastPinchDist: Float64 = 0.0
    // 平移起始触点
    private var panStartX: Float64 = 0.0
    private var panStartY: Float64 = 0.0
    private var panBaseOffsetX: Float64 = 0.0
    private var panBaseOffsetY: Float64 = 0.0
    private var isPanning: Bool = false
    // 双击计数
    private var tapCount: Int32 = 0

    // ─── P2-195 下拉手势追踪 ────────────────────────────────────────────────────
    private var isDismissGesture: Bool = false
    // 关闭阈值（dp）
    private let DISMISS_THRESHOLD: Float64 = 200.0

    // ─── P2-198 自动隐藏 chrome 计时器版本 ───────────────────────────────────────
    private var chromeTimerVersion: Int32 = 0

    // S7-117: Appearance → "Show Next Media on Tap"（iOS MediaDisplaySettings.showNextMediaOnTap，
    // 默认 true；GalleryController.swift:1548 以 disableTapNavigation 传入 GalleryPagerNode）。
    // 开启时单击左/右边缘（宽 min(44, width/6)，GalleryPagerNode.swift:7-9,366-372）切到上一张/下一张。
    private var tapNavigationEnabled: Bool = true
    private var viewerWidth: Float64 = 0.0
    private var tapDownX: Float64 = -1.0

    protected override func aboutToAppear(): Unit {
        this.displayIndex = this.initialIndex
        this.tapNavigationEnabled = loadShowNextMediaOnTapPref()
        // P2-198: 打开时 3 秒后自动隐藏 chrome
        this.scheduleChromeFade()
    }

    public func build() {
        Stack {
            // 背景：P2-195 下拉时渐透明
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0x000000)
                .opacity(1.0 - this.dismissProgress * 0.8)

            // 图片区域（含缩放+平移+下拉动效）
            // opacity 和 translate 放在外层 Stack 上
            // TC-0024 rework2 返修：显式 zIndex(0)（对齐 CallScreen.cj 全屏 Stack 覆盖层惯例，
            // 见 D-136），确保该层始终位于顶/底工具栏（zIndex 100）之下参与命中测试排序，
            // 不依赖 Stack 子项声明顺序的隐式层叠假设（根因：diag-...-TC-0024-rework1.md 证实
            // 声明顺序更晚的工具栏未能获得预期的命中测试优先级）。
            Stack {
                this.buildImageArea()
            }
            .width(100.percent)
            .height(100.percent)
            .opacity(1.0 - this.dismissProgress * 0.6)
            .translate(x: 0.0, y: this.dismissProgress * this.DISMISS_THRESHOLD)
            .zIndex(0)

            // ==================== P2-198 顶部控制栏 ====================
            // 对齐 iOS GalleryController 导航栏：关闭 + 标题(发送者/时间或计数) + 更多按钮
            if (this.showControls) {
                Row {
                    // 关闭按钮（资源保真修复：Navigation/Close.imageset/headercross_30.pdf 转 SVG）
                    // 命中区放大到 48x48（iOS 44pt 触摸目标惯例 + 余量），图标本身保持 20x20 视觉大小不变
                    Column {
                        Image(@r(app.media.media_ic_close))
                            .width(20)
                            .height(20)
                            .fillColor(0xFFFFFF)
                    }
                    .width(48)
                    .height(48)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .backgroundColor(0x80000000)
                    .borderRadius(24)
                    .onClick({ evt =>
                        this.onClose()
                    })

                    // 标题区域：优先显示 "发送者 / 时间"（对应 iOS "You / today at 23:26"），
                    // 无发送者数据时回退为图片计数
                    Column {
                        if (this.getCurrentSenderName().size > 0) {
                            Text(this.getCurrentSenderName())
                                .fontSize(16)
                                .fontColor(0xFFFFFF)
                                .fontWeight(FontWeight.Medium)
                            if (this.getCurrentTimeText().size > 0) {
                                Text(this.getCurrentTimeText())
                                    .fontSize(12)
                                    .fontColor(0xB3FFFFFF)
                                    .margin(top: 2)
                            }
                        } else if (this.images.size > 1) {
                            Text("${this.displayIndex + 1} / ${this.images.size}")
                                .fontSize(16)
                                .fontColor(0xFFFFFF)
                        }
                    }
                    .alignItems(HorizontalAlign.Center)
                    .margin(left: 12)

                    Blank()

                    // 更多按钮（资源保真修复：Chat List/NavigationMore.imageset/more_30.pdf 转 SVG）
                    // 对应 iOS 导航栏右上角 "..." 更多操作入口（GalleryController rightBarButton），
                    // imgmenu 批次接真：点击展开自绘下拉菜单（Forward / Save to Gallery / Share / Delete，
                    // 对齐 iOS 图片查看器 "..." context menu 动作子集）
                    Column {
                        Image(@r(app.media.media_ic_more))
                            .width(20)
                            .height(20)
                            .fillColor(0xFFFFFF)
                    }
                    .width(48)
                    .height(48)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .backgroundColor(0x80000000)
                    .borderRadius(24)
                    .onClick({ evt =>
                        this.showMoreMenu = !this.showMoreMenu
                        // 菜单展开期间不要让 chrome 自动隐藏收走菜单锚点
                        if (this.showMoreMenu) {
                            this.scheduleChromeFade()
                        }
                    })
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 48)
                .position(x: 0, y: 0)
                .zIndex(100)
            }

            // ==================== imgmenu：顶部"更多"下拉菜单 ====================
            // 对应 iOS GalleryController 右上角 "..." 弹出的 context menu（Forward /
            // Save to Gallery / Share / Delete 动作子集）。自绘 overlay（本工程无 bindMenu
            // 已验证先例），锚定在更多按钮下方，zIndex 高于顶栏保证命中。
            if (this.showControls && this.showMoreMenu) {
                Row {
                    Blank()
                    this.buildMoreMenu()
                }
                .width(100.percent)
                .padding(right: 16)
                .position(x: 0, y: 104)
                .zIndex(120)
            }

            // ==================== P2-198/199 底部控制栏 ====================
            if (this.showControls) {
                Column {
                    // P2-199: Caption 展示（真实 ImageItem.caption 数据）
                    if (this.getCurrentCaption().size > 0) {
                        Scroll() {
                            Text(this.getCurrentCaption())
                                .fontSize(14)
                                .fontColor(0xFFFFFF)
                                .padding(left: 16, right: 16, top: 4, bottom: 4)
                                .width(100.percent)
                        }
                        .scrollable(ScrollDirection.Vertical)
                        .scrollBar(BarState.Auto)
                        .height(80)
                        .width(100.percent)
                        .backgroundColor(0x60000000)
                    }

                    // 操作按钮
                    Row {
                        // 分享按钮（资源保真修复：Chat/Context Menu/Share.imageset/ic_lt_share.pdf 转 SVG）
                        Column {
                            Image(@r(app.media.media_ic_share))
                                .width(22)
                                .height(22)
                                .fillColor(0xFFFFFF)
                            Text(trSource("Share"))
                                .fontSize(12)
                                .fontColor(0xFFFFFF)
                                .margin(top: 4)
                        }
                        .padding(left: 20, right: 20, top: 12, bottom: 12)
                        .backgroundColor(0x80000000)
                        .borderRadius(12)
                        .alignItems(HorizontalAlign.Center)
                        .onClick({ evt =>
                            this.shareCurrentImage()
                        })

                        // 保存按钮（资源保真修复：Chat/Context Menu/Save.imageset/ic_lt_save.pdf 转 SVG）
                        Column {
                            Image(@r(app.media.media_ic_save))
                                .width(22)
                                .height(22)
                                .fillColor(0xFFFFFF)
                            Text(trSource("Save"))
                                .fontSize(12)
                                .fontColor(0xFFFFFF)
                                .margin(top: 4)
                        }
                        .padding(left: 20, right: 20, top: 12, bottom: 12)
                        .backgroundColor(0x80000000)
                        .borderRadius(12)
                        .alignItems(HorizontalAlign.Center)
                        .margin(left: 24)
                        .onClick({ evt =>
                            this.saveCurrentImage()
                        })

                        // 转发按钮（imgmenu 批次；iOS 图片查看器把 Forward 放在右上 "..." 菜单，
                        // 本实现底栏与 "..." 菜单同时提供，接 ChatRoomPage 既有 forward picker →
                        // messages.forwardMessages 真实链路）。
                        // N/A 说明：原位为 Edit（iOS footer editButton 打开完整照片编辑器
                        // PhotoEditorScreen——裁剪/涂鸦/贴纸），本工程未实现照片编辑器，占位
                        // stub 按钮按"诚实原则"移除，不再展示（见 imgmenu 批次报告）。
                        if (this.getCurrentMsgId() != 0) {
                            Column {
                                Image(@r(app.media.chatroom_ic_forward))
                                    .width(22)
                                    .height(22)
                                    .fillColor(0xFFFFFF)
                                Text(trSource("Forward"))
                                    .fontSize(12)
                                    .fontColor(0xFFFFFF)
                                    .margin(top: 4)
                            }
                            .padding(left: 20, right: 20, top: 12, bottom: 12)
                            .backgroundColor(0x80000000)
                            .borderRadius(12)
                            .alignItems(HorizontalAlign.Center)
                            .margin(left: 24)
                            .onClick({ evt =>
                                this.forwardCurrentImage()
                            })
                        }

                        // 删除按钮（复用已有 clist_ic_delete 矢量资源，对齐 iOS footer deleteButton；
                        // imgmenu 批次接真：上报宿主页 onDeleteRequest → 确认弹窗 →
                        // messages.deleteMessages。无消息上下文（msgId==0）时隐藏。）
                        if (this.getCurrentMsgId() != 0) {
                            Column {
                                Image(@r(app.media.clist_ic_delete))
                                    .width(22)
                                    .height(22)
                                    .fillColor(0xFFFFFF)
                                Text(trSource("Delete"))
                                    .fontSize(12)
                                    .fontColor(0xFFFFFF)
                                    .margin(top: 4)
                            }
                            .padding(left: 20, right: 20, top: 12, bottom: 12)
                            .backgroundColor(0x80000000)
                            .borderRadius(12)
                            .alignItems(HorizontalAlign.Center)
                            .margin(left: 24)
                            .onClick({ evt =>
                                this.deleteCurrentImage()
                            })
                        }
                    }
                    .width(100.percent)
                    .justifyContent(FlexAlign.Center)
                }
                .width(100.percent)
                .padding(bottom: 48)
                .position(x: 0, y: 75.percent)
                .zIndex(100)
            }

            // 保存状态提示
            if (this.saveStatus.size > 0) {
                Text(this.saveStatus)
                    .fontSize(14)
                    .fontColor(0xFFFFFF)
                    .padding(left: 16, right: 16, top: 8, bottom: 8)
                    .backgroundColor(0x99000000)
                    .borderRadius(8)
                    .position(x: 35.percent, y: 45.percent)
            }

            // 底部指示点（多图时显示）
            if (this.showControls && this.images.size > 1) {
                Row {
                    ForEach(this.images.toArray(), itemGenerator: { _img: ImageItem, idx: Int64 =>
                        Column {}
                            .width(if (idx == this.displayIndex) { 16 } else { 8 })
                            .height(8)
                            .backgroundColor(if (idx == this.displayIndex) { 0xFFFFFF } else { 0x80FFFFFF })
                            .borderRadius(4)
                            .margin(left: if (idx > 0) { 6 } else { 0 })
                    })
                }
                .position(x: 0, y: 92.percent)
                .width(100.percent)
                .justifyContent(FlexAlign.Center)
            }
        }
        .width(100.percent)
        .height(100.percent)
    }

    // ─── 图片区域（含 Swiper + 手势）────────────────────────────────────────────

    @Builder func buildImageArea(): Unit {
        if (this.images.size == 1) {
            // 单图模式
            Image(this.images[0].url)
                .width(100.percent)
                .height(100.percent)
                .objectFit(ImageFit.Contain)
                .scale(x: this.zoomScale, y: this.zoomScale)
                .translate(x: this.offsetX, y: this.offsetY)
                .onTouch({ event =>
                    this.handleTouch(event)
                })
                .onClick({ evt =>
                    this.handleTap()
                })
        } else {
            // 多图模式 — 使用 Swiper
            Swiper(controller: this.swiperController) {
                ForEach(this.images.toArray(), itemGenerator: { imageItem: ImageItem, index: Int64 =>
                    Stack {
                        Image(imageItem.url)
                            .width(100.percent)
                            .height(100.percent)
                            .objectFit(ImageFit.Contain)
                            .scale(x: this.zoomScale, y: this.zoomScale)
                            .translate(x: this.offsetX, y: this.offsetY)
                    }
                    .width(100.percent)
                    .height(100.percent)
                    .onTouch({ event =>
                        this.handleTouch(event)
                    })
                    .onClick({ evt =>
                        this.handleTap()
                    })
                })
            }
            .index(UInt32(this.initialIndex))
            .indicator(false)
            .loop(false)
            .onAreaChange({ _: Area, newArea: Area =>
                this.viewerWidth = newArea.width.value
            })
            .onChange({ index: Int32 =>
                this.displayIndex = Int64(index)
                // 切图重置缩放/平移/下拉状态
                this.zoomScale = Float32(1.0)
                this.offsetX = 0.0
                this.offsetY = 0.0
                this.dismissProgress = 0.0
                this.lastPinchDist = 0.0
                this.tapCount = 0
                // P2-198: 切图时重置 chrome 并重置自动隐藏计时；imgmenu：收起更多菜单
                this.showControls = true
                this.showMoreMenu = false
                this.scheduleChromeFade()
            })
            .width(100.percent)
            .height(100.percent)
        }
    }

    // ─── P2-194/195 手势处理 ──────────────────────────────────────────────────────

    /**
     * 统一 onTouch 手势处理器
     * 双指 → 捏合缩放（P2-194）
     * 单指 + 已缩放 → 平移（P2-194）
     * 单指 + 未缩放 + 向下 → 下拉关闭（P2-195）
     *
     * onTouch 在 UI 线程，直接写 @State 合规（S-001）。
     */
    private func handleTouch(event: TouchEvent): Unit {
        let touchCount = event.touches.size

        if (touchCount >= 2) {
            // ── 双指捏合缩放（P2-194）──
            this.isDismissGesture = false
            // 下拉关闭中被第二指打断 → 复位 dismissProgress，否则图片卡在半透明+下移
            // （opacity/translate 由 dismissProgress 驱动）(audit P2-7)
            this.dismissProgress = 0.0
            this.isPanning = false
            let t0 = event.touches[0]
            let t1 = event.touches[1]
            let dx = t1.x - t0.x
            let dy = t1.y - t0.y
            let dist = sqrt(dx * dx + dy * dy)
            if (dist < 1.0) { return }

            if (event.eventType == TouchType.Down) {
                this.lastPinchDist = dist
                return
            }

            if (this.lastPinchDist > 1.0 && event.eventType == TouchType.Move) {
                let ratio = Float32(dist / this.lastPinchDist)
                let newScale = this.zoomScale * ratio
                if (newScale < Float32(0.8)) {
                    this.zoomScale = Float32(0.8)
                } else if (newScale > Float32(5.0)) {
                    this.zoomScale = Float32(5.0)
                } else {
                    this.zoomScale = newScale
                }
            }
            this.lastPinchDist = dist

            if (event.eventType == TouchType.Up || event.eventType == TouchType.Cancel) {
                this.lastPinchDist = 0.0
                if (this.zoomScale < Float32(1.0)) {
                    this.zoomScale = Float32(1.0)
                    this.offsetX = 0.0
                    this.offsetY = 0.0
                }
            }
            return
        }

        // ── 单指 ──
        if (touchCount == 1) {
            let t0 = event.touches[0]

            if (event.eventType == TouchType.Down) {
                this.tapDownX = t0.x
                this.panStartX = t0.x
                this.panStartY = t0.y
                this.panBaseOffsetX = this.offsetX
                this.panBaseOffsetY = this.offsetY
                this.isDismissGesture = false
                this.isPanning = false
                this.lastPinchDist = 0.0
                return
            }

            if (event.eventType == TouchType.Move) {
                let deltaX = t0.x - this.panStartX
                let deltaY = t0.y - this.panStartY

                if (Float64(this.zoomScale) > 1.05) {
                    // 已缩放：平移（P2-194）
                    this.isPanning = true
                    this.isDismissGesture = false
                    this.offsetX = this.panBaseOffsetX + deltaX
                    this.offsetY = this.panBaseOffsetY + deltaY
                } else {
                    // 未缩放：检测下拉（P2-195）
                    if (!this.isPanning && deltaY > 10.0 && !this.isDismissGesture) {
                        this.isDismissGesture = true
                    }
                    if (this.isDismissGesture && deltaY >= 0.0) {
                        let progress = deltaY / this.DISMISS_THRESHOLD
                        if (progress > 1.0) {
                            this.dismissProgress = 1.0
                        } else {
                            this.dismissProgress = progress
                        }
                    }
                }
                return
            }

            if (event.eventType == TouchType.Up || event.eventType == TouchType.Cancel) {
                if (this.isDismissGesture) {
                    if (this.dismissProgress >= 1.0) {
                        // 超阈值：关闭（P2-195）
                        this.dismissProgress = 0.0
                        this.isDismissGesture = false
                        this.onClose()
                    } else {
                        // 未超阈值：回弹（P2-195）
                        this.dismissProgress = 0.0
                        this.isDismissGesture = false
                    }
                } else if (this.isPanning) {
                    this.clampOffset()
                }
                this.isPanning = false
                return
            }
        }

        if (event.eventType == TouchType.Up || event.eventType == TouchType.Cancel) {
            this.lastPinchDist = 0.0
            this.isPanning = false
            if (!this.isDismissGesture) {
                this.dismissProgress = 0.0
            }
        }
    }

    /**
     * P2-194 + P2-198 点击处理
     * 连续 2 次 onClick → 双击：切换缩放 1.0↔2.0
     * 单次点击（300ms 后）→ 切换 chrome 显隐
     */
    private func handleTap(): Unit {
        this.tapCount = this.tapCount + 1
        if (this.tapCount >= 2) {
            this.tapCount = 0
            if (this.zoomScale > Float32(1.2)) {
                // 还原
                this.zoomScale = Float32(1.0)
                this.offsetX = 0.0
                this.offsetY = 0.0
            } else {
                // 放大到 2.0
                this.zoomScale = Float32(2.0)
            }
        } else {
            let snap = this.tapCount
            let _ = spawn {
                sleep(Duration.millisecond * 300)
                launch {
                    if (this.tapCount == snap) {
                        this.tapCount = 0
                        if (!this.performSideTapNavigation()) {
                            // 单击：切换 chrome（P2-198）；imgmenu：chrome 隐藏时同时收起更多菜单
                            this.showControls = !this.showControls
                            if (this.showControls) {
                                this.scheduleChromeFade()
                            } else {
                                this.showMoreMenu = false
                            }
                        }
                    }
                }
            }
        }
    }

    /**
     * S7-117: GalleryPagerNode.tapLongTapOrDoubleTapGesture（:366-372）对齐——单击落在左边缘且
     * canGoToPreviousItem → 上一张；落在右边缘且 canGoToNextItem → 下一张。
     * canGoTo* 在 disableTapNavigation（= !showNextMediaOnTap）时恒 false（:581-600）。
     * 返回 true 表示已切图（本次单击不再切换 chrome）。
     */
    private func performSideTapNavigation(): Bool {
        if (!this.tapNavigationEnabled || this.images.size <= 1 || this.viewerWidth <= 0.0 || this.tapDownX < 0.0) {
            return false
        }
        if (Float64(this.zoomScale) > 1.05) {
            return false
        }
        let sixth = Float64(Int64(this.viewerWidth / 6.0))
        let edge = if (sixth < 44.0) { sixth } else { 44.0 }
        if (this.tapDownX < edge && this.displayIndex > 0) {
            this.swiperController.showPrevious()
            return true
        }
        if (this.tapDownX > this.viewerWidth - edge && this.displayIndex < this.images.size - 1) {
            this.swiperController.showNext()
            return true
        }
        return false
    }

    /**
     * P2-194 平移边界回弹
     */
    private func clampOffset(): Unit {
        let maxX = Float64(360.0) * (Float64(this.zoomScale) - 1.0) / 2.0
        let maxY = Float64(780.0) * (Float64(this.zoomScale) - 1.0) / 2.0
        if (this.offsetX > maxX) {
            this.offsetX = maxX
        } else if (this.offsetX < -maxX) {
            this.offsetX = -maxX
        }
        if (this.offsetY > maxY) {
            this.offsetY = maxY
        } else if (this.offsetY < -maxY) {
            this.offsetY = -maxY
        }
    }

    /**
     * P2-198 自动隐藏 chrome：3 秒无操作后隐藏
     */
    private func scheduleChromeFade(): Unit {
        this.chromeTimerVersion = this.chromeTimerVersion + 1
        let currentVersion = this.chromeTimerVersion
        let _ = spawn {
            sleep(Duration.second * 3)
            launch {
                if (this.chromeTimerVersion == currentVersion) {
                    this.showControls = false
                    // imgmenu：chrome 自动隐藏时同时收起更多菜单
                    this.showMoreMenu = false
                }
            }
        }
    }

    /**
     * P2-199: 获取当前图片的 caption（真实数据来自 ImageItem.caption）
     */
    private func getCurrentCaption(): String {
        if (this.displayIndex >= 0 && this.displayIndex < this.images.size) {
            return this.images[this.displayIndex].caption
        }
        return ""
    }

    /**
     * TC-0023 返修：获取当前图片的发送者名（真实数据来自 ImageItem.senderName）
     * 调用方（如 ChatRoomPage.openImageViewer）未填充时返回空串，标题栏回退为图片计数。
     */
    private func getCurrentSenderName(): String {
        if (this.displayIndex >= 0 && this.displayIndex < this.images.size) {
            return this.images[this.displayIndex].senderName
        }
        return ""
    }

    /**
     * TC-0023 返修：获取当前图片的时间文本（真实数据来自 ImageItem.timeText）
     */
    private func getCurrentTimeText(): String {
        if (this.displayIndex >= 0 && this.displayIndex < this.images.size) {
            return this.images[this.displayIndex].timeText
        }
        return ""
    }

    // ==================== imgmenu 批次：更多菜单 + 分享/转发/删除 ====================

    /**
     * 顶部"更多"下拉菜单内容（对齐 iOS 图片查看器右上 "..." context menu 动作子集：
     * Forward / Save to Gallery / Share / Delete；均复用底栏同一真实实现）。
     */
    @Builder
    func buildMoreMenu() {
        Column {
            if (this.getCurrentMsgId() != 0) {
                Row {
                    Image(@r(app.media.chatroom_ic_forward))
                        .width(20)
                        .height(20)
                        .fillColor(0xFFFFFF)
                    Text(trSource("Forward"))
                        .fontSize(15)
                        .fontColor(0xFFFFFF)
                        .margin(left: 12)
                }
                .width(100.percent)
                .height(46)
                .padding(left: 16, right: 16)
                .onClick({ evt =>
                    this.showMoreMenu = false
                    this.forwardCurrentImage()
                })
                Divider()
                    .color(0x33FFFFFF)
            }

            Row {
                Image(@r(app.media.media_ic_save))
                    .width(20)
                    .height(20)
                    .fillColor(0xFFFFFF)
                Text(trSource("Save to Gallery"))
                    .fontSize(15)
                    .fontColor(0xFFFFFF)
                    .margin(left: 12)
            }
            .width(100.percent)
            .height(46)
            .padding(left: 16, right: 16)
            .onClick({ evt =>
                this.showMoreMenu = false
                this.saveCurrentImage()
            })

            Divider()
                .color(0x33FFFFFF)

            Row {
                Image(@r(app.media.media_ic_share))
                    .width(20)
                    .height(20)
                    .fillColor(0xFFFFFF)
                Text(trSource("Share"))
                    .fontSize(15)
                    .fontColor(0xFFFFFF)
                    .margin(left: 12)
            }
            .width(100.percent)
            .height(46)
            .padding(left: 16, right: 16)
            .onClick({ evt =>
                this.showMoreMenu = false
                this.shareCurrentImage()
            })

            if (this.getCurrentMsgId() != 0) {
                Divider()
                    .color(0x33FFFFFF)
                Row {
                    Image(@r(app.media.clist_ic_delete))
                        .width(20)
                        .height(20)
                        .fillColor(0xFFFF3B30)
                    Text(trSource("Delete"))
                        .fontSize(15)
                        .fontColor(0xFFFF3B30)
                        .margin(left: 12)
                }
                .width(100.percent)
                .height(46)
                .padding(left: 16, right: 16)
                .onClick({ evt =>
                    this.showMoreMenu = false
                    this.deleteCurrentImage()
                })
            }
        }
        .width(220)
        .backgroundColor(0xF2262628)
        .borderRadius(14)
        .clip(true)
    }

    /**
     * 获取当前图片所属消息 id（ImageItem.msgId；0 = 无消息上下文，Forward/Delete 不可用）
     */
    private func getCurrentMsgId(): Int64 {
        if (this.displayIndex >= 0 && this.displayIndex < this.images.size) {
            return this.images[this.displayIndex].msgId
        }
        return 0
    }

    /**
     * imgmenu：分享当前图片（对应 iOS GalleryController actionButton → UIActivityViewController）。
     *
     * 真实链路：callArkAsync(SHARE_LINK, {filePath,...}) → ShareLinkImpl.ets（media-file 分支）
     * → fileUri.getUriFromPath → systemShare.ShareController.show（真实系统分享面板，IMAGE UTD）。
     * ok=false（无 context / API 错）时诚实降级：copyMediaFileUri 把 file:// URI 写入系统剪贴板
     * 并提示（同 InviteMembersSheet.shareLink 的降级先例，不静默）。
     */
    private func shareCurrentImage(): Unit {
        if (this.displayIndex < 0 || this.displayIndex >= this.images.size) { return }
        let rawPath = this.images[this.displayIndex].url
        if (rawPath.size == 0) { return }
        // ArkTS 侧 fileUri.getUriFromPath 需要沙箱绝对路径；去掉可能的 file:// 前缀
        let path = if (rawPath.startsWith("file://")) { rawPath[7..rawPath.size] } else { rawPath }
        let argJson = "{\"filePath\":\"" + imageViewerJsonEscape(path) + "\",\"title\":\"Photo\",\"isVideo\":false}"
        Hilog.info(0, "CjTelegram", "[ImageViewer] Share image: ${path}")
        callArkAsync(SHARE_LINK, argJson, { res =>
            if (res.contains("\"ok\":true")) {
                Hilog.info(0, "CjTelegram", "[ImageViewer] systemShare presented ok")
            } else {
                Hilog.info(0, "CjTelegram", "[ImageViewer] systemShare unavailable, fallback to clipboard: ${res}")
                if (getSaveToCameraRollService().copyMediaFileUri(rawPath)) {
                    launch { this.saveStatus = "Photo link copied" }
                } else {
                    launch { this.saveStatus = "Share unavailable" }
                }
                this.clearSaveStatusAfterDelay()
            }
        })
    }

    /**
     * imgmenu：转发当前图片 — 上报宿主页（ChatRoomPage 关闭查看器并打开既有 forward picker，
     * 落到 messages.forwardMessages 真实 TL 调用）。
     */
    private func forwardCurrentImage(): Unit {
        let msgId = this.getCurrentMsgId()
        if (msgId == 0) { return }
        Hilog.info(0, "CjTelegram", "[ImageViewer] Forward requested msgId=${msgId}")
        this.onForwardRequest(msgId)
    }

    /**
     * imgmenu：删除当前图片 — 上报宿主页（ChatRoomPage 弹确认框 Delete for Me / Everyone，
     * 落到 messages.deleteMessages 真实 TL 调用）。
     */
    private func deleteCurrentImage(): Unit {
        let msgId = this.getCurrentMsgId()
        if (msgId == 0) { return }
        Hilog.info(0, "CjTelegram", "[ImageViewer] Delete requested msgId=${msgId}")
        this.onDeleteRequest(msgId)
    }

    /**
     * TC-0024 rework2 返修：保存当前图片到系统相册（权限姿势升级）。
     *
     * 历史：
     * 1. 原始实现用 FileIo.copyFile 把图片拷进 App 私有沙箱 saved_photos 目录（假保存）。
     * 2. rework1 改为 PermissionsService.ensurePermission(PhotoLibrary) 动态申请
     *    ohos.permission.WRITE_IMAGEVIDEO + SaveToCameraRollService.saveImageToGallery()
     *    （photoAccessHelper.applyChanges），逻辑正确但被本文件 build() 的 z-order 命中测试
     *    回归挡住，从未被验证；且 WRITE_IMAGEVIDEO 的 availableLevel=system_basic，
     *    普通 apl:normal 签名档位下 signed HAP 装不上（工程阻塞，与 UI 缺陷独立但一并处理）。
     *
     * 本轮（rework2）：cangjie-kb 核实 photoAccessHelper.showAssetsCreationDialog（KB doc_id
     * cjlang_ohos_..._cj-apis-file-photo_access_helper，起始版本 22，见 kb_consultations）——
     * 拉起系统"保存确认"弹窗，用户同意后返回已授予保存权限的 uri 列表；属于一次性用户同意
     * 交互（类似 SaveButton 安全组件语义），**不需要**声明/动态申请 WRITE_IMAGEVIDEO
     * AccessToken 权限。KB 文档明确"当传入 uri 为沙箱路径时，可正常保存图片/视频，但无界面
     * 预览"——本工程 ImageItem.url 正是本地沙箱路径（如 ChatRoomPage.openImageViewer 填充的
     * m.photoLocalPath），直接可用，无需先创建媒体库资源。
     *
     * 后续治理（gallery-nopermission 跨 feature 权限治理，独立 worktree
     * feature/gallery-nopermission）：DeviceAccessService.cj/PermissionsService.cj/
     * SaveToCameraRollService.cj/VideoPlayer.cj/SaveToCameraRollComponent.cj 已全部迁移到
     * 同一 showAssetsCreationDialog 免权限姿势，module.json5 的 WRITE_IMAGEVIDEO 声明
     * 已随之移除——rework1 报告记录的 signed HAP 因该权限 availableLevel=system_basic
     * 装不上的工程阻塞已解除。详见该批次 featureX.md Hand-off。
     */
    private func saveCurrentImage(): Unit {
        if (this.displayIndex < 0 || this.displayIndex >= this.images.size) { return }
        let currentImage = this.images[this.displayIndex]
        let srcPath = currentImage.url
        if (srcPath.size == 0) { return }

        match (getGlobalAbilityContext()) {
            case None =>
                Hilog.info(0, "CjTelegram", "[ImageViewer] Save failed: no ability context")
                this.saveStatus = "Save failed"
                this.clearSaveStatusAfterDelay()
            case Some(ctx) =>
                // imgmenu 批次真机返修：srcFileUri 必须带 bundleName authority
                // （file://<bundle>/<path>），空 authority 时媒体库进程读不到源文件，
                // 弹窗不出现且回调立即返回空（同 SaveToCameraRollService.normalizeFileUri 注释）。
                let uri = imageViewerShareableUri(srcPath)
                let ext = extractFileExtension(srcPath)
                let config = PhotoCreationConfig(ext, PhotoType.Image)
                let callback = ImageViewerSaveDialogCallback(this, srcPath)
                try {
                    let phAccessHelper = getPhotoAccessHelper(ctx)
                    phAccessHelper.showAssetsCreationDialog([uri], [config], callback)
                } catch (e: BusinessException) {
                    Hilog.info(0, "CjTelegram", "[ImageViewer] showAssetsCreationDialog BusinessException: ${e.message}")
                    this.saveStatus = "Save failed"
                    this.clearSaveStatusAfterDelay()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ImageViewer] showAssetsCreationDialog Exception: ${e}")
                    this.saveStatus = "Save failed"
                    this.clearSaveStatusAfterDelay()
                }
        }
    }

    /**
     * showAssetsCreationDialog 的结果回调入口（由 ImageViewerSaveDialogCallback.invoke 调用）。
     * 非 UI 线程回调，@State 写入须用 launch{} 包裹（S-001）。
     * savedUris 非空 = 用户同意保存；空列表 = 用户拒绝（不视为错误，按 iOS 取消保存语义处理）。
     *
     * imgmenu 批次真机返修：用户同意后媒体库只创建**空资产**并返回已授权目标 uri，
     * 写入图片字节是调用方职责（真机实证：未写入时相册出现 0 字节坏图）——此处调用
     * SaveToCameraRollService.writeFileToUri 把源文件落盘进目标 uri，成功才提示 Saved!。
     */
    func onSaveDialogResult(savedUris: Array<String>, srcPath: String): Unit {
        if (savedUris.size > 0) {
            if (getSaveToCameraRollService().writeFileToUri(srcPath, savedUris[0])) {
                Hilog.info(0, "CjTelegram", "[ImageViewer] Saved to system gallery: ${savedUris[0]}")
                launch { this.saveStatus = "Saved!" }
            } else {
                Hilog.info(0, "CjTelegram", "[ImageViewer] save copy-to-uri failed: ${savedUris[0]}")
                launch { this.saveStatus = "Save failed" }
            }
        } else {
            Hilog.info(0, "CjTelegram", "[ImageViewer] showAssetsCreationDialog: user declined or empty result")
            launch { this.saveStatus = "" }
        }
        this.clearSaveStatusAfterDelay()
    }

    /**
     * 3秒后清除保存状态提示（保存成功/失败结果共用）
     */
    private func clearSaveStatusAfterDelay(): Unit {
        let _ = spawn {
            sleep(Duration.second * 3)
            launch { this.saveStatus = "" }
        }
    }
}

/**
 * TC-0024 rework2: showAssetsCreationDialog 结果回调实现。
 * KB Example 101（cj-apis-file-photo_access_helper）：
 *   class MyCallback1<T> <: Callback1Argument<T> { func invoke(err: ?BusinessException, arg: T): Unit }
 * 对齐本仓库既有惯例（DeviceProximityBinding.cj DeviceProximitySensorCallback 等）。
 */
class ImageViewerSaveDialogCallback <: Callback1Argument<Array<String>> {
    private var _viewer: ImageViewer
    // imgmenu 批次：携带源文件路径，同意后由 onSaveDialogResult 写入目标 uri（见其注释）
    private var _srcPath: String

    init(viewer: ImageViewer, srcPath: String) {
        this._viewer = viewer
        this._srcPath = srcPath
    }

    public func invoke(err: ?BusinessException, arg: Array<String>): Unit {
        match (err) {
            case Some(e) =>
                Hilog.info(0, "CjTelegram", "[ImageViewer] showAssetsCreationDialog callback error: ${e.message}")
                this._viewer.onSaveDialogResult([], this._srcPath)
            case None =>
                this._viewer.onSaveDialogResult(arg, this._srcPath)
        }
    }
}

/**
 * 从本地文件路径提取扩展名（不含 "."），供 PhotoCreationConfig.fileNameExtension 使用。
 * R-101: String 无 hasSuffix，用 split(".") 取最后一段代替。
 */
/**
 * S7-117: 读取外观设置 "Show Next Media on Tap"（AppearanceSettingsPage 写入同一
 * Preferences 存储 "telegram_themes_cache" / 键 "show_next_media_on_tap"，未写过时默认 true，
 * 对齐 iOS MediaDisplaySettings.defaultSettings）。
 */
func loadShowNextMediaOnTapPref(): Bool {
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, "telegram_themes_cache")
                match (prefs.get("show_next_media_on_tap", PreferencesValueType.Integer(1))) {
                    case PreferencesValueType.Integer(n) => return n != 0
                    case _ => return true
                }
            } catch (_e: Exception) {
                return true
            }
        case None => return true
    }
}

private func extractFileExtension(path: String): String {
    let parts = path.split(".")
    if (parts.size > 1) {
        return parts[parts.size - 1]
    }
    return "jpg"
}

// showAssetsCreationDialog srcFileUri 的 bundleName authority（与 AppScope/app.json5 一致）
private let VIEWER_URI_BUNDLE: String = "com.hmcangjie.telegram"

/**
 * imgmenu：沙箱路径 → 带 bundleName authority 的分享型 file URI
 * （file://<bundle>/<abs-path>；空 authority 的 file:/// 形态一并升级）。
 */
private func imageViewerShareableUri(path: String): String {
    if (path.startsWith("file://")) {
        let rest = path[7..path.size]
        if (rest.startsWith("/")) {
            return "file://" + VIEWER_URI_BUNDLE + rest
        }
        return path
    }
    if (path.startsWith("/")) {
        return "file://" + VIEWER_URI_BUNDLE + path
    }
    return "file://" + path
}

/**
 * imgmenu：JSON 字符串转义（仅 " 与 \，沙箱路径无其他特殊字符），
 * 同 InviteMembersSheet.jsonEscapeInvite 先例。
 */
private func imageViewerJsonEscape(s: String): String {
    var result = ""
    for (ch in s.runes()) {
        if (ch == r'"') {
            result += "\\\""
        } else if (ch == r'\\') {
            result += "\\\\"
        } else {
            result += ch.toString()
        }
    }
    return result
}
