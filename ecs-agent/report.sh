#!/bin/bash
#
# SSH Connection Monitor Script for ECS Auto-Stop
# This script monitors active SSH connections and reports to Function Compute
#
# Installation:
#   1. Copy to /opt/ssh-monitor/report.sh
#   2. chmod +x /opt/ssh-monitor/report.sh
#   3. Add cron job: */5 * * * * /opt/ssh-monitor/report.sh >> /var/log/ssh-monitor.log 2>&1
#

set -e

# Configuration - Update these values
CONFIG_FILE="/opt/ssh-monitor/config.env"

# Load configuration
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "[ERROR] Configuration file not found: $CONFIG_FILE"
    echo "Please create the config file with the following variables:"
    echo "  FC_ENDPOINT=https://your-fc-endpoint.ap-northeast-1.fc.aliyuncs.com/ssh-status"
    echo "  INSTANCE_ID=i-xxxxx"
    echo "  AUTH_TOKEN=your-secret-token"
    exit 1
fi

# Validate required configuration
if [[ -z "$FC_ENDPOINT" || -z "$INSTANCE_ID" || -z "$AUTH_TOKEN" ]]; then
    echo "[ERROR] Missing required configuration variables"
    exit 1
fi

# Get current timestamp
TIMESTAMP=$(date +%s)
DATE_STR=$(date '+%Y-%m-%d %H:%M:%S')

# Count active SSH connections
# Method 1: Using ss command (preferred, more reliable)
if command -v ss &> /dev/null; then
    SSH_COUNT=$(ss -tn state established '( dport = :22 or sport = :22 )' 2>/dev/null | grep -v "^State" | wc -l | tr -d ' ')
# Method 2: Fallback to netstat
elif command -v netstat &> /dev/null; then
    SSH_COUNT=$(netstat -tn 2>/dev/null | grep ':22 ' | grep 'ESTABLISHED' | wc -l | tr -d ' ')
# Method 3: Count logged-in users via who
else
    SSH_COUNT=$(who 2>/dev/null | wc -l | tr -d ' ')
fi

# Ensure SSH_COUNT is a valid number
if ! [[ "$SSH_COUNT" =~ ^[0-9]+$ ]]; then
    SSH_COUNT=0
fi

echo "[$DATE_STR] SSH connections: $SSH_COUNT"

# Build JSON payload
JSON_PAYLOAD=$(cat <<EOF
{
    "instance_id": "$INSTANCE_ID",
    "ssh_count": $SSH_COUNT,
    "timestamp": $TIMESTAMP
}
EOF
)

# Report to Function Compute
HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$FC_ENDPOINT" \
    -H "Content-Type: application/json" \
    -H "X-Auth-Token: $AUTH_TOKEN" \
    -d "$JSON_PAYLOAD" \
    --connect-timeout 10 \
    --max-time 30)

# Extract HTTP status code (last line)
HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
    echo "[$DATE_STR] Report sent successfully (HTTP $HTTP_CODE)"
else
    echo "[$DATE_STR] [ERROR] Failed to send report (HTTP $HTTP_CODE): $RESPONSE_BODY"
    exit 1
fi
