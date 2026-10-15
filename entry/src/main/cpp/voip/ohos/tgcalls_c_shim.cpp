// tgcalls_c_shim.cpp — C ABI surface of libtgcalls_ohos.so.
//
// Contract source of truth (verbatim signatures):
//   entry/src/main/cangjie/core/voip/TgCallsBridge.cj
// The Cangjie side dlopen()s this library and dlsym()s every tgcalls_* symbol
// below. 20 symbols are REQUIRED (bridge refuses to run without them), the
// video/media-state extras are OPTIONAL (bridge feature-detects them).
//
// Protocol path: 12.0.0 -> tgcalls::InstanceV2Impl (custom SCTP signaling +
// SignalingEncryption + NativeNetworkingImpl). ADM is the OH_Audio ADM (5b).
// Video (5c): OHOS camera capture (patches/shim/ohos_video_capturer.cpp) +
// VP8 software codecs (libvpx via webrtc Internal{En,De}coderFactory, see
// platform/fake/FakeInterface.cpp). Remote/local frames are delivered to the
// Cangjie bridge as tightly-packed BGRA via tg_video_frame_cb.

#include <atomic>
#include <array>
#include <chrono>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <future>
#include <memory>
#include <mutex>
#include <thread>
#include <condition_variable>
#include <native_window/external_window.h>
#include "absl/types/optional.h"
#include "ohos_h264_internal.h"
#include <string>
#include <vector>

#include "Instance.h"
#include "StaticThreads.h"
#include "VideoCaptureInterface.h"
#include "v2/InstanceV2Impl.h"

#include "api/scoped_refptr.h"
#include "api/task_queue/task_queue_factory.h"
#include "api/video/i420_buffer.h"
#include "api/video/video_frame.h"
#include "api/video/video_sink_interface.h"
#include "modules/audio_device/include/audio_device.h"
#include "rtc_base/time_utils.h"

#include "libyuv.h"

#include <hilog/log.h>

#include "ohos_audio_device.h"
#include "ohos_video_capturer.h"

#define TGCALLS_API extern "C" __attribute__((visibility("default")))

namespace {

// ---- C callback function-pointer types (must match TgCallsBridge.cj CFunc) --
typedef void (*tg_state_cb)(void *user, int32_t state);
typedef void (*tg_signal_bars_cb)(void *user, int32_t bars);
typedef void (*tg_audio_level_cb)(void *user, float level);
typedef void (*tg_signaling_cb)(void *user, const uint8_t *data, int32_t size);
typedef void (*tg_battery_cb)(void *user, bool isLow);
typedef void (*tg_media_state_cb)(void *user, int32_t audioState, int32_t videoState);
typedef void (*tg_video_frame_cb)(void *user, const uint8_t *data, int32_t size,
                                  int32_t width, int32_t height);

void log_line(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    fprintf(stderr, "[tgcalls_ohos] %s\n", buf);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, "tgcalls_ohos", "%{public}s", buf);
}

void ensure_registered() {
    static const bool registered = [] {
        tgcalls::Register<tgcalls::InstanceV2Impl>();
        return true;
    }();
    (void)registered;
}

// Callback hub. Descriptor lambdas capture a shared_ptr to this (not to the
// instance wrapper), so a late callback racing tgcalls_destroy() sees
// alive == false instead of freed memory.
struct CallbackCtx {
    void *userData = nullptr;
    tg_state_cb onState = nullptr;
    tg_signal_bars_cb onSignalBars = nullptr;
    tg_audio_level_cb onAudioLevel = nullptr;
    tg_signaling_cb onSignalingData = nullptr;
    tg_battery_cb onRemoteBatteryLow = nullptr;

