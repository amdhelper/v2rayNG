#!/usr/bin/env bash
# Build libv2rayohos.so — the HarmonyOS port of AndroidLibXrayLite.
#
# WHY this exact recipe (see docs/OHOS_PORT.md for the full write-up):
#   HarmonyOS NEXT is musl libc. A Go c-shared library is only dlopen-able and
#   only safe to call from foreign (ArkTS / VPN extension) threads when the Go
#   runtime stores its `g` pointer in a generic dynamic TLS slot (TLSDESC).
#   Standard Go cannot do that for arm64:
#     - GOOS=android -> bionic fixed TLS slot -> cgo from a foreign thread SIGSEGV
#     - GOOS=linux   -> initial-exec TLS      -> musl refuses to dlopen it
#   Only an OpenHarmony Go fork with `GOOS=openharmony` + arm64 TLSDESC works.
#
# The toolchain lives OUTSIDE this repository on purpose: `hvigor clean`
# deletes <repo>/build and used to wipe the whole toolchain.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OHOS_GO_FORK="${OHOS_GO_FORK:-$HOME/ohos-build/ohos-go-1.26.5}"
HARMONY_HOME="${HARMONY_HOME:-$HOME/harmonyos-sdk/command-line-tools}"
OHOS_NATIVE_HOME="${OHOS_NATIVE_HOME:-$HARMONY_HOME/sdk/default/openharmony/native}"

CC_BIN="$OHOS_NATIVE_HOME/llvm/bin/aarch64-unknown-linux-ohos-clang"
CXX_BIN="$OHOS_NATIVE_HOME/llvm/bin/aarch64-unknown-linux-ohos-clang++"
SYSROOT="$OHOS_NATIVE_HOME/sysroot"

SRC_DIR="$ROOT_DIR/native/libv2ray_ohos"
OUT_DIR="$ROOT_DIR/entry/src/main/cpp/prebuilt/arm64-v8a"
VERSION_SCRIPT="$ROOT_DIR/native/libv2ray_ohos/export.map"

GO="$OHOS_GO_FORK/bin/go"

if [ ! -x "$GO" ]; then
  echo "[FAIL] OHOS Go toolchain not found: $GO"
  echo "       Build it once with: bash scripts/bootstrap_ohos_go.sh"
  echo "       (needs a bootstrap Go >= 1.24.6; see docs/OHOS_PORT.md)"
  exit 2
fi
if [ ! -x "$CC_BIN" ]; then
  echo "[FAIL] OHOS clang not found: $CC_BIN"
  echo "       Set OHOS_NATIVE_HOME or DEVECO_SDK_HOME."
  exit 2
fi

mkdir -p "$OUT_DIR"

export GOTOOLCHAIN=local
export GOFLAGS=
export GOOS=openharmony
export GOARCH=arm64
export CGO_ENABLED=1
export CC="$CC_BIN"
export CXX="$CXX_BIN"
# -ftls-model=global-dynamic removes the remaining initial-exec TLS relocations;
# musl only dlopens libraries whose TLS requests are general-dynamic.
export CGO_CFLAGS="-ftls-model=global-dynamic -D__MUSL__=1"
export CGO_CXXFLAGS="$CGO_CFLAGS"
# NOTE: never add -tags netgo here — the openharmony net port needs cgo and
# netgo breaks it with `_C_getifaddrs undefined`.
export CGO_LDFLAGS="--target=aarch64-linux-ohos --sysroot=$SYSROOT -Wl,-z,noexecstack"

cd "$SRC_DIR"

echo "[INFO] go mod tidy (toolchain: $("$GO" version))"
"$GO" mod tidy

echo "[INFO] building libv2rayohos.so"
"$GO" build \
  -buildmode=c-shared \
  -trimpath \
  -ldflags "-s -w -buildid= -checklinkname=0 -extldflags=-Wl,--version-script=$VERSION_SCRIPT" \
  -o "$OUT_DIR/libv2rayohos.so" \
  .

echo "[OK] $OUT_DIR/libv2rayohos.so"
ls -l "$OUT_DIR/libv2rayohos.so"

echo "[INFO] verifying the TLSDESC / openharmony fingerprints"
# NOTE: never `strings ... | grep -m1 PATTERN && ok || fail` under `set -o pipefail`.
# grep -m1 exits at the first hit, strings then dies of SIGPIPE, and with pipefail the
# whole pipeline is reported as failed even though the pattern matched.
# Read the strings dump once and count without -m.
STRINGS_DUMP="$(mktemp)"
strings -a "$OUT_DIR/libv2rayohos.so" > "$STRINGS_DUMP" 2>/dev/null || true

GOOS_HITS=0
if [ -s "$STRINGS_DUMP" ]; then
  GOOS_HITS=$(grep -c 'GOOS=openharmony' "$STRINGS_DUMP" || true)
fi
if [ "${GOOS_HITS:-0}" -gt 0 ]; then
  echo "  ok: GOOS=openharmony present ($GOOS_HITS hits)"
else
  echo "  [FAIL] GOOS=openharmony missing — wrong toolchain? see docs/OHOS_PORT.md §2"
  rm -f "$STRINGS_DUMP"
  exit 1
fi
grep -o 'go1\.26\.[0-9]*' "$STRINGS_DUMP" | head -1 || true
grep -o 'xray-core@v[^ "]*' "$STRINGS_DUMP" | head -1 || true
rm -f "$STRINGS_DUMP"

NM="$OHOS_NATIVE_HOME/llvm/bin/llvm-nm"
READELF="$OHOS_NATIVE_HOME/llvm/bin/llvm-readelf"
if [ -x "$NM" ]; then
  echo "--- exported V2RayOhos* symbols ---"
  "$NM" -D "$OUT_DIR/libv2rayohos.so" | grep ' T V2RayOhos' || echo "  [WARN] no V2RayOhos exports found"
fi
if [ -x "$READELF" ]; then
  echo "--- TLS relocations ---"
  "$READELF" -l "$OUT_DIR/libv2rayohos.so" | grep -i TLS || echo "  [WARN] no PT_TLS segment"
  "$READELF" -r "$OUT_DIR/libv2rayohos.so" | grep -i -m3 TLSDESC || echo "  [WARN] no R_AARCH64_TLSDESC"
fi
