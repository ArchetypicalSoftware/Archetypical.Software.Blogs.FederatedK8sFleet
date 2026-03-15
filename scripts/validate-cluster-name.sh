#!/bin/bash
# scripts/validate-cluster-name.sh
# Validates cluster name against naming conventions
# Usage: ./validate-cluster-name.sh <cluster-name>

set -e

NAME="${1:?Cluster name required}"

# Check if name matches pattern: lowercase alphanumeric + hyphens, 1-63 chars, no leading/trailing hyphens
if [[ ! "$NAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
  echo "❌ Invalid cluster name: $NAME"
  echo ""
  echo "Requirements:"
  echo "  - Lowercase alphanumeric characters and hyphens only"
  echo "  - Length: 1-63 characters"
  echo "  - Cannot start or end with hyphen"
  echo ""
  echo "Examples of valid names:"
  echo "  - pilot-1"
  echo "  - prod-api-1"
  echo "  - team-management"
  exit 1
fi

echo "✓ Valid cluster name: $NAME"
exit 0
