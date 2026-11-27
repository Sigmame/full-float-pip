#!/bin/bash
# uninstall.sh — Float Video uninstall script

set -e

echo ""
echo "Float Video — Uninstaller"
echo "=========================="
echo ""

# Remove native app
INSTALL_DIR="$HOME/Library/Application Support/FloatVideo"
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    echo "Removed: $INSTALL_DIR"
else
    echo "Not found: $INSTALL_DIR (skipped)"
fi

# Remove Native Messaging Host manifests (Chrome and Brave)
for NATIVE_HOST in \
    "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.aspect.floatvideo.json" \
    "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.aspect.floatvideo.json"; do
    if [ -f "$NATIVE_HOST" ]; then
        rm "$NATIVE_HOST"
        echo "Removed: $NATIVE_HOST"
    else
        echo "Not found: $NATIVE_HOST (skipped)"
    fi
done

echo ""
echo "Uninstall complete!"
echo ""
echo "  Note: The extension must be removed manually at chrome://extensions (Brave: brave://extensions)"
echo ""
