package ohos_app_cangjie_entry.bindings

import kit.PerformanceAnalysisKit.Hilog

/**
 * LottieCppBinding — Lottie C++ 渲染引擎平台封装层
 *
 * 对应 Telegram-iOS submodules/LottieCpp（lottie C++ 渲染引擎）。
 *
 * 平台差异说明：
 *   Telegram-iOS 使用 liblottiecpp（C++ 库）通过以下 API 完成渲染：
 *     - lottie::Renderer::make(jsonString) — 从 Lottie JSON 创建渲染器
 *     - lottie::Renderer::setFrame(float)  — 设置当前帧
 *     - lottie::CanvasRenderer::render(...) — 将帧渲染到 Canvas 上下文
 *
 *   HarmonyOS 侧平台差异：
 *     - liblottiecpp.so 为 iOS/macOS 专属，依赖 Foundation SDK 和 Darwin 平台接口
 *     - HarmonyOS 未提供等价 Lottie C++ 渲染 API
 *     - 若要完整渲染，需将 lottiecpp 交叉编译为 OHOS aarch64-linux-ohos 目标（类似
 *       tgcalls 的处理方式，参见 syntax_error.md #80-#85），并通过 dlopen 运行时加载
 *     - 当前阶段：渲染调用标注为 platform_gap（渲染延迟），元数据解析（帧数/帧率/尺寸）
 *       通过纯 Cangjie 实现的 Lottie JSON 解析完整实现
 *
 * 本层提供：
 * - LottieVector2D          — 二维向量（对应 lottie::Vector2D）
 * - LottieColor             — RGBA 颜色（对应 lottie::Color）
 * - LottieAnimationMetadata — 动画元数据
 * - LottieRenderResult      — 渲染结果枚举（包含 platform_gap 状态）
 * - LottieCppBinding        — 封装类，提供元数据解析和渲染状态接口
 *
 * 渲染路径差异处理：
 *   renderFrame() 返回 LottieRenderResult 枚举，明确区分"渲染成功"和"平台能力缺口"。
 *   调用方（如 sticker 组件）应检查状态并降级到静态缩略图或帧动画播放。
 *
 * 依赖注意：本文件不导入 services 包（避免循环依赖），使用内联 JSON 字段提取器。
 */

// ──────────────────────────────────────────────────────────────
// 数据模型类型
// ──────────────────────────────────────────────────────────────

/**
 * 二维向量 — 对应 lottie::Vector2D
 */
public class LottieVector2D {
    public var x: Float64
    public var y: Float64

    public init(x: Float64, y: Float64) {
        this.x = x
        this.y = y
    }
}

/**
 * RGBA 颜色 — 对应 lottie::Color
 * 各分量范围 [0.0, 1.0]
 */
public class LottieColor {
    public var r: Float64
    public var g: Float64
    public var b: Float64
    public var a: Float64

    public init(r: Float64, g: Float64, b: Float64, a: Float64) {
        this.r = r
        this.g = g
        this.b = b
        this.a = a
    }

    /**
     * 构造不透明黑色
     */
    public static func black(): LottieColor {
        return LottieColor(0.0, 0.0, 0.0, 1.0)
    }

    /**
     * 构造不透明白色
     */
    public static func white(): LottieColor {
        return LottieColor(1.0, 1.0, 1.0, 1.0)
    }

    /**
     * 构造完全透明色
     */
    public static func clear(): LottieColor {
        return LottieColor(0.0, 0.0, 0.0, 0.0)
    }
}

/**
 * Lottie 动画元数据 — 从 Lottie JSON 中解析得到的基本信息
 *
 * 对应 lottie::Renderer 公开属性：
 *   - frameCount()      → 总帧数 (op - ip)
 *   - framesPerSecond() → 帧率（Lottie JSON: "fr"）
 *   - size()            → 动画尺寸（Lottie JSON: "w", "h"）
 */
public class LottieAnimationMetadata {
    /**
     * 总帧数（= outPoint - inPoint）
     * Lottie JSON: "op" - "ip"
     */
    public var frameCount: Int64

    /**
     * 帧率（每秒帧数）
     * Lottie JSON: "fr"
     */
    public var framesPerSecond: Float64

    /**
     * 动画宽度（像素）
     * Lottie JSON: "w"
     */
    public var width: Float64

    /**
     * 动画高度（像素）
     * Lottie JSON: "h"
     */
    public var height: Float64

    /**
     * 起始帧（in-point）
     * Lottie JSON: "ip"
     */
    public var inPoint: Float64

