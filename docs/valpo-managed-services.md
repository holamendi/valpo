# Valpo Managed Services

Valpo treats curated infrastructure as the normal path and raw containers as a future escape hatch. Postgres and Redis are implemented today as private, project-owned services with persistent runtime state and explicit app bindings.

## Implemented Behavior

### Definitions And Creation

`Valpo::Services::Registry` contains one definition object for each supported service type. Web, worker, Postgres, and Redis definitions declare their supported options. Managed definitions additionally own version selection, image, readiness command, runtime environment, credentials, volume path, and binding environment.

`Valpo::Services::Creator` is the single record-creation path used by the API, manifest reconciliation, and source-backed service configuration. Unsupported and type-incompatible options are rejected rather than silently ignored.

Supported managed versions:

| Type | Versions | Default image |
| --- | --- | --- |
| Postgres | `16`, `17`, `18` | `postgres:18-alpine` |
| Redis | `7`, `8` | `redis:8-alpine` |

Images are selected by Valpo and cannot be overridden through the managed-service API.

### Runtime

`Services::ManagedLifecycle` provisions, restarts, stops, deletes, repairs, and reads logs for managed containers. `Services::Runtime` performs the low-level Docker work.

Implemented runtime guarantees:

- one private container on the shared `valpo` Docker network;
- no public host port;
- a persistent Docker volume;
- generated credentials and connection information;
- type-specific readiness polling;
- `unless-stopped` restart policy;
- reconciliation of stopped or missing containers through `System::Repairer`;
- explicit `force=true` confirmation before deletion;
- removal of the container, volume, and dependency records during deletion.

Projects are grouping boundaries. Each app and managed service has its own `svc_` identity and a name unique within its project. Project deletion is refused until all services have been removed.

### Bindings

`Services::DependencyManager` owns binding and unbinding. A binding is explicit, stays within one project, and affects one app service only. Binding requires the managed service to be running and rejects generated environment keys that would collide with another dependency.

Postgres bindings generate:

```text
DATABASE_URL
PGHOST
PGPORT
PGDATABASE
PGUSER
PGPASSWORD
```

Redis bindings generate:

```text
REDIS_URL
REDIS_HOST
REDIS_PORT
REDIS_PASSWORD
```

An app with an active release is restarted after a binding changes so its generated environment reflects the new dependency set. `valpo service env SERVICE --project PROJECT` redacts secret values; `--reveal` displays them on the host.

### CLI And Manifest Surface

```bash
valpo service create database --project myapp --type postgres --version 18
valpo service create cache --project myapp --type redis --version 8
valpo service bind web database --project myapp
valpo service env web --project myapp
valpo service restart database --project myapp
valpo service delete database --project myapp --force
```

The unchanged `valpo.toml` schema can declare Postgres and Redis services and app `depends_on` edges. `Manifests::Planner` previews changes without mutation; `Manifests::Reconciler` applies add/update-only changes through the same creator and lifecycle collaborators used elsewhere.

## Current Security Gap

Managed credentials are generated with cryptographically secure randomness and written to the local SQLite database, but they are not encrypted at rest. Filesystem permissions and host access are the present protection. Host-key-backed encryption, key rotation, and migration behavior are near-term security work tracked in the [roadmap](./valpo-roadmap.md); documentation must not claim encrypted storage until that work ships.

## Future Work

The following are intentionally not implemented:

- MariaDB, MySQL, and additional managed definitions;
- backup, restore, and retention scheduling;
- project export/import of dumps, snapshots, credentials, and dependency metadata;
- credential rotation;
- descriptive or enforced resource plans;
- storage resizing and first-class volume resources;
- public database exposure;
- arbitrary custom service containers;
- automatic app binding at creation time;
- dashboard service-management flows.

MariaDB, backups, exports, and encrypted managed credentials are roadmap work, not “v1 behavior.” New definitions should be added only after their lifecycle, readiness, binding, deletion, repair, and eventual backup semantics can be supported coherently.
