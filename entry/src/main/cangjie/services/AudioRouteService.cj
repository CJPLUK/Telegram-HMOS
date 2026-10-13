package ohos_app_cangjie_entry.services

/**
 * AudioRouteService — 通话音频路由选择（P2-056）
 *
 * iOS 对照：
 *   TelegramCallsUI/Sources/CallControllerNodeV2.swift — availableAudioOutputs / setCurrentAudioOutput
 *   TelegramAudio/Sources/ManagedAudioSession.swift   — AudioSessionOutput enum + setupOutputMode
 *
 * 路由类型（对应 iOS AudioSessionOutput）:
 *   Builtin  → iOS .builtin     — 听筒（贴脸通话模式，proximity 触发时默认）
 *   Speaker  → iOS .speaker     — 扬声器（免提）
 *   WiredHeadset → iOS .headphones — 有线耳机/耳机（3.5mm + USB-C）
 *   BluetoothHeadset → iOS .bluetooth — 无线蓝牙耳机/AirPods
 *
 * 实现策略（C 优先查询结论 → Phase 3 反转模式, SSOT §5）：
 *   KB 三轮查询 "OH_AudioRoutingManager audio route selection C NDK"
 *   top_hit_score 均 < 0.02，无 C NDK Cangjie 绑定命中。
 *   → 系统调用搬到 ArkTS 侧 (ets/interop/impls/AudioRouteImpl.ets) 调 @kit.AudioKit audio：
 *     getAudioManager().getRoutingManager() → getDevices(2) 枚举输出设备，
 *     selectOutputDevice([descriptor]) 切换输出。启动时 registerArkFunc 注册进仓颉。
 *   → 仓颉经 callArkAsync 调用并解析结果 JSON；route↔deviceType 映射保留在仓颉侧。
 *
 * INTEROP 契约 (D3, 双侧签名一致):
 *   枚举: method = AUDIO_LIST_DEVICES ("audio.listDevices")
 *     argJson (CJ→ArkTS): {}
 *     result (ArkTS→CJ):  {"ok": <bool>, "devices": [{"id","type","name"}]}
 *   切换: method = AUDIO_SET_ROUTE ("audio.setRoute")
 *     argJson (CJ→ArkTS): {"deviceId": <id>}   仓颉侧已按 route 解析出 deviceId
 *     result (ArkTS→CJ):  {"ok": <bool>}
 *
 * 诚实说明：
 *   - selectOutputDevice / getDevices 在 ArkTS 层为异步 Promise；结果经 callArkAsync 回传。
 *   - 蓝牙设备 ID 在 getDevices(2) 中以设备 id 整数区分，无法提前知晓；实现为枚举后选第一个匹配设备。
 *   - 被动 OS deviceChange 推送监听未经 interop 桥接（需另建 dispatchEvent 事件通道 / 动共享文件）；
 *     setDeviceChangeCallback 保留公共签名，回调在每次 refreshDevices 主动重枚举时触发。
 */

import kit.PerformanceAnalysisKit.Hilog
import kit.ArkUI.launch
import ohos_app_cangjie_entry.interop.*
import std.collection.ArrayList

// ==================== 音频路由枚举 ====================

/**
 * 音频输出路由（对应 iOS AudioSessionOutput）
 * 用于 action sheet 显示和路由切换
 */
public enum AudioRoute {
    | Builtin          // 听筒（earpiece）
    | Speaker          // 扬声器（speakerphone）
    | WiredHeadset     // 有线耳机
    | BluetoothHeadset // 蓝牙耳机 / AirPods

    public func ordinal(): Int32 {
        match (this) {
            case Builtin => 0
            case Speaker => 1
            case WiredHeadset => 2
            case BluetoothHeadset => 3
        }
    }

    public operator func ==(right: AudioRoute): Bool {
        return this.ordinal() == right.ordinal()
    }

    public operator func !=(right: AudioRoute): Bool {
        return this.ordinal() != right.ordinal()
    }

    public func displayName(): String {
        match (this) {
            case Builtin => "Earpiece"
            case Speaker => "Speaker"
            case WiredHeadset => "Headphones"
            case BluetoothHeadset => "Bluetooth"
        }
    }

    public func icon(): String {
        match (this) {
            case Builtin => "🎧"
            case Speaker => "🔊"
            case WiredHeadset => "🎧"
            case BluetoothHeadset => "📶"
        }
    }
}

// ==================== 音频设备信息 ====================

/**
 * 鸿蒙音频输出设备描述
 * 通过 ArkTS getRoutingManager().getDevices(2) 枚举，2 = OUTPUT_DEVICES_FLAG
 */
public class AudioDeviceInfo {
    public var deviceId: Int32
    public var deviceType: Int32    // 2=builtin earpiece, 3=wired headset, 10=speaker, 7-9=BT variants
    public var deviceName: String

