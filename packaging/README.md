# Valpo Packaging

Valpo currently ships a bootstrap installer, a source installer, and Ubuntu 26.04 LTS packaging templates.

Run installation and installed `valpo` commands as root. The examples below assume a root shell.

## Bootstrap Installer

Install the current development version on a fresh host:

```bash
curl -fsSL https://raw.githubusercontent.com/holamendi/valpo/main/packaging/bootstrap.sh | bash
```

The bootstrap downloads a GitHub source archive into a private temporary directory, extracts it, invokes `packaging/install.sh`, and removes the temporary files. It requires root because the source installer installs system packages and writes system configuration.

The bootstrap intentionally has no installation options. Valpo owns its host layout, and domain configuration happens after installation. For an inspect-first installation, download `bootstrap.sh`, review it, then run it with `bash bootstrap.sh`.

## Source Installer

Run from a Valpo source checkout:

```bash
packaging/install.sh
```

The installer:

- installs runtime packages including Docker, Caddy, curl, build tools, mise, Ruby, Bundler, and gems
- installs checksum-verified `pack` 0.40.8 on Linux amd64/arm64 for Cloud Native Buildpacks
- installs source into `/opt/valpo`
- stores Valpo state under `/var/lib/valpo`
- writes production config to `/etc/valpo/valpo.yml`
- creates the private credential directory at `/var/lib/valpo/secrets`
- writes Valpo-generated Caddy routes to `/var/lib/valpo/caddy/valpo.caddy`
- ensures `/etc/caddy/Caddyfile` imports the generated Valpo Caddy file
- installs systemd units and starts `valpo-api` and `valpo-worker`

Ruby is installed through mise with precompiled binaries enabled:

```bash
MISE_RUBY_COMPILE=false
mise settings set ruby.compile false
```

If mise falls back to compiling Ruby from source, the installer fails.

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

The installer binds `valpo-api` to `127.0.0.1` by default. If you change `api_host` to a non-local address, configure `api_token` in `/etc/valpo/valpo.yml` or set `VALPO_API_TOKEN`; Valpo refuses to boot a non-local API without a token.

CLI calls use `VALPO_API_TOKEN` first, then the `api_token` in the loaded config file. The CLI intentionally has no token command-line flag so credentials do not leak through process listings or shell history.

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

The manifest creates a private App with read-only Contents permission, the `push` event, a signed webhook, and server callback URLs. GitHub returns the generated private key and webhook secret to the callback. Valpo atomically stores them in `/var/lib/valpo/secrets/github-app.json` with mode `0600`, verifies installation redirects against GitHub, and mints short-lived installation tokens for each source fetch.

`auto_deploy = true` sources deploy matching branch pushes. A source using `HEAD` follows pushes to the repository's default branch. Delivery IDs are deduplicated, and a service with an active operation is skipped instead of receiving a second deployment job.

The file-backed PAT remains a temporary migration fallback for existing hosts and smoke tests:

```bash
op read op://vault/github-pat | valpo auth login github --with-token
```

Do not put GitHub App credentials, PATs, or installation tokens in `valpo.yml` or `valpo.toml`. `valpo auth logout github` removes local credentials; remove the installation or App separately in GitHub when retiring it.

Because the App callback and webhook URLs contain the default app domain, Valpo will not replace that domain while App credentials are configured. Log out locally, change the domain, run the App setup again, and delete the old App in GitHub.

## Source Build Configuration

Source services default to build strategy `auto`: Valpo uses a context-root Dockerfile when present and otherwise builds with Cloud Native Buildpacks. Packaged installs pin `pack` under `/var/lib/valpo/.local/bin` and pin the Paketo Ubuntu Noble builder. `/etc/valpo/valpo.yml` controls the build deadline and builder:

```yaml
production:
  build_timeout: 1800
  buildpack_builder: paketobuildpacks/ubuntu-noble-builder@sha256:6576792807752dfc227d0df115c99b0a77d97ddb71b4d6c757e99630c60db019
```

Build output is available through normal job events. Buildpack caches are stable Docker volumes scoped to a build target and are removed when its owning service or project is deleted. A repository `project.toml` is honored, but the configured builder remains explicit. Runtime service secrets are not passed into builds.

On a Linux development host with Docker and `pack`, run the opt-in build/inspect/run smoke test with:

```bash
VALPO_TEST_BUILDPACKS=1 mise exec -- bundle exec ruby -Itest test/integration/buildpack_smoke_test.rb
```

## Templates

The current templates assume:

- Valpo is deployed from a source checkout at `/opt/valpo`.
- Ruby 4.0.5 is installed through mise under `/var/lib/valpo`.
- Bundler has installed dependencies for that checkout.
- Production config lives at `/etc/valpo/valpo.yml`.
- Valpo state lives under `/var/lib/valpo`.

Adjust the `ExecStart` paths or service `PATH` for the Ruby manager used on the host.

`valpo-migrate.service` is a one-shot unit that runs before the API and worker. Keep migrations owned by that unit instead of adding `--migrate` to both long-running services.

## VPS Smoke Test

Run the repeatable VPS smoke test from a local checkout:

```bash
packaging/vps-smoke-test.sh root@162.55.43.108 apps.valpo.dev --reboot
```

By default the smoke test copies the current checkout to `/tmp/valpo-src`, runs the full installer, deploys `nginx:alpine`, verifies HTTPS, releases, logs, optional reboot recovery, and then deletes the project. Use `--skip-deps` only when intentionally testing an update on a host whose dependencies are already installed.

To prove installation from a clean Valpo state, use the guarded destructive wrapper. It removes all Valpo-owned services, runtime resources, state, files, and the dedicated account; verifies their absence; then runs the full smoke test from the local checkout. Docker, Caddy, and other shared host packages remain installed.

```bash
packaging/vps-clean-install-smoke-test.sh root@162.55.43.108 apps.valpo.dev --confirm-destroy-valpo
```

Use the source smoke test on a host whose GitHub PAT is already configured:

```bash
packaging/vps-source-smoke-test.sh root@162.55.43.108 apps.valpo.dev
```

It installs the current checkout, creates a unique project without a manifest, and deploys `holamendi/smol-roda` while omitting ref, build strategy, Dockerfile, context, and port. It verifies automatic Dockerfile selection, the resolved commit, port `3000`, injected `PORT`, HTTPS, and release metadata, then removes only the generated project/runtime resources. The script checks the GitHub credential file digest and `auth status github` before and after; it never logs out or deletes the stored PAT. Use `--repository OWNER/REPO` for another repository or `--skip-install` to test the already-installed version.
