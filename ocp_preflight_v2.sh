#!/usr/bin/env bash
# OpenShift Pre-Flight & Inventory Utility v2.0
# Read-only: no oc patch/apply/adm upgrade or other cluster mutations.
# Requires bash 4+, oc, jq. Optional: skopeo for --mirror-tags.

set -o pipefail
VERSION_TOOL='2.0.0'
MODE='health'
TARGET=''
OPERATOR=''
WRITE_JSON=false
OUTPUT_DIR='./reports'
MIRROR_TAGS=false
PASS=0; WARN=0; FAIL=0; UNKNOWN=0
INVESTIGATE=()
RESULTS='[]'
WORKDIR=''
CLUSTER_ID='unknown'
CLUSTER_VERSION='unknown'
CHANNEL='unknown'
SERVER='unknown'

usage() {
cat <<'HELP'
OpenShift Pre-Flight & Inventory Utility v2.0 (READ-ONLY)

Usage: ocp_preflight_v2.sh [--health | --inventory | --preflight] [options]

Modes (choose one; default is --health):
  --health             Cluster health checks (original script's intent)
  --inventory          Cluster, Operator, catalog and mirror inventory
  --preflight          Both health checks and inventory

Options:
  --target VERSION     Proposed OCP target (reports upgrade prerequisites; no changes)
  --operator NAME      Limit detailed Operator inventory to package/subscription NAME
  --mirror-tags        Query registry tags for active catalog repositories with skopeo
  --json               Write timestamped structured JSON report alongside terminal output
  --output DIR         Output root for JSON reports (default: ./reports)
  --help, -h           Show help
  --version            Show version

Examples:
  ./ocp_preflight_v2.sh
  ./ocp_preflight_v2.sh --inventory
  ./ocp_preflight_v2.sh --preflight --target 4.20.42 --json
  ./ocp_preflight_v2.sh --inventory --operator mtv-operator --mirror-tags

Exit codes: 0 = no findings; 1 = WARN or UNKNOWN; 2 = FAIL; 3 = tool/setup error.
UNKNOWN means evidence could not be obtained. It is never treated as PASS.
This script never installs images, changes channels, approves plans, or upgrades OCP.
HELP
}

fatal() { printf '[ERROR] %s\n' "$*" >&2; exit 3; }
cleanup() { [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf -- "$WORKDIR"; }
trap cleanup EXIT

while (($#)); do
  case "$1" in
    --health) MODE='health'; shift ;;
    --inventory) MODE='inventory'; shift ;;
    --preflight) MODE='preflight'; shift ;;
    --target|--operator|--output)
      opt="$1"; (($# >= 2)) || fatal "Missing value for $opt"
      case "$opt" in
        --target) TARGET="$2" ;;
        --operator) OPERATOR="$2" ;;
        --output) OUTPUT_DIR="$2" ;;
      esac
      shift 2 ;;
    --json) WRITE_JSON=true; shift ;;
    --mirror-tags) MIRROR_TAGS=true; shift ;;
    --help|-h) usage; exit 0 ;;
    --version) echo "$VERSION_TOOL"; exit 0 ;;
    *) fatal "Unrecognized argument: $1 (use --help)" ;;
  esac
done

command -v oc >/dev/null 2>&1 || fatal 'oc CLI not found'
command -v jq >/dev/null 2>&1 || fatal 'jq not found'
if $MIRROR_TAGS && ! command -v skopeo >/dev/null 2>&1; then
  fatal '--mirror-tags requires skopeo (omit the option if unavailable)'
fi
[[ -z "$TARGET" || "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fatal '--target must be X.Y.Z'
WORKDIR=$(mktemp -d) || fatal 'Unable to create temporary directory'

heading() { printf '\n========== %s ==========\n' "$1"; }
record() {
  local level="$1" section="$2" message="$3" details="${4:-}"
  printf '[%-7s] %s\n' "$level" "$message"
  [[ -n "$details" ]] && printf '%s\n' "$details" | sed 's/^/           /'
  case "$level" in PASS) ((PASS+=1));; WARN) ((WARN+=1));; FAIL) ((FAIL+=1));; UNKNOWN) ((UNKNOWN+=1));; esac
  RESULTS=$(jq -cn --argjson old "$RESULTS" --arg level "$level" --arg section "$section" --arg message "$message" --arg detail "$details" '$old + [{level:$level,section:$section,message:$message,detail:$detail}]')
}
pass() { record PASS "$1" "$2" "${3:-}"; }
warn() { record WARN "$1" "$2" "${3:-}"; }
fail() { record FAIL "$1" "$2" "${3:-}"; }
unknown() { record UNKNOWN "$1" "$2" "${3:-}"; }
investigate() { INVESTIGATE+=("$1|$2"); }

