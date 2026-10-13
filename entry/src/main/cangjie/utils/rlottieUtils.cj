package ohos_app_cangjie_entry.utils

/**
 * rlottieUtils — rlottie 渲染库上层工具调用接口
 *
 * 对应 iOS: RLottieBinding 上层调用点（AnimationNode.cj、MessageBubble.cj 等）
 *
 * 提供高层工具函数，供 MessageBubble、EmojiPicker、StickerPicker 等组件调用。
 * 依赖 RlottieBinding（bindings/rlottieBinding.cj）中的接口契约。
 *
 * 函数列表：
 * - buildRlottieInstance()        工厂方法：创建 RlottieBinding 实例
 * - loadAnimation(data, key)      从字节数据加载动画（默认无色彩替换/无 fitz 修改）
 * - loadAnimationWithOptions(...)  带选项加载（指定 FitzModifier + 颜色替换）
 * - validateAnimationData(data)   验证 Lottie JSON 数据基本合法性
 * - computeFrameIndex(info, t)    从时间戳（秒）计算帧索引（夹紧到 [0, frameCount-1]）
 * - computeLoopTime(info, t)      时间戳对总时长取模（循环播放用）
 * - formatAnimationDuration(sec)  动画时长格式化为人类可读字符串（"0.5s" / "1.2s"）
 * - getAnimationFrameInterval(fps) 帧间隔（毫秒），用于定时器驱动
 * - isTgsData(data)               检测字节是否为 TGS（gzip 压缩 Lottie JSON）
 * - isLottieJsonData(data)        检测字节是否为未压缩 Lottie JSON
 * - buildColorReplacement(from, to) 构建单个颜色替换条目的快捷方法
 */

import ohos_app_cangjie_entry.bindings.{
    RlottieBinding,
    RlottieAnimationInfo,
    RlottieFrameBuffer,
    RlottieColorReplacement,
    RlottieInstance,
    LottieFitzModifier
}
import kit.PerformanceAnalysisKit.Hilog

// ============================================================
// 工厂方法
// ============================================================

/**
 * 创建 RlottieBinding 实例（工厂方法）
 * 供调用方通过 RlottieInstance 接口访问，便于后续替换实现
 */
public func buildRlottieInstance(): RlottieBinding {
    return RlottieBinding()
}

// ============================================================
// 加载便捷方法
// ============================================================

/**
 * 从字节数组加载 Lottie 动画（默认选项：无 FitzModifier，无颜色替换）
 *
 * 对应 iOS: [[LottieInstance alloc] initWithData:data fitzModifier:LottieFitzModifierNone colorReplacements:nil cacheKey:cacheKey]
 *
 * @param data     Lottie JSON 字节数组（未压缩；TGS 需先 gzip 解压）
 * @param cacheKey 缓存 key（通常为 sticker fileId 或消息 id 字符串）
 * @return 成功返回 Some(RlottieBinding)，失败返回 None
 */
public func loadAnimation(data: Array<UInt8>, cacheKey: String): Option<RlottieBinding> {
    let instance = buildRlottieInstance()
    let emptyReplacements = Array<RlottieColorReplacement>(0, repeat: RlottieColorReplacement())
    let ok = instance.loadFromData(
        data,
        LottieFitzModifier.FitzNone,
        emptyReplacements,
        cacheKey
    )
    if (ok) {
        return Option<RlottieBinding>.Some(instance)
    }
    Hilog.info(0, "CjTelegram", "[RlottieUtils] loadAnimation failed")
    return Option<RlottieBinding>.None
}

/**
 * 带选项加载 Lottie 动画（指定 FitzModifier 和颜色替换）
 *
 * 对应 iOS: [[LottieInstance alloc] initWithData:data fitzModifier:modifier colorReplacements:colors cacheKey:key]
 * 用于皮肤色调动画贴纸（带 Fitzpatrick 人物角色贴纸）
 *
 * @param data             Lottie JSON 字节数组
 * @param cacheKey         缓存 key
 * @param fitzModifier     肤色修饰符
 * @param colorReplacements 颜色替换列表
 * @return 成功返回 Some(RlottieBinding)，失败返回 None
 */
