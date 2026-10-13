package ohos_app_cangjie_entry.components

import kit.ImageKit.PixelMap
import kit.PerformanceAnalysisKit.Hilog
import std.collection.{HashMap, HashSet}
import std.sync.Monitor
import ohos_app_cangjie_entry.services.{
    resolveCustomEmojiDocument, ensureStickerLocalFile, loadStickerStaticFrame
}

/**
 * 消息正文里内联自定义表情的取图。
 *
 * `messageEntityCustomEmoji` 早就在 TLDialogs.cj 解析成 `entityType = "customEmoji"`
 * 并带着 documentId 落库了，但整个 UI 层没有任何消费方 —— 收到的高级表情消息
 * 一直只显示 alt 字符（👍 之类）。这是差距清单里唯一一条属于「显示错误」而不是
 * 「显示不够好」的。
 *
 * iOS 用 `EmojiTextAttachmentView` / `InlineStickerItemLayer` 把文档画进文本流。
 * 仓颉这边的等价物是 `Text { ... ImageSpan(...) ... }`：ImageSpan 既接受
 * PixelMap 也接受文件路径，正好覆盖动画表情（取代表帧）与静态表情（直接给路径）。
 *
 * 取图必须是异步的，而 `@Builder` 里只能读值不能等待，所以这里的约定是：
 *   - 组件 aboutToAppear 时对每个 documentId 调一次 `requestInlineCustomEmoji`；
 *   - 就绪回调里把一个 @State epoch 加一，触发重建；
 *   - `@Builder` 里同步读 `inlineCustomEmojiFrame` / `inlineCustomEmojiPath`，
 *     没就绪就退回 alt 文本。
 */
private let inlineMonitor: Monitor = Monitor()
private var inlineFrames: HashMap<Int64, PixelMap> = HashMap<Int64, PixelMap>()
private var inlinePaths: HashMap<Int64, String> = HashMap<Int64, String>()
private var inlineInflight: HashSet<Int64> = HashSet<Int64>()
private var inlineFailed: HashSet<Int64> = HashSet<Int64>()

/** 内联表情的光栅尺寸：正文 16pt 字号下 iOS 的行内表情约 20pt，取 3 倍物理像素。 */
private let INLINE_EMOJI_RASTER: Int32 = 72

public func inlineCustomEmojiFrame(documentId: Int64): Option<PixelMap> {
    synchronized(inlineMonitor) {
        if (inlineFrames.contains(documentId)) {
            return Some(inlineFrames[documentId])
        }
    }
    return None<PixelMap>
}

public func inlineCustomEmojiPath(documentId: Int64): String {
    synchronized(inlineMonitor) {
        if (inlinePaths.contains(documentId)) {
            return inlinePaths[documentId]
        }
    }
    return ""
}

public func hasInlineCustomEmoji(documentId: Int64): Bool {
    synchronized(inlineMonitor) {
        return inlineFrames.contains(documentId) || inlinePaths.contains(documentId)
    }
}

/**
 * 请求一枚内联自定义表情。已就绪会立刻回调；失败过的不再重试，
 * 避免一屏几十条消息把有界调度器灌满。
 */
public func requestInlineCustomEmoji(documentId: Int64, onReady: () -> Unit): Unit {
    if (documentId == 0) { return }
    synchronized(inlineMonitor) {
        if (inlineFrames.contains(documentId) || inlinePaths.contains(documentId)) {
            onReady()
            return
        }
        if (inlineInflight.contains(documentId) || inlineFailed.contains(documentId)) {
            return
        }
        let _ = inlineInflight.add(documentId)
    }
    let _ = getKeyboardMediaScheduler().submit {
        var ready = false
        match (resolveCustomEmojiDocument(documentId)) {
            case Some(doc) =>
                let path = ensureStickerLocalFile(doc)
                if (path.size > 0) {
                    let animated = doc.mimeType.contains("tgs") ||
                        doc.mimeType.contains("lottie") || doc.mimeType.contains("webm")
                    if (animated) {
                        // 正文里的表情不挂播放流：一屏可能几十枚，取代表帧即可，
                        // 与 iOS 在非可见/低性能场景下的降级一致。
                        match (loadStickerStaticFrame(
                            doc.documentId, path, doc.mimeType.contains("webm"),
                            INLINE_EMOJI_RASTER, representative: true)) {
                            case Some(pixelMap) =>
                                synchronized(inlineMonitor) { inlineFrames[documentId] = pixelMap }
                                ready = true
                            case None => ()
                        }
                    } else {
                        // 静态 WEBP/PNG 直接交给 ImageSpan 的路径重载
                        synchronized(inlineMonitor) { inlinePaths[documentId] = path }
                        ready = true
                    }
                }
            case None => ()
        }
        synchronized(inlineMonitor) {
            let _ = inlineInflight.remove(documentId)
            if (!ready) { let _ = inlineFailed.add(documentId) }
        }
        if (ready) {
            onReady()
        } else {
            Hilog.info(0, "CjTelegram", "[InlineEmoji] unresolved id=${documentId}")
        }
    }
}
