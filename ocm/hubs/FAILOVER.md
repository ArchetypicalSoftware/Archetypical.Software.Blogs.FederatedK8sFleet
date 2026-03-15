# OCM Hub Failover Procedures

## Overview

This document describes the manual failover process from the primary OCM hub to the secondary hub in production. This is a **manual, intentional operation** that should only be performed when the primary hub is unhealthy or undergoing maintenance.

**Active-Passive Model:**
- **Primary Hub** (`production-hub-primary` in `us-east-1`): Actively manages all workload clusters
- **Secondary Hub** (`production-hub-secondary` in `eu-west-1`): Standby, not managing clusters until failover

## Prerequisites

Before performing failover, ensure:

1. ✓ Both hubs are deployed and healthy
2. ✓ Network connectivity between hubs is available
3. ✓ GitHub credentials are available for updating hub topology
4. ✓ Access to kubeconfigs for both hub clusters
5. ✓ Scheduled maintenance window announced to users (if possible)
6. ✓ Backup of current ManagedClusterSet state taken

## Detection: Is Primary Hub Unhealthy?

### Health Check Procedure

Run these checks against `production-hub-primary`:

```bash
# Set context to primary hub
kubectl config use-context production-primary

# Check hub components
kubectl get deployment -n open-cluster-management -o wide
kubectl get deployment -n open-cluster-management-hub -o wide

# Check hub readiness
kubectl get clusteroperation -A
kubectl get multiclusterhubs

# Check managed cluster registration
kubectl get managedcluster -o wide

# Check OCM controller logs
kubectl logs -n open-cluster-management -l app=cluster-manager --tail=50
kubectl logs -n open-cluster-management -l app=registration-controller --tail=50
```

### Unhealthy Indicators

Primary hub is **unhealthy** if any of these conditions persist for >15 minutes:

- OCM hub ClusterManager pod is not Running
- cluster-manager deployment replicas != desired
- registration-controller pod is not Running
- ManagedCluster registration is failing (status.conditions show persistent errors)
- No kubeconfig available from primary hub bootstrap token
- API server is unreachable

### Decision Point

