package ohos_app_cangjie_entry.services

import kit.ArkUI.*
import std.collection.*
import std.convert.*

/**
 * JSON 解析工具类
 * 简化版 JSON 解析，满足 MVP 需求
 */
public class JsonParser {
    
    /**
     * 解析 JSON 字符串为 JsonObject
     */
    public static func parseObject(json: String): JsonObject {
        let trimmed = json.trimAscii()
        if (!trimmed.startsWith("{")) {
            return JsonObject()
        }
        
        let obj = JsonObject()
        let content = trimmed[1..(trimmed.size - 1)]
        
        obj.parseContent(content)
        return obj
    }
    
    /**
     * 解析 JSON 数组字符串为 JsonArray
     */
    public static func parseArray(json: String): JsonArray {
        let trimmed = json.trimAscii()
        if (!trimmed.startsWith("[")) {
            return JsonArray()
        }
        
        let arr = JsonArray()
        let content = trimmed[1..(trimmed.size - 1)]
        
        arr.parseContent(content)
        return arr
    }
    
    /**
     * 将 JsonObject 转换为 JSON 字符串
     */
    public static func stringify(obj: JsonObject): String {
        return obj.toJsonString()
    }
}

/**
 * JSON 对象类
 */
public class JsonObject {
    private var data: HashMap<String, JsonValue> = HashMap<String, JsonValue>()
    
    public func getString(key: String): String {
        let value = this.data.get(key)
        if (value.isSome()) {
            return value.getOrThrow().asString()
        }
        return ""
    }
    
    public func getInt(key: String): Int64 {
        let value = this.data.get(key)
        if (value.isSome()) {
            return value.getOrThrow().asInt()
        }
        return 0
    }
    
    public func getFloat(key: String): Float64 {
        let value = this.data.get(key)
        if (value.isSome()) {
            return value.getOrThrow().asFloat()
        }
        return 0.0
    }
    
    public func getBool(key: String): Bool {
        let value = this.data.get(key)
        if (value.isSome()) {
            return value.getOrThrow().asBool()
        }
        return false
    }
    
    public func getObject(key: String): JsonObject {
        let value = this.data.get(key)
        if (value.isSome()) {
            return value.getOrThrow().asObject()
        }
        return JsonObject()
    }
    
    public func getArray(key: String): JsonArray {
        let value = this.data.get(key)
        if (value.isSome()) {
            return value.getOrThrow().asArray()
        }
        return JsonArray()
    }
    
    public func has(key: String): Bool {
        return this.data.contains(key)
    }
    
    public func setString(key: String, value: String) {
        this.data[key] = JsonValue.fromString(value)
    }
    
    public func setInt(key: String, value: Int64) {
        this.data[key] = JsonValue.fromInt(value)
    }
    
    public func setBool(key: String, value: Bool) {
        this.data[key] = JsonValue.fromBool(value)
    }
    
    public func setObject(key: String, value: JsonObject) {
        this.data[key] = JsonValue.fromObject(value)
    }
    
    public func setArray(key: String, value: JsonArray) {
        this.data[key] = JsonValue.fromArray(value)
    }
    
    public func toJsonString(): String {
        var result = "{"
        var first = true
        
        for ((key, value) in this.data) {
            if (!first) {
                result += ","
            }
            result += "\"" + key + "\":" + value.toJsonString()
            first = false
        }
        
        result += "}"
        return result
    }
    
    internal func parseContent(content: String) {
        var remaining = content.trimAscii()
        
        while (remaining.size > 0) {
            remaining = remaining.trimAscii()
            if (remaining.startsWith(",")) {
                remaining = remaining[1..].trimAscii()
            }
            
            if (remaining.size == 0) {
                break
            }
            
            let keyResult = parseStringValue(remaining)
            let key = keyResult[0]
            remaining = keyResult[1].trimAscii()
            
            if (remaining.startsWith(":")) {
                remaining = remaining[1..].trimAscii()
            }
            
            let valueResult = parseValue(remaining)
            this.data[key] = valueResult[0]
            remaining = valueResult[1]
        }
    }
}

/**
 * JSON 数组类
 */
public class JsonArray {
    private var items: ArrayList<JsonValue> = ArrayList<JsonValue>()
    
    public func size(): Int64 {
        return this.items.size
    }
    
