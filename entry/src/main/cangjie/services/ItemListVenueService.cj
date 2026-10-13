package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog

/**
 * 场所列表项数据层 (ItemListVenueItem)
 *
 * iOS 原版 (ItemListVenueItem.swift) 本身无 MTProto/TL 调用——
 * 该组件是纯展示/选择行：接收外部传入的场所数据（名称、地址、类型），
 * 渲染后通过 onSelect 回调把选中事件交回调用方。
 * 网络层由上游（如 LocationPicker）负责，本服务提供场所数据模型和辅助工具。
 *
 * 调用链: ItemListVenueComponent.onClick → onSelect callback（无 TL）
 */

// 场所展示数据模型
public class VenueItemData {
    public var venueId: String = ""
    public var title: String = ""
    public var address: String = ""
    public var type_: String = ""
    public var latitude: Float64 = 0.0
    public var longitude: Float64 = 0.0
    public var provider: String = "foursquare"

    public init() {}

    public init(
        venueId: String,
        title: String,
        address: String,
        type_: String,
        latitude: Float64,
        longitude: Float64
    ) {
        this.venueId = venueId
        this.title = title
        this.address = address
        this.type_ = type_
        this.latitude = latitude
        this.longitude = longitude
    }
}

private var _itemListVenueServiceInstance: Option<ItemListVenueService> = None

public func getItemListVenueService(): ItemListVenueService {
    match (_itemListVenueServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ItemListVenueService()
            _itemListVenueServiceInstance = Some(inst)
            return inst
    }
}

/**
 * ItemListVenueService — 场所列表项辅助服务
 *
 * 提供场所类型到展示颜色/标签的映射，供 ItemListVenueComponent 使用。
 * 对应 iOS LocationResources 框架中 venueIcon() 的颜色逻辑。
 */
public class ItemListVenueService {

    /**
     * 根据 Foursquare 场所类型返回展示背景色（ARGB Int32）
     * iOS 原版用 venueIcon(engine:type:background:) 信号加载图标；
     * 仓颉侧简化为颜色映射，图标以类型首字母代替。
     */
    public func venueIconColor(type_: String): Int64 {
        let lowerType = type_.toAsciiLower()
        if (lowerType.contains("food") || lowerType.contains("restaurant") || lowerType.contains("cafe")) {
            return 0xE8744C
        } else if (lowerType.contains("shop") || lowerType.contains("store") || lowerType.contains("market")) {
            return 0x5AB1D6
        } else if (lowerType.contains("hotel") || lowerType.contains("lodging") || lowerType.contains("hostel")) {
            return 0x7BC67E
        } else if (lowerType.contains("park") || lowerType.contains("garden") || lowerType.contains("nature")) {
            return 0x50C878
        } else if (lowerType.contains("art") || lowerType.contains("museum") || lowerType.contains("gallery")) {
            return 0x9B59B6
        } else if (lowerType.contains("sport") || lowerType.contains("gym") || lowerType.contains("fitness")) {
            return 0xE74C3C
        } else if (lowerType.contains("transport") || lowerType.contains("station") || lowerType.contains("airport")) {
            return 0x3498DB
        } else if (lowerType.contains("health") || lowerType.contains("hospital") || lowerType.contains("pharmacy")) {
            return 0xE91E63
        } else {
            return 0x317AFF
        }
    }

    /**
     * 根据场所类型返回单字母图标标签
     */
    public func venueIconLabel(type_: String): String {
        let lowerType = type_.toAsciiLower()
        if (lowerType.contains("food") || lowerType.contains("restaurant") || lowerType.contains("cafe")) {
            return "F"
        } else if (lowerType.contains("shop") || lowerType.contains("store") || lowerType.contains("market")) {
            return "S"
        } else if (lowerType.contains("hotel") || lowerType.contains("lodging")) {
            return "H"
        } else if (lowerType.contains("park") || lowerType.contains("garden")) {
            return "P"
        } else if (lowerType.contains("art") || lowerType.contains("museum")) {
            return "M"
        } else if (lowerType.contains("sport") || lowerType.contains("gym")) {
            return "G"
        } else if (lowerType.contains("transport") || lowerType.contains("station") || lowerType.contains("airport")) {
            return "T"
        } else if (lowerType.contains("health") || lowerType.contains("hospital")) {
            return "+"
        } else {
            return "L"
        }
    }

    /**
     * 记录场所选中事件（供调试/日志使用）
     */
    public func logVenueSelected(venue: VenueItemData): Unit {
        Hilog.info(0, "CjTelegram", "[ItemListVenueService] venue selected: title=${venue.title} type=${venue.type_}")
    }
}
