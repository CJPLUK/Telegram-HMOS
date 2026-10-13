package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.arkui.ui_context.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.utils.safeAnimateTo

/**
 * ProgressiveThumbnailComponent — 渐进式缩略图加载组件
 *
 * P2-391: 缩略图渐进加载 (blurhash / tiny thumbnail 模糊占位 → 全图淡入过渡)
 *
 * iOS 对应:
 *   - DirectMediaImageCache.getProgressiveSize + getLoadSignal 管线
 *   - TGPhotoEditorBlurEffect: 缩略图先显示低质量预览，全图加载完成后 opacity 动画淡入
 *   - SoftwareVideoLayerFrameManager 的占位模糊渲染模式
 *
 * 实现策略:
 *   1. placeholderUrl 不空时显示模糊占位 (blur data:// URL 或低清图)
 *   2. fullImageUrl 不空时叠加显示全图，opacity 从 0 → 1 (animateTo 300ms EaseInOut)
 *   3. fullImageUrl 触发 onComplete 时置 highResReady=true → spawn(UIThread) 淡入动画
 *
 * 调用方式 (单向数据流，不依赖 parent @State 进来的回调):
 *   ProgressiveThumbnailComponent(
 *       placeholderUrl: blurDataUrl,       // data:// URL 或 ""
 *       fullImageUrl:   localFilePath,     // file:// 路径或 ""
 *       width:          160.0,
 *       height:         160.0,
 *       fit:            ImageFit.Cover
 *   )
 *
 * 注意事项:
 *   - 全@State 无 dangling: placeholderUrl/fullImageUrl 为 public 输入字段，非 @State
 *     — 父组件通过传参刷新，无 orphan @State
 *   - S-001: onComplete 在 UI 事件线程，可直接写 @State (文档: Image.onComplete 为 UI 线程回调)
 *   - R-131: @State 缩放相关使用 Float32，opacity 为 Float64 (ArkUI .opacity() 接受 Float64)
 */
@Component
public class ProgressiveThumbnailComponent {
    /** 模糊占位图 URL (data://image/jpeg;base64,... 或 file:// 低清路径，空串时跳过) */
    public var placeholderUrl: String = ""
    /** 全分辨率图 URL (file:// 路径，可异步传入，空串时仅显示占位) */
    public var fullImageUrl: String = ""
    /** 显示宽度 (vp) */
    public var width: Float64 = 100.0
    /** 显示高度 (vp) */
    public var height: Float64 = 100.0
    /** 图片填充方式，默认 Cover */
    public var fit: ImageFit = ImageFit.Cover
    /** 全图淡入时长 (ms)，默认 300 ms，对应 iOS CALayer opacity animation */
    public var fadeDuration: Int32 = 300

    // 内部状态
    @State var highResOpacity: Float64 = 0.0
    @State var highResReady: Bool = false

    /**
     * 全图淡入动画 (S-001: spawn(UIThread) 包裹 @State 写入)
     * 对应 iOS: CATransaction animateTo opacity=1 duration=fadeDuration
     */
    private func fadeInHighRes(): Unit {
        spawn(UIThread) {
            =>
            safeAnimateTo({ => getUIContext() }, 
                AnimateParam(duration: this.fadeDuration, curve: Curve.EaseInOut),
                { => this.highResOpacity = 1.0 }
            )
            Hilog.info(0, "CjTelegram", "[ProgressiveThumb] fadeIn highRes url=${this.fullImageUrl.size}")
        }
    }

    private func hasPlaceholder(): Bool {
        return this.placeholderUrl.size > 0
    }

    private func hasFullImage(): Bool {
        return this.fullImageUrl.size > 0
    }

    func build() {
        Stack {
            if (this.hasPlaceholder()) {
                Image(this.placeholderUrl)
                    .width(this.width)
                    .height(this.height)
                    .objectFit(this.fit)
                    .blur(8.0)
            } else {
                Column {}
                    .width(this.width)
                    .height(this.height)
                    .backgroundColor(0xFFE0E0E0)
            }

            if (this.hasFullImage()) {
                Image(this.fullImageUrl)
                    .width(this.width)
                    .height(this.height)
                    .objectFit(this.fit)
                    .opacity(this.highResOpacity)
                    .onComplete({ _msg: ImageLoadResult =>
                        if (!this.highResReady) {
                            this.highResReady = true
                            this.fadeInHighRes()
                        }
                    })
            }
        }
        .width(this.width)
        .height(this.height)
    }
}
