# the minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)
project(Telegram_Cangjie)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

# Prebuilt arm64-v8a static libs (libopus / libyuv / libcrypto / libvpx) and their headers are
# vendored under third_party/prebuilt, and the libwebm parser source under third_party/libwebm, so
# a fresh clone builds with full functionality (voice-message Opus/OGG encoding, round-video
# transcoding, WebM video stickers) without running tgcalls_ohos/build.sh first. If the vendored
# copy is absent, fall back to a locally built ../tgcalls_ohos/out tree.
# To rebuild the prebuilt libs from source, run third_party/prebuilt/build_all.sh (pinned sources and
# toolchain in third_party/prebuilt/build_env.txt).
set(TGCALLS_OHOS_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../tgcalls_ohos)
set(TG_PREBUILT_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/third_party/prebuilt)
if(EXISTS ${TG_PREBUILT_ROOT}/arm64-v8a/lib/libopus.a)
    set(TG_NATIVE_LIB_DIR ${TG_PREBUILT_ROOT}/arm64-v8a/lib)
    set(TG_NATIVE_INCLUDE_DIR ${TG_PREBUILT_ROOT}/include)
else()
    set(TG_NATIVE_LIB_DIR ${TGCALLS_OHOS_ROOT}/out/lib)
    set(TG_NATIVE_INCLUDE_DIR ${TGCALLS_OHOS_ROOT}/out/include)
endif()
if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/third_party/libwebm/mkvparser/mkvparser.cc)
    set(LIBWEBM_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/third_party/libwebm)
    set(TG_LIBVPX_SRC_INCLUDE_DIR "")
else()
    set(LIBWEBM_ROOT ${TGCALLS_OHOS_ROOT}/src/libvpx/third_party/libwebm)
    set(TG_LIBVPX_SRC_INCLUDE_DIR ${TGCALLS_OHOS_ROOT}/src/libvpx)
endif()
set(TG_VIDEO_STICKER_LIBVPX ${TG_NATIVE_LIB_DIR}/libvpx.a)
set(TG_VIDEO_STICKER_MKVPARSER ${LIBWEBM_ROOT}/mkvparser/mkvparser.cc)

set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build rlottie as part of entry" FORCE)
set(LOTTIE_MODULE OFF CACHE BOOL "Disable external image modules" FORCE)
set(LOTTIE_THREAD ON CACHE BOOL "Use rlottie's per-thread raster workers" FORCE)
set(LOTTIE_CACHE ON CACHE BOOL "Cache parsed animations" FORCE)
set(LOTTIE_TEST OFF CACHE BOOL "Disable rlottie tests" FORCE)
add_subdirectory(third_party/rlottie EXCLUDE_FROM_ALL)

# The native thread pool owns one FreeType outline/stroker per worker. Keep the
# fallback safe as well in case this target is configured without its pool.
# Independent visible nodes may render concurrently; each Animation instance
# is still serialized by its StreamingLottiePlayer owner.
target_compile_definitions(rlottie PRIVATE LOTTIE_THREAD_SAFE)

# The debug HAP compiles native sources with -O0, which puts rlottie's scanline
# rasterizer several times over its per-frame budget: a 384px TGS frame then
# takes longer than the 33ms the player schedules it in, and playback degrades
# to render speed. The rasterizer must stay optimized in every variant.
target_compile_options(rlottie PRIVATE -O3)

set(ENTRY_SOURCES
    napi_init.cpp
    telegram_lottie_bridge.cpp
    emoji_grid_compositor.cpp)

if(CMAKE_OHOS_ARCH_ABI STREQUAL "arm64-v8a"
   AND EXISTS ${TG_VIDEO_STICKER_LIBVPX}
   AND EXISTS ${TG_VIDEO_STICKER_MKVPARSER})
    set(TG_VIDEO_STICKER_NATIVE ON)
    list(APPEND ENTRY_SOURCES
        telegram_video_sticker_bridge.cpp
        ${TG_VIDEO_STICKER_MKVPARSER})
else()
    set(TG_VIDEO_STICKER_NATIVE OFF)
    list(APPEND ENTRY_SOURCES telegram_video_sticker_stub.cpp)
endif()

