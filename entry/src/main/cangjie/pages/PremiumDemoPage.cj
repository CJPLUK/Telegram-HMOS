package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.{trOr, trSource}
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.sync.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.services.{getPremiumService, ensureGifLocalFile}

/**
 * P2-298: Premium 功能 Demo 展示页（混合工程迁移版）
 *
 * iOS 参考: submodules/PremiumUI/Sources/PremiumDemoScreen.swift (DemoSheetContent / DemoPagerComponent)
 *
 * 结构:
 *   - Swiper 左右滑动翻页（.indicator(true) 内置 PageIndicator dots）
 *   - ~23 个 perk demo 页（每页: 大图标/emoji演示区 + 标题 + 说明）
 *   - demo 视频实际播放需视频底座，用静态预览 + emoji 大图代替（视频资产未打包）
 *   - 底部"Get Premium"按钮（IAP 未做，Log 替代）
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹 + .title/.hideTitleBar/.onReady，只留内容
 *  - pageStack.pop(animated:true) → routerPop()
 *  - aboutToAppear + onReady 参数解析 → ensureLoaded() 里 takePending("PremiumDemoPage") + .onAppear
 *
 * Swiper.onChange 签名: ?(Int32) -> Unit  (R-107: ForEach/Builder 内无 let/var)
 */

/**
 * 单个 perk demo 内容数据
 */
public class PerkDemoContent {
    public var identifier: String = ""
    public var title: String = ""
    public var description: String = ""
    public var demoEmoji: String = ""
    public var demoColor: Int64 = 0x5856D6
    public var demoDetail: String = ""

    public init(
        identifier!: String,
        title!: String,
        description!: String,
        demoEmoji!: String,
        demoColor!: Int64,
        demoDetail!: String
    ) {
        this.identifier = identifier
        this.title = title
        this.description = description
        this.demoEmoji = demoEmoji
        this.demoColor = demoColor
        this.demoDetail = demoDetail
    }
}

/**
 * 全部 23 个 perk demo 内容列表
 * 顺序对应 iOS PremiumDemoScreen.Subject 枚举
 */
