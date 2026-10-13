// Emoji 网格原生合成器 —— iOS MultiAnimationRenderer 的鸿蒙对位。
//
// 动机（真机结论）：ArkUI 路径下每帧 @State 写 → 组件 diff → 纹理重绑，
// 80 格 × 30fps ≈ 2400 次组件更新/秒，UI 线程是不可逾越的墙。本合成器把
// 表情网格的帧上屏整体搬进 native：一个 XComponent surface（ets 壳 Stack
// 底层，见 ChatRoomPage.ets），渲染线程按 30fps 用 rlottie 直接光栅化并
// 写 NativeWindow buffer —— UI 线程零参与，等价 iOS 的 CALayer.contents。
//
// 接口（Cangjie 经 dlsym 调用，全部 extern "C"）：
//   emojiGridCompositorSetSurface(surfaceId)  0=解绑
//   emojiGridCompositorSetItems(payload)      "docId|path|x|y|sizePx;..." 屏幕 px
//   emojiGridCompositorSetViewport(x,y,w,h,bgColor) 面板底色区（px）
//   emojiGridCompositorSetActive(active)      滚动中关、停稳开
//
// 线程模型：单渲染线程；items/viewport 由互斥锁保护，双缓冲交换。
// 动画实例 LRU（32 个）避免反复解析 .tgs。

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <list>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <pthread.h>
#include <vector>

#include <cmath>
#include <cstdio>

#include <hilog/log.h>
#include <native_buffer/buffer_common.h>
#include <native_buffer/native_buffer.h>
#include <native_window/external_window.h>

#define EGC_LOG(fmt, ...) OH_LOG_Print(LOG_APP, LOG_INFO, 0xC0DE, "EmojiGridNative", fmt, ##__VA_ARGS__)

#include "third_party/rlottie/inc/rlottie.h"

// telegram_lottie_bridge.cpp 导出的 gzip 解包与 root op 修补（外部链接）。
bool TelegramLottieInflateGzip(const uint8_t *data, size_t size, std::string &json);
void TelegramLottiePatchRootOutPoint(std::string &json);

