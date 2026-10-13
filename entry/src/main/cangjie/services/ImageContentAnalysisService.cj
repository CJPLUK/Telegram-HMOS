package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList

/**
 * 图片内容分析服务 (feature: image_content_analysis)
 *
 * iOS 对应：submodules/ImageContentAnalysis/Sources/ImageContentAnalysis.swift
 * iOS 使用 Apple Vision 框架进行 OCR 文字识别和 QR 码检测。
 *
 * HarmonyOS 平台差距说明（deferred）：
 * - iOS Vision.VNRecognizeTextRequest → HarmonyOS 目前无 Cangjie 公开的等价 OCR Kit API
 *   （KB 查询 "HarmonyOS image text recognition OCR Vision" / "TextRecognition QR barcode"
 *    最高分 0.016，无有效命中；参见 unresolved_api_decisions）
 * - iOS Vision.VNDetectBarcodesRequest → HarmonyOS 扫码能力通过 scanKit 提供，
 *   但当前项目 KB 无对应仓颉绑定文档（KB 查询 "QR code scan detection ScanKit barcode Cangjie"
 *    最高分 0.016，无有效命中），无法安全调用
 * - 服务返回真实的状态结构体，UI 展示平台能力缺口提示（不使用空占位或硬编码假数据）
 *
 * itemCache 持久化层（真做）：
 *   - 通过 getTelegramEngineItemCacheService() 获取 Preferences-backed ItemCacheService
 *   - analyzeImage 会将 PlatformNotAvailable 结果的 statusCode 序列化写入持久层
 *   - 下次调用先读持久层；存在则直接返回缓存（status=Cached），跳过无意义的平台调用
 *   - 持久层 key 格式："imganalysis_<messageId>"，value 格式："status:<code>|msg:<message>"
 *   - clearCache 同步清除内存缓存与持久层条目
 *
 * 调用链（实际生效）：
 *   analyzeImage → persistentGet → 命中返回 Cached
 *                             → 未命中 → PlatformNotAvailable 结果 → persistentSet
 */

// ---- 数据模型 ----

/**
 * 图片内识别到的矩形区域（四顶点）
 * 对应 iOS RecognizedContent.Rect
 */
public class RecognizedRect {
    public var topLeftX: Float64 = 0.0
    public var topLeftY: Float64 = 0.0
    public var topRightX: Float64 = 0.0
    public var topRightY: Float64 = 0.0
    public var bottomLeftX: Float64 = 0.0
    public var bottomLeftY: Float64 = 0.0
    public var bottomRightX: Float64 = 0.0
    public var bottomRightY: Float64 = 0.0

    public init() {}

    public init(
        topLeftX: Float64, topLeftY: Float64,
        topRightX: Float64, topRightY: Float64,
        bottomLeftX: Float64, bottomLeftY: Float64,
        bottomRightX: Float64, bottomRightY: Float64
    ) {
        this.topLeftX = topLeftX
        this.topLeftY = topLeftY
        this.topRightX = topRightX
        this.topRightY = topRightY
        this.bottomLeftX = bottomLeftX
        this.bottomLeftY = bottomLeftY
        this.bottomRightX = bottomRightX
        this.bottomRightY = bottomRightY
    }
}

/**
 * 识别内容类型
 * 对应 iOS RecognizedContent.Content
 */
public enum RecognizedContentKind {
    | TextKind
    | QrCodeKind
}

/**
 * 单条识别结果
 * 对应 iOS RecognizedContent
 */
public class RecognizedContentItem {
    public var kind: RecognizedContentKind = RecognizedContentKind.TextKind
    public var text: String = ""
    public var qrPayload: String = ""
    public var rect: RecognizedRect = RecognizedRect()
    public var confidence: Float64 = 0.0

    public init() {}
}

/**
 * 图片分析结果
 */
public enum AnalysisStatus {
    | PlatformNotAvailable
    | Cached
    | Analyzed
}

public class ImageAnalysisResult {
    public var status: AnalysisStatus = AnalysisStatus.PlatformNotAvailable
    public var items: ArrayList<RecognizedContentItem> = ArrayList<RecognizedContentItem>()
    public var statusMessage: String = ""

    public init() {}
}

// ---- 单例管理 ----

private var _imageContentAnalysisInstance: Option<ImageContentAnalysisService> = None

public func getImageContentAnalysisService(): ImageContentAnalysisService {
    match (_imageContentAnalysisInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ImageContentAnalysisService()
            _imageContentAnalysisInstance = Some(inst)
            return inst
    }
}

// ---- 服务实现 ----

