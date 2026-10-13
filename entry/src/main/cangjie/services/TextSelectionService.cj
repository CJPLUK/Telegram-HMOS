package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.sync.ReentrantMutex
import ohos_app_cangjie_entry.utils.copyText

/**
 * 文本选择状态：持有当前选区的起止字符索引
 */
public class TextSelectionRange {
    public var start: Int64
    public var end: Int64

    public init(s: Int64, e: Int64) {
        this.start = s
        this.end = e
    }

    public func length(): Int64 {
        if (this.end > this.start) { this.end - this.start } else { Int64(0) }
    }

    public func isEmpty(): Bool {
        this.end <= this.start
    }
}

/**
 * TextSelectionService — 文本选择功能的核心数据层
 *
 * 职责：
 *   1. 维护当前选区 (range)
 *   2. 从原始文本按选区提取子串
 *   3. 将选中文本写入系统剪切板（HarmonyOS: BasicServicesKit PasteboardKit）
 *   4. 暴露 onCopyCallback / onQuoteCallback 供 UI 层注册回调
 *
 * iOS 原版 TextSelectionNode 的 performAction(.copy) 直接操作 UIPasteboard.general.string。
 * 本实现对应 HarmonyOS 侧的系统剪切板写入（纯本地操作，无 MTProto 调用）。
 */
public class TextSelectionService {
    private var mutex: ReentrantMutex = ReentrantMutex()

    // 当前选区
    private var _range: TextSelectionRange = TextSelectionRange(0, 0)

    // 被选中的完整源文本（由外部在每次文本更新时写入）
    private var _sourceText: String = ""

    // 外部注册的回调
    public var onCopyCallback: (String) -> Unit = { _text: String => }
    public var onQuoteCallback: (String, Int64, Int64) -> Unit = { _text: String, _start: Int64, _end: Int64 => }

    public init() {}

    // ==================== 选区管理 ====================

    /**
     * 设置源文本（由 TextSelectionComponent 在绑定消息时调用）
     */
    public func setSourceText(text: String): Unit {
        this.mutex.lock()
        this._sourceText = text
        this.mutex.unlock()
    }

    /**
     * 设置选区范围（由手势拖拽或长按词选触发）
     */
    public func setSelection(start: Int64, end: Int64): Unit {
        this.mutex.lock()
        let safeStart = if (start < 0) { Int64(0) } else { start }
        let textLen = Int64(this._sourceText.size)
        let safeEnd = if (end > textLen) { textLen } else { end }
        this._range = TextSelectionRange(
            if (safeStart < safeEnd) { safeStart } else { safeEnd },
            if (safeStart < safeEnd) { safeEnd } else { safeStart }
        )
        this.mutex.unlock()
    }

    /**
     * 清除选区
     */
    public func clearSelection(): Unit {
        this.mutex.lock()
        this._range = TextSelectionRange(0, 0)
        this.mutex.unlock()
    }

    /**
     * 全选
     */
    public func selectAll(): Unit {
        this.mutex.lock()
        this._range = TextSelectionRange(0, Int64(this._sourceText.size))
        this.mutex.unlock()
    }

    /**
     * 获取当前选区（只读拷贝）
     */
    public func getRange(): TextSelectionRange {
        this.mutex.lock()
        let r = TextSelectionRange(this._range.start, this._range.end)
        this.mutex.unlock()
        return r
    }

    /**
     * 判断当前是否有非空选区
     */
    public func hasSelection(): Bool {
        this.mutex.lock()
        let result = !this._range.isEmpty()
        this.mutex.unlock()
        return result
    }

    // ==================== 文本提取 ====================

    /**
     * 按选区从源文本提取子串
     * 返回 UTF-8 安全的子串（仓颉 String.size 是 UTF-8 字节数，
     * 需要 toRuneArray() 按 Unicode codepoint 截取）
     */
    public func getSelectedText(): String {
        this.mutex.lock()
        let r = this._range
        let src = this._sourceText
        this.mutex.unlock()

        if (r.isEmpty()) { return "" }

        let runes = src.toRuneArray()
        let totalCodepoints = Int64(runes.size)
        let safeStart = if (r.start >= totalCodepoints) { totalCodepoints } else { r.start }
        let safeEnd = if (r.end > totalCodepoints) { totalCodepoints } else { r.end }
        if (safeStart >= safeEnd) { return "" }

        let len = safeEnd - safeStart
        var result = ""
        var i: Int64 = safeStart
        while (i < safeEnd) {
            result = result + String(runes[i])
            i = i + 1
        }
        return result
    }

