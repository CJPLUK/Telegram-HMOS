// .acv3 → ArkTS 帧通道（Phase1：ArkTS ImageAnimator 表情网格）。
//
// ArkTS 侧 `import { emojiLoadCachedFrames } from 'libentry.so'`：
//   emojiLoadCachedFrames(path: string)
//     → { raster: number, frameDurationMs: number, frames: ArrayBuffer[] } | null
// 帧为 BGRA8888 预乘，边长 raster。.acv3 版式（与仓颉侧
// AnimatedEmojiService 的 v3 编码器一致）：
//   [0..3]  magic 'ACV1'
//   [4..7]  raster (i32 LE)
//   [8..11] frameCount (i32 LE)
//   [12..15] frameDurationMs (i32 LE)
//   每帧: [len i32][runs: (skip i32)(lit i32)(lit*4 bytes)... 相对上一帧的 delta]

#include <cstdint>
#include <cstdio>
#include <utime.h>
#include <cstring>
#include <string>
#include <vector>

#include "napi/native_api.h"

namespace {

int32_t ReadI32(const uint8_t *p) {
    return static_cast<int32_t>(p[0]) | (static_cast<int32_t>(p[1]) << 8) |
           (static_cast<int32_t>(p[2]) << 16) | (static_cast<int32_t>(p[3]) << 24);
}

// skip/lit 均为**字节**计（仓颉编码器 encodeRunsInto 在 Byte 数组上跑）。
bool ApplyRuns(const uint8_t *runs, size_t runsLen, uint8_t *frame, size_t frameLen) {
    size_t pos = 0;
    size_t out = 0;
    while (pos + 8 <= runsLen) {
        int32_t skip = ReadI32(runs + pos);
        int32_t lit = ReadI32(runs + pos + 4);
        pos += 8;
        if (skip < 0 || lit < 0) return false;
        out += static_cast<size_t>(skip);
        size_t litBytes = static_cast<size_t>(lit);
        if (pos + litBytes > runsLen || out + litBytes > frameLen) return false;
        memcpy(frame + out, runs + pos, litBytes);
        pos += litBytes;
        out += litBytes;
    }
    return pos == runsLen;
}

void TintTemplateBgra(uint8_t *px, size_t frameLen) {
    // supportsTextColor 模板素材：染 iOS 次级文字色 #8E8E93（预乘 alpha）。
    for (size_t i = 0; i + 3 < frameLen; i += 4) {
        uint32_t a = px[i + 3];
        px[i]     = static_cast<uint8_t>((0x93 * a) / 255); // B
        px[i + 1] = static_cast<uint8_t>((0x8E * a) / 255); // G
        px[i + 2] = static_cast<uint8_t>((0x8E * a) / 255); // R
    }
}

} // namespace

