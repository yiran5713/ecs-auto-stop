#!/bin/bash
#
# Uninstallation script for SSH Monitor Agent
#

set -e

INSTALL_DIR="/opt/ssh-monitor"
LOG_FILE="/var/log/ssh-monitor.log"

echo "=== SSH Monitor Agent Uninstallation ==="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This script must be run as root (use sudo)"
    exit 1
fi

# Remove cron job
echo "[1/3] Removing cron job..."
if crontab -l 2>/dev/null | grep -q "$INSTALL_DIR/report.sh"; then
    crontab -l 2>/dev/null | grep -v "$INSTALL_DIR/report.sh" | grep -v "# SSH Monitor Agent" | crontab -
    echo "Cron job removed"
else
    echo "No cron job found"
fi

# Remove installation directory
echo "[2/3] Removing installation directory..."
if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    echo "Directory removed: $INSTALL_DIR"
else
    echo "Directory not found: $INSTALL_DIR"
fi

# Optionally remove log file
echo "[3/3] Keeping log file for reference: $LOG_FILE"
echo "(Remove manually if not needed: rm $LOG_FILE)"

echo ""
echo "=== Uninstallation Complete ==="
