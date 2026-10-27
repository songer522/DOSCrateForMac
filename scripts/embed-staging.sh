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
