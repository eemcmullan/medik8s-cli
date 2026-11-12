# medik8s-cli PoC

## Why

Today, workload-availability features on a cluster are provided by **six separate
OLM operators**, each with its own `Subscription`, `ClusterServiceVersion`, and
CRDs:

| Operator                           | API group                                |
| ---------------------------------- | ---------------------------------------- |
| Node Health Check (NHC)            | `remediation.medik8s.io`                 |
| Self Node Remediation (SNR)        | `self-node-remediation.medik8s.io`       |
| Storage Based Remediation (SBR)    | `storage-based-remediation.medik8s.io`   |
| Fence Agents Remediation (FAR)     | `fence-agents-remediation.medik8s.io`    |
| Machine Deletion Remediation (MDR) | `machine-deletion-remediation.medik8s.io`|
| Node Maintenance (NMO)             | `nodemaintenance.medik8s.io`             |

**WAO** consolidates these into a single operator that manages them as
operands under one `WorkloadAvailabilityConfig`. Manually updating to WAO means
carefully backing up and translating custom resources, removing the old operators
in the right order, installing WAO, and restoring configuration — without
disrupting any in-flight remediation.

The goal of `medik8s-cli` is to make that update **safe, repeatable, and
observable.**

## The CLI (WIP)

## Proof-of-concept - upgrade

The scripts in [`scripts/poc/`](scripts/poc/) implement the full migration against a
live cluster. They are **only POCs for disposable / non-production clusters.**

### Prerequisites

- `kubectl` and a reachable **OLM-enabled** cluster (e.g. OpenShift) with the
  medik8s operators installed.
- For the WAO build/install step: `git`, `make`, `go`, and a container tool
  (`podman` or `docker`).

### Run the whole flow

[`upgrade.sh`](scripts/poc/upgrade.sh) orchestrates the steps in order, stopping at
the first failure:

```sh
# Forward migration: backup -> delete source operators -> build & install WAO
./scripts/poc/upgrade.sh

# Non-interactive (skips confirmation prompts)
./scripts/poc/upgrade.sh --yes

# Undo: remove WAO, reinstall the original operators from backup
./scripts/poc/upgrade.sh --rollback-only
```

### What each step does

| Step | Script | Summary |
| ---- | ------ | ------- |
| 1. Backup | [`backup-medik8s-crs.sh`](scripts/poc/backup-medik8s-crs.sh) | Backs up every medik8s CR to an in-cluster PVC (sanitized to restore-ready form), records original `ownerReferences`, and records which operators are installed. |
| 2. Delete | [`delete-medik8s-operators.sh`](scripts/poc/delete-medik8s-operators.sh) | Deletes the operators safely — CRs → operands → OLM `Subscription`/`CSV` — waiting between each. |
| 3. Install | [`install-wao.sh`](scripts/poc/install-wao.sh) | Builds/pushes the WAO bundle, and catalog, installs WAO, enables the components that had backed-up CRs. |
| Rollback | [`rollback-to-medik8s.sh`](scripts/poc/rollback-to-medik8s.sh) | Removes WAO and reinstalls the original operators (with their CRs) from the backup. |

Every destructive step **refuses to run while a remediation or node maintenance is
in progress**.


```sh
# Where the backup PVC/pod live (defaults to openshift-workload-availability)
WAO_BACKUP_NAMESPACE=<backup-ns>

# Container tool for the WAO build (auto-detected otherwise)
CONTAINER_TOOL=podman
```

## CLI interface (not implemented)

Once implemented, the same workflow will be exposed as a `kubectl` plugin invoked
as `kubectl medik8s`:

```sh
kubectl medik8s wao-upgrade [--namespace openshift-workload-availability]
kubectl medik8s wao-upgrade-step <backup|delete|install|restore|verify>
kubectl medik8s wao-upgrade status
kubectl medik8s wao-upgrade rollback --backup <id>
```

See [`docs/design.md`](docs/design.md) for the full design.