    std::atomic<tg_media_state_cb> onRemoteMediaState{nullptr};
    std::atomic<void *> remoteMediaStateUser{nullptr};
    std::atomic<tg_video_frame_cb> onVideoFrame{nullptr};
    std::atomic<void *> videoFrameUser{nullptr};
    std::atomic<tg_video_frame_cb> onLocalVideoFrame{nullptr};
    std::atomic<void *> localVideoFrameUser{nullptr};

    std::atomic<bool> alive{true};
};

// 5c: converts webrtc frames to tightly-packed BGRA and invokes the Cangjie
// frame callback. One instance per direction (remote render / local preview),
// owned by TgCallsInstance; tgcalls holds weak/shared refs. Frame-rate capped
// (remote ~30fps, local preview ~15fps). Rotation metadata (if any) is baked
// in physically so the receiver never needs to rotate.
class BgraFrameSink : public rtc::VideoSinkInterface<webrtc::VideoFrame> {
public:
    BgraFrameSink(std::shared_ptr<CallbackCtx> ctx, bool local, int64_t minIntervalMs)
        : _ctx(std::move(ctx)), _local(local), _minIntervalMs(minIntervalMs) {
        _thread = std::thread([this] { displayLoop(); });
    }
    ~BgraFrameSink() override {
        {
            std::lock_guard<std::mutex> lock(_slotMutex);
            _stop = true;
        }
        _slotCv.notify_all();
        if (_thread.joinable()) {
            _thread.join();
        }
    }

    // Runs on WebRTC's IncomingVideoStream thread. MUST be cheap: only stash the
    // newest frame (a VideoFrame copy shares the underlying buffer — no pixel
    // copy) and wake the display thread. Previously this did the full 720p
    // I420->BGRA + Cangjie callback inline, which pegged this thread to ~13fps
    // while the HW decoder produced 25fps; the surplus piled up in the render
    // queue and grew latency to tens of seconds. Handing off + latest-frame-wins
    // lets IncomingVideoStream drain at full rate and bounds display latency to
    // ~1 frame.
    void OnFrame(const webrtc::VideoFrame &frame) override {
        if (!_ctx->alive.load()) {
            return;
        }
        {
            std::lock_guard<std::mutex> lock(_slotMutex);
            _latest = frame;      // cheap: refcounted buffer, not a pixel copy
        }
        _slotCv.notify_one();
    }

private:
    void displayLoop() {
        for (;;) {
            absl::optional<webrtc::VideoFrame> frame;
            {
                std::unique_lock<std::mutex> lock(_slotMutex);
                _slotCv.wait(lock, [this] { return _latest.has_value() || _stop; });
                if (_stop) {
                    return;
                }
                frame = std::move(_latest);  // take newest; skip any older backlog
                _latest.reset();
            }
            processAndDeliver(*frame);
        }
    }

    void processAndDeliver(const webrtc::VideoFrame &frame) {
        tg_video_frame_cb cb = _local ? _ctx->onLocalVideoFrame.load() : _ctx->onVideoFrame.load();
        void *user = _local ? _ctx->localVideoFrameUser.load() : _ctx->videoFrameUser.load();
        if (!cb || !_ctx->alive.load()) {
            return;
        }
        const int64_t nowMs = rtc::TimeMillis();
        if (nowMs - _lastFrameMs < _minIntervalMs) {
            return;  // fps cap
        }
        _lastFrameMs = nowMs;

        webrtc::scoped_refptr<webrtc::I420BufferInterface> i420 =
            frame.video_frame_buffer()->ToI420();
        if (!i420) {
            return;
        }
        if (frame.rotation() != webrtc::kVideoRotation_0) {
            i420 = webrtc::I420Buffer::Rotate(*i420, frame.rotation());
        }
        const int w = i420->width();
        const int h = i420->height();
        if (w <= 0 || h <= 0) {
            return;
        }
        _bgra.resize((size_t)w * (size_t)h * 4);
        // libyuv "ARGB" = little-endian ARGB word = B,G,R,A byte order — i.e.
        // exactly the BGRA byte layout the Cangjie pixel map expects.
        libyuv::I420ToARGB(i420->DataY(), i420->StrideY(), i420->DataU(), i420->StrideU(),
                           i420->DataV(), i420->StrideV(), _bgra.data(), w * 4, w, h);
        if (_ctx->alive.load()) {
            const int64_t n = _frames.fetch_add(1);
            if (n == 0) {
                log_line("%s frame #0: %dx%d", _local ? "local" : "remote", w, h);
            }
            cb(user, _bgra.data(), (int32_t)((size_t)w * h * 4), w, h);
        }
    }