    // ==================== 剪切板操作 ====================

    /**
     * 将选中文本复制到系统剪切板。
     *
     * HarmonyOS PasteboardKit API:
     *   import kit.BasicServicesKit.{SystemPasteboard, PasteData}
     *   SystemPasteboard.getSystemPasteboard().setData(PasteData.createPlainTextData(text))
     *
     * KB 查询未在知识库中找到 PasteboardKit 仓颉绑定签名（最高分 0.016，与意图无关），
     * 故 fallback: 实现完整调用链并记录 unresolved_api_decision；
     * 同时通过 onCopyCallback 将已选文本回传给调用方，确保 UI 层可感知复制完成。
     *
     * 见 unresolved_api_decisions[0]。
     */
    public func copySelectedText(): Unit {
        let text = this.getSelectedText()
        if (text.size == 0) { return }

        // 系统剪切板写入（通过 PasteboardUtils.copyText NDK 桥真写系统剪贴板）
        let ok = copyText(text)
        if (ok) {
            Hilog.info(0, "CjTelegram", "[TextSel] copy to system clipboard ok, len=${text.size}")
        } else {
            Hilog.info(0, "CjTelegram", "[TextSel] copy to system clipboard failed, len=${text.size}")
        }
        this.onCopyCallback(text)
    }

    /**
     * 将选中文本作为引用回调给消息层（用于引用回复）
     */
    public func quoteSelectedText(): Unit {
        let text = this.getSelectedText()
        if (text.size == 0) { return }

        let r = this.getRange()
        Hilog.info(0, "CjTelegram", "[TextSel] quote text")
        this.onQuoteCallback(text, r.start, r.end)
    }

    /**
     * 按词边界扩展选区（对应 iOS long-press 初始词选）
     * 简化实现：从 tapIndex 向两端扩展到空格/标点边界
     */
    public func selectWordAt(charIndex: Int64): Unit {
        this.mutex.lock()
        let src = this._sourceText
        this.mutex.unlock()

        if (src.size == 0) { return }

        let runes = src.toRuneArray()
        let total = Int64(runes.size)
        if (charIndex >= total || charIndex < 0) { return }

        var wordStart = charIndex
        var wordEnd = charIndex + 1

        // 向左扩展到词边界
        while (wordStart > 0) {
            let r = runes[wordStart - 1]
            if (isWordSeparator(r)) { break }
            wordStart = wordStart - 1
        }

        // 向右扩展到词边界
        while (wordEnd < total) {
            let r = runes[wordEnd]
            if (isWordSeparator(r)) { break }
            wordEnd = wordEnd + 1
        }

        this.setSelection(wordStart, wordEnd)
    }

    // ==================== 内部工具 ====================

    private func isWordSeparator(r: Rune): Bool {
        let code = UInt32(r)
        // 空格、换行、制表符、常见标点
        return code == 32u32 || code == 10u32 || code == 13u32 || code == 9u32 ||
               code == 44u32 || code == 46u32 || code == 33u32 || code == 63u32 ||
               code == 59u32 || code == 58u32 || code == 34u32 || code == 39u32
    }
}

// ==================== 单例访问器 ====================

private var _globalTextSelectionService: ?TextSelectionService = None

/**
 * 获取全局 TextSelectionService 实例
 * 每个聊天会话在打开文本选择时创建一个，关闭后释放
 */
public func getTextSelectionService(): TextSelectionService {
    match (_globalTextSelectionService) {
        case Some(svc) => svc
        case None =>
            let svc = TextSelectionService()
            _globalTextSelectionService = Some(svc)
            svc
    }
}

/**
 * 重置 TextSelectionService（会话结束时调用）
 */
public func resetTextSelectionService(): Unit {
    _globalTextSelectionService = None
}
