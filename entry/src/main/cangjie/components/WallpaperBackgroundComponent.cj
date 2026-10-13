package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.utils.safeAnimateTo

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.arkui.ui_context.*
import kit.PerformanceAnalysisKit.Hilog
import kit.ImageKit.{createImageSource, ImageSource, DecodingOptions, PixelMap, createPixelMap, InitializationOptions, PixelMapFormat}
import kit.ImageKit.Size as IKSize
import std.time.*
import std.sync.*
import std.math.sqrt
import std.collection.{HashMap, HashSet}
import ohos_app_cangjie_entry.services.{
    WallpaperType,
    WallpaperInfo,
    WallpaperImageDisplayMode,
    GradientPoint,
    gradientPositionsForPhase,
    gradientComputePixel,
    computeDimmingOpacity,
    getSharedGradientPhase,
    getGlobalAbilityContext
}

/**
 * WallpaperBackgroundComponent — 壁纸背景组件
 *
 * P2-386: 多点动态渐变 (4色控制点 + 8步phase位置移动 + animateEvent流动)
 * P2-388: 图案壁纸+着色 (pattern位图叠加层 + patternColor tint + softlight混合)
 * P2-390: 暗化叠层 (intensity黑层opacity + 仅深色外观启用)
 *
 * 渲染结构（对位 iOS：GradientBackgroundNode.contentView 是 UIImageView，pattern 是
 * WallpaperBackgroundNode.patternImageLayer，都是「位图 + 图像视图」，不是逐帧画布）：
 *   - 渐变层：80×80 渐变位图（SoftwareGradientBackground.swift:375 `size.fitted(80×80)`，按
 *     (colors, phase) 缓存，对位 :365 backgroundImageHash）交给 `Image(PixelMap)` objectFit Fill +
 *     插值放大（对位 :309/:455 UIImageView 线性放大）。
 *   - 图案层：按 (uri, 目标像素尺寸) 在解码阶段缩放一次、缓存，`Image(PixelMap)` 以 intensity 为
 *     opacity 叠加（对位 WallpaperBackgroundNode.swift:1435-1443 compositionOpacity）。内建图案
 *     objectFit Cover（对位 renderPreparedImageWithSymbol aspect-fill 居中），云端缩略图 Fill。
 *   - 反相（intensity < 0，:1451-1459）：黑色宿主 + 「渐变透过图案 alpha 蒙版、整体降到 |intensity|」
 *     的内容层。本平台 ArkUI 组件无 blendMode，因此这一层是后台线程预合成的 premultiplied 位图
 *     （按 key 缓存，分辨率封顶），`Image(PixelMap)` 直接显示。
 *   曾经的实现是 Canvas 逐格 fillRect / drawImage：Canvas 在 Hybrid 页面首次布局轮次里创建时
 *   onReady 不以真实尺寸回调、onReady 之前的绘制被静默丢弃，会话页背景因此空白；且 6400 次
 *   fillRect 让壁纸库同帧 25 格重画阻塞主线程 >6s（THREAD_BLOCK_6S）。现在没有任何画布：尺寸只
 *   从根节点 onAreaChange 取，退化尺寸（≤1）不做任何解码 / 合成。
 *
 * 渐变算法: 对应 iOS SoftwareGradientBackground.generateGradient()
 *   - 控制点: GradientBackgroundNode.basePositions 8点, 每步取偶数4点
 *   - Swirl扭曲: swirlFactor=0.35*centerDist, theta=sf²*0.8*8
 *   - 距离权重: dist = max(0, 0.92-dist)³
 *
 * animateEvent (P2-386 / TC-0412):
 *   - 相位推进权在触发方（ChatRoomPage.advanceChatGradientPhase）
 *   - triggerPhaseAnimation() 只驱动 @State phaseProgress，不再自己 advanceSharedGradientPhase
 */

private let BUNDLED_DEFAULT_PATTERN_URI = "bundle://wallpaper_pattern_dots"

// 所有模块级缓存共用一把锁：渐变位图 / 图案位图在主线程取，反相合成在后台线程产出并写回。
private let _wallpaperCacheMonitor: Monitor = Monitor()

// ────── 渐变 80×80 位图缓存 ──────
private let GRADIENT_TILE_SIZE: Int64 = 80
private let GRADIENT_PIXEL_MAP_CACHE_LIMIT: Int64 = 48
private let _gradientTileBytesCache: HashMap<String, Array<UInt8>> = HashMap<String, Array<UInt8>>()
private let _gradientPixelMapCache: HashMap<String, PixelMap> = HashMap<String, PixelMap>()

func gradientTileCacheKey(colors: Array<UInt32>, phase: Int32): String {
    var key = "p${phase}"
    for (c in colors) {
        key = key + "_${c}"
    }
    return key
}

/** 80×80 BGRA8888 渐变像素（6400 次 gradientComputePixel，纯算术）。 */
private func buildGradientTileBytes(colors: Array<UInt32>, phase: Int32): Array<UInt8> {
    let positions = gradientPositionsForPhase(phase)
    let w = GRADIENT_TILE_SIZE
    let h = GRADIENT_TILE_SIZE
    let bytes = Array<UInt8>(w * h * 4, repeat: 0)
    var offset: Int64 = 0
    for (py in 0..h) {
        let wy = Float64(py) / Float64(h)
        for (px in 0..w) {
            let wx = Float64(px) / Float64(w)
            let argb = gradientComputePixel(wx, wy, colors, positions)
            bytes[offset] = UInt8(argb & 0xFF)
            bytes[offset + 1] = UInt8((argb >> 8) & 0xFF)
            bytes[offset + 2] = UInt8((argb >> 16) & 0xFF)
            bytes[offset + 3] = 0xFF
            offset += 4
        }
    }
    return bytes
}

