// OHOS hardware H.264 encoder implementing webrtc::VideoEncoder.
//
// Byte-buffer async mode: OHOS proactively hands us free input buffers
// (OnNeedInputBuffer) and finished output buffers (OnNewOutputBuffer) on its own
// threads. We feed I420 in submission order and deliver EncodedImage in output
// order; low-latency one-in-one-out keeps the two in lockstep, so a simple FIFO
// of per-frame metadata correlates output->input. SPS/PPS arrive once as a
// CODEC_DATA buffer; we cache and prepend them to every keyframe because
// WebRTC's H264 RTP path expects parameter sets with each IDR.

#include "ohos_h264_internal.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <map>
#include <mutex>
#include <queue>
#include <vector>

#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avbuffer_info.h>
#include <multimedia/player_framework/native_avformat.h>
#include <hilog/log.h>

#include "third_party/libyuv/include/libyuv.h"
#include "api/video/encoded_image.h"
#include "api/video/i420_buffer.h"
#include "api/video/video_frame.h"
#include "api/video_codecs/video_encoder.h"
#include "common_video/h264/h264_bitstream_parser.h"
#include "modules/video_coding/include/video_codec_interface.h"
#include "modules/video_coding/include/video_error_codes.h"
#include "rtc_base/logging.h"

namespace tgcalls_ohos {
namespace {

#undef LOG_TAG
#define OHH264_TAG "tgcalls_ohos"
#define ELOG(fmt, ...) \
  OH_LOG_Print(LOG_APP, LOG_INFO, 0, OHH264_TAG, "[h264enc] " fmt, ##__VA_ARGS__)

constexpr int kIFrameIntervalSeconds = 3600;  // effectively "never" auto-IDR;
                                              // WebRTC drives keyframes explicitly.

// A NAL scan: does the Annex-B stream contain an SPS (nal_unit_type==7)?
bool ContainsSps(const uint8_t* data, size_t size) {
  size_t i = 0;
  while (i + 4 < size) {
    // find start code 00 00 01 or 00 00 00 01
    if (data[i] == 0 && data[i + 1] == 0 &&
        (data[i + 2] == 1 || (data[i + 2] == 0 && i + 3 < size && data[i + 3] == 1))) {
      size_t nal = (data[i + 2] == 1) ? i + 3 : i + 4;
      if (nal < size && (data[nal] & 0x1f) == 7) {
        return true;
      }
      i = nal;
    } else {
      ++i;
    }
  }
  return false;
}

class OhosH264Encoder : public webrtc::VideoEncoder {
 public:
  OhosH264Encoder() = default;
  ~OhosH264Encoder() override { Release(); }

  int32_t InitEncode(const webrtc::VideoCodec* codec_settings,
                     const webrtc::VideoEncoder::Settings& settings) override {
    if (!codec_settings || codec_settings->codecType != webrtc::kVideoCodecH264) {
      return WEBRTC_VIDEO_CODEC_ERR_PARAMETER;
    }
    width_ = codec_settings->width;
    height_ = codec_settings->height;
    // Cap at 30: tgcalls advertised 60fps but the software capture path only
    // sustains ~15-30fps; a 60fps rate-control target starves each frame of
    // bits (blur) and confuses the pacer. 30 matches deliverable reality.
    framerate_ = codec_settings->maxFramerate > 0
                     ? std::min<uint32_t>(codec_settings->maxFramerate, 30)
                     : 30;
    bitrate_bps_ = codec_settings->startBitrate * 1000;  // kbps -> bps
    if (bitrate_bps_ == 0) {
      bitrate_bps_ = codec_settings->maxBitrate * 1000;
    }
    if (bitrate_bps_ == 0) {
      bitrate_bps_ = 1200 * 1000;
    }
    return InitCodec();
  }

  int32_t InitCodec() {
    const char* hw = OhosAvcHwEncoderName();
    enc_ = hw ? OH_VideoEncoder_CreateByName(hw)
              : OH_VideoEncoder_CreateByMime(OhosAvcMime());
    if (!enc_) {
      ELOG("create encoder failed (hw=%{public}s)", hw ? hw : "none");
      return WEBRTC_VIDEO_CODEC_ERROR;
    }

    OH_AVCodecCallback cb;
    cb.onError = &OhosH264Encoder::OnError;
    cb.onStreamChanged = &OhosH264Encoder::OnStreamChanged;
    cb.onNeedInputBuffer = &OhosH264Encoder::OnNeedInput;
    cb.onNewOutputBuffer = &OhosH264Encoder::OnNewOutput;
    if (OH_VideoEncoder_RegisterCallback(enc_, cb, this) != AV_ERR_OK) {
      ELOG("RegisterCallback failed");
      return WEBRTC_VIDEO_CODEC_ERROR;
    }

    OH_AVFormat* fmt = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_WIDTH, width_);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_HEIGHT, height_);
    // HW encoders universally accept NV12; feeding I420 to an NV12 pipeline
    // produced all-green output (chroma read as interleaved). Convert to NV12.
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
    OH_AVFormat_SetDoubleValue(fmt, OH_MD_KEY_FRAME_RATE, (double)framerate_);
    OH_AVFormat_SetLongValue(fmt, OH_MD_KEY_BITRATE, (int64_t)bitrate_bps_);
    // CBR: RTC wants a steady rate the bandwidth estimator can reason about.
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_VIDEO_ENCODE_BITRATE_MODE, CBR);
    // Real-time encode: emit each frame immediately, no lookahead buffering.
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);
    // iOS (VideoToolbox) encodes Constrained High: same bitrate, visibly better
    // picture than Baseline (CABAC, 8x8 transform). Payload types carry no fmtp in
    // group calls and every Telegram decoder handles High. Baseline is the fallback
    // when the platform encoder rejects High.
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_PROFILE, AVC_PROFILE_HIGH);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_I_FRAME_INTERVAL,
                            kIFrameIntervalSeconds * 1000);  // ms
    OH_AVErrCode cfg = OH_VideoEncoder_Configure(enc_, fmt);
    if (cfg != AV_ERR_OK) {
      ELOG("Configure with High profile failed err=%{public}d, retrying Baseline", (int)cfg);
      OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_PROFILE, AVC_PROFILE_BASELINE);
      cfg = OH_VideoEncoder_Configure(enc_, fmt);
    }
    OH_AVFormat_Destroy(fmt);
    if (cfg != AV_ERR_OK) {
      ELOG("Configure failed %dx%d err=%d", width_, height_, cfg);
      return WEBRTC_VIDEO_CODEC_ERROR;
    }
    if (OH_VideoEncoder_Prepare(enc_) != AV_ERR_OK) {
      ELOG("Prepare failed");
      return WEBRTC_VIDEO_CODEC_ERROR;
    }
    if (OH_VideoEncoder_Start(enc_) != AV_ERR_OK) {
      ELOG("Start failed");
      return WEBRTC_VIDEO_CODEC_ERROR;
    }
    // Query the encoder's required input buffer geometry; the NV12 planes must
    // be written at this stride/slice-height, not tight width, or the picture
    // shears.
    enc_stride_ = width_;
    enc_slice_ = height_;
    OH_AVFormat* indesc = OH_VideoEncoder_GetInputDescription(enc_);
    if (indesc) {
      int s = 0, sh = 0;
      if (OH_AVFormat_GetIntValue(indesc, OH_MD_KEY_VIDEO_STRIDE, &s) && s > 0)
        enc_stride_ = s;
      if (OH_AVFormat_GetIntValue(indesc, OH_MD_KEY_VIDEO_SLICE_HEIGHT, &sh) && sh > 0)
        enc_slice_ = sh;
      OH_AVFormat_Destroy(indesc);
    }
    running_.store(true);
    error_.store(false);
    ELOG("started %{public}dx%{public}d @%{public}ufps %{public}ubps stride=%{public}d slice=%{public}d (HW AVC NV12)",
         width_, height_, framerate_, bitrate_bps_, enc_stride_, enc_slice_);
    return WEBRTC_VIDEO_CODEC_OK;
  }

  int32_t RegisterEncodeCompleteCallback(
      webrtc::EncodedImageCallback* callback) override {
    std::lock_guard<std::mutex> lock(cb_mutex_);
    callback_ = callback;
    return WEBRTC_VIDEO_CODEC_OK;
  }

  void SetRates(const RateControlParameters& parameters) override {
    if (!running_.load()) return;
    if (parameters.framerate_fps >= 1.0) {
      framerate_ = static_cast<uint32_t>(parameters.framerate_fps + 0.5);
    }
    uint32_t bps = parameters.bitrate.get_sum_bps();
    if (bps == 0) return;  // pause: keep last config, WebRTC stops feeding
    bitrate_bps_ = bps;
    OH_AVFormat* p = OH_AVFormat_Create();
    OH_AVFormat_SetLongValue(p, OH_MD_KEY_BITRATE, (int64_t)bitrate_bps_);
    OH_VideoEncoder_SetParameter(enc_, p);
    OH_AVFormat_Destroy(p);
  }

  int32_t Encode(const webrtc::VideoFrame& frame,
                 const std::vector<webrtc::VideoFrameType>* frame_types) override {
    if (!running_.load() || error_.load()) return WEBRTC_VIDEO_CODEC_ERROR;
    {
      std::lock_guard<std::mutex> lock(cb_mutex_);
      if (!callback_) return WEBRTC_VIDEO_CODEC_UNINITIALIZED;
    }
    bool want_key = false;
    if (frame_types) {
      for (auto t : *frame_types) {
        if (t == webrtc::VideoFrameType::kVideoFrameKey) { want_key = true; break; }
      }
    }
    if (want_key) {
      OH_AVFormat* p = OH_AVFormat_Create();
      OH_AVFormat_SetIntValue(p, OH_MD_KEY_REQUEST_I_FRAME, 1);
      OH_VideoEncoder_SetParameter(enc_, p);
      OH_AVFormat_Destroy(p);
    }

    auto i420 = frame.video_frame_buffer()->ToI420();
    if (!i420) return WEBRTC_VIDEO_CODEC_ENCODER_FAILURE;

    // Non-blocking, reference-style: queue the frame and let the HW's
    // OnNeedInput callback drain it. Never block WebRTC's encoder thread (a
    // blocking wait added ~1 frame of latency). Bounded depth: drop the oldest
    // if the encoder falls behind, so latency can't accumulate.
    PendingFrame pf;
    pf.i420 = i420;
    pf.meta.rtp_ts = frame.timestamp();
    pf.meta.render_ms = frame.render_time_ms();
    pf.meta.ntp_ms = frame.ntp_time_ms();
    pf.meta.color_space = frame.color_space();
    {
      std::lock_guard<std::mutex> lock(in_mutex_);
      if (pending_.size() >= 2) pending_.pop();  // drop oldest, keep latency low
      pending_.push(std::move(pf));
    }
    TryFeed();
    return WEBRTC_VIDEO_CODEC_OK;
  }

  // Pair available HW input buffers with queued frames. Safe to call from the
  // encoder thread (Encode) or the HW callback thread (OnNeedInput).
  void TryFeed() {
    for (;;) {
      uint32_t index;
      OH_AVBuffer* in = nullptr;
      PendingFrame pf;
      {
        std::lock_guard<std::mutex> lock(in_mutex_);
        if (free_in_.empty() || pending_.empty() || !running_.load()) return;
        index = free_in_.front();
        auto it = in_buffers_.find(index);
        if (it == in_buffers_.end()) { free_in_.pop(); continue; }
        in = it->second;
        pf = std::move(pending_.front());
        free_in_.pop();
        pending_.pop();
      }
      uint8_t* dst = OH_AVBuffer_GetAddr(in);
      int cap = OH_AVBuffer_GetCapacity(in);
      const int need = enc_stride_ * enc_slice_ * 3 / 2;
      if (!dst || cap < need) continue;
      uint8_t* dstY = dst;
      uint8_t* dstUV = dst + (size_t)enc_stride_ * enc_slice_;
      libyuv::I420ToNV12(pf.i420->DataY(), pf.i420->StrideY(), pf.i420->DataU(),
                         pf.i420->StrideU(), pf.i420->DataV(), pf.i420->StrideV(),
                         dstY, enc_stride_, dstUV, enc_stride_, width_, height_);
      OH_AVCodecBufferAttr attr;
      attr.pts = pf.meta.rtp_ts;
      attr.size = need;
      attr.offset = 0;
      attr.flags = AVCODEC_BUFFER_FLAGS_NONE;
      OH_AVBuffer_SetBufferAttr(in, &attr);
      {
        std::lock_guard<std::mutex> lock(meta_mutex_);
        meta_.push(pf.meta);
      }
      if (OH_VideoEncoder_PushInputBuffer(enc_, index) != AV_ERR_OK) {
        std::lock_guard<std::mutex> lock(meta_mutex_);
        if (!meta_.empty()) meta_.pop();
      }
    }
  }

  int32_t Release() override {
    running_.store(false);
    in_cv_.notify_all();
    if (enc_) {
      OH_VideoEncoder_Stop(enc_);
      OH_VideoEncoder_Destroy(enc_);
      enc_ = nullptr;
    }
    {
      std::lock_guard<std::mutex> lock(in_mutex_);
      std::queue<uint32_t>().swap(free_in_);
      std::queue<PendingFrame>().swap(pending_);
      in_buffers_.clear();
    }
    {
      std::lock_guard<std::mutex> lock(meta_mutex_);
      std::queue<Meta>().swap(meta_);
    }
    sps_pps_.clear();
    return WEBRTC_VIDEO_CODEC_OK;
  }

  EncoderInfo GetEncoderInfo() const override {
    EncoderInfo info;
    info.implementation_name = "OHOS-AVCodec-H264-HW";
    info.is_hardware_accelerated = true;
    info.supports_native_handle = false;
    info.requested_resolution_alignment = 2;  // chroma-subsampled I420
    return info;
  }

 private:
  struct Meta {
    uint32_t rtp_ts = 0;
    int64_t render_ms = 0;
    int64_t ntp_ms = 0;
    absl::optional<webrtc::ColorSpace> color_space;
  };
  struct PendingFrame {
    rtc::scoped_refptr<webrtc::I420BufferInterface> i420;
    Meta meta;
  };

  static void CopyPlane(uint8_t* dst, int dstStride, const uint8_t* src,
                        int srcStride, int w, int h) {
    for (int r = 0; r < h; ++r) {
      memcpy(dst + (size_t)r * dstStride, src + (size_t)r * srcStride, w);
    }
  }

  // ---- OHOS async callbacks (static trampolines) ----
  static void OnError(OH_AVCodec*, int32_t err, void* user) {
    auto* self = static_cast<OhosH264Encoder*>(user);
    ELOG("encoder error %d", err);
    self->error_.store(true);
  }
  static void OnStreamChanged(OH_AVCodec*, OH_AVFormat*, void*) {}

  static void OnNeedInput(OH_AVCodec*, uint32_t index, OH_AVBuffer* buffer,
                          void* user) {
    auto* self = static_cast<OhosH264Encoder*>(user);
    {
      std::lock_guard<std::mutex> lock(self->in_mutex_);
      self->in_buffers_[index] = buffer;
      self->free_in_.push(index);
    }
    self->TryFeed();
  }

  static void OnNewOutput(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer,
                          void* user) {
    auto* self = static_cast<OhosH264Encoder*>(user);
    self->HandleOutput(codec, index, buffer);
  }

  void HandleOutput(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer) {
    OH_AVCodecBufferAttr attr;
    if (OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK) {
      OH_VideoEncoder_FreeOutputBuffer(codec, index);
      return;
    }
    const uint8_t* data = OH_AVBuffer_GetAddr(buffer);
    if (!data || attr.size <= 0) {
      OH_VideoEncoder_FreeOutputBuffer(codec, index);
      return;
    }
    const uint8_t* payload = data + attr.offset;
    size_t len = (size_t)attr.size;

    if (attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA) {
      // SPS/PPS parameter sets: cache, don't deliver, don't consume a meta.
      sps_pps_.assign(payload, payload + len);
      OH_VideoEncoder_FreeOutputBuffer(codec, index);
      return;
    }

    bool key = (attr.flags & AVCODEC_BUFFER_FLAGS_SYNC_FRAME) != 0;

    Meta m;
    {
      std::lock_guard<std::mutex> lock(meta_mutex_);
      if (!meta_.empty()) { m = meta_.front(); meta_.pop(); }
    }

    // Assemble Annex-B: WebRTC needs SPS+PPS ahead of each IDR.
    std::vector<uint8_t> out;
    if (key && !sps_pps_.empty() && !ContainsSps(payload, len)) {
      out.reserve(sps_pps_.size() + len);
      out.insert(out.end(), sps_pps_.begin(), sps_pps_.end());
      out.insert(out.end(), payload, payload + len);
    } else {
      out.assign(payload, payload + len);
    }
    OH_VideoEncoder_FreeOutputBuffer(codec, index);

    webrtc::EncodedImage image;
    image.SetEncodedData(
        webrtc::EncodedImageBuffer::Create(out.data(), out.size()));
    image._encodedWidth = width_;
    image._encodedHeight = height_;
    image.SetRtpTimestamp(m.rtp_ts);
    image.capture_time_ms_ = m.render_ms;
    image.ntp_time_ms_ = m.ntp_ms;
    image._frameType = key ? webrtc::VideoFrameType::kVideoFrameKey
                           : webrtc::VideoFrameType::kVideoFrameDelta;
    if (m.color_space) image.SetColorSpace(m.color_space);

    bitstream_parser_.ParseBitstream(image);
    image.qp_ = bitstream_parser_.GetLastSliceQp().value_or(-1);

    webrtc::CodecSpecificInfo csi;
    csi.codecType = webrtc::kVideoCodecH264;
    csi.codecSpecific.H264.packetization_mode =
        webrtc::H264PacketizationMode::NonInterleaved;  // mode 1
    csi.codecSpecific.H264.temporal_idx = webrtc::kNoTemporalIdx;
    csi.codecSpecific.H264.idr_frame = key;
    csi.codecSpecific.H264.base_layer_sync = false;

    std::lock_guard<std::mutex> lock(cb_mutex_);
    if (callback_) callback_->OnEncodedImage(image, &csi);
  }

  OH_AVCodec* enc_ = nullptr;
  int width_ = 0, height_ = 0;
  int enc_stride_ = 0, enc_slice_ = 0;  // encoder input buffer geometry
  uint32_t framerate_ = 30;
  uint32_t bitrate_bps_ = 0;

  std::atomic<bool> running_{false};
  std::atomic<bool> error_{false};

  std::mutex cb_mutex_;
  webrtc::EncodedImageCallback* callback_ = nullptr;

  std::mutex in_mutex_;
  std::condition_variable in_cv_;
  std::queue<uint32_t> free_in_;
  std::map<uint32_t, OH_AVBuffer*> in_buffers_;
  std::queue<PendingFrame> pending_;

  std::mutex meta_mutex_;
  std::queue<Meta> meta_;

  std::vector<uint8_t> sps_pps_;
  webrtc::H264BitstreamParser bitstream_parser_;
};

}  // namespace

std::unique_ptr<webrtc::VideoEncoder> CreateOhosH264Encoder(
    const webrtc::SdpVideoFormat& /*format*/) {
  return std::make_unique<OhosH264Encoder>();
}

}  // namespace tgcalls_ohos
