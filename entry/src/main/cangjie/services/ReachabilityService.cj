package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.NetworkKit.*
import ohos.callback_invoke.*
import ohos.business_exception.*
import ohos.base.*
import std.collection.ArrayList
import std.sync.ReentrantMutex

/**
 * ReachabilityService —— 网络可达性监测（单元 P2-252）。
 *
 * 对照 iOS Telegram-iOS/submodules/Reachability/Sources/Reachability.swift：
 *   iOS 用 NWPathMonitor / LegacyReachability 暴露 NetworkType { none | wifi | cellular }
 *   + reachabilityChanged 回调。该服务把同一语义搬到鸿蒙原生
 *   **@ohos.net.connection（kit.NetworkKit）**：
 *     - createNetConnection() → NetConnection 句柄
 *     - register() 订阅默认网络状态变化
 *     - on(NetAvailable / NetUnavailable / NetCapabilitiesChange / NetLost) 回调更新当前状态
 *     - getDefaultNet() / hasDefaultNet() / getNetCapabilities(netHandle) 用于初始快照
 *   bearerTypes(Array<NetBearType>) 含 BearerWifi → Wifi、BearerCellular → Cellular、
 *   其它 → Other，空/无网 → Unavailable。
 *
 * 用途：供"连接状态 header / 可达性驱动重连"消费——MTProtoClient 可 addListener 在网络恢复时
 *   触发重连，UI 可读 currentStatus()/isAvailable() 渲染连接状态。工程现状无主动网络状态观察、
 *   重连仅反应式；本服务补齐主动观测侧。
 *
 * 降级（最高优先：不破坏现有可运行性）：所有 net.connection 调用 try/catch。
 *   API 失败 / 句柄拿不到时，currentStatus 退回保守值（Unknown / 保守 Available），
 *   绝不抛异常崩溃；消费方据此回退原有反应式重连路径。
 *
 * MTProto 说明：本服务只观测系统网络可达性，不参与 MTProto 协议帧；接线点（重连触发）由
 *   消费方通过 addListener 注入回调，本服务不直接依赖 MTProtoClient。
 *
 * 并发：currentStatus / listeners 受 stateMutex 保护；通知采用"快照-under-lock、锁外回调"范式，
 *   listener 闭包只捕获 let（status 值类型 + 不可变引用），避免回调重入死锁。
 */

/**
 * 网络状态枚举。
 * 构造子加 Net 前缀，避免与包内其它枚举/标识符在包级命名空间冲突。
 */
public enum NetworkStatus {
    | NetUnknown      // 尚未探测 / API 不可用的保守占位
    | NetUnavailable  // 明确无网络
    | NetWifi         // WiFi
    | NetCellular     // 蜂窝
    | NetOther        // 以太网等其它承载类型
}

extend NetworkStatus <: Equatable<NetworkStatus> {
    public operator func ==(that: NetworkStatus): Bool {
        match ((this, that)) {
            case (NetUnknown, NetUnknown) => true
            case (NetUnavailable, NetUnavailable) => true
            case (NetWifi, NetWifi) => true
            case (NetCellular, NetCellular) => true
            case (NetOther, NetOther) => true
            case _ => false
        }
    }

    public operator func !=(that: NetworkStatus): Bool {
        return !(this == that)
    }
}

/**
 * NetAvailable 事件回调：网络从无到有。
 */
class _ReachNetAvailableCb <: Callback1Argument<NetHandle> {
    let callback_: (NetHandle) -> Unit
    public init(callback: (NetHandle) -> Unit) {
        callback_ = callback
    }
    public func invoke(err: ?BusinessException, val: NetHandle): Unit {
        callback_(val)
    }
}

/**
 * NetUnavailable 事件回调：网络不可用（0 参数）。
 */
class _ReachNetUnavailableCb <: Callback0Argument {
    let callback_: () -> Unit
    public init(callback: () -> Unit) {
        callback_ = callback
    }
    public func invoke(err: ?BusinessException): Unit {
        callback_()
    }
}

/**
 * NetCapabilitiesChange 事件回调：承载能力变化（wifi↔cellular 等）。
 */
class _ReachNetCapabilitiesChangeCb <: Callback1Argument<NetCapabilityInfo> {
    let callback_: (NetCapabilityInfo) -> Unit
    public init(callback: (NetCapabilityInfo) -> Unit) {
        callback_ = callback
    }
    public func invoke(err: ?BusinessException, val: NetCapabilityInfo): Unit {
        callback_(val)
    }
}

/**
 * NetLost 事件回调：曾可用的网络丢失。
 */
