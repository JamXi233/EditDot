#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright © 2017–2026 JamXi, JSG-LLC.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
BUILD_MODE="${1:-native}"
if [ "$#" -gt 1 ] || { [ "$BUILD_MODE" != native ] && [ "$BUILD_MODE" != --universal ]; }; then
    printf 'Usage: bash scripts/build.sh [--universal]\n' >&2
    exit 1
fi
swift scripts/check-localizations.swift
package_app() {
    local INPUT_BINARY="$1" BINARY_DIR="$2" APP_DIR="$3"
    mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
    cp "$INPUT_BINARY" "$APP_DIR/Contents/MacOS/EditDot"
    /usr/bin/strip -S -x "$APP_DIR/Contents/MacOS/EditDot"
    cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
    cp LICENSE "$APP_DIR/Contents/Resources/LICENSE"
    cp NOTICE "$APP_DIR/Contents/Resources/NOTICE"
    cp -R Resources/Vendor "$APP_DIR/Contents/Resources/"
    local RESOURCE_BUNDLE="$APP_DIR/Contents/Resources/EditDot_EditDot.bundle"
    rm -rf "$RESOURCE_BUNDLE"
    mkdir -p "$RESOURCE_BUNDLE"
    cp "$BINARY_DIR/EditDot_EditDot.bundle/Info.plist" "$RESOURCE_BUNDLE/Info.plist"
    /usr/libexec/PlistBuddy -c 'Delete :CFBundleLocalizations' "$APP_DIR/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleLocalizations array' "$APP_DIR/Contents/Info.plist"
    for LANGUAGE_DIR in Sources/EditDot/Resources/*.lproj; do
        LANGUAGE_CODE="$(basename "$LANGUAGE_DIR" .lproj)"
        mkdir -p "$RESOURCE_BUNDLE/$LANGUAGE_CODE.lproj"
        cp "$LANGUAGE_DIR/Localizable.strings" "$RESOURCE_BUNDLE/$LANGUAGE_CODE.lproj/Localizable.strings"
        /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations: string $LANGUAGE_CODE" "$APP_DIR/Contents/Info.plist"
    done
    if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"; fi
    codesign --force --sign - "$APP_DIR"
    codesign --verify --deep --strict "$APP_DIR"
    printf 'Built: %s\n' "$APP_DIR"
}
if [ "$BUILD_MODE" = --universal ]; then
    for TARGET_ARCH in arm64 x86_64; do
        SCRATCH_DIR="$PROJECT_DIR/.build/universal/$TARGET_ARCH"
        swift build --scratch-path "$SCRATCH_DIR" -c release --triple "$TARGET_ARCH-apple-macosx12.0" -Xswiftc -Osize
        BINARY_DIR="$(swift build --scratch-path "$SCRATCH_DIR" -c release --triple "$TARGET_ARCH-apple-macosx12.0" --show-bin-path)"
        package_app "$BINARY_DIR/EditDot" "$BINARY_DIR" "$PROJECT_DIR/outputs/$TARGET_ARCH/EditDot.app"
    done
    BUILD_STAGE="$(mktemp -d "$PROJECT_DIR/outputs/.EditDot-universal.XXXXXX")"
    trap 'rm -rf "$BUILD_STAGE"' EXIT
    /usr/bin/lipo -create "$PROJECT_DIR/outputs/arm64/EditDot.app/Contents/MacOS/EditDot" "$PROJECT_DIR/outputs/x86_64/EditDot.app/Contents/MacOS/EditDot" -output "$BUILD_STAGE/EditDot"
    BINARY_DIR="$(swift build --scratch-path "$PROJECT_DIR/.build/universal/arm64" -c release --triple arm64-apple-macosx12.0 --show-bin-path)"
    package_app "$BUILD_STAGE/EditDot" "$BINARY_DIR" "$PROJECT_DIR/outputs/EditDot.app"
    /usr/bin/lipo "$PROJECT_DIR/outputs/EditDot.app/Contents/MacOS/EditDot" -verify_arch arm64 x86_64
else
    swift build -c release
    BINARY_DIR="$(swift build -c release --show-bin-path)"
    package_app "$BINARY_DIR/EditDot" "$BINARY_DIR" "$PROJECT_DIR/outputs/EditDot.app"
fi
