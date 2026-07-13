# Valpo Packaging

Valpo currently ships a source installer and Ubuntu 26.04 LTS packaging templates.

## Source Installer

Run from a Valpo source checkout:

```bash
sudo packaging/install.sh
```

Useful options:

```bash
sudo packaging/install.sh --source /path/to/valpo --no-start
sudo packaging/install.sh --skip-deps
```

The installer:

- installs runtime packages including Docker, Caddy, curl, build tools, mise, Ruby, Bundler, and gems
- installs source into `/opt/valpo`
- stores Valpo state under `/var/lib/valpo`
- writes production config to `/etc/valpo/valpo.yml`
- creates the private credential directory at `/var/lib/valpo/secrets`
- writes Valpo-generated Caddy routes to `/var/lib/valpo/caddy/valpo.caddy`
- ensures `/etc/caddy/Caddyfile` imports the generated Valpo Caddy file
- installs systemd units and starts `valpo-api` and `valpo-worker` unless `--no-start` is passed

Ruby is installed through mise with precompiled binaries enabled:

```bash
MISE_RUBY_COMPILE=false
mise settings set ruby.compile false
```

If mise falls back to compiling Ruby from source, the installer fails.

## API Binding And Auth

The installer binds `valpo-api` to `127.0.0.1` by default. If you change `api_host` to a non-local address, configure `api_token` in `/etc/valpo/valpo.yml` or set `VALPO_API_TOKEN`; Valpo refuses to boot a non-local API without a token.

CLI calls use `VALPO_API_TOKEN` first, then the `api_token` in the loaded config file. The CLI intentionally has no token command-line flag so credentials do not leak through process listings or shell history.

## GitHub Source Authentication

Manual private-repository builds use a fine-grained PAT as the temporary Phase 3A credential provider. Store a repository-scoped token with read-only Contents access through the local CLI:

```bash
sudo valpo auth login github
```

The command shows a prefilled GitHub token-creation link with read-only Contents permission, prompts without echo, validates the PAT with GitHub, and atomically writes `/var/lib/valpo/secrets/github-token` with mode `0600`. The worker resolves the file when each source deployment starts, so no restart is needed. Do not put this token in `valpo.yml` or `valpo.toml`.

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

By default the smoke test copies the current checkout to `/tmp/valpo-src`, reinstalls with `--skip-deps`, deploys `nginx:alpine`, verifies HTTPS, releases, logs, optional reboot recovery, and then deletes the project. Use `--full-install` for a fresh Ubuntu host that still needs dependencies.