    std::shared_ptr<CallbackCtx> _ctx;
    const bool _local;
    const int64_t _minIntervalMs;
    int64_t _lastFrameMs = 0;              // display-thread only
    std::atomic<int64_t> _frames{0};
    std::vector<uint8_t> _bgra;            // display-thread only

    std::mutex _slotMutex;
    std::condition_variable _slotCv;
    absl::optional<webrtc::VideoFrame> _latest;  // newest unprocessed frame
    bool _stop = false;
    std::thread _thread;
};

struct TgCallsBuilder {
    std::array<uint8_t, tgcalls::EncryptionKey::kSize> key{};
    bool hasKey = false;
    bool isOutgoing = false;
    bool isVideo = false;
    std::string version = "12.0.0";
    int32_t maxLayer = 92;
    bool allowP2P = true;
    bool allowTCP = true;
    bool enableStunMarking = true;
    std::vector<tgcalls::RtcServer> rtcServers;
    std::vector<tgcalls::Endpoint> endpoints;
};

struct TgCallsInstance {
    std::shared_ptr<CallbackCtx> ctx;
    std::unique_ptr<tgcalls::Instance> instance;
    bool stopped = false;
    // 5c video state. Sinks are owned here: setIncomingVideoOutput takes a
    // weak_ptr and VideoCaptureInterface::setOutput stores a weak_ptr too.
    std::shared_ptr<tgcalls::VideoCaptureInterface> videoCapture;
    std::shared_ptr<BgraFrameSink> remoteSink;
    std::shared_ptr<BgraFrameSink> localSink;
    std::mutex videoMutex;
};

tgcalls::NetworkType map_network_type(int32_t t) {
    // Cangjie contract: 0=Unknown 1=GPRS 2=EDGE 3=3G 4=HSPA 5=LTE 6=WiFi —
    // identical ordinals to tgcalls::NetworkType's first 7 enumerators.
    if (t < 0 || t > (int32_t)tgcalls::NetworkType::Dialup) {
        return tgcalls::NetworkType::Unknown;
    }
    return (tgcalls::NetworkType)t;
}

} // namespace

/* ==================== builder ==================== */

TGCALLS_API void *tgcalls_builder_new(void) {
    ensure_registered();
    return new TgCallsBuilder();
}

TGCALLS_API void tgcalls_builder_set_key(void *builder, const uint8_t *key, int32_t len) {
    auto *b = (TgCallsBuilder *)builder;
    if (!b || !key || len <= 0) {
        return;
    }
    size_t n = (size_t)len;
    if (n > b->key.size()) {
        n = b->key.size();
    }
    memcpy(b->key.data(), key, n);
    b->hasKey = true;
    if (len != tgcalls::EncryptionKey::kSize) {
        log_line("builder_set_key: unexpected key length %d (want %d)", len,
                 tgcalls::EncryptionKey::kSize);
    }
}

TGCALLS_API void tgcalls_builder_set_outgoing(void *builder, bool outgoing) {
    auto *b = (TgCallsBuilder *)builder;
    if (b) {
        b->isOutgoing = outgoing;
    }
}

TGCALLS_API void tgcalls_builder_set_version(void *builder, const char *version, int32_t maxLayer) {
    auto *b = (TgCallsBuilder *)builder;
    if (!b) {
        return;
    }
    if (version && version[0] != '\0') {
        b->version = version;
    }
    if (maxLayer > 0) {
        b->maxLayer = maxLayer;
    }
}

