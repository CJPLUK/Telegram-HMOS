# Voice and video call engine: builds libtgcalls_ohos.so from source, like Telegram for Android
# builds jni/voip (tgcalls + Telegram's WebRTC fork compiled together with the app). arm64-v8a only.
#
#   tgcalls/                 TelegramMessenger/tgcalls@e3069322, the files we compile, with HarmonyOS changes
#   webrtc/                  ali-fareed/webrtc@3817e906 (Telegram's WebRTC fork), the files we compile
#   ohos/                    HarmonyOS platform code: audio device, camera/screen capture, H.264, C API
#   third_party/             crc32c, pffft, rnnoise, libsrtp from Telegram-iOS third-party/ (same layout),
#                            abseil-cpp as a git submodule
#   webrtc_sources.cmake     WebRTC translation units (from the Telegram-iOS Bazel BUILD)
#   generated/               generated headers (WebRTC registered field trials)
# opus, libyuv, libvpx and BoringSSL come from ../third_party/prebuilt.
#
# The compile flags and the source lists are carried over from the standalone build script that
# produced the previously shipped prebuilt libtgcalls_ohos.so; the result has the same machine code.

set(VOIP_ROOT ${CMAKE_CURRENT_SOURCE_DIR})
set(TGCALLS_SRC ${VOIP_ROOT}/tgcalls)
set(WEBRTC_SRC ${VOIP_ROOT}/webrtc)
set(SHIM_DIR ${VOIP_ROOT}/ohos)
set(TP_ROOT ${VOIP_ROOT}/third_party)
set(PREBUILT_ROOT ${VOIP_ROOT}/../third_party/prebuilt)
set(PREBUILT_LIB ${PREBUILT_ROOT}/arm64-v8a/lib)
set(DEPS_INCLUDE ${PREBUILT_ROOT}/include)   # openssl/, opus/, vpx/, libyuv.h + libyuv/
set(GEN_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)

if(NOT EXISTS ${TP_ROOT}/webrtc/absl/CMakeLists.txt)
  message(FATAL_ERROR "abseil is missing at ${TP_ROOT}/webrtc/absl. "
                      "Run: git submodule update --init --recursive")
endif()

# The call engine is always built optimized, also in debug HAPs (DevEco Studio configures the
# native build as Debug: -O0, no NDEBUG, which enables WebRTC's DCHECKs and makes calls unusable).
set(CMAKE_C_FLAGS_DEBUG "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_RELEASE}")
set(CMAKE_ASM_FLAGS_DEBUG "${CMAKE_ASM_FLAGS_RELEASE}")
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
# Keep local checkout paths out of __FILE__ strings.
get_filename_component(VOIP_CPP_ROOT ${VOIP_ROOT}/.. ABSOLUTE)
add_compile_options(-ffile-prefix-map=${VOIP_CPP_ROOT}=.)
# Do not inherit the app's include directories (entry/src/main/cpp).
set_directory_properties(PROPERTIES INCLUDE_DIRECTORIES "")

