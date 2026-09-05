# Valpo Roadmap

Valpo develops outward from a reliable single-server core. Production-safe installation and recovery take priority over additional product surface.

## Implemented Foundation

The current pre-release provides:

- a Roda API, SQLite-backed jobs, a worker, and a resource-first CLI;
- registry and GitHub deployments using Dockerfiles or Cloud Native Buildpacks;
- web and worker services, health checks, releases, rollback, logs, and HTTPS routing;
- project-scoped Postgres and Redis services with encrypted credentials and explicit bindings;
- a validated `valpo.toml` manifest with dry-run, add/update reconciliation;
- scoped API credentials, encrypted service/provider secrets, key verification and rotation;
- storage maintenance, runtime repair, and repeatable VPS smoke tests;
- frozen incremental migrations, release compatibility metadata, and verified native amd64/arm64 artifacts;
- immutable release activation with a serialized upgrade transaction, local checkpoints, and interrupted-upgrade recovery.

## 1. Production Installation And Recovery

The current source installer is for development. Before expanding the product, Valpo needs:

- durable GitHub Releases and updates by verified tag ([#31](https://github.com/holamendi/valpo/issues/31));
- fresh-host installation directly from verified artifacts;
- off-host control-plane backup and clean-host restore for SQLite, the keyring, configuration, and release metadata; local upgrade checkpoints already exist;
- service-aware Postgres and Redis backup and restore tested on a clean host;
- separate API and Docker-capable worker privileges;
- dedicated-host preflight, guarded SSH/firewall hardening, security-update policy, and reboot coordination;
- preview and stable channels that promote the same verified artifact.

CI now gates injected migration/readiness failure recovery and artifact activation with existing app data. Crash-and-reboot upgrade recovery has also been verified on a disposable VM. Automated clean-host restore from an off-host backup remains required before production support. See the [release lifecycle](./valpo-release-lifecycle.md).

## 2. Additional Source Providers

Add GitLab after the GitHub path is stable. Provider support must preserve the same source, build, release, webhook, and failure behavior instead of introducing provider-specific deployment models.

Build secrets, Railpack, static-output detection, and image rebase remain outside the current build scope. Build targets already support custom builders and ordered buildpacks.

## 3. Static Sites

Add zip upload, safe extraction into immutable releases, Caddy file serving, custom domains, and rollback. Static hosting should not require a container.

## 4. Project Portability

Extend the existing manifest into export/import bundles containing the required database dumps, volume snapshots, static releases, credentials, and optional images. Import must support dry-run and report missing target capabilities before mutation.

Credential migration behavior must be defined before encrypted resources can be exported safely. Additional managed databases should wait until their lifecycle, backup, restore, and export behavior is tested.

## 5. Multi-Server Dashboard

Build a dashboard for registering and operating independent Valpo servers through their APIs. It may cache state, but each server remains authoritative and applications continue running without the dashboard.

Initial dashboard scope is server health, projects, deployments, jobs and logs, domains, static uploads, export/import, and API credential management.

## 6. Later Polish

Candidates include scheduled jobs, preview deployments, object-storage backups, deploy status checks, role-based access control, audit logs, templates, notifications, and stable extension APIs.

Public extension contracts should be extracted only after at least two real implementations need them. Extensions must keep resources, state transitions, jobs, failures, and secret access visible through Valpo's model.

## Deferred

Valpo does not plan early support for multi-node orchestration, automatic horizontal scaling, Kubernetes compatibility, cluster state, a plugin marketplace, a general CI system, or feature parity with broad self-hosted PaaS products.
