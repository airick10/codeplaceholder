#!/usr/bin/env bash
# Manually initiated OpenShift etcd backup and verified off-node collection.
# Usage: ./ocp-etcd-backup.sh <kubeconfig-file-name> <master-node-name>
set -Eeuo pipefail
umask 077

if (( $# != 2 )); then
  echo "Usage: $0 <kubeconfig-file-name> <master-node-name>" >&2
  exit 2
fi

cluster="$1"
node="$2"
# The cluster argument is a basename below ~/.kube/clusters, not a path.
if [[ ! "$cluster" =~ ^[A-Za-z0-9._-]+$ || ! "$node" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Cluster and node names must contain only letters, digits, dots, underscores, or hyphens." >&2
  exit 2
fi

command -v oc >/dev/null || { echo "Missing oc CLI" >&2; exit 2; }
command -v jq >/dev/null || { echo "Missing jq" >&2; exit 2; }
command -v tar >/dev/null || { echo "Missing tar" >&2; exit 2; }
command -v sha256sum >/dev/null || { echo "Missing sha256sum" >&2; exit 2; }

kubeconfig="$HOME/.kube/clusters/$cluster"
[[ -f "$kubeconfig" ]] || { echo "Kubeconfig not found: $kubeconfig" >&2; exit 2; }

# Adjust the root below if your bastion backup directory is different.
backup_root="$HOME/openshift-backups"
run_id="$(date -u +%Y%m%dT%H%M%SZ)"
node_dir="/home/core/assets/backup/automated-${run_id}"
debug_dir="/host/var/home/core/assets/backup/automated-${run_id}"
local_dir="$backup_root/$cluster/$run_id"
mkdir -p "$local_dir"
archive="$local_dir/backup.tar.partial"
log="$local_dir/backup.log"
manifest="$local_dir/manifest.txt"

failed() {
  rc=$?
  echo "FAILED (exit $rc): $cluster; partial files kept at $local_dir" >&2
}
trap failed ERR

echo "Checking access and cluster state..."
identity="$(oc --kubeconfig="$kubeconfig" whoami)"
api="$(oc --kubeconfig="$kubeconfig" whoami --show-server)"
version="$(oc --kubeconfig="$kubeconfig" get clusterversion version -o jsonpath='{.status.desired.version}')"
actual_node="$(oc --kubeconfig="$kubeconfig" get node "$node" -o json)"
if [[ "$(jq -r '.metadata.labels["node-role.kubernetes.io/master"] // "MISSING"' <<< "$actual_node")" == "MISSING" ]] &&
   [[ "$(jq -r '.metadata.labels["node-role.kubernetes.io/control-plane"] // "MISSING"' <<< "$actual_node")" == "MISSING" ]]; then
  echo "Selected node is not labeled as a control-plane/master node." >&2
  exit 1
fi
if [[ "$(jq -r '.status.conditions[] | select(.type == "Ready") | .status' <<< "$actual_node")" != "True" ]]; then
  echo "Selected node is not Ready." >&2
  exit 1
fi
co="$(oc --kubeconfig="$kubeconfig" get co etcd -o json)"
if [[ "$(jq -r '.status.conditions[] | select(.type == "Available") | .status' <<< "$co")" != "True" ]] ||
   [[ "$(jq -r '.status.conditions[] | select(.type == "Degraded") | .status' <<< "$co")" != "False" ]] ||
   [[ "$(jq -r '.status.conditions[] | select(.type == "Progressing") | .status' <<< "$co")" != "False" ]]; then
  echo "etcd ClusterOperator is not stable (Available/Degraded/Progressing). Aborting." >&2
  exit 1
fi

echo "Cluster: $cluster ($api), version $version, node $node, user $identity"
echo "Creating node-local snapshot under: $node_dir"
# Backup stdout and stderr are logged locally, never mixed into the binary tar stream.
oc --kubeconfig="$kubeconfig" debug --as-root --quiet "node/$node" \
  -- chroot /host /bin/sh -c \
  'mkdir -p "$1" && /usr/local/bin/cluster-backup.sh "$1"' sh "$node_dir" \
  > "$log" 2>&1

# Calculate checksums remotely for exactly the two expected backup artifacts.
echo "Reading source SHA-256 checksums..."
remote_output="$(oc --kubeconfig="$kubeconfig" debug --as-root --quiet "node/$node" \
  -- sh -c 'cd "$1" || exit 1; set -- snapshot_*.db static_kuberesources_*.tar.gz; [ "$#" -eq 2 ] || exit 2; [ -f "$1" ] && [ -s "$1" ] && [ -f "$2" ] && [ -s "$2" ] || exit 2; sha256sum "$1" "$2"' sh "$debug_dir")"
# The debug command may include status lines. Only retain correctly formed SHA records.
source_checks="$(printf '%s\n' "$remote_output" | grep -E '^[0-9a-fA-F]{64}  (snapshot_[^/ ]+\.db|static_kuberesources_[^/ ]+\.tar\.gz)$')"
[[ "$(printf '%s\n' "$source_checks" | wc -l)" -eq 2 ]] || { echo "Did not get exactly two valid source checksums" >&2; exit 1; }
printf '%s\n' "$source_checks" > "$local_dir/source-sha256.txt"

# Stream directly to a bastion archive: no tar file is created on the node.
echo "Streaming archive from node to bastion..."
oc --kubeconfig="$kubeconfig" debug --as-root --quiet "node/$node" \
  -- tar -C "$debug_dir" -cf - . > "$archive"

# Reading every archived member helps detect truncation and stdout contamination.
tar -tf "$archive" > /dev/null
tar -xOf "$archive" > /dev/null

# Verify individual files against their original node-side checksums.
echo "Comparing file checksums..."
while read -r expected filename; do
  [[ "$filename" == snapshot_*.db || "$filename" == static_kuberesources_*.tar.gz ]] || exit 1
  actual="$(tar -xOf "$archive" "./$filename" | sha256sum | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "Checksum mismatch: $filename" >&2
    exit 1
  fi
  echo "MATCH: $filename"
done < "$local_dir/source-sha256.txt"

cat > "$manifest" <<MANIFEST
Cluster label: $cluster
API: $api
OpenShift version at backup: $version
Control-plane node: $node
Authenticated user: $identity
Timestamp UTC: $run_id
Source directory (node): $node_dir
Transfer: OpenShift API debug tar stream
Verification: both source SHA-256 digests match archived members
MANIFEST
mv "$archive" "$local_dir/backup.tar"
trap - ERR
echo "SUCCESS: $local_dir/backup.tar"
echo "Original two backup files remain on node under $node_dir"