# Capture JSON once per API; errors never become empty successful results.
fetch() {
  local key="$1"; shift
  if oc get "$@" -o json >"$WORKDIR/$key.json" 2>"$WORKDIR/$key.err" && jq -e 'type=="object"' "$WORKDIR/$key.json" >/dev/null 2>&1; then
    return 0
  fi
  rm -f -- "$WORKDIR/$key.json"
  return 1
}
has() { [[ -s "$WORKDIR/$1.json" ]]; }
readjson() { cat -- "$WORKDIR/$1.json"; }
count() { jq -r "$2" "$WORKDIR/$1.json"; }

identify_cluster() {
  SERVER=$(oc whoami --show-server 2>/dev/null || true)
  [[ -n "$SERVER" ]] || fatal 'Unable to identify OpenShift API server; verify oc login/context'
  CLUSTER_ID=$(oc config current-context 2>/dev/null || echo 'unknown')
  fetch cv clusterversion version || fatal 'Unable to read ClusterVersion; check authentication/RBAC'
  CLUSTER_VERSION=$(count cv '.status.desired.version // .status.history[0].version // "unknown"')
  CHANNEL=$(count cv '.spec.channel // "unspecified"')
  printf '\n============================================\n'
  printf ' OPENSHIFT PRE-FLIGHT & INVENTORY v%s\n' "$VERSION_TOOL"
  printf ' %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  printf '============================================\n'
  printf 'Context: %s\nAPI: %s\nVersion: %s\nChannel: %s\nMode: %s\n' "$CLUSTER_ID" "$SERVER" "$CLUSTER_VERSION" "$CHANNEL" "$MODE"
  [[ -z "$TARGET" ]] || printf 'Target (proposed): %s\n' "$TARGET"
}