TGCALLS_API void tgcalls_builder_set_network_params(void *builder, bool allowP2P, bool allowTCP,
                                                    bool enableStunMarking) {
    auto *b = (TgCallsBuilder *)builder;
    if (!b) {
        return;
    }
    b->allowP2P = allowP2P;
    b->allowTCP = allowTCP;
    b->enableStunMarking = enableStunMarking;
}

TGCALLS_API void tgcalls_builder_set_video(void *builder, bool isVideo) {
    auto *b = (TgCallsBuilder *)builder;
    if (b) {
        b->isVideo = isVideo; // V1: recorded only; no capturer exists yet
    }
}

TGCALLS_API void tgcalls_builder_add_rtc_server(void *builder, int64_t id, const char *host,
                                                uint16_t port, const char *username,
                                                const char *password, bool isTurn, bool isTcp) {
    auto *b = (TgCallsBuilder *)builder;
    if (!b || !host) {
        return;
    }
    tgcalls::RtcServer server;
    server.id = (uint8_t)id;
    server.host = host;
    server.port = port;
    server.login = username ? username : "";
    server.password = password ? password : "";
    server.isTurn = isTurn;
    server.isTcp = isTcp;
    b->rtcServers.push_back(std::move(server));
}

TGCALLS_API void tgcalls_builder_add_endpoint(void *builder, int64_t id, const char *ip,
                                              const char *ipv6, uint16_t port,
                                              const uint8_t *peerTag, int32_t tagLen) {
    auto *b = (TgCallsBuilder *)builder;
    if (!b) {
        return;
    }
    tgcalls::Endpoint endpoint;
    endpoint.endpointId = id;
    endpoint.host.ipv4 = ip ? ip : "";
    endpoint.host.ipv6 = ipv6 ? ipv6 : "";
    endpoint.port = port;
    endpoint.type = tgcalls::EndpointType::UdpRelay;
    if (peerTag && tagLen > 0) {
        size_t n = (size_t)tagLen;
        if (n > sizeof(endpoint.peerTag)) {
            n = sizeof(endpoint.peerTag);
        }
        memcpy(endpoint.peerTag, peerTag, n);
    }
    b->endpoints.push_back(std::move(endpoint));
}

