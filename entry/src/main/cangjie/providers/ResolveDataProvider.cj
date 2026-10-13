package ohos_app_cangjie_entry.providers

import ohos_app_cangjie_entry.services.{getResolveService, ResolvedPeer, DeepLinkInfo, ContactDisplayData}

/**
 * ResolveDataProvider — 将 Resolve API 数据转为 UI 可用的 ViewModel
 *
 * 对应 iOS TelegramEngine.Resolve 的 UI 适配层
 * 对应 telegram_engine_resolve feature TERES-IF-1
 *
 * 职责：
 * - resolvePeerByName：按名称解析 peer，返回类型 + ID
 * - resolveDeepLink：解析 t.me/ 链接
 * - resolvePhoneNumber：按手机号解析用户
 */
public class ResolveDataProvider {
    private let resolveService = getResolveService()

    /**
     * 按名称解析 peer（username 或 t.me/username 格式）
     * @param name 用户名，如 "durov" 或 "t.me/durov" 中的路径部分
     * @return 解析结果：peer 类型（user/chat/channel）+ ID + accessHash
     */
    public func resolvePeerByName(name: String): Option<ResolvedPeer> {
        var username = name
        if (username.startsWith("t.me/") || username.startsWith("telegram.me/")) {
            username = extractPathFromDeepLink(username)
        }
        if (username.startsWith("@")) {
            username = username[1..Int64(username.size)]
        }
        if (username.isEmpty()) {
            return None
        }
        return this.resolveService.resolvePeerByName(username)
    }

    /**
     * 解析 t.me/ 等 deep link 路径
     * @param path 链接路径，如 "tg://resolve?domain=durov" 或 "t.me/durov" 的路径部分
     * @return Deep link 信息（message、updateApp）
     */
    public func resolveDeepLink(path: String): Option<DeepLinkInfo> {
        var cleanPath = path
        if (path.startsWith("t.me/") || path.startsWith("telegram.me/")) {
            cleanPath = extractPathFromDeepLink(path)
        }
        if (path.startsWith("tg://")) {
            cleanPath = extractPathFromTgScheme(path)
        }
        if (cleanPath.isEmpty()) {
            return None
        }
        return this.resolveService.resolveDeepLink(cleanPath)
    }

    /**
     * 按手机号解析用户
     * @param phone 手机号（含国家码，如 +1234567890）
     * @return 找到的用户信息
     */
    public func resolvePhoneNumber(phone: String): Option<ContactDisplayData> {
        if (phone.isEmpty()) {
            return None
        }
        return this.resolveService.resolvePhoneNumber(phone)
    }

    /**
     * 从 t.me/xxx 或 telegram.me/xxx 提取路径
     */
    private func extractPathFromDeepLink(link: String): String {
        if (link.startsWith("t.me/")) {
            return link[5..Int64(link.size)]
        }
        if (link.startsWith("telegram.me/")) {
            return link[12..Int64(link.size)]
        }
        return link
    }

    /**
     * 从 tg:// 链接提取路径
     */
    private func extractPathFromTgScheme(link: String): String {
        if (link.startsWith("tg://")) {
            return link[5..Int64(link.size)]
        }
        return link
    }
}