**If unhealthy:**
1. Attempt primary hub recovery (see [Recovery Options](#recovery-options))
2. If recovery fails, proceed with failover

**If healthy:**
1. Do NOT perform failover
2. Return to operations

## Pre-Failover: Prepare Secondary Hub

### 1. Verify Secondary Hub Health

```bash
# Set context to secondary hub
kubectl config use-context production-secondary

# Verify hub is initialized and ready
kubectl get clusteroperation -A
kubectl get multiclusterhubs -o yaml

# Verify secondary has 0 managed clusters (should be empty)
kubectl get managedcluster
# Expected: No resources found in default namespace
```

### 2. Verify Secondary Hub Bootstrap Token

```bash
# Check bootstrap secret exists
kubectl get secret bootstrap-hub-token -n open-cluster-management

# If missing, generate new token (see Recovery Options)
```

### 3. Test Network Connectivity

Secondary hub must be able to reach all workload clusters:

```bash
# Get list of all workload clusters
kubectl config use-context production-primary
workload_clusters=$(kubectl get managedcluster -o jsonpath='{.items[*].metadata.name}')

# For each cluster, verify API server is reachable from secondary hub node
kubectl config use-context production-secondary
for cluster in $workload_clusters; do
  echo "Testing connectivity to $cluster..."
  # This would be custom based on cluster network config
done
```

## Failover Procedure

### Step 1: Drain Primary Hub (if possible)

If primary hub is partially healthy, gracefully drain workload cluster management:

```bash
# Connect to primary hub
kubectl config use-context production-primary

# Cordon primary hub - prevent new cluster registrations
kubectl patch clusteroperation -A --type merge -p '{"spec":{"suspended": true}}'

# Give time for in-flight operations to complete
sleep 300

# Get current ManagedClusterSet assignment
kubectl get managedclusterset production -o yaml > /tmp/mcs-backup.yaml
```

### Step 2: Update ManagedClusterSet Hub Assignment

Update hub topology configuration to point workload clusters to secondary hub:

```bash
# Edit ocm/hubs/hub-topology.yaml
# Change all workload cluster entries from:
#   ocm_hub: production-primary
# To:
#   ocm_hub: production-secondary

# Or using kubectl:
kubectl config use-context production-primary
kubectl patch managedclusterset production -p '{
  "spec": {
    "clusterSelector": {
      "matchLabels": {
        "ocm-hub": "production-secondary"
      }
    }
  }
}' --type merge
```

**Alternative: GitOps Update**

Create PR to update hub topology:

```yaml
# ocm/hubs/hub-topology.yaml - Update this section:
workload_clusters:
  - name: cluster-1
    domain: platform
    ocm_hub: production-secondary  # Changed from production-primary
```

### Step 3: Verify Cluster Re-registration

Monitor workload cluster re-registration with secondary hub:

```bash
# Set context to secondary hub
kubectl config use-context production-secondary

# Watch for managed clusters to appear
kubectl get managedcluster --watch

# Expected: All workload clusters should appear within 5-10 minutes

# Verify cluster health
kubectl get managedcluster -o wide

# Check cluster status details
for cluster in $(kubectl get managedcluster -o name); do
  echo "=== $cluster ==="
  kubectl describe $cluster
done
```

### Step 4: Verify Workload Cluster Connectivity

On each workload cluster, verify OCM agent can reach secondary hub:

```bash
# On workload cluster
kubectl get managedcluster --context=<workload-cluster-context> \
  -n open-cluster-management-agent -o yaml

# Check for conditions indicating hub connectivity
# Example output should show ManagedClusterConditionAvailable = True

# View agent logs
kubectl logs -n open-cluster-management-agent -l app=klusterlet --tail=50
```

### Step 5: Verify All Workloads Still Running

On each workload cluster, verify Kubernetes workloads are unaffected:

```bash
# Check node status
kubectl get nodes

# Check pod status
kubectl get pods -A --field-selector=status.phase!=Running

# Check for pod evictions
kubectl get events -A --sort-by='.lastTimestamp' | tail -20
```

## Post-Failover: Validation

### Checklist

- [ ] Secondary hub has all expected managed clusters
- [ ] All ManagedCluster resources show `status.conditions.ManagedClusterConditionAvailable = True`
- [ ] All workload cluster nodes are Ready
- [ ] All workload cluster system pods are Running
- [ ] No pod evictions or restarts due to hub disconnect
- [ ] Flux synchronization is working (`flux get all --contexts=<workload-cluster>`
- [ ] Cluster API controllers are functional on hub
- [ ] No errors in OCM hub logs

### Monitoring Commands

```bash
# Overall cluster health across fleet
for cluster in $(kubectl get managedcluster -o name --context=production-secondary); do
  echo "Checking $cluster..."
  kubectl get nodes --context=$cluster --no-headers | awk '{print $1, $2}'
done

# Hub component status
kubectl get deployment -n open-cluster-management-hub --context=production-secondary

# Check for any failed operations
kubectl get clusteroperation --context=production-secondary -A
```

## Recovery: Bring Primary Hub Back Online

### If Primary Hub Recovers

Once the primary hub is healthy again:

```bash
# 1. Verify primary hub health
kubectl config use-context production-primary
kubectl get deployment -n open-cluster-management-hub -o wide

# 2. Wait for bootstrap token to regenerate
kubectl get secret bootstrap-hub-token -n open-cluster-management

# 3. Gradually re-register clusters back to primary
# Update ocm/hubs/hub-topology.yaml to change clusters back:
#   ocm_hub: production-primary

# 4. Monitor re-registration
kubectl config use-context production-primary
kubectl get managedcluster --watch

# 5. Once all clusters are re-registered, verify they're healthy
kubectl get managedcluster -o wide
```

### If Primary Hub Cannot Be Recovered

**Permanent Failover to Secondary Hub:**

```bash
# Keep workload clusters on secondary hub
# Update bootstrap tokens in GitHub Secrets:
PRODUCTION_OCM_HUB_BOOTSTRAP_TOKEN -> <secondary-hub-token>
PRODUCTION_OCM_HUB_API_URL -> <secondary-hub-api>
PRODUCTION_OCM_HUB_CA_CERT -> <secondary-hub-ca>

# Decommission primary hub
kubectl delete cluster production-hub-primary --namespace=default

# Update documentation: production-hub-secondary is now PRIMARY
# Update README.md, copilot-instructions.md with new topology

# Create GitHub issue to discuss permanent hub configuration
```

## Recovery Options

### Option 1: Restart OCM Hub Components

```bash
kubectl config use-context production-primary

# Restart cluster-manager operator
kubectl rollout restart deployment cluster-manager \
  -n open-cluster-management-hub

# Wait for rollout
kubectl rollout status deployment cluster-manager \
  -n open-cluster-management-hub --timeout=5m
```

### Option 2: Regenerate Bootstrap Token

If bootstrap token expires or is corrupted:

```bash
kubectl config use-context production-primary

# Get CSR signing key
secret_name=$(kubectl get secret -n open-cluster-management \
  -l app.kubernetes.io/name=registration-webhook \
  -o jsonpath='{.items[0].metadata.name}')

# Generate new token
token=$(kubectl get secret bootstrap-hub-token -n open-cluster-management \
  -o jsonpath='{.data.token}' | base64 -d)

# Use clusteradm to get new token
clusteradm get token --hub-kubeconfig=<primary-kubeconfig> \
  --output=<output-path>
```

### Option 3: Full Hub Disaster Recovery

If primary hub is completely lost:

```bash
# From GitHub Actions, trigger bootstrap-ocm-hub workflow:
# Input: clusters/production/management/aws/us-east-1/production-hub-primary/cluster.yaml
# This will:
# 1. Recreate the cluster
# 2. Initialize OCM hub components
# 3. Extract and store new bootstrap token
# 4. Workload clusters can re-register with new hub

# Then follow "Bring Primary Hub Back Online" steps above
```

## Communication & Runbook

### During Failover

1. **Announce in Status Page:** "Unplanned hub maintenance in progress"
2. **Notify Teams:** Ping #fleet-management Slack channel
3. **Run Validation:** Execute post-failover checklist every 5 minutes
4. **Update Issue:** Create GitHub issue documenting failover event with root cause

### Post-Failover

1. **Incident Postmortem:** Within 24 hours, create postmortem documenting:
   - Root cause of primary hub failure
   - Detection time and failover duration
   - Impact on workload clusters
   - Recovery steps taken
   - Preventive measures for future

2. **Update Documentation:**
   - Update this FAILOVER.md with lessons learned
   - Update cluster runbook with any new procedures
   - Update disaster recovery plan

3. **Example Postmortem PR:**
   ```
   Title: Postmortem: OCM Hub Failover on [DATE]
   
   Root Cause: [What caused the failure]
   Detection: [How we discovered it]
   Timeline: [What happened when]
   Impact: [Which clusters affected, for how long]
   Resolution: [What fixed it]
   Prevention: [What we'll do differently]
   ```

## Runbook Command Reference

### Quick Failover (Minimal Checks)

For experienced operators in an emergency:

```bash
# 1. Verify secondary hub is responsive
kubectl cluster-info --context=production-secondary

# 2. Update hub topology (GitHub UI or CLI)
# Change all workload clusters to: ocm_hub: production-secondary

# 3. Wait 10 minutes for re-registration
sleep 600

# 4. Spot check a few clusters
kubectl get managedcluster \
  --context=production-secondary --no-headers | head -5

# If all show "True" in last column, failover succeeded
```

### Full Failover (With Validation)

```bash
# See "Failover Procedure" section above for complete steps
```

## Rollback: Return to Primary Hub

Once primary hub is confirmed healthy and all clusters have been migrated to secondary:

```bash
# 1. Prepare primary hub
kubectl config use-context production-primary
kubectl get clusteroperation  # Should be empty or recovering

# 2. Gradually migrate clusters back
# Update ocm/hubs/hub-topology.yaml:
#   ocm_hub: production-primary

# 3. Monitor primary hub population
kubectl get managedcluster --watch

# 4. Verify cluster health on primary
for cluster in $(kubectl get managedcluster -o name); do
  echo "=== $cluster ==="
  kubectl get $cluster -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")]}'
done

# 5. Once all healthy, deregister from secondary
kubectl config use-context production-secondary
kubectl delete managedcluster --all  # Or selective deletion

# 6. Verify secondary is empty
kubectl get managedcluster  # Should be empty
```

## Failure Scenarios & Mitigations

| Scenario | Detection | Mitigation |
|----------|-----------|-----------|
| Primary hub API unreachable | `kubectl cluster-info` fails | Initiate failover immediately |
| Partial primary hub failure (some components down) | Some deployments NotReady | Attempt restart; if fails after 15min, failover |
| Secondary hub unreachable during failover | Re-registration timeouts | Check network; retry; if persists >30min, escalate |
| Managed clusters cannot reach secondary hub | ManagedCluster status shows "Unknown" | Check workload cluster OCM agent logs; verify network; retry registration |
| Hub bootstrap token expired | Registration rejected with "invalid token" | Generate new token on secondary hub; update GitHub Secrets |
| Duplicate cluster registration (registered to both hubs) | `kubectl get managedcluster` shows duplicate entries | Delete managed cluster on primary; let secondary be source of truth |

## Escalation

If failover is stuck or incomplete:

1. **Level 1:** Platform team - attempt recovery procedures
2. **Level 2:** OCM upstream support - check OCM documentation and issues
3. **Level 3:** Cluster API provider support - check provider-specific errors
4. **Level 4:** Manual intervention - manually update cluster kubeconfigs to point to secondary hub

## Related Documentation

- [copilot-instructions.md](../copilot-instructions.md) - Hub topology configuration
- [README.md](../../README.md) - Multi-hub architecture overview
- [bootstrap-ocm-hub.yaml](../.github/workflows/bootstrap-ocm-hub.yaml) - Hub provisioning workflow
