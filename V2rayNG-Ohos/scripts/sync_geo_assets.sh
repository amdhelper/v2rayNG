#!/usr/bin/env bash
# Copy the geoip/geosite data files the Xray core needs into the HAP's
# rawfile directory. They are taken from AndroidLibXrayLite/assets, i.e. the
# exact same data the Android build ships, so routing behaves identically.
#
# The copies are gitignored (27 MB of binaries that already live in the
# AndroidLibXrayLite submodule); run this after every clean checkout.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${GEO_SRC:-$(cd "$ROOT_DIR/.." && pwd)/AndroidLibXrayLite/assets}"
DST="$ROOT_DIR/entry/src/main/resources/rawfile"

mkdir -p "$DST"

missing=0
for f in geoip.dat geosite.dat; do
  if [ ! -f "$SRC/$f" ]; then
    echo "[WARN] missing source: $SRC/$f"
    missing=1
    continue
  fi
  if [ -f "$DST/$f" ] && [ "$(stat -c%s "$DST/$f")" = "$(stat -c%s "$SRC/$f")" ]; then
    echo "[OK]   $f already up to date"
    continue
  fi
  cp -f "$SRC/$f" "$DST/$f"
  echo "[COPY] $f -> $DST/$f ($(stat -c%s "$DST/$f") bytes)"
done

if [ "$missing" = "1" ]; then
  echo "[WARN] geo data incomplete — routing rules that use geoip:/geosite: will match nothing."
  echo "       The AndroidLibXrayLite submodule ships them; run:"
  echo "         git submodule update --init AndroidLibXrayLite"
  echo "       or regenerate with AndroidLibXrayLite/gen_assets.sh"
fi
exit 0
