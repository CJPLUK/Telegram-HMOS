// Internal factory hooks shared between the OHOS H264 factory and the
// encoder/decoder translation units. Not part of the public tgcalls surface.

#ifndef TGCALLS_OHOS_H264_INTERNAL_H_
#define TGCALLS_OHOS_H264_INTERNAL_H_

#include <memory>

#include "api/video_codecs/sdp_video_format.h"
#include "api/video_codecs/video_encoder.h"
#include "api/video_codecs/video_decoder.h"

namespace tgcalls_ohos {

// The OHOS AVC MIME string ("video/avc"); nullptr if the header const is
// unavailable at runtime.
const char* OhosAvcMime();

// Exact name of the HARDWARE AVC encoder/decoder (via GetCapabilityByCategory),
// so we CreateByName instead of CreateByMime (which may return a software
// codec). nullptr if no hardware codec is present.
const char* OhosAvcHwEncoderName();
const char* OhosAvcHwDecoderName();

std::unique_ptr<webrtc::VideoEncoder> CreateOhosH264Encoder(
    const webrtc::SdpVideoFormat& format);

std::unique_ptr<webrtc::VideoDecoder> CreateOhosH264Decoder();

// Remote-video render surface (XComponent NativeWindow). When set, the HW
// decoder renders directly to it (GPU zero-copy) instead of copying frames out
// to the CPU BGRA/PixelMap path. Set from the shim export
// tgcalls_set_remote_video_surface(); read by the decoder on InitCodec.
// void* is OHNativeWindow* (kept opaque to avoid pulling the header everywhere).
void SetRemoteRenderSurface(void* nativeWindow);
void* GetRemoteRenderSurface();
uint64_t GetRemoteSurfaceGeneration();

}  // namespace tgcalls_ohos

#endif  // TGCALLS_OHOS_H264_INTERNAL_H_