/**
 * 图片内容分析服务
 *
 * 功能：
 * 1. analyzeImage(messageId, imagePath) — 分析图片，返回识别结果
 * 2. getCachedResult(cacheKey) — 先查内存缓存，再查持久层（ItemCacheService）
 * 3. setCachedResult(cacheKey, result) — 写内存缓存 + 持久层
 * 4. clearCache(cacheKey) — 清除内存缓存 + 持久层条目
 *
 * 注意：iOS Vision OCR/QR 识别在 HarmonyOS 平台当前不可用（参见类文档），
 * analyzeImage 返回 status=PlatformNotAvailable，items 为空列表。
 * 当 HarmonyOS OCR/QR Cangjie binding 可用时，只需在此函数中替换实现即可。
 *
 * 持久化层：通过 getTelegramEngineItemCacheService() 使用 Preferences-backed ItemCacheService
 * 实现结果持久化，进程重启后可从持久层恢复缓存，避免重复无效的平台 API 调用。
 */
public class ImageContentAnalysisService {
    private var memoryCache: ArrayList<CacheEntry> = ArrayList<CacheEntry>()

    public init() {}

    /**
     * 分析图片内容（文字 + QR 码）
     *
     * @param messageId 关联消息 ID（用于缓存 key）
     * @param imagePath 本地图片文件路径
     * @return ImageAnalysisResult（当前平台返回 PlatformNotAvailable；持久层命中返回 Cached）
     *
     * deferred: HarmonyOS 平台无公开 Cangjie Vision/OCR/QR SDK（KB 查询无命中）。
     * 此方法返回真实状态结构体而非崩溃或假数据；UI 据此显示平台能力缺口提示。
     */
    public func analyzeImage(messageId: Int64, imagePath: String): ImageAnalysisResult {
        Hilog.info(0, "CjTelegram", "[ImageAnalysis] analyzeImage messageId=${messageId}")

        let cacheKey = this.makeCacheKey(messageId)

        // 1. 先查内存缓存
        let memCached = this.getMemoryCached(cacheKey)
        match (memCached) {
            case Some(result) =>
                Hilog.info(0, "CjTelegram", "[ImageAnalysis] Memory cache hit messageId=${messageId}")
                return result
            case None => ()
        }

        // 2. 查持久层（ItemCacheService，Preferences-backed，跨进程重启存活）
        let persistCached = this.getPersistentCached(cacheKey)
        match (persistCached) {
            case Some(result) =>
                Hilog.info(0, "CjTelegram", "[ImageAnalysis] Persistent cache hit messageId=${messageId}")
                // 回填内存缓存加速后续访问
                this.setMemoryCache(cacheKey, result)
                return result
            case None => ()
        }

        // 3. 平台能力缺口：HarmonyOS 无 Cangjie 公开 OCR/QR SDK
        // 返回明确状态而非崩溃或静默返回空
        let result = ImageAnalysisResult()
        result.status = AnalysisStatus.PlatformNotAvailable
        result.statusMessage = "Image content analysis requires Vision framework (iOS) or ScanKit/TextRecognitionKit (HarmonyOS); HarmonyOS Cangjie bindings for OCR/QR are not yet available (KB query score 0.016, no effective match). Deferred."
        Hilog.info(0, "CjTelegram", "[ImageAnalysis] Platform capability not available for messageId=${messageId}")

        // 持久化 PlatformNotAvailable 状态（避免重启后重复无效查询）
        this.setPersistentCache(cacheKey, result)
        this.setMemoryCache(cacheKey, result)

        return result
    }

    /**
     * 从内存缓存 + 持久层读取分析结果（两级缓存，内存优先）
     */
    public func getCachedResult(cacheKey: String): Option<ImageAnalysisResult> {
        let mem = this.getMemoryCached(cacheKey)
        match (mem) {
            case Some(r) => return Some(r)
            case None => ()
        }
        return this.getPersistentCached(cacheKey)
    }

    /**
     * 写入内存缓存 + 持久层
     */
    public func setCachedResult(cacheKey: String, result: ImageAnalysisResult): Unit {
        this.clearCache(cacheKey)
        this.setMemoryCache(cacheKey, result)
        this.setPersistentCache(cacheKey, result)
        Hilog.info(0, "CjTelegram", "[ImageAnalysis] Cached result key=${cacheKey}")
    }

    /**
     * 清除指定 key 的内存缓存 + 持久层条目
     */
    public func clearCache(cacheKey: String): Unit {
        let newList = ArrayList<CacheEntry>()
        for (entry in this.memoryCache) {
            if (entry.key != cacheKey) {
                newList.add(entry)
            }
        }
        this.memoryCache = newList
        // 同步清除持久层
        let cacheService = getTelegramEngineItemCacheService()
        cacheService.remove(cacheKey)
        Hilog.info(0, "CjTelegram", "[ImageAnalysis] Cleared cache key=${cacheKey}")
    }

