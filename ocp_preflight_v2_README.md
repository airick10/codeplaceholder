# OpenShift Pre-Flight & Inventory v2.0

Bash-based, **read-only** upgrade-preparation tool for disconnected OpenShift clusters. Extends the original `ocp_preflight.sh` concept while retaining terminal PASS/WARN/FAIL results, investigation commands and health checks. New inventory features use `oc -o json` and `jq` rather than parsing display columns.

## Requirements

- Bash 4 or newer
- Authenticated `oc` CLI with sufficient read privileges (`oc whoami --show-server` must work)
- `jq`
- Optional: `skopeo` and registry credentials for `--mirror-tags`

No third-party Python packages or external network requests are needed. `skopeo` queries only the catalog registries advertised by the cluster.

## Run

```bash
chmod +x ocp_preflight_v2.sh
./ocp_preflight_v2.sh                        # health only (original default)
./ocp_preflight_v2.sh --inventory             # Operator/catalog inventory
./ocp_preflight_v2.sh --preflight             # both
./ocp_preflight_v2.sh --inventory --operator mtv-operator
./ocp_preflight_v2.sh --preflight --target 4.20.42 --json --output ./reports
./ocp_preflight_v2.sh --inventory --mirror-tags
./ocp_preflight_v2.sh --help
```

**Terminal output is always printed.** `--json` adds a structured, timestamped report below `--output/<context>/<UTC timestamp>/`.

## Sections

Health: ClusterOperators, MCPs (including paused), node readiness/cordons/pressure, CPU/memory (when Metrics API works), pending CSRs, pending pods, container waiting errors, cumulative restart counts, PVCs, active PDBs with zero disruption allowance, MHCs, retained warning events.

Inventory: ClusterVersion, Subscriptions (including installed/current CSV, channel, approval and CatalogSource), CatalogSources and their image references, currently published PackageManifest channel heads, InstallPlans and CSVs, IDMS/ITMS source-to-mirror mappings. `--mirror-tags` optionally lists catalog repository tags using `skopeo`.

`--target X.Y.Z` adds a **preliminary** readiness section: Upgradeable condition, reported available updates, APIRequestCounts, `admin-acks`, release signature ConfigMap names/keys and human-review tasks.

## Important interpretation and limitations

- A visible catalog tag **does not prove** it contains a target Operator version, complete operand images, or a valid OLM upgrade path.
- A PackageManifest shows versions **advertised by configured catalogs**, not everything in the internal mirror and not necessarily what's installed.
- Signature ConfigMap discovery **does not cryptographically verify** the signature for a target release. The tool deliberately returns UNKNOWN for that requirement.
- A disconnected cluster can report no available updates because the public update graph is unreachable. Confirm the exact target upgrade edge separately.
- `--target` does not automatically establish support for an OCP or Operator upgrade. Compatibility and backup validation remain explicit tasks.
- `--mirror-tags` is an optional inventory convenience. Network reachability from the **bastion** doesn't prove nodes can pull the same images.
- Pod restart counts are cumulative, not necessarily new incidents. PDBs with expectedPods=0 are excluded from the active PDB warning.
- No remediation, patches, upgrades, approval changes, or other OpenShift write operations are performed.

## Status and exit codes

- PASS: the specific test passed based on available evidence.
- WARN: a condition needs review but may be expected.
- FAIL: unhealthy condition found.
- UNKNOWN: the tool couldn't obtain sufficient evidence (never counted as PASS).

Exit `0`: no WARN/FAIL/UNKNOWN in selected checks; exit `1`: one or more WARN/UNKNOWN; exit `2`: one or more FAIL; exit `3`: tool setup / authentication failure.

For unattended jobs, treat `1` as a review status, not automatically a failed upgrade. A `0` is **not** an authorization to upgrade.

## Known implementation boundaries

This version uses Bash/JQ and makes normal read-only API calls. On very large clusters, `oc get pods -A -o json`, PackageManifest queries, and terminal rendering can take time. The report intentionally does not collect Kubernetes Secrets. Review JSON reports before sharing because API server hostnames, namespaces, and image paths may be sensitive within your organization.

Before any production adoption, validate this utility against your organization's supported `oc`/`jq` versions, RBAC permissions, disconnected mirror conventions, and representative cluster workloads. It has been syntax-checked and mock-tested, **not executed against your live clusters**.