    public init(id: Int32, devType: Int32, name: String) {
        this.deviceId = id
        this.deviceType = devType
        this.deviceName = name
    }

    /**
     * 将鸿蒙 deviceType 映射到 AudioRoute
     * OH_AUDIO_DEVICE_TYPE: earpiece=2, speaker=3, wired_headset=7, BT_SCO=10, BT_A2DP=11
     */
    public func toAudioRoute(): AudioRoute {
        match (this.deviceType) {
            case 2 => AudioRoute.Builtin
            case 3 => AudioRoute.Speaker
            case 7 => AudioRoute.WiredHeadset
            case 10 => AudioRoute.BluetoothHeadset
            case 11 => AudioRoute.BluetoothHeadset
            case _ => AudioRoute.Builtin
        }
    }
}

// ==================== 单例 ====================

private var _audioRouteServiceInstance: Option<AudioRouteService> = None

public func getAudioRouteService(): AudioRouteService {
    match (_audioRouteServiceInstance) {
        case Some(s) => return s
        case None =>
            let s = AudioRouteService()
            _audioRouteServiceInstance = Some(s)
            return s
    }
}

// ==================== AudioRouteService ====================

/**
 * 音频路由服务
 *
 * 提供：
 *   1. getAvailableRoutes() — 枚举当前可用输出路由（通过 ArkTS arkinterop）
 *   2. setRoute(route:) — 切换路由（selectOutputDevice）
 *   3. getCurrentRoute() — 当前激活路由
 *   4. setDeviceChangeCallback() — 监听设备插拔/蓝牙连接变化
 *   5. refreshDevices() — 主动刷新设备列表（action sheet 打开时调用）
 */
public class AudioRouteService {

    private var _currentRoute: AudioRoute = AudioRoute.Builtin
    private var _availableRoutes: ArrayList<AudioRoute> = ArrayList<AudioRoute>()
    private var _availableDevices: ArrayList<AudioDeviceInfo> = ArrayList<AudioDeviceInfo>()
    private var _deviceChangeCallback: Option<(ArrayList<AudioRoute>) -> Unit> = None
    private var _listenerRegistered: Bool = false

    public init() {
        let routes = ArrayList<AudioRoute>()
        routes.add(AudioRoute.Builtin)
        routes.add(AudioRoute.Speaker)
        this._availableRoutes = routes
    }

    /**
     * 返回当前激活的路由
     */
    public func getCurrentRoute(): AudioRoute {
        return this._currentRoute
    }

    /**
     * 返回当前可用路由列表
     */
    public func getAvailableRoutes(): ArrayList<AudioRoute> {
        return this._availableRoutes
    }

    /**
     * 刷新设备列表（通话开始或 action sheet 打开时调用）
     * 通过 ArkTS @ohos.multimedia.audio → getRoutingManager().getDevices(2)
     */
    public func refreshDevices(callback: (ArrayList<AudioRoute>) -> Unit): Unit {
        Hilog.info(0, "CjTelegram", "[AudioRoute] refreshDevices via interop → ArkTS @kit.AudioKit")
        callArkAsync(AUDIO_LIST_DEVICES, "{}") { resJson =>
            // D1: 结果解析/回调是重活，放 spawn{} 里跑
            spawn {
                let newRoutes = ArrayList<AudioRoute>()
                let newDevices = ArrayList<AudioDeviceInfo>()
                var ok = false
                try {
                    let json = JsonParser.parseObject(resJson)
                    if (json.getBool("ok")) {
                        ok = true
                        let devArr = json.getArray("devices")
                        let len = devArr.size()
                        for (i in 0..len) {
                            let dev = devArr.getObject(i)
                            let devId = Int32(dev.getInt("id"))
                            let devType = Int32(dev.getInt("type"))
                            let nameVal = dev.getString("name")
                            let info = AudioDeviceInfo(devId, devType, nameVal)
                            let route = info.toAudioRoute()
                            var routeExists = false
                            for (existingRoute in newRoutes) {
                                if (existingRoute == route) { routeExists = true; break }
                            }
                            if (!routeExists) {
                                newRoutes.add(route)
                            }
                            newDevices.add(info)
                            Hilog.info(0, "CjTelegram", "[AudioRoute] device id=${devId} type=${devType} name=${nameVal}")
                        }
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AudioRoute] refreshDevices parse failed: ${e}")
                    ok = false
                }

                if (ok) {
                    // 确保听筒和扬声器始终可用
                    var hasBuiltin = false
                    var hasSpeaker = false
                    for (r in newRoutes) {
                        if (r == AudioRoute.Builtin) { hasBuiltin = true }
                        if (r == AudioRoute.Speaker) { hasSpeaker = true }
                    }
                    if (!hasBuiltin) { newRoutes.add(AudioRoute.Builtin) }
                    if (!hasSpeaker) { newRoutes.add(AudioRoute.Speaker) }

                    let routesCopy = newRoutes
                    let devsCopy = newDevices
                    launch {
                        this._availableRoutes = routesCopy
                        this._availableDevices = devsCopy
                        callback(routesCopy)
                    }
                } else {
                    Hilog.info(0, "CjTelegram", "[AudioRoute] refreshDevices ok=false, fallback builtin/speaker")
                    let fallback = ArrayList<AudioRoute>()
                    fallback.add(AudioRoute.Builtin)
                    fallback.add(AudioRoute.Speaker)
                    launch {
                        this._availableRoutes = fallback
                        callback(fallback)
                    }
                }
            }
        }
    }

