package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.{
    getMTProtoClient,
    HelpGetPremiumPromo,
    TLDeserializer,
    TLConstructors
}
import std.collection.ArrayList

/**
 * Premium 会员服务
 *
 * 封装 Premium 相关的 TL 方法调用
 * 调用链: Service → MTProtoClient.sendRequest()
 *
 * 对应 iOS PremiumUI: engine.help.getPremiumPromo
 */
private var _premiumServiceInstance: Option<PremiumService> = None

public func getPremiumService(): PremiumService {
    match (_premiumServiceInstance) {
        case Some(s) => s
        case None =>
            let s = PremiumService()
            _premiumServiceInstance = Some(s)
            s
    }
}

/**
 * Premium 推广信息解析结果（简化版）
 * help.premiumPromo#5334759c 包含 status_text, video_sections, period_options, users 等
 */
public class PremiumPromoResult {
    public var statusText: String = ""
    public var videoSections: ArrayList<String> = ArrayList<String>()
    /** Same-index pairing with videoSections, as defined by help.premiumPromo. */
    public var videos: ArrayList<GifItem> = ArrayList<GifItem>()
    public var periodOptions: ArrayList<PremiumPeriodOption> = ArrayList<PremiumPeriodOption>()
    public var isPremium: Bool = false
    public var parseOk: Bool = false
}

/**
 * 订阅周期选项
 */
public class PremiumPeriodOption {
    public var months: Int32 = 0
    public var amount: Int64 = 0
    public var currency: String = ""
    public var botUrl: String = ""
    public var storeProduct: String = ""
}

public class PremiumService {

    /**
     * 获取 Premium 推广信息
     * @return PremiumPromoResult 解析后的推广信息，parseOk=false 表示解析失败
     */
    public func getPremiumPromo(): PremiumPromoResult {
        let result = PremiumPromoResult()
        try {
            let req = HelpGetPremiumPromo()
            let client = getMTProtoClient()
            let responseData = client.sendRequest(req.toBytes())
            if (responseData.size < 4) {
                Hilog.info(0, "CjTelegram", "[PremiumService] getPremiumPromo: empty response")
                return result
            }
            let d = TLDeserializer(responseData)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let _ = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[PremiumService] getPremiumPromo RPC error: ${errMsg}")
                return result
            }
            if (ctor == 0x5334759c) {
                result.statusText = d.readString()
                skipMessageEntities(d)
                parseVideoSections(d, result)
                parseVideos(d, result)
                parsePeriodOptions(d, result)
                skipUsers(d)
                result.parseOk = true
                Hilog.info(0, "CjTelegram", "[PremiumService] getPremiumPromo ok, options: ${result.periodOptions.size}")
            } else {
                Hilog.info(0, "CjTelegram", "[PremiumService] getPremiumPromo unknown ctor")
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PremiumService] getPremiumPromo exception")
        }
        return result
    }

    private func skipMessageEntities(d: TLDeserializer): Unit {
        let vecCtor = d.readUInt32()
        if (vecCtor != 0x1cb5c415) { return }
        let count = d.readInt32()
        for (_i in 0..Int64(count)) {
            let entityCtor = d.readUInt32()
            let _ = d.readInt32()
            let _ = d.readInt32()
            if (entityCtor == 0x73924be0) {
                let _ = d.readString()
            } else if (entityCtor == 0x76a6d327) {
                let _ = d.readString()
            } else if (entityCtor == 0xdc7b1140) {
                let _ = d.readInt64()
            } else if (entityCtor == 0xc8cf05f8) {
                let _ = d.readInt64()
            } else if (entityCtor == 0xf1ccaaac) {
                let flags = d.readInt32()
                if ((flags & 1) != 0) { let _ = d.readUInt32() }
            }
        }
    }

    private func parseVideoSections(d: TLDeserializer, result: PremiumPromoResult): Unit {
        let vecCtor = d.readUInt32()
        if (vecCtor != 0x1cb5c415) { return }
        let count = d.readInt32()
        for (_i in 0..Int64(count)) {
            result.videoSections.add(d.readString())
        }
    }

    private func parseVideos(d: TLDeserializer, result: PremiumPromoResult): Unit {
        let vecCtor = d.readUInt32()
        if (vecCtor != 0x1cb5c415) { return }
        let count = d.readInt32()
        for (_i in 0..Int64(count)) {
            // PremiumUI pairs video_sections[n] with videos[n]. Reuse the
            // complete Document parser already used by the GIF/video stack so
            // the cursor remains aligned for period_options and the exact
            // server video can be downloaded by id/access_hash/file_reference.
            result.videos.add(parseGifDocument(d))
        }
    }

    private func parsePeriodOptions(d: TLDeserializer, result: PremiumPromoResult): Unit {
        let vecCtor = d.readUInt32()
        if (vecCtor != 0x1cb5c415) { return }
        let count = d.readInt32()
        for (_i in 0..Int64(count)) {
            let optCtor = d.readUInt32()
            if (optCtor == 0x5f2d1df2) {
                let opt = PremiumPeriodOption()
                let flags = d.readInt32()
                // TelegramApi/Api22.swift is authoritative here:
                // transaction is flags.3 and precedes months; store_product is
                // flags.0 and follows bot_url. Reading flags.0 at the front
                // shifted the whole vector and made every price option vanish.
                if ((flags & 8) != 0) { let _ = d.readString() }
                opt.months = d.readInt32()
                opt.currency = d.readString()
                opt.amount = d.readInt64()
                opt.botUrl = d.readString()
                if ((flags & 1) != 0) { opt.storeProduct = d.readString() }
                result.periodOptions.add(opt)
            }
        }
    }

    private func skipUsers(d: TLDeserializer): Unit {
        let vecCtor = d.readUInt32()
        if (vecCtor != 0x1cb5c415) { return }
        let count = d.readInt32()
        for (_i in 0..Int64(count)) {
            let userCtor = d.readUInt32()
            if (userCtor == 0x2e13f4c3 || userCtor == 0xd3bc4b7a) {
                let flags = d.readInt32()
                let _ = d.readInt64()
                if ((flags & 1) != 0) { let _ = d.readInt64() }
                if ((flags & 2) != 0) { let _ = d.readString() }
                if ((flags & 4) != 0) { let _ = d.readString() }
                if ((flags & 8) != 0) { let _ = d.readString() }
                if ((flags & 16) != 0) { let _ = d.readString() }
                if ((flags & 32) != 0) { let _ = d.readInt64() }
                if ((flags & 64) != 0) { let _ = d.readInt32() }
                if ((flags & 128) != 0) { let _ = d.readInt32() }
                if ((flags & 256) != 0) { let _ = d.readInt32() }
                if ((flags & 512) != 0) { let _ = d.readString() }
                if ((flags & 1024) != 0) { let _ = d.readInt64() }
            }
        }
    }
}
