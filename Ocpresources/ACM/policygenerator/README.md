
````markdown
# ACM PolicyGenerator Setup and Execution

## 1. First-Time ACM Hub Setup

The following steps are required when setting up the ACM PolicyGenerator workflow for the first time.

The purpose of this setup is to:

- Access the RHACM console.
- Identify the ACM Hub cluster.
- Bind the policy namespace to the appropriate ManagedClusterSet.
- Use an existing ACM Placement for policy targeting.
- Allow generated policies to be distributed to the required managed clusters.

---

## 1.1 Log in to the RHOCP Hub Cluster

1. Open a web browser and access the OpenShift Container Platform console:

   `https://console-openshift-console.apps.ocp4.example.com`

2. Select the **Red Hat Identity Management** identity provider.

3. Log in using the authorized administrative account.

   > Do not store passwords or other credentials in this SOP or Git repository.

4. After login, verify that you are connected to the **RHOCP Hub cluster**.

5. At the top of the OpenShift console, set the cluster switcher to:

   **All Clusters**

6. The RHACM console should now be available.

---

## 1.2 Bind the Policy Namespace to the ManagedClusterSet

The namespace containing ACM policies must be associated with the appropriate ManagedClusterSet.

For this example:

```text
Policy Namespace : policies-developer
ManagedClusterSet : default
````

### Using the RHACM Console

1. In the RHACM console, go to:

   **Infrastructure → Clusters**

2. Select:

   **Cluster sets**

3. Select the required ManagedClusterSet:

   ```text
   default
   ```

4. Click the **pencil / Edit** icon to edit the namespace bindings.

5. In the **Namespaces** drop-down list, select:

   ```text
   policies-developer
   ```

6. Click **Save**.

The relationship should now be:

```text
ManagedClusterSet
       │
       ▼
    default
       │
       │ Namespace Binding
       ▼
policies-developer
```

> For production environments, use the organization's approved ManagedClusterSet instead of `default`.

---

## 1.3 Verify the Namespace Binding

The namespace binding can be verified from the Hub cluster.

```bash
oc get managedclusterset
```

Check the namespace:

```bash
oc get namespace policies-developer
```

The namespace should exist before policies are generated and applied.

---

# 2. ACM Policy Targeting

After the namespace is associated with the ManagedClusterSet, identify the Placement that will determine which managed clusters receive the policy.

Example existing Placement:

```text
policy-namespace-placement
```

Verify the Placement:

```bash
oc get placement -A
```

For example:

```bash
oc get placement policy-namespace-placement \
  -n policies-developer
```

The policy workflow is:

```text
Policy
   │
   ▼
PlacementBinding
   │
   ▼
Existing Placement
   │
   ▼
ManagedClusterSet
   │
   ▼
Managed Clusters
```

The PolicyGenerator can reference the existing Placement instead of generating a new Placement.

Example:

```yaml
policyDefaults:
  placement:
    placementName: policy-namespace-placement
```

---

# 3. PolicyGenerator Git Repository

After the initial ACM setup, maintain the Kubernetes manifests and PolicyGenerator configuration in Git.

Recommended structure:

```text
acm-policies/
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
│   └── storage/
│       └── ...
│
├── policygen/
│   └── template.yaml
│
└── generated/
    └── monitoring-policy.yaml
```

---

# 4. PolicyGenerator Flow

The overall workflow is:

```text
┌─────────────────────────────────────────────────────────────────────┐
│                         Git Repository                              │
│                                                                     │
│  manifests/                         policygen/                      │
│  ├── node-cpu.yaml                  └── template.yaml               │
│  ├── node-memory.yaml                                               │
│  ├── node-filesystem.yaml                                           │
│  └── pvc-usage.yaml                                                 │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               │ Source
                               ▼
                    ┌──────────────────────┐
                    │ PolicyGenerator CLI  │
                    └──────────┬───────────┘
                               │
                               │ Generate
                               ▼
                    ┌──────────────────────┐
                    │ Generated ACM Policy │
                    │                      │
                    │ Policy               │
                    │ ConfigurationPolicy  │
                    │ PlacementBinding     │
                    └──────────┬───────────┘
                               │
                               │ oc apply
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         ACM HUB CLUSTER                             │
│                                                                     │
│                    ACM Governance                                  │
│                         │                                           │
│              ┌──────────┴──────────┐                                │
│              │                     │                                │
│              ▼                     ▼                                │
│     ConfigurationPolicy     PlacementBinding                        │
│                                    │                                │
│                                    ▼                                │
│                        Existing Placement                            │
│                                    │                                │
│                                    ▼                                │
│                         ManagedClusterSet                            │
└────────────────────────────┬────────────────────────────────────────┘
                             │
                             │ Policy distribution
                             ▼
              ┌──────────────────────────────┐
              │       Managed Clusters       │
              │                              │
              │  Cluster 1                   │
              │  Cluster 2                   │
              │  Cluster 3                   │
              │  ...                         │
              └──────────────┬───────────────┘
                             │
                             │ ConfigurationPolicy
                             ▼
                  ┌───────────────────────┐
                  │   AlertingRule        │
                  │                       │
                  │ openshift-monitoring  │
                  └───────────┬───────────┘
                              │
                              ▼
                    OpenShift Monitoring
                              │
                 ┌────────────┴────────────┐
                 ▼                         ▼
             Prometheus              Alertmanager
                 │                         │
                 └────────────┬────────────┘
                              ▼
                         Alert / Notification
