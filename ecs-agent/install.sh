#!/bin/bash
#
# Installation script for SSH Monitor Agent
# Run this script on the target ECS instance
#

set -e

INSTALL_DIR="/opt/ssh-monitor"
LOG_FILE="/var/log/ssh-monitor.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== SSH Monitor Agent Installation ==="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This script must be run as root (use sudo)"
    exit 1
fi

# Create installation directory
echo "[1/5] Creating installation directory..."
mkdir -p "$INSTALL_DIR"

# Copy scripts
echo "[2/5] Installing scripts..."
cp "$SCRIPT_DIR/report.sh" "$INSTALL_DIR/report.sh"
chmod +x "$INSTALL_DIR/report.sh"

# Check if config exists
if [[ ! -f "$INSTALL_DIR/config.env" ]]; then
    echo "[3/5] Creating config template..."
    cp "$SCRIPT_DIR/config.env.template" "$INSTALL_DIR/config.env"
    echo ""
    echo "!!! IMPORTANT !!!"
    echo "Please edit $INSTALL_DIR/config.env with your actual values:"
    echo "  - FC_ENDPOINT: Your Function Compute HTTP endpoint"
    echo "  - INSTANCE_ID: This ECS instance ID"
    echo "  - AUTH_TOKEN: Secret authentication token"
    echo ""
else
    echo "[3/5] Config file already exists, skipping..."
fi

# Create log file
echo "[4/5] Setting up log file..."
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

# Setup cron job
echo "[5/5] Setting up cron job..."
CRON_JOB="*/5 * * * * $INSTALL_DIR/report.sh >> $LOG_FILE 2>&1"
CRON_MARKER="# SSH Monitor Agent"

# Check if cron job already exists
if crontab -l 2>/dev/null | grep -q "$INSTALL_DIR/report.sh"; then
    echo "Cron job already exists, skipping..."
else
    # Add cron job
    (crontab -l 2>/dev/null || true; echo "$CRON_MARKER"; echo "$CRON_JOB") | crontab -
    echo "Cron job added successfully"
fi

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Next steps:"
echo "1. Edit the configuration file: $INSTALL_DIR/config.env"
echo "2. Test the script manually: $INSTALL_DIR/report.sh"
echo "3. Check logs at: $LOG_FILE"
echo ""
echo "To uninstall, run: $INSTALL_DIR/uninstall.sh"
