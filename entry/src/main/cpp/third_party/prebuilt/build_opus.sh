#!/bin/bash
# Rebuilds arm64-v8a/lib/libopus.a and include/opus from the opus 1.5.1 tarball vendored in Telegram-iOS.
source "$(dirname "$0")/build_common.sh"

TARBALL="$(telegram_ios_src)/third-party/opus/opus-1.5.1.tar.gz"
SRC="$WORK_DIR/src/opus-1.5.1"
BDIR="$WORK_DIR/build/opus"
PREFIX="$WORK_DIR/install/opus"

echo "==> opus 1.5.1"
rm -rf "$SRC" "$PREFIX"
tar -xzf "$TARBALL" -C "$WORK_DIR/src"
run_logged opus cmake_configure "$SRC" "$BDIR" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DOPUS_BUILD_SHARED_LIBRARY=OFF \
  -DOPUS_PRESUME_NEON=ON \
  -DOPUS_BUILD_TESTING=OFF \
  -DOPUS_BUILD_PROGRAMS=OFF \
  -DOPUS_STACK_PROTECTOR=OFF
run_logged opus "$NINJA" -C "$BDIR" install
cp -f "$PREFIX/lib/libopus.a" "$OUT_LIB/"
rm -rf "$OUT_INCLUDE/opus"
cp -R "$PREFIX/include/opus" "$OUT_INCLUDE/opus"
verify_lib "$OUT_LIB/libopus.a" opus_encoder_create
