# PDB Blocker Checker – Advanced Edition

## Overview

The **PDB Blocker Checker – Advanced Edition** is an OpenShift/Kubernetes operational utility designed to identify **Pod Disruption Budgets (PDBs)** that may block:

- Node drain operations
- Cluster upgrades
- MachineConfig updates
- Worker node maintenance
- Infrastructure lifecycle activities

The script evaluates every PDB in the cluster and calculates the effective `disruptionsAllowed` value using the same logic Kubernetes uses internally for:

- `minAvailable`
- `maxUnavailable`

It then categorizes PDBs into operational risk levels and provides detailed visibility into:

- Protected workloads
- Matching pods
- Pod locations
- Node impact
- Drain blockers
- High availability posture

---

# Features

## Accurate PDB Calculations

Supports both PDB models:

### minAvailable

```yaml
spec:
  minAvailable: 2
```

Calculation:

```text
disruptionsAllowed = currentHealthy - minAvailable
```

### maxUnavailable

```yaml
spec:
  maxUnavailable: 1
```

Calculation:

```text
disruptionsAllowed =
maxUnavailable - (expectedPods - currentHealthy)
```

---

## Risk Classification

| Status | Meaning |
|----------|----------|
| BLOCKED | disruptionsAllowed = 0 |
| LOW-HA | Less than 30% disruption capacity |
| SAFE | At least 30% disruption capacity |
| FULL-OUTAGE | 100% disruption allowed |

Color-coded output is provided for easy operational review.

---

## Namespace Filtering

Display PDBs only within a specific namespace.

Example:

```bash
./pdb_blocker_check.sh --namespace=myproject
```

---

## PDB Name Filtering

Search for a specific PDB by name.

Example:

```bash
./pdb_blocker_check.sh --pdb=web
```

---

## Node-Aware Analysis

Show all PDBs belonging to namespaces that have workloads running on a specific node.

Useful before:

- Node drains
- Worker replacement
- Maintenance windows
- Infrastructure migrations

Example:

```bash
./pdb_blocker_check.sh --node=worker-1
```

The report highlights:

```text
★ ON NODE
```

for pods currently running on the target node.

---

## Blocked-Only Mode

Display only PDBs that will prevent pod eviction.

Example:

```bash
./pdb_blocker_check.sh --blocked-only
```

---

## OpenShift System Namespace Exclusion

By default, namespaces beginning with:

```text
openshift*
```

are excluded.

To include them:

```bash
./pdb_blocker_check.sh --include-system
```

---

# Requirements

## OpenShift CLI

The script requires:

```bash
oc
```

Verify:

```bash
oc version
```

---

## jq

The script uses jq for JSON parsing.

Verify:

```bash
jq --version
```

Install:

### RHEL / CentOS

```bash
sudo yum install jq
```

### RHEL 8/9

```bash
sudo dnf install jq
```

### macOS

```bash
brew install jq
```

---

## Cluster Access

User must be authenticated:

```bash
oc login
```

Verify:

```bash
oc whoami
```

---

# Usage

## Display All Non-System PDBs

```bash
./pdb_blocker_check.sh
```

---

## Display PDBs for a Namespace

```bash
./pdb_blocker_check.sh \
  --namespace=my-app
```

---

## Search by PDB Name

```bash
./pdb_blocker_check.sh \
  --pdb=frontend
```

---

## Show Only Blockers

```bash
./pdb_blocker_check.sh \
  --blocked-only
```

---

## Analyze a Node

```bash
./pdb_blocker_check.sh \
  --node=worker-0
```

---

## Include OpenShift Namespaces

```bash
./pdb_blocker_check.sh \
  --include-system
```

---

## Combine Filters

```bash
./pdb_blocker_check.sh \
  --node=worker-0 \
  --blocked-only
```

---

# Sample Output

```text
[BLOCKED]

NAMESPACE: payments
PDB: payment-api

TYPE                 minAvailable
EXPECTED             3
HEALTHY              2
DISRUPTIONS          0

Selector:
app=payment-api

Pod count:
3 pod(s) matched

POD NAME                     NODE
payment-api-1                worker-0
payment-api-2                worker-1
payment-api-3                worker-2

Calculation:

disruptionsAllowed =
currentHealthy(2) -
minAvailable(2)
= 0

→ disruptionsAllowed = 0
→ this PDB will BLOCK maintenance / node drain
```

---

# Understanding the Results

## BLOCKED

```text
disruptionsAllowed = 0
```

Meaning:

- Node drain will fail
- Pod eviction is blocked
- Maintenance may be prevented

Example:

```yaml
replicas: 2

minAvailable: 2
```

Result:

```text
Healthy = 2
Disruptions Allowed = 0
```

---

## LOW-HA

```text
0 < disruptionsAllowed < 30%
```

Meaning:

- Evictions are possible
- Limited disruption capacity
- Maintenance carries elevated risk

---

## SAFE

```text
disruptionsAllowed >= 30%
```

Meaning:

- Reasonable HA posture
- Maintenance can proceed safely

---

## FULL-OUTAGE

```text
100% disruptions allowed
```

Meaning:

- Entire workload may be evicted
- Potential service downtime
- Review workload resilience

---

# Node Drain Validation Workflow

Before draining a node:

```bash
./pdb_blocker_check.sh \
  --node=<worker-node>
```

Review:

```text
[BLOCKED]
```

entries.

If any are present:

- Node drain may fail
- Upgrade may pause
- MachineConfig rollout may stall

Remediate the PDB before proceeding.

---

# Exit Conditions

The script exits when:

## Missing OpenShift CLI

```text
Error: 'oc' not found
```

---

## Missing jq

```text
Error: 'jq' not found
```

---

## Not Logged In

```text
Error: Not logged into OpenShift
```

---

## Invalid Arguments

```text
Unknown argument
```

---

# Operational Use Cases

## Cluster Upgrades

Identify workloads that may block:

```bash
oc adm upgrade
```

---

## Worker Node Maintenance

Validate drain readiness before:

```bash
oc adm drain
```

---

## MachineConfig Updates

Detect PDBs that can prevent node reboots.

---

## Capacity Planning

Identify applications with:

- Excessively strict PDBs
- Insufficient disruption capacity
- Poor HA configuration

---

## Application Readiness Reviews

Verify workload resiliency across namespaces.

---

# Author Notes

This utility is intended for OpenShift administrators, SREs, and platform engineers who need rapid visibility into Pod Disruption Budget behavior and maintenance impact.

The disruption calculations are derived from Kubernetes PDB evaluation logic and are intended to closely reflect actual eviction behavior observed during node drains and cluster operations.
