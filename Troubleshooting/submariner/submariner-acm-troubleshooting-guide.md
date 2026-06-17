# Red Hat ACM + Submariner Troubleshooting Guide

> **Version Scope**: This guide is version-agnostic but includes annotated output from a working ACM 2.15 / Submariner 0.22 deployment running OCP 4.16+ with OVNKubernetes CNI.  
> Where behaviour differs between Submariner 0.20 and 0.22, differences are noted inline.  
> **Script Reference**: See [`setup-submariner-kubeconfig.sh`](./setup-submariner-kubeconfig.sh) for the kubeconfig setup automation.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Key CRDs — Hub (Broker) Side](#2-key-crds--hub-broker-side)
3. [Key CRDs — Spoke Cluster Side](#3-key-crds--spoke-cluster-side)
4. [Required Network Ports](#4-required-network-ports)
5. [Kubeconfig Setup for Multi-Cluster Troubleshooting](#5-kubeconfig-setup-for-multi-cluster-troubleshooting)
6. [subctl Command Reference](#6-subctl-command-reference)
7. [Gateway-Level Verification (from the Gateway Node)](#7-gateway-level-verification-from-the-gateway-node)
8. [Service Discovery — Lighthouse DNS Troubleshooting](#8-service-discovery--lighthouse-dns-troubleshooting)
9. [YugabyteDB Multi-Cluster Service Discovery](#9-yugabytedb-multi-cluster-service-discovery)
10. [Common Failure Scenarios and Fixes](#10-common-failure-scenarios-and-fixes)
11. [Gateway Failover and HA Behaviour](#11-gateway-failover-and-ha-behaviour)
12. [Globalnet Mode](#12-globalnet-mode)
13. [Log Collection Reference](#13-log-collection-reference)
14. [Quick Reference Cheatsheet](#14-quick-reference-cheatsheet)

---

## 1. Architecture Overview

Submariner provides **L3-level pod-to-pod and pod-to-service connectivity across clusters**. It operates independently of the underlying CNI plugin (OVNKubernetes, OpenShiftSDN) and supports heterogeneous CNI combinations between clusters.

```
┌─────────────────────────────────────────────────────┐
│                  ACM Hub Cluster                    │
│                                                     │
│   ┌────────────────────────────────────────────┐   │
│   │  Broker (namespace: submariner-broker or   │   │
│   │  workload-broker)                          │   │
│   │  - Holds cluster endpoints metadata        │   │
│   │  - Broadcasts service/endpoint state       │   │
│   │  - No data-plane traffic flows here        │   │
│   └────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
            ▲ sync                    ▲ sync
            │                        │
┌───────────┴──────────┐  ┌──────────┴───────────────┐
│    Spoke: OCP1       │  │    Spoke: OCP2            │
│                      │  │                           │
│  submariner-gateway  │  │  submariner-gateway       │
│  submariner-routeagent  │  submariner-routeagent    │
│  lighthouse-agent    │  │  lighthouse-agent         │
│  lighthouse-coredns  │  │  lighthouse-coredns       │
│                      │  │                           │
│  Gateway Node ───────┼IPsec/Libreswan──────────────▶│
│  (worker-4)          │  │  (worker-4)               │
└──────────────────────┘  └───────────────────────────┘
```

### Data Plane Traffic Flow

```
Pod (OCP2)
   │
   ▼
clusterset.local DNS lookup
   │  (handled by Lighthouse CoreDNS)
   ▼
Lighthouse returns OCP1 service endpoint
   │
   ▼
Submariner Route Agent (OVN policy routing / iptables)
   │
   ▼
Submariner Gateway Node (OCP2)
   │  IPsec tunnel (libreswan, UDP 4500/500)
   ▼
Submariner Gateway Node (OCP1)
   │
   ▼
Target Pod/Service in OCP1
```

### Key Design Points

| Concept | Detail |
|---|---|
| Tunnel encryption | IPsec via libreswan (default) or WireGuard |
| Service discovery | Lighthouse CoreDNS — `*.svc.clusterset.local` |
| CIDR requirement | Pod and Service CIDRs **must be non-overlapping** (or Globalnet required) |
| Gateway HA | Active/Passive — only one gateway active per cluster at a time |
| Broker role | Metadata exchange only, zero data-plane involvement |
| ACM integration | Submariner deployed and lifecycle-managed via ACM `ManagedClusterAddon` |

---

## 2. Key CRDs — Hub (Broker) Side

> **Context**: These commands run against the **ACM Hub cluster**. The broker namespace is typically `submariner-broker` or `workload-broker` depending on your ACM version.

### 2.1 Broker Object

```bash
# What it does: Confirms the broker is deployed and shows Globalnet setting
oc get brokers.submariner.io submariner-broker \
  -n <broker-namespace> \
  -o yaml
```

**Example output (Globalnet disabled — non-overlapping CIDRs):**

```yaml
apiVersion: submariner.io/v1alpha1
kind: Broker
metadata:
  name: submariner-broker
  namespace: workload-broker
spec:
  globalnetEnabled: false    # true = CIDRs overlap, Globalnet active
```

> ⚠️ If `globalnetEnabled: true`, review [Section 12 — Globalnet Mode](#12-globalnet-mode).

---

### 2.2 Registered Clusters

```bash
# What it does: Lists all clusters that have joined this broker
# If a cluster is missing here, it has not successfully connected to the broker
oc get clusters.submariner.io -A -n <broker-namespace>
```

**Example output:**

```
NAMESPACE         NAME    AGE
workload-broker   ocp1    419d
workload-broker   ocp2    432d
```

> **Triage**: If a spoke cluster is absent here, check:
> - `ManagedClusterAddon` status on the Hub for that cluster
> - `submariner-operator` pod logs on the spoke
> - Network connectivity from spoke to broker API endpoint

---

### 2.3 Broker Endpoints

```bash
# What it does: Shows the registered cable endpoints (gateway node IPs) per cluster
# The IP here is the gateway node's inter-cluster-facing IP
oc get endpoints.submariner.io -A -n <broker-namespace>
```

**Example output:**

```
NAMESPACE         NAME                                       AGE
workload-broker   ocp1-submariner-cable-ocp1-<gateway-ip>   419d
workload-broker   ocp2-submariner-cable-ocp2-<gateway-ip>   432d
```

> **Triage**: If endpoint is stale or missing after a gateway node change, the broker hasn't synced the new endpoint. Restart `submariner-operator` on the affected spoke.

---

### 2.4 ManagedClusterAddon (ACM Hub)

```bash
# What it does: Shows Submariner addon deployment status per managed cluster
oc get managedclusteraddon submariner \
  -n <managed-cluster-name> \
  -o yaml
```

Look for `Available` condition = `True`. A `Degraded` condition points to the failing component in the message field.

---

## 3. Key CRDs — Spoke Cluster Side

> **Context**: These commands run against individual **spoke clusters** (OCP1 or OCP2). Use `--context <context-name>` when using the merged kubeconfig.

### 3.1 Submariner Operator CRD

```bash
# What it does: Shows full Submariner configuration on this cluster
# including cable driver, broker endpoint, CIDR config, and component status
kubectl --context OCP1-submariner-admin \
  get submariner submariner \
  -n submariner-operator \
  -o yaml
```

Key fields to check:

| Field | What to Verify |
|---|---|
| `spec.brokerK8sApiServer` | Points to the Hub broker API |
| `spec.cableDriver` | `libreswan` (default) or `wireguard` |
| `spec.clusterCIDR` | Matches actual pod CIDR |
| `spec.serviceCIDR` | Matches actual service CIDR |
| `status.deploymentStatus` | All components `Deployed` |

---

### 3.2 Gateway Resource

```bash
# What it does: Shows active gateway node, HA status, and connection summary
# Run this on EACH cluster to confirm gateways are elected
kubectl --context OCP1-submariner-admin \
  get gateway -n submariner-operator

kubectl --context OCP2-submariner-admin \
  get gateway -n submariner-operator
```

**Expected output (healthy):**

```
NAME            HA STATUS   SUMMARY
ocp1-worker-4   active      All connections (1) are established
```

> **Triage**: If `HA STATUS` is `passive` on both sides, the tunnel will not be established. Check gateway node labels.

---

### 3.3 Cluster Resource (spoke)

```bash
# What it does: Shows this cluster's self-registration details including CIDRs
kubectl --context OCP1-submariner-admin \
  get cluster.submariner.io \
  -n submariner-operator \
  -o yaml
```

---

### 3.4 Endpoint Resource (spoke)

```bash
# What it does: Shows the cable endpoint — the gateway node IP and tunnel config
kubectl --context OCP1-submariner-admin \
  get endpoint.submariner.io \
  -n submariner-operator \
  -o yaml
```

Key fields: `spec.privateIP`, `spec.publicIP`, `spec.subnets` (must include pod + service CIDRs).

---

### 3.5 ServiceExport and ServiceImport

```bash
# ServiceExport — created in the SOURCE cluster to make a service available
# What it does: Tells Lighthouse to advertise this service to other clusters
kubectl --context OCP1-submariner-admin \
  get serviceexport -n <namespace>

# ServiceImport — automatically created by Lighthouse in CONSUMING clusters
# What it does: Represents an imported remote service; enables DNS resolution
kubectl --context OCP1-submariner-admin \
  get serviceimport -n <namespace>

kubectl --context OCP2-submariner-admin \
  get serviceimport -n <namespace>
```

> **Important**: `ServiceExport` is created **manually** (or via automation) in the source cluster. `ServiceImport` is created **automatically** by Lighthouse in all clusters that can reach the broker. If `ServiceImport` is missing, Lighthouse sync is broken.

---

### 3.6 EndpointSlices (Lighthouse)

```bash
# What it does: Shows the actual endpoint IPs Lighthouse is serving for DNS
# These back the clusterset.local DNS entries
kubectl --context OCP1-submariner-admin \
  get endpointslice -n <namespace> -l submariner.io/originatingNamespace=<namespace>

kubectl --context OCP2-submariner-admin \
  get endpointslice -n <namespace> -l submariner.io/originatingNamespace=<namespace>
```

> **Triage**: If `EndpointSlice` exists but has no endpoints listed, the source service has no ready pods. If `EndpointSlice` is missing entirely, Lighthouse agent sync has failed.

---

## 4. Required Network Ports

These ports must be open **between gateway nodes** of both clusters (bidirectional):

| Protocol | Port | Purpose | Notes |
|---|---|---|---|
| UDP | 4500 | IPsec NAT-T (libreswan) | Required for NAT traversal |
| UDP | 500 | IPsec IKE (libreswan) | Key exchange |
| UDP | 4800 | VXLAN (intra-cluster route agent) | OVN/SDN overlay |
| TCP | 8080 | Gateway health check | Used by `subctl diagnose` |
| TCP | 6443 | OCP API (broker access) | Spoke → Hub broker |

> **Important distinction**:  
> - Ports **4500/500/4800** must be open between **spoke gateway nodes** (inter-cluster).  
> - Port **6443** must be open from **each spoke** to the **Hub API**.  
> - `subctl diagnose firewall inter-cluster` tests the first group automatically.

---

## 5. Kubeconfig Setup for Multi-Cluster Troubleshooting

A merged kubeconfig with named contexts is required for `subctl` inter-cluster commands and for switching between clusters without re-login.

> See [`setup-submariner-kubeconfig.sh`](./setup-submariner-kubeconfig.sh) for the automated version.

### 5.1 Create the env file

```bash
mkdir -p ~/submariner-troubleshooting

cat > ~/submariner-troubleshooting/.envdetails << 'EOF'
OCP1_API=<ocp1-api-hostname>
OCP1_PASSWORD=<kubeadmin-password>
OCP2_API=<ocp2-api-hostname>
OCP2_PASSWORD=<kubeadmin-password>
EOF

chmod 600 ~/submariner-troubleshooting/.envdetails
```

### 5.2 Manual steps (if not using the script)

```bash
# Step 1: Login and capture OCP1 kubeconfig
export KUBECONFIG=/tmp/OCP1-kubeconfig

oc login https://<ocp1-api>:6443 \
  -u kubeadmin -p '<password>' \
  --insecure-skip-tls-verify=true

oc config rename-context \
  "$(oc config current-context)" \
  OCP1-submariner-admin

# Step 2: Login and capture OCP2 kubeconfig
export KUBECONFIG=/tmp/OCP2-kubeconfig

oc login https://<ocp2-api>:6443 \
  -u kubeadmin -p '<password>' \
  --insecure-skip-tls-verify=true

oc config rename-context \
  "$(oc config current-context)" \
  OCP2-submariner-admin

# Step 3: Merge into a single kubeconfig
KUBECONFIG=/tmp/OCP1-kubeconfig:/tmp/OCP2-kubeconfig \
  kubectl config view --flatten \
  > ~/submariner-troubleshooting/submariner-kubeconfig

chmod 600 ~/submariner-troubleshooting/submariner-kubeconfig

# Step 4: Activate
export KUBECONFIG=~/submariner-troubleshooting/submariner-kubeconfig
```

### 5.3 Verify merged kubeconfig

```bash
kubectl config get-contexts

# Should show:
# CURRENT   NAME                    CLUSTER   ...
# *         OCP1-submariner-admin   ...
#           OCP2-submariner-admin   ...

oc --context OCP1-submariner-admin get nodes
oc --context OCP2-submariner-admin get nodes
```

---

## 6. subctl Command Reference

> `subctl` is the Submariner CLI. Match the binary version to your deployed Submariner version (e.g., `subctl-v0.22.x` for Submariner 0.22, `subctl-v0.20.x` for 0.20).  
> Download from: https://github.com/submariner-io/subctl/releases

### Context Requirement Matrix

| Command | Contexts Required | Direction |
|---|---|---|
| `subctl show all` | Single | Per-cluster — run separately on each |
| `subctl show connections` | Single | Per-cluster — run separately on each |
| `subctl diagnose all` | Single | Per-cluster — skips inter-cluster check |
| `subctl diagnose firewall inter-cluster` | **Both** | Run once per direction |
| `subctl verify` | **Both** | Bidirectional end-to-end tests |

---

### 6.1 Show Overall State

```bash
# What it does: Prints connections, endpoints, gateway status, network CIDRs, component versions
# Run on EACH cluster separately

./subctl show all \
  --kubeconfig ~/submariner-troubleshooting/submariner-kubeconfig \
  --context OCP1-submariner-admin

./subctl show all \
  --kubeconfig ~/submariner-troubleshooting/submariner-kubeconfig \
  --context OCP2-submariner-admin
```

**Example output (healthy OCP2 perspective):**

```
✓ Showing Connections
GATEWAY         CLUSTER   REMOTE IP       NAT   CABLE DRIVER   SUBNETS                           STATUS      RTT avg.
ocp1-worker-4   ocp1      <ocp1-gw-ip>    no    libreswan      <ocp1-svc-cidr>, <ocp1-pod-cidr>  connected   1.515ms

✓ Showing Endpoints
CLUSTER   ENDPOINT IP     PUBLIC IP   CABLE DRIVER   TYPE
ocp2      <ocp2-gw-ip>                libreswan      local
ocp1      <ocp1-gw-ip>                libreswan      remote

✓ Showing Gateways
NODE            HA STATUS   SUMMARY
ocp2-worker-4   active      All connections (1) are established

✓ Showing Network details
    Network plugin:  OVNKubernetes
    Service CIDRs:   [<ocp2-svc-cidr>]
    Cluster CIDRs:   [<ocp2-pod-cidr>]

✓ Showing versions
COMPONENT                       RUNNING
submariner-gateway              release-0.22
submariner-routeagent           release-0.22
submariner-lighthouse-agent     release-0.22
submariner-lighthouse-coredns   release-0.22
```

> **What to look for**:
> - `STATUS: connected` on all tunnel entries
> - `HA STATUS: active` on the gateway node
> - `NAT: no` is normal for clusters with direct L3 reachability; `NAT: yes` indicates NAT traversal via UDP 4500

---

### 6.2 Show Connections Only

```bash
# What it does: Focused view — tunnel status, RTT, cable driver, remote subnets
# Fastest way to confirm tunnel health; run per cluster

./subctl show connections \
  --kubeconfig ~/submariner-troubleshooting/submariner-kubeconfig \
  --context OCP1-submariner-admin

./subctl show connections \
  --kubeconfig ~/submariner-troubleshooting/submariner-kubeconfig \
  --context OCP2-submariner-admin
```

**Healthy example:**

```
GATEWAY         CLUSTER   REMOTE IP       NAT   CABLE DRIVER   SUBNETS   STATUS      RTT avg.
ocp2-worker-4   ocp2      <ocp2-gw-ip>    no    libreswan      ...       connected   1.44ms
```

> **Triage signals**:
> - `STATUS: connecting` → tunnel negotiation stuck; check IPsec ports and logs
> - `STATUS: error` → libreswan failure; check gateway pod logs
> - High RTT (>50ms) → network path issue or gateway node overloaded

---

### 6.3 Diagnose All (Single Cluster)

```bash
# What it does: Runs all local health checks — K8s version support, CIDR overlap,
# DaemonSet health, pod status, CNI support, OVN version, gateway/routeagent connections,
# kube-proxy mode, intra-cluster VXLAN, ServiceExport validity
# NOTE: Skips inter-cluster firewall — must run separately (see 6.4)

./subctl diagnose all \
  --kubeconfig ~/submariner-troubleshooting/submariner-kubeconfig \
  --context OCP1-submariner-admin \
  --verbose

./subctl diagnose all \
  --kubeconfig ~/submariner-troubleshooting/submariner-kubeconfig \
  --context OCP2-submariner-admin \
  --verbose
```

**Example output (all passing):**

```
✓ Kubernetes version "v1.29.14" is supported
✓ Non-Globalnet: cluster CIDRs do not overlap
✓ DaemonSet "submariner-gateway"          — healthy
✓ DaemonSet "submariner-routeagent"       — healthy
✓ DaemonSet "submariner-metrics-proxy"    — healthy
✓ Deployment "submariner-lighthouse-agent"     — healthy
✓ Deployment "submariner-lighthouse-coredns"   — healthy
✓ All Submariner pods healthy
✓ Gateway metrics accessible from non-gateway nodes
✓ CNI "OVNKubernetes" is supported
✓ OVN NB database version 7.3.0 supported
✓ Gateway connections healthy
✓ Route agent connections healthy
✓ Intra-cluster VXLAN firewall OK
✓ Services exported properly

Skipping inter-cluster firewall check — run "subctl diagnose firewall inter-cluster" manually
```

---

### 6.4 Diagnose Firewall Inter-Cluster (Both Contexts Required)

```bash
# What it does: Deploys temporary test pods on gateway nodes of BOTH clusters,
# sends probes through the tunnel, and verifies IPsec and VXLAN connectivity.
# Requires BOTH contexts in the same kubeconfig.
# Must be run in BOTH directions independently.

# Direction: OCP1 → OCP2
./subctl diagnose firewall inter-cluster \
  --kubeconfig ~/submariner-troubleshooting/submariner-kubeconfig \
  --context OCP1-submariner-admin \
  --remotecontext OCP2-submariner-admin \
  --verbose

# Direction: OCP2 → OCP1
./subctl diagnose firewall inter-cluster \
  --kubeconfig ~/submariner-troubleshooting/submariner-kubeconfig \
  --context OCP2-submariner-admin \
  --remotecontext OCP1-submariner-admin \
  --verbose
```

**Healthy output:**

```
✓ Checking if tunnels can be setup on gateway node of "OCP1"
✓ tcpdump output from sniffer pod on Gateway node: [packets captured]
✓ Tunnels can be established on gateway node of "OCP1"
```

> **If this fails**: IPsec ports (UDP 4500/500) are blocked between gateway nodes. Engage the network/firewall team with the specific source/destination IPs shown in `subctl show endpoints`.

---

### 6.5 End-to-End Verify (Both Contexts Required)

```bash
# What it does: Creates test namespaces and pods, exports/imports test services,
# and validates pod-to-pod and pod-to-service traffic across the tunnel.
# This is the most comprehensive connectivity test.

./subctl verify \
  --kubeconfig ~/submariner-troubleshooting/submariner-kubeconfig \
  --context OCP1-submariner-admin \
  --tocontext OCP2-submariner-admin \
  --verbose
```

---

## 7. Gateway-Level Verification (from the Gateway Node)

> These checks are run **directly on the gateway worker node** via `oc debug node` or SSH. Use when `subctl` shows tunnel issues and you need low-level IPsec visibility.

### 7.1 Identify the Active Gateway Node

```bash
# Run on EACH cluster — determines which worker node is the active gateway
kubectl --context OCP1-submariner-admin \
  get gateway -n submariner-operator -o wide

kubectl --context OCP2-submariner-admin \
  get gateway -n submariner-operator -o wide
```

---

### 7.2 Access the Gateway Node

```bash
# Method 1: oc debug (preferred in OCP — no SSH needed)
oc --context OCP1-submariner-admin \
  debug node/<gateway-node-name>

# Inside the debug shell:
chroot /host

# Method 2: exec into the gateway pod
kubectl --context OCP1-submariner-admin \
  exec -it \
  -n submariner-operator \
  $(kubectl --context OCP1-submariner-admin get pod \
    -n submariner-operator \
    -l app=submariner-gateway \
    -o jsonpath='{.items[0].metadata.name}') \
  -- bash
```

---

### 7.3 Check IPsec Tunnel State (inside gateway pod or node)

```bash
# List all active IPsec connections
ip xfrm state list

# Check IPsec security policies
ip xfrm policy list

# Using libreswan directly (if available in gateway pod)
ipsec status
ipsec trafficstatus

# Verify the tunnel interface is up
ip link show | grep -E "vx-submariner|vxlan"

# Check routing table for remote CIDRs
ip route | grep -E "<remote-pod-cidr>|<remote-svc-cidr>"
```

> **Expected**: Remote cluster CIDRs should appear in the routing table via the Submariner VXLAN interface.

---

### 7.4 Test Raw UDP Port Reachability (from gateway node)

```bash
# From OCP1 gateway node — test UDP 4500 to OCP2 gateway IP
# Replace <ocp2-gateway-ip> with the actual remote gateway IP

nc -u -z -v <ocp2-gateway-ip> 4500
nc -u -z -v <ocp2-gateway-ip> 500

# tcpdump to verify IPsec traffic (run before triggering a reconnect)
tcpdump -i any -n udp port 4500 or udp port 500
```

---

### 7.5 Force Gateway Reconnection

```bash
# Restart the gateway pod to trigger tunnel re-negotiation
# (Safe — routeagent will maintain pod routing during brief reconnect)
kubectl --context OCP1-submariner-admin \
  rollout restart daemonset/submariner-gateway \
  -n submariner-operator

# Watch recovery
kubectl --context OCP1-submariner-admin \
  get gateway -n submariner-operator -w
```

---

## 8. Service Discovery — Lighthouse DNS Troubleshooting

Lighthouse provides `*.svc.clusterset.local` DNS resolution using a CoreDNS plugin deployed per cluster.

### DNS Name Format

```
<service-name>.<namespace>.svc.clusterset.local
```

For services exported from a specific cluster (when same service exists in multiple clusters):

```
<service-name>.<namespace>.svc.<cluster-id>.local
```

---

### 8.1 Verify ServiceExport

```bash
# Run on SOURCE cluster (where the service lives)
# What it does: Confirms the export request exists
kubectl --context OCP1-submariner-admin \
  get serviceexport -n <namespace> -o yaml
```

Check `status.conditions`:
- `type: Valid` → `status: True` means Lighthouse accepted the export
- `type: Valid` → `status: False` → check the `message` field for the reason

---

### 8.2 Verify ServiceImport on Consuming Cluster

```bash
# Run on CONSUMING cluster
# What it does: Confirms Lighthouse has synced the remote service
kubectl --context OCP2-submariner-admin \
  get serviceimport -n <namespace> -o yaml
```

---

### 8.3 Verify Lighthouse EndpointSlices

```bash
# Run on CONSUMING cluster
# EndpointSlices back the actual DNS answers
kubectl --context OCP2-submariner-admin \
  get endpointslice -n <namespace>

# Detailed view — check addresses and conditions
kubectl --context OCP2-submariner-admin \
  get endpointslice -n <namespace> \
  -o custom-columns="NAME:.metadata.name,ENDPOINTS:.endpoints[*].addresses[*],READY:.endpoints[*].conditions.ready"
```

---

### 8.4 DNS Resolution Test from a Pod

```bash
# Run on CONSUMING cluster — exec into any pod in the same namespace
# What it does: Validates that clusterset.local DNS resolves end-to-end

kubectl --context OCP2-submariner-admin \
  exec -n <namespace> <pod-name> -- \
  getent hosts <service-name>.<namespace>.svc.clusterset.local

# Alternatively with nslookup/dig if available
kubectl --context OCP2-submariner-admin \
  exec -n <namespace> <pod-name> -- \
  nslookup <service-name>.<namespace>.svc.clusterset.local

kubectl --context OCP2-submariner-admin \
  exec -n <namespace> <pod-name> -- \
  dig <service-name>.<namespace>.svc.clusterset.local
```

> **If DNS fails but EndpointSlice exists**: Lighthouse CoreDNS is not forwarding correctly. Check Lighthouse CoreDNS pod logs (see Section 13) and verify the CoreDNS ConfigMap has the `clusterset.local` stub zone pointing to Lighthouse CoreDNS.

---

### 8.5 Verify Lighthouse CoreDNS ConfigMap

```bash
# Check that the cluster's CoreDNS is delegating clusterset.local to Lighthouse
oc --context OCP1-submariner-admin \
  get configmap coredns -n openshift-dns -o yaml

# Look for a forward block like:
# clusterset.local:5353 {
#     forward . <lighthouse-coredns-svc-ip>
# }

# Get the Lighthouse CoreDNS service IP
kubectl --context OCP1-submariner-admin \
  get svc submariner-lighthouse-coredns \
  -n submariner-operator
```

---

### 8.6 HTTP Connectivity Test

```bash
# Once DNS resolves, test HTTP reachability
kubectl --context OCP2-submariner-admin \
  exec -n <namespace> <pod-name> -- \
  curl -kv http://<service-name>.<namespace>.svc.clusterset.local:<port>/
```

---

## 9. YugabyteDB Multi-Cluster Service Discovery

This section covers the specific Submariner service discovery pattern for YugabyteDB (YB) stretched across two OCP clusters. YB uses multiple headless services per universe for master and tserver discovery.

### 9.1 YB Service Export Pattern

YugabyteDB services follow this naming convention per universe:

```
<universe-name>-yb-masters    (headless — master RPC/HTTP)
<universe-name>-yb-tservers   (headless — tserver RPC/HTTP)
```

Each cluster exports its own services so the other cluster can discover them:

```bash
# On OCP1 — verify exports of OCP1's YB services
kubectl --context OCP1-submariner-admin \
  get serviceexport -n yb-universe

# On OCP2 — verify exports of OCP2's YB services
kubectl --context OCP2-submariner-admin \
  get serviceexport -n yb-universe
```

---

### 9.2 Verify Cross-Cluster Service Imports

```bash
# On OCP1 — verify OCP2's services are imported (and vice versa)
kubectl --context OCP1-submariner-admin \
  get serviceimport -n yb-universe

kubectl --context OCP2-submariner-admin \
  get serviceimport -n yb-universe
```

---

### 9.3 Verify Lighthouse EndpointSlices for YB

```bash
# Check EndpointSlices on both clusters
kubectl --context OCP1-submariner-admin \
  get endpointslice -n yb-universe

kubectl --context OCP2-submariner-admin \
  get endpointslice -n yb-universe
```

---

### 9.4 DNS Resolution Test for YB Services

```bash
# From OCP1 pod — resolve OCP2's YB master service
kubectl --context OCP1-submariner-admin \
  exec -n yb-universe <ocp1-pod-name> -- \
  getent hosts <ocp2-yb-masters-svc-name>.yb-universe.svc.clusterset.local

# From OCP2 pod — resolve OCP1's YB master service
kubectl --context OCP2-submariner-admin \
  exec -n yb-universe <ocp2-pod-name> -- \
  getent hosts <ocp1-yb-masters-svc-name>.yb-universe.svc.clusterset.local
```

---

### 9.5 YB HTTP Endpoint Test

```bash
# Test YB master HTTP UI (port 7000) from a pod in the remote cluster
curl -kv \
  http://<remote-yb-masters-svc>.yb-universe.svc.clusterset.local:7000/

# Test YB tserver HTTP UI (port 9000)
curl -kv \
  http://<remote-yb-tservers-svc>.yb-universe.svc.clusterset.local:9000/
```

---

### 9.6 YB-Specific Triage Path

```
YB cross-cluster replication failing?
          │
          ▼
Are ServiceExports present on both clusters?
          │ No → Create ServiceExport for missing services
          │ Yes
          ▼
Are ServiceImports present on consuming clusters?
          │ No → Lighthouse sync broken — check lighthouse-agent logs
          │ Yes
          ▼
Do EndpointSlices have ready endpoints?
          │ No → YB pods not Ready; check pod status
          │ Yes
          ▼
Does DNS resolve from a pod in the consuming cluster?
          │ No → CoreDNS stub zone misconfigured or lighthouse-coredns down
          │ Yes
          ▼
Does curl reach the remote endpoint?
          │ No → IPsec tunnel issue — run subctl diagnose firewall inter-cluster
          │ Yes
          ▼
Issue is above the Submariner layer (YB config, certs, auth)
```

---

## 10. Common Failure Scenarios and Fixes

### 10.1 Tunnel Status: `connecting` — Never Reaches `connected`

**Symptoms**: `subctl show connections` shows `STATUS: connecting` indefinitely.

**Root causes and fixes**:

| Cause | How to Confirm | Fix |
|---|---|---|
| UDP 4500/500 blocked | `subctl diagnose firewall inter-cluster` fails | Open ports between gateway node IPs |
| Wrong gateway node IP in endpoint | `oc get endpoint.submariner.io` shows old IP | Restart submariner-operator on that spoke |
| IPsec pre-shared key mismatch | Gateway pod logs show `NO_PROPOSAL_CHOSEN` | Re-run ACM Submariner addon setup to regenerate PSK |
| Gateway node unreachable | `ping`/traceroute from the other gateway fails | Fix underlying network routing |

```bash
# Check gateway pod logs for IPsec errors
kubectl --context OCP1-submariner-admin \
  logs -n submariner-operator \
  -l app=submariner-gateway \
  --tail=200 | grep -iE "error|fail|NO_PROPOSAL|INVALID"
```

---

### 10.2 DNS Resolution Fails — `clusterset.local` Not Resolving

**Symptoms**: `getent hosts <svc>.svc.clusterset.local` returns nothing from inside a pod.

**Triage steps**:

```bash
# Step 1: Confirm ServiceExport and ServiceImport exist
kubectl --context OCP2-submariner-admin get serviceexport,serviceimport -n <ns>

# Step 2: Confirm Lighthouse CoreDNS pod is running
kubectl --context OCP2-submariner-admin \
  get pods -n submariner-operator -l app=submariner-lighthouse-coredns

# Step 3: Check CoreDNS delegation
oc --context OCP2-submariner-admin \
  get configmap coredns -n openshift-dns -o yaml | grep -A5 clusterset

# Step 4: Check Lighthouse CoreDNS logs
kubectl --context OCP2-submariner-admin \
  logs -n submariner-operator \
  -l app=submariner-lighthouse-coredns --tail=100
```

---

### 10.3 ServiceImport Missing on Remote Cluster

**Symptoms**: `ServiceExport` exists on source cluster but `ServiceImport` never appears on the consuming cluster.

**Root causes**:

- `submariner-lighthouse-agent` pod is not running or has errors
- Broker sync broken (agent cannot reach the Hub broker)

```bash
# Check lighthouse agent status
kubectl --context OCP2-submariner-admin \
  get pods -n submariner-operator -l app=submariner-lighthouse-agent

# Check lighthouse agent logs
kubectl --context OCP2-submariner-admin \
  logs -n submariner-operator \
  -l app=submariner-lighthouse-agent --tail=200

# Verify the ServiceExport is valid on source
kubectl --context OCP1-submariner-admin \
  get serviceexport <svc-name> -n <ns> -o yaml | grep -A10 status
```

---

### 10.4 Route Agent Crashing / Pod-to-Pod Traffic Drops

**Symptoms**: Tunnel shows `connected` but actual pod traffic fails.

**Root cause**: `submariner-routeagent` is responsible for programming OVN or iptables rules on every node. A crashed routeagent on a non-gateway node breaks traffic from pods on that node only.

```bash
# Check routeagent DaemonSet — should be running on ALL nodes
kubectl --context OCP1-submariner-admin \
  get pods -n submariner-operator -l app=submariner-routeagent -o wide

# Check for crash loops
kubectl --context OCP1-submariner-admin \
  get pods -n submariner-operator -l app=submariner-routeagent | grep -v Running

# Check logs on a failing routeagent pod
kubectl --context OCP1-submariner-admin \
  logs -n submariner-operator <routeagent-pod-name> --tail=200
```

---

### 10.5 Gateway HA — Both Nodes in Passive State

**Symptoms**: `subctl show all` shows `HA STATUS: passive` on the gateway node, no connections.

```bash
# Check gateway node label
kubectl --context OCP1-submariner-admin \
  get node <expected-gateway-node> \
  -o jsonpath='{.metadata.labels}' | grep submariner

# The gateway node must have this label:
# submariner.io/gateway: "true"

# Apply the label if missing
kubectl --context OCP1-submariner-admin \
  label node <node-name> submariner.io/gateway=true

# Then restart the gateway daemonset
kubectl --context OCP1-submariner-admin \
  rollout restart daemonset/submariner-gateway -n submariner-operator
```

---

### 10.6 Broker Sync Failure

**Symptoms**: `oc get clusters.submariner.io` on the Hub is missing one spoke; that spoke's endpoint is stale.

```bash
# Check submariner-operator pod on the affected spoke
kubectl --context OCP1-submariner-admin \
  logs -n submariner-operator \
  -l name=submariner-operator --tail=300 | grep -iE "broker|error|fail"

# Verify the spoke can reach the Hub API
curl -k https://<hub-api>:6443/healthz

# Restart the operator to force re-sync
kubectl --context OCP1-submariner-admin \
  rollout restart deployment/submariner-operator \
  -n submariner-operator
```

---

## 11. Gateway Failover and HA Behaviour

### How Gateway HA Works

Submariner uses an **Active/Passive** model per cluster:

- Only **one gateway node is active** at a time per cluster
- The active gateway holds the IPsec tunnels to all remote clusters
- Failover is triggered by the `submariner-gateway` DaemonSet leader election

```
Normal state:
  ocp1-worker-4 [ACTIVE]  ←──IPsec──→  ocp2-worker-4 [ACTIVE]
  ocp1-worker-5 [PASSIVE]              ocp2-worker-5 [PASSIVE]

During failover (ocp1-worker-4 goes down):
  ocp1-worker-4 [DOWN]
  ocp1-worker-5 [ACTIVE] ← elected     → re-establishes tunnel to ocp2-worker-4
```

### 11.1 Check HA Status

```bash
# Check which node is active and the connection count
kubectl --context OCP1-submariner-admin \
  get gateway -n submariner-operator

# Detailed view including failover history
kubectl --context OCP1-submariner-admin \
  describe gateway -n submariner-operator
```

### 11.2 Monitor Failover in Real Time

```bash
# Watch gateway election in real time
kubectl --context OCP1-submariner-admin \
  get gateway -n submariner-operator -w

# Watch pods during failover
kubectl --context OCP1-submariner-admin \
  get pods -n submariner-operator -l app=submariner-gateway -w
```

### 11.3 Gateway Node Requirements

- Must be a **worker node** (control plane nodes not supported for gateway role by default)
- Must have the label `submariner.io/gateway: "true"`
- Must have the required ports accessible from remote cluster gateway IPs
- Multiple nodes can be labeled — only one will be elected active

### 11.4 Simulate Failover (for testing)

```bash
# Cordon the active gateway node to trigger passive promotion
kubectl --context OCP1-submariner-admin \
  cordon <active-gateway-node>

# Watch the passive node take over
kubectl --context OCP1-submariner-admin \
  get gateway -n submariner-operator -w

# After validation, uncordon
kubectl --context OCP1-submariner-admin \
  uncordon <active-gateway-node>
```

**Expected recovery time**: 10–30 seconds for tunnel re-establishment after gateway election.

---

## 12. Globalnet Mode

### When is Globalnet Needed?

Globalnet is required when **pod CIDRs or service CIDRs overlap between clusters**. Without Globalnet, Submariner cannot route traffic because it cannot distinguish between the same IP in two clusters.

```bash
# Check current mode on the Hub broker
oc get broker.submariner.io submariner-broker \
  -n <broker-namespace> \
  -o jsonpath='{.spec.globalnetEnabled}'
```

### How Globalnet Works

```
Without Globalnet (non-overlapping CIDRs):
  Pod 172.16.1.5 (OCP1) → Pod 172.20.1.5 (OCP2)   [Direct routing — no translation]

With Globalnet (overlapping CIDRs — both clusters use 172.16.0.0/14):
  Pod 172.16.1.5 (OCP1) → GlobalEgressIP (e.g., 242.0.0.5)
                         → Routed via tunnel
                         → GlobalIngressIP (e.g., 242.1.0.5)
                         → Pod 172.16.1.5 (OCP2)
```

### 12.1 Globalnet Key Resources

```bash
# GlobalEgressIP — assigned to pods/namespaces for outbound inter-cluster traffic
kubectl --context OCP1-submariner-admin \
  get globalegressip -n <namespace>

# ClusterGlobalEgressIP — cluster-wide egress IP for all pods
kubectl --context OCP1-submariner-admin \
  get clusterglobalegressip

# GlobalIngressIP — assigned to exported services for inbound traffic
kubectl --context OCP1-submariner-admin \
  get globalingressip -n <namespace>
```

### 12.2 Globalnet CIDR Configuration

```bash
# Check assigned Globalnet CIDR per cluster
oc get cluster.submariner.io \
  -n submariner-operator \
  -o jsonpath='{.items[*].spec.globalCIDR}'
```

> **Note**: Globalnet introduces additional iptables NAT rules and increases CPU overhead on gateway nodes. For new deployments, design non-overlapping CIDRs to avoid Globalnet if possible.

---

## 13. Log Collection Reference

### Component → Log Location Matrix

| Component | Pod Label | Namespace | Single/Both Clusters |
|---|---|---|---|
| Gateway | `app=submariner-gateway` | `submariner-operator` | Each spoke separately |
| Route Agent | `app=submariner-routeagent` | `submariner-operator` | Each spoke separately |
| Lighthouse Agent | `app=submariner-lighthouse-agent` | `submariner-operator` | Each spoke separately |
| Lighthouse CoreDNS | `app=submariner-lighthouse-coredns` | `submariner-operator` | Each spoke separately |
| Submariner Operator | `name=submariner-operator` | `submariner-operator` | Each spoke separately |
| ACM Addon Manager | `app=submariner-addon` | `open-cluster-management` | Hub only |

### 13.1 Collect All Submariner Logs

```bash
# Gateway logs (most important for tunnel issues)
kubectl --context OCP1-submariner-admin \
  logs -n submariner-operator \
  -l app=submariner-gateway \
  --all-containers --tail=500 \
  > /tmp/ocp1-gateway.log

# Route agent logs (all pods — one per node)
kubectl --context OCP1-submariner-admin \
  logs -n submariner-operator \
  -l app=submariner-routeagent \
  --all-containers --tail=200 \
  > /tmp/ocp1-routeagent.log

# Lighthouse agent logs (service discovery sync)
kubectl --context OCP1-submariner-admin \
  logs -n submariner-operator \
  -l app=submariner-lighthouse-agent \
  --all-containers --tail=300 \
  > /tmp/ocp1-lighthouse-agent.log

# Lighthouse CoreDNS logs (DNS resolution failures)
kubectl --context OCP1-submariner-admin \
  logs -n submariner-operator \
  -l app=submariner-lighthouse-coredns \
  --all-containers --tail=300 \
  > /tmp/ocp1-lighthouse-coredns.log
```

### 13.2 Events in submariner-operator Namespace

```bash
# Recent events — useful for pod crash reasons, image pull failures
kubectl --context OCP1-submariner-admin \
  get events -n submariner-operator \
  --sort-by='.lastTimestamp' | tail -30
```

### 13.3 must-gather for Submariner

```bash
# Red Hat supported must-gather for ACM/Submariner
oc adm must-gather \
  --image=registry.redhat.io/rhacm2/acm-must-gather-rhel8:v<acm-version> \
  -- /usr/bin/gather

# Output in must-gather.local.*/ directory
```

---

## 14. Quick Reference Cheatsheet

### Environment Setup

```bash
export KUBECONFIG=~/submariner-troubleshooting/submariner-kubeconfig
SUBCTL=./subctl-v<version>-linux-amd64
KC="--kubeconfig $KUBECONFIG"
CTX1="--context OCP1-submariner-admin"
CTX2="--context OCP2-submariner-admin"
```

### Most Used Commands

```bash
# Tunnel health — run on each cluster
$SUBCTL show connections $KC $CTX1
$SUBCTL show connections $KC $CTX2

# Full state — run on each cluster
$SUBCTL show all $KC $CTX1
$SUBCTL show all $KC $CTX2

# Diagnose local — run on each cluster
$SUBCTL diagnose all $KC $CTX1 --verbose
$SUBCTL diagnose all $KC $CTX2 --verbose

# Firewall inter-cluster — BOTH directions, BOTH contexts needed
$SUBCTL diagnose firewall inter-cluster $KC $CTX1 --remotecontext OCP2-submariner-admin --verbose
$SUBCTL diagnose firewall inter-cluster $KC $CTX2 --remotecontext OCP1-submariner-admin --verbose

# Hub broker resources
oc get clusters.submariner.io -A
oc get endpoints.submariner.io -A
oc get brokers.submariner.io -A

# Spoke resources (run per cluster)
kubectl $CTX1 get gateway,endpoint,cluster -n submariner-operator
kubectl $CTX2 get gateway,endpoint,cluster -n submariner-operator

# Service discovery
kubectl $CTX1 get serviceexport,serviceimport,endpointslice -n <namespace>
kubectl $CTX2 get serviceexport,serviceimport,endpointslice -n <namespace>

# DNS test from pod
kubectl $CTX2 exec -n <ns> <pod> -- getent hosts <svc>.<ns>.svc.clusterset.local

# Log tailing
kubectl $CTX1 logs -n submariner-operator -l app=submariner-gateway -f
kubectl $CTX1 logs -n submariner-operator -l app=submariner-lighthouse-agent -f
```

### Triage Decision Tree

```
Problem reported
      │
      ├─ No cross-cluster connectivity at all?
      │        → subctl show connections (check STATUS)
      │        → subctl diagnose firewall inter-cluster
      │        → Check IPsec ports between gateway IPs
      │
      ├─ Service not reachable by DNS?
      │        → kubectl get serviceexport (source cluster)
      │        → kubectl get serviceimport (consuming cluster)
      │        → kubectl get endpointslice (consuming cluster)
      │        → getent hosts from pod
      │        → Check lighthouse-agent and lighthouse-coredns logs
      │
      ├─ Tunnel connected but pod traffic drops?
      │        → kubectl get pods -l app=submariner-routeagent
      │        → Check routeagent logs on affected nodes
      │        → ip xfrm state on gateway node
      │
      └─ Broker sync issue?
               → oc get clusters.submariner.io (Hub)
               → Check submariner-operator logs on spoke
               → Verify spoke → Hub API reachability
```

---

*Guide maintained by OpenShift Platform Engineering.*  
*Last validated against: ACM 2.15 / Submariner 0.22 / OCP 4.16+ / OVNKubernetes*
