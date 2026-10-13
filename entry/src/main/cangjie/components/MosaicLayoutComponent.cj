package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.services.*

/**
 * 马赛克布局组件（MosaicLayoutComponent）
 *
 * 将一组图片按照马赛克拼贴算法（iOS chatMessageBubbleMosaicLayout 移植版）
 * 在固定宽度容器内计算各图尺寸/坐标，并用 Stack + 绝对定位渲染。
 *
 * 使用方式（外部调用者负责提供图片 URL 列表和尺寸列表）：
 *
 *   MosaicLayoutComponent(
 *       imagePaths: paths,
 *       imageSizes: sizes,
 *       containerWidth: 280.0,
 *       maxHeight: 360.0,
 *       spacing: 1.0,
 *       onImageTap: { idx => ... }
 *   )
 *
 * 特性：
 *   - 1-10 张图均可处理（算法上无上限）
 *   - 真实复刻 iOS 马赛克布局算法，无 MTProto / TL 依赖（纯几何计算）
 *   - 每张图带圆角，点击回调暴露给外部
 */
@Component
public class MosaicLayoutComponent {
    // ---- 输入参数 ----
    public var imagePaths: Array<String>          // 每张图的本地路径或网络 URL
    public var imageSizes: Array<MosaicImageSize> // 原始图片尺寸（宽高，vp）
    public var containerWidth: Float64 = 280.0    // 拼贴容器可用宽度（vp）
    public var maxHeight: Float64 = 360.0         // 拼贴容器最大高度（vp）
    public var spacing: Float64 = 1.0             // 图片间距（vp，默认 1.0）
    public var cornerRadius: Float64 = 4.0        // 图片圆角半径（vp）
    public var onImageTap: (Int64) -> Unit = { _idx: Int64 => }  // 点击回调，参数为图片索引

    // ---- 内部状态 ----
    @State var layoutResult: MosaicLayoutResult = MosaicLayoutResult(
        items: Array<MosaicItemResult>(0, { _i: Int64 =>
            MosaicItemResult(x: 0.0, y: 0.0, width: 0.0, height: 0.0, position: MosaicItemPosition.none)
        }),
        totalWidth: 0.0,
        totalHeight: 0.0
    )
    @State var layoutReady: Bool = false

    // ---- 生命周期 ----
    public override func aboutToAppear(): Unit {
        let _ = spawn { this.doLayout() }
    }

    private func doLayout(): Unit {
        let result = computeMosaicLayout(
            maxWidth: this.containerWidth,
            maxHeight: this.maxHeight,
            itemSizes: this.imageSizes,
            spacing: this.spacing
        )
        launch {
            this.layoutResult = result
            this.layoutReady = true
        }
    }

    // ---- 辅助方法（不在 build/@Builder 中使用 let）----
    private func getContainerHeight(): Float64 {
        if (this.layoutReady) { this.layoutResult.totalHeight } else { 80.0 }
    }

    private func getItemX(idx!: Int64): Float64 {
        if (idx < Int64(this.layoutResult.items.size)) { this.layoutResult.items[idx].x } else { 0.0 }
    }

    private func getItemY(idx!: Int64): Float64 {
        if (idx < Int64(this.layoutResult.items.size)) { this.layoutResult.items[idx].y } else { 0.0 }
    }

    private func getItemW(idx!: Int64): Float64 {
        if (idx < Int64(this.layoutResult.items.size)) { this.layoutResult.items[idx].width } else { 80.0 }
    }

    private func getItemH(idx!: Int64): Float64 {
        if (idx < Int64(this.layoutResult.items.size)) { this.layoutResult.items[idx].height } else { 80.0 }
    }

    private func getImagePath(idx!: Int64): String {
        if (idx < Int64(this.imagePaths.size)) { this.imagePaths[idx] } else { "" }
    }

    private func getImageCount(): Int64 {
        Int64(this.imagePaths.size)
    }

    // ---- UI 构建 ----
    func build() {
        Stack() {
            ForEach(
                Array<Int64>(this.getImageCount(), { i: Int64 => i }),
                itemGenerator: { idx: Int64, _key: Int64 =>
                    Image(this.getImagePath(idx: idx))
                        .width(this.getItemW(idx: idx))
                        .height(this.getItemH(idx: idx))
                        .objectFit(ImageFit.Cover)
                        .borderRadius(this.cornerRadius)
                        .position(x: this.getItemX(idx: idx), y: this.getItemY(idx: idx))
                        .onClick({ _ => this.onImageTap(idx) })
                }
            )
        }
        .width(this.containerWidth)
        .height(this.getContainerHeight())
        .alignContent(Alignment.TopStart)
    }
}
