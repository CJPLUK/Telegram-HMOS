package ohos_app_cangjie_entry.core.mtproto

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList

/**
 * 聊天输入区用到的 TL 方法与解析（非联系人栏、自动删除计时器）。
 *   messages.hidePeerSettingsBar#4facb138 peer:InputPeer = Bool（telegram_api.tl:2304）
 *   messages.reportSpam#cf1592db peer:InputPeer = Bool（iOS Api42.swift:9151）
 *   messages.getPeerSettings#efd9a6a2 peer:InputPeer = messages.PeerSettings（iOS Api42.swift:7901，
 *     appendInt32(-270948702)）→ messages.peerSettings#6880b94d settings chats users
 */

public class MessagesGetPeerSettings <: TLObject {
    public var peer: TLObject = InputPeerEmpty()

    public func getConstructorId(): UInt32 { return 0xefd9a6a2 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
    }
}

/** messages.reportSpam#cf1592db peer:InputPeer = Bool（iOS Api42.swift:9151 appendInt32(-820669733)） */
public class MessagesReportSpam <: TLObject {
    public var peer: TLObject = InputPeerEmpty()

    public func getConstructorId(): UInt32 { return 0xcf1592db }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
    }
}

public class MessagesHidePeerSettingsBar <: TLObject {
    public var peer: TLObject = InputPeerEmpty()

    public func getConstructorId(): UInt32 { return 0x4facb138 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeRawBytes(this.peer.toBytes())
    }
}

/**
 * 聊天输入区需要的 UserFull 字段（iOS CachedUserData：peerStatusSettings / autoremoveTimeout）。
 * bot_info 位于 ttl_period 之前，必须完整读过（顺带记下命令与 Menu 按钮类型）。字段顺序对照 iOS Api30.swift:1268 parse_userFull，
 * peerSettings 对照 Api20.swift:1672，botInfo 对照 Api2.swift:576。
 */
public class ChatPeerFullExtras {
    public var parsed: Bool = false
    public var hasScheduled: Bool = false
    public var blocked: Bool = false
    public var settingsFlags: Int32 = 0
    public var ttlPeriod: Int32 = 0
    public var hasBotInfo: Bool = false
    public var botCommands: ArrayList<(String, String)> = ArrayList<(String, String)>()
    /** 0 = botMenuButtonDefault / 无；1 = botMenuButtonCommands；2 = botMenuButton(web app) */
    public var menuButtonKind: Int32 = 0
    public var menuButtonText: String = ""
    public var menuButtonUrl: String = ""
    /**
     * users.userFull.users 里的该用户（iOS fetchAndUpdateCachedPeerData 用它更新 peer，
     * isContact 因此总是服务端最新值）；None = 响应里没定位到。
     */
    public var user: Option<UserResponse> = None
    /**
     * S6-05：userFull.wallpaper:flags.24?WallPaper（iOS CachedUserData.wallpaper，会话打开时
     * fetchAndUpdateCachedPeerData 据此决定该会话的壁纸）。hasWallpaper=false 表示服务端没有
     * 该会话的专属壁纸；wallpaperSlug 为空 = wallPaperNoFile（只有 settings 颜色）。
     */
    public var hasWallpaper: Bool = false
    public var wallpaperId: Int64 = 0
    public var wallpaperSlug: String = ""
    public var wallpaperColors: Array<UInt32> = Array<UInt32>()
    public var wallpaperIntensity: Int32 = 0

    public init() {}

    /** peerSettings 位（telegram_api.tl peerSettings）：report_spam 0 add_contact 1 block_contact 2 share_contact 3 need_contacts_exception 4 autoarchived 7 */
    public func canReport(): Bool { (this.settingsFlags & 1) != 0 }
    public func canAddContact(): Bool { (this.settingsFlags & 2) != 0 }
    public func canBlock(): Bool { (this.settingsFlags & 4) != 0 }
    public func canShareContact(): Bool { (this.settingsFlags & 8) != 0 }
    public func needContactsException(): Bool { (this.settingsFlags & 16) != 0 }
    public func autoArchived(): Bool { (this.settingsFlags & 128) != 0 }
}

