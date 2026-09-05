# Valpo Packaging

Valpo currently ships a source installer for one fixed Ubuntu 26.04 LTS host layout and a development-only bootstrap.

Run installation as root and use root for installed `valpo` commands that manage the host.

## Immutable Release Artifacts

The release workflow builds self-contained Linux amd64 and arm64 archives named
`valpo-VERSION-linux-ARCH.tar.zst`. Each archive is rooted at
`opt/valpo/releases/VERSION/` and contains Valpo, Ruby 4.0.5, locked production
gems, `pack` 0.40.8, migrations, templates, and release-local launchers for the
CLI, API, worker, maintenance, and migrations. Mise is a pinned build-time
fetcher only and is not required by the extracted release.

Build and smoke-test an artifact on a native matching Linux or Docker host:

```bash
packaging/release/build.sh --architecture amd64 --output-dir dist
packaging/release/smoke.sh \
  --architecture amd64 \
  --archive dist/valpo-0.1.1-linux-amd64.tar.zst
packaging/release/sbom.sh \
  --architecture amd64 \
  --archive dist/valpo-0.1.1-linux-amd64.tar.zst \
  --output dist/valpo-0.1.1-linux-amd64.spdx.json
```

The builder refuses emulation, unpinned Ruby, unsafe archive paths, and artifacts
above the configured size limits. On a version tag, GitHub Actions publishes archives, SPDX SBOMs, checksums, and
attestations as durable GitHub Release assets after all release gates pass.
Enable immutable releases in repository settings before pushing a tag. Uploads
remain draft until complete; published tags and assets must never be replaced.
A failed publication may leave a draft for manual inspection; reruns refuse to
overwrite it. Untagged runs produce only workflow artifacts.

Artifacts can upgrade an existing installation using the host transaction below.
The source installer remains the development bootstrap for a fresh host.

## Host Upgrades

Install the updated host tooling from a reviewed checkout outside `/opt/valpo`
with `sudo packaging/upgrade.sh --channel stable`. Subsequent checks need no tag:

```bash
sudo valpo-upgrade
sudo valpo-upgrade --channel preview
sudo valpo-upgrade v0.1.2 --channel stable
```

The no-argument command (also spelled `update`) fetches all release pages and
selects the highest semantic version above the installed version. It does not
use GitHub's “latest” label or tag timestamps. It exits successfully without
changes when already up to date. This checks on invocation; no background timer
is installed. The saved installation channel is reused, defaulting to stable
for source installs. Development installations must explicitly choose stable or
preview for online updates. Stable excludes prereleases; preview includes both
prereleases and final releases. An explicit tag must also be newer and match the
selected channel. Drafts and unpublished tags are never installed.

Online updates require a complete immutable release and select amd64 or arm64
from the host architecture. Downloads use GitHub asset IDs in root-only temporary
staging and are size-limited. The archive checksum and exact-tag workflow
attestation must verify before extraction or candidate execution. Failed downloads
are removed. Missing assets, changed release identities, and verification failures
leave the active installation unchanged.

