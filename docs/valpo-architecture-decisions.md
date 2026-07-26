# Valpo Architecture Decisions

This document captures early decisions. They are intentionally lightweight and can evolve as implementation reveals better constraints.

## ADR 001: Each Server Is Self-Sufficient

Status: Accepted and implemented.

Decision:

Each Valpo server owns its local runtime state, metadata, resources, releases, jobs, and operational history.

Rationale:

Valpo is aimed at projects that can run on one vertically scaled VPS. A server should continue running and remain manageable even if the dashboard is unavailable.

Implications:

- Store server metadata locally.
- Keep the dashboard optional for runtime survival.
- Avoid central scheduler assumptions.
- Avoid default server-to-server communication.

## ADR 002: Dashboard Is An Operator, Not The Brain

Status: Proposed; dashboard implementation is deferred.

Decision:

The dashboard manages multiple independent servers by calling each server's API. It does not become the global source of truth for running apps.

Rationale:

This preserves the simple mental model and makes failure modes easier to understand.

Implications:

- Dashboard can cache state, but must be able to refresh from servers.
- Server APIs need complete project management capabilities.
- Server-side CLI should remain possible.

## ADR 003: Use Ruby, Roda, Sequel, And SQLite For The Host Agent

Status: Accepted and implemented.

Decision:

Use Ruby for the host API and worker. Use Roda for the API, Sequel for database access, and SQLite for local metadata.

Rationale:

The host control plane is orchestration-heavy rather than throughput-heavy. Ruby keeps implementation approachable, Roda keeps the host API small, and SQLite fits the single-server source-of-truth model.

Implications:

- Avoid a separate database dependency for Valpo itself.
- Keep the host agent easy to inspect and back up.
- Use migrations for all local schema changes.

## ADR 004: Use SQLite-Backed Jobs For V1

Status: Accepted and implemented for current operations.

Decision:

Use a custom SQLite-backed job table and worker process for long-running operations.

Rationale:

Deployments, builds, backups, restores, and imports must not run inside request handlers. A local job table is enough for a single-server system and avoids introducing Redis or a message broker.

Implications:

- API enqueues jobs.
- Worker locks and executes jobs.
- Job events are persisted.
- Concurrency starts low and can be expanded later.

## ADR 005: Normalize Deployment Inputs Into Releases

Status: Accepted for registry and GitHub deployments; other inputs remain proposed.

Decision:

Every implemented deployment input produces a release. Docker registry images and GitHub repositories are implemented; any later provider or static-upload path must reuse the release lifecycle rather than create a parallel deployment model.

Rationale:

A single release lifecycle makes deploys, rollbacks, logs, and migrations easier to reason about.

Implications:

- Source adapters should be separate from deploy activation.
- Rollback should activate a previous release artifact.
- Git providers should not create a separate deploy architecture.

## ADR 006: Docker Images Are The Runtime Artifact For Dynamic Apps

Status: Accepted and implemented for registry, Dockerfile, and buildpack deployments.

Decision:

Dynamic web apps should run as Docker containers. GitHub/GitLab builds should produce Docker images. Registry deploys should pull Docker images.

Rationale:

Docker is the common denominator for running arbitrary web apps on a VPS.

Implications:

- Store image references and digests in release records.
- Prefer image digest for reproducibility.
- Support explicit Dockerfile builds and Cloud Native Buildpacks builds.
- Default source builds to Dockerfile when one exists in the selected context, then buildpacks.
- Keep the platform builder pinned and record resolved build metadata on each release.

## ADR 007: Static Sites Are Served Directly By Caddy

Status: Proposed; static sites and uploads are not implemented.

Decision:

Static zip uploads should extract into immutable release directories and be served by Caddy's static file server.

Rationale:

Running a static site inside a container adds unnecessary overhead and obscures a simple hosting path.

Implications:

- Static projects have release directories rather than app containers.
- Caddy routing handles static file serving.
- Static rollback changes the active release route.

## ADR 008: Use Caddy As The Default Proxy

Status: Accepted and implemented for dynamic web applications and integration routes.

Decision:

