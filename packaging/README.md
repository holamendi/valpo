# Valpo Packaging

Valpo currently ships a source installer for one fixed Ubuntu 26.04 LTS host layout and a development-only bootstrap.

Run installation as root and use root for installed `valpo` commands that manage the host.

## Supported Source Installation

Install from a reviewed checkout pinned to an immutable full commit:

```bash
git clone https://github.com/holamendi/valpo.git
cd valpo
git checkout --detach <full-commit-sha>
sudo packaging/install.sh
```

Use a release tag only after verifying it and recording the full commit it resolves to. Keep the checkout outside `/opt/valpo`; the installer copies it into the installed layout. Review the selected revision and the installer before running it.

The installer:

- installs runtime packages including Docker, Caddy, curl, build tools, mise, Ruby, Bundler, and gems
- installs checksum-verified `pack` 0.40.8 on Linux amd64/arm64 for Cloud Native Buildpacks
- configures and activates the Redis host prerequisite `vm.overcommit_memory=1`
- installs source into `/opt/valpo`
- stores Valpo state under `/var/lib/valpo`
- copies the production config template to `/etc/valpo/valpo.yml` on the first install
- preserves the existing config byte-for-byte on later compatible installs
- creates the private host-key directory at `/var/lib/valpo/secrets`
- writes Valpo-generated Caddy routes to `/var/lib/valpo/caddy/valpo.caddy`
- ensures `/etc/caddy/Caddyfile` imports the generated Valpo Caddy file
- installs systemd units and starts `valpo-api` and `valpo-worker`

The supported layout is intentionally fixed: user/group `valpo`, Ruby `4.0.5`, source at `/opt/valpo`, configuration at `/etc/valpo/valpo.yml`, and state at `/var/lib/valpo`. The installer refuses non-Ubuntu hosts and Ubuntu releases other than 26.04 instead of attempting an untested installation.

Ruby is installed through mise with precompiled binaries enabled:

```bash
MISE_RUBY_COMPILE=false
mise settings set ruby.compile false
```

If mise falls back to compiling Ruby from source, the installer fails. Valpo is installed from its source checkout; the gemspec supports dependency resolution and repository tooling, not a supported `gem install valpo` distribution path.

## Development Bootstrap

For a disposable development host, the bootstrap can install the current mutable snapshot from `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/holamendi/valpo/main/packaging/bootstrap.sh | sudo bash
```

The bootstrap downloads the current `main` archive into a private temporary directory, extracts it, invokes `packaging/install.sh`, and removes the temporary files.

This path is deliberately development-only: the branch is mutable, the archive is not a versioned release artifact, and two runs may install different commits. It is not reproducible installation guidance. For an inspect-first development installation, download `bootstrap.sh`, review it, then run it with `sudo bash bootstrap.sh`.

## App Domain

The recommended setup dedicates a base hostname such as `apps.example.com` to Valpo:

1. Create a wildcard `A` record for `*.apps.example.com` pointing to the server's public IPv4 address. Add `AAAA` only when the server has working public IPv6.
2. Allow inbound TCP traffic on ports `80` and `443`.
3. Configure the base hostname after installation, omitting the `*.` prefix.

```bash
valpo domain set-default apps.example.com
```

Valpo first verifies a unique HTTPS challenge below the base hostname. It then creates and verifies generated hostnames for existing web services. A service named `web` in project `hello` receives `web.hello.apps.example.com`. Avoid creating intermediate DNS records such as `hello.apps.example.com`, because a more specific DNS node can prevent the parent wildcard from answering below it.

Custom domains can be attached alongside the generated default after their DNS points to the server:

```bash
valpo domain add web hello.example.com --project hello
```

`domain add` verifies the exact hostname automatically. A web deployment without a verified domain can build, start, and pass its health check, but it remains private with release and service status `ready`. Verifying either a generated or custom domain activates the latest ready release. Workers, Postgres, and Redis do not participate in domain verification.

