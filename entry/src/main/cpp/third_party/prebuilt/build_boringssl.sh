#!/bin/bash
# Rebuilds arm64-v8a/lib/libcrypto.a, libssl.a and include/openssl from BoringSSL as vendored in Telegram-iOS.
# The tree ships pre-generated linux-aarch64 assembly, so the ARMv8 crypto extensions are used.
source "$(dirname "$0")/build_common.sh"

SRC="$(telegram_ios_src)/third-party/boringssl"
BDIR="$WORK_DIR/build/boringssl"

echo "==> boringssl"
run_logged boringssl cmake_configure "$SRC" "$BDIR"
run_logged boringssl "$NINJA" -C "$BDIR" crypto ssl
cp -f "$BDIR/libcrypto.a" "$BDIR/libssl.a" "$OUT_LIB/"
rm -rf "$OUT_INCLUDE/openssl"
cp -R "$SRC/src/include/openssl" "$OUT_INCLUDE/openssl"
verify_lib "$OUT_LIB/libcrypto.a" SHA256
verify_lib "$OUT_LIB/libssl.a" SSL_CTX_new