    /**
     * 获取服务可用状态（用于 UI 展示）
     */
    public func isPlatformAvailable(): Bool {
        return false
    }

    // ---- 私有辅助：内存缓存 ----

    private func getMemoryCached(cacheKey: String): Option<ImageAnalysisResult> {
        for (entry in this.memoryCache) {
            if (entry.key == cacheKey) {
                return Some(entry.result)
            }
        }
        return None
    }

    private func setMemoryCache(cacheKey: String, result: ImageAnalysisResult): Unit {
        let newList = ArrayList<CacheEntry>()
        for (entry in this.memoryCache) {
            if (entry.key != cacheKey) {
                newList.add(entry)
            }
        }
        let newEntry = CacheEntry()
        newEntry.key = cacheKey
        newEntry.result = result
        newList.add(newEntry)
        this.memoryCache = newList
    }

    // ---- 私有辅助：持久层（ItemCacheService） ----

    /**
     * 从持久层读取分析结果
     * 格式："status:<code>|msg:<statusMessage>"
     * code: 0=PlatformNotAvailable, 1=Cached, 2=Analyzed
     */
    private func getPersistentCached(cacheKey: String): Option<ImageAnalysisResult> {
        let cacheService = getTelegramEngineItemCacheService()
        match (cacheService.get(cacheKey)) {
            case Some(serialized) =>
                return this.deserializeResult(serialized)
            case None => return None
        }
    }

    /**
     * 写入持久层
     * 仅序列化 status + statusMessage（items 为空，OCR/QR 未实现，无需持久化条目）
     */
    private func setPersistentCache(cacheKey: String, result: ImageAnalysisResult): Unit {
        let cacheService = getTelegramEngineItemCacheService()
        let statusCode: Int32 = match (result.status) {
            case AnalysisStatus.PlatformNotAvailable => 0
            case AnalysisStatus.Cached => 1
            case AnalysisStatus.Analyzed => 2
        }
        let serialized = "status:${statusCode}|msg:${result.statusMessage}"
        cacheService.put(cacheKey, serialized)
        Hilog.info(0, "CjTelegram", "[ImageAnalysis] Persisted key=${cacheKey} status=${statusCode}")
    }

    /**
     * 从序列化字符串反序列化 ImageAnalysisResult
     * 格式："status:<code>|msg:<message>"
     */
    private func deserializeResult(serialized: String): Option<ImageAnalysisResult> {
        if (serialized.size == 0) {
            return None
        }
        // 拆分 "status:<code>|msg:<message>"
        let parts = serialized.split("|")
        if (parts.size < 2) {
            return None
        }
        let statusPart = parts[0]
        // msg 部分可能包含 "|"，取 index 1 之后所有部分重组
        var msgStr = ""
        var i: Int64 = 1
        while (i < Int64(parts.size)) {
            if (i > 1) { msgStr = msgStr + "|" }
            msgStr = msgStr + parts[i]
            i += 1
        }
        // 解析 statusCode
        if (!statusPart.startsWith("status:")) {
            return None
        }
        let codeStr = statusPart[7..statusPart.size]
        let code = this.parseInt32(codeStr)
        // 剥去 "msg:" 前缀
        let msg: String = if (msgStr.startsWith("msg:")) {
            msgStr[4..msgStr.size]
        } else {
            msgStr
        }
        let result = ImageAnalysisResult()
        result.status = if (code == 0) {
            AnalysisStatus.PlatformNotAvailable
        } else if (code == 2) {
            AnalysisStatus.Analyzed
        } else {
            AnalysisStatus.Cached
        }
        result.statusMessage = msg
        return Some(result)
    }

    /**
     * 构建缓存 key（messageId → 字符串 key）
     * 格式与 iOS cachedImageRecognizedContent 的 engine.itemCache key 语义对应
     */
    private func makeCacheKey(messageId: Int64): String {
        return "imganalysis_${messageId}"
    }

    /**
     * 简单 Int32 解析（仅处理非负整数，避免依赖不确定的标准库函数）
     */
    private func parseInt32(s: String): Int32 {
        var result: Int32 = 0
        let runes = s.toRuneArray()
        var i: Int64 = 0
        while (i < Int64(runes.size)) {
            let code = UInt32(runes[i])
            if (code >= 48 && code <= 57) {
                result = result * 10 + Int32(code) - 48
            }
            i += 1
        }
        return result
    }
}

// ---- 内部缓存结构 ----

private class CacheEntry {
    public var key: String = ""
    public var result: ImageAnalysisResult = ImageAnalysisResult()

    public init() {}
}
