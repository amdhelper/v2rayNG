#!/usr/bin/env bash
# Host-side regression gate for the HarmonyOS port. No device, no HarmonyOS SDK
# needed — it bundles the port's pure-logic ArkTS sources, runs a corpus of real
# share links through them, and feeds every generated Xray config to the pinned
# xray-core.
#
# What this does NOT cover: the NAPI bridge, the VPN extension, anything that
# needs the platform. Those only ever get verified by building the HAP and by a
# real device.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LC="$ROOT_DIR/scripts/logic_check"
OHOS_GO_FORK="${OHOS_GO_FORK:-$HOME/ohos-build/ohos-go-1.26.5}"

NODE_BIN="$(command -v node || true)"
if [ -z "$NODE_BIN" ] && [ -x "$HOME/.hermes/tools/node-26.7.0-linux-x64/bin/node" ]; then
  NODE_BIN="$HOME/.hermes/tools/node-26.7.0-linux-x64/bin/node"
fi
if [ -z "$NODE_BIN" ]; then
  echo "[FAIL] node not found (needed to run the port's logic under a host runtime)"
  exit 2
fi

cd "$LC"

if [ ! -x node_modules/.bin/esbuild ]; then
  echo "[INFO] installing esbuild (first run)"
  npm install --no-audit --no-fund --silent
fi

echo "=== [0/4] geo data (routing rules need it; the checker refuses without it) ==="
bash "$ROOT_DIR/scripts/sync_geo_assets.sh"
export XRAY_LOCATION_ASSET="$ROOT_DIR/entry/src/main/resources/rawfile"

echo "=== [1/4] dead-setting audit (a toggle nothing reads is a toggle that lies) ==="
"$NODE_BIN" check_dead_settings.mjs

echo "=== [2/4] bundling the port's pure logic ==="
"$NODE_BIN" bundle.mjs

echo "=== [3/4] corpus assertions + config generation ==="
"$NODE_BIN" run.mjs

echo "=== [4/4] feeding the generated configs to the pinned xray-core ==="
# xray-core at this revision needs go >= 1.26, which the system Go is not; the
# OHOS fork's toolchain runs on the host too, so reuse it.
GO_BIN=""
if [ -x "$OHOS_GO_FORK/bin/go" ]; then
  GO_BIN="$OHOS_GO_FORK/bin/go"
elif command -v go >/dev/null 2>&1 && "$(command -v go)" version | grep -qE 'go1\.(2[6-9]|[3-9][0-9])'; then
  GO_BIN="$(command -v go)"
fi
if [ -z "$GO_BIN" ]; then
  echo "[FAIL] need go >= 1.26 to build the checker; run scripts/bootstrap_ohos_go.sh first"
  exit 2
fi

cd "$LC/xray_config_check"
"$GO_BIN" mod tidy >/dev/null 2>&1 || true
"$GO_BIN" build -o /tmp/xray_config_check .
/tmp/xray_config_check "$LC/out"

echo "[OK] logic gate passed"
