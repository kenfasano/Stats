#!/bin/bash
set -e

# ─── Config ───────────────────────────────────────────────────────────────────
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_FILE="$PROJECT_DIR/Stats.xcodeproj"
SCHEME="Stats"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="Stats.app"
INSTALL_DIR="/Applications"
# ──────────────────────────────────────────────────────────────────────────────

run_xcodebuild() {
    local use_xcpretty=$1

    local xcodebuild_cmd=(
        xcodebuild
        -project "$PROJECT_FILE"
        -scheme "$SCHEME"
        -configuration Release
        -derivedDataPath "$BUILD_DIR"
        -arch arm64
        CODE_SIGN_IDENTITY=""
        CODE_SIGNING_REQUIRED=NO
        CODE_SIGNING_ALLOWED=NO
    )

    if [ "$use_xcpretty" -eq 1 ]; then
        "${xcodebuild_cmd[@]}" | xcpretty 2>/dev/null
        return ${PIPESTATUS[0]}
    else
        "${xcodebuild_cmd[@]}"
    fi
}

echo "▶ Building $SCHEME (Release)..."

if command -v xcpretty &>/dev/null; then
    run_xcodebuild 1
else
    echo "⚠️  xcpretty not found, using raw output..."
    run_xcodebuild 0
fi

# ─── Find the built .app ──────────────────────────────────────────────────────
BUILT_APP=$(find "$BUILD_DIR" -name "$APP_NAME" -type d | head -1)

if [ -z "$BUILT_APP" ]; then
    echo "❌ Build failed — $APP_NAME not found in $BUILD_DIR"
    exit 1
fi

echo "✅ Build succeeded: $BUILT_APP"

# ─── Install to /Applications ─────────────────────────────────────────────────
echo "▶ Installing to $INSTALL_DIR/$APP_NAME ..."

if [ -d "$INSTALL_DIR/$APP_NAME" ]; then
    rm -rf "$INSTALL_DIR/$APP_NAME"
fi

cp -R "$BUILT_APP" "$INSTALL_DIR/"

echo "✅ Installed: $INSTALL_DIR/$APP_NAME"
echo ""
echo "▶ Launching..."
open "$INSTALL_DIR/$APP_NAME"