namespace {

bool InflateGzipFile(const std::string &path, std::string &json);

struct GridItem {
    uint64_t docId = 0;
    std::string path;
    int x = 0;
    int y = 0;
    int size = 0;
    bool animated = true;
};

struct AnimEntry {
    std::unique_ptr<rlottie::Animation> animation;
    size_t frameCount = 0;
    double frameRate = 30.0;
    std::vector<uint32_t> buffer; // size*size 渲染缓冲
    int bufferSize = 0;
};

std::mutex g_mutex;
int g_bufW = 0;
int g_bufH = 0;
uint64_t g_surfaceId = 0;
OHNativeWindow *g_window = nullptr;
std::vector<GridItem> g_items;
int g_vpX = 0, g_vpY = 0, g_vpW = 0, g_vpH = 0;
uint32_t g_bgColor = 0xFFFFFFFF;
std::atomic<bool> g_active{false};
std::atomic<bool> g_threadRunning{false};
std::atomic<uint64_t> g_generation{0};

// 动画实例 LRU
std::list<std::pair<std::string, std::shared_ptr<AnimEntry>>> g_animLru;
std::map<std::string, std::list<std::pair<std::string, std::shared_ptr<AnimEntry>>>::iterator> g_animMap;
constexpr size_t kAnimLruCap = 48;

std::shared_ptr<AnimEntry> AcquireAnimation(const std::string &path) {
    auto it = g_animMap.find(path);
    if (it != g_animMap.end()) {
        g_animLru.splice(g_animLru.begin(), g_animLru, it->second);
        return it->second->second;
    }
    std::string json;
    if (!InflateGzipFile(path, json)) {
        return nullptr;
    }
    ::TelegramLottiePatchRootOutPoint(json);
    auto anim = rlottie::Animation::loadFromData(std::move(json), path, "", false);
    if (!anim) {
        return nullptr;
    }
    auto entry = std::make_shared<AnimEntry>();
    entry->frameCount = anim->totalFrame();
    entry->frameRate = anim->frameRate();
    if (entry->frameRate <= 1.0) entry->frameRate = 30.0;
    entry->animation = std::move(anim);
    g_animLru.emplace_front(path, entry);
    g_animMap[path] = g_animLru.begin();
    while (g_animLru.size() > kAnimLruCap) {
        g_animMap.erase(g_animLru.back().first);
        g_animLru.pop_back();
    }
    return entry;
}

bool InflateGzipFile(const std::string &path, std::string &json) {
    FILE *fp = fopen(path.c_str(), "rb");
    if (fp == nullptr) return false;
    fseek(fp, 0, SEEK_END);
    long size = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (size <= 0) { fclose(fp); return false; }
    std::vector<uint8_t> data(static_cast<size_t>(size));
    size_t got = fread(data.data(), 1, data.size(), fp);
    fclose(fp);
    if (got != data.size()) return false;
    // gzip or plain json
    if (data.size() >= 2 && data[0] == 0x1f && data[1] == 0x8b) {
        return ::TelegramLottieInflateGzip(data.data(), data.size(), json);
    }
    json.assign(reinterpret_cast<char *>(data.data()), data.size());
    return true;
}

// ARGB 预乘帧贴到窗口 buffer（RGBA_8888，窗口像素为 BGRA 内存序时按 rlottie 输出对齐）。
void BlitFrame(uint32_t *dst, int dstW, int dstH, int stridePx,
               const uint32_t *src, int size, int dx, int dy) {
    for (int row = 0; row < size; row++) {
        int ty = dy + row;
        if (ty < 0 || ty >= dstH) continue;
        const uint32_t *srow = src + static_cast<size_t>(row) * size;
        uint32_t *drow = dst + static_cast<size_t>(ty) * stridePx;
        for (int col = 0; col < size; col++) {
            int tx = dx + col;
            if (tx < 0 || tx >= dstW) continue;
            uint32_t s = srow[col];
            uint32_t a = s >> 24;
            if (a == 0) continue;
            if (a == 255) { drow[tx] = s; continue; }
            uint32_t d = drow[tx];
            uint32_t inv = 255 - a;
            uint32_t r = ((s >> 16) & 0xFF) + (((d >> 16) & 0xFF) * inv) / 255;
            uint32_t g = ((s >> 8) & 0xFF) + (((d >> 8) & 0xFF) * inv) / 255;
            uint32_t b = (s & 0xFF) + ((d & 0xFF) * inv) / 255;
            drow[tx] = 0xFF000000u | (r << 16) | (g << 8) | b;
        }
    }
}

void RenderLoop() {
    EGC_LOG("render thread started");
    using Clock = std::chrono::steady_clock;
    auto start = Clock::now();
    int aliveLog = 0;
    while (g_threadRunning.load()) {
        if (!g_active.load()) {
            if ((aliveLog++ % 100) == 0) { EGC_LOG("thread alive, inactive"); }
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            continue;
        }
        OHNativeWindow *window = nullptr;
        std::vector<GridItem> items;
        int vpX, vpY, vpW, vpH;
        uint32_t bg;
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            window = g_window;
            items = g_items;
            vpX = g_vpX; vpY = g_vpY; vpW = g_vpW; vpH = g_vpH;
            bg = g_bgColor;
        }
        if (window == nullptr || vpW <= 0 || vpH <= 0) {
            static int idleLog = 0;
            if ((idleLog++ % 60) == 0) {
                EGC_LOG("idle window=%{public}d vp=(%{public}d,%{public}d)",
                        window != nullptr ? 1 : 0, vpW, vpH);
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            continue;
        }

        OHNativeWindowBuffer *buffer = nullptr;
        int fenceFd = -1;
        int reqRc = OH_NativeWindow_NativeWindowRequestBuffer(window, &buffer, &fenceFd);
        if (reqRc != 0 || buffer == nullptr) {
            static int reqLog = 0;
            if ((reqLog++ % 40) == 0) {
                EGC_LOG("requestBuffer failed rc=%{public}d", reqRc);
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            continue;
        }
        BufferHandle *handle = OH_NativeWindow_GetBufferHandleFromNative(buffer);
        if (handle == nullptr || handle->virAddr == nullptr) {
            OH_NativeWindow_NativeWindowAbortBuffer(window, buffer);
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            continue;
        }
        auto *pixels = reinterpret_cast<uint32_t *>(handle->virAddr);
        int stridePx = handle->stride / 4;
        int winW = handle->width;
        int winH = handle->height;
        static int frameLog = 0;
        if ((frameLog++ % 60) == 0) {
            EGC_LOG("frame buf=%{public}dx%{public}d stride=%{public}d fmt=%{public}d items=%{public}zu vp=(%{public}d,%{public}d,%{public}d,%{public}d)",
                    winW, winH, handle->stride, handle->format, items.size(), vpX, vpY, vpW, vpH);
        }

        // 面板区底色（其余区域被上层仓颉内容遮住，无需理会）
        for (int y = vpY; y < vpY + vpH && y < winH; y++) {
            if (y < 0) continue;
            uint32_t *row = pixels + static_cast<size_t>(y) * stridePx;
            for (int x = vpX; x < vpX + vpW && x < winW; x++) {
                if (x < 0) continue;
                row[x] = bg;
            }
        }

        double elapsed =
            std::chrono::duration<double>(Clock::now() - start).count();
        for (auto &item : items) {
            auto anim = AcquireAnimation(item.path);
            if (!anim || anim->frameCount == 0) continue;
            size_t frame = 0;
            if (item.animated && anim->frameCount > 1) {
                double loopSec = static_cast<double>(anim->frameCount) / anim->frameRate;
                double t = fmod(elapsed, loopSec);
                frame = static_cast<size_t>(t * anim->frameRate) % anim->frameCount;
            }
            if (anim->bufferSize != item.size) {
                anim->buffer.assign(static_cast<size_t>(item.size) * item.size, 0);
                anim->bufferSize = item.size;
            }
            rlottie::Surface surface(anim->buffer.data(), item.size, item.size,
                                     static_cast<size_t>(item.size) * 4);
            anim->animation->renderSync(frame, surface, true);
            BlitFrame(pixels, winW, winH, stridePx,
                      anim->buffer.data(), item.size, item.x, item.y);
        }

        Region region;
        Region::Rect rect{};
        rect.x = vpX; rect.y = vpY;
        rect.w = static_cast<uint32_t>(vpW); rect.h = static_cast<uint32_t>(vpH);
        region.rects = &rect;
        region.rectNumber = 1;
        OH_NativeWindow_NativeWindowFlushBuffer(window, buffer, fenceFd, region);

        std::this_thread::sleep_for(std::chrono::milliseconds(33));
    }
}

void *RenderLoopEntry(void *) {
    RenderLoop();
    return nullptr;
}

void EnsureThread() {
    bool expected = false;
    if (g_threadRunning.compare_exchange_strong(expected, true)) {
        // std::thread 在本工程 native 环境疑似静默不跑，直接用 pthread。
        pthread_t tid;
        int rc = pthread_create(&tid, nullptr, RenderLoopEntry, nullptr);
        EGC_LOG("pthread_create rc=%{public}d", rc);
        if (rc == 0) { pthread_detach(tid); }
        else { g_threadRunning.store(false); }
    }
}

} // namespace

extern "C" {

__attribute__((visibility("default"))) void emojiGridCompositorSetSurface(uint64_t surfaceId) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_window != nullptr && g_surfaceId != surfaceId) {
        OH_NativeWindow_DestroyNativeWindow(g_window);
        g_window = nullptr;
    }
    g_surfaceId = surfaceId;
    if (surfaceId != 0 && g_window == nullptr) {
        OHNativeWindow *window = nullptr;
        int rc = OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceId, &window);
        EGC_LOG("setSurface sid=%{public}llu rc=%{public}d",
                static_cast<unsigned long long>(surfaceId), rc);
        if (rc == 0) {
            g_window = window;
            OH_NativeWindow_NativeWindowHandleOpt(window, SET_FORMAT,
                NATIVEBUFFER_PIXEL_FMT_BGRA_8888);
            // CPU 写路径三件套缺一不可：不给 CPU_WRITE usage 的 producer
            // 首次 RequestBuffer 直接永久阻塞（真机实锤：渲染线程无声卡死）。
            uint64_t usage = NATIVEBUFFER_USAGE_CPU_READ |
                NATIVEBUFFER_USAGE_CPU_WRITE | NATIVEBUFFER_USAGE_MEM_DMA;
            OH_NativeWindow_NativeWindowHandleOpt(window, SET_USAGE, usage);
            if (g_bufW > 0 && g_bufH > 0) {
                OH_NativeWindow_NativeWindowHandleOpt(window, SET_BUFFER_GEOMETRY,
                    g_bufW, g_bufH);
            }
        }
    }
    EnsureThread();
}

