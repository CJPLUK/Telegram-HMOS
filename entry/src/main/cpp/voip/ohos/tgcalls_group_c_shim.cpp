// C ABI for the tgcalls group engine (GroupInstanceCustomImpl) on OHOS.
//
// Mirrors what iOS reaches through OngoingGroupCallContext / GroupCallThreadLocalContext
// (submodules/TelegramVoip/Sources/GroupCallContext.swift,
//  submodules/TgVoipWebrtc/Sources/OngoingCallThreadLocalContext.mm:2478-2907):
//   create -> emit_join_payload -> [app: phone.joinGroupCall] -> set_connection_mode(rtc)
//   -> set_join_response -> audio levels / network state callbacks -> stop/destroy.
//
// Threading: every callback fires on a tgcalls/webrtc worker thread. The Cangjie side
// must hop to its own executor before touching UI state.
//
// Lifetime: descriptor lambdas capture shared_ptr<GroupCallbackCtx>, never the wrapper,
// so a late callback racing tgcalls_group_destroy() observes alive == false.
#include "group/GroupInstanceCustomImpl.h"
#include "group/GroupInstanceImpl.h"
#include "StaticThreads.h"

#include "api/scoped_refptr.h"
#include "api/task_queue/task_queue_factory.h"
#include "modules/audio_device/include/audio_device.h"

#include <hilog/log.h>

#include <atomic>
#include <condition_variable>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "ohos_audio_device.h"
#include "ohos_surface_sink.h"
#include "ohos_video_capturer.h"

#include "VideoCaptureInterface.h"
#include "rtc_base/logging.h"
#include "third-party/json11.hpp"

#define TGCALLS_API extern "C" __attribute__((visibility("default")))

namespace {

// (user, isConnected, isTransitioningFromBroadcastToRtc, connectionMode 0 none / 1 rtc / 2 broadcast)
typedef void (*tg_group_network_state_cb)(void *user, bool isConnected, bool isTransitioning, int32_t mode);
// Parallel arrays of length n. ssrc == 0 is the local microphone (iOS AudioLevelKey.local).
typedef void (*tg_group_audio_levels_cb)(void *user, const uint32_t *ssrcs, const float *levels,
                                         const uint8_t *voice, int32_t n);
// (user, json, audioSsrc). json is GroupJoinInternalPayload::serialize() verbatim.
typedef void (*tg_group_join_payload_cb)(void *user, const char *json, uint32_t audioSsrc);
// Engine met RTP from ssrcs it has no description for. Answer with
// tgcalls_group_provide_channels(instance, requestId, ...). Unanswered requests are harmless.
typedef void (*tg_group_request_channels_cb)(void *user, int64_t requestId, const uint32_t *ssrcs, int32_t n);

void glog(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, "tgcalls_ohos", "[group] %{public}s", buf);
}

// WebRTC / tgcalls RTC_LOG -> hilog, errors only. (The bring-up build also forwarded
// warnings and video/codec info lines; that is several lines per second in a call.)
class HilogRtcSink final : public rtc::LogSink {
public:
    void OnLogMessage(const std::string &message) override { (void)message; }
    void OnLogMessage(const std::string &message, rtc::LoggingSeverity severity) override {
        if (severity >= rtc::LS_ERROR) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, 0, "tgcalls_ohos", "[rtc] %{public}.400s", message.c_str());
        }
    }
};

void ensure_rtc_logging() {
    static HilogRtcSink *sink = [] {
        auto *s = new HilogRtcSink();
        rtc::LogMessage::AddLogToStream(s, rtc::LS_ERROR);
        return s;
    }();
    (void)sink;
}

struct PendingChannelRequest {
    std::function<void(std::vector<tgcalls::MediaChannelDescription> &&)> completion;
};

struct GroupCallbackCtx {
    void *userData = nullptr;
    tg_group_network_state_cb onNetworkState = nullptr;
    tg_group_audio_levels_cb onAudioLevels = nullptr;
    tg_group_request_channels_cb onRequestChannels = nullptr;
    std::atomic<bool> alive{true};

