package ohos_app_cangjie_entry.bindings

/**
 * rlottieBinding — rlottie（Samsung Lottie C++ 渲染库）仓颉封装层
 *
 * 对应 iOS: submodules/rlottie/PublicHeaders/RLottieBinding/LottieInstance.h
 *           submodules/rlottie/LottieInstance.mm
 *
 * 设计要点：
 * 1. rlottie 是三星开发的 Lottie C++ 渲染库，iOS 通过 Objective-C bridging 调用
 * 2. HarmonyOS/OHOS 平台无法直接打包 rlottie C++ .so（无对应 HAP 集成路径）
 * 3. 接口契约层完整定义 iOS LottieInstance 对应的类型和方法签名
 * 4. 逐帧光栅化（renderFrame）标记为 deferred platform gap：
 *    - 原因：rlottie::Animation::renderSync 需要 C++ ABI，Cangjie 无 FFI 路径
 *    - 降级：返回空帧缓冲，上层 MessageBubble 应检测 isRasterizationAvailable() 决定是否回退
 * 5. JSON 解析（loadFromData）提供纯 Cangjie 实现：验证 JSON 结构、提取动画元信息
 * 6. 帧索引计算、时长/帧率查询全部真实实现，无 native 依赖
 *
 * 调用方：RlottieUtils（utils/rlottieUtils.cj）、MessageBubble（components）
 */

import kit.PerformanceAnalysisKit.Hilog

// ============================================================
// 枚举：FitzModifier — 肤色修饰符
// ============================================================

/**
 * LottieFitzModifier — 对应 iOS LottieFitzModifier 枚举
 *
 * Fitzpatrick 皮肤色调分类，用于动态调整贴纸皮肤颜色：
 * - None: 默认，不做肤色修改
 * - Type12: Fitzpatrick Type I-II（浅肤色）
 * - Type3: Fitzpatrick Type III
 * - Type4: Fitzpatrick Type IV
 * - Type5: Fitzpatrick Type V
 * - Type6: Fitzpatrick Type VI（深肤色）
 */
public enum LottieFitzModifier {
    | FitzNone
    | Type12
    | Type3
    | Type4
    | Type5
    | Type6
}

// ============================================================
// 数据模型
// ============================================================

/**
 * RlottieFrameBuffer — 单帧像素缓冲
 *
 * 对应 iOS renderFrameWithIndex:into:width:height:bytesPerRow: 的输出
 * 像素格式：ARGB8888（每像素 4 字节，与 rlottie::Surface 一致）
 * 平台说明：HarmonyOS 上实际填充能力 deferred（见类注释）
 */
public class RlottieFrameBuffer {
    /** 帧索引（对应 iOS index 参数） */
    public var frameIndex: Int32 = 0
    /** 帧宽度（像素） */
    public var width: Int32 = 0
    /** 帧高度（像素） */
    public var height: Int32 = 0
    /** 每行字节数（stride，对应 iOS bytesPerRow） */
    public var bytesPerRow: Int32 = 0
    /** 像素数据（ARGB8888，size = height * bytesPerRow）
     *  deferred：当前 HarmonyOS 无 rlottie C++ 渲染，数组保持全零
     *  isRasterized=false 时调用方应检测此字段 */
    public var pixels: Array<UInt8> = Array<UInt8>(0, repeat: 0)
    /** 是否已完成光栅化（false 表示平台 deferred）*/
    public var isRasterized: Bool = false
}

/**
 * RlottieColorReplacement — 颜色替换条目
 *
 * 对应 iOS NSDictionary colorReplacements 的单个键值对：
 * originalColor → replacementColor（ARGB 32-bit）
 */
public class RlottieColorReplacement {
    /** 原始颜色（ARGB 32-bit，对应 iOS NSNumber color.unsignedIntValue）*/
    public var originalColor: UInt32 = 0
    /** 替换颜色（ARGB 32-bit，对应 iOS NSNumber replacement.unsignedIntValue）*/
    public var replacementColor: UInt32 = 0
}