// payload: "docId|path|x|y|size|animated;..."（px 整数）
__attribute__((visibility("default"))) void emojiGridCompositorSetItems(const char *payload) {
    std::vector<GridItem> items;
    std::string src = payload != nullptr ? payload : "";
    size_t pos = 0;
    while (pos < src.size()) {
        size_t end = src.find(';', pos);
        if (end == std::string::npos) end = src.size();
        std::string rec = src.substr(pos, end - pos);
        pos = end + 1;
        if (rec.empty()) continue;
        // docId|path|x|y|size|animated
        std::vector<std::string> f;
        size_t s0 = 0;
        while (true) {
            size_t bar = rec.find('|', s0);
            if (bar == std::string::npos) { f.push_back(rec.substr(s0)); break; }
            f.push_back(rec.substr(s0, bar - s0));
            s0 = bar + 1;
        }
        if (f.size() < 6) continue;
        GridItem item;
        item.docId = strtoull(f[0].c_str(), nullptr, 10);
        item.path = f[1];
        item.x = atoi(f[2].c_str());
        item.y = atoi(f[3].c_str());
        item.size = atoi(f[4].c_str());
        item.animated = atoi(f[5].c_str()) != 0;
        if (item.size > 0 && !item.path.empty()) items.push_back(std::move(item));
    }
    EGC_LOG("setItems parsed=%{public}zu payloadLen=%{public}zu", items.size(), src.size());
    std::lock_guard<std::mutex> lock(g_mutex);
    g_items = std::move(items);
    g_generation.fetch_add(1);
}

