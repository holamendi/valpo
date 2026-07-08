# Valpo Agent Handoff

## Context

Valpo is a lightweight VPS application platform. It should provide a clean API, CLI, and dashboard for deploying and operating apps on one or many independent servers.

Each server is self-contained. The dashboard can manage multiple servers, but no server should depend on the dashboard or another server to keep running.

## Current Preferred Stack

Host server:

- Ruby
- Roda
- Sequel
- SQLite
- Puma
- systemd
- Docker Engine
- Caddy

Dashboard:

- Undecided, but Ruby/Rails is acceptable.
- Dashboard must talk to server APIs rather than own runtime state.

CLI:

- Ruby gem.
- Can talk directly to a server API.
- Should support SSH tunnel or private endpoint workflows.

## Architecture Rules

Follow these rules unless a later decision explicitly changes them:

1. Each VPS owns its own state.
2. Dashboard is optional for runtime survival.
3. Server-to-server communication is not part of the default model.
4. Long-running work must run as jobs, not API request handlers.
5. All deployment inputs should become releases.
6. Dynamic apps run as Docker containers.
7. Static sites are served directly by Caddy.
8. SQLite is the metadata store for the Valpo server.
9. Caddy is the default reverse proxy and static file server.
10. API access should be private by default.
11. Managed services are the happy path for common infrastructure.
12. Arbitrary custom containers are the escape hatch.
13. Preserve internal extension seams, but do not build a public plugin platform in v1.

## First Implementation Goal

Phase 1 is complete. The next implementation goal is first-class static-site hosting:

```text
create static project
upload a zipped dist directory
validate and extract zip releases safely
route static files through Caddy
support static release rollback
```

Do not start with GitHub/GitLab OAuth, buildpacks, managed databases, or the multi-server dashboard. Those depend on the core deploy lifecycle and static-site release model.

Do preserve modular boundaries for source adapters, build adapters, service definitions, backup targets, notification sinks, and lifecycle events. Those are future extension points, not v1 product scope.

## Suggested Repository Structure

The current implementation keeps API, worker, CLI, and shared library code in one Ruby gem-style repository rather than separate `apps/` directories.

```text
valpo/
  lib/
    valpo/
      api/
      jobs/
      models/
      docker/
      caddy/
      config.rb
      database.rb
      migrator.rb
  db/
    migrations/
  exe/
    valpo
    valpo-api
    valpo-worker
  packaging/
    README.md
    systemd/
  docs/
  test/
    valpo/
```

This structure is only a starting suggestion. Prefer coherence over rigid adherence.

## Initial Data Model

Minimum tables for the first slice:

```text
projects
releases
domains
jobs
job_events
```

Likely next tables:

```text
services
environment_variables
resources
resource_bindings
resource_credentials
backups
server_settings
api_tokens
```

## First API Surface

Approximate v1 endpoints:

```text
GET    /health

GET    /projects
POST   /projects
GET    /projects/:id
DELETE /projects/:id

POST   /projects/:id/deployments
GET    /projects/:id/releases
POST   /projects/:id/releases/:release_id/activate

GET    /projects/:id/domains
POST   /projects/:id/domains
DELETE /projects/:id/domains/:domain_id

GET    /projects/:id/logs

GET    /jobs
GET    /jobs/:id
GET    /jobs/:id/events
POST   /jobs/:id/cancel
```

Deployment request example:

```json
{
  "source_type": "registry",
  "image": "ghcr.io/example/hello:latest",
  "internal_port": 3000,
  "healthcheck_path": "/health"
}
```

## First Job Types

```text
deploy_registry_image
activate_release
rollback_release
apply_caddy_config
delete_project
```

Later job types:

```text
build_from_git
deploy_static_zip
provision_managed_service
bind_managed_service
rotate_service_credentials
backup_resource
restore_resource
export_project
import_project
```

## Deployment Implementation Notes

For registry deploy:

1. Pull the image.
2. Inspect and record the image digest.
3. Create a pending release.
4. Start a new container with deterministic labels.
5. Wait for health check.
6. Apply Caddy route to the new container.
7. Mark release active.
8. Stop old container after a drain period.
9. Mark job succeeded.

If a new deploy fails, leave the current active release untouched.

Suggested Docker labels:

```text
valpo.project_id
valpo.release_id
valpo.service
valpo.managed=true
```

## Caddy Implementation Notes

Valpo should store routing intent in SQLite and render/apply Caddy config from Valpo state.

Generated config should be reproducible from the database.

Avoid making raw Caddy config the primary source of truth.

## Managed Service Implementation Notes

Valpo should support arbitrary containers, but curated services should be the default experience for databases and common infrastructure.

Start with a built-in service catalog in Ruby code:

```text
postgres
mariadb
redis
volume
```

Each service should expose friendly settings such as name, version, plan, backup preference, and binding target. The provisioner should translate those settings into Docker containers, volumes, credentials, health checks, and generated app configuration.

Binding a Postgres service to an app should generate values such as `DATABASE_URL`, `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, and `PGPASSWORD`. Users should not have to create these by hand.

Generated environment values should be tracked as managed values so Valpo can update them during credential rotation, restore, or migration.

## Testing Priorities

Start with tests around state transitions and failure behavior:

- Job locking.
- Job retry or stale lock handling.
- Failed deploy leaves active release unchanged.
- Release activation updates the expected state.
- Rollback chooses the correct previous release.
- Caddy config generation from routes.
- Docker wrapper command construction.

Use integration tests where local Docker is available, but keep unit tests able to run without Docker.

Keep test files aligned with the source tree. For example, `lib/valpo/models/project.rb` should have a focused counterpart under `test/valpo/models/project_test.rb`.

## Open Questions

- How should secret encryption keys be generated, stored, and rotated?
- Should managed service credentials be preserved or regenerated during project import?
- Should v1 managed services be owned by exactly one project?
- Should Postgres/MariaDB backups be enabled by default?

Resolved for the current scaffold:

- The first API binds to localhost by default.
- The CLI is bundled in the same Ruby project as the server.
- Caddy starts with generated config file rendering and reload boundaries.
- Docker starts with one shared network named `valpo`.
- The first packaging target is Ubuntu 26.04 LTS.

## Agent Instruction

When starting implementation, read these documents first:

1. `valpo-product-brief.md`
2. `valpo-technical-architecture.md`
3. `valpo-managed-services.md`
4. `valpo-extensibility-and-positioning.md`
5. `valpo-architecture-decisions.md`
6. `valpo-roadmap.md`

Then continue with Phase 2 only:

- Add static-site hosting before moving to Git providers, managed services, or dashboard work.

Do not move to GitHub/GitLab, managed services, or dashboard work until static projects, zip upload, safe extraction, Caddy static routing, and static rollback are in place.
