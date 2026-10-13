package ohos_app_cangjie_entry.utils

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.bindings.{
    getLottieCppBinding,
    LottieAnimationMetadata,
    LottieVector2D,
    LottieColor,
    LottieRenderResult
}

/**
 * LottieCppUtils — Lottie C++ 上层工具接口
 *
 * 对应 Telegram-iOS submodules/LottieCpp 的上层使用模式：
 *   - Renderer::make(jsonString) 解析 Lottie JSON
 *   - Renderer::frameCount() / framesPerSecond() / size() 获取元数据
 *   - 帧渲染路径（deferred to native layer）
 *
 * 提供：
 * - parseLottieMetadata        — 从字节数组解析动画元数据
 * - parseLottieMetadataString  — 从 JSON 字符串解析动画元数据
 * - isLottieFile               — 判断文件路径是否为 Lottie 动画文件
 * - isLottieMimeType           — 判断 MIME 类型是否对应 Lottie 动画
 * - getLottieFrameCount        — 获取动画总帧数
 * - getLottieFrameRate         — 获取动画帧率
 * - getLottieSize              — 获取动画尺寸
 * - getLottieDuration          — 获取动画时长（秒）
 * - getLottieRenderStatus      — 获取渲染能力状态（platform_gap / available）
 * - renderLottieFrame          — 渲染指定帧（HarmonyOS 返回 platform_gap）
 * - lottieMsPerFrame           — 每帧时长（毫秒），用于 ArkUI 帧动画降级
 */

/**
 * 从 UTF-8 编码的 Lottie JSON 字节数组解析动画元数据
 *
 * 对应 lottie::Renderer::make(jsonString) + Renderer::frameCount()/framesPerSecond()/size()。
 *
 * 支持的文件来源：
 *   - 从磁盘读取的 .json 文件（原始 Lottie JSON）
 *   - 解压后的 .tgs 文件内容（gzip 解压后为 Lottie JSON）
 *
 * @param jsonBytes UTF-8 编码的 Lottie JSON 字节数组
 * @return 解析成功返回 Some(LottieAnimationMetadata)；格式错误返回 None
 */
public func parseLottieMetadata(jsonBytes: Array<Byte>): Option<LottieAnimationMetadata> {
    return getLottieCppBinding().parseLottieJson(jsonBytes)
}

/**
 * 从 Lottie JSON 字符串直接解析动画元数据
 *
 * @param jsonString Lottie JSON 字符串
 * @return 解析成功返回 Some(LottieAnimationMetadata)；格式错误返回 None
 */
public func parseLottieMetadataString(jsonString: String): Option<LottieAnimationMetadata> {
    return getLottieCppBinding().parseLottieJsonString(jsonString)
}

/**
 * 判断文件路径是否为 Lottie 动画文件
 *
 * 支持格式：
 *   - .tgs  — Telegram 动画贴纸（gzip 压缩的 Lottie JSON）
 *   - .json — 原始 Lottie JSON（如内嵌动画资源）
 *
 * 对应 iOS 侧判断 mimeType == "application/x-tgsticker" 或 contains("lottie")。
 *
 * @param filePath 文件路径或文件名
 * @return true 表示为 Lottie 支持的动画格式
 */
public func isLottieFile(filePath: String): Bool {
    return getLottieCppBinding().isLottieFilePath(filePath)
}

/**
 * 判断 MIME 类型是否对应 Lottie 动画
 *
 * Telegram 动画贴纸的 MIME 类型：
 *   - "application/x-tgsticker" — TGS 动画贴纸
 *   - 含 "lottie"              — Lottie JSON 动画
 *
 * @param mimeType MIME 类型字符串
 * @return true 表示为 Lottie 动画
 */
public func isLottieMimeType(mimeType: String): Bool {
    return getLottieCppBinding().isLottieMimeType(mimeType)
}

/**
 * 获取 Lottie 动画总帧数
 *
 * 对应 lottie::Renderer::frameCount()（= outPoint - inPoint）。
 *
 * @param jsonBytes UTF-8 编码的 Lottie JSON
 * @return 总帧数；解析失败返回 0
 */
public func getLottieFrameCount(jsonBytes: Array<Byte>): Int64 {
    return getLottieCppBinding().getFrameCount(jsonBytes)
}

/**
 * 获取 Lottie 动画帧率（每秒帧数）
 *
 * 对应 lottie::Renderer::framesPerSecond()（JSON 字段 "fr"）。
 *
 * @param jsonBytes UTF-8 编码的 Lottie JSON
 * @return 帧率（fps）；解析失败返回 0.0
 */
public func getLottieFrameRate(jsonBytes: Array<Byte>): Float64 {
    return getLottieCppBinding().getFrameRate(jsonBytes)
}

/**
 * 获取 Lottie 动画尺寸
 *
 * 对应 lottie::Renderer::size()（JSON 字段 "w", "h"）。
 *
 * @param jsonBytes UTF-8 编码的 Lottie JSON
 * @return 动画尺寸向量 (width, height)；解析失败返回 (0, 0)
 */
public func getLottieSize(jsonBytes: Array<Byte>): LottieVector2D {
    return getLottieCppBinding().getSize(jsonBytes)
}

