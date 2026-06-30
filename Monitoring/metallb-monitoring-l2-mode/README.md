# MetalLB L2 Mode — Grafana Dashboard

Grafana dashboard for monitoring MetalLB running in **Layer 2 (ARP/NDP) mode** on OpenShift / Kubernetes. Built from real speaker pod metric scrapes, includes Red Hat-specific L2 metrics not documented on the upstream MetalLB metrics page. Designed to scale to large clusters (15+ nodes) without becoming a wall of tiny tiles.

## Why this dashboard exists

MetalLB in L2 mode has no native UI, no built-in alerting, and the upstream metrics docs only cover the generic allocator and k8s-client metrics. The real failure modes in production — pool exhaustion, stale config on one speaker, a VIP flapping between nodes due to a crash-looping pod — are only visible if you correlate several raw counters together. This dashboard does that correlation work so you don't have to re-derive it during an incident.

## What's covered

### 1. Cluster Status (top row)
Quick at-a-glance cluster health, aggregated so it doesn't blow up into 15+ tiles on large clusters.

- **Speakers Config Loaded (sum)** — `sum(metallb_k8s_client_config_loaded_bool)`. Should equal your total speaker/node count. If it's lower, at least one speaker never successfully loaded a config and isn't doing ARP for its VIPs.
- **Speakers Config Stale (sum)** — `sum(metallb_k8s_client_config_stale_bool)`. Must be 0. Any value >0 means a speaker is running on an old config because the latest reload failed — usually a bad CR (IPAddressPool / L2Advertisement) applied to the cluster.
- **IPs In Use / Total Pool IPs / Pool Utilisation % / Free IPs Remaining** — from controller's `metallb_allocator_addresses_in_use_total` and `metallb_allocator_addresses_total`. These come from the **controller** pod, not the speaker — different deployment, different scrape target.

**Threshold logic:**
- Config Loaded: green only at full count (no fixed number, compare visually against known speaker count)
- Config Stale: green=0, red=anything ≥1 (zero-tolerance metric, no "yellow" zone — staleness is binary risk)
- Pool Utilisation %: green <70%, yellow 70–90%, red >90% — gives lead time to add IPs to the pool before exhaustion blocks new LoadBalancer services
- Free IPs Remaining: red <3, yellow <10, green ≥10 — small pools (common in on-prem L2 setups) hit zero fast, so the floor is deliberately low

### 2. Node Leadership Balance
Bar gauge: `sort_desc(sum by (node) (metallb_speaker_announced))`

Counts how many VIPs each node currently leads. In L2 mode only one node answers ARP for a given VIP at a time — if that ownership is lopsided (one node holding most VIPs), that node becomes a single point of failure for a large chunk of your LoadBalancer traffic. This panel has no color thresholds by design — it's a balance/shape check, not a pass/fail metric. You're looking for roughly even bar lengths across nodes, not a specific number.

### 3. Live Node-to-Service Mapping
Table fed by `metallb_speaker_announced{protocol="layer2"}`, trimmed to: VIP, Node, Speaker Pod, Service, Protocol, Announced. Dropped labels: `container`, `endpoint`, `job`, `namespace`, `prometheus`, `instance` — these are Prometheus scrape-plumbing labels with no operational value for a human reading the table during an incident.

This is your live source of truth for "which node is serving this VIP right now, and which service is it for" — the question you ask first when a service becomes unreachable.

### 4. L2 ARP/NDP — Requests, Responses & Drop Detection
Three panels, one logical flow: a client asks "who has this IP" (request), MetalLB answers (response), and the difference between the two (dropped) tells you if anyone went unanswered.

- **Requests Received** (`rate(metallb_layer2_requests_received[...])`) per VIP — normal baseline is very low (sub-1 req/s, often milli-req/s) because clients cache the ARP/NDP entry once resolved. Spikes mean new clients joining, expired caches, or a network storm.
- **Responses Sent** (`rate(metallb_layer2_responses_sent[...])`) per VIP — should track Requests Received almost exactly. A persistent gap below the request line means a speaker is failing to answer, which directly breaks ingress for that VIP.
- **Dropped/Ignored Requests** (cluster-wide delta: `sum(rate(requests)) - sum(rate(responses))`) — should sit flat at zero. Any sustained positive value, even small, means real client traffic is being silently ignored somewhere in the cluster. This is the cleanest single number to alert on (suggested: fire if >0 for 2+ minutes).

**Threshold logic:** Dropped Requests panel uses a hard red threshold at the smallest non-zero value (0.001) — there is no "acceptable" non-zero level for dropped ARP requests, so the threshold is effectively binary (zero = fine, anything else = alert).

### 5. Gratuitous ARP/NDP — Failover & Stability Signals
This is the section that actually tells you about failovers, because MetalLB has no dedicated "failover event" counter — gratuitous ARP/NDP sends are the closest proxy, since MetalLB sends them specifically when a VIP's leader changes.