/** 取 (colors, phase) 的渐变像素字节；未命中生成一次并缓存。任意线程可调。 */
func gradientTileBytes(colors: Array<UInt32>, phase: Int32): Array<UInt8> {
    let key = gradientTileCacheKey(colors, phase)
    synchronized(_wallpaperCacheMonitor) {
        match (_gradientTileBytesCache.get(key)) {
            case Some(cached) => return cached
            case None => ()
        }
    }
    let t0 = DateTime.now().toUnixTimeStamp().toMilliseconds()
    let bytes = buildGradientTileBytes(colors, phase)
    let t1 = DateTime.now().toUnixTimeStamp().toMilliseconds()
    synchronized(_wallpaperCacheMonitor) {
        if (_gradientTileBytesCache.size >= GRADIENT_PIXEL_MAP_CACHE_LIMIT) {
            _gradientTileBytesCache.clear()
        }
        _gradientTileBytesCache[key] = bytes
    }
    Hilog.info(0, "CjTelegram", "[WallpaperBg] gradient tile built phase=${phase} ms=${t1 - t0}")
    return bytes
}

/** 取 (colors, phase) 的 80×80 渐变 PixelMap；Size 为 ImageKit 的 {height, width} 顺序。 */
func gradientTilePixelMap(colors: Array<UInt32>, phase: Int32): PixelMap {
    let key = gradientTileCacheKey(colors, phase)
    synchronized(_wallpaperCacheMonitor) {
        match (_gradientPixelMapCache.get(key)) {
            case Some(cached) => return cached
            case None => ()
        }
    }
    let bytes = gradientTileBytes(colors, phase)
    let pm = createPixelMap(
        bytes,
        InitializationOptions(
            IKSize(Int32(GRADIENT_TILE_SIZE), Int32(GRADIENT_TILE_SIZE)),
            srcPixelFormat: PixelMapFormat.Bgra8888,
            pixelFormat: PixelMapFormat.Bgra8888
        )
    )
    synchronized(_wallpaperCacheMonitor) {
        if (_gradientPixelMapCache.size >= GRADIENT_PIXEL_MAP_CACHE_LIMIT) {
            _gradientPixelMapCache.clear()
        }
        _gradientPixelMapCache[key] = pm
    }
    return pm
}

// ────── 图案位图：按 (uri, 目标像素) 解码缩放缓存 ──────
// 此前按 uri 缓存全尺寸位图（内建图案 1440×2960），且缓存上限 24 项小于壁纸库条目数（~38），
// 不断清空重解码。现在解码阶段就缩放到目标像素（DecodingOptions.desiredSize），字节预算封顶。
private let PATTERN_SCALED_CACHE_BYTES_LIMIT: Int64 = 64 * 1024 * 1024
// 直接显示的图案位图单张上限：覆盖 1080×2340 全屏；更大目标按比例缩小后由 Image 插值放大。
private let PATTERN_MAX_DECODE_PIXELS: Int64 = 2600000
private let _patternScaledCache: HashMap<String, PixelMap> = HashMap<String, PixelMap>()
private var _patternScaledCacheBytes: Int64 = 0
private let _patternSourceSizeCache: HashMap<String, (Int64, Int64)> = HashMap<String, (Int64, Int64)>()

private func openPatternImageSource(uri: String): Option<ImageSource> {
    if (uri.size == 0) {
        return None
    }
    try {
        if (uri == BUNDLED_DEFAULT_PATTERN_URI) {
            match (getGlobalAbilityContext()) {
                case Some(ctx) =>
                    // `wallpaper_pattern_dots.svg` is byte-for-byte the decompressed source
                    // TelegramUI/Resources/fqv01SQemVIBAAAApND8LDRUhRU.tgv document. ImageSource
                    // cannot decode SVG into PixelMap on this runtime, so this media resource is a
                    // deterministic 1440x2960 transparent rasterisation of that exact SVG. It keeps
                    // the complete document geometry instead of scaling a 155x320 server thumbnail.
                    let data = ctx.resourceManager.getMediaByName("wallpaper_pattern_dots_full")
                    return Some(createImageSource(data))
                case None => return None
            }
        }
        let path = if (uri.startsWith("file://")) { uri[7..] } else { uri }
        return Some(createImageSource(path))
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[WallpaperBg] pattern image source open failed uri=${uri}: ${e}")
        return None
    }
}

/** 图案源图像素尺寸 (width, height)；打不开时 None。 */
func patternSourceSize(uri: String): Option<(Int64, Int64)> {
    synchronized(_wallpaperCacheMonitor) {
        match (_patternSourceSizeCache.get(uri)) {
            case Some(cached) => return Some(cached)
            case None => ()
        }
    }
    match (openPatternImageSource(uri)) {
        case Some(source) =>
            try {
                let info = source.getImageInfo()
                let size = (Int64(info.size.width), Int64(info.size.height))
                synchronized(_wallpaperCacheMonitor) {
                    _patternSourceSizeCache[uri] = size
                }
                return Some(size)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[WallpaperBg] pattern getImageInfo failed uri=${uri}: ${e}")
                return None
            }
        case None => return None
    }
}