__attribute__((visibility("default"))) void emojiGridCompositorSetViewport(int x, int y, int w, int h, uint32_t bgColor) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_vpX = x; g_vpY = y; g_vpW = w; g_vpH = h;
    g_bgColor = bgColor;
}

// libraryname 回调路径：OnSurfaceCreated 直接给 NativeWindow（FromSurfaceId
// 产线在本环境 RequestBuffer 永久阻塞，真机实锤弃用）。
__attribute__((visibility("default"))) void EmojiGridCompositorAttachWindow(
    void *window, uint64_t w, uint64_t h) {
    EGC_LOG("attachWindow enter %{public}p", window);
    std::lock_guard<std::mutex> lock(g_mutex);
    g_window = reinterpret_cast<OHNativeWindow *>(window);
    g_bufW = static_cast<int>(w);
    g_bufH = static_cast<int>(h);
    if (g_window != nullptr) {
        OH_NativeWindow_NativeWindowHandleOpt(g_window, SET_FORMAT,
            NATIVEBUFFER_PIXEL_FMT_BGRA_8888);
        uint64_t usage = NATIVEBUFFER_USAGE_CPU_READ |
            NATIVEBUFFER_USAGE_CPU_WRITE | NATIVEBUFFER_USAGE_MEM_DMA;
        OH_NativeWindow_NativeWindowHandleOpt(g_window, SET_USAGE, usage);
        OH_NativeWindow_NativeWindowHandleOpt(g_window, SET_BUFFER_GEOMETRY,
            g_bufW, g_bufH);
    }
    EGC_LOG("attachWindow %{public}dx%{public}d", g_bufW, g_bufH);
    EnsureThread();
}

__attribute__((visibility("default"))) void EmojiGridCompositorDetachWindow(void) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_window = nullptr;
    EGC_LOG("detachWindow");
}

__attribute__((visibility("default"))) void emojiGridCompositorSetSurfaceSize(int w, int h) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_bufW = w;
    g_bufH = h;
    if (g_window != nullptr && w > 0 && h > 0) {
        OH_NativeWindow_NativeWindowHandleOpt(g_window, SET_BUFFER_GEOMETRY, w, h);
        EGC_LOG("setSurfaceSize %{public}dx%{public}d", w, h);
    }
}

__attribute__((visibility("default"))) void emojiGridCompositorSetActive(int active) {
    g_active.store(active != 0);
    EnsureThread();
}

} // extern "C"
