# Medik8s CLI

## Status and intent

This is a design proposal only. It defines the future commands for moving
an existing Medik8s installation managed through individual OLM operators
to one Workload Availability Operator (WAO) installation.

> **Command names are provisional.** `wao-upgrade` and `wao-upgrade-step` are
> the current proposed public command names and may change before implementation.

## Confirmed upstream facts

The design below is grounded in the current upstream projects. Implementation
must still re-confirm names and versions against the published WAO release it
targets.

- **Source operators** Node Health Check (NHC), Self Node Remediation
  (SNR), Storage Based Remediation (SBR), Fence Agents Remediation (FAR),
  Machine Deletion Remediation (MDR), and Node Maintenance (NMO). Each is today
  an independent OLM package with its own `Subscription`, `ClusterServiceVersion`
  (CSV), and `OperatorGroup`.
- **Target operator** WAO consolidates the same six as managed *operands*
  under a single OLM package with one CSV that owns all component APIs and RBAC.
  It deploys to the `openshift-workload-availability` namespace.
- **WAO configuration API.** WAO exposes a single cluster-scoped
  `WorkloadAvailabilityConfig`.
  **Every component operand defaults to `enabled: false`** and must be turned on
  explicitly.
- **Shared CRDs.** WAO's bundle ships component CRDs (13 total: the primary API
  plus the upstream component CRDs). These overlap by name and API group with the
  CRDs the individual source operators install. Because the CRDs are the same,
  restore re-applies the source CR specs unchanged; there is no per-field spec
  translation (see "Configuration mapping").
- **WAO availability.** The CLI installs WAO from an existing OLM `CatalogSource`;
  it does not build or push images. The target WAO release must be published in a
  reachable catalog. (The POC builds WAO from source only because it is not yet
  catalog-published.)
- **Installed-operator set is authoritative.** Some source operators (notably FAR)
  have no persistent CRs — their remediation CR is transient. The set of installed
  source operators is therefore derived from OLM `Subscription`s, not from CR
  presence.

## User-facing commands

The CLI has two primary entry points. Both use the same persisted
upgrade record, known upgrade assumptions, safety checks, and rollback data; they
differ only in who advances the workflow.

```text
kubectl medik8s wao-upgrade [options]                 # complete upgrade
kubectl medik8s wao-upgrade-step <step> [options]     # one validated phase
```

`wao-upgrade` is the end-to-end command. It checks for active remediations,
then completes preflight validation and backs up the source CRs, deletes the
CRs and source operator operands, waits for those deletions, deletes the source
OLM operators, installs WAO, restores the configuration, and
verifies the result.

`wao-upgrade-step` is the controlled, phase-by-phase command. It is for operators
who need to inspect the cluster between destructive operations or coordinate
maintenance windows. It cannot skip phases or operate without an upgrade
record created by the `backup` step or a preceding step.

### Shared options

```text
--namespace NAME               WAO target namespace. defaults to openshift-workload-availability

status [options]
rollback [options]
```

The CLI uses the kubeconfig selected by the `KUBECONFIG` environment variable
and the active context in that kubeconfig.

## Primary commands

### `wao-upgrade`

Runs the complete upgrade lifecycle. It is the normal
path for a supported, uncomplicated installation.

```text
kubectl medik8s wao-upgrade [options]
```

The command advances through every phase in order and waits at each readiness
gate. It stops at the first active remediation, failure, or timeout, and reports
the exact next safe command (`status`, `wao-upgrade-step <phase>`, or
`rollback`). It never silently continues past a deletion or install failure.

### `wao-upgrade-step`

Executes exactly one named lifecycle phase against an existing upgrade
record. The supported steps mirror the end-to-end command:

```text
kubectl medik8s wao-upgrade-step backup
kubectl medik8s wao-upgrade-step delete
kubectl medik8s wao-upgrade-step install
kubectl medik8s wao-upgrade-step restore
kubectl medik8s wao-upgrade-step verify
```

Each subcommand performs one part of the upgrade:

- `backup` saves the source CRs and records the installed source operators'
  `Subscription`s (see "CR backup and operator record").
- `delete` deletes the backed-up source CRs and source operator operands, waits
  for those deletions, then removes the source OLM operators.
