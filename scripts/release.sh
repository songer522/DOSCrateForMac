#!/bin/bash
# Builds, signs, notarizes and packages DOSCrate.
# Required env: DEVELOPER_ID, NOTARY_PROFILE, DOSCRATE_APPCAST_URL, DOSCRATE_SPARKLE_KEY, VERSION.
# Outputs in build/release/: DOSCrate-<VERSION>.dmg and dosbox-staging-0.83.0-source.tar.gz.
set -euo pipefail

missing=()
for v in DEVELOPER_ID NOTARY_PROFILE DOSCRATE_APPCAST_URL DOSCRATE_SPARKLE_KEY VERSION; do
    if [ -z "${!v:-}" ]; then missing+=("$v"); fi
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "error: missing required environment variables: ${missing[*]}" >&2
    exit 1
fi

if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "error: VERSION must be numeric dotted (e.g. 1.2.0), got '$VERSION'" >&2
    exit 1
fi

cd "$(dirname "$0")/.."
OUT="build/release"
ARCHIVE="$OUT/DOSCrate.xcarchive"
EXPORT="$OUT/export"
APP="$EXPORT/DOSCrate.app"
STAGING_APP="$APP/Contents/Resources/DOSBox Staging.app"
DMG="$OUT/DOSCrate-$VERSION.dmg"
TEAM_ID="$(printf '%s' "$DEVELOPER_ID" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')"
if [ -z "$TEAM_ID" ]; then
    echo "error: DEVELOPER_ID must end with the team id in parentheses, e.g. 'Developer ID Application: Name (TEAMID)'" >&2
    exit 1
fi

sign() { codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$@"; }

rm -rf "$OUT"
mkdir -p "$OUT"
echo "==> Source tarball"
curl -fL -o "$OUT/dosbox-staging-0.83.0-source.tar.gz" \
    https://github.com/dosbox-staging/dosbox-staging/archive/refs/tags/v0.83.0.tar.gz

scripts/fetch-staging.sh

echo "==> Archive (Release)"
xcodebuild archive -project DOSCrate.xcodeproj -scheme DOSCrate -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" \
    DOSCRATE_APPCAST_URL="$DOSCRATE_APPCAST_URL" DOSCRATE_SPARKLE_KEY="$DOSCRATE_SPARKLE_KEY"

echo "==> Export (developer-id)"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>teamID</key><string>$TEAM_ID</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$OUT/ExportOptions.plist"

echo "==> Re-sign inside-out"
LIB_DIR="$STAGING_APP/Contents/MacOS/lib"
if [ ! -d "$LIB_DIR" ]; then
    echo "error: $LIB_DIR not found" >&2
    exit 1
fi
signed=0
while IFS= read -r -d '' lib; do sign "$lib"; signed=$((signed + 1)); done \
    < <(find "$LIB_DIR" -name '*.dylib' -print0)
if [ "$signed" -eq 0 ]; then
    echo "error: no dylibs found under $LIB_DIR" >&2
    exit 1
fi
sign "$STAGING_APP/Contents/MacOS/dosbox"
sign "$STAGING_APP"

# Sparkle nested helpers, innermost first (per Sparkle's sandboxing/codesign docs).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "XPCServices/Installer.xpc" "XPCServices/Downloader.xpc" "Autoupdate" "Updater.app"; do
    if [ -e "$SPARKLE/$item" ]; then
        sign "$SPARKLE/$item"
    else
        echo "note: skipping missing Sparkle helper $item" >&2
    fi
done
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --entitlements App/DOSCrate.entitlements "$APP"

echo "==> Verify"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl -a -vv "$APP" || echo "note: spctl rejects until the DMG is notarized and stapled" >&2

echo "==> DMG"
hdiutil create -volname DOSCrate -srcfolder "$APP" -ov -format UDZO "$DMG"
sign "$DMG"

echo "==> Notarize"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"

echo "Done: $DMG"
