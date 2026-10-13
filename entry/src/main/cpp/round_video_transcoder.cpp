// 圆形视频消息离线转码：mp4（AVRecorder 录制，任意分辨率/旋转）→ 中心裁方 → 缩放到 side×side →
// H.264 重编码 + 音频 AAC 直通 → mp4。对位 iOS VideoMessageCameraScreen 的 400×400 输出
//（iOS 用 AVAssetWriter 直接录方形；OHOS 相机 VideoProfile 没有 1:1，只能录完再裁）。
// 管线：OH_AVDemuxer → OH_VideoDecoder(buffer, NV12) → libyuv 裁/缩/旋 → OH_VideoEncoder(buffer, NV12) → OH_AVMuxer。
#include "napi/native_api.h"
#include <hilog/log.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avsource.h>
#include <multimedia/player_framework/native_avdemuxer.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <multimedia/player_framework/native_avmuxer.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <libyuv.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

#define TAG "CjTelegram"
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0000, TAG, __VA_ARGS__)

namespace {

struct Frame {
    std::vector<uint8_t> i420;   // side×side I420
    int64_t pts = 0;
    bool eos = false;
};

struct AudioSample {
    OH_AVCodecBufferAttr attr;
    std::vector<uint8_t> data;
};

struct Ctx {
    // 参数
    std::string inPath, outPath;
    int side = 400;            // square：边长；fit：长边上限
    int mode = 0;              // 0 square（中心裁方）/ 1 fit（等比缩放，不裁）
    int outW = 400, outH = 400;
    int fallbackRotation = 0;
    int bitrate = 0;           // 0 → square 1.2 Mbps / fit 2.2 Mbps
    // 源
    int inFd = -1, outFd = -1;
    OH_AVSource* source = nullptr;
    OH_AVDemuxer* demuxer = nullptr;
    OH_AVFormat* audioTrackFmt = nullptr;
    int vTrack = -1, aTrack = -1;
    int srcW = 0, srcH = 0, rotation = 0;
    double fps = 30.0;
    bool decInputEos = false;
    // 解码器输出布局
    OH_AVCodec* dec = nullptr;
    bool decInfoReady = false;
    int decPixFmt = AV_PIXEL_FORMAT_NV12;
    int decStride = 0, decSliceH = 0, decPicW = 0, decPicH = 0;
    // 编码器输入布局
    OH_AVCodec* enc = nullptr;
    bool encInfoReady = false;
    int encStride = 0, encSliceH = 0;
    // 复用
    OH_AVMuxer* muxer = nullptr;
    std::mutex muxMtx;
    bool muxerStarted = false;
    int32_t vOut = -1, aOut = -1;
    std::vector<uint8_t> codecConfig;
    std::vector<AudioSample> audio;
    // 帧队列（解码回调 → 编码回调）
    std::mutex qm;
    std::condition_variable qcv;
    std::deque<Frame> q;
    // 完成
    std::mutex dm;
    std::condition_variable dcv;
    bool done = false, failed = false;
    std::string err;
    int64_t frames = 0, lastPts = 0;
    // napi
    bool ok = false;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

void fail(Ctx* c, const std::string& e) {
    {
        std::lock_guard<std::mutex> lk(c->dm);
        if (!c->failed) { c->failed = true; c->err = e; }
        c->done = true;
    }
    c->dcv.notify_all();
    c->qcv.notify_all();
    LOGE("[RoundVideo] %{public}s", e.c_str());
}

void finish(Ctx* c) {
    { std::lock_guard<std::mutex> lk(c->dm); c->done = true; }
    c->dcv.notify_all();
}

int getInt(OH_AVFormat* f, const char* key, int def) {
    int32_t v = 0;
    return (f && OH_AVFormat_GetIntValue(f, key, &v)) ? v : def;
}

// ---------- 解码器回调 ----------
void decOnError(OH_AVCodec*, int32_t code, void* ud) { fail((Ctx*)ud, "decoder error " + std::to_string(code)); }

void readDecInfo(Ctx* c, OH_AVFormat* f) {
    c->decPixFmt = getInt(f, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
    c->decPicW = getInt(f, OH_MD_KEY_VIDEO_PIC_WIDTH, getInt(f, OH_MD_KEY_WIDTH, c->srcW));
    c->decPicH = getInt(f, OH_MD_KEY_VIDEO_PIC_HEIGHT, getInt(f, OH_MD_KEY_HEIGHT, c->srcH));
    c->decStride = getInt(f, OH_MD_KEY_VIDEO_STRIDE, c->decPicW);
    c->decSliceH = getInt(f, OH_MD_KEY_VIDEO_SLICE_HEIGHT, c->decPicH);
    if (c->decStride < c->decPicW) c->decStride = c->decPicW;
    if (c->decSliceH < c->decPicH) c->decSliceH = c->decPicH;
    c->decInfoReady = true;
    LOGI("[RoundVideo] decoder out: fmt=%{public}d pic=%{public}dx%{public}d stride=%{public}d slice=%{public}d",
         c->decPixFmt, c->decPicW, c->decPicH, c->decStride, c->decSliceH);
}

void decOnStreamChanged(OH_AVCodec*, OH_AVFormat* f, void* ud) { readDecInfo((Ctx*)ud, f); }

void decOnNeedInput(OH_AVCodec* codec, uint32_t idx, OH_AVBuffer* buf, void* ud) {
    Ctx* c = (Ctx*)ud;
    if (c->failed) return;
    OH_AVCodecBufferAttr attr = { 0, 0, 0, 0 };
    if (c->decInputEos) {
        attr.flags = AVCODEC_BUFFER_FLAGS_EOS;
        OH_AVBuffer_SetBufferAttr(buf, &attr);
        OH_VideoDecoder_PushInputBuffer(codec, idx);
        return;
    }
    OH_AVErrCode r = OH_AVDemuxer_ReadSampleBuffer(c->demuxer, (uint32_t)c->vTrack, buf);
    OH_AVBuffer_GetBufferAttr(buf, &attr);
    if (r != AV_ERR_OK || attr.size <= 0) {
        attr.size = 0;
        attr.flags = AVCODEC_BUFFER_FLAGS_EOS;
        OH_AVBuffer_SetBufferAttr(buf, &attr);
        c->decInputEos = true;
    } else if (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) {
        c->decInputEos = true;
    }
    OH_VideoDecoder_PushInputBuffer(codec, idx);
}

void decOnNewOutput(OH_AVCodec* codec, uint32_t idx, OH_AVBuffer* buf, void* ud) {
    Ctx* c = (Ctx*)ud;
    OH_AVCodecBufferAttr attr = { 0, 0, 0, 0 };
    OH_AVBuffer_GetBufferAttr(buf, &attr);
    if (attr.size > 0 && !c->failed) {
        if (!c->decInfoReady) {
            OH_AVFormat* f = OH_VideoDecoder_GetOutputDescription(codec);
            if (f) { readDecInfo(c, f); OH_AVFormat_Destroy(f); }
            else { c->decPicW = c->srcW; c->decPicH = c->srcH; c->decStride = c->srcW; c->decSliceH = c->srcH; c->decInfoReady = true; }
        }
        const uint8_t* base = OH_AVBuffer_GetAddr(buf);
        const int W = c->decPicW, H = c->decPicH, S = c->decStride, SH = c->decSliceH;
        // 裁剪区：square 取中心方块；fit 取整帧
        int cw, ch, cx, cy;
        if (c->mode == 1) { cw = W & ~1; ch = H & ~1; cx = 0; cy = 0; }
        else { cw = ch = (W < H ? W : H) & ~1; cx = ((W - cw) / 2) & ~1; cy = ((H - ch) / 2) & ~1; }
        // 1) 裁剪区 → I420(cw×ch)
        std::vector<uint8_t> crop((size_t)cw * ch * 3 / 2);
        uint8_t* cy_ = crop.data();
        uint8_t* cu_ = cy_ + (size_t)cw * ch;
        uint8_t* cv_ = cu_ + (size_t)cw * ch / 4;
        const uint8_t* y = base + (size_t)cy * S + cx;
        if (c->decPixFmt == AV_PIXEL_FORMAT_YUVI420) {
            const uint8_t* u = base + (size_t)S * SH + (size_t)(cy / 2) * (S / 2) + cx / 2;
            const uint8_t* v = u + (size_t)(S / 2) * (SH / 2);
            libyuv::I420Copy(y, S, u, S / 2, v, S / 2, cy_, cw, cu_, cw / 2, cv_, cw / 2, cw, ch);
        } else {
            const uint8_t* uv = base + (size_t)S * SH + (size_t)(cy / 2) * S + cx;
            if (c->decPixFmt == AV_PIXEL_FORMAT_NV21)
                libyuv::NV21ToI420(y, S, uv, S, cy_, cw, cu_, cw / 2, cv_, cw / 2, cw, ch);
            else
                libyuv::NV12ToI420(y, S, uv, S, cy_, cw, cu_, cw / 2, cv_, cw / 2, cw, ch);
        }
        // 2) 缩放到旋转前尺寸（旋转 90/270 时输出宽高对调）
        const bool swap = (c->rotation == 90 || c->rotation == 270);
        const int sw = swap ? c->outH : c->outW;
        const int sh = swap ? c->outW : c->outH;
        std::vector<uint8_t> scaled((size_t)sw * sh * 3 / 2);
        uint8_t* sy = scaled.data(); uint8_t* su = sy + (size_t)sw * sh; uint8_t* sv = su + (size_t)sw * sh / 4;
        libyuv::I420Scale(cy_, cw, cu_, cw / 2, cv_, cw / 2, cw, ch, sy, sw, su, sw / 2, sv, sw / 2, sw, sh, libyuv::kFilterBox);
        // 3) 按容器旋转矩阵摆正 → outW×outH
        Frame fr;
        fr.pts = attr.pts;
        if (c->rotation == 90 || c->rotation == 180 || c->rotation == 270) {
            const int ow = c->outW, oh = c->outH;
            fr.i420.resize((size_t)ow * oh * 3 / 2);
            uint8_t* ry = fr.i420.data(); uint8_t* ru = ry + (size_t)ow * oh; uint8_t* rv = ru + (size_t)ow * oh / 4;
            libyuv::RotationMode m = c->rotation == 90 ? libyuv::kRotate90 : (c->rotation == 180 ? libyuv::kRotate180 : libyuv::kRotate270);
            libyuv::I420Rotate(sy, sw, su, sw / 2, sv, sw / 2, ry, ow, ru, ow / 2, rv, ow / 2, sw, sh, m);
        } else {
            fr.i420 = std::move(scaled);
        }
        { std::lock_guard<std::mutex> lk(c->qm); c->q.push_back(std::move(fr)); }
        c->qcv.notify_one();
    }
    if (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) {
        Frame e; e.eos = true;
        { std::lock_guard<std::mutex> lk(c->qm); c->q.push_back(std::move(e)); }
        c->qcv.notify_one();
    }
    OH_VideoDecoder_FreeOutputBuffer(codec, idx);
}

// ---------- 编码器回调 ----------
void encOnError(OH_AVCodec*, int32_t code, void* ud) { fail((Ctx*)ud, "encoder error " + std::to_string(code)); }
void encOnStreamChanged(OH_AVCodec*, OH_AVFormat*, void*) {}

void encOnNeedInput(OH_AVCodec* codec, uint32_t idx, OH_AVBuffer* buf, void* ud) {
    Ctx* c = (Ctx*)ud;
    Frame fr;
    {
        std::unique_lock<std::mutex> lk(c->qm);
        c->qcv.wait(lk, [&] { return !c->q.empty() || c->failed; });
        if (c->failed) return;
        fr = std::move(c->q.front());
        c->q.pop_front();
    }
    OH_AVCodecBufferAttr attr = { fr.pts, 0, 0, 0 };
    if (fr.eos) {
        attr.flags = AVCODEC_BUFFER_FLAGS_EOS;
        OH_AVBuffer_SetBufferAttr(buf, &attr);
        OH_VideoEncoder_PushInputBuffer(codec, idx);
        return;
    }
    const int OW = c->outW, OH = c->outH;
    if (!c->encInfoReady) {
        OH_AVFormat* f = OH_VideoEncoder_GetInputDescription(codec);
        c->encStride = f ? getInt(f, OH_MD_KEY_VIDEO_STRIDE, OW) : OW;
        c->encSliceH = f ? getInt(f, OH_MD_KEY_VIDEO_SLICE_HEIGHT, OH) : OH;
        if (f) OH_AVFormat_Destroy(f);
        if (c->encStride < OW) c->encStride = OW;
        if (c->encSliceH < OH) c->encSliceH = OH;
        c->encInfoReady = true;
        LOGI("[RoundVideo] encoder in: stride=%{public}d slice=%{public}d", c->encStride, c->encSliceH);
    }
    int need = c->encStride * c->encSliceH * 3 / 2;
    int cap = OH_AVBuffer_GetCapacity(buf);
    if (need > cap) { fail(c, "encoder input too small"); return; }
    uint8_t* dst = OH_AVBuffer_GetAddr(buf);
    const uint8_t* sy = fr.i420.data(); const uint8_t* su = sy + (size_t)OW * OH; const uint8_t* sv = su + (size_t)OW * OH / 4;
    libyuv::I420ToNV12(sy, OW, su, OW / 2, sv, OW / 2, dst, c->encStride, dst + (size_t)c->encStride * c->encSliceH, c->encStride, OW, OH);
    attr.size = need;
    OH_AVBuffer_SetBufferAttr(buf, &attr);
    OH_VideoEncoder_PushInputBuffer(codec, idx);
}

void ensureMuxerStarted(Ctx* c) {
    std::lock_guard<std::mutex> lk(c->muxMtx);
    if (c->muxerStarted || c->failed) return;
    OH_AVFormat* vf = OH_AVFormat_Create();
    OH_AVFormat_SetStringValue(vf, OH_MD_KEY_CODEC_MIME, OH_AVCODEC_MIMETYPE_VIDEO_AVC);
    OH_AVFormat_SetIntValue(vf, OH_MD_KEY_WIDTH, c->outW);
    OH_AVFormat_SetIntValue(vf, OH_MD_KEY_HEIGHT, c->outH);
    OH_AVFormat_SetDoubleValue(vf, OH_MD_KEY_FRAME_RATE, c->fps);
    OH_AVErrCode r = OH_AVMuxer_AddTrack(c->muxer, &c->vOut, vf);
    OH_AVFormat_Destroy(vf);
    if (r != AV_ERR_OK) { fail(c, "muxer add video track " + std::to_string(r)); return; }
    if (c->audioTrackFmt) {
        if (OH_AVMuxer_AddTrack(c->muxer, &c->aOut, c->audioTrackFmt) != AV_ERR_OK) {
            LOGE("[RoundVideo] audio track rejected, sending silent video");
            c->aOut = -1;
        }
    }
    if (OH_AVMuxer_Start(c->muxer) != AV_ERR_OK) { fail(c, "muxer start"); return; }
    c->muxerStarted = true;
    if (c->aOut >= 0) {
        for (AudioSample& s : c->audio) {
            OH_AVBuffer* b = OH_AVBuffer_Create((int32_t)s.data.size());
            if (!b) continue;
            memcpy(OH_AVBuffer_GetAddr(b), s.data.data(), s.data.size());
            OH_AVBuffer_SetBufferAttr(b, &s.attr);
            OH_AVMuxer_WriteSampleBuffer(c->muxer, (uint32_t)c->aOut, b);
            OH_AVBuffer_Destroy(b);
        }
        LOGI("[RoundVideo] muxer started, %{public}zu audio samples written", c->audio.size());
        c->audio.clear();
    } else {
        LOGI("[RoundVideo] muxer started (video only)");
    }
}

void encOnNewOutput(OH_AVCodec* codec, uint32_t idx, OH_AVBuffer* buf, void* ud) {
    Ctx* c = (Ctx*)ud;
    OH_AVCodecBufferAttr attr = { 0, 0, 0, 0 };
    OH_AVBuffer_GetBufferAttr(buf, &attr);
    if (attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA) {
        // 编码器给的是 Annex-B SPS/PPS；不能塞进 OH_MD_KEY_CODEC_CONFIG（复用器按 avcC 解析 →
        // 生成的 avcC 没有 PPS，对端 "non-existing PPS 0 referenced"）。按 OH 官方样例：
        // 带 CODEC_DATA 标志的 buffer 原样 WriteSampleBuffer，复用器据此生成 avcC。
        LOGI("[RoundVideo] codec data %{public}d B", attr.size);
        ensureMuxerStarted(c);
        if (c->muxerStarted && !c->failed) {
            std::lock_guard<std::mutex> lk(c->muxMtx);
            OH_AVMuxer_WriteSampleBuffer(c->muxer, (uint32_t)c->vOut, buf);
        }
    } else {
        ensureMuxerStarted(c);
        if (attr.size > 0 && c->muxerStarted && !c->failed) {
            std::lock_guard<std::mutex> lk(c->muxMtx);
            OH_AVMuxer_WriteSampleBuffer(c->muxer, (uint32_t)c->vOut, buf);
            c->frames++;
            if (c->frames == 1) LOGI("[RoundVideo] first video sample %{public}d B flags=%{public}u", attr.size, attr.flags);
            if (attr.pts > c->lastPts) c->lastPts = attr.pts;
        }
    }
    bool eos = (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0;
    OH_VideoEncoder_FreeOutputBuffer(codec, idx);
    if (eos) finish(c);
}

// ---------- 主流程（napi 工作线程） ----------
void run(Ctx* c) {
    struct stat st;
    c->inFd = open(c->inPath.c_str(), O_RDONLY);
    if (c->inFd < 0 || fstat(c->inFd, &st) != 0 || st.st_size <= 0) { fail(c, "open input"); return; }
    c->source = OH_AVSource_CreateWithFD(c->inFd, 0, st.st_size);
    if (!c->source) { fail(c, "create source"); return; }
    c->demuxer = OH_AVDemuxer_CreateWithSource(c->source);
    if (!c->demuxer) { fail(c, "create demuxer"); return; }
    OH_AVFormat* sf = OH_AVSource_GetSourceFormat(c->source);
    int trackCount = getInt(sf, OH_MD_KEY_TRACK_COUNT, 0);
    if (sf) OH_AVFormat_Destroy(sf);
    OH_AVFormat* videoFmt = nullptr;
    for (int i = 0; i < trackCount; i++) {
        OH_AVFormat* tf = OH_AVSource_GetTrackFormat(c->source, (uint32_t)i);
        if (!tf) continue;
        int type = getInt(tf, OH_MD_KEY_TRACK_TYPE, -1);
        if (type == MEDIA_TYPE_VID && c->vTrack < 0) {
            c->vTrack = i; videoFmt = tf;
            c->srcW = getInt(tf, OH_MD_KEY_WIDTH, 0);
            c->srcH = getInt(tf, OH_MD_KEY_HEIGHT, 0);
            c->rotation = getInt(tf, OH_MD_KEY_ROTATION, -1);
            double fr = 0; if (OH_AVFormat_GetDoubleValue(tf, OH_MD_KEY_FRAME_RATE, &fr) && fr > 1) c->fps = fr;
        } else if (type == MEDIA_TYPE_AUD && c->aTrack < 0) {
            c->aTrack = i; c->audioTrackFmt = tf;
        } else {
            OH_AVFormat_Destroy(tf);
        }
    }
    if (c->vTrack < 0 || c->srcW <= 0 || c->srcH <= 0) { if (videoFmt) OH_AVFormat_Destroy(videoFmt); fail(c, "no video track"); return; }
    if (c->rotation < 0) c->rotation = c->fallbackRotation;
    c->rotation = ((c->rotation % 360) + 360) % 360;
    if (c->mode == 1) {
        const bool swap = (c->rotation == 90 || c->rotation == 270);
        const int dw = swap ? c->srcH : c->srcW, dh = swap ? c->srcW : c->srcH;
        const int longSide = dw > dh ? dw : dh;
        const double sc = longSide > c->side ? (double)c->side / longSide : 1.0;
        c->outW = ((int)(dw * sc)) & ~1;
        c->outH = ((int)(dh * sc)) & ~1;
        if (c->outW < 16) c->outW = 16;
        if (c->outH < 16) c->outH = 16;
        if (c->bitrate <= 0) c->bitrate = 2200000;
    } else {
        c->outW = c->outH = c->side;
        if (c->bitrate <= 0) c->bitrate = 1200000;
    }
    LOGI("[RoundVideo] mode=%{public}d src %{public}dx%{public}d rot=%{public}d fps=%{public}.1f tracks=%{public}d audio=%{public}d → %{public}dx%{public}d @%{public}d",
         c->mode, c->srcW, c->srcH, c->rotation, c->fps, trackCount, c->aTrack, c->outW, c->outH, c->bitrate);

    OH_AVDemuxer_SelectTrackByID(c->demuxer, (uint32_t)c->vTrack);
    // 音频先全部读出（AAC 直通，≤60 s 只有几百 KB），避免与视频回调线程并发读 demuxer
    if (c->aTrack >= 0) {
        OH_AVDemuxer_SelectTrackByID(c->demuxer, (uint32_t)c->aTrack);
        OH_AVBuffer* ab = OH_AVBuffer_Create(256 * 1024);
        while (ab) {
            if (OH_AVDemuxer_ReadSampleBuffer(c->demuxer, (uint32_t)c->aTrack, ab) != AV_ERR_OK) break;
            AudioSample s;
            OH_AVBuffer_GetBufferAttr(ab, &s.attr);
            if (s.attr.size <= 0 || (s.attr.flags & AVCODEC_BUFFER_FLAGS_EOS)) break;
            const uint8_t* p = OH_AVBuffer_GetAddr(ab);
            s.data.assign(p + s.attr.offset, p + s.attr.offset + s.attr.size);
            s.attr.offset = 0;
            c->audio.push_back(std::move(s));
        }
        if (ab) OH_AVBuffer_Destroy(ab);
        OH_AVDemuxer_UnselectTrackByID(c->demuxer, (uint32_t)c->aTrack);
        LOGI("[RoundVideo] audio samples: %{public}zu", c->audio.size());
    }

    // 输出复用器
    c->outFd = open(c->outPath.c_str(), O_CREAT | O_RDWR | O_TRUNC, 0644);
    if (c->outFd < 0) { OH_AVFormat_Destroy(videoFmt); fail(c, "open output"); return; }
    c->muxer = OH_AVMuxer_Create(c->outFd, AV_OUTPUT_FORMAT_MPEG_4);
    if (!c->muxer) { OH_AVFormat_Destroy(videoFmt); fail(c, "create muxer"); return; }
    OH_AVMuxer_SetRotation(c->muxer, 0);

    // 编码器（先起，作为帧消费者）
    c->enc = OH_VideoEncoder_CreateByMime(OH_AVCODEC_MIMETYPE_VIDEO_AVC);
    if (!c->enc) { OH_AVFormat_Destroy(videoFmt); fail(c, "create encoder"); return; }
    {
        OH_AVFormat* ef = OH_AVFormat_Create();
        OH_AVFormat_SetIntValue(ef, OH_MD_KEY_WIDTH, c->outW);
        OH_AVFormat_SetIntValue(ef, OH_MD_KEY_HEIGHT, c->outH);
        OH_AVFormat_SetIntValue(ef, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
        OH_AVFormat_SetDoubleValue(ef, OH_MD_KEY_FRAME_RATE, c->fps);
        OH_AVFormat_SetLongValue(ef, OH_MD_KEY_BITRATE, c->bitrate);
        OH_AVFormat_SetIntValue(ef, OH_MD_KEY_VIDEO_ENCODE_BITRATE_MODE, BITRATE_MODE_VBR);
        OH_AVFormat_SetIntValue(ef, OH_MD_KEY_I_FRAME_INTERVAL, 1000);
        OH_AVCodecCallback ecb = { encOnError, encOnStreamChanged, encOnNeedInput, encOnNewOutput };
        OH_AVErrCode r1 = OH_VideoEncoder_RegisterCallback(c->enc, ecb, c);
        OH_AVErrCode r2 = OH_VideoEncoder_Configure(c->enc, ef);
        OH_AVFormat_Destroy(ef);
        if (r1 != AV_ERR_OK || r2 != AV_ERR_OK) { OH_AVFormat_Destroy(videoFmt); fail(c, "encoder configure " + std::to_string(r2)); return; }
        if (OH_VideoEncoder_Prepare(c->enc) != AV_ERR_OK || OH_VideoEncoder_Start(c->enc) != AV_ERR_OK) {
            OH_AVFormat_Destroy(videoFmt); fail(c, "encoder start"); return;
        }
    }
    // 解码器（新建 format：不带 ROTATION，避免解码器自己转一次）
    {
        const char* mime = nullptr;
        if (!OH_AVFormat_GetStringValue(videoFmt, OH_MD_KEY_CODEC_MIME, &mime) || !mime) mime = OH_AVCODEC_MIMETYPE_VIDEO_AVC;
        c->dec = OH_VideoDecoder_CreateByMime(mime);
        if (!c->dec) { OH_AVFormat_Destroy(videoFmt); fail(c, "create decoder"); return; }
        OH_AVFormat* df = OH_AVFormat_Create();
        OH_AVFormat_SetStringValue(df, OH_MD_KEY_CODEC_MIME, mime);
        OH_AVFormat_SetIntValue(df, OH_MD_KEY_WIDTH, c->srcW);
        OH_AVFormat_SetIntValue(df, OH_MD_KEY_HEIGHT, c->srcH);
        OH_AVFormat_SetIntValue(df, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
        uint8_t* cfg = nullptr; size_t cfgLen = 0;
        if (OH_AVFormat_GetBuffer(videoFmt, OH_MD_KEY_CODEC_CONFIG, &cfg, &cfgLen) && cfg && cfgLen > 0)
            OH_AVFormat_SetBuffer(df, OH_MD_KEY_CODEC_CONFIG, cfg, cfgLen);
        OH_AVCodecCallback dcb = { decOnError, decOnStreamChanged, decOnNeedInput, decOnNewOutput };
        OH_AVErrCode r1 = OH_VideoDecoder_RegisterCallback(c->dec, dcb, c);
        OH_AVErrCode r2 = OH_VideoDecoder_Configure(c->dec, df);
        OH_AVFormat_Destroy(df);
        OH_AVFormat_Destroy(videoFmt);
        if (r1 != AV_ERR_OK || r2 != AV_ERR_OK) { fail(c, "decoder configure " + std::to_string(r2)); return; }
        if (OH_VideoDecoder_Prepare(c->dec) != AV_ERR_OK || OH_VideoDecoder_Start(c->dec) != AV_ERR_OK) { fail(c, "decoder start"); return; }
    }
    // 等待完成（编码器 EOS 输出）
    {
        std::unique_lock<std::mutex> lk(c->dm);
        if (!c->dcv.wait_for(lk, std::chrono::seconds(120), [&] { return c->done; })) {
            lk.unlock();
            fail(c, "timeout");
        }
    }
}

void cleanup(Ctx* c) {
    // 先停编码器/解码器再关复用器；失败时也要把回调线程唤醒
    { std::lock_guard<std::mutex> lk(c->dm); if (!c->done) { c->failed = true; c->done = true; } }
    c->qcv.notify_all();
    if (c->dec) { OH_VideoDecoder_Stop(c->dec); OH_VideoDecoder_Destroy(c->dec); c->dec = nullptr; }
    if (c->enc) { OH_VideoEncoder_Stop(c->enc); OH_VideoEncoder_Destroy(c->enc); c->enc = nullptr; }
    if (c->muxer) {
        if (c->muxerStarted) OH_AVMuxer_Stop(c->muxer);
        OH_AVMuxer_Destroy(c->muxer); c->muxer = nullptr;
    }
    if (c->audioTrackFmt) { OH_AVFormat_Destroy(c->audioTrackFmt); c->audioTrackFmt = nullptr; }
    if (c->demuxer) { OH_AVDemuxer_Destroy(c->demuxer); c->demuxer = nullptr; }
    if (c->source) { OH_AVSource_Destroy(c->source); c->source = nullptr; }
    if (c->outFd >= 0) { close(c->outFd); c->outFd = -1; }
    if (c->inFd >= 0) { close(c->inFd); c->inFd = -1; }
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

void execute(napi_env, void* data) {
    Ctx* c = (Ctx*)data;
    run(c);
    bool okNow;
    { std::lock_guard<std::mutex> lk(c->dm); okNow = c->done && !c->failed; }
    cleanup(c);
    c->ok = okNow && c->frames > 0;
    if (c->ok) {
        LOGI("[RoundVideo] done: %{public}lld frames, %{public}lld ms → %{public}s",
             (long long)c->frames, (long long)(c->lastPts / 1000), c->outPath.c_str());
    } else {
        if (c->err.empty()) c->err = c->frames == 0 ? "no frames" : "unknown";
        unlink(c->outPath.c_str());
    }
}

void complete(napi_env env, napi_status, void* data) {
    Ctx* c = (Ctx*)data;
    napi_value obj, v;
    napi_create_object(env, &obj);
    napi_get_boolean(env, c->ok, &v); napi_set_named_property(env, obj, "ok", v);
    napi_create_double(env, c->ok ? c->outW : 0, &v); napi_set_named_property(env, obj, "width", v);
    napi_create_double(env, c->ok ? c->outH : 0, &v); napi_set_named_property(env, obj, "height", v);
    napi_create_double(env, (double)(c->lastPts / 1000), &v); napi_set_named_property(env, obj, "durationMs", v);
    napi_create_double(env, (double)c->frames, &v); napi_set_named_property(env, obj, "frames", v);
    napi_create_string_utf8(env, c->err.c_str(), NAPI_AUTO_LENGTH, &v); napi_set_named_property(env, obj, "error", v);
    napi_resolve_deferred(env, c->deferred, obj);
    napi_delete_async_work(env, c->work);
    delete c;
}

} // namespace

// squareVideo(inPath, outPath, side?, rotation?, mode?, bitrate?) → Promise<{ok, width, height, durationMs, frames, error}>
napi_value RoundVideoSquare(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value argv[6] = { nullptr, nullptr, nullptr, nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    Ctx* c = new Ctx();
    if (argc >= 2) { c->inPath = getString(env, argv[0]); c->outPath = getString(env, argv[1]); }
    int32_t n = 0;
    if (argc >= 3 && napi_get_value_int32(env, argv[2], &n) == napi_ok && n >= 64) c->side = n & ~1;
    if (argc >= 4 && napi_get_value_int32(env, argv[3], &n) == napi_ok) c->fallbackRotation = n;
    if (argc >= 5 && napi_get_value_int32(env, argv[4], &n) == napi_ok) c->mode = (n == 1) ? 1 : 0;
    if (argc >= 6 && napi_get_value_int32(env, argv[5], &n) == napi_ok && n > 0) c->bitrate = n;
    napi_value promise = nullptr;
    napi_create_promise(env, &c->deferred, &promise);
    napi_value name;
    napi_create_string_utf8(env, "roundVideoSquare", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, execute, complete, c, &c->work);
    napi_queue_async_work(env, c->work);
    return promise;
}
