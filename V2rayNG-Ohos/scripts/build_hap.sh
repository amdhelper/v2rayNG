#!/usr/bin/env bash
# Build the HAP. Debug by default.
#
# Verified environment (2026-09-30): Command Line Tools 6.1.1.280,
# hvigor 6.24.2, ohpm 6.1.2.268, HarmonyOS SDK 6.1.1 (API 24).
# All three SDK/Node variables MUST be exported or hvigorw cannot find node
# or the SDK.
#
# Usage: bash scripts/build_hap.sh [debug|release] [--with-native]
set -euo pipefail

MODE="debug"
WITH_NATIVE=0
for a in "$@"; do
  case "$a" in
    debug|release) MODE="$a" ;;
    --with-native) WITH_NATIVE=1 ;;
    *) echo "[FAIL] unknown argument: $a"; exit 2 ;;
  esac
done

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARMONY_HOME="${HARMONY_HOME:-$HOME/harmonyos-sdk/command-line-tools}"

export DEVECO_NODE_HOME="${DEVECO_NODE_HOME:-$HARMONY_HOME/tool/node}"
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$HARMONY_HOME/sdk}"
export OHOS_BASE_SDK_HOME="${OHOS_BASE_SDK_HOME:-$HARMONY_HOME/sdk}"
export PATH="$DEVECO_NODE_HOME/bin:$PATH"

if [ "$WITH_NATIVE" = "1" ]; then
  bash "$PROJECT_DIR/scripts/build_native_all.sh"
fi

bash "$PROJECT_DIR/scripts/sync_geo_assets.sh"

PRE="$PROJECT_DIR/entry/src/main/cpp/prebuilt/arm64-v8a"
if [ ! -f "$PRE/libv2rayohos.so" ]; then
  echo "[WARN] $PRE/libv2rayohos.so missing — the bridge will report"
  echo "       'libv2rayohos.so not loadable' at runtime."
  echo "       Build it with: bash scripts/build_native_all.sh"
fi

cd "$PROJECT_DIR"

if [ ! -d oh_modules ]; then
  echo "[INFO] first build: ohpm install"
  "$HARMONY_HOME/bin/ohpm" install --all
fi

echo "[INFO] building HAP (mode=$MODE)"
"$HARMONY_HOME/bin/hvigorw" assembleHap --mode module -p product=default -p buildMode="$MODE" --no-daemon

HAP="$PROJECT_DIR/entry/build/default/outputs/default/entry-default-unsigned.hap"
if [ -f "$HAP" ]; then
  echo "[OK] $HAP"
  ls -l "$HAP"
else
  echo "[FAIL] HAP not produced at $HAP"
  exit 1
fi