/** 解码缩放到 pxW×pxH（BGRA8888）的图案位图；命中缓存直接返回。任意线程可调。 */
func loadPatternPixelMapScaled(uri: String, pxW: Int64, pxH: Int64): Option<PixelMap> {
    if (uri.size == 0 || pxW <= 0 || pxH <= 0) {
        return None
    }
    let key = "${uri}|${pxW}x${pxH}"
    synchronized(_wallpaperCacheMonitor) {
        match (_patternScaledCache.get(key)) {
            case Some(cached) => return Some(cached)
            case None => ()
        }
    }
    match (openPatternImageSource(uri)) {
        case Some(source) =>
            try {
                let t0 = DateTime.now().toUnixTimeStamp().toMilliseconds()
                let pm = source.createPixelMap(
                    options: DecodingOptions(
                        desiredSize: IKSize(Int32(pxH), Int32(pxW)),
                        desiredPixelFormat: PixelMapFormat.Bgra8888
                    )
                )
                let got = pm.getImageInfo().size
                let bytes = Int64(got.width) * Int64(got.height) * 4
                var cacheBytes: Int64 = 0
                synchronized(_wallpaperCacheMonitor) {
                    if (_patternScaledCacheBytes + bytes > PATTERN_SCALED_CACHE_BYTES_LIMIT) {
                        _patternScaledCache.clear()
                        _patternScaledCacheBytes = 0
                    }
                    _patternScaledCache[key] = pm
                    _patternScaledCacheBytes += bytes
                    cacheBytes = _patternScaledCacheBytes
                }
                let t1 = DateTime.now().toUnixTimeStamp().toMilliseconds()
                Hilog.info(0, "CjTelegram", "[WallpaperBg] pattern decoded px=${pxW}x${pxH} got=${got.width}x${got.height} ms=${t1 - t0} cacheKB=${cacheBytes / 1024} uri=${uri}")
                return Some(pm)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[WallpaperBg] pattern scaled decode failed uri=${uri} px=${pxW}x${pxH}: ${e}")
                return None
            }
        case None => return None
    }
}

// ────── 反相路径预合成：渐变 × 图案 alpha × |intensity| ──────
// 对位 WallpaperBackgroundNode.swift:1451-1459：黑色宿主、内容 = 渐变透过图案蒙版、整体 alpha
// 降到 |intensity|。本平台组件无 blendMode，后台线程按像素合成一次、按 key 缓存。
// 分辨率封顶 0.4 Mpx（仓颉逐像素循环在本机约 µs 级/像素；全屏 2.6 Mpx 会达秒级）：
// 夜间图案以低 alpha 落在黑底上，Image 插值放大后边缘略软，几何与颜色与源侧一致。
private let COMPOSITE_MAX_PIXELS: Int64 = 400000
private let COMPOSITE_CACHE_BYTES_LIMIT: Int64 = 32 * 1024 * 1024
private let _compositeCache: HashMap<String, PixelMap> = HashMap<String, PixelMap>()
private var _compositeCacheBytes: Int64 = 0
private let _compositeInFlight: HashSet<String> = HashSet<String>()

func maskedCompositeKey(uri: String, colors: Array<UInt32>, phase: Int32, contentAlpha: Float64, pxW: Int64, pxH: Int64): String {
    return "${uri}|${gradientTileCacheKey(colors, phase)}|a${Int64(contentAlpha * 1000.0)}|${pxW}x${pxH}"
}

func getMaskedComposite(key: String): Option<PixelMap> {
    synchronized(_wallpaperCacheMonitor) {
        return _compositeCache.get(key)
    }
}

/**
 * 在调用线程合成 pxW×pxH 的 premultiplied BGRA 位图：渐变（80×80 位图双线性放大）× 图案 alpha
 * （图案按 patW×patH 解码，采样偏移 offX/offY 实现 aspect-fill 居中裁切）× contentAlpha。
 */
private func composeMaskedPixelMap(
    uri: String,
    colors: Array<UInt32>,
    phase: Int32,
    contentAlpha: Float64,
    pxW: Int64,
    pxH: Int64,
    patW: Int64,
    patH: Int64,
    offX: Int64,
    offY: Int64
): Option<PixelMap> {
    let patternOpt = loadPatternPixelMapScaled(uri, patW, patH)
    var pattern: PixelMap
    match (patternOpt) {
        case Some(pm) => pattern = pm
        case None => return None
    }
    try {
        let info = pattern.getImageInfo()
        let gotW = Int64(info.size.width)
        let gotH = Int64(info.size.height)
        let stride = Int64(pattern.getBytesNumberPerRow())
        let pat = Array<UInt8>(Int64(pattern.getPixelBytesNumber()), repeat: 0)
        pattern.readPixelsToBuffer(pat)
        let tile = gradientTileBytes(colors, phase)
        let ts = GRADIENT_TILE_SIZE
        let out = Array<UInt8>(pxW * pxH * 4, repeat: 0)
        var ak = Int64(contentAlpha * 256.0 + 0.5)
        if (ak < 0) { ak = 0 }
        if (ak > 256) { ak = 256 }
        // 预计算采样坐标（定点 8 位权重）
        let xs0 = Array<Int64>(pxW, repeat: 0)
        let xs1 = Array<Int64>(pxW, repeat: 0)
        let xw = Array<Int64>(pxW, repeat: 0)
        for (x in 0..pxW) {
            var fx = (Float64(x) + 0.5) / Float64(pxW) * Float64(ts) - 0.5
            if (fx < 0.0) { fx = 0.0 }
            if (fx > Float64(ts - 1)) { fx = Float64(ts - 1) }
            let x0 = Int64(fx)
            xs0[x] = x0
            xs1[x] = if (x0 + 1 < ts) { x0 + 1 } else { x0 }
            xw[x] = Int64((fx - Float64(x0)) * 256.0)
        }
        var o: Int64 = 0
        for (y in 0..pxH) {
            var fy = (Float64(y) + 0.5) / Float64(pxH) * Float64(ts) - 0.5
            if (fy < 0.0) { fy = 0.0 }
            if (fy > Float64(ts - 1)) { fy = Float64(ts - 1) }
            let y0 = Int64(fy)
            let y1 = if (y0 + 1 < ts) { y0 + 1 } else { y0 }
            let wy = Int64((fy - Float64(y0)) * 256.0)
            let row0 = y0 * ts * 4
            let row1 = y1 * ts * 4
            var py = y + offY
            if (py < 0) { py = 0 }
            if (py >= gotH) { py = gotH - 1 }
            let patRow = py * stride
            for (x in 0..pxW) {
                let i00 = row0 + xs0[x] * 4
                let i01 = row0 + xs1[x] * 4
                let i10 = row1 + xs0[x] * 4
                let i11 = row1 + xs1[x] * 4
                let wx = xw[x]
                var px = x + offX
                if (px < 0) { px = 0 }
                if (px >= gotW) { px = gotW - 1 }
                let pa = Int64(pat[patRow + px * 4 + 3])
                let a = (pa * ak) >> 8
                for (c in 0..3) {
                    let top = Int64(tile[i00 + c]) * (256 - wx) + Int64(tile[i01 + c]) * wx
                    let bottom = Int64(tile[i10 + c]) * (256 - wx) + Int64(tile[i11 + c]) * wx
                    let v = (top * (256 - wy) + bottom * wy) >> 16
                    out[o + c] = UInt8((v * a) / 255)
                }
                out[o + 3] = UInt8(a)
                o += 4
            }
        }
        let pm = createPixelMap(
            out,
            InitializationOptions(
                IKSize(Int32(pxH), Int32(pxW)),
                srcPixelFormat: PixelMapFormat.Bgra8888,
                pixelFormat: PixelMapFormat.Bgra8888
            )
        )
        return Some(pm)
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[WallpaperBg] composite failed uri=${uri} px=${pxW}x${pxH}: ${e}")
        return None
    }
}

