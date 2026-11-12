#!/usr/bin/env bash
#
# upgrade.sh
#
# Orchestrator for the medik8s -> WAO migration POC. Runs the individual step
# scripts synchronously, in order, stopping at the first failure.
#
# Forward migration (default):
#   1. backup-medik8s-crs.sh      back up all medik8s CRs + record installed operators
#   2. delete-medik8s-operators.sh  delete the source operators (CRs -> operands -> OLM)
#   3. install-wao.sh             build/push/install WAO, configure + restore from backup
#
# Rollback (optional, run on its own):
#   --rollback-only
#
# All step scripts read the same configuration from common.sh, so environment
# overrides (e.g. WAO_BACKUP_NAMESPACE, CONTAINER_TOOL) set here are inherited by
# every step.
#
# Do NOT mix --rollback-only with the forward migration
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_LOG_PREFIX="upgrade"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"   # log/warn/die

ROLLBACK_ONLY=0
YES=0

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--yes] [--rollback-only]

  (default)         Run the forward migration in order:
                      backup -> delete -> install (WAO).
  --rollback-only   Run only the rollback (remove WAO, reinstall the original
                    operators + CRs from the backup). Does not run the forward steps.
  --yes             Non-interactive: pass --yes to the steps that prompt
                    (delete, rollback).

Environment overrides are read from common.sh and inherited by every step, e.g.:
  WAO_BACKUP_NAMESPACE   CONTAINER_TOOL
EOF
}

# Run a step script (absolute path), logging a banner around it. Aborts (set -e)
# if the step fails.
run_step() {
  local label="$1"; shift
  echo >&2
  log "============================================================"
  log "STEP: ${label}"
  log "============================================================"
  "$@"
  log "STEP OK: ${label}"
}

forward_migration() {
  local yesflag=""
  [ "$YES" = "1" ] && yesflag="--yes"

  run_step "1/3 backup CRs"        "${SCRIPT_DIR}/backup-medik8s-crs.sh"
  # shellcheck disable=SC2086
  run_step "2/3 delete operators"  "${SCRIPT_DIR}/delete-medik8s-operators.sh" $yesflag
  run_step "3/3 install WAO"       "${SCRIPT_DIR}/install-wao.sh"

  echo >&2
  log "migration complete: WAO installed and configured from the backup."
  log "to undo: $(basename "$0") --rollback-only"
}

rollback_only() {
  local yesflag=""
  [ "$YES" = "1" ] && yesflag="--yes"
  # shellcheck disable=SC2086
  run_step "rollback" "${SCRIPT_DIR}/rollback-to-medik8s.sh" $yesflag

  echo >&2
  log "rollback complete: WAO removed, original operators reinstalled from the backup."
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --rollback-only) ROLLBACK_ONLY=1 ;;
      --yes|-y)        YES=1 ;;
      -h|--help)       usage; exit 0 ;;
      *) usage; die "unknown argument: $1" ;;
    esac
    shift
  done

  # Sanity: all step scripts must be present and executable-readable.
  local s
  for s in backup-medik8s-crs.sh delete-medik8s-operators.sh install-wao.sh rollback-to-medik8s.sh; do
    [ -f "${SCRIPT_DIR}/${s}" ] || die "missing step script: ${SCRIPT_DIR}/${s}"
  done

  if [ "$ROLLBACK_ONLY" = "1" ]; then
    rollback_only
  else
    forward_migration
  fi
}

main "$@"
