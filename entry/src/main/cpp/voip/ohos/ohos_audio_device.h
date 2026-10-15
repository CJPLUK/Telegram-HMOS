// ohos_audio_device.h — OHOS OH_Audio-backed webrtc AudioDeviceModule (step 5b).
//
// Provides a real (non-dummy) AudioDeviceModule for libtgcalls_ohos.so, so an
// accepted call carries live microphone/speaker audio instead of silence.
//
// Design: OHAudioDevice implements webrtc::AudioDeviceGeneric (same contract as
// the in-tree AudioDeviceDummy) using the OHOS NDK OH_AudioCapturer /
// OH_AudioRenderer streams (48 kHz / 16-bit / mono). It is wrapped by the stock
// webrtc AudioDeviceModuleImpl via its inject-a-generic-device constructor, so
// all of the AudioDeviceModule surface + the AudioDeviceBuffer plumbing (which
// bridges to the media engine's Opus encode/decode + APM) is reused verbatim.
//
// The shim's Descriptor.createAudioDeviceModule calls CreateOHAudioDeviceModule.
// InstanceV2ImplInternal::createAudioDeviceModule() validates the result with
// Init()==0 and, on failure, falls back to the dummy ADM — so even if OH_Audio
// stream creation fails on-device (e.g. missing mic permission) the call still
// connects, just silent. See createAudioDeviceModule() in InstanceV2Impl.cpp.

#pragma once

#include "api/scoped_refptr.h"

namespace webrtc {
class AudioDeviceModule;
class TaskQueueFactory;
}  // namespace webrtc

namespace tgcalls_ohos {

// Build an OH_Audio-backed AudioDeviceModule. Returns nullptr only if the ADM
// wrapper itself cannot be constructed (never throws; OH_Audio stream failures
// are deferred to InitPlayout/InitRecording, which degrade to silence).
webrtc::scoped_refptr<webrtc::AudioDeviceModule> CreateOHAudioDeviceModule(
    webrtc::TaskQueueFactory* taskQueueFactory);

// Earpiece / loudspeaker selection for the VOICE_COMMUNICATION renderer
// (OH_AudioRenderer_SetDefaultOutputDevice, API 12+). Process-global: the choice
// is remembered and re-applied whenever a renderer is (re)created, so it may be
// called before the call's audio device exists.
void SetSpeakerOutput(bool speaker);

}  // namespace tgcalls_ohos
