// ohos_video_capturer.cpp — step 5c OHOS camera capture (see header).
//
// Design notes (v2, after the ALN-AL00 first-frame SIGSEGV):
// - OnBufferAvailable is invoked INLINE inside the camera producer's
//   BufferQueue::FlushBuffer binder transaction (crash-stack proof:
//   BufferQueueProducer::FlushBuffer -> CallConsumerListener ->
//   ImageReceiverSurfaceListener::OnBufferAvailable -> app callback on an
//   OS_IPC_* thread). Touching the image from that context crashed inside
//   OH_ImageNative_GetComponentTypes (NULL deref in libohimage; image handle
//   itself non-null). The callback now ONLY signals a private worker thread;
//   every OH_Image* call happens there, after the flush transaction returned.
// - OH_ImageNative_GetComponentTypes is NOT used at all (observed crash site;
//   component enumeration is unreliable for camera surface images on
//   HarmonyOS 6.1.0.125). Components are probed directly by the fixed ids
//   Y=1/U=2/V=3; every OH call is checked and any failure drops the frame —
//   the frame path must never be able to kill the process (a fault there
//   takes down the whole app mid-IPC).
// - Profile selection queries the NORMAL_VIDEO scene-mode capability
//   (matching the session mode; falls back to the default query). Empirical
//   Mate 60 Pro list has no 640x360; the square 480x480 ties 640x360 on raw
//   pixel count (230400) and was the original (bad) pick — square/portrait
//   profiles are now penalized so the classic 640x480 wins.
// - Frames are converted+rotated upright in one libyuv::Android420ToI420Rotate
//   call and sent with rotation=0 (no CVO dependency). Standard phone sensor
//   orientation constants (back=90°, front=270°): the physical-orientation
//   NDK query is API 22+, too new for this SDK; hilog carries the chosen mode
//   for post-test correction.
// - The ROM's OH_ImageNative_GetPixelStride LIES for interleaved YUV_420_SP
//   (reports 1; real interleave step is 2 — produced magenta-striped chroma
//   on both ends of the call). The chroma layout is therefore decided from
//   measured evidence (component address delta, chroma rowStride vs width),
//   never from the reported pixel stride. See processImage().
// - Camera open/config/start runs on a setup thread: camera service IPC must
//   not wedge the tgcalls media thread.

#include "ohos_video_capturer.h"

#include <atomic>
#include <chrono>
#include <cinttypes>
#include <condition_variable>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <map>
#include <mutex>
#include <thread>
#include <vector>

#include "VideoCaptureInterface.h"
#include "VideoCapturerInterface.h"
#include "platform/PlatformInterface.h"

#include "api/video/i420_buffer.h"
#include "api/video/video_frame.h"
#include "api/video/video_sink_interface.h"
#include "media/base/adapted_video_track_source.h"
#include "rtc_base/ref_counted_object.h"
#include "rtc_base/time_utils.h"

#include "libyuv.h"

#include <ohcamera/camera.h>
#include <ohcamera/camera_device.h>
#include <ohcamera/camera_input.h>
#include <ohcamera/camera_manager.h>
#include <ohcamera/capture_session.h>
#include <ohcamera/preview_output.h>
#include <multimedia/image_framework/image/image_common.h>
#include <multimedia/image_framework/image/image_native.h>
#include <multimedia/image_framework/image/image_receiver_native.h>
#include <native_buffer/native_buffer.h>
#include <hilog/log.h>

namespace tgcalls_ohos {
namespace {

void vlog(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    fprintf(stderr, "[tgcalls_ohos][cam] %s\n", buf);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, "tgcalls_ohos", "[cam] %{public}s", buf);
}

// Image component ids (values shared with the legacy image_mdk enum).
// GetComponentTypes is deliberately NOT called — see file header.
constexpr uint32_t kCompY = 1;
constexpr uint32_t kCompU = 2;
constexpr uint32_t kCompV = 3;

// 采集分辨率：使用 720p 作为好网目标。HW H264 + high-bitrate 模式提供 2Mbps
// 上限，WebRTC BWE 仍会在弱网时自动降分辨率/帧率；不再从 540p 源图开始编码，
// 避免对端全屏放大后细节先天不足。色度偏移和旋转路径均 resolution-safe。
constexpr int kTargetWidth = 1280;
constexpr int kTargetHeight = 720;
constexpr int kSensorOrientationBack = 90;   // standard phone sensor layout
constexpr int kSensorOrientationFront = 270;

/* ------------------------- track source ---------------------------------- */

class OhosVideoTrackSource : public rtc::AdaptedVideoTrackSource {
public:
    OhosVideoTrackSource() : rtc::AdaptedVideoTrackSource(2) {}

    // Full-res upright frame from the camera; runs adaptation, then feeds the
    // encoder path. Called on the capture worker thread.
    void PushI420(webrtc::scoped_refptr<webrtc::I420Buffer> buffer, int64_t timeUs) {
        int adaptedWidth = 0;
        int adaptedHeight = 0;
        int cropWidth = 0;
        int cropHeight = 0;
        int cropX = 0;
        int cropY = 0;
        if (!AdaptFrame(buffer->width(), buffer->height(), timeUs, &adaptedWidth, &adaptedHeight,
                        &cropWidth, &cropHeight, &cropX, &cropY)) {
            return;
        }
        webrtc::scoped_refptr<webrtc::VideoFrameBuffer> out = buffer;
        if (adaptedWidth != buffer->width() || adaptedHeight != buffer->height()) {
            auto scaled = webrtc::I420Buffer::Create(adaptedWidth, adaptedHeight);
            scaled->CropAndScaleFrom(*buffer, cropX, cropY, cropWidth, cropHeight);
            out = scaled;
        }
        OnFrame(webrtc::VideoFrame::Builder()
                    .set_video_frame_buffer(out)
                    .set_rotation(webrtc::kVideoRotation_0)
                    .set_timestamp_us(timeUs)
                    .build());
    }