public func getPerkDemoList(): Array<PerkDemoContent> {
    return [
        PerkDemoContent(
            identifier: "double_limits",
            title: "Double Limits",
            description: "Increase limits for chats, channels, folders and pinned messages to double the free amounts.",
            demoEmoji: "2️⃣",
            demoColor: 0x5856D6,
            demoDetail: "Free: 500 chats in folders\nPremium: 1000 chats in folders\n\nFree: 500 channels\nPremium: 1000 channels\n\nFree: 10 pinned chats\nPremium: 20 pinned chats"
        ),
        PerkDemoContent(
            identifier: "more_upload",
            title: "4 GB File Uploads",
            description: "Share files of up to 4 GB each, the largest in the messaging industry.",
            demoEmoji: "📁",
            demoColor: 0x3478F6,
            demoDetail: "Standard upload limit: 2 GB\nPremium upload limit: 4 GB\n\nShare high-resolution videos, large archives, and professional files without compression."
        ),
        PerkDemoContent(
            identifier: "faster_download",
            title: "Faster Downloads",
            description: "Download media and files without any limits at the highest speed available.",
            demoEmoji: "⚡",
            demoColor: 0xFFCC00,
            demoDetail: "Priority download bandwidth\nNo speed throttling\nInstant media loading\n\nExperience downloads at full network speed with no artificial limits."
        ),
        PerkDemoContent(
            identifier: "voice_to_text",
            title: "Voice-to-Text",
            description: "Get text transcriptions for any voice message you receive.",
            demoEmoji: "🎙️",
            demoColor: 0x34C759,
            demoDetail: "Tap any voice message → see text transcription\n\nSupports multiple languages\nWorks offline\nPerfect for quiet environments"
        ),
        PerkDemoContent(
            identifier: "no_ads",
            title: "No Ads",
            description: "Remove all sponsored messages from chats and channels.",
            demoEmoji: "🚫",
            demoColor: 0xFF3B30,
            demoDetail: "No sponsored messages\nClean reading experience\nNo tracking\n\nEnjoy Telegram without any advertising interruptions."
        ),
        PerkDemoContent(
            identifier: "infinite_reactions",
            title: "Unique Reactions",
            description: "Express yourself with exclusive animated reactions not available to other users.",
            demoEmoji: "❤️‍🔥",
            demoColor: 0xFF6B35,
            demoDetail: "100+ premium animated reactions\nExclusive effects: fire heart, party popper, galaxy...\n\nLong-press any message to reveal premium reactions."
        ),
        PerkDemoContent(
            identifier: "premium_stickers",
            title: "Premium Stickers",
            description: "Use stickers with exclusive animated effects — falling petals, bubbles, and more.",
            demoEmoji: "⭐",
            demoColor: 0xFFD700,
            demoDetail: "Animated premium sticker effects\nFalling petals, rising bubbles, sparkling stars\n\nAvailable in all sticker packs marked with ⭐"
        ),
        PerkDemoContent(
            identifier: "advanced_chat_management",
            title: "Advanced Chat Management",
            description: "Organize your inbox with folder tags and manage more chats, bots and channels.",
            demoEmoji: "💬",
            demoColor: 0x5856D6,
            demoDetail: "Up to 10 chat folders (free: 10, same but with more chats)\nFolder tags for quick filtering\nPin up to 20 chats\nManage 10 bots in a bot list"
        ),
        PerkDemoContent(
            identifier: "profile_badge",
            title: "Profile Badge",
            description: "Show a special Premium badge next to your name in chats and profile.",
            demoEmoji: "🏅",
            demoColor: 0xFFD700,
            demoDetail: "Premium ⭐ badge visible in:\n• Your profile\n• Chat lists\n• Group member lists\n• Replies and forwards"
        ),
        PerkDemoContent(
            identifier: "animated_userpics",
            title: "Animated Profile Photos",
            description: "Set an animated profile photo that your contacts will see in chats.",
            demoEmoji: "▶️",
            demoColor: 0x3478F6,
            demoDetail: "Upload a short video as your profile photo\nShows animated in chat lists and profiles\nPerfect loop, up to 5 seconds\n\nContacts on any Telegram version will see the animation."
        ),
        PerkDemoContent(
            identifier: "app_icons",
            title: "App Icons",
            description: "Change the icon Telegram displays on your device's home screen.",
            demoEmoji: "📱",
            demoColor: 0x5856D6,
            demoDetail: "10+ exclusive icon designs:\n• Classic, Nocturnal, Arctic\n• Turbo, Premium, Ivory\n• ...and more\n\nSettings → Appearance → App Icon"
        ),
        PerkDemoContent(
            identifier: "animated_emoji",
            title: "Animated Emoji",
            description: "React and express yourself with unique full-screen animated emoji.",
            demoEmoji: "😊",
            demoColor: 0xFF9500,
            demoDetail: "Send animated emoji in chats\nFull-screen effect when tapped\nExclusive premium emoji set\n\nTap any animated emoji to see the effect!"
        ),
        PerkDemoContent(
            identifier: "emoji_status",
            title: "Emoji Status",
            description: "Set an animated emoji as your status to tell people what you're up to.",
            demoEmoji: "🏷️",
            demoColor: 0xAF52DE,
            demoDetail: "Appears next to your name everywhere\nChoose from thousands of animated emoji\nExpires automatically or stays indefinitely\n\nProfile → Set Emoji Status"
        ),
        PerkDemoContent(
            identifier: "translations",
            title: "Real-Time Translation",
            description: "Subscribe to Telegram Premium to be able to translate all messages in a chat at once.",
            demoEmoji: "",
            demoColor: 0x34C759,
            demoDetail: ""
        ),
        PerkDemoContent(
            identifier: "stories",
            title: "Stories",
            description: "Share everyday moments with a wider audience through Premium Stories.",
            demoEmoji: "🔄",
            demoColor: 0xFF3B30,
            demoDetail: "Post Stories visible to all contacts\nAdd links, stickers, reactions\nExpires after 24h or stays in archive\n\nFree users can view Stories but not post publicly."
        ),
        PerkDemoContent(
            identifier: "peer_colors",
            title: "Color Theme",
            description: "Customize the look of your profile and chat messages with unique accent colors.",
            demoEmoji: "🎨",
            demoColor: 0xFF6B35,
            demoDetail: "8 exclusive premium color themes\nCustomize message bubble color\nCustomize profile header accent\n\nSettings → Appearance → Message Color"
        ),
        PerkDemoContent(
            identifier: "wallpapers",
            title: "Premium Wallpapers",
            description: "Set unique wallpapers in any chat, including exclusive premium patterns.",
            demoEmoji: "🖼️",
            demoColor: 0x3478F6,
            demoDetail: "Chat-specific wallpapers\n12 exclusive premium patterns\nAnimated wallpapers\n\nLong-press any chat → Chat Settings → Wallpaper"
        ),
        PerkDemoContent(
            identifier: "saved_tags",
            title: "Message Tags",
            description: "Add tags to Saved Messages to quickly filter them by topic.",
            demoEmoji: "🏷️",
            demoColor: 0xFFD700,
            demoDetail: "Tag any saved message with emoji\nFilter saved messages by tag\nOrganize notes, links, media\n\nForward to Saved Messages → Tag +"
        ),
        PerkDemoContent(
            identifier: "last_seen",
            title: "Last Seen & Read Time",
            description: "Check when exactly contacts read your messages and when they were last online.",
            demoEmoji: "⏱️",
            demoColor: 0x5856D6,
            demoDetail: "Exact read timestamp for messages\nPrecise last online time (not just 'recently')\n\nAvailable in private chats with Premium users."
        ),
        PerkDemoContent(
            identifier: "message_privacy",
            title: "Message Privacy",
            description: "Choose who can mention you, or send voice and video messages in your inbox.",
            demoEmoji: "🔒",
            demoColor: 0xFF9500,
            demoDetail: "Block voice/video messages from non-contacts\nRestrict who can mention you in groups\nControl who can forward your messages\n\nSettings → Privacy → Advanced"
        ),
        PerkDemoContent(
            identifier: "folder_tags",
            title: "Folder Tags",
            description: "Add color tags to chats within your folders for instant visual filtering.",
            demoEmoji: "📂",
            demoColor: 0x34C759,
            demoDetail: "Assign emoji tags to chats in folders\nFilter folder by tag instantly\nCustomize up to 5 tags per chat\n\nFolder Settings → Tag Chat"
        ),
        PerkDemoContent(
            identifier: "effects",
            title: "Message Effects",
            description: "Send messages with unique visual effects: confetti, lasers, or a burning flame.",
            demoEmoji: "✨",
            demoColor: 0xFF6B35,
            demoDetail: "Fire effect — for passionate messages\nConfetti — celebrate moments\nLaser — for impact\nHearts — show love\n\nLong-press Send → Choose Effect"
        ),
        PerkDemoContent(
            identifier: "pm_noforwards",
            title: "Copy Protection",
            description: "Restrict saving content from your messages in any of your private chats.",
            demoEmoji: "🛡️",
            demoColor: 0xFF3B30,
            demoDetail: "Prevent forwarding your messages\nPrevent saving media\nBlock screenshots (Android)\n\nChat Settings → Restrict Saving Content"
        ),
        PerkDemoContent(identifier: "business_location", title: "Location", description: "Display the location of your business on your account.", demoEmoji: "", demoColor: 0xEF6922, demoDetail: ""),
        PerkDemoContent(identifier: "business_hours", title: "Opening Hours", description: "Show to your customers when you are open for business.", demoEmoji: "", demoColor: 0xE54937, demoDetail: ""),
        PerkDemoContent(identifier: "quick_replies", title: "Quick Replies", description: "Set up shortcuts with rich text and media to respond to messages faster.", demoEmoji: "", demoColor: 0xDB374B, demoDetail: ""),
        PerkDemoContent(identifier: "greeting_message", title: "Greeting Messages", description: "Create greetings that will be automatically sent to new customers.", demoEmoji: "", demoColor: 0xBC4395, demoDetail: ""),
        PerkDemoContent(identifier: "away_message", title: "Away Messages", description: "Define messages that are automatically sent when you are off.", demoEmoji: "", demoColor: 0x9B4FED, demoDetail: ""),
        PerkDemoContent(identifier: "business_links", title: "Links", description: "Create links that start a chat with you, suggesting the first message.", demoEmoji: "", demoColor: 0x8958FF, demoDetail: ""),
        PerkDemoContent(identifier: "business_intro", title: "Intro", description: "Customize the message people see before they start a chat with you.", demoEmoji: "", demoColor: 0x676BFF, demoDetail: ""),
        PerkDemoContent(identifier: "business_bots", title: "Chatbots", description: "Add any third party chatbots that will process customer interactions.", demoEmoji: "", demoColor: 0x0088FF, demoDetail: "")
    ]
}

