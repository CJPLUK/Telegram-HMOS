## Telegram for HarmonyOS

[English](README.md) | [简体中文](README.zh-CN.md)

[Telegram](https://telegram.org) 是一款注重速度与安全的即时通讯应用，快速、简洁、免费。
本仓库包含一个**非官方** HarmonyOS Telegram 客户端的源码。它是原生 HarmonyOS 应用，辅以少量 C++。

客户端直接通过 MTProto 与 Telegram 服务器通信，界面与交互对齐 [Telegram for iOS](https://github.com/TelegramMessenger/Telegram-iOS)。本项目与 Telegram FZ-LLC 无任何隶属、背书或维护关系。

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
- arm64 HarmonyOS 真机，或 x86_64 模拟器

1. 克隆源码：
   ```bash
   git clone https://github.com/PoivronMax/Telegram-HMOS.git
   ```
2. 用 DevEco Studio 打开（Open，不要用 Import）项目目录，等待同步完成。
3. 在 `entry/src/main/cangjie/core/mtproto/MTProtoConfig.cj` 中，把从 https://my.telegram.org/apps 拿到的值填入 `PROD_API_ID` 和 `PROD_API_HASH`。如需使用 Telegram 测试数据中心，也请填写 `TEST_API_ID` / `TEST_API_HASH`。
4. 配置签名：**File › Project Structure › Signing Configs**，登录后勾选 *Automatically generate signature*（或指定你自己的证书）。DevEco Studio 会把签名配置写入 `build-profile.json5`，其中含证书路径和密钥口令，**请勿提交**。
5. 选择 `entry` 模块点击 **Run**。也可以用 DevEco Studio 自带的 `hvigorw`（`<DevEco Studio>/tools/hvigor/bin/hvigorw`）在命令行编译：
   ```bash
   hvigorw assembleHap --mode module -p product=default -p buildMode=debug
   ```

### 已知限制

几个预编译的原生媒体库（libopus、libyuv、libvpx 和 BoringSSL）暂未包含在本仓库中。项目不依赖它们也能正常编译，但在补齐之前：

- **语音消息**以 WAV 而不是 Opus/OGG 发送，对方收到的是普通音频文件，而不是语音消息。
- **圆形视频消息**按原始录制画面发送，不做 400×400 方形裁剪。
- **视频贴纸**（WebM/VP9）无法播放。
- **MTProto 加密**使用较慢的备用实现。

语音和视频通话不受影响。这些库会在后续更新中补齐。

### 目录结构

```
AppScope/                 应用级配置与图标
entry/
  src/main/cangjie/       应用代码
    core/                 MTProto、存储、VoIP、主题
    services/ providers/  业务逻辑与数据访问
    viewmodels/ pages/ components/
                          界面
  src/main/cpp/           原生代码：rlottie（动画贴纸）、媒体与视频贴纸桥接
  src/main/ets/           ArkTS 入口 Ability 与互操作胶水层
  libs/                   预编译的标准扩展库（stdx）与 libtgcalls_ohos.so
third_party_licenses/     随仓库分发的第三方组件许可证全文
```

### 本地化

字符串位于 `entry/src/main/resources/base/element/string.json`。官方客户端的翻译维护在 https://translations.telegram.org。

### 许可证

本程序是自由软件：你可以依据自由软件基金会发布的 GNU 通用公共许可证（GPL）**第 2 版，或（由你选择）任何更新的版本**，再发布和/或修改它。完整条款见 [LICENSE](LICENSE)。

这与本项目所基于的 [Telegram for Android](https://github.com/DrKLO/Telegram) 和 [Telegram for iOS](https://github.com/TelegramMessenger/Telegram-iOS) 使用的许可证相同。

随仓库分发的第三方组件保留各自的许可证，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

“Telegram”及 Telegram Logo 是 Telegram FZ-LLC 的商标。“HarmonyOS”是华为技术有限公司的商标。
