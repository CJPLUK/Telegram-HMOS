// ohos_audio_device.cpp — OH_Audio-backed webrtc AudioDeviceModule (step 5b).
// See ohos_audio_device.h for the design overview.

// audio_device_impl.h hides class AudioDeviceModuleImpl behind this guard; the
// TU that defines it (audio_device_impl.cc) is compiled with the same define
// (see patches/tgcalls/CMakeLists.txt). Define it here too so we see the
// declaration and can construct the ADM via its inject-a-generic-device ctor.
#define WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE

#include "ohos_audio_device.h"

#include <algorithm>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <chrono>
#include <cstring>
#include <memory>
#include <mutex>

#include <hilog/log.h>

#include "api/make_ref_counted.h"
#include "api/task_queue/task_queue_factory.h"
#include "modules/audio_device/audio_device_buffer.h"
#include "modules/audio_device/audio_device_generic.h"
#include "modules/audio_device/audio_device_impl.h"
#include "modules/audio_device/include/audio_device.h"
#include "modules/audio_device/include/audio_device_defines.h"

#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiostream_base.h>
#include <ohaudio/native_audiocapturer.h>
#include <ohaudio/native_audiorenderer.h>

namespace tgcalls_ohos {

namespace {
std::mutex g_route_mutex;
OH_AudioRenderer* g_active_renderer = nullptr;   // owned by OHAudioDevice
bool g_speaker_output = false;                   // false = earpiece (1:1 default)

void ApplyRouteLocked() {
  if (g_active_renderer == nullptr) {
    return;
  }
  OH_AudioStream_Result r = OH_AudioRenderer_SetDefaultOutputDevice(
      g_active_renderer,
      g_speaker_output ? AUDIO_DEVICE_TYPE_SPEAKER : AUDIO_DEVICE_TYPE_EARPIECE);
  OH_LOG_Print(LOG_APP, LOG_INFO, 0, "tgcalls_ohos",
               "[audio] SetDefaultOutputDevice(%{public}s)=%{public}d",
               g_speaker_output ? "speaker" : "earpiece", (int)r);
}
}  // namespace
namespace {

constexpr int32_t kSampleRate = 48000;      // Hz  (webrtc VoIP internal rate)
constexpr int32_t kChannels = 1;            // mono
constexpr int32_t kBytesPerSample = 2;      // S16LE
constexpr size_t kSamplesPer10ms = kSampleRate / 100;                 // 480
constexpr size_t kBytesPer10ms = kSamplesPer10ms * kChannels * kBytesPerSample;  // 960

void oh_log(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, "[tgcalls_ohos/adm] ");
  vfprintf(stderr, fmt, ap);
  fprintf(stderr, "\n");
  va_end(ap);
}

// OH_Audio 10ms-agnostic ADM. Capture/render callbacks arrive on OH_Audio's own
// threads with an arbitrary byte `length`; a fixed 10ms staging chunk per
// direction repackages them into the exact 480-sample frames the webrtc
// AudioDeviceBuffer expects (and back), so the implementation is correct for
// any device callback size.
class OHAudioDevice : public webrtc::AudioDeviceGeneric {
 public:
  OHAudioDevice() = default;
  ~OHAudioDevice() override {
    StopPlayout();
    StopRecording();
  }

  // ---- init / terminate ----------------------------------------------------
  int32_t ActiveAudioLayer(
      webrtc::AudioDeviceModule::AudioLayer& audioLayer) const override {
    audioLayer = webrtc::AudioDeviceModule::kPlatformDefaultAudio;
    return 0;
  }
  InitStatus Init() override {
    initialized_ = true;
    return InitStatus::OK;
  }
  int32_t Terminate() override {
    StopPlayout();
    StopRecording();
    initialized_ = false;
    return 0;
  }
  bool Initialized() const override { return initialized_; }

