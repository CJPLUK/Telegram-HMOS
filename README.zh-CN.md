## Telegram for HarmonyOS

[English](README.md) | [简体中文](README.zh-CN.md)

[Telegram](https://telegram.org) 是一款注重速度与安全的即时通讯应用，快速、简洁、免费。
本仓库包含一个**非官方** HarmonyOS Telegram 客户端的源码。它是原生 HarmonyOS 应用，辅以少量 C++。

客户端直接通过 MTProto 与 Telegram 服务器通信，界面与交互对齐 [Telegram for iOS](https://github.com/TelegramMessenger/Telegram-iOS)。本项目与 Telegram FZ-LLC 无任何隶属、背书或维护关系。

与 Telegram for iOS 对照的核心场景测试结果见[测试报告](docs/test-report/README.zh-CN.md)。

## 创建你自己的 Telegram 应用

Telegram 欢迎所有开发者使用其 API 和源码在其平台上开发应用。目前 Telegram 对**所有开发者**有以下要求：

1. [**申请你自己的 api_id**](https://core.telegram.org/api/obtaining_api_id)。
2. 请**不要**在你的应用名中使用 Telegram，或确保用户清楚它是非官方应用。
3. 请**不要**使用 Telegram 的标准 Logo（蓝色圆形中的白色纸飞机）作为你的应用图标。
4. 请阅读 Telegram 的[**安全指南**](https://core.telegram.org/mtproto/security_guidelines)，妥善保护用户的数据与隐私。
5. 请记得同样公开**你自己的**代码，以遵守许可证要求。

### API 与协议文档

Telegram API 文档：https://core.telegram.org/api

MTProto 协议文档：https://core.telegram.org/mtproto

当前实现的 API layer 为 214（`MTProtoConfig.LAYER`）。

### 编译指南

**注意**：本仓库**不包含**任何 API 凭证和签名配置。编译前请按下文填写你自己的 `api_id` / `api_hash` 并配置签名。

环境要求：

- [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/) 6.1 及以上，并安装仓颉插件
- HarmonyOS SDK 6.0.2（API 22）
- arm64 HarmonyOS 真机

1. 克隆源码：
   ```bash
   git clone --recursive https://github.com/CJPLUK/Telegram-HMOS.git
   ```
   `--recursive` 会同时拉取通话引擎依赖的 Abseil 子模块。已经克隆过的仓库执行一次 `git submodule update --init --recursive`。
2. 用 DevEco Studio 打开（Open，不要用 Import）项目目录，等待同步完成。
3. 在 `entry/src/main/cangjie/core/mtproto/MTProtoConfig.cj` 中，把从 https://my.telegram.org/apps 拿到的值填入 `PROD_API_ID` 和 `PROD_API_HASH`。如需使用 Telegram 测试数据中心，也请填写 `TEST_API_ID` / `TEST_API_HASH`。
4. 配置签名：**File › Project Structure › Signing Configs**，登录后勾选 *Automatically generate signature*（或指定你自己的证书）。DevEco Studio 会把签名配置写入 `build-profile.json5`，其中含证书路径和密钥口令，**请勿提交**。
5. 选择 `entry` 模块点击 **Run**。

### 原生库

应用的 C/C++ 部分位于 `entry/src/main/cpp/`，用到以下第三方库：

| 库 | 用途 | 形式 |
|---|---|---|
| opus 1.5.1 | 语音消息编码 | 预编译静态库 |
| libyuv | 圆形视频消息转码 | 预编译静态库 |
| libvpx 1.13.0 | WebM 视频贴纸解码 | 预编译静态库 |
| BoringSSL（libcrypto、libssl） | MTProto 加密、通话加密 | 预编译静态库 |
| libwebm（mkvparser） | WebM 容器解析 | 源码 |
| rlottie | 动画贴纸与表情 | 源码 |
| tgcalls、WebRTC、Abseil、libsrtp、crc32c、PFFFT、RNNoise | 语音/视频通话引擎 `libtgcalls_ohos.so` | 源码 |

其中 opus、libyuv、libvpx 和 BoringSSL 也被通话引擎使用（音频编码、视频格式转换、VP8/VP9、DTLS/SRTP）。

**源码部分**在 DevEco Studio 构建时由 CMake 随应用一起编译（入口是 `entry/src/main/cpp/CMakeLists.txt`），无需额外操作。通话引擎的构建脚本是 `entry/src/main/cpp/voip/CMakeLists.txt`，HarmonyOS 平台层（音频、相机与录屏采集、硬件 H.264 编解码）在 `voip/ohos/`。通话引擎在 Debug 构建中也开启优化，因此首次构建会多花几分钟。Abseil 以 git 子模块引入，克隆时需要 `--recursive`。

**预编译静态库**及其头文件位于 `entry/src/main/cpp/third_party/prebuilt/`，克隆后直接参与链接。如需从源码重新编译：

```bash
entry/src/main/cpp/third_party/prebuilt/build_all.sh     # 或单独运行 build_<库名>.sh
```

脚本会拉取固定版本的上游源码，用 DevEco Studio 自带的 HarmonyOS NDK 编译；使用 `build_env.txt` 中记录的同一版本工具链时，产物与仓库中的文件逐字节一致。源码版本、编译选项和校验和也记录在该文件中；各库的上游版本与许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

应用代码及其运行库目前只有 arm64-v8a 版本，因此应用只能运行在 arm64 设备上，不支持 x86_64 模拟器。

### 目录结构

```
AppScope/                 应用级配置与图标
docs/test-report/         测试报告
entry/
  src/main/cangjie/       应用代码
    core/                 MTProto、存储、VoIP、主题
    services/ providers/  业务逻辑与数据访问
    viewmodels/ pages/ components/
                          界面
  src/main/cpp/           原生代码：媒体、加密与视频贴纸桥接
    third_party/          rlottie 与 libwebm 源码；预编译的 opus、libyuv、libvpx、BoringSSL
    voip/                 通话引擎源码：tgcalls、WebRTC、HarmonyOS 平台层
  src/main/ets/           ArkTS 入口 Ability 与互操作胶水层
  libs/                   预编译的标准扩展库（stdx）
third_party_licenses/     随仓库分发的第三方组件许可证全文
```

### 本地化

字符串位于 `entry/src/main/resources/base/element/string.json`。官方客户端的翻译维护在 https://translations.telegram.org。

### 许可证

本程序是自由软件：你可以依据自由软件基金会发布的 GNU 通用公共许可证（GPL）**第 2 版，或（由你选择）任何更新的版本**，再发布和/或修改它。完整条款见 [LICENSE](LICENSE)。

这与本项目所基于的 [Telegram for Android](https://github.com/DrKLO/Telegram) 和 [Telegram for iOS](https://github.com/TelegramMessenger/Telegram-iOS) 使用的许可证相同。

随仓库分发的第三方组件保留各自的许可证，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

“Telegram”及 Telegram Logo 是 Telegram FZ-LLC 的商标。“HarmonyOS”是华为技术有限公司的商标。
