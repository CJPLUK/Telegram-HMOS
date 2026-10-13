// 语音消息编码：PCM(WAV/S16LE) → libopus(30 kbps, 20 ms 帧) → 自写 Ogg 分页 → audio/ogg。
// 对位 iOS submodules/OpusBinding/Sources/opusenc/opusenc.m：48 kHz 单声道、
// OPUS_APPLICATION_AUDIO、bitrate 30*1024、frame_size 960；波形算法对位
// ManagedAudioRecorder.swift processWaveformPreview / 停止时的 100 桶归一化（peak=31）。
// libopus 复用 tgcalls_ohos/out/lib/libopus.a（arm64），非 arm64 走 opus_ogg_stub.cpp。
#include "napi/native_api.h"
#include <hilog/log.h>
#include <opus.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#define TAG "CjTelegram"
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0000, TAG, __VA_ARGS__)

namespace {

struct Job {
    std::string pcmPath;
    std::string oggPath;
    int sampleRate = 48000;
    int bitrate = 30 * 1024;
    bool ok = false;
    std::string error;
    int64_t bytes = 0;
    int64_t durationMs = 0;
    std::string waveformHex;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

// ---- Ogg CRC32（多项式 0x04c11db7，非反射，初值 0，无终异或）----
uint32_t g_crcTable[256];
bool g_crcInit = false;
void initCrc() {
    if (g_crcInit) return;
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t r = i << 24;
        for (int j = 0; j < 8; j++) {
            r = (r & 0x80000000u) ? ((r << 1) ^ 0x04c11db7u) : (r << 1);
        }
        g_crcTable[i] = r;
    }
    g_crcInit = true;
}
uint32_t oggCrc(const uint8_t* d, size_t n) {
    uint32_t c = 0;
    for (size_t i = 0; i < n; i++) {
        c = (c << 8) ^ g_crcTable[((c >> 24) & 0xff) ^ d[i]];
    }
    return c;
}

inline void putLE16(std::vector<uint8_t>& v, uint16_t x) { v.push_back(x & 0xff); v.push_back((x >> 8) & 0xff); }
inline void putLE32(std::vector<uint8_t>& v, uint32_t x) { for (int i = 0; i < 4; i++) v.push_back((x >> (8 * i)) & 0xff); }
inline void putLE64(std::vector<uint8_t>& v, uint64_t x) { for (int i = 0; i < 8; i++) v.push_back((x >> (8 * i)) & 0xff); }
inline uint16_t rdLE16(const uint8_t* p) { return (uint16_t)(p[0] | (p[1] << 8)); }
inline uint32_t rdLE32(const uint8_t* p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }

// ---- 最小 Ogg 分页器：一页 ≤255 个 segment；OpusHead/OpusTags 各自独占一页 ----
class OggWriter {
public:
    OggWriter(FILE* f, uint32_t serial) : f_(f), serial_(serial) { initCrc(); }

    bool addPacket(const uint8_t* d, size_t n, int64_t granuleAfter, bool flush, bool eos) {
        size_t segs = n / 255 + 1;
        if (segCount_ + segs > 255) {
            if (!flushPage(lastGranule_, false)) return false;
        }
        data_.insert(data_.end(), d, d + n);
        lens_.push_back(n);
        segCount_ += segs;
        lastGranule_ = granuleAfter;
        if (flush || eos || lens_.size() >= 50) return flushPage(granuleAfter, eos);
        return true;
    }

    bool finish(int64_t granule) { return lens_.empty() ? true : flushPage(granule, true); }

private:
    bool flushPage(int64_t granule, bool eos) {
        if (lens_.empty()) return true;
        std::vector<uint8_t> page;
        page.reserve(27 + segCount_ + data_.size());
        const char* magic = "OggS";
        page.insert(page.end(), magic, magic + 4);
        page.push_back(0);                                   // version
        page.push_back((first_ ? 0x02 : 0) | (eos ? 0x04 : 0)); // header type
        putLE64(page, (uint64_t)granule);
        putLE32(page, serial_);
        putLE32(page, seq_++);
        putLE32(page, 0);                                    // crc 占位
        page.push_back((uint8_t)segCount_);
        for (size_t n : lens_) {
            while (n >= 255) { page.push_back(255); n -= 255; }
            page.push_back((uint8_t)n);
        }
        page.insert(page.end(), data_.begin(), data_.end());
        uint32_t crc = oggCrc(page.data(), page.size());
        page[22] = crc & 0xff; page[23] = (crc >> 8) & 0xff; page[24] = (crc >> 16) & 0xff; page[25] = (crc >> 24) & 0xff;
        bool ok = fwrite(page.data(), 1, page.size(), f_) == page.size();
        first_ = false;
        data_.clear(); lens_.clear(); segCount_ = 0;
        return ok;
    }

