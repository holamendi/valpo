# Valpo

Valpo is a self-hosted platform for deploying containerized web apps and background processes, managing Postgres and Redis, and configuring HTTPS routing on a single VPS.

The project is pre-release and intentionally does not preserve compatibility with retired APIs or internal constants. See the [documentation index](./docs/README.md), [CLI guide](./docs/valpo-cli.md), [API v1 guide](./docs/valpo-api.md), and [OpenAPI 3.1 specification](./docs/openapi.yaml).

## Installation

Valpo currently targets a fresh Ubuntu 26.04 LTS server. Install from a reviewed checkout pinned to an immutable full commit:

```bash
git clone https://github.com/holamendi/valpo.git
cd valpo
git checkout --detach <full-commit-sha>
sudo packaging/install.sh
sudo valpo system status
```

The mutable `packaging/bootstrap.sh` path is development-only, not durable installation guidance. See the [packaging guide](./packaging/README.md) for schema-compatible updates, backups, clean reinstalls, and uninstall behavior.

## Getting Started

Run the remaining installed-host commands with `sudo` (or from a root shell). Deploy `nginx:alpine`:

```bash
sudo valpo project create hello
sudo valpo service create web --project hello --type web --port 80
sudo valpo service deploy web --project hello --image nginx:alpine
```

Without a domain, the release remains private in the `ready` state. To publish it, point `*.apps.example.com` at the server, allow inbound TCP traffic on ports `80` and `443`, then configure the base name without `*.`:

```bash
sudo valpo domain set-default apps.example.com
```

Valpo verifies HTTPS reachability, assigns `web.hello.apps.example.com`, and activates the ready release. Avoid intermediate DNS records such as `hello.apps.example.com`, which can shadow the wildcard.

Alternatively, point a custom domain at the server and attach it directly:

```bash
sudo valpo domain add web hello.example.com --project hello
```

Domain commands verify reachability before exposing the app. Workers and managed services never require a domain.