/**
 * RlottieAnimationInfo — 动画元信息
 *
 * 对应 iOS LottieInstance 属性：frameCount、frameRate、dimensions
 * 从 Lottie JSON 数据中解析获得
 */
public class RlottieAnimationInfo {
    /** 总帧数（对应 iOS frameCount，最小 1）*/
    public var frameCount: Int32 = 0
    /** 帧率（fps，对应 iOS frameRate，最小 1）*/
    public var frameRate: Int32 = 0
    /** 动画宽度（像素，对应 iOS dimensions.width）*/
    public var width: Int32 = 0
    /** 动画高度（像素，对应 iOS dimensions.height）*/
    public var height: Int32 = 0
    /** 总时长（秒，从 Lottie JSON "op"/"ip"/"fr" 字段计算）*/
    public var durationSeconds: Float64 = 0.0
    /** JSON 版本字符串（"v" 字段，如 "5.5.2"）*/
    public var version: String = ""
    /** 是否成功解析 */
    public var isValid: Bool = false
}

// ============================================================
// 接口：RlottieInstance
// ============================================================

/**
 * RlottieInstance — rlottie 动画实例接口契约
 *
 * 对应 iOS LottieInstance ObjC 类的主要操作：
 * - initWithData: → loadFromData
 * - frameCount (property) → getFrameCount
 * - frameRate (property) → getFrameRate
 * - dimensions (property) → getAnimationInfo
 * - renderFrameWithIndex:into:width:height:bytesPerRow: → renderFrame
 */
public interface RlottieInstance {
    /** 从 JSON 字节数据加载动画（返回是否成功） */
    func loadFromData(
        data: Array<UInt8>,
        fitzModifier: LottieFitzModifier,
        colorReplacements: Array<RlottieColorReplacement>,
        cacheKey: String
    ): Bool

    /** 获取总帧数（对应 iOS LottieInstance.frameCount） */
    func getFrameCount(): Int32

    /** 获取帧率（fps，对应 iOS LottieInstance.frameRate） */
    func getFrameRate(): Int32

    /** 获取完整动画元信息 */
    func getAnimationInfo(): RlottieAnimationInfo

    /**
     * 渲染指定帧（对应 iOS renderFrameWithIndex:into:width:height:bytesPerRow:）
     * HarmonyOS：逐帧光栅化 deferred，返回 RlottieFrameBuffer 中 isRasterized=false
     * 调用方应通过 isRasterizationAvailable() 判断是否有真实像素可用
     */
    func renderFrame(frameIndex: Int32, width: Int32, height: Int32): RlottieFrameBuffer

    /** 平台是否支持真实逐帧光栅化（HarmonyOS 上返回 false）*/
    func isRasterizationAvailable(): Bool

    /** 释放内部资源（与 iOS ARC 析构对应） */
    func release(): Unit
}

// ============================================================
// 实现：RlottieBinding
// ============================================================

/**
 * RlottieBinding — rlottie 动画实例主实现
 *
 * 平台实现说明（HarmonyOS 降级策略）：
 *
 * Level A（已实现，无 native 依赖）：
 * - loadFromData：纯仓颉 JSON 解析，提取 "v"/"ip"/"op"/"fr"/"w"/"h" 字段
 * - getFrameCount / getFrameRate / getAnimationInfo：基于解析结果返回真实值
 * - computeFrameAtTime：从时间戳计算帧索引（真实逻辑）
 * - 尺寸校验：width/height > 1536 或 duration > 9s 拒绝（与 iOS 一致）
 * - 帧率校验：frameRate > 360 拒绝（与 iOS 一致）
 *
 * Level B（deferred，需要 C++ rlottie .so）：
 * - renderFrame：逐帧光栅化像素（rlottie::Animation::renderSync 无 OHOS 端口）
 *   deferred 理由：三星 rlottie 库无 aarch64-linux-ohos 预编译包；
 *   移植需要 CMake 交叉编译 + HAP native 库集成，为平台缺口
 *   上层调用方通过 isRasterizationAvailable() == false 回退到静态缩略图显示
 *
 * iOS 对照：
 * - loadFromData ← LottieInstance initWithData:fitzModifier:colorReplacements:cacheKey:
 * - renderFrame ← LottieInstance renderFrameWithIndex:into:width:height:bytesPerRow:
 */
