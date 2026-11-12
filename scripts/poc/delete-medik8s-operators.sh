#!/usr/bin/env bash
#
# delete-existing-operators.sh
#
# Proof-of-concept for the WAO upgrade "delete source operators" step.
#
# Deletes the medik8s operators and their resources from the
# cluster, in a safe order, then prints the operator names and versions that
# were removed. Only these operators are ever touched:
#
#   NHC  node-healthcheck-operator      remediation.medik8s.io
#   SNR  self-node-remediation          self-node-remediation.medik8s.io
#   SBR  storage-based-remediation      storage-based-remediation.medik8s.io
#   FAR  fence-agents-remediation       fence-agents-remediation.medik8s.io
#   MDR  machine-deletion-remediation   machine-deletion-remediation.medik8s.io
#   NMO  node-maintenance-operator      nodemaintenance.medik8s.io
#
# Deletion order (each step waits for completion before the next):
#   1. CRs       - every custom resource instance of the six operators'
#                  CRDs (the CRDs themselves are NOT deleted). The operators are
#                  still running here, so they can clear finalizers.
#   2. Operands  - workloads the operators spawned from those CRs (e.g. SNR's
#                  per-node agent DaemonSet). These are removed automatically by
#                  owner-reference garbage collection once the CRs are gone; the
#                  script waits for that, and force-deletes only leftovers that
#                  are owned by the deleted CRs.
#   3. Operators - the OLM install itself (Subscription + ClusterServiceVersion),
#                  which removes the controller-manager deployments.
#
# Discovery is by OLM package name: Subscriptions whose spec.name is one of the
# six known packages are followed to their installed CSV (for version/namespace).
# Nothing outside the six packages / six API groups is deleted.
#
# Before deleting anything it refuses to proceed while any medik8s remediation
# or node maintenance is in progress (shared check in common.sh), and it captures
# each operator's Subscription to the backup PVC (/backup/operators/) so
# rollback-to-medik8s.sh can reinstall them later.
#
# This is a POC. It does NOT delete CRDs, OperatorGroups, or namespaces. Run the
# backup script first (scripts/poc/backup-medik8s-crs.sh).
#
# Safety: prompts for confirmation unless WAO_DELETE_ASSUME_YES=1 (or --yes).
# Use --dry-run to preview without changing anything.
#
# Requirements: kubectl, awk, and a reachable OLM-enabled cluster.
#
set -euo pipefail

# Shared config, registry, and helpers (PACKAGES list, logging, CRD helpers,
# active-remediation gate).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_LOG_PREFIX="delete"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Configuration (override via environment)
# ---------------------------------------------------------------------------
DELETE_TIMEOUT="${WAO_DELETE_TIMEOUT:-300}"   # seconds to wait per phase
POLL_INTERVAL="${WAO_DELETE_POLL:-5}"         # seconds between checks
ASSUME_YES="${WAO_DELETE_ASSUME_YES:-0}"
DRY_RUN=0

SUB_RES="subscriptions.operators.coreos.com"
CSV_RES="clusterserviceversions.operators.coreos.com"

# Populated by discover_operators():
# each entry: pkg|display|ns|subName|csvName|version|group
DISCOVERED=()
DISCOVERED_GROUPS=()
CR_KINDS_SPACE=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run a mutating command, or just print it under --dry-run.
maybe() {
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY-RUN: $*"
  else
    "$@"
  fi
}

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--dry-run] [--yes]

  --dry-run   Show what would be deleted without changing anything.
  --yes       Do not prompt for confirmation (or set WAO_DELETE_ASSUME_YES=1).
