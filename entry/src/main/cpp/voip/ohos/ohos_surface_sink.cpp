#include "ohos_surface_sink.h"

#include <hilog/log.h>
#include <native_buffer/native_buffer.h>
#include <native_window/external_window.h>
#include <sys/mman.h>
#include <unistd.h>

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>

#include "absl/types/optional.h"
#include "api/video/i420_buffer.h"
#include "libyuv.h"
#include "rtc_base/time_utils.h"

namespace tgcalls_ohos {
namespace {

#define SLOG(fmt, ...) OH_LOG_Print(LOG_APP, LOG_INFO, 0, "tgcalls_ohos", "[surface] " fmt, ##__VA_ARGS__)

class SurfaceFrameSinkImpl final : public SurfaceFrameSink {
 public:
  SurfaceFrameSinkImpl(OHNativeWindow* window, bool mirror, std::string tag)
      : window_(window), mirror_(mirror), tag_(std::move(tag)) {
    thread_ = std::thread([this] { Loop(); });
  }

  ~SurfaceFrameSinkImpl() override {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stop_ = true;
    }
    cv_.notify_all();
    if (thread_.joinable()) {
      thread_.join();
    }
    if (window_) {
      OH_NativeWindow_DestroyNativeWindow(window_);
      window_ = nullptr;
    }
    SLOG("%{public}s: released after %{public}lld frames", tag_.c_str(), (long long)frames_.load());
  }

  void OnFrame(const webrtc::VideoFrame& frame) override {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      latest_ = frame;  // refcounted buffer, no pixel copy
    }
    cv_.notify_one();
  }