    /**
     * 结束帧（out-point）
     * Lottie JSON: "op"
     */
    public var outPoint: Float64

    /**
     * 动画版本（如 "5.9.0"）
     * Lottie JSON: "v"
     */
    public var version: String

    public init(
        frameCount: Int64,
        framesPerSecond: Float64,
        width: Float64,
        height: Float64,
        inPoint: Float64,
        outPoint: Float64,
        version: String
    ) {
        this.frameCount = frameCount
        this.framesPerSecond = framesPerSecond
        this.width = width
        this.height = height
        this.inPoint = inPoint
        this.outPoint = outPoint
        this.version = version
    }

    /**
     * 动画时长（秒）
     */
    public func durationSeconds(): Float64 {
        if (this.framesPerSecond <= 0.0) {
            return 0.0
        }
        return Float64(this.frameCount) / this.framesPerSecond
    }

    /**
     * 返回动画尺寸向量
     */
    public func size(): LottieVector2D {
        return LottieVector2D(this.width, this.height)
    }
}

/**
 * Lottie 渲染结果状态枚举
 */
public enum LottieRenderResult {
    /**
     * 渲染成功（占位：HarmonyOS 渲染路径未来接通后使用）
     */
    | RenderSuccess

    /**
     * 平台能力缺口：HarmonyOS 侧 liblottiecpp.so 未集成，无法执行像素级渲染。
     * 调用方应降级到静态缩略图或 ArkUI 帧动画。
     * 类比 PdfBinding.platform_gap、TgCallsBridge 的 dlopen 延迟加载模式。
     */
    | RenderDeferredPlatformGap

    /**
     * 输入数据无效（JSON 解析失败、缺失 "w"/"h"/"fr" 等必要字段）
     */
    | RenderUnsupportedInputData
}

// ──────────────────────────────────────────────────────────────
// 单例访问
// ──────────────────────────────────────────────────────────────

private var _lottieCppBindingInstance: Option<LottieCppBinding> = None

/**
 * 获取 LottieCppBinding 单例
 */
public func getLottieCppBinding(): LottieCppBinding {
    match (_lottieCppBindingInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = LottieCppBinding()
            _lottieCppBindingInstance = Some(inst)
            return inst
    }
}

// ──────────────────────────────────────────────────────────────
// LottieCppBinding 封装类
// ──────────────────────────────────────────────────────────────

/**
 * LottieCppBinding — Lottie C++ 引擎封装层
 *
 * 核心职责：
 * 1. 从 Lottie JSON 字节数组解析动画元数据（纯 Cangjie 实现，无 native 依赖）
 * 2. 提供渲染状态接口，明确标注 HarmonyOS 的平台能力缺口
 * 3. 校验 Lottie JSON 格式合法性
 *
 * 注意：渲染调用（renderFrame）返回 RenderDeferredPlatformGap，因 liblottiecpp.so
 * 需要交叉编译为 OHOS 目标并通过运行时 dlopen 加载（类比 TgCallsBridge 模式）。
 * 本层设计上预留渲染接口以保持契约完整性，供后续集成。
 */
public class LottieCppBinding {

