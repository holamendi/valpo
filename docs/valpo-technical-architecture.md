# Valpo Technical Architecture

## Current System

Valpo is a self-contained control plane for one VPS. It exposes a Roda JSON API, stores metadata in SQLite through Sequel, runs long operations through a SQLite-backed worker, and delegates runtime concerns to Docker, Caddy, systemd, and the host filesystem.

```text
CLI / future dashboard
          |
          | HTTP API v1
          v
      Valpo API ----> SQLite
          |
          | enqueue / inspect
          v
      Valpo Worker
          |
          +----> Docker containers, images, networks, volumes
          +----> Caddy routes and TLS
```

Every server owns its state and keeps running without a dashboard or another Valpo server. Server-to-server coordination is not part of the model. The dashboard remains a future API client, not an owner of runtime state.

Current host stack:

- Ruby 4.0, Roda, Sequel, SQLite, Puma, and Zeitwerk;
- a custom SQLite-backed job queue and one worker process;
- Docker Engine through a strict CLI wrapper;
- Cloud Native Buildpacks through pinned `pack` and Paketo builder versions;
- Caddy through generated configuration and an explicit reload boundary;
- systemd units and Ubuntu packaging;
- a bundled Ruby CLI built with `dry-cli`.

The public HTTP surface and validation boundary are described in the [API guide](./valpo-api.md) and [OpenAPI document](./openapi.yaml).

## Architecture Rules

1. Each VPS owns its metadata, secrets, jobs, and runtime state.
2. The dashboard is optional for runtime survival.
3. Long-running work executes as a job, not in an API request.
4. Every deployment input becomes a release.
5. Docker runs dynamic apps and managed services; Caddy owns public routing.
6. SQLite is the control-plane metadata store.
7. Generated Docker and Caddy state is projected from Valpo records.
8. Managed services are the curated path; custom containers are a later escape hatch.
9. Internal extension seams may evolve, but no public plugin contract exists yet.
10. Cohesive low-level Docker and build-pipeline classes remain intact when splitting them would only add indirection.

## Runtime Boundaries

### API

`API::App` is a thin Roda transport layer. The JSON parser handles transport parsing; one `dry-validation` contract owns each body or query shape. `API::RequestHelpers` only invokes a contract and maps dry errors into stable API details. Under `API::V1`, each public resource module keeps its small named contracts beside plain hash-rendering functions. Routes enqueue jobs or call record-oriented collaborators, then delegate response construction to those versioned modules.

Every resource operation is under `/v1`; `GET /` and `GET /health` are unversioned. Terminal routes are exact, and Roda's not-found handler produces JSON for unknown paths and trailing segments.

### Jobs

`Jobs::Worker` only polls, locks, invokes, and records completion. `Jobs::HandlerRegistry` is the worker composition root. One handler class exists for each queue operation, and registry coverage is checked against `Jobs::Queue::SUPPORTED_TYPES`.

Implemented job states are:

```text
queued
running
succeeded
failed
```

There is no canceled state, cancellation operation, lease, or automatic replay. At startup, the worker marks jobs left in `running` as failed with a manual-retry event. A non-blocking file lock beside the SQLite database enforces exactly one worker for that database; multi-worker execution is not implemented.

### Deployments, Domains, Routing, And Repair

- `Deployments::Lifecycle` owns deploy, rollback, stop, restart, reconfigure, delete, and app-log behavior.
- `Deployments::Activator` switches routes, activates releases, and retires prior containers.
- `Deployments::Repairer` reconciles active and ready app containers.
- `Storage::Maintainer` serializes ownership-scoped image, build-cache, orphan-container, and history retention through the normal worker queue.
- `Domains::Orchestrator` verifies platform/custom domains and activates ready releases.
- `Caddy::Reconciler` projects verified domain/release state into generated Caddy configuration.
- `System::Repairer` coordinates managed-service repair, app repair, and Caddy reconciliation.

A web release may build and pass health checks without a verified hostname. It remains private in `ready`; verifying a generated or custom domain activates it. Worker releases activate without domains. A failed deploy records a failed release and leaves the current active release untouched.

