# Valpo

Valpo is an early-stage design exploration for a lightweight, Heroku-like VPS application platform.

The current intent is to make one appropriately sized server feel like a tasteful, self-contained platform for deploying web apps, Docker containers, managed services, databases, and static sites.

## Current Status

Phase 2B is implemented and the PAT-based bootstrap of Phase 3A is available. A Valpo project can contain multiple app and managed services, apply a strict `valpo.toml` manifest, or create a PAT-authenticated GitHub Dockerfile service entirely through the CLI. Source creation and updates validate the repository, ref, Dockerfile, and context before changing configuration. Web ports can be explicit or resolved from image metadata, with a port-3000 fallback for source images that declare none. Valpo routes web services through Caddy and provisions private Postgres and Redis dependencies.

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

Refresh the generated CLI guide after changing commands or service definitions:

```bash
mise exec -- bundle exec rake cli:docs
```

Terminal 1:

```bash
mise exec -- bundle exec exe/valpo-api --migrate
```

Terminal 2:

```bash
mise exec -- bundle exec exe/valpo-worker
```

Terminal 3:

```bash
mise exec -- bundle exec exe/valpo project create hello
mise exec -- bundle exec exe/valpo service create hello/web --type web --port 3000
mise exec -- bundle exec exe/valpo service deploy hello/web --image nginx:alpine
mise exec -- bundle exec exe/valpo service list hello
mise exec -- bundle exec exe/valpo system status
```

After configuring GitHub authentication, a source-backed service needs no manifest and usually needs no build or port flags:

```bash
mise exec -- bundle exec exe/valpo auth login github
mise exec -- bundle exec exe/valpo project create smol-roda
mise exec -- bundle exec exe/valpo service create smol-roda/web \
  --type web \
  --source github:holamendi/smol-roda \
  --deploy
mise exec -- bundle exec exe/valpo domain add smol-roda/web smol-roda.apps.example.com
```

## Documents

- [Product brief](docs/valpo-product-brief.md)
- [Technical architecture](docs/valpo-technical-architecture.md)
- [Managed services](docs/valpo-managed-services.md)
- [Project manifest](docs/valpo-project-manifest.md)
- [CLI guide](docs/valpo-cli.md)
- [Extensibility and positioning](docs/valpo-extensibility-and-positioning.md)
- [Roadmap](docs/valpo-roadmap.md)
- [Architecture decisions](docs/valpo-architecture-decisions.md)
- [Agent handoff](docs/valpo-agent-handoff.md)
