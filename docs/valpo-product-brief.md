# Valpo Product Brief

## Summary

Valpo is a modern, lightweight, VPS-hosted application platform for indie hackers and small teams. It should make one ordinary server feel like a tasteful, self-contained platform for deploying web apps, Docker containers, managed services, databases, and static sites.

The goal is not to build a Kubernetes replacement or a large multi-node platform. The goal is to make vertical scaling on one VPS pleasant, safe, inspectable, and easy to operate.

Current pre-release scope is intentionally smaller than the product direction below: registry and GitHub deployments, web/worker applications, and Postgres/Redis managed services run on one server with one worker. Static hosting, resource plans, export/import, public plugin APIs, multi-server operation, and multi-worker execution are not implemented.

## Product Positioning

Valpo turns each VPS into a self-sufficient app platform, then provides a dashboard and CLI to operate one or many Valpo servers.

Valpo is for people who miss the Heroku experience: simple deploys, add-on-like services, sensible defaults, and enough escape hatches for advanced users.

Key distinction:

> Each server is the source of truth for itself. The dashboard is an operator, not the brain.

If the dashboard is unavailable, applications continue running and the server remains manageable through the server API or CLI.

## Target Users

- Indie hackers deploying several small products.
- Solo developers who want a Heroku-like experience on their own VPS.
- Small teams with apps that can scale vertically before needing multi-node infrastructure.
- Developers who want GitHub/GitLab, Docker image, managed database, static-site, and backup workflows without Kubernetes complexity.

## Product Principles

- Simple by default.
- Self-contained per server.
- Sensible defaults before customization.
- Managed services before raw container wiring.
- Boring runtime primitives: Docker, Caddy, systemd, SQLite, filesystem volumes.
- Tasteful dashboard, but no dashboard dependency for runtime survival.
- Clear lifecycle events and logs for every long-running operation.
- Declarative project state where possible.
- No server-to-server communication in the default architecture.
- Migration as export/import, not magic live transfer.
- Arbitrary container configuration as an escape hatch, not the main happy path.
- Internal extension seams before a public plugin marketplace.

## Primary Capabilities

Valpo should eventually support:

- Deploy from Docker registry image.
- Deploy from GitHub repository.
- Deploy from GitLab repository.
- Build from a Dockerfile or Cloud Native Buildpacks.
- Host static sites from uploaded zip folders with a drag-and-drop dashboard flow.
- Manage domains and TLS.
- Manage environment variables and secrets.
- Create and manage Heroku-style services such as Postgres, MariaDB, Redis, and volumes.
- Bind services to apps without requiring users to manually assemble environment variables.
- View logs, releases, health checks, deploy history, and job status.
- Roll back to previous releases.
- Back up and restore resources.
- Export/import projects between servers.
- Manage multiple independent servers from one dashboard.
- Extend deployment sources, managed services, backup targets, and notification sinks over time.

## Non-Goals

Valpo should not initially attempt to provide:

- Kubernetes orchestration.
- Multi-node scheduling.
- Automatic horizontal scaling across servers.
- Server-to-server clustering.
- Service mesh functionality.
- A plugin marketplace.
- Feature parity with broad self-hosted PaaS tools such as Coolify or Dokploy.
- Full cloud-provider abstraction.
- Complex infrastructure-as-code workflows.
- A general CI platform.

## Experience Goals

CLI examples:

```bash
valpo project create hello
valpo service create web --project hello --type web --port 3000
valpo service create database --project hello --type postgres
valpo service bind web database --project hello
valpo service deploy web --project hello --image ghcr.io/example/hello:latest
valpo domain add web hello.example.com --project hello
valpo service logs web --project hello
valpo release rollback web --project hello
```

Dashboard examples:

- Register a VPS.
- Create a project.
- Connect a GitHub/GitLab repository.
- Deploy from an image or branch.
- Drag and drop a static-site zip.
- Add a domain.
- Watch deployment logs stream in real time.
- Create a Postgres service from friendly presets.
- Bind the Postgres service to an app without manually configuring `DATABASE_URL`.
- Back up a project.
- Export a project and import it on another server.

## Central Product Bet

The useful wedge is not "a smaller Kubernetes." It is:

> A refined, self-hosted control plane for Heroku-like single-server application hosting.
