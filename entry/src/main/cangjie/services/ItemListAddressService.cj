package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList

/**
 * ItemListAddressService — 地址列表项数据层
 *
 * 对应 iOS ItemListAddressItem.swift 所需的数据接口。
 * 用于 Passport、收货地址、账单地址等场景。
 *
 * 提供:
 * - AddressData 数据模型
 * - 地址校验方法
 * - 多行/单行格式化
 * - 复制到剪贴板
 */
private var _itemListAddressServiceInstance: Option<ItemListAddressService> = None

public func getItemListAddressService(): ItemListAddressService {
    match (_itemListAddressServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ItemListAddressService()
            _itemListAddressServiceInstance = Some(inst)
            return inst
    }
}

/**
 * 地址数据模型
 * 对应 Telegram Passport SecureValue 中的 address 结构
 */
public class AddressData {
    public var street1: String = ""
    public var street2: String = ""
    public var city: String = ""
    public var state: String = ""
    public var country: String = ""
    public var postCode: String = ""

    public init() {}

    public init(street1: String, street2: String, city: String, state: String, country: String, postCode: String) {
        this.street1 = street1
        this.street2 = street2
        this.city = city
        this.state = state
        this.country = country
        this.postCode = postCode
    }

    /**
     * 判断地址是否为空
     */
    public func isEmpty(): Bool {
        return this.street1.isEmpty() && this.street2.isEmpty() &&
            this.city.isEmpty() && this.state.isEmpty() &&
            this.country.isEmpty() && this.postCode.isEmpty()
    }
}

public class ItemListAddressService {

    /**
     * 校验地址是否有效（至少包含街道或城市+国家）
     */
    public func validateAddress(addr: AddressData): Bool {
        if (addr.isEmpty()) { return false }
        let hasStreet = addr.street1.size > 0 || addr.street2.size > 0
        let hasCity = addr.city.size > 0
        let hasCountry = addr.country.size > 0
        return hasStreet || (hasCity && hasCountry)
    }

    /**
     * 格式化为多行显示（用于列表项展示）
     * 每行一个字段，空字段跳过
     */
    public func formatMultiLine(addr: AddressData): String {
        let parts = ArrayList<String>()
        if (addr.street1.size > 0) { parts.add(addr.street1) }
        if (addr.street2.size > 0) { parts.add(addr.street2) }
        if (addr.city.size > 0) { parts.add(addr.city) }
        if (addr.state.size > 0) { parts.add(addr.state) }
        if (addr.country.size > 0) { parts.add(addr.country) }
        if (addr.postCode.size > 0) { parts.add(addr.postCode) }
        if (parts.size == 0) { return "" }
        let sb = StringBuilder()
        sb.append(parts[0])
        for (i in 1..parts.size) {
            sb.append("\n")
            sb.append(parts[i])
        }
        return sb.toString()
    }

    /**
     * 格式化为单行（用于复制、搜索等）
     */
    public func formatSingleLine(addr: AddressData): String {
        let parts = ArrayList<String>()
        if (addr.street1.size > 0) { parts.add(addr.street1) }
        if (addr.street2.size > 0) { parts.add(addr.street2) }
        if (addr.city.size > 0) { parts.add(addr.city) }
        if (addr.state.size > 0) { parts.add(addr.state) }
        if (addr.country.size > 0) { parts.add(addr.country) }
        if (addr.postCode.size > 0) { parts.add(addr.postCode) }
        if (parts.size == 0) { return "" }
        let sb = StringBuilder()
        sb.append(parts[0])
        for (i in 1..parts.size) {
            sb.append(", ")
            sb.append(parts[i])
        }
        return sb.toString()
    }

    /**
     * 复制地址到剪贴板
     * 使用多行格式，便于粘贴到表单
     */
    public func copyToClipboard(addr: AddressData): Unit {
        let text = this.formatMultiLine(addr)
        if (text.size > 0) {
            setClipboardText(text)
            Hilog.info(0, "CjTelegram", "[ItemListAddressService] Copied address to clipboard")
        }
    }

    /**
     * 复制指定文本到剪贴板（用于长按复制整段地址）
     */
    public func copyTextToClipboard(text: String): Unit {
        if (text.size > 0) {
            setClipboardText(text)
            Hilog.info(0, "CjTelegram", "[ItemListAddressService] Copied text to clipboard")
        }
    }
}