    /**
     * 从 Lottie JSON 字节数组解析动画元数据
     *
     * Lottie JSON 格式（airbnb/lottie spec）关键字段：
     *   "v"  : String  — 版本（如 "5.9.0"）
     *   "fr" : Number  — 帧率（frames per second）
     *   "ip" : Number  — 起始帧（in-point）
     *   "op" : Number  — 结束帧（out-point）
     *   "w"  : Number  — 宽度（像素）
     *   "h"  : Number  — 高度（像素）
     *
     * TGS（Telegram Animated Sticker）是 gzip 压缩的 Lottie JSON，
     * 调用本方法前需先解压为原始 JSON 字节。
     *
     * @param jsonBytes UTF-8 编码的 Lottie JSON 字节数组
     * @return 解析成功返回 Some(LottieAnimationMetadata)；格式错误返回 None
     */
    public func parseLottieJson(jsonBytes: Array<Byte>): Option<LottieAnimationMetadata> {
        if (jsonBytes.size == 0) {
            Hilog.info(0, "CjTelegram", "[LottieCpp] parseLottieJson: empty input")
            return None
        }

        let jsonStr = lottieJsonBytesToString(jsonBytes)
        if (jsonStr.size == 0) {
            Hilog.info(0, "CjTelegram", "[LottieCpp] parseLottieJson: conversion failed")
            return None
        }

        let trimmed = jsonStr.trimAscii()
        if (!trimmed.startsWith("{")) {
            Hilog.info(0, "CjTelegram", "[LottieCpp] parseLottieJson: not a JSON object")
            return None
        }

        // 从 Lottie JSON 提取顶层数值字段
        let fr = lottieExtractNumberField(trimmed, "fr")
        let w = lottieExtractNumberField(trimmed, "w")
        let h = lottieExtractNumberField(trimmed, "h")
        let ip = lottieExtractNumberField(trimmed, "ip")
        let op = lottieExtractNumberField(trimmed, "op")
        let version = lottieExtractStringField(trimmed, "v")

        // 必要字段校验：fr, w, h 均必须 > 0
        if (fr <= 0.0 || w <= 0.0 || h <= 0.0) {
            Hilog.info(0, "CjTelegram", "[LottieCpp] parseLottieJson: missing required fields fr/w/h")
            return None
        }

        // 计算帧数：out-point 减去 in-point
        let computedFrameCount: Int64
        if (op > ip && op > 0.0) {
            computedFrameCount = Int64(op - ip)
        } else if (op > 0.0) {
            computedFrameCount = Int64(op)
        } else {
            computedFrameCount = 0
        }

        let meta = LottieAnimationMetadata(
            computedFrameCount,
            fr,
            w,
            h,
            ip,
            op,
            version
        )

        Hilog.info(0, "CjTelegram", "[LottieCpp] parsed ok frames=" + computedFrameCount.toString() + " fps=" + fr.toString() + " size=" + w.toString() + "x" + h.toString())
        return Some(meta)
    }

    /**
     * 从 Lottie JSON 字符串直接解析元数据
     *
     * @param jsonString UTF-8 Lottie JSON 字符串
     * @return 解析成功返回 Some(LottieAnimationMetadata)；格式错误返回 None
     */
    public func parseLottieJsonString(jsonString: String): Option<LottieAnimationMetadata> {
        let runes = jsonString.toRuneArray()
        let bytes = Array<Byte>(runes.size, { i: Int64 =>
            let code = UInt32(runes[i])
            if (code < 128) { UInt8(code) } else { UInt8(63) }
        })
        return this.parseLottieJson(bytes)
    }

    /**
     * 校验 Lottie JSON 字节数组格式合法性
     *
     * @param jsonBytes UTF-8 编码的 Lottie JSON
     * @return true 表示格式合法（包含必要字段 fr/w/h）
     */
    public func isLottieJsonValid(jsonBytes: Array<Byte>): Bool {
        match (this.parseLottieJson(jsonBytes)) {
            case Some(_) => return true
            case None => return false
        }
    }

    /**
     * 获取 Lottie JSON 的总帧数
     *
     * @param jsonBytes UTF-8 编码的 Lottie JSON
     * @return 总帧数；解析失败返回 0
     */
    public func getFrameCount(jsonBytes: Array<Byte>): Int64 {
        match (this.parseLottieJson(jsonBytes)) {
            case Some(meta) => return meta.frameCount
            case None => return 0
        }
    }

    /**
     * 获取 Lottie JSON 的帧率
     *
     * @param jsonBytes UTF-8 编码的 Lottie JSON
     * @return 帧率（fps）；解析失败返回 0.0
     */
    public func getFrameRate(jsonBytes: Array<Byte>): Float64 {
        match (this.parseLottieJson(jsonBytes)) {
            case Some(meta) => return meta.framesPerSecond
            case None => return 0.0
        }
    }

    /**
     * 获取 Lottie 动画尺寸
     *
     * @param jsonBytes UTF-8 编码的 Lottie JSON
     * @return 动画尺寸向量；解析失败返回 (0, 0)
     */
    public func getSize(jsonBytes: Array<Byte>): LottieVector2D {
        match (this.parseLottieJson(jsonBytes)) {
            case Some(meta) => return meta.size()
            case None => return LottieVector2D(0.0, 0.0)
        }
    }

    /**
     * 渲染指定帧到像素缓冲区
     *
     * platform_gap：liblottiecpp.so 需要为 OHOS aarch64-linux-ohos 目标交叉编译，
     * 并通过运行时 dlopen 加载（参见 TgCallsBridge.cj 中 dlopen/dlsym 模式）。
     * 当前阶段此路径未集成，返回 RenderDeferredPlatformGap。
     *
     * 降级建议：
     *   - 使用 ArkUI Image 显示贴纸静态预览图（如果存在）
     *   - 或使用 ArkUI Animator + 帧图片序列实现帧播放
     *
     * @param metadata 动画元数据（由 parseLottieJson 获取）
     * @param frameIndex 要渲染的帧索引（0 到 frameCount-1）
     * @return LottieRenderResult 渲染状态
     */
    public func renderFrame(metadata: LottieAnimationMetadata, frameIndex: Int64): LottieRenderResult {
        Hilog.info(0, "CjTelegram", "[LottieCpp] renderFrame: platform_gap — liblottiecpp.so not integrated for OHOS")
        return LottieRenderResult.RenderDeferredPlatformGap
    }