    void RequestOutputFormat(int width, int height, int fps) {
        video_adapter()->OnOutputFormatRequest(std::make_pair(width, height), width * height, fps);
    }

    void setScreencast(bool v) { _screencast = v; }

    // VideoTrackSourceInterface
    bool is_screencast() const override { return _screencast; }
    absl::optional<bool> needs_denoising() const override { return false; }
    SourceState state() const override { return kLive; }
    bool remote() const override { return false; }

private:
    bool _screencast = false;
};


/* ------------------------- camera capturer ------------------------------- */

class OhosCameraCapturer;

std::mutex &receiverMapMutex() {
    static std::mutex m;
    return m;
}
std::map<OH_ImageReceiverNative *, OhosCameraCapturer *> &receiverMap() {
    static std::map<OH_ImageReceiverNative *, OhosCameraCapturer *> m;
    return m;
}

void onImageArriveTrampoline(OH_ImageReceiverNative *receiver);

class OhosCameraCapturer : public tgcalls::VideoCapturerInterface {
public:
    OhosCameraCapturer(webrtc::scoped_refptr<OhosVideoTrackSource> source, std::string deviceId,
                       std::function<void(tgcalls::VideoState)> stateUpdated,
                       std::function<void(tgcalls::PlatformCaptureInfo)> captureInfoUpdated)
        : _source(std::move(source)),
          _stateUpdated(std::move(stateUpdated)),
          _captureInfoUpdated(std::move(captureInfoUpdated)) {
        _wantBack = deviceId.find("back") != std::string::npos;
        _rotationMode = _wantBack ? libyuv::kRotate90 : libyuv::kRotate270;
    }

    ~OhosCameraCapturer() override {
        // 0. Wait for any in-flight flip to finish so the receiver/worker/session
        //    it may be rebuilding are in a settled state before we unwind them.
        //    switchCamera() is only ever called on the (same) media thread that
        //    runs this destructor, so no new switch can start here.
        if (_switchThread.joinable()) {
            _switchThread.join();
        }
        // 1. Wait for setup to finish: receiver registration and camera handle
        //    state must be final before we unwind them.
        if (_setupThread.joinable()) {
            _setupThread.join();
        }
        // 2. Cut new frame signals: OS callback off + registry entry gone.
        if (_receiver) {
            OH_ImageReceiverNative_Off(_receiver);
            std::lock_guard<std::mutex> lock(receiverMapMutex());
            receiverMap().erase(_receiver);
        }
        // 3. Stop the worker BEFORE releasing any handle it dereferences.
        {
            std::lock_guard<std::mutex> lock(_frameMutex);
            _workerStop = true;
        }
        _frameCv.notify_all();
        if (_workerThread.joinable()) {
            _workerThread.join();
        }
        // 4. Release camera + receiver objects.
        teardownCamera();
        vlog("capturer destroyed (frames=%" PRId64 " dropped=%" PRId64 ")", _frameCount.load(),
             _dropCount.load());
    }

