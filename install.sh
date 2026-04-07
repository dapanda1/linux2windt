#!/bin/bash
# ============================================================================
# linux2windt - Installer
# ============================================================================
# Sets up:
#   1. File permissions (chmod 600 on config, 755 on scripts)
#   2. Cron job for scheduled daily runs
#   3. Desktop shortcut icon for manual runs
#   4. Dependency check (smbclient, curl, perl, ping)
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="linux2windt.pl"
CONFIG_NAME="linux2windt.conf"
DESKTOP_FILE="$HOME/Desktop/linux2windt.desktop"
CRON_TAG="# linux2windt"

echo "==========================================="
echo "  linux2windt v2.0.0 - Installer"
echo "==========================================="
echo ""
echo "Script directory: $SCRIPT_DIR"
echo ""

# ------------------------------------------------------------------
# Step 1: Check dependencies
# ------------------------------------------------------------------
echo "[1/7] Checking dependencies..."

MISSING=()
command -v perl       >/dev/null 2>&1 || MISSING+=("perl")
command -v smbclient  >/dev/null 2>&1 || MISSING+=("smbclient (samba-client)")
command -v curl       >/dev/null 2>&1 || MISSING+=("curl")
command -v ping       >/dev/null 2>&1 || MISSING+=("ping (iputils-ping)")

# Check for Perl JSON module
perl -MJSON::PP -e '1' 2>/dev/null || MISSING+=("perl JSON::PP (libjson-pp-perl)")