  // ---- device enumeration (single implicit default device) -----------------
  int16_t PlayoutDevices() override { return 1; }
  int16_t RecordingDevices() override { return 1; }
  int32_t PlayoutDeviceName(uint16_t index,
                            char name[webrtc::kAdmMaxDeviceNameSize],
                            char guid[webrtc::kAdmMaxGuidSize]) override {
    return NameDefaultDevice(index, name, guid);
  }
  int32_t RecordingDeviceName(uint16_t index,
                              char name[webrtc::kAdmMaxDeviceNameSize],
                              char guid[webrtc::kAdmMaxGuidSize]) override {
    return NameDefaultDevice(index, name, guid);
  }
  int32_t SetPlayoutDevice(uint16_t index) override { return 0; }
  int32_t SetPlayoutDevice(
      webrtc::AudioDeviceModule::WindowsDeviceType device) override {
    return 0;
  }
  int32_t SetRecordingDevice(uint16_t index) override { return 0; }
  int32_t SetRecordingDevice(
      webrtc::AudioDeviceModule::WindowsDeviceType device) override {
    return 0;
  }

  // ---- availability / init -------------------------------------------------
  int32_t PlayoutIsAvailable(bool& available) override {
    available = true;
    return 0;
  }
  int32_t RecordingIsAvailable(bool& available) override {
    available = true;
    return 0;
  }
  int32_t InitPlayout() override;
  bool PlayoutIsInitialized() const override { return play_initialized_; }
  int32_t InitRecording() override;
  bool RecordingIsInitialized() const override { return rec_initialized_; }

  // ---- transport control ---------------------------------------------------
  int32_t StartPlayout() override;
  int32_t StopPlayout() override;
  bool Playing() const override { return playing_; }
  int32_t StartRecording() override;
  int32_t StopRecording() override;
  bool Recording() const override { return recording_; }

  // ---- mixer init (no-op; routing handled by OH_Audio usage/source) --------
  int32_t InitSpeaker() override { return 0; }
  bool SpeakerIsInitialized() const override { return true; }
  int32_t InitMicrophone() override { return 0; }
  bool MicrophoneIsInitialized() const override { return true; }

  // ---- volume (not exposed; webrtc/tgcalls handle level & mute) ------------
  int32_t SpeakerVolumeIsAvailable(bool& available) override {
    available = false;
    return 0;
  }
  int32_t SetSpeakerVolume(uint32_t volume) override { return -1; }
  int32_t SpeakerVolume(uint32_t& volume) const override { return -1; }
  int32_t MaxSpeakerVolume(uint32_t& maxVolume) const override { return -1; }
  int32_t MinSpeakerVolume(uint32_t& minVolume) const override { return -1; }
  int32_t MicrophoneVolumeIsAvailable(bool& available) override {
    available = false;
    return 0;
  }
  int32_t SetMicrophoneVolume(uint32_t volume) override { return -1; }
  int32_t MicrophoneVolume(uint32_t& volume) const override { return -1; }
  int32_t MaxMicrophoneVolume(uint32_t& maxVolume) const override { return -1; }
  int32_t MinMicrophoneVolume(uint32_t& minVolume) const override { return -1; }

  // ---- mute (tgcalls mutes via the outgoing channel, not the ADM) ----------
  int32_t SpeakerMuteIsAvailable(bool& available) override {
    available = false;
    return 0;
  }
  int32_t SetSpeakerMute(bool enable) override { return -1; }
  int32_t SpeakerMute(bool& enabled) const override { return -1; }
  int32_t MicrophoneMuteIsAvailable(bool& available) override {
    available = false;
    return 0;
  }
  int32_t SetMicrophoneMute(bool enable) override { return -1; }
  int32_t MicrophoneMute(bool& enabled) const override { return -1; }