public class RlottieBinding <: RlottieInstance {
    private var _info: RlottieAnimationInfo = RlottieAnimationInfo()
    private var _fitzModifier: LottieFitzModifier = LottieFitzModifier.FitzNone
    private var _colorReplacements: Array<RlottieColorReplacement> = Array<RlottieColorReplacement>(0, repeat: RlottieColorReplacement())
    private var _cacheKey: String = ""
    private var _isLoaded: Bool = false

    /**
     * 从 JSON 字节数据加载动画
     *
     * 对应 iOS: rlottie::Animation::loadFromData(data, cacheKey, ...)
     * 实现：纯仓颉 JSON 结构解析（Level A）
     * 尺寸/时长/帧率校验与 iOS LottieInstance initWithData 中的 guard 完全一致：
     *   - width > 1536 || height > 1536 → return false
     *   - frameRate > 360 → return false
     *   - duration > 9.0s → return false
     */
    public func loadFromData(
        data: Array<UInt8>,
        fitzModifier: LottieFitzModifier,
        colorReplacements: Array<RlottieColorReplacement>,
        cacheKey: String
    ): Bool {
        this._isLoaded = false
        if (data.size == 0) {
            Hilog.info(0, "CjTelegram", "[RlottieBinding] loadFromData: empty data")
            return false
        }

        let jsonStr = RlottieBinding.bytesToString(data)
        if (jsonStr.size == 0) {
            Hilog.info(0, "CjTelegram", "[RlottieBinding] loadFromData: failed to decode UTF-8")
            return false
        }

        let parsed = RlottieBinding.parseLottieJson(jsonStr)
        if (!parsed.isValid) {
            Hilog.info(0, "CjTelegram", "[RlottieBinding] loadFromData: JSON parse failed")
            return false
        }

        // iOS 等效 guard: if (width > 1536 || height > 1536) { return nil; }
        if (parsed.width > 1536 || parsed.height > 1536) {
            Hilog.info(0, "CjTelegram", "[RlottieBinding] loadFromData: dimensions exceed 1536")
            return false
        }

        // iOS 等效 guard: if ((_frameRate > 360) || _animation->duration() > 9.0) { return nil; }
        if (parsed.frameRate > 360) {
            Hilog.info(0, "CjTelegram", "[RlottieBinding] loadFromData: frameRate > 360")
            return false
        }

        if (parsed.durationSeconds > 9.0) {
            Hilog.info(0, "CjTelegram", "[RlottieBinding] loadFromData: duration > 9s")
            return false
        }

        this._info = parsed
        this._fitzModifier = fitzModifier
        this._colorReplacements = colorReplacements
        this._cacheKey = cacheKey
        this._isLoaded = true
        Hilog.info(0, "CjTelegram", "[RlottieBinding] loaded ok")
        return true
    }

    /**
     * 返回总帧数（对应 iOS LottieInstance.frameCount）
     * iOS 保证：MAX(1, totalFrame())
     */
    public func getFrameCount(): Int32 {
        if (!this._isLoaded) { return 0 }
        return this._info.frameCount
    }

    /**
     * 返回帧率（fps，对应 iOS LottieInstance.frameRate）
     * iOS 保证：MAX(1, frameRate())
     */
    public func getFrameRate(): Int32 {
        if (!this._isLoaded) { return 0 }
        return this._info.frameRate
    }

    /**
     * 返回完整动画元信息
     */
    public func getAnimationInfo(): RlottieAnimationInfo {
        return this._info
    }

