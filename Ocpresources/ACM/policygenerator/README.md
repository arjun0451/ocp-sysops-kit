# ACM PolicyGenerator SOP

## 1. Purpose

This SOP describes how to use the **RHACM PolicyGenerator CLI** to generate ACM governance policies from Kubernetes manifests.

The approach separates:

* **PolicyGenerator template** — defines how policies are generated.
* **Manifest** — defines the Kubernetes object to be enforced.
* **Generated policy** — output consumed by ACM.
* **Placement** — existing ACM Placement used to determine target clusters.

---

## 2. Recommended Directory Structure

Use one directory per policy scenario.

```text
acm-policies/
├── policygen/
│   ├── template.yaml
│   ├── node-alerts.yaml
│   ├── storage-alerts.yaml
│   └── security-alerts.yaml
│
├── manifests/
│   ├── node-alerts/
│   │   ├── node-cpu.yaml
│   │   ├── node-memory.yaml
│   │   └── node-filesystem.yaml
│   │
│   ├── storage-alerts/
│   │   └── pvc-usage.yaml
│   │
│   └── security/
│       └── ...
│
├── generated/
│   ├── node-alerts-policy.yaml
│   ├── storage-alerts-policy.yaml
│   └── security-policy.yaml
│
└── README.md
```

A simpler structure can also be used for a small repository:

```text
acm-policies/
├── policygen/
│   └── template.yaml
├── manifests/
│   ├── node-cpu.yaml
│   ├── node-memory.yaml
│   ├── node-filesystem.yaml
│   └── pvc-usage.yaml
└── generated/
    └── custom-alert-policies.yaml
```

---

# 3. Prerequisites

The following are required:

* RHACM Hub cluster access
* `oc` CLI
* PolicyGenerator CLI
* Access to the ACM namespace, for example:

```bash
oc project ocp-policies
```

Verify the PolicyGenerator:

```bash
./PolicyGenerator --help
```

Verify cluster access:

```bash
oc whoami
oc get managedclusters
```

---

# 4. ACM Placement

Policies need to be associated with clusters through an ACM `Placement`.

For production, it is preferable to **reuse an existing Placement** rather than generating a new Placement for every policy.

Example existing Placement:

```text
policy-namespace-placement
```

Check it:

```bash
oc get placement -A
```

Example:

```bash
oc get placement policy-namespace-placement -n ocp-policies -o yaml
```

The Placement should already select the intended managed clusters or ManagedClusterSet.

---

# 5. PolicyGenerator Template

Create:

```text
policygen/template.yaml
```

Example production-oriented template:

```yaml
apiVersion: policy.open-cluster-management.io/v1
kind: PolicyGenerator

metadata:
  name: custom-alert-policies

policyDefaults:
  namespace: ocp-policies

  severity: low
  remediationAction: inform
  complianceType: musthave
  disabled: false

  # Prevent ACM ConfigurationPolicy from interpreting
  # Prometheus template variables such as {{ $labels.* }}
  configurationPolicyAnnotations:
    policy.open-cluster-management.io/disable-templates: "true"

  # Reuse an existing ACM Placement
  placement:
    placementName: policy-namespace-placement

policies:
  - name: custom-alertingrules
    description: Custom monitoring alerting rules
    manifests:
      - path: ../manifests/
```

> **Important:** `disable-templates: "true"` is particularly important when the Kubernetes manifest contains Prometheus expressions such as `{{ $labels.instance }}` or `{{ $value }}`. Without it, ACM ConfigurationPolicy templating can interpret these variables and produce errors such as `undefined variable "$labels"`.

---

# 6. Kubernetes Manifest

The Kubernetes object being managed should remain a normal Kubernetes manifest.

For example:

```text
manifests/node-filesystem.yaml
```