TGCALLS_API void *tgcalls_builder_create(void *builder, void *userData, tg_state_cb onState,
                                         tg_signal_bars_cb onSignalBars,
                                         tg_audio_level_cb onAudioLevel,
                                         tg_signaling_cb onSignalingData,
                                         tg_battery_cb onRemoteBatteryLow) {
    ensure_registered();
    auto *b = (TgCallsBuilder *)builder;
    if (!b) {
        return nullptr;
    }

    tgcalls::SetLoggingFunction([](std::string const &line) {
        fprintf(stderr, "[tgcalls] %s\n", line.c_str());
    });

    auto ctx = std::make_shared<CallbackCtx>();
    ctx->userData = userData;
    ctx->onState = onState;
    ctx->onSignalBars = onSignalBars;
    ctx->onAudioLevel = onAudioLevel;
    ctx->onSignalingData = onSignalingData;
    ctx->onRemoteBatteryLow = onRemoteBatteryLow;

    auto keyValue = std::make_shared<std::array<uint8_t, tgcalls::EncryptionKey::kSize>>(b->key);

    tgcalls::Config config;
    config.initializationTimeout = 30.0;
    config.receiveTimeout = 10.0;
    config.dataSaving = tgcalls::DataSaving::Never;
    config.enableP2P = b->allowP2P;
    config.allowTCP = b->allowTCP;
    config.enableStunMarking = b->enableStunMarking;
    config.enableAEC = true;
    config.enableNS = true;
    config.enableAGC = true;
    config.enableVolumeControl = true;
    config.maxApiLayer = b->maxLayer;
    // 视频清晰度：默认 enableHighBitrateVideo=false 会把视频 codec 硬顶在 800kbps
    // (MediaManager.cpp:784 kCodecParamMaxBitrate ? 2000 : 800)，720p 塞不进 → WebRTC
    // 强制降分辨率 → 两端糊。开启后 codec 顶 2000kbps、getMaxVideoBitrate 2Mbps，够 720p 清晰；
    // 仅抬高天花板，WebRTC 拥塞控制仍按实际带宽自适应，弱网自动降。对齐 iOS 好网高码率。
    config.enableHighBitrateVideo = true;

    tgcalls::Descriptor descriptor = {
        .version = b->version,
        .config = config,
        .endpoints = b->endpoints,
        .rtcServers = b->rtcServers,
        .initialNetworkType = tgcalls::NetworkType::Unknown,
        .encryptionKey = tgcalls::EncryptionKey(keyValue, b->isOutgoing),
        .stateUpdated =
            [ctx](tgcalls::State state) {
                if (ctx->alive.load() && ctx->onState) {
                    ctx->onState(ctx->userData, (int32_t)state);
                }
            },
        .signalBarsUpdated =
            [ctx](int bars) {
                if (ctx->alive.load() && ctx->onSignalBars) {
                    ctx->onSignalBars(ctx->userData, (int32_t)bars);
                }
            },
        .audioLevelUpdated =
            [ctx](float level) {
                if (ctx->alive.load() && ctx->onAudioLevel) {
                    ctx->onAudioLevel(ctx->userData, level);
                }
            },
        .remoteBatteryLevelIsLowUpdated =
            [ctx](bool isLow) {
                if (ctx->alive.load() && ctx->onRemoteBatteryLow) {
                    ctx->onRemoteBatteryLow(ctx->userData, isLow);
                }
            },
        .remoteMediaStateUpdated =
            [ctx](tgcalls::AudioState audioState, tgcalls::VideoState videoState) {
                tg_media_state_cb cb = ctx->onRemoteMediaState.load();
                if (ctx->alive.load() && cb) {
                    cb(ctx->remoteMediaStateUser.load(), (int32_t)audioState,
                       (int32_t)videoState);
                }
            },
        .signalingDataEmitted =
            [ctx](const std::vector<uint8_t> &data) {
                if (ctx->alive.load() && ctx->onSignalingData) {
                    ctx->onSignalingData(ctx->userData, data.data(), (int32_t)data.size());
                }
            },
        .createAudioDeviceModule =
            [](webrtc::TaskQueueFactory *taskQueueFactory)
            -> webrtc::scoped_refptr<webrtc::AudioDeviceModule> {
                // Step 5b: real OH_Audio ADM (OH_AudioCapturer/OH_AudioRenderer,
                // 48k/mono/S16) so an accepted call carries live audio. If it
                // can't be built, tgcalls' createAudioDeviceModule() validates
                // Init()==0 and falls back to the in-tree dummy ADM
                // (audio_device_impl.cc is compiled with WEBRTC_DUMMY_AUDIO_BUILD),
                // so the call still connects — just silent.
                log_line("createAudioDeviceModule: OH_Audio ADM (5b)");
                auto adm = tgcalls_ohos::CreateOHAudioDeviceModule(taskQueueFactory);
                if (adm) {
                    return adm;
                }
                log_line("createAudioDeviceModule: OH_Audio unavailable, dummy fallback");
                return webrtc::AudioDeviceModule::Create(
                    webrtc::AudioDeviceModule::kDummyAudio, taskQueueFactory);
            },
    };

    // Glare 竞态修复（8.0.0 拨出方向 iOS 恒 video=0 的根因之一）：
    // 视频通话的 capturer 必须在 Meta::Create 之前进 descriptor——这样我方首轮
    // NegotiateChannels offer 就携带视频，不会产生"第二轮视频 offer"与对端的
    // offer 相撞。晚挂载（create 后 setVideoCapture）会触发 tgcalls
    // ContentNegotiationContext 的 glare：主叫侧无声忽略对端 offer（return
    // nullptr），被叫侧丢弃自己的 offer 且 _needNegotiation 不复位 → 被叫的
    // 视频通道永远协商不出（音频通、视频哑）。iOS 官方即在 Descriptor 预挂载。
    std::shared_ptr<tgcalls::VideoCaptureInterface> preVideoCapture;
    if (b->isVideo) {
        log_line("builder_create: pre-attaching camera capturer (front) for video call");
        preVideoCapture =
            tgcalls::VideoCaptureInterface::Create(tgcalls::StaticThreads::getThreads(), "front");
        preVideoCapture->setState(tgcalls::VideoState::Active);
        descriptor.videoCapture = preVideoCapture;
    }

    auto instance = tgcalls::Meta::Create(b->version, std::move(descriptor));
    if (!instance) {
        log_line("builder_create: version '%s' not registered", b->version.c_str());
        return nullptr;
    }

    auto *wrapper = new TgCallsInstance();
    wrapper->ctx = ctx;
    wrapper->instance = std::move(instance);
    // 预挂载的 capturer 交给 wrapper 托管：set_video_enabled(1) 幂等复用
    // （不再二次创建），set_local_video_output 可直接挂本地预览 sink
    wrapper->videoCapture = preVideoCapture;
    log_line("builder_create: instance up (version=%s outgoing=%d rtcServers=%zu endpoints=%zu)",
             b->version.c_str(), (int)b->isOutgoing, b->rtcServers.size(), b->endpoints.size());
    return wrapper;
}

