# Repository Guidelines

## Project Structure & Module Organization

Valpo is a Ruby 4.0.5 application. Production code lives in `lib/valpo/`, grouped by areas such as `api/`, `cli/`, `jobs/`, and `services/`. Executables are in `exe/`; migrations are in `db/migrations/`. Tests mirror source under `test/`, with fakes in `test/support/`. Installation assets belong in `packaging/`; documentation belongs in `docs/`.

Zeitwerk loads Valpo constants. Match filenames to constants, keep one primary class or module per file, and preserve the `API`, `CLI`, and `GitHub` inflections. `lib/valpo/models/project.rb`, for example, defines `Valpo::Project`.

Valpo is pre-release. Do not preserve compatibility with retired APIs, configuration, or internal constants unless explicitly required. The public bootstrap schema is frozen: never edit `db/migrations/001_bootstrap.rb`; add a new contiguous migration for every schema change.

## Build, Test, and Development Commands

- `mise trust && mise install`: install the pinned Ruby toolchain.
- `mise exec -- bundle install`: install gem dependencies.
- `mise exec -- bundle exec rake db:migrate`: prepare the local SQLite database in `tmp/`.
- `mise exec -- bundle exec rake test`: run the complete Minitest suite; plain `rake` is equivalent.
- `mise exec -- bundle exec rake standard`: run Standard Ruby and repository-specific RuboCop checks.
- `mise exec -- bundle exec exe/valpo-api --migrate`: run the API; run `exe/valpo-worker` separately.

## Coding Style & Naming Conventions

Use two-space Ruby indentation and Standard Ruby formatting. Name files and methods in `snake_case`, classes/modules in `CamelCase`, and tests `*_test.rb`. Prefer hash shorthand (`service:`) and implicit `it` for a single block parameter unless a nested block needs it. Run `rake standard:fix` for automatic corrections. Require external dependencies explicitly; do not add internal `require "valpo/..."` chains.

## Testing & Documentation Guidelines

Use Minitest and add focused regression coverage beside the corresponding source path. Run one test with `bundle exec ruby -Itest test/valpo/services/creator_test.rb`. New behavior and bug fixes should exercise success and failure paths.

After CLI changes, run `rake cli:docs` and commit the generated guide. After API changes, update `docs/valpo-api.md` and `docs/openapi.yaml`. Verify documentation with `rake cli:docs:check api:check docs:check`.

## Commit & Pull Request Guidelines

Use `feat:`, `fix:`, `refactor:`, or `docs:` followed by an imperative summary. Keep commits focused. Pull requests should explain the problem and approach, link issues, list verification commands, and include representative CLI/API output for behavior changes. Call out schema, configuration, or deployment impacts.

## Security & Configuration

Keep tokens and local databases out of Git. Use `VALPO_CONFIG` or documented `VALPO_*` environment variables; development state and generated Caddy files remain under ignored `tmp/`.