```yaml
apiVersion: monitoring.openshift.io/v1
kind: AlertingRule
metadata:
  name: psa-node-filesystem-high-usage
  namespace: openshift-monitoring
spec:
  groups:
    - name: psa-node-filesystem-usage
      rules:
        - alert: NodeFilesystemHighUsage
          annotations:
            description: |
              Filesystem on device {{ $labels.device }},
              mounted at {{ $labels.mountpoint }} on node {{ $labels.instance }},
              has less than 20% free space remaining.

              Current available space: {{ printf "%.2f" $value }}%.

            summary: Node filesystem usage above 80%

          expr: |
            (
              node_filesystem_avail_bytes{
                fstype!="",
                job="node-exporter",
                mountpoint!~"/var/lib/ibmc-s3fs.*"
              }
              /
              node_filesystem_size_bytes{
                fstype!="",
                job="node-exporter",
                mountpoint!~"/var/lib/ibmc-s3fs.*"
              }
              * 100 < 90
            )
            and
            node_filesystem_readonly{
              fstype!="",
              job="node-exporter",
              mountpoint!~"/var/lib/ibmc-s3fs.*"
            } == 0

          for: 1m

          labels:
            platform: infrastructure
            severity: critical
```

The manifest remains independent from ACM.

---

# 7. Multiple Manifests

Multiple Kubernetes objects can be placed in the manifest directory:

```text
manifests/
├── node-cpu.yaml
├── node-memory.yaml
├── node-filesystem.yaml
└── pvc-usage.yaml
```

For example:

### `node-cpu.yaml`

```yaml
apiVersion: monitoring.openshift.io/v1
kind: AlertingRule
metadata:
  name: psa-high-node-cpu-usage-alert
  namespace: openshift-monitoring
spec:
  groups:
    - name: psa-high-node-cpu-usage-alert
      rules:
        - alert: HighNodeCpuUsageAlert
          expr: |
            100 - (
              avg by (instance)
              (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100
            ) > 85
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: High CPU usage on node
            description: |
              {{ $labels.instance }} is higher than 85% CPU usage.
              Current usage: {{ $value }}%
```

### `node-memory.yaml`

```yaml
apiVersion: monitoring.openshift.io/v1
kind: AlertingRule
metadata:
  name: psa-high-node-memory-usage-alert
  namespace: openshift-monitoring
spec:
  groups:
    - name: psa-high-node-memory-usage-alert
      rules:
        - alert: HighNodeMemoryUsageAlert
          expr: |
            (
              1 -
              (
                sum by (instance) (
                  node_memory_MemFree_bytes
                  + node_memory_Buffers_bytes
                  + node_memory_Cached_bytes
                )
                /
                sum by (instance) (
                  node_memory_MemTotal_bytes
                )
              )
            ) * 100 > 85
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: High memory usage on node
            description: |
              Node {{ $labels.instance }} has sustained high memory usage.
              Current usage: {{ $value }}%
```

### `pvc-usage.yaml`

```yaml
apiVersion: monitoring.openshift.io/v1
kind: AlertingRule
metadata:
  name: custom-pvc-usage-high
  namespace: openshift-monitoring
spec:
  groups:
    - name: custom-pvc-usage-alerts
      rules:
        - alert: HighPVCUsage
          expr: |
            (
              kubelet_volume_stats_used_bytes
              /
              kubelet_volume_stats_capacity_bytes
            ) * 100 > 80
          for: 60m
          labels:
            severity: critical
          annotations:
            summary: PVC usage above 80%
            description: |
              PVC {{ $labels.persistentvolumeclaim }}
              in namespace {{ $labels.namespace }}
              is using more than 80% of its capacity.
              Current usage: {{ $value }}%
```

---

# 8. Generate the ACM Policy

From the repository root:

```bash
./PolicyGenerator policygen/template.yaml
```

If the generator supports output redirection:

```bash
./PolicyGenerator policygen/template.yaml > generated/custom-alertingrules-policy.yaml
```

The generated output should contain:

```text
Policy
PlacementBinding
```

Because the template uses:

```yaml
placement:
  placementName: policy-namespace-placement
```

the generator references the existing Placement rather than creating a new Placement.

---

# 9. Validate the Generated YAML

Before applying it to the Hub, validate the YAML:

```bash
oc apply --dry-run=server \
  -f generated/custom-alertingrules-policy.yaml
```

If the generated file contains multiple YAML documents, `oc` processes them all.

You can also inspect:

```bash
cat generated/custom-alertingrules-policy.yaml
```

Verify that the generated `PlacementBinding` contains:

```yaml
placementRef:
  apiGroup: cluster.open-cluster-management.io
  kind: Placement
  name: policy-namespace-placement
```

---

# 10. Apply the Policy to ACM Hub

Apply the generated policy:

```bash
oc apply -f generated/custom-alertingrules-policy.yaml
```

Verify:

```bash
oc get policy -n ocp-policies
```

Check the policy:

```bash
oc get policy custom-alertingrules \
  -n ocp-policies \
  -o yaml
```

Check the PlacementBinding:

```bash
oc get placementbinding -n ocp-policies
```

---

# 11. Verify Policy Status

Check policy compliance:

```bash
oc get policy -n ocp-policies
```

Example:

```text
NAME                    REMEDIATION ACTION   COMPLIANCE STATE
custom-alertingrules    inform               Compliant
```

For detailed information:

```bash
oc describe policy custom-alertingrules -n ocp-policies
```

---

# 12. Verify on the Managed Cluster

Once ACM distributes the policy, check the managed cluster.

For example:

```bash
oc get alertingrule -n openshift-monitoring
```

Verify the alert:

```bash
oc get alertingrule psa-node-filesystem-high-usage \
  -n openshift-monitoring \
  -o yaml
```

You should see:

```yaml
metadata:
  name: psa-node-filesystem-high-usage
```

and the corresponding Prometheus rule.

---

# 13. Policy Lifecycle

The overall workflow is:

```text
Kubernetes Manifest
        │
        ▼
manifests/
        │
        ▼
PolicyGenerator template
        │
        ▼
PolicyGenerator CLI
        │
        ▼
Generated ACM Policy
        │
        ├── Policy
        │
        └── PlacementBinding
                │
                ▼
     Existing ACM Placement
                │
                ▼
        Managed Clusters
                │
                ▼
      ConfigurationPolicy
                │
                ▼
       Kubernetes Object
```

---

# 14. Adding a New Policy Scenario

For a new requirement, follow these steps.

### Step 1 — Create the Kubernetes manifest

Example:

```text
manifests/security/
└── example.yaml
```

### Step 2 — Test the manifest directly

```bash
oc apply --dry-run=server -f manifests/security/example.yaml
```

### Step 3 — Add the manifest path to PolicyGenerator

```yaml
policies:
  - name: security-policy
    description: Security configuration policy
    manifests:
      - path: ../manifests/security/
```

### Step 4 — Generate

```bash
./PolicyGenerator policygen/template.yaml \
  > generated/security-policy.yaml
```

### Step 5 — Validate

```bash
oc apply --dry-run=server \
  -f generated/security-policy.yaml
```

### Step 6 — Apply

```bash
oc apply -f generated/security-policy.yaml
```

### Step 7 — Verify

```bash
oc get policy -n ocp-policies
```

---

# 15. Recommended Repository Model

For multiple policy types, keep **manifests and policy generation configuration separate**:

```text
acm-policies/
│
├── policygen/
│   ├── monitoring.yaml
│   ├── security.yaml
│   ├── storage.yaml
│   └── operators.yaml
│
├── manifests/
│   ├── monitoring/
│   │   ├── node-cpu.yaml
│   │   ├── node-memory.yaml
│   │   ├── node-filesystem.yaml
│   │   └── pvc-usage.yaml
│   │
│   ├── security/
│   │   └── ...
│   │
│   ├── storage/
│   │   └── ...
│   │
│   └── operators/
│       └── ...
│
└── generated/
    ├── monitoring-policy.yaml
    ├── security-policy.yaml
    ├── storage-policy.yaml
    └── operators-policy.yaml
```

This makes it easy to add new policy scenarios without modifying existing manifests.

---

# 16. Important Configuration

For Prometheus/AlertingRule manifests containing:

```text
{{ $labels.instance }}
{{ $labels.namespace }}
{{ $labels.device }}
{{ $value }}
```

keep this in the PolicyGenerator:

```yaml
configurationPolicyAnnotations:
  policy.open-cluster-management.io/disable-templates: "true"
```

Otherwise ACM may try to process the Prometheus variables as ACM policy templates.

For your existing setup, the important part of the generator is therefore:

```yaml
policyDefaults:
  namespace: ocp-policies

  severity: low
  remediationAction: inform
  complianceType: musthave
  disabled: false

  configurationPolicyAnnotations:
    policy.open-cluster-management.io/disable-templates: "true"

  placement:
    placementName: policy-namespace-placement
```

This is the core pattern you were using in January, and **yes, your approach is conceptually correct**: keep the AlertingRule as a normal manifest, let PolicyGenerator wrap it into a ConfigurationPolicy, reuse the existing ACM Placement, and apply the generated Policy/PlacementBinding to the Hub.