    /**
     * 获取渲染能力状态描述字符串
     *
     * @return "platform_gap" 表示需要降级；"available" 表示渲染可用
     */
    public func getRenderCapabilityStatus(): String {
        return "platform_gap"
    }

    /**
     * 判断文件路径是否为 Lottie 动画文件
     *
     * 支持：.tgs（gzip 压缩 Lottie JSON）和 .json（原始 Lottie JSON）
     *
     * @param filePath 文件路径或文件名
     * @return true 表示为支持的动画文件格式
     */
    public func isLottieFilePath(filePath: String): Bool {
        if (filePath.size == 0) {
            return false
        }
        let lower = filePath.toAsciiLower()
        return lower.endsWith(".tgs") || lower.endsWith(".json")
    }

    /**
     * 判断 MIME 类型是否为 Lottie 动画
     *
     * Telegram 贴纸 MIME 类型：
     *   - "application/x-tgsticker" — TGS 动画贴纸
     *   - 含 "lottie" 或 "tgs"     — Lottie 动画
     *
     * @param mimeType MIME 类型字符串
     * @return true 表示为 Lottie 动画
     */
    public func isLottieMimeType(mimeType: String): Bool {
        if (mimeType.size == 0) {
            return false
        }
        let lower = mimeType.toAsciiLower()
        return lower.contains("tgsticker") || lower.contains("lottie") ||
               lower.contains("tgs")
    }

    /**
     * 计算指定时间点对应的帧索引
     *
     * @param metadata 动画元数据
     * @param timeSeconds 时间点（秒，从 0 开始）
     * @return 帧索引，clamped 到 [0, frameCount-1]
     */
    public func timeToFrameIndex(metadata: LottieAnimationMetadata, timeSeconds: Float64): Int64 {
        if (metadata.framesPerSecond <= 0.0 || metadata.frameCount <= 0) {
            return 0
        }
        let raw = Int64(timeSeconds * metadata.framesPerSecond)
        if (raw < 0) {
            return 0
        }
        if (raw >= metadata.frameCount) {
            return metadata.frameCount - 1
        }
        return raw
    }

    /**
     * 将帧索引转换为对应的时间点（秒）
     *
     * @param metadata 动画元数据
     * @param frameIndex 帧索引
     * @return 时间点（秒）
     */
    public func frameIndexToTime(metadata: LottieAnimationMetadata, frameIndex: Int64): Float64 {
        if (metadata.framesPerSecond <= 0.0) {
            return 0.0
        }
        return Float64(frameIndex) / metadata.framesPerSecond
    }
}

// ──────────────────────────────────────────────────────────────
// 内部工具函数（不导入 services 包，避免循环依赖）
// ──────────────────────────────────────────────────────────────

/**
 * 将 ASCII/UTF-8 字节数组转换为 String（Lottie JSON 专用）
 *
 * 处理策略：遍历字节，仅转换 ASCII 范围（0-127）；非 ASCII 用 '?' 替代。
 * Lottie JSON 的键名和数值字段均为 ASCII，'?' 替代不影响元数据解析。
 */
private func lottieJsonBytesToString(bytes: Array<Byte>): String {
    if (bytes.size == 0) {
        return ""
    }
    var result: String = ""
    var i: Int64 = 0
    while (i < bytes.size) {
        let b = bytes[i]
        let code = UInt32(b)
        if (code < 128) {
            result = result + Rune(code).toString()
        } else {
            result = result + "?"
        }
        i = i + 1
    }
    return result
}

/**
 * 从 Lottie JSON 字符串中提取指定数值字段的值
 *
 * 仅提取顶层数值字段，格式：
 *   ... "key": 123.45 ...  or  ... "key":123 ...
 *
 * 实现策略：
 *   1. 搜索 `"key":` 模式（包含可选空白）
 *   2. 跳过空白，读取数字字符（包含 '-', '.', 'e', 'E'）
 *   3. 转换为 Float64
 *
 * 此函数专用于 Lottie JSON 顶层字段提取，不处理嵌套对象。
 */
