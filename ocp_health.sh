#!/bin/bash

# ------------------------------------------------------------
# OpenShift Quick Health Check
# Read-only
# ------------------------------------------------------------

PASS=0
WARN=0
FAIL=0

green()  { echo "[PASS] $1"; ((PASS++)); }
yellow() { echo "[WARN] $1"; ((WARN++)); }
red()    { echo "[FAIL] $1"; ((FAIL++)); }

echo
echo "=================================================="
echo " OPENSHIFT HEALTH CHECK"
echo " $(date)"
echo "=================================================="
echo

# ------------------------------------------------------------
# Cluster Version
# ------------------------------------------------------------

VERSION=$(oc get clusterversion version \
  -o jsonpath='{.status.desired.version}' 2>/dev/null)

if [[ -n "$VERSION" ]]; then
    echo "Cluster Version: $VERSION"
else
    red "Unable to determine cluster version"
fi

echo


# ------------------------------------------------------------
# Cluster Operators
# ------------------------------------------------------------

BAD_CO=$(oc get co --no-headers 2>/dev/null | \
    awk '$3!="True" || $4=="True" || $5=="True" {print $1}')

if [[ -z "$BAD_CO" ]]; then
    green "All ClusterOperators healthy"
else
    red "Unhealthy ClusterOperators:"
    echo "$BAD_CO" | sed 's/^/       /'
fi


# ------------------------------------------------------------
# Nodes
# ------------------------------------------------------------

TOTAL_NODES=$(oc get nodes --no-headers 2>/dev/null | wc -l)
BAD_NODES=$(oc get nodes --no-headers 2>/dev/null | \
    awk '$2 !~ /^Ready/ {print $1 " (" $2 ")"}')

if [[ -z "$BAD_NODES" ]]; then
    green "All $TOTAL_NODES nodes Ready"
else
    red "Nodes not Ready:"
    echo "$BAD_NODES" | sed 's/^/       /'
fi


# ------------------------------------------------------------
# MachineConfigPools
# ------------------------------------------------------------

BAD_MCP=$(oc get mcp --no-headers 2>/dev/null | \
    awk '$5!="True" || $6=="True" {print $1}')

if [[ -z "$BAD_MCP" ]]; then
    green "MachineConfigPools healthy"
else
    red "MachineConfigPool problem:"
    echo "$BAD_MCP" | sed 's/^/       /'
fi


# ------------------------------------------------------------
# Paused MachineConfigPools
# ------------------------------------------------------------

PAUSED_MCP=$(oc get mcp -o json 2>/dev/null | \
    jq -r '.items[] | select(.spec.paused == true) | .metadata.name')

if [[ -z "$PAUSED_MCP" ]]; then
    green "No MachineConfigPools paused"
else
    yellow "Paused MachineConfigPools:"
    echo "$PAUSED_MCP" | sed 's/^/       /'
fi


# ------------------------------------------------------------
# Pending CSRs
# ------------------------------------------------------------

PENDING_CSR=$(oc get csr --no-headers 2>/dev/null | \
    awk '$NF=="Pending" {print $1}')

CSR_COUNT=$(echo "$PENDING_CSR" | sed '/^$/d' | wc -l)

if [[ "$CSR_COUNT" -eq 0 ]]; then
    green "No pending CSRs"
else
    yellow "$CSR_COUNT pending CSR(s)"
    echo "$PENDING_CSR" | sed 's/^/       /'
fi


# ------------------------------------------------------------
# Failed / Pending Pods
# ------------------------------------------------------------

BAD_PODS=$(oc get pods -A --no-headers 2>/dev/null | \
    awk '$4!="Running" && $4!="Completed" && $4!="Succeeded" {
        print $1 "/" $2 " (" $4 ")"
    }')

BAD_POD_COUNT=$(echo "$BAD_PODS" | sed '/^$/d' | wc -l)

if [[ "$BAD_POD_COUNT" -eq 0 ]]; then
    green "No obviously unhealthy pods"
else
    yellow "$BAD_POD_COUNT unhealthy pod(s)"
    echo "$BAD_PODS" | head -10 | sed 's/^/       /'

    if [[ "$BAD_POD_COUNT" -gt 10 ]]; then
        echo "       ... showing first 10"
    fi
fi


# ------------------------------------------------------------
# High Restart Pods
# ------------------------------------------------------------

RESTART_PODS=$(oc get pods -A --no-headers 2>/dev/null | \
    awk '$5 >= 10 {
        print $1 "/" $2 " (" $5 " restarts)"
    }')

