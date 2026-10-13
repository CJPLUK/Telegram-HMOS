package ohos_app_cangjie_entry.bindings

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.convert.*

/**
 * WidgetItemsUtilsBinding — 桌面小组件工具封装层
 *
 * 对应 iOS WidgetItemsUtils.swift 中 WidgetDataPeer.Message 扩展的平台层职责：
 *   iOS: 写入 AppGroup shared container（UserDefaults(suiteName:)），数据格式为 JSON
 *   HarmonyOS: 提供 WidgetItemData 的 JSON 序列化/反序列化逻辑；
 *              持久化读写（Preferences）由上层 services 完成，因为 services 层
 *              才能访问 UIAbilityContext（bindings 层禁止反向依赖 services）。
 *
 * 职责（纯逻辑，无 services / MTProto 调用）：
 *   1. 定义 WidgetItemData 数据传输对象（平行于 services.WidgetPeerItem，独立于 services 层）
 *   2. 将 WidgetItemData 列表序列化为 JSON 字符串
 *   3. 将 JSON 字符串反序列化为 WidgetItemData 列表
 *   4. 提供 WidgetItemData 与 JSON 之间的单条目编解码
 *
 * 不引用 services 层，避免 bindings ↔ services 循环依赖。
 * 实际持久化由 WidgetItemsUtilsUtils（utils 层）告知 services 层通过 Preferences 完成。
 *
 * S-64/R-69 自查（N/A）：
 *   本文件为纯逻辑服务类，无 @Component / build() / aboutToAppear，
 *   S-64（aboutToAppear 必须 public）和 R-69（spawn 返回值）均不适用。
 */

private var _widgetItemsUtilsBindingInstance: Option<WidgetItemsUtilsBinding> = None

/**
 * 获取 WidgetItemsUtilsBinding 单例
 */
public func getWidgetItemsUtilsBinding(): WidgetItemsUtilsBinding {
    match (_widgetItemsUtilsBindingInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = WidgetItemsUtilsBinding()
            _widgetItemsUtilsBindingInstance = Some(inst)
            return inst
    }
}

/**
 * 桌面小组件条目数据传输对象
 *
 * 与 services.WidgetPeerItem 字段一致，但独立定义于 bindings 层，
 * 以避免 bindings ↔ services 循环依赖。
 * services 层在调用序列化时需先将 WidgetPeerItem 转换为 WidgetItemData。
 */
public class WidgetItemData {
    public var peerId: Int64 = 0
    public var name: String = ""
    public var avatarText: String = ""
    public var lastMessage: String = ""
    public var unreadCount: Int64 = 0
    public var isMuted: Bool = false
    public var isGroup: Bool = false
    public var isChannel: Bool = false
    public var timestamp: Int64 = 0
    public var avatarLocalPath: String = ""

    public init() {}

    public init(
        peerId!: Int64,
        name!: String,
        avatarText!: String,
        lastMessage!: String,
        unreadCount!: Int64,
        isMuted!: Bool,
        isGroup!: Bool,
        isChannel!: Bool,
        timestamp!: Int64,
        avatarLocalPath!: String
    ) {
        this.peerId = peerId
        this.name = name
        this.avatarText = avatarText
        this.lastMessage = lastMessage
        this.unreadCount = unreadCount
        this.isMuted = isMuted
        this.isGroup = isGroup
        this.isChannel = isChannel
        this.timestamp = timestamp
        this.avatarLocalPath = avatarLocalPath
    }

    /**
     * 序列化为 JSON 对象字符串
     *
     * 对应 WidgetPeerItem.toJson()，格式保持一致以确保 Preferences 数据互通。
     */
    public func toJson(): String {
        let escaped = this.lastMessage
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
        let nameEsc = this.name
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
        let avatarEsc = this.avatarText
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
        let pathEsc = this.avatarLocalPath
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
        return "{\"peerId\":${this.peerId},\"name\":\"${nameEsc}\",\"avatarText\":\"${avatarEsc}\",\"lastMessage\":\"${escaped}\",\"unreadCount\":${this.unreadCount},\"isMuted\":${this.isMuted},\"isGroup\":${this.isGroup},\"isChannel\":${this.isChannel},\"timestamp\":${this.timestamp},\"avatarLocalPath\":\"${pathEsc}\"}"
    }
}

