package ohos_app_cangjie_entry.services

/**
 * ImageCompressBridge — 发图前按 iOS 口径压缩（长边 1280 px、JPEG q80、按 EXIF 摆正）。
 * ArkTS 反转 photo.compress（ImageCompressImpl.ets）。仅限非 UI 线程。
 */

import kit.PerformanceAnalysisKit.Hilog

public class CompressedPhoto {
    public var ok: Bool = false
    public var path: String = ""
    public var width: Int32 = 0
    public var height: Int32 = 0
    public var bytes: Int64 = 0
    public init() {}
}

public class ImageCompressBridge {
    public static func compress(path: String, maxSide: Int32, quality: Int32): CompressedPhoto {
        let r = CompressedPhoto()
        let arg = "{\"path\":\"" + path + "\",\"maxSide\":${maxSide},\"quality\":${quality}}"
        let res = arkCallSync("photo.compress", arg, 30000)
        if (res.size == 0) { return r }
        try {
            let obj = JsonParser.parseObject(res)
            r.ok = obj.getBool("ok")
            r.path = obj.getString("path")
            r.width = Int32(obj.getInt("width"))
            r.height = Int32(obj.getInt("height"))
            r.bytes = obj.getInt("bytes")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ImageCompress] parse failed: ${e}")
        }
        return r
    }
}
