#!/usr/bin/env bash

# ------------------------------------------------------------
# OpenShift Upgrade Pre-Flight Check + Inventory
# Version: 2.1 (readable edition)
# READ ONLY - this script makes NO changes to the cluster.
#
# Requires: bash 4+, oc, jq
# Optional: skopeo (only when using --mirror-tags)
#
# Default: run original-style health checks.
# See: ./ocp_preflight_readable.sh --help
# ------------------------------------------------------------

set -o pipefail

SCRIPT_VERSION="2.1"
MODE="health"
TARGET=""
OPERATOR=""
SAVE_JSON=false
MIRROR_TAGS=false
OUTPUT_DIR="./reports"

PASS=0
WARN=0
FAIL=0
UNKNOWN=0
INVESTIGATE=()

# The script writes temporary API results here, then removes them.
TEMP_DIR=""
trap '[[ -z "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"' EXIT

# ------------------------------------------------------------
# Help / command-line options
# ------------------------------------------------------------

show_help() {
    cat <<'HELP'
OpenShift Pre-Flight + Inventory (read-only)

Usage: ./ocp_preflight_readable.sh [mode] [options]

Modes (one at a time; default is --health):
  --health              Run the original health checks
  --inventory           Collect Operators, catalogs, mirrors and channels
  --preflight           Run BOTH health and inventory

Options:
  --target VERSION      Review prerequisites for a proposed OCP upgrade
  --operator NAME       Limit Operator inventory to a named package/subscription
  --mirror-tags         Ask skopeo for tags in catalog image repositories
  --json                Save a timestamped JSON report AND print to terminal
  --output DIRECTORY    Choose JSON report directory (default: ./reports)
  --version             Show script version
  --help                Show this help

Examples:
  ./ocp_preflight_readable.sh
  ./ocp_preflight_readable.sh --inventory
  ./ocp_preflight_readable.sh --preflight --json
  ./ocp_preflight_readable.sh --inventory --operator mtv-operator
  ./ocp_preflight_readable.sh --preflight --target 4.20.42 --json

Exit codes: 0 = no findings; 1 = WARN/UNKNOWN; 2 = FAIL; 3 = setup error.
This script does NOT approve, patch, upgrade, or install anything.
HELP
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --health)       MODE="health"; shift ;;
        --inventory)    MODE="inventory"; shift ;;
        --preflight)    MODE="preflight"; shift ;;
        --json)         SAVE_JSON=true; shift ;;
        --mirror-tags)  MIRROR_TAGS=true; shift ;;
        --help|-h)      show_help; exit 0 ;;
        --version)      echo "$SCRIPT_VERSION"; exit 0 ;;
        --target|--operator|--output)
            if [[ $# -lt 2 || -z "$2" ]]; then
                echo "[ERROR] Missing value for $1" >&2
                exit 3
            fi
            case "$1" in
                --target)   TARGET="$2" ;;
                --operator) OPERATOR="$2" ;;
                --output)   OUTPUT_DIR="$2" ;;
            esac
            shift 2 ;;
        *) echo "[ERROR] Unknown option: $1" >&2; exit 3 ;;
    esac
done

# ------------------------------------------------------------
# Common output functions (same PASS/WARN/FAIL style)
# ------------------------------------------------------------

# Keep the findings in JSON Lines format for optional reporting.
# This is simpler than repeatedly rebuilding a large JSON array.
log_result() {
    local level="$1"
    local section="$2"
    local message="$3"
    local details="${4:-}"

    printf '[%s] %s\n' "$level" "$message"
    if [[ -n "$details" ]]; then
        printf '%s\n' "$details" | sed 's/^/        /'
    fi

    jq -nc \
        --arg level "$level" \
        --arg section "$section" \
        --arg message "$message" \
        --arg details "$details" \
        '{level:$level, section:$section, message:$message, details:$details}' \
        >> "$TEMP_DIR/findings.jsonl"

    case "$level" in
        PASS)    ((PASS+=1)) ;;
        WARN)    ((WARN+=1)) ;;
        FAIL)    ((FAIL+=1)) ;;
        UNKNOWN) ((UNKNOWN+=1)) ;;
    esac
}

green()   { log_result "PASS" "$1" "$2" "${3:-}"; }
yellow()  { log_result "WARN" "$1" "$2" "${3:-}"; }
red()     { log_result "FAIL" "$1" "$2" "${3:-}"; }
unknown() { log_result "UNKNOWN" "$1" "$2" "${3:-}"; }