    // Synchronous, cheap part: enumerate cameras + pick profile. Returns false
    // if no usable camera. Fills outResolution with upright dimensions.
    // Reusable across the initial prepare() AND flip: the camera manager /
    // supported-cameras list are (re)acquired only when absent, so the live
    // switch path can re-pick _camera/_profile without a full teardown.
    bool selectCameraDeviceAndProfile(std::pair<int, int> &outResolution) {
        if (!_manager) {
            Camera_ErrorCode merr = OH_Camera_GetCameraManager(&_manager);
            if (merr != CAMERA_OK || !_manager) {
                vlog("GetCameraManager failed: %d", (int)merr);
                return false;
            }
        }
        if (!_cameras || _cameraCount == 0) {
            Camera_ErrorCode cerr =
                OH_CameraManager_GetSupportedCameras(_manager, &_cameras, &_cameraCount);
            if (cerr != CAMERA_OK || !_cameras || _cameraCount == 0) {
                vlog("GetSupportedCameras failed: %d count=%u", (int)cerr, _cameraCount);
                return false;
            }
        }
        Camera_ErrorCode err;
        Camera_Position want = _wantBack ? CAMERA_POSITION_BACK : CAMERA_POSITION_FRONT;
        _camera = nullptr;
        for (uint32_t i = 0; i < _cameraCount; i++) {
            if (_cameras[i].cameraPosition == want) {
                _camera = &_cameras[i];
                break;
            }
        }
        if (!_camera) {
            _camera = &_cameras[0]; // fall back to any camera
            vlog("wanted position %d not found, using camera 0", (int)want);
        }

        // Capability for the session mode we actually use (NORMAL_VIDEO);
        // fall back to the default query if the scene-mode API objects.
        Camera_OutputCapability *capability = nullptr;
        err = OH_CameraManager_GetSupportedCameraOutputCapabilityWithSceneMode(
            _manager, _camera, NORMAL_VIDEO, &capability);
        if (err != CAMERA_OK || !capability || capability->previewProfilesSize == 0) {
            vlog("scene-mode caps unavailable (err=%d), using default caps", (int)err);
            if (capability) {
                OH_CameraManager_DeleteSupportedCameraOutputCapability(_manager, capability);
            }
            capability = nullptr;
            err = OH_CameraManager_GetSupportedCameraOutputCapability(_manager, _camera, &capability);
            if (err != CAMERA_OK || !capability) {
                vlog("GetSupportedCameraOutputCapability failed: %d", (int)err);
                return false;
            }
        }
        const Camera_Profile *best = nullptr;
        int64_t bestScore = INT64_MAX;
        const int64_t targetPixels = (int64_t)kTargetWidth * kTargetHeight;
        for (uint32_t i = 0; i < capability->previewProfilesSize; i++) {
            const Camera_Profile *p = capability->previewProfiles[i];
            if (!p || p->format != CAMERA_FORMAT_YUV_420_SP) {
                continue;
            }
            const int64_t w = p->size.width;
            const int64_t h = p->size.height;
            const int64_t pixels = w * h;
            int64_t score = pixels > targetPixels ? (pixels - targetPixels) * 2 : (targetPixels - pixels);
            // Square/portrait profiles are a poor fit for a call — and 480x480
            // exactly ties 640x360 on pixel count (230400), which is how the
            // original selector picked it. Penalize aspect < 1.2.
            if (h > 0 && w * 5 < h * 6) {
                score += 400000;
            }
            if (w * 9 == h * 16) {
                score -= score / 4; // slight preference for 16:9
            }
            if (score < bestScore) {
                bestScore = score;
                best = p;
            }
        }
        if (!best) {
            vlog("no YUV_420_SP preview profile (of %u); cannot capture", capability->previewProfilesSize);
            OH_CameraManager_DeleteSupportedCameraOutputCapability(_manager, capability);
            return false;
        }
        _profile = *best;
        OH_CameraManager_DeleteSupportedCameraOutputCapability(_manager, capability);

        _srcWidth = (int)_profile.size.width;
        _srcHeight = (int)_profile.size.height;
        bool swap = _rotationMode == libyuv::kRotate90 || _rotationMode == libyuv::kRotate270;
        _dstWidth = swap ? _srcHeight : _srcWidth;
        _dstHeight = swap ? _srcWidth : _srcHeight;
        outResolution = std::make_pair(_dstWidth, _dstHeight);
        vlog("camera=%s pos=%d profile=%dx%d fmt=%d rotate=%d -> %dx%d upright",
             _camera->cameraId ? _camera->cameraId : "?", (int)_camera->cameraPosition, _srcWidth,
             _srcHeight, (int)_profile.format, (int)_rotationMode, _dstWidth, _dstHeight);
        return true;
    }

    // Initial bring-up: pick camera/profile synchronously (cheap), then kick the
    // slow camera open/config onto the setup thread so the media thread never
    // blocks on camera-service IPC.
    bool prepare(std::pair<int, int> &outResolution) {
        if (!selectCameraDeviceAndProfile(outResolution)) {
            return false;
        }
        _setupThread = std::thread([this] { setupAndStart(); });
        return true;
    }

    // tgcalls::VideoCapturerInterface --------------------------------------
    void setState(tgcalls::VideoState state) override {
        bool wantRunning = state == tgcalls::VideoState::Active;
        std::lock_guard<std::mutex> lock(_sessionMutex);
        _desiredRunning = wantRunning;
        applyRunStateLocked();
    }

    void setPreferredCaptureAspectRatio(float aspectRatio) override {
        (void)aspectRatio; // aspect handled by adaptVideoSource()
    }

    void setUncroppedOutput(std::shared_ptr<rtc::VideoSinkInterface<webrtc::VideoFrame>> sink) override {
        std::lock_guard<std::mutex> lock(_sinkMutex);
        _uncroppedSink = std::move(sink);
    }

    int getRotation() override { return 0; } // frames are pre-rotated upright

    void setOnFatalError(std::function<void()> error) override {
        std::lock_guard<std::mutex> lock(_sessionMutex);
        _onFatalError = std::move(error);
        if (_fatalError && _onFatalError) {
            _onFatalError();
        }
    }

    // Called from the image-receiver binder callback: ONLY bump a counter and
    // wake the worker. No OH_Image* call is allowed here — the callback runs
    // inline inside the camera producer's FlushBuffer IPC transaction.
    void notifyFrameAvailable() {
        {
            std::lock_guard<std::mutex> lock(_frameMutex);
            _framesPending++;
        }
        _frameCv.notify_one();
    }

    // Hands the concrete capturer (`this`) to the completion. Runs on the tgcalls
    // media thread (via VideoCaptureInterfaceObject::withNativeImplementation);
    // the shim's flip path uses it to reach switchCamera() below.
    void withNativeImplementation(std::function<void(void *)> completion) override {
        completion(this);
    }

    // Flip front<->back WITHOUT blocking the caller (media) thread: the real
    // camera reconfiguration is pushed onto the dedicated _switchThread and this
    // returns immediately. Requests coalesce, so rapid double-taps collapse to
    // the final desired camera.
    void switchCamera(bool wantBack) {
        bool spawn = false;
        {
            std::lock_guard<std::mutex> lock(_switchMutex);
            _pendingWantBack = wantBack;
            _hasPendingSwitch = true;
            if (!_switchRunning) {
                _switchRunning = true;
                spawn = true;
            }
        }
        if (spawn) {
            // The previous run (if any) has already returned once _switchRunning
            // was observed false, so this join is immediate and never blocks the
            // media thread for real work.
            if (_switchThread.joinable()) {
                _switchThread.join();
            }
            _switchThread = std::thread([this] { switchThreadLoop(); });
        }
    }

private:
    struct Plane {
        const uint8_t *addr = nullptr;
        OH_NativeBuffer *buffer = nullptr;
        int32_t rowStride = 0;
        int32_t pixelStride = 1;
        bool valid = false;
    };

