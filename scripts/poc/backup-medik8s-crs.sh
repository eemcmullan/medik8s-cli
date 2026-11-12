#!/usr/bin/env bash
#
# backup-existing-crs.sh
#
# Proof-of-concept for the WAO upgrade "backup existing CRs" step.
#
# What it does:
#   1. Finds the cluster via the active kubeconfig (KUBECONFIG or ~/.kube/config)
#      and the current context.
#   2. Creates a backup namespace, a PVC, and a ubi-minimal pod that mounts it.
#   3. Creates one directory per source operator on the PVC
#      (nhc-backup, snr-backup, sbr-backup, far-backup, mdr-backup, nmo-backup).
#   4. Discovers each operator's CRDs and writes every existing CR, as its own
#      YAML file, into the matching directory on the PVC. Each CR is sanitized
#      into a restore-ready form first (status and server-populated metadata are
#      stripped; see sanitize_cr). Because ownerReferences are stripped, each
#      CR's original owner(s) are recorded in a per-directory owner-references.json
#      sidecar so the information is not lost.
#
# Each run refreshes the backup: the previous per-operator directories are
# cleared and rewritten from the current cluster state, and a sentinel file
# records when the latest backup completed (shown in the report).
#
# Requirements: kubectl, bash, awk, and a reachable cluster with a default
# StorageClass.
#
set -euo pipefail

# Shared config, registry, and helpers (operator list, logging, CRD helpers,
# active-remediation gate, backup configuration variables).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_LOG_PREFIX="backup"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Backup-specific helpers
# ---------------------------------------------------------------------------
kexec()   { kubectl exec -n "$NAMESPACE" "$POD_NAME" -- "$@"; }
kexec_i() { kubectl exec -i -n "$NAMESPACE" "$POD_NAME" -- "$@"; }

# ---------------------------------------------------------------------------
# Preflight: locate the cluster and verify connectivity
# ---------------------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found on PATH"
  command -v awk >/dev/null 2>&1 || die "awk not found on PATH"

  local kubeconfig context server
  kubeconfig="${KUBECONFIG:-$HOME/.kube/config}"
  kubectl version >/dev/null 2>&1 \
    || die "cannot reach a cluster (KUBECONFIG=${kubeconfig}). Is your context set?"

  context="$(kubectl config current-context 2>/dev/null || echo '<unknown>')"
  server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo '<unknown>')"

  log "kubeconfig : ${kubeconfig}"
}

# ---------------------------------------------------------------------------
# Ensure the backup scaffolding exists (namespace, PVC, dummy pod)
# ---------------------------------------------------------------------------
ensure_scaffolding() {
  log "ensuring namespace '${NAMESPACE}'"
  kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
    || kubectl create namespace "$NAMESPACE" >/dev/null

  log "ensuring PVC '${PVC_NAME}' (${STORAGE_SIZE})"
  if ! kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    {
      cat <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: kubectl-medik8s
    wao.medik8s.io/purpose: cr-backup
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${STORAGE_SIZE}
EOF
      if [ -n "$STORAGE_CLASS" ]; then
        printf '  storageClassName: %s\n' "$STORAGE_CLASS"
      fi
    } | kubectl apply -f - >/dev/null
  fi

  # The "dummy" pod: ubi9/ubi-minimal, PVC mounted at $MOUNT. It is just a
  # storage sidecar (shell + coreutils); collection happens on the host.
  if ! kubectl get pod "$POD_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: kubectl-medik8s
    wao.medik8s.io/purpose: cr-backup
spec:
  restartPolicy: Always
  containers:
    - name: writer
      image: ${IMAGE}
      command: ["sleep", "infinity"]
      volumeMounts:
        - name: backup
          mountPath: ${MOUNT}
  volumes:
    - name: backup
      persistentVolumeClaim:
        claimName: ${PVC_NAME}
EOF
  fi

  log "waiting for pod '${POD_NAME}' to be Ready (timeout ${WAIT_TIMEOUT})"
  kubectl wait --for=condition=Ready "pod/${POD_NAME}" -n "$NAMESPACE" \
    --timeout="$WAIT_TIMEOUT" >/dev/null \
    || die "pod '${POD_NAME}' did not become Ready; check image pull / PVC binding"
}

