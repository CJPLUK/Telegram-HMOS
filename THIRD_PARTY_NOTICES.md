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

## Prebuilt binaries

The static libraries and headers in `entry/src/main/cpp/third_party/prebuilt/` can be rebuilt from source with `build_all.sh` in that directory; `build_env.txt` there records the exact source commits, build options and checksums.

| Component | Location | Licence | Licence text |
|---|---|---|---|
| [Cangjie stdx](https://gitcode.com/Cangjie/cangjie_stdx) | `entry/libs/stdx/`, `entry/libs/arm64-v8a/libstdx.*.so`, `entry/libs/arm64-v8a/libcangjie-*.so` | Apache-2.0 with Runtime Library Exception | `third_party_licenses/cangjie-stdx.LICENSE.txt` |
| [Huawei Secure C](https://gitee.com/openeuler/libboundscheck) | `entry/libs/arm64-v8a/libsecurec.so` | Mulan PSL v2 | `third_party_licenses/securec.LICENSE.txt` |
| [BoringSSL](https://boringssl.googlesource.com/boringssl) `libcrypto.a`, as vendored in Telegram for iOS | `entry/src/main/cpp/third_party/prebuilt/` | OpenSSL / ISC and others | `third_party_licenses/boringssl.LICENSE.txt` |
| [Opus](https://opus-codec.org) 1.5.1 `libopus.a` | `entry/src/main/cpp/third_party/prebuilt/` | BSD-3-Clause | `third_party_licenses/opus.COPYING.txt` |
| [libyuv](https://chromium.googlesource.com/libyuv/libyuv) `libyuv.a`, as vendored in Telegram for iOS | `entry/src/main/cpp/third_party/prebuilt/` | BSD-3-Clause and patent grant | `third_party_licenses/libyuv.LICENSE.txt`, `libyuv.PATENTS.txt` |
| [libvpx](https://chromium.googlesource.com/webm/libvpx) v1.13.0 `libvpx.a` | `entry/src/main/cpp/third_party/prebuilt/` | BSD-3-Clause and patent grant | `third_party_licenses/libvpx.LICENSE.txt`, `libvpx.PATENTS.txt` |
| `libtgcalls_ohos.so`: a HarmonyOS build of the Telegram call engine and its dependencies | `entry/libs/arm64-v8a/libtgcalls_ohos.so` | See the rows below | |
| ↳ [tgcalls](https://github.com/TelegramMessenger/tgcalls), built from commit [`e3069322`](https://github.com/TelegramMessenger/tgcalls/tree/e3069322a3d1e16ecb11a5e302242e59ddd7f09e) | | LGPL-3.0 | `third_party_licenses/LGPL-3.0.txt`, `third_party_licenses/GPL-3.0.txt` |
| ↳ [WebRTC](https://webrtc.googlesource.com/src), Telegram's fork, built from commit [`3817e906`](https://github.com/ali-fareed/webrtc/tree/3817e906cb6c22ec9cc62023b073e1a668d9cb33) | | BSD-3-Clause and patent grant | `third_party_licenses/webrtc.LICENSE.txt`, `webrtc.PATENTS.txt` |
| ↳ [BoringSSL](https://boringssl.googlesource.com/boringssl) | | OpenSSL / ISC and others | `third_party_licenses/boringssl.LICENSE.txt` |
| ↳ [Opus](https://opus-codec.org) | | BSD-3-Clause | `third_party_licenses/opus.COPYING.txt` |
| ↳ [libyuv](https://chromium.googlesource.com/libyuv/libyuv) | | BSD-3-Clause and patent grant | `third_party_licenses/libyuv.LICENSE.txt`, `libyuv.PATENTS.txt` |
| ↳ [libvpx](https://chromium.googlesource.com/webm/libvpx) | | BSD-3-Clause and patent grant | `third_party_licenses/libvpx.LICENSE.txt`, `libvpx.PATENTS.txt` |
| ↳ [libsrtp](https://github.com/cisco/libsrtp) | | BSD-3-Clause | `third_party_licenses/libsrtp.LICENSE.txt` |
| ↳ [usrsctp](https://github.com/sctplab/usrsctp) | | BSD-3-Clause | `third_party_licenses/usrsctp.LICENSE.txt` |

## Build-time dependencies (not distributed)

`@ohos/hypium` and `@ohos/hamock` (test frameworks) and `@cangjie/cjhybridcomponent` are fetched by ohpm at build time, and are covered by their own licences.
