#!/usr/bin/env bash
#
# common.sh
#
# Shared helpers and definitions for the medik8s -> WAO upgrade POC scripts.
# Source it from a step script:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   POC_LOG_PREFIX="backup"            # optional; defaults to "poc"
#   . "${SCRIPT_DIR}/common.sh"
#
# It is safe to source more than once. This file defines variables and
# functions only; it does not run any step logic.
#
# shellcheck shell=bash

# Guard against double-sourcing.
[ -n "${_MEDIK8S_COMMON_SOURCED:-}" ] && return 0
_MEDIK8S_COMMON_SOURCED=1

# ---------------------------------------------------------------------------
# Canonical medik8s operator registry (single source of truth)
# Fields:  display | apiGroup | olmPackage | backupDir | waoComponent
# (waoComponent is the key under WorkloadAvailabilityConfig .spec.components)
# ---------------------------------------------------------------------------
MEDIK8S_OPERATORS=(
  "Node Health Check (NHC)|remediation.medik8s.io|node-healthcheck-operator|nhc-backup|nodeHealthCheck"
  "Self Node Remediation (SNR)|self-node-remediation.medik8s.io|self-node-remediation|snr-backup|selfNodeRemediation"
  "Storage Based Remediation (SBR)|storage-based-remediation.medik8s.io|storage-based-remediation|sbr-backup|storageBasedRemediation"
  "Fence Agents Remediation (FAR)|fence-agents-remediation.medik8s.io|fence-agents-remediation|far-backup|fenceAgentsRemediation"
  "Machine Deletion Remediation (MDR)|machine-deletion-remediation.medik8s.io|machine-deletion-remediation|mdr-backup|machineDeletionRemediation"
  "Node Maintenance (NMO)|nodemaintenance.medik8s.io|node-maintenance-operator|nmo-backup|nodeMaintenance"
)

# Derived views of the registry, kept for the step scripts that consume them.
#   OPERATORS: backupDir|display|apiGroup   (used by the backup step)
#   PACKAGES:  olmPackage|display|apiGroup  (used by the delete step)
OPERATORS=()
PACKAGES=()
_mk_op=""
for _mk_op in "${MEDIK8S_OPERATORS[@]}"; do
  IFS='|' read -r _mk_disp _mk_grp _mk_pkg _mk_dir _mk_comp <<<"$_mk_op"
  OPERATORS+=("${_mk_dir}|${_mk_disp}|${_mk_grp}")
  PACKAGES+=("${_mk_pkg}|${_mk_disp}|${_mk_grp}")
done
unset _mk_op _mk_disp _mk_grp _mk_pkg _mk_dir _mk_comp

# Remediation "request" CRs whose mere existence signals an in-progress
# remediation (or node maintenance). Fields: Kind | apiGroup
MEDIK8S_REMEDIATIONS=(
  "SelfNodeRemediation|self-node-remediation.medik8s.io"
  "FenceAgentsRemediation|fence-agents-remediation.medik8s.io"
  "MachineDeletionRemediation|machine-deletion-remediation.medik8s.io"
  "StorageBasedRemediation|storage-based-remediation.medik8s.io"
  "NodeMaintenance|nodemaintenance.medik8s.io"
)

# ---------------------------------------------------------------------------
# Backup step configuration (POC: fixed values)
# ---------------------------------------------------------------------------
# Namespace for the backup PVC/pod — colocated with the medik8s CRs / WAO operands.
NAMESPACE="${WAO_BACKUP_NAMESPACE:-openshift-workload-availability}"
PVC_NAME="medik8s-crs-backup"
POD_NAME="medik8s-backup-writer"
STORAGE_SIZE="1Gi"
STORAGE_CLASS="" # empty = cluster default
IMAGE="${WAO_MUST_GATHER_IMAGE:-quay.io/medik8s/must-gather:latest}"
MOUNT="/backup"
SENTINEL="${MOUNT}/.backup-complete"
WAIT_TIMEOUT="180s"

