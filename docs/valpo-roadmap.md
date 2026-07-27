# Valpo Roadmap

## Roadmap Philosophy

Build from the smallest useful self-contained VPS platform outward. Avoid starting with GitHub/GitLab, static-site expansion, or the multi-server dashboard until the single-server deploy lifecycle and managed-service foundation are solid and repeatably operable.

The first milestone should prove that Valpo can reliably take an artifact, run it, route traffic to it, show logs, roll it back, survive routine host operations, and clean up after itself. The next product-defining milestone is managed services that feel like Heroku add-ons rather than raw container setup.

## Phase 0: Architecture And Scaffold

Goal: create the project skeleton and validate the local host model.

Status: implemented. The repository has the Roda API, Sequel/SQLite migrations, SQLite-backed job runner, worker, CLI, config loading, Docker/Caddy boundaries, and systemd/config templates. A pre-release foundation pass added `/v1`, strict `dry-validation` request contracts, versioned resource renderers, an OpenAPI 3.1 mirror, exact routes, stable errors, cohesive production boundaries, and synchronized documentation.

Deliverables:

- Ruby project structure.
- Roda API skeleton.
- Sequel and SQLite setup.
- Initial migrations.
- systemd unit templates.
- Basic config file format.
- Docker CLI wrapper.
- Caddy config/apply wrapper.
- SQLite-backed job table.
- Worker process skeleton.
- CLI skeleton.

Exit criteria:

- API and worker can run locally.
- A job can be enqueued, executed, and inspected.
- SQLite schema is migrated reproducibly.

## Phase 1: Single-Server Container Deploy MVP

Goal: deploy a prebuilt Docker image to one VPS, route HTTPS traffic to it, and make the server safe to operate repeatedly.

Status: complete.

### Phase 1A: Container Deploy Path

Status: complete.

Deliverables:

- Create project.
- Deploy from Docker image reference.
- Pull image and record digest.
- Start container.
- Basic health check.
- Configure Caddy route.
- Add/remove/list domains.
- Store release history.
- Roll back to previous release.
- Stream or retrieve deployment logs.
- Retrieve app logs.
- Stop/restart individual services.
- Installer creates an operator-friendly `valpo` CLI command on `PATH`.

Example target flow:

```bash
valpo project create hello
valpo service create web --project hello --type web --port 3000
valpo service deploy web --project hello --image ghcr.io/example/hello:latest
valpo domain add web hello.example.com --project hello
valpo service logs web --project hello
valpo release list web --project hello
valpo release rollback web --project hello
```

Exit criteria:

- A user can deploy an existing container image behind HTTPS.
- A failed deploy does not break the currently active release.
- Rollback works without rebuilding.
- Core install/deploy/domain/log/release operations work from the installed CLI on a fresh Ubuntu VPS.

### Phase 1B: Single-Server Operability

Status: complete. Project deletion cleanup, default synchronous CLI operations, advanced `job wait`, `system repair` for Caddy regeneration plus active-container Docker reconciliation, reboot verification, private API defaults, token-gated non-local API binding, and repeatable VPS smoke testing are implemented.

Deliverables:

- Delete project and clean up its active container, domains, releases, and generated routes.
- Add `job wait JOB_ID` for troubleshooting and synchronous deploy/domain commands with timeouts and useful exit codes.
- Verify active apps after host reboot.
- Reconcile Valpo metadata with Docker and Caddy state on startup or through an explicit repair command.
- Regenerate Caddy config from SQLite state and reload Caddy.
- Keep the API private by default and add token-based API authentication before any non-local API exposure.
- Add a repeatable VPS smoke test for install, deploy, domain, HTTPS, logs, reboot, and cleanup.

Exit criteria:

- A fresh VPS can install Valpo, deploy `nginx:alpine`, add a public HTTPS domain, reboot, and continue serving the app.
- A test project can be deleted without leaving containers, routes, or domains behind.
- Long-running CLI workflows can wait for completion and fail with non-zero status on job failure or timeout.
- The Valpo control API is not publicly reachable unless explicit authentication has been configured; narrowly scoped provider callbacks use protocol-specific authentication.
- The smoke test can be rerun on the same host without manual cleanup.

