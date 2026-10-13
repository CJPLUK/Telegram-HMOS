#include <algorithm>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <zlib.h>

#include "third_party/rlottie/inc/rlottie.h"

// This bundled rlottie revision declares the function in namespace rlottie
// but its static library exports the legacy global ABI symbol.
void configureModelCacheSize(size_t cacheSize);

// 供 emoji_grid_compositor 复用的 gzip 解包（外部链接符号）。
bool TelegramLottieInflateGzip(const uint8_t *data, size_t size, std::string &json);
void TelegramLottiePatchRootOutPoint(std::string &json);

namespace {

struct TelegramLottieAnimation {
    std::unique_ptr<rlottie::Animation> animation;
};

bool InflateGzip(const uint8_t *data, size_t size, std::string &json) {
    if (data == nullptr || size == 0) {
        return false;
    }

    z_stream stream{};
    stream.next_in = const_cast<Bytef *>(reinterpret_cast<const Bytef *>(data));
    stream.avail_in = static_cast<uInt>(size);
    if (inflateInit2(&stream, MAX_WBITS + 16) != Z_OK) {
        return false;
    }

    std::vector<char> output(64 * 1024);
    int status = Z_OK;
    while (status == Z_OK) {
        const size_t previousSize = json.size();
        stream.next_out = reinterpret_cast<Bytef *>(output.data());
        stream.avail_out = static_cast<uInt>(output.size());
        status = inflate(&stream, Z_NO_FLUSH);
        json.append(output.data(), output.size() - stream.avail_out);
        if (json.size() == previousSize && stream.avail_in == 0 && status == Z_OK) {
            status = Z_DATA_ERROR;
        }
    }
    inflateEnd(&stream);
    return status == Z_STREAM_END && !json.empty();
}

}  // namespace

extern "C" __attribute__((visibility("default"))) void *tg_lottie_create(
    const uint8_t *data, uint64_t size, const char *cacheKey) {
    if (data == nullptr || size == 0) {
        return nullptr;
    }

    static std::once_flag modelCacheConfigured;
    std::call_once(modelCacheConfigured, [] {
        // Visible chat nodes own independent animation instances, while the
        // immutable parsed model is shared by the stable document/emoji key.
        // A larger model LRU avoids repeating gzip + JSON parsing after a
        // short scroll, matching iOS's shared animation cache behavior.
        ::configureModelCacheSize(32);
    });

    std::string json;
    if (size >= 2 && data[0] == 0x1f && data[1] == 0x8b) {
        if (!InflateGzip(data, static_cast<size_t>(size), json)) {
            return nullptr;
        }
    } else {
        json.assign(reinterpret_cast<const char *>(data), static_cast<size_t>(size));
    }

    TelegramLottiePatchRootOutPoint(json);

    auto holder = std::make_unique<TelegramLottieAnimation>();
    holder->animation = rlottie::Animation::loadFromData(
        json, cacheKey == nullptr ? std::string() : std::string(cacheKey));
    if (!holder->animation) {
        return nullptr;
    }
    return holder.release();
}

extern "C" __attribute__((visibility("default"))) uint32_t tg_lottie_frame_count(void *handle) {
    auto *holder = static_cast<TelegramLottieAnimation *>(handle);
    return holder == nullptr ? 0U : static_cast<uint32_t>(holder->animation->totalFrame());
}

extern "C" __attribute__((visibility("default"))) double tg_lottie_frame_rate(void *handle) {
    auto *holder = static_cast<TelegramLottieAnimation *>(handle);
    return holder == nullptr ? 0.0 : holder->animation->frameRate();
}

extern "C" __attribute__((visibility("default"))) int32_t tg_lottie_render(
    void *handle, uint32_t frame, uint32_t width, uint32_t height,
    uint8_t *output, uint64_t outputSize) {
    auto *holder = static_cast<TelegramLottieAnimation *>(handle);
    const uint64_t required = static_cast<uint64_t>(width) * height * 4U;
    if (holder == nullptr || output == nullptr || width == 0 || height == 0 || outputSize < required) {
        return 0;
    }
    std::memset(output, 0, static_cast<size_t>(required));
    const size_t totalFrames = std::max<size_t>(1, holder->animation->totalFrame());
    holder->animation->renderSync(
        std::min<size_t>(frame, totalFrames - 1),
        rlottie::Surface(reinterpret_cast<uint32_t *>(output), width, height, width * 4U));
    return 1;
}

extern "C" __attribute__((visibility("default"))) void tg_lottie_destroy(void *handle) {
    delete static_cast<TelegramLottieAnimation *>(handle);
}

