# Valpo Managed Services

## Purpose

Valpo should let advanced users run arbitrary containers, but the main experience should be higher-level managed services that feel like Heroku add-ons.

The user should not need to know which Docker image, environment variables, volume paths, credentials, health checks, or connection strings are required to create a useful Postgres or MariaDB instance.

The ideal interaction is:

```bash
valpo services:create myapp/web --type web --port 3000
valpo services:create myapp/database --type postgres --version 18 --wait
valpo services:bind myapp/web myapp/database --wait
valpo env myapp/web
```

Or in the dashboard:

```text
Project -> Add service -> Postgres -> Small -> Create
```

Valpo handles the details.

## Product Principle

Arbitrary containers are the escape hatch. Curated services are the happy path.

This matters because the target user misses the Heroku experience: they want to build and ship products, not hand-wire database containers.

## Service Catalog

Valpo should have a built-in service catalog. Each service definition describes how to provision, bind, back up, restore, inspect, and destroy a service.

Initial catalog:

```text
postgres
redis
```

Later catalog:

```text
mariadb
mysql
minio
meilisearch
typesense
valkey
clickhouse
volume
```

These should be added carefully. A small set of excellent built-ins is better than many shallow wrappers.

## User-Facing Settings

A managed service should expose friendly settings:

```text
name
type
version
plan
storage size
backup schedule
backup retention
private-only or public exposure
maintenance window
```

For v1, the settings can be minimal:

```text
name
type
version
plan
```

Phase 2A supports Postgres versions `16`, `17`, and `18`, defaulting to `18`, and Redis versions `7` and `8`, defaulting to `8`. Managed-service flows reject arbitrary image tags; the catalog maps versions to `postgres:<version>-alpine` and `redis:<version>-alpine`.

The plan should map to practical defaults:

```text
small
medium
large
custom
```

For example, a `small` Postgres plan might define default memory hints, storage location, backup retention, and health checks. Valpo does not need to enforce hard resource limits on day one, but the plan abstraction gives the UI and API a friendly shape.

## Internal Model

Suggested objects:

```text
ServiceDefinition
  type
  display_name
  supported_versions
  default_version
  plans
  provisioner
  backup_strategy
  restore_strategy
  bind_strategy

Service
  id
  project_id
  name
  kind: web, worker, postgres, or redis
  status

ManagedServiceConfig
  service_id
  version
  image
  plan
  container_name
  volume_name
  internal_host
  internal_port
  credentials_json
  created_at
  updated_at

ServiceDependency
  id
  service_id
  dependency_service_id
  status
  env_json
  created_at
  updated_at
```

`ServiceDefinition` can start as Ruby code rather than database rows. Built-in services should be versioned with Valpo.

## Provisioner Interface

Each managed service should implement a small lifecycle interface:

```text
validate_settings
provision
status
bind
unbind
backup
restore
rotate_credentials
destroy
export
import
```

These operations should run as background jobs and write job events.

## Binding Model

Binding a managed service to an app service means Valpo generates configuration for that specific app container. Other app services in the project receive nothing unless they declare the same dependency.

For Postgres, binding might generate:

```text
DATABASE_URL
PGHOST
PGPORT
PGDATABASE
PGUSER
PGPASSWORD
```

For MariaDB, binding might generate:

```text
DATABASE_URL
MYSQL_HOST
MYSQL_PORT
MYSQL_DATABASE
MYSQL_USER
MYSQL_PASSWORD
```

The user should not need to manually create these values.

Advanced users can still override or add environment variables manually. Generated values should be marked as managed so Valpo can update them when credentials rotate.

Valpo stores generated service credentials in SQLite and redacts secret env values by default. Use `valpo env PROJECT/SERVICE --reveal` to inspect actual values on the host.

## Phase 2B CLI Surface