    public func getString(index: Int64): String {
        if (index >= 0 && index < this.items.size) {
            let optItem = this.items.get(index)
            if (optItem.isSome()) {
                return optItem.getOrThrow().asString()
            }
        }
        return ""
    }
    
    public func getInt(index: Int64): Int64 {
        if (index >= 0 && index < this.items.size) {
            let optItem = this.items.get(index)
            if (optItem.isSome()) {
                return optItem.getOrThrow().asInt()
            }
        }
        return 0
    }
    
    public func getObject(index: Int64): JsonObject {
        if (index >= 0 && index < this.items.size) {
            let optItem = this.items.get(index)
            if (optItem.isSome()) {
                return optItem.getOrThrow().asObject()
            }
        }
        return JsonObject()
    }
    
    public func getObjects(): ArrayList<JsonObject> {
        var result = ArrayList<JsonObject>()
        for (item in this.items) {
            result.add(item.asObject())
        }
        return result
    }
    
    public func addString(value: String) {
        this.items.add(JsonValue.fromString(value))
    }
    
    public func addInt(value: Int64) {
        this.items.add(JsonValue.fromInt(value))
    }
    
    public func addObject(value: JsonObject) {
        this.items.add(JsonValue.fromObject(value))
    }
    
    public func toJsonString(): String {
        var result = "["
        var first = true
        
        for (item in this.items) {
            if (!first) {
                result += ","
            }
            result += item.toJsonString()
            first = false
        }
        
        result += "]"
        return result
    }
    
    internal func parseContent(content: String) {
        var remaining = content.trimAscii()
        
        while (remaining.size > 0) {
            remaining = remaining.trimAscii()
            if (remaining.startsWith(",")) {
                remaining = remaining[1..].trimAscii()
            }
            
            if (remaining.size == 0) {
                break
            }
            
            let valueResult = parseValue(remaining)
            this.items.add(valueResult[0])
            remaining = valueResult[1]
        }
    }
}

/**
 * JSON 值类型枚举
 */
public enum JsonValueType {
    | STRING
    | INT
    | FLOAT
    | BOOL
    | OBJECT
    | ARRAY
    | NULL
}

/**
 * JSON 值类
 */
public class JsonValue {
    public var valueType: JsonValueType = JsonValueType.NULL
    
    private var stringValue: String = ""
    private var intValue: Int64 = 0
    private var floatValue: Float64 = 0.0
    private var boolValue: Bool = false
    private var objectValue: JsonObject = JsonObject()
    private var arrayValue: JsonArray = JsonArray()
    
    public static func fromString(value: String): JsonValue {
        let v = JsonValue()
        v.valueType = JsonValueType.STRING
        v.stringValue = value
        return v
    }
    
    public static func fromInt(value: Int64): JsonValue {
        let v = JsonValue()
        v.valueType = JsonValueType.INT
        v.intValue = value
        return v
    }
    
    public static func fromFloat(value: Float64): JsonValue {
        let v = JsonValue()
        v.valueType = JsonValueType.FLOAT
        v.floatValue = value
        return v
    }
    
    public static func fromBool(value: Bool): JsonValue {
        let v = JsonValue()
        v.valueType = JsonValueType.BOOL
        v.boolValue = value
        return v
    }
    
    public static func fromObject(value: JsonObject): JsonValue {
        let v = JsonValue()
        v.valueType = JsonValueType.OBJECT
        v.objectValue = value
        return v
    }
    
    public static func fromArray(value: JsonArray): JsonValue {
        let v = JsonValue()
        v.valueType = JsonValueType.ARRAY
        v.arrayValue = value
        return v
    }
    
    public static func fromNull(): JsonValue {
        let v = JsonValue()
        v.valueType = JsonValueType.NULL
        return v
    }
    
    public func asString(): String {
        match (this.valueType) {
            case STRING => this.stringValue
            case INT => this.intValue.toString()
            case FLOAT => this.floatValue.toString()
            case BOOL => if (this.boolValue) { "true" } else { "false" }
            case _ => ""
        }
    }
    
    public func asInt(): Int64 {
        match (this.valueType) {
            case INT => this.intValue
            case FLOAT => Int64(this.floatValue)
            case STRING => this.parseStringToInt()
            case _ => 0
        }
    }
    
