#!/bin/bash
# ============================================================================
# linux2windt - Uninstaller
# ============================================================================
# Removes the cron job and desktop shortcut. Does NOT delete logs or config.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DESKTOP_FILE="$HOME/Desktop/linux2windt.desktop"
CRON_TAG="# linux2windt"

echo "linux2windt - Uninstaller"
echo ""

# Remove cron job
echo "Removing cron job..."
(crontab -l 2>/dev/null | grep -v "$CRON_TAG") | crontab -
echo "  Done."

# Remove desktop shortcut
if [ -f "$DESKTOP_FILE" ]; then
    echo "Removing desktop shortcut..."
    rm -f "$DESKTOP_FILE"
    echo "  Done."
else
    echo "No desktop shortcut found."
fi

echo ""
echo "Uninstall complete."
echo "  - Config and logs have NOT been deleted."
echo "  - To fully remove, delete: $SCRIPT_DIR"