# ---------------------------------------------------------------------------
# List CRs of a resource as "<namespace> <name>" lines ("-" ns = cluster-scoped)
# ---------------------------------------------------------------------------
list_items() {
  local res="$1" scope="$2"
  if [ "$scope" = "Namespaced" ]; then
    kubectl get "$res" -A \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
  else
    kubectl get "$res" \
      -o jsonpath='{range .items[*]}{"-"}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Sanitize a single CR's YAML into a restore-ready form: drop server-populated
# and runtime fields that are not needed to recreate the object, while keeping
# apiVersion, kind, metadata.name/namespace/labels/annotations, and spec.
#
# Section-aware: only strips these keys inside the metadata block, so identically
# named keys under spec are preserved.
# ---------------------------------------------------------------------------
sanitize_cr() {
  awk '
    function indent(s){ match(s, /^ */); return RLENGTH }
    BEGIN { skip=0; skipind=-1; section="" }
    {
      ind = indent($0)
      if (skip) {
        # Still inside the dropped block: deeper lines, or same-indent sequence
        # items (kubectl renders a "- item" at the same indent as its key).
        if (ind > skipind) next
        if (ind == skipind && $0 ~ /^ *-/) next
        skip=0
      }

      # Track the current top-level (indent 0) section.
      if (ind == 0 && $0 ~ /^[A-Za-z]/) { key=$0; sub(/:.*/, "", key); section=key }

      # Drop the whole status block.
      if (ind == 0 && $0 ~ /^status:/) { skip=1; skipind=0; next }

      # Drop server-side metadata fields (only within the metadata block).
      if (section == "metadata" && ind == 2 && \
          $0 ~ /^  (creationTimestamp|generation|resourceVersion|uid|selfLink|managedFields|ownerReferences|finalizers):/) {
        skip=1; skipind=2; next
      }

      # Drop the last-applied-configuration annotation (within metadata).
      if (section == "metadata" && $0 ~ /^    kubectl\.kubernetes\.io\/last-applied-configuration:/) {
        skip=1; skipind=4; next
      }

      print
    }'
}

# ---------------------------------------------------------------------------
# OwnerReferences sidecar helpers.
#
# ownerReferences are stripped from the restore-ready YAML (a stale owner uid
# would make the garbage collector delete a restored object). To avoid losing
# the information, the original owner(s) of each CR are recorded in a per-directory
# owner-references.json sidecar.
# ---------------------------------------------------------------------------

# Minimal JSON string escaping (backslash and double-quote).
json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Emit a CR's ownerReferences as lines: kind|name|uid|apiVersion|controller
get_owner_refs() {
  local crd="$1" name="$2" ns="$3"
  local jp='{range .metadata.ownerReferences[*]}{.kind}{"|"}{.name}{"|"}{.uid}{"|"}{.apiVersion}{"|"}{.controller}{"\n"}{end}'
  if [ "$ns" = "-" ] || [ -z "$ns" ]; then
    kubectl get "$crd" "$name" -o jsonpath="$jp" 2>/dev/null || true
  else
    kubectl get "$crd" "$name" -n "$ns" -o jsonpath="$jp" 2>/dev/null || true
  fi
}

# Build one JSON object {kind,namespace,name,owners:[...]} for a CR.
# Reads owner lines (kind|name|uid|apiVersion|controller) on stdin.
# Returns 1 (prints nothing) when the CR has no ownerReferences.
cr_owner_json() {
  local kind="$1" ns="$2" name="$3"
  local oKind oName oUid oApi oCtl owners="" first=1 obj nsjson
  while IFS='|' read -r oKind oName oUid oApi oCtl; do
    [ -z "${oKind}${oName}" ] && continue
    [ -z "$oCtl" ] && oCtl=false
    obj="{\"kind\":\"$(json_str "$oKind")\",\"name\":\"$(json_str "$oName")\",\"uid\":\"$(json_str "$oUid")\",\"apiVersion\":\"$(json_str "$oApi")\",\"controller\":${oCtl}}"
    if [ "$first" = "1" ]; then owners="$obj"; first=0; else owners="${owners},${obj}"; fi
  done
  [ -z "$owners" ] && return 1
  nsjson="null"
  if [ "$ns" != "-" ] && [ -n "$ns" ]; then nsjson="\"$(json_str "$ns")\""; fi
  printf '{"kind":"%s","namespace":%s,"name":"%s","owners":[%s]}' \
    "$(json_str "$kind")" "$nsjson" "$(json_str "$name")" "$owners"
}

# ---------------------------------------------------------------------------
# Perform the backup. Collection runs on the host; CR YAML is streamed into the
# pod and written onto the PVC.
# ---------------------------------------------------------------------------
do_backup() {
  log "backing up into PVC '${PVC_NAME}' at '${MOUNT}' (refreshing any previous backup)"
  # Start clean so stale files (CRs that no longer exist) are not left behind.
  kexec /bin/sh -c "rm -rf ${MOUNT}/*-backup ${MOUNT}/operators '${SENTINEL}'" || true
  local total=0

  for entry in "${OPERATORS[@]}"; do
    IFS='|' read -r dir display group <<<"$entry"
    kexec mkdir -p "${MOUNT}/${dir}"
    log "operator: ${display} -> ${dir}/  (group ${group})"

    local dir_owner_json=""
    local crds
    crds="$(crds_in_group "$group")"
    if [ -z "$crds" ]; then
      log "  no CRDs installed for this group"
      continue
    fi

    local crd
    for crd in $crds; do
      local plural scope items
      plural="${crd%%.*}"
      scope="$(crd_scope "$crd")"
      items="$(list_items "$crd" "$scope")"
      [ -z "$items" ] && { log "  ${crd}: none"; continue; }

      while IFS=' ' read -r ns name; do
        [ -z "${name:-}" ] && continue
        local file obj
        if [ "$ns" = "-" ] || [ -z "$ns" ]; then
          file="${plural}_${name}.yaml"
          obj="$(kubectl get "$crd" "$name" -o yaml | sanitize_cr)"
        else
          file="${plural}_${ns}_${name}.yaml"
          obj="$(kubectl get "$crd" "$name" -n "$ns" -o yaml | sanitize_cr)"
        fi
        printf '%s\n' "$obj" | kexec_i /bin/sh -c "cat > '${MOUNT}/${dir}/${file}'"
        total=$((total + 1))
        log "  saved ${crd} ${ns:+${ns}/}${name} -> ${dir}/${file}"

        # Record original ownerReferences (stripped from the sanitized YAML).
        local owner_lines cr_json kind_name
        owner_lines="$(get_owner_refs "$crd" "$name" "$ns")"
        if [ -n "$owner_lines" ]; then
          kind_name="$(printf '%s\n' "$obj" | awk '/^kind:/{print $2; exit}')"
          cr_json="$(printf '%s\n' "$owner_lines" | cr_owner_json "$kind_name" "$ns" "$name" || true)"
          if [ -n "$cr_json" ]; then
            if [ -z "$dir_owner_json" ]; then
              dir_owner_json="$cr_json"
            else
              dir_owner_json="${dir_owner_json},${cr_json}"
            fi
          fi
        fi
      done <<<"$items"
    done

    # Write the per-operator ownerReferences sidecar, if any CR had owners.
    if [ -n "$dir_owner_json" ]; then
      printf '[%s]\n' "$dir_owner_json" \
        | kexec_i /bin/sh -c "cat > '${MOUNT}/${dir}/owner-references.json'"
      log "  wrote ${dir}/owner-references.json"
    fi
  done

  # Record which operators were INSTALLED (OLM Subscriptions). This is the
  # authoritative set for rollback: operators like FAR may have no persistent CRs
  # (their remediation CR is transient), so CR presence alone would miss them.
  capture_installed_operators

  # Mark the backup complete.
  printf 'backup-complete %s context=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(kubectl config current-context 2>/dev/null || echo unknown)" \
    | kexec_i /bin/sh -c "cat > '${SENTINEL}'"

  log "backup complete: ${total} CR(s) written to the PVC"
}

# ---------------------------------------------------------------------------
# Capture installed medik8s operator Subscriptions to the PVC (for rollback).
# ---------------------------------------------------------------------------
capture_installed_operators() {
  log "recording installed medik8s operators (OLM Subscriptions)"
  local pkg ns sub n=0
  while IFS='|' read -r pkg ns sub; do
    [ -z "${pkg:-}" ] && continue
    save_subscription_to_backup "$pkg" "$ns" "$sub"
    log "  recorded ${pkg} (${sub} in ${ns}) -> operators/${pkg}.subscription.yaml"
    n=$((n + 1))
  done <<<"$(installed_medik8s_subscriptions)"
  [ "$n" -eq 0 ] && log "  no installed medik8s operator Subscriptions found"
  return 0
}

# ---------------------------------------------------------------------------
# Parse the metadata block of a single-object CR YAML into one pipe-row:
#   kind|namespace|name|apiVersion|uid|resourceVersion|creationTimestamp
# ---------------------------------------------------------------------------
parse_meta() {
  awk '
    /^apiVersion:/           && av=="" { av=$2 }
    /^kind:/                 && kd=="" { kd=$2 }
    /^  name:/               && nm=="" { nm=$2 }
    /^  namespace:/          && ns=="" { ns=$2 }
    /^  uid:/                && ui=="" { ui=$2 }
    /^  resourceVersion:/    && rv=="" { rv=$2 }
    /^  creationTimestamp:/  && ct=="" { ct=$2 }
    END {
      printf "%s|%s|%s|%s|%s|%s|%s\n",
        (kd?kd:"?"), (ns?ns:"-"), (nm?nm:"?"),
        (av?av:"?"), (ui?ui:"-"), (rv?rv:"-"), (ct?ct:"-")
    }'
}

# ---------------------------------------------------------------------------
# Report: read the backup back FROM the PVC and
# print it to this terminal.
# ---------------------------------------------------------------------------
report() {
  echo
  echo "============================================================"
  echo " Medik8s CR backup report"
  echo "============================================================"
  echo "PVC name   : ${PVC_NAME}"
  echo "Namespace  : ${NAMESPACE}"
  echo "Mount path : ${MOUNT}"
  local completed
  completed="$(kexec cat "$SENTINEL" 2>/dev/null || echo 'unknown')"
  echo "Completed  : ${completed}"
  echo

  local grand=0
  for entry in "${OPERATORS[@]}"; do
    IFS='|' read -r dir display _ <<<"$entry"

    local files
    # List backed-up CRs only (exclude the ownerReferences sidecar).
    files="$(kexec /bin/sh -c "ls -1 '${MOUNT}/${dir}' 2>/dev/null" \
             | grep -v '^owner-references.json$' || true)"
    # Skip operators with no backed-up CRs entirely.
    [ -z "$files" ] && continue

    echo "------------------------------------------------------------"
    echo "Directory: ${dir}   (${display})"
    echo "------------------------------------------------------------"
    printf '  %-26s %-22s %-34s %s\n' "KIND" "NAMESPACE" "NAME" "APIVERSION"
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      local meta kind ns name av uid rv ct
      # Read the backed-up (sanitized) YAML back from the PVC and parse it locally.
      meta="$(kexec cat "${MOUNT}/${dir}/${f}" | parse_meta)"
      IFS='|' read -r kind ns name av uid rv ct <<<"$meta"
      printf '  %-26s %-22s %-34s %s\n' "$kind" "$ns" "$name" "$av"
      grand=$((grand + 1))
    done <<<"$files"
    if kexec test -f "${MOUNT}/${dir}/owner-references.json" 2>/dev/null; then
      echo "  (original ownerReferences recorded in owner-references.json)"
    fi
    echo
  done
}

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0")

Backs up all medik8s CRs to an in-cluster PVC and prints a report.
Each run refreshes the backup: the previous per-operator directories are
replaced with the current cluster state.
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      *) usage; die "unknown argument: $1" ;;
    esac
    shift
  done

  preflight
  ensure_scaffolding
  do_backup
  report
}

main "$@"