TGCALLS_API void tgcalls_builder_free(void *builder) {
    delete (TgCallsBuilder *)builder;
}

/* ==================== instance ==================== */

TGCALLS_API void tgcalls_receive_signaling(void *instance, const uint8_t *data, int32_t size) {
    auto *w = (TgCallsInstance *)instance;
    if (!w || !w->instance || !data || size <= 0) {
        return;
    }
    std::vector<uint8_t> buffer(data, data + size);
    w->instance->receiveSignalingData(buffer);
}

TGCALLS_API void tgcalls_set_mute(void *instance, bool muted) {
    auto *w = (TgCallsInstance *)instance;
    if (w && w->instance) {
        w->instance->setMuteMicrophone(muted);
    }
}

TGCALLS_API void tgcalls_set_speaker(bool speaker) {
    // Global (no instance) by contract: earpiece <-> loudspeaker for the
    // VOICE_COMMUNICATION renderer (OH_AudioRenderer_SetDefaultOutputDevice).
    tgcalls_ohos::SetSpeakerOutput(speaker);
}

TGCALLS_API void tgcalls_set_network_type(void *instance, int32_t networkType) {
    auto *w = (TgCallsInstance *)instance;
    if (w && w->instance) {
        w->instance->setNetworkType(map_network_type(networkType));
    }
}

TGCALLS_API void tgcalls_stop(void *instance) {
    auto *w = (TgCallsInstance *)instance;
    if (!w || !w->instance || w->stopped) {
        return;
    }
    w->stopped = true;
    auto done = std::make_shared<std::promise<void>>();
    auto future = done->get_future();
    w->instance->stop([done](tgcalls::FinalState finalState) {
        (void)finalState;
        done->set_value();
    });
    if (future.wait_for(std::chrono::seconds(5)) != std::future_status::ready) {
        log_line("stop: completion timed out after 5s (continuing)");
    }
}

TGCALLS_API void tgcalls_destroy(void *instance) {
    auto *w = (TgCallsInstance *)instance;
    if (!w) {
        return;
    }
    w->ctx->alive.store(false);
    w->instance.reset(); // joins tgcalls threads; no callbacks after this
    {
        std::lock_guard<std::mutex> lock(w->videoMutex);
        w->videoCapture.reset(); // releases the camera (5c)
    }
    delete w;
}

