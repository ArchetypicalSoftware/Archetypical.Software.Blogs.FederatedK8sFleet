# Archetypical Fleet Management System - Implementation Guide

## 1. Goal and mental model

Implement a decentralized, GitHub-driven, Cluster API–based multi-cluster system supporting AWS, Azure, and GCP where:

- **GitHub** is the **source of truth** for cluster definitions and fleet configuration
- **Cluster API (CAPI)** manages **cluster lifecycle** using **ClusterClass + topology**
- **GitHub Actions + kind** handle **initial bootstrap** and `clusterctl move`
- Clusters become **self-managed management clusters** after bootstrap
- **Open Cluster Management (OCM)** provides **multi-hub fleet registration, policy, and placement**
- **Flux** handles **GitOps** from separate repository (`github.com/ArchetypicalSoftware/fleet-gitops`)
- **Minimal bootstrap** installs only: Flux operator + instance + ConfigMap + External Secrets credentials
- **Environment-scoped** cloud credentials (DEV_*, STAGING_*, PRODUCTION_*)
- **Deletion protection** via label checks for production clusters
- **Autoscaling** enabled by default on all clusters

This file is written so an agent (or human) can implement the system end-to-end.

---

## 2. Repository structure

Use a layout that enforces environment → domain → provider → region hierarchy:

```text
.
├── clusters/
│   ├── dev/                                    # Environment (sorting priority)
│   │   ├── management/                         # Domain
│   │   │   ├── aws/                            # Provider
│   │   │   │   ├── us-east-1/                  # Region
│   │   │   │   │   └── dev-hub/                # Cluster name
│   │   │   │   │       └── cluster.yaml
│   │   │   │   └── us-west-2/
│   │   │   │       └── dev-mgmt-1/
│   │   │   │           └── cluster.yaml
│   │   │   ├── azure/
│   │   │   │   └── eastus/
│   │   │   └── gcp/
│   │   │       └── us-central1/
│   │   ├── platform/
│   │   │   └── aws/
│   │   │       └── us-east-1/
│   │   │           └── pilot-1/
│   │   │               └── cluster.yaml
│   │   ├── logging/
│   │   └── payments/
│   ├── staging/
│   │   ├── management/
│   │   ├── platform/
│   │   ├── logging/
│   │   └── payments/
│   └── production/
│       ├── management/
│       │   └── aws/
│       │       ├── us-east-1/
│       │       │   └── production-hub-primary/
│       │       │       └── cluster.yaml       # MUST have deletion-protection: enabled
│       │       └── eu-west-1/
│       │           └── production-hub-secondary/
│       │               └── cluster.yaml       # MUST have deletion-protection: enabled
│       ├── platform/
│       ├── logging/
│       └── payments/
│
├── clusterclasses/
│   ├── aws-standard-clusterclass.yaml          # Multi-cloud support
│   ├── aws-standard-templates.yaml
│   ├── azure-standard-clusterclass.yaml
│   ├── azure-standard-templates.yaml
│   ├── gcp-standard-clusterclass.yaml
│   ├── gcp-standard-templates.yaml
│   ├── ocm-hub-clusterclass.yaml               # OCM hub with environment sizing
│   └── ocm-hub-templates.yaml
│
├── ocm/
│   ├── hubs/
│   │   ├── hub-topology.yaml                   # Multi-hub federation config
│   │   ├── FAILOVER.md                         # Hub failover procedures
│   │   ├── dev/
│   │   │   └── clustermanager.yaml
│   │   ├── staging/
│   │   │   └── clustermanager.yaml
│   │   └── production/
│   │       ├── primary/
│   │       │   └── clustermanager.yaml
│   │       └── secondary/
│   │           └── clustermanager.yaml
│   ├── placements/
│   │   ├── environment-placements.yaml
│   │   └── domain-placements.yaml
│   └── policies/
│       ├── require-namespace-label.yaml
│       ├── security-baseline.yaml
│       └── cost-tracking-tags.yaml
│
├── scripts/
│   ├── validate-cluster-name.sh
│   ├── extract-ocm-secrets.sh
│   └── apply-gitops-metadata.sh
│
└── .github/
    ├── CODEOWNERS                              # Path-based approval rules
    └── workflows/
        ├── bootstrap-ocm-hub.yaml              # Multi-hub bootstrap with matrix
        ├── bootstrap-cluster.yaml              # Minimal bootstrap workflow
        ├── cleanup-cluster.yaml                # Deletion with protection checks
        ├── reconcile-capi-changes.yaml         # Change-only reconciliation
        ├── validate-manifests.yaml             # Path, name, label, schema validation
        └── enforce-approvals.yaml              # Team-based PR approvals
```

