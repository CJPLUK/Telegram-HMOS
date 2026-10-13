package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * P2-307: Premium 隐私/条款展示屏（混合工程迁移版）
 *
 * iOS 参考: submodules/PremiumUI/Sources/PremiumPrivacyScreen.swift
 *           (PremiumPrivacyScreen.Subject: .presence / .readTime)
 *           + Telegram Premium ToS / Privacy Policy inline text
 *
 * 本页展示:
 *   1. Telegram Premium 服务条款 (Terms of Service)
 *   2. 隐私政策摘要 (Privacy Policy summary)
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹 + .title/.hideTitleBar/.onReady，只留内容
 *  - onReady 参数解析 → ensureLoaded() 里 takePending("PremiumTermsPage") + .onAppear
 *
 * param: "terms" | "privacy" (默认 "terms")
 */
@HybridComponentEntry
@Component
public class PremiumTermsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var activeTab: String = "terms"
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let param = takePending("PremiumTermsPage")
        this.activeTab = if (param == "privacy") { "privacy" } else { "terms" }
    }

    private func isTerms(): Bool {
        return this.activeTab == "terms"
    }

    @Builder
    func buildTabBar() {
        Row {
            Column {
                Text(trSource("Terms of Service"))
                    .fontSize(15)
                    .fontWeight(if (this.isTerms()) { FontWeight.Bold } else { FontWeight.Regular })
                    .fontColor(if (this.isTerms()) { 0x007AFF } else { 0x8E8E93 })
                    .textAlign(TextAlign.Center)
                    .padding(top: 10, bottom: 10)

                Divider()
                    .color(if (this.isTerms()) { 0x007AFF } else { Color.Transparent })
                    .strokeWidth(2)
            }
            .layoutWeight(1)
            .onClick({ evt =>
                this.activeTab = "terms"
            })

            Column {
                Text(trSource("Privacy Policy"))
                    .fontSize(15)
                    .fontWeight(if (this.isTerms()) { FontWeight.Regular } else { FontWeight.Bold })
                    .fontColor(if (this.isTerms()) { 0x8E8E93 } else { 0x007AFF })
                    .textAlign(TextAlign.Center)
                    .padding(top: 10, bottom: 10)

                Divider()
                    .color(if (this.isTerms()) { Color.Transparent } else { 0x007AFF })
                    .strokeWidth(2)
            }
            .layoutWeight(1)
            .onClick({ evt =>
                this.activeTab = "privacy"
            })
        }
        .width(100.percent)
        .backgroundColor(0xFFFFFF)

        Divider()
            .color(0xE5E5EA)
            .strokeWidth(1)
    }

    @Builder
    func buildTermsContent() {
        Column {
            Text("Telegram Premium — Terms of Service")
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor(0x000000)
                .width(100.percent)
                .padding(left: 16, right: 16, top: 16, bottom: 8)

            Text("Last updated: January 1, 2024")
                .fontSize(13)
                .fontColor(0x8E8E93)
                .width(100.percent)
                .padding(left: 16, right: 16, bottom: 16)

            Text("1. Subscription")
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(0x000000)
                .width(100.percent)
                .padding(left: 16, right: 16, top: 8, bottom: 4)

            Text("Telegram Premium is a subscription service that provides access to exclusive features. By subscribing, you agree to pay the applicable subscription fee for the selected plan (monthly, 6-month, or annual).")
                .fontSize(14)
                .fontColor(0x3C3C43)
                .width(100.percent)
                .padding(left: 16, right: 16, bottom: 12)

            Text("2. Billing & Renewal")
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(0x000000)
                .width(100.percent)
                .padding(left: 16, right: 16, top: 8, bottom: 4)

            Text("Subscriptions automatically renew at the end of each billing period unless cancelled at least 24 hours before the renewal date. Your payment account will be charged within 24 hours prior to the end of the current period.")
                .fontSize(14)
                .fontColor(0x3C3C43)
                .width(100.percent)
                .padding(left: 16, right: 16, bottom: 12)

            Text("3. Cancellation")
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(0x000000)
                .width(100.percent)
                .padding(left: 16, right: 16, top: 8, bottom: 4)

            Text("You may cancel your Telegram Premium subscription at any time. Upon cancellation, you retain access to Premium features until the end of the current billing period. No refunds are provided for partial periods.")
                .fontSize(14)
                .fontColor(0x3C3C43)
                .width(100.percent)
                .padding(left: 16, right: 16, bottom: 12)

            Text("4. Features")
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(0x000000)
                .width(100.percent)
                .padding(left: 16, right: 16, top: 8, bottom: 4)

            Text("Premium features include, but are not limited to: increased upload sizes (4 GB), faster downloads, voice-to-text transcription, no ads, unique reactions, premium stickers, animated profile photos, custom app icons, emoji status, real-time translation, and more. Telegram reserves the right to modify Premium features with reasonable notice.")
                .fontSize(14)
                .fontColor(0x3C3C43)
                .width(100.percent)
                .padding(left: 16, right: 16, bottom: 12)

            Text("5. Gifts & Transfers")
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(0x000000)
                .width(100.percent)
                .padding(left: 16, right: 16, top: 8, bottom: 4)

            Text("Premium subscriptions gifted to other users are non-refundable and non-transferable once activated. Gift codes may not be resold.")
                .fontSize(14)
                .fontColor(0x3C3C43)
                .width(100.percent)
                .padding(left: 16, right: 16, bottom: 12)

            Text("6. Governing Terms")
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(0x000000)
                .width(100.percent)
                .padding(left: 16, right: 16, top: 8, bottom: 4)

            Text("This subscription is subject to the Telegram Terms of Service (https://telegram.org/tos) and Privacy Policy (https://telegram.org/privacy). In the event of conflict, the Telegram Terms of Service shall prevail.")
                .fontSize(14)
                .fontColor(0x3C3C43)
                .width(100.percent)
                .padding(left: 16, right: 16, bottom: 12)

            Text("7. Contact")
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(0x000000)
                .width(100.percent)
                .padding(left: 16, right: 16, top: 8, bottom: 4)

            Text("For support with Telegram Premium, contact @PremiumBot or visit https://telegram.org/faq_premium")
                .fontSize(14)
                .fontColor(0x3C3C43)
                .width(100.percent)
                .padding(left: 16, right: 16, bottom: 32)

            Text("Full Terms of Service: telegram.org/tos")
                .fontSize(13)
                .fontColor(0x007AFF)
                .width(100.percent)
                .textAlign(TextAlign.Center)
                .padding(left: 16, right: 16, bottom: 24)
                .onClick({ evt =>
                    Hilog.info(0, "CjTelegram", "[PremiumTermsPage] Open ToS URL: https://telegram.org/tos")
                })
        }
        .width(100.percent)
    }

    @Builder
    func buildPrivacyContent() {
        Column {
            Text("Telegram Privacy Policy")
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor(0x000000)
                .width(100.percent)
                .padding(left: 16, right: 16, top: 16, bottom: 8)

            Text("Last updated: January 1, 2024")
                .fontSize(13)
                .fontColor(0x8E8E93)
                .width(100.percent)
                .padding(left: 16, right: 16, bottom: 16)

            Text("1. Data We Collect")
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(0x000000)
                .width(100.percent)
                .padding(left: 16, right: 16, top: 8, bottom: 4)

            Text("Telegram collects minimal data necessary to provide the service. For Telegram Premium subscribers, we collect: subscription status, billing information (processed by the payment provider), and feature usage to provide Premium services.")
                .fontSize(14)
                .fontColor(0x3C3C43)
                .width(100.percent)
                .padding(left: 16, right: 16, bottom: 12)

            Text("2. What We Don't Collect")
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(0x000000)
                .width(100.percent)
                .padding(left: 16, right: 16, top: 8, bottom: 4)

            Text("Telegram does NOT read your messages. Secret Chats use end-to-end encryption and Telegram has no access to their contents. We do not sell your data to third parties.")
                .fontSize(14)
                .fontColor(0x3C3C43)
                .width(100.percent)
                .padding(left: 16, right: 16, bottom: 12)

            Text("3. Premium Data Processing")
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(0x000000)
                .width(100.percent)
                .padding(left: 16, right: 16, top: 8, bottom: 4)

            Text("When you subscribe to Telegram Premium, your subscription status is stored on Telegram servers to enable Premium features. Payment processing is handled by our payment partners (e.g., App Store, Google Play, Huawei AppGallery). Telegram does not store your full payment details.")
                .fontSize(14)
                .fontColor(0x3C3C43)
                .width(100.percent)
                .padding(left: 16, right: 16, bottom: 12)

            Text("4. Voice-to-Text")
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(0x000000)
                .width(100.percent)
                .padding(left: 16, right: 16, top: 8, bottom: 4)

            Text("Voice-to-Text transcriptions are processed on Telegram servers. The voice message content is transmitted for transcription and is not stored beyond the duration needed to provide the transcription.")
                .fontSize(14)
                .fontColor(0x3C3C43)
                .width(100.percent)
                .padding(left: 16, right: 16, bottom: 12)

            Text("5. Your Rights")
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(0x000000)
                .width(100.percent)
                .padding(left: 16, right: 16, top: 8, bottom: 4)

            Text("You can delete your Telegram account and all associated data at any time through Settings → Delete Account. Upon deletion, all data including Premium subscription records are permanently removed from Telegram servers.")
                .fontSize(14)
                .fontColor(0x3C3C43)
                .width(100.percent)
                .padding(left: 16, right: 16, bottom: 12)

            Text("6. Contact")
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(0x000000)
                .width(100.percent)
                .padding(left: 16, right: 16, top: 8, bottom: 4)

            Text("For privacy-related inquiries, contact @GDPRBot or visit https://telegram.org/privacy")
                .fontSize(14)
                .fontColor(0x3C3C43)
                .width(100.percent)
                .padding(left: 16, right: 16, bottom: 32)

            Text("Full Privacy Policy: telegram.org/privacy")
                .fontSize(13)
                .fontColor(0x007AFF)
                .width(100.percent)
                .textAlign(TextAlign.Center)
                .padding(left: 16, right: 16, bottom: 24)
                .onClick({ evt =>
                    Hilog.info(0, "CjTelegram", "[PremiumTermsPage] Open Privacy Policy URL: https://telegram.org/privacy")
                })
        }
        .width(100.percent)
    }

    public func build() {
        Column {
            this.buildTabBar()

            Scroll {
                Column {
                    if (this.isTerms()) {
                        this.buildTermsContent()
                    } else {
                        this.buildPrivacyContent()
                    }
                }
                .width(100.percent)
            }
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .backgroundColor(0xF2F2F7)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
