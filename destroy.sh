#!/bin/bash
#
# Destroy script for ECS Auto-Stop Automation
# This script removes all cloud resources created by Terraform
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
INFRA_DIR="$PROJECT_ROOT/infra"

echo "=== ECS Auto-Stop Resource Cleanup ==="
echo ""
echo "WARNING: This will destroy all cloud resources created by this project."
echo "Make sure to uninstall the ECS agent first to avoid errors."
echo ""

cd "$INFRA_DIR"

# Show what will be destroyed
terraform plan -destroy

echo ""
read -p "Are you sure you want to destroy all resources? (yes/no): " confirm

if [[ "$confirm" != "yes" ]]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo ""
echo "Destroying resources..."
terraform destroy -auto-approve

echo ""
echo "=== Cleanup Complete ==="
echo ""
echo "Don't forget to:"
echo "1. Uninstall the agent from the ECS instance:"
echo "   ssh root@YOUR_ECS_IP '/opt/ssh-monitor/uninstall.sh'"
echo ""
