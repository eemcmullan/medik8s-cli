#!/usr/bin/env bash
#
# backup-medik8s-crs.sh
#
# Proof-of-concept for the WAO upgrade "backup existing CRs" step.
#
# What it does:
#   1. Finds the cluster via the active kubeconfig/context.
#   2. Runs `oc adm must-gather --image=quay.io/medik8s/must-gather` to pull a full
#      diagnostic bundle.
#   3. Creates a backup writer pod.
#   4. Derives the IN-CLUSTER, restore-ready backup from the local bundle: for every
#      medik8s CR found in the bundle it writes one sanitized YAML into the matching
#      per-operator directory on the PVC. Because ownerReferences are stripped,
#      each CR's original owner(s) are recorded in a per-directory
#      owner-references.json sidecar.
#   5. Records which operators are installed (OLM Subscriptions).
#
# Each run refreshes the backup: the previous per-operator directories are cleared
# and rewritten from a fresh must-gather, and a sentinel file records when the
# latest backup completed.
#
# Requirements: oc (for must-gather), kubectl, bash, awk, tar, and a reachable
# OpenShift cluster with a default StorageClass.
#
set -euo pipefail

# Shared config, registry, and helpers (operator list, logging, CRD helpers,
# active-remediation gate, backup configuration variables, must-gather image).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_LOG_PREFIX="backup"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Backup-specific configuration
# ---------------------------------------------------------------------------
# Local directory for the must-gather diagnostic bundle. Override with the
# WAO_MUST_GATHER_DIR
MG_LOCAL_DIR="${WAO_MUST_GATHER_DIR:-${PWD}/must-gather-$(date -u +%Y%m%d-%H%M%S)}"
MG_PROVENANCE="${IMAGE}"
# Local scratch where the restore-ready tree is assembled before being pushed to
# the PVC. Kept separate from the (untrusted) must-gather bundle.
STAGING_DIR=""

