package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * P2-305 Premium Limit Upsell 页面（混合工程迁移版）
 *
 * 对应 iOS PremiumUI/PremiumLimitScreen.swift
 *
 * 功能:
 *   - 展示 Free vs Premium 上限对比（进度条 + 数值）
 *   - 覆盖 11 类 double_limit 类型（folders/chatsPerFolder/pins/pinnedSavedPeers/files/
 *     accounts/linksPerSharedFolder/membershipInSharedFolders/channels/
 *     expiringStories/multiStories）
 *   - Upgrade 按钮 → 跳转 PremiumPage
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹 + .title/.hideTitleBar/.onReady，只留内容
 *  - pushPathByName → routerPush；pop(animated:true) → routerPop()
 *  - aboutToAppear + onReady 参数解析 → ensureLoaded() 里 takePending("PremiumLimitUpsellPage") + .onAppear
 */

// ---------------------------------------------------------------------------
// 数据模型 — 11 类 limit 类型
// ---------------------------------------------------------------------------

/**
 * Premium Limit 类型枚举（对应 iOS PremiumLimitScreen.Subject）
 */
public enum PremiumLimitType {
    | Folders
    | ChatsPerFolder
    | Pins
    | PinnedSavedPeers
    | Files
    | Accounts
    | LinksPerSharedFolder
    | MembershipInSharedFolders
    | Channels
    | ExpiringStories
    | MultiStories
    | Unknown

    public func ordinal(): Int32 {
        match (this) {
            case Folders => 0
            case ChatsPerFolder => 1
            case Pins => 2
            case PinnedSavedPeers => 3
            case Files => 4
            case Accounts => 5
            case LinksPerSharedFolder => 6
            case MembershipInSharedFolders => 7
            case Channels => 8
            case ExpiringStories => 9
            case MultiStories => 10
            case Unknown => 11
        }
    }

    public operator func ==(right: PremiumLimitType): Bool {
        return this.ordinal() == right.ordinal()
    }

    public operator func !=(right: PremiumLimitType): Bool {
        return this.ordinal() != right.ordinal()
    }
}

public func premiumLimitTypeFromIdentifier(id!: String): PremiumLimitType {
    if (id == "folders") { return PremiumLimitType.Folders }
    if (id == "chats_per_folder") { return PremiumLimitType.ChatsPerFolder }
    if (id == "pins") { return PremiumLimitType.Pins }
    if (id == "pinned_saved_peers") { return PremiumLimitType.PinnedSavedPeers }
    if (id == "files") { return PremiumLimitType.Files }
    if (id == "accounts") { return PremiumLimitType.Accounts }
    if (id == "links_per_folder") { return PremiumLimitType.LinksPerSharedFolder }
    if (id == "folder_membership") { return PremiumLimitType.MembershipInSharedFolders }
    if (id == "channels") { return PremiumLimitType.Channels }
    if (id == "expiring_stories") { return PremiumLimitType.ExpiringStories }
    if (id == "multi_stories") { return PremiumLimitType.MultiStories }
    return PremiumLimitType.Unknown
}

/**
 * Limit 类型配置（free/premium 上限值 + 文案）
 *
 * 数值参考 iOS UserLimits.defaultValue / EngineConfiguration.UserLimits.defaultValue:
 *   folders: free=10, premium=20
 *   chats_per_folder: free=100, premium=200
 *   pins: free=5, premium=10
 *   pinned_saved_peers: free=5, premium=10
 *   files: free=2 GB, premium=4 GB（展示字符串）
 *   accounts: free=3, premium=4
 *   links_per_folder: free=3, premium=20
 *   folder_membership: free=2, premium=10
 *   channels: free=500, premium=1000
 *   expiring_stories: free=3, premium=100（active per day）
 *   multi_stories: free=3, premium=100
 */
public class PremiumLimitConfig {
    public var limitType: PremiumLimitType
    public var title: String
    public var description: String
    public var icon: String
    public var freeLimitLabel: String
    public var premiumLimitLabel: String
    public var freeNumeric: Float64
    public var premiumNumeric: Float64

    public init(
        limitType!: PremiumLimitType,
        title!: String,
        description!: String,
        icon!: String,
        freeLimitLabel!: String,
        premiumLimitLabel!: String,
        freeNumeric!: Float64,
        premiumNumeric!: Float64
    ) {
        this.limitType = limitType
        this.title = title
        this.description = description
        this.icon = icon
        this.freeLimitLabel = freeLimitLabel
        this.premiumLimitLabel = premiumLimitLabel
        this.freeNumeric = freeNumeric
        this.premiumNumeric = premiumNumeric
    }
}

