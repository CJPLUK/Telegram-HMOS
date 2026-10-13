package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.ImageKit.*
import kit.CoreFileKit.*
import ohos.business_exception.BusinessException
import std.time.DateTime

/**
 * 图片压缩服务（ImageCompression feature）
 *
 * 对应 iOS ImageCompression.swift:
 *   scaleImageToPixelSize / compressImageToJPEG / compressImageMiniThumbnail
 *
 * 功能:
 *   - JPEG 质量压缩（0-100）：compressToJpeg
 *   - 缩放到目标尺寸后再压缩：compressToMaxPixelSize
 *   - Mini 缩略图生成（40×40）：compressMiniThumbnail
 *
 * 注意：
 *   - 纯本地图像压缩，不涉及 MTProto 上传。
 *     调用方如需上传压缩结果，请将返回的 Array<UInt8> 交给 FileUploadService.uploadFile()。
 *   - "Service → MTProtoClient.send() 完整" 标注 N/A：
 *     图片压缩本身无 TL 方法，iOS 侧 MozjpegBinding 仅是编解码库封装，
 *     HarmonyOS 上由 ImageKit (ImagePacker) 提供等效能力。
 */

private var _imageCompressionInstance: Option<ImageCompressionService> = None

public func getImageCompressionService(): ImageCompressionService {
    match (_imageCompressionInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ImageCompressionService()
            _imageCompressionInstance = Some(inst)
            return inst
    }
}

public class ImageCompressionService {

    public func compressPixelMapToJpeg(pixelMap: PixelMap, quality: UInt8): Array<UInt8> {
        return packPixelMapToJpeg(pixelMap, quality)
    }

    /** 将裁剪/涂鸦得到的 PixelMap 按 Telegram 静态贴纸规范落成唯一 WebP 文件。 */
    public func prepareStaticStickerPixelMapWebP(pixelMap: PixelMap): String {
        try {
            let info = pixelMap.getImageInfo()
            let width = info.size.width
            let height = info.size.height
            if (width <= 0 || height <= 0) { return "" }
            let longest = if (width > height) { width } else { height }
            let scale = Float32(512.0) / Float32(longest)
            if (scale != Float32(1.0)) { pixelMap.scale(scale, scale) }
            let packer = createImagePacker()
            let bytes = packer.packToData(pixelMap, PackingOption("image/webp", UInt8(100)))
            packer.release()
            return this.writeCustomStickerBytes(bytes)
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[ImageCompression] pack edited sticker failed: ${e.message}")
        }
        return ""
    }