napi_value EmojiLoadCachedFrames(napi_env env, napi_callback_info info) {
    napi_value nullVal = nullptr;
    napi_get_null(env, &nullVal);

    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) return nullVal;

    char pathBuf[512];
    size_t pathLen = 0;
    if (napi_get_value_string_utf8(env, args[0], pathBuf, sizeof(pathBuf), &pathLen) != napi_ok) {
        return nullVal;
    }
    bool tint = false;
    if (argc >= 2) {
        napi_get_value_bool(env, args[1], &tint);
    }

    FILE *fp = fopen(pathBuf, "rb");
    if (fp == nullptr) return nullVal;
    // touch mtime = 最近使用时间：磁盘 GC 按 mtime 淘汰，构建时间当 LRU 会
    // 优先误删最常用的老缓存（真机实锤：首页 emoji 被整批清掉、全网格冻结）。
    utime(pathBuf, nullptr);
    fseek(fp, 0, SEEK_END);
    long size = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (size < 16) { fclose(fp); return nullVal; }
    std::vector<uint8_t> data(static_cast<size_t>(size));
    size_t got = fread(data.data(), 1, data.size(), fp);
    fclose(fp);
    if (got != data.size()) return nullVal;

    if (!(data[0] == 'A' && data[1] == 'C' && data[2] == 'V' && data[3] == '1')) {
        return nullVal;
    }
    int32_t raster = ReadI32(data.data() + 4);
    int32_t frameCount = ReadI32(data.data() + 8);
    int32_t durationMs = ReadI32(data.data() + 12);
    if (raster <= 0 || raster > 512 || frameCount <= 1 || durationMs <= 0) {
        return nullVal;
    }

    size_t frameLen = static_cast<size_t>(raster) * raster * 4;
    std::vector<uint8_t> cur(frameLen, 0);

    napi_value framesArr = nullptr;
    napi_create_array_with_length(env, static_cast<size_t>(frameCount), &framesArr);

    size_t pos = 16;
    for (int32_t i = 0; i < frameCount; i++) {
        if (pos + 4 > data.size()) return nullVal;
        int32_t len = ReadI32(data.data() + pos);
        pos += 4;
        if (len < 0 || pos + static_cast<size_t>(len) > data.size()) return nullVal;
        if (!ApplyRuns(data.data() + pos, static_cast<size_t>(len), cur.data(), frameLen)) {
            return nullVal;
        }
        pos += static_cast<size_t>(len);

        void *bufData = nullptr;
        napi_value arrayBuf = nullptr;
        if (napi_create_arraybuffer(env, frameLen, &bufData, &arrayBuf) != napi_ok) {
            return nullVal;
        }
        memcpy(bufData, cur.data(), frameLen);
        if (tint) {
            TintTemplateBgra(reinterpret_cast<uint8_t *>(bufData), frameLen);
        }
        napi_set_element(env, framesArr, static_cast<uint32_t>(i), arrayBuf);
    }

    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_value v = nullptr;
    napi_create_int32(env, raster, &v);
    napi_set_named_property(env, result, "raster", v);
    napi_create_int32(env, durationMs, &v);
    napi_set_named_property(env, result, "frameDurationMs", v);
    napi_set_named_property(env, result, "frames", framesArr);
    return result;
}

// static_frames 原始 BGRA 单帧（尺寸=raster²×4）。
// emojiLoadRawFrame(path: string, raster: number) → ArrayBuffer | null
napi_value EmojiLoadRawFrame(napi_env env, napi_callback_info info) {
    napi_value nullVal = nullptr;
    napi_get_null(env, &nullVal);
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) return nullVal;
    char pathBuf[512];
    size_t pathLen = 0;
    if (napi_get_value_string_utf8(env, args[0], pathBuf, sizeof(pathBuf), &pathLen) != napi_ok) {
        return nullVal;
    }
    int32_t raster = 0;
    napi_get_value_int32(env, args[1], &raster);
    if (raster <= 0 || raster > 512) return nullVal;
    bool tint = false;
    if (argc >= 3) {
        napi_get_value_bool(env, args[2], &tint);
    }
    size_t frameLen = static_cast<size_t>(raster) * raster * 4;
    FILE *fp = fopen(pathBuf, "rb");
    if (fp == nullptr) return nullVal;
    void *bufData = nullptr;
    napi_value arrayBuf = nullptr;
    if (napi_create_arraybuffer(env, frameLen, &bufData, &arrayBuf) != napi_ok) {
        fclose(fp);
        return nullVal;
    }
    size_t got = fread(bufData, 1, frameLen, fp);
    fclose(fp);
    if (got != frameLen) return nullVal;
    if (tint) {
        TintTemplateBgra(reinterpret_cast<uint8_t *>(bufData), frameLen);
    }
    return arrayBuf;
}

// ============================================================================
// 增量解帧会话（RenderNode 贴纸管线）：打开 .acv3 → 逐帧按需解码。
// 会话只持有 fd + 帧偏移索引 + prev/scratch 两块缓冲（~150KB/会话），
// 帧字节每次从磁盘读（页缓存兜底）——对位 iOS AnimationCache 的
// "压缩存储 + 每拍解一帧"内存模型，替代全帧 PixelMap 驻留。
//   emojiAnimOpen(path) -> {handle, raster, frameCount, frameDurationMs} | null
//   emojiAnimNextBatch(handles[], outs: ArrayBuffer[]) -> Promise<int[]>
//     （批量解下一帧到各自 out（调用方复用同一块，零每拍分配）；到尾自动
//      回绕。解码在 libuv 线程执行、执行期与 open/close 持锁互斥 ——
//      UI 线程只收结果写像素，见 AnimBatchExecute）
//   emojiAnimClose(handle) -> void
// ============================================================================

#include <map>
#include <mutex>