  // ---- stereo (mono only) --------------------------------------------------
  int32_t StereoPlayoutIsAvailable(bool& available) override {
    available = false;
    return 0;
  }
  int32_t SetStereoPlayout(bool enable) override { return enable ? -1 : 0; }
  int32_t StereoPlayout(bool& enabled) const override {
    enabled = false;
    return 0;
  }
  int32_t StereoRecordingIsAvailable(bool& available) override {
    available = false;
    return 0;
  }
  int32_t SetStereoRecording(bool enable) override { return enable ? -1 : 0; }
  int32_t StereoRecording(bool& enabled) const override {
    enabled = false;
    return 0;
  }

  // ---- delay (rough constants; feeds webrtc AEC via SetVQEData) ------------
  int32_t PlayoutDelay(uint16_t& delayMS) const override {
    delayMS = kPlayoutDelayMs;
    return 0;
  }

  void AttachAudioBuffer(webrtc::AudioDeviceBuffer* audioBuffer) override {
    audio_buffer_ = audioBuffer;
  }

 private:
  static constexpr uint16_t kPlayoutDelayMs = 40;
  static constexpr int kRecordingDelayMs = 20;

  int32_t NameDefaultDevice(uint16_t index,
                            char name[webrtc::kAdmMaxDeviceNameSize],
                            char guid[webrtc::kAdmMaxGuidSize]) {
    if (index != 0) {
      return -1;
    }
    if (name) {
      std::strncpy(name, "OHOS default audio", webrtc::kAdmMaxDeviceNameSize - 1);
    }
    if (guid) {
      std::strncpy(guid, "ohos_default", webrtc::kAdmMaxGuidSize - 1);
    }
    return 0;
  }

  // OH_Audio C callback trampolines -> member handlers.
  static int32_t RenderWriteCb(OH_AudioRenderer* /*renderer*/, void* userData,
                               void* buffer, int32_t length) {
    return static_cast<OHAudioDevice*>(userData)->OnRenderWrite(buffer, length);
  }
  static int32_t CapturerReadCb(OH_AudioCapturer* /*capturer*/, void* userData,
                                void* buffer, int32_t length) {
    return static_cast<OHAudioDevice*>(userData)->OnCapturerRead(buffer, length);
  }
  // Defensive no-op event/error trampolines so a null slot is never invoked.
  static int32_t RenderNoopEvent(OH_AudioRenderer*, void*, OH_AudioStream_Event) {
    return 0;
  }
  static int32_t RenderNoopInterrupt(OH_AudioRenderer*, void*,
                                     OH_AudioInterrupt_ForceType,
                                     OH_AudioInterrupt_Hint) {
    return 0;
  }
  static int32_t RenderNoopError(OH_AudioRenderer*, void*, OH_AudioStream_Result) {
    return 0;
  }
  static int32_t CapturerNoopEvent(OH_AudioCapturer*, void*, OH_AudioStream_Event) {
    return 0;
  }
  static int32_t CapturerNoopInterrupt(OH_AudioCapturer*, void*,
                                       OH_AudioInterrupt_ForceType,
                                       OH_AudioInterrupt_Hint) {
    return 0;
  }
  static int32_t CapturerNoopError(OH_AudioCapturer*, void*, OH_AudioStream_Result) {
    return 0;
  }

  int32_t OnRenderWrite(void* buffer, int32_t length);
  int32_t OnCapturerRead(void* buffer, int32_t length);

  webrtc::AudioDeviceBuffer* audio_buffer_ = nullptr;

  bool initialized_ = false;
  bool play_initialized_ = false;
  bool rec_initialized_ = false;
  bool playing_ = false;
  bool recording_ = false;

  OH_AudioRenderer* renderer_ = nullptr;
  OH_AudioCapturer* capturer_ = nullptr;

  // 10ms staging chunks (guarded by the matching mutex).
  std::mutex playout_mutex_;
  uint8_t play_chunk_[kBytesPer10ms] = {0};
  size_t play_chunk_pos_ = kBytesPer10ms;  // start "empty" -> pulls on first cb