    /**
     * 切换音频输出路由
     * 通过 ArkTS selectOutputDevice([deviceId]) 切换
     *
     * @param route 目标路由
     */
    public func setRoute(route: AudioRoute): Unit {
        Hilog.info(0, "CjTelegram", "[AudioRoute] setRoute: ${route.displayName()}")
        let targetRoute = route

        // route → deviceId 解析保留在仓颉侧（映射不跨边界）
        var targetDeviceId: Int32 = -1
        for (dev in this._availableDevices) {
            if (dev.toAudioRoute() == targetRoute) {
                targetDeviceId = dev.deviceId
                break
            }
        }

        if (targetDeviceId < 0) {
            Hilog.info(0, "CjTelegram", "[AudioRoute] no device for route ${targetRoute.displayName()}, skip")
        } else {
            // argJson schema 与 ArkTS AudioRouteImpl 逐条对应 (D3): {"deviceId"}
            let argJson = "{\"deviceId\":${targetDeviceId}}"
            let capturedRoute = targetRoute
            callArkAsync(AUDIO_SET_ROUTE, argJson) { resJson =>
                spawn {
                    let json = JsonParser.parseObject(resJson)
                    if (json.getBool("ok")) {
                        Hilog.info(0, "CjTelegram", "[AudioRoute] selectOutputDevice ok route=${capturedRoute.displayName()}")
                        launch { this._currentRoute = capturedRoute }
                    } else {
                        Hilog.info(0, "CjTelegram", "[AudioRoute] selectOutputDevice failed route=${capturedRoute.displayName()}")
                    }
                }
            }
        }

        // 乐观更新本地状态（避免 UI 等待 async 确认）
        launch { this._currentRoute = route }
    }

    /**
     * 注册设备变化监听（耳机插拔、蓝牙连接/断开）
     * ArkTS: routingManager.on("deviceChange", callback)
     *
     * 对应 iOS: AVAudioSession.routeChangeNotification
     */
    public func setDeviceChangeCallback(cb: (ArrayList<AudioRoute>) -> Unit): Unit {
        this._deviceChangeCallback = Some(cb)
        if (this._listenerRegistered) { return }
        this._listenerRegistered = true

        // 被动 OS deviceChange 推送需另建 interop 事件通道（out of scope，未桥接）。
        // 保留公共签名：立即主动重枚举一次，让 caller 拿到当前路由；后续变化经
        // refreshDevices（action sheet 打开 / 通话开始）主动触发时也会回调 _deviceChangeCallback。
        Hilog.info(0, "CjTelegram", "[AudioRoute] setDeviceChangeCallback: registered (on-demand refresh model)")
        this.refreshDevices({ newRoutes =>
            match (this._deviceChangeCallback) {
                case Some(cbFn) => cbFn(newRoutes)
                case None => ()
            }
        })
    }

    /**
     * 通话开始时初始化路由
     * - 若有蓝牙设备 → 自动切换蓝牙（对应 iOS 行为）
     * - 否则保持听筒（默认）
     */
    public func onCallStarted(): Unit {
        Hilog.info(0, "CjTelegram", "[AudioRoute] onCallStarted — refreshing devices")
        this.refreshDevices({ routes =>
            var hasBt = false
            var hasWired = false
            for (r in routes) {
                if (r == AudioRoute.BluetoothHeadset) { hasBt = true }
                if (r == AudioRoute.WiredHeadset) { hasWired = true }
            }
            if (hasBt) {
                this.setRoute(AudioRoute.BluetoothHeadset)
            } else if (hasWired) {
                this.setRoute(AudioRoute.WiredHeadset)
            } else {
                Hilog.info(0, "CjTelegram", "[AudioRoute] onCallStarted: default builtin/speaker")
            }
        })
    }

    /**
     * 通话结束时恢复
     */
    public func onCallEnded(): Unit {
        this._currentRoute = AudioRoute.Builtin
        Hilog.info(0, "CjTelegram", "[AudioRoute] onCallEnded — route reset to Builtin")
    }
}
