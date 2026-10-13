package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.utils.percentEncode
import std.collection.ArrayList

/**
 * 游戏高分记录
 * 对应 iOS Api.HighScore#highScore pos:int user_id:long score:int
 * Constructor ID: 0x73A379EB = 1940093419
 */
public class GameHighScore {
    public var pos: Int32 = 0
    public var userId: Int64 = 0
    public var score: Int32 = 0

    public static func deserialize(d: TLDeserializer): GameHighScore {
        let h = GameHighScore()
        h.pos = d.readInt32()
        h.userId = d.readInt64()
        h.score = d.readInt32()
        return h
    }
}

/**
 * messages.getGameHighScores#e822649d — 获取游戏排行榜
 * peer:InputPeer id:int user_id:InputUser = messages.HighScores
 * Constructor ID: 0xe822649d => Int32 as -400399203
 *
 * 序列化：writeUInt32(constructorId) + peer(boxed) + id(int32) + user_id(boxed)
 */
public class MessagesGetGameHighScores <: TLObject {
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var msgId: Int32 = 0
    public var userId: Int64 = 0
    public var userAccessHash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xe822649du32 }

    public func serialize(serializer: TLSerializer) {
        // peer = inputPeerUser (0xDDE8A54C)
        serializer.writeUInt32(0xDDE8A54Cu32)
        serializer.writeInt64(this.peerId)
        serializer.writeInt64(this.peerAccessHash)
        // id (message id, int32)
        serializer.writeInt32(this.msgId)
        // user_id = inputUser (0xf21158c6)
        serializer.writeUInt32(0xf21158c6u32)
        serializer.writeInt64(this.userId)
        serializer.writeInt64(this.userAccessHash)
    }
}

/**
 * messages.setGameScore#8ef8ecc0 — 设置游戏分数 (P2-039 share_score TL ctor)
 *
 * flags:# edit_message:flags.0?true force:flags.1?true
 * peer:InputPeer id:int user_id:InputUser score:int
 * Constructor ID: 0x8ef8ecc0 (iOS TelegramApi/Sources/Api42.swift:9908)
 *
 * 序列化: writeUInt32(constructorId) + flags(int32) + peer(boxed) + id(int32) + user_id(boxed) + score(int32)
 */
public class MessagesSetGameScore <: TLObject {
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var msgId: Int32 = 0
    public var userId: Int64 = 0
    public var userAccessHash: Int64 = 0
    public var score: Int32 = 0
    public var editMessage: Bool = true
    public var force: Bool = false

    public func getConstructorId(): UInt32 { return 0x8ef8ecc0u32 }

    public func serialize(serializer: TLSerializer) {
        // flags: bit0=edit_message, bit1=force
        var flags: Int32 = 0
        if (this.editMessage) { flags = flags | 1 }
        if (this.force) { flags = flags | 2 }
        serializer.writeInt32(flags)
        // peer = inputPeerUser (0xDDE8A54C)
        serializer.writeUInt32(0xDDE8A54Cu32)
        serializer.writeInt64(this.peerId)
        serializer.writeInt64(this.peerAccessHash)
        // id (message id, int32)
        serializer.writeInt32(this.msgId)
        // user_id = inputUser (0xf21158c6)
        serializer.writeUInt32(0xf21158c6u32)
        serializer.writeInt64(this.userId)
        serializer.writeInt64(this.userAccessHash)
        // score
        serializer.writeInt32(this.score)
    }
}

/**
 * 游戏服务
 * 对应 iOS GameControllerNode — 封装 messages.getGameHighScores / setGameScore TL 调用
 *
 * 调用链: GameService.getHighScores() → getMTProtoClient().sendRequest() → TL response parse
 *         GameService.setScore()     → getMTProtoClient().sendRequest() → TL response (Updates)
 */
private var _gameServiceInstance: Option<GameService> = None

public func getGameService(): GameService {
    match (_gameServiceInstance) {
        case Some(svc) => return svc
        case None =>
            let svc = GameService()
            _gameServiceInstance = Some(svc)
            return svc
    }
}

public class GameService {