    std::mutex requestsMutex;
    int64_t nextRequestId = 1;
    std::map<int64_t, PendingChannelRequest> requests;
};

class ChannelRequestTask final : public tgcalls::RequestMediaChannelDescriptionTask {
public:
    ChannelRequestTask(std::shared_ptr<GroupCallbackCtx> ctx, int64_t requestId)
        : _ctx(std::move(ctx)), _requestId(requestId) {}

    void cancel() override {
        std::lock_guard<std::mutex> lock(_ctx->requestsMutex);
        _ctx->requests.erase(_requestId);
    }

private:
    std::shared_ptr<GroupCallbackCtx> _ctx;
    int64_t _requestId;
};

struct TgGroupInstance {
    std::shared_ptr<GroupCallbackCtx> ctx;
    std::unique_ptr<tgcalls::GroupInstanceCustomImpl> impl;

    std::mutex videoMutex;
    std::shared_ptr<tgcalls::VideoCaptureInterface> videoCapture;
    std::shared_ptr<tgcalls_ohos::SurfaceFrameSink> localSink;
    // endpointId -> sink. tgcalls only keeps weak refs, so these own the sinks.
    std::map<std::string, std::shared_ptr<tgcalls_ohos::SurfaceFrameSink>> incomingSinks;
};

tgcalls::VideoChannelDescription::Quality qualityFromInt(int v) {
    if (v >= 2) {
        return tgcalls::VideoChannelDescription::Quality::Full;
    }
    if (v == 1) {
        return tgcalls::VideoChannelDescription::Quality::Medium;
    }
    return tgcalls::VideoChannelDescription::Quality::Thumbnail;
}

}  // namespace

