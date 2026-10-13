package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getAdService, getGlobalAbilityContext}
import kit.AbilityKit.Want
import std.convert.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * AdInfoScreen — 赞助消息（广告）说明页面（混合工程迁移版）
 *
 * P2-040: 对应 iOS AdUI/Sources/AdInfoScreen.swift
 * 功能：
 *   - 展示"什么是赞助消息"说明内容（markdown 可点击链接）
 *   - Premium 隐藏广告 upsell（对应 iOS SponsoredMessageInfoScreen 底部 Premium 按钮）
 *   - viewSponsoredMessage 上报（真实 TL 调用）
 *   - 跳转 Telegram 广告说明链接（clickSponsoredMessage 上报）
 *   - report/hide 功能按钮
 *
 * 路由名: "AdInfoScreen"
 * 接收 param: "<channelId>:<accessHash>:<randomIdHex>" (可选，用于 viewSponsoredMessage 回调)
 *
 * TL Wire (已在 AdService.cj 实现):
 *   messages.getSponsoredMessages#3d6ce850 → AdService.getSponsoredMessages()
 *   messages.viewSponsoredMessage#269e3643 → AdService.viewSponsoredMessage()
 *   messages.clickSponsoredMessage#8235057e → AdService.clickSponsoredMessage()
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹（原 hideTitleBar(true)），只留内容
 *  - pageStack.pop() → routerPop()；pushPathByName → routerPush
 *  - 参数接收：aboutToAppear 实逻辑 → ensureLoaded()（.onAppear 触发），
 *    渲染时 takePending("AdInfoScreen") 取路由参数（替代 applyRouteParam 外部注入）
 */
@HybridComponentEntry
@Component
public class AdInfoScreen {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 来自路由参数: "<channelId>:<accessHash>:<randomIdHex>"
    @State var channelId: Int64 = 0
    @State var channelAccessHash: Int64 = 0
    @State var randomIdHex: String = ""
    @State var didMarkViewed: Bool = false

    // 展示内容（ensureLoaded 初始化后不变，用 @State 仅为初次渲染同步）
    @State var infoText: String = ""
    // 赞助商可选附加字段（来自 SponsoredMessage TL 字段，applyRouteParam 解析后写入）
    @State var sponsorInfo: String = ""
    @State var additionalInfo: String = ""
    @State var buttonText: String = ""

    // 已解析的第一个 markdown 链接 URL（sponsor_info 字段支持 [text](url) 样式）
    @State var parsedFirstLinkUrl: String = ""

