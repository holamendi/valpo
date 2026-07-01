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
- writes Valpo-generated Caddy routes to `/var/lib/valpo/caddy/valpo.caddy`
- ensures `/etc/caddy/Caddyfile` imports the generated Valpo Caddy file
- installs systemd units and starts `valpo-api` and `valpo-worker` unless `--no-start` is passed

Ruby is installed through mise with precompiled binaries enabled:

```bash
MISE_RUBY_COMPILE=false
mise settings set ruby.compile false
```

If mise falls back to compiling Ruby from source, the installer fails.

## Templates

The current templates assume:

- Valpo is deployed from a source checkout at `/opt/valpo`.
- Ruby 4.0.5 is installed through mise under `/var/lib/valpo`.
- Bundler has installed dependencies for that checkout.
- Production config lives at `/etc/valpo/valpo.yml`.
- Valpo state lives under `/var/lib/valpo`.

Adjust the `ExecStart` paths or service `PATH` for the Ruby manager used on the host.

`valpo-migrate.service` is a one-shot unit that runs before the API and worker. Keep migrations owned by that unit instead of adding `--migrate` to both long-running services.
