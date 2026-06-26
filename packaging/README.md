# Valpo Packaging Templates

These are Ubuntu 26.04 LTS templates, not a host installer.

The current templates assume:

- Valpo is deployed from a source checkout at `/opt/valpo`.
- Ruby 4.0.5 is installed outside the distro Ruby package.
- Bundler has installed dependencies for that checkout.
- Production config lives at `/etc/valpo/valpo.yml`.
- Valpo state lives under `/var/lib/valpo`.

Adjust the `ExecStart` paths or service `PATH` for the Ruby manager used on the host.

`valpo-migrate.service` is a one-shot unit that runs before the API and worker. Keep migrations owned by that unit instead of adding `--migrate` to both long-running services.
