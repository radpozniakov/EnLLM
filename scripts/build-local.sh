#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-Debug}"
DERIVED_DATA_DIR="$ROOT_DIR/.xcode-build"
STAGING_DIR="$DERIVED_DATA_DIR/StableBuild/$CONFIGURATION"
OUTPUT_DIR="$ROOT_DIR/.local-app"
APP_PATH="$OUTPUT_DIR/EnLLM.app"
STAGED_APP_PATH="$STAGING_DIR/EnLLM.app"

case "$CONFIGURATION" in
    Debug|Release) ;;
    *)
        echo "Usage: $0 [Debug|Release]" >&2
        exit 2
        ;;
esac

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR" "$OUTPUT_DIR"

xcodebuild \
    -project "$ROOT_DIR/EnLLM.xcodeproj" \
    -scheme EnLLM \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    CONFIGURATION_BUILD_DIR="$STAGING_DIR" \
    build

codesign --verify --deep --strict --verbose=2 "$STAGED_APP_PATH"
rm -rf "$APP_PATH"
mv "$STAGED_APP_PATH" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "Built and verified: $APP_PATH"
