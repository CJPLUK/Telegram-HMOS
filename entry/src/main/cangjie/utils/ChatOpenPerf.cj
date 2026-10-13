package ohos_app_cangjie_entry.utils

import kit.PerformanceAnalysisKit.Hilog

/**
 * [ChatOpenPerf] —— 会话列表点按 → 会话页首屏内容 的耗时标记。
 *
 * ChatListPage 行点按时调用 chatOpenPerfBegin 记录原点；此后导航、页面构造、onAppear、
 * ensureLoaded、消息列表提交、List 首次布局、气泡挂载等关键点调用 chatOpenPerfMark，输出
 *   [ChatOpenPerf] t=<自点按毫秒> stage=<阶段>
 * 供真机 hilog 与逐帧截图对照。原点超过 CHAT_OPEN_PERF_WINDOW_MS 后所有标记自动静默，
 * 正常使用期（非刚点开会话）不产生日志。
 *
 * 所有写入都在 UI 线程（点按回调 / launch），Int64 读写在 arm64 上天然原子，诊断用途不加锁。
 */
const CHAT_OPEN_PERF_WINDOW_MS: Int64 = 8000

var _chatOpenPerfOrigin: Int64 = 0
var _chatOpenPerfBubbleCount: Int64 = 0

/** 点按会话行：记录原点并打 stage=tap。 */
public func chatOpenPerfBegin(chatId: Int64, peerType: String): Unit {
    _chatOpenPerfOrigin = monotonicNowMs()
    _chatOpenPerfBubbleCount = 0
    Hilog.info(0, "CjTelegram", "[ChatOpenPerf] t=0ms stage=tap peer=${peerType}:${chatId}")
}

/** 关键点标记；原点未设或已超出观测窗口时静默。 */
public func chatOpenPerfMark(stage: String): Unit {
    let origin = _chatOpenPerfOrigin
    if (origin == 0) { return }
    let elapsed = monotonicNowMs() - origin
    if (elapsed < 0 || elapsed > CHAT_OPEN_PERF_WINDOW_MS) { return }
    Hilog.info(0, "CjTelegram", "[ChatOpenPerf] t=${elapsed}ms stage=${stage}")
}

/** 气泡挂载计数：首个与每第 5 个各打一条，避免刷屏。 */
public func chatOpenPerfBubbleAppeared(messageId: Int64): Unit {
    if (_chatOpenPerfOrigin == 0) { return }
    _chatOpenPerfBubbleCount += 1
    let n = _chatOpenPerfBubbleCount
    if (n == 1 || n % 5 == 0) { chatOpenPerfMark("bubbleAppear n=${n} msg=${messageId}") }
}