    private func parseStringToInt(): Int64 {
        try {
            return Int64.parse(this.stringValue)
        } catch (_: Exception) {
            return 0
        }
    }
    
    public func asFloat(): Float64 {
        match (this.valueType) {
            case FLOAT => this.floatValue
            case INT => Float64(this.intValue)
            case STRING => this.parseStringToFloat()
            case _ => 0.0
        }
    }
    
    private func parseStringToFloat(): Float64 {
        try {
            return Float64.parse(this.stringValue)
        } catch (_: Exception) {
            return 0.0
        }
    }
    
    public func asBool(): Bool {
        match (this.valueType) {
            case BOOL => this.boolValue
            case STRING => this.stringValue == "true"
            case INT => this.intValue != 0
            case _ => false
        }
    }
    
    public func asObject(): JsonObject {
        match (this.valueType) {
            case OBJECT => this.objectValue
            case _ => JsonObject()
        }
    }
    
    public func asArray(): JsonArray {
        match (this.valueType) {
            case ARRAY => this.arrayValue
            case _ => JsonArray()
        }
    }
    
    public func isNull(): Bool {
        match (this.valueType) {
            case NULL => true
            case _ => false
        }
    }
    
    public func toJsonString(): String {
        match (this.valueType) {
            case STRING => "\"" + escapeJsonString(this.stringValue) + "\""
            case INT => this.intValue.toString()
            case FLOAT => this.floatValue.toString()
            case BOOL => if (this.boolValue) { "true" } else { "false" }
            case OBJECT => this.objectValue.toJsonString()
            case ARRAY => this.arrayValue.toJsonString()
            case NULL => "null"
        }
    }
}

// ========== 解析辅助函数 ==========

/**
 * 解析 JSON 字符串值
 * 使用 runes() 遍历以正确处理 UTF-8 多字节字符（如中文）
 */
func parseStringValue(input: String): (String, String) {
    var s = input.trimAscii()
    
    if (!s.startsWith("\"")) {
        return ("", s)
    }
    
    // 跳过开头的引号，转换为 Rune 数组
    let runes = s.toRuneArray()
    var i: Int64 = 1  // 跳过第一个引号
    var result = ""
    var escaped = false
    
    while (i < runes.size) {
        let ch = runes[i]
        
        if (escaped) {
            // 处理转义字符
            if (ch == r'"') {
                result += "\""
            } else if (ch == r'\\') {
                result += "\\"
            } else if (ch == r'n') {
                result += "\n"
            } else if (ch == r'r') {
                result += "\r"
            } else if (ch == r't') {
                result += "\t"
            } else if (ch == r'u') {
                // Unicode 转义: \uXXXX
                if (i + 4 < runes.size) {
                    var hexStr = ""
                    for (j in 1..5) {
                        hexStr += runes[i + j].toString()
                    }
                    // 尝试解析 Unicode 码点
                    try {
                        let codePoint = parseHexToInt(hexStr)
                        if (codePoint >= 0) {
                            result += Rune(UInt32(codePoint)).toString()
                        }
                    } catch (_: Exception) {
                        result += "\\u" + hexStr
                    }
                    i += 4
                } else {
                    result += ch.toString()
                }
            } else {
                result += ch.toString()
            }
            escaped = false
        } else if (ch == r'\\') {
            escaped = true
        } else if (ch == r'"') {
            // 找到结束引号
            // 计算剩余字符串（需要转回字节位置）
            var remaining = ""
            for (j in (i + 1)..runes.size) {
                remaining += runes[j].toString()
            }
            return (result, remaining)
        } else {
            result += ch.toString()
        }
        
        i += 1
    }
    
    return (result, "")
}

/**
 * 解析十六进制字符串为整数
 */
func parseHexToInt(hex: String): Int64 {
    var result: Int64 = 0
    for (ch in hex.runes()) {
        result *= 16
        if (ch >= r'0' && ch <= r'9') {
            result += Int64(UInt32(ch) - UInt32(r'0'))
        } else if (ch >= r'a' && ch <= r'f') {
            result += Int64(UInt32(ch) - UInt32(r'a') + 10)
        } else if (ch >= r'A' && ch <= r'F') {
            result += Int64(UInt32(ch) - UInt32(r'A') + 10)
        }
    }
    return result
}

/**
 * 解析 JSON 值
 * 使用 runes() 遍历以正确处理 UTF-8 多字节字符
 */