- **Gratuitous Rate (per VIP)** — `rate(metallb_layer2_gratuitous_sent[...])`. Baseline is near-zero (occasional keep-alive style ticks to stop switches from expiring MAC table entries). A spike = a failover happened for that VIP. Sustained, repeating spikes (mountain pattern that never returns to baseline) = flapping, usually a crash-looping pod or split-brain leader election.
- **Gratuitous Rate (per Node)** — same metric, joined with `kube_pod_info{namespace="metallb-system"}` on the `pod` label to roll it up by physical node instead of VIP. Lets you see *which node* is doing the most failover work, separate from *which VIP* is unstable — useful when one node is flapping leadership for many VIPs at once (suggests a node-level problem, not a pod-level one). Requires kube-state-metrics scraped in the same Prometheus; if `kube_pod_info` isn't available this panel returns empty.
- **Gratuitous/Requests Ratio %** — `(100 * grat_rate / req_rate) and (req_rate > 0.01)`. This answers "is the failover traffic large relative to real client demand." Gated so it only computes when there's at least 0.01 req/s of real traffic — below that floor the original formula (with a `+0.001` safety constant) mathematically blows up to numbers like 133,000% purely because you're dividing by a near-zero denominator, not because anything is actually wrong. Gaps in this panel's line are expected on quiet L2 networks and mean "too little traffic to judge," not an error.

**Threshold logic:**
- Per-VIP gratuitous rate: orange at 0.5 pps, red at 2 pps — chosen because legitimate keep-alive gratuitous traffic is well under 0.1 pps in steady state; anything sustained above 0.5 pps means active re-announcement, not background noise
- Ratio %: red line at 50% — below 50% means client-driven ARP traffic still dominates; above 50% sustained means MetalLB's own failover chatter is outpacing real demand, a clear instability signal once the traffic-gate confirms the numbers are meaningful

### 6. Failover Severity — Cumulative Gratuitous Sends Ranked
Bar gauge: `sort_desc(metallb_layer2_gratuitous_sent)` — raw cumulative counter per VIP, ranked descending. This is the single most reliable panel in the dashboard because it's unaffected by the division/rate math issues above — it's just a counter, sorted.

**Threshold logic:** green <5,000, yellow 5,000–25,000, red >25,000. These aren't arbitrary — the distinguishing factor isn't the absolute number but how fast it got there:
- 25,000 reached over weeks of uptime = totally normal background accumulation (occasional keep-alive ticks add up over time)
- 25,000 reached in minutes or hours = active incident — almost always either a crash-looping pod forcing repeated leader migration, or a split-brain scenario where two nodes are fighting over the same VIP

Since Prometheus counters reset on pod restart, also check the **speaker uptime** alongside this panel before judging severity — a freshly restarted speaker will naturally show a low count regardless of historical instability.

## Metrics used

| Metric | Source pod | Purpose |
|---|---|---|
| `metallb_k8s_client_config_loaded_bool` | speaker | config health |
| `metallb_k8s_client_config_stale_bool` | speaker | config health |
| `metallb_allocator_addresses_in_use_total` | controller | pool usage |
| `metallb_allocator_addresses_total` | controller | pool usage |
| `metallb_speaker_announced` | speaker | VIP → node → service ownership |
| `metallb_layer2_requests_received` | speaker | ARP/NDP requests per VIP |
| `metallb_layer2_responses_sent` | speaker | ARP/NDP responses per VIP |
| `metallb_layer2_gratuitous_sent` | speaker | failover signal per VIP |
| `kube_pod_info` | kube-state-metrics | pod→node join for per-node gratuitous panel |

> `metallb_layer2_*` and `metallb_speaker_announced` are not listed on the upstream MetalLB Prometheus metrics docs page but are present in real speaker pod scrapes (Red Hat OpenShift MetalLB operator build).

## Import instructions

1. Grafana UI → Dashboards → New → Import
2. Upload `metallb-l2-dashboard.json`
3. Select your Prometheus datasource when prompted
4. Dashboard UID: `metallb-l2-v4`

## Requirements

- Prometheus scraping MetalLB speaker and controller pods (`metallb-system` namespace)
- kube-state-metrics scraped in the same Prometheus, for the per-node gratuitous ARP panel (`kube_pod_info` join)
- MetalLB running in L2 mode (these metrics are L2-specific; BGP mode uses different metrics and this dashboard won't be useful for it)

## Known caveats

- `metallb_speaker_announced` carries label cardinality per VIP/service/node — on large clusters with many LoadBalancer services this can be heavy; trim with `protocol="layer2"` filters as already done in the panels
- The gratuitous/requests ratio panel is gated to skip computation when request rate is near-zero (common on quiet L2 networks) — gaps in that panel are expected and not an error
- Per-node gratuitous panel requires `kube_pod_info` pod-name labels to match between MetalLB and kube-state-metrics — verify the join works in your environment before relying on it
- No native PromQL way to detect node-to-node VIP flap *history* from `metallb_speaker_announced` (it's a gauge showing only current state, not a log of past ownership) — use the ranked gratuitous-sends panel as the reliable flap/instability signal instead, or add a Grafana State Timeline panel querying the raw metric for a visual flap trace over time
- Counters reset on speaker pod restart — cross-check speaker uptime before treating a low cumulative gratuitous count as "stable"

