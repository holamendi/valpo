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

The pre-commit hook is check-only: it runs the test suite, Ruby style checks, generated CLI/OpenAPI checks, and documentation-link checks without rewriting the working tree. GitHub Actions runs the same checks on the single supported Ubuntu 26.04 environment, plus Bash syntax validation and ShellCheck for every tracked shell script.

Run or automatically fix Ruby style with:

```bash
mise exec -- bundle exec rake standard
mise exec -- bundle exec rake standard:fix
```

These tasks run Standard plus the repository policies in `.rubocop-project.yml`. Use shorthand values when a keyword or symbol key matches its local variable (`service:`), and use implicit `it` when a single block parameter is only referenced in that block's own scope. Keep a named parameter when it must be referenced from a nested block; the project cop deliberately treats that as a scope boundary.

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

## Repository And Loader Conventions

API, worker, CLI, models, and shared runtime code live in one Ruby gem-style repository. Valpo-owned constants are loaded lazily through Zeitwerk:

- align every production filename with its constant;
- keep one primary production class or module per file; small version-specific contracts may be nested in their owning `API::V1` resource module;
- preserve the `API`, `CLI`, and `GitHub` inflections;
- do not reintroduce internal `require "valpo/..."` chains;
- continue to require standard-library and third-party dependencies explicitly;
- remember that `lib/valpo/models/` is collapsed, so `models/project.rb` defines `Valpo::Project` rather than `Valpo::Models::Project`;
- keep focused tests alongside the source tree, such as `lib/valpo/services/creator.rb` and `test/valpo/services/creator_test.rb`.

Test-local fakes and tiny private test value objects may remain in their owning test. Cohesive Docker/runtime and build-pipeline classes should not be split merely to satisfy a size metric.

The gemspec is used for dependency resolution and gem-style repository structure. RubyGems installation is not a supported distribution path; packaged hosts are installed from a source checkout through `packaging/install.sh`.

## API Maintenance

Resource routes are intentionally incompatible with the old unversioned paths and live under `/v1`. Request bodies use Roda JSON parsing plus `dry-validation` JSON contracts; query shapes have separate contracts. Do not add ad-hoc optional-type helpers or `typecast_params`.

Every terminal route has a comment immediately above its matcher:

```ruby
# POST /v1/projects — create a project.
r.post true do
```

Version-specific contracts and response renderers live together under `API::V1` resource modules. When a route, contract, renderer, or response changes, update both [valpo-api.md](./valpo-api.md) and [openapi.yaml](./openapi.yaml), then run `rake api:check`. The check compares OpenAPI operations with route comments and validates local references and representative contract parity.

## Schema And Release Metadata Policy

`db/migrations/001_bootstrap.rb` is the permanent public bootstrap schema. Never edit it, including for formatting-only changes. Add one new, contiguously numbered migration for every schema change (`002_description.rb`, `003_description.rb`, and so on). `SchemaInfo` checks the frozen bootstrap digest and contiguous sequence before Sequel runs migrations.

Keep migrations self-contained: use Sequel schema/data operations and do not call current application models whose shape may no longer match an older database. New release work must cover fresh migration and upgrade from the previous published schema. Destructive changes should use an expand/contract sequence so the prior code release remains usable during the rollback window.

The tracked `release.json` is the immutable release compatibility manifest. It records the code version, API compatibility version, supported/target database schemas, configuration schema, and host profile. Update it with version or compatibility changes, and ensure its schema target equals the latest migration. Channel, verified archive digest, and installation time belong to the host's separate root-owned installation metadata so the exact same artifact can be promoted without rebuilding it.
