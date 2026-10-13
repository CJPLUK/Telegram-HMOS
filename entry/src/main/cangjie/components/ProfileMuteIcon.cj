package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import kit.ImageKit.PixelMap
import ohos.arkui.state_macro_manage.*
import std.sync.*
import std.time.*
import ohos.resource.__GenerateResource__
import ohos_app_cangjie_entry.app.getAppState
import ohos_app_cangjie_entry.services.{ensureProfileMuteAnimationLoaded, getProfileMuteFrame, getProfileMuteFrameCount, getProfileMuteFrameDuration}

/** Telegram-iOS PeerInfoHeaderButtonNode mute/unmute Lottie counterpart. */
@Component
public class ProfileMuteIcon {
    @Prop var muted: Bool
    @Prop var blue: Bool
    @Prop var autoplay: Bool

    @State var ready: Bool = false
    @State var frameIndex: Int64 = 0
    private var playbackTimer: Option<Timer> = None<Timer>

    public override func aboutToAppear(): Unit {
        let mutedValue = this.muted
        let blueValue = this.blue
        let shouldPlay = this.autoplay
        let _ = spawn {
            let selectedLoaded = ensureProfileMuteAnimationLoaded(mutedValue, blueValue)
            // Both end states must already be available when @Prop muted changes.
            let _ = ensureProfileMuteAnimationLoaded(!mutedValue, blueValue)
            if (selectedLoaded) {
                launch {
                    this.ready = true
                    let count = getProfileMuteFrameCount(mutedValue, blueValue)
                    this.frameIndex = if (shouldPlay || count == 0) { 0 } else { count - 1 }
                    if (shouldPlay) { this.startPlayback() }
                }
            }
        }
    }

    public override func aboutToDisappear(): Unit { this.stopPlayback() }

    private func currentFrame(): PixelMap {
        match (getProfileMuteFrame(this.muted, this.blue, this.frameIndex)) {
            case Some(frame) => return frame
            case None => return getEmptyAnimatedEmojiPixelMap()
        }
    }

    private func startPlayback(): Unit {
        this.stopPlayback()
        let count = getProfileMuteFrameCount(this.muted, this.blue)
        if (count <= 1) { return }
        var interval = getProfileMuteFrameDuration(this.muted, this.blue)
        if (interval < 16) { interval = 16 }
        this.playbackTimer = Some(Timer.repeat(
            Duration.millisecond * Int64(interval), Duration.millisecond * Int64(interval),
            { =>
                if (!getAppState().isInForeground()) { return }
                launch {
                    if (this.frameIndex + 1 >= count) {
                        this.frameIndex = count - 1
                        this.stopPlayback()
                    } else {
                        this.frameIndex = this.frameIndex + 1
                    }
                }
            }, style: CatchupStyle.Skip
        ))
    }

    private func stopPlayback(): Unit {
        match (this.playbackTimer) {
            case Some(timer) =>
                timer.cancel()
                this.playbackTimer = None<Timer>
            case None => ()
        }
    }

    public func build() {
        Stack(alignContent: Alignment.Center) {
            if (this.ready) {
                Image(this.currentFrame())
                    .id("profileMute_${this.muted}_${this.blue}_${this.frameIndex}")
                    .width(40)
                    .height(40)
                    .objectFit(ImageFit.Contain)
            } else {
                Image(if (this.muted) { @r(app.media.clist_ic_mute) } else { @r(app.media.clist_ic_unmute) })
                    .width(30)
                    .height(30)
                    .fillColor(if (this.blue) { 0xFF007AFF } else { 0xFFFFFFFF })
            }
        }
        .width(40)
        .height(40)
    }
}
