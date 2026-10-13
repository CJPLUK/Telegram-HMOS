#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iterator>
#include <memory>
#include <vector>

#include "third_party/libwebm/mkvparser/mkvparser.h"
#include "vpx/vp8dx.h"
#include "vpx/vpx_decoder.h"

namespace {
class MemoryMkvReader final : public mkvparser::IMkvReader {
public:
    explicit MemoryMkvReader(const std::vector<uint8_t> &bytes) : bytes_(bytes) {}
    int Read(long long position, long length, unsigned char *buffer) override {
        if (position < 0 || length < 0 || buffer == nullptr ||
            position + length > static_cast<long long>(bytes_.size())) return -1;
        std::copy_n(bytes_.data() + position, length, buffer);
        return 0;
    }
    int Length(long long *total, long long *available) override {
        if (total == nullptr || available == nullptr) return -1;
        *total = static_cast<long long>(bytes_.size());
        *available = *total;
        return 0;
    }
private:
    const std::vector<uint8_t> &bytes_;
};

struct EncodedFrame {
    int64_t timeUs = 0;
    int64_t offset = 0;
    size_t length = 0;
};

struct AxisSample {
    uint16_t first = 0;
    uint16_t second = 0;
    uint16_t weight = 0;
};

std::vector<AxisSample> BuildAxis(uint32_t sourceSize, uint32_t targetSize) {
    std::vector<AxisSample> result(targetSize);
    if (sourceSize == 0 || targetSize == 0) return result;
    for (uint32_t index = 0; index < targetSize; ++index) {
        int64_t position =
            (static_cast<int64_t>(index * 2U + 1U) * sourceSize * 256) /
            (static_cast<int64_t>(targetSize) * 2) - 128;
        position = std::max<int64_t>(0, position);
        uint32_t first = std::min<uint32_t>(static_cast<uint32_t>(position >> 8), sourceSize - 1);
        uint32_t second = std::min<uint32_t>(first + 1, sourceSize - 1);
        result[index] = {
            static_cast<uint16_t>(first),
            static_cast<uint16_t>(second),
            static_cast<uint16_t>(position & 255)
        };
    }
    return result;
}

class TelegramVideoSticker {
public:
    // Own the mapped resource once. Frame entries are lightweight ranges into
    // this buffer; the old path copied every compressed VP9 packet before it
    // could decode frame zero.
    std::vector<uint8_t> fileBytes;
    std::vector<EncodedFrame> frames;
    double frameRate = 30.0;
    int64_t decodedIndex = -1;
    vpx_codec_ctx_t codec {};
    bool codecReady = false;
    uint32_t scaleSourceWidth = 0;
    uint32_t scaleSourceHeight = 0;
    uint32_t scaleTargetWidth = 0;
    uint32_t scaleTargetHeight = 0;
    std::vector<AxisSample> lumaX;
    std::vector<AxisSample> lumaY;
    std::vector<AxisSample> chromaX;
    std::vector<AxisSample> chromaY;
    ~TelegramVideoSticker() { ResetCodec(false); }
    bool ResetCodec(bool initialize = true) {
        if (codecReady) {
            vpx_codec_destroy(&codec);
            codecReady = false;
        }
        decodedIndex = -1;
        if (!initialize) return true;
        codec = {};
        vpx_codec_dec_cfg_t config {};
        config.threads = 2;
        codecReady = vpx_codec_dec_init(&codec, vpx_codec_vp9_dx(), &config, 0) == VPX_CODEC_OK;
        return codecReady;
    }

