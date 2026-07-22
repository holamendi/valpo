# Valpo Extensibility And Positioning

Research snapshot: 2026-07-22. This document records architectural lessons, not a continuously maintained feature comparison. Vendor capabilities and positioning change; only claims that influence a Valpo boundary are retained.

## Context

Valpo should be extensible enough to grow beyond its built-in services, but it should not become a broad, everything-included self-hosting control panel.

The closest reference points are:

- Dokku for small, scriptable, plugin-friendly server operations.
- Coolify and Dokploy for modern self-hosted PaaS breadth.
- Railway for polished project/service UX.

Valpo should borrow selectively while keeping a narrower product boundary.

## Competitive Notes

### Dokku

Dokku's strength is its Unix-like extensibility. Its plugins are simple collections of executable files, commands, and lifecycle hooks. That makes it approachable to build on top of.

What to borrow:

- Lifecycle extension points.
- Command extensibility.
- Add-on-like service plugins.
- Low ceremony for advanced users.

What to avoid:

- Unstructured shell hooks as the main extension contract.
- Hidden global side effects.
- Plugin behavior that is hard for the API/dashboard to introspect.
- Extensions that mutate runtime state outside Valpo's model.

Valpo should learn from Dokku's simplicity, but expose more structured extension contracts.

### Coolify

Coolify represents the broad, dashboard-first self-hosted PaaS category. The relevant architectural contrast is breadth across infrastructure and team workflows versus Valpo's deliberately independent single-server control plane.

What to borrow:

- Clear dashboard-first management.
- Git integrations.
- Managed databases and services.
- Backups as a visible product feature.
- API-driven operations.

What to avoid:

- "Any use-case" positioning.
- Too many one-click services too early.
- Adjacent team, observability, and automation surfaces becoming required early scope.
- Multi-server and cluster abstractions that weaken the single-server mental model.

Valpo should not compete by matching feature count.

### Dokploy

Dokploy represents a Compose- and infrastructure-oriented self-hosted deployment platform. The relevant contrast is a wide runtime/configuration surface versus Valpo's typed services, releases, and generated routing model.

What to borrow:

- Docker image, Git, and Dockerfile deploy paths.
- Managed database creation and backups.
- Templates as a later onboarding feature.
- API and CLI access.

What to avoid:

- Docker Compose as the core happy path.
- Traefik labels or proxy internals leaking into normal user workflows.
- Docker Swarm or multi-node capabilities in early architecture.
- Enterprise/team-management scope before the single-server experience is excellent.

Valpo should feel more opinionated and calmer than Dokploy.

### Railway

Railway is much broader than Valpo's intended scope, but its project/service mental model is the useful reference: an app can live beside databases and supporting services, with generated configuration connecting them.

What to borrow:

- Project as a container for app services and resources.
- Clear service/resource cards.
- Database creation as a first-class action.
- Generated connection variables and service references.
- Templates as a high-quality onboarding path.
- Deployment/job logs that feel immediate and legible.

What to avoid:

- Complex cloud-provider scope.
- PR environments and duplicated environments as early features.
- Gimmicky UI interactions that do not improve operator confidence.
- Treating Valpo as a cloud platform rather than a self-contained VPS platform.

Valpo should borrow Railway's clarity, not its breadth.

## Positioning Boundary

Valpo should be:

```text
A tasteful, Heroku-like VPS platform for one machine that is enough for the job.
```

Valpo should not be:

```text
A self-hosted cloud provider.
A Kubernetes alternative.
A Docker Compose GUI.
A homelab app store.
A multi-node orchestration system.
A complete observability platform.
```

It should run on a small VPS if the user wants that, but the product should not be shaped around the "$5 VPS runs everything" meme. The real target is a single machine sized appropriately for the workload.

## Extensibility Strategy

Extensibility should be designed in layers.

### Layer 1: Internal Extension Interfaces

Build internal interfaces first, before public plugins:

```text
SourceAdapter
BuildAdapter
ServiceDefinition
ServiceProvisioner
BackupTarget
NotificationSink
LifecycleSubscriber
```

These should be Ruby interfaces used by built-in features. Once they stabilize, they can become public plugin contracts.

### Layer 2: Typed Lifecycle Events

Expose structured lifecycle events instead of arbitrary shell hooks:

```text
project.created
deployment.started
deployment.succeeded
deployment.failed
release.activated
domain.attached
resource.provisioned
resource.bound
backup.completed
import.completed
```

Each event should have:

- a versioned payload
- stable identifiers
- timeout behavior
- retry behavior
- clear permission scope
- job/event log visibility

### Layer 3: Plugin Packages

Public plugins can come later. Possible packaging options:

- Ruby gems loaded by Valpo.
- Local plugin directories with a manifest.
- Subprocess plugins that communicate over JSON.

The safest long-term shape is probably a manifest plus subprocess protocol. It keeps plugins language-agnostic and allows Valpo to control permissions, timeouts, inputs, and outputs.

Example manifest:

```toml
[plugin]
name = "valpo-postmark"
version = "0.1.0"
api_version = "2026-06"
description = "Send deployment notifications through Postmark"

[[hooks]]
event = "deployment.succeeded"
command = "bin/deployment-succeeded"
timeout_seconds = 10
```

Do not build this in v1. Design the internal boundaries so it remains possible.

## First Extension Points To Preserve

The earliest code should leave room for:

- new deployment sources such as GitHub, GitLab, registry, static upload, and later S3 artifact
- new managed service definitions such as Postgres, MariaDB, Redis, and later Meilisearch
- new backup targets such as local disk, S3, R2, Backblaze B2
- notification sinks such as webhook, Slack, email
- templates that create projects and services from a manifest
- deployment lifecycle subscribers

Avoid designing every extension point immediately. Keep the core abstractions small and explicit.

## Plugin Guardrails

Valpo should not allow plugins to silently bypass the core state model.

Guardrails:

- Plugin actions must be represented as jobs when they are long-running.
- Plugin-created resources must be visible in the API and dashboard.
- Plugin output must be structured.
- Plugin failures must be visible in job logs.
- Plugins should declare required capabilities.
- Plugins should not receive secrets unless explicitly granted.
- Plugins should not mutate Caddy or Docker outside Valpo's wrappers.
- Plugins should use Valpo APIs for state changes.

## Template Strategy

Templates are related to extensibility but should be simpler.

A template should describe a project shape:

```text
app service
managed services
environment variables
domains
volumes
post-deploy notes
```

Templates should not be arbitrary code by default. They should be declarative manifests that Valpo validates before applying.

This gives Valpo one-click onboarding without becoming an app store too early.

## Product Direction

The right direction is:

```text
small core
excellent defaults
managed services
structured extension points
public plugin API later
```

The wrong direction is:

```text
feature parity with Coolify/Dokploy
raw Docker Compose as the primary user experience
unbounded service marketplace
multi-server orchestration
shell hooks before stable domain events
```

## Sources Reviewed For This Snapshot

- [Coolify documentation](https://coolify.io/docs)
- [Dokploy documentation](https://docs.dokploy.com/docs/core)
- [Dokku plugin documentation](https://dokku.com/docs/development/plugin-creation/)
- [Dokku community plugin documentation](https://dokku.com/docs/community/plugins/)
- [Railway documentation](https://docs.railway.com/)
