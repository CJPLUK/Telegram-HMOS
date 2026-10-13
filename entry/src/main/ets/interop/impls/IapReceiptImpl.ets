// IAP receipt capability — real @kit.IAPKit iap.createPurchase impl (Phase 3 reversal, SSOT §5).
// HMS IAP is Huawei-private; the @kit.IAPKit module IS present in this SDK, so the capability
// is genuinely reversed (NOT a fabricated receipt).
//
// ArkTS owns iap.createPurchase; cangjie PremiumSubscriptionFlowPage.getHarmonyIapReceipt()
// calls via callArkAsync(IAP_RECEIPT, argJson).
//
// argJson (cangjie → ArkTS): {"productId": string, "productType": number}
//     productId   — AppGallery Connect product id for the selected premium plan.
//                   When empty, IAP has no product to purchase → honest ok:false (N-A),
//                   which the caller surfaces as "not available on this platform".
//     productType — IAP ProductType: 0=CONSUMABLE 1=NONCONSUMABLE 2=AUTORENEWABLE 3=NONRENEWABLE.
//                   Telegram Premium is a renewable subscription → 2 (AUTORENEWABLE).
// result (ArkTS → cangjie): {"ok": boolean, "receipt": string}
//     ok=true  → purchase completed; receipt = CreatePurchaseResult.purchaseData (the store
//                receipt JSON string the Telegram server validates).
//     ok=false → purchase failed / cancelled / no productId. receipt omitted.
//
// The purchase UI requires a UIAbilityContext; obtained via getContext() (same pattern as
// BackgroundPrivacyImpl / ShareLinkImpl).
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { InteropMethod } from '../InteropContract';
import { iap } from '@kit.IAPKit';
import { common } from '@kit.AbilityKit';

interface IapReceiptArgs {
  productId: string;
  productType: number;
}

function toProductType(n: number): iap.ProductType {
  if (n === 0) {
    return iap.ProductType.CONSUMABLE;
  } else if (n === 1) {
    return iap.ProductType.NONCONSUMABLE;
  } else if (n === 3) {
    return iap.ProductType.NONRENEWABLE;
  }
  return iap.ProductType.AUTORENEWABLE;
}

export function registerIapReceipt(): void {
  registerArkFunc(InteropMethod.IAP_RECEIPT, (argJson: string, onResult: (r: string) => void): void => {
    try {
      const a: IapReceiptArgs = JSON.parse(argJson) as IapReceiptArgs;
      const productId: string = (typeof a.productId === 'string') ? a.productId : '';
      if (productId.length === 0) {
        // No AGC product configured → IAP has nothing to purchase. Honest N-A.
        onResult(JSON.stringify({ ok: false }));
        return;
      }
      const pType: iap.ProductType = toProductType(a.productType);
      const context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
      const parameter: iap.PurchaseParameter = {
        productId: productId,
        productType: pType
      };
      iap.createPurchase(context, parameter).then((result: iap.CreatePurchaseResult): void => {
        // CreatePurchaseResult carries the store receipt as purchaseData.
        const receipt: string = (typeof result.purchaseData === 'string') ? result.purchaseData : '';
        if (receipt.length > 0) {
          onResult(JSON.stringify({ ok: true, receipt: receipt }));
        } else {
          onResult(JSON.stringify({ ok: false }));
        }
      }).catch((): void => {
        onResult(JSON.stringify({ ok: false }));
      });
    } catch (e) {
      onResult(JSON.stringify({ ok: false }));
    }
  });
}
