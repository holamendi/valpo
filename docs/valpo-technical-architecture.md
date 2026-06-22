# Valpo Technical Architecture

## Architecture Summary

Valpo runs a small control plane on each VPS. The control plane exposes an API, stores local metadata in SQLite, performs long-running work through a background worker, and delegates runtime concerns to Docker, Caddy, systemd, and the host filesystem.

The happy path should be Heroku-like: create an app, attach a managed service, deploy, and let Valpo generate the low-level configuration. Raw container configuration remains available for advanced users.

The dashboard and CLI talk to each server API. Servers do not need to communicate with each other.

```text
Dashboard / CLI
      |
      | HTTPS, SSH tunnel, WireGuard, Tailscale, or mTLS
      |
Valpo API on VPS
      |
      | creates jobs, reads state, streams events
      |
Valpo Worker
      |
      | orchestrates
      |
Docker, Caddy, systemd, SQLite, filesystem volumes
```

## Proposed Host Components

Each Valpo server should run:

```text
valpo-api        Roda API service, served by Puma
valpo-worker     background worker for deploys, builds, backups, restores
valpo-db.sqlite  local metadata database
Docker Engine    app containers, database containers, image builds
Caddy            reverse proxy, TLS, static file serving
systemd          service supervision for Valpo itself
filesystem       uploads, releases, backups, build cache, volume snapshots
```

## Suggested Ruby Stack

- Roda for the host API.
- Sequel for persistence.
- SQLite for Valpo metadata.
- Puma for serving the API.
- A custom SQLite-backed job runner for v1.
- Ruby CLI, likely using OptionParser or Thor.

Avoid introducing Redis, Sidekiq, Postgres, or a message broker for Valpo's own internals until there is a concrete need.

## Runtime Philosophy

Ruby should own orchestration and state transitions. It should not try to become the runtime.

Use existing host tools for what they already do well:

- Docker runs app and database containers.
- Caddy handles routing, static file serving, and automatic HTTPS.
- systemd keeps Valpo API and worker processes alive.
- SQLite stores local Valpo metadata.
- Filesystem directories hold immutable releases, uploads, backups, and snapshots.

## Managed Services Philosophy

Valpo should support arbitrary containers, but curated managed services should be the primary experience for common infrastructure.

Examples:

- Postgres
- MariaDB
- Redis
- named persistent volumes
- object-storage credentials later

A user should be able to create a database with friendly settings instead of manually defining Docker images, volumes, environment variables, ports, credentials, and connection strings.

Example:

```bash
valpo services:create main-db --type postgres --project myapp --plan small
valpo services:bind myapp main-db
```

Valpo should provision the container, create credentials, create the volume, attach it to the right Docker network, generate connection configuration, inject the binding into the app, and include the service in backup/export/import workflows.

Advanced users can still run custom containers or manually set environment variables, but that is the escape hatch rather than the default path.

## Extensibility Philosophy

Valpo should keep clean internal extension points from the beginning, but it should not ship a public plugin marketplace in the first versions.

Initial extension seams:

- source adapters
- build adapters
- service definitions
- service provisioners
- backup targets
- notification sinks
- lifecycle subscribers

These should start as internal Ruby interfaces used by built-in features. Once the contracts stabilize, they can become public plugin APIs.

Prefer typed events and structured payloads over arbitrary shell hooks. Plugins should not mutate Docker, Caddy, or Valpo state behind the control plane.

## Source To Release Model

Every deployment path should normalize into the same lifecycle:

```text
source -> build or fetch -> release artifact -> deploy -> route traffic -> monitor
```

Supported source adapters:

```text
Valpo::Sources::Registry
Valpo::Sources::GitHub
Valpo::Sources::GitLab
Valpo::Sources::StaticUpload
```

All adapters should produce a release. This keeps deploy logic consistent across registry images, Git repositories, and uploaded static zips.

## Project Model

Initial domain objects:

```text
Project
  id
  name
  type: container or static
  status
  created_at
  updated_at

Service
  id
  project_id
  name: web, worker, etc.
  image
  command
  internal_port
  healthcheck
  scale

Release
  id
  project_id
  version
  source_type
  source_ref
  artifact_ref
  image_digest
  status
  activated_at
  created_at

Domain
  id
  project_id
  hostname
  route_target
  tls_status

EnvironmentVariable
  id
  project_id
  key
  encrypted_value
  scope
  managed_by

Resource
  id
  project_id
  type: postgres, mariadb, redis, volume, custom_container
  name
  version
  plan
  status
  config_json
  created_at
  updated_at

ResourceBinding
  id
  project_id
  resource_id
  status
  env_json
  created_at

ResourceCredential
  id
  resource_id
  name
  encrypted_value_json
  created_at

Job
  id
  type
  status
  payload_json
  progress
  error
  locked_by
  locked_at
  started_at
  finished_at
  created_at

JobEvent
  id
  job_id
  stream: stdout, stderr, system
  message
  created_at
```

For the first version, support one `web` service per project. Workers, scheduled jobs, and multiple process types can come later.

## Background Jobs

All long-running work should be asynchronous:

- deployments
- Docker builds
- image pulls
- static zip extraction
- backups
- restores
- project export/import
- managed service provisioning
- service binding and credential rotation
- domain certificate checks

The API creates a job and returns a job id. The worker locks and executes queued jobs. The UI and CLI poll or stream job status and events.

