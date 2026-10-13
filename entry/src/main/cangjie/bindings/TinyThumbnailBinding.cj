package ohos_app_cangjie_entry.bindings

import kit.PerformanceAnalysisKit.Hilog
import stdx.encoding.base64.*

/**
 * TinyThumbnailBinding — 内联极小缩略图解码平台封装层
 *
 * 对应 Telegram-iOS TinyThumbnail.swift (decodeTinyThumbnail)。
 *
 * Telegram stripped thumbnail 字节流格式：
 *   Byte 0:    版本号，必须为 0x01
 *   Byte 1:    宽度 (UInt8)
 *   Byte 2:    高度 (UInt8)
 *   Byte 3..:  JPEG scan data（无完整 JPEG 头尾）
 *
 * 重建流程：
 *   1. 校验版本 == 1，数据长度 >= 3
 *   2. 提取 width / height
 *   3. 拼接 standardJpegHeader + scanData + standardJpegFooter
 *   4. 将 width 写入偏移 164，height 写入偏移 166（SOF0 段内）
 *   5. 返回完整 JPEG 字节数组
 */

private var _tinyThumbnailBindingInstance: Option<TinyThumbnailBinding> = None

/**
 * 获取 TinyThumbnailBinding 单例
 */
public func getTinyThumbnailBinding(): TinyThumbnailBinding {
    match (_tinyThumbnailBindingInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = TinyThumbnailBinding()
            _tinyThumbnailBindingInstance = Some(inst)
            return inst
    }
}

/**
 * 内联极小缩略图解码封装层
 */
public class TinyThumbnailBinding {

    /**
     * 解码 Telegram stripped thumbnail 字节流为标准 JPEG 字节数组
     *
     * @param data  服务端下发的紧凑字节流（version + width + height + scanData）
     * @return      完整 JPEG 字节数组；版本不符或数据过短返回 None
     */
    public func decode(data: Array<Byte>): Option<Array<Byte>> {
        if (data.size < 3) {
            Hilog.info(0, "CjTelegram", "[TinyThumbnail] data too short")
            return None
        }

        let version = data[0]
        if (version != UInt8(1)) {
            Hilog.info(0, "CjTelegram", "[TinyThumbnail] unknown version")
            return None
        }

        let width = data[1]
        let height = data[2]

        let header = tinyThumbnailHeader()
        let footer = tinyThumbnailFooter()

        let scanSize = data.size - 3
        let totalSize = header.size + scanSize + footer.size

        let result = Array<Byte>(totalSize, repeat: UInt8(0))

        // 写入 header
        var offset: Int64 = 0
        var i: Int64 = 0
        while (i < header.size) {
            result[offset] = header[i]
            offset += 1
            i += 1
        }

        // 写入 scan data（bytes 3..end of input）
        var j: Int64 = 3
        while (j < Int64(data.size)) {
            result[offset] = data[j]
            offset += 1
            j += 1
        }

        // 写入 footer
        var k: Int64 = 0
        while (k < footer.size) {
            result[offset] = footer[k]
            offset += 1
            k += 1
        }

        // 将 width/height 写入偏移 164/166（对应 iOS TinyThumbnail.swift 的固定偏移）
        // 这两个偏移位于 JPEG SOF0 段内（header 长 623 字节，偏移 164/166 在 header 内）
        if (Int64(result.size) > 166) {
            result[164] = width
            result[166] = height
        }

        Hilog.info(0, "CjTelegram", "[TinyThumbnail] decoded ok totalBytes=${Int64(result.size)}")
        return Some(result)
    }

    /**
     * 返回 JPEG 字节总长度（不含 scan data），用于调试/校验
     */
    public func headerSize(): Int64 {
        return tinyThumbnailHeader().size
    }
}

/**
 * Telegram tiny thumbnail JPEG 标准头部（623 字节）
 *
 * 与 iOS TinyThumbnail.swift 的 tinyThumbnailHeaderPattern 完全一致，
 * 直接使用原始 base64 字符串解码。
 */
func tinyThumbnailHeader(): Array<Byte> {
    let b64 = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlk" +
        "kYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl" +
        "+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/" +
        "wAARCAAAAAADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAA" +
        "AgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcY" +
        "GRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKT" +
        "lJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP0" +
        "9fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQA" +
        "AQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2" +
        "Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOk" +
        "paanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMB" +
        "AAIRAxEAPwA="
    match (fromBase64String(b64)) {
        case Some(bytes) => return bytes
        case None =>
            Hilog.info(0, "CjTelegram", "[TinyThumbnail] FATAL: header base64 decode failed")
            return Array<Byte>(0, repeat: UInt8(0))
    }
}

/**
 * Telegram tiny thumbnail JPEG 标准尾部（2 字节：0xFF 0xD9）
 *
 * 与 iOS TinyThumbnail.swift 的 tinyThumbnailFooterPattern 完全一致。
 */
func tinyThumbnailFooter(): Array<Byte> {
    return Array<Byte>(2, { i: Int64 =>
        if (i == 0) { UInt8(0xFF) } else { UInt8(0xD9) }
    })
}