static void *group_create_impl(void *user,
                               tg_group_network_state_cb onNetworkState,
                               tg_group_audio_levels_cb onAudioLevels,
                               tg_group_request_channels_cb onRequestChannels,
                               int32_t outgoingAudioBitrateKbit,
                               bool enableNoiseSuppression,
                               bool disableAudioInput,
                               bool screencast) {
    ensure_rtc_logging();
    auto ctx = std::make_shared<GroupCallbackCtx>();
    ctx->userData = user;
    ctx->onNetworkState = onNetworkState;
    ctx->onAudioLevels = onAudioLevels;
    ctx->onRequestChannels = onRequestChannels;

    tgcalls::GroupInstanceDescriptor descriptor;
    descriptor.threads = tgcalls::StaticThreads::getThreads();
    descriptor.config.need_log = false;
    descriptor.networkStateUpdated = [ctx](tgcalls::GroupNetworkState state) {
        if (!ctx->alive.load() || !ctx->onNetworkState) {
            return;
        }
        int32_t mode = 0;
        switch (state.connectionMode) {
            case tgcalls::GroupConnectionMode::GroupConnectionModeNone: mode = 0; break;
            case tgcalls::GroupConnectionMode::GroupConnectionModeRtc: mode = 1; break;
            case tgcalls::GroupConnectionMode::GroupConnectionModeBroadcast: mode = 2; break;
        }
        glog("network state: connected=%d transitioning=%d mode=%d",
             state.isConnected ? 1 : 0, state.isTransitioningFromBroadcastToRtc ? 1 : 0, mode);
        ctx->onNetworkState(ctx->userData, state.isConnected, state.isTransitioningFromBroadcastToRtc, mode);
    };
    descriptor.audioLevelsUpdated = [ctx](tgcalls::GroupLevelsUpdate const &update) {
        if (!ctx->alive.load() || !ctx->onAudioLevels || update.updates.empty()) {
            return;
        }
        const size_t n = update.updates.size();
        std::vector<uint32_t> ssrcs(n);
        std::vector<float> levels(n);
        std::vector<uint8_t> voice(n);
        for (size_t i = 0; i < n; i++) {
            const auto &it = update.updates[i];
            ssrcs[i] = it.ssrc;
            // iOS zeroes the level of a muted source (OngoingCallThreadLocalContext.mm:2506-2518).
            levels[i] = it.value.isMuted ? 0.0f : it.value.level;
            voice[i] = it.value.voice ? 1 : 0;
        }
        ctx->onAudioLevels(ctx->userData, ssrcs.data(), levels.data(), voice.data(), (int32_t)n);
    };
    descriptor.requestMediaChannelDescriptions =
        [ctx](std::vector<uint32_t> const &ssrcs,
              std::function<void(std::vector<tgcalls::MediaChannelDescription> &&)> completion)
        -> std::shared_ptr<tgcalls::RequestMediaChannelDescriptionTask> {
        int64_t requestId = 0;
        {
            std::lock_guard<std::mutex> lock(ctx->requestsMutex);
            requestId = ctx->nextRequestId++;
            ctx->requests[requestId] = PendingChannelRequest{std::move(completion)};
        }
        if (ctx->alive.load() && ctx->onRequestChannels && !ssrcs.empty()) {
            ctx->onRequestChannels(ctx->userData, requestId, ssrcs.data(), (int32_t)ssrcs.size());
        }
        return std::make_shared<ChannelRequestTask>(ctx, requestId);
    };
    descriptor.createAudioDeviceModule =
        [screencast](webrtc::TaskQueueFactory *taskQueueFactory) -> webrtc::scoped_refptr<webrtc::AudioDeviceModule> {
        if (screencast) {
            // The screen-share instance carries video only; a second OH_Audio stream would fight the call's.
            return webrtc::AudioDeviceModule::Create(webrtc::AudioDeviceModule::kDummyAudio, taskQueueFactory);
        }
        auto adm = tgcalls_ohos::CreateOHAudioDeviceModule(taskQueueFactory);
        if (adm) {
            glog("createAudioDeviceModule: OH_Audio ADM");
            return adm;
        }
        glog("createAudioDeviceModule: OH_Audio unavailable, dummy fallback");
        return webrtc::AudioDeviceModule::Create(webrtc::AudioDeviceModule::kDummyAudio, taskQueueFactory);
    };
    descriptor.outgoingAudioBitrateKbit = outgoingAudioBitrateKbit > 0 ? outgoingAudioBitrateKbit : 32;
    descriptor.initialEnableNoiseSuppression = enableNoiseSuppression;
    descriptor.disableAudioInput = disableAudioInput;
    // Generic: the join payload announces our (not yet sending) simulcast ssrc
    // groups, so the camera can be switched on later without rejoining — same as iOS.
    descriptor.videoContentType = screencast ? tgcalls::VideoContentType::Screencast : tgcalls::VideoContentType::Generic;
    // H264 first: the OHOS hardware codec handles it; VP8 is the software fallback.
    descriptor.videoCodecPreferences = {tgcalls::VideoCodecName::H264, tgcalls::VideoCodecName::VP8};
    descriptor.minOutgoingVideoBitrateKbit = 500;                   // OngoingCallThreadLocalContext.mm:2454
    descriptor.isConference = false;

    auto *wrapper = new TgGroupInstance();
    wrapper->ctx = ctx;
    wrapper->impl = std::make_unique<tgcalls::GroupInstanceCustomImpl>(std::move(descriptor));
    glog("created instance=%p bitrate=%d ns=%d screencast=%d", (void *)wrapper, outgoingAudioBitrateKbit,
         enableNoiseSuppression ? 1 : 0, screencast ? 1 : 0);
    return wrapper;
}

TGCALLS_API void *tgcalls_group_create(void *user,
                                       tg_group_network_state_cb onNetworkState,
                                       tg_group_audio_levels_cb onAudioLevels,
                                       tg_group_request_channels_cb onRequestChannels,
                                       int32_t outgoingAudioBitrateKbit,
                                       bool enableNoiseSuppression,
                                       bool disableAudioInput) {
    return group_create_impl(user, onNetworkState, onAudioLevels, onRequestChannels, outgoingAudioBitrateKbit,
                             enableNoiseSuppression, disableAudioInput, false);
}

// Screen-share instance (iOS: the separate screencast OngoingGroupCallContext): video-only,
// VideoContentType::Screencast (screencast simulcast bitrates), dummy audio device.
TGCALLS_API void *tgcalls_group_create_screencast(void *user,
                                                  tg_group_network_state_cb onNetworkState,
                                                  tg_group_request_channels_cb onRequestChannels) {
    return group_create_impl(user, onNetworkState, nullptr, onRequestChannels, 32, false, true, true);
}