Initial job states:

```text
queued
running
succeeded
failed
canceled
```

For v1, a SQLite-backed queue is enough:

- A single worker process polls for queued jobs.
- Jobs are locked with `locked_by` and `locked_at`.
- The worker writes structured events.
- A stuck job can be detected by stale lock timestamps.
- Limit deployment/build concurrency to one at first.

This keeps Valpo dependency-light and makes job state inspectable.

## Deployment Flows

### Docker Registry Deployment

```text
1. User submits image reference.
2. API creates deployment job.
3. Worker pulls image.
4. Worker records image digest.
5. Worker creates release.
6. Worker starts replacement container.
7. Worker waits for health check.
8. Worker updates Caddy route.
9. Worker marks release active.
10. Worker stops old container after drain period.
```

This should be the first dynamic-app deployment path because it avoids Git provider complexity.

### GitHub/GitLab Deployment

```text
1. User connects repository.
2. User chooses branch and build settings.
3. Valpo installs webhook or receives deploy trigger.
4. Worker clones or fetches the repo.
5. Worker builds Docker image using Dockerfile.
6. Worker tags image with project and commit SHA.
7. Worker creates release from image digest.
8. Standard container deploy flow runs.
```

Start with Dockerfile builds only. Buildpacks can be added later.

### Static Zip Deployment

```text
1. User uploads zip through dashboard or CLI.
2. API stores upload and creates deployment job.
3. Worker validates zip contents.
4. Worker extracts into immutable release directory.
5. Worker creates release.
6. Worker updates Caddy file_server route.
7. Worker marks release active.
```

Static sites should be served directly by Caddy rather than wrapped in containers.

### Managed Service Provisioning

```text
1. User chooses a service type and friendly settings.
2. API creates a service provisioning job.
3. Worker resolves defaults from the service catalog.
4. Worker creates volume, network attachment, credentials, and container.
5. Worker waits for service readiness.
6. Worker records service metadata and credentials.
7. Optional binding job injects generated connection settings into the app.
8. Worker restarts or redeploys the app if needed.
```

The service catalog should hide low-level Docker details for common resources while preserving an advanced override path.

## Caddy Integration

Caddy should be the default proxy and static file server.

Valpo should store routing intent in SQLite and generate/apply Caddy config from that source of truth.

Routing examples:

- Dynamic app: hostname -> container internal network address and port.
- Static site: hostname -> immutable release directory with Caddy `file_server`.

Avoid storing raw hand-edited Caddy config as the primary model. Store Valpo's intended routes and generate config from that.

## Docker Integration

Initial implementation can use the Docker CLI through a strict wrapper. Favor structured output and explicit error handling.

Examples:

- `docker pull`
- `docker image inspect`
- `docker run`
- `docker stop`
- `docker rm`
- `docker logs`
- `docker build`
- `docker network create`
- `docker volume create`

Move to a Docker API client later only if it reduces complexity.

## Filesystem Layout

Suggested host layout:

```text
/var/lib/valpo/
  valpo.db
  uploads/
  releases/
    projects/
      <project-id>/
        releases/
          <release-id>/
  backups/
  exports/
  build-cache/

/etc/valpo/
  valpo.yml
  secrets.key

/var/log/valpo/
  api.log
  worker.log
```

Static releases should be immutable directories. Activation should be a metadata and routing change, not in-place mutation.

## Security Model

The Valpo API should not default to being a casually exposed public endpoint.

Recommended access modes:

- Localhost-only API with CLI over SSH tunnel.
- Private network access through WireGuard or Tailscale.
- Optional public HTTPS API with strong authentication.
- Optional mTLS for dashboard-to-server communication.

API tokens should be scoped and revocable.

Secrets should be encrypted at rest using a host-local key from `/etc/valpo/secrets.key`.

The dashboard should store server connection metadata, but each server should own its own secrets and runtime state.

## Dashboard Role

The dashboard aggregates and operates independent servers:

- server inventory
- project list per server
- deploy actions
- logs and job status
- static-site upload
- GitHub/GitLab connection flows
- backup and restore actions
- export/import flows

It should not be required for existing apps to keep running.

## Migration Model

Migration should be modeled as export/import.

A project export can include:

- project manifest
- services and image references
- managed resource manifests
- resource bindings
- release metadata
- domains
- encrypted env vars
- database dumps
- volume snapshots
- static release directories
- optional Docker image archive

Target import should validate capabilities before applying:

```text
Can restore Postgres version?
Can provision the requested managed service types?
Can pull or load required image?
Are required ports available?
Are domains already assigned?
Are secrets importable?
Is there enough disk space?
```

Avoid default server-to-server communication. Direct transfer can be a later explicit migration mode, but the base model should work through a local file or object storage bridge.

## Operational Requirements

Valpo should make these operations first-class:

- install
- upgrade
- backup Valpo metadata
- restore Valpo metadata
- inspect jobs
- cancel jobs
- restart API/worker
- regenerate Caddy config
- verify Docker and Caddy health
- rotate API tokens
- provision managed service
- bind managed service to project
- rotate service credentials
- export project
- import project

## Initial MVP Boundary

The first credible slice:

```text
install Valpo on one VPS
create project
deploy Docker image
add domain
serve through Caddy
view logs
view releases
rollback release
run all long operations as jobs
```
