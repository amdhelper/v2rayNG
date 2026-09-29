#!/usr/bin/env bash
# Build every native artifact the HAP needs, then (optionally) the HAP itself.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== [1/3] libv2rayohos.so (Go c-shared, OpenHarmony toolchain) ==="
bash "$ROOT_DIR/scripts/build_libv2ray_ohos.sh"

echo "=== [2/3] libhevsocks5tun.so (C, OHOS NDK clang) ==="
bash "$ROOT_DIR/scripts/build_hev_ohos.sh"

echo "=== [3/3] artifacts ==="
ls -l "$ROOT_DIR/entry/src/main/cpp/prebuilt/arm64-v8a/"
