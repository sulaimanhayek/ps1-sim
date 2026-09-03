#!/usr/bin/env bash
# Builds PS1Sim.app (universal) and a distributable DMG into ./dist.
#
#   scripts/build_app.sh [version]
#
# The result is ad-hoc signed. It is not notarized, so first launch needs
# right-click > Open, or the xattr command printed at the end.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-1.0.0}"
APP="dist/PS1Sim.app"
DMG="dist/PS1Sim-${VERSION}.dmg"

echo "==> Building universal binary (arm64 + x86_64)"
rm -rf dist
mkdir -p dist

# Built one architecture at a time: `swift build --arch a --arch b` needs full
# Xcode's xcbuild, while per-triple builds work with just the command line tools.
SLICES=()
for TRIPLE in arm64-apple-macosx13.0 x86_64-apple-macosx13.0; do
  echo "    - $TRIPLE"
  if swift build -c release --triple "$TRIPLE" >/dev/null 2>&1; then
    SLICE="$(swift build -c release --triple "$TRIPLE" --show-bin-path)/PS1Sim"
    [ -f "$SLICE" ] && SLICES+=("$SLICE")
  else
    echo "      (skipped: this toolchain cannot target $TRIPLE)"
  fi
done

if [ ${#SLICES[@]} -eq 0 ]; then
  echo "No architecture could be built." >&2
  exit 1
fi

BINARY="dist/PS1Sim.bin"
if [ ${#SLICES[@]} -gt 1 ]; then
  lipo -create -output "$BINARY" "${SLICES[@]}"
else
  echo "    warning: only one architecture built; the app will not be universal."
  cp "${SLICES[0]}" "$BINARY"
fi
lipo -archs "$BINARY" | sed 's/^/    architectures: /'

echo "==> Assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/PS1Sim"
chmod +x "$APP/Contents/MacOS/PS1Sim"
sed "s/__VERSION__/${VERSION}/g" packaging/Info.plist > "$APP/Contents/Info.plist"

echo "==> Rendering icon"
ICONSET="dist/AppIcon.iconset"
swift scripts/make_icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# An emulator core dropped in packaging/cores/ is bundled and adopted on first run.
if [ -d packaging/cores ] && compgen -G "packaging/cores/*.dylib" > /dev/null; then
  echo "==> Bundling cores from packaging/cores"
  mkdir -p "$APP/Contents/Resources/Cores"
  cp packaging/cores/*.dylib "$APP/Contents/Resources/Cores/"
  codesign --force --sign - "$APP/Contents/Resources/Cores/"*.dylib
fi

echo "==> Signing (ad-hoc)"
# Copied files can carry extended attributes, which codesign refuses to sign over.
xattr -cr "$APP"
rm -f "$BINARY"
codesign --force --deep --sign - \
  --entitlements packaging/PS1Sim.entitlements \
  --options runtime "$APP" 2>/dev/null || \
codesign --force --deep --sign - --entitlements packaging/PS1Sim.entitlements "$APP"

echo "==> Building $DMG"
STAGING="dist/dmg"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp README.md "$STAGING/README.md" 2>/dev/null || true
hdiutil create -volname "PS1Sim" -srcfolder "$STAGING" -ov -format ULFO "$DMG" >/dev/null
rm -rf "$STAGING"

echo
echo "Built:"
echo "  $APP"
echo "  $DMG"
echo
echo "The app is ad-hoc signed, not notarized. After downloading, clear quarantine with:"
echo "  xattr -dr com.apple.quarantine /Applications/PS1Sim.app"
