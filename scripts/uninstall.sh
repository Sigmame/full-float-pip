#!/bin/bash
# uninstall.sh — removes VibeFloat.
#
# Your favourites, watched / hidden lists and "Tiếp tục xem" live in
# ~/Library/Application Support/FloatVideo/catalog-storage.json. They are kept unless you pass --purge.

set -e

echo ""
echo "VibeFloat — Uninstaller"
echo "======================="
echo ""

INSTALL_DIR="$HOME/Library/Application Support/FloatVideo"
KEEP="catalog-storage.json"

if pgrep -f "$INSTALL_DIR/VibeFloat.app" >/dev/null 2>&1; then
    echo "VibeFloat is running. Quit it (⌘Q) first, then run this again."
    exit 1
fi

if [ ! -d "$INSTALL_DIR" ]; then
    echo "Not found: $INSTALL_DIR (nothing to remove)"
elif [ "$1" = "--purge" ]; then
    rm -rf "$INSTALL_DIR"
    echo "Removed: $INSTALL_DIR (including your saved lists)"
else
    find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 ! -name "$KEEP" -exec rm -rf {} +
    echo "Removed the app from: $INSTALL_DIR"
    [ -f "$INSTALL_DIR/$KEEP" ] && echo "Kept your saved lists: $INSTALL_DIR/$KEEP   (run with --purge to delete them too)"
fi

# Files from the old Chrome setup, if they are still around.
OLD_MANIFEST="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.aspect.floatvideo.json"
if [ -f "$OLD_MANIFEST" ]; then
    rm -f "$OLD_MANIFEST"
    echo "Removed: $OLD_MANIFEST"
fi

echo ""
echo "Uninstall complete."
echo "  If the VibeFloat extension is still in Chrome, remove it at chrome://extensions."
echo ""
