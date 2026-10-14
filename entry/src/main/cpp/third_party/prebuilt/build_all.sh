#!/bin/bash
# Rebuilds every prebuilt library in this directory. See build_env.txt for the pinned sources and toolchain.
#
#   ./build_all.sh                          rebuild in place
#   OUT_DIR=/tmp/check ./build_all.sh       rebuild elsewhere, e.g. to compare with the committed copies
set -euo pipefail
cd "$(dirname "$0")"
./build_boringssl.sh
./build_opus.sh
./build_libyuv.sh
./build_libvpx.sh
