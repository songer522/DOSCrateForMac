#!/bin/bash
# Fetches the pinned DOSBox Staging release into Vendor/ (git-ignored). Idempotent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/staging.lock"

APP="$ROOT/Vendor/DOSBox Staging.app"
BIN="$APP/Contents/MacOS/dosbox"

if [ -x "$BIN" ] && "$BIN" --version 2>/dev/null | grep -q "$STAGING_VERSION"; then
    echo "vendor: DOSBox Staging $STAGING_VERSION already present"
    exit 0
fi

WORK="$(mktemp -d)"
MOUNT="$WORK/mnt"
mkdir -p "$MOUNT"
cleanup() {
    hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "vendor: downloading DOSBox Staging $STAGING_VERSION"
curl -fL --progress-bar -o "$WORK/staging.dmg" "$STAGING_URL"

ACTUAL="$(shasum -a 256 "$WORK/staging.dmg" | awk '{print $1}')"
if [ "$ACTUAL" != "$STAGING_SHA256" ]; then
    echo "checksum mismatch"
    exit 1
fi

hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$WORK/staging.dmg" >/dev/null

SRC="$(find "$MOUNT" -maxdepth 1 -name '*.app' | head -n 1)"
if [ -z "$SRC" ]; then
    echo "error: no .app found in DMG"
    exit 1
fi

mkdir -p "$ROOT/Vendor"
rm -rf "$APP"
ditto "$SRC" "$APP"

# License/notice files: the DMG has none beside the app, so take them from inside the app.
LIC="$ROOT/Vendor/staging-licenses"
rm -rf "$LIC"
mkdir -p "$LIC"
cp "$APP/Contents/SharedSupport/LICENSE" "$LIC/"
ditto "$APP/Contents/doc/licenses" "$LIC/licenses"
# Also copy any license/notice files that do sit beside the app in the DMG.
find "$MOUNT" -maxdepth 1 -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) \
    -exec cp {} "$LIC/" \;

echo "vendor: installed $("$BIN" --version 2>/dev/null | head -n 1)"