cleanup() { [ -n "$STAGING_DIR" ] && rm -rf "$STAGING_DIR" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Backup-specific helpers
# ---------------------------------------------------------------------------
kexec()   { kubectl exec -n "$NAMESPACE" "$POD_NAME" -- "$@"; }
kexec_i() { kubectl exec -i -n "$NAMESPACE" "$POD_NAME" -- "$@"; }

# ---------------------------------------------------------------------------
# Preflight: locate the cluster and verify connectivity + tooling
# ---------------------------------------------------------------------------
preflight() {
  command -v oc >/dev/null 2>&1 \
    || die "oc not found on PATH (required for 'oc adm must-gather')"
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found on PATH"
  command -v awk >/dev/null 2>&1 || die "awk not found on PATH"
  command -v tar >/dev/null 2>&1 || die "tar not found on PATH"

  local kubeconfig
  kubeconfig="${KUBECONFIG:-$HOME/.kube/config}"
  kubectl version >/dev/null 2>&1 \
    || die "cannot reach a cluster (KUBECONFIG=${kubeconfig}). Is your context set?"

  log "kubeconfig        : ${kubeconfig}"
  log "context           : $(kubectl config current-context 2>/dev/null || echo '<unknown>')"
  log "must-gather image : ${IMAGE}"
}

# ---------------------------------------------------------------------------
# Run must-gather to pull the diagnostic bundle locally.
# ---------------------------------------------------------------------------
run_must_gather() {
  mkdir -p "$MG_LOCAL_DIR"
  log "running must-gather into '${MG_LOCAL_DIR}' (this can take a few minutes)"
  oc adm must-gather --image="$IMAGE" --dest-dir="$MG_LOCAL_DIR" \
    || die "'oc adm must-gather' failed (is this an OpenShift cluster reachable by oc?)"

  # Sanity: the bundle should contain oc-adm-inspect output.
  if ! find "$MG_LOCAL_DIR" -type d \( -name cluster-scoped-resources -o -name namespaces \) \
       | grep -q .; then
    die "must-gather produced no inspect output under '${MG_LOCAL_DIR}'"
  fi

  local content_dir digest
  content_dir="$(find "$MG_LOCAL_DIR" -type d -name '*sha256-*' | head -n1)"
  if [ -n "$content_dir" ]; then
    digest="sha256:$(basename "$content_dir" | sed -n 's/.*sha256-//p')"
    MG_PROVENANCE="${IMAGE}@${digest}"
  else
    MG_PROVENANCE="${IMAGE}"
  fi

  log "must-gather bundle collected (${MG_PROVENANCE})"
}

# ---------------------------------------------------------------------------
# Ensure the backup scaffolding exists (namespace, PVC, writer pod).
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

  # The writer pod: must-gather image, PVC mounted at $MOUNT. The entrypoint
  # (/usr/bin/gather) is overridden with sleep; the pod is used as a storage
  # sidecar that already carries oc + tar for receiving the backup tree.
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
# Sanitize a single CR's YAML into a restore-ready form: drop server-populated
# and runtime fields that are not needed to recreate the object, while keeping
# apiVersion, kind, metadata.name/namespace/labels/annotations, and spec.
#
# Section-aware: only strips these keys inside the metadata block, so identically
# named keys under spec are preserved. Reads YAML on stdin.
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

# Extract a CR file's ownerReferences as lines: kind|name|uid|apiVersion|controller
# Parses the metadata.ownerReferences block straight out of the must-gather YAML
# (so the live cluster is never re-queried; must-gather is the sole source).
extract_owner_refs_file() {
  awk '
    function ind(s){ match(s,/^ */); return RLENGTH }
    function flush(){ if(have) printf "%s|%s|%s|%s|%s\n",k,n,u,a,c; k="";n="";u="";a="";c="false";have=0 }
    function setkv(s,   p,key,val){
      p=index(s,":"); if(p==0) return
      key=substr(s,1,p-1); val=substr(s,p+1)
      gsub(/^[ \t]+|[ \t]+$/,"",key); gsub(/^[ \t]+|[ \t]+$/,"",val)
      sub(/^"/,"",val); sub(/"$/,"",val)
      if(key=="kind")k=val; else if(key=="name")n=val; else if(key=="uid")u=val;
      else if(key=="apiVersion")a=val; else if(key=="controller")c=val
    }
    BEGIN{ inmeta=0; inown=0; have=0; k="";n="";u="";a="";c="false" }
    {
      i=ind($0)
      if(i==0 && $0 ~ /^[A-Za-z][A-Za-z0-9]*:/){ if(inown)flush(); inown=0; sec=$0; sub(/:.*/,"",sec); inmeta=(sec=="metadata"?1:0); next }
      if(!inmeta) next
      if(i==2 && $0 ~ /^  ownerReferences:[ \t]*$/){ if(inown)flush(); inown=1; next }
      if(!inown) next
      if(i==2 && $0 ~ /^  -[ \t]/){ flush(); have=1; rest=$0; sub(/^  -[ \t]+/,"",rest); setkv(rest); next }
      if(i>=4){ setkv($0); next }
      flush(); inown=0
    }
    END{ if(inown)flush() }
  ' "$1"
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

# Read a single field (first match) from a CR YAML file.
yaml_top_field() { awk -v k="$1" '$0 ~ ("^" k ":"){sub(/^[^:]*:[ \t]*/,""); print; exit}' "$2"; }
yaml_meta_field() { awk -v k="$1" '$0 ~ ("^  " k ":"){sub(/^[^:]*:[ \t]*/,""); print; exit}' "$2"; }

# ---------------------------------------------------------------------------
# Derive the restore-ready backup from the must-gather bundle into STAGING_DIR.
# ---------------------------------------------------------------------------
DERIVED_TOTAL=0
derive_backup() {
  STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/medik8s-backup.XXXXXX")"
  log "deriving restore-ready backup from the must-gather bundle"
  local total=0 entry dir display group

  for entry in "${OPERATORS[@]}"; do
    IFS='|' read -r dir display group <<<"$entry"
    mkdir -p "${STAGING_DIR}/${dir}"
    log "operator: ${display} -> ${dir}/  (group ${group})"

    local files
    files="$(find "$MG_LOCAL_DIR" -type f \( -name '*.yaml' -o -name '*.yml' \) \
               -path "*/${group}/*" 2>/dev/null || true)"
    if [ -z "$files" ]; then
      log "  no CRs for this group in the bundle"
      continue
    fi

    local dir_owner_json="" f
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      local kind ns name plural file owner_lines cr_json
      kind="$(yaml_top_field kind "$f")"
      # Defensive: the group dirs only hold CRs, but never treat a CRD as a CR.
      [ -z "$kind" ] && continue
      [ "$kind" = "CustomResourceDefinition" ] && continue

      ns="$(yaml_meta_field namespace "$f")"
      plural="$(basename "$(dirname "$f")")"
      name="$(basename "${f%.yaml}")"; name="${name%.yml}"

      if [ -n "$ns" ]; then
        file="${plural}_${ns}_${name}.yaml"
      else
        file="${plural}_${name}.yaml"
      fi
      sanitize_cr < "$f" > "${STAGING_DIR}/${dir}/${file}"
      total=$((total + 1))
      log "  saved ${kind} ${ns:+${ns}/}${name} -> ${dir}/${file}"

      # Record original ownerReferences (stripped from the sanitized YAML).
      owner_lines="$(extract_owner_refs_file "$f")"
      if [ -n "$owner_lines" ]; then
        cr_json="$(printf '%s\n' "$owner_lines" | cr_owner_json "$kind" "${ns:--}" "$name" || true)"
        if [ -n "$cr_json" ]; then
          if [ -z "$dir_owner_json" ]; then
            dir_owner_json="$cr_json"
          else
            dir_owner_json="${dir_owner_json},${cr_json}"
          fi
        fi
      fi
    done <<<"$files"

    # Write the per-operator ownerReferences sidecar, if any CR had owners.
    if [ -n "$dir_owner_json" ]; then
      printf '[%s]\n' "$dir_owner_json" > "${STAGING_DIR}/${dir}/owner-references.json"
      log "  wrote ${dir}/owner-references.json"
    fi
  done

  DERIVED_TOTAL="$total"
}

# ---------------------------------------------------------------------------
# Push the staged restore-ready tree onto the PVC via the writer pod, replacing
# any previous backup. The must-gather-based pod already has tar for extraction.
# ---------------------------------------------------------------------------
push_to_pvc() {
  log "pushing restore-ready backup into PVC '${PVC_NAME}' at '${MOUNT}' (refreshing any previous backup)"
  # Start clean so stale files (CRs that no longer exist) are not left behind.
  kexec /bin/sh -c "rm -rf ${MOUNT}/*-backup ${MOUNT}/operators '${SENTINEL}'" || true
  tar -C "$STAGING_DIR" -cf - . | kexec_i tar -C "$MOUNT" -xf -
}

# ---------------------------------------------------------------------------
# Perform the backup end to end.
# ---------------------------------------------------------------------------
do_backup() {
  derive_backup
  push_to_pvc

  # Record which operators were INSTALLED (OLM Subscriptions). This is the
  # authoritative set for rollback.
  capture_installed_operators

  # Mark the backup complete. Record the collector provenance (image@digest) and the
  # local bundle path so a backup is traceable to the exact must-gather that produced it.
  printf 'backup-complete %s context=%s collector=%s bundle=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(kubectl config current-context 2>/dev/null || echo unknown)" \
    "$MG_PROVENANCE" \
    "$MG_LOCAL_DIR" \
    | kexec_i /bin/sh -c "cat > '${SENTINEL}'"

  log "backup complete: ${DERIVED_TOTAL} CR(s) written to the PVC"
  log "local must-gather bundle kept at: ${MG_LOCAL_DIR}"
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
# Report: read the backup back FROM the PVC and print it to this terminal.
# ---------------------------------------------------------------------------
report() {
  echo
  echo "============================================================"
  echo " Medik8s CR backup report"
  echo "============================================================"
  echo "PVC name          : ${PVC_NAME}"
  echo "Namespace         : ${NAMESPACE}"
  echo "Mount path        : ${MOUNT}"
  echo "must-gather image : ${IMAGE}"
  echo "Collector         : ${MG_PROVENANCE}"
  echo "Local bundle      : ${MG_LOCAL_DIR}"
  local completed
  completed="$(kexec cat "$SENTINEL" 2>/dev/null || echo 'unknown')"
  echo "Completed         : ${completed}"
  echo

  local grand=0 entry
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
    local f
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

Runs medik8s must-gather, then backs up all medik8s CRs to an in-cluster PVC and
prints a report. Each run refreshes the backup.

Environment:
  WAO_MUST_GATHER_DIR     local bundle directory (default ./must-gather-<timestamp>)
  WAO_BACKUP_NAMESPACE    backup PVC/pod namespace (default openshift-workload-availability)
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

  # Backup is read-only (must-gather + a storage sidecar), so unlike the
  # destructive steps it does NOT gate on active remediations
  preflight
  run_must_gather
  ensure_scaffolding
  do_backup
  report
}

main "$@"