// Start/stop capturing the screen into this (screencast) instance. The system consent dialog
// appears on start; the network-state callback reports the outcome indirectly (no video sent).
TGCALLS_API void tgcalls_group_set_screen_capture(void *instance, bool enabled) {
    auto *w = static_cast<TgGroupInstance *>(instance);
    if (!w || !w->impl) {
        return;
    }
    std::lock_guard<std::mutex> lock(w->videoMutex);
    if (enabled) {
        if (!w->videoCapture) {
            glog("screen: creating screen capturer");
            w->videoCapture = tgcalls::VideoCaptureInterface::Create(tgcalls::StaticThreads::getThreads(), "screen");
            w->videoCapture->setState(tgcalls::VideoState::Active);
        }
        w->impl->setVideoCapture(w->videoCapture);
    } else {
        glog("screen: releasing screen capturer");
        w->impl->setVideoCapture(nullptr);
        w->videoCapture.reset();
    }
}

TGCALLS_API void tgcalls_group_emit_join_payload(void *instance, tg_group_join_payload_cb cb, void *user) {
    auto *w = static_cast<TgGroupInstance *>(instance);
    if (!w || !w->impl || !cb) {
        return;
    }
    auto ctx = w->ctx;
    w->impl->emitJoinPayload([ctx, cb, user](tgcalls::GroupJoinPayload const &payload) {
        if (!ctx->alive.load()) {
            return;
        }
        glog("join payload: ssrc=%u jsonLen=%zu", payload.audioSsrc, payload.json.size());
        cb(user, payload.json.c_str(), payload.audioSsrc);
    });
}

TGCALLS_API void tgcalls_group_set_connection_mode(void *instance, int32_t mode, bool keepBroadcastIfWasEnabled,
                                                   bool isUnifiedBroadcast) {
    auto *w = static_cast<TgGroupInstance *>(instance);
    if (!w || !w->impl) {
        return;
    }
    tgcalls::GroupConnectionMode m = tgcalls::GroupConnectionMode::GroupConnectionModeNone;
    if (mode == 1) {
        m = tgcalls::GroupConnectionMode::GroupConnectionModeRtc;
    } else if (mode == 2) {
        m = tgcalls::GroupConnectionMode::GroupConnectionModeBroadcast;
    }
    w->impl->setConnectionMode(m, keepBroadcastIfWasEnabled, isUnifiedBroadcast);
}

TGCALLS_API void tgcalls_group_set_join_response(void *instance, const char *json) {
    auto *w = static_cast<TgGroupInstance *>(instance);
    if (!w || !w->impl || !json) {
        return;
    }
    glog("set join response: len=%zu", strlen(json));
    w->impl->setJoinResponsePayload(std::string(json));
}

TGCALLS_API void tgcalls_group_set_muted(void *instance, bool isMuted) {
    auto *w = static_cast<TgGroupInstance *>(instance);
    if (w && w->impl) {
        w->impl->setIsMuted(isMuted);
    }
}

TGCALLS_API void tgcalls_group_set_noise_suppression(void *instance, bool enabled) {
    auto *w = static_cast<TgGroupInstance *>(instance);
    if (w && w->impl) {
        w->impl->setIsNoiseSuppressionEnabled(enabled);
    }
}

// volume: 1.0 == 100% (iOS passes participant.volume / 10000.0).
TGCALLS_API void tgcalls_group_set_volume(void *instance, uint32_t ssrc, double volume) {
    auto *w = static_cast<TgGroupInstance *>(instance);
    if (w && w->impl) {
        w->impl->setVolume(ssrc, volume);
    }
}

TGCALLS_API void tgcalls_group_remove_ssrcs(void *instance, const uint32_t *ssrcs, int32_t n) {
    auto *w = static_cast<TgGroupInstance *>(instance);
    if (!w || !w->impl || !ssrcs || n <= 0) {
        return;
    }
    w->impl->removeSsrcs(std::vector<uint32_t>(ssrcs, ssrcs + n));
}