health_checks() {
  heading 'CLUSTER HEALTH'
  local bad n output
  if fetch co co; then
    bad=$(jq -r '.items[] | .metadata.name as $n | ([.status.conditions[]? | select(.type=="Available") | .status][0] // "Unknown") as $a | ([.status.conditions[]? | select(.type=="Progressing") | .status][0] // "Unknown") as $p | ([.status.conditions[]? | select(.type=="Degraded") | .status][0] // "Unknown") as $d | select($a!="True" or $p!="False" or $d!="False") | "\($n): Available=\($a), Progressing=\($p), Degraded=\($d)"' "$WORKDIR/co.json")
    if [[ -z "$bad" ]]; then pass 'ClusterOperators' 'All ClusterOperators healthy'; else fail 'ClusterOperators' 'ClusterOperator conditions require attention' "$bad"; investigate 'ClusterOperators' 'oc get co'; fi
  else unknown 'ClusterOperators' 'Could not retrieve ClusterOperators'; fi

  if fetch mcp mcp; then
    bad=$(jq -r '.items[] | .metadata.name as $n | ([.status.conditions[]? | select(.type=="Updated") | .status][0] // "Unknown") as $u | ([.status.conditions[]? | select(.type=="Updating") | .status][0] // "Unknown") as $g | ([.status.conditions[]? | select(.type=="Degraded") | .status][0] // "Unknown") as $d | select($u!="True" or $g!="False" or $d!="False") | "\($n): Updated=\($u), Updating=\($g), Degraded=\($d)"' "$WORKDIR/mcp.json")
    if [[ -z "$bad" ]]; then pass MCP 'All MachineConfigPools healthy'; else fail MCP 'MachineConfigPool conditions require attention' "$bad"; investigate MCP 'oc get mcp'; fi
    bad=$(jq -r '.items[] | select(.spec.paused==true) | .metadata.name' "$WORKDIR/mcp.json")
    if [[ -z "$bad" ]]; then pass MCP 'No paused MCPs'; else warn MCP 'Paused MCPs found; check whether intentional' "$bad"; fi
  else unknown MCP 'Could not retrieve MachineConfigPools'; fi

  if fetch nodes nodes; then
    n=$(count nodes '.items|length')
    bad=$(jq -r '.items[] | .metadata.name as $n | ([.status.conditions[]? | select(.type=="Ready") | .status][0] // "Unknown") as $r | select($r!="True") | "\($n): Ready=\($r)"' "$WORKDIR/nodes.json")
    if [[ -z "$bad" ]]; then pass Nodes "All $n nodes Ready"; else fail Nodes 'Nodes not Ready' "$bad"; investigate Nodes 'oc get nodes -o wide'; fi
    bad=$(jq -r '.items[] | select(.spec.unschedulable==true) | .metadata.name' "$WORKDIR/nodes.json")
    if [[ -z "$bad" ]]; then pass Nodes 'No nodes cordoned'; else warn Nodes 'Cordoned nodes' "$bad"; fi
    bad=$(jq -r '.items[] | .metadata.name as $n | .status.conditions[]? | select((.type=="DiskPressure" or .type=="MemoryPressure" or .type=="PIDPressure") and .status=="True") | "\($n): \(.type)"' "$WORKDIR/nodes.json")
    if [[ -z "$bad" ]]; then pass Nodes 'No node pressure conditions'; else fail Nodes 'Node pressure detected' "$bad"; fi
  else unknown Nodes 'Could not retrieve Nodes'; fi

  if output=$(oc adm top nodes --no-headers 2>/dev/null) && [[ -n "$output" ]]; then
    bad=$(printf '%s\n' "$output" | awk 'NF>=5 {cpu=$3;gsub(/%/,"",cpu); if((cpu+0)>=80) print $1 " CPU=" $3}')
    if [[ -z "$bad" ]]; then pass Utilization 'No nodes at or above 80% CPU'; else warn Utilization 'High node CPU utilization' "$bad"; fi
    bad=$(printf '%s\n' "$output" | awk 'NF>=5 {mem=$5;gsub(/%/,"",mem); if((mem+0)>=80) print $1 " MEM=" $5}')
    if [[ -z "$bad" ]]; then pass Utilization 'No nodes at or above 80% memory'; else warn Utilization 'High node memory utilization' "$bad"; fi
  else unknown Utilization 'Node metrics unavailable'; fi

  if fetch csr csr; then
    bad=$(jq -r '.items[] | select((.status.conditions // [] | length)==0) | .metadata.name' "$WORKDIR/csr.json")
    if [[ -z "$bad" ]]; then pass CSR 'No pending CSRs'; else warn CSR 'Pending CSRs' "$bad"; investigate CSR 'oc get csr'; fi
  else unknown CSR 'Could not retrieve CSRs'; fi

  if fetch pods pods -A; then
    bad=$(jq -r '.items[] | select(.status.phase=="Pending") | "\(.metadata.namespace)/\(.metadata.name)"' "$WORKDIR/pods.json")
    n=$(printf '%s\n' "$bad" | awk 'NF{n++} END{print n+0}')
    if ((n==0)); then pass Pods 'No Pending pods'; else warn Pods "$n Pending pods" "$(printf '%s\n' "$bad" | head -10)"; investigate Pods 'oc get pods -A'; fi
    bad=$(jq -r '.items[] | .metadata.namespace as $ns | .metadata.name as $p | ([.status.containerStatuses[]?.restartCount] | add // 0) as $r | select($r>=10) | "\($ns)/\($p): \($r) restarts"' "$WORKDIR/pods.json")
    n=$(printf '%s\n' "$bad" | awk 'NF{n++} END{print n+0}')
    if ((n==0)); then pass Pods 'No pods with 10+ restarts'; else warn Pods "$n pods with 10+ cumulative restarts (compare baseline)" "$(printf '%s\n' "$bad" | head -10)"; fi
    bad=$(jq -r '.items[] | .metadata.namespace as $ns | .metadata.name as $p | [.status.containerStatuses[]? | select(.state.waiting.reason? | IN("CrashLoopBackOff","ImagePullBackOff","ErrImagePull","CreateContainerError")) | .state.waiting.reason] | .[] | "\($ns)/\($p): \(.)"' "$WORKDIR/pods.json")
    if [[ -z "$bad" ]]; then pass Pods 'No detected critical container waiting reasons'; else warn Pods 'Container waiting errors found' "$(printf '%s\n' "$bad" | head -10)"; fi
  else unknown Pods 'Could not retrieve all-namespace Pods'; fi

  if fetch pvc pvc -A; then
    bad=$(jq -r '.items[] | select(.status.phase != "Bound") | "\(.metadata.namespace)/\(.metadata.name): \(.status.phase // "Unknown")"' "$WORKDIR/pvc.json")
    if [[ -z "$bad" ]]; then pass PVC 'All PVCs Bound'; else warn PVC 'PVCs not Bound (may include intentionally Pending)' "$(printf '%s\n' "$bad" | head -10)"; fi
  else unknown PVC 'Could not retrieve PVCs'; fi

  if fetch pdb pdb -A; then
    bad=$(jq -r '.items[] | select((.status.disruptionsAllowed // -1)==0 and (.status.expectedPods // 0)>0) | "\(.metadata.namespace)/\(.metadata.name) (healthy=\(.status.currentHealthy // "?") desired=\(.status.desiredHealthy // "?") expected=\(.status.expectedPods))"' "$WORKDIR/pdb.json")
    n=$(printf '%s\n' "$bad" | awk 'NF{n++} END{print n+0}')
    if ((n==0)); then pass PDB 'No active PDBs with zero allowed disruptions'; else warn PDB "$n active PDB(s) with zero allowed disruptions" "$(printf '%s\n' "$bad" | head -10)"; investigate PDB 'oc get pdb -A'; fi
  else unknown PDB 'Could not retrieve PDBs'; fi

  if fetch mhc machinehealthchecks -n openshift-machine-api; then
    n=$(count mhc '.items|length')
    if ((n==0)); then warn MHC 'No MachineHealthChecks found (may be expected)'; else pass MHC "$n MachineHealthChecks inventoried"; fi
    bad=$(jq -r '.items[] | select(.spec.maxUnhealthy=="100%") | .metadata.name' "$WORKDIR/mhc.json")
    if [[ -n "$bad" ]]; then warn MHC 'MHC maxUnhealthy=100%; verify approved upgrade procedure' "$bad"; fi
  else unknown MHC 'MachineHealthChecks unavailable or not applicable'; fi

  if fetch events events -A --field-selector type=Warning; then
    n=$(count events '.items|length')
    if ((n==0)); then pass Events 'No currently retained Warning events'; else warn Events "$n retained Warning events (not necessarily new)"; investigate Events 'oc get events -A --field-selector type=Warning --sort-by=.lastTimestamp'; fi
  else unknown Events 'Could not retrieve Warning events'; fi
}

