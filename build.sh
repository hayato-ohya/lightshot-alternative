#!/bin/zsh
# Builds Lightshot Alternative.app (Apple Silicon native).
#   ./build.sh            build to build/Lightshot Alternative.app
#   ./build.sh install    build and copy to /Applications (replaces existing)
#   ./build.sh run        build and launch
#   ./build.sh universal  build a universal (arm64 + x86_64) binary
#   ./build.sh dmg        build and package a drag-and-drop installer (build/Lightshot-Alternative-<version>.dmg)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Lightshot Alternative"
EXEC_NAME="LightshotAlt"
BUNDLE_ID="${BUNDLE_ID:-com.hayato.lightshot-alternative}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
CMD="${1:-build}"

# Quit a running instance and wait for it to exit, so the new one can take over the hot key.
stop_app() {
  pkill -x "$EXEC_NAME" 2>/dev/null || return 0
  for _ in {1..40}; do
    pgrep -x "$EXEC_NAME" >/dev/null || return 0
    sleep 0.1
  done
  pkill -9 -x "$EXEC_NAME" 2>/dev/null || true
  sleep 0.3
}

if [[ "$CMD" == "universal" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=".build/apple/Products/Release/$EXEC_NAME"
else
  swift build -c release
  BIN=$(find .build -type f -perm +111 -name "$EXEC_NAME" -not -path "*dSYM*" -not -path "*/apple/*" | head -1)
  [[ -f ".build/release/$EXEC_NAME" ]] && BIN=".build/release/$EXEC_NAME"
fi

mkdir -p "$BUILD_DIR"
if [[ ! -f "$BUILD_DIR/AppIcon.icns" || ! -f "$BUILD_DIR/menubar/MenuBarIcon.png" || scripts/generate-icon.swift -nt "$BUILD_DIR/AppIcon.icns" ]]; then
  echo "Generating icons…"
  rm -rf "$BUILD_DIR/AppIcon.iconset" "$BUILD_DIR/menubar"
  swift scripts/generate-icon.swift "$BUILD_DIR/AppIcon.iconset" "$BUILD_DIR/menubar"
  iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXEC_NAME"
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$BUILD_DIR"/menubar/MenuBarIcon*.png "$APP/Contents/Resources/"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
  Resources/Info.plist > "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

# Sign with the self-signed "Lightshot Alternative Dev" certificate when present (see scripts/make-signing-cert.sh).
# With a fixed certificate the Screen Recording permission survives rebuilds; ad-hoc signatures do not.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "Lightshot Alternative Dev"; then
    SIGN_IDENTITY="Lightshot Alternative Dev"
  else
    SIGN_IDENTITY="-"
    echo "note: ad-hoc signing; run scripts/make-signing-cert.sh once so Screen Recording permission persists across rebuilds"
  fi
fi
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
echo "Built: $APP ($(lipo -archs "$APP/Contents/MacOS/$EXEC_NAME"))"

case "$CMD" in
  install)
    stop_app
    rm -rf "/Applications/$APP_NAME.app"
    ditto "$APP" "/Applications/$APP_NAME.app"
    echo "Installed to /Applications/$APP_NAME.app"
    open "/Applications/$APP_NAME.app"
    ;;
  run)
    stop_app
    open "$APP"
    ;;
  dmg)
    DMG="$BUILD_DIR/Lightshot-Alternative-$VERSION.dmg"
    STAGING="$BUILD_DIR/dmg-staging"
    rm -rf "$STAGING" "$DMG"
    mkdir -p "$STAGING"
    ditto "$APP" "$STAGING/$APP_NAME.app"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
    rm -rf "$STAGING"
    echo "Created: $DMG  (open it and drag the app onto Applications)"
    ;;
esac
