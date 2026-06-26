# Valpo

Valpo is an early-stage design exploration for a lightweight, Heroku-like VPS application platform.

The current intent is to make one appropriately sized server feel like a tasteful, self-contained platform for deploying web apps, Docker containers, managed services, databases, and static sites.

## Current Status

Phase 0 implementation has started. The repository now contains the first Ruby scaffold for the local server API, worker, CLI, SQLite migrations, and Docker/Caddy wrapper boundaries.

## Development

Valpo currently targets Ruby 4.0.5 and Ubuntu 26.04 LTS for the first host packaging templates.

```bash
mise install ruby@4.0.5
mise x ruby@4.0.5 -- bundle install
mise x ruby@4.0.5 -- bundle exec rake db:migrate
mise x ruby@4.0.5 -- bundle exec rake test
```

If your shell is not already using Ruby 4.0.5, prefix commands with `mise x ruby@4.0.5 --`.

Local defaults keep state under `tmp/`, bind the API to `127.0.0.1:7092`, render generated Caddy config under `tmp/`, and assume a shared Docker network named `valpo`.

Useful development commands:

Terminal 1:

```bash
mise x ruby@4.0.5 -- bundle exec exe/valpo-api --migrate
```

Terminal 2:

```bash
mise x ruby@4.0.5 -- bundle exec exe/valpo projects:create hello
mise x ruby@4.0.5 -- bundle exec exe/valpo jobs:enqueue-system-check
mise x ruby@4.0.5 -- bundle exec exe/valpo-worker --once
mise x ruby@4.0.5 -- bundle exec exe/valpo jobs:list
```

## Documents

- [Product brief](docs/valpo-product-brief.md)
- [Technical architecture](docs/valpo-technical-architecture.md)
- [Managed services](docs/valpo-managed-services.md)
- [Extensibility and positioning](docs/valpo-extensibility-and-positioning.md)
- [Roadmap](docs/valpo-roadmap.md)
- [Architecture decisions](docs/valpo-architecture-decisions.md)
- [Agent handoff](docs/valpo-agent-handoff.md)