inventory_checks() {
  heading 'CLUSTER INVENTORY'
  printf 'Desired release image: %s\n' "$(count cv '.spec.desiredUpdate.image // .status.desired.image // "unspecified"')"
  printf 'Update server: %s\n' "$(count cv '.spec.upstream // "default"')"
  printf 'Upgradeable: %s\n' "$(jq -r '[.status.conditions[]? | select(.type=="Upgradeable") | .status + " (" + (.reason // "") + ")"] | join(", ")' "$WORKDIR/cv.json")"
  local key name bad n
  heading 'OPERATOR SUBSCRIPTIONS'
  if ! fetch subscriptions subscriptions -A; then unknown Inventory 'Cannot retrieve Subscriptions'; else
    jq -r --arg op "$OPERATOR" '.items[] | select($op=="" or .metadata.name==$op or .spec.name==$op) | [.metadata.namespace,.metadata.name,(.spec.name // "-"),(.spec.channel // "-"),(.status.installedCSV // "-"),(.status.currentCSV // "-"),(.spec.source // "-"),(.spec.installPlanApproval // "-")] | @tsv' "$WORKDIR/subscriptions.json" | awk 'BEGIN{print "NAMESPACE\tSUBSCRIPTION\tPACKAGE\tCHANNEL\tINSTALLED CSV\tCURRENT CSV\tSOURCE\tAPPROVAL"} {print}'
    n=$(jq --arg op "$OPERATOR" '[.items[] | select($op=="" or .metadata.name==$op or .spec.name==$op)] | length' "$WORKDIR/subscriptions.json")
    if ((n==0)); then warn Inventory "No subscriptions matched '${OPERATOR:-any}'"; else pass Inventory "$n Subscription(s) inventoried"; fi
    bad=$(jq -r --arg op "$OPERATOR" '.items[] | select($op=="" or .metadata.name==$op or .spec.name==$op) | select((.status.installedCSV // "") != (.status.currentCSV // "")) | "\(.metadata.namespace)/\(.metadata.name): \(.status.installedCSV // "-") != \(.status.currentCSV // "-")"' "$WORKDIR/subscriptions.json")
    [[ -z "$bad" ]] || warn Inventory 'Subscription installedCSV/currentCSV differ; investigate' "$bad"
  fi

  heading 'CATALOG SOURCES'
  if fetch catalogs catalogsources -A; then
    jq -r '.items[] | [.metadata.namespace,.metadata.name,(.spec.image // "-")] | @tsv' "$WORKDIR/catalogs.json" | awk 'BEGIN{print "NAMESPACE\tNAME\tCATALOG IMAGE"}{print}'
    pass Inventory "$(count catalogs '.items|length') CatalogSource(s) inventoried"
  else unknown Inventory 'Cannot retrieve CatalogSources'; fi

  heading 'PACKAGEMANIFEST CHANNEL HEADS'
  if fetch packages packagemanifests -A; then
    if has subscriptions; then
      jq -nr --slurpfile pkgs "$WORKDIR/packages.json" --slurpfile subs "$WORKDIR/subscriptions.json" --arg op "$OPERATOR" '
        ($subs[0].items | map(select($op=="" or .metadata.name==$op or .spec.name==$op))) as $wanted |
        ["PACKAGE\tCATALOG\tCHANNEL\tHEAD CSV"] +
        [ $wanted[] as $s | $pkgs[0].items[] |
          select(.status.packageName == $s.spec.name and .status.catalogSource == $s.spec.source and .status.catalogSourceNamespace == $s.spec.sourceNamespace) |
          . as $p | .status.channels[]? |
          "\($s.spec.name)\t\($p.status.catalogSource)\t\(.name)\t\(.currentCSV // "-")" ] | .[]'
    else printf 'Subscription inventory unavailable; cannot match packages to subscriptions\n'; fi
    if (( $(count packages '.items|length') > 0 )); then pass Inventory 'PackageManifest catalog-channel data collected (channel heads are not installed versions)'; else unknown Inventory 'PackageManifests returned no entries'; fi
  else unknown Inventory 'Cannot retrieve PackageManifests (API or permissions may be unavailable)'; fi

  heading 'INSTALLPLANS / CSVs'
  if fetch installplans installplans -A; then
    jq -r '.items[] | select(.status.phase != "Complete" or .spec.approved != true) | "\(.metadata.namespace)/\(.metadata.name): phase=\(.status.phase // "Unknown"), approved=\(.spec.approved // false)"' "$WORKDIR/installplans.json" | head -25
    pass Inventory "$(count installplans '.items|length') InstallPlans inventoried"
  else unknown Inventory 'Cannot retrieve InstallPlans'; fi
  if fetch csvs csv -A; then
    bad=$(jq -r '.items[] | select(.status.phase != "Succeeded") | "\(.metadata.namespace)/\(.metadata.name): \(.status.phase // "Unknown")"' "$WORKDIR/csvs.json")
    if (( $(count csvs '.items|length') == 0 )); then unknown Inventory 'No installed CSVs were returned'; elif [[ -z "$bad" ]]; then pass Inventory 'All inventoried CSVs Succeeded'; else warn Inventory 'Non-Succeeded CSVs found' "$(printf '%s\n' "$bad" | head -15)"; fi
  else unknown Inventory 'Cannot retrieve CSVs'; fi

  heading 'MIRROR CONFIGURATION'
  for key in idms itms; do
    if [[ "$key" == idms ]]; then
      if fetch "$key" imagedigestmirrorsets; then :; else unknown Mirror 'Cannot retrieve ImageDigestMirrorSets'; continue; fi
      printf 'ImageDigestMirrorSets: %s\n' "$(count idms '.items|length')"
      jq -r '.items[] | .metadata.name as $name | .spec.imageDigestMirrors[]? | "  \($name): \(.source) -> \(.mirrors | join(", ")) (policy=\(.mirrorSourcePolicy // "default"))"' "$WORKDIR/idms.json" | head -40
    else
      if fetch "$key" imagetagmirrorsets; then :; else unknown Mirror 'Cannot retrieve ImageTagMirrorSets'; continue; fi
      printf 'ImageTagMirrorSets: %s\n' "$(count itms '.items|length')"
      jq -r '.items[] | .metadata.name as $name | .spec.imageTagMirrors[]? | "  \($name): \(.source) -> \(.mirrors | join(", ")) (policy=\(.mirrorSourcePolicy // "default"))"' "$WORKDIR/itms.json" | head -40
    fi
  done
  printf 'Note: mirror mappings show pull routing; they do not prove image availability.\n'

  if $MIRROR_TAGS; then
    heading 'CATALOG IMAGE TAGS (SKOPEO)'
    if has catalogs; then
      mkdir -p "$WORKDIR/tags"
      while IFS= read -r repo; do
        [[ -n "$repo" ]] || continue
        name=$(printf '%s' "$repo" | tr '/:' '__')
        printf '%s\n' "$repo"
        if skopeo list-tags "docker://$repo" >"$WORKDIR/tags/$name.json" 2>"$WORKDIR/tags/$name.err"; then
          jq -r '.Tags[]?' "$WORKDIR/tags/$name.json" | tail -20 | sed 's/^/  /'
        else
          unknown Mirror "Cannot list tags: $repo" "$(head -1 "$WORKDIR/tags/$name.err")"
        fi
      done < <(jq -r '.items[].spec.image // empty | sub("@sha256:.*$"; "") | sub(":([^/:]+)$"; "")' "$WORKDIR/catalogs.json" | sort -u)
    else unknown Mirror 'CatalogSource images unavailable for skopeo'; fi
  fi
}

