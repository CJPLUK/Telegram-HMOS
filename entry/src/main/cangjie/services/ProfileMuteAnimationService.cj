package ohos_app_cangjie_entry.services

import kit.ImageKit.{createPixelMap, InitializationOptions, Size, PixelMap, PixelMapFormat, AlphaType}
import kit.PerformanceAnalysisKit.Hilog
import std.collection.{ArrayList, HashMap}
import std.sync.Monitor
import ohos_app_cangjie_entry.bindings.getTelegramLottieNative
import ohos_app_cangjie_entry.utils.readRawFileBytes

// 显示尺寸 40vp；按 3 倍密度栅格化，避免 PixelMap 被放大后发糊。
private let PROFILE_MUTE_ICON_SIZE: Int32 = 120
private let profileMuteMonitor = Monitor()
private var profileMuteFrames = HashMap<String, ArrayList<PixelMap>>()
private var profileMuteDurations = HashMap<String, Int32>()

private func profileMuteKey(muted: Bool, blue: Bool): String {
    return "${if (muted) { "muted" } else { "unmuted" }}_${if (blue) { "blue" } else { "white" }}"
}

private func tintProfileMuteFrame(source: Array<UInt8>, blue: Bool): Array<UInt8> {
    let result = source.clone()
    let red: UInt16 = if (blue) { 0 } else { 255 }
    let green: UInt16 = if (blue) { 122 } else { 255 }
    let blueValue: UInt16 = 255
    var index: Int64 = 0
    while (index + 3 < Int64(result.size)) {
        let alpha = UInt16(result[index + 3])
        result[index] = UInt8((blueValue * alpha) / 255)
        result[index + 1] = UInt8((green * alpha) / 255)
        result[index + 2] = UInt8((red * alpha) / 255)
        index = index + 4
    }
    return result
}

/** Render Telegram-iOS' exact PeerInfo mute Lottie into cached PixelMaps. */
public func ensureProfileMuteAnimationLoaded(muted: Bool, blue: Bool): Bool {
    let key = profileMuteKey(muted, blue)
    synchronized(profileMuteMonitor) {
        if (profileMuteFrames.contains(key)) { return true }
    }
    let resourceName = if (muted) { "anim_profilemute.json" } else { "anim_profileunmute.json" }
    match (readRawFileBytes(resourceName)) {
        case None =>
            Hilog.info(0, "CjTelegram", "[ProfileMuteAnimation] missing ${resourceName}")
            return false
        case Some(bytes) =>
            let nativeFrames = getTelegramLottieNative().renderTgs(
                bytes, "profile_${key}", PROFILE_MUTE_ICON_SIZE, maxFrames: 40
            )
            if (!nativeFrames.success) { return false }
            let frames = ArrayList<PixelMap>()
            let options = InitializationOptions(
                Size(PROFILE_MUTE_ICON_SIZE, PROFILE_MUTE_ICON_SIZE),
                srcPixelFormat: PixelMapFormat.Bgra8888,
                pixelFormat: PixelMapFormat.Bgra8888,
                alphaType: AlphaType.Premul
            )
            for (frame in nativeFrames.frames) {
                frames.add(createPixelMap(tintProfileMuteFrame(frame, blue), options))
            }
            synchronized(profileMuteMonitor) {
                profileMuteFrames[key] = frames
                profileMuteDurations[key] = nativeFrames.frameDurationMs
            }
            return frames.size > 0
    }
}

public func getProfileMuteFrameCount(muted: Bool, blue: Bool): Int64 {
    synchronized(profileMuteMonitor) {
        match (profileMuteFrames.get(profileMuteKey(muted, blue))) {
            case Some(frames) => return Int64(frames.size)
            case None => return 0
        }
    }
}

public func getProfileMuteFrameDuration(muted: Bool, blue: Bool): Int32 {
    synchronized(profileMuteMonitor) {
        match (profileMuteDurations.get(profileMuteKey(muted, blue))) {
            case Some(value) => return value
            case None => return 17
        }
    }
}

public func getProfileMuteFrame(muted: Bool, blue: Bool, index: Int64): Option<PixelMap> {
    synchronized(profileMuteMonitor) {
        match (profileMuteFrames.get(profileMuteKey(muted, blue))) {
            case Some(frames) =>
                if (index >= 0 && index < Int64(frames.size)) { return frames.get(index) }
            case None => ()
        }
    }
    return None
}
