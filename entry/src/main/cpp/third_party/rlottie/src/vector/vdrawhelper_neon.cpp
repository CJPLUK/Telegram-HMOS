// Upstream rlottie gates its ARM fast paths on __ARM_NEON__, which only the
// 32-bit ARM toolchains define. The OHOS aarch64 clang defines __ARM_NEON
// instead, so on arm64-v8a this whole file used to compile to nothing and the
// solid SourceOver blend plus the surface fill fell back to the scalar C loops.
#if defined(__ARM_NEON) || defined(__ARM_NEON__)

#include "vdrawhelper.h"

#if defined(__aarch64__)

#include <arm_neon.h>

// The 32-bit pixman assembly (pixman-arm-neon-asm.S) is only built for ARCH
// "arm", so aarch64 gets intrinsics that reproduce the same results as the C
// reference in vdrawhelper.cpp / vcompositionfunctions.cpp.

void memfill32(uint32_t *dest, uint32_t value, int length)
{
    if (length <= 0) return;

    const uint32x4_t v = vdupq_n_u32(value);
    int i = 0;
    for (; i + 16 <= length; i += 16) {
        vst1q_u32(dest + i, v);
        vst1q_u32(dest + i + 4, v);
        vst1q_u32(dest + i + 8, v);
        vst1q_u32(dest + i + 12, v);
    }
    for (; i + 4 <= length; i += 4) {
        vst1q_u32(dest + i, v);
    }
    for (; i < length; ++i) {
        dest[i] = value;
    }
}

void Vcomp_func_solid_SourceOver_neon(uint32_t *dest, int length,
                                      uint32_t color,
                                      uint32_t const_alpha)
{
    if (const_alpha != 255) color = BYTE_MUL(color, const_alpha);

    const uint32_t ialpha = static_cast<uint32_t>(255 - vAlpha(color));
    if (ialpha == 0) {
        // Fully opaque source: the destination contributes nothing.
        memfill32(dest, color, length);
        return;
    }

    const uint8x16_t vialpha = vdupq_n_u8(static_cast<uint8_t>(ialpha));
    const uint8x16_t vcolor = vreinterpretq_u8_u32(vdupq_n_u32(color));

    int i = 0;
    for (; i + 4 <= length; i += 4) {
        uint8_t *raw = reinterpret_cast<uint8_t *>(dest + i);
        const uint8x16_t d = vld1q_u8(raw);
        // BYTE_MUL truncates ((channel * a) >> 8); vshrn_n_u16 matches it.
        const uint8x8_t lo = vshrn_n_u16(
            vmull_u8(vget_low_u8(d), vget_low_u8(vialpha)), 8);
        const uint8x8_t hi = vshrn_n_u16(
            vmull_u8(vget_high_u8(d), vget_high_u8(vialpha)), 8);
        vst1q_u8(raw, vaddq_u8(vcolor, vcombine_u8(lo, hi)));
    }
    for (; i < length; ++i) {
        dest[i] = color + BYTE_MUL(dest[i], ialpha);
    }
}

#else

extern "C" void pixman_composite_src_n_8888_asm_neon(int32_t w, int32_t h,
                                                     uint32_t *dst,
                                                     int32_t   dst_stride,
                                                     uint32_t  src);

extern "C" void pixman_composite_over_n_8888_asm_neon(int32_t w, int32_t h,
                                                      uint32_t *dst,
                                                      int32_t   dst_stride,
                                                      uint32_t  src);

void memfill32(uint32_t *dest, uint32_t value, int length)
{
    pixman_composite_src_n_8888_asm_neon(length, 1, dest, length, value);
}

void Vcomp_func_solid_SourceOver_neon(uint32_t *dest, int length,
                                      uint32_t color,
                                     uint32_t const_alpha)
{
    if (const_alpha != 255) color = BYTE_MUL(color, const_alpha);

    pixman_composite_over_n_8888_asm_neon(length, 1, dest, length, color);
}

#endif
#endif
