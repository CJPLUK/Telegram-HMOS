package ohos_app_cangjie_entry.viewmodels

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.getInAppPurchaseManagerService

/**
 * 应用内购买 ViewModel
 *
 * 连接 InAppPurchaseManagerService，提供 Premium 订阅、恢复购买等接口
 * 对应 iOS InAppPurchaseManager: availableProducts, buyProduct, restorePurchases
 *
 * 鸿蒙适配: 产品列表由华为 IAP SDK 获取，收据由华为 IAP 提供后通过本 ViewModel 提交至 Telegram
 */
@Observed
public class InAppPurchaseManagerViewModel {

    @Publish public var isLoading: Bool = false
    @Publish public var lastError: String = ""
    @Publish public var restoreSucceeded: Bool = false
    @Publish public var sendReceiptSucceeded: Bool = false

    // Premium 产品 ID 列表（iOS productIdentifiers 对应）
    private let _productIds: ArrayList<String> = ArrayList<String>()

    public func ensureProductIdsLoaded(): Unit {
        if (this._productIds.isEmpty()) {
            this._productIds.add("org.telegram.telegramPremium.monthly")
            this._productIds.add("org.telegram.telegramPremium.threeMonths")
            this._productIds.add("org.telegram.telegramPremium.sixMonths")
            this._productIds.add("org.telegram.telegramPremium.twelveMonths")
        }
    }

    /**
     * 获取可用的 Premium 产品 ID 列表
     * 鸿蒙实际价格由华为 IAP SDK 获取，此处仅返回产品 ID
     */
    public func getAvailableProductIds(): ArrayList<String> {
        this.ensureProductIdsLoaded()
        return this._productIds
    }

    /**
     * 提交收据至 Telegram 服务器
     * @param receipt 收据字节（华为 IAP 或 App Store）
     * @param purpose "subscription" | "restore" | "upgrade"
     */
    public func sendReceipt(receipt: Array<Byte>, purpose: String): Unit {
        this.isLoading = true
        this.lastError = ""
        this.sendReceiptSucceeded = false
        spawn {
            let svc = getInAppPurchaseManagerService()
            let ok = svc.sendAppStoreReceipt(receipt, purpose)
            launch {
                this.isLoading = false
                if (ok) {
                    this.sendReceiptSucceeded = true
                    this.lastError = ""
                } else {
                    this.lastError = "send_receipt_failed"
                }
            }
        }
    }

    /**
     * 恢复购买
     * 由调用方传入收据数据（华为 IAP 恢复后提供）
     */
    public func restorePurchases(receipt: Array<Byte>): Unit {
        this.isLoading = true
        this.lastError = ""
        this.restoreSucceeded = false
        spawn {
            let svc = getInAppPurchaseManagerService()
            let ok = svc.sendAppStoreReceipt(receipt, "restore")
            launch {
                this.isLoading = false
                if (ok) {
                    this.restoreSucceeded = true
                    this.lastError = ""
                } else {
                    this.restoreSucceeded = false
                    this.lastError = "restore_failed"
                }
            }
        }
    }

    /**
     * 清除上次操作结果
     */
    public func clearLastResult(): Unit {
        this.lastError = ""
        this.restoreSucceeded = false
        this.sendReceiptSucceeded = false
    }
}
