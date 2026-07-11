# Valpo

Valpo is an early-stage design exploration for a lightweight, Heroku-like VPS application platform.

The current intent is to make one appropriately sized server feel like a tasteful, self-contained platform for deploying web apps, Docker containers, managed services, databases, and static sites.

## Current Status

Phase 2B is implemented. A Valpo project can contain multiple app and managed services, apply a strict `valpo.toml` manifest, deploy registry images, route web services through Caddy, and provision private Postgres and Redis dependencies.

This pre-release schema is a clean break from the earlier project-as-app model. Existing development installations must back up and reset their SQLite database before upgrading; Valpo detects the retired schema and refuses to discard it automatically.

## Development

Valpo currently targets Ruby 4.0.5 and Ubuntu 26.04 LTS for the first host packaging templates.

```bash
mise trust
mise install
mise exec -- bundle install
mise exec -- bundle exec rake db:migrate
mise exec -- bundle exec rake test
mise exec -- bundle exec rake standard
```

After trusting `.mise.toml`, shell integration can run `bundle` directly. The examples below use `mise exec --` explicitly so they also work in automation.

Local defaults keep state under `tmp/`, bind the API to `127.0.0.1:7092`, render generated Caddy config under `tmp/`, and assume a shared Docker network named `valpo`.

Useful development commands:

Install the repo-managed Git hooks:

```bash
mise exec -- bundle exec rake hooks:install
```

Run or auto-fix Ruby style with Standard:

```bash
mise exec -- bundle exec rake standard
mise exec -- bundle exec rake standard:fix
```

Terminal 1:

```bash
mise exec -- bundle exec exe/valpo-api --migrate
```

Terminal 2:

```bash
mise exec -- bundle exec exe/valpo projects:create hello
mise exec -- bundle exec exe/valpo services:create hello/web --type web --port 3000
mise exec -- bundle exec exe/valpo deploy hello/web --image nginx:alpine
mise exec -- bundle exec exe/valpo jobs:enqueue-system-check
mise exec -- bundle exec exe/valpo-worker --once
mise exec -- bundle exec exe/valpo jobs:list
```

## Documents

- [Product brief](docs/valpo-product-brief.md)
- [Technical architecture](docs/valpo-technical-architecture.md)
- [Managed services](docs/valpo-managed-services.md)
- [Project manifest](docs/valpo-project-manifest.md)
- [Extensibility and positioning](docs/valpo-extensibility-and-positioning.md)
- [Roadmap](docs/valpo-roadmap.md)
- [Architecture decisions](docs/valpo-architecture-decisions.md)
- [Agent handoff](docs/valpo-agent-handoff.md)