EOF
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found on PATH"
  command -v awk >/dev/null 2>&1 || die "awk not found on PATH"

  local kubeconfig context server
  kubeconfig="${KUBECONFIG:-$HOME/.kube/config}"
  kubectl version >/dev/null 2>&1 \
    || die "cannot reach a cluster (KUBECONFIG=${kubeconfig}). Is your context set?"
  kubectl get crd "$SUB_RES" >/dev/null 2>&1 \
    || die "OLM not detected (no ${SUB_RES} CRD); this script manages OLM operators"

  context="$(kubectl config current-context 2>/dev/null || echo '<unknown>')"
  server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo '<unknown>')"
  log "kubeconfig : ${kubeconfig}"
  if [ "$DRY_RUN" = "1" ]; then log "mode       : DRY-RUN (no changes will be made)"; fi
}

# ---------------------------------------------------------------------------
# Discover the installed medik8s operators by OLM package name.
# ---------------------------------------------------------------------------
discover_operators() {
  log "discovering medik8s operators"

  local subs
  subs="$(kubectl get "$SUB_RES" -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.spec.name}{"|"}{.status.installedCSV}{"|"}{.status.currentCSV}{"\n"}{end}' \
    2>/dev/null || true)"

  local entry pkg display group
  for entry in "${PACKAGES[@]}"; do
    IFS='|' read -r pkg display group <<<"$entry"

    # Find a Subscription whose spec.name matches this package.
    local line ns sub spec installed current csv version
    line="$(printf '%s\n' "$subs" | awk -F'|' -v p="$pkg" '$3==p {print; exit}')"
    if [ -z "$line" ]; then
      log "  ${display}: not installed"
      continue
    fi
    IFS='|' read -r ns sub spec installed current <<<"$line"
    csv="${installed:-$current}"

    version="?"
    if [ -n "$csv" ]; then
      version="$(kubectl get "$CSV_RES" "$csv" -n "$ns" -o jsonpath='{.spec.version}' 2>/dev/null || echo '?')"
    fi

    log "  ${display}: subscription '${sub}' in '${ns}', CSV '${csv:-<none>}' (v${version})"
    DISCOVERED+=("${pkg}|${display}|${ns}|${sub}|${csv}|${version}|${group}")
    DISCOVERED_GROUPS+=("$group")
  done

  if [ "${#DISCOVERED[@]}" -eq 0 ]; then
    log "no medik8s operators found; nothing to do"
    exit 0
  fi

  # Collect the CR kinds for the discovered groups (for operand owner matching).
  local g crds crd k allkinds=""
  for g in "${DISCOVERED_GROUPS[@]}"; do
    crds="$(crds_in_group "$g")"
    for crd in $crds; do
      k="$(kubectl get crd "$crd" -o jsonpath='{.spec.names.kind}' 2>/dev/null || true)"
      [ -n "$k" ] && allkinds="${allkinds} ${k}"
    done
  done
  CR_KINDS_SPACE="$(printf '%s' "$allkinds" | tr ' ' '\n' | awk 'NF' | sort -u | tr '\n' ' ')"
}

confirm() {
  [ "$DRY_RUN" = "1" ] && return 0
  [ "$ASSUME_YES" = "1" ] && return 0
  local ans
  printf '\n\033[1;31mThis will DELETE the operators listed above and all their CRs/operands.\033[0m\n' >&2
  printf 'Type "yes" to continue: ' >&2
  read -r ans || true
  [ "$ans" = "yes" ] || die "aborted by user"
}

# ---------------------------------------------------------------------------
# Count remaining CR instances across the discovered groups.
# ---------------------------------------------------------------------------
count_crs() {
  local total=0 g crds crd scope n
  for g in "${DISCOVERED_GROUPS[@]}"; do
    crds="$(crds_in_group "$g")"
    for crd in $crds; do
      scope="$(crd_scope "$crd")"
      if [ "$scope" = "Namespaced" ]; then
        n="$(kubectl get "$crd" -A -o name 2>/dev/null | grep -c . || true)"
      else
        n="$(kubectl get "$crd" -o name 2>/dev/null | grep -c . || true)"
      fi
      total=$((total + n))
    done
  done
  echo "$total"
}

