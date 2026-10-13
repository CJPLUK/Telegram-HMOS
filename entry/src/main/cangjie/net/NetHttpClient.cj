package ohos_app_cangjie_entry.net

import ohos.net.http.*
import ohos.business_exception.BusinessException
import kit.PerformanceAnalysisKit.Hilog
import std.collection.HashMap
import std.sync.Monitor
import std.time.DateTime

/**
 * 系统 HTTP 客户端（ohos.net.http）的同步封装。
 *
 * 为什么不用 stdx.net.http：它在本工程里必崩。真机栈：
 *   LastFatalMessage: itfVExtensionDataStart is nullptr
 *   MapleRuntime::TypeInfo::TryUpdateExtensionData → GetMTable
 *   libstdx.net.http.so  stdx.net.http.Client::get(String)
 *   LocationResourcesService::fetchMapSnapshot
 * 即仓颉运行时在为 stdx 动态库里的类型装配接口表时拿到空指针直接 abort，
 * 不是业务代码的问题，也无法用 try/catch 兜住（SIGABRT）。
 * 同一个坑此前已经在 stdx 的 MD5 上踩过一次（见 FileUploadService 里被清空的小文件 MD5）。
 *
 * ohos.net.http 是系统 NetStack 的绑定，不经过 stdx 那条动态库路径。
 *
 * 同步语义：系统 API 是回调式的，这里用 Monitor 等回调落地后再返回，
 * 以便原有的同步调用链（fetchMapSnapshot 等）不用改造。**必须在 spawn 出来的
 * 线程里调用**，不能在 UI 线程上调用，否则会把主线程堵住。
 */
public class NetHttpResult {
    public var success: Bool = false
    public var statusCode: Int64 = 0
    public var bytes: Array<Byte> = Array<Byte>(0, repeat: 0)

    public func text(): String {
        if (this.bytes.size == 0) { return "" }
        try {
            return String.fromUtf8(this.bytes)
        } catch (_: Exception) {
            return ""
        }
    }
}

/**
 * 一次请求的等待状态。
 * 仓颉的 lambda 不能捕获可变局部变量，回调要写的东西必须挂在对象字段上。
 */
private class NetHttpPending {
    let monitor = Monitor()
    let result = NetHttpResult()
    var finished: Bool = false
}

private func netHttpNowMs(): Int64 {
    return DateTime.now().toUnixTimeStamp().toMilliseconds()
}

/** GET，返回原始字节（图片等二进制资源） */
public func netHttpGetBytes(
    url: String,
    headers!: HashMap<String, String> = HashMap<String, String>(),
    timeoutMs!: Int64 = 30000
): NetHttpResult {
    return netHttpExecute(url, RequestMethod.Get, HttpData.StringData(""), headers, timeoutMs)
}

/** GET，返回文本（JSON 等） */
public func netHttpGetText(url: String, timeoutMs!: Int64 = 30000): String {
    return netHttpGetBytes(url, timeoutMs: timeoutMs).text()
}

/** POST，请求体与响应都按文本处理 */
public func netHttpPostText(
    url: String,
    body: String,
    headers!: HashMap<String, String> = HashMap<String, String>(),
    timeoutMs!: Int64 = 30000
): NetHttpResult {
    return netHttpExecute(url, RequestMethod.Post, HttpData.StringData(body), headers, timeoutMs)
}

private func netHttpExecute(
    url: String,
    method: RequestMethod,
    body: HttpData,
    headers: HashMap<String, String>,
    timeoutMs: Int64
): NetHttpResult {
    let pending = NetHttpPending()
    let monitor = pending.monitor
    let result = pending.result

    let request = createHttp()
    let options = HttpRequestOptions(
        method: method,
        extraData: body,
        expectDataType: Some(HttpDataType.ArrayBuffer),
        usingCache: false,
        header: headers,
        readTimeout: UInt32(timeoutMs),
        connectTimeout: UInt32(timeoutMs),
        maxLimit: 32 * 1024 * 1024
    )

    try {
        request.request(
            url,
            options,
            { err: Option<BusinessException>, resp: Option<HttpResponse> =>
                synchronized(pending.monitor) {
                    match (err) {
                        case Some(e) =>
                            Hilog.warn(0, "CjTelegram", "[NetHttp] failed code=${e.code}")
                        case None => ()
                    }
                    match (resp) {
                        case Some(r) =>
                            pending.result.statusCode = Int64(r.responseCode)
                            match (r.result) {
                                case ArrayData(data) => pending.result.bytes = data
                                case StringData(s) => pending.result.bytes = s.toArray()
                                case _ => ()
                            }
                            pending.result.success = pending.result.statusCode >= 200 &&
                                pending.result.statusCode < 300 && pending.result.bytes.size > 0
                        case None => ()
                    }
                    pending.finished = true
                    pending.monitor.notifyAll()
                }
            }
        )

        // 回调没来也必须有终点：超时预算之外再宽限 5s，到点按失败返回。
        let deadline = netHttpNowMs() + timeoutMs + 5000
        synchronized(monitor) {
            while (!pending.finished) {
                let remaining = deadline - netHttpNowMs()
                if (remaining <= 0) {
                    Hilog.warn(0, "CjTelegram", "[NetHttp] timed out waiting for callback")
                    break
                }
                let _ = monitor.wait(timeout: Duration.millisecond * remaining)
            }
        }
    } catch (e: Exception) {
        Hilog.warn(0, "CjTelegram", "[NetHttp] request threw: ${e.message}")
    }

    try { request.destroy() } catch (_: Exception) {}
    return result
}