# ---------------------------------------------------------------------------
# Logging (prefix set per step via POC_LOG_PREFIX)
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m[%s]\033[0m %s\n' "${POC_LOG_PREFIX:-poc}" "$*" >&2; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "${POC_LOG_PREFIX:-poc}" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "${POC_LOG_PREFIX:-poc}" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# CRD helpers
# ---------------------------------------------------------------------------

# CRD full names (plural.group) belonging to an API group.
crds_in_group() {
  kubectl get crds \
    -o jsonpath="{range .items[?(@.spec.group=='$1')]}{.metadata.name}{\"\n\"}{end}" \
    2>/dev/null || true
}

# Scope ("Namespaced" or "Cluster") of a CRD; defaults to Namespaced.
crd_scope() {
  kubectl get crd "$1" -o jsonpath='{.spec.scope}' 2>/dev/null || echo Namespaced
}

# Resolve the CRD full name (plural.group) for a Kind within an API group.
# Prints nothing if the CRD is not installed.
crd_for_kind() {
  local kind="$1" group="$2" crd k
  for crd in $(crds_in_group "$group"); do
    k="$(kubectl get crd "$crd" -o jsonpath='{.spec.names.kind}' 2>/dev/null || true)"
    if [ "$k" = "$kind" ]; then
      printf '%s\n' "$crd"
      return 0
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Installed-operator record
# ---------------------------------------------------------------------------
SUBSCRIPTION_RES="subscriptions.operators.coreos.com"

# Echo "pkg|namespace|subName" for each known medik8s package that has a
# Subscription on the cluster.
installed_medik8s_subscriptions() {
  local subs entry pkg display group line ns sub spec
  subs="$(kubectl get "$SUBSCRIPTION_RES" -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.spec.name}{"\n"}{end}' \
    2>/dev/null || true)"
  for entry in "${PACKAGES[@]}"; do
    IFS='|' read -r pkg display group <<<"$entry"
    line="$(printf '%s\n' "$subs" | awk -F'|' -v p="$pkg" '$3==p{print; exit}')"
    [ -z "$line" ] && continue
    IFS='|' read -r ns sub spec <<<"$line"
    printf '%s|%s|%s\n' "$pkg" "$ns" "$sub"
  done
  return 0
}

# Save a minimal, re-appliable Subscription manifest for one operator to the backup
# PVC at /backup/operators/<pkg>.subscription.yaml (via the backup pod).
save_subscription_to_backup() {
  local pkg="$1" ns="$2" sub="$3" channel name source srcns approval
  channel="$(kubectl get "$SUBSCRIPTION_RES" "$sub" -n "$ns" -o jsonpath='{.spec.channel}' 2>/dev/null || true)"
  name="$(kubectl get "$SUBSCRIPTION_RES" "$sub" -n "$ns" -o jsonpath='{.spec.name}' 2>/dev/null || true)"
  source="$(kubectl get "$SUBSCRIPTION_RES" "$sub" -n "$ns" -o jsonpath='{.spec.source}' 2>/dev/null || true)"
  srcns="$(kubectl get "$SUBSCRIPTION_RES" "$sub" -n "$ns" -o jsonpath='{.spec.sourceNamespace}' 2>/dev/null || true)"
  approval="$(kubectl get "$SUBSCRIPTION_RES" "$sub" -n "$ns" -o jsonpath='{.spec.installPlanApproval}' 2>/dev/null || true)"
  [ -z "$approval" ] && approval=Automatic
  kubectl exec -i -n "$NAMESPACE" "$POD_NAME" -- \
    /bin/sh -c "mkdir -p '${MOUNT}/operators' && cat > '${MOUNT}/operators/${pkg}.subscription.yaml'" <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${sub}
  namespace: ${ns}
spec:
  channel: ${channel}
  name: ${name}
  source: ${source}
  sourceNamespace: ${srcns}
  installPlanApproval: ${approval}
EOF
}

# ---------------------------------------------------------------------------
# Active-remediation gate
#
# Refuses to proceed while any medik8s remediation (or node maintenance) is in
# progress. Reusable by every destructive upgrade step. The presence of a
# remediation-request CR instance means a remediation is active.
# ---------------------------------------------------------------------------
check_no_active_remediations() {
  log "checking for active remediations"
  local found=0 entry kind group crd lines line

  for entry in "${MEDIK8S_REMEDIATIONS[@]}"; do
    IFS='|' read -r kind group <<<"$entry"
    crd="$(crd_for_kind "$kind" "$group")"
    [ -z "$crd" ] && continue

    # Works for both namespaced (-A) and cluster-scoped (fallback) resources.
    lines="$(kubectl get "$crd" -A \
               -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' \
               2>/dev/null \
             || kubectl get "$crd" \
               -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
               2>/dev/null \
             || true)"

    [ -z "$lines" ] && continue
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      warn "  active ${kind}: ${line}"
      found=$((found + 1))
    done <<<"$lines"
  done

  if [ "$found" -gt 0 ]; then
    die "refusing to proceed: ${found} active remediation(s)/maintenance in progress. Wait for them to finish, then retry."
  fi
  log "  no active remediations"
}
