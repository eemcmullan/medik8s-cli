#!/usr/bin/env bash
#
# rollback-to-medik8s.sh
#
# Proof-of-concept for the WAO upgrade "rollback" step: undo the migration by
# removing WAO and reinstalling the original medik8s operators (with their CRs)
# from the backup.
#
# What it does:
#   1. Deletes the WAO custom resources and operator:
#        - component CR instances (NodeHealthCheck, *Config, *Template, ...) while
#          WAO is still running so finalizers clear,
#        - the WorkloadAvailabilityConfig 'cluster',
#        - the WAO Subscription + ClusterServiceVersion,
#        - the wao-poc-catalog CatalogSource.
#   2. Reinstalls the original operators that had backed-up CRs and waits for their
#      CSVs. It prefers the Subscription captured on the PVC by
#      delete-medik8s-operators.sh (/backup/operators/<package>.subscription.yaml);
#      if none was captured, it reconstructs a Subscription from the cluster's
#      package manifest (catalog/channel) and installs into openshift-operators.
#   3. Restores the backed-up CRs to their ORIGINAL namespaces (as captured in the backup)
#
# Requirements: kubectl, a reachable OLM cluster, and the backup PVC/pod from
# backup-medik8s-crs.sh (with Subscriptions captured during delete).
#
# Safety: refuses to proceed while any medik8s remediation or node maintenance is
# in progress (shared check in common.sh), and prompts for confirmation unless
# WAO_ROLLBACK_ASSUME_YES=1 (or --yes).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_LOG_PREFIX="rollback"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

WAO_INSTALL_NS="${WAO_INSTALL_NAMESPACE:-openshift-workload-availability}"
WAO_CONFIG_NAME="cluster"
WAO_CONFIG_CRD="workloadavailabilityconfigs.workloadavailability.medik8s.io"
WAO_SUB_NAME="workload-availability-operator"
CATALOG_NS="openshift-marketplace"
CATALOG_NAME="wao-poc-catalog"

SUB_RES="subscriptions.operators.coreos.com"
CSV_RES="clusterserviceversions.operators.coreos.com"

# Fallback reinstall: look the operator up in the cluster's package manifests. 
# A package can exist in multiple catalogs 
PM_NS="openshift-marketplace"
FALLBACK_SUB_NS="openshift-operators"
FALLBACK_CATALOGS="redhat-operators community-operators"

ROLLBACK_TIMEOUT="600"
POLL="5"
ASSUME_YES="${WAO_ROLLBACK_ASSUME_YES:-0}"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--yes]

Removes WAO and reinstalls the original medik8s operators (with their CRs) from
the backup. Reinstalls only operators whose backup directory has CRs.

  --yes   Do not prompt for confirmation (or set WAO_ROLLBACK_ASSUME_YES=1).
EOF
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found on PATH"
  command -v awk >/dev/null 2>&1 || die "awk not found on PATH"
  kubectl version >/dev/null 2>&1 || die "cannot reach a cluster (check KUBECONFIG/context)"
  kubectl get crd "$SUB_RES" >/dev/null 2>&1 || die "OLM not detected (${SUB_RES} missing)"
  kubectl get pod "$POD_NAME" -n "$NAMESPACE" >/dev/null 2>&1 \
    || die "backup pod '${POD_NAME}' not found in '${NAMESPACE}'; run backup-medik8s-crs.sh first"
  log "cluster : $(kubectl config current-context 2>/dev/null || echo '<unknown>')"
}

confirm() {
  [ "$ASSUME_YES" = "1" ] && return 0
  local ans
  printf '\n\033[1;31mThis will DELETE WAO and reinstall the original medik8s operators from backup.\033[0m\n' >&2
  printf 'Type "yes" to continue: ' >&2
  read -r ans || true
  [ "$ans" = "yes" ] || die "aborted by user"
}

# ---------------------------------------------------------------------------
# Helpers shared with the other steps' patterns
# ---------------------------------------------------------------------------
is_transient_kind() {
  local k="$1" e kind grp
  for e in "${MEDIK8S_REMEDIATIONS[@]}"; do
    IFS='|' read -r kind grp <<<"$e"
    [ "$k" = "$kind" ] && return 0
  done
  return 1
}

