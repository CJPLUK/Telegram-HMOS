#!/bin/bash
# Rebuilds arm64-v8a/lib/libyuv.a and include/libyuv* from libyuv as vendored in Telegram-iOS.
# Only the static `yuv` target is built; the NEON paths are compiled in on aarch64.
source "$(dirname "$0")/build_common.sh"

SRC="$(telegram_ios_src)/third-party/libyuv/third_party/libyuv"
BDIR="$WORK_DIR/build/libyuv"

echo "==> libyuv"
run_logged libyuv cmake_configure "$SRC" "$BDIR"
run_logged libyuv "$NINJA" -C "$BDIR" yuv
cp -f "$BDIR/libyuv.a" "$OUT_LIB/"
rm -rf "$OUT_INCLUDE/libyuv" "$OUT_INCLUDE/libyuv.h"
cp -R "$SRC/include/libyuv" "$OUT_INCLUDE/libyuv"
cp -f "$SRC/include/libyuv.h" "$OUT_INCLUDE/libyuv.h"
verify_lib "$OUT_LIB/libyuv.a" ARGBToI420
