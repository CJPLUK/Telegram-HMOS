package ohos_app_cangjie_entry.providers

import std.collection.ArrayList
import ohos_app_cangjie_entry.services.{getThemesEngineService, ThemesResult, ThemeItem, WallPapersResult, WallPaperEntry}

/**
 * ThemesDataProvider — 主题数据提供层
 *
 * 对应 iOS TelegramEngine.Themes 的 UI 适配层。
 * 职责：
 *   - 将 ThemesEngineService 的 TL 调用结果转为 UI 可消费的 ViewModel
 *   - 为外观设置、主题选择等页面提供统一的数据访问接口
 *   - 委托 ThemesEngineService 执行真实 TL 调用
 *
 * 调用链（getThemes 为例）：
 *   ThemesDataProvider.getThemes()
 *     → ThemesEngineService.getThemes(format, hash)
 *       → getMTProtoClient().sendRequest(AccountGetThemes)
 *         → parseAccountThemesResponse(responseData)
 */
public class ThemesDataProvider {
    private let engine = getThemesEngineService()

    // ==================== 所有云端主题 ====================

    /**
     * 获取所有云端主题（供外观设置页 UI 显示）
     * 对应 iOS TelegramEngine.Themes.themes(accountManager:forceUpdate:)
     * @param format  主题格式，传 None 则不过滤格式
     * @param hash    缓存 hash，0 = 强制刷新
     */
    public func getThemes(format: Option<String>, hash: Int64): ThemesResult {
        return this.engine.getThemes(format, hash)
    }

    /**
     * 强制刷新所有主题（无缓存）
     */
    public func refreshThemes(): ThemesResult {
        return this.engine.getThemes(None, 0)
    }

    // ==================== 聊天主题 ====================

    /**
     * 获取聊天主题列表
     * 对应 iOS TelegramEngine.Themes.getChatThemes(accountManager:forceUpdate:onlyCached:)
     * @param hash 缓存 hash，0 = 强制刷新
     */
    public func getChatThemes(hash: Int64): ThemesResult {
        return this.engine.getChatThemes(hash)
    }

    /**
     * 强制刷新聊天主题
     */
    public func refreshChatThemes(): ThemesResult {
        return this.engine.getChatThemes(0)
    }

    // ==================== 主题保存（收藏） ====================

    /**
     * 收藏云端主题
     * 对应 iOS 侧 account.saveTheme (unsave=false)
     * @param slug 主题 URL slug
     */
    public func saveTheme(slug: String): Bool {
        return this.engine.saveTheme(slug, false)
    }

    /**
     * 取消收藏云端主题
     * @param slug 主题 URL slug
     */
    public func unsaveTheme(slug: String): Bool {
        return this.engine.saveTheme(slug, true)
    }

    // ==================== 主题安装（应用） ====================

    /**
     * 安装云端主题（全量参数版）
     * 对应 iOS TelegramEngine.Themes installTheme / account.installTheme
     * @param dark        true=深色模式
     * @param slug        主题 slug（None = 恢复默认）
     * @param format      主题格式（None = 不指定）
     * @param baseThemeId BaseTheme 编号 0~4，None = 不指定
     */
    public func installTheme(dark: Bool, slug: Option<String>, format: Option<String>, baseThemeId: Option<Int32>): Bool {
        return this.engine.installTheme(dark, slug, format, baseThemeId)
    }

    /**
     * 安装浅色默认主题（Classic Day）
     */
    public func installLightTheme(): Bool {
        return this.engine.installTheme(false, None, None, Some(Int32(1)))
    }

    /**
     * 安装深色默认主题（Night）
     */
    public func installDarkTheme(): Bool {
        return this.engine.installTheme(true, None, None, Some(Int32(2)))
    }

    /**
     * 通过 slug 安装指定浅色主题
     */
    public func installLightThemeBySlug(slug: String): Bool {
        return this.engine.installTheme(false, Some(slug), None, None)
    }

    /**
     * 通过 slug 安装指定深色主题
     */
    public func installDarkThemeBySlug(slug: String): Bool {
        return this.engine.installTheme(true, Some(slug), None, None)
    }

    // ==================== 壁纸列表 ====================

    /**
     * 获取云端壁纸列表（hash 增量）
     * 对应 iOS TelegramEngine.Themes.wallpapers(accountManager:forceUpdate:)
     * TL: account.getWallPapers#07967d36 hash:long = account.WallPapers
     *
     * @param hash  上次响应 hash（0 = 强制刷新；-1 = 使用内存 hash 缓存）
     */
    public func getWallPapers(hash: Int64): WallPapersResult {
        return this.engine.getWallPapers(hash)
    }

    /**
     * 强制刷新壁纸列表（忽略 hash 缓存）
     */
    public func refreshWallPapers(): WallPapersResult {
        return this.engine.getWallPapers(0)
    }

    // ==================== 聊天壁纸 ====================

    /**
     * 设置聊天壁纸（通过壁纸 id+accessHash 引用现有壁纸）
     * 对应 iOS messages.setChatWallPaper with InputWallPaper
     * TL: messages.setChatWallPaper#8ffacae1 flags.0?InputWallPaper
     *
     * @param peerId             目标对话 ID
     * @param peerType           "user" | "chat" | "channel"
     * @param accessHash         peer accessHash
     * @param wallpaperId        壁纸 ID
     * @param wallpaperAccessHash 壁纸 accessHash
     * @param forBoth            true = 双端同时设置
     */
    public func setChatWallPaper(peerId: Int64, peerType: String, accessHash: Int64,
                                  wallpaperId: Int64, wallpaperAccessHash: Int64,
                                  forBoth: Bool): Bool {
        return this.engine.setChatWallPaper(peerId, peerType, accessHash,
                                             wallpaperId, wallpaperAccessHash, forBoth)
    }

    /**
     * 复用现有壁纸（setExisting — 通过消息 id 引用）
     * TL: messages.setChatWallPaper flags.1 (id field)
     *
     * @param peerId    目标对话 ID
     * @param peerType  "user" | "chat" | "channel"
     * @param accessHash peer accessHash
     * @param msgId     含壁纸的消息 ID
     */
    public func setChatWallPaperById(peerId: Int64, peerType: String, accessHash: Int64, msgId: Int32): Bool {
        return this.engine.setChatWallPaperById(peerId, peerType, accessHash, msgId)
    }

    /**
     * 还原聊天壁纸为默认
     * TL: messages.setChatWallPaper flags.4 (revert=true)
     *
     * @param peerId    目标对话 ID
     * @param peerType  "user" | "chat" | "channel"
     * @param accessHash peer accessHash
     */
    public func revertChatWallPaper(peerId: Int64, peerType: String, accessHash: Int64): Bool {
        return this.engine.revertChatWallPaper(peerId, peerType, accessHash)
    }

    // ==================== 聊天主题 ====================

    /**
     * 设置聊天主题
     * 对应 iOS messages.setChatTheme
     * TL: messages.setChatTheme#e63be13f peer:InputPeer emoticon:string = Updates
     *
     * @param peerId    目标对话 ID
     * @param peerType  "user" | "chat" | "channel"
     * @param accessHash peer accessHash（channel/user 需要）
     * @param emoticon  主题表情符号字符串；传空字符串清除主题
     */
    public func setChatTheme(peerId: Int64, peerType: String, accessHash: Int64, emoticon: String): Bool {
        return this.engine.setChatTheme(peerId, peerType, accessHash, emoticon)
    }
}