    // Guarded per-component read. Any failure -> false (frame dropped).
    bool mapPlane(OH_ImageNative *image, uint32_t component, Plane &plane) {
        OH_NativeBuffer *buffer = nullptr;
        if (OH_ImageNative_GetByteBuffer(image, component, &buffer) != IMAGE_SUCCESS || !buffer) {
            return false;
        }
        void *addr = nullptr;
        if (OH_NativeBuffer_Map(buffer, &addr) != 0 || !addr) {
            return false;
        }
        if (OH_ImageNative_GetRowStride(image, component, &plane.rowStride) != IMAGE_SUCCESS) {
            plane.rowStride = 0; // fall back to width later
        }
        if (OH_ImageNative_GetPixelStride(image, component, &plane.pixelStride) != IMAGE_SUCCESS) {
            plane.pixelStride = 0;
        }
        plane.addr = (const uint8_t *)addr;
        plane.buffer = buffer;
        plane.valid = true;
        return true;
    }

    void dropFrame(const char *why) {
        _dropCount.fetch_add(1);
        if (!_layoutWarned.exchange(true)) {
            vlog("frame drop: %s (further drops logged silently)", why);
        }
    }

    // Worker thread: the ONLY place OH_Image* APIs are called.
    void workerLoop() {
        vlog("capture worker up");
        for (;;) {
            {
                std::unique_lock<std::mutex> lock(_frameMutex);
                _frameCv.wait_for(lock, std::chrono::milliseconds(200),
                                  [this] { return _workerStop || _framesPending > 0; });
                if (_workerStop) {
                    break;
                }
                if (_framesPending == 0) {
                    continue;
                }
                _framesPending = 0;
            }
            // Drain everything queued (receiver capacity is small).
            for (;;) {
                // Bail the instant teardown is requested: at high resolution the
                // camera can refill faster than we drain, so without this check
                // the loop never empties and never rechecks _workerStop -> the
                // destructor's join() deadlocks the shared media thread.
                if (_workerStop.load(std::memory_order_relaxed)) {
                    break;
                }
                OH_ImageNative *image = nullptr;
                Image_ErrorCode ierr = OH_ImageReceiverNative_ReadNextImage(_receiver, &image);
                if (ierr != IMAGE_SUCCESS || !image) {
                    break; // queue empty (normal) or receiver unhappy (drop)
                }
                processImage(image);
                OH_ImageNative_Release(image);
            }
        }
        vlog("capture worker down");
    }