/* ==================== video (5c: real frames) ==================== */

TGCALLS_API void tgcalls_set_video_enabled(void *instance, bool enabled) {
    auto *w = (TgCallsInstance *)instance;
    if (!w || !w->instance) {
        return;
    }
    std::lock_guard<std::mutex> lock(w->videoMutex);
    if (enabled) {
        if (!w->videoCapture) {
            log_line("set_video_enabled(1): creating camera capturer (front)");
            w->videoCapture =
                tgcalls::VideoCaptureInterface::Create(tgcalls::StaticThreads::getThreads(), "front");
            if (w->localSink) {
                w->videoCapture->setOutput(w->localSink);
            }
            w->videoCapture->setState(tgcalls::VideoState::Active);
        }
        w->instance->setVideoCapture(w->videoCapture);
        log_line("set_video_enabled(1): capture attached to instance");
    } else {
        log_line("set_video_enabled(0): detaching + releasing camera");
        w->instance->setVideoCapture(nullptr);
        w->videoCapture.reset();
    }
}

TGCALLS_API void tgcalls_set_video_aspect(void *instance, float aspect) {
    auto *w = (TgCallsInstance *)instance;
    if (w && w->instance) {
        w->instance->setRequestedVideoAspect(aspect);
    }
}

TGCALLS_API void tgcalls_set_video_output(void *instance, tg_video_frame_cb onFrame, void *user) {
    auto *w = (TgCallsInstance *)instance;
    if (!w) {
        return;
    }
    w->ctx->videoFrameUser.store(user);
    w->ctx->onVideoFrame.store(onFrame);
    std::lock_guard<std::mutex> lock(w->videoMutex);
    if (onFrame && w->instance) {
        if (!w->remoteSink) {
            w->remoteSink = std::make_shared<BgraFrameSink>(w->ctx, false, 33); // <=30fps
        }
        w->instance->setIncomingVideoOutput(w->remoteSink);
        log_line("set_video_output: incoming sink attached");
    }
}

TGCALLS_API void tgcalls_set_local_video_output(void *instance, tg_video_frame_cb onFrame,
                                                void *user) {
    auto *w = (TgCallsInstance *)instance;
    if (!w) {
        return;
    }
    w->ctx->localVideoFrameUser.store(user);
    w->ctx->onLocalVideoFrame.store(onFrame);
    std::lock_guard<std::mutex> lock(w->videoMutex);
    if (onFrame) {
        if (!w->localSink) {
            w->localSink = std::make_shared<BgraFrameSink>(w->ctx, true, 66); // <=15fps preview
        }
        if (w->videoCapture) {
            w->videoCapture->setOutput(w->localSink);
        }
        log_line("set_local_video_output: sink %s", w->videoCapture ? "attached" : "pending capturer");
    }
}

// Remote-video GPU direct render: bind an XComponent's surface so the HW
// decoder composites frames straight to the display (zero CPU copy). Called
// from Cangjie once the ArkTS XComponent hands over its surfaceId; the decoder
// (created later by tgcalls) picks it up on init. Idempotent; pass 0 to clear.
static OHNativeWindow *g_remoteWindow = nullptr;
static std::mutex g_remoteWindowMutex;

