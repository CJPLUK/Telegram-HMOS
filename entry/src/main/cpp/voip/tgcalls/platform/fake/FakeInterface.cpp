// OHOS patch of tgcalls/platform/fake/FakeInterface.cpp.
//
// History:
// - V1 (5a): non-null but codec-less video factories (audio-only build; the
//   nullptr originals caused SIGSEGV NULL@0x0 in InstanceV2ImplInternal::
//   start(), which dereferences the encoder factory unconditionally).
// - 5c (this version): real video. Factories are webrtc's
//   InternalEncoderFactory/InternalDecoderFactory (VP8 via libvpx; VP9 TUs are
//   compiled as RTC_ENABLE_VP9-less stubs so the factories advertise VP8 only;
//   H264 wrapper reports no formats without WEBRTC_USE_H264). Both factories
//   remain NON-NULL — hard requirement, see 5a note above.
//   Capture side: OHOS camera (ohcamera + image receiver) via
//   patches/shim/ohos_video_capturer.{h,cpp}.

#include "FakeInterface.h"

#include "api/video_codecs/sdp_video_format.h"
#include "api/video_codecs/video_encoder.h"
#include "api/video_codecs/video_decoder.h"
#include "media/engine/internal_encoder_factory.h"
#include "media/engine/internal_decoder_factory.h"

#include "ohos_video_capturer.h"
#include <hilog/log.h>
#include "ohos_h264.h"

#include <cstdio>

namespace tgcalls {

std::unique_ptr<webrtc::VideoEncoderFactory> FakeInterface::makeVideoEncoderFactory(bool preferHardwareEncoding, bool isScreencast) {
  // OHOS hardware H264 (preferred) wrapping the software VP8 factory as
  // fallback. Software VP8 at 720p pegged two CPU cores and capped capture at
  // ~12fps; HW H264 offloads the codec and iOS negotiates H264. See ohos_h264.*
  fprintf(stderr, "[tgcalls_ohos] makeVideoEncoderFactory: OHOS HW-H264 + VP8 fallback\n");
  return tgcalls_ohos::CreateOhosH264EncoderFactory(
      std::make_unique<webrtc::InternalEncoderFactory>());
}

std::unique_ptr<webrtc::VideoDecoderFactory> FakeInterface::makeVideoDecoderFactory() {
  fprintf(stderr, "[tgcalls_ohos] makeVideoDecoderFactory: OHOS HW-H264 + VP8 fallback\n");
  return tgcalls_ohos::CreateOhosH264DecoderFactory(
      std::make_unique<webrtc::InternalDecoderFactory>());
}

webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> FakeInterface::makeVideoSource(rtc::Thread *signalingThread,
                                                                                     rtc::Thread *workerThread) {
  return tgcalls_ohos::CreateOhosVideoSource();
}

bool FakeInterface::supportsEncoding(const std::string &codecName) {
  if (codecName == "H264" && tgcalls_ohos::HasHardwareH264()) return true;
  return codecName == "VP8";
}

void FakeInterface::adaptVideoSource(webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> videoSource, int width,
                                     int height, int fps) {
  tgcalls_ohos::AdaptOhosVideoSource(videoSource, width, height, fps);
}

std::unique_ptr<VideoCapturerInterface> FakeInterface::makeVideoCapturer(
    webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> source, std::string deviceId,
    std::function<void(VideoState)> stateUpdated, std::function<void(PlatformCaptureInfo)> captureInfoUpdated,
    std::shared_ptr<PlatformContext> platformContext, std::pair<int, int> &outResolution) {
  fprintf(stderr, "[tgcalls_ohos] makeVideoCapturer(deviceId=%s)\n", deviceId.c_str());
  OH_LOG_Print(LOG_APP, LOG_INFO, 0, "tgcalls_ohos", "[platform] makeVideoCapturer(%{public}s)", deviceId.c_str());
  if (deviceId == "screen") {
    // Group-call screen sharing (patches/shim/ohos_screen_capturer.cpp).
    return tgcalls_ohos::CreateOhosScreenCapturer(source, stateUpdated, outResolution);
  }
  return tgcalls_ohos::CreateOhosVideoCapturer(source, deviceId, stateUpdated, captureInfoUpdated,
                                               outResolution);
}

std::unique_ptr<PlatformInterface> CreatePlatformInterface() {
  return std::make_unique<FakeInterface>();
}

}  // namespace tgcalls
