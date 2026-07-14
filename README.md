# Valpo

Valpo is a pre-release, self-hosted application platform for a single VPS. Its CLI deploys web and worker containers, routes web traffic through Caddy, and attaches private Postgres and Redis services.

Valpo is under active development and is not ready for production use. Database migrations may be rewritten before the first release, and development installations may need to recreate their SQLite database after an update.

## What Works Today

- Deploy `web` and `worker` services from registry images.
- Build and deploy Dockerfiles from GitHub repositories with a fine-grained personal access token (PAT).
- Route web services through Caddy with automatic HTTPS.
- Resolve web ports from explicit configuration or image metadata, with a port `3000` fallback for source images that expose no port.
- Provision private Postgres 16, 17, or 18 and Redis 7 or 8 services with persistent Docker volumes.
- Bind managed services to individual app services and inject their generated connection variables.
- Inspect logs and releases, roll back releases, stop or restart services, and repair runtime state.
- Define multi-service projects with a strict, add/update-only `valpo.toml` manifest.

GitLab, GitHub App authentication and webhooks, buildpacks, static-site uploads, backups, project import/export, and the dashboard are planned but not implemented.

## Install On Ubuntu

The source installer currently targets a fresh Ubuntu 26.04 LTS server. It installs Docker, Caddy, mise, Ruby 4.0.5, Valpo's Ruby dependencies, systemd units, and an operator CLI at `/usr/local/bin/valpo`.

```bash
git clone https://github.com/holamendi/valpo.git
cd valpo
sudo packaging/install.sh
sudo valpo system status
```

The installer stores configuration in `/etc/valpo/valpo.yml` and state in `/var/lib/valpo`. The API listens on `127.0.0.1:7092` by default. Keep it private unless you configure `api_token`; Valpo refuses to bind an unauthenticated API to a non-local address.

See the [packaging guide](packaging/README.md) for installer options, configuration, service management, and VPS smoke tests.

## Deploy A Registry Image

Create a project and a web service, deploy an image, then attach a domain:

```bash
sudo valpo project create hello
sudo valpo service create hello/web --type web --port 80
sudo valpo service deploy hello/web --image nginx:alpine
sudo valpo domain add hello/web hello.example.com
```

Point the domain's DNS record at the server before adding it so Caddy can obtain a TLS certificate. Deployment and domain commands wait for their background jobs by default and stream progress to stderr.

Useful follow-up commands:

```bash
sudo valpo service show hello/web
sudo valpo service logs hello/web
sudo valpo release list hello/web
sudo valpo release rollback hello/web
```

## Deploy From GitHub

Valpo's current GitHub integration uses one server-wide, fine-grained PAT. Interactive login shows a link to GitHub's token form, validates the token, and stores it in Valpo's private credential file:

```bash
sudo valpo auth login github
sudo valpo auth status github
```

Create and deploy a service directly from a repository:

```bash
sudo valpo project create smol-roda
sudo valpo service create smol-roda/web \
  --type web \
  --source github:holamendi/smol-roda \
  --deploy
```

The source defaults to remote `HEAD`, `Dockerfile`, and build context `.`. Valpo validates the repository, ref, Dockerfile, and context before saving the configuration. GitHub.com is the only supported provider today; Git submodules and Git LFS are not configured automatically.

## Add A Managed Service

Create a private database and bind it to an app service:

```bash
sudo valpo service create hello/database --type postgres
sudo valpo service bind hello/web hello/database
sudo valpo service env hello/web
```

Generated secret values are masked unless `service env` is passed `--reveal`. Managed services are not exposed on public host ports.

## Use A Project Manifest

A `valpo.toml` file can declare sources, Docker build targets, app services, managed services, and dependencies. Preview changes before applying them:

```bash
sudo valpo project apply valpo.toml --dry-run
sudo valpo project apply valpo.toml
```

Manifest reconciliation creates and updates declared records but retains omitted records. Destructive changes require explicit CLI commands. See the [project manifest guide](docs/valpo-project-manifest.md) for the schema and a complete example.

## CLI And Configuration

Run `sudo valpo --help` or `sudo valpo RESOURCE ACTION --help` for contextual help. Commands use readable output by default; add `--json` for automation. Use `--no-wait` to return a queued job immediately or `--timeout SECONDS` to change the default wait.

The installed wrapper runs Valpo as its dedicated system user, so host-local commands normally need `sudo`. API authentication is read from `VALPO_API_TOKEN` first, then `api_token` in the loaded configuration file.

See the generated [CLI guide](docs/valpo-cli.md) for every command, reference format, global option, and exit code.

## Pre-release Database Compatibility

All current schema is defined in the first migration because Valpo has not been released. If an existing development database reports a migration version newer than the migrations in the checkout, back it up if necessary, remove it, and run the migrations again.

Valpo also detects the retired project-as-app schema and refuses to discard it automatically. The local development database defaults to `tmp/valpo-development.sqlite3`; installed hosts use `/var/lib/valpo/valpo.db` by default.

## Development

The repository pins Ruby 4.0.5 with mise:

```bash
mise trust
mise install
mise exec -- bundle install
mise exec -- bundle exec rake db:migrate
mise exec -- bundle exec rake test
mise exec -- bundle exec rake standard
```

Run the API, worker, and development CLI in separate terminals:

```bash
mise exec -- bundle exec exe/valpo-api --migrate
mise exec -- bundle exec exe/valpo-worker
mise exec -- bundle exec exe/valpo system status
```

Install the repo-managed Git hooks with `mise exec -- bundle exec rake hooks:install`. After changing CLI registration, arguments, or service definitions, regenerate the canonical CLI guide with `mise exec -- bundle exec rake cli:docs`.

## More Documentation

- [CLI guide](docs/valpo-cli.md)
- [Project manifest](docs/valpo-project-manifest.md)
- [Managed services](docs/valpo-managed-services.md)
- [Packaging and host operations](packaging/README.md)
- [Product brief](docs/valpo-product-brief.md)
- [Technical architecture](docs/valpo-technical-architecture.md)
- [Roadmap](docs/valpo-roadmap.md)
- [Architecture decisions](docs/valpo-architecture-decisions.md)
- [Extensibility and positioning](docs/valpo-extensibility-and-positioning.md)
- [Agent handoff](docs/valpo-agent-handoff.md)