/**
 * 桌面小组件工具封装层（纯逻辑：JSON 序列化 / 反序列化）
 */
public class WidgetItemsUtilsBinding {

    /**
     * 将 WidgetItemData 列表序列化为 JSON 字符串
     *
     * 对应 iOS WidgetDataPeer 编码为 JSON 写入 AppGroup container 的逻辑。
     *
     * @param items  要序列化的条目列表
     * @return       JSON 数组字符串，空列表返回 "[]"
     */
    public func serializeItems(items: ArrayList<WidgetItemData>): String {
        if (items.isEmpty()) {
            return "[]"
        }
        var json: String = "["
        var first: Bool = true
        for (item in items) {
            if (!first) { json = json + "," }
            json = json + item.toJson()
            first = false
        }
        json = json + "]"
        return json
    }

    /**
     * 从 JSON 字符串反序列化 WidgetItemData 列表
     *
     * 对应 iOS 读取 AppGroup UserDefaults 后解析 JSON 的逻辑。
     * 格式严格对应 WidgetItemData.toJson() 的输出。
     *
     * @param json  JSON 数组字符串
     * @return      解析出的条目列表；解析失败或空数组返回空列表
     */
    public func deserializeItems(json: String): ArrayList<WidgetItemData> {
        let result = ArrayList<WidgetItemData>()
        let trimmed = json.trimAscii()
        if (trimmed.size <= 2) {
            return result
        }
        // 去掉外层 [ ]，使用 String 下标切片（对应 JsonParser.cj 中的 trimmed[1..n] 模式）
        let inner = trimmed[1..(trimmed.size - 1)]
        let objects = this.splitJsonObjects(inner)
        for (objStr in objects) {
            let item = this.parseJsonObject(objStr)
            match (item) {
                case Some(i) => result.add(i)
                case None => ()
            }
        }
        return result
    }

    // ==================== 私有辅助方法 ====================

    /**
     * 将 JSON 数组内容拆分为独立对象字符串列表
     *
     * 按嵌套深度追踪花括号，找到每个完整的 JSON 对象边界。
     * 使用 rune 数组追踪字符，用 String 切片提取子字符串。
     */
    private func splitJsonObjects(inner: String): ArrayList<String> {
        let objects = ArrayList<String>()
        var depth: Int32 = 0
        var start: Int64 = 0
        let runes = inner.toRuneArray()
        var i: Int64 = 0
        while (i < runes.size) {
            let ch = runes[i]
            if (ch == r'{') {
                if (depth == 0) { start = i }
                depth = depth + 1
            } else if (ch == r'}') {
                depth = depth - 1
                if (depth == 0) {
                    let objStr = String(runes[start..(i + 1)])
                    objects.add(objStr)
                }
            }
            i = i + 1
        }
        return objects
    }

    /**
     * 从单个 JSON 对象字符串解析 WidgetItemData
     *
     * 依赖 WidgetItemData.toJson() 的固定格式：
     * {"peerId":N,"name":"S","avatarText":"S","lastMessage":"S",
     *  "unreadCount":N,"isMuted":B,"isGroup":B,"isChannel":B,
     *  "timestamp":N,"avatarLocalPath":"S"}
     */
    private func parseJsonObject(obj: String): Option<WidgetItemData> {
        try {
            let item = WidgetItemData()
            item.peerId = this.extractInt64(obj, "peerId")
            item.name = this.extractString(obj, "name")
            item.avatarText = this.extractString(obj, "avatarText")
            item.lastMessage = this.extractString(obj, "lastMessage")
            item.unreadCount = this.extractInt64(obj, "unreadCount")
            item.isMuted = this.extractBool(obj, "isMuted")
            item.isGroup = this.extractBool(obj, "isGroup")
            item.isChannel = this.extractBool(obj, "isChannel")
            item.timestamp = this.extractInt64(obj, "timestamp")
            item.avatarLocalPath = this.extractString(obj, "avatarLocalPath")
            return Some(item)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[WidgetItemsUtilsBinding] parseJsonObject failed")
            return None
        }
    }