/**
 * 后台线程：确保 key 对应的合成位图进入缓存（同 key 并发请求只合成一次，其余等待），完成后
 * 在 UI 线程回调 onDone。
 */
func ensureMaskedCompositeAsync(
    key: String,
    uri: String,
    colors: Array<UInt32>,
    phase: Int32,
    contentAlpha: Float64,
    pxW: Int64,
    pxH: Int64,
    patW: Int64,
    patH: Int64,
    offX: Int64,
    offY: Int64,
    onDone: () -> Unit
): Unit {
    let _ = spawn {
        var shouldBuild = false
        synchronized(_wallpaperCacheMonitor) {
            if (!_compositeCache.contains(key) && !_compositeInFlight.contains(key)) {
                _compositeInFlight.add(key)
                shouldBuild = true
            }
        }
        if (shouldBuild) {
            let t0 = DateTime.now().toUnixTimeStamp().toMilliseconds()
            let result = composeMaskedPixelMap(uri, colors, phase, contentAlpha, pxW, pxH, patW, patH, offX, offY)
            synchronized(_wallpaperCacheMonitor) {
                match (result) {
                    case Some(pm) =>
                        let bytes = pxW * pxH * 4
                        if (_compositeCacheBytes + bytes > COMPOSITE_CACHE_BYTES_LIMIT) {
                            _compositeCache.clear()
                            _compositeCacheBytes = 0
                        }
                        _compositeCache[key] = pm
                        _compositeCacheBytes += bytes
                    case None => ()
                }
                _compositeInFlight.remove(key)
            }
            let t1 = DateTime.now().toUnixTimeStamp().toMilliseconds()
            Hilog.info(0, "CjTelegram", "[WallpaperBg] composite built px=${pxW}x${pxH} ms=${t1 - t0} ok=${result.isSome()} key=${key}")
        } else {
            // 同 key 正在合成：等它落入缓存（或失败清出 in-flight）。
            var waited = 0
            while (waited < 300) {
                sleep(Duration.millisecond * 20)
                waited += 1
                var finished = false
                synchronized(_wallpaperCacheMonitor) {
                    finished = _compositeCache.contains(key) || !_compositeInFlight.contains(key)
                }
                if (finished) { break }
            }
        }
        spawn(UIThread) {
            =>
            onDone()
        }
    }
}

@Component
public class WallpaperBackgroundComponent {
    /** 旧版兼容字段 (TwoColorGradient / SolidColor / CustomImage) */
    /** TC-0402 round11 修法A (diag-suite_settings_appearance-TC-0402-round11.md 缺口A)：
     * 十个主题切换路径入参改 @Prop，补父→子通道；按 S-141 声明处不带初始值。 */
    @Prop var wallpaperType: WallpaperType
    @Prop var solidColor: UInt32
    @Prop var gradientColorStart: UInt32
    @Prop var gradientColorEnd: UInt32
    @Prop var gradientAngle: Float64
    @Prop var imageUri: String
    @Prop var fallbackColor: UInt32
    /** P2-386: 4色多点渐变颜色数组 */
    @Prop var gradientColors: Array<UInt32>
    /** P2-386: 初始 phase (0-7) */
    @Prop var phase: Int32
    /** P2-388: 图案叠加颜色 (0xAARRGGBB) */
    public var patternColor: UInt32 = 0x80000000
    /**
     * P2-388: 图案叠加强度。对位 iOS `file.settings.intensity / 100`（`WallpaperBackgroundNode.
     * swift:1435-1443`）：`>= 0.0` 时按该值做 softLight 混合透明度；`< 0.0` 走反相路径
     * （`invertPattern`，:1451-1455）。绝对值仍落在 0.0-1.0。
     */
    @Prop var patternIntensity: Float64
    /**
     * F-A1 (diag-suite_settings_root-TC-0507-round4.md §七, ic_wallpaper_pattern_layer_chat_qr_
     * share)：pattern 壁纸的本地文件路径（`file://` URI 或沙箱绝对路径），由消费方下载/缓存
     * 后传入（对位源侧 `patternImageLayer.patternContentImage`，来自云端 `.tgv` 文档
     * `WallpaperResourcesService.downloadWallpaper()` 落盘产物）。留空时保持渐变单层——不画任何
     * 自造图案。
     */
    @Prop var patternFile: String
    /** F-A1: pattern 壁纸的云端 slug（`TelegramWallpaper.File.slug`），当前仅透传供未来接线使用，不参与本组件渲染判定。 */
    public var patternSlug: String = ""
    /** P2-390: 暗化叠层强度 (0.0-1.0) */
    public var dimmingIntensity: Float64 = 0.0
    /** P2-390: 是否深色外观 */
    @Prop var isDarkMode: Bool
    /**
     * P2-387: 图片壁纸显示模式
     * iOS: aspectFit→Contain / halfAspectFill→ScaleDown / cover→Cover / fill→Fill
     */
    public var imageDisplayMode: WallpaperImageDisplayMode = WallpaperImageDisplayMode.Cover
    /**
     * P2-393: 自定义图片是否开启模糊
     * blur 通过 .blur(radius:) 属性实现（radius=10 时可见）
     */
    public var imageBlurEnabled: Bool = false
    /**
     * P2-389: 模糊强度 (0-100)，映射到 ArkUI .blur(radius) 中 radius=strength/5.0
     * 50 → radius=10（默认）; 0 → 不模糊; 100 → radius=20（极度模糊）
     * iOS 对应: WallpaperGalleryEntry.settings.blur intensity slider
     */
    public var imageBlurStrength: Int32 = 50
    /**
     * TC-0410 rework_round=1（diag-suite_settings_appearance-TC-0410.md 修法方向 2，required_fix
     * ⑤）：`WallpaperPickerPage` 全屏预览态「Pattern」按钮的独立叠加层开关——与 `wallpaperType`
     * 的互斥基础渲染分支解耦，纯色/渐变预览也能叠加同一份点阵，不需要把预览临时数据伪装成
     * `PatternWallpaper` 类型（临时开关只影响预览渲染，不改变实际要提交的 `wallpaperType`）。
     */
    public var patternOverlayEnabled: Bool = false

