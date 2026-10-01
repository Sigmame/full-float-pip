#!/bin/bash
# install.sh — builds VibeFloat and installs the app.
#
# VibeFloat is a standalone macOS app: the movie catalogue, the floating player and the menu bar
# item are all in it. No browser extension is needed.

set -e
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
NATIVE_APP_DIR="$PROJECT_DIR/native-app"
INSTALL_DIR="$HOME/Library/Application Support/FloatVideo"
APP="$INSTALL_DIR/VibeFloat.app"

echo ""
echo "VibeFloat — Installer"
echo "====================="
echo ""

# ---- Step 1: compile ----
echo "[1/3] Compiling the app..."
cd "$NATIVE_APP_DIR"
swift build -c release 2>&1 | tail -5
BUILD_OUTPUT="$NATIVE_APP_DIR/.build/release/FloatVideo"
if [ ! -f "$BUILD_OUTPUT" ]; then
    echo "Compilation failed! Check that the Xcode Command Line Tools are installed:"
    echo "   xcode-select --install"
    exit 1
fi
echo "Compilation successful"

# ---- Step 2: install the app bundle, with the catalogue UI inside it ----
echo ""
echo "[2/3] Installing the app..."
mkdir -p "$APP/Contents/MacOS"
cp "$BUILD_OUTPUT" "$APP/Contents/MacOS/FloatVideo"
cp "$NATIVE_APP_DIR/Support/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/FloatVideo"

CATALOG_DIR="$APP/Contents/Resources/catalog"
rm -rf "$CATALOG_DIR"
mkdir -p "$CATALOG_DIR"
for f in catalog.html catalog.css catalog.js movie-service.js site-access.js dub-preference.js; do
    cp "$NATIVE_APP_DIR/Catalog/$f" "$CATALOG_DIR/$f"
done
cp -R "$NATIVE_APP_DIR/Catalog/icons" "$CATALOG_DIR/icons"

# The launch path must be inside the .app so the speech-recognition permission can attach.
ln -sfn "VibeFloat.app/Contents/MacOS/FloatVideo" "$INSTALL_DIR/FloatVideo"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - --identifier "com.aspect.floatvideo" --timestamp=none "$APP" 2>/dev/null \
  || codesign --force --sign - "$APP/Contents/MacOS/FloatVideo"
echo "Installed and signed: $APP"

# ---- Step 3: clean up what the old browser-extension setup left behind ----
echo ""
echo "[3/3] Checking for files from the old Chrome setup..."
OLD_FILES=(
    "$INSTALL_DIR/float_video_host.sh"
    "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.aspect.floatvideo.json"
)
removed=0
for old in "${OLD_FILES[@]}"; do
    if [ -f "$old" ] && [ ! -L "$old" ]; then
        rm -f "$old"
        echo "  removed: $old"
        removed=$((removed + 1))
    fi
done
[ "$removed" -eq 0 ] && echo "  nothing to remove"
echo "  If the VibeFloat extension is still in Chrome, remove it at chrome://extensions."

echo ""
echo "================================="
echo "Installation complete!"
echo "================================="
echo ""
echo "  Open the app:   open \"$APP\""
echo "  Then use the menu bar icon, the Dock icon, or the window: catalogue, search, favourites,"
echo "  watched / hidden lists, and 'Phát nổi' to open the floating player over any app."
echo ""
echo "  If VibeFloat is already running, quit it (⌘Q) and open it again to use this build."
echo "  Remote control from a terminal: scripts/vibe-sync.sh"
echo ""
