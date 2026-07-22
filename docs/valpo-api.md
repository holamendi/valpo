# Valpo API v1

Valpo exposes a JSON HTTP API for the bundled CLI and future dashboard clients. The API is pre-release: resource operations live under `/v1`, and incompatible changes may be made before the first release. `GET /` and `GET /health` remain unversioned.

The complete machine-readable contract is [openapi.yaml](./openapi.yaml). Named contracts nested in the `API::V1` resource modules are the runtime authority; OpenAPI is the maintained public mirror and is checked against every standardized route comment. The same resource modules render response hashes without a serializer framework.

## Authentication

When `api_token` is configured, every endpoint requires:

```http
Authorization: Bearer TOKEN
```

The API binds to localhost by default. Non-local binding requires an API token. SSH tunnels or a private network remain the preferred access path; the current bearer token is host-wide and is not yet scoped or revocable.

## Requests And Validation

Body operations require `Content-Type: application/json` and a JSON object. Roda parses the transport; one `dry-validation` contract per request shape validates the object.

Body contracts:

- preserve native JSON booleans, integers, arrays, objects, and `null` values;
- reject malformed JSON, scalar or array bodies, missing fields, unknown fields, nested unknown fields, wrong types, empty required strings, invalid paths, and out-of-range ports;
- accept `internal_port` as the only API port field;
- use `[]` to clear a command and `null` to clear `internal_port` or `healthcheck_path`.

Query contracts reject every undeclared key. Positive integer queries use parameter coercion. Boolean queries accept only the literal serialized values `true` and `false`.

Shape and type failures return `400 invalid_request`. Cross-field or stateful rules remain Ruby domain validation and return `422 validation_failed`; examples include service-type-specific options, source/build relationships, `image`/`ref` exclusivity, deployment readiness, and forced deletion.

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

`details` is optional. Each entry contains the dotted field path, dry predicate code, and human-readable text.

## Errors

Error envelopes are flat and stable:

| Status | Code | Meaning |
| --- | --- | --- |
| `400` | `invalid_request` | Transport, body/query shape, type, or range failure |
| `401` | `unauthorized` | Missing or invalid bearer token |
| `404` | `not_found` | Unknown resource, path, or trailing segment |
| `409` | `conflict` | Valid operation conflicts with current state |
| `422` | `validation_failed` | Valid request shape fails a semantic rule |
| `500` | `internal_error` | Unexpected failure; the client receives a generic message and the server logs the exception |

Every terminal route is exact. Unsupported methods, retired unversioned resource paths, unknown paths, and extra trailing segments return a JSON 404 response.

## Maintenance

After changing a route, contract, renderer, or response:

1. Update the operation comment immediately above the terminal Roda matcher: `# METHOD /path — concise purpose`.
2. Update [openapi.yaml](./openapi.yaml).
3. Run `mise exec -- bundle exec rake api:check` and `mise exec -- bundle exec rake test`.

The checks validate OpenAPI YAML structure, unique operation IDs, local references, request-schema parity, and exact equality between OpenAPI operations and route comments.