readiness_checks() {
  [[ -n "$TARGET" ]] || return 0
  heading "TARGET READINESS: $TARGET"
  if [[ "$TARGET" == "$CLUSTER_VERSION" ]]; then warn Readiness 'Target equals current cluster version'; fi
  local gate message
  gate=$(jq -r '[.status.conditions[]? | select(.type=="Upgradeable") | (.status // "Unknown") + " | " + (.reason // "") + " | " + (.message // "")] | join("\n")' "$WORKDIR/cv.json")
  if [[ -n "$gate" ]]; then
    if grep -q '^False' <<<"$gate"; then warn Readiness 'Upgradeable=False; investigate applicability to target version' "$gate"; else pass Readiness 'No Upgradeable=False condition reported'; fi
  else unknown Readiness 'No Upgradeable condition returned'; fi
  printf 'Available updates reported by cluster: '
  message=$(jq -r '[.status.availableUpdates[]?.version] | join(", ")' "$WORKDIR/cv.json")
  printf '%s\n' "${message:-none (normal on disconnected clusters)}"
  unknown Readiness 'Supported target upgrade edge not verified by this script; check Red Hat update graph or local OSUS'
  unknown Readiness 'Target release payload completeness, signature matching and image pull access require external verification'
  unknown Readiness 'Operator-to-target compatibility and upgrade sequences require product documentation review'
  unknown Readiness 'Fresh etcd + application backups and recovery arrangements require human confirmation'
  if fetch apirequests apirequestcounts; then
    printf 'APIs flagged for removal (review requests in current hour / last 24h):\n'
    jq -r '.items[] | select((.status.removedInRelease // "")!="") | "  \(.metadata.name): removedIn=\(.status.removedInRelease), currentHour=\(.status.currentHour.requestCount // "unknown"), last24h=\(.status.last24h | if type=="array" then (map(.requestCount // 0)|add // 0) else (.requestCount // "unknown") end)"' "$WORKDIR/apirequests.json" | head -25
    pass Readiness 'APIRequestCounts retrieved; inspect APIs removed in target Kubernetes release'
  else unknown Readiness 'Could not retrieve APIRequestCounts'; fi
  if fetch adminacks cm admin-acks -n openshift-config; then
    printf 'Admin acknowledgments currently recorded:\n'
    jq -r '.data // {} | to_entries[] | "  \(.key)=\(.value)"' "$WORKDIR/adminacks.json" | head -30
  else unknown Readiness 'Could not retrieve admin-acks ConfigMap'; fi
  if fetch signatures configmaps -n openshift-config-managed -l release.openshift.io/verification-signatures; then
    printf 'Release signature ConfigMaps currently labeled: %s\n' "$(count signatures '.items|length')"
    unknown Readiness 'Signature ConfigMaps inventoried, but target release digest/signature not cryptographically verified'
  else unknown Readiness 'Unable to retrieve signature ConfigMaps'; fi
}