public func getPremiumLimitConfig(limitType!: PremiumLimitType): PremiumLimitConfig {
    match (limitType) {
        case PremiumLimitType.Folders =>
            PremiumLimitConfig(
                limitType: limitType,
                title: "Limit Reached",
                description: "You have reached the limit for chat folders. Upgrade to Premium to create up to 20 folders.",
                icon: "📁",
                freeLimitLabel: "10",
                premiumLimitLabel: "20",
                freeNumeric: 10.0,
                premiumNumeric: 20.0
            )
        case PremiumLimitType.ChatsPerFolder =>
            PremiumLimitConfig(
                limitType: limitType,
                title: "Limit Reached",
                description: "You have too many chats in this folder. Premium allows up to 200 chats per folder.",
                icon: "💬",
                freeLimitLabel: "100",
                premiumLimitLabel: "200",
                freeNumeric: 100.0,
                premiumNumeric: 200.0
            )
        case PremiumLimitType.Pins =>
            PremiumLimitConfig(
                limitType: limitType,
                title: "Too Many Pinned Chats",
                description: "You have reached the limit for pinned chats. Premium allows up to 10 pinned chats.",
                icon: "📌",
                freeLimitLabel: "5",
                premiumLimitLabel: "10",
                freeNumeric: 5.0,
                premiumNumeric: 10.0
            )
        case PremiumLimitType.PinnedSavedPeers =>
            PremiumLimitConfig(
                limitType: limitType,
                title: "Too Many Pinned Saved Messages",
                description: "You have reached the limit for pinned chats in Saved Messages. Premium allows up to 10.",
                icon: "📌",
                freeLimitLabel: "5",
                premiumLimitLabel: "10",
                freeNumeric: 5.0,
                premiumNumeric: 10.0
            )
        case PremiumLimitType.Files =>
            PremiumLimitConfig(
                limitType: limitType,
                title: "File Too Large",
                description: "This file exceeds the 2 GB limit. With Premium you can share files up to 4 GB.",
                icon: "📄",
                freeLimitLabel: "2 GB",
                premiumLimitLabel: "4 GB",
                freeNumeric: 2.0,
                premiumNumeric: 4.0
            )
        case PremiumLimitType.Accounts =>
            PremiumLimitConfig(
                limitType: limitType,
                title: "Too Many Accounts",
                description: "You have reached the limit of 3 accounts. Premium allows you to add one more account.",
                icon: "👤",
                freeLimitLabel: "3",
                premiumLimitLabel: "4",
                freeNumeric: 3.0,
                premiumNumeric: 4.0
            )
        case PremiumLimitType.LinksPerSharedFolder =>
            PremiumLimitConfig(
                limitType: limitType,
                title: "Limit Reached",
                description: "You have reached the limit for invite links in shared folders. Premium allows up to 20.",
                icon: "🔗",
                freeLimitLabel: "3",
                premiumLimitLabel: "20",
                freeNumeric: 3.0,
                premiumNumeric: 20.0
            )
        case PremiumLimitType.MembershipInSharedFolders =>
            PremiumLimitConfig(
                limitType: limitType,
                title: "Limit Reached",
                description: "You have reached the limit for shared folder memberships. Premium allows up to 10.",
                icon: "📂",
                freeLimitLabel: "2",
                premiumLimitLabel: "10",
                freeNumeric: 2.0,
                premiumNumeric: 10.0
            )
        case PremiumLimitType.Channels =>
            PremiumLimitConfig(
                limitType: limitType,
                title: "Too Many Channels",
                description: "You have reached the limit for joined channels and groups. Premium allows up to 1000.",
                icon: "📡",
                freeLimitLabel: "500",
                premiumLimitLabel: "1000",
                freeNumeric: 500.0,
                premiumNumeric: 1000.0
            )
        case PremiumLimitType.ExpiringStories =>
            PremiumLimitConfig(
                limitType: limitType,
                title: "Story Limit",
                description: "You can post up to 3 stories per day with a free account. Upgrade for up to 100 stories.",
                icon: "🌀",
                freeLimitLabel: "3/day",
                premiumLimitLabel: "100/day",
                freeNumeric: 3.0,
                premiumNumeric: 100.0
            )
        case PremiumLimitType.MultiStories =>
            PremiumLimitConfig(
                limitType: limitType,
                title: "Story Limit",
                description: "Upgrade to Premium to post more stories simultaneously.",
                icon: "🌀",
                freeLimitLabel: "3",
                premiumLimitLabel: "100",
                freeNumeric: 3.0,
                premiumNumeric: 100.0
            )
        case _ =>
            PremiumLimitConfig(
                limitType: PremiumLimitType.Unknown,
                title: "Limit Reached",
                description: "Upgrade to Premium to unlock higher limits.",
                icon: "⭐",
                freeLimitLabel: "—",
                premiumLimitLabel: "2x",
                freeNumeric: 1.0,
                premiumNumeric: 2.0
            )
    }
}