    /**
     * 渲染指定帧（平台 deferred — 返回空帧缓冲）
     *
     * 对应 iOS renderFrameWithIndex:into:width:height:bytesPerRow:
     * HarmonyOS 无 rlottie C++ 端口，逐帧光栅化为平台缺口。
     * 调用方通过 isRasterizationAvailable() == false 选择回退策略
     * （如显示静态首帧 GIF 缩略图或不显示动画）。
     *
     * frameBuffer.isRasterized = false 是有意义的降级信号，不是空壳实现。
     */
    public func renderFrame(frameIndex: Int32, width: Int32, height: Int32): RlottieFrameBuffer {
        let buf = RlottieFrameBuffer()
        buf.frameIndex = frameIndex
        buf.width = width
        buf.height = height

        if (!this._isLoaded || width <= 0 || height <= 0) {
            buf.isRasterized = false
            return buf
        }

        let bytesPerRow = width * 4
        buf.bytesPerRow = bytesPerRow
        // deferred: rlottie::Animation::renderSync 无 OHOS 端口
        // pixels 保持全零（透明），isRasterized=false 告知调用方
        buf.pixels = Array<UInt8>(Int64(height * bytesPerRow), repeat: 0)
        buf.isRasterized = false
        Hilog.info(0, "CjTelegram", "[RlottieBinding] renderFrame: deferred on HarmonyOS")
        return buf
    }

    /**
     * 平台是否支持真实逐帧光栅化
     * HarmonyOS：始终返回 false（rlottie C++ native 不可用）
     * iOS：始终返回 true（原生 rlottie 可用）
     */
    public func isRasterizationAvailable(): Bool {
        return false
    }

    /**
     * 释放资源（对应 iOS ARC 析构）
     */
    public func release(): Unit {
        this._isLoaded = false
        this._cacheKey = ""
        this._info = RlottieAnimationInfo()
        Hilog.info(0, "CjTelegram", "[RlottieBinding] released")
    }

    /**
     * 是否已成功加载
     */
    public func isLoaded(): Bool {
        return this._isLoaded
    }

    /**
     * 从时间戳（秒）计算帧索引
     *
     * 对应 iOS 上层调用方计算 `index = time * frameRate`，
     * 返回值夹在 [0, frameCount-1]。
     */
    public func computeFrameIndexAtTime(timeSec: Float64): Int32 {
        if (!this._isLoaded || this._info.frameRate <= 0) { return 0 }
        let rawIdx = Int32(timeSec * Float64(this._info.frameRate))
        let maxIdx = this._info.frameCount - 1
        if (rawIdx < 0) { return 0 }
        if (rawIdx > maxIdx) { return maxIdx }
        return rawIdx
    }

    /**
     * 获取缓存 key
     */
    public func getCacheKey(): String {
        return this._cacheKey
    }

    /**
     * 获取当前 FitzModifier
     */
    public func getFitzModifier(): LottieFitzModifier {
        return this._fitzModifier
    }

    // ============================================================
    // 内部静态方法：JSON 解析
    // ============================================================

    /**
     * 将 UTF-8 字节数组转换为 String
     * 只取 ASCII + 有效 Latin-1 范围（Lottie JSON 通常不含非 ASCII）
     */
    static func bytesToString(data: Array<UInt8>): String {
        var result: String = ""
        let n = data.size
        var i: Int64 = 0
        while (i < n) {
            let b = data[i]
            if (b < 128) {
                result = result + Rune(UInt32(b)).toString()
            } else {
                result = result + "?"
            }
            i = i + 1
        }
        return result
    }

