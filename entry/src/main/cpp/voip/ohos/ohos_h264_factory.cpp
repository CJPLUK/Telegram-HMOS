// OHOS H.264 encoder/decoder factories. Advertise HW H264 (preferred) and
// delegate VP8 to a software fallback so negotiation still succeeds with a
// VP8-only peer. The H264 SdpVideoFormat is built from WebRTC's own profile
// helpers so RTP negotiation matches a stock WebRTC H264 endpoint.

#include "ohos_h264.h"
#include "ohos_h264_internal.h"

#include <atomic>
#include <memory>
#include <vector>

#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <hilog/log.h>

#include "absl/strings/match.h"
#include "api/video_codecs/h264_profile_level_id.h"
#include "api/video_codecs/sdp_video_format.h"
#include "media/base/media_constants.h"
#include "media/engine/simulcast_encoder_adapter.h"

namespace tgcalls_ohos {
namespace {

#define FLOG(fmt, ...) \
  OH_LOG_Print(LOG_APP, LOG_INFO, 0, "tgcalls_ohos", "[h264fac] " fmt, ##__VA_ARGS__)

bool IsH264Name(const webrtc::SdpVideoFormat& f) {
  return absl::EqualsIgnoreCase(f.name, cricket::kH264CodecName);
}

// Constrained-Baseline, level 3.1 (up to 720p30), packetization-mode 1 — the
// most interoperable H264 profile; iOS Telegram advertises the same.
webrtc::SdpVideoFormat H264Format() {
  const absl::optional<std::string> profile =
      webrtc::H264ProfileLevelIdToString(webrtc::H264ProfileLevelId(
          webrtc::H264Profile::kProfileConstrainedBaseline,
          webrtc::H264Level::kLevel3_1));
  return webrtc::SdpVideoFormat(
      cricket::kH264CodecName,
      {{cricket::kH264FmtpProfileLevelId, profile.value_or("42e01f")},
       {cricket::kH264FmtpLevelAsymmetryAllowed, "1"},
       {cricket::kH264FmtpPacketizationMode, "1"}});
}

// Produces single-stream HW encoders; the SimulcastEncoderAdapter below asks it
// once per simulcast layer.
class OhosH264SingleStreamFactory : public webrtc::VideoEncoderFactory {
 public:
  std::vector<webrtc::SdpVideoFormat> GetSupportedFormats() const override {
    std::vector<webrtc::SdpVideoFormat> formats;
    if (HasHardwareH264()) formats.push_back(H264Format());
    return formats;
  }

  std::unique_ptr<webrtc::VideoEncoder> CreateVideoEncoder(
      const webrtc::SdpVideoFormat& format) override {
    FLOG("CreateVideoEncoder -> OHOS HW H264 (one simulcast layer)");
    return CreateOhosH264Encoder(format);
  }
};

class OhosH264EncoderFactory : public webrtc::VideoEncoderFactory {
 public:
  explicit OhosH264EncoderFactory(
      std::unique_ptr<webrtc::VideoEncoderFactory> fallback)
      : fallback_(std::move(fallback)) {}

  std::vector<webrtc::SdpVideoFormat> GetSupportedFormats() const override {
    std::vector<webrtc::SdpVideoFormat> formats;
    if (HasHardwareH264()) formats.push_back(H264Format());  // preferred
    if (fallback_) {
      for (auto& f : fallback_->GetSupportedFormats()) formats.push_back(f);
    }
    return formats;
  }

  std::unique_ptr<webrtc::VideoEncoder> CreateVideoEncoder(
      const webrtc::SdpVideoFormat& format) override {
    if (IsH264Name(format) && HasHardwareH264()) {
      // Group calls announce 3 simulcast layers (SIM ssrc group). The HW encoder
      // is single-stream, so without the adapter only the first ssrc ever carried
      // video and viewers asking the SFU for another layer saw nothing. With one
      // configured stream (1:1 calls) the adapter is a pass-through.
      FLOG("CreateVideoEncoder -> SimulcastEncoderAdapter(OHOS HW H264)");
      return std::make_unique<webrtc::SimulcastEncoderAdapter>(&single_stream_, format);
    }
    return fallback_ ? fallback_->CreateVideoEncoder(format) : nullptr;
  }

 private:
  OhosH264SingleStreamFactory single_stream_;
  std::unique_ptr<webrtc::VideoEncoderFactory> fallback_;
};

class OhosH264DecoderFactory : public webrtc::VideoDecoderFactory {
 public:
  explicit OhosH264DecoderFactory(
      std::unique_ptr<webrtc::VideoDecoderFactory> fallback)
      : fallback_(std::move(fallback)) {}

  std::vector<webrtc::SdpVideoFormat> GetSupportedFormats() const override {
    std::vector<webrtc::SdpVideoFormat> formats;
    if (HasHardwareH264()) formats.push_back(H264Format());
    if (fallback_) {
      for (auto& f : fallback_->GetSupportedFormats()) formats.push_back(f);
    }
    return formats;
  }

  std::unique_ptr<webrtc::VideoDecoder> Create(
      const webrtc::Environment& env,
      const webrtc::SdpVideoFormat& format) override {
    if (IsH264Name(format) && HasHardwareH264()) {
      FLOG("Create -> OHOS HW H264 decoder");
      return CreateOhosH264Decoder();
    }
    return fallback_ ? fallback_->Create(env, format) : nullptr;
  }

  std::unique_ptr<webrtc::VideoDecoder> CreateVideoDecoder(
      const webrtc::SdpVideoFormat& format) override {
    if (IsH264Name(format) && HasHardwareH264()) {
      return CreateOhosH264Decoder();
    }
    return fallback_ ? fallback_->CreateVideoDecoder(format) : nullptr;
  }

 private:
  std::unique_ptr<webrtc::VideoDecoderFactory> fallback_;
};

}  // namespace

const char* OhosAvcMime() { return OH_AVCODEC_MIMETYPE_VIDEO_AVC; }

static std::atomic<void*> g_remoteRenderSurface{nullptr};
// Bumped on every set/clear so a live decoder can detect the binding changed
// (e.g. a second VideoCallScreen shell replaced the XComponent, or a stale
// shell's teardown cleared it) and re-init against the current surface.
static std::atomic<uint64_t> g_remoteSurfaceGeneration{0};
void SetRemoteRenderSurface(void* nativeWindow) {
  g_remoteRenderSurface.store(nativeWindow);
  g_remoteSurfaceGeneration.fetch_add(1);
  FLOG("remote render surface %{public}s (gen=%{public}llu)",
       nativeWindow ? "set" : "cleared",
       (unsigned long long)g_remoteSurfaceGeneration.load());
}
void* GetRemoteRenderSurface() { return g_remoteRenderSurface.load(); }
uint64_t GetRemoteSurfaceGeneration() { return g_remoteSurfaceGeneration.load(); }

static const char* HwName(bool isEncoder) {
  OH_AVCapability* cap = OH_AVCodec_GetCapabilityByCategory(
      OH_AVCODEC_MIMETYPE_VIDEO_AVC, isEncoder, HARDWARE);
  if (!cap || !OH_AVCapability_IsHardware(cap)) return nullptr;
  return OH_AVCapability_GetName(cap);  // stable string owned by the capability
}

const char* OhosAvcHwEncoderName() {
  static const char* n = HwName(true);
  FLOG("HW AVC encoder name = %{public}s", n ? n : "(none)");
  return n;
}

const char* OhosAvcHwDecoderName() {
  static const char* n = HwName(false);
  FLOG("HW AVC decoder name = %{public}s", n ? n : "(none)");
  return n;
}

bool HasHardwareH264() {
  static const bool cached = [] {
    const char* mime = OH_AVCODEC_MIMETYPE_VIDEO_AVC;
    OH_AVCapability* enc =
        OH_AVCodec_GetCapabilityByCategory(mime, true, HARDWARE);
    OH_AVCapability* dec =
        OH_AVCodec_GetCapabilityByCategory(mime, false, HARDWARE);
    bool ok = enc && dec && OH_AVCapability_IsHardware(enc) &&
              OH_AVCapability_IsHardware(dec);
    FLOG("HasHardwareH264 = %d (enc=%p dec=%p)", ok ? 1 : 0, (void*)enc,
         (void*)dec);
    return ok;
  }();
  return cached;
}

std::unique_ptr<webrtc::VideoEncoderFactory> CreateOhosH264EncoderFactory(
    std::unique_ptr<webrtc::VideoEncoderFactory> vp8Fallback) {
  return std::make_unique<OhosH264EncoderFactory>(std::move(vp8Fallback));
}

std::unique_ptr<webrtc::VideoDecoderFactory> CreateOhosH264DecoderFactory(
    std::unique_ptr<webrtc::VideoDecoderFactory> vp8Fallback) {
  return std::make_unique<OhosH264DecoderFactory>(std::move(vp8Fallback));
}

}  // namespace tgcalls_ohos