  std::mutex recording_mutex_;
  uint8_t rec_chunk_[kBytesPer10ms] = {0};
  size_t rec_chunk_len_ = 0;
};

// ---- playout ---------------------------------------------------------------

int32_t OHAudioDevice::InitPlayout() {
  if (playing_) {
    return -1;
  }
  if (play_initialized_) {
    return 0;
  }
  OH_AudioStreamBuilder* builder = nullptr;
  if (OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_RENDERER) !=
      AUDIOSTREAM_SUCCESS) {
    oh_log("InitPlayout: builder create failed");
    return -1;
  }
  OH_AudioStreamBuilder_SetSamplingRate(builder, kSampleRate);
  OH_AudioStreamBuilder_SetChannelCount(builder, kChannels);
  OH_AudioStreamBuilder_SetSampleFormat(builder, AUDIOSTREAM_SAMPLE_S16LE);
  OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
  // VOICE_COMMUNICATION routes to the earpiece/comms path (hardware AEC etc.).
  OH_AudioStreamBuilder_SetRendererInfo(builder,
                                        AUDIOSTREAM_USAGE_VOICE_COMMUNICATION);
  // Low-latency path with 10 ms callbacks. The default (normal mode) asked for ~93 ms of
  // audio per callback: that alone buffered 93-186 ms on playout and made NetEq keep a
  // bigger cushion for the bursty pulls. iOS runs 10-20 ms audio I/O.
  OH_AudioStreamBuilder_SetLatencyMode(builder, AUDIOSTREAM_LATENCY_MODE_FAST);
  OH_AudioStreamBuilder_SetFrameSizeInCallback(builder, (int32_t)kSamplesPer10ms);

  OH_AudioRenderer_Callbacks callbacks;
  std::memset(&callbacks, 0, sizeof(callbacks));
  callbacks.OH_AudioRenderer_OnWriteData = &OHAudioDevice::RenderWriteCb;
  callbacks.OH_AudioRenderer_OnStreamEvent = &OHAudioDevice::RenderNoopEvent;
  callbacks.OH_AudioRenderer_OnInterruptEvent = &OHAudioDevice::RenderNoopInterrupt;
  callbacks.OH_AudioRenderer_OnError = &OHAudioDevice::RenderNoopError;
  OH_AudioStreamBuilder_SetRendererCallback(builder, callbacks, this);

  OH_AudioStream_Result r = OH_AudioStreamBuilder_GenerateRenderer(builder, &renderer_);
  OH_AudioStreamBuilder_Destroy(builder);
  if (r != AUDIOSTREAM_SUCCESS || renderer_ == nullptr) {
    oh_log("InitPlayout: GenerateRenderer failed (%d)", (int)r);
    renderer_ = nullptr;
    return -1;
  }
  play_initialized_ = true;
  {
    std::lock_guard<std::mutex> lock(g_route_mutex);
    g_active_renderer = renderer_;
    ApplyRouteLocked();
  }
  // 显式设渲染音量到最大（质量修复：通话"声音小"部分因从不设渲染音量）。
  // OH_AudioRenderer_SetVolume 存在于 API12+；弱链接式调用，失败仅记日志不致命。
  OH_AudioStream_Result vr = OH_AudioRenderer_SetVolume(renderer_, 1.0f);
  {
    int32_t fs = 0;
    OH_AudioRenderer_GetFrameSizeInCallback(renderer_, &fs);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, "tgcalls_ohos", "[adm] renderer ready: frames/callback=%{public}d (asked %{public}d)", fs, (int)kSamplesPer10ms);
  }
  oh_log("InitPlayout: OH_AudioRenderer ready (48k/mono/S16), SetVolume(1.0)=%d", (int)vr);
  return 0;
}

