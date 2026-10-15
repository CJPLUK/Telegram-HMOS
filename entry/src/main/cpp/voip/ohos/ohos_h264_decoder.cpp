// OHOS hardware H.264 decoder implementing webrtc::VideoDecoder.
//
// Feed Annex-B H264 (SPS/PPS inline on keyframes, as WebRTC's depacketizer
// delivers) into the HW decoder; it emits frames on its own thread which we
// wrap as I420 VideoFrames. HW decoders on this SoC output NV12 with an aligned
// stride/slice-height, so we read those from the OnStreamChanged format and
// libyuv-convert to the tightly-packed I420 WebRTC expects. The input pts (set
// to the RTP timestamp) rides through the decoder and comes back on the output
// buffer, correlating output->input without a side FIFO.

#include "ohos_h264_internal.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <map>
#include <mutex>
#include <queue>
#include <vector>

#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avbuffer_info.h>
#include <multimedia/player_framework/native_avformat.h>
#include <native_window/external_window.h>
#include <hilog/log.h>

#include "third_party/libyuv/include/libyuv.h"
#include "rtc_base/time_utils.h"
#include "api/video/i420_buffer.h"
#include "api/video/video_frame.h"
#include "api/video_codecs/video_decoder.h"
#include "modules/video_coding/include/video_error_codes.h"

namespace tgcalls_ohos {
namespace {

#define DLOG(fmt, ...) \
  OH_LOG_Print(LOG_APP, LOG_INFO, 0, "tgcalls_ohos", "[h264dec] " fmt, ##__VA_ARGS__)

class OhosH264Decoder : public webrtc::VideoDecoder {
 public:
  OhosH264Decoder() = default;
  ~OhosH264Decoder() override { Release(); }

  bool Configure(const Settings& settings) override {
    auto res = settings.max_render_resolution();
    width_ = res.Width() > 0 ? res.Width() : 1280;
    height_ = res.Height() > 0 ? res.Height() : 720;
    stride_ = width_;
    slice_height_ = height_;
    out_pixfmt_ = AV_PIXEL_FORMAT_NV12;
    return InitCodec() == WEBRTC_VIDEO_CODEC_OK;
  }

  int32_t InitCodec() {
    const char* hw = OhosAvcHwDecoderName();
    dec_ = hw ? OH_VideoDecoder_CreateByName(hw)
              : OH_VideoDecoder_CreateByMime(OhosAvcMime());
    if (!dec_) { DLOG("create decoder failed (hw=%{public}s)", hw ? hw : "none"); return WEBRTC_VIDEO_CODEC_ERROR; }

    OH_AVCodecCallback cb;
    cb.onError = &OhosH264Decoder::OnError;
    cb.onStreamChanged = &OhosH264Decoder::OnStreamChanged;
    cb.onNeedInputBuffer = &OhosH264Decoder::OnNeedInput;
    cb.onNewOutputBuffer = &OhosH264Decoder::OnNewOutput;
    if (OH_VideoDecoder_RegisterCallback(dec_, cb, this) != AV_ERR_OK) {
      DLOG("RegisterCallback failed"); return WEBRTC_VIDEO_CODEC_ERROR;
    }

    bound_generation_ = GetRemoteSurfaceGeneration();
    void* surface = GetRemoteRenderSurface();
    surface_mode_ = false;

    OH_AVFormat* fmt = OH_AVFormat_Create();
    // Size the codec for the largest stream it may be switched to, not for the
    // first frames. Group calls start on the 180p simulcast layer and move up to
    // 720p in place; input buffers sized for 180p are too small for a 720p access
    // unit, and that wedged the decoder on device (see TryFeed).
    const int cfg_w = width_ > 1280 ? width_ : 1280;
    const int cfg_h = height_ > 1280 ? height_ : 1280;   // portrait or landscape
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_WIDTH, cfg_w);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_HEIGHT, cfg_h);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_MAX_INPUT_SIZE, 2 * 1024 * 1024);
    // Real-time decode: output each picture as soon as it is decoded instead of
    // holding it for display reordering. Without this the HW releases frames late
    // and in batches; WebRTC only remembers the last 10 submitted frames
    // (kDecoderFrameMemoryLength), so a late batch comes back with no matching
    // record and is discarded ("Too many frames backed up in the decoder") — on
    // device that was 8 consecutive frames gone per burst, i.e. visible stutter.
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
    // Surface mode renders the decoded picture as-is, bypassing the CPU sink's
    // I420Buffer::Rotate of the RTP CVO rotation — tell the codec/compositor to
    // rotate at render instead. Buffer mode must NOT set this (sink rotates).
    if (surface && want_rotation_deg_ != 0) {
      OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_ROTATION, want_rotation_deg_);
      DLOG("configure rotation=%{public}d", want_rotation_deg_);
    }
    applied_rotation_deg_ = surface ? want_rotation_deg_ : 0;
    OH_AVErrCode cfg = OH_VideoDecoder_Configure(dec_, fmt);
    OH_AVFormat_Destroy(fmt);
    if (cfg != AV_ERR_OK) { DLOG("Configure failed"); return WEBRTC_VIDEO_CODEC_ERROR; }