---

## 3. Multi-hub OCM architecture

### 3.1 Hub topology

**Active-passive federation for production HA:**

- **dev-hub**: Single hub in `us-east-1` (2 workers, capacity <10 clusters)
- **staging-hub**: Single hub in `us-west-2` (3 workers, capacity <50 clusters)
- **production-hub-primary**: Active hub in `us-east-1` (5 workers, autoscale to 15, capacity 1000+)
- **production-hub-secondary**: Passive hub in `eu-west-1` (5 workers, autoscale to 15, capacity 1000+)

### 3.2 Environment-scoped GitHub Secrets

**OCM Hub secrets (extracted during hub bootstrap):**

- `DEV_OCM_HUB_KUBECONFIG`, `DEV_OCM_HUB_BOOTSTRAP_TOKEN`, `DEV_OCM_HUB_API_URL`, `DEV_OCM_HUB_CA_CERT`, `DEV_OCM_CLUSTER_MANAGER_TOKEN`
- `STAGING_OCM_HUB_KUBECONFIG`, `STAGING_OCM_HUB_BOOTSTRAP_TOKEN`, `STAGING_OCM_HUB_API_URL`, `STAGING_OCM_HUB_CA_CERT`, `STAGING_OCM_CLUSTER_MANAGER_TOKEN`
- `PRODUCTION_PRIMARY_OCM_HUB_KUBECONFIG`, `PRODUCTION_PRIMARY_OCM_HUB_BOOTSTRAP_TOKEN`, `PRODUCTION_PRIMARY_OCM_HUB_API_URL`, `PRODUCTION_PRIMARY_OCM_HUB_CA_CERT`, `PRODUCTION_PRIMARY_OCM_CLUSTER_MANAGER_TOKEN`
- `PRODUCTION_SECONDARY_OCM_HUB_KUBECONFIG`, `PRODUCTION_SECONDARY_OCM_HUB_BOOTSTRAP_TOKEN`, `PRODUCTION_SECONDARY_OCM_HUB_API_URL`, `PRODUCTION_SECONDARY_OCM_HUB_CA_CERT`, `PRODUCTION_SECONDARY_OCM_CLUSTER_MANAGER_TOKEN`

**Cloud provider credentials (environment-scoped):**

- AWS: `DEV_AWS_ACCESS_KEY_ID`, `DEV_AWS_SECRET_ACCESS_KEY`, `STAGING_AWS_ACCESS_KEY_ID`, `STAGING_AWS_SECRET_ACCESS_KEY`, `PRODUCTION_AWS_ACCESS_KEY_ID`, `PRODUCTION_AWS_SECRET_ACCESS_KEY`
- Azure: `DEV_AZURE_CLIENT_ID`, `DEV_AZURE_CLIENT_SECRET`, `DEV_AZURE_SUBSCRIPTION_ID`, `DEV_AZURE_TENANT_ID`, (repeat for STAGING_ and PRODUCTION_)
- GCP: `DEV_GCP_SERVICE_ACCOUNT`, `STAGING_GCP_SERVICE_ACCOUNT`, `PRODUCTION_GCP_SERVICE_ACCOUNT` (base64-encoded JSON keys)

**Cluster kubeconfigs (stored after bootstrap):**

- Format: `{ENV}_{CLUSTER_NAME}_KUBECONFIG` (e.g., `DEV_PILOT_1_KUBECONFIG`, `PRODUCTION_PAYMENTS_API_KUBECONFIG`)

---

## 4. ClusterClass templates with autoscaler and cost tracking

### 4.1 Common autoscaler variables (all ClusterClass templates)

```yaml
variables:
  - name: autoscalerEnabled
    required: false
    schema:
      openAPIV3Schema:
        type: boolean
        default: true
  - name: workerMinReplicas
    required: false
    schema:
      openAPIV3Schema:
        type: integer
        default: 1
        minimum: 0
  - name: workerMaxReplicas
    required: false
    schema:
      openAPIV3Schema:
        type: integer
        default: 10
        minimum: 1
        maximum: 100
  - name: scaleDownDelayAfterAdd
    required: false
    schema:
      openAPIV3Schema:
        type: string
        default: "10m"
  - name: scaleDownUnneededTime
    required: false
    schema:
      openAPIV3Schema:
        type: string
        default: "10m"
  - name: scaleDownUtilizationThreshold
    required: false
    schema:
      openAPIV3Schema:
        type: string
        default: "0.5"
```

