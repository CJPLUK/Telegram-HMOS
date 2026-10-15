// Screen sharing capturer for group calls (OH_AVScreenCapture, original-stream mode).
//
//   OH_AVScreenCapture (RGBA native buffers, home screen, no audio)
//   -> libyuv ABGRToI420 -> webrtc I420Buffer -> the shared AdaptedVideoTrackSource
//
// The system shows its own consent dialog on start; no app permission is declared.
// State callbacks: STARTED / CANCELED (user declined) / STOPPED_BY_USER (system
// stop control) are reported through tgcalls::VideoState so the session can end
// the share. Also keeps `tgcalls_screen_capture_probe` for the diagnostic path.
#include "ohos_video_capturer.h"

#include <hilog/log.h>
#include <multimedia/player_framework/native_avscreen_capture.h>
#include <multimedia/player_framework/native_avscreen_capture_base.h>
#include <multimedia/player_framework/native_avscreen_capture_errors.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <native_buffer/native_buffer.h>

#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>

#include "api/media_stream_interface.h"
#include "VideoCaptureInterface.h"
#include "VideoCapturerInterface.h"
#include "api/video/i420_buffer.h"
#include "api/video/video_frame.h"
#include "api/video/video_sink_interface.h"
#include "rtc_base/time_utils.h"
#include "third_party/libyuv/include/libyuv.h"

#define TGCALLS_API extern "C" __attribute__((visibility("default")))
#define SLOG(fmt, ...) OH_LOG_Print(LOG_APP, LOG_INFO, 0, "tgcalls_ohos", "[screen] " fmt, ##__VA_ARGS__)

namespace tgcalls_ohos {
namespace {

// Capture at the phone's portrait size scaled to ~720p wide; the SFU layers scale down from here.
constexpr int kCaptureWidth = 720;
constexpr int kCaptureHeight = 1600;

class OhosScreenCapturer : public tgcalls::VideoCapturerInterface {
public:
    OhosScreenCapturer(webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> source,
                       std::function<void(tgcalls::VideoState)> stateUpdated)
        : _source(std::move(source)), _stateUpdated(std::move(stateUpdated)) {
        MarkOhosVideoSourceScreencast(_source.get(), true);
    }

    ~OhosScreenCapturer() override { stop(); }

    bool start() {
        std::lock_guard<std::mutex> lock(_mutex);
        if (_cap) {
            return true;
        }
        _cap = OH_AVScreenCapture_Create();
        if (!_cap) {
            SLOG("create failed");
            return false;
        }
        OH_AVScreenCapture_SetStateCallback(_cap, &OhosScreenCapturer::OnState, this);
        OH_AVScreenCapture_SetErrorCallback(_cap, &OhosScreenCapturer::OnError, this);
        OH_AVScreenCapture_SetDataCallback(_cap, &OhosScreenCapturer::OnBuffer, this);

        OH_AVScreenCaptureConfig config{};
        config.captureMode = OH_CAPTURE_HOME_SCREEN;
        config.dataType = OH_ORIGINAL_STREAM;
        config.videoInfo.videoCapInfo.videoFrameWidth = kCaptureWidth;
        config.videoInfo.videoCapInfo.videoFrameHeight = kCaptureHeight;
        config.videoInfo.videoCapInfo.videoSource = OH_VIDEO_SOURCE_SURFACE_RGBA;
        // The microphone stays with the call; the inner (playback) capture is required by Init.
        config.audioInfo.innerCapInfo.audioSampleRate = 48000;
        config.audioInfo.innerCapInfo.audioChannels = 2;
        config.audioInfo.innerCapInfo.audioSource = OH_ALL_PLAYBACK;
        int rc = OH_AVScreenCapture_Init(_cap, config);
        if (rc != AV_SCREEN_CAPTURE_ERR_OK) {
            SLOG("init failed rc=%{public}d", rc);
            releaseLocked();
            return false;
        }
        rc = OH_AVScreenCapture_StartScreenCapture(_cap);
        SLOG("start -> %{public}d (consent dialog follows)", rc);
        if (rc != AV_SCREEN_CAPTURE_ERR_OK) {
            releaseLocked();
            return false;
        }
        return true;
    }

    void stop() {
        std::lock_guard<std::mutex> lock(_mutex);
        if (!_cap) {
            return;
        }
        SLOG("stop (frames=%{public}d)", _frames.load());
        OH_AVScreenCapture_StopScreenCapture(_cap);
        releaseLocked();
    }

    // tgcalls::VideoCapturerInterface --------------------------------------
    void setState(tgcalls::VideoState state) override {
        SLOG("setState %{public}d", static_cast<int>(state));
        if (state == tgcalls::VideoState::Active) {
            start();
        } else {
            stop();
        }
    }
    void setPreferredCaptureAspectRatio(float) override {}
    void setUncroppedOutput(std::shared_ptr<rtc::VideoSinkInterface<webrtc::VideoFrame>> sink) override {
        std::lock_guard<std::mutex> lock(_sinkMutex);
        _uncroppedSink = std::move(sink);
    }
    int getRotation() override { return 0; }
    void setOnFatalError(std::function<void()> error) override {
        std::lock_guard<std::mutex> lock(_mutex);
        _onFatalError = std::move(error);
    }
    void withNativeImplementation(std::function<void(void *)> completion) override { completion(this); }

private:
    void releaseLocked() {
        if (_cap) {
            OH_AVScreenCapture_Release(_cap);
            _cap = nullptr;
        }
    }

