#!/bin/bash
# ============================================================================
# linux2windt - Updater
# ============================================================================
# Pulls the latest version from GitHub while preserving your config and
# local state. Safe to run from inside the project directory — the script
# stays in memory after deleting itself.
#
# What it preserves:
#   - linux2windt.conf        (your settings and credentials)
#   - .schema_version         (migration state)
#   - All logs and state in LOG_DIR (usually outside this folder)
#
# Usage:
#   bash update.sh
# ============================================================================

set -e

REPO_URL="https://github.com/dapanda1/linux2windt.git"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
DIR_NAME="$(basename "$SCRIPT_DIR")"
TEMP_DIR=$(mktemp -d)
BACKUP_DIR=$(mktemp -d)
CONFIG_NAME="linux2windt.conf"

echo "==========================================="
echo "  linux2windt - Updater"
echo "==========================================="
echo ""

# ------------------------------------------------------------------
# Step 1: Show current version
# ------------------------------------------------------------------
CURRENT_VERSION=$(perl "$SCRIPT_DIR/linux2windt.pl" --version 2>/dev/null || echo "unknown")
echo "Current version: $CURRENT_VERSION"
echo ""

# ------------------------------------------------------------------
# Step 2: Back up local state
# ------------------------------------------------------------------
echo "[1/5] Backing up local state..."

BACKED_UP=0
if [ -f "$SCRIPT_DIR/$CONFIG_NAME" ]; then
    cp "$SCRIPT_DIR/$CONFIG_NAME" "$BACKUP_DIR/$CONFIG_NAME"
    echo "  Saved: $CONFIG_NAME"
    BACKED_UP=1
fi

if [ -f "$SCRIPT_DIR/.schema_version" ]; then
    cp "$SCRIPT_DIR/.schema_version" "$BACKUP_DIR/.schema_version"
    echo "  Saved: .schema_version"
fi

if [ "$BACKED_UP" -eq 0 ]; then
    echo "  WARNING: No config file found. A fresh config will be created."
fi

# ------------------------------------------------------------------
# Step 3: Clone latest version to temp directory
# ------------------------------------------------------------------
echo ""
echo "[2/5] Downloading latest version..."

git clone --quiet "$REPO_URL" "$TEMP_DIR/linux2windt" 2>&1
if [ $? -ne 0 ]; then
    echo "  ERROR: git clone failed. Your current install is unchanged."
    rm -rf "$TEMP_DIR" "$BACKUP_DIR"
    exit 1
fi

NEW_VERSION=$(perl "$TEMP_DIR/linux2windt/linux2windt.pl" --version 2>/dev/null || echo "unknown")
echo "  Latest version: $NEW_VERSION"

# ------------------------------------------------------------------
# Step 4: Replace files
# ------------------------------------------------------------------
echo ""
echo "[3/5] Replacing project files..."

# Remove old project files (but NOT the config or .schema_version — those
# are already backed up)
cd "$PARENT_DIR"
rm -rf "$SCRIPT_DIR"

# Move the new clone into place
mv "$TEMP_DIR/linux2windt" "$SCRIPT_DIR"

echo "  Files replaced."

# ------------------------------------------------------------------
# Step 5: Restore local state
# ------------------------------------------------------------------
echo ""
echo "[4/5] Restoring local state..."

if [ -f "$BACKUP_DIR/$CONFIG_NAME" ]; then
    cp "$BACKUP_DIR/$CONFIG_NAME" "$SCRIPT_DIR/$CONFIG_NAME"
    echo "  Restored: $CONFIG_NAME"
fi

if [ -f "$BACKUP_DIR/.schema_version" ]; then
    cp "$BACKUP_DIR/.schema_version" "$SCRIPT_DIR/.schema_version"
    echo "  Restored: .schema_version"
fi

# ------------------------------------------------------------------
# Step 6: Re-run installer
# ------------------------------------------------------------------
echo ""
echo "[5/5] Running installer..."
echo ""

cd "$SCRIPT_DIR"
bash install.sh

# ------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------
rm -rf "$TEMP_DIR" "$BACKUP_DIR"

echo ""
echo "==========================================="
echo "  Update complete: $CURRENT_VERSION -> $NEW_VERSION"
echo "==========================================="
echo ""
echo "  Config migrations (if any) will run automatically"
echo "  on the next transfer."
echo ""