### Services

- `Services::Registry` maps service kinds to definition objects for web, worker, Postgres, and Redis.
- `Services::Creator` is the single record-creation path.
- `Services::ManagedLifecycle` owns managed container operations.
- `Services::RedisHostRequirements` validates the installer-owned kernel prerequisite before Redis starts.
- `Services::DependencyManager` owns bind and unbind behavior.
- `Services::Runtime` contains cohesive low-level managed Docker behavior.

Each definition declares its supported options. Managed definitions also declare versions, image, runtime environment, readiness command, credentials, volume path, and binding environment. See [managed services](./valpo-managed-services.md).

### Sources, Builds, And Manifests

GitHub HTTPS fetches prefer short-lived, repository-scoped installation tokens minted by a per-server GitHub App behind `Sources::Fetcher`; an encrypted fine-grained PAT remains available as a fallback. Repository/ref/strategy/context preflight resolves an exact commit and chooses Dockerfile or buildpack execution before source-backed configuration mutates. `Builds::Orchestrator` serializes builds per target and dispatches to a Dockerfile or Cloud Native Buildpacks backend. Both backends stream output, share a build timeout, and produce release build metadata.

The App is created through GitHub's manifest flow. After wildcard app-domain verification, Caddy reserves `github.<app-domain>` and proxies only `/integrations/github` to the local API. One-time setup state protects the manifest callback, the generated private key and webhook secret are encrypted in SQLite with the mode-`0600` host keyring, and installation redirects are checked with an App JWT. Signed `push` events are deduplicated by delivery ID and enqueue exact-commit deploy jobs for matching `auto_deploy` sources.

The manifest creates one private App owned by either a personal account or one selected organization. Valpo intentionally supports one App per server. An encrypted fine-grained PAT is the alternative credential mode when one server must fetch repositories outside a single App owner's scope; multi-App credentials are not planned.

`Manifests::Planner` computes preview actions without mutation. `Manifests::Reconciler` applies the unchanged `valpo.toml` schema through service creation, managed lifecycle, dependency, and deployment collaborators. Omitted resources are retained.

## Source-To-Release Model

Every deployment normalizes to:

```text
source or registry image
        -> build/pull and inspect
        -> release record
        -> replacement container
        -> health check
        -> ready or active
        -> route switch
        -> retire prior container
```

Current inputs are registry images and GitHub source builds. Source build targets support `auto`, `dockerfile`, and `buildpack`; `auto` uses a context-root Dockerfile when present and otherwise selects buildpacks. GitLab and static uploads are proposed inputs, not implemented adapters.

## Data Model

Implemented tables:

```text
projects
sources
build_targets
services
app_service_configs
managed_service_configs
service_dependencies
service_environment_variables
releases
platform_domains
domains
provider_credentials
api_credentials
control_plane_states
github_app_setups
github_webhook_deliveries
jobs
job_events
```

Important ownership and field conventions:

- `Project` is a grouping boundary with a manifest digest and last-applied timestamp.
- `Source` and `BuildTarget` belong to a project and may have an `owner_service_id` for CLI-owned configuration.
- `Service.kind` is `web`, `worker`, `postgres`, or `redis`; app/managed details live in one-to-one configuration tables.
- `AppServiceConfig` stores `build_target_id`, command JSON, nullable `internal_port`, and nullable `healthcheck_path`.
- `ManagedServiceConfig` stores version, image, runtime names/address, port, and encrypted credential JSON.
- `ServiceDependency` links one app service to one managed service; its environment is derived from the dependency at runtime.
- `ServiceEnvironmentVariable` stores a custom app-service key, encrypted value, sensitivity flag, and timestamps.
- `Service` and `Release` carry environment revisions so reconciliation can identify a stale running release.
- `Release` stores source/artifact identity, resolved build strategy and metadata, runtime configuration, container/route identity, state, and activation time.
- `Domain` stores custom or generated hostname verification and projected route state.
- `PlatformDomain` stores the active or candidate wildcard base and verification state.
- `GitHubAppSetup` stores expiring one-time setup state; `GitHubWebhookDelivery` stores delivery IDs and payload digests for replay protection.
- `ProviderCredential` stores encrypted provider payloads plus non-secret public metadata.
- `APICredential` stores a token prefix, one-way digest, scopes, revocation/expiry state, and usage timestamps.
- `ControlPlaneState` persists one-way security boundaries such as completion of local API bootstrap; bootstrap never reopens merely because credentials are unavailable.
- `Job` stores type, payload, progress, error, lock, start, finish, and creation state; `JobEvent` stores stdout/stderr/system messages.

