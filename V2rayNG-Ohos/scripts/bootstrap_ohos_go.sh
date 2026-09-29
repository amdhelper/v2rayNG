#!/usr/bin/env bash
# One-time: build the OpenHarmony-capable Go toolchain used for
# libv2rayohos.so. See docs/OHOS_PORT.md ("Go cgo TLS 墙") for why neither
# GOOS=android nor GOOS=linux works on HarmonyOS.
#
# Result: $OHOS_BUILD_ROOT/ohos-go-1.26.5/bin/go  (go1.26.5 + GOOS=openharmony)
# Kept OUTSIDE the repository on purpose: `hvigor clean` deletes <repo>/build.
set -euo pipefail

OHOS_BUILD_ROOT="${OHOS_BUILD_ROOT:-$HOME/ohos-build}"
GO_FORK_TAG="${GO_FORK_TAG:-v1.26.5-beta1}"
GO_FORK_REPO="${GO_FORK_REPO:-https://github.com/star4277/ohos-go.git}"
BOOTSTRAP_VERSION="${BOOTSTRAP_VERSION:-go1.24.6}"   # go1.26 src needs >= 1.24.6

mkdir -p "$OHOS_BUILD_ROOT"
cd "$OHOS_BUILD_ROOT"

if [ ! -x "$OHOS_BUILD_ROOT/$BOOTSTRAP_VERSION/bin/go" ]; then
  echo "[INFO] fetching bootstrap $BOOTSTRAP_VERSION"
  for url in \
      "https://golang.google.cn/dl/${BOOTSTRAP_VERSION}.linux-amd64.tar.gz" \
      "https://mirrors.aliyun.com/golang/${BOOTSTRAP_VERSION}.linux-amd64.tar.gz" \
      "https://dl.google.com/go/${BOOTSTRAP_VERSION}.linux-amd64.tar.gz" ; do
    if curl -fL --connect-timeout 20 --max-time 900 -o "${BOOTSTRAP_VERSION}.tar.gz" "$url"; then
      echo "[INFO] got $url"
      break
    fi
  done
  [ -s "${BOOTSTRAP_VERSION}.tar.gz" ] || { echo "[FAIL] bootstrap download failed"; exit 2; }
  rm -rf "$BOOTSTRAP_VERSION" go
  tar xzf "${BOOTSTRAP_VERSION}.tar.gz"
  mv go "$BOOTSTRAP_VERSION"
fi

FORK_DIR="$OHOS_BUILD_ROOT/ohos-go-1.26.5"
if [ ! -d "$FORK_DIR/src" ]; then
  echo "[INFO] cloning $GO_FORK_REPO ($GO_FORK_TAG)"
  rm -rf "$FORK_DIR"
  git clone --depth 1 --branch "$GO_FORK_TAG" "$GO_FORK_REPO" "$FORK_DIR"
fi

echo "[INFO] bootstrapping the OHOS Go toolchain (this takes several minutes)"
cd "$FORK_DIR/src"
GOROOT_BOOTSTRAP="$OHOS_BUILD_ROOT/$BOOTSTRAP_VERSION" GOTOOLCHAIN=local GOFLAGS= bash ./make.bash

cd "$FORK_DIR"
./bin/go version
./bin/go tool dist list | grep -i openharmony
echo "[OK] OHOS Go toolchain ready at $FORK_DIR"
