#!/usr/bin/env bash
# Build a macOS .app with PyInstaller. Run this on a Mac.
set -euo pipefail
cd "$(dirname "$0")"

python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements-macos.txt pyinstaller

# Build a multi-resolution .icns from the PNG mascot.
rm -rf build/Clippr.iconset
mkdir -p build/Clippr.iconset
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" assets/clippr.png --out "build/Clippr.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" assets/clippr.png --out "build/Clippr.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/Clippr.iconset -o assets/clippr.icns

pyinstaller --noconfirm --clean --windowed \
  --name Clippr \
  --icon assets/clippr.icns \
  --add-data "assets:assets" \
  --add-data "ocr_windows.ps1:." \
  main.py

echo
echo "Built dist/Clippr.app"
echo "For distribution: codesign + notarytool are required."
