# Valpo Roadmap

## Roadmap Philosophy

Build from the smallest useful self-contained VPS platform outward. Avoid starting with GitHub/GitLab, managed database features, or the multi-server dashboard until the local server deploy lifecycle is solid.

The first milestone should prove that Valpo can reliably take an artifact, run it, route traffic to it, show logs, and roll it back. The next product-defining milestone is managed services that feel like Heroku add-ons rather than raw container setup.

## Phase 0: Architecture And Scaffold

Goal: create the project skeleton and validate the local host model.

Status: implemented as the initial Ruby scaffold. The current repository has the Roda API skeleton, Sequel/SQLite migrations, SQLite-backed job runner, worker, CLI, config loading, Docker/Caddy wrapper boundaries, and systemd/config templates.

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

Goal: deploy a prebuilt Docker image to one VPS and route HTTP traffic to it.

Status: next implementation phase.

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
- Stop/restart project.

Example target flow:

```bash
valpo projects:create hello
valpo deploy hello --image ghcr.io/example/hello:latest --port 3000
valpo domains:add hello hello.example.com
valpo logs hello
valpo releases hello
valpo rollback hello
```

Exit criteria:

- A user can deploy an existing container image behind HTTPS.
- A failed deploy does not break the currently active release.
- Rollback works without rebuilding.

## Phase 2: Static Sites

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

## Phase 3: GitHub And GitLab Deployments

Goal: connect repositories and build/deploy on demand or webhook push.

Deliverables:

- GitHub repository connection.
- GitLab repository connection.
- Branch selection.
- Manual deploy from branch or commit SHA.
- Webhook endpoint.
- Dockerfile build job.
- Build logs.
- Image tagging by project and commit.
- Release created from built image digest.

Initial constraint:

- Support Dockerfile builds only.
- Defer buildpacks until the Dockerfile path is reliable.

Exit criteria:

- A user can connect a GitHub or GitLab repo and deploy a branch.
- Push webhooks can enqueue deployment jobs.
- Failed builds leave the active release untouched.

## Phase 4: Resources And Backups

Goal: manage common single-server resources through high-level, Heroku-style service flows.

Deliverables:

- Built-in service catalog.
- Friendly plans and defaults.
- Postgres managed service.
- MariaDB managed service.
- Redis managed service.
- Named volume resource.
- Attach resource to project.
- Bind resource to project.
- Generate and inject managed connection settings.
- Rotate service credentials.
- Manual backups.
- Scheduled backups.
- Restore from backup.
- Backup retention policy.

Exit criteria:

- A project can be deployed with a managed Postgres container.
- A user can add Postgres without manually setting `DATABASE_URL`.
- Backups and restores are visible as jobs with logs.
- Backup artifacts are stored predictably.

## Phase 5: Project Export And Import

Goal: make migration between servers understandable and robust.

Deliverables:

- Project manifest format.
- Export project bundle.
- Import project bundle.
- Export database dumps.
- Export volume snapshots.
- Export static releases.
- Optional Docker image archive.
- Import preflight validation.
- Import dry run.

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

- Buildpacks.
- Scheduled jobs.
- Worker process types.
- Multiple services per project.
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
