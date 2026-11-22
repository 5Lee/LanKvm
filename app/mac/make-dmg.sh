#!/bin/bash
# Builds LanKvm.dmg — a drag-to-install disk image for the Mac app.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/build"
APP="$BUILD/products.noindex/LanKvm.app"
DMG="$BUILD/LanKvm.dmg"

if [ ! -d "$APP" ]; then
  echo "LanKvm.app is missing. Run ./build.sh first." >&2
  exit 1
fi

echo "==> Staging"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/LanKvm.app"
cp "$HERE/../../LICENSE" "$STAGE/LICENSE.txt"
# The classic install gesture: drag the app onto the Applications shortcut.
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/README.txt" <<'TEXT'
LanKvm
======

Drag LanKvm.app onto the Applications folder to install.

First run:
  1. Open LanKvm from your Applications folder.
  2. The LanKvm status icon appears in the menu bar.
  3. macOS asks for Accessibility permission. Grant it in
     System Settings -> Privacy & Security -> Accessibility.
     Without it LanKvm cannot capture the keyboard and mouse.
  4. Open the menu bar icon -> Settings..., then enter the address and
     token shown in the LanKvm window on your Windows PC.

Controls:
  Move the mouse to the edge of the screen to enter Windows.
  Move it back to return.
  Control+Option+Command+K returns to the Mac at any time.
  The menu bar has "Return to Mac now" as well.
TEXT

echo "==> Creating the disk image"
hdiutil create \
  -volname "LanKvm" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  "$DMG" >/dev/null

echo "==> Signing the disk image"
codesign --force --sign - "$DMG" 2>/dev/null || true

SIZE="$(du -h "$DMG" | cut -f1)"
echo
echo "Built: $DMG  ($SIZE)"