bool TelegramLottieInflateGzip(const uint8_t *data, size_t size, std::string &json) {
    return InflateGzip(data, size, json);
}

// Telegram 部分 .tgs 的根 out-point 是坏的（root op=1 而图层 op=180，真机
// 解剖实锤）：rlottie totalFrame 按 root op 算，整包变成单帧静画。Telegram
// 官方客户端的 rlottie 分支按图层最大 op 播。这里对位：扫全文取最大
// "op" 数值，回写第一处（root 区）op。
void TelegramLottiePatchRootOutPoint(std::string &json) {
    double maxOp = 0.0;
    size_t firstPos = std::string::npos;
    size_t firstLen = 0;
    size_t pos = 0;
    while (true) {
        pos = json.find("\"op\":", pos);
        if (pos == std::string::npos) break;
        size_t numStart = pos + 5;
        while (numStart < json.size() && json[numStart] == ' ') numStart++;
        size_t numEnd = numStart;
        while (numEnd < json.size() &&
               (isdigit(static_cast<unsigned char>(json[numEnd])) ||
                json[numEnd] == '.' || json[numEnd] == '-' ||
                json[numEnd] == 'e' || json[numEnd] == 'E' || json[numEnd] == '+')) {
            numEnd++;
        }
        if (numEnd > numStart) {
            double v = atof(json.substr(numStart, numEnd - numStart).c_str());
            if (v > maxOp) maxOp = v;
            if (firstPos == std::string::npos) {
                firstPos = numStart;
                firstLen = numEnd - numStart;
            }
        }
        pos = numEnd;
    }
    if (firstPos == std::string::npos || maxOp <= 1.0) return;
    double firstVal = atof(json.substr(firstPos, firstLen).c_str());
    // 只救「root op 明显坏掉」（≤1）的文件。全局最大 op 会扫到 asset 子图层
    // （预合成的时间重映射区间远超真实时长，真机 🤑 duck：root op=180、
    // 子图层 op=350）——无条件覆写会把好文件拉长，尾段没有任何图层覆盖，
    // 渲染出 ~0.5s 全透明帧，循环一圈整帧闪一次（「贴纸空白帧」根因）。
    if (firstVal > 1.5) return;
    if (firstVal >= maxOp) return;
    char buf[32];
    snprintf(buf, sizeof(buf), "%g", maxOp);
    json.replace(firstPos, firstLen, buf);
}

// .acv3 构建的 delta+RLE 编码（native 下沉）：与仓颉 encodeRunsInto 输出
// 字节级一致（[skip i32][lit i32][lit bytes]...，<9 字节的相同段并入字面段）。
// 仓颉逐字节循环编 74KB×2 数组是构建器的 CPU 大头（真机 136px webm ~12-16s/个）。
// 返回写入 out 的字节数；容量不足返回 -1。
extern "C" __attribute__((visibility("default"))) int64_t tg_delta_encode_runs(
    const uint8_t *prev, const uint8_t *cur, uint64_t len,
    uint8_t *out, uint64_t outCap) {
    uint64_t pos = 0;
    uint64_t o = 0;
    while (pos < len) {
        uint64_t skip = 0;
        while (pos + skip < len && cur[pos + skip] == prev[pos + skip]) skip++;
        uint64_t lit = 0;
        while (pos + skip + lit < len) {
            uint64_t i = pos + skip + lit;
            if (cur[i] != prev[i]) { lit++; continue; }
            if (i + 9 < len) {
                bool run9 = true;
                for (int k = 0; k < 9; k++) {
                    if (cur[i + k] != prev[i + k]) { run9 = false; break; }
                }
                if (!run9) { lit++; continue; }
            }
            break;
        }
        if (o + 8 + lit > outCap) return -1;
        int32_t s32 = (int32_t)skip;
        int32_t l32 = (int32_t)lit;
        out[o++] = (uint8_t)(s32 & 0xff); out[o++] = (uint8_t)((s32 >> 8) & 0xff);
        out[o++] = (uint8_t)((s32 >> 16) & 0xff); out[o++] = (uint8_t)((s32 >> 24) & 0xff);
        out[o++] = (uint8_t)(l32 & 0xff); out[o++] = (uint8_t)((l32 >> 8) & 0xff);
        out[o++] = (uint8_t)((l32 >> 16) & 0xff); out[o++] = (uint8_t)((l32 >> 24) & 0xff);
        memcpy(out + o, cur + pos + skip, lit);
        o += lit;
        pos += skip + lit;
    }
    return (int64_t)o;
}
