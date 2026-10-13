#include <cstdint>

extern "C" __attribute__((visibility("default"))) void *tg_video_sticker_create(const char *) {
    return nullptr;
}

extern "C" __attribute__((visibility("default"))) uint32_t tg_video_sticker_frame_count(void *) {
    return 0;
}

extern "C" __attribute__((visibility("default"))) double tg_video_sticker_frame_rate(void *) {
    return 0.0;
}

extern "C" __attribute__((visibility("default"))) int32_t tg_video_sticker_render_frame(
    void *, uint32_t, uint32_t, uint32_t, uint8_t *, uint64_t) {
    return 0;
}

extern "C" __attribute__((visibility("default"))) void tg_video_sticker_destroy(void *) {}