    FILE* f_;
    uint32_t serial_;
    uint32_t seq_ = 0;
    bool first_ = true;
    std::vector<uint8_t> data_;
    std::vector<size_t> lens_;
    size_t segCount_ = 0;
    int64_t lastGranule_ = 0;
};

// iOS ManagedAudioRecorder 停止录音时的波形归一化：每包峰值 → 100 桶取 max →
// calculatedPeak = 均值*1.8（≥2500）→ min(sample, calculatedPeak)*31/calculatedPeak。
std::vector<uint8_t> buildWaveform5bit(const std::vector<int16_t>& peaks) {
    int16_t scaled[100];
    memset(scaled, 0, sizeof(scaled));
    size_t count = peaks.size();
    for (size_t i = 0; i < count; i++) {
        size_t idx = i * 100 / count;
        if (scaled[idx] < peaks[i]) scaled[idx] = peaks[i];
    }
    int64_t sum = 0;
    for (int i = 0; i < 100; i++) sum += scaled[i];
    int64_t calculatedPeak = (int64_t)((double)sum * 1.8 / 100.0);
    if (calculatedPeak < 2500) calculatedPeak = 2500;
    std::vector<uint8_t> out(63, 0);
    int bitPos = 0;
    for (int i = 0; i < 100; i++) {
        int64_t s = scaled[i] < 0 ? 0 : scaled[i];
        int64_t minPeak = s < calculatedPeak ? s : calculatedPeak;
        int64_t v = minPeak * 31 / calculatedPeak;
        if (v > 31) v = 31;
        int byteIdx = bitPos / 8, bitOff = bitPos % 8;
        out[byteIdx] |= (uint8_t)((v << bitOff) & 0xff);
        if (bitOff + 5 > 8 && byteIdx + 1 < 63) out[byteIdx + 1] |= (uint8_t)(v >> (8 - bitOff));
        bitPos += 5;
    }
    return out;
}

std::string toHex(const std::vector<uint8_t>& b) {
    static const char* h = "0123456789abcdef";
    std::string s; s.reserve(b.size() * 2);
    for (uint8_t x : b) { s.push_back(h[x >> 4]); s.push_back(h[x & 15]); }
    return s;
}

bool readFile(const std::string& path, std::vector<uint8_t>& out) {
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return false;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n <= 0) { fclose(f); return false; }
    out.resize((size_t)n);
    size_t got = fread(out.data(), 1, (size_t)n, f);
    fclose(f);
    out.resize(got);
    return got > 0;
}

