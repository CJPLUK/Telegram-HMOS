// ohos_video_capturer.h — step 5c: OHOS camera capture for tgcalls.
//
// Native-only pipeline (no JS/ArkTS bridge in the frame path):
//   ohcamera preview output -> OH_ImageReceiverNative (NV21/YUV_420_SP)
//   -> libyuv (to I420 + rotate upright) -> webrtc I420Buffer
//   -> rtc::AdaptedVideoTrackSource (adaptation + broadcast to encoder)
//   plus an optional "uncropped" sink (local preview, full-res pre-adaptation).
//
// Consumed by platform/fake/FakeInterface.cpp (makeVideoSource /
// makeVideoCapturer / adaptVideoSource hooks). Camera permission
// (ohos.permission.CAMERA) is granted at the app layer before video starts.

#ifndef TGCALLS_OHOS_VIDEO_CAPTURER_H
#define TGCALLS_OHOS_VIDEO_CAPTURER_H

#include <functional>
#include <memory>
#include <string>
#include <utility>

#include "api/scoped_refptr.h"

namespace webrtc {
class VideoTrackSourceInterface;
class I420Buffer;
} // namespace webrtc

namespace tgcalls {
enum class VideoState;
struct PlatformCaptureInfo;
class VideoCapturerInterface;
} // namespace tgcalls

namespace tgcalls_ohos {

// Non-null AdaptedVideoTrackSource-backed track source.
webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> CreateOhosVideoSource();

// Forward of PlatformInterface::adaptVideoSource (VideoAdapter output request).
void AdaptOhosVideoSource(webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> source,
                          int width, int height, int fps);

// Creates a camera capturer bound to `source` (must come from
// CreateOhosVideoSource). deviceId containing "back" selects the rear camera;
// anything else (including "") selects the front camera. Returns nullptr only
// if no camera device is present. outResolution is the (upright-rotated)
// capture resolution used for aspect adaptation.
// Screen sharing (ohos_screen_capturer.cpp): OH_AVScreenCapture -> I420 -> the same source.
// deviceId "screen" in makeVideoCapturer routes here.
std::unique_ptr<tgcalls::VideoCapturerInterface> CreateOhosScreenCapturer(
    webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> source,
    std::function<void(tgcalls::VideoState)> stateUpdated,
    std::pair<int, int> &outResolution);
void PushI420ToOhosVideoSource(webrtc::VideoTrackSourceInterface *source,
                               webrtc::scoped_refptr<webrtc::I420Buffer> buffer, int64_t timeUs);
void MarkOhosVideoSourceScreencast(webrtc::VideoTrackSourceInterface *source, bool v);

std::unique_ptr<tgcalls::VideoCapturerInterface> CreateOhosVideoCapturer(
    webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> source,
    std::string deviceId,
    std::function<void(tgcalls::VideoState)> stateUpdated,
    std::function<void(tgcalls::PlatformCaptureInfo)> captureInfoUpdated,
    std::pair<int, int> &outResolution);

// Flip the running capturer's camera front<->back in place, without a
// synchronous teardown/rebuild on the tgcalls media thread. `nativePtr` must be
// the opaque pointer delivered to
// VideoCapturerInterface::withNativeImplementation()'s completion (an
// OhosCameraCapturer*). Safe to call with nullptr (no-op). Returns immediately;
// the actual camera reconfiguration happens on the capturer's own thread.
void SwitchOhosCameraNative(void *nativePtr, bool wantBack);

} // namespace tgcalls_ohos

#endif