    void PrepareScalePlan(const vpx_image_t *image, uint32_t width, uint32_t height) {
        if (scaleSourceWidth == image->d_w && scaleSourceHeight == image->d_h &&
            scaleTargetWidth == width && scaleTargetHeight == height) return;
        scaleSourceWidth = image->d_w;
        scaleSourceHeight = image->d_h;
        scaleTargetWidth = width;
        scaleTargetHeight = height;
        const uint32_t chromaWidth =
            (image->d_w + ((1U << image->x_chroma_shift) - 1U)) >> image->x_chroma_shift;
        const uint32_t chromaHeight =
            (image->d_h + ((1U << image->y_chroma_shift) - 1U)) >> image->y_chroma_shift;
        lumaX = BuildAxis(image->d_w, width);
        lumaY = BuildAxis(image->d_h, height);
        chromaX = BuildAxis(chromaWidth, width);
        chromaY = BuildAxis(chromaHeight, height);
    }
};

uint8_t Clamp(int value) {
    return static_cast<uint8_t>(std::max(0, std::min(255, value)));
}

// Scale YUV directly into the requested backing surface. Bilinear sampling
// replaces the old nearest-neighbour 512 -> 160 pass that blurred edges.
void ConvertFrame(TelegramVideoSticker *video, const vpx_image_t *image,
                  uint32_t width, uint32_t height, uint8_t *output) {
    const bool fullRange = image->range == VPX_CR_FULL_RANGE;
    const bool hasAlpha = image->planes[VPX_PLANE_ALPHA] != nullptr;
    video->PrepareScalePlan(image, width, height);
    auto bilinear = [&](int plane, const AxisSample &x, const AxisSample &y) -> int {
        const uint8_t *pixels = image->planes[plane];
        const int stride = image->stride[plane];
        const int top = pixels[y.first * stride + x.first] * (256 - x.weight) +
            pixels[y.first * stride + x.second] * x.weight;
        const int bottom = pixels[y.second * stride + x.first] * (256 - x.weight) +
            pixels[y.second * stride + x.second] * x.weight;
        return (top * (256 - y.weight) + bottom * y.weight + 32768) >> 16;
    };
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            const int yy = bilinear(VPX_PLANE_Y, video->lumaX[x], video->lumaY[y]);
            const int u = bilinear(VPX_PLANE_U, video->chromaX[x], video->chromaY[y]);
            const int v = bilinear(VPX_PLANE_V, video->chromaX[x], video->chromaY[y]);
            int r = 0, g = 0, b = 0;
            if (fullRange) {
                const int d = u - 128, e = v - 128;
                r = yy + ((359 * e) >> 8);
                g = yy - ((88 * d + 183 * e) >> 8);
                b = yy + ((454 * d) >> 8);
            } else {
                const int c = std::max(0, yy - 16), d = u - 128, e = v - 128;
                r = (298 * c + 409 * e + 128) >> 8;
                g = (298 * c - 100 * d - 208 * e + 128) >> 8;
                b = (298 * c + 516 * d + 128) >> 8;
            }
            const size_t offset = (static_cast<size_t>(y) * width + x) * 4;
            output[offset] = Clamp(b);
            output[offset + 1] = Clamp(g);
            output[offset + 2] = Clamp(r);
            output[offset + 3] = hasAlpha
                ? Clamp(bilinear(VPX_PLANE_ALPHA, video->lumaX[x], video->lumaY[y]))
                : 255;
        }
    }
    // A WebM without an alpha plane is an opaque animation. Do not infer
    // transparency from dark edge-connected pixels: full-frame Telegram
    // animations frequently contain black outlines or dark backgrounds, and
    // chroma-keying those pixels permanently removes source detail. This is
    // the same contract used by iOS' FFMpeg frame source: decoded alpha is
    // honored when present; otherwise the frame remains opaque.
}