Use Caddy for HTTP routing and automatic HTTPS. If static sites are implemented later, evaluate Caddy's file server in that feature rather than treating it as current behavior.

Rationale:

Caddy matches Valpo's preference for sensible defaults, low operational overhead, and straightforward HTTPS.

Implications:

- Valpo stores routing intent and applies generated Caddy config.
- Dynamic apps route to container ports.
- Static file routing remains a proposal owned by ADR 007.

## ADR 009: API Should Be Private By Default

Status: Accepted; private binding and a host-wide bearer token are implemented, while scoped credentials remain deferred.

Decision:

The host control API should default to a private access mode. Public HTTPS control API exposure should be optional and strongly authenticated. Provider callbacks and webhooks may use narrowly routed public prefixes with protocol-specific authentication.

Rationale:

The API can control deployments, secrets, resources, and containers. It should not be casually exposed.

Implications:

- Prefer SSH tunnel, localhost, WireGuard, Tailscale, or mTLS.
- Use scoped, revocable tokens.
- Keep dashboard-to-server authentication explicit.
- Let Caddy expose only the callback paths a provider requires; protect setup with one-time state and webhooks with signed payload verification.

## ADR 010: Migration Is Export/Import

Status: Proposed; export, import, and project migration are not implemented.

Decision:

Project migration should be modeled as export/import of a portable bundle.

Rationale:

This fits the no server-to-server communication principle and produces clear failure modes.

Implications:

- Reuse the versioned `valpo.toml` project manifest and extend export with runtime artifacts.
- Include database dumps, volume snapshots, static releases, and image references.
- Support import preflight validation.
- Add direct transfer only as an explicit later optimization.

## ADR 011: Managed Services Are The Happy Path

Status: Accepted for Postgres and Redis; additional services and data-portability behavior are deferred.

Decision:

Valpo provides curated Postgres and Redis services as the current happy path. Add another service only when its complete lifecycle is required and understood; arbitrary custom service containers remain deferred.

Rationale:

The target audience wants a modern version of the Heroku experience. Creating a database should not require choosing Docker images, manually creating volumes, wiring environment variables, and inventing backup commands.

Implications:

- Add a built-in service catalog.
- Model resources, credentials, and bindings explicitly.
- Let service provisioners generate connection settings.
- Mark generated environment values as managed.
- Include managed services in backup, restore, export, and import workflows.
- Keep custom containers separate from curated managed services.

## ADR 012: Preserve Extension Seams Without Shipping A Plugin Platform First

Status: Proposed constraint; no public plugin, lifecycle-event, backup-target, or notification contract exists.

Decision:

Valpo should define clean internal extension interfaces for sources, builds, managed services, backups, notifications, and lifecycle events. Public third-party plugins should come later, after the internal contracts prove stable.

Rationale:

Dokku's extensibility is one of its strengths, but unstructured shell hooks can be difficult for an API and dashboard to introspect. Valpo should preserve hackability while keeping state transitions structured and visible.

Implications:

- Keep source adapters, service definitions, backup targets, and notification sinks modular.
- Prefer typed lifecycle events with versioned payloads.
- Do not let extensions mutate Docker, Caddy, or SQLite state behind Valpo's model.
- Do not build a plugin marketplace in v1.
- Treat templates as declarative manifests, not arbitrary code.

## ADR 013: Use A Resource-First CLI With Synchronous Defaults

Status: Accepted and implemented.

Decision:

Use explicitly registered `dry-cli` command objects organized as `valpo RESOURCE ACTION`. Keep the server API asynchronous, but wait for operation jobs by default in the CLI.

Rationale:

Resource-first commands scale more consistently as projects gain multiple app and managed services. Synchronous defaults match interactive operator expectations, while `--no-wait` and advanced job commands preserve asynchronous and troubleshooting workflows.

Implications:

- Human-readable tables and detail views are the default.
- `--json` emits one JSON document on stdout for automation.
- Progress and job events go to stderr.
- Usage failures exit `2`; operational failures exit `1`.
- Background job commands remain available but are omitted from primary root help.
- Service type definitions used by help and validation must not require database boot.