# ---------------------------------------------------------------------------
# Phase 1: delete CRs. Operators still run, so finalizers clear.
# ---------------------------------------------------------------------------
delete_crs() {
  log "PHASE 1/3: deleting custom resources"
  local g crds crd scope

  for g in "${DISCOVERED_GROUPS[@]}"; do
    crds="$(crds_in_group "$g")"
    for crd in $crds; do
      scope="$(crd_scope "$crd")"
      if [ "$scope" = "Namespaced" ]; then
        # `kubectl delete` has no --all-namespaces; enumerate and delete per item.
        local items
        items="$(kubectl get "$crd" -A \
          -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
          2>/dev/null || true)"
        printf '%s\n' "$items" | while IFS=' ' read -r ns name; do
          [ -z "${name:-}" ] && continue
          maybe kubectl delete "$crd" "$name" -n "$ns" --wait=false --ignore-not-found
        done
      else
        maybe kubectl delete "$crd" --all --wait=false --ignore-not-found
      fi
    done
  done

  wait_crs_gone
}

wait_crs_gone() {
  if [ "$DRY_RUN" = "1" ]; then log "DRY-RUN: would wait for CRs to be deleted"; return 0; fi
  local deadline remaining
  deadline=$(( $(date +%s) + DELETE_TIMEOUT ))
  while :; do
    remaining="$(count_crs)"
    if [ "$remaining" -eq 0 ]; then log "  all CRs deleted"; return 0; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      warn "  timeout waiting for CRs (${remaining} remaining); they may have finalizers"
      return 1
    fi
    log "  waiting for CRs to delete (${remaining} remaining)..."
    sleep "$POLL_INTERVAL"
  done
}

# ---------------------------------------------------------------------------
# Phase 2: operands. Find workloads owned by our CR kinds and wait for GC.
# ---------------------------------------------------------------------------
get_operands() {
  [ -z "$CR_KINDS_SPACE" ] && return 0
  local types="daemonsets deployments statefulsets replicasets jobs pods" t
  for t in $types; do
    kubectl get "$t" -A \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{range .metadata.ownerReferences[*]}{.kind}{" "}{end}{"\n"}{end}' \
      2>/dev/null \
    | awk -v t="$t" -v kinds="$CR_KINDS_SPACE" '
        BEGIN { n=split(kinds,a," "); for(i=1;i<=n;i++) if(a[i]!="") set[a[i]]=1 }
        {
          split($0, p, "|"); ns=p[1]; name=p[2]; owners=p[3];
          if (name=="") next;
          m=split(owners, o, " ");
          for (i=1;i<=m;i++) if (o[i] in set) { print t "|" ns "|" name; break }
        }'
  done
}

delete_operands() {
  log "PHASE 2/3: waiting for operands to clear"

  if [ "$DRY_RUN" = "1" ]; then
    local snap
    snap="$(get_operands || true)"
    if [ -z "$snap" ]; then
      log "DRY-RUN: no CR-owned operand workloads currently present"
    else
      printf '%s\n' "$snap" | while IFS='|' read -r t ns name; do
        log "DRY-RUN: would wait for / force-delete ${t} ${ns}/${name}"
      done
    fi
    return 0
  fi

  local deadline remaining
  deadline=$(( $(date +%s) + DELETE_TIMEOUT ))
  while :; do
    remaining="$(get_operands || true)"
    if [ -z "$remaining" ]; then log "  all operand workloads cleared"; return 0; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      warn "  timeout waiting for GC; force-deleting remaining operand workloads"
      printf '%s\n' "$remaining" | while IFS='|' read -r t ns name; do
        [ -z "$name" ] && continue
        log "  force-deleting ${t} ${ns}/${name}"
        kubectl delete "$t" "$name" -n "$ns" --wait=false --ignore-not-found || true
      done
      return 0
    fi
    local count
    count="$(printf '%s\n' "$remaining" | grep -c . || true)"
    log "  waiting for ${count} operand workload(s) to be garbage-collected..."
    sleep "$POLL_INTERVAL"
  done
}

