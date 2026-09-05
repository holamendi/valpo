# Valpo Release And Host Lifecycle

Valpo can build deterministic native amd64/arm64 archives, but artifact activation, transactional upgrades, first-class backup/restore, and unattended updates are not implemented. The source installer remains a development path because it replaces `/opt/valpo` in place and cannot atomically restore code and database state after a failed transition.

## Artifact Contract

Release archives are named `valpo-VERSION-linux-ARCH.tar.zst` and rooted at `/opt/valpo/releases/VERSION/`. They contain the application, migrations, metadata, templates, Ruby, production dependencies, `pack`, and release-local entrypoints. Mise and compiler tooling are build-time dependencies and are not packaged.

An artifact assumes its final versioned path but does not activate itself, install services, or modify the current source installer. A production installer must verify its checksum and attestations before staging it.

## Host Contract

Valpo targets a fresh, dedicated Ubuntu host. It may require exclusive ownership of documented systemd services, files, generated Caddy configuration, Docker resources, ports, and policy drop-ins, but must not replace unrelated operator configuration.

Production preflight should reject conflicts. SSH hardening must also verify a non-root key-authenticated operator and a provider-console recovery path before disabling password or root authentication.

## Compatibility And Identity

Each release carries `release.json` with its code version, API compatibility version, supported and target database schemas, configuration schema, and host-profile version. Separate root-owned installation metadata records the selected channel, verified artifact digest, and installation time.

The current release boots only when the database matches its target schema. A future updater will use the supported schema range during preflight and migrate before activation.

`001_bootstrap.rb` is permanent; every schema change adds one contiguous migration. Migrations are self-contained and use expand/contract changes where practical. Database down-migrations are not the primary rollback mechanism.

SQLite check constraints enforce the finite service, release, dependency, domain, platform-domain, and job states even for direct dataset writes. Partial unique indexes permit at most one active release per service and one active platform domain. Application transition methods reject forbidden lifecycle edges before writing; compare-and-set job transitions remain atomic. Upgrade preflight reports unknown states for explicit operator repair and deterministically retires duplicate active rows before installing these constraints.

## Upgrade Transaction

Production installation will use immutable version directories and an atomic `current` symlink. An update will:

1. Acquire a root-owned lock, verify the candidate, and refuse active work.
2. Stop the API and worker while applications continue running.
3. Checkpoint SQLite, the keyring, and configuration together.
4. Migrate with the candidate and atomically switch the active release.
5. Restart, verify, reconcile runtime state, and record the result.

A pre-activation failure restores the checkpoint and prior release. Later code-only rollback is safe only when the prior release supports the current schema; restoring an older database after new mutations is a separate, potentially destructive recovery operation.

## Recovery

Valpo distinguishes three artifacts:

1. A short-lived local checkpoint for immediate upgrade rollback.
2. An encrypted off-host backup for rebuilding a server.
3. A portable project export for moving selected projects.

SQLite and the encryption keyring form one recovery set. Postgres and Redis also require service-aware, consistent backups into fresh volumes. Recovery is supported only after automated clean-host restore tests verify application state.

Ubuntu security packages remain managed by APT. Valpo may coordinate reboots around active work and backup freshness, but LTS-to-LTS upgrades require a separate tested procedure; the preferred path is a fresh host and verified restore.
