# check_api_latency_from_masters.sh

Measures connectivity timing from every OpenShift master node to the cluster API endpoint, using `curl` timing metrics via `oc debug`.

## What it does

For each master node, the script:
1. Opens an `oc debug` session into the node and runs `curl` against the API endpoint.
2. Captures DNS lookup, connect, TLS handshake, start-transfer, and total time.
3. Prints a table per node with each metric color-coded as `OK` / `WARN` / `CRIT` based on configurable thresholds.
4. Prints a final summary table comparing total time across all masters.

## Requirements

- `oc` CLI logged in with cluster access and permission to run `oc debug node/<name>`.
- `awk` available locally (used for ms conversion and threshold comparisons).
- A terminal that supports ANSI colors (most do; colors degrade gracefully to escape codes in non-TTY output/logs).

## Usage

```bash
chmod +x check_api_latency_from_masters.sh
./check_api_latency_from_masters.sh
```

No arguments are required. The script auto-discovers master nodes via:
```bash
oc get nodes -l node-role.kubernetes.io/master= -o name
```

## Configuration

Edit the top of the script:

```bash
OCP_URL="api.<example.com>:6443"
```
Set this to the API endpoint you want to test (`<host>:<port>`, no `https://`).

```bash
declare -A WARN_MS=( [dns]=5   [connect]=10  [tls]=50   [transfer]=100 [total]=100 )
declare -A CRIT_MS=( [dns]=20  [connect]=50  [tls]=150  [transfer]=300 [total]=300 )
```
Thresholds are in milliseconds. A metric turns yellow (`WARN`) at or above its `WARN_MS` value, and red (`CRIT`) at or above its `CRIT_MS` value. These are reasonable starting points for intra-cluster master-to-API calls — tune them once you've seen baseline numbers for your environment, since load balancer hops or air-gapped network paths may run higher than on-prem.

## Sample output

```
OpenShift API Connectivity Check
Endpoint: https://api.example.com:6443
================================================================================

Node: master-0
--------------------------------------------------------------------------
  Metric                   Time   Status
  DNS Lookup              1.000 ms   OK
  Connect                 3.000 ms   OK
  TLS Handshake          12.000 ms   OK
  Start Transfer         15.000 ms   OK
  Total                  16.000 ms   OK
--------------------------------------------------------------------------

Node: master-1
--------------------------------------------------------------------------
  Metric                   Time   Status
  DNS Lookup              2.000 ms   OK
  Connect                45.000 ms   WARN
  TLS Handshake         180.000 ms   CRIT
  Start Transfer        220.000 ms   WARN
  Total                 350.000 ms   CRIT
--------------------------------------------------------------------------

================================================================================
Summary (Total time per node)
--------------------------------------------------------------------------
  Node                              Total   Status
  master-0                       16.000 ms   OK
  master-1                      350.000 ms   CRIT
================================================================================
Connectivity test complete.
```

## Notes

- If a node can't be reached or `oc debug` fails, that node prints "Failed to reach endpoint from this node." and the script continues to the next one rather than aborting.
- If no master nodes are found (e.g. not logged in, wrong context), the script exits early with an error message instead of producing empty output.
- All `curl` timing values from `time_namelookup`, `time_connect`, etc. are cumulative from the start of the request, not deltas between stages — this matches curl's native behavior.
- The script does not clean up `oc debug` pods, set per-node timeouts, or exit non-zero on `CRIT` status — it's intended for interactive/manual checks rather than automated alerting.
