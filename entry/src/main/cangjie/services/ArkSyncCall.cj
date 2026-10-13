package ohos_app_cangjie_entry.services

/**
 * arkCallSync — 把回调式 callArkAsync 包成同步调用（仅限非 UI 线程；回调经 JS 主线程投递，
 * 在 UI 线程等待会死锁）。超时返回空串。MapKitBridge / AudioPlayerBridge / VideoThumbnailBridge 共用。
 */

import std.sync.*
import std.time.*
import ohos_app_cangjie_entry.interop.callArkAsync

class ArkSyncBox {
    var value: String = ""
    var done: Bool = false
    let monitor: Monitor = Monitor()
}

public func arkCallSync(name: String, argJson: String, timeoutMs: Int64): String {
    let box = ArkSyncBox()
    callArkAsync(name, argJson, { r: String =>
        synchronized(box.monitor) {
            box.value = r
            box.done = true
            box.monitor.notifyAll()
        }
    })
    synchronized(box.monitor) {
        if (!box.done) {
            let _ = box.monitor.wait(timeout: Duration.millisecond * timeoutMs)
        }
    }
    return box.value
}
