# Archetypical Fleet Management System

**GitHub-driven, multi-cloud Kubernetes cluster orchestration using Cluster API and Open Cluster Management**

## Overview

This repository implements a decentralized, GitOps-driven fleet management system for Kubernetes clusters across AWS, Azure, and GCP. It provides:

- **Declarative cluster lifecycle** via Cluster API (CAPI) with ClusterClass + topology
- **Multi-hub OCM architecture** for fleet registration, policy enforcement, and placement
- **Minimal bootstrap** with Flux for GitOps-driven configuration
- **Environment-scoped** cloud credentials and secrets
- **Autoscaling** enabled by default on all clusters
- **Deletion protection** for production clusters
- **Cost tracking** via automated tagging

## Architecture

```
GitHub (Source of Truth)
    ↓
GitHub Actions (Bootstrap & Lifecycle)
    ↓
Cluster API (Cluster Provisioning)
    ↓
Self-Managed Clusters
    ↓
OCM Hub (Fleet Management) + Flux (GitOps Configuration)
```

## Repository Structure

```
clusters/{env}/{domain}/{provider}/{region}/{name}/
  └── cluster.yaml          # Cluster definition using ClusterClass

clusterclasses/
  ├── aws-standard-clusterclass.yaml
  ├── azure-standard-clusterclass.yaml
  ├── gcp-standard-clusterclass.yaml
  └── ocm-hub-clusterclass.yaml

ocm/hubs/
  ├── hub-topology.yaml     # Multi-hub federation config
  ├── dev/, staging/, production/
  ├── placements/           # Cluster selection rules
  └── policies/             # Governance policies

.github/workflows/
  ├── bootstrap-ocm-hub.yaml        # Hub cluster bootstrap
  ├── bootstrap-cluster.yaml        # Workload cluster bootstrap
  ├── cleanup-cluster.yaml          # Cluster deletion
  └── validate-manifests.yaml       # PR validation
```

## Quick Start

### Prerequisites

- GitHub repository with Actions enabled
- Cloud provider credentials (AWS/Azure/GCP)
- GitHub CLI (`gh`) for secret management
- `kubectl`, `clusterctl`, `flux` CLI tools

### 1. Configure GitHub Secrets

Environment-scoped cloud credentials:

```bash
# AWS credentials (repeat for STAGING_, PRODUCTION_)
gh secret set DEV_AWS_ACCESS_KEY_ID --body "<your-key-id>"
gh secret set DEV_AWS_SECRET_ACCESS_KEY --body "<your-secret-key>"

# Azure credentials (repeat for STAGING_, PRODUCTION_)
gh secret set DEV_AZURE_CLIENT_ID --body "<your-client-id>"
gh secret set DEV_AZURE_CLIENT_SECRET --body "<your-client-secret>"
gh secret set DEV_AZURE_SUBSCRIPTION_ID --body "<your-subscription-id>"
gh secret set DEV_AZURE_TENANT_ID --body "<your-tenant-id>"

# GCP credentials (repeat for STAGING_, PRODUCTION_)
gh secret set DEV_GCP_SERVICE_ACCOUNT --body "$(cat service-account.json | base64)"
```

GitOps repository token:

```bash
gh secret set GITOPS_REPO_TOKEN --body "<github-token-with-repo-access>"
```

### 2. Bootstrap OCM Hub

Create a hub cluster definition:

```yaml
# clusters/dev/management/aws/us-east-1/dev-hub/cluster.yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: dev-hub
  labels:
    team: management
    cluster-type: management
    environment: dev
spec:
  topology:
    class: ocm-hub
    version: v1.28.0
    controlPlane:
      replicas: 3
    workers:
      machineDeployments:
        - class: default-worker
          replicas: 2
    variables:
      - name: region
        value: us-east-1
      - name: environment
        value: dev
```

Trigger bootstrap workflow:

```bash
git add clusters/dev/management/aws/us-east-1/dev-hub/cluster.yaml
git commit -m "Add dev OCM hub cluster"
git push origin main
```

### 3. Deploy Workload Cluster

Create cluster definition:

```yaml
# clusters/dev/platform/aws/us-east-1/pilot-1/cluster.yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: pilot-1
  labels:
    team: platform
    cluster-type: workload
    environment: dev
spec:
  topology:
    class: aws-standard
    version: v1.30.0
    controlPlane:
      replicas: 3
    workers:
      machineDeployments:
        - class: default-worker
          replicas: 3
    variables:
      - name: region
        value: us-east-1
      - name: workerMinReplicas
        value: 1
      - name: workerMaxReplicas
        value: 10
```

Push to trigger bootstrap:

```bash
git add clusters/dev/platform/aws/us-east-1/pilot-1/cluster.yaml
git commit -m "Add pilot-1 cluster"
git push origin main
```

## Cluster Lifecycle

### Creation

1. Create cluster.yaml in appropriate path
2. Open PR for review
3. Validation workflow checks path, naming, labels
4. CODEOWNERS approval required
5. Merge to main triggers bootstrap workflow
6. Cluster created, self-managed, registered with OCM hub
7. Flux GitOps configured from fleet-gitops repo

### Updates

1. Modify cluster.yaml (change versions, scaling, etc.)
2. Open PR
3. Merge triggers reconciliation on self-managed cluster
4. CAPI reconciles topology changes

### Deletion

**For production clusters:**

1. Remove `deletion-protection: enabled` label (requires platform team approval)
2. Delete cluster.yaml file (requires platform team approval + `APPROVED FOR DELETION` comment)
3. Merge triggers cleanup workflow
4. Kubeconfig secret removed, cluster resources deleted

## Validation Rules

All PRs are validated for:

- **Path pattern**: `clusters/{env}/{domain}/{provider}/{region}/{name}/cluster.yaml`
- **Cluster name**: Lowercase alphanumeric + hyphens, 1-63 chars
- **ClusterClass matches provider**: `aws-standard` must be in `.../aws/...` path
- **Required labels**: `team`, `cluster-type`, `environment`, `deletion-protection` (production only)
- **No duplicate names**: Cluster names must be unique across repository
- **Autoscaler ranges**: min >= 0, max <= 100, min < max

## Multi-Hub Architecture

- **dev-hub**: `us-east-1`, capacity <10 clusters
- **staging-hub**: `us-west-2`, capacity <50 clusters  
- **production-hub-primary**: `us-east-1`, active, capacity 1000+
- **production-hub-secondary**: `eu-west-1`, passive failover, capacity 1000+

## Documentation

- [copilot-instructions.md](copilot-instructions.md) - Complete implementation guide
- [ocm/hubs/FAILOVER.md](ocm/hubs/FAILOVER.md) - Hub failover procedures (TODO)
- [scripts/](scripts/) - Helper scripts and utilities

## Contributing

1. Create feature branch
2. Add/modify cluster definitions following path conventions
3. Ensure validation passes locally
4. Open PR with clear description
5. Await CODEOWNERS approval
6. Merge to main

## Support

- GitHub Issues for bug reports
- GitHub Discussions for questions
- Platform team: @ArchetypicalSoftware/platform-team

## License

MIT License - See [LICENSE](LICENSE) file
