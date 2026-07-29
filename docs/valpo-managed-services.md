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

- installer-owned `/etc/sysctl.d/99-valpo-redis.conf` with an effective `vm.overcommit_memory=1`;
- validation of that host prerequisite before Redis provisioning, restart, or repair starts a container;
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

The root installer owns the privileged Redis host configuration. The unprivileged worker only reads `/proc/sys/vm/overcommit_memory`; it refuses to start a Redis container with a clear validation error when the effective value is not `1`. Uninstall removes Valpo's sysctl configuration file without changing the live kernel value.

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

An app with an active release is restarted after a binding changes so its effective environment reflects the new dependency set. Binding values are derived from the managed service's encrypted credentials instead of being stored on the dependency record. `valpo service env list SERVICE --project PROJECT` redacts secret values; `--reveal` displays them on the host.

### CLI And Manifest Surface

```bash
valpo service create database --project myapp --type postgres --version 18
valpo service create cache --project myapp --type redis --version 8
valpo service bind web database --project myapp
printf %s "$VALUE" | valpo service env set web FEATURE_FLAG --project myapp --plain
valpo service env list web --project myapp
valpo service restart database --project myapp
valpo service delete database --project myapp --force
```

The unchanged `valpo.toml` schema can declare Postgres and Redis services and app `depends_on` edges. `Manifests::Planner` previews changes without mutation; `Manifests::Reconciler` applies add/update-only changes through the same creator and lifecycle collaborators used elsewhere.

### Encrypted Credentials And Environment

Managed credentials and custom per-service environment values are encrypted with AES-256-GCM before SQLite persistence. Each envelope is bound to its record and field with authenticated additional data. The only durable secret file is the host keyring, which must be backed up with the database and kept access-restricted; losing it makes encrypted records unrecoverable. The envelope records a key version so old keys remain readable during operator-facing verification and transactional re-encryption with `valpo system secrets verify` and `valpo system secrets rotate`.

## Future Work

The following are intentionally not implemented:

- MariaDB, MySQL, and additional managed definitions;
- backup, restore, and retention scheduling;
- project export/import of dumps, snapshots, credentials, and dependency metadata;
- managed database credential rotation;
- descriptive or enforced resource plans;
- storage resizing and first-class volume resources;
- public database exposure;
- arbitrary custom service containers;
- automatic app binding at creation time;
- dashboard service-management flows.

MariaDB, backups, and exports are roadmap work, not “v1 behavior.” New definitions should be added only after their lifecycle, readiness, binding, deletion, repair, and eventual backup semantics can be supported coherently.
