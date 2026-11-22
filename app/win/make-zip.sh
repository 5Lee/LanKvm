#!/bin/bash
# Packages the Windows receiver for distribution.
#
# Produces a zip holding the prebuilt LanKvm.exe, so the target PC needs no
# compiler and no PowerShell. install.bat is included as a fallback for the
# case where the prebuilt binary will not start.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/build"
STAGE="$BUILD/LanKvm-win"
ZIP="$BUILD/LanKvm-win.zip"

if [ ! -f "$HERE/LanKvm.exe" ]; then
  echo "LanKvm.exe is missing. Build it on Windows first (see build-on-windows.bat)." >&2
  exit 1
fi

echo "==> Staging"
rm -rf "$STAGE" "$ZIP"
mkdir -p "$STAGE"
cp "$HERE/LanKvm.exe" "$STAGE/LanKvm.exe"
cp "$HERE/LanKvm.cs" "$STAGE/LanKvm.cs"
cp "$HERE/install.bat" "$STAGE/install.bat"
cp "$HERE/run-lankvm.bat" "$STAGE/run-lankvm.bat"
cp "$HERE/build-on-windows.bat" "$STAGE/build-on-windows.bat"
cp "$HERE/README.txt" "$STAGE/README.txt"
cp "$HERE/../../LICENSE" "$STAGE/LICENSE.txt"

echo "==> Compressing"
# Windows expects CRLF and a forward-slash-free root; zip stores plain names.
(cd "$STAGE" && zip -X -q -r "$ZIP" .)

rm -rf "$STAGE"

SIZE="$(du -h "$ZIP" | cut -f1)"
echo
echo "Built: $ZIP  ($SIZE)"
echo
echo "Contents:"
unzip -l "$ZIP" | sed -n '4,20p'
