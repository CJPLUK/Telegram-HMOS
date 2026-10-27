## Telegram for HarmonyOS

[English](README.md) | [简体中文](README.zh-CN.md)

[Telegram](https://telegram.org) is a messaging app with a focus on speed and security. It’s superfast, simple and free.
This repo contains the source code of an **unofficial** Telegram client for HarmonyOS, a native HarmonyOS app with a small C++ layer.

The client talks to Telegram servers directly over MTProto, and its UI and behaviour follow [Telegram for iOS](https://github.com/TelegramMessenger/Telegram-iOS). It is not affiliated with, endorsed by or maintained by Telegram FZ-LLC.

## Creating your Telegram Application

Telegram welcomes all developers to use its API and source code to create applications on its platform.
There are several things Telegram requires from **all developers** for the moment.

1. [**Obtain your own api_id**](https://core.telegram.org/api/obtaining_api_id) for your application.
2. Please **do not** use the name Telegram for your app — or make sure your users understand that it is unofficial.
3. Kindly **do not** use Telegram's standard logo (white paper plane in a blue circle) as your app's logo.
4. Please study Telegram's [**security guidelines**](https://core.telegram.org/mtproto/security_guidelines) and take good care of your users' data and privacy.
5. Please remember to publish **your** code too in order to comply with the licences.

### API, Protocol documentation

Telegram API manuals: https://core.telegram.org/api

MTproto protocol manuals: https://core.telegram.org/mtproto

The client currently implements API layer 214 (`MTProtoConfig.LAYER`).

### Compilation Guide

**Note**: This repo ships **no** API credentials and **no** signing configuration. Before building, you must fill in your own `api_id` / `api_hash` and set up signing as described below.

You will require:

- [DevEco Studio](https://developer.huawei.com/consumer/en/deveco-studio/) 6.1 or newer, with the Cangjie plugin installed
- HarmonyOS SDK 6.0.2 (API 22)
- An arm64 HarmonyOS device

1. Clone the source code:
   ```bash
   git clone --recursive https://github.com/CJPLUK/Telegram-HMOS.git
   ```
   `--recursive` fetches the Abseil submodule the call engine needs. If you already cloned without it, run `git submodule update --init --recursive`.
2. Open the project directory in DevEco Studio (open it, do NOT import it) and let it sync.
3. Fill in `PROD_API_ID` and `PROD_API_HASH` in `entry/src/main/cangjie/core/mtproto/MTProtoConfig.cj` with the values you got from https://my.telegram.org/apps. Fill in `TEST_API_ID` / `TEST_API_HASH` too if you plan to use Telegram's test data centers.
4. Configure signing: **File › Project Structure › Signing Configs**, then sign in and choose *Automatically generate signature* (or point it to your own certificate). DevEco Studio writes the signing configuration into `build-profile.json5`; **do not commit it**, it contains your certificate paths and key passwords.
5. Choose the `entry` module and press **Run**.

### Native libraries

The C/C++ part of the app lives in `entry/src/main/cpp/` and uses these third-party libraries:

| Library | Used for | Shipped as |
|---|---|---|
| opus 1.5.1 | Voice message encoding | Prebuilt static library |
| libyuv | Round video message transcoding | Prebuilt static library |
| libvpx 1.13.0 | WebM video sticker decoding | Prebuilt static library |
| BoringSSL (libcrypto, libssl) | MTProto and call encryption | Prebuilt static library |
| libwebm (mkvparser) | WebM container parsing | Source |
| rlottie | Animated stickers and emoji | Source |
| tgcalls, WebRTC, Abseil, libsrtp, crc32c, PFFFT, RNNoise | Voice and video call engine `libtgcalls_ohos.so` | Source |

opus, libyuv, libvpx and BoringSSL are also used by the call engine (audio coding, video format conversion, VP8/VP9, DTLS/SRTP).

**Libraries shipped as source** are compiled by CMake together with the app when DevEco Studio builds it (entry point: `entry/src/main/cpp/CMakeLists.txt`); nothing extra is needed. The call engine is built by `entry/src/main/cpp/voip/CMakeLists.txt`, and its HarmonyOS platform code (audio, camera and screen capture, hardware H.264) is in `voip/ohos/`. The call engine is built with optimizations also in debug builds, so the first build takes a few minutes longer. Abseil is a git submodule, hence `--recursive` when cloning.

**Prebuilt static libraries** and their headers are in `entry/src/main/cpp/third_party/prebuilt/` and are linked as they are. To rebuild them from source:

```bash
entry/src/main/cpp/third_party/prebuilt/build_all.sh     # or a single build_<library>.sh
```

The scripts fetch pinned upstream sources and compile them with the HarmonyOS NDK that comes with DevEco Studio; with the toolchain version recorded in `build_env.txt`, the output is byte-for-byte identical to the committed files. Source versions, build options and checksums are recorded in the same file; upstream versions and licences of all components are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

The application code and its runtime libraries are currently available for arm64-v8a only, so the app runs on arm64 devices only; the x86_64 emulator is not supported.

### Project structure

```
AppScope/                 App-level configuration and icons
entry/
  src/main/cangjie/       Application code
    core/                 MTProto, storage, VoIP, theme
    services/ providers/  Business logic and data access
    viewmodels/ pages/ components/
                          UI
  src/main/cpp/           Native code: media, crypto and video-sticker bridges
    third_party/          rlottie and libwebm sources; prebuilt opus, libyuv, libvpx, BoringSSL
    voip/                 Call engine sources: tgcalls, WebRTC, HarmonyOS platform code
  src/main/ets/           ArkTS entry ability and interop glue
  libs/                   Prebuilt standard extension libraries (stdx)
third_party_licenses/     Licence texts of bundled third-party components
```

### Localization

Strings live in `entry/src/main/resources/base/element/string.json`. Translations of the official apps are maintained at https://translations.telegram.org.

### License

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either **version 2 of the License, or (at your option) any later version**. See [LICENSE](LICENSE) for the full text.

This is the same licence as [Telegram for Android](https://github.com/DrKLO/Telegram) and [Telegram for iOS](https://github.com/TelegramMessenger/Telegram-iOS), on which this project is based.

Bundled third-party components keep their own licences. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

"Telegram" and the Telegram logo are trademarks of Telegram FZ-LLC. "HarmonyOS" is a trademark of Huawei Technologies Co., Ltd.