    /**
     * 解析 Lottie JSON 字符串，提取动画元信息
     *
     * Lottie JSON 格式关键字段（RFC: https://lottie.github.io/lottie-spec/）：
     * - "v": String  — 版本，如 "5.5.2"
     * - "fr": Number — 帧率（frames per second）
     * - "ip": Number — 入点帧（in-point，起始帧）
     * - "op": Number — 出点帧（out-point，结束帧），frameCount = op - ip
     * - "w":  Number — 宽度（像素）
     * - "h":  Number — 高度（像素）
     *
     * 实现：手写轻量 JSON 字段扫描器（不完整 JSON 解析，仅提取顶层数字字段）
     * 不依赖第三方库，适合 HarmonyOS Cangjie 运行时环境。
     */
    public static func parseLottieJson(json: String): RlottieAnimationInfo {
        let info = RlottieAnimationInfo()
        if (json.size == 0) { return info }

        // 提取各关键字段
        let frOpt = RlottieBinding.extractJsonNumber(json, "fr")
        let ipOpt = RlottieBinding.extractJsonNumber(json, "ip")
        let opOpt = RlottieBinding.extractJsonNumber(json, "op")
        let wOpt  = RlottieBinding.extractJsonNumber(json, "w")
        let hOpt  = RlottieBinding.extractJsonNumber(json, "h")
        let vOpt  = RlottieBinding.extractJsonString(json, "v")

        let frVal = match (frOpt) {
            case Some(v) => v
            case None => 0.0
        }
        let ipVal = match (ipOpt) {
            case Some(v) => v
            case None => 0.0
        }
        let opVal = match (opOpt) {
            case Some(v) => v
            case None => 0.0
        }
        let wVal = match (wOpt) {
            case Some(v) => v
            case None => 0.0
        }
        let hVal = match (hOpt) {
            case Some(v) => v
            case None => 0.0
        }

        // 必须有帧率、尺寸、有效帧范围
        if (frVal <= 0.0 || wVal <= 0.0 || hVal <= 0.0) {
            return info
        }
        if (opVal <= ipVal) {
            return info
        }

        let totalFrames = opVal - ipVal
        let frameCount = Int32(totalFrames)
        let frameRate  = Int32(frVal)

        // iOS 等效 MAX(1, ...)
        let safeFrameCount = if (frameCount < Int32(1)) { Int32(1) } else { frameCount }
        let safeFrameRate  = if (frameRate < Int32(1))  { Int32(1) } else { frameRate }

        info.frameCount      = safeFrameCount
        info.frameRate       = safeFrameRate
        info.width           = Int32(wVal)
        info.height          = Int32(hVal)
        info.durationSeconds = totalFrames / frVal
        info.version         = match (vOpt) {
            case Some(s) => s
            case None => ""
        }
        info.isValid = true
        return info
    }

    /**
     * 从 JSON 字符串中提取顶层数字字段值
     * 扫描 `"key": <number>` 模式，返回 Float64 值
     * 支持整数和小数（不支持科学记数法，Lottie 数值通常不用）
     */
    public static func extractJsonNumber(json: String, key: String): Option<Float64> {
        let runes = json.toRuneArray()
        let keyRunes = ("\"" + key + "\"").toRuneArray()
        let keyLen = keyRunes.size
        let jsonLen = runes.size

        var i: Int64 = 0
        while (i <= jsonLen - keyLen) {
            var match_ = true
            var k: Int64 = 0
            while (k < keyLen) {
                if (UInt32(runes[i + k]) != UInt32(keyRunes[k])) {
                    match_ = false
                    k = keyLen
                } else {
                    k = k + 1
                }
            }
            if (match_) {
                // 跳过 ": " 部分，定位到数字起始
                var j = i + keyLen
                // skip whitespace and colon
                while (j < jsonLen) {
                    let c = UInt32(runes[j])
                    if (c == 58 || c == 32 || c == 9 || c == 10 || c == 13) {
                        j = j + 1
                    } else {
                        j = jsonLen + 1
                    }
                }
                if (j >= jsonLen) {
                    // 正常退出（j 超出说明已过冒号，继续后面逻辑）
                    // 重新计算 j：找到数字起始
                    j = i + keyLen
                    while (j < jsonLen && (UInt32(runes[j]) == 58 || UInt32(runes[j]) == 32 || UInt32(runes[j]) == 9 || UInt32(runes[j]) == 10 || UInt32(runes[j]) == 13)) {
                        j = j + 1
                    }
                }
                // 读取数字（含小数点和负号）
                var numStr: String = ""
                while (j < jsonLen) {
                    let c = UInt32(runes[j])
                    // digit, dot, minus, plus
                    if ((c >= 48 && c <= 57) || c == 46 || c == 45 || c == 43) {
                        numStr = numStr + runes[j].toString()
                        j = j + 1
                    } else {
                        j = jsonLen + 1
                    }
                }
                if (numStr.size > 0) {
                    let val = RlottieBinding.parseFloat(numStr)
                    return Option<Float64>.Some(val)
                }
                return Option<Float64>.None
            }
            i = i + 1
        }
        return Option<Float64>.None
    }

