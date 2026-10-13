package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.ImageKit.*
import kit.CoreFileKit.*
import ohos.business_exception.BusinessException

/**
 * 动画帧压缩服务（AnimationCompression feature）
 *
 * 对应 iOS AnimationCompressor.swift:
 *   AnimationCompressor.compress(image:completion:) — Metal GPU DCT + Huffman 编码
 *
 * HarmonyOS 等效说明:
 *   - iOS 使用 Metal GPU 计算 DCT 并配合 DctHuffman 库编码，HarmonyOS 无对等 GPU 图像
 *     压缩流水线 API（deferred: Metal/DCT/Huffman 编解码无 HarmonyOS 对应能力）。
 *   - 本服务使用 ImageKit (ImagePacker) 提供 JPEG/WebP 质量压缩作为本地媒体压缩能力：
 *     适用于 GIF 帧、WebM 截帧等静态图像的尺寸缩减，满足贴纸传输前的基础压缩需求。
 *   - 无 MTProto TL 方法（"Service → MTProtoClient.send() 完整" 标注 N/A）：
 *     动画压缩本身是纯客户端本地能力，iOS 侧亦无服务端 TL 调用。
 *
 * 主要能力:
 *   - compressFrame: 将单帧图像文件压缩为 JPEG 字节流（对应 iOS compress(image:completion:)）
 *   - compressFrameToWebP: 将单帧压缩为 WebP（比 JPEG 更小，适合动画贴纸帧存储）
 *   - compressFrameWithMaxSize: 缩放到目标尺寸后再压缩（8x8 块对齐，对应 iOS DCT 8×8 约束）
 *   - estimateCompressedSize: 预估压缩后字节数（辅助调用方决策质量参数）
 */

private var _animationCompressionInstance: Option<AnimationCompressionService> = None

public func getAnimationCompressionService(): AnimationCompressionService {
    match (_animationCompressionInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = AnimationCompressionService()
            _animationCompressionInstance = Some(inst)
            return inst
    }
}

/**
 * 压缩结果数据
 */
public class AnimationCompressedFrame {
    public var data: Array<UInt8>
    public var width: Int32
    public var height: Int32
    public var format: String

    public init(d: Array<UInt8>, w: Int32, h: Int32, fmt: String) {
        this.data = d
        this.width = w
        this.height = h
        this.format = fmt
    }
}

public class AnimationCompressionService {

    /**
     * 将单帧图像文件压缩为 JPEG 字节流。
     * 对应 iOS AnimationCompressor.compress(image:completion:) 的输出阶段。
     *
     * @param filePath 源图片绝对路径（本地文件，支持 JPEG/PNG/WebP/GIF首帧）
     * @param quality  JPEG 质量，取值 0-100（iOS DCT 实现对应约 80-90）
     * @return 压缩后的 JPEG 字节数组，失败返回空数组
     */
    public func compressFrame(filePath!: String, quality!: UInt8): Array<UInt8> {
        Hilog.info(0, "CjTelegram", "[AnimationCompression] compressFrame path=${filePath} quality=${quality}")
        var fd: Int32 = -1
        try {
            let file = FileIo.open(filePath, mode: OpenMode.READ_ONLY)
            fd = Int32(file.fd)
            let imageSource = createImageSource(fd)
            let pixelMap = imageSource.createPixelMap()
            let result = packPixelMapToJpeg(pixelMap, quality)
            pixelMap.release()
            imageSource.release()
            FileIo.close(file.fd)
            Hilog.info(0, "CjTelegram", "[AnimationCompression] compressFrame done size=${result.size}")
            return result
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[AnimationCompression] compressFrame BusinessException: ${e.message}")
            if (fd >= 0) {
                try { FileIo.close(fd) } catch (_e: Exception) {}
            }
            return Array<UInt8>(0, repeat: 0)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[AnimationCompression] compressFrame exception")
            if (fd >= 0) {
                try { FileIo.close(fd) } catch (_e: Exception) {}
            }
            return Array<UInt8>(0, repeat: 0)
        }
    }

