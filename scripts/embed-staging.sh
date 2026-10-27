#!/bin/bash
# Xcode build phase: copies Vendor/DOSBox Staging.app into the app's Resources.
set -euo pipefail

SRC="${SRCROOT}/Vendor/DOSBox Staging.app"
if [ ! -d "$SRC" ]; then
    echo "error: run 'make vendor' first"
    exit 1
fi
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/DOSBox Staging.app"
rm -rf "$DEST"
ditto "$SRC" "$DEST"

# License files shown in the Licenses window: ours and Sparkle's, then DOSBox Staging's.
LICENSES_SRC="${SRCROOT}/Vendor/staging-licenses"
if [ ! -d "$LICENSES_SRC" ]; then
    echo "error: Vendor/staging-licenses missing; run 'make vendor' first"
    exit 1
fi
LICENSES_ROOT="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Licenses"
rm -rf "$LICENSES_ROOT"
mkdir -p "$LICENSES_ROOT/DOSBox-Staging"
ditto "${SRCROOT}/App/Resources/Licenses" "$LICENSES_ROOT"
ditto "$LICENSES_SRC" "$LICENSES_ROOT/DOSBox-Staging"
