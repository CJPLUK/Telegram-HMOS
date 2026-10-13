package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.services.{
    getPremiumService,
    PremiumPromoResult,
    PremiumPeriodOption,
    getInAppPurchaseManagerService,
    getPaymentsService
}
import ohos_app_cangjie_entry.core.mtproto.InputStorePaymentPremiumSubscription
import ohos_app_cangjie_entry.interop.*
import std.collection.ArrayList

/**
 * P2-299: Premium 订阅购买流程页（混合工程迁移版）
 *
 * iOS 对照: PremiumIntroScreen (购买流程) + InAppPurchaseManager
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹（.title/.hideTitleBar 由 ArkTS 壳提供）
 *  - pushPathByName → routerPush
 *  - aboutToAppear 有实逻辑（loadPrices）→ ensureLoaded()/.onAppear
 *
 * IAP Receipt（P2-299 → Phase 3 反转）：华为 IAP 无 C NDK，走 ArkTS @kit.IAPKit interop。
 * 反转链路: requestIapReceipt → callArkAsync(IAP_RECEIPT) → IapReceiptImpl.ets →
 *   iap.createPurchase → CreatePurchaseResult.purchaseData（真实 store receipt）。
 * 注意：本 build 尚未接入 AppGallery Connect 产品目录（iapProductIdForSelection 返回空串），
 * ArkTS 侧据此诚实返回 ok:false（N-A），绝不伪造 receipt；接入产品目录后即真实可购。
 */
// ---- 轻量 JSON 读取（仅解析 interop 回传的扁平 result 对象）----
private func jsonBoolFieldPremium(json: String, key: String): Bool {
    let needle = "\"${key}\""
    match (json.indexOf(needle)) {
        case Some(i) =>
            let rest = json[(i + needle.size)..json.size]
            match (rest.indexOf("true")) {
                case Some(t) =>
                    match (rest.indexOf("false")) {
                        case Some(f) => return t < f
                        case None => return true
                    }
                case None => return false
            }
        case None => return false
    }
}

private func jsonStringFieldPremium(json: String, key: String): String {
    let needle = "\"${key}\""
    match (json.indexOf(needle)) {
        case Some(i) =>
            let afterKey = json[(i + needle.size)..json.size]
            match (afterKey.indexOf("\"")) {
                case Some(q1) =>
                    let valStart = afterKey[(q1 + 1)..afterKey.size]
                    match (valStart.indexOf("\"")) {
                        case Some(q2) => return valStart[0..q2]
                        case None => return ""
                    }
                case None => return ""
            }
        case None => return ""
    }
}

// IAP receipt 字符串 → UTF-8 字节（sendAppStoreReceipt 需 Array<Byte>）。
private func iapReceiptBytes(receipt: String): Array<Byte> {
    return receipt.toArray()
}