# ---------------------------------------------------------------------------
# Phase 3: delete the OLM operators (Subscription + CSV), wait for CSV removal.
# ---------------------------------------------------------------------------
# Capture each discovered operator's Subscription to the backup PVC so rollback
# can reinstall the originals faithfully (uses the shared save_subscription_to_backup
# from common.sh). Best-effort: if the backup pod is absent, warn and continue.
# NOTE: the backup step also records installed operators; this is a belt-and-braces
# capture at delete time.
# ---------------------------------------------------------------------------
capture_subscriptions() {
  if ! kubectl get pod "$POD_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    warn "backup pod '${POD_NAME}' not found in '${NAMESPACE}'; skipping Subscription capture"
    warn "(rollback will reinstall from the backup step's record instead)"
    return 0
  fi
  log "capturing operator Subscriptions to the backup PVC (for rollback)"
  local entry pkg display ns sub csv version group
  for entry in "${DISCOVERED[@]}"; do
    IFS='|' read -r pkg display ns sub csv version group <<<"$entry"
    if [ "$DRY_RUN" = "1" ]; then
      log "  DRY-RUN: would save ${pkg} subscription -> operators/${pkg}.subscription.yaml"
      continue
    fi
    save_subscription_to_backup "$pkg" "$ns" "$sub"
    log "  saved ${pkg} -> operators/${pkg}.subscription.yaml"
  done
}

delete_operators() {
  log "PHASE 3/3: deleting operators"
  local entry pkg display ns sub csv version group

  for entry in "${DISCOVERED[@]}"; do
    IFS='|' read -r pkg display ns sub csv version group <<<"$entry"
    log "  ${display}: deleting subscription '${sub}'"
    maybe kubectl delete "$SUB_RES" "$sub" -n "$ns" --wait=false --ignore-not-found
    if [ -n "$csv" ]; then
      log "  ${display}: deleting CSV '${csv}'"
      maybe kubectl delete "$CSV_RES" "$csv" -n "$ns" --wait=false --ignore-not-found
    fi
  done

  wait_csvs_gone
}

wait_csvs_gone() {
  if [ "$DRY_RUN" = "1" ]; then log "DRY-RUN: would wait for CSVs to be deleted"; return 0; fi
  local deadline entry pkg display ns sub csv version group remaining
  deadline=$(( $(date +%s) + DELETE_TIMEOUT ))
  while :; do
    remaining=0
    for entry in "${DISCOVERED[@]}"; do
      IFS='|' read -r pkg display ns sub csv version group <<<"$entry"
      [ -z "$csv" ] && continue
      if kubectl get "$CSV_RES" "$csv" -n "$ns" >/dev/null 2>&1; then
        remaining=$((remaining + 1))
      fi
    done
    if [ "$remaining" -eq 0 ]; then log "  all operator CSVs deleted"; return 0; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      warn "  timeout waiting for ${remaining} CSV(s) to delete"
      return 1
    fi
    log "  waiting for ${remaining} operator CSV(s) to delete..."
    sleep "$POLL_INTERVAL"
  done
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
summary() {
  echo
  echo "============================================================"
  echo " Deleted medik8s operators"
  echo "============================================================"
  printf '  %-34s %-12s %-28s %s\n' "OPERATOR" "VERSION" "PACKAGE" "NAMESPACE"
  local entry pkg display ns sub csv version group
  for entry in "${DISCOVERED[@]}"; do
    IFS='|' read -r pkg display ns sub csv version group <<<"$entry"
    printf '  %-34s %-12s %-28s %s\n' "$display" "v${version}" "$pkg" "$ns"
  done
  echo "============================================================"
  echo "Operators removed: ${#DISCOVERED[@]}"
  [ "$DRY_RUN" = "1" ] && echo "(DRY-RUN: nothing was actually deleted)"
  echo "============================================================"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --yes|-y)  ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "unknown argument: $1" ;;
    esac
    shift
  done

  preflight
  check_no_active_remediations
  discover_operators
  confirm

  capture_subscriptions
  delete_crs
  delete_operands
  delete_operators
  summary
}

main "$@"
