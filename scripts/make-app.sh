#!/bin/bash
# Build "Ultima Ratio Regum.app" into dist/.
#
#   scripts/make-app.sh               app only; players download the game on first run
#   scripts/make-app.sh --with-game   also bundle the official game ZIP, unmodified
#
# The game's licence (its Readme.txt) allows redistributing the binary and all
# accompanying files, unmodified and free of charge, with the Readme included.
# --with-game bundles the official ZIP byte-for-byte (verified by sha256), so
# the Readme travels with it. Only distribute such a build free of charge.
#
# SIGN_IDENTITY="Developer ID Application: ..." signs for distribution;
# the default is an ad-hoc signature for local use.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

WITH_GAME=0
[ "${1:-}" = "--with-game" ] && WITH_GAME=1

GAME_URL=https://www.markrjohnsongames.com/wp-content/uploads/2026/01/URR0104d.zip
GAME_SHA256=c24e86b2d8b6b27a33f53a085d0378112aab6954871608b76ac04cbf95125934
GAME_ZIP=URR0104d.zip

APP="$ROOT/dist/Ultima Ratio Regum.app"
step() { printf '\n==> %s\n' "$*"; }

step "Building the launcher"
swift build --package-path launcher -c release
BIN=$(swift build --package-path launcher -c release --show-bin-path)

step "Building the developer blog page"
python3 news/build.py

step "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/runtime-context/game" "$APP/Contents/Resources/news"
cp "$BIN/URRLauncher" "$BIN/urrctl" "$APP/Contents/MacOS/"
cp -R runtime "$APP/Contents/Resources/runtime-context/runtime"
cp game/extract.py game/urr_container.py "$APP/Contents/Resources/runtime-context/game/"
cp news/dist/index.html "$APP/Contents/Resources/news/index.html"
find "$APP" -name .DS_Store -delete
VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo dev)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Ultima Ratio Regum</string>
  <key>CFBundleDisplayName</key><string>Ultima Ratio Regum</string>
  <key>CFBundleIdentifier</key><string>io.github.earchibald.urr-launcher</string>
  <key>CFBundleExecutable</key><string>URRLauncher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.10.4d</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.role-playing-games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

if [ "$WITH_GAME" = 1 ]; then
  step "Bundling the official $GAME_ZIP (unmodified)"
  CACHE="$ROOT/dist/cache"
  mkdir -p "$CACHE" "$APP/Contents/Resources/Game"
  if [ ! -f "$CACHE/$GAME_ZIP" ] || ! echo "$GAME_SHA256  $CACHE/$GAME_ZIP" | shasum -a 256 -c - >/dev/null 2>&1; then
    curl -fL --progress-bar -o "$CACHE/$GAME_ZIP" "$GAME_URL"
  fi
  echo "$GAME_SHA256  $CACHE/$GAME_ZIP" | shasum -a 256 -c -
  cp "$CACHE/$GAME_ZIP" "$APP/Contents/Resources/Game/$GAME_ZIP"
fi

step "Signing"
codesign --force --deep --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --deep --strict "$APP"
du -sh "$APP"
echo "Built $APP"
