#!/bin/bash
# scripts/extract-ocm-secrets.sh
# Extracts OCM hub secrets and stores them as GitHub secrets
# Usage: ./extract-ocm-secrets.sh <environment> <hub-kubeconfig-path>

set -e

ENV="${1:?Environment required (dev|staging|production)}"
KUBECONFIG_PATH="${2:?Hub kubeconfig path required}"

if [ ! -f "$KUBECONFIG_PATH" ]; then
  echo "❌ Kubeconfig file not found: $KUBECONFIG_PATH"
  exit 1
fi

export KUBECONFIG="$KUBECONFIG_PATH"

echo "🔍 Extracting OCM hub secrets for environment: $ENV"

# Validate cluster connection
echo "Checking cluster connectivity..."
if ! kubectl cluster-info > /dev/null 2>&1; then
  echo "❌ Failed to connect to cluster"
  exit 1
fi

# Extract secrets
echo "Extracting bootstrap token..."
BOOTSTRAP_TOKEN=$(kubectl get secret -n open-cluster-management bootstrap-token-* -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || echo "")

echo "Extracting API server URL..."
API_URL=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "")

echo "Extracting CA certificate..."
CA_CERT=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null || echo "")

echo "Extracting cluster manager token..."
CLUSTER_MANAGER_TOKEN=$(kubectl create token -n open-cluster-management cluster-manager --duration=87600h 2>/dev/null || echo "")

# Validate extracted values
if [ -z "$BOOTSTRAP_TOKEN" ] || [ -z "$API_URL" ] || [ -z "$CA_CERT" ]; then
  echo "⚠ Warning: Some secrets could not be extracted"
  echo "  Bootstrap Token: ${#BOOTSTRAP_TOKEN} bytes"
  echo "  API URL: $API_URL"
  echo "  CA Cert: ${#CA_CERT} bytes"
fi

# Prepare environment prefix
ENV_UPPER=$(echo "$ENV" | tr '[:lower:]' '[:upper:]')

# Handle production hubs
if [ "$ENV" == "production" ]; then
  HUB_TYPE="${3:?Hub type required for production (primary|secondary)}"
  HUB_TYPE_UPPER=$(echo "$HUB_TYPE" | tr '[:lower:]' '[:upper:]')
  SECRET_PREFIX="${ENV_UPPER}_${HUB_TYPE_UPPER}"
else
  SECRET_PREFIX="$ENV_UPPER"
fi

echo ""
echo "📝 GitHub secrets to be set:"
echo "  - ${SECRET_PREFIX}_OCM_HUB_KUBECONFIG"
echo "  - ${SECRET_PREFIX}_OCM_HUB_BOOTSTRAP_TOKEN"
echo "  - ${SECRET_PREFIX}_OCM_HUB_API_URL"
echo "  - ${SECRET_PREFIX}_OCM_HUB_CA_CERT"
echo "  - ${SECRET_PREFIX}_OCM_CLUSTER_MANAGER_TOKEN"
echo ""

# Store secrets if gh CLI available
if command -v gh &> /dev/null; then
  echo "🔐 Storing secrets in GitHub..."
  
  kubectl config view --minify --flatten > /tmp/hub-kubeconfig
  gh secret set "${SECRET_PREFIX}_OCM_HUB_KUBECONFIG" < /tmp/hub-kubeconfig
  echo -n "$BOOTSTRAP_TOKEN" | gh secret set "${SECRET_PREFIX}_OCM_HUB_BOOTSTRAP_TOKEN"
  echo -n "$API_URL" | gh secret set "${SECRET_PREFIX}_OCM_HUB_API_URL"
  echo -n "$CA_CERT" | gh secret set "${SECRET_PREFIX}_OCM_HUB_CA_CERT"
  echo -n "$CLUSTER_MANAGER_TOKEN" | gh secret set "${SECRET_PREFIX}_OCM_CLUSTER_MANAGER_TOKEN"
  
  rm -f /tmp/hub-kubeconfig
  
  echo "✓ Secrets stored successfully"
else
  echo "⚠ GitHub CLI (gh) not found. Secrets not stored."
  echo "   Please set these manually or install gh CLI"
fi

exit 0
