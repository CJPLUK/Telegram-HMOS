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
5. 选择 `entry` 模块点击 **Run**。

### 原生库

与 Telegram for Android 一样，本仓库直接附带几个预编译的第三方原生库，克隆后即可编译出完整功能：opus（语音消息）、libyuv（圆形视频消息）、libvpx（视频贴纸）和 BoringSSL 的 libcrypto（MTProto 加密）。它们位于 `entry/src/main/cpp/third_party/prebuilt/`（arm64-v8a），同目录还有头文件和从固定版本源码重新编译它们的脚本：

```bash
entry/src/main/cpp/third_party/prebuilt/build_all.sh
```

编译结果可复现，与仓库中的文件逐字节一致。源码版本、工具链和校验和见同目录的 `build_env.txt`。

通话引擎 `entry/libs/arm64-v8a/libtgcalls_ohos.so` 同样是预编译的，所用上游版本见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

完整功能仅支持 arm64 设备。x86_64 模拟器上，语音消息编码、圆形视频裁剪和视频贴纸使用桩实现，通话不可用。

### 目录结构

```
AppScope/                 应用级配置与图标
entry/
  src/main/cangjie/       应用代码
    core/                 MTProto、存储、VoIP、主题
    services/ providers/  业务逻辑与数据访问
    viewmodels/ pages/ components/
                          界面
  src/main/cpp/           原生代码：媒体、加密与视频贴纸桥接
    third_party/          rlottie 与 libwebm 源码；预编译的 opus、libyuv、libvpx、libcrypto
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