    /**
     * iOS subject cutout 的离线降级实现：从四角估计背景色，将与背景接近的像素
     * 变为透明。它不冒充系统 ML 分割，但对证件照、商品照等纯色背景可立即得到
     * 可发送的透明 WebP，并保留原图供用户一键撤销。
     */
    public func prepareCutoutStickerWebP(filePath: String): String {
        var sourcePath = filePath
        if (sourcePath.startsWith("file://")) { sourcePath = sourcePath[7..] }
        var fd: Int32 = -1
        try {
            let file = FileIo.open(sourcePath, mode: OpenMode.READ_ONLY)
            fd = Int32(file.fd)
            let imageSource = createImageSource(fd)
            let pixelMap = imageSource.createPixelMap()
            let info = pixelMap.getImageInfo()
            let width = Int64(info.size.width)
            let height = Int64(info.size.height)
            if (width <= 0 || height <= 0) {
                pixelMap.release()
                imageSource.release()
                FileIo.close(file.fd)
                return ""
            }
            let longest = if (width > height) { width } else { height }
            if (longest > 512) {
                let scale = Float32(512.0) / Float32(longest)
                pixelMap.scale(scale, scale)
            }
            this.removeFlatBackground(pixelMap)
            let output = this.prepareStaticStickerPixelMapWebP(pixelMap)
            pixelMap.release()
            imageSource.release()
            FileIo.close(file.fd)
            fd = -1
            return output
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[ImageCompression] cutout failed: ${e.message}")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ImageCompression] cutout exception: ${e}")
        }
        if (fd >= 0) { try { FileIo.close(fd) } catch (_: Exception) {} }
        return ""
    }

    private func removeFlatBackground(pixelMap: PixelMap): Unit {
        let info = pixelMap.getImageInfo()
        let width = Int64(info.size.width)
        let height = Int64(info.size.height)
        let total = Int64(pixelMap.getPixelBytesNumber())
        if (width <= 1 || height <= 1 || total < width * height * 4) { return }
        let pixels = Array<UInt8>(total, repeat: 0)
        pixelMap.readPixelsToBuffer(pixels)
        let cornerOffsets: Array<Int64> = [0, (width - 1) * 4,
            (height - 1) * width * 4, (height * width - 1) * 4]
        var bgB: Int64 = 0
        var bgG: Int64 = 0
        var bgR: Int64 = 0
        for (offset in cornerOffsets) {
            bgB = bgB + Int64(pixels[offset])
            bgG = bgG + Int64(pixels[offset + 1])
            bgR = bgR + Int64(pixels[offset + 2])
        }
        bgB = bgB / 4
        bgG = bgG / 4
        bgR = bgR / 4
        var index: Int64 = 0
        while (index < width * height) {
            let offset = index * 4
            let db = Int64(pixels[offset]) - bgB
            let dg = Int64(pixels[offset + 1]) - bgG
            let dr = Int64(pixels[offset + 2]) - bgR
            let distance = db * db + dg * dg + dr * dr
            if (distance < 2500) {
                pixels[offset + 3] = 0
            } else if (distance < 6400) {
                pixels[offset + 3] = UInt8((distance - 2500) * 255 / 3900)
            }
            index = index + 1
        }
        pixelMap.writeBufferToPixels(pixels)
    }

    private func writeCustomStickerBytes(bytes: Array<UInt8>): String {
        if (bytes.isEmpty()) { return "" }
        let filesDir = getAppFilesDir()
        if (filesDir.isEmpty()) { return "" }
        let outputDir = filesDir + "/custom_stickers"
        try { FileIo.mkdir(outputDir) } catch (_: Exception) {}
        let stamp = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let outputPath = outputDir + "/custom_sticker_${stamp}.webp"
        try {
            let output = FileIo.open(outputPath, mode: 0o1101)
            FileIo.write(output.fd, bytes)
            FileIo.close(output)
            return outputPath
        } catch (_: Exception) { return "" }
    }

    /**
     * 将相册图片准备成 Telegram 静态贴纸资源：最长边精确缩放为 512，另一边不超过
     * 512，并编码为 WebP。对应 iOS MediaEditorScreen stickerEditor 输出阶段。
     * 当前仅负责规范化资源；抠图、描边和画布编辑由后续编辑器 UI 承担。
     */
    public func prepareStaticStickerWebP(filePath: String): String {
        var sourcePath = filePath
        if (sourcePath.startsWith("file://")) { sourcePath = sourcePath[7..] }
        var fd: Int32 = -1
        try {
            let file = FileIo.open(sourcePath, mode: OpenMode.READ_ONLY)
            fd = Int32(file.fd)
            let imageSource = createImageSource(fd)
            let pixelMap = imageSource.createPixelMap()
            let info = pixelMap.getImageInfo()
            let width = info.size.width
            let height = info.size.height
            if (width <= 0 || height <= 0) {
                pixelMap.release()
                imageSource.release()
                FileIo.close(file.fd)
                return ""
            }

            let longest = if (width > height) { width } else { height }
            let scale = Float32(512.0) / Float32(longest)
            if (scale != Float32(1.0)) { pixelMap.scale(scale, scale) }

            let packer = createImagePacker()
            let bytes = packer.packToData(pixelMap, PackingOption("image/webp", UInt8(100)))
            packer.release()
            pixelMap.release()
            imageSource.release()
            FileIo.close(file.fd)
            fd = -1
            if (bytes.isEmpty()) { return "" }

            let outputPath = this.writeCustomStickerBytes(bytes)
            if (outputPath.isEmpty()) { return "" }
            Hilog.info(0, "CjTelegram",
                "[ImageCompression] prepared static sticker ${width}x${height} -> ${outputPath}")
            return outputPath
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[ImageCompression] prepare sticker failed: ${e.message}")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ImageCompression] prepare sticker exception: ${e}")
        }
        if (fd >= 0) { try { FileIo.close(fd) } catch (_: Exception) {} }
        return ""
    }

    /**
     * 将图片文件压缩为 JPEG 字节流。
     *
     * @param filePath 源图片绝对路径（本地文件）
     * @param quality  JPEG 质量，取值 0-100（100 为最高质量）
     * @return 压缩后的 JPEG 字节数组，失败返回空数组
     */
    public func compressToJpeg(filePath: String, quality: UInt8): Array<UInt8> {
        Hilog.info(0, "CjTelegram", "[ImageCompression] compressToJpeg path=${filePath} quality=${quality}")
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
            return result
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[ImageCompression] compressToJpeg failed: ${e.message}")
            if (fd >= 0) {
                try { FileIo.close(fd) } catch (_e: Exception) {}
            }
            return Array<UInt8>(0, repeat: 0)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ImageCompression] compressToJpeg exception")
            if (fd >= 0) {
                try { FileIo.close(fd) } catch (_e: Exception) {}
            }
            return Array<UInt8>(0, repeat: 0)
        }
    }

    /**
     * 将图片缩放到最大边长限制后，再压缩为 JPEG 字节流。
     * 等效于 iOS scaleImageToPixelSize + compressImageToJPEG 组合。
     *
     * @param filePath    源图片绝对路径
     * @param maxPixels   最大像素边长（长边限制），例如 1280
     * @param quality     JPEG 质量，取值 0-100
     * @return 压缩后的 JPEG 字节数组，失败返回空数组
     */
    public func compressToMaxPixelSize(filePath: String, maxPixels: Int32, quality: UInt8): Array<UInt8> {
        Hilog.info(0, "CjTelegram", "[ImageCompression] compressToMaxPixelSize path=${filePath} maxPixels=${maxPixels} quality=${quality}")
        var fd: Int32 = -1
        try {
            let file = FileIo.open(filePath, mode: OpenMode.READ_ONLY)
            fd = Int32(file.fd)
            let imageSource = createImageSource(fd)
            let pixelMap = imageSource.createPixelMap()

            // 获取原始尺寸并计算缩放比例
            let info = pixelMap.getImageInfo()
            let origW = info.size.width
            let origH = info.size.height

            if (origW > 0 && origH > 0) {
                let maxW = Float32(maxPixels)
                let maxH = Float32(maxPixels)
                let scaleX: Float32 = if (Float32(origW) > maxW) { maxW / Float32(origW) } else { Float32(1.0) }
                let scaleY: Float32 = if (Float32(origH) > maxH) { maxH / Float32(origH) } else { Float32(1.0) }
                let scale: Float32 = if (scaleX < scaleY) { scaleX } else { scaleY }

                if (scale < Float32(1.0)) {
                    pixelMap.scale(scale, scale)
                }
            }

            let result = packPixelMapToJpeg(pixelMap, quality)
            pixelMap.release()
            imageSource.release()
            FileIo.close(file.fd)
            return result
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[ImageCompression] compressToMaxPixelSize failed: ${e.message}")
            if (fd >= 0) {
                try { FileIo.close(fd) } catch (_e: Exception) {}
            }
            return Array<UInt8>(0, repeat: 0)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ImageCompression] compressToMaxPixelSize exception")
            if (fd >= 0) {
                try { FileIo.close(fd) } catch (_e: Exception) {}
            }
            return Array<UInt8>(0, repeat: 0)
        }
    }

    /**
     * 生成 Mini 缩略图（40×40 像素），等效于 iOS compressImageMiniThumbnail(.image)。
     *
     * @param filePath 源图片绝对路径
     * @return 缩略图 JPEG 字节数组，失败返回空数组
     */
    public func compressMiniThumbnail(filePath: String): Array<UInt8> {
        Hilog.info(0, "CjTelegram", "[ImageCompression] compressMiniThumbnail path=${filePath}")
        var fd: Int32 = -1
        try {
            let file = FileIo.open(filePath, mode: OpenMode.READ_ONLY)
            fd = Int32(file.fd)
            let imageSource = createImageSource(fd)
            let pixelMap = imageSource.createPixelMap()

            // 缩放到 40×40（iOS mini thumbnail 标准尺寸）
            let info = pixelMap.getImageInfo()
            let origW = info.size.width
            let origH = info.size.height
            if (origW > 0 && origH > 0) {
                let targetW: Float32 = Float32(40.0)
                let targetH: Float32 = Float32(40.0)
                let scaleX: Float32 = targetW / Float32(origW)
                let scaleY: Float32 = targetH / Float32(origH)
                pixelMap.scale(scaleX, scaleY)
            }

            let result = packPixelMapToJpeg(pixelMap, UInt8(80))
            pixelMap.release()
            imageSource.release()
            FileIo.close(file.fd)
            return result
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[ImageCompression] compressMiniThumbnail failed: ${e.message}")
            if (fd >= 0) {
                try { FileIo.close(fd) } catch (_e: Exception) {}
            }
            return Array<UInt8>(0, repeat: 0)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ImageCompression] compressMiniThumbnail exception")
            if (fd >= 0) {
                try { FileIo.close(fd) } catch (_e: Exception) {}
            }
            return Array<UInt8>(0, repeat: 0)
        }
    }

    /**
     * 将 PixelMap 打包为 JPEG 字节数组（内部辅助方法）。
     *
     * @param pixelMap PixelMap 对象（调用方负责 release）
     * @param quality  JPEG 质量 0-100
     * @return JPEG 字节数组
     */
    private func packPixelMapToJpeg(pixelMap: PixelMap, quality: UInt8): Array<UInt8> {
        let packer = createImagePacker()
        let opts = PackingOption("image/jpeg", quality)
        let result = packer.packToData(pixelMap, opts)
        packer.release()
        return result
    }
}
