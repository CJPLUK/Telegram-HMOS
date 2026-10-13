package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.services.{getPeersNearbyIconService, getCurrentDeviceLocation}

/**
 * 附近的人图标组件 (Phase PNRIN)
 *
 * 对应 Telegram-iOS PeersNearbyIconNode
 * 中心圆 + 外扩脉冲圈 + 附近人数 badge
 * 无人时灰色，有人时蓝色
 * 当 lat/lng 为 0 时自动获取当前位置
 */
@Component
public class PeersNearbyIconComponent {
    public var lat: Float64 = 0.0
    public var lng: Float64 = 0.0
    public var size: Int64 = 48
    public var onClick: () -> Unit = { => }

    @State var nearbyCount: Int32 = 0

    public func aboutToAppear(): Unit {
        this.loadNearbyCount()
    }

    private func loadNearbyCount(): Unit {
        let _ = spawn {
            var useLat = this.lat
            var useLng = this.lng
            if (useLat == 0.0 && useLng == 0.0) {
                let loc = getCurrentDeviceLocation()
                if (loc.success) {
                    useLat = loc.latitude
                    useLng = loc.longitude
                }
            }
            let service = getPeersNearbyIconService()
            let count = service.getNearbyCount(useLat, useLng)
            launch {
                this.nearbyCount = count
            }
        }
    }

    private func getCenterColor(): Int64 {
        if (this.nearbyCount > 0) {
            return 0x317AFF
        }
        return 0x8E8E93
    }

    private func getPulseColor(): Int64 {
        if (this.nearbyCount > 0) {
            return 0x317AFF
        }
        return 0x8E8E93
    }

    public func build() {
        Stack(alignContent: Alignment.Center) {
            this.buildPulseRings()
            this.buildCenterIcon()
            this.buildBadge()
        }
        .width(this.size)
        .height(this.size)
        .onClick({ _evt => this.onClick() })
    }

    @Builder
    private func buildPulseRings() {
        Column {}
            .width(this.size + 16)
            .height(this.size + 16)
            .borderRadius((this.size + 16) / 2)
            .backgroundColor(this.getPulseColor())
            .opacity(0.2)
        Column {}
            .width(this.size + 26)
            .height(this.size + 26)
            .borderRadius((this.size + 26) / 2)
            .backgroundColor(this.getPulseColor())
            .opacity(0.1)
    }

    @Builder
    private func buildCenterIcon() {
        Column {
            Text("\u{1F4CD}")
                .fontSize(this.size * 24 / 48)
                .fontColor(0xFFFFFF)
        }
        .width(this.size)
        .height(this.size)
        .borderRadius(this.size / 2)
        .backgroundColor(this.getCenterColor())
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    private func buildBadge() {
        if (this.nearbyCount > 0) {
            Column {
                Text(if (this.nearbyCount > 99) { "99+" } else { "${this.nearbyCount}" })
                    .fontSize(10)
                    .fontColor(0xFFFFFF)
                    .fontWeight(FontWeight.Medium)
            }
            .padding(left: 4, right: 4, top: 2, bottom: 2)
            .backgroundColor(0x317AFF)
            .borderRadius(8)
            .constraintSize(maxWidth: 24, maxHeight: 16)
            .alignSelf(ItemAlign.End)
            .margin(top: -4, right: -4)
        }
    }
}