    /** 根节点实测尺寸（vp，onAreaChange）。0 表示尚未布局：图案 / 合成层不挂，只挂渐变。 */
    @State var areaWidth: Float64 = 0.0
    @State var areaHeight: Float64 = 0.0
    @State var currentPhase: Int32 = 0
    @State var phaseProgress: Float64 = 0.0
    /** 反相合成位图在后台产出后自增，驱动 maskedSlot() 重新查缓存。 */
    @State var compositeVersion: Int64 = 0
    // 普通 var：本实例已经发出的合成请求 key，避免每轮 build 重复投递。
    private var compositeRequested: HashSet<String> = HashSet<String>()
    private var layoutSeen: Bool = false

    // ────── 私有辅助函数 (S-005: build 块内禁止 let/var) ──────

    private func blurRadius(): Float64 {
        if (!this.imageBlurEnabled) { return 0.0 }
        var s = Int64(this.imageBlurStrength)
        if (s < 0) { s = 0 }
        if (s > 100) { s = 100 }
        return Float64(s) / 5.0
    }

    private func isCustomImage(): Bool {
        match (this.wallpaperType) {
            case WallpaperType.CustomImage => true
            case _ => false
        }
    }

    private func isTwoColorGradient(): Bool {
        match (this.wallpaperType) {
            case WallpaperType.TwoColorGradient => true
            case _ => false
        }
    }

    private func isMultiColorGradient(): Bool {
        match (this.wallpaperType) {
            case WallpaperType.MultiColorGradient => true
            case _ => false
        }
    }

    private func isPatternWallpaper(): Bool {
        match (this.wallpaperType) {
            case WallpaperType.PatternWallpaper => true
            case _ => false
        }
    }

    private func effectivePhase(): Int32 {
        return this.currentPhase
    }

    private func imageFitForDisplayMode(): ImageFit {
        match (this.imageDisplayMode) {
            case WallpaperImageDisplayMode.AspectFit => ImageFit.Contain
            case WallpaperImageDisplayMode.HalfAspectFill => ImageFit.ScaleDown
            case WallpaperImageDisplayMode.Cover => ImageFit.Cover
            case WallpaperImageDisplayMode.Fill => ImageFit.Fill
        }
    }

    /** P2-390: 暗化叠层 opacity */
    private func dimmingOpacity(): Float64 {
        return computeDimmingOpacity(this.dimmingIntensity, this.isDarkMode)
    }

    private func hasDimming(): Bool {
        return this.dimmingOpacity() > 0.001
    }

    /**
     * ADV-2 (rework_round=1): invert-path content alpha — source
     * `WallpaperBackgroundNode.swift:1456-1459` fades `gradientBackgroundNode?.contentView`/
     * `contentNode` to `abs(intensity)` when `invertPattern` (our `patternIntensity < 0.0`)
     * is active.
     */
    private func invertContentAlpha(): Float64 {
        let magnitude = if (this.patternIntensity < 0.0) { -this.patternIntensity } else { this.patternIntensity }
        return min(1.0, magnitude)
    }

    /** 正强度：图案以 intensity 为不透明度叠加；反相基础层（PatternWallpaper 无 overlay）按源侧 compositionOpacity=1。 */
    private func patternLayerAlpha(): Float64 {
        return if (this.patternIntensity < 0.0) { 1.0 } else { min(1.0, this.patternIntensity) }
    }

    private func hasArea(): Bool {
        return this.areaWidth > 1.0 && this.areaHeight > 1.0
    }

    private func isBundledPattern(): Bool {
        return this.patternFile == BUNDLED_DEFAULT_PATTERN_URI
    }

    /** 当前显示密度（px / vp）。 */
    private func displayDensity(): Float64 {
        let d = Float64(getDefaultDisplaySync().densityPixels)
        return if (d <= 0.0) { 1.0 } else { d }
    }

