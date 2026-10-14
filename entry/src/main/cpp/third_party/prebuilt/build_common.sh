#!/bin/bash
# Shared setup for the build_*.sh scripts in this directory. Not meant to be run directly.
#
# The scripts rebuild the prebuilt arm64-v8a static libraries in ./arm64-v8a/lib and their headers
# in ./include from pinned upstream sources. Pinned versions and the toolchain they were built with
# are recorded in build_env.txt.
#
# Environment overrides:
#   OHOS_NDK           HarmonyOS native SDK   (default: DevEco Studio's sdk/default/openharmony/native)
#   TELEGRAM_IOS_SRC   existing Telegram-iOS checkout at TELEGRAM_IOS_COMMIT (default: sparse-fetched)
#   LIBVPX_SRC         existing libvpx checkout at LIBVPX_COMMIT              (default: fetched)
#   WORK_DIR           sources and build trees (default: $TMPDIR/telegram-hmos-prebuilt)
#   OUT_DIR            where lib/ and include/ are written (default: this directory)
set -euo pipefail

PREBUILT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- pinned sources (keep in sync with build_env.txt) -----------------------
# BoringSSL, opus 1.5.1 and libyuv are taken from Telegram for iOS's third-party/ tree, the same
# sources the iOS app and tgcalls build against.
TELEGRAM_IOS_REPO=https://github.com/TelegramMessenger/Telegram-iOS.git
TELEGRAM_IOS_COMMIT=6ad963e5b62d354da79040f388ae2b9132fb17b8
# libvpx v1.13.0, the commit Telegram-iOS pins as its third-party/libvpx/libvpx submodule.
LIBVPX_REPO=https://github.com/webmproject/libvpx.git
LIBVPX_COMMIT=e7bfd8b6c230a6824e7fd1efa2378a7322986128

# ---- OHOS NDK toolchain -------------------------------------------------------
OHOS_NDK="${OHOS_NDK:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native}"
OHOS_ARCH=arm64-v8a
CMAKE="$OHOS_NDK/build-tools/cmake/bin/cmake"
NINJA="$OHOS_NDK/build-tools/cmake/bin/ninja"
TOOLCHAIN="$OHOS_NDK/build/cmake/ohos.toolchain.cmake"
LLVM_BIN="$OHOS_NDK/llvm/bin"
for f in "$CMAKE" "$NINJA" "$TOOLCHAIN" "$LLVM_BIN/clang"; do
  [ -e "$f" ] || { echo "ERROR: missing $f (set OHOS_NDK)" >&2; exit 1; }
done

WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}/telegram-hmos-prebuilt}"
OUT_DIR="${OUT_DIR:-$PREBUILT_DIR}"
OUT_LIB="$OUT_DIR/$OHOS_ARCH/lib"
OUT_INCLUDE="$OUT_DIR/include"
mkdir -p "$WORK_DIR/src" "$OUT_LIB" "$OUT_INCLUDE"

if command -v sysctl >/dev/null 2>&1 && sysctl -n hw.ncpu >/dev/null 2>&1; then
  JOBS="$(sysctl -n hw.ncpu)"
else
  JOBS="$(nproc 2>/dev/null || echo 8)"
fi

# ---- sources -----------------------------------------------------------------
telegram_ios_src() {   # prints the Telegram-iOS source root, fetching it on first use
  if [ -n "${TELEGRAM_IOS_SRC:-}" ]; then
    echo "$TELEGRAM_IOS_SRC"
    return
  fi
  local dir="$WORK_DIR/src/telegram-ios"
  if [ ! -f "$dir/.fetched-$TELEGRAM_IOS_COMMIT" ]; then
    echo "==> fetching Telegram-iOS third-party sources at ${TELEGRAM_IOS_COMMIT:0:10}" >&2
    rm -rf "$dir"
    git init -q "$dir"
    git -C "$dir" remote add origin "$TELEGRAM_IOS_REPO"
    git -C "$dir" sparse-checkout set third-party/boringssl third-party/opus third-party/libyuv >&2
    git -C "$dir" fetch -q --depth 1 --filter=blob:none origin "$TELEGRAM_IOS_COMMIT" >&2
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD >&2
    touch "$dir/.fetched-$TELEGRAM_IOS_COMMIT"
  fi
  echo "$dir"
}

