# Valpo CLI

This guide is generated from database-free CLI metadata. Run `rake cli:docs` after changing command registration, arguments, or service definitions.

The Valpo CLI uses resource-first commands: choose a resource, then an action. Run `valpo --help`, `valpo RESOURCE --help`, or `valpo RESOURCE ACTION --help` for contextual help. The equivalent `valpo help RESOURCE ACTION` form is also supported.

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
valpo service list [PROJECT]
valpo service create PROJECT/NAME --type TYPE
valpo service show SERVICE
valpo service delete SERVICE --force
valpo service deploy SERVICE
valpo service logs SERVICE
valpo service restart SERVICE
valpo service stop SERVICE
valpo service env SERVICE
valpo service bind APP_SERVICE MANAGED_SERVICE
valpo service unbind APP_SERVICE MANAGED_SERVICE
valpo domain list SERVICE
valpo domain add SERVICE HOSTNAME
valpo domain remove SERVICE HOSTNAME_OR_ID
valpo release list SERVICE
valpo release rollback SERVICE
valpo system status
valpo system repair
valpo version
```

## References

Projects accept a name such as `acme` or a typed ID beginning with `prj_`. Services accept `PROJECT/NAME`, such as `acme/web`, or a typed ID beginning with `svc_`. The CLI resolves named service references through an exact project/service lookup and caches each result for the current invocation.

New services must be named as `PROJECT/NAME`:

```bash
valpo service create acme/web --type web --port 3000
```

## Service Types

| Type | Purpose | Versions |
| --- | --- | --- |
| `web` | HTTP application routed through Caddy | n/a |
| `worker` | Background process without a public route | n/a |
| `postgres` | Private managed PostgreSQL database | 16, 17, 18 (default 18) |
| `redis` | Private managed Redis database | 7, 8 (default 8) |

`command` is valid for `web` and `worker`. `port` and `healthcheck-path` are valid only for `web`. `version` is valid only for `postgres` and `redis`. Incompatible options are rejected rather than ignored. Managed service images are selected by Valpo and cannot be overridden.

## Deployments

Deploy an app service's configured GitHub source at its manifest ref, or override it with a branch, tag, or commit SHA:

```bash
valpo service deploy acme/web
valpo service deploy acme/web --ref release
```

Registry-image deployment remains available as an explicit alternative:

```bash
valpo service deploy acme/web --image ghcr.io/acme/web:latest
```

`--image` and `--ref` are mutually exclusive. Source builds run in the worker and stream Git fetch, Docker build, health-check, and release events through the normal job output.

Authenticate GitHub locally with a non-echoing prompt:

```bash
valpo auth login github
valpo auth status github
valpo auth logout github
```

Interactive login links to GitHub's prefilled fine-grained-token form with read-only Contents permission, then validates the PAT with GitHub before storing it. This proves the token is recognized and identifies its account; repository selection is still verified by the Git fetch during deployment.

`auth login` writes the configured private credential file directly after validation; it does not send the PAT to the Valpo API or put it in a job. For secret-manager automation, pipe one line with `--with-token`. There is intentionally no token-value option because command arguments can leak through shell history and process listings.

```bash
op read op://vault/github-pat | valpo auth login github --with-token
```

## Output

Commands print concise tables or detail views by default. Add `--json` for scripting; stdout then contains exactly one JSON document. Progress, warnings, streamed job events, and errors are written to stderr, so redirecting stdout remains safe.

```bash
valpo service list acme --json
valpo service show acme/web --json
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
