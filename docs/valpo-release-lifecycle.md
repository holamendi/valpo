# Valpo Release And Host Lifecycle

## Current Status

Valpo now has a frozen bootstrap migration, contiguous incremental-migration policy, explicit configuration schema, machine-readable `release.json`, and a separate installation-metadata contract. The API and CLI report release and schema identity. CI can build and smoke-test deterministic native amd64/arm64 archives rooted at the future immutable release path, with pinned Ruby and `pack`, production gems, SPDX SBOMs, checksums, build provenance, and SBOM attestations. Activation of those artifacts, transactional control-plane updates, first-class backup/restore, host hardening, GitHub Release publication, and unattended Valpo updates remain to be implemented.

The existing source installer remains a development path. It must not be presented as a production updater because it replaces `/opt/valpo` in place and cannot atomically restore code and database state after a failed transition.

## Artifact Boundary

The release payload is `valpo-VERSION-linux-ARCH.tar.zst`, rooted at
`opt/valpo/releases/VERSION/`. It carries the application, migrations, metadata,
templates, Ruby 4.0.5, production dependencies, `pack`, and release-local
entrypoints. Mise participates only in the pinned build and is removed from the
payload. Normalized archive metadata and single-threaded `zstd -10` make a build
reproducible for the same inputs and `SOURCE_DATE_EPOCH`.

The artifact assumes its final `/opt/valpo/releases/VERSION` location. It does
not activate itself, install services, write installation metadata, modify the
source installer, or define upgrade and rollback behavior. A future installer
must verify the published checksum and attestations before staging this payload.

## Dedicated-Host Contract

Valpo supports one fresh, dedicated Ubuntu host at a time. Dedicated means Valpo may require and validate exclusive ownership of its documented control-plane files, systemd services, generated Caddy block, Docker network, labeled Docker resources, port ranges, and host-policy drop-ins. It does not mean Valpo may silently replace unrelated operator configuration.

A production installer should refuse conflicting listeners, Docker workloads, filesystem layouts, or policy files unless a future explicitly unsupported override is selected. SSH changes require a verified non-root key-authenticated operator and a recoverable provider-console path before password or root authentication is disabled.

## Release Identity

Every code release carries an immutable `release.json` with:

- semantic code version;
- API compatibility version;
- minimum, target, and maximum database schema;
- configuration schema;
- host-profile version.

Root-owned installation metadata separately records the installed version, selected channel, verified archive digest, and installation time. The archive cannot contain its own digest, and channel is host policy rather than artifact identity. Keeping them separate allows promotion from preview to stable to reuse the exact verified artifact.

The current process may boot only when the database is at the release's target schema. A future updater uses the supported schema range during preflight and migrates to the target before making the candidate release active.

Supported channels are `development`, `preview`, and `stable`. Development describes a source checkout without installation metadata. Preview and stable require a verified artifact digest and installation time; promoting a release must reuse the exact artifact rather than rebuild it.

## Schema And Configuration Compatibility

`001_bootstrap.rb` is frozen permanently. Each schema change adds one contiguous integer migration. Migrations must be self-contained and must not depend on current application models.

Production migrations follow expand/contract behavior where practical. A release first adds compatible storage, later code switches reads and writes, and a subsequent release removes retired storage. Database down-migrations are not the primary rollback mechanism.

Operator YAML carries `config_schema`. An absent value currently means schema `1` for compatibility with existing development installations. Future incompatible configuration changes require an explicit validator/migrator and must not rewrite operator files without showing the resulting plan.

## Planned Upgrade Transaction

The production layout will use immutable version directories and an atomic `current` symlink. An update will acquire a root-owned lock, verify and stage the candidate, refuse active work, stop only the API and worker, checkpoint SQLite/keyring/configuration together, migrate with the candidate, switch the symlink, restart and verify the control plane, reconcile projected state, and record the result.

Applications and managed-service containers continue running while the control plane is stopped. A failure before the new API accepts work restores the checkpoint and prior release automatically. Later rollback is code-only when the previous release supports the current schema; restoring an older database after new mutations requires an explicit maintenance recovery because it can discard control-plane changes.

## Recovery Classes

Valpo distinguishes:

1. A short-lived local upgrade checkpoint for immediate transition rollback.
2. An encrypted off-host disaster-recovery backup for rebuilding a lost server.
3. A portable project export for moving selected projects between servers.

The SQLite database and encryption keyring are one recovery set. Managed Postgres and Redis require service-aware consistent backups and restores into fresh volumes. A backup is not considered supported until automated tests restore it on a clean compatible host and verify application state.

## Operating-System Lifecycle

Ubuntu security updates remain owned by APT and `unattended-upgrades`; Valpo will manage only named drop-ins and status. Automatic package installation and host reboot are separate operations. A future reboot coordinator will observe the maintenance window, active Valpo jobs and updates, backup freshness, bounded deferral, and post-boot reconciliation.

Ubuntu LTS-to-LTS transitions are not unattended Valpo updates. The intended recovery-first path is a fresh supported host followed by a verified restore; any in-place release upgrade requires its own tested operator procedure.
