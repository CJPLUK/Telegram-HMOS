package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.{
    getMTProtoClient,
    PaymentsAssignAppStoreTransaction,
    PaymentsCanPurchaseStore,
    InputStorePaymentPremiumSubscription,
    TLObject,
    TLDeserializer,
    TLConstructors
}

/**
 * 应用内购买服务 (In-App Purchase Manager Service)
 *
 * 封装 payments.assignAppStoreTransaction TL 方法
 * 调用链: Service → MTProtoClient.sendRequest()
 *
 * 对应 iOS InAppPurchaseManager: engine.payments.sendAppStoreReceipt
 * 鸿蒙侧: 收据数据来自华为 IAP SDK，通过本服务提交至 Telegram 服务器
 */
private var _iapServiceInstance: Option<InAppPurchaseManagerService> = None

public func getInAppPurchaseManagerService(): InAppPurchaseManagerService {
    match (_iapServiceInstance) {
        case Some(s) => s
        case None =>
            let s = InAppPurchaseManagerService()
            _iapServiceInstance = Some(s)
            s
    }
}

public class InAppPurchaseManagerService {

    /**
     * 查询服务端购买资格（payments.canPurchaseStore#4fdc5ea7）
     *
     * 向 Telegram 服务端确认当前用户是否具备执行指定店内购买的资格。
     * 响应为 Bool (boolTrue 0x997275b5 / boolFalse 0xbc799737)。
     *
     * iOS 对应: Api.functions.payments.canPurchaseStore(purpose:)
     * ctor 0x4fdc5ea7 validated: iOS appendInt32(1339842215) -> hex 0x4fdc5ea7
     *
     * @param purpose 购买目的（InputStorePaymentPremiumSubscription 等 InputStorePaymentPurpose 变体）
     * @return true 允许购买，false 不允许
     */
    public func canPurchaseStore(purpose: InputStorePaymentPremiumSubscription): Bool {
        return this.canPurchaseStorePurpose(purpose)
    }

    public func canPurchaseStorePurpose(purpose: TLObject): Bool {
        try {
            let req = PaymentsCanPurchaseStore()
            req.purpose = purpose
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size >= 4) {
                let d = TLDeserializer(responseData)
                let ctor = d.readUInt32()
                if (ctor == TLConstructors.RPC_ERROR) {
                    let _ = d.readInt32()
                    let _ = d.readString()
                    Hilog.info(0, "CjTelegram", "[IAP] canPurchaseStore RPC error")
                    return false
                }
                let result = ctor == TLConstructors.BOOL_TRUE
                Hilog.info(0, "CjTelegram", "[IAP] canPurchaseStore result received")
                return result
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[IAP] canPurchaseStore exception")
        }
        return false
    }

    /**
     * 向 Telegram 服务器提交 App Store 收据
     * @param receipt 收据字节数据（iOS: App Store receipt, 鸿蒙: 华为 IAP 收据）
     * @param purpose "subscription" | "restore" | "upgrade"
     * @return true 成功, false 失败
     */
    public func sendAppStoreReceipt(receipt: Array<Byte>, purpose: String): Bool {
        if (receipt.size == 0) {
            Hilog.info(0, "CjTelegram", "[IAP] sendAppStoreReceipt: receipt empty")
            return false
        }
        try {
            let purposeObj = InputStorePaymentPremiumSubscription()
            if (purpose == "restore") {
                purposeObj.restore = true
            } else if (purpose == "upgrade") {
                purposeObj.upgrade = true
            }
            return this.sendStoreReceipt(receipt, purposeObj)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[IAP] sendAppStoreReceipt exception")
        }
        return false
    }

    public func sendStoreReceipt(receipt: Array<Byte>, purpose: TLObject): Bool {
        if (receipt.size == 0) { return false }
        try {
            let req = PaymentsAssignAppStoreTransaction()
            req.receipt = receipt
            req.purpose = purpose
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size >= 4) {
                let d = TLDeserializer(responseData)
                let ctor = d.readUInt32()
                if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                    let _ = d.readInt32()
                    let _ = d.readString()
                    Hilog.info(0, "CjTelegram", "[IAP] sendAppStoreReceipt RPC error")
                    return false
                }
                Hilog.info(0, "CjTelegram", "[IAP] sendAppStoreReceipt success")
                return true
            }
        } catch (e: Exception) { Hilog.info(0, "CjTelegram", "[IAP] sendStoreReceipt exception") }
        return false
    }
}
