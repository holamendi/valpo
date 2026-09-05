# Valpo API v1

Valpo exposes a JSON HTTP API for the bundled CLI and future dashboard clients. The API is pre-release: resource operations live under `/v1`, and incompatible changes may be made before the first release. `GET /` and `GET /health` remain unversioned.

The complete machine-readable contract is [openapi.yaml](./openapi.yaml). Runtime request contracts are authoritative; automated checks keep OpenAPI aligned with them and the registered routes.

`GET /health` reports process health plus the server release, API compatibility version, current and target database schemas, configuration schema, host-profile version, release channel, and artifact digest. Development checkouts have a `null` artifact digest. The current release refuses to boot when its database schema does not match the target recorded in `release.json`.

## Authentication

API credentials are scoped and revocable. The raw bearer value is returned only at creation; Valpo stores its SHA-256 digest. After one-time bootstrap, control-plane endpoints always require:

```http
Authorization: Bearer TOKEN
```

Create the first credential from the local host with `valpo auth token create NAME`. The bootstrap credential must have `admin` scope. Before that succeeds, the only unauthenticated control-plane operation is an exact local `POST /v1/api-credentials`; all other paths fail closed. Bootstrap is persisted as complete and never reopens when credentials are revoked or expire.

Credentials may have `admin`, `read`, or `write` scopes; only an admin credential can issue, list, or revoke them through `/v1/api-credentials`, so `write` cannot be escalated into `admin`. Valpo refuses to revoke the final active admin. If all admin tokens are lost or expire, stop or network-isolate the API and run `valpo auth token recover NAME --confirm-offline-recovery` on the host. The command directly opens the configured SQLite database, refuses recovery while an active admin exists, and does not reopen HTTP bootstrap. The API binds to localhost by default and refuses a non-local binding until an active credential exists. Supply a token to the CLI through `VALPO_API_TOKEN`.

GitHub integration endpoints are the only public exception. Caddy exposes `github.<app-domain>/integrations/github`; setup uses one-time state, installation redirects are verified against the App, and webhooks require GitHub's `X-Hub-Signature-256` HMAC. Other API paths remain private.

`POST /v1/auth/github` creates the one-hour setup URL used by `valpo auth login github`; its optional `organization` field selects organization ownership instead of the current user's personal account. `POST /v1/auth/github/pat` validates and stores an encrypted fallback PAT. `GET /v1/auth/github` returns only non-secret identity, and `DELETE /v1/auth/github` removes all local GitHub credential records without deleting the App on GitHub.

The GitHub App callback and webhook URLs contain the default app domain. Valpo therefore blocks app-domain replacement while App credentials are configured. Remove the local authentication, replace the domain, create the new App, and delete the retired App in GitHub.

OpenAPI marks these integration operations with `security: []` because they use integration-specific authentication instead of bearer tokens. Webhook bodies are limited to 25 MiB before HMAC validation.

## Requests And Validation

Body operations require `Content-Type: application/json` and a JSON object.

Body contracts:

- preserve native JSON booleans, integers, arrays, objects, and `null` values;
- reject malformed JSON, scalar or array bodies, missing fields, unknown fields, nested unknown fields, wrong types, empty required strings, invalid paths, and out-of-range ports;
- accept `internal_port` as the only API port field;
- use `[]` to clear a command and `null` to clear `internal_port` or `healthcheck_path`.

Query contracts reject every undeclared key. Positive integer queries use parameter coercion. Boolean queries accept only the literal serialized values `true` and `false`.

Shape and type failures return `400 invalid_request`. Cross-field or state-dependent failures return `422 validation_failed`; examples include incompatible service options, source/build relationships, `image`/`ref` exclusivity, deployment readiness, and forced deletion.