int32_t OHAudioDevice::StartPlayout() {
  if (!play_initialized_ || renderer_ == nullptr) {
    return -1;
  }
  if (playing_) {
    return 0;
  }
  if (audio_buffer_) {
    audio_buffer_->SetPlayoutSampleRate(kSampleRate);
    audio_buffer_->SetPlayoutChannels(kChannels);
    audio_buffer_->StartPlayout();
  }
  {
    std::lock_guard<std::mutex> lock(playout_mutex_);
    play_chunk_pos_ = kBytesPer10ms;  // force a fresh pull on the first callback
    playing_ = true;
  }
  if (OH_AudioRenderer_Start(renderer_) != AUDIOSTREAM_SUCCESS) {
    oh_log("StartPlayout: OH_AudioRenderer_Start failed");
    std::lock_guard<std::mutex> lock(playout_mutex_);
    playing_ = false;
    return -1;
  }
  oh_log("StartPlayout: playing");
  return 0;
}

int32_t OHAudioDevice::StopPlayout() {
  if (!play_initialized_) {
    return 0;
  }
  // Disarm callbacks first (in-flight ones become silent no-ops), then stop the
  // OH stream WITHOUT holding the mutex (Stop blocks for callback drain -> would
  // deadlock against a callback waiting on the same mutex).
  {
    std::lock_guard<std::mutex> lock(playout_mutex_);
    playing_ = false;
  }
  if (renderer_) {
    {
      std::lock_guard<std::mutex> lock(g_route_mutex);
      if (g_active_renderer == renderer_) {
        g_active_renderer = nullptr;
      }
    }
    OH_AudioRenderer_Stop(renderer_);
    OH_AudioRenderer_Release(renderer_);
    renderer_ = nullptr;
  }
  if (audio_buffer_) {
    audio_buffer_->StopPlayout();
  }
  play_initialized_ = false;
  oh_log("StopPlayout: stopped");
  return 0;
}

// OH_Audio wants `length` bytes to play. Serve them from the 10ms staging chunk,
// pulling fresh 10ms frames from the media engine (via the AudioDeviceBuffer) as
// needed. Fills silence if playout is stopping.
// Diagnostic (OHOS-LAT adm): if OH_Audio calls us in bursts the media engine sees
// starvation on playout / clumped delivery on capture, which shows up as delay.
static void note_callback_gap(const char* which, int32_t length, int64_t& last_ms, int64_t& max_gap,
                              int64_t& calls, int64_t& bytes, int64_t& window_start) {
  const int64_t now = std::chrono::duration_cast<std::chrono::milliseconds>(
                          std::chrono::steady_clock::now().time_since_epoch()).count();
  if (last_ms != 0) {
    const int64_t gap = now - last_ms;
    if (gap > max_gap) max_gap = gap;
  }
  last_ms = now;
  calls++;
  bytes += length;
  if (window_start == 0) window_start = now;
  if (now - window_start >= 10000) {
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, "tgcalls_ohos",
                 "[adm] OHOS-LAT %{public}s/10s: calls=%{public}lld avg_bytes=%{public}lld max_gap_ms=%{public}lld",
                 which, (long long)calls, (long long)(calls ? bytes / calls : 0), (long long)max_gap);
    calls = 0; bytes = 0; max_gap = 0; window_start = now;
  }
}

int32_t OHAudioDevice::OnRenderWrite(void* buffer, int32_t length) {
  uint8_t* dst = static_cast<uint8_t*>(buffer);
  int32_t remaining = length;
  std::lock_guard<std::mutex> lock(playout_mutex_);
  {
    static int64_t last = 0, max_gap = 0, calls = 0, bytes = 0, win = 0;
    note_callback_gap("render", length, last, max_gap, calls, bytes, win);
  }
  while (remaining > 0) {
    if (play_chunk_pos_ >= kBytesPer10ms) {
      if (!playing_ || audio_buffer_ == nullptr) {
        std::memset(dst, 0, remaining);
        return 0;
      }
      audio_buffer_->RequestPlayoutData(kSamplesPer10ms);
      audio_buffer_->GetPlayoutData(play_chunk_);  // always fills 10ms (silence if idle)
      play_chunk_pos_ = 0;
    }
    size_t n = std::min<size_t>(remaining, kBytesPer10ms - play_chunk_pos_);
    std::memcpy(dst, play_chunk_ + play_chunk_pos_, n);
    dst += n;
    play_chunk_pos_ += n;
    remaining -= static_cast<int32_t>(n);
  }
  return 0;
}