write_report() {
  $WRITE_JSON || return 0
  local timestamp slug dir
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  slug=$(printf '%s' "$CLUSTER_ID" | tr -cs 'A-Za-z0-9_.-' '_' | cut -c1-90)
  dir="$OUTPUT_DIR/${slug:-cluster}/$timestamp"
  mkdir -p -- "$dir" || { warn Report 'Unable to create output directory'; return 0; }
  # Use extracted, bounded fields; no credentials or Secret resources are requested.
  local src
  for src in cv co mcp nodes csr pods pvc pdb mhc events subscriptions catalogs packages installplans csvs idms itms apirequests adminacks signatures; do
    if has "$src"; then
      case "$src" in
        pods) jq '{count:(.items|length),items:[.items[]|{namespace:.metadata.namespace,name:.metadata.name,phase:.status.phase,containerStatuses:[.status.containerStatuses[]?|{name,restartCount,state}]}]}' "$WORKDIR/$src.json" >"$dir/$src.json" ;;
        subscriptions) jq '{items:[.items[] | {namespace:.metadata.namespace,name:.metadata.name,package:.spec.name,channel:.spec.channel,source:.spec.source,sourceNamespace:.spec.sourceNamespace,approval:.spec.installPlanApproval,installedCSV:.status.installedCSV,currentCSV:.status.currentCSV}]}' "$WORKDIR/$src.json" >"$dir/$src.json" ;;
        catalogs) jq '{items:[.items[] | {namespace:.metadata.namespace,name:.metadata.name,image:.spec.image,status:.status.connectionState.lastObservedState}]}' "$WORKDIR/$src.json" >"$dir/$src.json" ;;
        packages) jq '{items:[.items[] | {package:.status.packageName,catalog:.status.catalogSource,catalogNamespace:.status.catalogSourceNamespace,channels:[.status.channels[]?|{name,currentCSV}]}]}' "$WORKDIR/$src.json" >"$dir/$src.json" ;;
        adminacks) jq '{data:(.data // {})}' "$WORKDIR/$src.json" >"$dir/$src.json" ;;
        signatures) jq '{items:[.items[]|{name:.metadata.name,namespace:.metadata.namespace,signatureKeys:(.binaryData // {} | keys)}]}' "$WORKDIR/$src.json" >"$dir/$src.json" ;;
        *) jq '.' "$WORKDIR/$src.json" >"$dir/$src.json" ;;
      esac
    fi
  done
  jq -n --arg toolVersion "$VERSION_TOOL" --arg context "$CLUSTER_ID" --arg server "$SERVER" --arg clusterVersion "$CLUSTER_VERSION" --arg channel "$CHANNEL" --arg target "$TARGET" --arg mode "$MODE" --arg timestamp "$timestamp" --argjson checks "$RESULTS" --argjson pass "$PASS" --argjson warn "$WARN" --argjson fail "$FAIL" --argjson unknown "$UNKNOWN" '{toolVersion:$toolVersion,context:$context,apiServer:$server,version:$clusterVersion,channel:$channel,target:$target,mode:$mode,timestamp:$timestamp,summary:{pass:$pass,warn:$warn,fail:$fail,unknown:$unknown},checks:$checks}' >"$dir/report.json"
  printf '\nJSON report saved under: %s\n' "$dir"
}

