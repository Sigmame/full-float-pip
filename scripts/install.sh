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
DATA_DIR="$HOME/Library/Application Support/FloatVideo"   # saved lists, caches (kept across reinstalls)
APPS_DIR="$HOME/Applications"
APP="$APPS_DIR/VibeFloat.app"

echo ""
echo "VibeFloat — Installer"
echo "====================="
echo ""

# A running copy would keep using the old build, and replacing it under a live process is unsafe.
if pgrep -f "VibeFloat.app/Contents/MacOS/FloatVideo" >/dev/null 2>&1; then
    echo "VibeFloat is running. Quit it (⌘Q) first, then run this again."
    exit 1
fi

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

# ---- Step 2: install the app bundle, with the catalogue UI and the icon inside it ----
echo ""
echo "[2/3] Installing the app..."
mkdir -p "$APPS_DIR" "$DATA_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_OUTPUT" "$APP/Contents/MacOS/FloatVideo"
cp "$NATIVE_APP_DIR/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$NATIVE_APP_DIR/Support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/FloatVideo"

CATALOG_DIR="$APP/Contents/Resources/catalog"
mkdir -p "$CATALOG_DIR"
for f in catalog.html catalog.css catalog.js movie-service.js site-access.js dub-preference.js; do
    cp "$NATIVE_APP_DIR/Catalog/$f" "$CATALOG_DIR/$f"
done
cp -R "$NATIVE_APP_DIR/Catalog/icons" "$CATALOG_DIR/icons"

xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - --identifier "com.aspect.floatvideo" --timestamp=none "$APP" 2>/dev/null \
  || codesign --force --sign - "$APP/Contents/MacOS/FloatVideo"
touch "$APP"   # so Finder, Launchpad and the Dock pick up the icon
echo "Installed and signed: $APP"

# Earlier versions lived inside Application Support; that copy is now stale.
if [ -d "$DATA_DIR/VibeFloat.app" ]; then
    rm -rf "$DATA_DIR/VibeFloat.app"
    echo "Removed the old copy: $DATA_DIR/VibeFloat.app"
fi
[ -L "$DATA_DIR/FloatVideo" ] && rm -f "$DATA_DIR/FloatVideo"

# ---- Step 3: clean up what the old browser-extension setup left behind ----
echo ""
echo "[3/3] Checking for files from the old Chrome setup..."
OLD_FILES=(
    "$DATA_DIR/float_video_host.sh"
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
echo "  Installed in:  $APP"
echo "  Open it:       open -a VibeFloat      (or Launchpad / Spotlight / Finder → Applications)"
echo "  Then use the menu bar icon, the Dock icon, or the window: catalogue, search, favourites,"
echo "  watched / hidden lists, and 'Phát nổi' to open the floating player over any app."
echo ""
echo "  Your saved lists and caches stay in: $DATA_DIR"
echo "  Remote control from a terminal: scripts/vibe-sync.sh"
echo ""
