#!/bin/bash
# Builds LanKvm.app — the standalone macOS menu bar app.
#
# Reuses the input helper from the DSH plugin (mac-helper.swift) so the
# Accessibility permission and the edge/clipboard behaviour stay identical.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# Keep development copies out of Spotlight's application results.
BUILD="$HERE/build/products.noindex"
APP="$BUILD/LanKvm.app"
TARGET="$(uname -m)-apple-macos13.0"

echo "==> Cleaning"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling the input and clipboard helper"
# Swift requires the file containing top-level code to be named main.swift in a multi-file build.
HELPER_SRC="$(mktemp -d)"
trap 'rm -rf "$HELPER_SRC"' EXIT
cp "$ROOT/../mac-helper.swift" "$HELPER_SRC/main.swift"
xcrun swiftc -O -swift-version 5 -target "$TARGET" \
  -framework ApplicationServices -framework AppKit \
  -o "$APP/Contents/Resources/lankvm-helper" \
  -D LANKVM_STANDALONE "$HELPER_SRC/main.swift" \
  "$HERE/Sources/ClipboardWorker.swift" "$HERE/Sources/WindowsClient.swift" "$HERE/Sources/FileTransfer.swift"

echo "==> Compiling LanKvm.app"
xcrun swiftc -O -swift-version 5 -target "$TARGET" \
  -framework AppKit -framework Network \
  -o "$APP/Contents/MacOS/LanKvm" \
  "$HERE/Sources/main.swift" \
  "$HERE/Sources/DiagnosticLog.swift" "$HERE/Sources/AppController.swift" \
  "$HERE/Sources/WindowsClient.swift" \
  "$HERE/Sources/Discovery.swift" \
  "$HERE/Sources/Settings.swift"

echo "==> Packaging the application icon"
ICONSET="$HELPER_SRC/LanKvm.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$HERE/Resources/LanKvm.png" \
    --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  pixels=$((size * 2))
  sips -z "$pixels" "$pixels" "$HERE/Resources/LanKvm.png" \
    --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/LanKvm.icns"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>LanKvm</string>
  <key>CFBundleDisplayName</key><string>LanKvm 跨屏</string>
  <key>CFBundleIconFile</key><string>LanKvm.icns</string>
  <key>CFBundleIdentifier</key><string>local.lankvm</string>
  <key>CFBundleExecutable</key><string>LanKvm</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.3.3</string>
  <key>CFBundleVersion</key><string>10</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>LanKvm connects to your Windows PC on the local network.</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
# Sign with a stable identity when one exists.
#
# macOS records the Accessibility grant against the code signature. An ad-hoc
# signature is identified by its cdhash, which changes on every rebuild, so each
# rebuild would silently invalidate the user's grant while System Settings still
# showed the switch as on. A named identity keeps the designated requirement
# stable across rebuilds.
SIGN_IDENTITY="${LANKVM_SIGN_IDENTITY:-LanKvm Local Signing}"
sign_one() {
  # Sign the helper first: --deep is unreliable for executables under
  # Contents/Resources, and each binary needs the stable identity on its own.
  codesign --force --sign "$1" "$APP/Contents/Resources/lankvm-helper"
  codesign --force --sign "$1" "$APP/Contents/MacOS/LanKvm"
  codesign --force --sign "$1" "$APP"
}
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  echo "==> Signing with \"$SIGN_IDENTITY\""
  sign_one "$SIGN_IDENTITY"
else
  echo "==> Signing ad-hoc (Accessibility must be re-granted after each rebuild)"
  sign_one -
fi

echo "==> Verifying signature"
codesign --verify --strict "$APP" && echo "    signature OK"

echo
echo "Built: $APP"
echo "For everyday use, install in /Applications and open /Applications/LanKvm.app."