libvpx_src() {   # prints the libvpx source root, fetching it on first use
  if [ -n "${LIBVPX_SRC:-}" ]; then
    echo "$LIBVPX_SRC"
    return
  fi
  local dir="$WORK_DIR/src/libvpx"
  if [ ! -f "$dir/.fetched-$LIBVPX_COMMIT" ]; then
    echo "==> fetching libvpx at ${LIBVPX_COMMIT:0:10}" >&2
    rm -rf "$dir"
    git init -q "$dir"
    git -C "$dir" remote add origin "$LIBVPX_REPO"
    git -C "$dir" fetch -q --depth 1 origin "$LIBVPX_COMMIT" >&2
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD >&2
    touch "$dir/.fetched-$LIBVPX_COMMIT"
  fi
  echo "$dir"
}

# ---- helpers -----------------------------------------------------------------
# Strip local checkout paths from __FILE__ strings so the output does not depend on (or reveal)
# where the sources live, and rebuilding produces byte-identical archives. Each directory is mapped
# under every spelling the compiler may see (as given, physical, and without macOS's /private).
# (libvpx needs none of this, and must not get it: it records its configure flags in the library.)
path_variants() {
  local p="$1" phys
  phys="$(cd "$p" && pwd -P)"
  printf '%s\n' "$p" "$phys" "${p#/private}" "${phys#/private}" | sort -u
}

prefix_map_flags() {
  local flags="" v
  for v in $(path_variants "$WORK_DIR/src"); do flags="$flags -ffile-prefix-map=$v=."; done
  if [ -n "${TELEGRAM_IOS_SRC:-}" ]; then
    for v in $(path_variants "$TELEGRAM_IOS_SRC"); do flags="$flags -ffile-prefix-map=$v=./telegram-ios"; done
  fi
  echo "${flags# }"
}

cmake_configure() {   # $1=source dir  $2=build dir  rest=extra -D flags
  local src="$1" bdir="$2"
  shift 2
  "$CMAKE" -S "$src" -B "$bdir" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DOHOS_ARCH="$OHOS_ARCH" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_FLAGS="$(prefix_map_flags)" \
    -DCMAKE_CXX_FLAGS="$(prefix_map_flags)" \
    "$@"
}

run_logged() {   # $1=log name  rest=command; prints the log tail on failure
  local log="$WORK_DIR/logs/$1.log"
  shift
  mkdir -p "$WORK_DIR/logs"
  if ! "$@" >"$log" 2>&1; then
    echo "ERROR: build failed, see $log" >&2
    tail -30 "$log" >&2
    exit 1
  fi
}

verify_lib() {   # $1=archive  $2=symbol that must be defined in it
  # Count with grep -c rather than grep -q: under pipefail, grep -q exiting early kills the producer with SIGPIPE.
  local lib="$1" sym="$2" total aarch64 defined
  total="$("$LLVM_BIN/llvm-objdump" -a "$lib" 2>/dev/null | grep -c "file format" || true)"
  aarch64="$("$LLVM_BIN/llvm-objdump" -a "$lib" 2>/dev/null | grep -c "file format elf64-littleaarch64" || true)"
  [ "$total" -gt 0 ] && [ "$total" = "$aarch64" ] \
    || { echo "ERROR: $lib: only $aarch64/$total members are elf64-littleaarch64" >&2; exit 1; }
  defined="$("$LLVM_BIN/llvm-nm" "$lib" 2>/dev/null | grep -c " T $sym" || true)"
  [ "$defined" -gt 0 ] || { echo "ERROR: $lib does not define $sym" >&2; exit 1; }
  echo "OK: $lib ($total aarch64 objects, defines $sym)"
}