class _ReachNetLostCb <: Callback1Argument<NetHandle> {
    let callback_: (NetHandle) -> Unit
    public init(callback: (NetHandle) -> Unit) {
        callback_ = callback
    }
    public func invoke(err: ?BusinessException, val: NetHandle): Unit {
        callback_(val)
    }
}

public class ReachabilityService {
    private static var _instance: Option<ReachabilityService> = None<ReachabilityService>

    private let stateMutex = ReentrantMutex()
    private var currentStatus_: NetworkStatus = NetUnknown
    private var started_: Bool = false
    private var conn_: Option<NetConnection> = None<NetConnection>
    private let listeners_: ArrayList<(NetworkStatus) -> Unit> = ArrayList<(NetworkStatus) -> Unit>()

    private init() {}

    /**
     * 获取单例实例。
     */
    public static func getInstance(): ReachabilityService {
        if (ReachabilityService._instance.isNone()) {
            ReachabilityService._instance = Some(ReachabilityService())
        }
        return ReachabilityService._instance.getOrThrow()
    }

    /**
     * 启动网络可达性监测：注册默认网络回调并采集初始快照。
     * 幂等：重复 start 不重复注册。全程 try/catch 降级。
     */
    public func start(): Unit {
        synchronized(this.stateMutex) {
            if (this.started_) {
                return
            }
            this.started_ = true
        }

        // 1) 初始快照（getDefaultNet + getNetCapabilities），失败保守降级。
        let initial = this.probeCurrentStatus()
        this.updateStatus(initial)

        // 2) 注册 net.connection 默认网络回调。
        try {
            let conn = createNetConnection()
            conn.register()

            let availableCb = _ReachNetAvailableCb({ handle: NetHandle =>
                ReachabilityService.getInstance().onNetAvailable(handle)
            })
            conn.on(NetConnectionEvent.NetAvailable, availableCb)

            let unavailableCb = _ReachNetUnavailableCb({ =>
                ReachabilityService.getInstance().onNetUnavailable()
            })
            conn.on(NetConnectionEvent.NetUnavailable, unavailableCb)

            let capChangeCb = _ReachNetCapabilitiesChangeCb({ info: NetCapabilityInfo =>
                ReachabilityService.getInstance().onNetCapabilitiesChange(info)
            })
            conn.on(NetConnectionEvent.NetCapabilitiesChange, capChangeCb)

            let lostCb = _ReachNetLostCb({ handle: NetHandle =>
                ReachabilityService.getInstance().onNetLost(handle)
            })
            conn.on(NetConnectionEvent.NetLost, lostCb)

            synchronized(this.stateMutex) {
                this.conn_ = Some(conn)
            }
            Hilog.info(0, "CjTelegram", "[ReachabilityService] started, registered net.connection callbacks")
        } catch (e: BusinessException) {
            Hilog.error(0, "CjTelegram",
                "[ReachabilityService] register failed (code=${e.code}): ${e.message}; degrading to passive")
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[ReachabilityService] register failed: ${e}; degrading to passive")
        }
    }

    /**
     * 停止监测：注销 net.connection 订阅。全程 try/catch。
     */
    public func stop(): Unit {
        var connToStop: Option<NetConnection> = None<NetConnection>
        synchronized(this.stateMutex) {
            if (!this.started_) {
                return
            }
            connToStop = this.conn_
            this.conn_ = None<NetConnection>
            this.started_ = false
        }
        match (connToStop) {
            case Some(conn) =>
                try {
                    conn.unregister()
                    Hilog.info(0, "CjTelegram", "[ReachabilityService] stopped, unregistered net.connection")
                } catch (e: BusinessException) {
                    Hilog.error(0, "CjTelegram",
                        "[ReachabilityService] unregister failed (code=${e.code}): ${e.message}")
                } catch (e: Exception) {
                    Hilog.error(0, "CjTelegram", "[ReachabilityService] unregister failed: ${e}")
                }
            case None => ()
        }
    }

    /**
     * 当前网络状态（线程安全读）。
     */
    public func currentStatus(): NetworkStatus {
        synchronized(this.stateMutex) {
            return this.currentStatus_
        }
    }

    /**
     * 网络是否可用。保守语义：Unknown 视为可用（避免误判离线阻断既有反应式路径）。
     */
    public func isAvailable(): Bool {
        let s = this.currentStatus()
        match (s) {
            case NetUnavailable => false
            case _ => true
        }
    }