    void processImage(OH_ImageNative *image) {
        Image_Size size = {0, 0};
        if (OH_ImageNative_GetImageSize(image, &size) != IMAGE_SUCCESS) {
            return dropFrame("GetImageSize failed");
        }
        int width = (int)size.width;
        int height = (int)size.height;
        if (width < 2 || height < 2 || width > 8192 || height > 8192) {
            return dropFrame("implausible image size");
        }

        // Probe components by fixed id — GetComponentTypes is never called.
        Plane y, u, v;
        bool ok = mapPlane(image, kCompY, y);
        const uint8_t *srcU = nullptr;
        const uint8_t *srcV = nullptr;
        int strideU = 0, strideV = 0, pixelStrideUV = 1;
        const char *layout = "?";
        if (ok) {
            bool hasU = mapPlane(image, kCompU, u);
            bool hasV = mapPlane(image, kCompV, v);
            // ALN-AL00 forensics (vc2/vc3 live-call captures): chroma GetByteBuffer
            // may map the WHOLE NV21 buffer (bufSz == w*h*3/2 and addr == yAddr),
            // NOT a per-plane view. The mapped base is then the LUMA start — the
            // chroma plane actually begins after luma at base + yStride*height.
            // Reading base+0/+1 fed luma bytes into chroma: magenta stripes +
            // structure-bearing half-scale ghost doubling, identical on both ends.
            const int strideYLocal = y.rowStride > 0 ? y.rowStride : width;
            auto chromaBaseOf = [&](const uint8_t *addr) -> const uint8_t * {
                return (addr == y.addr)
                           ? (y.addr + (size_t)strideYLocal * (size_t)height)
                           : addr;
            };
            if (hasU && hasV) {
                srcU = u.addr;
                srcV = v.addr;
                strideU = u.rowStride > 0 ? u.rowStride : width;
                strideV = v.rowStride > 0 ? v.rowStride : width;
                // Decide interleaved vs planar from MEASURED evidence, never from
                // the ROM's reported pixel stride: this ROM (ALN-AL00 6.1.0.125)
                // reports pixelStride=1 for interleaved YUV_420_SP, which fed
                // libyuv a planar read of interleaved bytes (magenta stripes +
                // half-scale chroma doubling). Evidence used instead:
                //   1. adjacent component addresses (|v-u|==1): interleaved, and
                //      the sign distinguishes NV12 (U first) / NV21 (V first);
                //   2. chroma rowStride >= full image width: interleaved (a true
                //      planar chroma row of a w-wide frame is ~w/2 bytes).
                const intptr_t diffVU = (intptr_t)v.addr - (intptr_t)u.addr;
                const bool interleaved = diffVU == 1 || diffVU == -1 || strideU >= width;
                if (interleaved) {
                    pixelStrideUV = 2;
                    if (diffVU == 0) {
                        // Identical mapped address for both components: whole-buffer
                        // view (see chromaBaseOf) — offset to the real chroma plane.
                        // OHOS camera YUV_420_SP is NV21 => V first.
                        const uint8_t *cb = chromaBaseOf(u.addr);
                        srcV = cb;
                        srcU = cb + 1;
                        layout = "interleaved-samebase-NV21";
                    } else if (diffVU == 1) {
                        layout = "interleaved-NV12"; // U first, V = U+1
                    } else if (diffVU == -1) {
                        layout = "interleaved-NV21"; // V first, U = V+1
                    } else {
                        // Distinct mappings of the same physical plane: trust each
                        // pointer as "first sample of its component", stride said
                        // interleaved so step by 2.
                        layout = "interleaved-splitmap";
                    }
                } else {
                    pixelStrideUV = u.pixelStride > 0 ? u.pixelStride : 1;
                    layout = "planar";
                }
            } else if (hasU) {
                // Single interleaved chroma plane: OHOS YUV_420_SP == NV21 (VU).
                const uint8_t *cb = chromaBaseOf(u.addr);
                srcV = cb;
                srcU = cb + 1;
                strideU = strideV = u.rowStride > 0 ? u.rowStride : width;
                pixelStrideUV = 2;
                layout = "single-U-NV21";
            } else if (hasV) {
                const uint8_t *cb = chromaBaseOf(v.addr);
                srcV = cb;
                srcU = cb + 1;
                strideU = strideV = v.rowStride > 0 ? v.rowStride : width;
                pixelStrideUV = 2;
                layout = "single-V-NV21";
            } else {
                ok = false;
            }
        }

        if (ok) {
            if (_frameCount.load() == 0) {
                // Diagnostic ground truth for the chroma layout decision.
                size_t ySz = 0, uSz = 0, vSz = 0;
                OH_ImageNative_GetBufferSize(image, kCompY, &ySz);
                OH_ImageNative_GetBufferSize(image, kCompU, &uSz);
                OH_ImageNative_GetBufferSize(image, kCompV, &vSz);
                vlog("first frame raw: %dx%d yAddr=%p uAddr=%p vAddr=%p vMinusU=%lld uMinusY=%lld"
                     " strides(y=%d u=%d v=%d) reportedPix(y=%d u=%d v=%d) bufSz(y=%zu u=%zu v=%zu)",
                     width, height, (const void *)y.addr, (const void *)u.addr,
                     (const void *)v.addr, (long long)((intptr_t)v.addr - (intptr_t)u.addr),
                     (long long)((intptr_t)u.addr - (intptr_t)y.addr), y.rowStride, u.rowStride,
                     v.rowStride, y.pixelStride, u.pixelStride, v.pixelStride, ySz, uSz, vSz);
                vlog("first frame: %dx%d layout=%s yStride=%d uvStride=%d uvPixStride=%d srcU=%p srcV=%p",
                     width, height, layout, y.rowStride, strideU, pixelStrideUV,
                     (const void *)srcU, (const void *)srcV);
            }
            const bool swap =
                _rotationMode == libyuv::kRotate90 || _rotationMode == libyuv::kRotate270;
            auto buffer = webrtc::I420Buffer::Create(swap ? height : width, swap ? width : height);
            int res = libyuv::Android420ToI420Rotate(
                y.addr, y.rowStride > 0 ? y.rowStride : width, srcU, strideU > 0 ? strideU : width,
                srcV, strideV > 0 ? strideV : width, pixelStrideUV, buffer->MutableDataY(),
                buffer->StrideY(), buffer->MutableDataU(), buffer->StrideU(), buffer->MutableDataV(),
                buffer->StrideV(), width, height, (libyuv::RotationMode)_rotationMode);
            if (res == 0) {
                int64_t nowUs = rtc::TimeMicros();
                if (_frameCount.fetch_add(1) == 0) {
                    vlog("first frame converted OK -> %dx%d upright", buffer->width(),
                         buffer->height());
                }
                std::shared_ptr<rtc::VideoSinkInterface<webrtc::VideoFrame>> localSink;
                {
                    std::lock_guard<std::mutex> lock(_sinkMutex);
                    localSink = _uncroppedSink;
                }
                if (localSink) {
                    localSink->OnFrame(webrtc::VideoFrame::Builder()
                                           .set_video_frame_buffer(buffer)
                                           .set_rotation(webrtc::kVideoRotation_0)
                                           .set_timestamp_us(nowUs)
                                           .build());
                }
                _source->PushI420(buffer, nowUs);
            } else {
                dropFrame("Android420ToI420Rotate failed");
            }
        } else {
            dropFrame("component probe failed (Y/U/V)");
        }

        for (Plane *p : {&y, &u, &v}) {
            if (p->valid && p->buffer) {
                OH_NativeBuffer_Unmap(p->buffer);
            }
        }
    }