# Count CR instances across all six medik8s groups.
count_medik8s_crs() {
  local total=0 g crds crd scope n
  for g in remediation.medik8s.io self-node-remediation.medik8s.io \
           storage-based-remediation.medik8s.io fence-agents-remediation.medik8s.io \
           machine-deletion-remediation.medik8s.io nodemaintenance.medik8s.io; do
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

apply_cr_retry() {
  local content="$1" label="$2" tries=0 max="${WAO_RESTORE_RETRIES:-36}" out rc
  while :; do
    out="$(printf '%s\n' "$content" | kubectl apply -f - 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then log "    applied ${label}"; return 0; fi
    tries=$((tries + 1))
    if [ "$tries" -ge "$max" ]; then
      warn "    failed to apply ${label} after ${tries} tries: ${out}"
      return 1
    fi
    sleep "$POLL"
  done
}

# Wait for the CSV behind a Subscription (by name+namespace) to reach Succeeded.
wait_sub_csv() {
  local ns="$1" sub="$2" deadline csv phase
  deadline=$(( $(date +%s) + ROLLBACK_TIMEOUT ))
  csv=""
  while :; do
    csv="$(kubectl get "$SUB_RES" "$sub" -n "$ns" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
    [ -n "$csv" ] && break
    [ "$(date +%s)" -ge "$deadline" ] && { warn "  ${sub}: no CSV resolved in time"; return 1; }
    log "  ${sub}: waiting for InstallPlan/CSV..."
    sleep "$POLL"
  done
  while :; do
    phase="$(kubectl get "$CSV_RES" "$csv" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [ "$phase" = "Succeeded" ] && { log "  ${csv}: Succeeded"; return 0; }
    [ "$(date +%s)" -ge "$deadline" ] && { warn "  ${csv}: phase ${phase:-unknown} (timed out)"; return 1; }
    log "  ${csv}: phase ${phase:-pending}..."
    sleep "$POLL"
  done
}

# Operators (registry entries) whose backup directory holds CRs.
operators_with_backup_crs() {
  local entry disp grp pkg dir comp files
  for entry in "${MEDIK8S_OPERATORS[@]}"; do
    IFS='|' read -r disp grp pkg dir comp <<<"$entry"
    files="$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
               /bin/sh -c "ls -1 '${MOUNT}/${dir}' 2>/dev/null" \
             | grep -v '^owner-references.json$' || true)"
    [ -n "$files" ] && printf '%s\n' "$entry"
  done
  return 0
}

# Operators to reinstall: those that were installed (captured Subscription) OR
# that have backed-up CRs.
operators_to_reinstall() {
  local entry disp grp pkg dir comp files has
  for entry in "${MEDIK8S_OPERATORS[@]}"; do
    IFS='|' read -r disp grp pkg dir comp <<<"$entry"
    has=0
    if kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
         test -f "${MOUNT}/operators/${pkg}.subscription.yaml" 2>/dev/null; then
      has=1
    else
      files="$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
                 /bin/sh -c "ls -1 '${MOUNT}/${dir}' 2>/dev/null" \
               | grep -v '^owner-references.json$' || true)"
      [ -n "$files" ] && has=1
    fi
    [ "$has" = "1" ] && printf '%s\n' "$entry"
  done
  return 0
}

