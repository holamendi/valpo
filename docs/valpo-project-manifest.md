# Valpo Project Manifest

`valpo.toml` describes one project containing sources, builds, app services, and managed services. The server database remains authoritative; the manifest changes it only when explicitly applied.

```toml
schema = 1

[project]
name = "acme"

[sources.backend]
provider = "github"
repository = "acme/backend"
ref = "main"
auto_deploy = true

[builds.backend]
source = "backend"
strategy = "auto"
context = "."

[services.web]
type = "web"
build = "backend"
command = ["bundle", "exec", "puma"]
port = 3000
healthcheck = "/health"
depends_on = ["database", "cache"]

[services.worker]
type = "worker"
build = "backend"
command = ["bundle", "exec", "sidekiq"]
depends_on = ["database", "cache"]

[services.database]
type = "postgres"
version = "18"

[services.cache]
type = "redis"
version = "8"
```

Preview and apply changes with:

```bash
valpo project apply valpo.toml --dry-run
valpo project apply valpo.toml
```

Applying a manifest is idempotent and adds or updates declared resources. Omitted resources and dependencies are retained; deletion always requires a separate CLI command. A service's type and managed-service version cannot be changed.

Secrets, source credentials, GitHub App keys, and access tokens do not belong in the manifest. GitHub repositories use `owner/repository`, not clone URLs.

## Sources And Builds

GitHub sources support a branch, tag, commit, or `HEAD`. `HEAD` follows the repository's default branch. A source with `auto_deploy = true` deploys signed pushes to its configured branch; Valpo deduplicates webhook deliveries and skips a service that already has an active operation.

Authenticate through a private per-server GitHub App:

```bash
valpo auth login github
```

Use `--organization ORG` when the repositories belong to an organization. An encrypted fine-grained PAT is available when one App cannot cover the required repository owners. See the [CLI guide](./valpo-cli.md#deployments) for setup and credential behavior.

Build strategies are:

- `auto` (default): use `<context>/Dockerfile` when present; otherwise use Cloud Native Buildpacks.
- `dockerfile`: require `dockerfile`, which defaults to `Dockerfile` and must remain inside the checkout.
- `buildpack`: use the configured builder and reject a `dockerfile` field.

Buildpacks honor `project.toml`, but Valpo selects the builder. Web services default to the `web` process unless `command` is set; buildpack workers require a command.

Valpo validates the repository, ref, context, and build inputs before changing configuration. A deployment records the exact commit, resolved strategy, image, and available buildpack metadata. GitHub.com shallow single-ref checkouts are supported; Git submodules and Git LFS are not configured.

## Runtime Rules

For web services, an explicit `port` wins. Otherwise Valpo uses the image's sole TCP `EXPOSE` port, then port `3000` for a source image with no exposed port. Ambiguous images and registry images without exactly one exposed TCP port require an explicit port. Valpo injects the resolved value as `PORT`; workers have no platform port.

`depends_on` controls which database and cache variables an app receives. Unknown fields, invalid paths, unsupported versions, and missing source, build, or dependency references fail validation before a reconciliation job is queued.

CLI-created source and build definitions belong to one service. Manifest definitions are project-owned and shareable. Updating a manifest-backed service through the CLI detaches it into private definitions rather than changing shared manifest records.
