#!/usr/bin/env bash
#
# install-wao.sh
#
# Proof-of-concept for the WAO upgrade "install WAO" step: build and push the
# Workload Availability Operator (WAO) image, bundle, and file-based catalog, then
# install WAO and configure it from the backup. WAO is a new operator that is not
# yet in the OpenShift operator catalogs, so we build it ourselves and serve it
# from a catalog image.
#
# What it does:
#   1. Clones the WAO source.
#   2. Builds and pushes images to ttl.sh using WAO's own Make targets:
#        - operator (manager) image   IMG
#        - bundle image               BUNDLE_IMG   (OLM bundle; references IMG)
#        - catalog image (FBC)        CATALOG_IMG  (references BUNDLE_IMG)
#   3. Generates dist/catalogsource.yaml (a CatalogSource pointing at CATALOG_IMG)
#      and copies the install manifests (Namespace/OperatorGroup/Subscription).
#   4. Applies the CatalogSource + Subscription, waits for the WAO CSV to succeed,
#      then:
#        a. creates the WorkloadAvailabilityConfig named 'cluster' with the
#           components ENABLED according to the backed-up CRs, and
#        b. REAPPLIES the backed-up component CR specs. WAO
#           ships the same component CRDs, and WorkloadAvailabilityConfig only
#           holds enable flags + manager resources, so the detailed specs live in
#           the component CRs (NodeHealthCheck, *Template, *Config). Transient
#           remediation/maintenance instances are skipped. CRs are
#           retargeted into the WAO namespace (openshift-workload-availability).
#
# Requirements: git, make, go, a container tool (podman or docker), kubectl, a
# reachable cluster, and the backup PVC/pod from backup-medik8s-crs.sh. WAO's
# Makefile downloads operator-sdk / opm / yq / etc. on demand.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
POC_LOG_PREFIX="wao-build"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"   # log/warn/die

WAO_REPO="https://github.com/medik8s/workload-availability-operator.git"
WAO_REF="main"                             # WAO git ref to build
WAO_SRC="${REPO_ROOT}/.wao-src"            # cloned here (reused if already present)
OUT_DIR="${REPO_ROOT}/.wao-build-out"

REGISTRY="ttl.sh"                          # ephemeral POC registry (image TAG = TTL)
IMAGE_PREFIX="wao-poc"                      # ttl.sh image name prefix (POC: fixed)
TTL="24h"
WAO_VERSION="0.1.0"                        # WAO bundle/CSV version
PLATFORM="linux/amd64"                      # POC target arch (must match the cluster)
CONTAINER_TOOL="${CONTAINER_TOOL:-}"       # auto-detected if empty

# Install/configure settings.
WAO_INSTALL_NS="${WAO_INSTALL_NAMESPACE:-openshift-workload-availability}"
WAO_CONFIG_NAME="${WAO_CONFIG_NAME:-cluster}"
WAO_CONFIG_API="workloadavailability.medik8s.io/v1alpha1"
WAO_CONFIG_CRD="workloadavailabilityconfigs.workloadavailability.medik8s.io"
INSTALL_TIMEOUT="600"                      # seconds to wait for the CSV
POLL="5"                                    # seconds between readiness polls

# Derived image references.
IMG="${REGISTRY}/${IMAGE_PREFIX}:${TTL}"
BUNDLE_IMG="${REGISTRY}/${IMAGE_PREFIX}-bundle:${TTL}"
CATALOG_IMG="${REGISTRY}/${IMAGE_PREFIX}-catalog:${TTL}"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0")

Builds and pushes the WAO operator/bundle/catalog images, installs WAO on the
cluster (CatalogSource + Subscription), then creates the WorkloadAvailabilityConfig
and restores the backed-up CR specs. Needs kubectl, a reachable cluster, and the
backup PVC/pod from backup-medik8s-crs.sh.

On success it removes the local build scratch (.wao-src/, .wao-build-out/); on
failure they are kept for inspection.

The POC builds WAO (main) for linux/amd64 and pushes to ttl.sh. Environment:
  CONTAINER_TOOL (podman|docker, auto)   WAO_BACKUP_NAMESPACE (default openshift-workload-availability)
EOF
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
detect_container_tool() {
  [ -n "$CONTAINER_TOOL" ] && return 0
  if command -v podman >/dev/null 2>&1; then CONTAINER_TOOL=podman
  elif command -v docker >/dev/null 2>&1; then CONTAINER_TOOL=docker
  else die "no container tool found (install podman or docker, or set CONTAINER_TOOL)"; fi
}

