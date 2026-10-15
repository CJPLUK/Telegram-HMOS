// OHOS hardware H.264 codec for tgcalls/WebRTC.
//
// Why: the software VP8 path (InternalEncoder/DecoderFactory over libvpx) plus
// the software NV21->I420 rotate saturates two CPU cores at 720p on-device
// (measured: IncomingVideoSt + tgc-media both pegged ~96%), capping capture at
// ~12fps and stuttering the decode -> low perceived quality + latency. OHOS
// exposes hardware H.264 (AVC) encode/decode via the AVCodec Kit
// (native_avcodec_video{encoder,decoder}.h, Kirin has HW AVC). Telegram iOS
// negotiates H264 in calls (codec prefs: Auto/H265/H264/VP8/VP9), so advertising
// H264 lets both ends run hardware and frees the CPU.
//
// This header exposes factory creators that FakeInterface hands to tgcalls. The
// factories advertise H264 (constrained-baseline, packetization-mode=1) and
// build OHOS-backed webrtc::Video{Encoder,Decoder} instances. WebRTC's own H264
// RTP packetizer / SdpVideoFormat / EncodedImage machinery is reused verbatim
// (see modules/video_coding/codecs/h264) — only the codec core is swapped for
// OHOS AVCodec.

#ifndef TGCALLS_OHOS_H264_H_
#define TGCALLS_OHOS_H264_H_

#include <memory>

#include "api/video_codecs/video_encoder_factory.h"
#include "api/video_codecs/video_decoder_factory.h"

namespace tgcalls_ohos {

// True if the device actually exposes a hardware AVC encoder AND decoder.
// Cheap runtime capability probe (OH_AVCodec_GetCapabilityByCategory +
// OH_AVCapability_IsHardware); cached after first call.
bool HasHardwareH264();

// Factory that advertises H264 first (preferred) then delegates VP8 to the
// supplied software fallback factory, so negotiation still succeeds if a peer
// lacks H264. Ownership of `vp8Fallback` is taken.
std::unique_ptr<webrtc::VideoEncoderFactory> CreateOhosH264EncoderFactory(
    std::unique_ptr<webrtc::VideoEncoderFactory> vp8Fallback);

std::unique_ptr<webrtc::VideoDecoderFactory> CreateOhosH264DecoderFactory(
    std::unique_ptr<webrtc::VideoDecoderFactory> vp8Fallback);

}  // namespace tgcalls_ohos

#endif  // TGCALLS_OHOS_H264_H_