    /**
     * 目标像素几何：(pxW, pxH, patW, patH, offX, offY)。pxW×pxH = 区域像素（封顶 maxPixels 后等比
     * 缩小）；内建图案 aspect-fill：patW×patH ≥ pxW×pxH、居中偏移；其它图案直接拉伸到区域。
     */
    private func patternGeometry(maxPixels: Int64): (Int64, Int64, Int64, Int64, Int64, Int64) {
        let density = this.displayDensity()
        var aw = this.areaWidth * density
        var ah = this.areaHeight * density
        if (aw * ah > Float64(maxPixels)) {
            let shrink = sqrt(Float64(maxPixels) / (aw * ah))
            aw = aw * shrink
            ah = ah * shrink
        }
        let pxW = max(1, Int64(aw + 0.5))
        let pxH = max(1, Int64(ah + 0.5))
        if (this.isBundledPattern()) {
            match (patternSourceSize(this.patternFile)) {
                case Some((sw, sh)) =>
                    let sourceWidth = max(1.0, Float64(sw))
                    let sourceHeight = max(1.0, Float64(sh))
                    let scale = max(Float64(pxW) / sourceWidth, Float64(pxH) / sourceHeight)
                    let patW = max(pxW, Int64(sourceWidth * scale + 0.5))
                    let patH = max(pxH, Int64(sourceHeight * scale + 0.5))
                    return (pxW, pxH, patW, patH, (patW - pxW) / 2, (patH - pxH) / 2)
                case None => ()
            }
        }
        return (pxW, pxH, pxW, pxH, 0, 0)
    }

    // ────── 渐变层 ──────

    private func gradientKey(): String {
        return gradientTileCacheKey(this.gradientColors, this.effectivePhase())
    }

    private func gradientSlot(): Array<String> {
        return [this.gradientKey()]
    }

    private func gradientPixelMap(): PixelMap {
        return gradientTilePixelMap(this.gradientColors, this.effectivePhase())
    }

    // ────── 图案层（直接显示，按 intensity 叠加） ──────

    private func patternKey(): String {
        if (this.patternFile.size == 0 || !this.hasArea()) {
            return ""
        }
        let (_pw, _ph, patW, patH, _ox, _oy) = this.patternGeometry(PATTERN_MAX_DECODE_PIXELS)
        return "${this.patternFile}|${patW}x${patH}"
    }

    /** 图案位图可用时返回单元素 key 数组（解码在此发生一次并缓存），否则空数组 ⇒ 不挂图案层。 */
    private func patternSlot(): Array<String> {
        let key = this.patternKey()
        if (key.size == 0) {
            return []
        }
        match (this.patternPixelMap()) {
            case Some(_) => return [key]
            case None => return []
        }
    }

    private func patternPixelMap(): Option<PixelMap> {
        if (this.patternFile.size == 0 || !this.hasArea()) {
            return None
        }
        let (_pw, _ph, patW, patH, _ox, _oy) = this.patternGeometry(PATTERN_MAX_DECODE_PIXELS)
        return loadPatternPixelMapScaled(this.patternFile, patW, patH)
    }

    private func patternPixelMapOrEmpty(): PixelMap {
        match (this.patternPixelMap()) {
            case Some(pm) => return pm
            case None => return this.gradientPixelMap()
        }
    }

    /** 内建图案是完整文档：aspect-fill 居中（Cover）；云端缩略图是已渲染的整屏表示：拉伸（Fill）。 */
    private func patternFit(): ImageFit {
        return if (this.isBundledPattern()) { ImageFit.Cover } else { ImageFit.Fill }
    }

    // ────── 反相合成层 ──────

    private func maskedKey(): String {
        if (this.patternFile.size == 0 || !this.hasArea()) {
            return ""
        }
        let (pxW, pxH, _a, _b, _c, _d) = this.patternGeometry(COMPOSITE_MAX_PIXELS)
        return maskedCompositeKey(this.patternFile, this.gradientColors, this.effectivePhase(), this.invertContentAlpha(), pxW, pxH)
    }

    /** 合成位图已在缓存 ⇒ [key]；否则投递一次后台合成并返回空（完成后 compositeVersion 自增触发重查）。 */
    private func maskedSlot(): Array<String> {
        let version = this.compositeVersion
        let key = this.maskedKey()
        if (key.size == 0) {
            return []
        }
        match (getMaskedComposite(key)) {
            case Some(_) => return [key]
            case None => ()
        }
        if (!this.compositeRequested.contains(key)) {
            this.compositeRequested.add(key)
            let (pxW, pxH, patW, patH, offX, offY) = this.patternGeometry(COMPOSITE_MAX_PIXELS)
            Hilog.info(0, "CjTelegram", "[WallpaperBg] composite requested px=${pxW}x${pxH} v=${version} key=${key}")
            ensureMaskedCompositeAsync(
                key, this.patternFile, this.gradientColors, this.effectivePhase(), this.invertContentAlpha(),
                pxW, pxH, patW, patH, offX, offY,
                { => this.compositeVersion = this.compositeVersion + 1 }
            )
        }
        return []
    }

    private func maskedPixelMapOrEmpty(): PixelMap {
        match (getMaskedComposite(this.maskedKey())) {
            case Some(pm) => return pm
            case None => return this.gradientPixelMap()
        }
    }

    // ────── 尺寸 / 相位 ──────

    private func sizeDiffers(a: Float64, b: Float64): Bool {
        let d = a - b
        return d > 0.5 || d < -0.5
    }

    /** 根节点布局面积（vp）。退化尺寸（≤1）忽略；只在真的变化时写 @State。 */
    private func onRootArea(w: Float64, h: Float64): Unit {
        if (w <= 1.0 || h <= 1.0) {
            return
        }
        if (!this.sizeDiffers(w, this.areaWidth) && !this.sizeDiffers(h, this.areaHeight)) {
            return
        }
        Hilog.info(0, "CjTelegram", "[WallpaperBg] area ${Int64(w)}x${Int64(h)} (was ${Int64(this.areaWidth)}x${Int64(this.areaHeight)}) type=${this.wallpaperType.ordinal()} phase=${this.effectivePhase()} overlay=${this.patternOverlayEnabled} intensity=${this.patternIntensity} pattern=${this.patternFile.size > 0}")
        this.areaWidth = w
        this.areaHeight = h
        this.layoutSeen = true
    }

