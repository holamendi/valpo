# Valpo Project Manifest

`valpo.toml` describes one project containing named sources, image build targets, app services, and managed services. The server database remains authoritative; applying a manifest is an explicit reconciliation operation.

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

Preview and apply it with:

```bash
valpo project apply valpo.toml --dry-run
valpo project apply valpo.toml
```

Applying is idempotent and creates or updates declared records. Omitted records and dependencies are retained; deletion always requires an explicit CLI operation. Service kind and managed-service version are immutable in this version.

Source credentials, GitHub App keys, access tokens, and application secrets never belong in this file. GitHub repositories use the `owner/repository` form; clone URLs are rejected.

## GitHub App Authentication And Push Deployments

Configure and verify the default app domain, then start the per-server GitHub App flow:

```bash
valpo auth login github
```

The command prints a one-time setup URL under `github.<app-domain>`. The wildcard DNS used by generated application domains already covers this host. Open the URL, name the private App, create it from Valpo's manifest, and choose the repositories it may access.

A private App can only be installed on its owning account. For repositories owned by an organization, create the App under that organization:

```bash
valpo auth login github --organization acme
```

The manifest requests read-only repository Contents permission and subscribes to `push`. GitHub redirects the browser with a temporary conversion code; the server exchanges it within the allowed hour and stores the generated App ID, private key, and webhook secret. The post-install redirect is verified with an App JWT instead of trusting the browser-provided installation ID.

Inspect or remove the credential without revealing it:

```bash
valpo auth status github
valpo auth logout github
```

On a packaged host, the callback atomically writes `/var/lib/valpo/secrets/github-app.json` with mode `0600`. Each checkout looks up the App installation for the repository and mints a short-lived Contents-read token. The private key, webhook secret, and installation tokens never enter the project manifest, SQLite, API request bodies, jobs, Git remotes, logs, or process arguments.

For a manifest source with `auto_deploy = true`, a signed push to its configured branch enqueues an exact-commit deployment. `ref = "HEAD"` follows the repository's default branch. Webhook delivery IDs are persisted for replay protection; a push is skipped for a service that already has an active operation.

The fine-grained PAT path remains temporarily available for migration and source smoke tests. It must be piped explicitly, so the token does not enter shell history or process arguments:

```bash
op read op://vault/github-pat | valpo auth login github --with-token
```

The App path takes precedence when both credential files exist. `auth logout` removes local credentials only; uninstall or delete the App separately in GitHub when retiring it.

Then deploy the configured ref, or override it for one deployment:

```bash
valpo service deploy web --project acme
valpo service deploy web --project acme --ref feature/candidate
```

A manifest is optional for a service owned by one CLI workflow. The equivalent manifest-free flow is:

```bash
valpo project create acme
valpo service create web --project acme \
  --type web \
  --source github:acme/backend \
  --deploy
```

An omitted ref resolves remote `HEAD`; build strategy and context default to `auto` and `.`. With `auto`, Valpo uses `Dockerfile` in the selected context when it exists and otherwise runs a Cloud Native Buildpacks build. Selecting `dockerfile` explicitly requires that Dockerfile to exist and never falls through to buildpacks after a Docker build failure. Selecting `buildpack` ignores repository Dockerfiles. Every source-backed create performs an authenticated shallow checkout, resolves an exact commit, and verifies the selected context and build inputs before creating any records. It does not build unless `--deploy` is present. `service update` performs the same preflight before source or build changes are committed:

```bash
valpo service update web --project acme --ref release --deploy
valpo service update web --project acme --dockerfile ops/Dockerfile --context .
valpo service update web --project acme --build-strategy buildpack --deploy
valpo service update web --project acme --clear-port
```

CLI-created source and build definitions are private to that service. Manifest definitions remain project-owned and shareable; updating a manifest-backed service through the CLI detaches the service into private definitions instead of mutating shared manifest records.

The manifest accepts these build strategies:

- `auto` (default): use `<context>/Dockerfile` when present, otherwise use buildpacks.
- `dockerfile`: use `dockerfile`, defaulting to `Dockerfile`; the path must stay inside the checkout.
- `buildpack`: use the configured Cloud Native Buildpacks builder; `dockerfile` is invalid.

Buildpack builds use `pack` and honor a repository `project.toml`. Valpo's configured `buildpack_builder` is passed explicitly and therefore remains the platform-selected builder. Web builds select `web` as the default process and may instead use an explicit service command. Buildpack worker services must define an explicit command, for example `command = ["bundle", "exec", "sidekiq"]`.

For web services, an explicit configured or deployment port wins. Otherwise Valpo uses the image's sole TCP `EXPOSE` port. Source images with no exposed TCP port fall back to `3000`; ambiguous source images and registry images without exactly one exposed TCP port require `--port`. Every web container receives `PORT` with the resolved value, and the release stores that value. Worker services receive no platform port.

Valpo fetches into a temporary checkout, builds the selected Dockerfile or buildpack context, tags the local image by project, build target, and commit, and records the exact commit and resolved build strategy on the release. Buildpack releases also record the pinned builder, detected buildpacks, and process types when image inspection succeeds. A create-with-deploy reuses the validated checkout rather than fetching twice. Build output streams through job events, and builds fail after the configured timeout. Named build and launch cache volumes are reused per build target and removed with the owning service or project. The repository credential is supplied to Git through an askpass environment. Runtime service secrets are not passed to buildpacks.

This integration currently supports GitHub.com and shallow single-ref checkouts without Git submodule or Git LFS setup. Valpo stores one private App per server, and a private App can only access repositories belonging to its owning personal account or organization. Repositories split across multiple owners will require a future multi-App credential model. Valpo does not yet expose repository discovery or installation management beyond GitHub's installation UI.

App services receive generated database/cache variables only for services named in `depends_on`. Unknown keys, invalid paths, unsupported versions, and missing source/build/dependency references fail validation before a reconciliation job is queued.