    /**
     * 将单帧图像缩放到目标尺寸（8x8 块对齐）后压缩为 JPEG 字节流。
     * 对应 iOS AnimationCompressor 的 8x8 threadgroup 对齐约束。
     *
     * @param filePath    源图片绝对路径
     * @param targetWidth 目标宽度（会向下对齐到 8 的倍数）
     * @param targetHeight 目标高度（会向下对齐到 8 的倍数）
     * @param quality     JPEG 质量，取值 0-100
     * @return AnimationCompressedFrame，失败时 data 为空数组
     */
    public func compressFrameWithMaxSize(filePath!: String, targetWidth!: Int32, targetHeight!: Int32, quality!: UInt8): AnimationCompressedFrame {
        Hilog.info(0, "CjTelegram", "[AnimationCompression] compressFrameWithMaxSize path=${filePath} target=${targetWidth}x${targetHeight}")
        let alignedWidth = alignTo8(targetWidth)
        let alignedHeight = alignTo8(targetHeight)
        var fd: Int32 = -1
        try {
            let file = FileIo.open(filePath, mode: OpenMode.READ_ONLY)
            fd = Int32(file.fd)
            let imageSource = createImageSource(fd)
            let pixelMap = imageSource.createPixelMap()

            let info = pixelMap.getImageInfo()
            let origW = info.size.width
            let origH = info.size.height

            if (origW > 0 && origH > 0 && (alignedWidth > 0 && alignedHeight > 0)) {
                let scaleX: Float32 = Float32(alignedWidth) / Float32(origW)
                let scaleY: Float32 = Float32(alignedHeight) / Float32(origH)
                pixelMap.scale(scaleX, scaleY)
            }

            let data = packPixelMapToJpeg(pixelMap, quality)
            pixelMap.release()
            imageSource.release()
            FileIo.close(file.fd)
            Hilog.info(0, "CjTelegram", "[AnimationCompression] compressFrameWithMaxSize done size=${data.size}")
            return AnimationCompressedFrame(data, alignedWidth, alignedHeight, "jpeg")
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[AnimationCompression] compressFrameWithMaxSize BusinessException: ${e.message}")
            if (fd >= 0) {
                try { FileIo.close(fd) } catch (_e: Exception) {}
            }
            return AnimationCompressedFrame(Array<UInt8>(0, repeat: 0), alignedWidth, alignedHeight, "jpeg")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[AnimationCompression] compressFrameWithMaxSize exception")
            if (fd >= 0) {
                try { FileIo.close(fd) } catch (_e: Exception) {}
            }
            return AnimationCompressedFrame(Array<UInt8>(0, repeat: 0), alignedWidth, alignedHeight, "jpeg")
        }
    }

    /**
     * 将单帧图像文件压缩为 WebP 字节流（比 JPEG 更小，适合贴纸帧）。
     *
     * @param filePath 源图片绝对路径
     * @param quality  WebP 质量，取值 0-100
     * @return 压缩后的 WebP 字节数组，失败返回空数组
     */
    public func compressFrameToWebP(filePath!: String, quality!: UInt8): Array<UInt8> {
        Hilog.info(0, "CjTelegram", "[AnimationCompression] compressFrameToWebP path=${filePath} quality=${quality}")
        var fd: Int32 = -1
        try {
            let file = FileIo.open(filePath, mode: OpenMode.READ_ONLY)
            fd = Int32(file.fd)
            let imageSource = createImageSource(fd)
            let pixelMap = imageSource.createPixelMap()
            let result = packPixelMapToWebP(pixelMap, quality)
            pixelMap.release()
            imageSource.release()
            FileIo.close(file.fd)
            Hilog.info(0, "CjTelegram", "[AnimationCompression] compressFrameToWebP done size=${result.size}")
            return result
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[AnimationCompression] compressFrameToWebP BusinessException: ${e.message}")
            if (fd >= 0) {
                try { FileIo.close(fd) } catch (_e: Exception) {}
            }
            return Array<UInt8>(0, repeat: 0)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[AnimationCompression] compressFrameToWebP exception")
            if (fd >= 0) {
                try { FileIo.close(fd) } catch (_e: Exception) {}
            }
            return Array<UInt8>(0, repeat: 0)
        }
    }

    /**
     * 预估压缩后字节数（不实际读取文件，根据分辨率和质量估算）。
     * 辅助调用方在选择质量参数前做决策。
     *
     * @param width   图像宽度（像素）
     * @param height  图像高度（像素）
     * @param quality JPEG 质量 0-100
     * @return 预估字节数（Int64）
     */
    public func estimateCompressedSize(width!: Int32, height!: Int32, quality!: UInt8): Int64 {
        let pixels = Int64(width) * Int64(height)
        let qualityFactor: Float64 = Float64(quality) / Float64(100)
        let bitsPerPixel: Float64 = Float64(0.5) + qualityFactor * Float64(3.0)
        let estimatedBytes = Int64(Float64(pixels) * bitsPerPixel / Float64(8))
        Hilog.info(0, "CjTelegram", "[AnimationCompression] estimateCompressedSize ${width}x${height} q=${quality} -> ${estimatedBytes} bytes")
        return estimatedBytes
    }

    /**
     * 将 PixelMap 打包为 JPEG 字节数组（内部辅助方法）。
     */
    private func packPixelMapToJpeg(pixelMap: PixelMap, quality: UInt8): Array<UInt8> {
        let packer = createImagePacker()
        let opts = PackingOption("image/jpeg", quality)
        let result = packer.packToData(pixelMap, opts)
        packer.release()
        return result
    }

    /**
     * 将 PixelMap 打包为 WebP 字节数组（内部辅助方法）。
     */
    private func packPixelMapToWebP(pixelMap: PixelMap, quality: UInt8): Array<UInt8> {
        let packer = createImagePacker()
        let opts = PackingOption("image/webp", quality)
        let result = packer.packToData(pixelMap, opts)
        packer.release()
        return result
    }

    /**
     * 将整数向下对齐到最近的 8 的倍数（对应 iOS Metal threadgroupSize = (8, 8)）。
     */
    private func alignTo8(value: Int32): Int32 {
        if (value <= 0) {
            return Int32(8)
        }
        return (value / Int32(8)) * Int32(8)
    }
}