/**
 * P2-298 PremiumDemoPage — Swiper 横向滑动展示所有 23 个 perk demo
 *
 * 路由名: "PremiumDemoPage"
 * param: perk identifier 字符串（定位到对应 demo 页），经 takePending 取回
 */
@HybridComponentEntry
@Component
public class PremiumDemoPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var currentIndex: Int32 = 0
    @State var demoList: Array<PerkDemoContent> = Array<PerkDemoContent>(0, {_: Int64 => PerkDemoContent(
        identifier: "", title: "", description: "", demoEmoji: "", demoColor: 0, demoDetail: ""
    )})
    @State var loaded: Bool = false
    @State var requestedIdentifier: String = ""
    @State var translationVideoPath: String = ""
    @State var subjectVideoPath: String = ""
    @State var helloVisible: Bool = false
    @State var gradientAngle: Float64 = 135.0

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let list = getPerkDemoList()
        let param = takePending("PremiumDemoPage")
        this.requestedIdentifier = param
        if (param.size > 0 && param != "{}") {
            for (item in list) {
                if (item.identifier == param) {
                    // PremiumDemoScreen(subject:) renders exactly the requested
                    // subject. It is not an entry into the complete perk pager.
                    this.demoList = [item]
                    this.currentIndex = 0
                    if (param == "translations") {
                        this.loadTranslationVideo()
                        this.startTranslationAnimations()
                    } else if (this.isBusinessSubject(param)) {
                        this.loadSubjectVideo(param)
                    }
                    return
                }
            }
        }
        this.demoList = list
        this.currentIndex = 0
    }

    private func isBusinessSubject(identifier: String): Bool {
        return identifier == "business_location" || identifier == "business_hours" || identifier == "quick_replies" ||
            identifier == "greeting_message" || identifier == "away_message" || identifier == "business_links" ||
            identifier == "business_intro" || identifier == "business_bots"
    }

    private func loadSubjectVideo(identifier: String): Unit {
        let _ = spawn {
            let promo = getPremiumService().getPremiumPromo()
            var localPath = ""
            var i: Int64 = 0
            while (i < promo.videoSections.size && i < promo.videos.size) {
                if (promo.videoSections[i] == identifier) {
                    localPath = ensureGifLocalFile(promo.videos[i])
                    break
                }
                i = i + 1
            }
            let resolvedPath = localPath
            launch { this.subjectVideoPath = resolvedPath }
        }
    }

    @Builder
    private func businessPhone(item: PerkDemoContent) {
        Stack(alignContent: Alignment.Center) {
            Column { }.width(250).height(420).backgroundColor(0xFF111216)
                .border(width: 6, color: 0xFF303136).borderRadius(42)
            if (this.subjectVideoPath.size > 0) {
                Video(src: this.subjectVideoPath).width(226).height(396).autoPlay(true).loop(true).muted(true)
                    .controls(false).objectFit(ImageFit.Cover).borderRadius(34)
            } else {
                LoadingProgress().width(28).height(28).color(0xFFFFFFFF)
            }
        }.width(100.percent).height(420).margin(bottom: 18)
    }

    private func startTranslationAnimations(): Unit {
        // The translation subtree is mounted only after requestedIdentifier is
        // applied. Flip animation state on the next UI beat so ArkUI observes
        // the same 0 -> visible transition that HelloView creates per phrase.
        let _ = Timer.once(Duration.millisecond * 50, { =>
            launch {
                this.helloVisible = true
                this.gradientAngle = 225.0
            }
        })
    }

    private func loadTranslationVideo(): Unit {
        let _ = spawn {
            let promo = getPremiumService().getPremiumPromo()
            var localPath = ""
            var i: Int64 = 0
            while (i < promo.videoSections.size && i < promo.videos.size) {
                if (promo.videoSections[i] == "translations") {
                    localPath = ensureGifLocalFile(promo.videos[i])
                    break
                }
                i = i + 1
            }
            let resolvedPath = localPath
            launch { this.translationVideoPath = resolvedPath }
        }
    }

    @Builder
    private func helloPhrase(text: String, x: Int64, y: Int64,
                             delay: Int32, duration: Int32, targetScale: Float32) {
        Text(text)
            .fontSize(14).fontWeight(FontWeight.Bold).fontColor(0x8FFFFFFF)
            .position(x: x, y: y)
            .opacity(if (this.helloVisible) { 1.0 } else { 0.0 })
            .scale(x: if (this.helloVisible) { targetScale } else { 0.5f32 },
                   y: if (this.helloVisible) { targetScale } else { 0.5f32 })
            .animation(AnimateParam(duration: duration, curve: Curve.EaseInOut,
                delay: delay, iterations: -1, playMode: PlayMode.Alternate))
    }

    @Builder
    private func translationPhone() {
        Stack(alignContent: Alignment.TopStart) {
            this.helloPhrase("Вітаю", 26, 18, 70, 1870, 1.05f32)
            this.helloPhrase("你好", 260, 8, 310, 2130, 1.14f32)
            this.helloPhrase("Hello", 322, 48, 520, 1780, 1.08f32)
            this.helloPhrase("سلام", 8, 86, 690, 2240, 1.16f32)
            this.helloPhrase("Bonjour", 245, 78, 150, 1960, 1.03f32)
            this.helloPhrase("Guten tag", 315, 120, 430, 2080, 1.12f32)
            this.helloPhrase("שלום", 20, 170, 760, 1810, 1.05f32)
            this.helloPhrase("नमस्ते", 318, 184, 250, 2190, 1.15f32)
            this.helloPhrase("Ciao", 8, 244, 600, 1910, 1.10f32)
            this.helloPhrase("こんにちは", 296, 250, 20, 2260, 1.04f32)
            this.helloPhrase("Olá", 18, 304, 390, 1840, 1.18f32)
            this.helloPhrase("Привет", 300, 316, 720, 2030, 1.06f32)
            this.helloPhrase("Hola", 8, 344, 200, 2160, 1.11f32)

            Stack(alignContent: Alignment.Center) {
                Column { }.width(250).height(420).backgroundColor(0xFF111216)
                    .border(width: 6, color: 0xFF303136).borderRadius(42)
                if (this.translationVideoPath.size > 0) {
                    Video(src: this.translationVideoPath)
                        .width(226).height(396).autoPlay(true).loop(true).muted(true)
                        .controls(false).objectFit(ImageFit.Cover).borderRadius(34)
                } else {
                    LoadingProgress().width(28).height(28).color(0xFFFFFFFF)
                }
            }.width(100.percent).height(420).margin(top: 8)
        }.width(100.percent).height(360).clip(true)
    }

    private func perkDemoColor(idx: Int32): Int64 {
        if (Int64(idx) < this.demoList.size) {
            return this.demoList[Int64(idx)].demoColor
        }
        return 0x5856D6
    }

    private func currentDemoTitle(): String {
        let i = Int64(this.currentIndex)
        if (i < this.demoList.size) {
            return this.demoList[i].title
        }
        return ""
    }

    private func currentDemoDesc(): String {
        let i = Int64(this.currentIndex)
        if (i < this.demoList.size) {
            return this.demoList[i].description
        }
        return ""
    }

    @Builder
    func buildDemoContentFor(item: PerkDemoContent) {
        Column {
            if (item.identifier == "translations") {
                this.translationPhone()
            } else if (this.isBusinessSubject(item.identifier)) {
                this.businessPhone(item)
            } else {
                Stack(alignContent: Alignment.Center) {
                    Column { }
                        .width(160)
                        .height(160)
                        .backgroundColor(item.demoColor)
                        .borderRadius(32)
                        .shadow(radius: 24.0, color: item.demoColor, offsetX: 0.0, offsetY: 8.0)

                    Column {
                        Text(item.demoEmoji)
                            .fontSize(64)
                            .textAlign(TextAlign.Center)
                    }
                    .alignItems(HorizontalAlign.Center)
                    .justifyContent(FlexAlign.Center)
                }
                .width(200)
                .height(200)
                .margin(bottom: 32)
            }

            Text(if (item.identifier == "translations") { trSource("Real-Time Translation") } else { item.title })
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor(0xFFFFFF)
                .textAlign(TextAlign.Center)
                .width(100.percent)
                .padding(left: 24, right: 24)
                .margin(bottom: 12)

            Text(if (item.identifier == "translations") {
                trOr("Premium.TranslationStandaloneInfo", "Subscribe to Telegram Premium to be able to translate all messages in a chat at once.")
            } else { item.description })
                .fontSize(15)
                .fontColor(0xCCFFFFFF)
                .textAlign(TextAlign.Center)
                .width(100.percent)
                .padding(left: 32, right: 32)
                .margin(bottom: 24)

            if (item.demoDetail.size > 0) {
                Scroll {
                    Column {
                        Text(item.demoDetail)
                            .fontSize(14)
                            .fontColor(0xAAFFFFFF)
                            .textAlign(TextAlign.Center)
                            .width(100.percent)
                            .padding(left: 24, right: 24)
                    }
                    .width(100.percent)
                }
                .height(120)
                .scrollBar(BarState.Off)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .alignItems(HorizontalAlign.Center)
        .justifyContent(FlexAlign.Center)
    }

    @Builder
    func buildEmptyState() {
        Column {
            Text(trSource("Loading..."))
                .fontSize(18)
                .fontColor(0xAAFFFFFF)
                .textAlign(TextAlign.Center)
        }
        .width(100.percent)
        .height(100.percent)
        .alignItems(HorizontalAlign.Center)
        .justifyContent(FlexAlign.Center)
    }

    @Builder
    private func buildTranslationSheet() {
        Column {
            Stack(alignContent: Alignment.TopStart) {
                Column { }
                    .width(100.percent).height(360)
                    .linearGradient(angle: this.gradientAngle, colors: [
                        (Color(0xFF0077FF), 0.0),
                        (Color(0xFF6B93FF), 0.38),
                        (Color(0xFF8878FF), 0.7),
                        (Color(0xFFE46ACE), 1.0)
                    ])
                    .animation(AnimateParam(duration: 4500, curve: Curve.Linear,
                        iterations: -1, playMode: PlayMode.Alternate))

                this.translationPhone()

                Button {
                    Text("×").fontSize(27).fontWeight(FontWeight.Medium).fontColor(0xFFFFFFFF)
                }
                .width(44).height(44).borderRadius(22).backgroundColor(0xFF7F76F4)
                .margin(left: 16, top: 16)
                .onClick({ _ => routerPop() })
            }.width(100.percent).height(360)

            Text(trSource("Real-Time Translation"))
                .fontSize(22).fontWeight(FontWeight.Bold).fontColor(0xFF111111)
                .textAlign(TextAlign.Center).width(100.percent).margin(top: 18)
            Text(trOr("Premium.TranslationStandaloneInfo", "Subscribe to Telegram Premium to be able to translate all messages in a chat at once."))
                .fontSize(17).fontColor(0xFF111111).textAlign(TextAlign.Center)
                .width(100.percent).padding(left: 24, right: 24).margin(top: 10)
            Text(trOr("Premium.Translation.Proceed", "About Telegram Premium"))
                .fontSize(17).fontWeight(FontWeight.Bold).fontColor(0xFFFFFFFF)
                .width(100.percent).height(52).textAlign(TextAlign.Center).borderRadius(26)
                .linearGradient(angle: 90.0, colors: [
                    (Color(0xFF0077FF), 0.0),
                    (Color(0xFF6B93FF), 0.4),
                    (Color(0xFF8878FF), 0.7),
                    (Color(0xFFE46ACE), 1.0)
                ])
                .animation(AnimateParam(duration: 4500, curve: Curve.Linear,
                    iterations: -1, playMode: PlayMode.Alternate))
                .margin(left: 16, right: 16, top: 20, bottom: 12.0 + getSafeAreaBottom())
                .onClick({ _ => routerReplaceTop("PremiumPage", "translation") })
        }
        .width(100.percent)
        .backgroundColor(0xFFFFFFFF)
        .borderRadius(topLeft: 28, topRight: 28, bottomLeft: 0, bottomRight: 0)
        .clip(true)
    }

    public func build() {
        if (this.requestedIdentifier == "translations") {
            Stack(alignContent: Alignment.Bottom) {
                this.buildTranslationSheet()
            }
            .width(100.percent).height(100.percent).backgroundColor(Color.Transparent)
            .onAppear({ => this.ensureLoaded() })
        } else {
            Stack(alignContent: Alignment.TopStart) {
                Column {
                    if (this.demoList.size == 0) {
                        this.buildEmptyState()
                    } else {
                    Swiper() {
                        ForEach(this.demoList, itemGenerator: { item: PerkDemoContent, _i: Int64 =>
                            this.buildDemoContentFor(item)
                        })
                    }
                    .index(UInt32(this.currentIndex))
                    .loop(false)
                    .indicator(this.demoList.size > 1)
                    .onChange({ idx: Int32 =>
                        this.currentIndex = idx
                    })
                    .width(100.percent)
                    .layoutWeight(1)

                    Column {
                        Text(if (this.requestedIdentifier == "translations") {
                            trOr("Premium.Translation.Proceed", "About Telegram Premium")
                        } else { trSource("Get Premium") })
                            .fontSize(17)
                            .fontWeight(FontWeight.Bold)
                            .fontColor(0xFFFFFF)
                            .width(100.percent)
                            .height(50)
                            .textAlign(TextAlign.Center)
                            .borderRadius(12)
                            .linearGradient(angle: 90.0, colors: [
                                (Color(0xFF0077FF), 0.0),
                                (Color(0xFF6B93FF), 0.4),
                                (Color(0xFF8878FF), 0.7),
                                (Color(0xFFE46ACE), 1.0)
                            ])
                            .margin(left: 16, right: 16, bottom: 20)
                            .onClick({ _ => routerReplaceTop("PremiumPage", this.requestedIdentifier) })
                    }
                    .width(100.percent)
                }
                }
                .width(100.percent)
                .height(100.percent)
                .linearGradient(angle: 160.0, colors: [
                (Color(0xFF1A0050), 0.0),
                (Color(0xFF0E2C7A), 0.4),
                (Color(0xFF1A0050), 1.0)
                ])
                Button {
                    Image(@r(app.media.nav_ic_close)).width(17).height(17).fillColor(0xFFFFFFFF)
                }.width(42).height(42).borderRadius(21).backgroundColor(0x557B6CF6)
                    .margin(left: 16, top: 8.0 + getSafeAreaTop())
                    .onClick({ _ => routerPop() })
            }
            .width(100.percent)
            .height(100.percent)
            .onAppear({ => this.ensureLoaded() })
        }
    }
}

/**
 * The source presents PremiumDemoScreen as a flat modal owned by the caller.
 * Keep the translation subject available as a regular component so callers
 * such as LanguageSettingsPage can use a real sheet instead of a transparent
 * navigation destination.
 */
@Component
public class TranslationPremiumDemoSheet {
    @StorageLink["presentationStrings"] var presentationStrings: PresentationStringsSnapshot = currentPresentationStrings()
    public var onClose: () -> Unit = { => }
    public var onProceed: () -> Unit = { => }
    @State var translationVideoPath: String = ""
    @State var helloVisible: Bool = false
    @State var gradientAngle: Float64 = 135.0
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let _ = Timer.once(Duration.millisecond * 50, { =>
            launch {
                this.helloVisible = true
                this.gradientAngle = 225.0
            }
        })
        let _ = spawn {
            let promo = getPremiumService().getPremiumPromo()
            var localPath = ""
            var i: Int64 = 0
            while (i < promo.videoSections.size && i < promo.videos.size) {
                if (promo.videoSections[i] == "translations") {
                    localPath = ensureGifLocalFile(promo.videos[i])
                    break
                }
                i = i + 1
            }
            let resolvedPath = localPath
            launch { this.translationVideoPath = resolvedPath }
        }
    }

    @Builder
    private func helloPhrase(text: String, x: Int64, y: Int64,
                             delay: Int32, duration: Int32, targetScale: Float32) {
        Text(text)
            .fontSize(14).fontWeight(FontWeight.Bold).fontColor(0x8FFFFFFF)
            .position(x: x, y: y)
            .opacity(if (this.helloVisible) { 1.0 } else { 0.0 })
            .scale(x: if (this.helloVisible) { targetScale } else { 0.5f32 },
                   y: if (this.helloVisible) { targetScale } else { 0.5f32 })
            .animation(AnimateParam(duration: duration, curve: Curve.EaseInOut,
                delay: delay, iterations: -1, playMode: PlayMode.Alternate))
    }

    @Builder
    private func translationPhone() {
        Stack(alignContent: Alignment.TopStart) {
            this.helloPhrase("Вітаю", 26, 18, 70, 1870, 1.05f32)
            this.helloPhrase("你好", 260, 8, 310, 2130, 1.14f32)
            this.helloPhrase("Hello", 322, 48, 520, 1780, 1.08f32)
            this.helloPhrase("سلام", 8, 86, 690, 2240, 1.16f32)
            this.helloPhrase("Bonjour", 245, 78, 150, 1960, 1.03f32)
            this.helloPhrase("Guten tag", 315, 120, 430, 2080, 1.12f32)
            this.helloPhrase("שלום", 20, 170, 760, 1810, 1.05f32)
            this.helloPhrase("नमस्ते", 318, 184, 250, 2190, 1.15f32)
            this.helloPhrase("Ciao", 8, 244, 600, 1910, 1.10f32)
            this.helloPhrase("こんにちは", 296, 250, 20, 2260, 1.04f32)
            this.helloPhrase("Olá", 18, 304, 390, 1840, 1.18f32)
            this.helloPhrase("Привет", 300, 316, 720, 2030, 1.06f32)
            this.helloPhrase("Hola", 8, 344, 200, 2160, 1.11f32)
            Stack(alignContent: Alignment.Center) {
                Column { }.width(250).height(420).backgroundColor(0xFF111216)
                    .border(width: 6, color: 0xFF303136).borderRadius(42)
                if (this.translationVideoPath.size > 0) {
                    Video(src: this.translationVideoPath)
                        .width(226).height(396).autoPlay(true).loop(true).muted(true)
                        .controls(false).objectFit(ImageFit.Cover).borderRadius(34)
                } else {
                    LoadingProgress().width(28).height(28).color(0xFFFFFFFF)
                }
            }.width(100.percent).height(420).margin(top: 8)
        }.width(100.percent).height(360).clip(true)
    }

    public func build() {
        Column {
            Stack(alignContent: Alignment.TopStart) {
                Column { }.width(100.percent).height(360)
                    .linearGradient(angle: this.gradientAngle, colors: [
                        (Color(0xFF0077FF), 0.0), (Color(0xFF6B93FF), 0.38),
                        (Color(0xFF8878FF), 0.7), (Color(0xFFE46ACE), 1.0)
                    ])
                    .animation(AnimateParam(duration: 4500, curve: Curve.Linear,
                        iterations: -1, playMode: PlayMode.Alternate))
                this.translationPhone()
                Button { Text("×").fontSize(27).fontWeight(FontWeight.Medium).fontColor(0xFFFFFFFF) }
                    .width(44).height(44).borderRadius(22).backgroundColor(0x557B6CF6)
                    .margin(left: 16, top: 16).onClick({ _ => this.onClose() })
            }.width(100.percent).height(360)
            Text(trSource("Real-Time Translation"))
                .fontSize(22).fontWeight(FontWeight.Bold).fontColor(0xFF111111)
                .textAlign(TextAlign.Center).width(100.percent).margin(top: 18)
            Text(trOr("Premium.TranslationStandaloneInfo", "Subscribe to Telegram Premium to be able to translate all messages in a chat at once."))
                .fontSize(17).fontColor(0xFF111111).textAlign(TextAlign.Center)
                .width(100.percent).padding(left: 24, right: 24).margin(top: 10)
            Text(trOr("Premium.Translation.Proceed", "About Telegram Premium"))
                .fontSize(17).fontWeight(FontWeight.Bold).fontColor(0xFFFFFFFF)
                .width(100.percent).height(52).textAlign(TextAlign.Center).borderRadius(26)
                .linearGradient(angle: 90.0, colors: [
                    (Color(0xFF0077FF), 0.0), (Color(0xFF6B93FF), 0.4),
                    (Color(0xFF8878FF), 0.7), (Color(0xFFE46ACE), 1.0)
                ])
                .margin(left: 16, right: 16, top: 20, bottom: 12.0 + getSafeAreaBottom())
                .onClick({ _ => this.onProceed() })
        }
        .width(100.percent).backgroundColor(0xFFFFFFFF)
        .onAppear({ => this.ensureLoaded() })
    }
}