    // Surface mode: if a render surface (XComponent NativeWindow) is set, bind
    // it so the HW decoder composites frames straight to the display (GPU, zero
    // CPU copy). Must be after Configure, before Prepare. Falls back to the CPU
    // buffer path when no surface is present, so nothing breaks pre-migration.
    if (surface) {
      OH_AVErrCode se = OH_VideoDecoder_SetSurface(
          dec_, static_cast<OHNativeWindow*>(surface));
      surface_mode_ = (se == AV_ERR_OK);
      DLOG("SetSurface %{public}s -> surface_mode=%{public}d", se == AV_ERR_OK ? "ok" : "FAIL", surface_mode_);
      if (surface_mode_) {
        // Re-assert aspect-preserving fill after codec binding — the codec's
        // producer connect can reset scaling back to SCALE_TO_WINDOW (stretch).
        int32_t sm = OH_NativeWindow_NativeWindowSetScalingModeV2(
            static_cast<OHNativeWindow*>(surface), OH_SCALING_MODE_SCALE_CROP_V2);
        DLOG("scaling mode SCALE_CROP_V2 -> %{public}d", sm);
      }
    }

    if (OH_VideoDecoder_Prepare(dec_) != AV_ERR_OK) return WEBRTC_VIDEO_CODEC_ERROR;
    if (OH_VideoDecoder_Start(dec_) != AV_ERR_OK) return WEBRTC_VIDEO_CODEC_ERROR;
    running_.store(true);
    error_.store(false);
    DLOG("started (HW AVC decoder, surface_mode=%{public}d)", surface_mode_);
    return WEBRTC_VIDEO_CODEC_OK;
  }

  int32_t RegisterDecodeCompleteCallback(
      webrtc::DecodedImageCallback* callback) override {
    std::lock_guard<std::mutex> lock(cb_mutex_);
    callback_ = callback;
    return WEBRTC_VIDEO_CODEC_OK;
  }

  int32_t Decode(const webrtc::EncodedImage& input, bool /*missing*/,
                 int64_t /*render_time_ms*/) override {
    if (!running_.load() || error_.load()) return WEBRTC_VIDEO_CODEC_ERROR;
    if (input.size() == 0 || !input.data()) return WEBRTC_VIDEO_CODEC_ERROR;

    // Track the RTP CVO rotation of the incoming stream (iOS sends portrait
    // video as rotated landscape + rotation metadata).
    want_rotation_deg_ = RotationDeg(input.rotation_);

    // Rebuild the codec when (a) the surface binding changed since this codec
    // instance was configured (a new XComponent shell bound its surface, or the
    // old one was torn down — the codec pins the NativeWindow it was prepared
    // with and would keep rendering into an invisible/dead surface forever), or
    // (b) surface mode's render rotation no longer matches the stream rotation.
    // Then restart from the next keyframe.
    if (GetRemoteSurfaceGeneration() != bound_generation_ ||
        (surface_mode_ && want_rotation_deg_ != applied_rotation_deg_)) {
      DLOG("reinit: gen %{public}llu->%{public}llu rot %{public}d->%{public}d",
           (unsigned long long)bound_generation_,
           (unsigned long long)GetRemoteSurfaceGeneration(),
           applied_rotation_deg_, want_rotation_deg_);
      Release();
      if (InitCodec() != WEBRTC_VIDEO_CODEC_OK) return WEBRTC_VIDEO_CODEC_ERROR;
      need_keyframe_ = true;
    }
    if (need_keyframe_) {
      if (input._frameType != webrtc::VideoFrameType::kVideoFrameKey)
        return WEBRTC_VIDEO_CODEC_ERROR;  // ask WebRTC for a keyframe (PLI)
      need_keyframe_ = false;
    }

    // Back-pressure. WebRTC remembers only the last 10 frames handed to Decode()
    // (kDecoderFrameMemoryLength); a frame that comes back after 10 newer ones were
    // submitted has no record left and is discarded ("Too many frames backed up in
    // the decoder"). The network delivers clumps (on device: 37 frames in one
    // second, every ~7s), WebRTC pushes the whole clump at once, and an async HW
    // decoder then loses the head of it — 8 frames gone per clump, visible stutter.
    // A software decoder never sees this because Decode() is synchronous. Do the
    // same in effect: keep at most kMaxInFlight frames between submit and output.
    // The HW decodes 720p in a few ms, so this wait is short; the timeout is a
    // safety net for access units that never produce a picture.
    {
      std::unique_lock<std::mutex> lock(flight_mutex_);
      const int64_t wait_t0 = rtc::TimeMillis();
      lat_inflight_sum_ += in_flight_;
      const bool ok = flight_cv_.wait_for(lock, std::chrono::milliseconds(120),
                                          [this] { return in_flight_ < kMaxInFlight || !running_.load(); });
      {
        const int64_t w = rtc::TimeMillis() - wait_t0;
        lat_wait_sum_ += w;
        if (w > lat_wait_max_.load()) lat_wait_max_.store(w);
      }
      if (!ok) {
        if (flight_timeouts_++ < 5) DLOG("in-flight wait timed out (in_flight=%{public}d), resetting", in_flight_);
        in_flight_ = 0;
      }
      in_flight_++;
    }

    // Copy the access unit into the pending queue and let the HW's OnNeedInput
    // callback drain it.
    PendingInput pi;
    pi.data.assign(input.data(), input.data() + input.size());
    pi.pts = input.RtpTimestamp();
    pi.key = input._frameType == webrtc::VideoFrameType::kVideoFrameKey;
    {
      std::lock_guard<std::mutex> lock(in_mutex_);
      // Queue depth. In steady state the HW keeps up and this stays at 0-1. It
      // only fills while the codec reconfigures itself for a new resolution — a
      // simulcast layer switch, which group calls do several times (180p -> 360p
      // -> 720p on join, and again whenever bandwidth moves). That pause is a few
      // hundred ms. With the old cap of 3 the frames arriving meanwhile were shed,
      // the reference chain broke, and the stream froze until a PLI keyframe came
      // (up to 3s on device). Hold them instead: the codec drains the backlog
      // faster than real time, so the cost is one short pause, not a freeze.
      // Only a genuine stall (>1.5s of input) resets and asks for a keyframe.
      constexpr size_t kMaxPending = 45;
      if (pending_.size() < kMaxPending) {
        pending_.push(std::move(pi));
      } else {
        std::queue<PendingInput>().swap(pending_);
        {
          std::lock_guard<std::mutex> fl(flight_mutex_);
          in_flight_ = 0;
        }
        n_drop_ += (int)kMaxPending;
        need_keyframe_ = true;
        DLOG("input stalled: flushed %{public}d queued frames, waiting for keyframe", (int)kMaxPending);
        return WEBRTC_VIDEO_CODEC_ERROR;
      }
    }
    n_in_++;
    TryFeed();
    return WEBRTC_VIDEO_CODEC_OK;
  }

  void TryFeed() {
    for (;;) {
      uint32_t index;
      OH_AVBuffer* in = nullptr;
      PendingInput pi;
      {
        std::lock_guard<std::mutex> lock(in_mutex_);
        if (free_in_.empty() || pending_.empty() || !running_.load()) return;
        index = free_in_.front();
        auto it = in_buffers_.find(index);
        if (it == in_buffers_.end()) { free_in_.pop(); continue; }
        in = it->second;
        pi = std::move(pending_.front());
        free_in_.pop();
        pending_.pop();
      }
      uint8_t* dst = OH_AVBuffer_GetAddr(in);
      int cap = OH_AVBuffer_GetCapacity(in);
      if (!dst || cap < (int)pi.data.size()) {
        // The access unit does not fit. Put the input slot BACK: the old code just
        // `continue`d, leaking one slot per oversized frame until the codec had no
        // input buffers left and never produced another frame (frozen picture,
        // "Too many frames backed up in the decoder").
        DLOG("input too large: au=%{public}d cap=%{public}d, dropping + keyframe", (int)pi.data.size(), cap);
        {
          std::lock_guard<std::mutex> lock(in_mutex_);
          free_in_.push(index);
        }
        need_keyframe_ = true;
        n_drop_++;
        return;
      }
      memcpy(dst, pi.data.data(), pi.data.size());
      OH_AVCodecBufferAttr attr;
      attr.pts = pi.pts;
      attr.size = (int32_t)pi.data.size();
      attr.offset = 0;
      attr.flags = pi.key ? AVCODEC_BUFFER_FLAGS_SYNC_FRAME
                          : AVCODEC_BUFFER_FLAGS_NONE;
      OH_AVBuffer_SetBufferAttr(in, &attr);
      {
        std::lock_guard<std::mutex> lock(lat_mutex_);
        push_time_[(uint32_t)pi.pts] = rtc::TimeMillis();
        if (push_time_.size() > 64) push_time_.erase(push_time_.begin());
      }
      OH_VideoDecoder_PushInputBuffer(dec_, index);
    }
  }

  int32_t Release() override {
    running_.store(false);
    in_cv_.notify_all();
    {
      std::lock_guard<std::mutex> lock(flight_mutex_);
      in_flight_ = 0;
    }
    flight_cv_.notify_all();
    if (dec_) {
      OH_VideoDecoder_Stop(dec_);
      OH_VideoDecoder_Destroy(dec_);
      dec_ = nullptr;
    }
    std::lock_guard<std::mutex> lock(in_mutex_);
    std::queue<uint32_t>().swap(free_in_);
    std::queue<PendingInput>().swap(pending_);
    in_buffers_.clear();
    return WEBRTC_VIDEO_CODEC_OK;
  }

  DecoderInfo GetDecoderInfo() const override {
    DecoderInfo info;
    info.implementation_name = "OHOS-AVCodec-H264-HW";
    info.is_hardware_accelerated = true;
    return info;
  }
  const char* ImplementationName() const override { return "OHOS-AVCodec-H264-HW"; }

 private:
  static void OnError(OH_AVCodec*, int32_t err, void* user) {
    auto* self = static_cast<OhosH264Decoder*>(user);
    DLOG("decoder error %d", err);
    self->error_.store(true);
  }
  static void OnStreamChanged(OH_AVCodec*, OH_AVFormat* format, void* user) {
    auto* self = static_cast<OhosH264Decoder*>(user);
    int w = 0, h = 0, stride = 0, sh = 0, pf = 0;
    int cl = 0, cr = 0, ct = 0, cb = 0;
    if (OH_AVFormat_GetIntValue(format, OH_MD_KEY_WIDTH, &w) && w > 0) self->width_ = w;
    if (OH_AVFormat_GetIntValue(format, OH_MD_KEY_HEIGHT, &h) && h > 0) self->height_ = h;
    if (OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_STRIDE, &stride) && stride > 0)
      self->stride_ = stride;
    else
      self->stride_ = self->width_;
    if (OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_SLICE_HEIGHT, &sh) && sh > 0)
      self->slice_height_ = sh;
    else
      self->slice_height_ = self->height_;
    if (OH_AVFormat_GetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, &pf) && pf > 0)
      self->out_pixfmt_ = pf;
    // Crop rectangle: the visible image can be inset from the (aligned) coded
    // frame; ignoring it leaves a green strip along the padded edge.
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_CROP_LEFT, &cl);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_CROP_RIGHT, &cr);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_CROP_TOP, &ct);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_CROP_BOTTOM, &cb);
    self->crop_left_ = cl > 0 ? cl : 0;
    self->crop_top_ = ct > 0 ? ct : 0;
    // CROP_RIGHT/BOTTOM are inclusive last-column indices on OHOS; derive the
    // visible extent from them when present.
    self->disp_w_ = (cr > cl) ? (cr - cl + 1) : self->width_;
    self->disp_h_ = (cb > ct) ? (cb - ct + 1) : self->height_;
    DLOG("stream changed coded=%{public}dx%{public}d disp=%{public}dx%{public}d "
         "stride=%{public}d sh=%{public}d pf=%{public}d crop=l%{public}d,t%{public}d,r%{public}d,b%{public}d",
         self->width_, self->height_, self->disp_w_, self->disp_h_, self->stride_,
         self->slice_height_, self->out_pixfmt_, cl, ct, cr, cb);
  }
  static void OnNeedInput(OH_AVCodec*, uint32_t index, OH_AVBuffer* buffer,
                          void* user) {
    auto* self = static_cast<OhosH264Decoder*>(user);
    {
      std::lock_guard<std::mutex> lock(self->in_mutex_);
      self->in_buffers_[index] = buffer;
      self->free_in_.push(index);
    }
    self->TryFeed();
  }
  static void OnNewOutput(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer,
                          void* user) {
    static_cast<OhosH264Decoder*>(user)->HandleOutput(codec, index, buffer);
  }

  void HandleOutput(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer) {
    OH_AVCodecBufferAttr attr;
    if (OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK) {
      OH_VideoDecoder_FreeOutputBuffer(codec, index);
      return;
    }
    {
      std::lock_guard<std::mutex> lock(lat_mutex_);
      auto it = push_time_.find((uint32_t)attr.pts);
      if (it != push_time_.end()) {
        const int64_t hw = rtc::TimeMillis() - it->second;
        lat_hw_sum_ += hw;
        if (hw > lat_hw_max_) lat_hw_max_ = hw;
        lat_hw_n_++;
        push_time_.erase(it);
      }
    }

    if (surface_mode_) {
      // GPU zero-copy: composite straight to the XComponent surface. No CPU read
      // of the frame at all. Then hand WebRTC a tiny placeholder frame (correct
      // rtp timestamp) so its receive stream stays alive for A/V sync / stats /
      // freeze detection — without it WebRTC would spam keyframe requests.
      uint32_t rtp_ts = (uint32_t)attr.pts;
      OH_VideoDecoder_RenderOutputBuffer(codec, index);
      DeliverPlaceholder(rtp_ts);
      CountOut();
      return;
    }

    const uint8_t* src = OH_AVBuffer_GetAddr(buffer);
    if (!src || attr.size <= 0 || width_ <= 0 || height_ <= 0) {
      OH_VideoDecoder_FreeOutputBuffer(codec, index);
      return;
    }
    const int stride = stride_ > 0 ? stride_ : width_;
    const int sh = slice_height_ > 0 ? slice_height_ : height_;
    const int w = disp_w_ > 0 ? disp_w_ : width_;
    const int h = disp_h_ > 0 ? disp_h_ : height_;
    const int cl = crop_left_, ct = crop_top_;

    rtc::scoped_refptr<webrtc::I420Buffer> i420 = webrtc::I420Buffer::Create(w, h);
    if (out_pixfmt_ == AV_PIXEL_FORMAT_YUVI420) {
      const uint8_t* sy = src + (size_t)ct * stride + cl;
      const uint8_t* su = src + (size_t)stride * sh +
                          (size_t)(ct / 2) * (stride / 2) + (cl / 2);
      const uint8_t* sv = src + (size_t)stride * sh +
                          (size_t)(stride / 2) * (sh / 2) +
                          (size_t)(ct / 2) * (stride / 2) + (cl / 2);
      libyuv::I420Copy(sy, stride, su, stride / 2, sv, stride / 2,
                       i420->MutableDataY(), i420->StrideY(),
                       i420->MutableDataU(), i420->StrideU(),
                       i420->MutableDataV(), i420->StrideV(), w, h);
    } else {
      // NV12 (default HW output): Y plane then interleaved UV, both at `stride`.
      const uint8_t* sy = src + (size_t)ct * stride + cl;
      const uint8_t* suv = src + (size_t)stride * sh +
                           (size_t)(ct / 2) * stride + cl;
      libyuv::NV12ToI420(sy, stride, suv, stride,
                         i420->MutableDataY(), i420->StrideY(),
                         i420->MutableDataU(), i420->StrideU(),
                         i420->MutableDataV(), i420->StrideV(), w, h);
    }
    uint32_t rtp_ts = (uint32_t)attr.pts;
    OH_VideoDecoder_FreeOutputBuffer(codec, index);
    {
      // Diagnostic: RTC streams have no B-frames, so output must be monotonic.
      const uint32_t last = last_out_ts_.exchange(rtp_ts);
      if (last != 0 && (int32_t)(rtp_ts - last) < 0 && ooo_logged_.fetch_add(1) < 10) {
        DLOG("out-of-order output: ts=%{public}u after %{public}u", rtp_ts, last);
      }
    }

    webrtc::VideoFrame frame = webrtc::VideoFrame::Builder()
                                   .set_video_frame_buffer(i420)
                                   .set_timestamp_rtp(rtp_ts)
                                   .build();
    {
      std::lock_guard<std::mutex> lock(cb_mutex_);
      if (callback_) callback_->Decoded(frame);
    }
    CountOut();
  }

  // Keep WebRTC's receive stream alive in surface mode by delivering a tiny
  // frame carrying the real rtp timestamp (for A/V sync) but no decoded pixels
  // (those went to the GPU surface). Reused 16x16 black buffer — negligible cost.
  void DeliverPlaceholder(uint32_t rtp_ts) {
    if (!placeholder_) {
      placeholder_ = webrtc::I420Buffer::Create(16, 16);
      webrtc::I420Buffer::SetBlack(placeholder_.get());  // not uninitialized garbage
    }
    webrtc::VideoFrame frame = webrtc::VideoFrame::Builder()
                                   .set_video_frame_buffer(placeholder_)
                                   .set_timestamp_rtp(rtp_ts)
                                   .build();
    std::lock_guard<std::mutex> lock(cb_mutex_);
    if (callback_) callback_->Decoded(frame);
  }

  // Per-second throughput probe: in/out/drop rates + queue depth.
  void ReleaseFlightSlot() {
    {
      std::lock_guard<std::mutex> lock(flight_mutex_);
      if (in_flight_ > 0) in_flight_--;
    }
    flight_cv_.notify_one();
  }

  void CountOut() {
    ReleaseFlightSlot();
    int64_t n = ++n_out_;
    int64_t now = rtc::TimeMillis();
    // Health line every 10 s (was every second during bring-up); counters cover that window.
    if (now - last_log_ms_ >= 10000) {
      size_t depth;
      { std::lock_guard<std::mutex> l(in_mutex_); depth = pending_.size(); }
      const long long in_n = (long long)n_in_.exchange(0);
      long long wait_sum, wait_max, inflight_sum, hw_sum, hw_max, hw_n;
      {
        std::lock_guard<std::mutex> lock(lat_mutex_);
        wait_sum = lat_wait_sum_.exchange(0); wait_max = lat_wait_max_.exchange(0); inflight_sum = lat_inflight_sum_.exchange(0);
        hw_sum = lat_hw_sum_; hw_max = lat_hw_max_; hw_n = lat_hw_n_;
        lat_hw_sum_ = lat_hw_max_ = lat_hw_n_ = 0;
      }
      DLOG("rate/10s: in=%{public}lld out=%{public}lld drop=%{public}lld pending=%{public}zu surf=%{public}d (%{public}dx%{public}d)"
           " decode_wait_avg=%{public}lldms max=%{public}lldms inflight_avg=%{public}.1f hw_lat_avg=%{public}lldms max=%{public}lldms",
           in_n, (long long)(n - last_out_),
           (long long)n_drop_.exchange(0), depth, surface_mode_ ? 1 : 0, disp_w_, disp_h_,
           in_n > 0 ? wait_sum / in_n : 0, wait_max, in_n > 0 ? (double)inflight_sum / in_n : 0.0,
           hw_n > 0 ? hw_sum / hw_n : 0, hw_max);
      last_out_ = n;
      last_log_ms_ = now;
    }
  }

  static int RotationDeg(webrtc::VideoRotation r) {
    switch (r) {
      case webrtc::kVideoRotation_90: return 90;
      case webrtc::kVideoRotation_180: return 180;
      case webrtc::kVideoRotation_270: return 270;
      default: return 0;
    }
  }

  OH_AVCodec* dec_ = nullptr;
  bool surface_mode_ = false;
  uint64_t bound_generation_ = 0;
  std::atomic<bool> need_keyframe_{false};
  static constexpr int kMaxInFlight = 6;
  std::mutex flight_mutex_;
  std::condition_variable flight_cv_;
  int in_flight_ = 0;
  int flight_timeouts_ = 0;
  std::atomic<uint32_t> last_out_ts_{0};
  std::atomic<int> ooo_logged_{0};
  int want_rotation_deg_ = 0;
  int applied_rotation_deg_ = 0;
  rtc::scoped_refptr<webrtc::I420Buffer> placeholder_;
  int width_ = 0, height_ = 0, stride_ = 0, slice_height_ = 0;
  int disp_w_ = 0, disp_h_ = 0, crop_left_ = 0, crop_top_ = 0;
  int out_pixfmt_ = AV_PIXEL_FORMAT_NV12;

  std::atomic<int64_t> n_in_{0}, n_out_{0}, n_drop_{0};
  // Latency diagnostics (10 s windows): time Decode() blocks on the in-flight cap,
  // in-flight depth at entry, and HW push->output latency keyed by rtp timestamp.
  std::mutex lat_mutex_;
  std::map<uint32_t, int64_t> push_time_;
  std::atomic<int64_t> lat_wait_sum_{0}, lat_wait_max_{0}, lat_inflight_sum_{0};   // written under flight_mutex_
  int64_t lat_hw_sum_ = 0, lat_hw_max_ = 0, lat_hw_n_ = 0;
  int64_t last_out_ = 0, last_log_ms_ = 0;

  std::atomic<bool> running_{false};
  std::atomic<bool> error_{false};

  std::mutex cb_mutex_;
  webrtc::DecodedImageCallback* callback_ = nullptr;

  struct PendingInput {
    std::vector<uint8_t> data;
    int64_t pts = 0;
    bool key = false;
  };

  std::mutex in_mutex_;
  std::condition_variable in_cv_;
  std::queue<uint32_t> free_in_;
  std::map<uint32_t, OH_AVBuffer*> in_buffers_;
  std::queue<PendingInput> pending_;
};

}  // namespace

std::unique_ptr<webrtc::VideoDecoder> CreateOhosH264Decoder() {
  return std::make_unique<OhosH264Decoder>();
}

}  // namespace tgcalls_ohos
