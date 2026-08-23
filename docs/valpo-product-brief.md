# Valpo Product Brief

Valpo is a self-hosted, Heroku-like platform for applications that fit on one VPS. It combines simple deployments, managed services, HTTPS, and inspectable operations without introducing Kubernetes or a central control plane.

Each server owns its state and remains manageable through its API and CLI. A future dashboard will operate one or more independent servers, but applications must not depend on it.

## Audience

- Individuals and small teams running several applications on their own infrastructure.
- Developers who prefer managed defaults but still need access to the underlying server.
- Workloads that can scale vertically before requiring multi-node orchestration.

## Principles

- Keep each server self-contained.
- Prefer managed services and sensible defaults to raw container wiring.
- Use familiar primitives: Docker, Caddy, systemd, SQLite, and filesystem volumes.
- Make long-running operations, state changes, and failures inspectable.
- Keep the dashboard optional and avoid server-to-server coordination.
- Add extension contracts only after multiple implementations need them.

## Scope

The current pre-release supports registry and GitHub deployments, Dockerfile and buildpack builds, web and worker applications, Postgres and Redis, domains, releases, and a project manifest.

Planned work includes production-safe installation and recovery, more source providers, static sites, backups, project export/import, and a multi-server dashboard. See the [roadmap](./valpo-roadmap.md) for sequencing.

Valpo is not intended to provide Kubernetes orchestration, multi-node scheduling, automatic horizontal scaling, a service mesh, a general CI platform, or a broad plugin marketplace. Raw container configuration may become an escape hatch, but it is not the primary product model.

The central product bet is a refined, self-hosted control plane for single-server application hosting—not a smaller cloud provider.
