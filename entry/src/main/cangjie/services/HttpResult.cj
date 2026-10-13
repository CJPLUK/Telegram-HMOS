package ohos_app_cangjie_entry.services

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import std.collection.*

/**
 * HTTP 请求结果
 * 对应 iOS 中的网络响应处理
 * 
 * iOS 文件参考:
 * - submodules/TelegramCore/Sources/Network/FetchHttpResource.swift
 */
@Observed
public class HttpResult {
    // 请求是否成功
    @Publish public var success: Bool = false
    
    // HTTP 状态码
    @Publish public var statusCode: Int32 = 0
    
    // 响应体
    @Publish public var body: String = ""
    
    // 错误信息
    @Publish public var errorMessage: String = ""
    
    // 响应头（简化版，使用 key=value 格式存储）
    @Publish public var headers: ArrayList<String> = ArrayList<String>()
    
    /**
     * 创建成功响应
     */
    public static func ok(body: String, statusCode!: Int32 = 200): HttpResult {
        let result = HttpResult()
        result.success = true
        result.statusCode = statusCode
        result.body = body
        return result
    }
    
    /**
     * 创建失败响应
     */
    public static func error(message: String, statusCode!: Int32 = 0): HttpResult {
        let result = HttpResult()
        result.success = false
        result.statusCode = statusCode
        result.errorMessage = message
        return result
    }
    
    /**
     * 检查是否是成功的 HTTP 状态码 (2xx)
     */
    public func isHttpSuccess(): Bool {
        return this.statusCode >= 200 && this.statusCode < 300
    }
    
    /**
     * 获取响应头
     */
    public func getHeader(name: String): String {
        let lowerName = name.toAsciiLower()
        for (header in this.headers) {
            if (header.toAsciiLower().startsWith(lowerName + "=")) {
                let index = header.indexOf("=")
                if (index.isSome()) {
                    return header[(index.getOrThrow() + 1)..]
                }
            }
        }
        return ""
    }
}

/**
 * HTTP 请求方法枚举
 */
public enum HttpMethod {
    | GET
    | POST
    | PUT
    | DELETE
    | PATCH
    
    public func toString(): String {
        match (this) {
            case GET => "GET"
            case POST => "POST"
            case PUT => "PUT"
            case DELETE => "DELETE"
            case PATCH => "PATCH"
        }
    }
}

/**
 * HTTP 请求配置
 */
public class HttpRequest {
    // 请求 URL
    public var url: String = ""
    
    // 请求方法
    public var method: HttpMethod = HttpMethod.GET
    
    // 请求头
    public var headers: ArrayList<String> = ArrayList<String>()
    
    // 请求体
    public var body: String = ""
    
    // 超时时间（毫秒）
    public var timeout: Int64 = 30000
    
    /**
     * 添加请求头
     */
    public func addHeader(name: String, value: String): HttpRequest {
        this.headers.add(name + "=" + value)
        return this
    }
    
    /**
     * 设置 Content-Type
     */
    public func setContentType(contentType: String): HttpRequest {
        return this.addHeader("Content-Type", contentType)
    }
    
    /**
     * 设置 JSON Content-Type
     */
    public func setJsonContentType(): HttpRequest {
        return this.setContentType("application/json")
    }
    
    /**
     * 设置请求体
     */
    public func setBody(body: String): HttpRequest {
        this.body = body
        return this
    }
}