std::unique_ptr<TelegramVideoSticker> OpenWebm(const char *path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) return nullptr;
    auto result = std::make_unique<TelegramVideoSticker>();
    result->fileBytes.assign(std::istreambuf_iterator<char>(stream), {});
    if (result->fileBytes.empty()) return nullptr;
    MemoryMkvReader reader(result->fileBytes);
    mkvparser::EBMLHeader header;
    long long position = 0;
    if (header.Parse(&reader, position) < 0) return nullptr;
    mkvparser::Segment *rawSegment = nullptr;
    if (mkvparser::Segment::CreateInstance(&reader, position, rawSegment) != 0 || rawSegment == nullptr) return nullptr;
    std::unique_ptr<mkvparser::Segment> segment(rawSegment);
    if (segment->Load() < 0) return nullptr;
    long videoTrack = 0;
    const auto *tracks = segment->GetTracks();
    for (unsigned long i = 0; i < tracks->GetTracksCount(); ++i) {
        const auto *track = tracks->GetTrackByIndex(i);
        if (track != nullptr && track->GetType() == mkvparser::Track::kVideo) {
            videoTrack = track->GetNumber();
            break;
        }
    }
    if (videoTrack == 0) return nullptr;
    for (const mkvparser::Cluster *cluster = segment->GetFirst();
         cluster != nullptr && !cluster->EOS(); cluster = segment->GetNext(cluster)) {
        const mkvparser::BlockEntry *entry = nullptr;
        if (cluster->GetFirst(entry) != 0) continue;
        while (entry != nullptr && !entry->EOS()) {
            const mkvparser::Block *block = entry->GetBlock();
            if (block != nullptr && block->GetTrackNumber() == videoTrack) {
                for (int i = 0; i < block->GetFrameCount(); ++i) {
                    const auto &packet = block->GetFrame(i);
                    EncodedFrame frame;
                    frame.timeUs = block->GetTime(cluster) / 1000;
                    frame.offset = packet.pos;
                    frame.length = static_cast<size_t>(packet.len);
                    if (frame.offset >= 0 && frame.length > 0 &&
                        static_cast<uint64_t>(frame.offset) + frame.length <= result->fileBytes.size()) {
                        result->frames.push_back(frame);
                    }
                }
            }
            const mkvparser::BlockEntry *next = nullptr;
            if (cluster->GetNext(entry, next) != 0) break;
            entry = next;
        }
    }
    if (result->frames.empty()) return nullptr;
    if (result->frames.size() > 1) {
        std::vector<int64_t> deltas;
        for (size_t i = 1; i < result->frames.size(); ++i) {
            const int64_t delta = result->frames[i].timeUs - result->frames[i - 1].timeUs;
            if (delta > 0) deltas.push_back(delta);
        }
        if (!deltas.empty()) {
            std::sort(deltas.begin(), deltas.end());
            result->frameRate = std::min(30.0, 1000000.0 / deltas[deltas.size() / 2]);
        }
    }
    if (!result->ResetCodec()) return nullptr;
    return result;
}

bool RenderFrame(TelegramVideoSticker *video, uint32_t index, uint32_t width,
                 uint32_t height, uint8_t *output, uint64_t outputSize) {
    const uint64_t required = static_cast<uint64_t>(width) * height * 4U;
    if (video == nullptr || video->frames.empty() || output == nullptr ||
        width == 0 || height == 0 || outputSize < required) return false;
    index %= static_cast<uint32_t>(video->frames.size());
    if (static_cast<int64_t>(index) <= video->decodedIndex && !video->ResetCodec()) return false;
    for (int64_t i = video->decodedIndex + 1; i <= static_cast<int64_t>(index); ++i) {
        const auto &packet = video->frames[static_cast<size_t>(i)];
        const uint8_t *encoded = video->fileBytes.data() + packet.offset;
        if (vpx_codec_decode(&video->codec, encoded, packet.length, nullptr, 0) != VPX_CODEC_OK) return false;
        vpx_codec_iter_t iterator = nullptr;
        vpx_image_t *decoded = nullptr;
        while (vpx_image_t *candidate = vpx_codec_get_frame(&video->codec, &iterator)) decoded = candidate;
        video->decodedIndex = i;
        if (i == static_cast<int64_t>(index)) {
            if (decoded == nullptr) return false;
            ConvertFrame(video, decoded, width, height, output);
            return true;
        }
    }
    return false;
}
}  // namespace

extern "C" __attribute__((visibility("default"))) void *tg_video_sticker_create(const char *path) {
    auto video = OpenWebm(path);
    return video == nullptr ? nullptr : video.release();
}
extern "C" __attribute__((visibility("default"))) uint32_t tg_video_sticker_frame_count(void *handle) {
    auto *video = static_cast<TelegramVideoSticker *>(handle);
    return video == nullptr ? 0U : static_cast<uint32_t>(video->frames.size());
}
extern "C" __attribute__((visibility("default"))) double tg_video_sticker_frame_rate(void *handle) {
    auto *video = static_cast<TelegramVideoSticker *>(handle);
    return video == nullptr ? 0.0 : video->frameRate;
}
extern "C" __attribute__((visibility("default"))) int32_t tg_video_sticker_render_frame(
    void *handle, uint32_t frame, uint32_t width, uint32_t height,
    uint8_t *output, uint64_t outputSize) {
    return RenderFrame(static_cast<TelegramVideoSticker *>(handle), frame, width, height, output, outputSize) ? 1 : 0;
}
extern "C" __attribute__((visibility("default"))) void tg_video_sticker_destroy(void *handle) {
    delete static_cast<TelegramVideoSticker *>(handle);
}
