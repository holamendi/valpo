# Valpo Project Manifest

`valpo.toml` describes one project containing named sources, Docker build targets, app services, and managed services. The server database remains authoritative; applying a manifest is an explicit reconciliation operation.

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
dockerfile = "Dockerfile"
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

## Manual GitHub Deployments With A PAT

For the Phase 3A bootstrap, store a fine-grained personal access token through the local CLI:

```bash
valpo auth login github
GitHub PAT:
```

The prompt does not echo. The command deliberately has no token-value option, so the PAT does not enter shell history or process arguments. For secret-manager automation, pipe one line explicitly:

```bash
op read op://vault/github-pat | valpo auth login github --with-token
```

Interactive login displays a [prefilled fine-grained-token form](https://github.com/settings/personal-access-tokens/new?name=Valpo&description=Source+deployments+for+Valpo&expires_in=90&contents=read) with read-only Contents permission. After entry, Valpo calls GitHub's authenticated-user endpoint and stores the PAT only if GitHub accepts it. That endpoint requires no additional fine-grained permissions; repository selection and Contents access are ultimately verified by the Git fetch during deployment.

Inspect or remove the credential without revealing it:

```bash
valpo auth status github
valpo auth logout github
```

Select only the repositories Valpo needs and grant read-only repository Contents access. GitHub documents both [fine-grained token creation](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) and [PAT authentication for HTTPS Git operations](https://docs.github.com/en/get-started/git-basics/about-remote-repositories#cloning-with-https-urls). Public repositories can be fetched without a token.

On a packaged host, the command atomically writes `/var/lib/valpo/secrets/github-token` with mode `0600`. The worker reads it when a source deployment starts, so changing the PAT does not require a restart.

Then deploy the configured ref, or override it for one deployment:

```bash
valpo service deploy acme/web
valpo service deploy acme/web --ref feature/candidate
```

A manifest is optional for a service owned by one CLI workflow. The equivalent manifest-free flow is:

```bash
valpo project create acme
valpo service create acme/web \
  --type web \
  --source github:acme/backend \
  --deploy
```

An omitted ref resolves remote `HEAD`; Dockerfile and context default to `Dockerfile` and `.`. Every source-backed create performs an authenticated shallow checkout, resolves an exact commit, and verifies that both build paths exist and stay inside the checkout before creating any records. `service update` performs the same preflight before source or build changes are committed:

```bash
valpo service update acme/web --ref release --deploy
valpo service update acme/web --dockerfile ops/Dockerfile --context .
valpo service update acme/web --clear-port
```

CLI-created source and build definitions are private to that service. Manifest definitions remain project-owned and shareable; updating a manifest-backed service through the CLI detaches the service into private definitions instead of mutating shared manifest records.

For web services, an explicit configured or deployment port wins. Otherwise Valpo uses the image's sole TCP `EXPOSE` port. Source images with no exposed TCP port fall back to `3000`; ambiguous source images and registry images without exactly one exposed TCP port require `--port`. Every web container receives `PORT` with the resolved value, and the release stores that value. Worker services receive no platform port.

Valpo fetches into a temporary checkout, builds the configured Dockerfile/context, tags the local image by project, build target, and commit, and records the exact commit on the release. A create-with-deploy reuses the validated checkout rather than fetching twice. The PAT is supplied to Git via an askpass environment and is never stored in the manifest, SQLite, API requests, job payloads, Git remotes, logs, or process arguments.

This bootstrap has deliberate limits: one server-wide token, GitHub.com only, manual deploys only, and shallow single-ref checkouts without Git submodule or Git LFS setup. Fine-grained PATs are also tied to one resource owner, so this is suitable for an initial single-owner server but not the final multi-owner credential model. GitHub App installation tokens remain the Phase 3A destination.

App services receive generated database/cache variables only for services named in `depends_on`. Unknown keys, invalid paths, unsupported versions, and missing source/build/dependency references fail validation before a reconciliation job is queued.