section() {
    echo
    echo "------------------ $1 ------------------"
}

# Give people the actual oc commands to run, as the original script did.
investigate() {
    INVESTIGATE+=("$1|$2")
}

# ------------------------------------------------------------
# Read an OpenShift resource once, as JSON
# ------------------------------------------------------------

# Example:
#   if get_json nodes nodes; then
#       jq -r '.items[].metadata.name' "$TEMP_DIR/nodes.json"
#   else
#       unknown "Nodes" "Unable to read nodes"
#   fi
#
# Command errors are important: an API that cannot be read must NOT
# be interpreted as a healthy cluster with zero matching resources.
get_json() {
    local file="$1"
    shift

    if oc get "$@" -o json > "$TEMP_DIR/$file.json" 2> "$TEMP_DIR/$file.err" \
        && jq -e 'type == "object"' "$TEMP_DIR/$file.json" >/dev/null 2>&1; then
        return 0
    fi

    rm -f "$TEMP_DIR/$file.json"
    return 1
}

have_json() {
    [[ -s "$TEMP_DIR/$1.json" ]]
}

# ------------------------------------------------------------
# Initial checks and cluster identification
# ------------------------------------------------------------

command -v oc >/dev/null 2>&1 || { echo '[ERROR] oc is required' >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo '[ERROR] jq is required' >&2; exit 3; }

if $MIRROR_TAGS && ! command -v skopeo >/dev/null 2>&1; then
    echo '[ERROR] --mirror-tags requires skopeo' >&2
    exit 3
fi

