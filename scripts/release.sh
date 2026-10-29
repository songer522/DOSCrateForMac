#!/bin/bash
# Builds, signs, notarizes and packages DOSCrate.
# Required env: DEVELOPER_ID, NOTARY_PROFILE, DOSCRATE_APPCAST_URL, DOSCRATE_SPARKLE_KEY, VERSION.
# Outputs in build/release/, all attached to the GitHub release:
#   DOSCrate-<VERSION>.dmg
#   appcast.xml                                      (Sparkle EdDSA-signed appcast feed)
#   dosbox-staging-<STAGING_VERSION>-source.tar.gz   (GPL-2.0-or-later, checked against staging.lock)
#   glib-<version>.tar.xz, gettext-<version>.tar.gz  (LGPL-2.1-or-later libraries bundled with Staging, checked against staging.lock)
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
# STAGING_VERSION, STAGING_URL, STAGING_SHA256, STAGING_SOURCE_SHA256
source scripts/staging.lock

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
# For code that carries its own entitlements (Staging's allow-jit, Sparkle's Downloader.xpc).
sign_keeping_entitlements() { sign --preserve-metadata=entitlements "$@"; }

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Staging source tarball"
STAGING_SOURCE="$OUT/dosbox-staging-$STAGING_VERSION-source.tar.gz"
curl -fL -o "$STAGING_SOURCE" \
    "https://github.com/dosbox-staging/dosbox-staging/archive/refs/tags/v$STAGING_VERSION.tar.gz"
actual="$(shasum -a 256 "$STAGING_SOURCE" | awk '{print $1}')"
if [ -z "${STAGING_SOURCE_SHA256:-}" ]; then
    echo "error: scripts/staging.lock has no STAGING_SOURCE_SHA256." >&2
    echo "       The downloaded source hashes to $actual; check it, then add:" >&2
    echo "       STAGING_SOURCE_SHA256=$actual" >&2
    exit 1
fi
if [ "$actual" != "$STAGING_SOURCE_SHA256" ]; then
    echo "error: Staging source checksum mismatch: expected $STAGING_SOURCE_SHA256, got $actual" >&2
    exit 1
fi

scripts/fetch-staging.sh