public func readPeerSettingsFlags(d: TLDeserializer): Int32 {
    let _ = d.readUInt32()
    let flags = d.readInt32()
    if ((flags & (1 << 6)) != 0) { let _ = d.readInt32() }
    if ((flags & (1 << 9)) != 0) {
        let _ = d.readString()
        let _ = d.readInt32()
    }
    if ((flags & (1 << 13)) != 0) {
        let _ = d.readInt64()
        let _ = d.readString()
    }
    if ((flags & (1 << 14)) != 0) { let _ = d.readInt64() }
    if ((flags & (1 << 15)) != 0) { let _ = d.readString() }
    if ((flags & (1 << 16)) != 0) { let _ = d.readString() }
    if ((flags & (1 << 17)) != 0) { let _ = d.readInt32() }
    if ((flags & (1 << 18)) != 0) { let _ = d.readInt32() }
    return flags
}

private func readBotInfoInto(d: TLDeserializer, r: ChatPeerFullExtras): Unit {
    let _ = d.readUInt32()
    let flags = d.readInt32()
    r.hasBotInfo = true
    if ((flags & 1) != 0) { let _ = d.readInt64() }
    if ((flags & 2) != 0) { let _ = d.readString() }
    if ((flags & 16) != 0) { skipPhoto(d) }
    if ((flags & 32) != 0) { skipDocument(d) }
    if ((flags & 4) != 0) {
        let vec = d.readUInt32()
        if (vec == TLConstructors.VECTOR) {
            let n = d.readInt32()
            for (_i in 0..Int64(n)) {
                let _ = d.readUInt32()   // botCommand#c27ac8c7
                let command = d.readString()
                let description = d.readString()
                r.botCommands.add((command, description))
            }
        }
    }
    if ((flags & 8) != 0) {
        let ctor = d.readUInt32()
        if (ctor == 0x4258c205) {
            r.menuButtonKind = 1
        } else if (ctor == 0xc7b57ce6) {
            r.menuButtonKind = 2
            r.menuButtonText = d.readString()
            r.menuButtonUrl = d.readString()
        }
    }
    if ((flags & 128) != 0) { let _ = d.readString() }
    if ((flags & 256) != 0) {
        let _ = d.readUInt32()
        skipBotAppSettingsBody(d)
    }
    if ((flags & 512) != 0) {
        let _ = d.readUInt32()
        skipBotVerifierSettingsBody(d)
    }
}

/**
 * 在 users.userFull 尾部 users 向量里定位 id == userId 的 User：逐字节找 user 构造器
 * （当前 0x31774388 / 旧 0x020b1422 / 0x317a5722，小端）后完整解析，id 相同才采用。
 */
private func findUserInResponse(data: Array<Byte>, from: Int64, userId: Int64): Option<UserResponse> {
    var pos = if (from < 4) { 4 } else { from }
    while (pos + 12 <= data.size) {
        let b0 = UInt8(data[pos])
        let b1 = UInt8(data[pos + 1])
        let b2 = UInt8(data[pos + 2])
        let b3 = UInt8(data[pos + 3])
        let isUserCtor = (b0 == 0x88 && b1 == 0x43 && b2 == 0x77 && b3 == 0x31) ||
            (b0 == 0x22 && b1 == 0x14 && b2 == 0x0B && b3 == 0x02) ||
            (b0 == 0x22 && b1 == 0x57 && b2 == 0x7A && b3 == 0x31)
        if (isUserCtor) {
            try {
                let d = TLDeserializer(ByteUtils.slice(data, pos, data.size))
                let u = UserResponse.deserializeBoxed(d)
                if (u.id == userId && !u.isEmpty) {
                    return Some(u)
                }
            } catch (_e: Exception) {}
        }
        pos += 1
    }
    return None
}

