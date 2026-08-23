# Valpo

Valpo deploys containerized web apps and workers, manages Postgres and Redis, and configures HTTPS routing on a single VPS.

Valpo is pre-release. See the [documentation index](./docs/README.md) for CLI, API, manifest, and operations guides.

## Development Installation

The current source installer targets a fresh Ubuntu 26.04 LTS server. Install a reviewed commit with:

```bash
git clone https://github.com/holamendi/valpo.git
cd valpo
git checkout --detach <full-commit-sha>
sudo packaging/install.sh
sudo valpo system status
```

This is a development path: transactional upgrades and recovery are not implemented. See the [packaging guide](./packaging/README.md) for host operations and the [release lifecycle](./docs/valpo-release-lifecycle.md) for the production contract.

## Getting Started

Run installed-host commands as root. Deploy `nginx:alpine`:

```bash
sudo valpo project create hello
sudo valpo service create web --project hello --type web --port 80
sudo valpo service deploy web --project hello --image nginx:alpine
```

Without a domain, the release remains private in the `ready` state. To publish it, point `*.apps.example.com` at the server, allow inbound TCP traffic on ports `80` and `443`, then configure the base name without `*.`:

```bash
sudo valpo domain set-default apps.example.com
```

Valpo verifies HTTPS, assigns `web.hello.apps.example.com`, and activates the release. Avoid intermediate DNS records such as `hello.apps.example.com`, which can shadow the wildcard.

Alternatively, point a custom domain at the server and attach it directly:

```bash
sudo valpo domain add web hello.example.com --project hello
```

Domain commands verify reachability before exposing an app. Workers and managed services do not need domains.
