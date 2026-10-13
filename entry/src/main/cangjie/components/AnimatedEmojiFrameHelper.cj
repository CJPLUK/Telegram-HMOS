package ohos_app_cangjie_entry.components

import kit.ImageKit.{PixelMap, createPixelMap, InitializationOptions, Size, PixelMapFormat}

public func getEmptyAnimatedEmojiPixelMap(): PixelMap {
    return createPixelMap(
        Array<UInt8>(4, repeat: 0),
        InitializationOptions(
            Size(1, 1),
            srcPixelFormat: PixelMapFormat.Bgra8888,
            pixelFormat: PixelMapFormat.Bgra8888
        )
    )
}
