# Valpo Development

Valpo pins Ruby 4.0.5 with mise. Set up a checkout and run its checks with:

```bash
mise trust
mise install
mise exec -- bundle install
mise exec -- bundle exec rake db:migrate
mise exec -- bundle exec rake test
mise exec -- bundle exec rake standard
```

Local defaults keep state under `tmp/`, bind the API to `127.0.0.1:7092`, render generated Caddy configuration under `tmp/`, and use a shared Docker network named `valpo`.

Run the API, worker, and development CLI in separate terminals:

```bash
mise exec -- bundle exec exe/valpo-api --migrate
mise exec -- bundle exec exe/valpo-worker
mise exec -- bundle exec exe/valpo system status
```

Install the repository-managed Git hooks with:

```bash
mise exec -- bundle exec rake hooks:install
```

The pre-commit hook runs tests, style checks, generated-document checks, and link checks without rewriting the working tree. CI adds Bash syntax validation and ShellCheck.

Run or automatically fix Ruby style with:

```bash
mise exec -- bundle exec rake standard
mise exec -- bundle exec rake standard:fix
```

These tasks run Standard plus `.rubocop-project.yml`.

After changing CLI registration, arguments, or service definitions, regenerate the canonical CLI guide:

```bash
mise exec -- bundle exec rake cli:docs
```

Verify generated CLI documentation without rewriting it, validate the API/OpenAPI mirror, and check documentation links with:

```bash
mise exec -- bundle exec rake cli:docs:check
mise exec -- bundle exec rake api:check
mise exec -- bundle exec rake docs:check
```

## Release Artifact Development

`.mise.toml` disables Ruby compilation, and `mise.lock` records attested Linux
x64 and arm64 assets. Regenerate it only when changing Ruby, then review both
platform entries. The builder also pins `mise`, `pack`, the Ubuntu builder, and
the SBOM tool. Native gems compile in a disposable stage; compiler tooling is
not packaged.

Builds must run on the requested native architecture; the scripts intentionally
refuse QEMU or another architecture mismatch:

```bash
packaging/release/build.sh --architecture amd64 --output-dir dist
packaging/release/smoke.sh \
  --architecture amd64 \
  --archive dist/valpo-0.1.0-linux-amd64.tar.zst
```

Set `SOURCE_DATE_EPOCH` to a Unix timestamp for reproducible builds; otherwise
the commit timestamp is used. The build enforces archive size limits. Run
`test/packaging/release_artifact_test.rb` for fast contract checks and the smoke
script for archive, runtime, migration, CLI, and API verification.

## Repository And Loader Conventions

Zeitwerk loads Valpo constants. Repository-specific rules are:

- align every production filename with its constant;
- keep one primary production class or module per file; small version-specific contracts may be nested in their owning `API::V1` resource module;
- preserve the `API`, `CLI`, and `GitHub` inflections;
- do not reintroduce internal `require "valpo/..."` chains;
- continue to require standard-library and third-party dependencies explicitly;
- remember that `lib/valpo/models/` is collapsed, so `models/project.rb` defines `Valpo::Project` rather than `Valpo::Models::Project`;
- mirror production paths under `test/`.

Test-local fakes may remain in their owning test. Do not split cohesive Docker/runtime or build-pipeline classes only to satisfy a size metric. RubyGems installation is unsupported; use `packaging/install.sh`.

## API Maintenance

Resource routes live under `/v1`. Request bodies and query strings use separate `dry-validation` contracts; do not add ad-hoc coercion helpers or `typecast_params`.

Every terminal route has a comment immediately above its matcher:

```ruby
# POST /v1/projects — create a project.
r.post true do
```

Version-specific contracts and renderers live under `API::V1`. When a route, contract, renderer, or response changes, update [valpo-api.md](./valpo-api.md) and [openapi.yaml](./openapi.yaml), then run `rake api:check`.

## Schema And Release Metadata Policy

`db/migrations/001_bootstrap.rb` is the permanent public bootstrap schema. Never edit it, including for formatting-only changes. Add one new, contiguously numbered migration for every schema change (`002_description.rb`, `003_description.rb`, and so on). `SchemaInfo` checks the frozen bootstrap digest and contiguous sequence before Sequel runs migrations.

Keep migrations self-contained: use Sequel schema/data operations and do not call current application models whose shape may no longer match an older database. New release work must cover fresh migration and upgrade from the previous published schema. Destructive changes should use an expand/contract sequence so the prior code release remains usable during the rollback window.

The tracked `release.json` is the immutable release compatibility manifest. It records the code version, API compatibility version, supported/target database schemas, configuration schema, and host profile. Update it with version or compatibility changes, and ensure its schema target equals the latest migration. Channel, verified archive digest, and installation time belong to the host's separate root-owned installation metadata so the exact same artifact can be promoted without rebuilding it.