# ---------------------------------------------------------------------------
# 1. Delete WAO
# ---------------------------------------------------------------------------
delete_wao() {
  log "STEP 1/3: removing WAO"

  # a. Delete component CR instances while WAO still runs (so finalizers clear).
  log "  deleting medik8s CR instances"
  local g crds crd scope items
  for g in remediation.medik8s.io self-node-remediation.medik8s.io \
           storage-based-remediation.medik8s.io fence-agents-remediation.medik8s.io \
           machine-deletion-remediation.medik8s.io nodemaintenance.medik8s.io; do
    crds="$(crds_in_group "$g")"
    for crd in $crds; do
      scope="$(crd_scope "$crd")"
      if [ "$scope" = "Namespaced" ]; then
        items="$(kubectl get "$crd" -A \
          -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
        printf '%s\n' "$items" | while IFS=' ' read -r ns name; do
          [ -z "${name:-}" ] && continue
          kubectl delete "$crd" "$name" -n "$ns" --wait=false --ignore-not-found >/dev/null 2>&1 || true
        done
      else
        kubectl delete "$crd" --all --wait=false --ignore-not-found >/dev/null 2>&1 || true
      fi
    done
  done

  local deadline remaining
  deadline=$(( $(date +%s) + ROLLBACK_TIMEOUT ))
  while :; do
    remaining="$(count_medik8s_crs)"
    [ "$remaining" -eq 0 ] && { log "  all medik8s CRs deleted"; break; }
    [ "$(date +%s)" -ge "$deadline" ] && { warn "  timeout: ${remaining} CR(s) still present"; break; }
    log "  waiting for ${remaining} CR(s) to delete..."
    sleep "$POLL"
  done

  # b. Delete the WorkloadAvailabilityConfig.
  if kubectl get "$WAO_CONFIG_CRD" "$WAO_CONFIG_NAME" >/dev/null 2>&1; then
    log "  deleting WorkloadAvailabilityConfig '${WAO_CONFIG_NAME}'"
    kubectl delete "$WAO_CONFIG_CRD" "$WAO_CONFIG_NAME" --ignore-not-found --timeout=120s \
      || warn "  WorkloadAvailabilityConfig deletion did not complete cleanly"
  fi

  # c. Delete the WAO Subscription + CSV.
  local wcsv
  wcsv="$(kubectl get "$SUB_RES" "$WAO_SUB_NAME" -n "$WAO_INSTALL_NS" \
            -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
  log "  deleting WAO Subscription '${WAO_SUB_NAME}'"
  kubectl delete "$SUB_RES" "$WAO_SUB_NAME" -n "$WAO_INSTALL_NS" --ignore-not-found >/dev/null 2>&1 || true
  if [ -n "$wcsv" ]; then
    log "  deleting WAO CSV '${wcsv}'"
    kubectl delete "$CSV_RES" "$wcsv" -n "$WAO_INSTALL_NS" --ignore-not-found >/dev/null 2>&1 || true
  fi

  # d. Delete the POC CatalogSource.
  log "  deleting CatalogSource '${CATALOG_NAME}'"
  kubectl delete catalogsource "$CATALOG_NAME" -n "$CATALOG_NS" --ignore-not-found >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# 2. Reinstall the original operators.
#
# Prefer the Subscription captured during delete (faithful: exact channel/source/
# namespace). If none was captured, reconstruct one from the cluster's package
# manifest for that package and install it into FALLBACK_SUB_NS.
# ---------------------------------------------------------------------------

# Echo a Subscription YAML for a package
subscription_manifest() {
  local pkg="$1" captured catalog catalogns channel
  captured="$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
               cat "${MOUNT}/operators/${pkg}.subscription.yaml" 2>/dev/null || true)"
  if [ -n "$captured" ]; then
    printf '%s\n' "$captured"
    return 0
  fi
  # Pick the first preferred catalog that actually publishes this package.
  local cat
  for cat in $FALLBACK_CATALOGS; do
    channel="$(kubectl get packagemanifests -n "$PM_NS" -l "catalog=${cat}" \
      -o jsonpath="{range .items[?(@.metadata.name=='${pkg}')]}{.status.defaultChannel}{end}" 2>/dev/null || true)"
    if [ -n "$channel" ]; then catalog="$cat"; break; fi
  done
  # Fall back to any catalog if none of the preferred ones has it.
  if [ -z "$catalog" ]; then
    catalog="$(kubectl get packagemanifest "$pkg" -n "$PM_NS" -o jsonpath='{.status.catalogSource}' 2>/dev/null || true)"
    channel="$(kubectl get packagemanifest "$pkg" -n "$PM_NS" -o jsonpath='{.status.defaultChannel}' 2>/dev/null || true)"
  fi
  if [ -z "$catalog" ] || [ -z "$channel" ]; then
    return 1
  fi
  cat <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${pkg}
  namespace: ${FALLBACK_SUB_NS}
spec:
  channel: ${channel}
  name: ${pkg}
  source: ${catalog}
  sourceNamespace: ${PM_NS}
  installPlanApproval: Automatic
EOF
}