# Cluster access + backup pod are required for configure/restore. Fail fast.
check_cluster_prereqs() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found on PATH"
  kubectl version >/dev/null 2>&1 || die "cannot reach a cluster (check KUBECONFIG/context)"
  kubectl get pod "$POD_NAME" -n "$NAMESPACE" >/dev/null 2>&1 \
    || die "backup pod '${POD_NAME}' not found in '${NAMESPACE}'; run backup-medik8s-crs.sh first"
  log "cluster        : $(kubectl config current-context 2>/dev/null || echo '<unknown>')"
}

preflight() {
  for bin in git make go; do
    command -v "$bin" >/dev/null 2>&1 || die "$bin not found on PATH"
  done
  detect_container_tool
  command -v "$CONTAINER_TOOL" >/dev/null 2>&1 || die "container tool '$CONTAINER_TOOL' not found"

  if [ "$REGISTRY" = "ttl.sh" ]; then
    warn "ttl.sh is ephemeral: images expire after ${TTL}. POC/disposable clusters only."
  fi

  # Install + configure + restore always run, so require cluster access and the
  # backup now (fail fast, before the long build).
  check_cluster_prereqs
}

# ---------------------------------------------------------------------------
# Obtain WAO source
# ---------------------------------------------------------------------------
ensure_source() {
  if [ -d "${WAO_SRC}/.git" ]; then
    return 0
  fi
  if [ -e "$WAO_SRC" ] && [ ! -d "${WAO_SRC}/.git" ]; then
    die "${WAO_SRC} exists but is not a git checkout; remove it and re-run"
  fi
  git clone --depth 1 --branch "$WAO_REF" "$WAO_REPO" "$WAO_SRC"
}

# ---------------------------------------------------------------------------
# Build + push via WAO's Make targets
# ---------------------------------------------------------------------------
run_make() {
  log "make $*"
  make -C "$WAO_SRC" "$@" \
    IMG="$IMG" BUNDLE_IMG="$BUNDLE_IMG" CATALOG_IMG="$CATALOG_IMG" \
    VERSION="$WAO_VERSION" CONTAINER_TOOL="$CONTAINER_TOOL" PLATFORM="$PLATFORM"
}

build_and_push() {
  log "PHASE 1/3: operator image  (this may take a while)"
  run_make docker-build
  run_make docker-push

  log "PHASE 2/3: OLM bundle image"
  run_make bundle-build
  run_make bundle-push

  log "PHASE 3/3: file-based catalog image"
  build_catalog
  run_make catalog-push
}

# Normalize an arch string to amd64/arm64.
norm_arch() {
  case "$1" in
    arm64|aarch64) echo arm64 ;;
    x86_64|amd64)  echo amd64 ;;
    *)             echo "$1" ;;
  esac
}

