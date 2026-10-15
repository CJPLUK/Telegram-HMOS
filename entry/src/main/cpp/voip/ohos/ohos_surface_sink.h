// Renders webrtc::VideoFrame into an ArkTS XComponent surface (OHNativeWindow).
//
// Group video chats show several remote videos at once, so the 1:1 trick of
// binding ONE global surface to the hardware decoder does not apply. Each tile
// gets its own sink: frames (I420 from VP8 or from the H264 decoder's buffer
// path) are converted to RGBA with libyuv and queued into the tile's window.
// Latest-frame-wins on a private thread, so the decoder thread never blocks.
#ifndef TGCALLS_OHOS_SURFACE_SINK_H_
#define TGCALLS_OHOS_SURFACE_SINK_H_

#include <cstdint>
#include <memory>

#include "api/video/video_frame.h"
#include "api/video/video_sink_interface.h"

namespace tgcalls_ohos {

class SurfaceFrameSink : public rtc::VideoSinkInterface<webrtc::VideoFrame> {
 public:
  // mirror: flip horizontally (front-camera self preview).
  static std::shared_ptr<SurfaceFrameSink> Create(uint64_t surfaceId, bool mirror, const char* tag);
  ~SurfaceFrameSink() override = default;
};

}  // namespace tgcalls_ohos

#endif  // TGCALLS_OHOS_SURFACE_SINK_H_
