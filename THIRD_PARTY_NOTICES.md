# Third-Party Notices

This project as a whole is licensed under the GNU General Public License, version 2 or (at your option) any later version. See [LICENSE](LICENSE).

It is based on, and contains material derived from, the following Telegram clients. Both are licensed under GNU GPL v2 or later:

- Telegram for iOS: https://github.com/TelegramMessenger/Telegram-iOS
- Telegram for Android: https://github.com/DrKLO/Telegram

This includes the animation assets (`.tgs`) and other resources under `entry/src/main/resources/`.

The components below are distributed with this repository under their own licences.

## Source code

| Component | Location | Licence | Licence text |
|---|---|---|---|
| [rlottie](https://github.com/Samsung/rlottie) | `entry/src/main/cpp/third_party/rlottie/` | LGPL-2.1, plus FreeType (FTL), pixman (MIT), stb (MIT/public domain) and RapidJSON (MIT) for the parts listed in its `COPYING` | `entry/src/main/cpp/third_party/rlottie/COPYING` and `licenses/` |
| [libwebm](https://chromium.googlesource.com/webm/libwebm) (mkvparser), from libvpx v1.13.0 | `entry/src/main/cpp/third_party/libwebm/` | BSD-3-Clause and patent grant | `entry/src/main/cpp/third_party/libwebm/LICENSE.TXT`, `PATENTS.TXT` |
| [tgcalls](https://github.com/TelegramMessenger/tgcalls) commit [`e3069322`](https://github.com/TelegramMessenger/tgcalls/tree/e3069322a3d1e16ecb11a5e302242e59ddd7f09e), with HarmonyOS changes | `entry/src/main/cpp/voip/tgcalls/` | LGPL-3.0 | `entry/src/main/cpp/voip/tgcalls/LICENSE`, `third_party_licenses/GPL-3.0.txt` |
| [WebRTC](https://webrtc.googlesource.com/src), Telegram's fork, commit [`3817e906`](https://github.com/ali-fareed/webrtc/tree/3817e906cb6c22ec9cc62023b073e1a668d9cb33), with HarmonyOS changes | `entry/src/main/cpp/voip/webrtc/` | BSD-3-Clause and patent grant | `entry/src/main/cpp/voip/webrtc/LICENSE`, `PATENTS` |
| [Abseil](https://github.com/abseil/abseil-cpp) commit `6bf3c73f` (git submodule) | `entry/src/main/cpp/voip/third_party/webrtc/absl/` | Apache-2.0 | `LICENSE` in that directory |
| [libsrtp](https://github.com/cisco/libsrtp) 2.2.0-pre, as vendored in Chromium | `entry/src/main/cpp/voip/third_party/webrtc/libsrtp/` | BSD-3-Clause | `entry/src/main/cpp/voip/third_party/webrtc/libsrtp/third_party/libsrtp/LICENSE` |
| [crc32c](https://github.com/google/crc32c) | `entry/src/main/cpp/voip/third_party/webrtc/crc32c/` | BSD-3-Clause | `third_party_licenses/crc32c.LICENSE.txt` |
| [PFFFT](https://bitbucket.org/jpommier/pffft) | `entry/src/main/cpp/voip/third_party/webrtc/pffft/` | BSD-like (FFTPACK) | header of `pffft.c` |
| [RNNoise](https://github.com/xiph/rnnoise) | `entry/src/main/cpp/voip/third_party/webrtc/rnnoise/`, `entry/src/main/cpp/voip/third_party/rnnoise/` | BSD-3-Clause | `entry/src/main/cpp/voip/third_party/webrtc/rnnoise/third_party/rnnoise/COPYING` |

The voice and video call engine (`libtgcalls_ohos.so`) is compiled from the sources under `entry/src/main/cpp/voip/` together with the app. tgcalls, WebRTC, libsrtp, crc32c, PFFFT and RNNoise are the copies Telegram for iOS uses (`third-party/` at commit `6ad963e5`); the HarmonyOS changes to tgcalls and WebRTC are recorded in this repository's git history, and `entry/src/main/cpp/voip/ohos/` is the HarmonyOS platform code.

## Prebuilt binaries

The static libraries and headers in `entry/src/main/cpp/third_party/prebuilt/` can be rebuilt from source with `build_all.sh` in that directory; `build_env.txt` there records the exact source commits, build options and checksums.

| Component | Location | Licence | Licence text |
|---|---|---|---|
| [Cangjie stdx](https://gitcode.com/Cangjie/cangjie_stdx) | `entry/libs/stdx/`, `entry/libs/arm64-v8a/libstdx.*.so`, `entry/libs/arm64-v8a/libcangjie-*.so` | Apache-2.0 with Runtime Library Exception | `third_party_licenses/cangjie-stdx.LICENSE.txt` |
| [Huawei Secure C](https://gitee.com/openeuler/libboundscheck) | `entry/libs/arm64-v8a/libsecurec.so` | Mulan PSL v2 | `third_party_licenses/securec.LICENSE.txt` |
| [BoringSSL](https://boringssl.googlesource.com/boringssl) `libcrypto.a`, `libssl.a`, as vendored in Telegram for iOS | `entry/src/main/cpp/third_party/prebuilt/` | OpenSSL / ISC and others | `third_party_licenses/boringssl.LICENSE.txt` |
| [Opus](https://opus-codec.org) 1.5.1 `libopus.a` | `entry/src/main/cpp/third_party/prebuilt/` | BSD-3-Clause | `third_party_licenses/opus.COPYING.txt` |
| [libyuv](https://chromium.googlesource.com/libyuv/libyuv) `libyuv.a`, as vendored in Telegram for iOS | `entry/src/main/cpp/third_party/prebuilt/` | BSD-3-Clause and patent grant | `third_party_licenses/libyuv.LICENSE.txt`, `libyuv.PATENTS.txt` |
| [libvpx](https://chromium.googlesource.com/webm/libvpx) v1.13.0 `libvpx.a` | `entry/src/main/cpp/third_party/prebuilt/` | BSD-3-Clause and patent grant | `third_party_licenses/libvpx.LICENSE.txt`, `libvpx.PATENTS.txt` |

## Build-time dependencies (not distributed)

`@ohos/hypium` and `@ohos/hamock` (test frameworks) and `@cangjie/cjhybridcomponent` are fetched by ohpm at build time, and are covered by their own licences.