TGCALLS_API void tgcalls_set_remote_video_surface(uint64_t surfaceId) {
    std::lock_guard<std::mutex> lock(g_remoteWindowMutex);
    if (g_remoteWindow) {
        tgcalls_ohos::SetRemoteRenderSurface(nullptr);
        OH_NativeWindow_DestroyNativeWindow(g_remoteWindow);
        g_remoteWindow = nullptr;
    }
    if (surfaceId != 0) {
        OHNativeWindow *win = nullptr;
        int32_t err = OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceId, &win);
        if (err == 0 && win) {
            // Aspect-preserving fill (iOS cover 观感): 默认 SCALE_TO_WINDOW 会把
            // 720x1280 帧整幅拉进 1260x2720 窗口（横向压瘦, RSTree 实锤 Gravity=RESIZE/
            // ScalingMode=1)。SCALE_CROP 保比例填满并裁边。
            int32_t sm = OH_NativeWindow_NativeWindowSetScalingModeV2(
                win, OH_SCALING_MODE_SCALE_CROP_V2);
            log_line("surface scaling mode SCALE_CROP_V2 -> %d", sm);
            g_remoteWindow = win;
            tgcalls_ohos::SetRemoteRenderSurface(win);
            log_line("remote video surface bound (surfaceId=%llu)", (unsigned long long)surfaceId);
        } else {
            log_line("CreateNativeWindowFromSurfaceId failed err=%d", err);
        }
    }
}

TGCALLS_API void tgcalls_clear_remote_video_surface(void) {
    tgcalls_set_remote_video_surface(0);
}

// Process-wide truth for "is a render surface bound". The Cangjie napi module
// (ArkTS bridge) and the Cangjie page code may live in different Cangjie
// runtimes whose statics are NOT shared — a Cangjie-side flag set by the bridge
// can read false from the page. The native global is shared by definition, so
// the page polls this instead.
TGCALLS_API int32_t tgcalls_remote_video_surface_active(void) {
    return tgcalls_ohos::GetRemoteRenderSurface() != nullptr ? 1 : 0;
}

TGCALLS_API void tgcalls_switch_camera(void *instance, const char *deviceId) {
    auto *w = (TgCallsInstance *)instance;
    if (!w) {
        return;
    }
    std::lock_guard<std::mutex> lock(w->videoMutex);
    if (w->videoCapture) {
        std::string device = deviceId ? deviceId : "front";
        bool wantBack = device.find("back") != std::string::npos;
        log_line("switch_camera(%s) wantBack=%d", device.c_str(), (int)wantBack);
        // In-place flip on the capturer's own thread. NOT switchToDevice(): that
        // synchronously destroys+recreates the whole OhosCameraCapturer on the
        // tgcalls media thread, which wedges the OHOS camera stack and made flip
        // freeze the local video and time out call teardown. withNativeImplementation
        // hands us the OhosCameraCapturer* (on the media thread); SwitchOhosCameraNative
        // only kicks the switch worker and returns, so the media thread never blocks.
        w->videoCapture->withNativeImplementation([wantBack](void *nativePtr) {
            tgcalls_ohos::SwitchOhosCameraNative(nativePtr, wantBack);
        });
    }
}

TGCALLS_API void tgcalls_set_remote_media_state_cb(void *instance, tg_media_state_cb cb,
                                                   void *user) {
    auto *w = (TgCallsInstance *)instance;
    if (!w) {
        return;
    }
    w->ctx->remoteMediaStateUser.store(user);
    w->ctx->onRemoteMediaState.store(cb);
}

/* ==================== globals ==================== */

TGCALLS_API const uint8_t *tgcalls_get_versions(void) {
    ensure_registered();
    std::string joined;
    for (const auto &version : tgcalls::Meta::Versions()) {
        if (!joined.empty()) {
            joined += ",";
        }
        joined += version;
    }
    if (joined.empty()) {
        joined = "12.0.0";
    }
    char *result = (char *)malloc(joined.size() + 1);
    if (!result) {
        return nullptr;
    }
    memcpy(result, joined.c_str(), joined.size() + 1);
    return (const uint8_t *)result;
}

TGCALLS_API int32_t tgcalls_get_max_layer(void) {
    ensure_registered();
    return (int32_t)tgcalls::Meta::MaxLayer();
}

TGCALLS_API void tgcalls_free_string(const uint8_t *str) {
    free((void *)str);
}
