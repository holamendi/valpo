# Valpo CLI

This guide is generated from database-free CLI metadata. Run `rake cli:docs` after changing command registration, arguments, or service definitions.

The Valpo CLI uses resource-first commands: choose a resource, then an action. Run `valpo --help`, `valpo RESOURCE --help`, or `valpo RESOURCE ACTION --help` for contextual help. The equivalent `valpo help RESOURCE ACTION` form is also supported.

On an installed host, run the CLI as root; the wrapper drops privileges to the dedicated Valpo user. The examples below therefore use `valpo` directly and can also be used from a development checkout.

## Command Hierarchy

```text
valpo auth login PROVIDER
valpo auth status PROVIDER
valpo auth logout PROVIDER
valpo project list
valpo project create NAME
valpo project show PROJECT
valpo project delete PROJECT
valpo project apply FILE
valpo project logs PROJECT
valpo service list
valpo service create NAME --project PROJECT --type TYPE
valpo service show SERVICE
valpo service update SERVICE
valpo service delete SERVICE --force
valpo service deploy SERVICE
valpo service logs SERVICE
valpo service restart SERVICE
valpo service stop SERVICE
valpo service env SERVICE
valpo service bind APP_SERVICE MANAGED_SERVICE
valpo service unbind APP_SERVICE MANAGED_SERVICE
valpo domain show-default
valpo domain set-default HOSTNAME
valpo domain list SERVICE
valpo domain add SERVICE HOSTNAME
valpo domain verify SERVICE HOSTNAME_OR_ID
valpo domain remove SERVICE HOSTNAME_OR_ID
valpo release list SERVICE
valpo release rollback SERVICE
valpo system status
valpo system repair
valpo version
```

## References

Projects accept a name such as `acme` or a typed ID beginning with `prj_`. Services accept a name such as `web` together with `--project acme`, or a typed ID beginning with `svc_`. Service IDs are globally unambiguous and do not require `--project`. The CLI resolves scoped names through an exact project/service lookup and caches each result for the current invocation.

New services require an explicit project:

```bash
valpo service create web --project acme --type web --port 3000
```

## Service Types

| Type | Purpose | Versions |
| --- | --- | --- |
| `web` | HTTP application routed through Caddy | n/a |
| `worker` | Background process without a public route | n/a |
| `postgres` | Private managed PostgreSQL database | 16, 17, 18 (default 18) |
| `redis` | Private managed Redis database | 7, 8 (default 8) |

`command` is valid for `web` and `worker`. `port` and `healthcheck-path` are valid only for `web`. `version` is valid only for `postgres` and `redis`. Incompatible options are rejected rather than ignored. Managed service images are selected by Valpo and cannot be overridden.

## Domains And Web Activation

Domain configuration happens after Valpo is installed. To use generated app hostnames, point a wildcard such as `*.apps.example.com` at the host, then set and verify its base name:

```bash
valpo domain set-default apps.example.com
valpo domain show-default
```

A web service named `web` in project `acme` receives `web.acme.apps.example.com`. Setting or changing the default reconciles existing web services but never removes custom domains.

A custom domain can be used instead:

```bash
valpo domain add web hello.example.com --project acme
valpo domain verify web hello.example.com --project acme
```

`domain set-default` and `domain add` verify a unique HTTPS challenge through Caddy. A web release without a verified domain remains private in the `ready` state; successful verification activates the latest ready release. Workers and managed services do not require domains.

## Source-Backed Services

A GitHub-backed app service can be created and deployed without `valpo.toml`:

```bash
valpo project create acme
valpo service create web --project acme \
  --type web \
  --source github:acme/backend \
  --deploy
```

`--ref` defaults to remote `HEAD`, `--build-strategy` defaults to `auto`, and `--context` defaults to `.`. Auto builds use `<context>/Dockerfile` when present and otherwise use Cloud Native Buildpacks. Use `--build-strategy dockerfile` or `--dockerfile PATH` to require a Dockerfile, and `--build-strategy buildpack` to ignore one. The repository, ref, context, and selected build inputs are validated before any service configuration is created. No image is built unless deployment is requested. Use `service update` to persist source, build, command, health-check, or port changes; `--deploy` validates, applies, and deploys the update as one operation.