    static void OnState(OH_AVScreenCapture *, OH_AVScreenCaptureStateCode code, void *user) {
        auto *self = static_cast<OhosScreenCapturer *>(user);
        SLOG("state -> %{public}d", static_cast<int>(code));
        switch (code) {
            case OH_SCREEN_CAPTURE_STATE_STARTED:
                if (self->_stateUpdated) self->_stateUpdated(tgcalls::VideoState::Active);
                break;
            case OH_SCREEN_CAPTURE_STATE_CANCELED:
            case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER:
            case OH_SCREEN_CAPTURE_STATE_INTERRUPTED_BY_OTHER:
            case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_CALL:
            case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER_SWITCHES:
                // The session listens for Inactive to end the share (declined consent, system stop).
                if (self->_stateUpdated) self->_stateUpdated(tgcalls::VideoState::Inactive);
                break;
            default:
                break;
        }
    }

    static void OnError(OH_AVScreenCapture *, int32_t code, void *user) {
        auto *self = static_cast<OhosScreenCapturer *>(user);
        SLOG("error %{public}d", code);
        std::function<void()> cb;
        {
            std::lock_guard<std::mutex> lock(self->_mutex);
            cb = self->_onFatalError;
        }
        if (cb) cb();
    }

    static void OnBuffer(OH_AVScreenCapture *, OH_AVBuffer *buffer, OH_AVScreenCaptureBufferType type,
                         int64_t, void *user) {
        if (type != OH_SCREEN_CAPTURE_BUFFERTYPE_VIDEO || !buffer) {
            return;
        }
        static_cast<OhosScreenCapturer *>(user)->handleVideo(buffer);
    }

    void handleVideo(OH_AVBuffer *buffer) {
        OH_NativeBuffer *nb = OH_AVBuffer_GetNativeBuffer(buffer);
        if (!nb) {
            return;
        }
        OH_NativeBuffer_Config cfg{};
        OH_NativeBuffer_GetConfig(nb, &cfg);
        void *addr = nullptr;
        if (OH_NativeBuffer_Map(nb, &addr) != 0 || !addr) {
            OH_NativeBuffer_Unreference(nb);
            return;
        }
        const int w = cfg.width & ~1;
        const int h = cfg.height & ~1;
        const int n = ++_frames;
        if (n == 1) {
            SLOG("first frame %{public}dx%{public}d format=%{public}d stride=%{public}d", cfg.width, cfg.height,
                 cfg.format, cfg.stride);
        }
        auto i420 = webrtc::I420Buffer::Create(w, h);
        // OHOS RGBA_8888 is R,G,B,A in memory = libyuv "ABGR" (little-endian word order).
        libyuv::ABGRToI420(static_cast<const uint8_t *>(addr), cfg.stride, i420->MutableDataY(), i420->StrideY(),
                           i420->MutableDataU(), i420->StrideU(), i420->MutableDataV(), i420->StrideV(), w, h);
        OH_NativeBuffer_Unmap(nb);
        OH_NativeBuffer_Unreference(nb);

        const int64_t timeUs = rtc::TimeMicros();
        {
            std::lock_guard<std::mutex> lock(_sinkMutex);
            if (_uncroppedSink) {
                _uncroppedSink->OnFrame(webrtc::VideoFrame::Builder()
                                            .set_video_frame_buffer(i420)
                                            .set_timestamp_us(timeUs)
                                            .build());
            }
        }
        PushI420ToOhosVideoSource(_source.get(), i420, timeUs);
    }

    webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> _source;
    std::function<void(tgcalls::VideoState)> _stateUpdated;
    std::mutex _mutex;
    OH_AVScreenCapture *_cap = nullptr;
    std::function<void()> _onFatalError;
    std::mutex _sinkMutex;
    std::shared_ptr<rtc::VideoSinkInterface<webrtc::VideoFrame>> _uncroppedSink;
    std::atomic<int> _frames{0};
};

}  // namespace

std::unique_ptr<tgcalls::VideoCapturerInterface> CreateOhosScreenCapturer(
    webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> source,
    std::function<void(tgcalls::VideoState)> stateUpdated, std::pair<int, int> &outResolution) {
    if (!source) {
        return nullptr;
    }
    outResolution = std::make_pair(kCaptureWidth, kCaptureHeight);
    SLOG("capturer created (start follows from setState)");
    // Capture starts from setState(Active) (VideoCaptureInterfaceObject defaults to Active).
    return std::make_unique<OhosScreenCapturer>(std::move(source), std::move(stateUpdated));
}

}  // namespace tgcalls_ohos

// ---- diagnostic probe (kept: long-press on the call title) ----
namespace {
std::atomic<bool> g_probeRunning{false};
}
TGCALLS_API int tgcalls_screen_capture_probe(int seconds, int width, int height) {
    bool expected = false;
    if (!g_probeRunning.compare_exchange_strong(expected, true)) {
        return 1;
    }
    std::thread([seconds, width, height] {
        auto source = tgcalls_ohos::CreateOhosVideoSource();
        std::pair<int, int> res;
        auto cap = tgcalls_ohos::CreateOhosScreenCapturer(source, [](tgcalls::VideoState s) {
            SLOG("probe state=%{public}d", static_cast<int>(s));
        }, res);
        if (cap) {
            cap->setState(tgcalls::VideoState::Active);
            std::this_thread::sleep_for(std::chrono::seconds(seconds > 0 ? seconds : 8));
            cap->setState(tgcalls::VideoState::Inactive);
        }
        SLOG("probe done");
        g_probeRunning = false;
    }).detach();
    (void)width; (void)height;
    return 0;
}
