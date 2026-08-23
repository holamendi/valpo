# Valpo Managed Services

Valpo provides private, project-owned Postgres and Redis services. It chooses the image, creates persistent storage and credentials, checks readiness, and exposes connection values only to explicitly bound app services.

## Supported Services

| Type | Versions | Default image |
| --- | --- | --- |
| Postgres | `16`, `17`, `18` | `postgres:18-alpine` |
| Redis | `7`, `8` | `redis:8-alpine` |

Managed images cannot be overridden. Each service has a project-scoped name and its own `svc_` identity.

## Lifecycle

Managed services:

- run on Valpo's private Docker network without a public host port;
- use persistent Docker volumes and an `unless-stopped` restart policy;
- are repaired when their container is stopped or missing;
- require `--force` for deletion, which also removes their volume and bindings.

Redis requires the installer-owned `vm.overcommit_memory=1` host setting. Valpo verifies it before starting a Redis container.

Projects cannot be deleted while they contain services.

## Bindings

Bindings stay within a project and connect one app service to one managed service. The managed service must be running. Valpo rejects bindings whose generated keys collide with another dependency and restarts an active app after its bindings change.

Postgres provides:

```text
DATABASE_URL
PGHOST
PGPORT
PGDATABASE
PGUSER
PGPASSWORD
```

Redis provides:

```text
REDIS_URL
REDIS_HOST
REDIS_PORT
REDIS_PASSWORD
```

Connection values are derived from encrypted credentials rather than copied onto binding records. `valpo service env list` redacts secrets unless `--reveal` is used.

## Usage

```bash
valpo service create database --project myapp --type postgres --version 18
valpo service create cache --project myapp --type redis --version 8
valpo service bind web database --project myapp
valpo service restart database --project myapp
valpo service delete database --project myapp --force
```

The project manifest supports Postgres and Redis services plus app `depends_on` entries. Applying a manifest adds or updates resources; omission never deletes them.

## Credentials And Limitations

Credentials are encrypted with AES-256-GCM using the host keyring. Back up the keyring with SQLite: encrypted records cannot be recovered without it. Use `valpo system secrets verify` and `valpo system secrets rotate` to check or rotate keys.

Backups, restore, credential rotation for individual databases, resource plans, storage resizing, public database access, and arbitrary managed-service images are not implemented.