add_library(entry SHARED ${ENTRY_SOURCES})
target_link_libraries(entry PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libace_ndk.z.so
    libnative_window.so
    rlottie
    z)

# 合成器渲染循环与光栅化同帧预算，保持 O3。
set_source_files_properties(emoji_grid_compositor.cpp
    PROPERTIES COMPILE_OPTIONS "-O3")

# gzip inflate + the per-frame surface handoff sit on the same frame budget as
# the rasterizer, so they follow the same -O0 exemption.
set_source_files_properties(telegram_lottie_bridge.cpp
    PROPERTIES COMPILE_OPTIONS "-O3")

if(TG_VIDEO_STICKER_NATIVE)
    # The app's debug HAP normally compiles native sources with -O0. A 384px
    # video sticker needs to decode and convert a frame inside a 33ms budget,
    # so keep this hot path optimized in debug builds as well.
    set_source_files_properties(telegram_video_sticker_bridge.cpp
        PROPERTIES COMPILE_OPTIONS "-O3")
    target_include_directories(entry PRIVATE
        ${TG_NATIVE_INCLUDE_DIR}
        ${TG_LIBVPX_SRC_INCLUDE_DIR}
        ${LIBWEBM_ROOT})
    target_link_libraries(entry PUBLIC ${TG_VIDEO_STICKER_LIBVPX})
endif()

# 帧通道独立 napi 模块（'entry' 模块名被仓颉混合框架抢注，另立门户）。
add_library(emoji_frames SHARED
    emoji_frames_napi.cpp
    emoji_frames_init.cpp)
target_link_libraries(emoji_frames PUBLIC libace_napi.z.so)
set_source_files_properties(emoji_frames_napi.cpp
    PROPERTIES COMPILE_OPTIONS "-O3")

# 媒体模块 tg_media：语音 Opus/OGG 编码 + 圆形视频方形转码
#（libopus / libyuv 用 third_party/prebuilt 里的预编译 arm64 静态库，缺失时退回 tgcalls_ohos/out；
#  系统 AVCodec/AVMuxer/AVDemuxer 走 NDK）。
set(TG_OPUS_LIB ${TG_NATIVE_LIB_DIR}/libopus.a)
set(TG_YUV_LIB ${TG_NATIVE_LIB_DIR}/libyuv.a)
if(CMAKE_OHOS_ARCH_ABI STREQUAL "arm64-v8a" AND EXISTS ${TG_OPUS_LIB} AND EXISTS ${TG_YUV_LIB})
    set(TG_CRYPTO_LIB ${TG_NATIVE_LIB_DIR}/libcrypto.a)
    add_library(tg_media SHARED tg_media_init.cpp opus_ogg_encoder.cpp round_video_transcoder.cpp tg_crypto.cpp)
    target_include_directories(tg_media PRIVATE
        ${TG_NATIVE_INCLUDE_DIR}
        ${TG_NATIVE_INCLUDE_DIR}/opus)
    target_link_libraries(tg_media PUBLIC
        libace_napi.z.so libhilog_ndk.z.so
        libnative_media_core.so libnative_media_codecbase.so
        libnative_media_avsource.so libnative_media_avdemuxer.so libnative_media_avmuxer.so
        libnative_media_vdec.so libnative_media_venc.so
        ${TG_OPUS_LIB} ${TG_YUV_LIB} ${TG_CRYPTO_LIB})
    set_source_files_properties(opus_ogg_encoder.cpp round_video_transcoder.cpp tg_crypto.cpp PROPERTIES COMPILE_OPTIONS "-O3")
else()
    add_library(tg_media SHARED tg_media_init.cpp tg_media_stub.cpp)
    target_link_libraries(tg_media PUBLIC libace_napi.z.so libhilog_ndk.z.so)
endif()

# 通话引擎 libtgcalls_ohos.so：tgcalls + Telegram 的 WebRTC 随应用从源码编译（同 Telegram Android 的 jni/voip），
# 只有 arm64-v8a（依赖的预编译静态库只有 arm64）。说明见 voip/CMakeLists.txt。
if(CMAKE_OHOS_ARCH_ABI STREQUAL "arm64-v8a")
    add_subdirectory(voip)
endif()
