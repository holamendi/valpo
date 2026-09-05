# Valpo Release And Host Lifecycle

Valpo builds native amd64/arm64 archives and supports transactional upgrades of an existing Ubuntu 26.04 installation. First-class off-host backup/restore, fresh-host artifact installation, and unattended updates remain future work. The source installer is a development bootstrap and refuses to overwrite an activated packaged installation.

## Artifact Contract

Release archives are named `valpo-VERSION-linux-ARCH.tar.zst` and rooted at `/opt/valpo/releases/VERSION/`. They contain the application, migrations, metadata, templates, Ruby, production dependencies, `pack`, and release-local entrypoints. Mise and compiler tooling are build-time dependencies and are not packaged.

An artifact assumes its final versioned path but does not activate itself, install services, or modify the current source installer. The host updater verifies checksums before extraction; preview/stable channels additionally require tagged release-workflow attestations. Development artifacts are locally built and checksum-verified, without claiming GitHub provenance.

`sudo valpo-upgrade` discovers the highest eligible newer immutable GitHub
Release, downloads the native archive, and reuses the verified transaction below.
An explicit `vVERSION` remains optional; `--channel preview` includes prereleases.
`apply ARCHIVE --sha256 DIGEST --channel CHANNEL` and `recover` remain available
for local artifacts and interrupted transactions. Tagged builds publish durable
assets only after native smoke tests, SBOM/provenance generation, and installation
acceptance succeed. See [operator commands and authentication](../packaging/README.md#host-upgrades).

## Host Contract

Valpo targets a fresh, dedicated Ubuntu host. It may require exclusive ownership of documented systemd services, files, generated Caddy configuration, Docker resources, ports, and policy drop-ins, but must not replace unrelated operator configuration.

Production preflight should reject conflicts. SSH hardening must also verify a non-root key-authenticated operator and a provider-console recovery path before disabling password or root authentication.

## Compatibility And Identity

Each release carries `release.json` with its code version, API compatibility version, supported and target database schemas, configuration schema, and host-profile version. Separate root-owned installation metadata records the selected channel, verified artifact digest, and installation time.

The current release boots only when the database matches its target schema. The host updater checks the supported schema range during preflight and migrates before activation.

`001_bootstrap.rb` is permanent; every schema change adds one contiguous migration. Migrations are self-contained and use expand/contract changes where practical. Database down-migrations are not the primary rollback mechanism.

SQLite check constraints enforce the finite service, release, dependency, domain, platform-domain, and job states even for direct dataset writes. Partial unique indexes permit at most one active release per service and one active platform domain. Application transition methods reject forbidden lifecycle edges before writing; compare-and-set job transitions remain atomic. The lifecycle-invariants migration reports unknown states for explicit operator repair and deterministically retires duplicate active rows before installing these constraints.

## Upgrade Transaction

The host updater uses immutable version directories and an atomic `current` symlink:

1. Acquire a root-owned lock and verify the candidate checksum and, for preview/stable channels, its tagged release-workflow attestation.
2. Stage the native artifact and validate configuration, schema compatibility, and host layout.
3. Close the API and maintenance scheduler; reject queued/running jobs before stopping the idle worker. App containers and Caddy keep running.
4. Checkpoint SQLite using its backup API, with the keyring, configuration, units, and installation metadata. Persist a recovery journal before mutation.
5. Migrate with the candidate and check authenticated API readiness in an isolated network namespace. Construct worker handlers without consuming jobs.
6. Install release-based units, atomically switch `current`, durably mark activation committed, then reopen the API and worker.

A pre-activation failure restores the checkpoint and prior release. A systemd guard prevents starting against an interrupted migration after a crash or reboot; `sudo valpo-upgrade recover` restores the old state before reopening. After commitment, recovery only restarts the new release, preserving subsequent writes. Late rollback and schema downgrades are not provided.

See [host upgrade commands](../packaging/README.md#host-upgrades). Upgrade checkpoints are retained under `/var/lib/valpo-updater/checkpoints`; they are root-only and contain encryption keys. They are not automatically pruned and do not back up managed service volumes. Normal application reconciliation remains an explicit operator action; the readiness probe does not change running applications.

## Recovery

Valpo distinguishes three artifacts:

1. An implemented local checkpoint for immediate upgrade rollback, retained until explicitly removed.
2. A planned encrypted off-host backup for rebuilding a server.
3. A planned portable project export for moving selected projects.

SQLite and the encryption keyring form one recovery set. Postgres and Redis also require service-aware, consistent backups into fresh volumes. Off-host disaster recovery must not be claimed as supported until automated clean-host restore tests verify application state. Local interrupted-upgrade recovery is already implemented and tested.

Ubuntu security packages remain managed by APT. Valpo may coordinate reboots around active work and backup freshness, but LTS-to-LTS upgrades require a separate tested procedure; the preferred path is a fresh host and verified restore.