Typed IDs (`prj_`, `svc_`, and related prefixes) are immutable identities. The CLI accepts service names scoped by project for people and IDs for unambiguous automation.

## Docker And Caddy

The Docker wrapper constructs explicit command arrays and consumes structured inspect output. App and managed containers share the `valpo` network and carry deterministic ownership labels:

```text
valpo.managed
valpo.owned
valpo.project_id
valpo.release_id
valpo.service_id
```

Valpo stores routing intent in SQLite. `Caddy::Reconciler` renders only verified, running web routes with a valid active target, writes generated configuration, reloads Caddy, and records projected targets. Raw hand-edited Caddy configuration is not the source of truth.

## Filesystem Layout

Implemented packaging uses the following durable roots:

```text
/var/lib/valpo/
  valpo.db
  secrets/
    master.key
  caddy/
    valpo.caddy

/etc/valpo/
  valpo.yml

/etc/sysctl.d/
  99-valpo-redis.conf
```

The Redis sysctl file persists `vm.overcommit_memory=1`; the installer applies it with root privileges and the unprivileged worker only verifies the effective `/proc` value. The API, worker, and migration service log to the systemd journal. The packaging creates `/var/log/valpo` through `LogsDirectory`, but no current process writes `api.log` or `worker.log` files there.

Build-target locks live beside the SQLite database. Buildpack build and launch caches are deterministic Docker volumes rather than host directories. Uploads, immutable static releases, backups, and exports are proposed future directories. They must not be documented as implemented until their owning features exist.

## Security: Implemented And Proposed

Implemented today:

- localhost API binding by default;
- refusal to bind non-locally without an active API credential;
- scoped, revocable API credentials stored as one-way SHA-256 digests and compared in constant time;
- strict JSON/query validation and generic client-facing 500 errors;
- private Docker networking for managed services;
- AES-256-GCM encryption for managed credentials, per-service environment values, GitHub App secrets, and fallback PATs;
- per-record authenticated additional data and versioned encryption envelopes;
- a mode-`0600` host keyring outside SQLite, generated under the private secrets directory;
- an encrypted GitHub App key and webhook secret used for short-lived installation credentials;
- HMAC verification and delivery-ID deduplication for the public GitHub webhook;
- an encrypted GitHub PAT fallback kept out of jobs, manifests, sources, builds, and releases;
- redaction of sensitive custom and managed environment values unless explicitly revealed.

Known gaps and proposed behavior:

- Operator-facing verification and key rotation re-encrypt every encrypted record transactionally and retain old key versions; destructive key pruning is not implemented.
- The SQLite database and host keyring must be backed up together; no first-class backup workflow enforces that yet.
- mTLS and first-class private-network/dashboard enrollment are not implemented.
- Audit logs, role-based access control, and secret migration policies are future work.

The root key intentionally cannot be stored in the database it protects. Moving non-secret boot settings such as database path, API bind address, Docker network, and runtime timeouts into SQLite would also create a bootstrap cycle, so they remain in `/etc/valpo/valpo.yml`.

## Future Boundaries

The export/import model, backups, static releases, additional source providers, dashboard, and public extension API remain future work. Export/import should validate target capabilities before mutation and should not require server-to-server coordination. Internal source, definition, backup-target, notification, and lifecycle boundaries may become public only after their contracts stabilize.
