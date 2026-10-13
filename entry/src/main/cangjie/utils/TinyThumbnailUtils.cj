package ohos_app_cangjie_entry.utils

import ohos_app_cangjie_entry.bindings.getTinyThumbnailBinding
import stdx.encoding.base64.*

/**
 * TinyThumbnailUtils — 内联极小缩略图解码上层工具接口
 *
 * 对应 Telegram-iOS TinyThumbnail.swift 公开函数 decodeTinyThumbnail。
 *
 * 提供：
 * - decodeTinyThumbnail：将服务端紧凑字节流还原为标准 JPEG 字节数组
 * - decodeTinyThumbnailToDataUrl：还原后编码为 data:image/jpeg;base64,... URL
 *   供 CangjieUI Image() 直接使用
 */

/**
 * 将 Telegram stripped thumbnail 字节流解码为完整 JPEG 字节数组
 *
 * 字节流格式：[version(1B)] [width(1B)] [height(1B)] [scanData...]
 * version 必须为 1，数据长度不得少于 3 字节。
 *
 * @param data  服务端下发的紧凑字节流
 * @return      完整 JPEG 字节数组；解码失败返回 None
 */
public func decodeTinyThumbnail(data: Array<Byte>): Option<Array<Byte>> {
    return getTinyThumbnailBinding().decode(data)
}

/**
 * 将 Telegram stripped thumbnail 字节流解码并转换为 data URL
 *
 * 格式：data:image/jpeg;base64,<base64-encoded JPEG>
 * 可直接传给 CangjieUI Image() 组件显示。
 *
 * @param data  服务端下发的紧凑字节流
 * @return      data URL 字符串；解码失败返回空字符串
 */
public func decodeTinyThumbnailToDataUrl(data: Array<Byte>): String {
    match (getTinyThumbnailBinding().decode(data)) {
        case Some(jpegBytes) =>
            let b64 = toBase64String(jpegBytes)
            return "data:image/jpeg;base64," + b64
        case None =>
            return ""
    }
}