void runEncode(Job& job) {
    std::vector<uint8_t> file;
    if (!readFile(job.pcmPath, file)) { job.error = "read pcm failed"; return; }

    // WAV 头解析（RIFF/fmt/data）；非 RIFF 视为裸 S16LE
    size_t dataOff = 0, dataLen = file.size();
    int channels = 1, rate = job.sampleRate, bits = 16;
    if (file.size() >= 12 && memcmp(file.data(), "RIFF", 4) == 0 && memcmp(file.data() + 8, "WAVE", 4) == 0) {
        size_t pos = 12;
        bool haveData = false;
        while (pos + 8 <= file.size()) {
            const uint8_t* id = file.data() + pos;
            uint32_t len = rdLE32(file.data() + pos + 4);
            if (memcmp(id, "fmt ", 4) == 0 && pos + 8 + 16 <= file.size()) {
                channels = rdLE16(file.data() + pos + 10);
                rate = (int)rdLE32(file.data() + pos + 12);
                bits = rdLE16(file.data() + pos + 22);
            } else if (memcmp(id, "data", 4) == 0) {
                dataOff = pos + 8;
                dataLen = file.size() - dataOff;
                if (len < dataLen) dataLen = len;
                haveData = true;
                break;
            }
            pos += 8 + len + (len & 1);
        }
        if (!haveData) { job.error = "wav without data chunk"; return; }
    }
    if (bits != 16 || channels < 1 || channels > 2) { job.error = "unsupported pcm format"; return; }
    if (rate != 8000 && rate != 12000 && rate != 16000 && rate != 24000 && rate != 48000) {
        job.error = "unsupported sample rate " + std::to_string(rate); return;
    }
    const int16_t* pcm = reinterpret_cast<const int16_t*>(file.data() + dataOff);
    size_t frames = dataLen / 2 / (size_t)channels;
    if (frames == 0) { job.error = "empty pcm"; return; }

    // 单声道化（Telegram 语音单声道）
    std::vector<int16_t> mono(frames);
    for (size_t i = 0; i < frames; i++) {
        mono[i] = channels == 2 ? (int16_t)(((int)pcm[i * 2] + (int)pcm[i * 2 + 1]) / 2) : pcm[i];
    }

    int err = 0;
    OpusEncoder* enc = opus_encoder_create(rate, 1, OPUS_APPLICATION_AUDIO, &err);
    if (!enc || err != OPUS_OK) { job.error = std::string("opus_encoder_create: ") + opus_strerror(err); return; }
    opus_encoder_ctl(enc, OPUS_SET_BITRATE(job.bitrate));
    opus_encoder_ctl(enc, OPUS_SET_VBR(1));
    opus_encoder_ctl(enc, OPUS_SET_LSB_DEPTH(16));
    opus_int32 lookahead = 0;
    opus_encoder_ctl(enc, OPUS_GET_LOOKAHEAD(&lookahead));
    const int64_t preskip48 = (int64_t)lookahead * 48000 / rate;

    FILE* out = fopen(job.oggPath.c_str(), "wb");
    if (!out) { opus_encoder_destroy(enc); job.error = "open ogg failed"; return; }
    uint32_t serial = (uint32_t)(reinterpret_cast<uintptr_t>(&job) ^ (uint32_t)frames ^ 0x5a17u);
    OggWriter ogg(out, serial);

    // OpusHead（RFC 7845 §5.1）
    std::vector<uint8_t> head;
    head.insert(head.end(), (const uint8_t*)"OpusHead", (const uint8_t*)"OpusHead" + 8);
    head.push_back(1);                       // version
    head.push_back(1);                       // channels
    putLE16(head, (uint16_t)preskip48);      // pre-skip（48k 采样）
    putLE32(head, (uint32_t)rate);           // input sample rate
    putLE16(head, 0);                        // output gain
    head.push_back(0);                       // mapping family
    // OpusTags（RFC 7845 §5.2）
    std::vector<uint8_t> tags;
    tags.insert(tags.end(), (const uint8_t*)"OpusTags", (const uint8_t*)"OpusTags" + 8);
    const char* vendor = "libopus (Telegram_Cangjie)";
    putLE32(tags, (uint32_t)strlen(vendor));
    tags.insert(tags.end(), (const uint8_t*)vendor, (const uint8_t*)vendor + strlen(vendor));
    putLE32(tags, 0);
    bool ok = ogg.addPacket(head.data(), head.size(), 0, true, false)
           && ogg.addPacket(tags.data(), tags.size(), 0, true, false);

    const int frameSize = rate / 50;         // 20 ms（48k → 960，对位 iOS frame_size）
    const int64_t granuleStep = 960;         // 每帧对应 48k 采样数
    std::vector<int16_t> frameBuf((size_t)frameSize, 0);
    std::vector<uint8_t> packet(4000);
    std::vector<int16_t> peaks;
    peaks.reserve(frames / (size_t)frameSize + 1);
    int64_t granule = preskip48;
    size_t pos = 0;
    while (ok && pos < frames) {
        size_t n = frames - pos < (size_t)frameSize ? frames - pos : (size_t)frameSize;
        std::fill(frameBuf.begin(), frameBuf.end(), 0);
        int16_t peak = 0;
        for (size_t i = 0; i < n; i++) {
            int16_t s = mono[pos + i];
            frameBuf[i] = s;
            int16_t a = s < 0 ? (s == INT16_MIN ? INT16_MAX : (int16_t)-s) : s;
            if (a > peak) peak = a;
        }
        peaks.push_back(peak);
        int len = opus_encode(enc, frameBuf.data(), frameSize, packet.data(), (opus_int32)packet.size());
        if (len < 0) { job.error = std::string("opus_encode: ") + opus_strerror(len); ok = false; break; }
        pos += n;
        bool last = pos >= frames;
        // 末页 granule 只算真实采样（去掉补零），播放器据此裁掉尾部
        granule = last ? preskip48 + (int64_t)frames * 48000 / rate : granule + granuleStep;
        ok = ogg.addPacket(packet.data(), (size_t)len, granule, false, last);
    }
    if (ok) ok = ogg.finish(granule);
    fclose(out);
    opus_encoder_destroy(enc);
    if (!ok) { if (job.error.empty()) job.error = "ogg write failed"; remove(job.oggPath.c_str()); return; }

    FILE* chk = fopen(job.oggPath.c_str(), "rb");
    if (chk) { fseek(chk, 0, SEEK_END); job.bytes = ftell(chk); fclose(chk); }
    job.durationMs = (int64_t)frames * 1000 / rate;
    job.waveformHex = toHex(buildWaveform5bit(peaks));
    job.ok = true;
    LOGI("[OpusOgg] encoded %zu frames @%dHz → %lld B, %lld ms, preskip=%lld, %zu packets",
         frames, rate, (long long)job.bytes, (long long)job.durationMs, (long long)preskip48, peaks.size());
}