GitHub CLI must be installed and authenticated as root, or supply `GH_TOKEN` via
`sudo --preserve-env=GH_TOKEN valpo-upgrade`. Private release downloads require a
token with repository Contents read access; provenance verification also needs
Attestations read access. Never put a token in command arguments or configuration
committed to Git. Private repositories require GitHub Enterprise Cloud to generate
artifact attestations; making the repository public is not required for downloads,
but may be necessary for this provenance workflow without Enterprise Cloud. See
[GitHub's attestation requirements](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations).

For a local development archive or offline artifact, use:

```bash
sudo packaging/upgrade.sh apply \
  /path/to/valpo-0.1.1-linux-amd64.tar.zst \
  --sha256 <verified-sha256> --channel development
```

Subsequent upgrades use `packaging/upgrade.sh` from the reviewed incoming release
to refresh the host tooling, or the installed root-owned `valpo-upgrade apply`
command with the same arguments. The installed `valpo-upgrade recover` command
always remains available during an interrupted transaction. The host needs zstd, iproute2, util-linux, and the normal Valpo runtime packages.
The first invocation preserves a root-owned copy of the installed Ruby runtime
under `/var/lib/valpo-updater/runtime/ruby`. Recovery uses that runtime and Ruby
standard libraries, without loading Valpo or its application gems. `development` explicitly identifies a
locally built, checksum-verified artifact. `preview` and `stable` additionally
require GitHub CLI and a valid attestation from the repository's release workflow,
on `refs/tags/vVERSION`, using a GitHub-hosted runner. Obtain the expected digest
from a trusted build; calculating a digest from an untrusted download does not
authenticate it.

The upgrader verifies and stages an immutable release, serializes host changes,
closes the API, and refuses queued/running work without interrupting the worker.
It then stops the idle worker and checkpoints SQLite, configuration, encryption
keys, host units, and installation metadata together. Migration and an actual
authenticated API health check run before activation; the health check uses a
private network namespace, with no external clients or job execution. Successful
verification atomically switches `/opt/valpo/current`, records activation, and
starts the services. App containers and Caddy remain running throughout.

A failure before activation restores the checkpoint and previous services.
After activation, automatic recovery only restarts the new release: it must not
discard subsequent user writes. Interrupted pre-activation transactions block
systemd starts, including after a reboot. Recover them with:

```bash
sudo valpo-upgrade recover
```

Checkpoints remain root-only under `/var/lib/valpo-updater/checkpoints` and include
encryption keys. They are local upgrade recovery material, not off-host backups;
they do not contain managed Postgres/Redis volumes. No retention pruning or late
rollback command is provided yet. Uninstallation removes these checkpoints.
Coordinate host administration so no direct local database writers run during an
upgrade. Custom systemd drop-ins require review and are rejected. Source installs
cannot overwrite an activated packaged installation.

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
- creates the initial configuration and preserves it on compatible reinstalls
- creates private state, host-key, and generated Caddy paths under `/var/lib/valpo`
- imports Valpo's generated routes from the system Caddy configuration
- installs systemd units and starts `valpo-api` and `valpo-worker`

The layout is fixed: user/group `valpo`, Ruby `4.0.5`, source at `/opt/valpo`, configuration at `/etc/valpo/valpo.yml`, and state at `/var/lib/valpo`. Other operating systems and Ubuntu releases are rejected.

Ruby is installed through mise with precompiled binaries enabled:

```bash
MISE_RUBY_COMPILE=false
mise settings set ruby.compile false
```

The installer fails if mise cannot use a precompiled Ruby. `gem install valpo` is not supported.

## Development Bootstrap

For a disposable development host, the bootstrap can install the current mutable snapshot from `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/holamendi/valpo/main/packaging/bootstrap.sh | sudo bash
```

The bootstrap installs a mutable snapshot of `main`, so it is neither reproducible nor suitable for production. For an inspect-first installation, download and review the script before running it.

## App Domain

The recommended setup dedicates a base hostname such as `apps.example.com` to Valpo:

1. Create a wildcard `A` record for `*.apps.example.com` pointing to the server's public IPv4 address. Add `AAAA` only when the server has working public IPv6.
2. Allow inbound TCP traffic on ports `80` and `443`.
3. Configure the base hostname after installation, omitting the `*.` prefix.

```bash
valpo domain set-default apps.example.com
```

Valpo first verifies a unique HTTPS challenge below the base hostname. It then creates and verifies generated hostnames for existing web services. A service named `web` in project `hello` initially receives `hello-web.apps.example.com`. Each service gets a stable slug, with a random suffix on collision; renames and default-domain changes preserve that slug. For Cloudflare Universal SSL, use a zone root such as `example.com` as the default to keep generated names within first-level wildcard certificate coverage.

Custom domains can be attached alongside the generated default after their DNS points to the server:

```bash
valpo domain add web hello.example.com --project hello
```

`domain add` verifies the exact hostname automatically. A web deployment without a verified domain can build, start, and pass its health check, but it remains private with release and service status `ready`. Verifying either a generated or custom domain activates the latest ready release. Workers, Postgres, and Redis do not participate in domain verification.

## API Binding And Auth

The installer binds `valpo-api` to `127.0.0.1` by default. It creates the initial admin credential before starting the API and saves the raw token in `/etc/valpo/bootstrap-token` with root-only mode `0600`. It never prints this token in installation logs. Reinstalling preserves existing credentials and never reopens bootstrap.

Initialize the installed host's local CLI profile, then issue a separate token for your computer:

```bash
valpo login --server http://127.0.0.1:7092 --name local --with-token < /etc/valpo/bootstrap-token
valpo auth token create my-computer --scope=admin
```

On your computer, run `valpo login --server https://YOUR-API-HOST --name live` and enter the new token at the hidden prompt. Login validates and saves it in a private client config file; later commands use it automatically. Client tokens are plaintext in that file, protected by owner-only permissions. Keep client profiles and bootstrap tokens out of Git and shared backups. `VALPO_API_TOKEN` remains an override for environments and secret managers. See the [CLI guide](../docs/valpo-cli.md#server-login) for profile selection and logout.

Server-side credentials are scoped and revocable, and SQLite stores only their digests. All API calls require authentication once bootstrap completes. Valpo refuses to boot on a non-local `api_host` until the database contains an active credential. Recovery after losing all administrator access remains an explicit offline operation.

The packaged wrapper and systemd units set `VALPO_ENV=production`. When running an executable directly from a development checkout with an environment-keyed config file, set both variables explicitly:

```bash
VALPO_ENV=production VALPO_CONFIG=/path/to/valpo.yml \
  mise exec -- bundle exec exe/valpo-api
```

Without `VALPO_ENV=production`, direct development commands select the `development` section/defaults rather than the `production` mapping.

## GitHub Source Authentication

After the default app domain is verified, create the private GitHub App for this server:

```bash
valpo auth login github
```

The command prints a one-time URL on `github.<app-domain>`. Open it, create the App, and select its repositories. The app-domain wildcard already covers this hostname.

Private Apps can only be installed on the account that owns them. For organization repositories, create the App under that organization:

```bash
valpo auth login github --organization acme
```

Valpo encrypts the App key and webhook secret and uses short-lived installation tokens for source fetches. Sources with `auto_deploy = true` deploy matching signed pushes.

An encrypted fine-grained PAT remains available as a fallback:

```bash
op read op://vault/github-pat | valpo auth login github --with-token
```

Do not put provider credentials in `valpo.yml` or `valpo.toml`. `valpo auth logout github` removes only Valpo's local records; remove the App separately in GitHub.

Because callback URLs use the default app domain, change it by logging out of GitHub locally, replacing the domain, and setting up a new App. See the [CLI guide](../docs/valpo-cli.md#deployments) for full authentication behavior.

## Source Build Configuration

Source services default to build strategy `auto`: Valpo uses a context-root Dockerfile when present and otherwise builds with Cloud Native Buildpacks. Packaged installs pin `pack` under `/var/lib/valpo/.local/bin` and pin the Heroku 26 builder. `/etc/valpo/valpo.yml` controls the build deadline and builder:

```yaml
production:
  build_timeout: 1800
  buildpack_builder: heroku/builder@sha256:e0d2453e68106a8000da70780f631e888ca61a515ea9921a26a1f7391964908a
```

Build output is available through job events. Buildpack caches belong to a build target and expire after the configured retention period. Build targets may override the server builder and provide an ordered buildpack list in the manifest or CLI/API. Omitted lists honor `project.toml` or builder detection. Runtime secrets are not passed into builds.

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

`build_log_limit` caps build output stored in SQLite. Incremental auto-vacuum returns pages freed by history cleanup to the filesystem.

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

The installer permits an in-place development update only when the installed and incoming frozen bootstrap migrations match. It then runs later contiguous migrations and preserves `/etc/valpo/valpo.yml`.

In-place source updates replace `/opt/valpo` without transactional rollback, so use them only on disposable development hosts. For a clean reinstall:

```bash
packaging/uninstall.sh
packaging/install.sh
```

Before uninstalling, stop Valpo and make an offline backup of all operator-owned state:

- `/etc/valpo/valpo.yml`;
- `/var/lib/valpo`, including the SQLite database, its sidecar files, and credentials;
- every volume reported by `docker volume ls --filter label=valpo.owned=true`.

Keep these backups access-restricted and verify them before continuing.

Uninstall removes Valpo metadata, credentials, routes, and label-owned Docker resources. It removes Valpo's Redis sysctl file but leaves the live `vm.overcommit_memory` value unchanged in case another Redis installation uses it. These manual copies are not a supported restore workflow; test recovery separately. Run the source installer from a checkout outside `/opt/valpo`.

## Service Logs And Troubleshooting

The API and worker log to the systemd journal; Valpo does not write `api.log` or `worker.log` files:

```bash
journalctl -u valpo-api.service -u valpo-worker.service
journalctl -u valpo-migrate.service
systemctl status valpo-api.service valpo-worker.service
```

Use `valpo system status`, `valpo job list`, and `valpo job events JOB_ID` for control-plane and operation-level diagnosis.

## Uninstall

Back up the state described above, then run the destructive uninstaller from a reviewed checkout:

```bash
packaging/uninstall.sh
```

It disables Valpo services, removes containers, volumes, and networks carrying `valpo.owned=true`, removes the Caddy import, and deletes Valpo host files/state/account. It deliberately retains Docker images and every unlabeled Docker resource rather than guessing ownership from a `valpo-*` name. Shared packages such as Docker and Caddy are also retained.

## End-to-End Test Environment

The canonical development E2E environment is the `valpo` Incus VM on Starbook,
with the persistent public canary at `https://valpo-e2e.siesta.cam/` routed
through the existing Cloudflare Tunnel. This environment covers installed-host
updates, schema migration, API bootstrap and recovery, deployment, normal Valpo
domain verification, service/VM restart recovery, and public reachability.

Follow [End-to-end testing](../docs/end-to-end-testing.md) for the topology,
safety rules, worktree installation procedure, tunnel-origin requirements, and
verification commands. Connect as `pablo@starbook`; never aim the destructive
clean-install wrapper at Starbook itself.

## Direct Public VPS Smoke Test

Keep the direct-host smoke test for cases that specifically require a publicly
addressed origin, direct Caddy TLS termination, or a clean host-package install:

```bash
packaging/vps-smoke-test.sh root@HOST apps.example.com --reboot
```

The test installs the current checkout, exercises host prerequisites, deployment, HTTPS, encrypted environment values, key rotation, logs, and optional reboot recovery, then removes its project and temporary credential. It replaces the host's default app domain, so never run it on a host serving unrelated projects. `--skip-deps` is only for a schema-compatible update on an already prepared test host.

For a clean-state test, use the guarded wrapper. It uninstalls Valpo and deletes its label-owned resources before running the full test; shared packages, images, and unlabeled Docker resources remain.

```bash
packaging/vps-clean-install-smoke-test.sh root@HOST apps.example.com --confirm-destroy-valpo
```

Use the source smoke test on a host whose GitHub App or fallback PAT is already configured:

```bash
packaging/vps-source-smoke-test.sh root@HOST apps.example.com
```

This verifies the default GitHub source-build path without changing the configured provider credential. Use `--repository OWNER/REPO` for another repository or `--skip-install` to test the installed version.


## Build host verification

The Ubuntu installer installs `docker-buildx` alongside `docker.io` and verifies the plugin. It checks HTTPS download connectivity and advertised IPv6 routing before downloading tools. A broken IPv6 route is an actionable installation error; Valpo never changes host or shared bridge networking automatically.

Before each buildpack build, Valpo checks the Docker platform and tools, resolves builder/run-image digests, and verifies run-image export on the containerd image store. For Docker's `no suitable export target` failure, it materializes the declared run-image layers using Buildx and verifies export again. This is an automated compatibility workaround for [moby/moby#52193](https://github.com/moby/moby/issues/52193), not a switch of Docker storage backends. It applies to each newly resolved run image. Other export errors fail preflight without retrying the workaround.

CI and release publication require `.github/workflows/buildpack-acceptance.yml`: install with full dependencies on a disposable Ubuntu host, apply the Ruby 4.0.6/Postgres 18 fixture manifest, build with multiple explicit buildpacks from an empty app cache, and verify an HTTP database write survives container restarts. The same workflow builds a next-version artifact, injects migration and API readiness failures, verifies checkpoint recovery, activates the valid artifact, and checks the existing app's persisted data. The fixture substitutes local source checkout for GitHub authentication and uses the private loopback release URL. Public TLS and GitHub authentication are covered separately by live-server verification.

On a disposable installed host, run `packaging/buildpack_acceptance.rb` with the installed Ruby bundle, `VALPO_ENV=production`, `VALPO_CONFIG=/etc/valpo/valpo.yml`, and `VALPO_ACCEPTANCE=1`. Run again with `verify` after reboot to check the same persisted item. The harness deliberately retains its project for that check; do not run it on a production host.