// ---- recording -------------------------------------------------------------

int32_t OHAudioDevice::InitRecording() {
  if (recording_) {
    return -1;
  }
  if (rec_initialized_) {
    return 0;
  }
  OH_AudioStreamBuilder* builder = nullptr;
  if (OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_CAPTURER) !=
      AUDIOSTREAM_SUCCESS) {
    oh_log("InitRecording: builder create failed");
    return -1;
  }
  OH_AudioStreamBuilder_SetSamplingRate(builder, kSampleRate);
  OH_AudioStreamBuilder_SetChannelCount(builder, kChannels);
  OH_AudioStreamBuilder_SetSampleFormat(builder, AUDIOSTREAM_SAMPLE_S16LE);
  OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
  // VOICE_COMMUNICATION source => VoIP mic capture (platform AEC/NS).
  OH_AudioStreamBuilder_SetCapturerInfo(builder,
                                        AUDIOSTREAM_SOURCE_TYPE_VOICE_COMMUNICATION);
  OH_AudioStreamBuilder_SetLatencyMode(builder, AUDIOSTREAM_LATENCY_MODE_FAST);
  OH_AudioStreamBuilder_SetFrameSizeInCallback(builder, (int32_t)kSamplesPer10ms);

  OH_AudioCapturer_Callbacks callbacks;
  std::memset(&callbacks, 0, sizeof(callbacks));
  callbacks.OH_AudioCapturer_OnReadData = &OHAudioDevice::CapturerReadCb;
  callbacks.OH_AudioCapturer_OnStreamEvent = &OHAudioDevice::CapturerNoopEvent;
  callbacks.OH_AudioCapturer_OnInterruptEvent = &OHAudioDevice::CapturerNoopInterrupt;
  callbacks.OH_AudioCapturer_OnError = &OHAudioDevice::CapturerNoopError;
  OH_AudioStreamBuilder_SetCapturerCallback(builder, callbacks, this);

  OH_AudioStream_Result r = OH_AudioStreamBuilder_GenerateCapturer(builder, &capturer_);
  OH_AudioStreamBuilder_Destroy(builder);
  if (r != AUDIOSTREAM_SUCCESS || capturer_ == nullptr) {
    oh_log("InitRecording: GenerateCapturer failed (%d) — likely mic permission",
           (int)r);
    capturer_ = nullptr;
    return -1;
  }
  rec_initialized_ = true;
  {
    int32_t fs = 0;
    OH_AudioCapturer_GetFrameSizeInCallback(capturer_, &fs);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, "tgcalls_ohos", "[adm] capturer ready: frames/callback=%{public}d (asked %{public}d)", fs, (int)kSamplesPer10ms);
  }
  oh_log("InitRecording: OH_AudioCapturer ready (48k/mono/S16)");
  return 0;
}

int32_t OHAudioDevice::StartRecording() {
  if (!rec_initialized_ || capturer_ == nullptr) {
    return -1;
  }
  if (recording_) {
    return 0;
  }
  if (audio_buffer_) {
    audio_buffer_->SetRecordingSampleRate(kSampleRate);
    audio_buffer_->SetRecordingChannels(kChannels);
    audio_buffer_->StartRecording();
  }
  {
    std::lock_guard<std::mutex> lock(recording_mutex_);
    rec_chunk_len_ = 0;
    recording_ = true;
  }
  if (OH_AudioCapturer_Start(capturer_) != AUDIOSTREAM_SUCCESS) {
    oh_log("StartRecording: OH_AudioCapturer_Start failed");
    std::lock_guard<std::mutex> lock(recording_mutex_);
    recording_ = false;
    return -1;
  }
  oh_log("StartRecording: recording");
  return 0;
}