```bash
valpo service update web --project acme --ref release --deploy
valpo service update web --project acme --build-strategy buildpack --deploy
valpo service update web --project acme --clear-command --clear-healthcheck --clear-port
```

An omitted web port is resolved after the image is available: explicit configuration wins, then a sole TCP `EXPOSE`, then port `3000` for a source image with no exposed port. Ambiguous images and registry images without exactly one exposed TCP port require `--port`.

## Deployments

Deploy an app service's configured GitHub source, or override it once with a branch, tag, or commit SHA:

```bash
valpo service deploy web --project acme
valpo service deploy web --project acme --ref release
```

Registry-image deployment remains available as an explicit alternative:

```bash
valpo service deploy web --project acme --image ghcr.io/acme/web:latest
```

`--image` and `--ref` are mutually exclusive. Source builds run in the worker and stream Git fetch, Dockerfile or buildpack output, health-check, and release events through the normal job output. Buildpack workers require an explicit service command.

Connect GitHub with a private, per-server GitHub App:

```bash
valpo auth login github
valpo auth status github
valpo auth logout github
```

`auth login` requires a verified default app domain and prints a one-time HTTPS setup URL. Open it, name the private GitHub App, create it from Valpo's manifest, and choose the repositories it may access. Valpo reserves `github.<app-domain>` for the manifest callback and signed push webhook. The App requests read-only Contents permission and the `push` event.

A private GitHub App can only be installed on its owning account. Use `--organization ORG` when the repositories belong to an organization; omit it for repositories owned by your personal account.

```bash
valpo auth login github --organization acme
```

GitHub returns the App ID, private key, and webhook secret directly to the server callback. Packaged hosts store them in `/var/lib/valpo/secrets/github-app.json` with mode `0600`. Source fetches mint short-lived installation tokens for the requested repository; private keys, webhook secrets, and installation tokens never enter manifests, API payloads, jobs, Git remotes, logs, or process arguments.

The fine-grained PAT path remains as a temporary migration fallback. Pipe one token line explicitly with `--with-token`; there is intentionally no token-value option because command arguments can leak through shell history and process listings.

```bash
op read op://vault/github-pat | valpo auth login github --with-token
```

`auth logout github` removes local credentials only. It does not uninstall or delete the GitHub App on GitHub.

## Output

Commands print concise tables or detail views by default. Add `--json` for scripting; stdout then contains exactly one JSON document. Progress, warnings, streamed job events, and errors are written to stderr, so redirecting stdout remains safe.

```bash
valpo service list --project acme --json
valpo service show web --project acme --json
```

## Waiting

Operations wait for their background job by default and stream each unseen job event to stderr. The default timeout is 600 seconds.

- Use `--no-wait` to return the queued job immediately.
- Use `--timeout SECONDS` to change the maximum wait.
- The server API stays asynchronous; waiting is a CLI behavior.

## Exit Codes

- `0`: command completed successfully.
- `1`: API, background job, network, or runtime operation failed.
- `2`: command usage, arguments, or options are invalid.

## Configuration

The API URL defaults to `http://127.0.0.1:7092` and can be set with `--api-url` or `VALPO_API_URL`. Use `--config PATH` or `VALPO_CONFIG` to load a Valpo configuration file. API authentication is read from `VALPO_API_TOKEN` first, then `api_token` in the configuration file.

Global options may appear before or after the resource command:

```bash
valpo --api-url http://127.0.0.1:7092 project list
valpo project list --config /etc/valpo/valpo.yml
```

`valpo version` is fully offline. `valpo system status` calls `/health` and reports whether the client and server versions match.

## Advanced Job Inspection

Jobs are an operational detail, so they are omitted from primary root help. They remain available for troubleshooting:

```text
valpo job list
valpo job show ID
valpo job wait ID
valpo job events ID
```

Normal workflows should rely on default waiting or `--no-wait`; use the job commands when investigating queue or worker behavior.
