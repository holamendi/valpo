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

Postgres mounts its named volume on the image's actual data directory: `/var/lib/postgresql/data` for versions 16 and 17, and `/var/lib/postgresql` for version 18. New volumes carry a `valpo.volume_path` label recording that target. Before recreating a version 16 or 17 container, Valpo checks the current mount or the volume label and refuses to continue when an older, ambiguous layout could strand data in an anonymous Docker volume.

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

## Inspecting And Recovering Postgres 16/17 Volumes

Installations that created Postgres 16 or 17 services before the version-specific mount fix must be inspected **before** stopping, restarting, repairing, or deleting those containers. A safe container has its `valpo-...-data` named volume mounted directly at `/var/lib/postgresql/data`. An affected container instead has that named volume at `/var/lib/postgresql` and a second, usually anonymous volume at `/var/lib/postgresql/data`.

List the Postgres containers and inspect every mount on the selected container:

```bash
docker ps --all --filter label=valpo.service_type=postgres
container=valpo-REPLACE_WITH_SERVICE_ID
docker inspect "$container" \
  --format '{{range .Mounts}}{{println .Type .Name .Destination}}{{end}}'
```

If the named `valpo-...-data` volume already targets `/var/lib/postgresql/data`, no data relocation is needed. If the output shows the affected two-volume layout, keep the container and both volumes intact and take a logical backup first:

```bash
umask 077
docker exec "$container" sh -c 'exec pg_dumpall -U "$POSTGRES_USER"' > postgres-backup.sql
test -s postgres-backup.sql
```

The following on-host recovery copies the existing physical data into a newly labelled named volume. Set the variables to the exact container, named-volume, anonymous-volume, and major-version values from the inspection output. Keep the source version unchanged, stop the worker to prevent concurrent repair, and do not add `--volumes` to `docker rm`:

```bash
named_volume=valpo-REPLACE_WITH_SERVICE_ID-data
anonymous_volume=REPLACE_WITH_ANONYMOUS_VOLUME
postgres_version=17
sudo systemctl stop valpo-worker
docker stop "$container"
docker rm "$container"
docker volume rm "$named_volume"
docker volume create \
  --label valpo.owned=true \
  --label valpo.volume_path=/var/lib/postgresql/data \
  "$named_volume"
docker run --rm \
  --volume "$anonymous_volume:/source:ro" \
  --volume "$named_volume:/target" \
  --entrypoint sh "postgres:$postgres_version-alpine" \
  -c 'test -f /source/PG_VERSION && test -z "$(ls -A /target)" && cp -a /source/. /target/'
sudo systemctl start valpo-worker
valpo system repair
```

Confirm the service becomes ready and verify application data before considering removal of the anonymous source volume. Retain both the logical dump and anonymous volume until that verification is complete. If the original container is already gone and its anonymous volume cannot be identified with certainty, do not guess; restore a known backup into a fresh service.

## Credentials And Limitations

Credentials are encrypted with AES-256-GCM using the host keyring. Back up the keyring with SQLite: encrypted records cannot be recovered without it. Use `valpo system secrets verify` and `valpo system secrets rotate` to check or rotate keys.

Automated backups and restore, credential rotation for individual databases, resource plans, storage resizing, public database access, and arbitrary managed-service images are not implemented.