## Phase 2: Managed Services And Unified Project Foundation

Goal: make Postgres and Redis feel like Heroku-style add-ons instead of raw container setup.

Status: implemented. Phase 2A introduced private Postgres and Redis services. Phase 2B changed projects into grouping boundaries containing multiple app and managed services.

Start this phase only after Phase 1B is complete.

Deliverables:

- Built-in service registry with one definition object per supported type.
- Service records and lifecycle jobs.
- Private Docker runtime for service containers.
- Persistent Docker volumes for stateful services.
- Postgres managed service.
- Redis managed service.
- Supported version catalog: Postgres `16`, `17`, `18`; Redis `7`, `8`.
- Curated defaults.
- Generate service credentials and connection URLs.
- Shared service identity with typed UUIDv7 IDs.
- App-service kinds `web` and `worker`, plus managed `postgres` and `redis` kinds.
- Project-scoped service names addressed with `SERVICE --project PROJECT` by the CLI.
- Explicit app-to-managed-service dependencies.
- Inject managed environment values only into dependent app services.
- Restart or redeploy affected apps after binding.
- Strict `valpo.toml` project manifest with dry-run and add/update-only reconciliation.
- GitHub source and image build-target metadata, initially stored as unconnected configuration.
- Health checks and readiness polling for service containers.
- Refuse project deletion while any services remain.

Exit criteria:

- A project can contain multiple app services and managed dependencies.
- A user can add Postgres without manually setting `DATABASE_URL`.
- An app service can depend on Redis without manually assembling a Redis URL.
- Managed service containers survive host reboot and are repaired by the same operability path as apps.
- Services are private by default and do not expose public ports.
- Services can be deleted with explicit confirmation, removing their containers and volumes before project cleanup.

## Near-Term Foundation And Security

Goal: close the known security and operational gaps before expanding the product surface.

Status: storage foundation implemented; operational rotation and recovery workflows remain.

Deliverables:

- Encrypt managed-service credential JSON and per-service environment values at rest with a host-local key. Implemented.
- Store GitHub App secrets and fallback PATs in the same encrypted credential store. Implemented.
- Derive dependency environment from encrypted managed credentials instead of persisting duplicate secret JSON. Implemented.
- Generate a private, versioned host keyring and document that it must be backed up with SQLite. Implemented.
- Define credential migration behavior for future export/import.
- Replace the single host-wide bearer token with scoped, revocable, digest-only API credentials. Implemented.
- Add operator-facing host-key rotation, bulk re-encryption, recovery verification, and safe token-rollover workflows.
- Keep dependency, deployment, domain, Caddy, and system repair boundaries covered by characterization tests as internals evolve.

The root keyring intentionally remains outside SQLite so possession of the database alone is insufficient to decrypt secrets. Backups must include both artifacts under separate access controls; losing the keyring makes encrypted records unrecoverable.

## Phase 3A: GitHub Integration And Source Deployments

Goal: connect repositories and build/deploy on demand or webhook push.

Bootstrap implemented:

- CLI-managed, encrypted fine-grained PAT authentication for GitHub HTTPS fetches.
- Per-server GitHub App creation through a one-time manifest flow on `github.<app-domain>`.
- Encrypted database storage of the generated App key and webhook secret, with repository-scoped short-lived installation tokens for source fetches.
- HMAC-verified, delivery-deduplicated push webhooks that enqueue matching `auto_deploy` source jobs.
- Manifest-free source service creation and source/build/runtime updates through the public CLI.
- Mandatory repository/ref/path preflight with exact commit resolution before configuration changes.
- Service-owned source/build definitions, with detachment from shared manifest definitions on CLI updates.
- Manual deploy from the configured branch or an explicit branch, tag, or commit SHA.
- Dockerfile build logs, commit-based image tags, and git-backed releases.
- Automatic Dockerfile/buildpack selection, explicit build strategies, pinned Paketo builds, per-target caches, timeouts, and release build metadata.
- Automatic web-port resolution from explicit configuration, image `EXPOSE`, or the source-build port-3000 fallback.
- Failed fetches leave configuration untouched; failed builds and health checks record failed releases and leave an active release untouched.