std::string getString(napi_env env, napi_value v) {
    size_t len = 0;
    if (napi_get_value_string_utf8(env, v, nullptr, 0, &len) != napi_ok) return "";
    std::string s(len, '\0');
    size_t got = 0;
    napi_get_value_string_utf8(env, v, &s[0], len + 1, &got);
    s.resize(got);
    return s;
}

void execute(napi_env, void* data) { runEncode(*static_cast<Job*>(data)); }

void complete(napi_env env, napi_status, void* data) {
    Job* job = static_cast<Job*>(data);
    napi_value obj, v;
    napi_create_object(env, &obj);
    napi_get_boolean(env, job->ok, &v); napi_set_named_property(env, obj, "ok", v);
    napi_create_double(env, (double)job->bytes, &v); napi_set_named_property(env, obj, "bytes", v);
    napi_create_double(env, (double)job->durationMs, &v); napi_set_named_property(env, obj, "durationMs", v);
    napi_create_string_utf8(env, job->waveformHex.c_str(), NAPI_AUTO_LENGTH, &v); napi_set_named_property(env, obj, "waveformHex", v);
    napi_create_string_utf8(env, job->error.c_str(), NAPI_AUTO_LENGTH, &v); napi_set_named_property(env, obj, "error", v);
    if (!job->ok) LOGE("[OpusOgg] failed: %{public}s", job->error.c_str());
    napi_resolve_deferred(env, job->deferred, obj);
    napi_delete_async_work(env, job->work);
    delete job;
}

} // namespace

// encodeVoice(pcmPath, oggPath, sampleRate?, bitrate?) → Promise<{ok, bytes, durationMs, waveformHex, error}>
napi_value OpusOggEncodeVoice(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4] = { nullptr, nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    Job* job = new Job();
    if (argc >= 2) { job->pcmPath = getString(env, argv[0]); job->oggPath = getString(env, argv[1]); }
    int32_t n = 0;
    if (argc >= 3 && napi_get_value_int32(env, argv[2], &n) == napi_ok && n > 0) job->sampleRate = n;
    if (argc >= 4 && napi_get_value_int32(env, argv[3], &n) == napi_ok && n > 0) job->bitrate = n;
    napi_value promise = nullptr;
    napi_create_promise(env, &job->deferred, &promise);
    napi_value name;
    napi_create_string_utf8(env, "opusOggEncodeVoice", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, execute, complete, job, &job->work);
    napi_queue_async_work(env, job->work);
    return promise;
}
