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

Source credentials, GitHub App keys, access tokens, and application secrets never belong in this file. GitHub source and build records remain `unconnected` until Phase 3A implements repository access and Dockerfile builds.

App services receive generated database/cache variables only for services named in `depends_on`. Unknown keys, invalid paths, unsupported versions, and missing source/build/dependency references fail validation before a reconciliation job is queued.