// Answers a tg_group_request_channels_cb. Only audio descriptions for now (P4 adds video).
// Unknown ssrcs are simply left out; an empty answer (n == 0) is valid.
TGCALLS_API void tgcalls_group_provide_channels(void *instance, int64_t requestId, const uint32_t *ssrcs,
                                                const int64_t *userIds, int32_t n) {
    auto *w = static_cast<TgGroupInstance *>(instance);
    if (!w) {
        return;
    }
    std::function<void(std::vector<tgcalls::MediaChannelDescription> &&)> completion;
    {
        std::lock_guard<std::mutex> lock(w->ctx->requestsMutex);
        auto it = w->ctx->requests.find(requestId);
        if (it == w->ctx->requests.end()) {
            return;
        }
        completion = std::move(it->second.completion);
        w->ctx->requests.erase(it);
    }
    std::vector<tgcalls::MediaChannelDescription> result;
    for (int32_t i = 0; i < n; i++) {
        tgcalls::MediaChannelDescription d;
        d.type = tgcalls::MediaChannelDescription::Type::Audio;
        d.audioSsrc = ssrcs[i];
        d.userId = userIds ? userIds[i] : 0;
        result.push_back(std::move(d));
    }
    if (completion) {
        completion(std::move(result));
    }
}

/* ==================== video ==================== */

// Camera on/off. The capturer is created lazily and released on disable so the
// camera indicator goes away. front: true = selfie camera.
TGCALLS_API void tgcalls_group_set_video_enabled(void *instance, bool enabled, bool front) {
    auto *w = static_cast<TgGroupInstance *>(instance);
    if (!w || !w->impl) {
        return;
    }
    std::lock_guard<std::mutex> lock(w->videoMutex);
    if (enabled) {
        if (!w->videoCapture) {
            glog("video: creating camera capturer (%s)", front ? "front" : "back");
            w->videoCapture = tgcalls::VideoCaptureInterface::Create(tgcalls::StaticThreads::getThreads(),
                                                                     front ? "front" : "back");
            w->videoCapture->setState(tgcalls::VideoState::Active);
        }
        // The engine installs its own broadcaster as the capturer's output, so the
        // self preview must hang off addOutgoingVideoOutput (see set_local_video_surface).
        w->impl->setVideoCapture(w->videoCapture);
    } else {
        glog("video: releasing camera capturer");
        w->impl->setVideoCapture(nullptr);
        w->videoCapture.reset();
    }
}

TGCALLS_API void tgcalls_group_switch_camera(void *instance, bool front) {
    auto *w = static_cast<TgGroupInstance *>(instance);
    if (!w) {
        return;
    }
    std::lock_guard<std::mutex> lock(w->videoMutex);
    if (w->videoCapture) {
        const bool wantBack = !front;
        w->videoCapture->withNativeImplementation([wantBack](void *nativePtr) {
            tgcalls_ohos::SwitchOhosCameraNative(nativePtr, wantBack);
        });
    }
}

// Self preview into an XComponent surface. surfaceId 0 detaches.
TGCALLS_API void tgcalls_group_set_local_video_surface(void *instance, uint64_t surfaceId, bool mirror) {
    auto *w = static_cast<TgGroupInstance *>(instance);
    if (!w) {
        return;
    }
    std::lock_guard<std::mutex> lock(w->videoMutex);
    w->localSink = tgcalls_ohos::SurfaceFrameSink::Create(surfaceId, mirror, "local");
    if (w->localSink && w->impl) {
        w->impl->addOutgoingVideoOutput(w->localSink);   // weak ref; dropped when replaced
    }
}

// Remote video of one endpoint into an XComponent surface. surfaceId 0 detaches.
TGCALLS_API void tgcalls_group_set_incoming_video_surface(void *instance, const char *endpointId,
                                                          uint64_t surfaceId) {
    auto *w = static_cast<TgGroupInstance *>(instance);
    if (!w || !w->impl || !endpointId) {
        return;
    }
    std::string endpoint(endpointId);
    std::lock_guard<std::mutex> lock(w->videoMutex);
    if (surfaceId == 0) {
        w->incomingSinks.erase(endpoint);
        return;
    }
    auto sink = tgcalls_ohos::SurfaceFrameSink::Create(surfaceId, false, endpoint.c_str());
    if (!sink) {
        return;
    }
    w->incomingSinks[endpoint] = sink;
    w->impl->addIncomingVideoOutput(endpoint, sink);
}

