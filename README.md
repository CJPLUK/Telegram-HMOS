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
- An arm64 HarmonyOS device, or the x86_64 emulator

1. Clone the source code:
   ```bash
   git clone https://github.com/PoivronMax/Telegram-HMOS.git
   ```
2. Open the project directory in DevEco Studio (open it, do NOT import it) and let it sync.
3. Fill in `PROD_API_ID` and `PROD_API_HASH` in `entry/src/main/cangjie/core/mtproto/MTProtoConfig.cj` with the values you got from https://my.telegram.org/apps. Fill in `TEST_API_ID` / `TEST_API_HASH` too if you plan to use Telegram's test data centers.
4. Configure signing: **File › Project Structure › Signing Configs**, then sign in and choose *Automatically generate signature* (or point it to your own certificate). DevEco Studio writes the signing configuration into `build-profile.json5`; **do not commit it**, it contains your certificate paths and key passwords.
5. Choose the `entry` module and press **Run**. To build from the command line instead, use the `hvigorw` bundled with DevEco Studio (`<DevEco Studio>/tools/hvigor/bin/hvigorw`):
   ```bash
   hvigorw assembleHap --mode module -p product=default -p buildMode=debug
   ```

### Known limitations

A few prebuilt native media libraries (libopus, libyuv, libvpx and BoringSSL) are not yet included in this repo. The project builds without them, but until they are added:

- **Voice messages** are sent as WAV instead of Opus/OGG, so recipients get a regular audio file instead of a voice message.
- **Round video messages** are sent as recorded, without the 400×400 square crop.
- **Video stickers** (WebM/VP9) do not play.
- **MTProto encryption** uses a slower fallback implementation.

Voice and video calls are not affected. These libraries will be added in a future update.

### Project structure

```
AppScope/                 App-level configuration and icons
entry/
  src/main/cangjie/       Application code
    core/                 MTProto, storage, VoIP, theme
    services/ providers/  Business logic and data access
    viewmodels/ pages/ components/
                          UI
  src/main/cpp/           Native code: rlottie (animated stickers), media and video-sticker bridges
  src/main/ets/           ArkTS entry ability and interop glue
  libs/                   Prebuilt standard extension libraries (stdx) and libtgcalls_ohos.so
third_party_licenses/     Licence texts of bundled third-party components
```

### Localization

Strings live in `entry/src/main/resources/base/element/string.json`. Translations of the official apps are maintained at https://translations.telegram.org.

### License

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either **version 2 of the License, or (at your option) any later version**. See [LICENSE](LICENSE) for the full text.

This is the same licence as [Telegram for Android](https://github.com/DrKLO/Telegram) and [Telegram for iOS](https://github.com/TelegramMessenger/Telegram-iOS), on which this project is based.

Bundled third-party components keep their own licences. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

"Telegram" and the Telegram logo are trademarks of Telegram FZ-LLC. "HarmonyOS" is a trademark of Huawei Technologies Co., Ltd.
