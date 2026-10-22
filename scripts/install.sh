#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright © 2017–2026 JamXi, JSG-LLC.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -eq 0 ]; then
    bash "$PROJECT_DIR/scripts/build.sh"
fi
SOURCE_APP="${1:-$PROJECT_DIR/outputs/EditDot.app}"
TARGET_APP="/Applications/EditDot.app"
if /usr/bin/pgrep -f '^/Applications/EditDot.app/Contents/MacOS/EditDot($| )' >/dev/null; then
    printf 'Save your documents and quit EditDot before installing.\n请保存文稿并退出 EditDot 后再安装。\n' >&2
    exit 1
fi
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")
[ "$BUNDLE_ID" = "com.jamxi.editdot" ] || { printf 'Unexpected app bundle.\n' >&2; exit 1; }
INSTALL_STAGE=$(/usr/bin/mktemp -d /Applications/.EditDot-install.XXXXXX)
INSTALL_DONE=false
cleanup() {
    if [ "$INSTALL_DONE" = false ] && [ -d "$INSTALL_STAGE/Previous.app" ]; then
        /bin/rm -rf "$TARGET_APP"
        /bin/mv "$INSTALL_STAGE/Previous.app" "$TARGET_APP"
    fi
    /bin/rm -rf "$INSTALL_STAGE"
}
trap cleanup EXIT
/usr/bin/ditto "$SOURCE_APP" "$INSTALL_STAGE/EditDot.app"
/usr/bin/codesign --verify --deep --strict "$INSTALL_STAGE/EditDot.app"
if [ -e "$TARGET_APP" ]; then /bin/mv "$TARGET_APP" "$INSTALL_STAGE/Previous.app"; fi
/bin/mv "$INSTALL_STAGE/EditDot.app" "$TARGET_APP"
/usr/bin/codesign --verify --deep --strict "$TARGET_APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET_APP"
INSTALL_DONE=true
printf 'Installed: %s\n' "$TARGET_APP"
