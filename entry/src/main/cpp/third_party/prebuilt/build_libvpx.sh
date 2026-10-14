#!/bin/bash
# Rebuilds arm64-v8a/lib/libvpx.a and include/vpx from libvpx v1.13.0 (VP8 + VP9, NEON).
# libvpx uses its own configure script: target arm64-linux-gcc with the compilers pointed at the
# OHOS clang. The libwebm parser in ../libwebm comes from the same libvpx tree (third_party/libwebm).
source "$(dirname "$0")/build_common.sh"

SRC="$(libvpx_src)"
BDIR="$WORK_DIR/build/libvpx"
CLANG_TARGET="--target=aarch64-linux-ohos --sysroot=$OHOS_NDK/sysroot"

echo "==> libvpx"
rm -rf "$BDIR"
mkdir -p "$BDIR"
build() {
  cd "$BDIR"
  CC="$LLVM_BIN/clang $CLANG_TARGET" \
  CXX="$LLVM_BIN/clang++ $CLANG_TARGET" \
  LD="$LLVM_BIN/clang $CLANG_TARGET" \
  AR="$LLVM_BIN/llvm-ar" \
  NM="$LLVM_BIN/llvm-nm" \
  STRIP="$LLVM_BIN/llvm-strip" \
  "$SRC/configure" \
    --target=arm64-linux-gcc \
    --enable-static --disable-shared --enable-pic \
    --enable-vp8 --enable-vp9 \
    --enable-realtime-only \
    --disable-examples --disable-tools --disable-docs --disable-unit-tests \
    --disable-webm-io --disable-libyuv \
    --disable-install-docs --disable-install-bins --disable-install-srcs \
    --extra-cflags="-O3 -fvisibility=hidden"
  make -j"$JOBS" libvpx.a
}
run_logged libvpx build
cp -f "$BDIR/libvpx.a" "$OUT_LIB/"
rm -rf "$OUT_INCLUDE/vpx"
cp -R "$SRC/vpx" "$OUT_INCLUDE/vpx"
verify_lib "$OUT_LIB/libvpx.a" vpx_codec_enc_init_ver
