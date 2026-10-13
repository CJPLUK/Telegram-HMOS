package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.{getMTProtoClient, getClientForDC as mtprotoGetClientForDC, resetGlobalClient as mtprotoResetGlobalClient, ConnectionState, MTProtoClient}
import std.sync.ReentrantMutex
import std.time.*
/**
 * TelegramCore 网络服务 — MTProtoClient 增值封装
 *
 * 对应 Telegram-iOS TelegramCore/Network 层，在已有 MTProtoClient 基础上提供：
 * - 连接状态监控：根据请求成功/超时推断连接状态，支持状态回调
 * - 重连逻辑：请求超时或空响应时自动调用 ensureConnectionAlive 并重试一次
 * - 请求重试：单次失败自动重试，避免上层重复实现
 *
 * 禁止：重写 MTProtoClient 已有的 sendRequest/getClientForDC/resetGlobalClient
 */
private var _networkServiceInstance: Option<TelegramCore_NetworkService> = None
private let _networkServiceMutex = ReentrantMutex()

public func getTelegramCore_NetworkService(): TelegramCore_NetworkService {
    _networkServiceMutex.lock()
    match (_networkServiceInstance) {
        case Some(inst) =>
            _networkServiceMutex.unlock()
            return inst
        case None =>
            let inst = TelegramCore_NetworkService()
            _networkServiceInstance = Some(inst)
            _networkServiceMutex.unlock()
            return inst
    }
}

/**
 * 连接状态回调
 */
public interface NetworkConnectionStateCallback {
    func onConnectionStateChanged(state: ConnectionState): Unit
}

public class TelegramCore_NetworkService {
    private var lastKnownState: ConnectionState = ConnectionState.Disconnected
    private var stateCallback: Option<NetworkConnectionStateCallback> = None
    private let stateMutex = ReentrantMutex()

    public init() {}

    /**
     * 设置连接状态变化回调（供 UI 层监听）
     */
    public func setConnectionStateCallback(callback: NetworkConnectionStateCallback) {
        this.stateCallback = Some(callback)
    }

    /**
     * 获取当前推断的连接状态
     */
    public func getConnectionState(): ConnectionState {
        stateMutex.lock()
        let s = this.lastKnownState
        stateMutex.unlock()
        return s
    }

    /**
     * 发送 RPC 请求（增值：超时自动重连并重试一次）
     * 委托 MTProtoClient.sendRequest，不重复实现
     */
    public func sendRequest(data: Array<Byte>): Array<Byte> {
        let client = getMTProtoClient()
        var response = client.sendRequest(data)

        if (response.size == 0) {
            Hilog.info(0, "CjTelegram", "[NetworkService] Request timeout, ensuring connection alive and retrying...")
            client.ensureConnectionAlive()
            sleep(Duration.millisecond * 500)  // 等待重连
            response = client.sendRequest(data)
        }

        notifyStateFromResponse(response.size > 0)
        return response
    }

    /**
     * 获取指定 DC 的客户端（跨 DC 文件下载等）
     * 委托 getClientForDC，不重复实现
     */
    public func getClientForDC(dcId: Int64): MTProtoClient {
        return mtprotoGetClientForDC(dcId)
    }

    /**
     * 重置全局客户端（登出等场景）
     * 委托 resetGlobalClient
     */
    public func resetGlobalClient(): Unit {
        mtprotoResetGlobalClient()
        notifyStateFromResponse(false)
    }

    /**
     * 确保连接存活（供轮询等场景主动调用）
     */
    public func ensureConnectionAlive(): Unit {
        let client = getMTProtoClient()
        client.ensureConnectionAlive()
    }

    // 防止重复注册可达性监听器（幂等）。
    private var _reachabilityWired: Bool = false

    /**
     * P2-252 消费接线：把 ReachabilityService 的网络状态变化接到 MTProtoClient 的立即重连。
     *
     * 网络从「断」恢复到「通」（status 变为非 NetUnavailable）→ 调用 client.triggerReconnect()：
     *   取消当前退避等待、立刻发起一次重连，而非干等指数退避走完。
     * 这同时兑现了 P2-252 ReachabilityService 的消费侧（可达性 → 重连）。
     *
     * 解耦说明：core.mtproto 不反向 import services（避免包级循环依赖）；接线统一放在 services 层，
     *   由本方法用 addListener 注入回调驱动 MTProtoClient.triggerReconnect（与 NetworkUsageService 计量钩子同范式）。
     *
     * 幂等：重复调用只注册一次。全程 try/catch 降级——可达性服务不可用绝不影响既有反应式重连路径。
     */
    public func wireReachabilityReconnect(): Unit {
        stateMutex.lock()
        if (this._reachabilityWired) {
            stateMutex.unlock()
            return
        }
        this._reachabilityWired = true
        stateMutex.unlock()

        try {
            let reach = ReachabilityService.getInstance()
            reach.start()
            reach.addListener({ status: NetworkStatus =>
                // 网络可用（非明确不可用）→ 触发立即重连；不可用时不动（等恢复）。
                match (status) {
                    case NetUnavailable => ()
                    case _ =>
                        Hilog.info(0, "CjTelegram",
                            "[NetworkService] reachability up → immediate reconnect")
                        try {
                            getMTProtoClient().triggerReconnect()
                        } catch (e: Exception) {
                            Hilog.error(0, "CjTelegram",
                                "[NetworkService] triggerReconnect failed: ${e}")
                        }
                }
            })
            Hilog.info(0, "CjTelegram", "[NetworkService] reachability→reconnect wiring installed")
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram",
                "[NetworkService] wireReachabilityReconnect failed, staying on reactive reconnect: ${e}")
            stateMutex.lock()
            this._reachabilityWired = false
            stateMutex.unlock()
        }
    }

    private func connectionStatesEqual(a: ConnectionState, b: ConnectionState): Bool {
        match (a) {
            case ConnectionState.Disconnected =>
                match (b) {
                    case ConnectionState.Disconnected => return true
                    case _ => return false
                }
            case ConnectionState.Connecting =>
                match (b) {
                    case ConnectionState.Connecting => return true
                    case _ => return false
                }
            case ConnectionState.Connected =>
                match (b) {
                    case ConnectionState.Connected => return true
                    case _ => return false
                }
            case ConnectionState.Updating =>
                match (b) {
                    case ConnectionState.Updating => return true
                    case _ => return false
                }
        }
    }

    private func notifyStateFromResponse(success: Bool) {
        let newState = if (success) { ConnectionState.Connected } else { ConnectionState.Disconnected }
        var changed = false
        stateMutex.lock()
        if (!connectionStatesEqual(this.lastKnownState, newState)) {
            this.lastKnownState = newState
            changed = true
        }
        let cb = this.stateCallback
        stateMutex.unlock()

        if (changed) {
            match (cb) {
                case Some(callback) => callback.onConnectionStateChanged(newState)
                case None => ()
            }
        }
    }
}