    /**
     * TC-0412 (diag-suite_settings_appearance-TC-0412.md 修法 1)：
     * 多色渐变 / 图案壁纸在父级改 @Prop phase 或 shared phase 变化后，把
     * currentPhase 同步到最终值。shared 与 incoming 不一致时以 shared 为准
     * （useSharedAnimationPhase）；只写一次最终值，避免 incoming/shared 来回赋 @State 触发 build 回路。
     * 纯色 / 双色 / 自定义图不读 shared、不推进（保住 D1）。
     */
    private func syncAnimatedPhaseFromParentOrShared(): Unit {
        if (!(this.isMultiColorGradient() || this.isPatternWallpaper())) {
            return
        }
        let incoming = this.phase
        var resolved = incoming
        let shared = getSharedGradientPhase()
        if (shared != incoming) {
            resolved = shared
        }
        if (resolved != this.currentPhase) {
            this.currentPhase = resolved
        }
    }

    /** 零高度探针：每轮 build 同步相位。返回值恒为 ""（D-116：build() 体内不允许裸语句）。 */
    private func syncProbe(): String {
        this.syncAnimatedPhaseFromParentOrShared()
        return ""
    }

    /**
     * UI 侧相位形变动画。推进权在触发方（ChatRoomPage.advanceChatGradientPhase）。
     * 首次布局前只出静态图。渐变层 key 含 phase，currentPhase 变化即换位图。
     */
    public func triggerPhaseAnimation(): Unit {
        if (!this.layoutSeen) {
            return
        }
        this.currentPhase = this.phase
        this.phaseProgress = 0.0
        safeAnimateTo({ => getUIContext() },
            AnimateParam(duration: 300, curve: Curve.Linear),
            {
                =>
                this.phaseProgress = 1.0
            }
        )
    }

    public func aboutToAppear(): Unit {
        this.currentPhase = this.phase
        Hilog.info(0, "CjTelegram", "[WallpaperBg] aboutToAppear type=${this.wallpaperType.ordinal()} phase=${this.phase} overlay=${this.patternOverlayEnabled} intensity=${this.patternIntensity}")
    }

    // ────── 图层 Builder ──────

    /** 渐变层：80×80 位图拉伸铺满 + 插值放大（对位 UIImageView 线性放大）。key 含 colors/phase。 */
    @Builder
    func gradientLayer() {
        ForEach(this.gradientSlot(), itemGenerator: { _key: String, _idx: Int64 =>
            Image(this.gradientPixelMap())
                .width(100.percent)
                .height(100.percent)
                .objectFit(ImageFit.Fill)
                .interpolation(ImageInterpolation.High)
        }, keyGeneratorFunc: { key: String, _idx: Int64 => key })
    }

    /** 图案层：按目标像素解码的位图，intensity 作 opacity。无图案 / 未布局时 slot 为空不挂。 */
    @Builder
    func patternLayer() {
        ForEach(this.patternSlot(), itemGenerator: { _key: String, _idx: Int64 =>
            Image(this.patternPixelMapOrEmpty())
                .width(100.percent)
                .height(100.percent)
                .objectFit(this.patternFit())
                .interpolation(ImageInterpolation.Medium)
                .opacity(this.patternLayerAlpha())
        }, keyGeneratorFunc: { key: String, _idx: Int64 => key })
    }

    /** 反相合成层：premultiplied 位图（渐变 × 图案 alpha × |intensity|），落在黑色宿主之上。 */
    @Builder
    func maskedLayer() {
        ForEach(this.maskedSlot(), itemGenerator: { _key: String, _idx: Int64 =>
            Image(this.maskedPixelMapOrEmpty())
                .width(100.percent)
                .height(100.percent)
                .objectFit(ImageFit.Fill)
                .interpolation(ImageInterpolation.Medium)
        }, keyGeneratorFunc: { key: String, _idx: Int64 => key })
    }

    // ────── UI 构建 ──────

    func build() {
        Stack {
            Text(this.syncProbe()).height(0).fontSize(0)
            if (this.isCustomImage()) {
                if (this.imageUri.size > 0) {
                    if (this.imageBlurEnabled && this.blurRadius() > 0.0) {
                        Image(this.imageUri)
                            .width(100.percent)
                            .height(100.percent)
                            .objectFit(this.imageFitForDisplayMode())
                            .blur(this.blurRadius())
                    } else {
                        Image(this.imageUri)
                            .width(100.percent)
                            .height(100.percent)
                            .objectFit(this.imageFitForDisplayMode())
                    }
                } else {
                    Column {}
                        .width(100.percent)
                        .height(100.percent)
                        .backgroundColor(this.fallbackColor)
                }
            } else if (this.isTwoColorGradient()) {
                Column {}
                    .width(100.percent)
                    .height(100.percent)
                    .linearGradient(
                        angle: this.gradientAngle,
                        colors: [
                            (Color(this.gradientColorStart), 0.0),
                            (Color(this.gradientColorEnd), 1.0)
                        ]
                    )
            } else if (this.patternIntensity < 0.0) {
                // TC-0402 round13 F-3.2: the invert path (source `WallpaperBackgroundNode.swift:
                // 1434/1451`) is gated purely by `file.settings.intensity < 0`, ahead of the
                // wallpaperType branches. Source `:1456-1458` is two nodes: the host is black
                // **opaque** (outer Column, no opacity) and a *separate* content sub-layer is faded
                // to `abs(intensity)`.
                Column {
                    if (this.patternOverlayEnabled && this.patternFile.size > 0) {
                        // The sibling overlay below is the complete content layer (gradient
                        // through the pattern mask, already faded); drawing the gradient here too
                        // would double it and make night wallpaper much brighter than source.
                        Column {}
                            .width(100.percent)
                            .height(100.percent)
                    } else if (this.isMultiColorGradient() || this.isPatternWallpaper()) {
                        Stack {
                            this.gradientLayer()
                            if (this.isPatternWallpaper()) {
                                this.patternLayer()
                            }
                        }
                        .width(100.percent)
                        .height(100.percent)
                        .opacity(this.invertContentAlpha())
                    }
                }
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0xFF000000)
            } else if (this.isMultiColorGradient()) {
                this.gradientLayer()
            } else if (this.isPatternWallpaper()) {
                // P2-388: 渐变底 + 图案按 intensity 不透明度叠加（WallpaperBackgroundNode.swift:
                // 1435-1443 compositionOpacity；softLight 混合本平台不可得，保留不透明度叠加一半语义）。
                Stack {
                    this.gradientLayer()
                    this.patternLayer()
                }
                .width(100.percent)
                .height(100.percent)
            } else {
                Column {}
                    .width(100.percent)
                    .height(100.percent)
                    .backgroundColor(this.solidColor)
            }

            // TC-0410 rework_round=1: 预览态 / 会话页 Pattern 叠加层（与上面互斥的基础渲染分支解耦）。
            if (this.patternOverlayEnabled && this.patternFile.size > 0) {
                if (this.patternIntensity >= 0.0) {
                    this.patternLayer()
                } else {
                    this.maskedLayer()
                }
            }

            if (this.hasDimming()) {
                Column {}
                    .width(100.percent)
                    .height(100.percent)
                    .backgroundColor(0xFF000000)
                    .opacity(this.dimmingOpacity())
            }
        }
        .width(100.percent)
        .height(100.percent)
        .onAreaChange({ _: Area, newArea: Area =>
            this.onRootArea(newArea.width.value, newArea.height.value)
        })
    }
}

