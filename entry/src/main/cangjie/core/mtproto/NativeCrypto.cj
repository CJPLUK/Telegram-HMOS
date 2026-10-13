package ohos_app_cangjie_entry.core.mtproto

/**
 * NativeCrypto — AES-256-IGE / SHA-256 原生加速（cpp/tg_crypto.cpp，OpenSSL）。
 * dlopen("libtg_media.so") + dlsym；任一步失败则 available()=false，调用方退回纯仓颉实现。
 * 纯仓颉 AES 每块重做 key expansion + 大量小数组分配：512 KB 分片要数秒 CPU，是"发图/发视频慢"的主因。
 */

import std.sync.*
import std.core.LibC as CoreLibC
import kit.PerformanceAnalysisKit.Hilog

foreign func dlopen(path: CString, flags: Int32): CPointer<Unit>
foreign func dlsym(handle: CPointer<Unit>, symbol: CString): CPointer<Unit>

public class NativeCrypto {
    private static let _lock = ReentrantMutex()
    private static var _state: Int32 = 0   // 0 未加载 / 1 可用 / -1 不可用
    private static var _lib: CPointer<Unit> = CPointer<Unit>()
    static var fnIgeEnc: CFunc<(CPointer<UInt8>, CPointer<UInt8>, CPointer<UInt8>, CPointer<UInt8>, UIntNative) -> Int32> =
        CFunc<(CPointer<UInt8>, CPointer<UInt8>, CPointer<UInt8>, CPointer<UInt8>, UIntNative) -> Int32>(CPointer<Unit>())
    static var fnIgeDec: CFunc<(CPointer<UInt8>, CPointer<UInt8>, CPointer<UInt8>, CPointer<UInt8>, UIntNative) -> Int32> =
        CFunc<(CPointer<UInt8>, CPointer<UInt8>, CPointer<UInt8>, CPointer<UInt8>, UIntNative) -> Int32>(CPointer<Unit>())
    static var fnSha256: CFunc<(CPointer<UInt8>, UIntNative, CPointer<UInt8>) -> Unit> =
        CFunc<(CPointer<UInt8>, UIntNative, CPointer<UInt8>) -> Unit>(CPointer<Unit>())

    private static func sym(name: String): CPointer<Unit> {
        let cs = unsafe { CoreLibC.mallocCString(name) }
        let p = unsafe { dlsym(_lib, cs) }
        unsafe { CoreLibC.free(cs) }
        return p
    }

    private static func tryOpen(path: String): Bool {
        let cs = unsafe { CoreLibC.mallocCString(path) }
        let h = unsafe { dlopen(cs, 1) }
        unsafe { CoreLibC.free(cs) }
        if (h.isNull()) { return false }
        _lib = h
        return true
    }

    public static func available(): Bool {
        if (_state == 1) { return true }
        if (_state == -1) { return false }
        synchronized(_lock) {
            if (_state != 0) { return _state == 1 }
            var opened = tryOpen("libtg_media.so")
            if (!opened) { opened = tryOpen("/data/storage/el1/bundle/libs/arm64/libtg_media.so") }
            if (!opened) {
                Hilog.info(0, "CjTelegram", "[NativeCrypto] dlopen libtg_media.so failed; using pure Cangjie crypto")
                _state = -1
                return false
            }
            let pE = sym("tg_aes_ige_encrypt")
            let pD = sym("tg_aes_ige_decrypt")
            let pS = sym("tg_sha256")
            if (pE.isNull() || pD.isNull() || pS.isNull()) {
                Hilog.info(0, "CjTelegram", "[NativeCrypto] symbols missing; using pure Cangjie crypto")
                _state = -1
                return false
            }
            fnIgeEnc = CFunc<(CPointer<UInt8>, CPointer<UInt8>, CPointer<UInt8>, CPointer<UInt8>, UIntNative) -> Int32>(pE)
            fnIgeDec = CFunc<(CPointer<UInt8>, CPointer<UInt8>, CPointer<UInt8>, CPointer<UInt8>, UIntNative) -> Int32>(pD)
            fnSha256 = CFunc<(CPointer<UInt8>, UIntNative, CPointer<UInt8>) -> Unit>(pS)
            _state = 1
            Hilog.info(0, "CjTelegram", "[NativeCrypto] OpenSSL AES-IGE/SHA256 ready")
            return true
        }
    }

    /** data.size 必须是 16 的倍数，key 32 B，iv 32 B */
    public static func igeEncrypt(data: Array<Byte>, key: Array<Byte>, iv: Array<Byte>): Option<Array<Byte>> {
        if (data.size == 0 || data.size % 16 != 0 || key.size < 32 || iv.size < 32) { return None }
        let out = Array<Byte>(data.size, repeat: 0)
        var rc: Int32 = -1
        unsafe {
            let hd = acquireArrayRawData(data)
            let hk = acquireArrayRawData(key)
            let hi = acquireArrayRawData(iv)
            let ho = acquireArrayRawData(out)
            rc = fnIgeEnc(hk.pointer, hi.pointer, hd.pointer, ho.pointer, UIntNative(data.size))
            releaseArrayRawData(ho)
            releaseArrayRawData(hi)
            releaseArrayRawData(hk)
            releaseArrayRawData(hd)
        }
        if (rc != 0) { return None }
        return Some(out)
    }

    public static func igeDecrypt(data: Array<Byte>, key: Array<Byte>, iv: Array<Byte>): Option<Array<Byte>> {
        if (data.size == 0 || data.size % 16 != 0 || key.size < 32 || iv.size < 32) { return None }
        let out = Array<Byte>(data.size, repeat: 0)
        var rc: Int32 = -1
        unsafe {
            let hd = acquireArrayRawData(data)
            let hk = acquireArrayRawData(key)
            let hi = acquireArrayRawData(iv)
            let ho = acquireArrayRawData(out)
            rc = fnIgeDec(hk.pointer, hi.pointer, hd.pointer, ho.pointer, UIntNative(data.size))
            releaseArrayRawData(ho)
            releaseArrayRawData(hi)
            releaseArrayRawData(hk)
            releaseArrayRawData(hd)
        }
        if (rc != 0) { return None }
        return Some(out)
    }

    public static func sha256(data: Array<Byte>): Option<Array<Byte>> {
        if (data.size == 0) { return None }
        let out = Array<Byte>(32, repeat: 0)
        unsafe {
            let hd = acquireArrayRawData(data)
            let ho = acquireArrayRawData(out)
            fnSha256(hd.pointer, UIntNative(data.size), ho.pointer)
            releaseArrayRawData(ho)
            releaseArrayRawData(hd)
        }
        return Some(out)
    }
}