# Generated headers: WebRTC's registered field trials (committed, from webrtc/experiments/field_trials.py)
# and the include layouts WebRTC expects for opus and libyuv, taken from the prebuilt headers.
file(COPY ${VOIP_ROOT}/generated/field_trials_header DESTINATION ${GEN_DIR})
file(GLOB _opus_headers ${DEPS_INCLUDE}/opus/*.h)
file(COPY ${_opus_headers} DESTINATION ${GEN_DIR}/opus_headers/third_party/opus/src/include)
file(COPY ${DEPS_INCLUDE}/libyuv ${DEPS_INCLUDE}/libyuv.h
     DESTINATION ${GEN_DIR}/libyuv_headers/third_party/libyuv/include)
set(LIBYUV_INCLUDE_ROOT ${GEN_DIR}/libyuv_headers)

# ---- abseil (submodule); every library is linked, like the merged libabsl.a before ----------------
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(ABSL_PROPAGATE_CXX_STD ON)
set(ABSL_BUILD_TESTING OFF)
set(ABSL_ENABLE_INSTALL OFF)
add_subdirectory(${TP_ROOT}/webrtc/absl ${CMAKE_CURRENT_BINARY_DIR}/absl EXCLUDE_FROM_ALL)
function(voip_collect_static_targets dir out)
  set(_result)   # functions inherit the caller's variables: start empty, or each level re-appends its parent's list
  get_property(_targets DIRECTORY ${dir} PROPERTY BUILDSYSTEM_TARGETS)
  foreach(t ${_targets})
    get_target_property(_type ${t} TYPE)
    if(_type STREQUAL "STATIC_LIBRARY")
      list(APPEND _result ${t})
    endif()
  endforeach()
  get_property(_subdirs DIRECTORY ${dir} PROPERTY SUBDIRECTORIES)
  foreach(d ${_subdirs})
    voip_collect_static_targets(${d} _sub)
    list(APPEND _result ${_sub})
  endforeach()
  set(${out} ${_result} PARENT_SCOPE)
endfunction()
voip_collect_static_targets(${TP_ROOT}/webrtc/absl VOIP_ABSL_TARGETS)
list(SORT VOIP_ABSL_TARGETS)
set(VOIP_ABSL_ARCHIVES)
foreach(t ${VOIP_ABSL_TARGETS})
  list(APPEND VOIP_ABSL_ARCHIVES "$<TARGET_FILE:${t}>")
endforeach()

# ---- libsrtp ----------------------------------------------------------------------------------------
set(BORINGSSL_INCLUDE ${DEPS_INCLUDE})
add_subdirectory(${TP_ROOT}/webrtc/libsrtp/third_party/libsrtp ${CMAKE_CURRENT_BINARY_DIR}/libsrtp EXCLUDE_FROM_ALL)

# ---- WebRTC (static, linked into libtgcalls_ohos.so) -----------------------------------------------
# Flag set = Telegram Bazel copts + platform/linux/arm64 flags, minus video codec enables.
include(${VOIP_ROOT}/webrtc_sources.cmake)

# Support libraries compiled into the same archive (Bazel builds them as
# separate cc_library deps; static-archive result is equivalent):
set(SUPPORT_SOURCES
  # crc32c (dcsctp packet checksums). Portable only: vendored crc32c_config.h
  # comments out HAVE_ARM64_CRC32C, matching the Bazel linux/default branch.
  "${TP_ROOT}/webrtc/crc32c/third_party/crc32c/src/crc32c.cc"
  "${TP_ROOT}/webrtc/crc32c/third_party/crc32c/src/crc32c_portable.cc"
  # pffft (audio_processing utility fft wrapper)
  "${TP_ROOT}/webrtc/pffft/third_party/pffft/src/pffft.c"
  "${TP_ROOT}/webrtc/pffft/third_party/pffft/src/fftpack.c"
  # rnnoise (agc2 vad rnn weights)
  "${TP_ROOT}/webrtc/rnnoise/third_party/rnnoise/src/rnn_vad_weights.cc"
)

add_library(webrtc_audio STATIC ${WEBRTC_AUDIO_SOURCES} ${SUPPORT_SOURCES})
set_target_properties(webrtc_audio PROPERTIES C_STANDARD 11)

target_include_directories(webrtc_audio PRIVATE
  "${WEBRTC_SRC}"
  "${GEN_DIR}/field_trials_header"
  "${GEN_DIR}/opus_headers"
  "${DEPS_INCLUDE}"                    # openssl/...
  "${LIBYUV_INCLUDE_ROOT}"             # third_party/libyuv/include/...
  "${TP_ROOT}/webrtc/libsrtp"          # third_party/libsrtp/...
  "${TP_ROOT}/webrtc/libsrtp_config"   # config.h for libsrtp headers
  "${TP_ROOT}/webrtc/libsrtp/third_party/libsrtp/include"
  "${TP_ROOT}/webrtc/libsrtp/third_party/libsrtp/crypto/include"
  "${TP_ROOT}/webrtc/crc32c"           # third_party/crc32c/...
  "${TP_ROOT}/webrtc/pffft"            # third_party/pffft/...
  "${TP_ROOT}/webrtc/rnnoise"          # third_party/rnnoise/...
  "${TP_ROOT}/webrtc/absl"             # absl/...
  "${TP_ROOT}/webrtc/crc32c/third_party/crc32c/src/include"
)

# Flag set = Bazel copts + platform_shared_flags + linux_specific_flags +
# arm64_specific_flags, MINUS video codec enables (RTC_ENABLE_VP9,
# RTC_ENABLE_H265, WEBRTC_USE_H264, WEBRTC_USE_H264_DECODER) and AVX2 (x86).
target_compile_definitions(webrtc_audio PRIVATE
  # copts block
  BSD=1
  HAVE_PTHREAD
  WEBRTC_APM_DEBUG_DUMP=0
  WEBRTC_USE_BUILTIN_ISAC_FLOAT
  WEBRTC_OPUS_VARIABLE_COMPLEXITY=0
  HAVE_NETINET_IN_H
  SCTP_SIMPLE_ALLOCATOR
  SCTP_PROCESS_LEVEL_LOCKS
  __Userspace__
  PACKAGE_VERSION=""
  HAVE_SCTP
  WEBRTC_HAVE_DCSCTP
  WEBRTC_HAVE_SCTP
  NO_MAIN_THREAD_WRAPPING
  RTC_DISABLE_TRACE_EVENTS
  RTC_DISABLE_METRICS
  # platform_shared_flags (video codec defines dropped for V1)
  WEBRTC_POSIX
  HAVE_WEBRTC_VIDEO
  WEBRTC_NS_FLOAT
  BWE_TEST_LOGGING_COMPILE_TIME_ENABLE=0
  ABSL_ALLOCATOR_NOTHROW=1
  DYNAMIC_ANNOTATIONS_ENABLED=0
  WEBRTC_ENABLE_PROTOBUF=0
  WEBRTC_NON_STATIC_TRACE_EVENT_HANDLERS=0
  WEBRTC_OPUS_USE_CODEC_PLC
  WEBRTC_OPUS_SUPPORT_DRED
  # linux_specific_flags
  WEBRTC_LINUX
  __Userspace_os_Linux
  # arm64_specific_flags
  WEBRTC_ARCH_ARM64
  WEBRTC_HAS_NEON
  LIBYUV_NEON
)

target_compile_options(webrtc_audio PRIVATE -w -include stdint.h)

# ---- tgcalls + HarmonyOS platform code -> libtgcalls_ohos.so ---------------------------------------
set(TGCALLS_SOURCES
  # root: shared support for the v2 path
  "${TGCALLS_SRC}/Instance.cpp"
  "${TGCALLS_SRC}/AudioDeviceHelper.cpp"
  "${TGCALLS_SRC}/ChannelManager.cpp"
  "${TGCALLS_SRC}/CodecSelectHelper.cpp"
  "${TGCALLS_SRC}/CryptoHelper.cpp"
  "${TGCALLS_SRC}/EncryptedConnection.cpp"
  "${TGCALLS_SRC}/FakeAudioDeviceModule.cpp"
  "${TGCALLS_SRC}/FakeVideoTrackSource.cpp"
  "${TGCALLS_SRC}/FieldTrialsConfig.cpp"
  "${TGCALLS_SRC}/LogSinkImpl.cpp"
  "${TGCALLS_SRC}/Message.cpp"
  "${TGCALLS_SRC}/SctpDataChannelProviderInterfaceImpl.cpp"
  "${TGCALLS_SRC}/StaticThreads.cpp"
  "${TGCALLS_SRC}/ThreadLocalObject.cpp"
  "${TGCALLS_SRC}/TurnCustomizerImpl.cpp"
  "${TGCALLS_SRC}/VideoCaptureInterface.cpp"
  "${TGCALLS_SRC}/VideoCaptureInterfaceImpl.cpp"
  # v2: the 12.0.0 protocol stack
  "${TGCALLS_SRC}/v2/ContentNegotiation.cpp"
  "${TGCALLS_SRC}/v2/CustomDcSctpSocket.cpp"
  "${TGCALLS_SRC}/v2/DirectNetworkingImpl.cpp"
  "${TGCALLS_SRC}/v2/ExternalSignalingConnection.cpp"
  "${TGCALLS_SRC}/v2/InstanceV2Impl.cpp"
  "${TGCALLS_SRC}/v2/NativeNetworkingImpl.cpp"
  "${TGCALLS_SRC}/v2/RawTcpSocket.cpp"
  "${TGCALLS_SRC}/v2/ReflectorPort.cpp"
  "${TGCALLS_SRC}/v2/ReflectorRelayPortFactory.cpp"
  "${TGCALLS_SRC}/v2/Signaling.cpp"
  "${TGCALLS_SRC}/v2/SignalingConnection.cpp"
  "${TGCALLS_SRC}/v2/SignalingEncryption.cpp"
  "${TGCALLS_SRC}/v2/SignalingSctpConnection.cpp"
  # group: GroupInstanceCustomImpl (rtc mode). Broadcast decoders are stubbed,
  # see patches/tgcalls/group/StreamingMediaContextStub.cpp.
  "${TGCALLS_SRC}/group/GroupInstanceCustomImpl.cpp"
  "${TGCALLS_SRC}/group/GroupNetworkManager.cpp"
  "${TGCALLS_SRC}/group/GroupJoinPayloadInternal.cpp"
  "${TGCALLS_SRC}/group/StreamingMediaContextStub.cpp"
  # platform: fake (patched to null video codec factories, see FakeInterface.cpp)
  "${TGCALLS_SRC}/platform/fake/FakeInterface.cpp"
  # vendored support
  "${TGCALLS_SRC}/third-party/json11.cpp"
  "${TGCALLS_SRC}/utils/gzip.cpp"
)

# Extra webrtc TU not in the step-3 Bazel list: AudioDeviceModule::Create().
# Compiled with WEBRTC_DUMMY_AUDIO_BUILD so every audio layer resolves to the
# in-tree AudioDeviceDummy (no ALSA/Pulse classes referenced). All of its
# deps (audio_device_buffer/generic/dummy/fine_audio_buffer) are already in
# libwebrtc_audio.a.
set(EXTRA_WEBRTC_SOURCES "${WEBRTC_SRC}/modules/audio_device/audio_device_impl.cc")
set_source_files_properties("${WEBRTC_SRC}/modules/audio_device/audio_device_impl.cc"
  PROPERTIES COMPILE_DEFINITIONS "WEBRTC_DUMMY_AUDIO_BUILD;WEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE")

# 5c: the 4 codec TUs excluded from libwebrtc_audio.a (gen_sources.py
# VIDEO_CODEC_EXCLUDES). Everything else in the video pipeline (webrtc video
# engine, Internal{En,De}coderFactory, simulcast, generic codec infra) is
# ALREADY inside libwebrtc_audio.a — those .o were simply never pulled while
# nothing referenced VP8Encoder/VP8Decoder. vp9.cc is compiled WITHOUT
# RTC_ENABLE_VP9 (matching every other TU's define set — header-ABI rule), so
# it contributes empty-stub VP9 symbols and no libvpx_vp9 dependency: the
# factories advertise VP8 only. H264 TUs stay excluded (need openh264/ffmpeg).
list(APPEND EXTRA_WEBRTC_SOURCES
  "${WEBRTC_SRC}/modules/video_coding/codecs/interface/libvpx_interface.cc"
  "${WEBRTC_SRC}/modules/video_coding/codecs/vp8/libvpx_vp8_encoder.cc"
  "${WEBRTC_SRC}/modules/video_coding/codecs/vp8/libvpx_vp8_decoder.cc"
  "${WEBRTC_SRC}/modules/video_coding/codecs/vp9/vp9.cc"
)

# C shim + step-5b OH_Audio ADM (OH_AudioCapturer/OH_AudioRenderer) + step-5c
# OHOS camera capturer (ohcamera + OH_ImageReceiverNative). #include
# "ohos_audio_device.h" / "ohos_video_capturer.h" resolve relative to the shim
# source dir (also added to include dirs for FakeInterface.cpp), NDK system
# headers from the sysroot.
set(SHIM_SOURCES
  "${SHIM_DIR}/tgcalls_c_shim.cpp"
  "${SHIM_DIR}/tgcalls_group_c_shim.cpp"
  "${SHIM_DIR}/ohos_surface_sink.cpp"
  "${SHIM_DIR}/ohos_audio_device.cpp"
  "${SHIM_DIR}/ohos_video_capturer.cpp"
  "${SHIM_DIR}/ohos_screen_capturer.cpp"
  "${SHIM_DIR}/ohos_h264_encoder.cpp"
  "${SHIM_DIR}/ohos_h264_decoder.cpp"
  "${SHIM_DIR}/ohos_h264_factory.cpp"
)

# rnnoise (group engine noise suppression / VAD). Standalone Telegram copy.
set(RNNOISE_DIR "${TP_ROOT}/rnnoise")
set(RNNOISE_SOURCES
  "${RNNOISE_DIR}/Sources/celt_lpc.c"
  "${RNNOISE_DIR}/Sources/denoise.c"
  "${RNNOISE_DIR}/Sources/kiss_fft.c"
  "${RNNOISE_DIR}/Sources/pitch.c"
  "${RNNOISE_DIR}/Sources/rnn.c"
  "${RNNOISE_DIR}/Sources/rnn_data.c"
  "${RNNOISE_DIR}/Sources/rnn_reader.c"
)
# rnnoise embeds its own copy of a few CELT helpers whose names collide with
# libopus.a (ld.lld: duplicate symbol). Rename rnnoise's copies at compile time;
# all definitions and uses live inside these 7 TUs, so the rename is closed.
set_source_files_properties(${RNNOISE_SOURCES} PROPERTIES COMPILE_DEFINITIONS
  "remove_doubling=rnn_remove_doubling;pitch_search=rnn_pitch_search;pitch_downsample=rnn_pitch_downsample;opus_ifft_c=rnn_opus_ifft_c;opus_fft_impl=rnn_opus_fft_impl;opus_fft_c=rnn_opus_fft_c;opus_fft_alloc=rnn_opus_fft_alloc;opus_fft_alloc_twiddles=rnn_opus_fft_alloc_twiddles;opus_fft_free=rnn_opus_fft_free;celt_iir=rnn_celt_iir;celt_fir=rnn_celt_fir;_celt_lpc=rnn_celt_lpc;_celt_autocorr=rnn_celt_autocorr;celt_pitch_xcorr=rnn_celt_pitch_xcorr")

add_library(tgcalls_ohos SHARED ${TGCALLS_SOURCES} ${EXTRA_WEBRTC_SOURCES} ${SHIM_SOURCES} ${RNNOISE_SOURCES})

target_include_directories(tgcalls_ohos PRIVATE
  "${TGCALLS_SRC}"                     # Instance.h, v2/..., third-party/json11.hpp
  "${TGCALLS_SRC}/group"               # GroupInstanceCustomImpl.cpp uses bare "GroupNetworkManager.h"
  "${RNNOISE_DIR}/PublicHeaders"       # rnnoise.h
  "${SHIM_DIR}"                        # ohos_video_capturer.h for FakeInterface.cpp
  "${WEBRTC_SRC}"
  "${GEN_DIR}/field_trials_header"
  "${GEN_DIR}/opus_headers"
  "${DEPS_INCLUDE}"                    # openssl/..., libyuv.h + libyuv/...
  "${LIBYUV_INCLUDE_ROOT}"             # third_party/libyuv/include/...
  "${TP_ROOT}/webrtc/libsrtp"
  "${TP_ROOT}/webrtc/libsrtp_config"
  "${TP_ROOT}/webrtc/libsrtp/third_party/libsrtp/include"
  "${TP_ROOT}/webrtc/libsrtp/third_party/libsrtp/crypto/include"
  "${TP_ROOT}/webrtc/crc32c"
  "${TP_ROOT}/webrtc/pffft"
  "${TP_ROOT}/webrtc/rnnoise"
  "${TP_ROOT}/webrtc/absl"
  "${TP_ROOT}/webrtc/crc32c/third_party/crc32c/src/include"
)

# Define set: verbatim copy of patches/webrtc/CMakeLists.txt (header ABI).
target_compile_definitions(tgcalls_ohos PRIVATE
  BSD=1
  HAVE_PTHREAD
  WEBRTC_APM_DEBUG_DUMP=0
  WEBRTC_USE_BUILTIN_ISAC_FLOAT
  WEBRTC_OPUS_VARIABLE_COMPLEXITY=0
  HAVE_NETINET_IN_H
  SCTP_SIMPLE_ALLOCATOR
  SCTP_PROCESS_LEVEL_LOCKS
  __Userspace__
  PACKAGE_VERSION=""
  HAVE_SCTP
  WEBRTC_HAVE_DCSCTP
  WEBRTC_HAVE_SCTP
  NO_MAIN_THREAD_WRAPPING
  RTC_DISABLE_TRACE_EVENTS
  RTC_DISABLE_METRICS
  WEBRTC_POSIX
  HAVE_WEBRTC_VIDEO
  WEBRTC_NS_FLOAT
  BWE_TEST_LOGGING_COMPILE_TIME_ENABLE=0
  ABSL_ALLOCATOR_NOTHROW=1
  DYNAMIC_ANNOTATIONS_ENABLED=0
  WEBRTC_ENABLE_PROTOBUF=0
  WEBRTC_NON_STATIC_TRACE_EVENT_HANDLERS=0
  WEBRTC_OPUS_USE_CODEC_PLC
  WEBRTC_OPUS_SUPPORT_DRED
  WEBRTC_LINUX
  __Userspace_os_Linux
  WEBRTC_ARCH_ARM64
  WEBRTC_HAS_NEON
  LIBYUV_NEON
)

target_compile_options(tgcalls_ohos PRIVATE -w -include stdint.h -fvisibility=hidden)

# Static-link the skeleton archives (8 + libvpx since 5c). --start/end-group tolerates the
# webrtc<->absl<->boringssl cross-references regardless of order; the
# canonical order from toolchain说明.md is kept for readability.
# usrsctp is intentionally not linked (webrtc uses dcsctp; no consumer).
target_link_options(tgcalls_ohos PRIVATE
  "-static-libstdc++"   # libc++ linked statically, as before (OHOS_STL=c++_static)
  "-Wl,--no-undefined"
  "-Wl,--version-script=${VOIP_ROOT}/exports.map"
  "-Wl,--exclude-libs,ALL"
  "-Wl,--start-group"
  "$<TARGET_FILE:webrtc_audio>"
  ${VOIP_ABSL_ARCHIVES}
  "${PREBUILT_LIB}/libopus.a"
  "$<TARGET_FILE:srtp2>"
  "${PREBUILT_LIB}/libyuv.a"
  "${PREBUILT_LIB}/libvpx.a"
  "${PREBUILT_LIB}/libssl.a"
  "${PREBUILT_LIB}/libcrypto.a"
  "-Wl,--end-group"
)
add_dependencies(tgcalls_ohos webrtc_audio srtp2 ${VOIP_ABSL_TARGETS})
# OHOS system libraries, resolved from the NDK sysroot; every entry is on the
# NEEDED whitelist in build.sh (tgcalls_needed_gate):
#   ohaudio                      step-5b ADM (OH_AudioCapturer/OH_AudioRenderer)
#   ohcamera                     step-5c camera (manager/input/session/preview)
#   image_receiver/ohimage       step-5c preview frame access (OH_ImageReceiverNative/OH_ImageNative)
#   native_buffer                step-5c plane mapping (OH_NativeBuffer_Map)
#   hilog_ndk.z                  on-device diagnostics (OH_LOG_Print)
#   native_media_venc/vdec       HW H264 encode/decode (OH_VideoEncoder/Decoder)
#   native_media_codecbase       codec capability + async callbacks (OH_AVCapability)
#   native_media_core            OH_AVFormat / OH_AVBuffer
target_link_libraries(tgcalls_ohos PRIVATE z pthread m dl ohaudio
  ohcamera image_receiver ohimage native_buffer hilog_ndk.z
  native_media_venc native_media_vdec native_media_codecbase native_media_core
  native_window native_avscreen_capture)