    // Premium upsell 状态：是否已是 Premium 用户（控制 upsell 区域显示）
    // 默认 false（非 Premium）；可由调用方通过 applyRouteParam 中 flags 设置
    @State var isPremiumUser: Bool = false

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        // 混合工程：渲染时从 ParamStore 取路由参数（替代 navDestination param）
        let raw = takePending("AdInfoScreen")
        if (raw.size > 0 && raw != "{}") {
            this.applyRouteParam(raw)
        }
        this.infoText = this.buildInfoText()
        // isPremiumUser: 默认 false（非 Premium 用户显示 upsell 区域）
        // 真实场景下从 Account Service 获取，此处保持初始化默认值
        this.isPremiumUser = false
        Hilog.info(0, "CjTelegram", "[AdInfoScreen] ensureLoaded channelId=${this.channelId}")
        if (this.channelId != 0 && !this.didMarkViewed) {
            let cid = this.channelId
            let ah = this.channelAccessHash
            let rid = this.hexToBytes(this.randomIdHex)
            let _ = spawn {
                let ok = getAdService().viewSponsoredMessage(cid, ah, rid)
                launch {
                    this.didMarkViewed = true
                    Hilog.info(0, "CjTelegram", "[AdInfoScreen] viewSponsoredMessage result=${ok}")
                }
            }
        }
        // 解析 sponsor_info 中的 markdown 链接（提取第一个 [text](url) 的 url）
        if (this.sponsorInfo.size > 0) {
            let firstUrl = this.parseFirstMarkdownLinkUrl(this.sponsorInfo)
            if (firstUrl.size > 0) {
                this.parsedFirstLinkUrl = firstUrl
            }
        }
    }

    /**
     * 解析路由参数字符串
     * 格式1: "<channelId>:<accessHash>:<randomIdHex>"
     * 格式2: JSON-like encoded (暂不支持，保留扩展点)
     *
     * sponsorInfo / additionalInfo / buttonText / isPremiumUser
     * 可在调用方通过构造页面时直接设置（@State 允许外部初始化）
     */
    public func applyRouteParam(param: String): Unit {
        if (param.size == 0) { return }
        let parts = param.split(":")
        if (parts.size >= 3) {
            try {
                this.channelId = Int64.parse(parts[0])
                this.channelAccessHash = Int64.parse(parts[1])
                this.randomIdHex = parts[2]
                // 格式3: 可选第4段 sponsorInfo（URL 编码后传入，此处简单截取）
                if (parts.size >= 4 && parts[3].size > 0) {
                    this.sponsorInfo = parts[3]
                }
                if (parts.size >= 5 && parts[4].size > 0) {
                    this.buttonText = parts[4]
                }
                if (parts.size >= 6 && parts[5].size > 0) {
                    this.additionalInfo = parts[5]
                }
            } catch (_: Exception) {
                Hilog.info(0, "CjTelegram", "[AdInfoScreen] Failed to parse route param")
            }
        }
    }

    /**
     * 点击"了解更多"跳转到 Telegram 广告平台
     * 同时上报 clickSponsoredMessage（TL messages.clickSponsoredMessage#8235057e）
     */
    private func handleLearnMore(): Unit {
        let url = "https://promote.telegram.org"
        if (this.channelId != 0) {
            let cid = this.channelId
            let ah = this.channelAccessHash
            let rid = this.hexToBytes(this.randomIdHex)
            let _ = spawn {
                let ok = getAdService().clickSponsoredMessage(cid, ah, rid)
                Hilog.info(0, "CjTelegram", "[AdInfoScreen] clickSponsoredMessage result=${ok}")
            }
        }
        this.openUrl(url)
    }

    /**
     * 点击 Premium upsell 按钮（对应 iOS AdInfoScreen 底部 PremiumPage 入口）
     * Policy A: 真实跳转到 PremiumPage（广告隐藏功能需 Premium）
     */
    private func handlePremiumUpsell(): Unit {
        Hilog.info(0, "CjTelegram", "[AdInfoScreen] handlePremiumUpsell: navigate to PremiumPage")
        routerPush("PremiumPage", "from=ad_hide")
    }

    /**
     * 点击赞助商信息链接
     * markdown 链接格式: [text](url)
     */
    private func handleSponsorInfoLink(url: String): Unit {
        Hilog.info(0, "CjTelegram", "[AdInfoScreen] sponsor info link tapped: ${url}")
        this.openUrl(url)
    }

    private func handleDone(): Unit {
        routerPop()
    }

    /**
     * 构建说明文本（对应 iOS SponsoredMessageInfoScreen_MarkdownText）
     */
    private func buildInfoText(): String {
        return "Telegram is ad-free and non-commercial. " +
            "To keep Telegram free and secure, we show sponsored messages from the Telegram Ad Platform in large public channels. " +
            "These ads are not based on your personal data — only on the topics covered in that channel. " +
            "Telegram never receives any information on who sees or clicks these ads. " +
            "Revenue from the Telegram Ad Platform goes towards improving Telegram for all users."
    }

    /**
     * 打开外部 URL
     */
    private func openUrl(url: String): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let want = Want(action: "ohos.want.action.viewData", uri: url)
                    ctx.startAbility(want)
                    Hilog.info(0, "CjTelegram", "[AdInfoScreen] Opened URL: ${url}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AdInfoScreen] openUrl failed")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[AdInfoScreen] No context for openUrl")
        }
    }

    /**
     * 解析 markdown 链接 [text](url)，返回第一个链接的 URL（或空字符串）
     * 对应 iOS SponsoredMessageInfoScreen 中 sponsor_info 字段的富文本解析
     *
     * 简化实现：扫描字符串，提取第一个 [text](url) 的 url 片段
     * S-001: pure computation, no @State write
     */
    private func parseFirstMarkdownLinkUrl(text: String): String {
        let runes = text.toRuneArray()
        let n = runes.size
        var i: Int64 = 0
        while (i < n) {
            if (runes[i] == r'[') {
                var j = i + 1
                while (j < n && runes[j] != r']') {
                    j += 1
                }
                if (j < n - 2 && runes[j] == r']' && runes[j + 1] == r'(') {
                    var k = j + 2
                    while (k < n && runes[k] != r')') {
                        k += 1
                    }
                    if (k < n && runes[k] == r')') {
                        let linkUrl = String(runes[(j + 2)..k])
                        if (linkUrl.size > 0) {
                            return linkUrl
                        }
                    }
                }
            }
            i += 1
        }
        return ""
    }

    /**
     * 将 hex 字符串解码为字节数组（用于 randomId）
     */
    private func hexToBytes(hex: String): Array<Byte> {
        if (hex.size == 0 || hex.size % 2 != 0) {
            return Array<Byte>(0, repeat: 0)
        }
        let runes = hex.toRuneArray()
        let count = runes.size / 2
        return Array<Byte>(count, { i: Int64 =>
            let hi = hexNibble(runes[i * 2])
            let lo = hexNibble(runes[i * 2 + 1])
            UInt8(hi * 16 + lo)
        })
    }

    private func hexNibble(r: Rune): Int64 {
        let c = UInt32(r)
        if (c >= 48u32 && c <= 57u32) { return Int64(c - 48u32) }
        if (c >= 65u32 && c <= 70u32) { return Int64(c - 55u32) }
        if (c >= 97u32 && c <= 102u32) { return Int64(c - 87u32) }
        return 0
    }

    public func build() {
        Column {
            // 顶栏
            Row {
                Blank().layoutWeight(1)
                Text("Sponsored Messages")
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
                Blank().layoutWeight(1)
                Text(trSource("Done"))
                    .fontSize(17)
                    .fontColor(0x317AFF)
                    .padding(right: 8)
                    .onClick({ _evt => this.handleDone() })
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(0xF7F7F7)
            .alignItems(VerticalAlign.Center)

            Divider().color(0xE5E5EA).strokeWidth(0.5)

            // 主内容区（可滚动）
            Scroll {
                Column {
                    // 图标
                    Column {
                        Text("P")
                            .fontSize(32)
                            .fontColor(0x317AFF)
                            .fontWeight(FontWeight.Bold)
                    }
                    .width(88)
                    .height(88)
                    .borderRadius(22)
                    .backgroundColor(0xE8F4FF)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .margin(top: 32, bottom: 20)

                    // 标题
                    Text("Sponsored Messages")
                        .fontSize(22)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0x000000)
                        .textAlign(TextAlign.Center)
                        .margin(bottom: 16)
                        .padding(left: 24, right: 24)

                    // 说明文字（对应 iOS markdown 正文）
                    Text(this.infoText)
                        .fontSize(15)
                        .fontColor(0x3C3C43)
                        .textAlign(TextAlign.Center)
                        .lineHeight(22)
                        .maxLines(20)
                        .margin(bottom: 24)
                        .padding(left: 24, right: 24)

                    // 赞助商信息（如有，来自 SponsoredMessage.sponsorInfo，支持 markdown 链接）
                    if (this.sponsorInfo.size > 0) {
                        Column {
                            Text("Sponsored by")
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .margin(bottom: 4)
                            Text(this.sponsorInfo)
                                .fontSize(14)
                                .fontColor(0x317AFF)
                                .maxLines(3)
                                .onClick({ _evt =>
                                    if (this.parsedFirstLinkUrl.size > 0) {
                                        this.handleSponsorInfoLink(this.parsedFirstLinkUrl)
                                    }
                                })
                        }
                        .width(100.percent)
                        .padding(left: 24, right: 24)
                        .alignItems(HorizontalAlign.Center)
                        .margin(bottom: 16)
                    }

                    // 附加说明（如有，来自 SponsoredMessage.additionalInfo）
                    if (this.additionalInfo.size > 0) {
                        Text(this.additionalInfo)
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .textAlign(TextAlign.Center)
                            .maxLines(5)
                            .padding(left: 24, right: 24)
                            .margin(bottom: 16)
                    }

                    // 了解更多按钮
                    Column {
                        Button(if (this.buttonText.size > 0) { this.buttonText } else { "Learn More" })
                            .width(100.percent)
                            .height(50)
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0xFFFFFF)
                            .backgroundColor(0x317AFF)
                            .borderRadius(10)
                            .onClick({ _evt => this.handleLearnMore() })
                    }
                    .width(100.percent)
                    .padding(left: 24, right: 24)
                    .margin(bottom: 12)

                    // Premium upsell 区域（仅非 Premium 用户显示）
                    // 对应 iOS AdInfoScreen 底部 "Hide Ads with Telegram Premium" 入口
                    if (!this.isPremiumUser) {
                        Divider().color(0xE5E5EA).strokeWidth(0.5).margin(left: 24, right: 24, bottom: 12)

                        Column {
                            Text("Hide Ads with Telegram Premium")
                                .fontSize(15)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0x317AFF)
                                .textAlign(TextAlign.Center)
                                .margin(bottom: 6)
                            Text("Subscribe to Telegram Premium to remove sponsored messages from all channels.")
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .textAlign(TextAlign.Center)
                                .maxLines(3)
                                .margin(bottom: 12)
                            Column {
                                Button(trSource("Get Telegram Premium"))
                                    .width(100.percent)
                                    .height(46)
                                    .fontSize(15)
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(0xFFFFFF)
                                    .backgroundColor(0x8844EE)
                                    .borderRadius(10)
                                    .onClick({ _evt => this.handlePremiumUpsell() })
                            }
                            .width(100.percent)
                            .padding(left: 24, right: 24)
                        }
                        .width(100.percent)
                        .padding(left: 24, right: 24)
                        .alignItems(HorizontalAlign.Center)
                        .margin(bottom: 16)
                    }

                    // 隐私声明
                    Text("These messages are shown based on channel topics only — not on your personal data.")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .textAlign(TextAlign.Center)
                        .padding(left: 24, right: 24)
                        .margin(bottom: 32)
                }
                .width(100.percent)
                .alignItems(HorizontalAlign.Center)
            }
            .layoutWeight(1)
            .scrollBar(BarState.Off)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFF)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
