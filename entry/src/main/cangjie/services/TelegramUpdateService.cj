package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.{getMTProtoClient, TLSerializer, HelpAppUpdateResponse, MTProtoConfig}

/**
 * 应用更新检查结果
 * 对应 help.appUpdate 的 UI 友好格式
 */
public class AppUpdateResult {
    public var hasUpdate: Bool = false
    public var version: String = ""
    public var text: String = ""
    public var url: String = ""
    public var blocking: Bool = false
}

/**
 * TelegramUpdateService — 应用更新检查服务
 *
 * 对应 iOS TelegramUpdateUI
 * TL: help.getAppUpdate#522d5a7d source:string → help.AppUpdate
 *
 * 平台说明(HarmonyOS):
 *   鸿蒙应用更新通过 AppGallery 分发，无法实现应用内自更新(in-app binary replace)。
 *   本 Service 实现:
 *     1. getCurrentAppVersion() — 返回真实 APP_VERSION 常量(与 initConnection 上报一致)
 *     2. checkForUpdate()       — 真实发起 help.getAppUpdate MTProto 请求
 *   UpdateInfoPage 用 checkForUpdate 结果填充 changelog/version 展示；
 *   下载/安装入口 honest-deferred 为引导用户前往 AppGallery。
 */
public func getTelegramUpdateService(): TelegramUpdateService {
    return TelegramUpdateService()
}

public class TelegramUpdateService {

    /**
     * 返回当前安装版本号
     * 使用与 initConnection.appVersion 相同的常量，保证版本展示与 MTProto 握手一致
     */
    public func getCurrentAppVersion(): String {
        return MTProtoConfig.APP_VERSION
    }

    /**
     * 检查是否有应用更新
     * 发起真实 help.getAppUpdate MTProto 请求
     * @param source 来源标识（如 "settings"）
     * @return 更新信息；无更新时 hasUpdate=false；网络失败时返回 hasUpdate=false
     */
    public func checkForUpdate(source: String): AppUpdateResult {
        let result = AppUpdateResult()
        try {
            let client = getMTProtoClient()
            let serializer = TLSerializer()
            // help.getAppUpdate#522d5a7d source:string
            serializer.writeUInt32(0x522d5a7d)
            serializer.writeString(source)
            let data = client.sendRequest(serializer.getBytes())
            if (data.size >= 4) {
                let tlResp = HelpAppUpdateResponse.deserialize(data)
                result.hasUpdate = tlResp.hasUpdate
                result.version = tlResp.version
                result.text = tlResp.text
                result.url = tlResp.url
                result.blocking = tlResp.blocking
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[TelegramUpdateService] checkForUpdate error: ${e}")
        }
        return result
    }
}