private func lottieExtractNumberField(json: String, key: String): Float64 {
    let pattern = "\"" + key + "\":"
    let runes = json.toRuneArray()
    let patRunes = pattern.toRuneArray()

    if (patRunes.size == 0 || runes.size == 0) {
        return 0.0
    }

    var i: Int64 = 0
    while (i <= runes.size - patRunes.size) {
        // 检查 pattern 是否从位置 i 开始匹配
        var matched = true
        var pi: Int64 = 0
        while (pi < patRunes.size) {
            if (UInt32(runes[i + pi]) != UInt32(patRunes[pi])) {
                matched = false
                break
            }
            pi = pi + 1
        }

        if (matched) {
            // 找到 key，跳过已匹配的模式字符，跳过空白
            var j = i + patRunes.size
            while (j < runes.size) {
                let code = UInt32(runes[j])
                if (code != 32 && code != 9 && code != 10 && code != 13) {
                    break
                }
                j = j + 1
            }
            // 读取数字串（包含 '-', '.', 'e', 'E', '+'）
            var numStr: String = ""
            while (j < runes.size) {
                let code = UInt32(runes[j])
                if ((code >= 48 && code <= 57) || code == 45 || code == 46 ||
                    code == 101 || code == 69 || code == 43) {
                    numStr = numStr + Rune(code).toString()
                    j = j + 1
                } else {
                    break
                }
            }
            if (numStr.size > 0) {
                return lottieParseFloat(numStr)
            }
            return 0.0
        }
        i = i + 1
    }
    return 0.0
}

/**
 * 从 Lottie JSON 字符串中提取指定字符串字段的值
 *
 * 提取格式：`"key":"value"` 或 `"key": "value"`
 */
private func lottieExtractStringField(json: String, key: String): String {
    let pattern = "\"" + key + "\":"
    let runes = json.toRuneArray()
    let patRunes = pattern.toRuneArray()

    if (patRunes.size == 0 || runes.size == 0) {
        return ""
    }

    var i: Int64 = 0
    while (i <= runes.size - patRunes.size) {
        var matched = true
        var pi: Int64 = 0
        while (pi < patRunes.size) {
            if (UInt32(runes[i + pi]) != UInt32(patRunes[pi])) {
                matched = false
                break
            }
            pi = pi + 1
        }

        if (matched) {
            var j = i + patRunes.size
            // 跳过空白
            while (j < runes.size) {
                let code = UInt32(runes[j])
                if (code != 32 && code != 9) { break }
                j = j + 1
            }
            // 期待引号开头
            if (j < runes.size && UInt32(runes[j]) == 34) {
                j = j + 1
                var result: String = ""
                while (j < runes.size) {
                    let code = UInt32(runes[j])
                    if (code == 34) {
                        return result
                    }
                    if (code == 92 && j + 1 < runes.size) {
                        j = j + 1
                    }
                    result = result + Rune(UInt32(runes[j])).toString()
                    j = j + 1
                }
                return result
            }
            return ""
        }
        i = i + 1
    }
    return ""
}

/**
 * 将数字字符串解析为 Float64
 *
 * 支持格式：整数（"512"）、小数（"29.97"）、负数（"-1"）。
 * 不支持科学计数法（Lottie JSON 顶层字段不使用）。
 */
private func lottieParseFloat(s: String): Float64 {
    if (s.size == 0) {
        return 0.0
    }
    let runes = s.toRuneArray()
    var negative = false
    var idx: Int64 = 0

    if (idx < runes.size && UInt32(runes[idx]) == 45) {
        negative = true
        idx = idx + 1
    }

    var intPart: Int64 = 0
    while (idx < runes.size) {
        let code = UInt32(runes[idx])
        if (code >= 48 && code <= 57) {
            intPart = intPart * 10 + Int64(code - 48)
            idx = idx + 1
        } else {
            break
        }
    }

    var fracPart: Float64 = 0.0
    if (idx < runes.size && UInt32(runes[idx]) == 46) {
        idx = idx + 1
        var divisor: Float64 = 10.0
        while (idx < runes.size) {
            let code = UInt32(runes[idx])
            if (code >= 48 && code <= 57) {
                fracPart = fracPart + Float64(code - 48) / divisor
                divisor = divisor * 10.0
                idx = idx + 1
            } else {
                break
            }
        }
    }

    let result = Float64(intPart) + fracPart
    if (negative) {
        return result * -1.0
    }
    return result
}