    // Setup thread ---------------------------------------------------------
    void setupAndStart() {
        Camera_ErrorCode err;

        OH_ImageReceiverOptions *options = nullptr;
        if (OH_ImageReceiverOptions_Create(&options) != IMAGE_SUCCESS || !options) {
            return fail("ImageReceiverOptions_Create");
        }
        Image_Size sz;
        sz.width = (uint32_t)_srcWidth;   // must equal the preview profile size
        sz.height = (uint32_t)_srcHeight;
        OH_ImageReceiverOptions_SetSize(options, sz);
        OH_ImageReceiverOptions_SetCapacity(options, 4);
        OH_ImageReceiverNative *receiver = nullptr;
        Image_ErrorCode ierr = OH_ImageReceiverNative_Create(options, &receiver);
        OH_ImageReceiverOptions_Release(options);
        if (ierr != IMAGE_SUCCESS || !receiver) {
            return fail("ImageReceiverNative_Create");
        }
        _receiver = receiver;
        _workerThread = std::thread([this] { workerLoop(); });
        {
            std::lock_guard<std::mutex> lock(receiverMapMutex());
            receiverMap()[receiver] = this;
        }
        if (OH_ImageReceiverNative_On(receiver, &onImageArriveTrampoline) != IMAGE_SUCCESS) {
            return fail("ImageReceiverNative_On");
        }
        uint64_t surfaceId = 0;
        if (OH_ImageReceiverNative_GetReceivingSurfaceId(receiver, &surfaceId) != IMAGE_SUCCESS) {
            return fail("GetReceivingSurfaceId");
        }
        char surfaceIdStr[32];
        snprintf(surfaceIdStr, sizeof(surfaceIdStr), "%" PRIu64, surfaceId);

        err = OH_CameraManager_CreateCameraInput(_manager, _camera, &_input);
        if (err != CAMERA_OK || !_input) {
            return fail("CreateCameraInput", (int)err);
        }
        err = OH_CameraInput_Open(_input);
        if (err != CAMERA_OK) {
            return fail("CameraInput_Open", (int)err);
        }
        _inputOpen = true;
        err = OH_CameraManager_CreateCaptureSession(_manager, &_session);
        if (err != CAMERA_OK || !_session) {
            return fail("CreateCaptureSession", (int)err);
        }
        err = OH_CaptureSession_SetSessionMode(_session, NORMAL_VIDEO);
        if (err != CAMERA_OK) {
            vlog("SetSessionMode(NORMAL_VIDEO) -> %d (continuing)", (int)err);
        }
        err = OH_CaptureSession_BeginConfig(_session);
        if (err != CAMERA_OK) {
            return fail("BeginConfig", (int)err);
        }
        err = OH_CaptureSession_AddInput(_session, _input);
        if (err != CAMERA_OK) {
            return fail("AddInput", (int)err);
        }
        err = OH_CameraManager_CreatePreviewOutput(_manager, &_profile, surfaceIdStr, &_preview);
        if (err != CAMERA_OK || !_preview) {
            return fail("CreatePreviewOutput", (int)err);
        }
        err = OH_CaptureSession_AddPreviewOutput(_session, _preview);
        if (err != CAMERA_OK) {
            return fail("AddPreviewOutput", (int)err);
        }
        err = OH_CaptureSession_CommitConfig(_session);
        if (err != CAMERA_OK) {
            return fail("CommitConfig", (int)err);
        }

        {
            std::lock_guard<std::mutex> lock(_sessionMutex);
            _configured = true;
            applyRunStateLocked();
        }
        vlog("camera session configured (surfaceId=%s)", surfaceIdStr);
        if (_captureInfoUpdated) {
            tgcalls::PlatformCaptureInfo info;
            info.shouldBeAdaptedToReceiverAspectRate = true;
            info.rotation = 0;
            _captureInfoUpdated(info);
        }
    }

    void fail(const char *what, int code = 0) {
        vlog("camera setup FAILED at %s (code=%d)", what, code);
        std::function<void()> cb;
        {
            std::lock_guard<std::mutex> lock(_sessionMutex);
            _fatalError = true;
            cb = _onFatalError;
        }
        if (_stateUpdated) {
            _stateUpdated(tgcalls::VideoState::Inactive);
        }
        if (cb) {
            cb();
        }
    }

    void applyRunStateLocked() {
        if (!_configured || !_session) {
            return;
        }
        if (_desiredRunning && !_running) {
            Camera_ErrorCode err = OH_CaptureSession_Start(_session);
            if (err == CAMERA_OK) {
                _running = true;
                vlog("capture session started");
                if (_stateUpdated) {
                    _stateUpdated(tgcalls::VideoState::Active);
                }
            } else {
                vlog("CaptureSession_Start failed: %d", (int)err);
            }
        } else if (!_desiredRunning && _running) {
            OH_CaptureSession_Stop(_session);
            _running = false;
            vlog("capture session stopped");
            if (_stateUpdated) {
                _stateUpdated(tgcalls::VideoState::Paused);
            }
        }
    }

    void teardownCamera() {
        if (_session) {
            if (_running) {
                OH_CaptureSession_Stop(_session);
            }
            OH_CaptureSession_Release(_session);
            _session = nullptr;
        }
        if (_preview) {
            OH_PreviewOutput_Release(_preview);
            _preview = nullptr;
        }
        if (_input) {
            if (_inputOpen) {
                OH_CameraInput_Close(_input);
            } else {
                OH_CameraInput_Release(_input);
            }
            _input = nullptr;
        }
        if (_receiver) {
            OH_ImageReceiverNative_Release(_receiver);
            _receiver = nullptr;
        }
        if (_cameras && _manager) {
            OH_CameraManager_DeleteSupportedCameras(_manager, _cameras, _cameraCount);
            _cameras = nullptr;
            _cameraCount = 0;
        }
        if (_manager) {
            OH_Camera_DeleteCameraManager(_manager);
            _manager = nullptr;
        }
    }

    // Switch worker: drains coalesced flip requests, one physical switch at a
    // time, on this dedicated thread (never the media thread).
    void switchThreadLoop() {
        for (;;) {
            bool target;
            {
                std::lock_guard<std::mutex> lock(_switchMutex);
                if (!_hasPendingSwitch) {
                    _switchRunning = false; // switchCamera() may now respawn us
                    return;
                }
                target = _pendingWantBack;
                _hasPendingSwitch = false;
            }
            performSwitch(target);
        }
    }