```bash
valpo services:create PROJECT/NAME --type postgres|redis [--version VERSION] [--wait]
valpo services:list [PROJECT]
valpo services:show SERVICE
valpo services:logs SERVICE [--tail N]
valpo services:restart SERVICE [--wait]
valpo services:bind APP_SERVICE MANAGED_SERVICE [--wait]
valpo services:unbind APP_SERVICE MANAGED_SERVICE [--wait]
valpo services:delete SERVICE --force [--wait]
valpo env APP_SERVICE [--reveal]
```

Deleting a managed service removes its container, Docker volume, and explicit dependencies. Deleting a project is refused while any app or managed services remain.

## Postgres V1 Behavior

Initial Postgres support should include:

- Create private Postgres container.
- Create persistent Docker volume.
- Generate database name, user, password, and connection URL.
- Bind to one or more app services in its owning project.
- Health check readiness.
- App restart or redeploy after binding.

Useful defaults:

- Private network access only.
- No public port exposed.
- Latest supported stable major version selected by Valpo.
- One database and one application user per resource.
- Backups disabled until an explicit backup/restore phase.

Follow-up Postgres support should include:

- Manual backup using `pg_dump`.
- Manual restore using `pg_restore` or `psql`, depending on dump format.
- Include database dump in project export.
- Restore database during project import.

## MariaDB V1 Behavior

Initial MariaDB support should include:

- Create private MariaDB container.
- Create persistent Docker volume.
- Generate database name, user, password, and connection URL.
- Bind to explicit app services in its owning project.
- Health check readiness.
- Manual backup using `mariadb-dump` or `mysqldump`.
- Manual restore from dump.
- Include database dump in project export.
- Restore database during project import.

## Redis V1 Behavior

Initial Redis support should include:

- Create private Redis container.
- Optional persistence.
- Generate connection URL.
- Bind to explicit app services in its owning project.

Follow-up Redis support should include:

- Include configuration in export.
- Include data snapshot only when persistence is enabled.

## Custom Containers

Valpo should also allow custom service containers:

```bash
valpo containers:create search --image getmeili/meilisearch:v1.8
```

But custom containers should be clearly different from managed services:

- Valpo does not promise automatic backups.
- Valpo does not infer safe credential rotation.
- Valpo does not guarantee import/export semantics.
- User supplies ports, volumes, env vars, and health checks.

This preserves flexibility without weakening the curated service promise.

## Dashboard Experience

Dashboard service creation should avoid raw container fields by default.

Good default flow:

```text
Project
  Add service
  Choose Postgres
  Choose plan and version
  Confirm
  Watch provisioning job
  Service is automatically bound to the app
```

Advanced settings can include:

```text
version
storage path
storage size
backup schedule
backup retention
maintenance window
public exposure
custom environment variables
```

Advanced settings should be collapsed by default.

## API Sketch

```text
GET    /services
POST   /services
GET    /services/:id
GET    /services/:id/logs
POST   /services/:id/restart
POST   /services/:id/bind
DELETE /services/:id

GET    /projects/:project_id/env
```

Future service operations should add endpoints for unbinding, backups, restores, credential rotation, and catalog introspection.

Create Postgres request:

```json
{
  "type": "postgres",
  "name": "main-db",
  "version": "default",
  "plan": "small",
  "bind_to_project": true
}
```

## Migration And Export

Managed services should be first-class in export/import.

Export should include:

- resource manifest
- service type and version
- friendly settings
- encrypted credentials or regenerated credential policy
- backup artifact or dump
- binding metadata

Import should preflight:

- service type supported on target server
- version available or compatible
- enough disk space
- backup artifact readable
- binding target exists
- naming conflicts

## Open Questions

- Should credentials be preserved during import or regenerated by default?
- Should a managed service be owned by exactly one project in v1?
- Should backups be enabled by default for Postgres/MariaDB?
- Should Valpo expose any database publicly, or require explicit advanced configuration?
- Should resource plans enforce Docker memory/CPU limits or remain descriptive at first?