## API Binding And Auth

The installer binds `valpo-api` to `127.0.0.1` by default. API credentials are scoped, revocable records whose raw values are returned only once and stored as one-way digests. Create the first credential while the API is local:

```bash
valpo auth token create operator --scope=admin
export VALPO_API_TOKEN=valpo_...
```

After the first active credential is created, all API calls require one. Supply it to the CLI with `VALPO_API_TOKEN`; there is intentionally no token command-line flag or config-file value. Valpo refuses to boot on a non-local `api_host` until the database contains an active credential.

The packaged wrapper and systemd units set `VALPO_ENV=production`. When running an executable directly from a development checkout with an environment-keyed config file, set both variables explicitly:

```bash
VALPO_ENV=production VALPO_CONFIG=/path/to/valpo.yml \
  mise exec -- bundle exec exe/valpo-api
```

The installer also generates a frozen standalone Ruby load path under
`/var/lib/valpo/bundle`. The long-running API and worker use that setup directly,
so they do not retain the full Bundler runtime. Short-lived CLI, migration, and
maintenance commands continue to use the locked Bundler environment.

Without `VALPO_ENV=production`, direct development commands select the `development` section/defaults rather than the `production` mapping.

## GitHub Source Authentication

After the default app domain is verified, create the private GitHub App for this server:

```bash
valpo auth login github
```

The command prints a one-time URL on `github.<app-domain>`. Open it, name the App, create it from Valpo's manifest, and select the repositories it may access. The wildcard DNS already required for the app domain covers this hostname; no additional DNS record is needed.

Private Apps can only be installed on the account that owns them. For organization repositories, create the App under that organization:

```bash
valpo auth login github --organization acme
```

The manifest creates a private App with read-only Contents permission, the `push` event, a signed webhook, and server callback URLs. GitHub returns the generated private key and webhook secret to the callback. Valpo encrypts them in SQLite with the host keyring, verifies installation redirects against GitHub, and mints short-lived installation tokens for each source fetch.

`auto_deploy = true` sources deploy matching branch pushes. A source using `HEAD` follows pushes to the repository's default branch. Delivery IDs are deduplicated, and a service with an active operation is skipped instead of receiving a second deployment job.

An encrypted fine-grained PAT remains available as a fallback:

```bash
op read op://vault/github-pat | valpo auth login github --with-token
```

Do not put GitHub App credentials, PATs, or installation tokens in `valpo.yml` or `valpo.toml`. `valpo auth logout github` removes the encrypted local credential records; remove the installation or App separately in GitHub when retiring it.

Because the App callback and webhook URLs contain the default app domain, Valpo will not replace that domain while App credentials are configured. Log out locally, change the domain, run the App setup again, and delete the old App in GitHub.

## Source Build Configuration

Source services default to build strategy `auto`: Valpo uses a context-root Dockerfile when present and otherwise builds with Cloud Native Buildpacks. Packaged installs pin `pack` under `/var/lib/valpo/.local/bin` and pin the Paketo Jammy base builder. `/etc/valpo/valpo.yml` controls the build deadline and builder:

```yaml
production:
  build_timeout: 1800
  buildpack_builder: paketobuildpacks/builder-jammy-base@sha256:7510725172c8b2f1a7bce82b694e2af9599d5e2d97528c140eaeb81c569c21df
```

Build output is available through normal job events. Buildpack caches are stable Docker volumes scoped to a build target; they are removed when their owning service or project is deleted or after the configured period without a build. A repository `project.toml` is honored, but the configured builder remains explicit. Runtime service secrets are not passed into builds.

## Storage Maintenance

Valpo schedules ownership-scoped storage maintenance daily through `valpo-maintenance.timer`. Run a preview or an immediate pass with:

```bash
valpo system maintenance --dry-run
valpo system maintenance
```