 private:
  void Loop() {
    for (;;) {
      absl::optional<webrtc::VideoFrame> frame;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait(lock, [this] { return latest_.has_value() || stop_; });
        if (stop_) {
          return;
        }
        frame = std::move(latest_);
        latest_.reset();
      }
      const int64_t now = rtc::TimeMillis();
      // Only guard against bursts. A 30ms gate dropped every frame that arrived a
      // few ms early (33ms cadence + network jitter), which showed up as judder.
      if (now - last_ms_ < 12) {
        continue;
      }
      last_ms_ = now;
      Render(*frame);
    }
  }

  void Render(const webrtc::VideoFrame& frame) {
    webrtc::scoped_refptr<webrtc::I420BufferInterface> i420 = frame.video_frame_buffer()->ToI420();
    if (!i420) {
      return;
    }
    if (frame.rotation() != webrtc::kVideoRotation_0) {
      i420 = webrtc::I420Buffer::Rotate(*i420, frame.rotation());
    }
    const int w = i420->width();
    const int h = i420->height();
    if (w <= 0 || h <= 0 || !window_) {
      return;
    }
    if (w != width_ || h != height_) {
      OH_NativeWindow_NativeWindowHandleOpt(window_, SET_BUFFER_GEOMETRY, w, h);
      OH_NativeWindow_NativeWindowHandleOpt(window_, SET_FORMAT, NATIVEBUFFER_PIXEL_FMT_RGBA_8888);
      OH_NativeWindow_NativeWindowHandleOpt(
          window_, SET_USAGE,
          NATIVEBUFFER_USAGE_CPU_READ | NATIVEBUFFER_USAGE_CPU_WRITE | NATIVEBUFFER_USAGE_MEM_DMA);
      width_ = w;
      height_ = h;
      SLOG("%{public}s: geometry %{public}dx%{public}d", tag_.c_str(), w, h);
    }
    OHNativeWindowBuffer* buffer = nullptr;
    int fence = -1;
    if (OH_NativeWindow_NativeWindowRequestBuffer(window_, &buffer, &fence) != 0 || !buffer) {
      return;
    }
    if (fence >= 0) {
      close(fence);
    }
    BufferHandle* handle = OH_NativeWindow_GetBufferHandleFromNative(buffer);
    if (!handle || handle->size <= 0) {
      OH_NativeWindow_NativeWindowAbortBuffer(window_, buffer);
      return;
    }
    // ArkUI may resize the XComponent (grid relayout, expand/collapse) and then
    // hands out buffers with ITS geometry, not the one we set. Writing a larger
    // frame into such a buffer ran off the mapping (SIGSEGV SEGV_MAPERR, seen on
    // device when the second tile appeared). Never trust the cached geometry:
    // check this very buffer, and if it does not fit, drop the frame and re-assert.
    {
      const int bstride = handle->stride > 0 ? handle->stride : handle->width * 4;
      const int64_t needed = (int64_t)(h - 1) * bstride + (int64_t)w * 4;
      if (handle->width != w || handle->height != h || bstride < w * 4 || needed > (int64_t)handle->size) {
        OH_NativeWindow_NativeWindowAbortBuffer(window_, buffer);
        width_ = 0;   // forces SET_BUFFER_GEOMETRY again on the next frame
        height_ = 0;
        if (mismatches_.fetch_add(1) < 5) {
          SLOG("%{public}s: buffer %{public}dx%{public}d stride=%{public}d size=%{public}d does not fit frame %{public}dx%{public}d, re-asserting geometry",
               tag_.c_str(), handle->width, handle->height, bstride, handle->size, w, h);
        }
        return;
      }
    }
    void* mapped = mmap(nullptr, (size_t)handle->size, PROT_READ | PROT_WRITE, MAP_SHARED, handle->fd, 0);
    if (mapped == MAP_FAILED) {
      OH_NativeWindow_NativeWindowAbortBuffer(window_, buffer);
      return;
    }
    const int stride = handle->stride > 0 ? handle->stride : w * 4;
    // libyuv "ABGR" = little-endian ABGR word = R,G,B,A bytes = RGBA_8888.
    // Negative width mirrors horizontally in libyuv conversions that support it;
    // I420ToABGR does not, so mirror the planes first when requested.
    if (mirror_) {
      webrtc::scoped_refptr<webrtc::I420Buffer> flipped = webrtc::I420Buffer::Create(w, h);
      libyuv::I420Mirror(i420->DataY(), i420->StrideY(), i420->DataU(), i420->StrideU(), i420->DataV(),
                         i420->StrideV(), flipped->MutableDataY(), flipped->StrideY(),
                         flipped->MutableDataU(), flipped->StrideU(), flipped->MutableDataV(),
                         flipped->StrideV(), w, h);
      libyuv::I420ToABGR(flipped->DataY(), flipped->StrideY(), flipped->DataU(), flipped->StrideU(),
                         flipped->DataV(), flipped->StrideV(), static_cast<uint8_t*>(mapped), stride, w, h);
    } else {
      libyuv::I420ToABGR(i420->DataY(), i420->StrideY(), i420->DataU(), i420->StrideU(), i420->DataV(),
                         i420->StrideV(), static_cast<uint8_t*>(mapped), stride, w, h);
    }
    munmap(mapped, (size_t)handle->size);
    Region region{nullptr, 0};
    OH_NativeWindow_NativeWindowFlushBuffer(window_, buffer, -1, region);
    if (frames_.fetch_add(1) == 0) {
      SLOG("%{public}s: first frame %{public}dx%{public}d stride=%{public}d", tag_.c_str(), w, h, stride);
    }
  }

  OHNativeWindow* window_ = nullptr;
  bool mirror_ = false;
  std::string tag_;
  int width_ = 0;
  int height_ = 0;
  int64_t last_ms_ = 0;
  std::atomic<int64_t> frames_{0};
  std::atomic<int> mismatches_{0};

  std::mutex mutex_;
  std::condition_variable cv_;
  absl::optional<webrtc::VideoFrame> latest_;
  bool stop_ = false;
  std::thread thread_;
};

}  // namespace

std::shared_ptr<SurfaceFrameSink> SurfaceFrameSink::Create(uint64_t surfaceId, bool mirror, const char* tag) {
  if (surfaceId == 0) {
    return nullptr;
  }
  OHNativeWindow* window = nullptr;
  int32_t err = OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceId, &window);
  if (err != 0 || !window) {
    SLOG("%{public}s: CreateNativeWindowFromSurfaceId failed err=%{public}d", tag ? tag : "?", err);
    return nullptr;
  }
  // Aspect-preserving fill, same choice as the 1:1 remote surface.
  OH_NativeWindow_NativeWindowSetScalingModeV2(window, OH_SCALING_MODE_SCALE_CROP_V2);
  SLOG("%{public}s: bound surfaceId=%{public}llu", tag ? tag : "?", (unsigned long long)surfaceId);
  return std::make_shared<SurfaceFrameSinkImpl>(window, mirror, tag ? tag : "?");
}

}  // namespace tgcalls_ohos
