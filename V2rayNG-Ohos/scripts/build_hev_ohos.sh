#!/usr/bin/env bash
# Cross-compile hev-socks5-tunnel (the tun2socks data plane) for HarmonyOS.
#
# Pure C, so it does NOT need the OHOS Go fork: the HarmonyOS TLS wall only
# affects Go c-shared libraries. The NDK clang is enough.
#
# Source: the hev-socks5-tunnel git submodule of this repository (the same
# component the Android build uses for its "HEV TUN" mode).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARMONY_HOME="${HARMONY_HOME:-$HOME/harmonyos-sdk/command-line-tools}"
OHOS_NATIVE_HOME="${OHOS_NATIVE_HOME:-$HARMONY_HOME/sdk/default/openharmony/native}"
LLVM_BIN="$OHOS_NATIVE_HOME/llvm/bin"
SYSROOT="$OHOS_NATIVE_HOME/sysroot"

SRC_DIR="${HEV_SRC:-$(cd "$ROOT_DIR/.." && pwd)/hev-socks5-tunnel}"
OUT_DIR="$ROOT_DIR/entry/src/main/cpp/prebuilt/arm64-v8a"

CC_BIN="$LLVM_BIN/aarch64-unknown-linux-ohos-clang"
AR_BIN="$LLVM_BIN/llvm-ar"
STRIP_BIN="$LLVM_BIN/llvm-strip"
NM_BIN="$LLVM_BIN/llvm-nm"

if [ ! -d "$SRC_DIR/src" ]; then
  echo "[FAIL] hev-socks5-tunnel sources missing: $SRC_DIR"
  echo "       Run: git submodule update --init --recursive hev-socks5-tunnel"
  exit 2
fi
if [ ! -x "$CC_BIN" ]; then
  echo "[FAIL] OHOS clang not found: $CC_BIN (set OHOS_NATIVE_HOME)"
  exit 2
fi

# The upstream tree has nested submodules; make sure they are present.
if [ ! -d "$SRC_DIR/third-part/hev-task-system/src" ] || [ ! -d "$SRC_DIR/src/core/include" ]; then
  echo "[INFO] initializing nested submodules"
  git -C "$SRC_DIR" submodule update --init --recursive
fi

mkdir -p "$OUT_DIR"

TARGET_FLAGS="--target=aarch64-linux-ohos --sysroot=$SYSROOT"

cd "$SRC_DIR"
echo "[INFO] building hev-socks5-tunnel + bundled third-party libs (static)"
# -Wno-error overrides the Makefile's -Werror: cross-compiling the bundled
# third-party code produces warnings we do not own.
make static \
  CC="$CC_BIN" \
  AR="$AR_BIN" \
  STRIP="$STRIP_BIN" \
  CFLAGS="$TARGET_FLAGS -Wno-error" \
  LFLAGS="$TARGET_FLAGS"

# `make shared` would leave DT_NEEDED entries for libyaml/liblwip/
# libhev-task-system, none of which are packaged in the HAP and none of which
# would resolve by bare soname at dlopen time. Link everything statically so
# the shipped object is self-contained (only libc.so remains needed).
TP_A=(
  "$SRC_DIR/third-part/hev-task-system/bin/libhev-task-system.a"
  "$SRC_DIR/third-part/lwip/bin/liblwip.a"
  "$SRC_DIR/third-part/yaml/bin/libyaml.a"
)
for a in "${TP_A[@]}"; do
  if [ ! -f "$a" ]; then
    echo "[FAIL] missing static archive: $a"
    exit 1
  fi
done

echo "[INFO] linking a self-contained libhevsocks5tun.so"
"$CC_BIN" -shared -fPIC $TARGET_FLAGS -o "$OUT_DIR/libhevsocks5tun.so" \
  -Wl,--whole-archive "$SRC_DIR/bin/libhev-socks5-tunnel.a" -Wl,--no-whole-archive \
  -Wl,--start-group "${TP_A[@]}" -Wl,--end-group \
  -lpthread

echo "[OK] $OUT_DIR/libhevsocks5tun.so"
ls -l "$OUT_DIR/libhevsocks5tun.so"

echo "[INFO] verifying exported symbols"
"$NM_BIN" -D "$OUT_DIR/libhevsocks5tun.so" | grep 'hev_socks5_tunnel_main_from_str' || {
  echo "[FAIL] expected hev_socks5_tunnel_main_from_str"
  exit 1
}
"$NM_BIN" -D "$OUT_DIR/libhevsocks5tun.so" | grep 'hev_socks5_tunnel_quit' || {
  echo "[FAIL] expected hev_socks5_tunnel_quit"
  exit 1
}
"$NM_BIN" -D "$OUT_DIR/libhevsocks5tun.so" | grep 'hev_socks5_tunnel_stats' || {
  echo "[FAIL] expected hev_socks5_tunnel_stats"
  exit 1
}

echo "[INFO] verifying the object is self-contained (no bundled .so dependencies)"
READELF_BIN="$LLVM_BIN/llvm-readelf"
if [ -x "$READELF_BIN" ]; then
  NEEDED="$("$READELF_BIN" -d "$OUT_DIR/libhevsocks5tun.so" | grep NEEDED | grep -v 'libc\.so' || true)"
  if [ -n "$NEEDED" ]; then
    echo "[FAIL] unexpected dynamic dependency (would not resolve at dlopen time):"
    echo "$NEEDED"
    exit 1
  fi
  echo "  ok: only libc.so is needed"
fi