Maintenance removes orphaned Valpo containers after the grace period, stale `valpo/...` build images beyond the configured release retention, buildpack cache volumes unused beyond their retention, and expired jobs, job events, and GitHub webhook-delivery history. Removed release artifacts remain in deployment history with `artifact_available=false` and are excluded from rollback. Registry images, managed-service data volumes, unrelated Docker resources, and global Dockerfile BuildKit cache are never automatically deleted.

Every newly created app or managed-service container uses Docker's rotating `local` log driver. The defaults retain at most three compressed 10 MB log files per container. Existing containers adopt the limit when a deployment, restart, or repair recreates them.

The production defaults are:

```yaml
production:
  build_log_limit: 16777216
  image_retention_count: 3
  storage_cleanup_grace_period: 86400
  build_cache_retention: 2592000
  job_retention: 2592000
  container_log_max_size: 10m
  container_log_max_files: 3
```

Build command output stored in SQLite is capped per build by `build_log_limit`; the runner still retains its bounded failure tail for error reporting after the persisted stream is truncated. The SQLite database uses incremental auto-vacuum so history cleanup can return freed pages to the filesystem without creating a full duplicate database.

On a Linux development host with Docker and `pack`, run the opt-in build/inspect/run smoke test with:

```bash
VALPO_TEST_BUILDPACKS=1 mise exec -- bundle exec ruby -Itest test/integration/buildpack_smoke_test.rb
```

## Installed Host Layout

The installed services use:

- source at `/opt/valpo`;
- Ruby 4.0.5 installed through mise under `/var/lib/valpo`;
- Bundler dependencies under `/var/lib/valpo/bundle`;
- production config at `/etc/valpo/valpo.yml`;
- Redis sysctl configuration at `/etc/sysctl.d/99-valpo-redis.conf`;
- state under `/var/lib/valpo`;
- the versioned encryption keyring at `/var/lib/valpo/secrets/master.key`.

The keyring is the only durable secret stored outside SQLite. It is generated with mode `0600` and is required to decrypt managed credentials, service environment values, and provider credentials. Back up the database and keyring together under separate access controls; losing the keyring makes the encrypted rows unrecoverable.

Use `valpo system secrets verify` to confirm that the configured database and keyring can recover every encrypted record. Before running `valpo system secrets rotate`, back up both artifacts as one recovery set. Rotation verifies the records before mutation, adds a new active key version, re-encrypts all records in one SQLite transaction, and verifies the result. Old key versions are retained. Test restored database/keyring pairs on a separate host before relying on them.

`valpo-migrate.service` is a one-shot unit that runs before the API and worker. Keep migrations owned by that unit instead of adding `--migrate` to both long-running services.

## Development Updates And Clean Reinstalls

The installer supports an in-place development update only when the incoming and installed `db/migrations/001_bootstrap.rb` files have the same SHA-256 digest. It performs that comparison before installing packages, copying source, changing configuration, or running migrations. Migration `001` is now permanently frozen, so this comparison is an integrity and unsupported-checkout guard. Later schema changes use contiguous incremental migrations, which the installer runs. An existing `/etc/valpo/valpo.yml` is preserved byte-for-byte, with ownership/mode restored to `root:valpo`/`0640`.

The source installer's in-place update path still replaces `/opt/valpo` directly and has no code/database transaction or automatic rollback. Use in-place source updates only on disposable development hosts. Fresh source installation remains the current alpha installation path, but a production updater based on verified immutable releases and offline checkpoints is only specified in [the release lifecycle](../docs/valpo-release-lifecycle.md), not yet implemented. For a clean development reinstall:

```bash
packaging/uninstall.sh
packaging/install.sh
```

Before uninstalling, stop Valpo and make an offline backup of all operator-owned state:

- `/etc/valpo/valpo.yml`;
- `/var/lib/valpo`, including the SQLite database, its sidecar files, and credentials;
- every volume reported by `docker volume ls --filter label=valpo.owned=true`.

