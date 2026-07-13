# Valpo Handoff Documents

This folder contains early planning artifacts for Valpo, a lightweight VPS app platform inspired by Dokku, Kamal, Heroku, and static-site hosting tools.

The documents are intended for product planning, architectural review, and handoff to implementation agents.

## Documents

- [valpo-product-brief.md](./valpo-product-brief.md) describes the product idea, audience, principles, scope, and non-goals.
- [valpo-technical-architecture.md](./valpo-technical-architecture.md) describes the proposed host architecture, runtime components, core data model, job system, deployment flows, security posture, and migration model.
- [valpo-managed-services.md](./valpo-managed-services.md) describes the Heroku-style add-on experience for Postgres, MariaDB, Redis, and other high-level services.
- [valpo-project-manifest.md](./valpo-project-manifest.md) defines the current `valpo.toml` schema and reconciliation behavior.
- [valpo-cli.md](./valpo-cli.md) is the generated canonical command-line guide.
- [valpo-extensibility-and-positioning.md](./valpo-extensibility-and-positioning.md) compares reference projects and defines Valpo's extensibility boundaries.
- [valpo-roadmap.md](./valpo-roadmap.md) proposes a staged implementation roadmap from single-server core to multi-server dashboard.
- [valpo-architecture-decisions.md](./valpo-architecture-decisions.md) captures initial high-level decisions in lightweight ADR form.
- [valpo-agent-handoff.md](./valpo-agent-handoff.md) gives implementation agents a concrete starting brief, conventions, and first build milestones.
