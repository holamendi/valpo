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

- Docker image and Git deploy paths, with Dockerfile and buildpack builds.
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

## Deferred Extensibility Constraints

Status: not implemented. Valpo has no public plugin API, plugin package format, lifecycle-event contract, backup-target interface, notification sink, or template system.

The current code should remain concrete until a second real implementation creates pressure for an interface. Existing source fetching, build strategies, and managed-service definitions may use small internal composition boundaries, but those boundaries are not promises to third parties and should be changed freely while the product is pre-release.

If a concrete extension requirement arrives, preserve only these constraints:

- long-running actions remain visible jobs with inspectable output and failures;
- resources and state transitions remain visible through Valpo's model and API;
- extensions do not mutate Docker, Caddy, or SQLite behind Valpo's ownership boundaries;
- secrets are provided only through an explicit, narrowly scoped contract;
- declarative project templates, if needed, build on the existing validated manifest rather than execute arbitrary code.

Do not add adapters, event taxonomies, subprocess protocols, packaging formats, permission systems, or marketplaces in anticipation of future providers. Introduce the smallest boundary demanded by the next implemented source, service, backup, or notification feature, then reassess it after two real uses.

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
