#!/bin/bash

# ---------------------------------------------
# OpenShift Upgrade Pre-Flight Check
# Read-Only
# 
# Requires:
# oc
# jq
# 
# Purpose:
# Identify common conditions that should be
# reviewed before starting an OpenShift Upgrade.
# ---------------------------------------------

PASS=0
WARN=0
FAIL=0

INVESTIGATE=()

green() {
	echo "[PASS] $1"
	((PASS++))
}

yellow() {
	echo "[WARN] $1"
	((WARN++))
}

red() {
	echo "[FAIL] $1"
	((FAIL++))
}

echo
echo "==========================================="
echo " OPENSHIFT UPGRADE PRE-FLIGHT"
echo " $(date)"
echo "==========================================="
echo

# ------------------------------------------------
# Cluster Version
# ------------------------------------------------

VERSION=$(oc get clusterversion version \
	-o jsonpath='{.status.desired.version}' 2>/dev/null)

CHANNEL=$(oc get clusterversion version \
	-o jsonpath='{.spec.channel}' 2>/dev/null)
	
echo "Cluster Version: $VERSION"
echo "Update Channel: $CHANNEL"

# ------------------------------------------------
# Cluster Operators
# ------------------------------------------------

echo "------------ CLUSTER OPERATORS ---------------"

CO_ERROR=""
BAD_CO=""

