#!/bin/bash
# scripts/apply-gitops-metadata.sh
# Creates cluster-bootstrap ConfigMap with cluster metadata
# Usage: ./apply-gitops-metadata.sh <cluster-name> <environment> <domain> <provider> <region> <cluster-class> <k8s-version> <ocm-hub-url>

set -e

CLUSTER_NAME="${1:?Cluster name required}"
ENVIRONMENT="${2:?Environment required}"
DOMAIN="${3:?Domain required}"
PROVIDER="${4:?Provider required}"
REGION="${5:?Region required}"
CLUSTER_CLASS="${6:?ClusterClass required}"
K8S_VERSION="${7:?Kubernetes version required}"
OCM_HUB_URL="${8:?OCM hub URL required}"

GITOPS_PATH="clusters/$ENVIRONMENT/$DOMAIN/$PROVIDER/$REGION/$CLUSTER_NAME"

echo "📋 Creating cluster-bootstrap ConfigMap..."
echo "  Cluster: $CLUSTER_NAME"
echo "  Environment: $ENVIRONMENT"
echo "  Domain: $DOMAIN"
echo "  Provider: $PROVIDER"
echo "  Region: $REGION"
echo "  GitOps Path: $GITOPS_PATH"

kubectl create configmap cluster-bootstrap \
  --namespace=flux-system \
  --from-literal=provider="$PROVIDER" \
  --from-literal=region="$REGION" \
  --from-literal=team="$DOMAIN" \
  --from-literal=domain="$DOMAIN" \
  --from-literal=cluster-type="workload" \
  --from-literal=environment="$ENVIRONMENT" \
  --from-literal=cluster-name="$CLUSTER_NAME" \
  --from-literal=cluster-class="$CLUSTER_CLASS" \
  --from-literal=kubernetes-version="$K8S_VERSION" \
  --from-literal=ocm-hub-url="$OCM_HUB_URL" \
  --from-literal=gitops-repo="github.com/ArchetypicalSoftware/fleet-gitops" \
  --from-literal=gitops-path="$GITOPS_PATH" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✓ ConfigMap created successfully"