/** users.userFull#3b6d152e full_user:UserFull chats users —— 只读到 ttl_period(flags.14) 为止，再定位 users 里的该用户。 */
public func parseChatPeerFullExtras(data: Array<Byte>, userId!: Int64 = 0): ChatPeerFullExtras {
    let r = ChatPeerFullExtras()
    if (data.size < 8) { return r }
    let d = TLDeserializer(data)
    try {
        let outer = d.readUInt32()
        if (outer != 0x3b6d152e) {
            Hilog.info(0, "CjTelegram", "[ChatPeerFullExtras] unexpected ctor 0x${toHex32(outer)}")
            return r
        }
        let _ = d.readUInt32()          // userFull
        let flags = d.readInt32()
        let _ = d.readInt32()           // flags2
        r.blocked = (flags & 1) != 0
        r.hasScheduled = (flags & (1 << 12)) != 0
        let _ = d.readInt64()           // id
        if ((flags & (1 << 1)) != 0) { let _ = d.readString() }
        r.settingsFlags = readPeerSettingsFlags(d)
        if ((flags & (1 << 21)) != 0) { skipPhoto(d) }
        if ((flags & (1 << 2)) != 0) { skipPhoto(d) }
        if ((flags & (1 << 22)) != 0) { skipPhoto(d) }
        let _ = skipPeerNotifySettings(d)
        if ((flags & (1 << 3)) != 0) { readBotInfoInto(d, r) }
        if ((flags & (1 << 6)) != 0) { let _ = d.readInt32() }
        let _ = d.readInt32()           // common_chats_count
        if ((flags & (1 << 11)) != 0) { let _ = d.readInt32() }
        if ((flags & (1 << 14)) != 0) { r.ttlPeriod = d.readInt32() }
        r.parsed = true
        if (userId != 0) {
            r.user = findUserInResponse(data, d.getOffset(), userId)
        }
        // S6-05：继续读到 wallpaper:flags.24（iOS Api30.swift Cons_userFull 字段序：ttl_period →
        // theme:flags.15?ChatTheme → private_forward_name:flags.16?string →
        // bot_group_admin_rights:flags.17?ChatAdminRights → bot_broadcast_admin_rights:flags.18?ChatAdminRights
        // → wallpaper:flags.24?WallPaper）。chatAdminRights#5fb224d5 只有 flags:# 一个字段。
        // 这段单独 try：失败只丢壁纸，不影响上面已解析好的输入区字段。
        if ((flags & (1 << 24)) != 0) {
            try {
                if ((flags & (1 << 15)) != 0) { skipChatTheme(d) }
                if ((flags & (1 << 16)) != 0) { let _ = d.readString() }
                if ((flags & (1 << 17)) != 0) { let _ = d.readUInt32(); let _ = d.readInt32() }
                if ((flags & (1 << 18)) != 0) { let _ = d.readUInt32(); let _ = d.readInt32() }
                // origin/main 把 parseThemeWallPaperIdentity 扩成 5 元组（末位 hasIntensity，仅 ThemeSettings 用）。
                let (wpId, wpSlug, wpColors, wpIntensity, _) = parseThemeWallPaperIdentity(d)
                r.hasWallpaper = true
                r.wallpaperId = wpId
                r.wallpaperSlug = wpSlug
                r.wallpaperColors = wpColors
                r.wallpaperIntensity = wpIntensity
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatPeerFullExtras] wallpaper parse: ${e}")
            }
        }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[ChatPeerFullExtras] partial parse: ${e}")
    }
    return r
}

/** messages.peerSettings#6880b94d settings:PeerSettings chats users —— 只取 settings.flags。 */
public func parsePeerSettingsFlags(data: Array<Byte>): Option<Int32> {
    if (data.size < 12) { return None }
    try {
        let d = TLDeserializer(data)
        let outer = d.readUInt32()
        if (outer != 0x6880b94d) { return None }
        return Some(readPeerSettingsFlags(d))
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[ChatPeerFullExtras] peerSettings parse: ${e}")
        return None
    }
}
