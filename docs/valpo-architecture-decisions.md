# Valpo Architecture Decisions

This document captures early decisions. They are intentionally lightweight and can evolve as implementation reveals better constraints.

## ADR 001: Each Server Is Self-Sufficient

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

Decision:

The dashboard manages multiple independent servers by calling each server's API. It does not become the global source of truth for running apps.

Rationale:

This preserves the simple mental model and makes failure modes easier to understand.

Implications:

- Dashboard can cache state, but must be able to refresh from servers.
- Server APIs need complete project management capabilities.
- Server-side CLI should remain possible.

## ADR 003: Use Ruby, Roda, Sequel, And SQLite For The Host Agent

Decision:

Use Ruby for the host API and worker. Use Roda for the API, Sequel for database access, and SQLite for local metadata.

Rationale:

The host control plane is orchestration-heavy rather than throughput-heavy. Ruby keeps implementation approachable, Roda keeps the host API small, and SQLite fits the single-server source-of-truth model.

Implications:

- Avoid a separate database dependency for Valpo itself.
- Keep the host agent easy to inspect and back up.
- Use migrations for all local schema changes.

## ADR 004: Use SQLite-Backed Jobs For V1

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

Decision:

Docker registry images, GitHub repos, GitLab repos, and static zip uploads should all produce immutable releases.

Rationale:

A single release lifecycle makes deploys, rollbacks, logs, and migrations easier to reason about.

Implications:

- Source adapters should be separate from deploy activation.
- Rollback should activate a previous release artifact.
- Git providers should not create a separate deploy architecture.

## ADR 006: Docker Images Are The Runtime Artifact For Dynamic Apps

Decision:

Dynamic web apps should run as Docker containers. GitHub/GitLab builds should produce Docker images. Registry deploys should pull Docker images.

Rationale:

Docker is the common denominator for running arbitrary web apps on a VPS.

Implications:

- Store image references and digests in release records.
- Prefer image digest for reproducibility.
- Start with Dockerfile builds.
- Add buildpacks later if needed.

## ADR 007: Static Sites Are Served Directly By Caddy

Decision:

Static zip uploads should extract into immutable release directories and be served by Caddy's static file server.

Rationale:

Running a static site inside a container adds unnecessary overhead and obscures a simple hosting path.

Implications:

- Static projects have release directories rather than app containers.
- Caddy routing handles static file serving.
- Static rollback changes the active release route.

## ADR 008: Use Caddy As The Default Proxy

Decision:

Use Caddy for HTTP routing, automatic HTTPS, and static file serving.

Rationale:

Caddy matches Valpo's preference for sensible defaults, low operational overhead, and straightforward HTTPS.

Implications:

- Valpo stores routing intent and applies generated Caddy config.
- Dynamic apps route to container ports.
- Static apps route to release directories.

## ADR 009: API Should Be Private By Default

Decision:

The host API should default to a private access mode. Public HTTPS API exposure should be optional and strongly authenticated.

Rationale:

The API can control deployments, secrets, resources, and containers. It should not be casually exposed.

Implications:

- Prefer SSH tunnel, localhost, WireGuard, Tailscale, or mTLS.
- Use scoped, revocable tokens.
- Keep dashboard-to-server authentication explicit.

## ADR 010: Migration Is Export/Import

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

Decision:

Valpo should provide curated managed services for common infrastructure such as Postgres, MariaDB, Redis, and volumes. Arbitrary containers remain supported as an advanced escape hatch.

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
