package ohos_app_cangjie_entry.services

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import std.collection.*
import ohos_app_cangjie_entry.net.{netHttpGetBytes, netHttpPostText}

/**
 * HTTP 客户端封装
 * 对应 iOS TelegramCore/Sources/Network/FetchHttpResource.swift
 * 
 * 提供统一的 HTTP 请求接口，支持 GET/POST 等方法
 * 
 * MVP 阶段说明：
 * - 当前使用 Mock 实现，便于 UI 开发和测试
 * - 真实请求走 ohos.net.http（系统 NetStack，见 net/NetHttpClient.cj）
 * 
 * 使用方式：
 * ```cangjie
 * let client = HttpClient.getInstance()
 * let result = client.get("/api/chats")
 * if (result.success) {
 *     println(result.body)
 * }
 * ```
 */
public class HttpClient {
    // 基础 URL
    private var baseUrl: String = ""
    
    // 默认超时时间（毫秒）
    private var defaultTimeout: Int64 = 30000
    
    // 默认请求头
    private var defaultHeaders: ArrayList<String> = ArrayList<String>()
    
    // 是否使用 Mock 模式
    private var useMock: Bool = true
    
    // Mock 数据处理器
    private var mockHandler: Option<(HttpRequest) -> HttpResult> = None<(HttpRequest) -> HttpResult>
    
    // 单例实例
    private static var _instance: Option<HttpClient> = None<HttpClient>
    
    /**
     * 获取单例实例
     */
    public static func getInstance(): HttpClient {
        if (HttpClient._instance.isNone()) {
            HttpClient._instance = Some(HttpClient())
        }
        return HttpClient._instance.getOrThrow()
    }
    
    /**
     * 配置基础 URL
     */
    public func setBaseUrl(url: String): HttpClient {
        this.baseUrl = url
        return this
    }
    
    /**
     * 获取基础 URL
     */
    public func getBaseUrl(): String {
        return this.baseUrl
    }
    
    /**
     * 配置默认超时时间
     */
    public func setDefaultTimeout(timeout: Int64): HttpClient {
        this.defaultTimeout = timeout
        return this
    }
    
    /**
     * 添加默认请求头
     */
    public func addDefaultHeader(name: String, value: String): HttpClient {
        this.defaultHeaders.add(name + "=" + value)
        return this
    }
    
    /**
     * 设置 Mock 模式
     */
    public func setMockMode(enabled: Bool): HttpClient {
        this.useMock = enabled
        return this
    }
    
    /**
     * 设置 Mock 处理器
     */
    public func setMockHandler(handler: (HttpRequest) -> HttpResult): HttpClient {
        this.mockHandler = Some(handler)
        return this
    }
    
    /**
     * 发送 GET 请求
     */
    public func get(path: String): HttpResult {
        let request = HttpRequest()
        request.url = this.buildUrl(path)
        request.method = HttpMethod.GET
        request.timeout = this.defaultTimeout
        this.applyDefaultHeaders(request)
        
        return this.execute(request)
    }
    
    /**
     * 发送 POST 请求
     */
    public func post(path: String, body: String): HttpResult {
        let request = HttpRequest()
        request.url = this.buildUrl(path)
        request.method = HttpMethod.POST
        request.body = body
        request.timeout = this.defaultTimeout
        this.applyDefaultHeaders(request)
        request.setJsonContentType()
        
        return this.execute(request)
    }
    
    /**
     * 发送 PUT 请求
     */
    public func put(path: String, body: String): HttpResult {
        let request = HttpRequest()
        request.url = this.buildUrl(path)
        request.method = HttpMethod.PUT
        request.body = body
        request.timeout = this.defaultTimeout
        this.applyDefaultHeaders(request)
        request.setJsonContentType()
        
        return this.execute(request)
    }
    
    /**
     * 发送 DELETE 请求
     */
    public func delete(path: String): HttpResult {
        let request = HttpRequest()
        request.url = this.buildUrl(path)
        request.method = HttpMethod.DELETE
        request.timeout = this.defaultTimeout
        this.applyDefaultHeaders(request)
        
        return this.execute(request)
    }
    
    /**
     * 发送自定义请求
     */
    public func request(req: HttpRequest): HttpResult {
        // 如果 URL 不是完整 URL，补全基础 URL
        if (!req.url.startsWith("http://") && !req.url.startsWith("https://")) {
            req.url = this.buildUrl(req.url)
        }
        this.applyDefaultHeaders(req)
        
        return this.execute(req)
    }
    
    /**
     * 执行请求
     */
    private func execute(request: HttpRequest): HttpResult {
        // Mock 模式
        if (this.useMock) {
            return this.executeMock(request)
        }
        
        // 真实 HTTP 请求
        return this.executeReal(request)
    }
    
    /**
     * 执行 Mock 请求
     */
    private func executeMock(request: HttpRequest): HttpResult {
        // 如果有自定义 Mock 处理器，使用它
        if (this.mockHandler.isSome()) {
            return this.mockHandler.getOrThrow()(request)
        }
        
        // 默认 Mock 响应
        return this.getDefaultMockResponse(request)
    }
    