namespace {

struct AnimSession {
    FILE *fp = nullptr;
    int32_t raster = 0;
    int32_t frameCount = 0;
    int32_t durationMs = 33;
    int32_t nextIndex = 0;
    std::vector<long> offsets;   // 每帧 runs 起始文件偏移
    std::vector<int32_t> lengths;
    std::vector<uint8_t> cur;    // 当前帧（delta 目标，也是输出源）
    std::vector<uint8_t> scratch; // 帧 runs 读入缓冲
};

std::mutex g_animMutex;
std::map<int64_t, AnimSession *> g_animSessions;
int64_t g_nextAnimHandle = 1;

}  // namespace

napi_value EmojiAnimOpen(napi_env env, napi_callback_info info) {
    napi_value nullVal = nullptr;
    napi_get_null(env, &nullVal);
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) return nullVal;
    char pathBuf[512];
    size_t pathLen = 0;
    if (napi_get_value_string_utf8(env, args[0], pathBuf, sizeof(pathBuf), &pathLen) != napi_ok) {
        return nullVal;
    }
    FILE *fp = fopen(pathBuf, "rb");
    if (fp == nullptr) return nullVal;
    utime(pathBuf, nullptr); // 同 EmojiLoadCachedFrames：mtime 即 LRU 时钟
    uint8_t head[16];
    if (fread(head, 1, 16, fp) != 16 ||
        !(head[0] == 'A' && head[1] == 'C' && head[2] == 'V' && head[3] == '1')) {
        fclose(fp);
        return nullVal;
    }
    auto *s = new AnimSession();
    s->fp = fp;
    s->raster = ReadI32(head + 4);
    s->frameCount = ReadI32(head + 8);
    s->durationMs = ReadI32(head + 12);
    if (s->raster <= 0 || s->raster > 512 || s->frameCount <= 1 || s->durationMs <= 0) {
        fclose(fp);
        delete s;
        return nullVal;
    }
    // 建帧偏移索引（一次顺序扫描，只读长度头）
    long pos = 16;
    for (int32_t i = 0; i < s->frameCount; i++) {
        uint8_t lenBuf[4];
        if (fseek(fp, pos, SEEK_SET) != 0 || fread(lenBuf, 1, 4, fp) != 4) {
            fclose(fp);
            delete s;
            return nullVal;
        }
        int32_t len = ReadI32(lenBuf);
        if (len < 0) { fclose(fp); delete s; return nullVal; }
        s->offsets.push_back(pos + 4);
        s->lengths.push_back(len);
        pos += 4 + len;
    }
    size_t frameLen = static_cast<size_t>(s->raster) * s->raster * 4;
    s->cur.assign(frameLen, 0);
    int64_t handle;
    {
        std::lock_guard<std::mutex> lock(g_animMutex);
        handle = g_nextAnimHandle++;
        g_animSessions[handle] = s;
    }
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_value v = nullptr;
    napi_create_int64(env, handle, &v);
    napi_set_named_property(env, result, "handle", v);
    napi_create_int32(env, s->raster, &v);
    napi_set_named_property(env, result, "raster", v);
    napi_create_int32(env, s->frameCount, &v);
    napi_set_named_property(env, result, "frameCount", v);
    napi_create_int32(env, s->durationMs, &v);
    napi_set_named_property(env, result, "frameDurationMs", v);
    return result;
}

// 解码核心（调用方需持有 g_animMutex 或保证会话不被并发关闭）。
static int32_t AnimNextInto(int64_t handle, void *outData, size_t outLen) {
    auto it = g_animSessions.find(handle);
    if (it == g_animSessions.end()) return -1;
    AnimSession *s = it->second;
    size_t frameLen = s->cur.size();
    if (outLen < frameLen) return -1;
    int32_t idx = s->nextIndex;
    if (idx == 0) {
        // 回绕：delta 参照重置为全零（首帧相对透明底）
        std::fill(s->cur.begin(), s->cur.end(), 0);
    }
    int32_t len = s->lengths[idx];
    if (static_cast<size_t>(len) > s->scratch.size()) s->scratch.resize(len);
    if (fseek(s->fp, s->offsets[idx], SEEK_SET) != 0 ||
        fread(s->scratch.data(), 1, len, s->fp) != static_cast<size_t>(len)) {
        return -1;
    }
    if (!ApplyRuns(s->scratch.data(), len, s->cur.data(), frameLen)) return -1;
    memcpy(outData, s->cur.data(), frameLen);
    s->nextIndex = (idx + 1) % s->frameCount;
    return idx;
}