reinstall_operators() {
  log "STEP 2/3: reinstalling original operators"
  local entry disp grp pkg dir comp manifest subname subns
  local ops; ops="$(operators_to_reinstall)"
  [ -z "$ops" ] && { warn "  nothing to reinstall (no captured Subscriptions or backed-up CRs)"; return 0; }

  # Apply each Subscription.
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    IFS='|' read -r disp grp pkg dir comp <<<"$entry"
    manifest="$(subscription_manifest "$pkg" || true)"
    if [ -z "$manifest" ]; then
      warn "  ${disp}: no captured Subscription and package '${pkg}' not found in any catalog; skipping"
      continue
    fi
    subname="$(printf '%s\n' "$manifest" | awk '/^  name:/{print $2; exit}')"
    subns="$(printf '%s\n' "$manifest" | awk '/^  namespace:/{print $2; exit}')"
    if kubectl exec -n "$NAMESPACE" "$POD_NAME" -- test -f "${MOUNT}/operators/${pkg}.subscription.yaml" 2>/dev/null; then
      log "  ${disp}: applying captured Subscription '${subname}' in '${subns}' (original catalog)"
    else
      local src; src="$(printf '%s\n' "$manifest" | awk '/^  source:/{print $2; exit}')"
      warn "  ${disp}: no captured Subscription — the original catalog is unknown;"
      warn "    GUESSING catalog '${src}' (preference: ${FALLBACK_CATALOGS})."
      warn "    If this operator was installed from a different catalog, edit"
      warn "    FALLBACK_CATALOGS in this script, or run the full flow so backup records it."
    fi
    printf '%s\n' "$manifest" | kubectl apply -f - >/dev/null
  done <<<"$ops"

  # Wait for each operator's CSV to succeed.
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    IFS='|' read -r disp grp pkg dir comp <<<"$entry"
    manifest="$(subscription_manifest "$pkg" || true)"
    [ -z "$manifest" ] && continue
    subname="$(printf '%s\n' "$manifest" | awk '/^  name:/{print $2; exit}')"
    subns="$(printf '%s\n' "$manifest" | awk '/^  namespace:/{print $2; exit}')"
    log "  ${disp}: waiting for operator to be ready"
    wait_sub_csv "$subns" "$subname" || warn "  ${disp}: operator not ready; CRs may fail to apply"
  done <<<"$ops"
}

# ---------------------------------------------------------------------------
# 3. Restore the backed-up CRs to their ORIGINAL namespaces (as captured).
# ---------------------------------------------------------------------------
restore_pass() {
  local mode="$1" entry disp grp pkg dir comp files f content kind
  for entry in "${MEDIK8S_OPERATORS[@]}"; do
    IFS='|' read -r disp grp pkg dir comp <<<"$entry"
    files="$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
               /bin/sh -c "ls -1 '${MOUNT}/${dir}' 2>/dev/null" \
             | grep -v '^owner-references.json$' || true)"
    [ -z "$files" ] && continue
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      content="$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- cat "${MOUNT}/${dir}/${f}")"
      kind="$(printf '%s\n' "$content" | awk '/^kind:/{print $2; exit}')"
      if is_transient_kind "$kind"; then
        [ "$mode" = "other" ] && log "  skip ${kind} (${dir}/${f}) — transient instance"
        continue
      fi
      if [ "$mode" = "nhc"   ] && [ "$kind" != "NodeHealthCheck" ]; then continue; fi
      if [ "$mode" = "other" ] && [ "$kind"  = "NodeHealthCheck" ]; then continue; fi
      log "  restoring ${kind} <- ${dir}/${f}  (original namespace)"
      apply_cr_retry "$content" "${kind}/${f}" || true
    done <<<"$files"
  done
}

restore_crs() {
  log "STEP 3/3: restoring backed-up CRs to their original namespaces"
  restore_pass other   # templates / configs first
  restore_pass nhc     # then NodeHealthCheck
}

summary() {
  echo
  echo "============================================================"
  echo " Rollback complete"
  echo "============================================================"
  echo "Workload-availability-operator uninstalled"
  echo "Reinstalled original operators from the backup:"
  local entry disp grp pkg dir comp
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    IFS='|' read -r disp grp pkg dir comp <<<"$entry"
    echo "  - ${disp}  (${pkg})"
  done <<<"$(operators_to_reinstall)"
  echo
  echo "Verify:"
  echo "  kubectl get csv -A | grep -Ei 'healthcheck|self-node'"
  echo "  kubectl get nodehealthcheck -A"
  echo "============================================================"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y)  ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "unknown argument: $1" ;;
    esac
    shift
  done

  preflight
  check_no_active_remediations
  confirm
  delete_wao
  reinstall_operators
  restore_crs
  summary
}

main "$@"