```

---

# 5. PolicyGenerator Configuration

Example:

```yaml
apiVersion: policy.open-cluster-management.io/v1
kind: PolicyGenerator

metadata:
  name: custom-monitoring-policies

policyDefaults:
  namespace: policies-developer

  severity: low
  remediationAction: inform
  complianceType: musthave
  disabled: false

  configurationPolicyAnnotations:
    policy.open-cluster-management.io/disable-templates: "true"
#if we have existing placement we can use the placment section ,else create empty policy and map the placment from GUI
  placement:
    placementName: policy-namespace-placement

policies:
  - name: custom-alertingrules
    description: Custom OpenShift monitoring alerting rules

    manifests:
      - path: ../manifests/monitoring/
```

---

# 6. Add Kubernetes Manifests

Place the Kubernetes resources that should be managed by ACM under the appropriate manifest directory.

Example:

```text
manifests/monitoring/
├── node-cpu.yaml
├── node-memory.yaml
├── node-filesystem.yaml
└── pvc-usage.yaml
```

These are normal Kubernetes/OpenShift manifests.

For example:

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
              avg by (instance) (
                rate(node_cpu_seconds_total{mode="idle"}[5m])
              ) * 100
            ) > 85
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: High CPU usage on node
            description: |
              Node {{ $labels.instance }} has high CPU usage.
              Current usage: {{ $value }}%.
```

---

# 7. Generate the ACM Policy

Run the PolicyGenerator CLI from the repository root.

```bash
./PolicyGenerator policygen/template.yaml \
  > generated/monitoring-policy.yaml
```

The generated file contains the ACM Policy resources required for deployment.

For example:

```text
generated/monitoring-policy.yaml
```

contains:

```text
Policy
ConfigurationPolicy
PlacementBinding
```

The generated `PlacementBinding` references the existing Placement:

```yaml
placementRef:
  apiGroup: cluster.open-cluster-management.io
  kind: Placement
  name: policy-namespace-placement
```

---

# 8. Validate the Generated Policy

Before applying the generated policy to the Hub, perform a server-side dry run:

```bash
oc apply \
  --dry-run=server \
  -f generated/monitoring-policy.yaml
```

If there are no validation errors, continue with deployment.

---

# 9. Apply the Generated Policy to the ACM Hub

Apply the generated policy:

```bash
oc apply \
  -f generated/monitoring-policy.yaml
```

Verify the policy:

```bash
oc get policy -n policies-developer
```

Check the policy status:

```bash
oc describe policy custom-alertingrules \
  -n policies-developer
```

---

# 10. Verify Placement Binding

Check the PlacementBinding:

```bash
oc get placementbinding \
  -n policies-developer
```

Verify that it references:

```text
policy-namespace-placement
```

---

# 11. Policy Distribution

ACM uses the Placement and PlacementBinding to determine which managed clusters receive the policy.

The resulting flow is:

```text
ACM Hub
   │
   ▼
Policy
   │
   ▼
PlacementBinding
   │
   ▼
policy-namespace-placement
   │
   ▼
ManagedClusterSet
   │
   ▼
Selected Managed Clusters
```

---

# 12. Verify on the Managed Cluster

Log in to a selected managed cluster and verify that the `AlertingRule` was created.

```bash
oc get alertingrule \
  -n openshift-monitoring
```

For example:

```bash
oc get alertingrule \
  psa-high-node-cpu-usage-alert \
  -n openshift-monitoring
```

Verify the generated ConfigurationPolicy from the managed cluster:

```bash
oc get configurationpolicy -A
```

Check its status:

```bash
oc describe configurationpolicy \
  custom-alertingrules \
  -n <managed-cluster-policy-namespace>
```

---

# 13. Final Runtime Flow

The complete process is:

```text
                    FIRST-TIME ACM SETUP
                              │
                              ▼
                    ┌──────────────────┐
                    │   ACM Hub Login  │
                    └────────┬─────────┘
                             │
                             ▼
                    Bind Policy Namespace
                             │
                             ▼
                    ManagedClusterSet
                             │
                             ▼
                    Existing Placement
                             │
                             │
                    REPEATABLE WORKFLOW
                             │
                             ▼
                       Git Repository
                             │
                  ┌──────────┴──────────┐
                  ▼                     ▼
             Kubernetes            PolicyGenerator
             Manifests              template.yaml
                  │                     │
                  └──────────┬──────────┘
                             ▼
                    PolicyGenerator CLI
                             │
                             ▼
                    Generated ACM Policy
                             │
                             ▼
                         oc apply
                             │
                             ▼
                         ACM Hub
                             │
                    ┌────────┴────────┐
                    ▼                 ▼
                  Policy      PlacementBinding
                                      │
                                      ▼
                              Existing Placement
                                      │
                                      ▼
                              ManagedClusterSet
                                      │
                                      ▼
                              Managed Clusters
                                      │
                                      ▼
                            ConfigurationPolicy
                                      │
                                      ▼
                                 AlertingRule
                                      │
                                      ▼
                           OpenShift Monitoring
                                      │
                              ┌───────┴───────┐
                              ▼               ▼
                          Prometheus     Alertmanager
                              │               │
                              └───────┬───────┘
                                      ▼
                              Alert / Notification
```


```
```