@HybridComponentEntry
@Component
public class PremiumSubscriptionFlowPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var isLoadingPrices: Bool = true
    @State var priceInfoList: Array<PremiumPriceInfo> = Array<PremiumPriceInfo>(0, repeat: PremiumPriceInfo())
    @State var selectedOptionIndex: Int64 = 0
    @State var isPurchasing: Bool = false
    @State var isRestoring: Bool = false
    @State var purchaseError: String = ""
    @State var purchaseSucceeded: Bool = false
    @State var showConfetti: Bool = false
    @State var platformNote: String = ""
    @State var loaded: Bool = false

    // P2-306: Confetti 粒子动画状态（内联避免跨 @Component 实例化问题）
    @State var confettiTickCount: Int64 = 0
    @State var confettiIsRunning: Bool = false
    private let cfSettings: RenderingContextSettings = RenderingContextSettings(antialias: true)
    private let cfContext: CanvasRenderingContext2D = CanvasRenderingContext2D(this.cfSettings)
    private var cfParticles: Array<ConfettiViewParticle> = Array<ConfettiViewParticle>(0, repeat: ConfettiViewParticle())
    private var cfCanvasWidth: Float64 = 390.0
    private var cfCanvasHeight: Float64 = 844.0

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let _ = spawn {
            this.loadPrices()
        }
    }

    private func loadPrices(): Unit {
        let svc = getPremiumService()
        let result = svc.getPremiumPromo()
        let priceList: Array<PremiumPriceInfo>
        if (result.parseOk && result.periodOptions.size > 0) {
            priceList = PremiumPriceCalculator.buildPriceInfoList(options: result.periodOptions)
            Hilog.info(0, "CjTelegram", "[PremiumSubscriptionFlowPage] loaded ${priceList.size} price options from server")
        } else {
            priceList = this.defaultPriceList()
            Hilog.info(0, "CjTelegram", "[PremiumSubscriptionFlowPage] using fallback price list")
        }
        launch {
            this.isLoadingPrices = false
            this.priceInfoList = priceList
        }
    }

    private func defaultPriceList(): Array<PremiumPriceInfo> {
        let list = ArrayList<PremiumPriceInfo>()

        let m1 = PremiumPriceInfo()
        m1.months = 1
        m1.totalAmount = 499
        m1.currency = "USD"
        m1.currencySymbol = "$"
        m1.monthlyAmount = 499
        m1.prettyMonthlyPrice = "4.99"
        m1.prettyTotalPrice = "4.99"
        m1.formattedMonthlyPrice = "$4.99"
        m1.formattedTotalPrice = "$4.99"
        m1.discountPercent = 0
        m1.isBestValue = false
        m1.savingsBadge = ""
        list.add(m1)

        let m6 = PremiumPriceInfo()
        m6.months = 6
        m6.totalAmount = 2499
        m6.currency = "USD"
        m6.currencySymbol = "$"
        m6.monthlyAmount = 416
        m6.prettyMonthlyPrice = "4.16"
        m6.prettyTotalPrice = "24.99"
        m6.formattedMonthlyPrice = "$4.16"
        m6.formattedTotalPrice = "$24.99"
        m6.discountPercent = 17
        m6.isBestValue = false
        m6.savingsBadge = "Save 17%"
        list.add(m6)

        let m12 = PremiumPriceInfo()
        m12.months = 12
        m12.totalAmount = 3999
        m12.currency = "USD"
        m12.currencySymbol = "$"
        m12.monthlyAmount = 333
        m12.prettyMonthlyPrice = "3.33"
        m12.prettyTotalPrice = "39.99"
        m12.formattedMonthlyPrice = "$3.33"
        m12.formattedTotalPrice = "$39.99"
        m12.discountPercent = 33
        m12.isBestValue = true
        m12.savingsBadge = "Save 33%"
        list.add(m12)

        return Array<PremiumPriceInfo>(list.size, { i: Int64 => list[i] })
    }

    // ──────────────────────────────────────────────────────────────────────
    // P2-306: Confetti 粒子动画（内联版，避免跨 @Component 实例化问题）
    // ──────────────────────────────────────────────────────────────────────

    private func startConfetti(): Unit {
        if (this.confettiIsRunning) { return }
        this.cfParticles = this.cfCreateParticles()
        this.confettiIsRunning = true
        let _ = spawn {
            this.cfRunPhysicsLoop()
        }
        Hilog.info(0, "CjTelegram", "[PremiumSubscriptionFlowPage] confetti started ${this.cfParticles.size} particles")
    }

    private func cfCreateParticles(): Array<ConfettiViewParticle> {
        let list: Array<ConfettiViewParticle> = Array<ConfettiViewParticle>(150, { _i: Int64 => ConfettiViewParticle() })
        let colors: Array<UInt32> = [0xFF56CE6B, 0xFFCD89D0, 0xFF1E9AFF, 0xFFFF8724]
        let cw = this.cfCanvasWidth
        let ch = this.cfCanvasHeight
        var i: Int64 = 0
        while (i < 70) {
            let p = ConfettiViewParticle()
            p.x = Float64(i * 6 % Int64(cw))
            p.y = Float64(-Int64(ch) + i * 12 % Int64(ch))
            p.vx = Float64((i % 7) - 3) * 0.3
            p.vy = 3.0 + Float64(i % 5) * 0.4
            p.mass = 40.0 + Float64(i % 10) * 1.0
            p.angularVelocity = 1.0 + Float64(i % 6) * 0.8
            p.colorIndex = i % 4
            p.shapeType = i % 2
            p.sizeScale = 0.8 + Float64(i % 8) * 0.1
            p.colors = colors
            list[i] = p
            i += 1
        }
        let sideY = ch * 0.9
        let scaleFactor = 2400.0 * ch / 896.0
        i = 0
        while (i < 80) {
            let p = ConfettiViewParticle()
            let sideIndex: Int64 = i % 2
            let sideSign: Float64 = if (sideIndex == 0) { 1.0 } else { -1.0 }
            let baseX: Float64 = if (sideIndex == 0) { -20.0 } else { cw + 20.0 }
            let originAngle = Float64(i % 63) * 0.1
            let originAmplitude = Float64(i % 115)
            p.x = baseX + cvSinF64(originAngle) * originAmplitude
            p.y = sideY + cvCosF64(originAngle) * originAmplitude
            let speedBase = Float64(110 + i % 10)
            let velScale = (1.1 + Float64(i % 3) * 0.1) * scaleFactor / speedBase
            let vAngle = 1.5707963 + cvAtanF64(sideY / (cw * 0.8))
            let variation = Float64(i % 9) * 0.02 - 0.09
            let finalAngle = vAngle + variation
            p.vx = sideSign * velScale * cvSinF64(finalAngle)
            p.vy = velScale * cvCosF64(finalAngle)
            p.mass = speedBase
            p.angularVelocity = 1.0 + Float64(i % 5) * 0.7
            p.colorIndex = (i + 2) % 4
            p.shapeType = (i + 1) % 2
            p.sizeScale = 0.8 + Float64(i % 8) * 0.1
            p.colors = colors
            list[70 + i] = p
            i += 1
        }
        return list
    }

    private func cfRunPhysicsLoop(): Unit {
        let g: Float64 = 9.8
        let damping: Float64 = 0.93
        let maxY: Float64 = this.cfCanvasHeight + 30.0
        var localTime: Int64 = 0
        while (this.confettiIsRunning) {
            sleep(Duration.millisecond * 16)
            localTime += 1
            let turbIndex = localTime % 20
            var allBelowGround = true
            var k: Int64 = 0
            while (k < this.cfParticles.size) {
                let p = this.cfParticles[k]
                if (p.y < maxY) { allBelowGround = false }
                let dt: Float64 = 0.016
                p.x = p.x + p.vx * dt
                p.y = p.y + p.vy * dt
                p.rotationAngle = p.rotationAngle + p.angularVelocity * dt
                p.vy = p.vy + g * p.mass * dt
                if (p.vy < 0.0) {
                    p.vx = p.vx * damping
                    p.vy = p.vy * damping
                } else {
                    let turbulence = Float64((turbIndex + k) % 32) * 2.0 - 32.0
                    p.vx = p.vx + turbulence * dt
                }
                this.cfParticles[k] = p
                k += 1
            }
            let tc = localTime
            launch {
                this.confettiTickCount = tc
            }
            if (allBelowGround && localTime > 60) {
                launch {
                    this.confettiIsRunning = false
                    this.showConfetti = false
                    Hilog.info(0, "CjTelegram", "[PremiumSubscriptionFlowPage] confetti finished")
                }
                return
            }
        }
    }

    private func cfDrawParticles(): Unit {
        let ctx = this.cfContext
        ctx.clearRect(0.0, 0.0, this.cfCanvasWidth, this.cfCanvasHeight)
        var i: Int64 = 0
        while (i < this.cfParticles.size) {
            let p = this.cfParticles[i]
            if (p.y > this.cfCanvasHeight + 30.0 || p.y < -200.0) {
                i += 1
                continue
            }
            let colorIdx = p.colorIndex % 4
            let colorVal: UInt32 = p.colors[colorIdx]
            ctx.fillStyle = Int64(colorVal)
            ctx.save()
            ctx.translate(p.x, p.y)
            ctx.rotate(p.rotationAngle)
            let baseSize: Float64 = 8.0 * p.sizeScale
            if (p.shapeType == 0) {
                ctx.beginPath()
                ctx.arc(0.0, 0.0, baseSize * 0.5, 0.0, 6.28318, counterclockwise: false)
                ctx.fill()
            } else {
                let hw = baseSize * 0.125
                let hh = baseSize * 0.375
                ctx.fillRect(-hw, -hh, hw * 2.0, hh * 2.0)
            }
            ctx.restore()
            i += 1
        }
    }

    private func cfTickDesc(): String {
        return "cf_${this.confettiTickCount}"
    }

    @Builder
    func buildConfettiOverlay() {
        if (this.showConfetti) {
            Stack(alignContent: Alignment.TopStart) {
                Canvas(this.cfContext)
                    .width(100.percent)
                    .height(100.percent)
                    .onReady({
                        =>
                        this.cfDrawParticles()
                    })
                Text(this.cfTickDesc())
                    .width(0)
                    .height(0)
                    .opacity(0.0)
            }
            .width(100.percent)
            .height(100.percent)
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // End: Confetti
    // ──────────────────────────────────────────────────────────────────────

    private func onSubscribeClick(): Unit {
        if (this.isPurchasing) { return }
        this.isPurchasing = true
        this.purchaseError = ""
        this.purchaseSucceeded = false
        let _ = spawn {
            this.runPurchaseFlow()
        }
    }

    private func runPurchaseFlow(): Unit {
        let iapSvc = getInAppPurchaseManagerService()
        let purchasePurpose = InputStorePaymentPremiumSubscription()
        purchasePurpose.restore = false
        purchasePurpose.upgrade = false

        let canPurchase = iapSvc.canPurchaseStore(purchasePurpose)
        if (!canPurchase) {
            Hilog.info(0, "CjTelegram", "[PremiumSubscriptionFlowPage] canPurchaseStore returned false")
            launch {
                this.isPurchasing = false
                this.purchaseError = "Purchase eligibility check failed. Please try again."
            }
            return
        }
        Hilog.info(0, "CjTelegram", "[PremiumSubscriptionFlowPage] canPurchaseStore ok — requesting HarmonyOS IAP receipt")

        // Phase 3 反转：经 ArkTS @kit.IAPKit 拉真实购买凭证（异步）。
        this.requestIapReceipt({ receipt: String =>
            if (receipt.size == 0) {
                Hilog.info(0, "CjTelegram", "[PremiumSubscriptionFlowPage] IAP receipt unavailable (no AGC product / cancelled)")
                launch {
                    this.isPurchasing = false
                    this.purchaseError = "In-app purchase is not available: no Huawei IAP product is configured for this build (AppGallery Connect product id required). Please use a Telegram account purchased on another platform."
                    this.platformNote = "Note: HarmonyOS IAP requires an AppGallery Connect product id, not yet configured in this build."
                }
                return
            }
            let ok = getInAppPurchaseManagerService().sendAppStoreReceipt(iapReceiptBytes(receipt), "subscription")
            launch {
                this.isPurchasing = false
                if (ok) {
                    this.purchaseSucceeded = true
                    this.showConfetti = true
                    this.startConfetti()
                    Hilog.info(0, "CjTelegram", "[PremiumSubscriptionFlowPage] purchase succeeded")
                } else {
                    this.purchaseError = "Purchase failed. Please try again."
                    Hilog.info(0, "CjTelegram", "[PremiumSubscriptionFlowPage] sendAppStoreReceipt failed")
                }
            }
        })
    }

    /**
     * 请求华为 IAP 购买凭证 (receipt) — Phase 3 反转版。
     * 反转链路: callArkAsync(IAP_RECEIPT, {"productId":..,"productType":2}) → IapReceiptImpl.ets
     *   → iap.createPurchase(getContext(), ...) → CreatePurchaseResult.purchaseData（store receipt）。
     * productId 取自 store 产品目录（AGC 配置）；本 build 尚未接入产品目录时为空串，
     *   ArkTS 侧诚实返回 ok:false → 回调收到空 receipt（N-A），不伪造凭证。
     * onReceipt 收到非空 receipt 字符串表示购买成功；空串表示不可用。
     */
    private func requestIapReceipt(onReceipt: (String) -> Unit): Unit {
        // productType 2 = AUTORENEWABLE（Telegram Premium 为可续订订阅）。
        // productId：store 产品目录尚未接入本 build → 空串（ArkTS 侧据此返回 N-A）。
        let productId = this.iapProductIdForSelection()
        let argJson = "{\"productId\":\"${productId}\",\"productType\":2}"
        callArkAsync(IAP_RECEIPT, argJson, { res =>
            let ok = jsonBoolFieldPremium(res, "ok")
            let receipt = if (ok) { jsonStringFieldPremium(res, "receipt") } else { "" }
            Hilog.info(0, "CjTelegram", "[PremiumSubscriptionFlowPage] IAP_RECEIPT ArkTS ok=${ok} receiptLen=${receipt.size}")
            onReceipt(receipt)
        })
    }

    // store 产品目录（AGC 配置）尚未接入本 build → 返回空串，触发诚实 N-A。
    // 接入产品目录后，按 this.selectedOptionIndex → AGC productId 映射即可。
    private func iapProductIdForSelection(): String {
        return ""
    }

    private func onRestoreClick(): Unit {
        if (this.isRestoring) { return }
        this.isRestoring = true
        this.purchaseError = ""
        this.requestIapReceipt({ restoreReceipt: String =>
            if (restoreReceipt.size == 0) {
                launch {
                    this.isRestoring = false
                    this.purchaseError = "Restore is not available: HarmonyOS IAP receipt unavailable (see platform note above)."
                }
                return
            }
            let iapSvc = getInAppPurchaseManagerService()
            let ok = iapSvc.sendAppStoreReceipt(iapReceiptBytes(restoreReceipt), "restore")
            launch {
                this.isRestoring = false
                if (ok) {
                    this.purchaseSucceeded = true
                    this.showConfetti = true
                    this.startConfetti()
                    Hilog.info(0, "CjTelegram", "[PremiumSubscriptionFlowPage] restore succeeded")
                } else {
                    this.purchaseError = "Restore failed. No active subscription found."
                }
            }
        })
    }

    private func isPlanSelected(idx!: Int64): Bool {
        return idx == this.selectedOptionIndex
    }

    private func periodLabel(months!: Int32): String {
        if (months == 1) { return "1 Month" }
        if (months == 6) { return "6 Months" }
        if (months == 12) { return "12 Months" }
        return "${months} Months"
    }

    @Builder
    func buildHeader() {
        Column {
            Stack(alignContent: Alignment.Center) {
                Column { }
                    .width(100.percent)
                    .height(140)
                    .linearGradient(angle: 135.0, colors: [
                        (Color(0xFF7B2F8F), 0.0),
                        (Color(0xFF5856D6), 0.5),
                        (Color(0xFF54C7FC), 1.0)
                    ])
                Column {
                    Text(trSource(""))
                        .fontSize(44)
                        .margin(bottom: 6)
                    Text(trSource("Telegram Premium"))
                        .fontSize(22)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xFFFFFF)
                    Text("Unlock all features")
                        .fontSize(13)
                        .fontColor(0xCCFFFFFF)
                        .margin(top: 4)
                }
                .alignItems(HorizontalAlign.Center)
            }
            .width(100.percent)
            .height(140)
        }
        .width(100.percent)
    }

    @Builder
    func buildPriceRow(info!: PremiumPriceInfo, idx!: Int64) {
        Row {
            Column {
                Row {
                    Text(this.periodLabel(months: info.months))
                        .fontSize(15)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(if (this.isPlanSelected(idx: idx)) { 0x007AFF } else { 0x000000 })
                    if (info.isBestValue) {
                        Text(" Best Value")
                            .fontSize(12)
                            .fontColor(0x5856D6)
                            .fontWeight(FontWeight.Medium)
                    }
                }
                if (info.discountPercent > 0) {
                    Text("${info.formattedMonthlyPrice}/mo")
                        .fontSize(13)
                        .fontColor(0x3C3C43)
                        .margin(top: 2)
                }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Column {
                if (info.savingsBadge.size > 0 && info.discountPercent > 0) {
                    Text(info.savingsBadge)
                        .fontSize(11)
                        .fontColor(0xFFFFFF)
                        .backgroundColor(0x34C759)
                        .borderRadius(8)
                        .padding(left: 6, right: 6, top: 2, bottom: 2)
                        .margin(bottom: 2)
                }
                Text(info.formattedTotalPrice)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(if (this.isPlanSelected(idx: idx)) { 0x007AFF } else { 0x3C3C43 })
            }
            .alignItems(HorizontalAlign.End)

            if (this.isPlanSelected(idx: idx)) {
                Text(trSource(""))
                    .fontSize(18)
                    .fontColor(0x007AFF)
                    .margin(left: 8)
            } else {
                Text(trSource(""))
                    .fontSize(18)
                    .fontColor(0xC7C7CC)
                    .margin(left: 8)
            }
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 14, bottom: 14)
        .backgroundColor(if (this.isPlanSelected(idx: idx)) { 0xE8F0FE } else { 0xFFFFFF })
        .borderRadius(10)
        .margin(left: 16, right: 16, bottom: 8)
        .onClick({ _evt =>
            this.selectedOptionIndex = idx
        })
    }

    @Builder
    func buildPriceSection() {
        Column {
            Text("Choose a plan")
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor(0x000000)
                .width(100.percent)
                .padding(left: 16, right: 16, top: 20, bottom: 12)

            if (this.isLoadingPrices) {
                Text("Loading prices from Telegram servers...")
                    .fontSize(14)
                    .fontColor(0x8E8E93)
                    .width(100.percent)
                    .textAlign(TextAlign.Center)
                    .padding(top: 20, bottom: 20)
            } else {
                ForEach(this.priceInfoList, itemGenerator: { info: PremiumPriceInfo, idx: Int64 =>
                    this.buildPriceRow(info: info, idx: idx)
                })
            }
        }
        .width(100.percent)
        .backgroundColor(0xF2F2F7)
    }

    @Builder
    func buildActionSection() {
        Column {
            if (this.purchaseSucceeded) {
                Text("Welcome to Telegram Premium!")
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x34C759)
                    .width(100.percent)
                    .textAlign(TextAlign.Center)
                    .padding(top: 16, bottom: 16)
            } else {
                Text(if (this.isPurchasing) { "Processing..." } else { "Subscribe to Telegram Premium" })
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0xFFFFFF)
                    .width(100.percent)
                    .height(50)
                    .textAlign(TextAlign.Center)
                    .backgroundColor(if (this.isPurchasing) { 0xAAAAAA } else { 0x5856D6 })
                    .borderRadius(10)
                    .margin(top: 16, left: 16, right: 16)
                    .onClick({ _evt =>
                        this.onSubscribeClick()
                    })
            }

            if (this.purchaseError.size > 0) {
                Text(this.purchaseError)
                    .fontSize(13)
                    .fontColor(0xFF3B30)
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 8, bottom: 4)
            }

            if (this.platformNote.size > 0) {
                Text(this.platformNote)
                    .fontSize(12)
                    .fontColor(0x8E8E93)
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 4, bottom: 4)
            }

            Text(if (this.isRestoring) { "Restoring..." } else { "Restore purchases" })
                .fontSize(15)
                .fontColor(0x007AFF)
                .width(100.percent)
                .height(44)
                .textAlign(TextAlign.Center)
                .margin(top: 4, bottom: 8)
                .onClick({ _evt =>
                    this.onRestoreClick()
                })

            Row {
                Text(trSource("Terms of Service"))
                    .fontSize(13)
                    .fontColor(0x007AFF)
                    .onClick({ _evt =>
                        routerPush("PremiumTermsPage", "terms")
                    })
                Text(" · ")
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                Text(trSource("Privacy Policy"))
                    .fontSize(13)
                    .fontColor(0x007AFF)
                    .onClick({ _evt =>
                        routerPush("PremiumTermsPage", "privacy")
                    })
            }
            .width(100.percent)
            .justifyContent(FlexAlign.Center)
            .margin(bottom: 32)
        }
        .width(100.percent)
    }

    public func build() {
        Stack(alignContent: Alignment.TopStart) {
            Column {
                Scroll {
                    Column {
                        this.buildHeader()
                        this.buildPriceSection()
                        this.buildActionSection()
                    }
                    .width(100.percent)
                }
                .layoutWeight(1)
                .scrollBar(BarState.Off)
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xF2F2F7)

            this.buildConfettiOverlay()
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ => this.ensureLoaded() })
    }
}