/**
 * WallpaperDimmedNodeComponent — F-A2 (diag-suite_settings_root-TC-0507-round4.md §七,
 * ic_wallpaper_dimmed_content_chat_qr_share)：暴露 iOS `makeDimmedNode()` 的等价能力——一份
 * 「已渲染的、按 alpha 压暗的当前壁纸内容副本」，供消费页用自己的遮罩形状（QR 码点/码卡文字/
 * logo 圆底等）合成。与既有 `WallpaperBackgroundComponent.dimmingIntensity`/`isDarkMode` 暗化
 * 叠层是并列的新 public 能力（那一层服务于"壁纸本身随用户暗化设置变暗"的语义；本组件服务于
 * "消费页需要一份压暗内容源去做自己的遮罩合成"的语义，二者独立，故新增 sibling 组件而不是复用
 * 同一实例状态——同一份壁纸内容在屏上可能需要同时存在"正常显示"与"压暗后被遮罩露出"两份实例）。
 *
 * dim alpha 浅色 0.3 / 夜间 0.5，对位 `ChatQrCodeScreen.swift:1997`
 * `self.codeForegroundDimNode.alpha = isDarkAppearance ? 0.5 : 0.3`。
 *
 * 边界条件（ic 原文明令）：**不是**给消费页返回一个色值。源侧压暗对象是
 * `wallpaperBackgroundNode.makeDimmedNode()` 产出的真实壁纸内容克隆
 * （`GradientBackgroundNode.CloneNode`，`SoftwareGradientBackground.swift:202-230`），本组件同样
 * 直接内嵌真实 `WallpaperBackgroundComponent` 渲染树（渐变/图案像素随入参变化），再叠一层黑色
 * 半透明层，而不是计算并返回单个颜色常量。
 */
@Component
public class WallpaperDimmedNodeComponent {
    public var wallpaperType: WallpaperType = WallpaperType.SolidColor
    public var solidColor: UInt32 = 0xFFE8E6DF
    public var gradientColorStart: UInt32 = 0xFFFCF6E9
    public var gradientColorEnd: UInt32 = 0xFFE8DBC8
    public var gradientAngle: Float64 = 180.0
    public var imageUri: String = ""
    public var fallbackColor: UInt32 = 0xFFE8E6DF
    public var gradientColors: Array<UInt32> = [0xFF7FA381, 0xFFD3B48F, 0xFF336F55, 0xFFFBE37D]
    public var phase: Int32 = 0
    public var patternColor: UInt32 = 0x80000000
    public var patternIntensity: Float64 = 0.5
    public var patternFile: String = ""
    public var patternSlug: String = ""
    public var imageDisplayMode: WallpaperImageDisplayMode = WallpaperImageDisplayMode.Cover
    public var imageBlurEnabled: Bool = false
    public var imageBlurStrength: Int32 = 50
    public var patternOverlayEnabled: Bool = false
    /** 是否深色外观——决定 dim alpha 取 0.5（夜间）还是 0.3（浅色），对位 :1997。 */
    public var isDarkMode: Bool = false

    private func dimAlpha(): Float64 {
        if (this.isDarkMode) {
            return 0.5
        }
        return 0.3
    }

    func build() {
        Stack {
            WallpaperBackgroundComponent(
                wallpaperType: this.wallpaperType,
                solidColor: this.solidColor,
                gradientColorStart: this.gradientColorStart,
                gradientColorEnd: this.gradientColorEnd,
                gradientAngle: this.gradientAngle,
                imageUri: this.imageUri,
                fallbackColor: this.fallbackColor,
                gradientColors: this.gradientColors,
                phase: this.phase,
                patternColor: this.patternColor,
                patternIntensity: this.patternIntensity,
                patternFile: this.patternFile,
                patternSlug: this.patternSlug,
                dimmingIntensity: 0.0,
                isDarkMode: this.isDarkMode,
                imageDisplayMode: this.imageDisplayMode,
                imageBlurEnabled: this.imageBlurEnabled,
                imageBlurStrength: this.imageBlurStrength,
                patternOverlayEnabled: this.patternOverlayEnabled
            )
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0xFF000000)
                .opacity(this.dimAlpha())
        }
        .width(100.percent)
        .height(100.percent)
    }
}
