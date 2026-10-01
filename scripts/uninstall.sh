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

APP="$HOME/Applications/VibeFloat.app"
DATA_DIR="$HOME/Library/Application Support/FloatVideo"
KEEP="catalog-storage.json"

if pgrep -f "VibeFloat.app/Contents/MacOS/FloatVideo" >/dev/null 2>&1; then
    echo "VibeFloat is running. Quit it (⌘Q) first, then run this again."
    exit 1
fi

if [ -d "$APP" ]; then
    rm -rf "$APP"
    echo "Removed: $APP"
else
    echo "Not found: $APP (nothing to remove there)"
fi

if [ ! -d "$DATA_DIR" ]; then
    echo "No data folder: $DATA_DIR"
elif [ "$1" = "--purge" ]; then
    rm -rf "$DATA_DIR"
    echo "Removed: $DATA_DIR (including your saved lists)"
else
    # The app of earlier versions lived here too; take it, and everything else, but keep the saved lists.
    find "$DATA_DIR" -mindepth 1 -maxdepth 1 ! -name "$KEEP" -exec rm -rf {} +
    echo "Cleaned: $DATA_DIR"
    [ -f "$DATA_DIR/$KEEP" ] && echo "Kept your saved lists: $DATA_DIR/$KEEP   (run with --purge to delete them too)"
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