summary() {
  heading 'SUMMARY'
  printf 'PASS: %s  WARN: %s  FAIL: %s  UNKNOWN: %s\n' "$PASS" "$WARN" "$FAIL" "$UNKNOWN"
  if ((FAIL>0)); then printf 'RESULT: FAIL conditions require investigation.\n'
  elif ((WARN>0 || UNKNOWN>0)); then printf 'RESULT: Review WARN/UNKNOWN findings. Not an automatic upgrade approval.\n'
  else printf 'RESULT: No issues detected by selected checks; not a guarantee of upgrade readiness.\n'; fi
  if ((${#INVESTIGATE[@]}>0)); then
    heading 'INVESTIGATE'
    local entry reason command previous=''
    for entry in "${INVESTIGATE[@]}"; do
      reason=${entry%%|*}; command=${entry#*|}
      if [[ "$reason" != "$previous" ]]; then printf '\n%s:\n' "$reason"; previous="$reason"; fi
      printf '  %s\n' "$command"
    done
  fi
}

identify_cluster
case "$MODE" in
  health) health_checks ;;
  inventory) inventory_checks ;;
  preflight) health_checks; inventory_checks ;;
esac
readiness_checks
summary
write_report
if ((FAIL>0)); then exit 2; fi
if ((WARN>0 || UNKNOWN>0)); then exit 1; fi
exit 0