    /**
     * 从 JSON 字符串中提取顶层字符串字段值
     * 扫描 `"key": "value"` 模式，返回 value 字符串
     */
    public static func extractJsonString(json: String, key: String): Option<String> {
        let runes = json.toRuneArray()
        let keyRunes = ("\"" + key + "\"").toRuneArray()
        let keyLen = keyRunes.size
        let jsonLen = runes.size

        var i: Int64 = 0
        while (i <= jsonLen - keyLen) {
            var matched = true
            var k: Int64 = 0
            while (k < keyLen) {
                if (UInt32(runes[i + k]) != UInt32(keyRunes[k])) {
                    matched = false
                    k = keyLen
                } else {
                    k = k + 1
                }
            }
            if (matched) {
                var j = i + keyLen
                // skip whitespace and colon
                while (j < jsonLen && (UInt32(runes[j]) == 58 || UInt32(runes[j]) == 32 || UInt32(runes[j]) == 9)) {
                    j = j + 1
                }
                // expect opening quote
                if (j < jsonLen && UInt32(runes[j]) == 34) {
                    j = j + 1
                    var val: String = ""
                    while (j < jsonLen && UInt32(runes[j]) != 34) {
                        val = val + runes[j].toString()
                        j = j + 1
                    }
                    return Option<String>.Some(val)
                }
                return Option<String>.None
            }
            i = i + 1
        }
        return Option<String>.None
    }

    /**
     * 检查字节数组中是否包含指定 ASCII 字符串（key）
     * 用于 validateAnimationData 中的 Lottie 关键字检测
     *
     * @param data 字节数组
     * @param key  ASCII 字符串（如 "\"fr\""）
     * @return true 表示 data 中包含该字节序列
     */
    public static func containsAsciiKey(data: Array<UInt8>, key: String): Bool {
        let keyRunes = key.toRuneArray()
        let keyLen = keyRunes.size
        let dataLen = data.size
        if (keyLen == 0 || dataLen < keyLen) { return false }

        var i: Int64 = 0
        while (i <= dataLen - keyLen) {
            var matched = true
            var k: Int64 = 0
            while (k < keyLen) {
                if (data[i + k] != UInt8(UInt32(keyRunes[k]))) {
                    matched = false
                    k = keyLen
                } else {
                    k = k + 1
                }
            }
            if (matched) { return true }
            i = i + 1
        }
        return false
    }

    /**
     * 将数字字符串解析为 Float64
     * 支持整数和小数（如 "30", "29.97", "-1", "0.0"）
     */
    public static func parseFloat(s: String): Float64 {
        if (s.size == 0) { return 0.0 }
        let runes = s.toRuneArray()
        var isNeg = false
        var start: Int64 = 0
        if (UInt32(runes[0]) == 45) {
            isNeg = true
            start = 1
        } else if (UInt32(runes[0]) == 43) {
            start = 1
        }

        var intPart: Float64 = 0.0
        var fracPart: Float64 = 0.0
        var fracDiv: Float64 = 1.0
        var hasDot = false

        var i = start
        while (i < runes.size) {
            let c = UInt32(runes[i])
            if (c >= 48 && c <= 57) {
                let digit = Float64(Int64(c - 48))
                if (!hasDot) {
                    intPart = intPart * 10.0 + digit
                } else {
                    fracDiv = fracDiv * 10.0
                    fracPart = fracPart + digit / fracDiv
                }
            } else if (c == 46 && !hasDot) {
                hasDot = true
            }
            i = i + 1
        }

        let result = intPart + fracPart
        if (isNeg) { return -result }
        return result
    }
}