// ---------------------------------------------------------------------------
// UI 页面
// ---------------------------------------------------------------------------

@HybridComponentEntry
@Component
public class PremiumLimitUpsellPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var limitTypeId: String = "folders"
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let param = takePending("PremiumLimitUpsellPage")
        if (param.size > 0 && param != "{}") {
            this.limitTypeId = param
        }
        Hilog.info(0, "CjTelegram", "[PremiumLimitUpsellPage] limit type: ${this.limitTypeId}")
    }

    func resolveConfig(): PremiumLimitConfig {
        let t = premiumLimitTypeFromIdentifier(id: this.limitTypeId)
        return getPremiumLimitConfig(limitType: t)
    }

    func freeProgressRatio(): Float64 {
        let cfg = this.resolveConfig()
        if (cfg.premiumNumeric <= 0.0) { return 0.5 }
        return cfg.freeNumeric / cfg.premiumNumeric
    }

    func cfgFreeLimitLabel(): String { return this.resolveConfig().freeLimitLabel }
    func cfgPremiumLimitLabel(): String { return this.resolveConfig().premiumLimitLabel }
    func cfgIcon(): String { return this.resolveConfig().icon }
    func cfgTitle(): String { return this.resolveConfig().title }
    func cfgDescription(): String { return this.resolveConfig().description }
    func cfgLimitTypeLabel(): String { return this.limitTypeLabel(cfg: this.resolveConfig()) }

    @Builder
    func buildProgressBar() {
        Column {
            // 两列标签对比
            Row {
                Column {
                    Text(trSource("Free"))
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .fontWeight(FontWeight.Medium)
                    Text(this.cfgFreeLimitLabel())
                        .fontSize(17)
                        .fontColor(0x000000)
                        .fontWeight(FontWeight.Bold)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Column {
                    Text(trSource("Premium"))
                        .fontSize(13)
                        .fontColor(0x5856D6)
                        .fontWeight(FontWeight.Medium)
                    Text(this.cfgPremiumLimitLabel())
                        .fontSize(17)
                        .fontColor(0x5856D6)
                        .fontWeight(FontWeight.Bold)
                }
                .alignItems(HorizontalAlign.End)
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 0, bottom: 8)

            // 进度条：灰色背景，紫色填充代表 Free 限制，超出部分为 Premium 区间
            Stack(alignContent: Alignment.Start) {
                // 背景条（全宽）
                Row { }
                    .width(100.percent)
                    .height(8)
                    .backgroundColor(0xE5E5EA)
                    .borderRadius(4)

                // 前景条（Free 占比）
                Row { }
                    .width(this.freeProgressRatio() * 100.0)
                    .height(8)
                    .backgroundColor(0x5856D6)
                    .borderRadius(4)
            }
            .width(100.percent)
            .height(8)
            .padding(left: 16, right: 16)
        }
        .width(100.percent)
        .padding(top: 8, bottom: 8)
    }

    @Builder
    func buildComparisonRow(label!: String, freeVal!: String, premiumVal!: String) {
        Row {
            Text(label)
                .fontSize(15)
                .fontColor(0x3C3C43)
                .layoutWeight(1)

            Row {
                Text(freeVal)
                    .fontSize(15)
                    .fontColor(0x8E8E93)
                    .width(60)
                    .textAlign(TextAlign.Center)
                    .fontWeight(FontWeight.Medium)

                Text(premiumVal)
                    .fontSize(15)
                    .fontColor(0x5856D6)
                    .width(80)
                    .textAlign(TextAlign.Center)
                    .fontWeight(FontWeight.Bold)
            }
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 10, bottom: 10)
        .backgroundColor(0xFFFFFF)
        .borderRadius(8)
        .margin(left: 16, right: 16, bottom: 1)
    }

    public func build() {
        Column {
            Scroll {
                Column {
                    // 头部图标 + 标题
                    Column {
                        Text(this.cfgIcon())
                            .fontSize(48)
                            .margin(bottom: 12)

                        Text(this.cfgTitle())
                            .fontSize(22)
                            .fontWeight(FontWeight.Bold)
                            .fontColor(0x000000)
                            .textAlign(TextAlign.Center)
                            .margin(bottom: 8)

                        Text(this.cfgDescription())
                            .fontSize(15)
                            .fontColor(0x8E8E93)
                            .textAlign(TextAlign.Center)
                            .width(100.percent)
                            .padding(left: 24, right: 24)
                            .margin(bottom: 24)
                    }
                    .width(100.percent)
                    .alignItems(HorizontalAlign.Center)
                    .padding(top: 32)

                    // 进度条区域
                    Column {
                        Text("Your limit")
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .width(100.percent)
                            .padding(left: 16, right: 16, bottom: 4)

                        this.buildProgressBar()
                    }
                    .width(100.percent)
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(12)
                    .margin(left: 16, right: 16, bottom: 16)

                    // Free vs Premium 对比表
                    Column {
                        // 表头
                        Row {
                            Text("Feature")
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .layoutWeight(1)
                                .padding(left: 16)

                            Text(trSource("Free"))
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .width(60)
                                .textAlign(TextAlign.Center)

                            Text(trSource("Premium"))
                                .fontSize(13)
                                .fontColor(0x5856D6)
                                .width(80)
                                .textAlign(TextAlign.Center)
                        }
                        .width(100.percent)
                        .padding(left: 0, right: 16, top: 8, bottom: 4)

                        // 当前 limit 行
                        this.buildComparisonRow(
                            label: this.cfgLimitTypeLabel(),
                            freeVal: this.cfgFreeLimitLabel(),
                            premiumVal: this.cfgPremiumLimitLabel()
                        )

                        // 其他通用对比行
                        this.buildComparisonRow(
                            label: "File Upload Size",
                            freeVal: "2 GB",
                            premiumVal: "4 GB"
                        )
                        this.buildComparisonRow(
                            label: "Download Speed",
                            freeVal: "Normal",
                            premiumVal: "Fastest"
                        )
                        this.buildComparisonRow(
                            label: "No Ads",
                            freeVal: "✗",
                            premiumVal: "✓"
                        )
                        this.buildComparisonRow(
                            label: "Voice-to-Text",
                            freeVal: "✗",
                            premiumVal: "✓"
                        )
                    }
                    .width(100.percent)
                    .padding(bottom: 16)

                    // Upgrade button
                    Text(trSource("Upgrade to Premium"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xFFFFFF)
                        .width(100.percent)
                        .height(52)
                        .textAlign(TextAlign.Center)
                        .backgroundColor(0x5856D6)
                        .borderRadius(12)
                        .margin(left: 16, right: 16, top: 8)
                        .onClick({ evt =>
                            routerPush("PremiumPage", "")
                            Hilog.info(0, "CjTelegram", "[PremiumLimitUpsellPage] Navigate to PremiumPage")
                        })

                    Text("Platform in-app purchase not yet available on HarmonyOS.")
                        .fontSize(12)
                        .fontColor(0xAAAAAA)
                        .width(100.percent)
                        .textAlign(TextAlign.Center)
                        .padding(left: 16, right: 16, top: 8, bottom: 4)

                    Text("Maybe Later")
                        .fontSize(15)
                        .fontColor(0x007AFF)
                        .width(100.percent)
                        .height(44)
                        .textAlign(TextAlign.Center)
                        .margin(top: 4, bottom: 32)
                        .onClick({ evt =>
                            routerPop()
                        })

                    Row { }
                        .height(16)
                }
                .width(100.percent)
            }
            .layoutWeight(1)
            .scrollBar(BarState.Off)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }

    func limitTypeLabel(cfg!: PremiumLimitConfig): String {
        let t = cfg.limitType
        if (t == PremiumLimitType.Folders) { return "Chat Folders" }
        if (t == PremiumLimitType.ChatsPerFolder) { return "Chats per Folder" }
        if (t == PremiumLimitType.Pins) { return "Pinned Chats" }
        if (t == PremiumLimitType.PinnedSavedPeers) { return "Pinned Saved Msgs" }
        if (t == PremiumLimitType.Files) { return "Max File Size" }
        if (t == PremiumLimitType.Accounts) { return "Accounts" }
        if (t == PremiumLimitType.LinksPerSharedFolder) { return "Folder Links" }
        if (t == PremiumLimitType.MembershipInSharedFolders) { return "Folder Memberships" }
        if (t == PremiumLimitType.Channels) { return "Channels & Groups" }
        if (t == PremiumLimitType.ExpiringStories) { return "Daily Stories" }
        if (t == PremiumLimitType.MultiStories) { return "Active Stories" }
        return "Limit"
    }
}