// json: [{"audioSsrc":1,"userId":2,"endpointId":"x","minQuality":0,"maxQuality":1,
//         "ssrcGroups":[{"semantics":"SIM","ssrcs":[1,2,3]}]}]
// Quality: 0 thumbnail / 1 medium / 2 full (iOS PresentationGroupCallRequestedVideo.Quality).
TGCALLS_API void tgcalls_group_set_requested_video_channels(void *instance, const char *json) {
    auto *w = static_cast<TgGroupInstance *>(instance);
    if (!w || !w->impl || !json) {
        return;
    }
    std::string error;
    auto parsed = json11::Json::parse(std::string(json), error);
    if (!error.empty() || !parsed.is_array()) {
        glog("requested channels: bad json (%s)", error.c_str());
        return;
    }
    std::vector<tgcalls::VideoChannelDescription> channels;
    for (const auto &item : parsed.array_items()) {
        tgcalls::VideoChannelDescription d;
        d.audioSsrc = (uint32_t)item["audioSsrc"].number_value();
        d.userId = (int64_t)item["userId"].number_value();
        d.endpointId = item["endpointId"].string_value();
        d.minQuality = qualityFromInt(item["minQuality"].int_value());
        d.maxQuality = qualityFromInt(item["maxQuality"].int_value());
        for (const auto &g : item["ssrcGroups"].array_items()) {
            tgcalls::MediaSsrcGroup group;
            group.semantics = g["semantics"].string_value();
            for (const auto &ssrc : g["ssrcs"].array_items()) {
                group.ssrcs.push_back((uint32_t)ssrc.number_value());
            }
            d.ssrcGroups.push_back(std::move(group));
        }
        if (!d.endpointId.empty()) {
            channels.push_back(std::move(d));
        }
    }
    glog("requested channels: %zu", channels.size());
    w->impl->setRequestedVideoChannels(std::move(channels));
}

// Earpiece / loudspeaker. iOS group chats start on the loudspeaker.
TGCALLS_API void tgcalls_group_set_speaker(bool speaker) {
    tgcalls_ohos::SetSpeakerOutput(speaker);
}

// Blocks until the engine has torn down (5s cap, same policy as tgcalls_stop).
TGCALLS_API void tgcalls_group_stop(void *instance) {
    auto *w = static_cast<TgGroupInstance *>(instance);
    if (!w || !w->impl) {
        return;
    }
    w->ctx->alive.store(false);
    {
        std::lock_guard<std::mutex> lock(w->videoMutex);
        if (w->videoCapture) {
            w->impl->setVideoCapture(nullptr);
            w->videoCapture.reset();
        }
    }
    struct Waiter {
        std::mutex m;
        std::condition_variable cv;
        bool done = false;
    };
    auto waiter = std::make_shared<Waiter>();
    w->impl->stop([waiter]() {
        std::lock_guard<std::mutex> lock(waiter->m);
        waiter->done = true;
        waiter->cv.notify_all();
    });
    {
        std::unique_lock<std::mutex> lock(waiter->m);
        waiter->cv.wait_for(lock, std::chrono::seconds(5), [&] { return waiter->done; });
    }
    glog("stopped instance=%p", (void *)w);
}

TGCALLS_API void tgcalls_group_destroy(void *instance) {
    auto *w = static_cast<TgGroupInstance *>(instance);
    if (!w) {
        return;
    }
    w->ctx->alive.store(false);
    {
        std::lock_guard<std::mutex> lock(w->ctx->requestsMutex);
        w->ctx->requests.clear();
    }
    w->impl.reset();
    {
        std::lock_guard<std::mutex> lock(w->videoMutex);
        w->incomingSinks.clear();
        w->localSink.reset();
    }
    delete w;
}