if [ ${#MISSING[@]} -gt 0 ]; then
    echo ""
    echo "  MISSING DEPENDENCIES:"
    for dep in "${MISSING[@]}"; do
        echo "    - $dep"
    done
    echo ""
    echo "  Install with:"
    echo "    sudo apt update && sudo apt install -y smbclient curl iputils-ping libjson-pp-perl"
    echo ""
    read -p "  Install now? (y/n): " INSTALL_NOW
    if [ "$INSTALL_NOW" = "y" ] || [ "$INSTALL_NOW" = "Y" ]; then
        sudo apt update && sudo apt install -y smbclient curl iputils-ping libjson-pp-perl perl
        echo "  Dependencies installed."
    else
        echo "  Skipping. Script may not work without these."
    fi
else
    echo "  All dependencies found."
fi

# ------------------------------------------------------------------
# Step 2: Create config from example if needed
# ------------------------------------------------------------------
echo ""
echo "[2/7] Checking configuration file..."

FRESH_CONFIG=0

if [ ! -f "$SCRIPT_DIR/$CONFIG_NAME" ]; then
    if [ -f "$SCRIPT_DIR/${CONFIG_NAME}.example" ]; then
        cp "$SCRIPT_DIR/${CONFIG_NAME}.example" "$SCRIPT_DIR/$CONFIG_NAME"
        FRESH_CONFIG=1
        echo "  Created $CONFIG_NAME from ${CONFIG_NAME}.example"
        echo "  >>> You MUST edit $CONFIG_NAME with your settings before first run. <<<"
    else
        echo "  ERROR: No ${CONFIG_NAME}.example found. Cannot continue."
        exit 1
    fi
else
    echo "  $CONFIG_NAME already exists (copied from a previous install?)."
    echo "  Any schema changes will be applied automatically on first run via migrate.pl."
fi

# ------------------------------------------------------------------
# Step 3: Set permissions
# ------------------------------------------------------------------
echo ""
echo "[3/7] Setting file permissions..."

chmod 755 "$SCRIPT_DIR/$SCRIPT_NAME"
chmod 755 "$SCRIPT_DIR/migrate.pl"
chmod 755 "$SCRIPT_DIR/update.sh"
chmod 600 "$SCRIPT_DIR/$CONFIG_NAME"
echo "  $SCRIPT_NAME -> 755 (executable)"
echo "  migrate.pl   -> 755 (executable)"
echo "  update.sh    -> 755 (executable)"
echo "  $CONFIG_NAME -> 600 (owner-only read/write)"

# ------------------------------------------------------------------
# Step 4: Create log directory
# ------------------------------------------------------------------
echo ""
echo "[4/7] Creating log directory..."

if [ "$FRESH_CONFIG" -eq 1 ]; then
    echo "  Skipped — config has placeholder values. Re-run install.sh after editing."
else
    # Read LOG_DIR from config
    LOG_DIR=$(grep '^LOG_DIR=' "$SCRIPT_DIR/$CONFIG_NAME" | cut -d'=' -f2)
    if [ -n "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR"
        echo "  Created: $LOG_DIR"
    else
        echo "  WARNING: LOG_DIR not found in config. Skipping."
    fi
fi

# ------------------------------------------------------------------
# Step 5: Seed processed.log with existing files
# ------------------------------------------------------------------
# On first install, mark every file already in SOURCE_DIR as processed
# so only new files added after this point get transferred.
echo ""
echo "[5/7] Checking processed.log..."

if [ "$FRESH_CONFIG" -eq 1 ]; then
    echo "  Skipped — config has placeholder values. Re-run install.sh after editing."
else
    SOURCE_DIR=$(grep '^SOURCE_DIR=' "$SCRIPT_DIR/$CONFIG_NAME" | cut -d'=' -f2)
    PROCESSED_LOG_NAME=$(grep '^PROCESSED_LOG=' "$SCRIPT_DIR/$CONFIG_NAME" | cut -d'=' -f2)
    PROCESSED_LOG_NAME="${PROCESSED_LOG_NAME:-processed.log}"
    PROCESSED_LOG_PATH="$LOG_DIR/$PROCESSED_LOG_NAME"

    if [ -n "$LOG_DIR" ] && [ -n "$SOURCE_DIR" ]; then
        if [ ! -s "$PROCESSED_LOG_PATH" ]; then
            if [ -d "$SOURCE_DIR" ]; then
                # Strip trailing slash for consistent sed pattern
                SOURCE_CLEAN="${SOURCE_DIR%/}"
                COUNT=$(find "$SOURCE_CLEAN" -type f ! -path "${LOG_DIR}*" | sed "s|^${SOURCE_CLEAN}/||" | tee "$PROCESSED_LOG_PATH" | wc -l)
                echo "  Seeded processed.log with $COUNT existing file(s)."
                echo "  These files will be skipped on future runs."
            else
                echo "  SOURCE_DIR ($SOURCE_DIR) not found. Skipping seed."
                echo "  (This is normal if the drive isn't mounted yet.)"
            fi
        else
            echo "  processed.log already has entries. Skipping seed."
        fi
    else
        echo "  WARNING: LOG_DIR or SOURCE_DIR not set. Skipping seed."
    fi
fi

# ------------------------------------------------------------------
# Step 6: Set up cron job
# ------------------------------------------------------------------
echo ""
echo "[6/7] Setting up cron job..."

# Read schedule from config
CRON_SCHEDULE=$(grep '^CRON_SCHEDULE=' "$SCRIPT_DIR/$CONFIG_NAME" | cut -d'=' -f2)
if [ -z "$CRON_SCHEDULE" ]; then
    CRON_SCHEDULE="0 2 * * *"
    echo "  No CRON_SCHEDULE in config. Defaulting to: $CRON_SCHEDULE"
fi

CRON_LINE="$CRON_SCHEDULE perl $SCRIPT_DIR/$SCRIPT_NAME >> $LOG_DIR/cron.log 2>&1 $CRON_TAG"

# Remove any existing linux2windt cron entries, then add the new one
(crontab -l 2>/dev/null | grep -v "$CRON_TAG" ; echo "$CRON_LINE") | crontab -
echo "  Cron job installed: $CRON_SCHEDULE"
echo "  Full line: $CRON_LINE"

# ------------------------------------------------------------------
# Step 7: Create desktop shortcut for manual runs
# ------------------------------------------------------------------
echo ""
echo "[7/7] Creating desktop shortcut..."

# Ensure Desktop directory exists
mkdir -p "$HOME/Desktop"

cat > "$DESKTOP_FILE" <<DESKTOP
[Desktop Entry]
Type=Application
Name=linux2windt
Comment=Manually run the media file transfer script
Exec=lxterminal -e "bash -c 'perl $SCRIPT_DIR/$SCRIPT_NAME; echo; echo Press Enter to close...; read'"
Icon=network-transmit
Terminal=false
Categories=Utility;
StartupNotify=true
DESKTOP

chmod +x "$DESKTOP_FILE"

# On newer Raspberry Pi OS, .desktop files on the Desktop need to be trusted
if command -v gio >/dev/null 2>&1; then
    gio set "$DESKTOP_FILE" metadata::trusted true 2>/dev/null || true
fi

echo "  Desktop shortcut created: $DESKTOP_FILE"
echo "  (Double-click to run a manual transfer)"

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
echo ""
echo "==========================================="
echo "  Installation Complete!"
echo "==========================================="
echo ""

if [ "$FRESH_CONFIG" -eq 1 ]; then
    echo "  NEXT STEPS:"
    echo ""
    echo "  1. Edit the config file:"
    echo "       nano $SCRIPT_DIR/$CONFIG_NAME"
    echo ""
    echo "     Fill in ALL placeholder values, including:"
    echo "       - SOURCE_DIR     (local folder to scan)"
    echo "       - SMB_SERVER_IP  (Windows server IP)"
    echo "       - SMB_SHARE      (SMB share name)"
    echo "       - SMB_USER       (Windows login username)"
    echo "       - SMB_PASS       (Windows login password)"
    echo "       - WOL_MAC        (server MAC address)"
    echo "       - LOG_DIR        (where to write logs)"
    echo ""
    echo "     Optional - Home Assistant notifications:"
    echo "       - HA_NOTIFY_ENABLED=1 to enable (disabled by default)"
    echo "       - HA_URL, HA_TOKEN, HA_NOTIFY_SERVICE"
    echo ""
    echo "  2. Re-run the installer to finish setup:"
    echo "       bash $SCRIPT_DIR/install.sh"
    echo ""
    echo "  3. Test with a dry run:"
    echo "       perl $SCRIPT_DIR/$SCRIPT_NAME --dry-run"
else
    echo "  To test manually:"
    echo "    perl $SCRIPT_DIR/$SCRIPT_NAME --dry-run"
    echo ""
    echo "  To run a real transfer now:"
    echo "    perl $SCRIPT_DIR/$SCRIPT_NAME"
    echo ""
    echo "  Or double-click the desktop icon."
fi

echo "==========================================="