### 4.2 Cost tracking tags (required on all infrastructure)

All ClusterClass templates include patches injecting these tags:

- `environment` (from cluster path)
- `domain` (from cluster path)
- `team` (from cluster label)
- `managed-by: capi`
- `gitops-repo: fleet-gitops`

### 4.3 Provider-specific autoscaler requirements

**AWS**: ASG tags `k8s.io/cluster-autoscaler/enabled: "true"`, `k8s.io/cluster-autoscaler/<cluster-name>: "owned"`
**Azure**: VMSS tags `cluster-autoscaler-enabled: "true"`, `cluster-autoscaler-name: "<cluster-name>"`
**GCP**: MIG labels `cluster-autoscaler-enabled: "true"`, `cluster-autoscaler-<cluster-name>: "owned"`

---

## 5. Cluster naming and path conventions

### 5.1 ENFORCED RULES

1. **Path pattern**: `clusters/{env}/{domain}/{provider}/{region}/{name}/cluster.yaml`
2. **Environment**: Must be one of: `dev`, `staging`, `production`
3. **Provider**: Must be one of: `aws`, `azure`, `gcp`
4. **Cluster name**: Lowercase alphanumeric + hyphens, 1-63 chars, no leading/trailing hyphens
5. **ClusterClass must match provider**: e.g., `aws-standard` in `.../aws/...` path
6. **Required labels**:
   - `team: <domain>` (derived from path)
   - `cluster-type: <management|workload>`
   - `environment: <env>` (must match path)
   - `deletion-protection: enabled` (REQUIRED for production clusters)

### 5.2 Validation checks (automated in validate-manifests.yaml)

- Path regex: `^clusters/(dev|staging|production)/[a-z0-9-]+/(aws|azure|gcp)/[a-z0-9-]+/[a-z0-9-]+/cluster\.yaml$`
- Cluster name regex: `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`
- ClusterClass provider matches directory provider
- All required labels present and correct values
- No duplicate cluster names across entire repository
- Autoscaler min < max, min >= 0, max <= 100

---

## 6. Minimal bootstrap approach

**Bootstrap workflow installs ONLY:**

1. **Flux operator CRDs** - Core Flux components
2. **Flux GitRepository instance** - Points to `github.com/ArchetypicalSoftware/fleet-gitops` at per-cluster path
3. **cluster-bootstrap ConfigMap** - Metadata for Flux to consume (provider, region, team, environment, etc.)
4. **External Secrets credentials secret** - Read-only token for OCM hub namespace access

**Everything else (cluster-autoscaler, monitoring, ingress, policies, etc.) is managed via GitOps.**

### 6.1 Flux GitRepository path structure

Each cluster gets its own GitOps path: `clusters/{env}/{domain}/{provider}/{region}/{name}/`

Within this path, the fleet-gitops repo contains:
- `kustomization.yaml` - Root Kustomization
- `services/` - Cluster-specific services
- Shared base resources imported via Kustomize

### 6.2 cluster-bootstrap ConfigMap contents

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-bootstrap
  namespace: flux-system
data:
  provider: "aws"
  region: "us-east-1"
  team: "platform"
  domain: "platform"
  cluster-type: "workload"
  environment: "dev"
  cluster-name: "pilot-1"
  cluster-class: "aws-standard"
  kubernetes-version: "v1.30.0"
  ocm-hub-url: "https://dev-hub.example.com:6443"
  gitops-repo: "github.com/ArchetypicalSoftware/fleet-gitops"
  gitops-path: "clusters/dev/platform/aws/us-east-1/pilot-1"
```

---

## 7. Deletion protection procedures

### 7.1 Production cluster deletion requirements

**ALL production clusters MUST have:**

```yaml
metadata:
  labels:
    deletion-protection: enabled
```

### 7.2 Deletion process (2-step)

**Step 1**: Create PR removing `deletion-protection: enabled` label
- Requires approval from `@ArchetypicalSoftware/platform-team`
- Merge to main

**Step 2**: Create PR deleting `cluster.yaml` file
- Requires approval from `@ArchetypicalSoftware/platform-team`
- Platform team member MUST comment: `APPROVED FOR DELETION`
- Merge to main
- Automated cleanup runs:
  - Validates deletion-protection removed
  - Validates approval comment exists
  - Deletes GitHub Secret `{ENV}_{CLUSTER_NAME}_KUBECONFIG`
  - Optionally deletes cluster resources

**Attempting to delete a cluster with `deletion-protection: enabled` will fail validation.**

---

## 8. CODEOWNERS configuration

```gitignore
# .github/CODEOWNERS