    /**
     * 注册网络状态变化监听器（供 MTProtoClient 重连、UI 连接 header 等消费）。
     * 闭包只捕获 let。
     */
    public func addListener(cb: (NetworkStatus) -> Unit): Unit {
        synchronized(this.stateMutex) {
            this.listeners_.add(cb)
        }
    }

    /**
     * 清空全部监听器。
     */
    public func clearListeners(): Unit {
        synchronized(this.stateMutex) {
            this.listeners_.clear()
        }
    }

    // ---- 内部：事件处理 ----

    private func onNetAvailable(handle: NetHandle): Unit {
        // 网络可用：尽量读 capabilities 判 wifi/cellular，读不到退 Other。
        var status = NetOther
        try {
            let caps = getNetCapabilities(handle)
            status = ReachabilityService.statusFromCapabilities(caps)
        } catch (e: BusinessException) {
            Hilog.error(0, "CjTelegram",
                "[ReachabilityService] onNetAvailable getNetCapabilities failed (code=${e.code}): ${e.message}")
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[ReachabilityService] onNetAvailable getNetCapabilities failed: ${e}")
        }
        Hilog.info(0, "CjTelegram", "[ReachabilityService] netAvailable netId=${handle.netId}")
        this.updateStatus(status)
    }

    private func onNetUnavailable(): Unit {
        Hilog.info(0, "CjTelegram", "[ReachabilityService] netUnavailable")
        this.updateStatus(NetUnavailable)
    }

    private func onNetCapabilitiesChange(info: NetCapabilityInfo): Unit {
        let status = ReachabilityService.statusFromCapabilities(info.netCap)
        Hilog.info(0, "CjTelegram", "[ReachabilityService] netCapabilitiesChange netId=${info.netHandle.netId}")
        this.updateStatus(status)
    }

    private func onNetLost(handle: NetHandle): Unit {
        // 网络丢失：若系统仍有其它默认网络则重新探测，否则视为不可用。
        Hilog.info(0, "CjTelegram", "[ReachabilityService] netLost netId=${handle.netId}")
        let status = this.probeCurrentStatus()
        this.updateStatus(status)
    }

    /**
     * 主动探测当前默认网络状态。失败保守降级为 Unknown。
     */
    private func probeCurrentStatus(): NetworkStatus {
        try {
            if (!hasDefaultNet()) {
                return NetUnavailable
            }
            let handle = getDefaultNet()
            if (handle.netId == 0) {
                return NetUnavailable
            }
            let caps = getNetCapabilities(handle)
            return ReachabilityService.statusFromCapabilities(caps)
        } catch (e: BusinessException) {
            Hilog.error(0, "CjTelegram",
                "[ReachabilityService] probe failed (code=${e.code}): ${e.message}; status=Unknown")
            return NetUnknown
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[ReachabilityService] probe failed: ${e}; status=Unknown")
            return NetUnknown
        }
    }

    /**
     * 从 NetCapabilities.bearerTypes 推导 NetworkStatus。
     * BearerWifi 优先于 BearerCellular（与 iOS wifi 优先一致），其它承载 → Other，空 → Unavailable。
     */
    private static func statusFromCapabilities(caps: NetCapabilities): NetworkStatus {
        let bearers = caps.bearerTypes
        if (bearers.size == 0) {
            return NetUnavailable
        }
        var hasWifi = false
        var hasCellular = false
        var hasOther = false
        for (b in bearers) {
            match (b) {
                case BearerWifi => hasWifi = true
                case BearerCellular => hasCellular = true
                case _ => hasOther = true
            }
        }
        if (hasWifi) {
            return NetWifi
        }
        if (hasCellular) {
            return NetCellular
        }
        if (hasOther) {
            return NetOther
        }
        return NetUnavailable
    }

    /**
     * 更新当前状态；若发生变化，快照 listener（under lock）后锁外通知。
     */
    private func updateStatus(newStatus: NetworkStatus): Unit {
        var changed = false
        var snapshot: Array<(NetworkStatus) -> Unit> = Array<(NetworkStatus) -> Unit>()
        synchronized(this.stateMutex) {
            if (this.currentStatus_ != newStatus) {
                this.currentStatus_ = newStatus
                changed = true
                snapshot = this.listeners_.toArray()
            }
        }
        if (changed) {
            Hilog.info(0, "CjTelegram", "[ReachabilityService] status changed, notifying ${snapshot.size} listener(s)")
            for (cb in snapshot) {
                try {
                    cb(newStatus)
                } catch (e: Exception) {
                    Hilog.error(0, "CjTelegram", "[ReachabilityService] listener threw: ${e}")
                }
            }
        }
    }
}