func parseValue(input: String): (JsonValue, String) {
    var s = input.trimAscii()
    
    if (s.size == 0) {
        return (JsonValue.fromNull(), "")
    }
    
    // 获取第一个字符（Rune）
    let runes = s.toRuneArray()
    if (runes.size == 0) {
        return (JsonValue.fromNull(), "")
    }
    let firstChar = runes[0]
    
    if (firstChar == r'"') {
        let result = parseStringValue(s)
        return (JsonValue.fromString(result[0]), result[1])
    }
    
    if (firstChar == r'{') {
        let endIdx = findMatchingBrace(s, "{", "}")
        let objStr = s[0..endIdx]
        let obj = JsonParser.parseObject(objStr)
        return (JsonValue.fromObject(obj), s[endIdx..])
    }
    
    if (firstChar == r'[') {
        let endIdx = findMatchingBrace(s, "[", "]")
        let arrStr = s[0..endIdx]
        let arr = JsonParser.parseArray(arrStr)
        return (JsonValue.fromArray(arr), s[endIdx..])
    }
    
    if (s.startsWith("true")) {
        return (JsonValue.fromBool(true), s[4..])
    }
    
    if (s.startsWith("false")) {
        return (JsonValue.fromBool(false), s[5..])
    }
    
    if (s.startsWith("null")) {
        return (JsonValue.fromNull(), s[4..])
    }
    
    // 数字 - 使用 runes() 遍历
    var numStr = ""
    var bytePos: Int64 = 0
    var hasDecimal = false
    
    for (ch in s.runes()) {
        let charStr = ch.toString()
        if (ch == r'-' || ch == r'+' || (ch >= r'0' && ch <= r'9')) {
            numStr += charStr
            bytePos += charStr.size
        } else if (ch == r'.' && !hasDecimal) {
            numStr += charStr
            hasDecimal = true
            bytePos += charStr.size
        } else {
            break
        }
    }
    
    if (numStr.size > 0) {
        if (hasDecimal) {
            try {
                let floatVal = Float64.parse(numStr)
                return (JsonValue.fromFloat(floatVal), s[bytePos..])
            } catch (_: Exception) {
                // 解析失败
            }
        } else {
            try {
                let intVal = Int64.parse(numStr)
                return (JsonValue.fromInt(intVal), s[bytePos..])
            } catch (_: Exception) {
                // 解析失败
            }
        }
    }
    
    return (JsonValue.fromNull(), s)
}

/**
 * 查找匹配的括号位置
 * 使用 runes() 遍历以正确处理 UTF-8 多字节字符
 */
func findMatchingBrace(s: String, open: String, close: String): Int64 {
    let openRune = open.toRuneArray()[0]
    let closeRune = close.toRuneArray()[0]
    
    var count = 0
    var inString = false
    var prevWasEscape = false
    var bytePos: Int64 = 0
    
    for (ch in s.runes()) {
        // 获取当前字符的字节长度
        let charByteLen = ch.toString().size
        
        // 检查是否在字符串内
        if (ch == r'"' && !prevWasEscape) {
            inString = !inString
        }
        
        // 更新转义状态
        if (ch == r'\\' && !prevWasEscape) {
            prevWasEscape = true
        } else {
            prevWasEscape = false
        }
        
        if (!inString) {
            if (ch == openRune) {
                count += 1
            } else if (ch == closeRune) {
                count -= 1
                if (count == 0) {
                    // 返回下一个字符的字节位置
                    return bytePos + charByteLen
                }
            }
        }
        
        bytePos += charByteLen
    }
    
    return s.size
}

/**
 * 转义 JSON 字符串中的特殊字符
 * 使用 runes() 遍历以正确处理 UTF-8 多字节字符（如中文）
 */
func escapeJsonString(s: String): String {
    var result = ""
    // 使用 runes() 按字符遍历，而不是按字节索引
    for (ch in s.runes()) {
        if (ch == r'"') {
            result += "\\\""
        } else if (ch == r'\\') {
            result += "\\\\"
        } else if (ch == r'\n') {
            result += "\\n"
        } else if (ch == r'\r') {
            result += "\\r"
        } else if (ch == r'\t') {
            result += "\\t"
        } else {
            result += ch.toString()
        }
    }
    return result
}