# Build the catalog (FBC) image. WAO's `catalog-build` generates a Dockerfile that
# RUNs `opm serve --cache-only` at build time to pre-populate the cache. When the
# target platform differs from the host (e.g. linux/amd64 on an Apple-Silicon
# Mac), that RUN executes an emulated amd64 `opm` under qemu, which SIGSEGVs. In
# that case we build a cache-less FBC image instead (no build-time RUN); `opm
# serve` builds the cache at runtime on the cluster (native arch).
build_catalog() {
  local host target
  host="$(norm_arch "$(uname -m)")"
  target="$(norm_arch "${PLATFORM##*/}")"

  if [ "$host" = "$target" ]; then
    run_make catalog-build
    return 0
  fi

  warn "cross-arch build (host ${host} -> target ${target}); building a cache-less"
  warn "catalog image to avoid qemu emulating 'opm serve' (known SIGSEGV)."
  run_make catalog-fbc   # generates catalog/ (FBC) and a catalog.Dockerfile
  cat > "${WAO_SRC}/catalog.Dockerfile" <<'DOCKER'
# Cache-less FBC catalog (cross-arch safe). No build-time RUN (nothing emulated);
# opm builds its cache in memory at startup. Do NOT pass --cache-dir here: with an
# empty cache dir, opm serve does an integrity check and fatals.
FROM quay.io/operator-framework/opm:latest
ENTRYPOINT ["/bin/opm"]
CMD ["serve", "/configs"]
ADD catalog /configs
LABEL operators.operatorframework.io.index.configs.v1=/configs
DOCKER
  ( cd "$WAO_SRC" && "$CONTAINER_TOOL" build --platform "$PLATFORM" \
      -f catalog.Dockerfile -t "$CATALOG_IMG" . )
}

# ---------------------------------------------------------------------------
# Generate install manifests
# ---------------------------------------------------------------------------
generate_manifests() {
  log "generating CatalogSource"
  run_make catalog-source

  mkdir -p "$OUT_DIR"
  cp "${WAO_SRC}/dist/catalogsource.yaml" "${OUT_DIR}/catalogsource.yaml"
  # Static install manifests (Namespace + OperatorGroup + Subscription); the
  # Subscription's source already matches the CatalogSource name (wao-poc-catalog).
  cp "${WAO_SRC}/config/catalog/subscription.yaml" "${OUT_DIR}/subscription.yaml"

  log "wrote ${OUT_DIR}/catalogsource.yaml and ${OUT_DIR}/subscription.yaml"
}

# ---------------------------------------------------------------------------
# Install WAO: CatalogSource -> Subscription -> wait for the CSV to succeed.
# ---------------------------------------------------------------------------
install_wao() {
  log "INSTALL 1/3: applying CatalogSource"
  kubectl apply -f "${OUT_DIR}/catalogsource.yaml"
  log "  waiting for CatalogSource 'wao-poc-catalog' to connect (up to 180s)"
  kubectl wait --for=jsonpath='{.status.connectionState.lastObservedState}'=READY \
    catalogsource/wao-poc-catalog -n openshift-marketplace --timeout=180s \
    || warn "  CatalogSource not READY yet; the Subscription may take longer to resolve"

  log "INSTALL 2/3: applying Namespace + OperatorGroup + Subscription"
  kubectl apply -f "${OUT_DIR}/subscription.yaml"

  log "INSTALL 3/3: waiting for the WAO ClusterServiceVersion to succeed (up to ${INSTALL_TIMEOUT}s)"
  local deadline csv phase
  deadline=$(( $(date +%s) + INSTALL_TIMEOUT ))
  csv=""
  while :; do
    csv="$(kubectl get subscription workload-availability-operator -n "$WAO_INSTALL_NS" \
             -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
    [ -n "$csv" ] && break
    [ "$(date +%s)" -ge "$deadline" ] && die "timed out waiting for the Subscription to resolve a CSV"
    log "  waiting for the Subscription to resolve an InstallPlan/CSV..."
    sleep "$POLL"
  done
  log "  installing CSV '${csv}'"
  while :; do
    phase="$(kubectl get csv "$csv" -n "$WAO_INSTALL_NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [ "$phase" = "Succeeded" ] && { log "  CSV '${csv}' Succeeded"; break; }
    [ "$(date +%s)" -ge "$deadline" ] && die "timed out waiting for CSV '${csv}' (phase: ${phase:-unknown})"
    log "  CSV phase: ${phase:-pending}..."
    sleep "$POLL"
  done

  log "  waiting for the WorkloadAvailabilityConfig CRD to be established"
  kubectl wait --for=condition=Established "crd/${WAO_CONFIG_CRD}" --timeout=120s \
    || die "WorkloadAvailabilityConfig CRD not established"
}

# ---------------------------------------------------------------------------
# Decide which WAO components to enable from the backup.
# ---------------------------------------------------------------------------
enabled_components_from_backup() {
  kubectl get pod "$POD_NAME" -n "$NAMESPACE" >/dev/null 2>&1 \
    || die "backup pod '${POD_NAME}' not found in '${NAMESPACE}'; run backup-medik8s-crs.sh first"

  local entry disp grp pkg dir comp files
  for entry in "${MEDIK8S_OPERATORS[@]}"; do
    IFS='|' read -r disp grp pkg dir comp <<<"$entry"
    # Installed if a Subscription was captured for this package.
    if kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
         test -f "${MOUNT}/operators/${pkg}.subscription.yaml" 2>/dev/null; then
      printf '%s\n' "$comp"
      continue
    fi
    # Otherwise, installed if it had backed-up CRs.
    files="$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
               /bin/sh -c "ls -1 '${MOUNT}/${dir}' 2>/dev/null" \
             | grep -v '^owner-references.json$' || true)"
    [ -n "$files" ] && printf '%s\n' "$comp"
  done
  return 0   # never let the final empty-dir test set a non-zero exit (set -e)
}

# ---------------------------------------------------------------------------
# Configure WAO: build and apply the WorkloadAvailabilityConfig named 'cluster',
# enabling the components derived from the backup.
# ---------------------------------------------------------------------------
configure_wao() {
  log "CONFIGURE: deriving enabled components from the backup"
  local enabled
  enabled="$(enabled_components_from_backup)"

  # Build the components block for all six, enabled true only if in $enabled.
  local entry disp grp pkg dir comp components="" state
  for entry in "${MEDIK8S_OPERATORS[@]}"; do
    IFS='|' read -r disp grp pkg dir comp <<<"$entry"
    if printf '%s\n' "$enabled" | grep -qx "$comp"; then
      state=true
      log "  enable  ${comp}  (${disp}: installed in backup)"
    else
      state=false
      log "  disable ${comp}  (${disp}: not installed in backup)"
    fi
    components="${components}    ${comp}:
      enabled: ${state}
"
  done
  components="${components%$'\n'}"   # drop trailing newline

  log "applying WorkloadAvailabilityConfig '${WAO_CONFIG_NAME}'"
  kubectl apply -f - <<EOF
apiVersion: ${WAO_CONFIG_API}
kind: WorkloadAvailabilityConfig
metadata:
  name: ${WAO_CONFIG_NAME}
spec:
  components:
${components}
EOF
}

