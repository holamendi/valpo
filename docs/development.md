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

Run or automatically fix Ruby style with:

```bash
mise exec -- bundle exec rake standard
mise exec -- bundle exec rake standard:fix
```

After changing CLI registration, arguments, or service definitions, regenerate the canonical CLI guide:

```bash
mise exec -- bundle exec rake cli:docs
```

## Pre-release Database Compatibility

Valpo has not been released, so all current schema is kept in the first migration and that migration may be rewritten. If a development database reports a migration version newer than the migrations in the checkout, back it up if necessary, remove it, and run the migrations again. The default development database is `tmp/valpo-development.sqlite3`.

Valpo also detects the retired project-as-app schema and refuses to discard it automatically.