if CO_ERROR_FILE=$(mktemp); then

	if CO_JSON=$(oc get co -o json --request-timeout=30s \
		2>"$CO_ERROR_FILE"); then

		if BAD_CO=$(printf '%s\n' "$CO_JSON" | jq -r '
			if type != "object" then
				error("Expected a ClusterOperator list object")
			elif (.items | type) != "array" then
				error("ClusterOperator response has no items array")
			elif (.items | length) == 0 then
				error("No ClusterOperators returned")
			else
				.items[] |
				.metadata.name as $name |
				([(.status.conditions // [])[] |
					select(.type == "Available") |
					.status][0] // "Unknown") as $available |
				([(.status.conditions // [])[] |
					select(.type == "Progressing") |
					.status][0] // "Unknown") as $progressing |
				([(.status.conditions // [])[] |
					select(.type == "Degraded") |
					.status][0] // "Unknown") as $degraded |
				select(
					$available != "True" or
					$progressing != "False" or
					$degraded != "False"
				) |
				"\($name) (Available=\($available), Progressing=\($progressing), Degraded=\($degraded))"
			end
		' 2>"$CO_ERROR_FILE"); then
			: # Collection and assessment succeeded.
		else
			CO_ERROR="Unable to assess ClusterOperators"
		fi

	else
		CO_ERROR="Unable to collect ClusterOperators"
	fi

	if [[ -n "$CO_ERROR" ]]; then
		red "$CO_ERROR; health not assessed"

		if [[ -s "$CO_ERROR_FILE" ]]; then
			sed 's/^/        /' "$CO_ERROR_FILE"
		fi

	elif [[ -n "$BAD_CO" ]]; then
		red "ClusterOperator problem(s)"
		printf '%s\n' "$BAD_CO" | sed 's/^/        /'

	else
		green "All ClusterOperators Healthy"
	fi

	rm -f -- "$CO_ERROR_FILE"

else
	CO_ERROR="Unable to create temporary error file"
	red "$CO_ERROR; ClusterOperator health not assessed"
fi

if [[ -n "$CO_ERROR" || -n "$BAD_CO" ]]; then
	INVESTIGATE+=(
		"ClusterOperators|oc get co"
		"ClusterOperators|oc describe co <OPERATOR_NAME>"
	)
fi

echo
# ------------------------------------------------
# MachineConfigPools
# ------------------------------------------------

echo "---------------- MACHINE CONFIG POOLS --------------"

BAD_MCP=$(oc get mcp -o json 2>/dev/null | jq -r '
	.items[] |
	.metadata.name as $name |
	([.status.conditions[] |
		select(.type=="Updated")
		.status][0] // "Unknown") as $updated |
	([.status.conditions[] |
		select(.type=="Updating")
		.status][0] // "Unknown") as $updating |
	([.status.conditions[] |
		select(.type=="Degraded")
		.status][0] // "Unknown") as $degraded |
	select(
		$updated != "True" or
		$updating != "False" or
		$degraded != "False"
	) |
	"\($name) (Updated=\($updated), Updating=\($updating), Degraded=\($degraded))"
')

if [[ -z "$BAD_MCP" ]]; then
	green "All MachineConfigPools Healthy"
else
	red "MachineConfigPool problem(s)"
	echo "$BAD_MCP" | sed 's/^/        /'
	
	INVESTIGATE+=(
		"MachineConfigPools|oc get mcp"
		"MachineConfigPools|oc describe mcp <OPERATOR_NAME>"
	)
fi

# ------------------------------------------------
# Paused MachineConfigPools
# ------------------------------------------------

PAUSED_MCP=$(oc get mcp -o json 2>/dev/null | jq -r '
	.items[] |
	select(.spec.paused == true) |
	.metadata.name
')

if [[ -z "$PAUSED_MCP" ]]; then
	green "No MachineConfigPools paused"
else
	yellow "Paused MachineConfigPool(s)"
	echo "$PAUSED_MCP" | sed 's/^/        /'
	
	INVESTIGATE+=(
		"Paused MCP|oc get mcp"
	)
fi

echo

# ------------------------------------------------
# Node Readiness
# ------------------------------------------------

echo "-------------------- NODES ------------------------"

TOTAL_NODES=$(oc get nodes --no-headers 2>/dev/null | wc -l)

BAD_NODES=$(oc get nodes --no-headers 2>/dev/null | \
	awk '$2 !~ /^Ready/ {
		print $1 " (" $2 ")"
	}')
	
if [[ -z "$BAD_NODES" ]]; then
	green "All $TOTAL_NODES nodes Ready"
else
	red "Node(s) not Ready"
	echo "$BAD_NODES" | sed 's/^/        /'
	
	INVESTIGATE+=(
		"Node NotReady|oc get nodes"
		"Node NotReady|oc describe nodes <NODE_NAME>"
	)
fi

# ------------------------------------------------
# Cordoned / Unschedulable Nodes
# ------------------------------------------------

CORDONED=$(oc get nodes -o json 2>/dev/null | jq -r '
	.items[] |
	select(.spec.unschedulable == true) |
	.metadata.name
')

if [[ -z "$CORDONED" ]]; then
	green "No nodes cordoned"
else
	yellow "Cordoned node(s)"
	echo "$CORDONED" | sed 's/^/        /'
	
	INVESTIGATE+=(
		"Cordoned Nodes|oc get nodes"
		"Cordoned Nodes|oc describe node <NODE_NAME>"
	)
fi

echo

# ------------------------------------------------
# Node Pressure conditions
# ------------------------------------------------

echo "--------------- NODE PRESSURE ------------------"

PRESSURE=$(oc get nodes -o json 2>/dev/null | jq -r '
	.items[] |
	.metadata.name as $node |
	.status.conditions[] |
	select(
		(
			.type=="DiskPressure" or
			.type=="MemoryPressure" or
			.type=="PIDPressure"
		)
		and
		.status=="True"
	) |
	"\($node) (\(.type))"
')

if [[ -z "$PRESSURE" ]]; then
	green "No node pressure conditions"
else
	red "Node pressure condition(s) detected"
	echo "$PRESSURE" | sed 's/^/        /'
	
	INVESTIGATE+=(
		"Node Pressure|oc get nodes"
		"Node Pressure|oc describe node <NODE_NAME>"
		"Node Pressure|oc adm top nodes"
	)
fi

echo

# ------------------------------------------------
# Node Pressure Usages
# ------------------------------------------------

echo "---------------- NODE UTILIZATION -------------------"

TOP_OUTPUT=$(oc adm top nodes --no-headers 2>/dev/null)

if [[ -n "$TOP_OUTPUT" ]]; then

	HIGH_CPU=$(echo "$TOP_OUTPUT" | \
		awk '{
			cpu=$3
			gsub("%","",cpu)
			if((cpu+0) >= 80)
				print $1 " CPU=" $3
		}')
		
	HIGH_MEM=$(echo "$TOP_OUTPUT" | \
		awk '{
			mem=$5
			gsub("%","",mem)
			if((mem+0) >= 80)
				print $1 " MEM=" $5
		}')
	
	if [[ -z "$HIGH_CPU" ]]; then
		green "No node >=80% CPU"
	else
		yellow "Node(s) >=80% CPU"
		echo "$HIGH_CPU" | sed 's/^/        /'
		
		INVESTIGATE+=(
			"High Node CPU|oc adm top nodes"
		)
		
	fi
	
	if [[ -z "$HIGH_MEM" ]]; then
		green "No node >=80% memory"
	else
		yellow "Node(s) >=80% memory"
		echo "$HIGH_MEM" | sed 's/^/        /'
		
		INVESTIGATE+=(
			"High Node Memory|oc adm top nodes"
		)
	
	fi
	
else
	yellow "Unable to retreive node metrics"
fi

echo

# ------------------------------------------------
# Pending CSRs
# ------------------------------------------------

echo "----------------------- CSRs -----------------------"

PENDING_CSR=$(oc get csr -o json 2>/dev/null | jq -r '
	.items[] |
	select (
		(.status.conditions // [] | length) == 0
	) |
	.metadata.name
')

CSR_COUNT=$(echo "$PENDING_CSR" | sed '/^$/d' | wc -l)

if [[ "$CSR_COUNT" -eq 0 ]]; then
	green "No pending CSRs"
else	
	yellow "$CSR_COUNT pending CSR(s)"
	echo "$PENDING_CSR" | sed 's/^/        /'
	
	INVESTIGATE+=(
		"Pending CSRs|oc get csr"
		"Pending CSRs|oc describe csr <CSR_NAME>"
	)

fi

echo

# ------------------------------------------------
# Pending Pods
# ------------------------------------------------

echo "---------------------- PENDING PODS -----------------"

PENDING_PODS=$(oc get pods -A -o json 2>/dev/null | jq -r '
	.items[] |
	select(.status.phase == "Pending") |
	"\(.metadata.namespace)/\(.metadata.name)"
')

PENDING_COUNT=$(echo "$PENDING_PODS" | sed '/^$/d' | wc -l)

if [[ "$PENDING_COUNT" -eq 0 ]]; then
	green "No Pending pods"
else
	yellow "$PENDING_COUNT Pending pod(s)"
	echo "$PENDING_PODS" | head -10 | sed 's/^/        /'
	
	if [[ "$PENDING_COUNT" -gt 10 ]]; then
		echo "         ... showing first 10"
	fi
	
	INVESTIGATE+=(
		"Pending Pods|oc get pods -A"
		"Pending Pods|oc describe pod <POD_NAME> -n <NAMESPACE>"
	)

fi

echo

# ------------------------------------------------
# High Restart Pods
# ------------------------------------------------

echo "-------------------- RESTARTS -----------------------"

RESTART_PODS=$(oc get pods -A -o json 2>/dev/null | jq -r '
	.items[] |
	.metadata.namespace as $ns |
	.metadata.name as $pod |
	([.status.containerStatuses[]?.restartCount] | add // 0) as $restarts |
	select($restarts >= 10) |
	"\($ns)/\($pod) (\($restarts) restarts)"
')

RESTART_COUNT=$(echo "$RESTART_PODS" | sed '/^$/d' | wc -l)

if [[ "$RESTART_COUNT" -eq 0 ]]; then
	green "No pods with >=10 restarts"
else
	yellow "$RESTART_COUNT pod(s) with >=10 restarts"
	echo "$RESTART_PODS" | head -10 | sed 's/^/        /'
	
	if [[ "$RESTART_COUNT" -gt 10 ]]; then
		echo "           ... showing first 10"
	fi
	
	INVESTIGATE+=(
		"High Restarts|oc get pods -A"
		"High Restarts|oc describe pod <POD_NAME> -n <NAMESPACE>"
		"High Restarts|oc logs <POD_NAME> -n <NAMESPACE> --previous"
	)

fi

echo 

# ------------------------------------------------
# PVC Health
# ------------------------------------------------

echo "---------------------- STORAGE ----------------------"

BAD_PVC=$(oc get pvc -A --no-headers 2>/dev/null | \
	awk '$3!="Bound" {
		print $1 "/" $2 " (" $3 ")"
	}')

BAD_PVC_COUNT=$(echo "$BAD_PVC" | sed '/^$/d' | wc -l)

if [[ "$BAD_PVC_COUNT" -eq 0 ]]; then
	green "All PVCs Bound"
else
	yellow "$BAD_PVC_COUNT PVC(s) not Bound"
	echo "$BAD_PVC" | head -10 | sed 's/^/        /'
	
	INVESTIGATE+=(
		"PVC Problem|oc get pvc -A"
		"PVC Problem|oc describe pvc <PVC_NAME> -n <NAMESPACE>"
	)

fi

echo

# ------------------------------------------------
# PodDisruptionBudgets
# ------------------------------------------------

echo "--------------------- DISRUPTION BUDGETS -----------------"

ZERO_PDB=$(oc get pdb -A \
	-o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,ALLOW:.status.disruptionsAllowed,EXPECTED:.status.expectedPods' \
	--no-headers 2>/dev/null | \
	awk '$3 == 0 && $4 > 0 {
		print $1 "/" $2
	}')
	
ZERO_PDB_COUNT=$(echo "$ZERO_PDB" | sed '/^$/d' | wc -l)

if [[ "$ZERO_PDB_COUNT" -eq 0 ]]; then
	green "No PDBs currently blocking all disruptions"
else
	yellow "$ZERO_PDB_COUNT PDB(s) allow zero disruptions"
	echo "$ZERO_PDB" | head -10 | sed 's/^/        /'
	
	INVESTIGATE+=(
		"PDB Zero Disruptions|oc get pdb -A"
		"PDB Zero Disruptions|oc describe pdb <PDB_NAME> -n <NAMESPACE>"
	)
	
fi

echo

# ------------------------------------------------
# MachineHealthChecks
# ------------------------------------------------

echo "--------------- MACHINE HEALTH CHECKS ----------------"

MHC_COUNT=$(oc get machinehealthcheck -n openshift-machine-api \
	--no-headers 2>/dev/null | wc -l)
	
if [[ "$MHC_COUNT" -eq 0 ]]; then
	yellow "No MachineHealthChecks found"
else
	echo "MachineHealthChecks"
	oc get machinehealthcheck -n openshift-machine-api 2>/dev/null
	
	MHC_100=$(oc get machinehealthcheck -n openshift-machine-api \
		-o json 2>/dev/null | jq '
		[
			.items[] |
			select(.spec.maxUnhealthy == "100%")
		] | length
	')

	if [[ "$MHC_100" -eq 0 ]]; then
		green "No MachineHealthChecks use maxUnhealthy=100%"
	else
		yellow "$MHC_100 MachineHealthCheck(s) use maxUnhealthy=100%"
		
		INVESTIGATE+=(
			"MachineHealthChecks|oc get machinehealthcheck -n openshift-machine-api"
			"MachineHealthChecks|oc describe machinehealthcheck <MHC_NAME> -n openshift-machine-api"
		)
		
	fi
fi

echo

# ------------------------------------------------
# Available Updates
# ------------------------------------------------

echo "------------------- AVAILABLE UPDATES ----------------------"

AVAILABLE=$(oc get clusterversion version \
	-o jsonpath='{range .status.availableUpdates[*]}{.version}{"\n"}{end}' \
	2>/dev/null)
	
if [[ -z "$AVAILABLE" ]]; then
	yellow "No available updates currently reported"
else
	echo "Available update version(s)"
	echo "$AVAILABLE" | sed 's/^/        /'
fi

echo

# ------------------------------------------------
# Recent Warning Events
# ------------------------------------------------

echo "--------------------- WARNING EVENTS ------------------------"

WARNING_COUNT=$(oc get events -A \
	--field-selector type=Warning \
	--no-headers 2>/dev/null | wc -l)
	
if [[ "$WARNING_COUNT" -eq 0 ]]; then
	green "No Warning event entries currently returned"
elif [[ "$WARNING_COUNT" -lt 20 ]]; then
	yellow "$WARNING_COUNT Warning event entries"
else
	yellow "$WARNING_COUNT Warning event entries -- worth reviewing"
fi

if [[ "$WARNING_COUNT" -gt 10 ]]; then
	INVESTIGATE+=(
		"Warning Events|oc get events -A --field-selector type=Warning --sort-by=.lastTimestamp"
	)
fi

echo

# ------------------------------------------------
# Summary
# ------------------------------------------------

echo "========================================"
echo " UPGRADE PRE-FLIGHT SUMMARY"
echo "========================================"
echo " PASS: $PASS"
echo " WARN: $WARN"
echo " FAIL: $FAIL"
echo "========================================"

if [[ "$FAIL" -gt 0 ]]; then
	echo " RESULT: Resolve FAIL Conditions before upgrade"
elif [[ "$WARN" -gt 0 ]]; then
	echo " RESULT: Review WARN conditions before upgrade"
else
	echo " RESULT: No obvious pre-flight issues detected"

fi

# ------------------------------------------------
# Investigation Commands
# ------------------------------------------------

if [[ ${#INVESTIGATE[@]} -gt 0 ]]; then

	echo 
	echo "========================================"
	echo " INVESTIGATE"
	echo "========================================"
	
	LAST_REASON=""
	
	for ENTRY in "${INVESTIGATE[@]}"; do
	
		REASON="${ENTRY%%|*}"
		COMMAND="${ENTRY#*|}"
		
		if [[ "$REASON" != "$LAST_REASON" ]]; then
			echo
			echo "$REASON:"
			LAST_REASON="$REASON"
			
		fi
		
		echo "        $COMMAND"
		
	done
	
	echo
	echo "========================================="
fi

# ------------------------------------------------
# Exit Code
# ------------------------------------------------

if [[ "$FAIL" -gt 0 ]]; then
	exit 2
elif [[ "$WARN" -gt 0 ]]; then
	exit 1
else
	exit 0
fi