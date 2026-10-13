package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.core.mtproto.*

/**
 * ComposePollService — 创建投票 API 服务
 *
 * 封装 messages.sendMedia(inputMediaPoll) TL 方法，供 ComposePollScreenComponent 调用。
 *
 * 调用链:
 *   ComposePollService.sendPoll
 *     → InputMediaPoll (question + answers + flags)
 *     → MessagesSendMedia
 *     → MTProtoClient.sendRequest
 *
 * 支持的 poll 设置标志位 (poll#86e18161 flags:#):
 *   bit 1 (value 2): closed
 *   bit 2 (value 4): public_voters
 *   bit 3 (value 8): multiple_choice
 *   bit 4 (value 16): quiz
 */
public class ComposePollService {

    /**
     * 发送投票消息
     *
     * @param peerType  对话类型 ("user" / "chat" / "channel")
     * @param peerId    对话 ID
     * @param question  投票问题（必填，Telegram 限 255 字符）
     * @param answers   选项列表（2–10 条，每条 ≤100 字符）
     * @param anonymous 是否匿名（true = 不公开投票者，默认 true）
     * @param multipleChoice 是否允许多选
     * @param quiz      是否为测验模式（有正确答案）
     * @param replyToMsgId 回复的消息 ID（0 = 不回复）
     * @return SendMessageResult
     */
    public func sendPoll(
        peerType: String,
        peerId: Int64,
        question: String,
        answers: ArrayList<String>,
        anonymous!: Bool = true,
        multipleChoice!: Bool = false,
        quiz!: Bool = false,
        correctAnswers!: ArrayList<Int32> = ArrayList<Int32>(),
        replyToMsgId!: Int32 = 0
    ): SendMessageResult {
        Hilog.info(0, "CjTelegram", "[ComposePollService] sendPoll peer=${peerType}/${peerId} question=${question} answers=${answers.size} anon=${anonymous} multi=${multipleChoice} quiz=${quiz} correct=${correctAnswers.size}")
        let messageService = getRealMessageService()
        let result = messageService.sendPoll(
            peerType,
            peerId,
            question,
            answers,
            anonymous: anonymous,
            multipleChoice: multipleChoice,
            quiz: quiz,
            correctAnswers: correctAnswers,
            replyToMsgId: replyToMsgId
        )
        Hilog.info(0, "CjTelegram", "[ComposePollService] sendPoll result: success=${result.success} msgId=${result.messageId}")
        return result
    }
}

// ==================== 全局单例 accessor ====================

private var _composePollService: Option<ComposePollService> = None

/**
 * 获取 ComposePollService 单例
 */
public func getComposePollService(): ComposePollService {
    match (_composePollService) {
        case Some(svc) => return svc
        case None =>
            let svc = ComposePollService()
            _composePollService = Some(svc)
            return svc
    }
}
