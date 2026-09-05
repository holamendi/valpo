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

The source installer is the development bootstrap. Existing installations support transactional artifact upgrades with local checkpoints and interrupted-upgrade recovery; fresh-host artifact installation and off-host backup/restore remain planned. See the [packaging guide](./packaging/README.md) for host operations and the [release lifecycle](./docs/valpo-release-lifecycle.md) for the production contract.

## Updating An Installed Host

Updates currently require a newer native release archive and a trusted checksum:

```bash
sudo valpo-upgrade apply /path/to/valpo-VERSION-linux-amd64.tar.zst \
  --sha256 VERIFIED_SHA256 --channel development
sudo valpo system status
```

Use `development` for locally built artifacts; `preview` and `stable` also require
verified tagged release-workflow provenance. Tag-only discovery and downloads
are planned, not available yet. See the [upgrade guide](./packaging/README.md#host-upgrades)
for first-use setup, tool refresh, and `valpo-upgrade recover`.

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

Valpo verifies HTTPS, assigns `hello-web.apps.example.com`, and activates the release. Generated names use one stable service slug; collisions receive a random suffix. For Cloudflare Universal SSL, use the zone root (for example, `example.com`) as the default so generated names remain first-level subdomains.

Alternatively, point a custom domain at the server and attach it directly:

```bash
sudo valpo domain add web hello.example.com --project hello
```

Domain commands verify reachability before exposing an app. Workers and managed services do not need domains.
