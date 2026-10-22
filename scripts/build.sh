#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright © 2017–2026 JamXi, JSG-LLC.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
swift scripts/check-localizations.swift
swift build -c release
APP_DIR="$PROJECT_DIR/outputs/EditDot.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp .build/release/EditDot "$APP_DIR/Contents/MacOS/EditDot"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp LICENSE "$APP_DIR/Contents/Resources/LICENSE"
cp NOTICE "$APP_DIR/Contents/Resources/NOTICE"
cp -R Resources/Vendor "$APP_DIR/Contents/Resources/"
RESOURCE_BUNDLE="$APP_DIR/Contents/Resources/EditDot_EditDot.bundle"
rm -rf "$RESOURCE_BUNDLE"
mkdir -p "$RESOURCE_BUNDLE"
cp .build/release/EditDot_EditDot.bundle/Info.plist "$RESOURCE_BUNDLE/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleLocalizations' "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleLocalizations array' "$APP_DIR/Contents/Info.plist"
for LANGUAGE_DIR in Sources/EditDot/Resources/*.lproj; do
    LANGUAGE_CODE="$(basename "$LANGUAGE_DIR" .lproj)"
    mkdir -p "$RESOURCE_BUNDLE/$LANGUAGE_CODE.lproj"
    cp "$LANGUAGE_DIR/Localizable.strings" "$RESOURCE_BUNDLE/$LANGUAGE_CODE.lproj/Localizable.strings"
    /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations: string $LANGUAGE_CODE" "$APP_DIR/Contents/Info.plist"
done
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"