if [[ -n "$TARGET" && ! "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo '[ERROR] --target must be in X.Y.Z format' >&2
    exit 3
fi

TEMP_DIR=$(mktemp -d) || exit 3
: > "$TEMP_DIR/findings.jsonl"

SERVER=$(oc whoami --show-server 2>/dev/null)
CONTEXT=$(oc config current-context 2>/dev/null)

if [[ -z "$SERVER" ]] || ! get_json clusterversion clusterversion version; then
    echo '[ERROR] Unable to identify cluster. Check oc login and permissions.' >&2
    exit 3
fi

CLUSTER_VERSION=$(jq -r '.status.desired.version // "unknown"' "$TEMP_DIR/clusterversion.json")
CHANNEL=$(jq -r '.spec.channel // "unspecified"' "$TEMP_DIR/clusterversion.json")

printf '\n===========================================\n'
echo ' OPENSHIFT UPGRADE PRE-FLIGHT'
echo " Version: $SCRIPT_VERSION    $(date)"
printf '===========================================\n'
echo "Context: ${CONTEXT:-unknown}"
echo "API:     $SERVER"
echo "Version: $CLUSTER_VERSION"
echo "Channel: $CHANNEL"
echo "Mode:    $MODE"
[[ -z "$TARGET" ]] || echo "Target:  $TARGET (proposed only)"

# ============================================================
# HEALTH CHECKS - these follow the original script's order
# ============================================================

run_health_checks() {
    local problems count output high_cpu high_mem

    # --------------------------------------------------------
    # Cluster Operators
    # --------------------------------------------------------
    section "CLUSTER OPERATORS"

    if get_json operators co; then
        count=$(jq '.items | length' "$TEMP_DIR/operators.json")
        problems=$(jq -r '
            .items[] |
            .metadata.name as $name |
            ([.status.conditions[]? | select(.type=="Available") | .status][0] // "Unknown") as $available |
            ([.status.conditions[]? | select(.type=="Progressing") | .status][0] // "Unknown") as $progressing |
            ([.status.conditions[]? | select(.type=="Degraded") | .status][0] // "Unknown") as $degraded |
            select($available!="True" or $progressing!="False" or $degraded!="False") |
            "\($name): Available=\($available), Progressing=\($progressing), Degraded=\($degraded)"
        ' "$TEMP_DIR/operators.json")

        if ((count==0)); then
            unknown "ClusterOperators" "ClusterOperator query returned no items"
        elif [[ -z "$problems" ]]; then
            green "ClusterOperators" "All ClusterOperators healthy"
        else
            red "ClusterOperators" "ClusterOperator problem(s)" "$problems"
            investigate "ClusterOperators" "oc get co"
            investigate "ClusterOperators" "oc describe co <OPERATOR_NAME>"
        fi
    else
        unknown "ClusterOperators" "Unable to retrieve ClusterOperators"
    fi

    # --------------------------------------------------------
    # MachineConfigPools / paused pools
    # --------------------------------------------------------
    section "MACHINE CONFIG POOLS"

    if get_json mcp mcp; then
        count=$(jq '.items | length' "$TEMP_DIR/mcp.json")
        problems=$(jq -r '
            .items[] |
            .metadata.name as $name |
            ([.status.conditions[]? | select(.type=="Updated") | .status][0] // "Unknown") as $updated |
            ([.status.conditions[]? | select(.type=="Updating") | .status][0] // "Unknown") as $updating |
            ([.status.conditions[]? | select(.type=="Degraded") | .status][0] // "Unknown") as $degraded |
            select($updated!="True" or $updating!="False" or $degraded!="False") |
            "\($name): Updated=\($updated), Updating=\($updating), Degraded=\($degraded)"
        ' "$TEMP_DIR/mcp.json")

        if ((count==0)); then
            unknown "MachineConfigPools" "MachineConfigPool query returned no items"
        elif [[ -z "$problems" ]]; then
            green "MachineConfigPools" "All MachineConfigPools healthy"
        else
            red "MachineConfigPools" "MachineConfigPool problem(s)" "$problems"
            investigate "MachineConfigPools" "oc get mcp"
        fi

        problems=$(jq -r '.items[] | select(.spec.paused==true) | .metadata.name' "$TEMP_DIR/mcp.json")
        if [[ -z "$problems" ]]; then
            green "MachineConfigPools" "No MachineConfigPools paused"
        else
            yellow "MachineConfigPools" "Paused MachineConfigPool(s)" "$problems"
        fi
    else
        unknown "MachineConfigPools" "Unable to retrieve MachineConfigPools"
    fi

    # --------------------------------------------------------
    # Nodes: readiness, cordon and pressure
    # --------------------------------------------------------
    section "NODES"

    if get_json nodes nodes; then
        count=$(jq '.items | length' "$TEMP_DIR/nodes.json")
        problems=$(jq -r '
            .items[] |
            .metadata.name as $node |
            ([.status.conditions[]? | select(.type=="Ready") | .status][0] // "Unknown") as $ready |
            select($ready!="True") |
            "\($node) (Ready=\($ready))"
        ' "$TEMP_DIR/nodes.json")

        if ((count==0)); then
            unknown "Nodes" "Node query returned no items"
        elif [[ -z "$problems" ]]; then
            green "Nodes" "All $count nodes Ready"
        else
            red "Nodes" "Node(s) not Ready" "$problems"
            investigate "Nodes" "oc get nodes -o wide"
        fi

        problems=$(jq -r '.items[] | select(.spec.unschedulable==true) | .metadata.name' "$TEMP_DIR/nodes.json")
        if [[ -z "$problems" ]]; then
            green "Nodes" "No nodes cordoned"
        else
            yellow "Nodes" "Cordoned node(s)" "$problems"
        fi

        problems=$(jq -r '
            .items[] |
            .metadata.name as $node |
            .status.conditions[]? |
            select((.type=="DiskPressure" or .type=="MemoryPressure" or .type=="PIDPressure") and .status=="True") |
            "\($node): \(.type)"
        ' "$TEMP_DIR/nodes.json")

        if [[ -z "$problems" ]]; then
            green "Node Pressure" "No node pressure conditions"
        else
            red "Node Pressure" "Node pressure condition(s)" "$problems"
        fi
    else
        unknown "Nodes" "Unable to retrieve nodes"
    fi

    # --------------------------------------------------------
    # CPU / memory usage (requires metrics API)
    # --------------------------------------------------------
    section "NODE UTILIZATION"

    if output=$(oc adm top nodes --no-headers 2>/dev/null) && [[ -n "$output" ]]; then
        high_cpu=$(printf '%s\n' "$output" | awk '
            NF>=5 {
                cpu=$3
                gsub(/%/, "", cpu)
                if ((cpu+0) >= 80) print $1 " CPU=" $3
            }')
        high_mem=$(printf '%s\n' "$output" | awk '
            NF>=5 {
                mem=$5
                gsub(/%/, "", mem)
                if ((mem+0) >= 80) print $1 " MEM=" $5
            }')

        if [[ -z "$high_cpu" ]]; then
            green "Node Utilization" "No nodes at or above 80% CPU"
        else
            yellow "Node Utilization" "High CPU utilization" "$high_cpu"
        fi

        if [[ -z "$high_mem" ]]; then
            green "Node Utilization" "No nodes at or above 80% memory"
        else
            yellow "Node Utilization" "High memory utilization" "$high_mem"
        fi
    else
        unknown "Node Utilization" "Unable to retrieve node metrics"
    fi

    # --------------------------------------------------------
    # Pending CSRs
    # --------------------------------------------------------
    section "CSRs"

    if get_json csr csr; then
        problems=$(jq -r '.items[] | select((.status.conditions // [] | length)==0) | .metadata.name' "$TEMP_DIR/csr.json")
        if [[ -z "$problems" ]]; then
            green "CSRs" "No pending CSRs"
        else
            yellow "CSRs" "Pending CSR(s)" "$problems"
            investigate "CSRs" "oc get csr"
        fi
    else
        unknown "CSRs" "Unable to retrieve CSRs"
    fi

    # --------------------------------------------------------
    # Pending pods / high restarts / container failures
    # --------------------------------------------------------
    section "PODS"

    if get_json pods pods -A; then
        problems=$(jq -r '.items[] | select(.status.phase=="Pending") | "\(.metadata.namespace)/\(.metadata.name)"' "$TEMP_DIR/pods.json")
        count=$(printf '%s\n' "$problems" | awk 'NF{n++} END{print n+0}')

        if ((count==0)); then
            green "Pods" "No Pending pods"
        else
            yellow "Pods" "$count Pending pod(s)" "$(printf '%s\n' "$problems" | head -10)"
            investigate "Pods" "oc get pods -A"
        fi

        problems=$(jq -r '
            .items[] |
            .metadata.namespace as $ns |
            .metadata.name as $pod |
            ([.status.containerStatuses[]?.restartCount] | add // 0) as $restarts |
            select($restarts >= 10) |
            "\($ns)/\($pod) (\($restarts) restarts)"
        ' "$TEMP_DIR/pods.json")
        count=$(printf '%s\n' "$problems" | awk 'NF{n++} END{print n+0}')

        if ((count==0)); then
            green "Pods" "No pods with 10+ cumulative restarts"
        else
            yellow "Pods" "$count pod(s) with 10+ cumulative restarts" "$(printf '%s\n' "$problems" | head -10)"
        fi

        problems=$(jq -r '
            .items[] |
            .metadata.namespace as $ns |
            .metadata.name as $pod |
            .status.containerStatuses[]? |
            select(.state.waiting.reason == "CrashLoopBackOff" or
                   .state.waiting.reason == "ImagePullBackOff" or
                   .state.waiting.reason == "ErrImagePull" or
                   .state.waiting.reason == "CreateContainerError") |
            "\($ns)/\($pod) (\(.state.waiting.reason))"
        ' "$TEMP_DIR/pods.json")

        if [[ -z "$problems" ]]; then
            green "Pods" "No detected container waiting errors"
        else
            yellow "Pods" "Container waiting errors" "$(printf '%s\n' "$problems" | head -10)"
        fi
    else
        unknown "Pods" "Unable to retrieve pods across namespaces"
    fi

    # --------------------------------------------------------
    # PVCs / PDBs
    # --------------------------------------------------------
    section "STORAGE"

    if get_json pvc pvc -A; then
        problems=$(jq -r '.items[] | select(.status.phase!="Bound") | "\(.metadata.namespace)/\(.metadata.name) (\(.status.phase // "Unknown"))"' "$TEMP_DIR/pvc.json")
        if [[ -z "$problems" ]]; then
            green "PVCs" "All PVCs Bound"
        else
            yellow "PVCs" "PVC(s) not Bound (some may be intentionally Pending)" "$(printf '%s\n' "$problems" | head -10)"
        fi
    else
        unknown "PVCs" "Unable to retrieve PVCs"
    fi

    section "DISRUPTION BUDGETS"

    if get_json pdb pdb -A; then
        problems=$(jq -r '
            .items[] |
            select((.status.disruptionsAllowed // -1)==0 and (.status.expectedPods // 0)>0) |
            "\(.metadata.namespace)/\(.metadata.name) (expected=\(.status.expectedPods))"
        ' "$TEMP_DIR/pdb.json")
        count=$(printf '%s\n' "$problems" | awk 'NF{n++} END{print n+0}')

        if ((count==0)); then
            green "PDBs" "No active PDBs with zero allowed disruptions"
        else
            yellow "PDBs" "$count active PDB(s) allow zero disruptions" "$(printf '%s\n' "$problems" | head -10)"
            investigate "PDBs" "oc get pdb -A"
        fi
    else
        unknown "PDBs" "Unable to retrieve PDBs"
    fi

    # --------------------------------------------------------
    # MachineHealthChecks
    # --------------------------------------------------------
    section "MACHINE HEALTH CHECKS"

    if get_json mhc machinehealthchecks -n openshift-machine-api; then
        count=$(jq '.items | length' "$TEMP_DIR/mhc.json")
        if ((count==0)); then
            yellow "MachineHealthChecks" "No MachineHealthChecks found (may be expected)"
        else
            green "MachineHealthChecks" "$count MachineHealthChecks inventoried"
        fi

        problems=$(jq -r '.items[] | select(.spec.maxUnhealthy=="100%") | .metadata.name' "$TEMP_DIR/mhc.json")
        if [[ -n "$problems" ]]; then
            yellow "MachineHealthChecks" "maxUnhealthy=100% requires review" "$problems"
        fi
    else
        unknown "MachineHealthChecks" "Unable to retrieve MachineHealthChecks"
    fi

    # --------------------------------------------------------
    # Available cluster updates / Warning events
    # --------------------------------------------------------
    section "AVAILABLE UPDATES"
    jq -r '.status.availableUpdates[]?.version' "$TEMP_DIR/clusterversion.json" | sed 's/^/        /'
    echo "Note: disconnected clusters may not report available updates."

    section "WARNING EVENTS"

    if get_json events events -A --field-selector type=Warning; then
        count=$(jq '.items | length' "$TEMP_DIR/events.json")
        if ((count==0)); then
            green "Events" "No retained Warning events"
        else
            yellow "Events" "$count retained Warning event(s) (not necessarily recent)"
            investigate "Events" "oc get events -A --field-selector type=Warning --sort-by=.lastTimestamp"
        fi
    else
        unknown "Events" "Unable to retrieve Warning events"
    fi
}

# ============================================================
# INVENTORY - new sections; these DO NOT judge cluster health
# ============================================================

run_inventory() {
    local count problems repo filename

    # --------------------------------------------------------
    # Cluster information
    # --------------------------------------------------------
    section "CLUSTER INVENTORY"

    echo "Desired release image: $(jq -r '.status.desired.image // .spec.desiredUpdate.image // "unspecified"' "$TEMP_DIR/clusterversion.json")"
    echo "Update server:        $(jq -r '.spec.upstream // "default"' "$TEMP_DIR/clusterversion.json")"
    echo "Upgradeable condition:"
    jq -r '
        .status.conditions[]? |
        select(.type=="Upgradeable") |
        "        \(.status): \(.reason // "") - \(.message // "")"
    ' "$TEMP_DIR/clusterversion.json"

    # --------------------------------------------------------
    # Subscriptions: installed Operator, channel, approval
    # --------------------------------------------------------
    section "OPERATOR SUBSCRIPTIONS"

    if get_json subscriptions subscriptions -A; then
        printf '%-23s %-26s %-20s %-20s %-12s\n' "NAMESPACE" "PACKAGE" "CHANNEL" "INSTALLED CSV" "APPROVAL"

        jq -r --arg name "$OPERATOR" '
            .items[] |
            select($name=="" or .spec.name==$name or .metadata.name==$name) |
            [.metadata.namespace,
             (.spec.name // "-"),
             (.spec.channel // "-"),
             (.status.installedCSV // "-"),
             (.spec.installPlanApproval // "-")] |
            @tsv
        ' "$TEMP_DIR/subscriptions.json" | while IFS=$'\t' read -r ns package channel csv approval; do
            printf '%-23s %-26s %-20s %-20s %-12s\n' "$ns" "$package" "$channel" "$csv" "$approval"
        done

        count=$(jq --arg name "$OPERATOR" '[.items[] | select($name=="" or .spec.name==$name or .metadata.name==$name)] | length' "$TEMP_DIR/subscriptions.json")
        if ((count==0)); then
            yellow "Subscriptions" "No Operator Subscriptions matched the filter"
        else
            echo "Subscriptions found: $count"
        fi

        problems=$(jq -r --arg name "$OPERATOR" '
            .items[] |
            select($name=="" or .spec.name==$name or .metadata.name==$name) |
            select((.status.installedCSV // "") != (.status.currentCSV // "")) |
            "\(.metadata.namespace)/\(.metadata.name): installed=\(.status.installedCSV // "-") current=\(.status.currentCSV // "-")"
        ' "$TEMP_DIR/subscriptions.json")
        [[ -z "$problems" ]] || yellow "Subscriptions" "Installed CSV differs from current CSV" "$problems"
    else
        unknown "Subscriptions" "Unable to retrieve Operator Subscriptions"
    fi

    # --------------------------------------------------------
    # CatalogSources: names and current catalog images
    # --------------------------------------------------------
    section "CATALOG SOURCES"

    if get_json catalogs catalogsources -A; then
        jq -r '
            .items[] |
            "\(.metadata.namespace)/\(.metadata.name)\n        Image: \(.spec.image // "no image")\n        Connection: \(.status.connectionState.lastObservedState // "unknown")"
        ' "$TEMP_DIR/catalogs.json"
        echo "CatalogSources found: $(jq '.items | length' "$TEMP_DIR/catalogs.json")"
    else
        unknown "CatalogSources" "Unable to retrieve CatalogSources"
    fi

    # --------------------------------------------------------
    # PackageManifest channels advertised by active catalogs
    # --------------------------------------------------------
    section "PACKAGE MANIFEST CHANNELS"

    if get_json packages packagemanifests -A; then
        if have_json subscriptions; then
            jq -nr \
                --arg name "$OPERATOR" \
                --slurpfile subscriptions "$TEMP_DIR/subscriptions.json" \
                --slurpfile packages "$TEMP_DIR/packages.json" '
                $subscriptions[0].items[] |
                select($name=="" or .spec.name==$name or .metadata.name==$name) as $sub |
                $packages[0].items[] |
                select(.status.packageName == $sub.spec.name and
                       .status.catalogSource == $sub.spec.source and
                       .status.catalogSourceNamespace == $sub.spec.sourceNamespace) |
                .status.channels[]? |
                "\($sub.spec.name): \(.name) -> \(.currentCSV // "unknown")"
            '
        else
            echo "Subscription inventory unavailable; cannot match packages."
        fi
        echo "These are channel-head CSVs, NOT proof of a supported upgrade path."
    else
        unknown "PackageManifests" "Unable to retrieve PackageManifests"
    fi

    # --------------------------------------------------------
    # InstallPlans and installed CSVs
    # --------------------------------------------------------
    section "INSTALLPLANS / CSVs"

    if get_json installplans installplans -A; then
        echo "InstallPlans found: $(jq '.items | length' "$TEMP_DIR/installplans.json")"
        jq -r '
            .items[] |
            select(.status.phase!="Complete" or .spec.approved!=true) |
            "\(.metadata.namespace)/\(.metadata.name): phase=\(.status.phase // "Unknown"), approved=\(.spec.approved // false)"
        ' "$TEMP_DIR/installplans.json" | head -20
    else
        unknown "InstallPlans" "Unable to retrieve InstallPlans"
    fi

    if get_json csvs csv -A; then
        echo "CSVs found: $(jq '.items | length' "$TEMP_DIR/csvs.json")"
        problems=$(jq -r '
            .items[] |
            select(.status.phase!="Succeeded") |
            "\(.metadata.namespace)/\(.metadata.name) (\(.status.phase // "Unknown"))"
        ' "$TEMP_DIR/csvs.json")
        if [[ -n "$problems" ]]; then
            yellow "CSVs" "Non-Succeeded CSV(s)" "$(printf '%s\n' "$problems" | head -15)"
        fi
    else
        unknown "CSVs" "Unable to retrieve ClusterServiceVersions"
    fi

    # --------------------------------------------------------
    # IDMS / ITMS: internal mirror routing configuration
    # --------------------------------------------------------
    section "MIRROR CONFIGURATION"

    if get_json idms imagedigestmirrorsets; then
        echo "ImageDigestMirrorSets: $(jq '.items | length' "$TEMP_DIR/idms.json")"
        jq -r '
            .items[] |
            .metadata.name as $name |
            .spec.imageDigestMirrors[]? |
            "        \($name): \(.source) -> \(.mirrors | join(", "))"
        ' "$TEMP_DIR/idms.json"
    else
        unknown "Mirrors" "Unable to retrieve ImageDigestMirrorSets"
    fi

    if get_json itms imagetagmirrorsets; then
        echo "ImageTagMirrorSets: $(jq '.items | length' "$TEMP_DIR/itms.json")"
        jq -r '
            .items[] |
            .metadata.name as $name |
            .spec.imageTagMirrors[]? |
            "        \($name): \(.source) -> \(.mirrors | join(", "))"
        ' "$TEMP_DIR/itms.json"
    else
        unknown "Mirrors" "Unable to retrieve ImageTagMirrorSets"
    fi
    echo "Mirror mappings do NOT prove the images actually exist."

    # --------------------------------------------------------
    # Optional: tags stored in the mirror registry
    # --------------------------------------------------------
    if $MIRROR_TAGS; then
        section "CATALOG IMAGE TAGS (SKOPEO)"

        if have_json catalogs; then
            mkdir -p "$TEMP_DIR/mirror-tags"
            jq -r '
                .items[].spec.image // empty |
                sub("@sha256:.*$"; "") |
                sub(":([^/:]+)$"; "")
            ' "$TEMP_DIR/catalogs.json" | sort -u | while IFS= read -r repo; do
                [[ -n "$repo" ]] || continue
                filename=$(printf '%s' "$repo" | tr '/:' '__')
                echo "Repository: $repo"

                if skopeo list-tags "docker://$repo" > "$TEMP_DIR/mirror-tags/$filename.json" 2> "$TEMP_DIR/mirror-tags/$filename.err"; then
                    jq -r '.Tags[]?' "$TEMP_DIR/mirror-tags/$filename.json" | tail -20 | sed 's/^/        /'
                else
                    echo "        Unable to retrieve tags (credentials/network may be required)"
                fi
            done
            echo "A catalog tag does NOT tell us which channels it contains."
        else
            unknown "Mirrors" "CatalogSource inventory unavailable for tag lookup"
        fi
    fi
}

# ============================================================
# TARGET READINESS - information only, no upgrades or patches
# ============================================================

run_target_checks() {
    [[ -n "$TARGET" ]] || return 0

    section "TARGET VERSION READINESS: $TARGET"

    if [[ "$TARGET" == "$CLUSTER_VERSION" ]]; then
        yellow "Target" "Target version equals the installed version"
    fi

    local upgradeable
    upgradeable=$(jq -r '
        [.status.conditions[]? |
        select(.type=="Upgradeable") |
        "\(.status): \(.reason // "") - \(.message // "")"] |
        join("\n")
    ' "$TEMP_DIR/clusterversion.json")

    if [[ -z "$upgradeable" ]]; then
        unknown "Upgrade" "Upgradeable condition was not reported"
    elif [[ "$upgradeable" == False:* ]]; then
        yellow "Upgrade" "Cluster reports Upgradeable=False" "$upgradeable"
    else
        echo "Upgradeable: $upgradeable"
    fi

    echo "Cluster-reported available updates:"
    jq -r '.status.availableUpdates[]?.version' "$TEMP_DIR/clusterversion.json" | sed 's/^/        /'

    # These cannot safely be declared PASS from a version/tag alone.
    unknown "Upgrade" "Supported update path to $TARGET must be verified"
    unknown "Upgrade" "Target release image, digest and signatures need verification"
    unknown "Upgrade" "Installed Operator compatibility requires documentation review"
    unknown "Upgrade" "Recent etcd and application backups require confirmation"

    section "DEPRECATED API USAGE"
    if get_json apirequests apirequestcounts; then
        jq -r '
            .items[] |
            select((.status.removedInRelease // "") != "") |
            "\(.metadata.name): removed in \(.status.removedInRelease), current hour=\(.status.currentHour.requestCount // "unknown")"
        ' "$TEMP_DIR/apirequests.json" | head -25
        echo "Review removal versions and whether clients still use these APIs."
    else
        unknown "APIRequestCounts" "Unable to retrieve APIRequestCounts"
    fi

    section "ADMIN ACKNOWLEDGMENTS"
    if get_json adminacks cm admin-acks -n openshift-config; then
        jq -r '.data // {} | to_entries[] | "\(.key)=\(.value)"' "$TEMP_DIR/adminacks.json"
    else
        unknown "AdminAcks" "Unable to retrieve admin-acks ConfigMap"
    fi

    section "RELEASE SIGNATURE CONFIGMAPS"
    if get_json signatures configmaps -n openshift-config-managed -l release.openshift.io/verification-signatures; then
        echo "ConfigMaps returned: $(jq '.items | length' "$TEMP_DIR/signatures.json")"
        unknown "Signatures" "Target digest/signature matching is NOT verified by this listing"
    else
        unknown "Signatures" "Unable to list release signature ConfigMaps"
    fi
}

# ------------------------------------------------------------
# End-of-run investigation suggestions and summary
# ------------------------------------------------------------

show_summary() {
    local entry reason command last_reason=""

    echo
    echo "==========================================="
    echo " UPGRADE PRE-FLIGHT SUMMARY"
    echo "==========================================="
    echo " PASS:    $PASS"
    echo " WARN:    $WARN"
    echo " FAIL:    $FAIL"
    echo " UNKNOWN: $UNKNOWN"
    echo "==========================================="

    if ((FAIL > 0)); then
        echo " RESULT: Investigate FAIL conditions before upgrade"
    elif ((WARN > 0 || UNKNOWN > 0)); then
        echo " RESULT: Review WARN/UNKNOWN conditions before upgrade"
    else
        echo " RESULT: No obvious issues in the selected checks"
    fi
    echo " NOTE: This report is NOT automatic upgrade approval."

    if ((${#INVESTIGATE[@]} > 0)); then
        echo
        echo "================ INVESTIGATE ================"
        for entry in "${INVESTIGATE[@]}"; do
            reason="${entry%%|*}"
            command="${entry#*|}"
            if [[ "$reason" != "$last_reason" ]]; then
                echo
                echo "$reason:"
                last_reason="$reason"
            fi
            echo "        $command"
        done
    fi
}

# ------------------------------------------------------------
# Optional JSON report - includes collected resource snapshots
# ------------------------------------------------------------

save_json() {
    $SAVE_JSON || return 0

    local date_stamp safe_context report_dir file
    date_stamp=$(date -u +%Y%m%dT%H%M%SZ)
    safe_context=$(printf '%s' "${CONTEXT:-cluster}" | tr -cs 'A-Za-z0-9_.-' '_')
    report_dir="$OUTPUT_DIR/$safe_context/$date_stamp"

    if ! mkdir -p "$report_dir"; then
        echo "[WARN] Unable to create JSON report directory: $report_dir" >&2
        return 0
    fi

    # Save all successfully collected API responses as a snapshot.
    # We intentionally avoid the kubeconfig and Secrets.
    for file in "$TEMP_DIR"/*.json; do
        [[ -f "$file" ]] || continue
        case "${file##*/}" in
            adminacks.json)
                jq '{metadata:{name:.metadata.name,namespace:.metadata.namespace},data:(.data // {})}' "$file" > "$report_dir/${file##*/}" ;;
            signatures.json)
                jq '{items:[.items[] | {name:.metadata.name,namespace:.metadata.namespace}]}' "$file" > "$report_dir/${file##*/}" ;;
            *) cp "$file" "$report_dir/" ;;
        esac
    done

    # A compact machine-readable report of PASS/WARN/FAIL/UNKNOWN.
    jq -n \
        --arg context "$CONTEXT" \
        --arg apiServer "$SERVER" \
        --arg currentVersion "$CLUSTER_VERSION" \
        --arg channel "$CHANNEL" \
        --arg target "$TARGET" \
        --arg mode "$MODE" \
        --argjson pass "$PASS" \
        --argjson warn "$WARN" \
        --argjson fail "$FAIL" \
        --argjson unknown "$UNKNOWN" \
        --slurpfile findings "$TEMP_DIR/findings.jsonl" \
        '{context:$context, apiServer:$apiServer, currentVersion:$currentVersion,
          channel:$channel, target:$target, mode:$mode,
          summary:{pass:$pass,warn:$warn,fail:$fail,unknown:$unknown},
          findings:$findings}' > "$report_dir/report.json"

    echo
    echo "JSON report saved: $report_dir"
    echo "Note: inventory reports can contain internal server names and registry paths."
}

# ------------------------------------------------------------
# Main - intentionally simple
# ------------------------------------------------------------

case "$MODE" in
    health)    run_health_checks ;;
    inventory) run_inventory ;;
    preflight) run_health_checks; run_inventory ;;
esac

run_target_checks
show_summary
save_json

if ((FAIL > 0)); then
    exit 2
elif ((WARN > 0 || UNKNOWN > 0)); then
    exit 1
else
    exit 0
fi