    /**
     * 获取游戏排行榜
     * @param peerId      对方 peer ID (user_id)
     * @param peerAccessHash 对方 access hash
     * @param msgId       游戏消息 ID
     * @param userId      查询用户 ID
     * @param userAccessHash 查询用户 access hash
     * @return            排行榜列表（最多前 N 名）
     */
    public func getHighScores(peerId: Int64, peerAccessHash: Int64, msgId: Int32,
                              userId: Int64, userAccessHash: Int64): ArrayList<GameHighScore> {
        let client = getMTProtoClient()

        let req = MessagesGetGameHighScores()
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        req.msgId = msgId
        req.userId = userId
        req.userAccessHash = userAccessHash

        Hilog.info(0, "CjTelegram", "[GameService] Sending messages.getGameHighScores")
        let responseData = client.sendRequest(req.toBytes())
        Hilog.info(0, "CjTelegram", "[GameService] Response size: ${responseData.size}")

        let result = ArrayList<GameHighScore>()
        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[GameService] Empty response")
            return result
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        // RPC error
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19u32) {
            let code = d.readInt32()
            let msg = d.readString()
            Hilog.info(0, "CjTelegram", "[GameService] RPC error ${code}: ${msg}")
            return result
        }
        // messages.highScores#9a3bfd99 — constructor 0x9a3bfd99 = -1707344487 unsigned = 2587622857
        // In UInt32 space: 0x9a3bfd99
        if (constructor != 0x9a3bfd99u32) {
            Hilog.info(0, "CjTelegram", "[GameService] Unexpected constructor")
            return result
        }
        // scores: Vector<HighScore>
        let _ = d.readUInt32() // VECTOR constructor
        let scoresCount = d.readInt32()
        var i: Int32 = 0
        while (i < scoresCount) {
            let _ = d.readUInt32() // highScore constructor 0x73a379eb
            let hs = GameHighScore.deserialize(d)
            result.add(hs)
            i += 1
        }
        // users: Vector<User> — skip (not needed for display)
        Hilog.info(0, "CjTelegram", "[GameService] Parsed ${scoresCount} high scores")
        return result
    }

    /**
     * 设置游戏分数 (P2-039 messages.setGameScore)
     *
     * 对应 iOS messages.setGameScore#8ef8ecc0
     * Constructor ID: 0x8ef8ecc0 (Api42.swift:9908)
     *
     * @param peerId      对方 peer ID
     * @param peerAccessHash 对方 access hash
     * @param msgId       游戏消息 ID
     * @param userId      玩家用户 ID
     * @param userAccessHash 玩家 access hash
     * @param score       分数
     * @param editMessage 是否编辑消息中的分数（默认 true）
     * @param force       是否强制覆盖已有更高分（默认 false）
     * @return            true=成功, false=失败/RPC错误
     */
    public func setScore(peerId: Int64, peerAccessHash: Int64, msgId: Int32,
                         userId: Int64, userAccessHash: Int64,
                         score: Int32, editMessage!: Bool = true, force!: Bool = false): Bool {
        let client = getMTProtoClient()

        let req = MessagesSetGameScore()
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        req.msgId = msgId
        req.userId = userId
        req.userAccessHash = userAccessHash
        req.score = score
        req.editMessage = editMessage
        req.force = force

        Hilog.info(0, "CjTelegram", "[GameService] Sending messages.setGameScore score=${score}")
        let responseData = client.sendRequest(req.toBytes())
        Hilog.info(0, "CjTelegram", "[GameService] setGameScore response size: ${responseData.size}")

        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[GameService] setGameScore: empty response")
            return false
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19u32) {
            let code = d.readInt32()
            let msg = d.readString()
            Hilog.info(0, "CjTelegram", "[GameService] setGameScore RPC error ${code}: ${msg}")
            return false
        }
        Hilog.info(0, "CjTelegram", "[GameService] setGameScore ok constructor=0x${constructor}")
        return true
    }

    /**
     * 构造游戏分享链接
     * @param botUsername  Bot 用户名
     * @param gameName     游戏 short name
     * @return             https://t.me/<botUsername>?game=<gameName>
     */
    public func buildShareUrl(botUsername: String, gameName: String): String {
        return "https://t.me/" + percentEncode(botUsername) + "?game=" + percentEncode(gameName)
    }

}