# ---------------------------------------------------------------------------
# Reapply the backed-up component CR specs under WAO.
# ---------------------------------------------------------------------------
is_transient_kind() {
  local k="$1" e kind grp
  for e in "${MEDIK8S_REMEDIATIONS[@]}"; do
    IFS='|' read -r kind grp <<<"$e"
    [ "$k" = "$kind" ] && return 0
  done
  return 1
}

# Apply a CR (on stdin via $1). $3, if non-empty, is the target namespace passed
# as `-n`. Retries to ride out operand webhooks that are not ready yet.
apply_cr_retry() {
  local content="$1" label="$2" ns="${3:-}" tries=0 max="${WAO_RESTORE_RETRIES:-36}" out rc
  while :; do
    if [ -n "$ns" ]; then
      out="$(printf '%s\n' "$content" | kubectl apply -n "$ns" -f - 2>&1)"; rc=$?
    else
      out="$(printf '%s\n' "$content" | kubectl apply -f - 2>&1)"; rc=$?
    fi
    if [ "$rc" -eq 0 ]; then log "    applied ${label}"; return 0; fi
    tries=$((tries + 1))
    if [ "$tries" -ge "$max" ]; then
      warn "    failed to apply ${label} after ${tries} tries: ${out}"
      return 1
    fi
    sleep "$POLL"   # e.g. operand webhook not ready yet
  done
}

# Reapplied CRs are retargeted into the WAO namespace (WAO_INSTALL_NS):
#   - namespaced CRs: metadata.namespace is dropped and applied with -n WAO_INSTALL_NS.
#   - NodeHealthCheck (cluster-scoped): its remediationTemplate namespace references
#     are rewritten to WAO_INSTALL_NS so they resolve to the restored templates.
restore_pass() {
  local mode="$1" entry disp grp pkg dir comp files f content kind payload
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
        [ "$mode" = "other" ] && log "  skip ${kind} (${dir}/${f}) — transient remediation/maintenance instance"
        continue
      fi
      if [ "$mode" = "nhc"   ] && [ "$kind" != "NodeHealthCheck" ]; then continue; fi
      if [ "$mode" = "other" ] && [ "$kind"  = "NodeHealthCheck" ]; then continue; fi
      log "  restoring ${kind} <- ${dir}/${f}  (namespace -> ${WAO_INSTALL_NS})"
      if [ "$kind" = "NodeHealthCheck" ]; then
        # Cluster-scoped: no metadata.namespace. Point template refs at WAO ns.
        payload="$(printf '%s\n' "$content" \
          | sed -E "s/^([[:space:]]{4,})namespace:[[:space:]].*/\1namespace: ${WAO_INSTALL_NS}/")"
        apply_cr_retry "$payload" "${kind}/${f}" "" || true
      else
        # Namespaced: drop metadata.namespace and apply into the WAO namespace.
        payload="$(printf '%s\n' "$content" | sed -E '/^  namespace:[[:space:]]/d')"
        apply_cr_retry "$payload" "${kind}/${f}" "$WAO_INSTALL_NS" || true
      fi
    done <<<"$files"
  done
}

restore_crs() {
  log "Re-applying backed-up component CRs under WAO"
  restore_pass other   # templates / configs first
  restore_pass nhc     # then NodeHealthCheck (references the templates)
}

summary() {
  echo
  echo "============================================================"
  echo " WAO catalog built and pushed"
  echo "============================================================"
  echo "Operator image : ${IMG}"
  echo "Bundle image   : ${BUNDLE_IMG}"
  echo "Catalog image  : ${CATALOG_IMG}"
  echo
  echo "WAO installed in '${WAO_INSTALL_NS}'"
  echo "  kubectl get workloadavailabilityconfig ${WAO_CONFIG_NAME} -o yaml"
  echo
  echo "Components were enabled from the backed-up CRs"
  echo "CR specs were re-applied under WAO"
  echo "============================================================"
}

# ---------------------------------------------------------------------------
# Remove the local build scratch
# ---------------------------------------------------------------------------
cleanup_build_artifacts() {
  local d
  for d in "$WAO_SRC" "$OUT_DIR"; do
    [ -e "$d" ] || continue
    chmod -R u+w "$d" 2>/dev/null || true
    if rm -rf "$d" 2>/dev/null; then
    else
      warn "  could not fully remove ${d}; delete it manually if needed"
    fi
  done
  return 0   # never fail the run over cleanup
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
  ensure_source
  build_and_push
  generate_manifests
  install_wao
  configure_wao
  restore_crs
  summary
  cleanup_build_artifacts
}

main "$@"