    /**
     * 从 JSON 字符串中提取指定键的 Int64 值
     *
     * searchKey 仅包含 ASCII 字符，故 .size 等于 rune 数。
     * 使用 rune 数组定位数字边界，String 切片提取，Int64.parse 转换（需 std.convert.*）。
     */
    private func extractInt64(json: String, key: String): Int64 {
        let searchKey = "\"${key}\":"
        let keyIdx = this.findSubstring(json, searchKey)
        if (keyIdx < 0) { return Int64(0) }
        let valueStart = keyIdx + Int64(searchKey.toRuneArray().size)
        let runes = json.toRuneArray()
        var i: Int64 = valueStart
        while (i < runes.size && (runes[i] == r' ' || runes[i] == r'\t')) {
            i = i + 1
        }
        let numStart = i
        if (i < runes.size && runes[i] == r'-') { i = i + 1 }
        while (i < runes.size && runes[i] >= r'0' && runes[i] <= r'9') {
            i = i + 1
        }
        if (i <= numStart) { return Int64(0) }
        let numStr = String(runes[numStart..i])
        return Int64.parse(numStr)
    }

    /**
     * 从 JSON 字符串中提取指定键的 Bool 值
     */
    private func extractBool(json: String, key: String): Bool {
        let searchKey = "\"${key}\":"
        let keyIdx = this.findSubstring(json, searchKey)
        if (keyIdx < 0) { return false }
        let valueStart = keyIdx + Int64(searchKey.toRuneArray().size)
        let runes = json.toRuneArray()
        var i: Int64 = valueStart
        while (i < runes.size && (runes[i] == r' ' || runes[i] == r'\t')) {
            i = i + 1
        }
        if (i + 4 <= runes.size) {
            let candidate = String(runes[i..(i + 4)])
            if (candidate == "true") { return true }
        }
        return false
    }

    /**
     * 从 JSON 字符串中提取指定键的 String 值（处理 JSON 转义：\\ 和 \"）
     *
     * 支持 WidgetItemData.toJson() 产生的两种转义序列：\\ 和 \"
     */
    private func extractString(json: String, key: String): String {
        let searchKey = "\"${key}\":\""
        let keyIdx = this.findSubstring(json, searchKey)
        if (keyIdx < 0) { return "" }
        let valueStart = keyIdx + Int64(searchKey.toRuneArray().size)
        let runes = json.toRuneArray()
        var result: String = ""
        var i: Int64 = valueStart
        while (i < runes.size) {
            let ch = runes[i]
            if (ch == r'\\') {
                if (i + 1 < runes.size) {
                    let next = runes[i + 1]
                    if (next == r'"') {
                        result = result + "\""
                        i = i + 2
                    } else if (next == r'\\') {
                        result = result + "\\"
                        i = i + 2
                    } else {
                        result = result + "\\"
                        i = i + 1
                    }
                } else {
                    i = i + 1
                }
            } else if (ch == r'"') {
                break
            } else {
                result = result + ch.toString()
                i = i + 1
            }
        }
        return result
    }

    /**
     * 在字符串中查找子串（均为 ASCII 键，rune 数 = size），返回起始 rune 索引，未找到返回 -1
     */
    private func findSubstring(haystack: String, needle: String): Int64 {
        let hRunes = haystack.toRuneArray()
        let nRunes = needle.toRuneArray()
        if (nRunes.size == 0) { return Int64(0) }
        if (hRunes.size < nRunes.size) { return Int64(-1) }
        let limit: Int64 = hRunes.size - nRunes.size
        var i: Int64 = 0
        while (i <= limit) {
            var matched: Bool = true
            var j: Int64 = 0
            while (j < nRunes.size) {
                if (hRunes[i + j] != nRunes[j]) {
                    matched = false
                    break
                }
                j = j + 1
            }
            if (matched) { return i }
            i = i + 1
        }
        return Int64(-1)
    }
}
