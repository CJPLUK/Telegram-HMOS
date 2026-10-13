package ohos_app_cangjie_entry.adapters

import ohos_app_cangjie_entry.core.mtproto.{ConnectionState, MTProtoClient}
import ohos_app_cangjie_entry.services.{getTelegramCore_NetworkService, NetworkConnectionStateCallback}
/**
 * TelegramCore 网络适配层 — 对外接口
 *
 * 对应 Telegram-iOS TelegramCore/Network 对外 API
 * 为上层业务提供易用接口，委托 TelegramCore_NetworkService 实现
 *
 * 使用方式：
 *   let adapter = getTelegramCore_NetworkAdapter()
 *   let response = adapter.sendRequest(tlRequest.toBytes())
 *   let client = adapter.getClientForDC(dcId)
 */
private var _adapterInstance: Option<TelegramCore_NetworkAdapter> = None

public func getTelegramCore_NetworkAdapter(): TelegramCore_NetworkAdapter {
    match (_adapterInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = TelegramCore_NetworkAdapter()
            _adapterInstance = Some(inst)
            return inst
    }
}

public class TelegramCore_NetworkAdapter {
    public init() {}

    /**
     * 发送 RPC 请求
     * 委托 NetworkService（含超时重连、重试逻辑）
     */
    public func sendRequest(data: Array<Byte>): Array<Byte> {
        return getTelegramCore_NetworkService().sendRequest(data)
    }

    /**
     * 获取指定 DC 的 MTProto 客户端（跨 DC 文件下载等）
     */
    public func getClientForDC(dcId: Int64): MTProtoClient {
        return getTelegramCore_NetworkService().getClientForDC(dcId)
    }

    /**
     * 重置全局客户端（登出等场景）
     */
    public func resetGlobalClient(): Unit {
        getTelegramCore_NetworkService().resetGlobalClient()
    }

    /**
     * 获取当前连接状态
     */
    public func getConnectionState(): ConnectionState {
        return getTelegramCore_NetworkService().getConnectionState()
    }

    /**
     * 设置连接状态变化回调（供 UI 显示网络状态）
     */
    public func setConnectionStateCallback(callback: NetworkConnectionStateCallback): Unit {
        getTelegramCore_NetworkService().setConnectionStateCallback(callback)
    }

    /**
     * 确保连接存活（供轮询等场景主动调用）
     */
    public func ensureConnectionAlive(): Unit {
        getTelegramCore_NetworkService().ensureConnectionAlive()
    }

    /**
     * P2-252b: 订阅 ReachabilityService addListener，网络恢复时立即触发 MTProtoClient 重连。
     * 幂等：重复调用只注册一次。全程 try/catch 降级——可达性服务不可用时保留既有反应式重连。
     */
    public func wireReachabilityReconnect(): Unit {
        getTelegramCore_NetworkService().wireReachabilityReconnect()
    }
}
