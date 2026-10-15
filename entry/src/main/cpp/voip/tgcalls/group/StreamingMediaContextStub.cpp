// OHOS stub for tgcalls::StreamingMediaContext.
//
// The real implementation decodes broadcast parts (RTMP / unified stream) with
// FFmpeg + opusfile. Group video chats negotiate GroupConnectionMode::GroupConnectionModeRtc,
// where this context is never fed; it only has to link. In broadcast mode the
// object is inert: no audio is produced and no video frames are delivered.
#include "group/StreamingMediaContext.h"

namespace tgcalls {

class StreamingMediaContextPrivate {};

StreamingMediaContext::StreamingMediaContext(StreamingMediaContextArguments &&arguments) {
    (void)arguments;
}

StreamingMediaContext::~StreamingMediaContext() = default;

void StreamingMediaContext::setActiveVideoChannels(std::vector<VideoChannel> const &videoChannels) {
    (void)videoChannels;
}

void StreamingMediaContext::setVolume(uint32_t ssrc, double volume) {
    (void)ssrc;
    (void)volume;
}

void StreamingMediaContext::addVideoSink(std::string const &endpointId, std::weak_ptr<rtc::VideoSinkInterface<webrtc::VideoFrame>> sink) {
    (void)endpointId;
    (void)sink;
}

void StreamingMediaContext::getAudio(int16_t *audio_samples, const size_t num_samples, const size_t num_channels, const uint32_t samples_per_sec) {
    (void)samples_per_sec;
    if (audio_samples != nullptr) {
        for (size_t i = 0; i < num_samples * num_channels; i++) {
            audio_samples[i] = 0;
        }
    }
}

}