    /**
     * 获取默认 Mock 响应
     * 根据请求路径返回预设的 Mock 数据
     */
    private func getDefaultMockResponse(request: HttpRequest): HttpResult {
        let url = request.url
        
        // 认证相关 API Mock
        if (url.contains("/auth/sendCode")) {
            return HttpResult.ok("""
{
    "ok": true,
    "result": {
        "phone_code_hash": "mock_hash_123",
        "timeout": 60
    }
}
""")
        }
        
        if (url.contains("/auth/verifyCode")) {
            return HttpResult.ok("""
{
    "ok": true,
    "result": {
        "user": {
            "id": 1,
            "first_name": "Test",
            "last_name": "User",
            "phone": "+8613800138000"
        }
    }
}
""")
        }
        
        // 聊天列表 API Mock
        if (url.contains("/getChats") || url.contains("/chats")) {
            return HttpResult.ok("""
{
    "ok": true,
    "result": [
        {"id": 1, "name": "Alice", "last_message": "你好！", "time": "14:30", "unread_count": 2},
        {"id": 2, "name": "Bob", "last_message": "明天见", "time": "13:20", "unread_count": 0},
        {"id": 3, "name": "Carol", "last_message": "文件已发送", "time": "12:00", "unread_count": 5}
    ]
}
""")
        }
        
        // 消息 API Mock
        if (url.contains("/getMessages") || url.contains("/messages")) {
            return HttpResult.ok("""
{
    "ok": true,
    "result": [
        {"id": 1, "text": "你好！", "is_sent": false, "time": "14:30"},
        {"id": 2, "text": "你好啊！", "is_sent": true, "time": "14:31"},
        {"id": 3, "text": "今天天气怎么样？", "is_sent": false, "time": "14:32"},
        {"id": 4, "text": "天气很好！", "is_sent": true, "time": "14:33"}
    ]
}
""")
        }
        
        // 发送消息 API Mock
        if (url.contains("/sendMessage")) {
            return HttpResult.ok("""
{
    "ok": true,
    "result": {
        "message_id": 100,
        "date": 1706970000,
        "text": "Message sent"
    }
}
""")
        }
        
        // 获取更新 API Mock (Bot API style)
        if (url.contains("/getUpdates")) {
            return HttpResult.ok("""
{
    "ok": true,
    "result": []
}
""")
        }
        
        // 默认响应
        return HttpResult.ok("""
{
    "ok": true,
    "result": null
}
""")
    }
    
    /**
     * 执行真实 HTTP 请求
     *
     * 走系统 NetStack（net/NetHttpClient.cj）。原来用的 stdx.net.http 会让仓颉运行时
     * 在装配该动态库的接口表时 abort（itfVExtensionDataStart is nullptr），是硬崩、
     * try/catch 也拦不住，真机上已由地图快照那条链路复现过。
     */
    private func executeReal(request: HttpRequest): HttpResult {
        let methodStr = this.getMethodString(request.method)
        let headers = HashMap<String, String>()
        for (header in request.headers) {
            let parts = this.parseHeader(header)
            if (parts.size == 2) {
                headers[parts[0]] = parts[1]
            }
        }

        let response = if (methodStr == "GET" || methodStr == "DELETE") {
            netHttpGetBytes(request.url, headers: headers, timeoutMs: this.defaultTimeout)
        } else {
            netHttpPostText(request.url, request.body, headers: headers, timeoutMs: this.defaultTimeout)
        }

        if (!response.success) {
            return HttpResult.error("HTTP 请求失败", statusCode: Int32(response.statusCode))
        }
        let result = HttpResult()
        result.success = true
        result.statusCode = Int32(response.statusCode)
        result.body = response.text()
        return result
    }

    /**
     * 获取 HTTP 方法字符串
     */
    private func getMethodString(method: HttpMethod): String {
        match (method) {
            case GET => "GET"
            case POST => "POST"
            case PUT => "PUT"
            case DELETE => "DELETE"
            case PATCH => "PATCH"
            case _ => "GET"
        }
    }
    
    /**
     * 解析 header 字符串 "key=value" 为 [key, value]
     */
    private func parseHeader(header: String): ArrayList<String> {
        var result = ArrayList<String>()
        let idx = header.indexOf("=")
        if (idx.isSome()) {
            let i = idx.getOrThrow()
            result.add(header[0..i])
            result.add(header[(i + 1)..])
        }
        return result
    }
    
    /**
     * 构建完整 URL
     */
    private func buildUrl(path: String): String {
        if (path.startsWith("http://") || path.startsWith("https://")) {
            return path
        }
        
        var url = this.baseUrl
        if (!url.endsWith("/") && !path.startsWith("/")) {
            url += "/"
        }
        return url + path
    }
    
    /**
     * 应用默认请求头
     */
    private func applyDefaultHeaders(request: HttpRequest) {
        for (header in this.defaultHeaders) {
            request.headers.add(header)
        }
    }
}