echo "==> LGPL library sources"
# Staging bundles these in Contents/MacOS/lib. LGPL-2.1: glib (libglib, libgthread) and gettext (libintl);
# pcre2 and libslirp are BSD-licensed and only need their notices, which ship in the Licenses window.
VENDOR_LIB="Vendor/DOSBox Staging.app/Contents/MacOS/lib"
for lib in "$VENDOR_LIB"/*.dylib; do
    case "$(basename "$lib")" in
        libglib-2.0.*.dylib | libgthread-2.0.*.dylib | libintl.*.dylib | libpcre2-8.*.dylib | libslirp*.dylib) ;;
        *)
            echo "error: unknown bundled library $(basename "$lib"); work out its license obligations first" >&2
            exit 1
            ;;
    esac
done
# Versions come from the libraries' own exported version variables.
LIBVER="$OUT/libver"
xcrun clang -x c -o "$LIBVER" - <<'C'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
    void *h = dlopen(argv[1], RTLD_LAZY | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    for (int i = 2; i < argc; i++) {
        const unsigned int *v = dlsym(h, argv[i]);
        if (!v) { fprintf(stderr, "missing symbol %s\n", argv[i]); return 1; }
        printf("%u\n", *v);
    }
    return 0;
}
C
glib_parts="$("$LIBVER" "$VENDOR_LIB/libglib-2.0.0.dylib" glib_major_version glib_minor_version glib_micro_version | paste -sd. -)" || {
    echo "error: can't read the GLib version from $VENDOR_LIB/libglib-2.0.0.dylib" >&2
    exit 1
}
intl_raw="$("$LIBVER" "$VENDOR_LIB/libintl.8.dylib" libintl_version)" || {
    echo "error: can't read the gettext version from $VENDOR_LIB/libintl.8.dylib" >&2
    exit 1
}
# libintl_version is 0xMMmmss.
gettext_version="$(( (intl_raw >> 16) & 255 )).$(( (intl_raw >> 8) & 255 ))"
if [ $(( intl_raw & 255 )) -ne 0 ]; then gettext_version="$gettext_version.$(( intl_raw & 255 ))"; fi
if ! [[ "$glib_parts" =~ ^2\.[0-9]+\.[0-9]+$ ]] || ! [[ "$gettext_version" =~ ^0\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "error: unexpected library versions: glib '$glib_parts', gettext '$gettext_version'" >&2
    exit 1
fi
if [ "$glib_parts" != "${GLIB_VERSION:-}" ]; then
    echo "error: bundled GLib version ($glib_parts) does not match GLIB_VERSION (${GLIB_VERSION:-unset}) in scripts/staging.lock" >&2
    exit 1
fi
if [ "$gettext_version" != "${GETTEXT_VERSION:-}" ]; then
    echo "error: bundled gettext version ($gettext_version) does not match GETTEXT_VERSION (${GETTEXT_VERSION:-unset}) in scripts/staging.lock" >&2
    exit 1
fi
glib_series="${glib_parts%.*}"
echo "glib $glib_parts, gettext $gettext_version"
GLIB_TARBALL="$OUT/glib-$glib_parts.tar.xz"
GETTEXT_TARBALL="$OUT/gettext-$gettext_version.tar.gz"
# Upstream release tarballs (GNOME and GNU download servers).
curl -fL -o "$GLIB_TARBALL" "https://download.gnome.org/sources/glib/$glib_series/glib-$glib_parts.tar.xz"
curl -fL -o "$GETTEXT_TARBALL" "https://ftp.gnu.org/pub/gnu/gettext/gettext-$gettext_version.tar.gz"
glib_actual="$(shasum -a 256 "$GLIB_TARBALL" | awk '{print $1}')"
if [ -z "${GLIB_SOURCE_SHA256:-}" ] || [ "$glib_actual" != "$GLIB_SOURCE_SHA256" ]; then
    echo "error: GLib source checksum mismatch: expected ${GLIB_SOURCE_SHA256:-unset}, got $glib_actual" >&2
    exit 1
fi
gettext_actual="$(shasum -a 256 "$GETTEXT_TARBALL" | awk '{print $1}')"
if [ -z "${GETTEXT_SOURCE_SHA256:-}" ] || [ "$gettext_actual" != "$GETTEXT_SOURCE_SHA256" ]; then
    echo "error: gettext source checksum mismatch: expected ${GETTEXT_SOURCE_SHA256:-unset}, got $gettext_actual" >&2
    exit 1
fi
rm -f "$LIBVER"

echo "==> Generate project"
xcodegen generate

echo "==> Archive (Release)"
# Package.resolved is committed; use exactly the pinned Sparkle.
xcodebuild archive -project DOSCrate.xcodeproj -scheme DOSCrate -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -disableAutomaticPackageResolution \
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
# dosbox needs com.apple.security.cs.allow-jit for its dynamic core under the hardened runtime.
sign_keeping_entitlements "$STAGING_APP/Contents/MacOS/dosbox"
sign_keeping_entitlements "$STAGING_APP"
if ! codesign -d --entitlements - "$STAGING_APP/Contents/MacOS/dosbox" 2>&1 | grep -q com.apple.security.cs.allow-jit; then
    echo "error: dosbox lost its com.apple.security.cs.allow-jit entitlement" >&2
    exit 1
fi
for code in "$STAGING_APP/Contents/MacOS/dosbox" "$STAGING_APP"; do
    if ! codesign -dv "$code" 2>&1 | grep -Eq 'flags=0x[0-9a-f]+\([^)]*runtime'; then
        echo "error: $code is not signed with the hardened runtime" >&2
        exit 1
    fi
done

# Sparkle nested helpers, innermost first (per Sparkle's sandboxing/codesign docs).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "XPCServices/Installer.xpc" "XPCServices/Downloader.xpc" "Autoupdate" "Updater.app"; do
    if [ ! -e "$SPARKLE/$item" ]; then
        echo "note: skipping missing Sparkle helper $item" >&2
    elif [ "$item" = "XPCServices/Downloader.xpc" ]; then
        sign_keeping_entitlements "$SPARKLE/$item"
    else
        sign "$SPARKLE/$item"
    fi
done
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --entitlements App/DOSCrate.entitlements "$APP"

echo "==> Verify"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl -a -vv "$APP" || echo "note: spctl rejects until the DMG is notarized and stapled" >&2

echo "==> DMG"
DMG_ROOT="$OUT/dmg"
mkdir -p "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/DOSCrate.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname DOSCrate -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"
sign "$DMG"

echo "==> Notarize"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"

echo "==> Appcast (Sparkle EdDSA)"
DERIVED_DATA="$(xcodebuild -project DOSCrate.xcodeproj -scheme DOSCrate -showBuildSettings 2>/dev/null | awk -F' = ' '/^[[:space:]]*BUILD_DIR = / { sub(/\/Build\/Products$/, "", $2); print $2; exit }')"
GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast}"
if [ ! -x "$GENERATE_APPCAST" ]; then
    echo "error: Sparkle generate_appcast not found at $GENERATE_APPCAST" >&2
    exit 1
fi
APPCAST_DIR="$OUT/appcast"
mkdir -p "$APPCAST_DIR"
cp "$DMG" "$APPCAST_DIR/"
if [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
    "$GENERATE_APPCAST" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" -o "$OUT/appcast.xml" "$APPCAST_DIR"
else
    "$GENERATE_APPCAST" -o "$OUT/appcast.xml" "$APPCAST_DIR"
fi
rm -rf "$APPCAST_DIR"

echo "Done: $DMG"
echo "Appcast: $OUT/appcast.xml"
echo "Attach with it: $STAGING_SOURCE, $GLIB_TARBALL, $GETTEXT_TARBALL"