RESTART_COUNT=$(echo "$RESTART_PODS" | sed '/^$/d' | wc -l)

if [[ "$RESTART_COUNT" -eq 0 ]]; then
    green "No pods with >=10 restarts"
else
    yellow "$RESTART_COUNT pod(s) with >=10 restarts"
    echo "$RESTART_PODS" | head -10 | sed 's/^/       /'
fi


# ------------------------------------------------------------
# PVC Problems
# ------------------------------------------------------------

BAD_PVC=$(oc get pvc -A --no-headers 2>/dev/null | \
    awk '$3!="Bound" {
        print $1 "/" $2 " (" $3 ")"
    }')

BAD_PVC_COUNT=$(echo "$BAD_PVC" | sed '/^$/d' | wc -l)

if [[ "$BAD_PVC_COUNT" -eq 0 ]]; then
    green "All PVCs Bound"
else
    yellow "$BAD_PVC_COUNT PVC(s) not Bound"
    echo "$BAD_PVC" | head -10 | sed 's/^/       /'
fi


# ------------------------------------------------------------
# Released / Failed PVs
# ------------------------------------------------------------

BAD_PV=$(oc get pv --no-headers 2>/dev/null | \
    awk '$5=="Released" || $5=="Failed" {
        print $1 " (" $5 ")"
    }')

BAD_PV_COUNT=$(echo "$BAD_PV" | sed '/^$/d' | wc -l)

if [[ "$BAD_PV_COUNT" -eq 0 ]]; then
    green "No Released or Failed PVs"
else
    yellow "$BAD_PV_COUNT Released/Failed PV(s)"
    echo "$BAD_PV" | head -10 | sed 's/^/       /'
fi


# ------------------------------------------------------------
# PDBs allowing zero disruptions
# ------------------------------------------------------------

ZERO_PDB=$(oc get pdb -A \
    -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,ALLOW:.status.disruptionsAllowed \
    --no-headers 2>/dev/null | \
    awk '$3=="0" {print $1 "/" $2}')

ZERO_PDB_COUNT=$(echo "$ZERO_PDB" | sed '/^$/d' | wc -l)

if [[ "$ZERO_PDB_COUNT" -eq 0 ]]; then
    green "No PDBs currently blocking all disruptions"
else
    yellow "$ZERO_PDB_COUNT PDB(s) allow zero disruptions"
    echo "$ZERO_PDB" | head -10 | sed 's/^/       /'
fi


# ------------------------------------------------------------
# Node Resource Usage
# ------------------------------------------------------------

TOP_OUTPUT=$(oc adm top nodes --no-headers 2>/dev/null)

if [[ -n "$TOP_OUTPUT" ]]; then

    HIGH_CPU=$(echo "$TOP_OUTPUT" | \
        awk '{
            cpu=$3
            gsub("%","",cpu)
            if(cpu >= 80)
                print $1 " CPU=" $3
        }')

    HIGH_MEM=$(echo "$TOP_OUTPUT" | \
        awk '{
            mem=$5
            gsub("%","",mem)
            if(mem >= 80)
                print $1 " MEM=" $5
        }')

    if [[ -z "$HIGH_CPU" ]]; then
        green "No nodes >=80% CPU"
    else
        yellow "Nodes >=80% CPU"
        echo "$HIGH_CPU" | sed 's/^/       /'
    fi

    if [[ -z "$HIGH_MEM" ]]; then
        green "No nodes >=80% memory"
    else
        yellow "Nodes >=80% memory"
        echo "$HIGH_MEM" | sed 's/^/       /'
    fi

else
    yellow "Unable to retrieve node metrics"
fi


# ------------------------------------------------------------
# Warning Events
# ------------------------------------------------------------

WARNING_COUNT=$(oc get events -A \
    --field-selector type=Warning \
    --no-headers 2>/dev/null | wc -l)

if [[ "$WARNING_COUNT" -eq 0 ]]; then
    green "No Warning events currently returned"
elif [[ "$WARNING_COUNT" -lt 20 ]]; then
    yellow "$WARNING_COUNT Warning event entries"
else
    yellow "$WARNING_COUNT Warning event entries -- worth reviewing"
fi


# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

echo
echo "=================================================="
echo " SUMMARY"
echo "=================================================="
echo " PASS : $PASS"
echo " WARN : $WARN"
echo " FAIL : $FAIL"
echo "=================================================="
echo

if [[ "$FAIL" -gt 0 ]]; then
    exit 2
elif [[ "$WARN" -gt 0 ]]; then
    exit 1
else
    exit 0
fi