// ============================================================================
// 批量异步解帧：UI 线程 45% 的主项是 30fps × ~20 会话的 Next 解码全在主线程。
// 批量下移 libuv 线程：主线程只收结果数组 + writeBufferToPixelsSync（memcpy
// 级）+ draw。执行期全程持 g_animMutex —— open/close 与解码互斥，杜绝
// use-after-free（ETS 侧另有 batchInFlight 契约：批在飞不做 open/close）。
// ============================================================================
struct AnimBatchCtx {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::vector<int64_t> handles;
    std::vector<void *> bufs;
    std::vector<size_t> lens;
    std::vector<napi_ref> bufRefs;
    std::vector<int32_t> results;
};

static void AnimBatchExecute(napi_env, void *data) {
    auto *c = static_cast<AnimBatchCtx *>(data);
    c->results.resize(c->handles.size());
    std::lock_guard<std::mutex> lock(g_animMutex);
    for (size_t i = 0; i < c->handles.size(); i++) {
        c->results[i] = AnimNextInto(c->handles[i], c->bufs[i], c->lens[i]);
    }
}

static void AnimBatchComplete(napi_env env, napi_status, void *data) {
    auto *c = static_cast<AnimBatchCtx *>(data);
    napi_value arr = nullptr;
    napi_create_array_with_length(env, c->results.size(), &arr);
    for (size_t i = 0; i < c->results.size(); i++) {
        napi_value v = nullptr;
        napi_create_int32(env, c->results[i], &v);
        napi_set_element(env, arr, i, v);
    }
    napi_resolve_deferred(env, c->deferred, arr);
    for (napi_ref r : c->bufRefs) napi_delete_reference(env, r);
    napi_delete_async_work(env, c->work);
    delete c;
}

napi_value EmojiAnimNextBatch(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_value promise = nullptr;
    auto *c = new AnimBatchCtx();
    napi_create_promise(env, &c->deferred, &promise);
    bool ok = argc >= 2;
    uint32_t n = 0;
    if (ok) ok = napi_get_array_length(env, args[0], &n) == napi_ok;
    for (uint32_t i = 0; ok && i < n; i++) {
        napi_value hv = nullptr, bv = nullptr;
        int64_t handle = 0;
        void *buf = nullptr;
        size_t len = 0;
        ok = napi_get_element(env, args[0], i, &hv) == napi_ok &&
             napi_get_value_int64(env, hv, &handle) == napi_ok &&
             napi_get_element(env, args[1], i, &bv) == napi_ok &&
             napi_get_arraybuffer_info(env, bv, &buf, &len) == napi_ok;
        if (ok) {
            napi_ref r = nullptr;
            napi_create_reference(env, bv, 1, &r); // 钉住 ArrayBuffer 到批结束
            c->handles.push_back(handle);
            c->bufs.push_back(buf);
            c->lens.push_back(len);
            c->bufRefs.push_back(r);
        }
    }
    if (!ok) {
        napi_value arr = nullptr;
        napi_create_array_with_length(env, 0, &arr);
        napi_resolve_deferred(env, c->deferred, arr);
        for (napi_ref r : c->bufRefs) napi_delete_reference(env, r);
        delete c;
        return promise;
    }
    napi_value name = nullptr;
    napi_create_string_utf8(env, "EmojiAnimNextBatch", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, AnimBatchExecute, AnimBatchComplete, c, &c->work);
    napi_queue_async_work(env, c->work);
    return promise;
}

napi_value EmojiAnimClose(napi_env env, napi_callback_info info) {
    napi_value undef = nullptr;
    napi_get_undefined(env, &undef);
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) return undef;
    int64_t handle = 0;
    napi_get_value_int64(env, args[0], &handle);
    AnimSession *s = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_animMutex);
        auto it = g_animSessions.find(handle);
        if (it != g_animSessions.end()) {
            s = it->second;
            g_animSessions.erase(it);
        }
    }
    if (s != nullptr) {
        if (s->fp != nullptr) fclose(s->fp);
        delete s;
    }
    return undef;
}
