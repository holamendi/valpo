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
valpo service deploy web --project acme
```

Applying configures app services, provisions managed services, and binds dependencies. It does not build a new app release; completion events show the deployment commands.

Applying a manifest is idempotent and adds or updates declared resources. Omitted resources and dependencies are retained; deletion always requires a separate CLI command. A service's type and managed-service version cannot be changed.

Before applying anything, the worker performs source/build preflight for every declared source and build: it resolves the repository and ref, checks the build context, and verifies the selected Dockerfile when applicable. All failures are collected and reported with source/build names. A failed preflight leaves the project, source, build, service, dependency, and applied-manifest marker unchanged.

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

Build targets accept an optional `builder` OCI reference and an optional ordered `buildpacks` array. Omit `builder` to use the server default (the pinned Heroku 26 builder). Omit `buildpacks` to use repository `project.toml` selection or the builder's automatic detection. An explicit list replaces that selection; Valpo emits a precedence notice when `project.toml` exists. Empty lists and duplicates are rejected. To reset either setting in a manifest, remove it and apply again.

```toml
[builds.backend]
source = "backend"
strategy = "buildpack"
builder = "heroku/builder:26"
buildpacks = ["heroku/ruby", "heroku/procfile"]
```

Use a digest reference for reproducible builder selection. Valpo resolves builder and run-image digests before building and records them with the detected buildpack versions and platform. Builder, ordered list, run image, or descriptor changes invalidate the build cache. Custom buildpacks must be compatible with the selected builder; supported references are builder-contained IDs and OCI images, not host paths or classic Heroku Git buildpacks.

These settings belong to the shared build target, so web and worker services can use the same build configuration. CLI updates support `--builder`, `--buildpacks` (comma-separated), `--clear-builder`, and `--clear-buildpacks`.

Buildpacks honor the other settings in `project.toml`. Web services default to the `web` process unless `command` is set; buildpack workers require a command.

Valpo validates the repository, ref, context, and build inputs before changing configuration. A deployment records the exact commit, resolved strategy, image, and available buildpack metadata. GitHub.com shallow single-ref checkouts are supported; Git submodules and Git LFS are not configured.

## Runtime Rules

For web services, an explicit `port` wins. Otherwise Valpo uses the image's sole TCP `EXPOSE` port, then port `3000` for a source image with no exposed port. Ambiguous images and registry images without exactly one exposed TCP port require an explicit port. Valpo injects the resolved value as `PORT`; workers have no platform port.

`depends_on` controls which database and cache variables an app receives. Unknown fields, invalid paths, unsupported versions, and missing source, build, or dependency references fail validation before a reconciliation job is queued.

CLI-created source and build definitions belong to one service. Manifest definitions are project-owned and shareable. Updating a manifest-backed service through the CLI detaches it into private definitions rather than changing shared manifest records.