- `install` installs WAO and its selected operands.
- `restore` re-applies the backed-up CR specs under WAO (see "Configuration
  mapping").
- `verify` confirms WAO readiness: the WAO CSV is `Succeeded`, the
  `WorkloadAvailabilityConfig` carries the expected enabled set, each non-transient
  backed-up CR is present, and no source `Subscription`/CSV remains.

An active remediation blocks `wao-upgrade` and every `wao-upgrade-step`
subcommand. Before any upgrade command begins, the CLI checks for active
remediations and refuses to proceed if it finds one. The CLI does not create,
modify, or remove pause requests, and provides no override for this gate.

The gate fires on the mere existence of any instance of the remediation/
maintenance "request" kinds: `SelfNodeRemediation`, `FenceAgentsRemediation`,
`MachineDeletionRemediation`, `StorageBasedRemediation`, and `NodeMaintenance`.

## Supporting commands

### `wao-upgrade status`

Reports whether an upgrade is in progress and its phase, the selected WAO
installation, active remediations, readiness of the installed operator and
operands, and the newest backup. It makes no changes.

### Preflight validation

Before an upgrade begins, the CLI discovers the source OLM installations and
relevant Medik8s CRs and validates that they match the known upgrade path. It
must identify:

- OLM `Subscription`, `ClusterServiceVersion`, `OperatorGroup`, and catalog
  information.
- Configured CRs, their API versions, namespaces, references, and whether their
  schemas are supported by WAO.
- Active/in-flight remediations, which block upgrade execution.
- The target WAO namespace (`openshift-workload-availability` unless overridden),
  release, and the set of operands the upgrade workflow would set to
  `enabled: true` in the `WorkloadAvailabilityConfig`.
- Whether any source CRD overlaps by name and API group with a CRD WAO's bundle
  owns, and the ownership-transfer action that overlap requires.
- Blocking conditions, transformations requiring explicit user selection, and actions that are not reversible automatically.

## Upgrade status

The CLI keeps one authoritative upgrade record. It records the current phase,
backup reference and checksum, target namespace, and detected operator and WAO
versions so `status`, later upgrade steps, and `rollback` all use the same
state.

### `wao-upgrade rollback`

Restores the OLM configuration and original CR configuration from a named
backup, then removes the WAO installation only when it is safe to do so.

```text
--backup BACKUP                 Required backup ID
```

Rollback is phase-aware. Before WAO has reconciled the CRs restored from the
backup, it can normally restore the source configuration deterministically.
After WAO has reconciled those restored CRs or created remediation resources,
automatic rollback must stop.

## Shared upgrade lifecycle

```text
discover → no active remediations → preflight validated → CR backup created
        → source CRs and operands deleted → deletion confirmed
        → source OLM operators deleted → WAO installed
        → CRs determined → configuration verified
        → complete
```

Each transition is idempotent and stored in the upgrade record. The CLI may
retry an incomplete phase, but must never skip forward merely because a
resource exists.

### CRD ownership transition

The source operators and WAO both declare the same component CRDs. Under OLM, a
CRD is referenced by each operator's CSV, and deleting a CSV can, depending on
install mode and `ownerReferences`, cascade to resources it owns. The upgrade
must therefore treat CRD ownership as an explicit, reversible step.

- Before removing a source CSV, detach ownership links from the shared CRDs so
  CSV removal cannot cascade-delete the CRDs.
- Let WAO's CSV adopt the shared CRDs on install. The CLI must detect whether the
  WAO bundle's CRD versions are compatible with the existing stored CRs.

## Upgrade record and backup durability

- **Upgrade record.** The record lives in-cluster.
  The record stores the current phase, the backup location and reference, the
  effective context and namespaces, and detected operator/WAO versions.
- **CR backup and operator record.** The backup is stored in-cluster, holding each 
  source CR sanitized to a restore-ready form. Original CR `ownerReferences` 
  are recorded separately so the garbage collector cannot delete restored objects via a stale owner. 

## Configuration mapping

- **Enable flags.** The `WorkloadAvailabilityConfig` enables a component when its
  source operator was **installed**.
- **Namespace retargeting.** Component CRs are re-applied into the
  WAO namespace, and `NodeHealthCheck` remediation-template references are rewritten
  to match. Templates/configs are applied before `NodeHealthCheck` so references
  resolve. Rollback restores CRs to their original namespaces.
- **Transient instances skipped.** Remediation CRs found in a backup are not used.

## Safety invariants

- Do not create, modify, or remove pause requests.
- Use conflict detection and resource version checks before each
  write. Stop on unexpected drift.
- Make every mutation observable in the upgrade record and CLI output.
- Block every `wao-upgrade` and `wao-upgrade-step` operation while an active
  remediation exists.

## Open design decisions

- The precise schema of the `WorkloadAvailabilityConfig` operand settings, per
  targeted WAO release.
- **Backup identity.** Whether the CLI keeps a single refreshed backup (POC) or
  multiple retained, named backups. `rollback --backup <id>` assumes the latter.
- The supported rollback boundary after WAO begins reconciling, and the report
  format for resources that need manual operator review.