Source-backed app requests accept `build.strategy` as `auto`, `dockerfile`, or `buildpack`. It defaults to `auto`; supplying `build.dockerfile` without a strategy selects `dockerfile`, while combining a Dockerfile with `auto` or `buildpack` is rejected. `auto` resolves to Dockerfile only when `<context>/Dockerfile` exists, otherwise it resolves to buildpacks. Release responses expose the resolved strategy under `build`; Dockerfile releases include the path, while buildpack releases may include builder, buildpack, and process metadata. Registry releases return `"build": null`.

Service records retain `kind` internally, but every public service and project-log response exposes that field as `type`. Managed-service responses have no `plan` field. Effective environment entries identify whether they originate from a custom service variable or a managed dependency. Custom values are encrypted and sensitive by default; sensitive custom values and managed binding credentials are redacted for normal reads, including reads made with a `read` credential. `GET /v1/services/{service}/env?reveal=true` requires an `admin` credential and returns `403 forbidden` for every other credential. Authorized reveals return the plaintext values. Managed binding values are derived from encrypted managed credentials rather than persisted as a second copy.

## Bounded Lists And Logs

- `GET /v1/jobs` accepts `limit`; the default is `100` and the maximum is `500`.
- `GET /v1/jobs/{id}/events` accepts `after` and `limit`; the default is `200` and the maximum is `500`. `after` is an event ID from the same job, and events are ordered by creation time and ID.
- Mutating endpoints that enqueue work accept an optional `Idempotency-Key` header (maximum 255 bytes). Repeating the same request key returns the original job, including after it finishes; reusing it for a different job type returns `409`.
- Jobs expose indexed ownership, attempt and operation-generation counters, recovery strategy, latest checkpoint, lease expiry, and any required recovery action. `POST /v1/jobs/{id}/retry` requeues a failed retryable or resumable job. `POST /v1/jobs/{id}/reconcile` creates one deduplicated whole-system repair for an interrupted compensating job.
- Service and project log endpoints accept `tail`; the default is `200` and the maximum is `10,000`.

Clients waiting on a job must drain every event page before advancing the cursor. Daily storage maintenance expires completed jobs, their events, and GitHub webhook deliveries according to the host retention configuration.

`POST /v1/system/maintenance` enqueues an ownership-scoped cleanup job and accepts an optional `dry_run` boolean. Cleanup retains the configured number of deployable local build artifacts per service, marks older artifacts unavailable without deleting their release history, removes stale buildpack caches and orphaned Valpo containers, and leaves registry images, managed data volumes, unrelated Docker resources, and global Dockerfile build cache untouched.

`POST /v1/system/secrets/verify` requires an admin credential and enqueues decryption and format verification for every encrypted managed-service credential, custom service environment variable, and provider credential. `POST /v1/system/secrets/rotate` also requires admin scope; it verifies the current records, adds a new active host-key version, re-encrypts every record in one SQLite transaction, and verifies the result. Old key versions remain in the keyring so interrupted rotation does not make existing ciphertext unrecoverable. Safe record counts and active key versions are written to job events; plaintext values never enter jobs or events.

Example validation response:

```json
{
  "error": "invalid_request",
  "message": "Request validation failed",
  "details": [
    {
      "field": "source.token",
      "code": "unexpected_key",
      "message": "is not allowed"
    }
  ]
}
```

`details` is optional. Each entry contains a dotted field path, machine-readable code, and human-readable message.

## Errors

Error envelopes are flat and stable:

| Status | Code | Meaning |
| --- | --- | --- |
| `400` | `invalid_request` | Transport, body/query shape, type, or range failure |
| `401` | `unauthorized` | Missing or invalid bearer token |
| `403` | `forbidden` | Valid bearer credential lacks the required scope |
| `404` | `not_found` | Unknown resource, path, or trailing segment |
| `409` | `conflict` | Valid operation conflicts with current state |
| `413` | `payload_too_large` | Request body exceeds the supported limit |
| `422` | `validation_failed` | Valid request shape fails a semantic rule |
| `500` | `internal_error` | Unexpected failure; the client receives a generic message and the server logs the exception |

Unsupported methods, unversioned resource paths, unknown paths, and extra trailing segments return a JSON 404 response.