int32_t OHAudioDevice::StopRecording() {
  if (!rec_initialized_) {
    return 0;
  }
  {
    std::lock_guard<std::mutex> lock(recording_mutex_);
    recording_ = false;
  }
  if (capturer_) {
    OH_AudioCapturer_Stop(capturer_);
    OH_AudioCapturer_Release(capturer_);
    capturer_ = nullptr;
  }
  if (audio_buffer_) {
    audio_buffer_->StopRecording();
  }
  rec_initialized_ = false;
  oh_log("StopRecording: stopped");
  return 0;
}

// OH_Audio delivers `length` captured bytes. Accumulate into the 10ms staging
// chunk and hand each full 10ms frame to the media engine (encode via Opus).
int32_t OHAudioDevice::OnCapturerRead(void* buffer, int32_t length) {
  const uint8_t* src = static_cast<const uint8_t*>(buffer);
  int32_t remaining = length;
  std::lock_guard<std::mutex> lock(recording_mutex_);
  {
    static int64_t last = 0, max_gap = 0, calls = 0, bytes = 0, win = 0;
    note_callback_gap("capture", length, last, max_gap, calls, bytes, win);
  }
  if (!recording_ || audio_buffer_ == nullptr) {
    return 0;
  }
  while (remaining > 0) {
    size_t n = std::min<size_t>(remaining, kBytesPer10ms - rec_chunk_len_);
    std::memcpy(rec_chunk_ + rec_chunk_len_, src, n);
    src += n;
    rec_chunk_len_ += n;
    remaining -= static_cast<int32_t>(n);
    if (rec_chunk_len_ >= kBytesPer10ms) {
      audio_buffer_->SetRecordedBuffer(rec_chunk_, kSamplesPer10ms);
      audio_buffer_->SetVQEData(kPlayoutDelayMs, kRecordingDelayMs);
      audio_buffer_->DeliverRecordedData();
      rec_chunk_len_ = 0;
    }
  }
  return 0;
}

}  // namespace

webrtc::scoped_refptr<webrtc::AudioDeviceModule> CreateOHAudioDeviceModule(
    webrtc::TaskQueueFactory* taskQueueFactory) {
  // Wrap OHAudioDevice in the stock AudioDeviceModuleImpl via its inject ctor.
  // CreatePlatformSpecificObjects() early-returns for a provided device (it does
  // NOT overwrite it with a dummy), so we get the full ADM surface + the
  // AudioDeviceBuffer bridge to the media engine, driven by OH_Audio.
  auto adm = rtc::make_ref_counted<webrtc::AudioDeviceModuleImpl>(
      webrtc::AudioDeviceModule::kPlatformDefaultAudio,
      std::make_unique<OHAudioDevice>(), taskQueueFactory,
      /*create_detached=*/false);
  if (adm->CheckPlatform() == -1) {
    oh_log("CreateOHAudioDeviceModule: CheckPlatform failed");
    return nullptr;
  }
  if (adm->CreatePlatformSpecificObjects() == -1) {
    oh_log("CreateOHAudioDeviceModule: CreatePlatformSpecificObjects failed");
    return nullptr;
  }
  if (adm->AttachAudioBuffer() == -1) {
    oh_log("CreateOHAudioDeviceModule: AttachAudioBuffer failed");
    return nullptr;
  }
  oh_log("CreateOHAudioDeviceModule: OH_Audio ADM constructed");
  return adm;
}

void SetSpeakerOutput(bool speaker) {
  std::lock_guard<std::mutex> lock(g_route_mutex);
  g_speaker_output = speaker;
  ApplyRouteLocked();
}

}  // namespace tgcalls_ohos