    // The actual flip, entirely off the media thread. Preferred path (capture
    // size unchanged) reconfigures the live CaptureSession's input in place —
    // the session, preview output, ImageReceiver and worker thread all survive,
    // mirroring iOS AVCaptureSession beginConfiguration/removeInput/addInput.
    // Only when the front/back profile sizes differ do we fall back to a full
    // teardown + rebuild (still on this thread).
    void performSwitch(bool wantBack) {
        // Initial camera bring-up must be complete before we touch its handles.
        if (_setupThread.joinable()) {
            _setupThread.join();
        }
        if (_wantBack == wantBack) {
            vlog("switchCamera: already on %s camera, ignoring", wantBack ? "back" : "front");
            return;
        }

        // Snapshot session state and gate setState() off in one locked step, so
        // no media-thread setState() can start/stop the session under us.
        Camera_CaptureSession *session = nullptr;
        bool wasRunning = false;
        {
            std::lock_guard<std::mutex> lock(_sessionMutex);
            if (!_configured || !_session) {
                vlog("switchCamera: session not ready, deferring flip");
                return;
            }
            session = _session;
            wasRunning = _running;
            _configured = false; // setState()/applyRunStateLocked() now no-op
        }

        const int oldSrcW = _srcWidth;
        const int oldSrcH = _srcHeight;

        // Re-pick camera + profile for the new position (manager/cameras list is
        // still alive here, so this is cheap and _camera stays valid).
        _wantBack = wantBack;
        _rotationMode = _wantBack ? libyuv::kRotate90 : libyuv::kRotate270;
        std::pair<int, int> res;
        if (!selectCameraDeviceAndProfile(res)) {
            vlog("switchCamera: no camera for wantBack=%d", (int)wantBack);
            fail("switchCamera-select");
            return;
        }
        const bool sizeChanged = (_srcWidth != oldSrcW || _srcHeight != oldSrcH);

        if (!sizeChanged) {
            // ---- light path: swap the input inside the live session ----------
            if (wasRunning) {
                OH_CaptureSession_Stop(session);
            }
            Camera_ErrorCode err = OH_CaptureSession_BeginConfig(session);
            if (err != CAMERA_OK) {
                vlog("switch BeginConfig failed: %d", (int)err);
                return finishSwitchStart(session); // re-arm; nothing changed yet
            }
            // Release the OLD camera device FIRST — OHOS cameras are exclusive,
            // the new input can only open after the old one is fully released.
            if (_input) {
                OH_CaptureSession_RemoveInput(session, _input);
                if (_inputOpen) {
                    OH_CameraInput_Close(_input);
                }
                OH_CameraInput_Release(_input);
                _input = nullptr;
                _inputOpen = false;
            }
            err = OH_CameraManager_CreateCameraInput(_manager, _camera, &_input);
            if (err != CAMERA_OK || !_input) {
                vlog("switch CreateCameraInput failed: %d", (int)err);
                OH_CaptureSession_CommitConfig(session);
                fail("switchCamera-input");
                return;
            }
            err = OH_CameraInput_Open(_input);
            if (err != CAMERA_OK) {
                vlog("switch CameraInput_Open failed: %d", (int)err);
                OH_CaptureSession_CommitConfig(session);
                fail("switchCamera-open");
                return;
            }
            _inputOpen = true;
            err = OH_CaptureSession_AddInput(session, _input);
            if (err != CAMERA_OK) {
                vlog("switch AddInput failed: %d", (int)err);
                OH_CaptureSession_CommitConfig(session);
                fail("switchCamera-addinput");
                return;
            }
            err = OH_CaptureSession_CommitConfig(session);
            if (err != CAMERA_OK) {
                vlog("switch CommitConfig failed: %d", (int)err);
                fail("switchCamera-commit");
                return;
            }
            vlog("switchCamera(in-session) -> %s %dx%d", wantBack ? "back" : "front", _srcWidth,
                 _srcHeight);
            return finishSwitchStart(session);
        }

        // ---- heavy path (capture size changed): full teardown + rebuild -------
        vlog("switchCamera(rebuild): size %dx%d -> %dx%d", oldSrcW, oldSrcH, _srcWidth, _srcHeight);
        // Cut the frame path (mirror the destructor order) before releasing any
        // handle the worker dereferences.
        if (_receiver) {
            OH_ImageReceiverNative_Off(_receiver);
            std::lock_guard<std::mutex> lock(receiverMapMutex());
            receiverMap().erase(_receiver);
        }
        {
            std::lock_guard<std::mutex> lock(_frameMutex);
            _workerStop = true;
        }
        _frameCv.notify_all();
        if (_workerThread.joinable()) {
            _workerThread.join();
        }
        {
            std::lock_guard<std::mutex> lock(_sessionMutex);
            _running = false;
        }
        teardownCamera(); // releases session/preview/input/receiver/cameras/manager
        {
            std::lock_guard<std::mutex> lock(_frameMutex);
            _workerStop = false;
            _framesPending = 0;
        }
        // teardownCamera() dropped the manager + cameras list; re-enumerate and
        // re-pick so _camera points into a fresh, valid array for setupAndStart.
        if (!selectCameraDeviceAndProfile(res)) {
            vlog("switchCamera(rebuild): re-select failed");
            fail("switchCamera-rebuild-select");
            return;
        }
        setupAndStart(); // new receiver + worker + session; starts if _desiredRunning
        vlog("switchCamera(rebuild) done -> %s", wantBack ? "back" : "front");
    }