Remaining deliverables:

- Multi-App credentials for servers that deploy repositories belonging to more than one GitHub account or organization.
- Multi-record key rotation and bulk re-encryption tooling.
- A product decision on whether the encrypted PAT fallback remains supported after the GitHub App path is proven across installations.

Current build constraint:

- Support Dockerfile and Cloud Native Buildpacks builds that produce a local Docker image.
- Defer custom builders per project, build secrets, Railpack, static output detection, and image rebase.

Exit criteria:

- A user can connect a private GitHub repo and deploy a branch.
- Push webhooks can enqueue deployment jobs.
- Failed builds leave the active release untouched.

## Phase 3B: Additional Source Providers

Goal: add GitLab and other source adapters after the GitHub build path is stable.

Deliverables:

- GitLab repository connection and webhooks.
- Provider-neutral source credentials and events.
- Equivalent build/release behavior across supported providers.

## Phase 4: Static Sites

Goal: support static-site hosting as a first-class path.

Deliverables:

- Static project type.
- Zip upload endpoint.
- CLI upload command.
- Safe zip validation.
- Immutable release directory extraction.
- Caddy static file routing.
- Static release rollback.
- Dashboard drag-and-drop prototype.

Exit criteria:

- A user can upload a zipped `dist` folder and serve it through a custom domain.
- Rollback between static releases works.
- Static hosting does not require a container.

## Phase 5: Project Export And Import

Goal: make migration between servers understandable and robust.

Deliverables:

- Export the existing project manifest with runtime state references.
- Export project bundle.
- Import project bundle.
- Export database dumps.
- Export volume snapshots.
- Export static releases.
- Optional Docker image archive.
- Import preflight validation.
- Import dry run.
- MariaDB only after its definition, readiness, binding, backup, restore, and export semantics are specified and tested.

Exit criteria:

- A user can export a project from one server and import it into another.
- Import reports missing capabilities before making changes.
- Imported projects can be started and routed on the target server.

## Phase 6: Multi-Server Dashboard

Goal: manage multiple independent Valpo servers from one web UI.

Deliverables:

- Dashboard app.
- Server registration.
- Server health overview.
- Project list grouped by server.
- Deploy actions against a selected server.
- Job/log views.
- Static upload UI.
- Domain management UI.
- Export/import UI.
- Token management.

Architecture rule:

- The dashboard operates servers through their APIs.
- The dashboard is not required for apps to keep running.
- Servers do not coordinate with each other.

Exit criteria:

- A user can manage at least two independent Valpo servers from one dashboard.
- Losing dashboard access does not affect running apps.

## Phase 7: Polish And Extensibility

Goal: improve usability and add carefully chosen advanced features.

Potential deliverables:

- Scheduled jobs.
- Preview deployments.
- Object storage backup target.
- Direct migration transfer mode.
- GitHub/GitLab deploy status checks.
- Role-based access control.
- Audit log.
- Server upgrade UI.
- App templates.
- Internal extension interfaces promoted to stable APIs.
- Typed lifecycle hooks.
- Webhook notification sink.
- Custom backup targets.
- Third-party service definitions.
- Additional curated services such as MariaDB, only with complete lifecycle and data-portability behavior.

## Features To Delay

These should remain out of early scope:

- Multi-node orchestration.
- Automatic horizontal scaling across servers.
- Kubernetes compatibility.
- Plugin marketplace.
- Feature parity with Coolify or Dokploy.
- Full CI pipeline features.
- Complex network overlays.
- Server-to-server cluster state.