public func loadAnimationWithOptions(
    data: Array<UInt8>,
    cacheKey: String,
    fitzModifier: LottieFitzModifier,
    colorReplacements: Array<RlottieColorReplacement>
): Option<RlottieBinding> {
    let instance = buildRlottieInstance()
    let ok = instance.loadFromData(
        data,
        fitzModifier,
        colorReplacements,
        cacheKey
    )
    if (ok) {
        return Option<RlottieBinding>.Some(instance)
    }
    Hilog.info(0, "CjTelegram", "[RlottieUtils] loadAnimationWithOptions failed")
    return Option<RlottieBinding>.None
}

// ============================================================
// 数据验证
// ============================================================

/**
 * 验证 Lottie JSON 数据的基本合法性
 *
 * 检查项：
 * 1. 数据非空
 * 2. 不是 TGS 格式（gzip 压缩，需先解压）
 * 3. 包含 JSON 对象起始字符 '{'
 * 4. 包含 Lottie 必要字段 "fr"（帧率）和 "op"（结束帧）的关键字
 *
 * @param data 待验证的字节数组
 * @return true 表示数据结构基本合法（不保证完整解析成功）
 */
public func validateAnimationData(data: Array<UInt8>): Bool {
    if (data.size < 10) { return false }

    // TGS 是 gzip 压缩数据，magic bytes: 0x1f 0x8b
    if (data[0] == 0x1f && data[1] == 0x8b) {
        Hilog.info(0, "CjTelegram", "[RlottieUtils] validateAnimationData: data is gzip (TGS), needs decompression")
        return false
    }

    // 检查是否以 '{' 开头（JSON 对象）
    let firstByte = data[0]
    if (firstByte != 123) {
        return false
    }

    // 检查是否包含 Lottie 关键字段（"fr" 和 "op"）
    let hasFr = RlottieBinding.containsAsciiKey(data, "\"fr\"")
    let hasOp = RlottieBinding.containsAsciiKey(data, "\"op\"")
    return hasFr && hasOp
}

/**
 * 检测字节数据是否为 TGS 格式（gzip 压缩 Lottie JSON）
 *
 * TGS 是 Telegram 动态贴纸格式：gzip 压缩的 Lottie JSON
 * Magic bytes: 0x1F 0x8B（gzip header）
 *
 * @param data 待检测字节数组
 * @return true 表示是 TGS/gzip 格式
 */
public func isTgsData(data: Array<UInt8>): Bool {
    if (data.size < 2) { return false }
    return data[0] == 0x1f && data[1] == 0x8b
}

/**
 * 检测字节数据是否为未压缩的 Lottie JSON
 *
 * @param data 待检测字节数组
 * @return true 表示是未压缩 JSON（以 '{' 开头）
 */
public func isLottieJsonData(data: Array<UInt8>): Bool {
    if (data.size == 0) { return false }
    return data[0] == 123
}

// ============================================================
// 帧索引计算
// ============================================================

/**
 * 从时间戳（秒）计算帧索引
 *
 * 对应 iOS 上层调用方计算逻辑：index = time * frameRate
 * 返回值夹紧到 [0, frameCount-1]。
 *
 * 用途：驱动逐帧播放时，将当前播放时间转换为帧索引
 *
 * @param info    动画元信息（包含 frameCount 和 frameRate）
 * @param timeSec 当前播放时间（秒，从 0 开始）
 * @return 帧索引（[0, frameCount-1]）
 */
public func computeFrameIndex(info: RlottieAnimationInfo, timeSec: Float64): Int32 {
    if (!info.isValid || info.frameRate <= 0 || info.frameCount <= 0) { return 0 }
    let raw = Int32(timeSec * Float64(info.frameRate))
    let maxIdx = info.frameCount - 1
    if (raw < 0) { return 0 }
    if (raw > maxIdx) { return maxIdx }
    return raw
}

/**
 * 时间戳对总时长取模（循环播放用）
 *
 * 将任意时间戳映射到动画时长范围 [0, duration) 内，
 * 用于无限循环播放贴纸动画。
 *
 * @param info    动画元信息
 * @param timeSec 全局播放时间（秒，可以超过动画总时长）
 * @return 映射后的播放时间（[0, durationSeconds)）
 */