    // Re-arm the session after an in-session reconfig and (re)start if desired.
    void finishSwitchStart(Camera_CaptureSession *session) {
        (void)session;
        std::lock_guard<std::mutex> lock(_sessionMutex);
        _configured = true;
        _running = false; // Stop() above (if any) left the session stopped
        applyRunStateLocked();
    }

    webrtc::scoped_refptr<OhosVideoTrackSource> _source;
    std::function<void(tgcalls::VideoState)> _stateUpdated;
    std::function<void(tgcalls::PlatformCaptureInfo)> _captureInfoUpdated;

    bool _wantBack = false;
    int _rotationMode = libyuv::kRotate270;
    int _srcWidth = 0, _srcHeight = 0;
    int _dstWidth = 0, _dstHeight = 0;

    Camera_Manager *_manager = nullptr;
    Camera_Device *_cameras = nullptr;
    uint32_t _cameraCount = 0;
    const Camera_Device *_camera = nullptr;
    Camera_Profile _profile = {};
    Camera_Input *_input = nullptr;
    bool _inputOpen = false;
    Camera_CaptureSession *_session = nullptr;
    Camera_PreviewOutput *_preview = nullptr;
    OH_ImageReceiverNative *_receiver = nullptr;

    std::thread _setupThread;
    std::mutex _sessionMutex;
    bool _configured = false;
    bool _running = false;
    bool _desiredRunning = true; // VideoCaptureInterfaceObject defaults to Active
    bool _fatalError = false;
    std::function<void()> _onFatalError;

    // Frame hand-off: binder callback -> worker thread.
    std::thread _workerThread;
    std::mutex _frameMutex;
    std::condition_variable _frameCv;
    int _framesPending = 0;
    // Atomic so the inner frame-drain loop can honor it lock-free: at 720p a
    // single rotate can exceed the camera's inter-frame gap, so ReadNextImage
    // never returns "empty" and the drain loop would otherwise spin forever,
    // never returning to the top-of-loop _workerStop check. That wedged the
    // capture worker, hanging ~OhosCameraCapturer's join on the shared tgcalls
    // media thread -> instance stop timed out -> every subsequent call stuck
    // at "connecting". Still also written under _frameMutex for the CV wait.
    std::atomic<bool> _workerStop{false};

    std::mutex _sinkMutex;
    std::shared_ptr<rtc::VideoSinkInterface<webrtc::VideoFrame>> _uncroppedSink;

    // Camera flip: heavy reconfiguration runs here, off the media thread.
    std::thread _switchThread;
    std::mutex _switchMutex;
    bool _pendingWantBack = false;
    bool _hasPendingSwitch = false;
    bool _switchRunning = false;

    std::atomic<int64_t> _frameCount{0};
    std::atomic<int64_t> _dropCount{0};
    std::atomic<bool> _layoutWarned{false};
};

void onImageArriveTrampoline(OH_ImageReceiverNative *receiver) {
    // Runs inline inside the camera producer's FlushBuffer IPC transaction:
    // O(1), no OH_Image* calls, no frame work.
    std::lock_guard<std::mutex> lock(receiverMapMutex());
    auto it = receiverMap().find(receiver);
    if (it != receiverMap().end()) {
        it->second->notifyFrameAvailable();
    }
}

} // namespace

/* ------------------------- public factory API ----------------------------- */

// Screen capturer entry points (ohos_screen_capturer.cpp) reach the source through these.
void PushI420ToOhosVideoSource(webrtc::VideoTrackSourceInterface *source,
                               webrtc::scoped_refptr<webrtc::I420Buffer> buffer, int64_t timeUs) {
    static_cast<OhosVideoTrackSource *>(source)->PushI420(std::move(buffer), timeUs);
}
void MarkOhosVideoSourceScreencast(webrtc::VideoTrackSourceInterface *source, bool v) {
    static_cast<OhosVideoTrackSource *>(source)->setScreencast(v);
}

webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> CreateOhosVideoSource() {
    return webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface>(
        new rtc::RefCountedObject<OhosVideoTrackSource>());
}

void AdaptOhosVideoSource(webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> source,
                          int width, int height, int fps) {
    if (source) {
        static_cast<OhosVideoTrackSource *>(source.get())->RequestOutputFormat(width, height, fps);
    }
}

std::unique_ptr<tgcalls::VideoCapturerInterface> CreateOhosVideoCapturer(
    webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> source, std::string deviceId,
    std::function<void(tgcalls::VideoState)> stateUpdated,
    std::function<void(tgcalls::PlatformCaptureInfo)> captureInfoUpdated,
    std::pair<int, int> &outResolution) {
    if (!source) {
        return nullptr;
    }
    auto capturer = std::make_unique<OhosCameraCapturer>(
        webrtc::scoped_refptr<OhosVideoTrackSource>(
            static_cast<OhosVideoTrackSource *>(source.get())),
        std::move(deviceId), std::move(stateUpdated), std::move(captureInfoUpdated));
    if (!capturer->prepare(outResolution)) {
        vlog("CreateOhosVideoCapturer: prepare failed (no camera?)");
        return nullptr;
    }
    return capturer;
}

void SwitchOhosCameraNative(void *nativePtr, bool wantBack) {
    // nativePtr is the pointer handed to VideoCapturerInterface::
    // withNativeImplementation()'s completion, which for this platform is always
    // an OhosCameraCapturer* (see makeVideoCapturer). Runs on the media thread;
    // switchCamera() only kicks a worker thread and returns immediately.
    if (nativePtr) {
        static_cast<OhosCameraCapturer *>(nativePtr)->switchCamera(wantBack);
    }
}

} // namespace tgcalls_ohos