# Default owners
* @ArchetypicalSoftware/platform-team

# ClusterClass definitions
/clusterclasses/** @ArchetypicalSoftware/platform-team @ArchetypicalSoftware/sre-team

# OCM hub configuration
/ocm/hubs/** @ArchetypicalSoftware/platform-team @ArchetypicalSoftware/security-team

# Production clusters (environment-based)
/clusters/production/** @ArchetypicalSoftware/platform-team @ArchetypicalSoftware/security-team

# Staging clusters
/clusters/staging/** @ArchetypicalSoftware/platform-team

# Dev clusters
/clusters/dev/** @ArchetypicalSoftware/developers

# Domain-specific overrides
/clusters/**/management/** @ArchetypicalSoftware/platform-team
/clusters/**/platform/** @ArchetypicalSoftware/platform-team
/clusters/**/logging/** @ArchetypicalSoftware/logging-team
/clusters/**/payments/** @ArchetypicalSoftware/payments-team @ArchetypicalSoftware/security-team
```

---

## 9. TODO: Future enhancements

### 9.1 Hub failover procedures (High priority)

- Create `ocm/hubs/FAILOVER.md` with step-by-step procedures
- Document detection, ManagedClusterSet updates, failover testing

### 9.2 ESO operator installation order (Medium priority)

- Ensure GitOps Kustomization dependencies: ESO first, then dependent services
- Bootstrap creates credentials, GitOps installs operator

### 9.3 Cluster naming collision prevention (Completed)

- Validation workflow checks for duplicate names across all paths

### 9.4 Hub certificate rotation (Low priority)

- Document manual rotation procedure
- Future: Automate with CronJob + GitHub Actions

### 9.5 Cost tracking tag enforcement (Completed)

- All ClusterClass patches include required tags

### 9.6 External Secrets federation at scale (High priority)

- Migrate from GitHub Secrets to OCM hub + ESO at ~500 clusters
- Use ESO PushSecret to sync kubeconfigs

### 9.7 Multi-cloud networking automation (High priority)

- VPC peering, Transit Gateway, DNS zones per domain
- Network topology definitions in `ocm/networking/`

### 9.8 Cluster monitoring and observability (High priority)

- Prometheus per cluster, Thanos aggregation on hubs
- Grafana dashboards, alert routing

### 9.9 Security scanning and compliance (Medium priority)

- Trivy, Falco, OPA Gatekeeper via OCM policies
- Compliance reports on hub

### 9.10 Disaster recovery and backup (High priority)

- Velero, etcd snapshots, automated restore testing
- RTO/RPO SLAs per environment

---

## 10. Implementation checklist

### Phase 1: Foundation (Weeks 1-2)

- [ ] Create directory structure
- [ ] Add .gitignore
- [ ] Add .github/CODEOWNERS
- [ ] Create OCM hub ClusterClass (multi-cloud)
- [ ] Create AWS/Azure/GCP standard ClusterClass with autoscaler
- [ ] Add cost tracking tag patches
- [ ] Create validation workflow
- [ ] Create bootstrap-ocm-hub workflow
- [ ] Create bootstrap-cluster workflow
- [ ] Create cleanup-cluster workflow
- [ ] Create helper scripts
- [ ] Configure branch protection rules

### Phase 2: Hub deployment (Week 3)

- [ ] Deploy dev-hub cluster
- [ ] Extract and store DEV_OCM_HUB_* secrets
- [ ] Deploy staging-hub cluster
- [ ] Extract and store STAGING_OCM_HUB_* secrets
- [ ] Deploy production-hub-primary
- [ ] Deploy production-hub-secondary
- [ ] Configure hub-to-hub federation
- [ ] Document failover procedures

### Phase 3: Workload cluster bootstrap (Week 4)

- [ ] Deploy pilot-1 cluster
- [ ] Verify minimal bootstrap
- [ ] Verify GitOps connection
- [ ] Verify OCM registration
- [ ] Verify kubeconfig storage
- [ ] Verify autoscaler annotations

### Phase 4: GitOps repository setup (Week 5)

- [ ] Create fleet-gitops repo
- [ ] Add base Kustomizations
- [ ] Add per-cluster overlays
- [ ] Test Flux reconciliation

### Phase 5: Scale testing (Week 6)

- [ ] Deploy 5 clusters across dev/staging
- [ ] Test autoscaler functionality
- [ ] Test deletion protection
- [ ] Test cleanup workflow

### Phase 6: Production readiness (Week 7-8)

- [ ] Security audit
- [ ] Performance testing
- [ ] Document runbooks
- [ ] Train teams
- [ ] Deploy first production cluster

---

## 11. Reference implementation examples

### 11.1 OCM hub cluster definition

```yaml
# clusters/dev/management/aws/us-east-1/dev-hub/cluster.yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: dev-hub
  namespace: default
  labels:
    team: management
    cluster-type: management
    environment: dev
    hub-role: primary
spec:
  topology:
    class: ocm-hub
    version: v1.28.0
    controlPlane:
      replicas: 3
    workers:
      machineDeployments:
        - class: default-worker
          name: hub-workers
          replicas: 2
    variables:
      - name: region
        value: us-east-1
      - name: hubRole
        value: primary
      - name: environment
        value: dev
      - name: kubernetesVersion
        value: v1.28.0
      - name: workerMinReplicas
        value: 2
      - name: workerMaxReplicas
        value: 5
```

### 11.2 Production workload cluster definition

```yaml
# clusters/production/payments/aws/us-east-1/payments-api/cluster.yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: payments-api
  namespace: default
  labels:
    team: payments
    cluster-type: workload
    environment: production
    deletion-protection: enabled  # REQUIRED
spec:
  topology:
    class: aws-standard
    version: v1.30.0
    controlPlane:
      replicas: 3
    workers:
      machineDeployments:
        - class: default-worker
          name: default
          replicas: 5
    variables:
      - name: region
        value: us-east-1
      - name: controlPlaneMachineType
        value: m5.xlarge
      - name: workerMachineType
        value: m5.xlarge
      - name: kubernetesVersion
        value: v1.30.0
      - name: autoscalerEnabled
        value: true
      - name: workerMinReplicas
        value: 5
      - name: workerMaxReplicas
        value: 20
```

---

This file is the single reference for implementing the Archetypical Fleet Management System: GitHub PR → CAPI lifecycle → self-managed clusters → multi-hub OCM governance → minimal Flux GitOps → automated lifecycle with deletion protection.
3.1 ClusterClass definition
clusterclasses/aws-standard-clusterclass.yaml:

```yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: ClusterClass
metadata:
  name: aws-standard
  namespace: default
spec:
  infrastructure:
    ref:
      apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
      kind: AWSClusterTemplate
      name: aws-standard-cluster-template
  controlPlane:
    ref:
      apiVersion: controlplane.cluster.x-k8s.io/v1beta1
      kind: KubeadmControlPlaneTemplate
      name: aws-standard-controlplane-template
    machineInfrastructure:
      ref:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
        kind: AWSMachineTemplate
        name: aws-standard-controlplane-machinetemplate
  workers:
    machineDeployments:
      - class: default-worker
        template:
          bootstrap:
            ref:
              apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
              kind: KubeadmConfigTemplate
              name: aws-standard-worker-bootstrap-template
          infrastructure:
            ref:
              apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
              kind: AWSMachineTemplate
              name: aws-standard-worker-machinetemplate
  variables:
    - name: region
      required: true
      schema:
        openAPIV3Schema:
          type: string
    - name: controlPlaneMachineType
      required: true
      schema:
        openAPIV3Schema:
          type: string
    - name: workerMachineType
      required: true
      schema:
        openAPIV3Schema:
          type: string
    - name: kubernetesVersion
      required: true
      schema:
        openAPIV3Schema:
          type: string
  patches:
    - name: aws-cluster-region
      definitions:
        - selector:
            apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
            kind: AWSClusterTemplate
          jsonPatches:
            - op: replace
              path: "/spec/template/spec/region"
              valueFrom:
                variable: region
    - name: controlplane-instance-type
      definitions:
        - selector:
            apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
            kind: AWSMachineTemplate
            matchResources:
              controlPlane: true
          jsonPatches:
            - op: replace
              path: "/spec/template/spec/instanceType"
              valueFrom:
                variable: controlPlaneMachineType
    - name: worker-instance-type
      definitions:
        - selector:
            apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
            kind: AWSMachineTemplate
            matchResources:
              machineDeploymentClass:
                names: ["default-worker"]
          jsonPatches:
            - op: replace
              path: "/spec/template/spec/instanceType"
              valueFrom:
                variable: workerMachineType
    - name: kubernetes-version
      definitions:
        - selector:
            apiVersion: cluster.x-k8s.io/v1beta1
            kind: Cluster
          jsonPatches:
            - op: replace
              path: "/spec/topology/version"
              valueFrom:
                variable: kubernetesVersion
```
3.2 Supporting templates
clusterclasses/aws-standard-templates.yaml (can be split if desired):

```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: AWSClusterTemplate
metadata:
  name: aws-standard-cluster-template
  namespace: default
spec:
  template:
    spec:
      region: us-east-1   # overridden by patch
      network:
        vpc:
          cidrBlock: "10.0.0.0/16"
---
apiVersion: controlplane.cluster.x-k8s.io/v1beta1
kind: KubeadmControlPlaneTemplate
metadata:
  name: aws-standard-controlplane-template
  namespace: default
spec:
  template:
    spec:
      kubeadmConfigSpec:
        clusterConfiguration:
          apiServer:
            extraArgs:
              cloud-provider: aws
          controllerManager:
            extraArgs:
              cloud-provider: aws
        initConfiguration:
          nodeRegistration:
            kubeletExtraArgs:
              cloud-provider: aws
        joinConfiguration:
          nodeRegistration:
            kubeletExtraArgs:
              cloud-provider: aws
      machineTemplate:
        infrastructureRef:
          apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
          kind: AWSMachineTemplate
          name: aws-standard-controlplane-machinetemplate
      replicas: 3
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: AWSMachineTemplate
metadata:
  name: aws-standard-controlplane-machinetemplate
  namespace: default
spec:
  template:
    spec:
      instanceType: m5.large   # overridden by patch
      rootVolume:
        size: 80
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: AWSMachineTemplate
metadata:
  name: aws-standard-worker-machinetemplate
  namespace: default
spec:
  template:
    spec:
      instanceType: m5.large   # overridden by patch
      rootVolume:
        size: 80
---
apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
kind: KubeadmConfigTemplate
metadata:
  name: aws-standard-worker-bootstrap-template
  namespace: default
spec:
  template:
    spec:
      joinConfiguration:
        nodeRegistration:
          kubeletExtraArgs:
            cloud-provider: aws
```
4. Per-cluster definitions using topology
Teams only define small Cluster objects that reference the ClusterClass and set variables.

Example: clusters/teams/team-a/mgmt-a/cluster.yaml:

```yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: mgmt-a
  namespace: default
  labels:
    team: team-a
    role: management
spec:
  topology:
    class: aws-standard
    version: v1.30.0
    controlPlane:
      replicas: 3
    workers:
      machineDeployments:
        - class: default-worker
          name: default
          replicas: 3
    variables:
      - name: region
        value: us-east-1
      - name: controlPlaneMachineType
        value: m5.large
      - name: workerMachineType
        value: m5.large
      - name: kubernetesVersion
        value: v1.30.0
```
A workload cluster for the same team would be similar, with different name, labels, and possibly size.

5. Bootstrap workflow: create + move + register
.github/workflows/bootstrap-capi-ocm.yaml:

```yaml

name: Bootstrap CAPI cluster and register with OCM

on:
  push:
    branches: [ main ]
    paths:
      - "clusters/**"

jobs:
  bootstrap-capi-ocm:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Derive cluster path and name
        id: derive
        run: |
          CHANGED_FILE=$(git diff --name-only HEAD~1 HEAD | grep '^clusters/' | head -n1)
          CLUSTER_DIR=$(dirname "$CHANGED_FILE")
          CLUSTER_NAME=$(basename "$CLUSTER_DIR")
          echo "cluster_dir=$CLUSTER_DIR" >> $GITHUB_OUTPUT
          echo "cluster_name=$CLUSTER_NAME" >> $GITHUB_OUTPUT

      - name: Install tools
        run: |
          curl -Lo kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
          chmod +x kind && sudo mv kind /usr/local/bin/
          curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
          chmod +x kubectl && sudo mv kubectl /usr/local/bin/
          curl -L https://github.com/kubernetes-sigs/cluster-api/releases/latest/download/clusterctl-linux-amd64 -o clusterctl
          chmod +x clusterctl && sudo mv clusterctl /usr/local/bin/
          curl -L https://raw.githubusercontent.com/open-cluster-management-io/clusteradm/main/install.sh | bash
          echo "$HOME/.local/bin" >> $GITHUB_PATH

      - name: Create kind bootstrap cluster
        run: |
          kind create cluster --name capi-bootstrap
          kubectl cluster-info

      - name: Init CAPI on bootstrap
        env:
          INFRA_PROVIDER: aws
        run: |
          clusterctl init \
            --infrastructure ${INFRA_PROVIDER} \
            --bootstrap kubeadm \
            --control-plane kubeadm

      - name: Apply ClusterClass and templates
        run: |
          kubectl apply -f clusterclasses/

      - name: Apply cluster manifest
        run: |
          kubectl apply -f ${{ steps.derive.outputs.cluster_dir }}/

      - name: Wait for remote cluster kubeconfig
        env:
          CLUSTER_NAME: ${{ steps.derive.outputs.cluster_name }}
        run: |
          for i in {1..60}; do
            if clusterctl get kubeconfig ${CLUSTER_NAME} > remote.kubeconfig 2>/dev/null; then
              echo "Got kubeconfig"
              exit 0
            fi
            echo "Waiting for cluster kubeconfig..."
            sleep 30
          done
          echo "Timed out waiting for kubeconfig"
          exit 1

      - name: Init CAPI on remote cluster (self-managed)
        env:
          INFRA_PROVIDER: aws
        run: |
          clusterctl init \
            --kubeconfig remote.kubeconfig \
            --infrastructure ${INFRA_PROVIDER} \
            --bootstrap kubeadm \
            --control-plane kubeadm

      - name: Move management to remote cluster
        run: |
          clusterctl move --to-kubeconfig remote.kubeconfig

      - name: (Optional) Register cluster with OCM via clusteradm
        if: env.OCM_HUB_API_SERVER != ''
        env:
          HUB_API_SERVER: ${{ secrets.OCM_HUB_API_SERVER }}
          HUB_TOKEN: ${{ secrets.OCM_HUB_TOKEN }}
          CLUSTER_NAME: ${{ steps.derive.outputs.cluster_name }}
        run: |
          export KUBECONFIG=remote.kubeconfig
          clusteradm join \
            --hub-token ${HUB_TOKEN} \
            --hub-apiserver ${HUB_API_SERVER} \
            --cluster-name ${CLUSTER_NAME} \
            --capi-import \
            --capi-cluster-name ${CLUSTER_NAME} \
            --wait

      - name: Delete bootstrap cluster
        run: |
          kind delete cluster --name capi-bootstrap
```

Secrets required (examples):

OCM_HUB_API_SERVER, OCM_HUB_TOKEN for OCM hub.

Cloud provider credentials (AWS, etc.) configured via environment or provider-specific secrets (not shown here).

6. Change-only reconciliation workflow (no bootstrap)
Once a cluster is self-managed, future changes should be applied directly to it.

.github/workflows/reconcile-capi-changes.yaml:

```yaml

name: Reconcile CAPI cluster changes (no bootstrap)

on:
  push:
    branches: [ main ]
    paths:
      - "clusters/**"

jobs:
  reconcile-capi-changes:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Derive cluster path and name
        id: derive
        run: |
          CHANGED_FILE=$(git diff --name-only HEAD~1 HEAD | grep '^clusters/' | head -n1)
          CLUSTER_DIR=$(dirname "$CHANGED_FILE")
          CLUSTER_NAME=$(basename "$CLUSTER_DIR")
          echo "cluster_dir=$CLUSTER_DIR" >> $GITHUB_OUTPUT
          echo "cluster_name=$CLUSTER_NAME" >> $GITHUB_OUTPUT

      - name: Install kubectl
        run: |
          curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
          chmod +x kubectl && sudo mv kubectl /usr/local/bin/

      - name: Retrieve remote kubeconfig
        id: kubeconfig
        env:
          CLUSTER_NAME: ${{ steps.derive.outputs.cluster_name }}
        run: |
          # Example: kubeconfig stored as a GitHub secret (base64-encoded)
          echo "${REMOTE_KUBECONFIG_B64}" | base64 -d > remote.kubeconfig
        env:
          REMOTE_KUBECONFIG_B64: ${{ secrets.REMOTE_KUBECONFIG_B64_MGMT_A }} # adjust mapping per cluster

      - name: Apply updated cluster manifests to self-managed cluster
        env:
          KUBECONFIG: remote.kubeconfig
        run: |
          kubectl apply -f ${{ steps.derive.outputs.cluster_dir }}/

      - name: (Optional) Wait for reconciliation
        env:
          KUBECONFIG: remote.kubeconfig
          CLUSTER_NAME: ${{ steps.derive.outputs.cluster_name }}
        run: |
          kubectl wait --for=condition=Ready --timeout=30m \
            kubeadmcontrolplane.controlplane.cluster.x-k8s.io -l cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}

```
You can:

Use a mapping (e.g., a small JSON/YAML file) or matrix to choose the correct kubeconfig secret per cluster.

Replace the “kubeconfig from secret” step with a call to a persistent management cluster that can clusterctl get kubeconfig for workload clusters.

7. OCM hub configuration and governance
7.1 ClusterManager with feature gates
ocm/hub/clustermanager.yaml:

```yaml
apiVersion: operator.open-cluster-management.io/v1
kind: ClusterManager
metadata:
  name: cluster-manager
spec:
  registrationConfiguration:
    featureGates:
      - feature: ClusterImporter
        mode: Enable
      - feature: ManagedClusterAutoApproval
        mode: Enable
```

Apply this to the OCM hub cluster (managed separately or via GitOps).

7.2 Placement: select target clusters
ocm/hub/placements/team-a-placement.yaml:

```yaml

apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: team-a-placement
  namespace: open-cluster-management
spec:
  predicates:
    - requiredClusterSelector:
        labelSelector:
          matchLabels:
            team: team-a
```
This selects all ManagedCluster objects with team=team-a.

7.3 Policy: simple namespace label requirement
ocm/hub/policies/require-namespace-label.yaml:

```yaml

apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: require-namespace-label
  namespace: open-cluster-management
  annotations:
    policy.open-cluster-management.io/standards: "Security"
    policy.open-cluster-management.io/categories: "Best Practices"
    policy.open-cluster-management.io/controls: "Namespace Labeling"
spec:
  disabled: false
  remediationAction: enforce
  policy-templates:
    - objectDefinition:
        apiVersion: constraints.gatekeeper.sh/v1beta1
        kind: K8sRequiredLabels
        metadata:
          name: ns-must-have-owner
        spec:
          match:
            kinds:
              - apiGroups: [""]
                kinds: ["Namespace"]
          parameters:
            labels:
              - key: owner
                allowedRegex: ".+"

```

This assumes Gatekeeper is installed as an add-on in the managed clusters.

7.4 PlacementBinding: bind policy to placement
ocm/hub/policies/team-a-binding.yaml:

```yaml

apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: team-a-binding
  namespace: open-cluster-management
placementRef:
  apiGroup: cluster.open-cluster-management.io
  kind: Placement
  name: team-a-placement
subjects:
  - apiGroup: policy.open-cluster-management.io
    kind: Policy
    name: require-namespace-label
```
Governance flow:

OCM hub evaluates Placement → selects all ManagedCluster with team=team-a.

PlacementBinding ties that placement to the Policy.

OCM propagates the policy to those clusters.

The policy engine (Gatekeeper) enforces the rule in each cluster.

8. End-to-end lifecycle
Team requests a cluster

Adds clusters/teams/team-a/mgmt-a/cluster.yaml referencing ClusterClass aws-standard.

Opens a PR.

PR validation

validate-manifests.yaml (not shown) runs schema checks, optional clusterctl dry-runs.

PR merge → main

bootstrap-capi-ocm.yaml triggers on changes under clusters/**.

Bootstrap

Workflow creates kind cluster, installs CAPI, applies ClusterClass + Cluster.

CAPI in kind creates the remote cluster.

Workflow gets remote kubeconfig, installs CAPI there, and runs clusterctl move.

Optional: clusteradm join --capi-import registers the cluster with OCM.

kind cluster is deleted.

Self-managed state

Remote cluster now runs CAPI controllers and manages its own lifecycle.

It is part of the OCM fleet (if registered).

Ongoing changes

Edits to clusters/**/cluster.yaml trigger reconcile-capi-changes.yaml.

Workflow obtains kubeconfig and applies changes directly to the self-managed cluster.

CAPI reconciles topology changes (version bumps, scaling, etc.).

Fleet governance

OCM hub uses Placement + Policy + PlacementBinding to apply policies to selected clusters.

Clusters receive and enforce policies (e.g., namespace label requirements).

9. Implementation notes
Secrets and credentials

Store cloud provider credentials and OCM hub tokens in GitHub Secrets.

Store kubeconfigs for self-managed clusters as base64-encoded secrets, or derive them from a persistent management cluster.

Multiple providers

Add more ClusterClass definitions (e.g., azure-standard, gcp-standard).

Teams choose via spec.topology.class.

Management vs workload clusters

Some clusters can be “management” (hosting CAPI, OCM agents, GitOps).

Others can be “workload-only” but still registered in OCM.

Status feedback into GitHub (optional)

A small agent in each cluster can write status.yaml back into the repo via a GitHub App, making GitHub a live catalog of desired + observed state.

This file is the single reference for an agent to implement the full system: GitHub PR → CAPI lifecycle → self-managed clusters → OCM fleet governance, with separate workflows for initial bootstrap and ongoing reconciliation.