public func computeLoopTime(info: RlottieAnimationInfo, timeSec: Float64): Float64 {
    if (!info.isValid || info.durationSeconds <= 0.0) { return 0.0 }
    let dur = info.durationSeconds
    // 手动取模（仓颉 Float64 无 % 操作符用于浮点）
    let cycles = Float64(Int64(timeSec / dur))
    let looped = timeSec - cycles * dur
    if (looped < 0.0) { return 0.0 }
    return looped
}

// ============================================================
// 格式化工具
// ============================================================

/**
 * 格式化动画时长为人类可读字符串
 *
 * 用于调试和 UI 显示（如"贴纸时长: 1.5s"）
 *
 * @param durationSec 动画时长（秒）
 * @return 格式化字符串，如 "0.5s", "1.2s", "2.0s"
 */
public func formatAnimationDuration(durationSec: Float64): String {
    if (durationSec < 0.0) { return "0.0s" }
    // 保留一位小数：sec.d
    let intPart = Int64(durationSec)
    let fracPart = Int64((durationSec - Float64(intPart)) * 10.0)
    return "${intPart}.${fracPart}s"
}

/**
 * 计算帧间隔（毫秒）
 *
 * 用于 UI 定时器驱动帧播放（spawn + sleep 模式）。
 * 返回值 = 1000 / frameRate，夹紧到合理范围 [8, 1000] ms。
 *
 * @param frameRate 动画帧率（fps）
 * @return 帧间隔（毫秒）
 */
public func getAnimationFrameInterval(frameRate: Int32): Int64 {
    if (frameRate <= 0) { return 100 }
    let intervalMs = Int64(1000) / Int64(frameRate)
    if (intervalMs < 8) { return 8 }
    if (intervalMs > 1000) { return 1000 }
    return intervalMs
}

// ============================================================
// 颜色替换工具
// ============================================================

/**
 * 构建颜色替换条目
 *
 * 快捷方法，用于为动画贴纸添加颜色替换规则。
 * 对应 iOS colorReplacements NSDictionary 的单个键值对。
 *
 * @param originalColor   原始颜色（ARGB 32-bit）
 * @param replacementColor 替换颜色（ARGB 32-bit）
 * @return RlottieColorReplacement 条目
 */
public func buildColorReplacement(originalColor: UInt32, replacementColor: UInt32): RlottieColorReplacement {
    let entry = RlottieColorReplacement()
    entry.originalColor = originalColor
    entry.replacementColor = replacementColor
    return entry
}

/**
 * 从颜色列表构建颜色替换数组
 *
 * @param pairs Array of (original, replacement) pairs encoded as [orig0, rep0, orig1, rep1, ...]
 * @return Array<RlottieColorReplacement>
 */
public func buildColorReplacements(pairs: Array<UInt32>): Array<RlottieColorReplacement> {
    let count = pairs.size / 2
    if (count <= 0) {
        return Array<RlottieColorReplacement>(0, repeat: RlottieColorReplacement())
    }
    return Array<RlottieColorReplacement>(Int64(count), { i: Int64 =>
        let entry = RlottieColorReplacement()
        entry.originalColor   = pairs[Int64(i) * 2]
        entry.replacementColor = pairs[Int64(i) * 2 + 1]
        entry
    })
}

// ============================================================
// RlottieBinding 辅助扩展（静态工具方法，放在 utils 而非 binding 层）
// ============================================================

/**
 * 检查字节数组中是否包含指定 ASCII key 字符串
 * 用于 validateAnimationData 中的关键字检测
 *
 * @param data 字节数组
 * @param key  ASCII 字符串
 * @return true 表示 data 包含该字节序列
 */
public func bytesContainKey(data: Array<UInt8>, key: String): Bool {
    return RlottieBinding.containsAsciiKey(data, key)
}

/**
 * 从 RlottieAnimationInfo 生成简要描述字符串（调试用）
 *
 * 输出示例："v=5.5.2 fps=30 frames=60 size=512x512 dur=2.0s"
 *
 * @param info 动画元信息
 * @return 描述字符串
 */
public func describeAnimationInfo(info: RlottieAnimationInfo): String {
    if (!info.isValid) { return "invalid" }
    let dur = formatAnimationDuration(info.durationSeconds)
    return "v=${info.version} fps=${info.frameRate} frames=${info.frameCount} size=${info.width}x${info.height} dur=${dur}"
}