/**
 * 获取 Lottie 动画时长（秒）
 *
 * @param jsonBytes UTF-8 编码的 Lottie JSON
 * @return 动画时长（秒）；解析失败或帧率为0返回 0.0
 */
public func getLottieDuration(jsonBytes: Array<Byte>): Float64 {
    match (getLottieCppBinding().parseLottieJson(jsonBytes)) {
        case Some(meta) => return meta.durationSeconds()
        case None => return 0.0
    }
}

/**
 * 获取渲染能力状态
 *
 * 用于调用方判断是否需要降级到静态预览或 ArkUI 帧动画。
 *
 * 当前状态说明：
 *   liblottiecpp.so 需要为 OHOS aarch64-linux-ohos 交叉编译并集成（类似 tgcalls 路径），
 *   当前阶段返回 "platform_gap"，调用方应降级处理。
 *
 * @return "platform_gap" 表示渲染不可用，需降级；"available" 表示可用（未来接通后返回）
 */
public func getLottieRenderStatus(): String {
    return getLottieCppBinding().getRenderCapabilityStatus()
}

/**
 * 渲染 Lottie 动画的指定帧
 *
 * platform_gap：liblottiecpp.so 在 HarmonyOS 上尚未集成，
 * 返回 LottieRenderResult.RenderDeferredPlatformGap。
 *
 * 降级建议：
 *   - 使用 ArkUI Image 组件显示贴纸静态缩略图
 *   - 或使用 Animator + 帧图片序列实现帧播放（需服务端预提取帧序列）
 *   - 或显示 WebP 格式的动画贴纸（MessageBubble 已有相关处理路径）
 *
 * @param metadata 动画元数据（由 parseLottieMetadata 获取）
 * @param frameIndex 要渲染的帧索引（0 到 frameCount-1）
 * @return 渲染状态（当前始终为 RenderDeferredPlatformGap）
 */
public func renderLottieFrame(metadata: LottieAnimationMetadata, frameIndex: Int64): LottieRenderResult {
    let result = getLottieCppBinding().renderFrame(metadata, frameIndex)
    match (result) {
        case LottieRenderResult.RenderDeferredPlatformGap =>
            Hilog.info(0, "CjTelegram", "[LottieCppUtils] renderLottieFrame: platform_gap — use fallback rendering")
        case LottieRenderResult.RenderSuccess =>
            Hilog.info(0, "CjTelegram", "[LottieCppUtils] renderLottieFrame: success")
        case LottieRenderResult.RenderUnsupportedInputData =>
            Hilog.info(0, "CjTelegram", "[LottieCppUtils] renderLottieFrame: unsupported input")
    }
    return result
}

/**
 * 计算每帧时长（毫秒）
 *
 * 用于 ArkUI 帧动画（Animator）的 duration 参数计算：
 *   每帧毫秒数 = 1000 / framesPerSecond
 *
 * 典型 Telegram 贴纸：
 *   帧率 60fps → 每帧 ~16.67ms
 *   帧率 30fps → 每帧 ~33.33ms
 *
 * @param framesPerSecond 帧率（来自 LottieAnimationMetadata.framesPerSecond）
 * @return 每帧时长（毫秒）；帧率为0时返回 33（降级为 30fps）
 */
public func lottieMsPerFrame(framesPerSecond: Float64): Int64 {
    if (framesPerSecond <= 0.0) {
        return 33
    }
    let ms = 1000.0 / framesPerSecond
    if (ms < 1.0) {
        return 1
    }
    return Int64(ms)
}

/**
 * 计算指定时间点（秒）对应的帧索引
 *
 * @param metadata 动画元数据
 * @param timeSeconds 时间点（秒，从 0 开始）
 * @return 帧索引，clamped 到 [0, frameCount-1]
 */
public func lottieTimeToFrame(metadata: LottieAnimationMetadata, timeSeconds: Float64): Int64 {
    return getLottieCppBinding().timeToFrameIndex(metadata, timeSeconds)
}

/**
 * 计算指定帧索引对应的时间点（秒）
 *
 * @param metadata 动画元数据
 * @param frameIndex 帧索引
 * @return 时间点（秒）
 */
public func lottieFrameToTime(metadata: LottieAnimationMetadata, frameIndex: Int64): Float64 {
    return getLottieCppBinding().frameIndexToTime(metadata, frameIndex)
}

/**
 * 验证 Lottie JSON 字节数组格式是否合法
 *
 * @param jsonBytes UTF-8 编码的 Lottie JSON
 * @return true 表示格式合法（包含必要字段 fr/w/h）
 */
public func isValidLottieJson(jsonBytes: Array<Byte>): Bool {
    return getLottieCppBinding().isLottieJsonValid(jsonBytes)
}

/**
 * 从路径或 MIME 类型综合判断是否为 Lottie 动画
 *
 * 同时检查文件路径和 MIME 类型，满足其一即返回 true。
 *
 * @param filePath 文件路径（可以为空字符串）
 * @param mimeType MIME 类型（可以为空字符串）
 * @return true 表示为 Lottie 动画内容
 */
public func isLottieContent(filePath: String, mimeType: String): Bool {
    if (filePath.size > 0 && isLottieFile(filePath)) {
        return true
    }
    if (mimeType.size > 0 && isLottieMimeType(mimeType)) {
        return true
    }
    return false
}
