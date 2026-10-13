package ohos_app_cangjie_entry.viewmodels

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import std.sync.*
import ohos_app_cangjie_entry.services.*

/**
 * DeviceLocationManagerViewModel — 设备位置管理 ViewModel (Phase DLMGR)
 *
 * 对应 iOS DeviceLocationManager，为 UI 提供可观察的位置状态和操作方法。
 *
 * 状态:
 * - currentLocation: 当前位置（若有）
 * - isAuthorized: 是否已授权位置权限
 * - accuracyLevel: 精度级别（high=附近的人，low=通用）
 */
@Observed
public class DeviceLocationManagerViewModel {

    @Publish public var currentLocation: Option<LocationResult> = None<LocationResult>
    @Publish public var isAuthorized: Bool = false
    @Publish public var accuracyLevel: LocationAccuracyLevel = LocationAccuracyLevel.High
    @Publish public var isLoading: Bool = false
    @Publish public var errorMessage: String = ""

    private var _service: DeviceLocationManagerService = getDeviceLocationManagerService()

    /**
     * 刷新授权状态
     */
    public func refreshAuthorization(): Unit {
        this.isAuthorized = this._service.isAuthorized()
    }

    /**
     * 请求位置权限
     */
    public func requestPermission(onComplete: () -> Unit): Unit {
        this._service.requestPermission({ granted: Bool =>
            launch {
                this.isAuthorized = granted
                if (!granted) {
                    this.errorMessage = "位置权限未授权"
                } else {
                    this.errorMessage = ""
                }
                onComplete()
            }
        })
    }

    /**
     * 一次性请求当前位置
     */
    public func requestLocation(): Unit {
        if (!this.isAuthorized) {
            this.requestPermission({ => this.doRequestLocation() })
            return
        }
        this.doRequestLocation()
    }

    private func doRequestLocation(): Unit {
        this.isLoading = true
        this.errorMessage = ""
        spawn {
            let result = this._service.requestLocation(this.accuracyLevel)
            launch {
                if (result.success) {
                    this.currentLocation = Some(result)
                    this.errorMessage = ""
                    Hilog.info(0, "CjTelegram", "[DeviceLocationVM] requestLocation success")
                } else {
                    this.errorMessage = result.errorMessage
                    if (this.errorMessage.size == 0) {
                        this.errorMessage = "定位失败"
                    }
                }
                this.isLoading = false
            }
        }
    }

    /**
     * 设置精度级别
     */
    public func setAccuracyLevel(level: LocationAccuracyLevel): Unit {
        this.accuracyLevel = level
    }

    /**
     * 获取缓存的最近位置
     */
    public func getLastKnownLocation(): Option<LocationResult> {
        return this._service.getLastKnownLocation()
    }

    /**
     * 开始连续定位（用于实时位置分享）
     * @return true=已启动
     */
    public func startContinuousLocation(): Bool {
        if (!this.isAuthorized) {
            return false
        }
        return this._service.startContinuousLocation(
            this.accuracyLevel,
            { result: LocationResult =>
                launch {
                    this.currentLocation = Some(result)
                }
            }
        )
    }

    /**
     * 停止连续定位
     */
    public func stopLocation(): Unit {
        this._service.stopLocation()
    }

    /**
     * 初始化时刷新授权状态并加载缓存
     */
    public func onAppear(): Unit {
        this.refreshAuthorization()
        match (this._service.getLastKnownLocation()) {
            case Some(loc) =>
                this.currentLocation = Some(loc)
            case _ =>
                ()
        }
    }
}