Keep those backups access-restricted because they contain secrets and application data. Use the backup mechanism appropriate to the volume's storage driver, and verify the backup before continuing.

The uninstall destroys Valpo metadata, credentials, generated routing state, and label-owned Docker containers, volumes, and networks. It removes `/etc/sysctl.d/99-valpo-redis.conf` but does not reset the live host-wide `vm.overcommit_memory` value, because another Redis installation may depend on it; reboot or change the value explicitly if the host should return to its previous policy. The copies above are a manual safety measure, not a supported restore or data-preserving schema-upgrade workflow; test any recovery procedure on a separate host. Review retained Docker images and any intentionally unlabeled Docker resources separately. Run the source installer from a checkout outside `/opt/valpo`; replacing `/opt/valpo` manually defeats the installed/incoming migration comparison.

## Service Logs And Troubleshooting

The API and worker log to the systemd journal; Valpo does not write `api.log` or `worker.log` files:

```bash
journalctl -u valpo-api.service -u valpo-worker.service
journalctl -u valpo-migrate.service
systemctl status valpo-api.service valpo-worker.service
```

Use `valpo system status`, `valpo job list`, and `valpo job events JOB_ID` for control-plane and operation-level diagnosis.

## Uninstall

Run the destructive uninstaller from a reviewed checkout:

```bash
packaging/uninstall.sh
```

It disables Valpo services, removes containers, volumes, and networks carrying `valpo.owned=true`, removes the Caddy import, and deletes Valpo host files/state/account. It deliberately retains Docker images and every unlabeled Docker resource rather than guessing ownership from a `valpo-*` name. Shared packages such as Docker and Caddy are also retained.

## VPS Smoke Test

The dedicated Valpo test VPS is `root@162.55.43.108`, and its app-domain
suffix is `apps.valpo.dev`. Run the repeatable smoke test from a local checkout:

```bash
packaging/vps-smoke-test.sh root@162.55.43.108 apps.valpo.dev --reboot
```

By default the Ruby smoke controller copies the current checkout to `/tmp/valpo-src`, runs the full installer, verifies the private host key and persistent/effective Redis sysctl setting, sets the host-wide app domain, deploys `nginx:alpine`, exercises encrypted set/list/reveal/unset service environment behavior, rotates the host key while encrypted records exist, verifies HTTPS, releases, logs, optional reboot recovery, and then deletes the project. It creates a temporary admin API credential without exposing its raw token in process arguments or output, revokes it during guaranteed cleanup, and checks that a custom plaintext value does not occur in the SQLite files. It does not restore a previous app domain, so do not run it against a host serving unrelated projects. Use `--skip-deps` only when intentionally testing a schema-compatible development update on a host whose dependencies are already installed.

To prove installation from a clean Valpo state, use the guarded destructive wrapper. It runs the uninstaller, verifies the absence of label-owned runtime resources and host state, then runs the full smoke test from the local checkout. Docker images, unlabeled Docker resources, Docker, Caddy, and other shared host packages remain installed.

```bash
packaging/vps-clean-install-smoke-test.sh root@162.55.43.108 apps.valpo.dev --confirm-destroy-valpo
```

Use the source smoke test on a host whose GitHub App or fallback PAT is already configured:

```bash
packaging/vps-source-smoke-test.sh root@162.55.43.108 apps.valpo.dev
```

It installs the current checkout, creates a unique project without a manifest, and deploys `holamendi/smol-roda` while omitting ref, build strategy, Dockerfile, context, and port. It verifies automatic Dockerfile selection, the resolved commit, port `3000`, injected `PORT`, HTTPS, and release metadata, then removes only the generated project/runtime resources. The script checks the encrypted GitHub credential record and `auth status github` before and after; it never logs out or deletes the credential. Use `--repository OWNER/REPO` for another repository or `--skip-install` to test the already-installed version.
