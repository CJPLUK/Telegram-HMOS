package ohos_app_cangjie_entry.pages

/**
 * Premium Perk 枚举 — 完整 26 项（对应 iOS PremiumUI/PremiumIntroScreen.swift PremiumPerk）
 *
 * iOS 参考: submodules/PremiumUI/Sources/PremiumIntroScreen.swift
 * PremiumPerk enum allCases: 25 premium perks + business 共 26 项
 *
 * 每项包含:
 *   - title:    功能名称（英文）
 *   - subtitle: 功能说明（英文）
 *   - icon:     emoji 图标（ArkUI 无向量 SVG，用 emoji 替代）
 *   - identifier: iOS 服务端 identifier，用于与服务端返回的 videoSections 匹配
 */
public class PremiumPerkItem {
    public var title: String = ""
    public var subtitle: String = ""
    public var icon: String = ""
    public var identifier: String = ""

    public init(title!: String, subtitle!: String, icon!: String, identifier!: String) {
        this.title = title
        this.subtitle = subtitle
        this.icon = icon
        this.identifier = identifier
    }
}

/**
 * 26 项 Premium perk 完整列表（全局单例）
 * 顺序与 iOS PremiumIntroConfiguration.defaultValue.perks 一致
 */
public func getPremiumPerkList(): Array<PremiumPerkItem> {
    return [
        PremiumPerkItem(
            title: "Double Limits",
            subtitle: "Increase limits for chats, channels, folders and pinned messages.",
            icon: "2x",
            identifier: "double_limits"
        ),
        PremiumPerkItem(
            title: "4 GB File Uploads",
            subtitle: "Share files of up to 4 GB each, the largest in the industry.",
            icon: "📁",
            identifier: "more_upload"
        ),
        PremiumPerkItem(
            title: "Faster Downloads",
            subtitle: "Download media and files without any limits, at the highest speed available.",
            icon: "⚡",
            identifier: "faster_download"
        ),
        PremiumPerkItem(
            title: "Voice-to-Text",
            subtitle: "Get text transcriptions for any voice message you receive.",
            icon: "🎙",
            identifier: "voice_to_text"
        ),
        PremiumPerkItem(
            title: "No Ads",
            subtitle: "Remove sponsored messages from chats.",
            icon: "🚫",
            identifier: "no_ads"
        ),
        PremiumPerkItem(
            title: "Unique Reactions",
            subtitle: "Express yourself with new reactions that aren't available to other users.",
            icon: "❤️",
            identifier: "infinite_reactions"
        ),
        PremiumPerkItem(
            title: "Premium Stickers",
            subtitle: "Use stickers with exclusive effects — falling petals, bubbles and more.",
            icon: "⭐",
            identifier: "premium_stickers"
        ),
        PremiumPerkItem(
            title: "Advanced Chat Management",
            subtitle: "Organize your inbox with folder tags, and manage more chats, bots and channels.",
            icon: "💬",
            identifier: "advanced_chat_management"
        ),
        PremiumPerkItem(
            title: "Profile Badge",
            subtitle: "Show a special badge next to your name in chats and your profile.",
            icon: "🏅",
            identifier: "profile_badge"
        ),
        PremiumPerkItem(
            title: "Animated Profile Photos",
            subtitle: "Set an animated profile photo that your contacts will see in chats.",
            icon: "▶️",
            identifier: "animated_userpics"
        ),
        PremiumPerkItem(
            title: "App Icons",
            subtitle: "Change the icon Telegram displays on your device's home screen.",
            icon: "📱",
            identifier: "app_icons"
        ),
        PremiumPerkItem(
            title: "Animated Emoji",
            subtitle: "React and express yourself with unique animated emoji.",
            icon: "😊",
            identifier: "animated_emoji"
        ),
        PremiumPerkItem(
            title: "Emoji Status",
            subtitle: "Set an animated emoji as your status to tell people what you're up to.",
            icon: "🏷",
            identifier: "emoji_status"
        ),
        PremiumPerkItem(
            title: "Real-Time Translation",
            subtitle: "Translate any message to any language in real time right in your chat.",
            icon: "🌐",
            identifier: "translations"
        ),
        PremiumPerkItem(
            title: "Stories",
            subtitle: "Share everyday moments with a wider audience through Stories.",
            icon: "🔄",
            identifier: "stories"
        ),
        PremiumPerkItem(
            title: "Color Theme",
            subtitle: "Customize the look of your profile and chat messages with unique colors.",
            icon: "🎨",
            identifier: "peer_colors"
        ),
        PremiumPerkItem(
            title: "Premium Wallpapers",
            subtitle: "Set unique wallpapers in any of your chats, including exclusive premium patterns.",
            icon: "🖼",
            identifier: "wallpapers"
        ),
        PremiumPerkItem(
            title: "Message Tags",
            subtitle: "Add tags to Saved Messages to quickly filter them by topic.",
            icon: "🏷",
            identifier: "saved_tags"
        ),
        PremiumPerkItem(
            title: "Last Seen & Read Time",
            subtitle: "Check when exactly contacts read your messages and when they were last online.",
            icon: "⏱",
            identifier: "last_seen"
        ),
        PremiumPerkItem(
            title: "Message Privacy",
            subtitle: "Choose who can mention you or send voice/video messages in your inbox.",
            icon: "🔒",
            identifier: "message_privacy"
        ),
        PremiumPerkItem(
            title: "Folder Tags",
            subtitle: "Add tags to chats in your folder for quick filtering.",
            icon: "📂",
            identifier: "folder_tags"
        ),
        PremiumPerkItem(
            title: "Business",
            subtitle: "Set up your business profile, opening hours, greeting messages and more.",
            icon: "💼",
            identifier: "business"
        ),
        PremiumPerkItem(
            title: "Message Effects",
            subtitle: "Send messages with unique effects, like confetti, lasers or a burning flame.",
            icon: "✨",
            identifier: "effects"
        ),
        PremiumPerkItem(
            title: "Todo Lists",
            subtitle: "Create collaborative to-do lists in any chat.",
            icon: "✅",
            identifier: "todo"
        ),
        PremiumPerkItem(
            title: "Copy Protection",
            subtitle: "Restrict saving content from your messages in any of your private chats.",
            icon: "🛡",
            identifier: "pm_noforwards"
        ),
        PremiumPerkItem(
            title: "AI Writing Tools",
            subtitle: "Get AI-powered suggestions to improve your messages as you type.",
            icon: "🤖",
            identifier: "ai_compose"
        )
    ]
}
