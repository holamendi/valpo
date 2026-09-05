# Persistent Live Testing Server

This is a pre-release testing environment, not a supported production host.
It is separate from the canonical `valpo` E2E VM. Do not run destructive E2E
scripts against it or install Valpo on Starbook itself.

## Inventory

- SSH host: `pablo@starbook` over Tailscale.
- Incus VM: `valpo-live`, Ubuntu 26.04, 4 CPUs, 8 GiB RAM, 80 GiB disk.
- Reserved guest address: `10.238.201.30` on `incusbr0`.
- Application: `https://live.valpo.dev`.
- Secondary domain-attachment canary: `https://verify-live.valpo.dev`.
- Authenticated API: `https://api-live.valpo.dev`.
- Cloudflare Tunnel: `valpo-live`, ID `574e9c61-2c32-4392-9859-368ca5b37ef3`.
- Initial source revision: `9191d62990194fbfb4053c159498920757a99b4a`.
- Initial stopped-VM recovery snapshot: `initial-20260905`.
- Pre-fix recovery snapshot: `before-domain-fix-20260905`.

The installed source revision is `3ae45b29b4c3bb7c9f75a106b04a776b2ce629ce`,
recorded in `/etc/valpo/source-revision`. It includes stable single-label service
slugs (schema 5) and releases database read cursors before domain network
verification. It also recognizes lowercase Docker missing-volume errors for
Postgres provisioning. The recovery snapshot for this update is
`before-postgres-buildpack-20260905`.

On the operator's Mac, the `live` CLI profile selects `https://api-live.valpo.dev`
with a dedicated `pablo-mac` admin credential. Login stores credentials in
`~/.config/valpo/cli.json` with mode 0600 inside a mode-0700 directory. Tokens
are plaintext; keep this file out of Git and shared folders. To configure
another computer, issue a separate token and enter it at the hidden prompt:

```bash
valpo login --server https://api-live.valpo.dev --name live
valpo system status
```

`VALPO_API_TOKEN` overrides the saved token. Explicit `VALPO_API_URL` or
`--api-url` uses only the environment token, preventing a saved credential
from being sent to another endpoint. `valpo logout --revoke` revokes the
selected saved credential and removes its local profile.

Porkbun remains the registrar; Cloudflare hosts DNS. Each public hostname uses
a proxied CNAME pointing at the dedicated tunnel. `*.valpo.dev` also points
at this tunnel for generated service domains and the GitHub integration. Existing `apps.valpo.dev`
and `*.apps.valpo.dev` records belong to other infrastructure.

The tunnel runs inside the VM. It forwards application ACME HTTP-01 paths to
local Caddy port 80, other application traffic to verified HTTPS on port 443
with `matchSNItoHost`, and API traffic to loopback port 7092. The API requires
a credential before its tunnel route is activated. Unknown hosts return 404.

Configuration and tunnel credentials reside under `/etc/cloudflared`.
The operator token is root-owned under `/root/.config/valpo/operator-token`
with mode 0600. Do not print it or commit it. Use the root-only
`/usr/local/sbin/valpo-operator` wrapper for authenticated operations:

```bash
ssh pablo@starbook 'incus exec valpo-live -- valpo-operator system status'
ssh pablo@starbook 'incus exec valpo-live -- valpo-operator service show web --project live-canary'
```

The verified default app domain is `valpo.dev`. The canary
uses `https://live-canary-web.valpo.dev`, with its existing custom domains
preserved. GitHub setup and webhooks use `https://github.valpo.dev`.
Wildcard tunnel rules follow the explicit API and canary rules, routing ACME
challenges to Caddy port 80 and other traffic to verified HTTPS on port 443.
First-level generated names fit Cloudflare Universal SSL coverage. Domains
outside `*.valpo.dev` still need their own DNS and tunnel routing.

If restoring the older `before-domain-slugs-20260905` snapshot, also restore the wildcard DNS record:
`*.valpo.dev` previously targeted `pixie.porkbun.com`, DNS-only, TTL 600.
The VM snapshot does not include Cloudflare DNS changes.

## Updating Valpo

Updates are manual. Select and review a full commit, run the appropriate tests,
and preserve its identity; the initial setup found no published GitHub releases.
The source installer is not transactional. A stopped VM snapshot preserves the
database, keyring, application volumes, configuration, and code together.

1. Confirm no jobs are active and stop accepting writes. Allow active work to
   finish before shutting down the guest.
2. Stop `valpo-live` cleanly and take a uniquely named Incus snapshot. Start the
   VM again. Expect public downtime during this process.
3. Transfer a complete `git archive` file of the reviewed commit, push it into
   the guest with `incus file push`, and extract into a fresh directory under
   `/root`. Verify the archive contains the bootstrap migration before stopping
   services. The installer sets `/opt/valpo` to mode 0755 for the Valpo account.
4. Run that checkout's `packaging/install.sh` inside the VM. Use the full
   installer when dependencies change. Never modify the frozen bootstrap
   migration or bypass its compatibility check.
5. Record the installed commit in `/etc/valpo/source-revision` after success.
6. Verify the API, worker, Caddy, Docker, and tunnel services; authenticated
   system status; the public canary; and rejection of unauthenticated API calls.
   Test a guest restart when changing host configuration.

If an update fails, stop the guest and restore the pre-update snapshot before
restarting. Restoring discards all writes since the snapshot; coordinate this
before accepting further traffic. Local snapshots are recovery points, not
off-host backups, and do not survive loss of Starbook's disk.

## Operational Checks

```bash
curl --fail https://live.valpo.dev/
curl -s -o /dev/null -w '%{http_code}\n' https://api-live.valpo.dev/v1/projects
ssh pablo@starbook 'incus exec valpo-live -- systemctl is-active valpo-api valpo-worker caddy docker cloudflared'
ssh pablo@starbook 'incus exec valpo-live -- valpo-operator system secrets verify'
ssh pablo@starbook 'incus exec valpo-live -- journalctl -u valpo-api -u valpo-worker -u cloudflared --since "10 minutes ago" --no-pager'
```

The unauthenticated API request must return 401. Tunnel health alone does not
prove the application works; compare the public response with the deployed
service and verify its domain through Valpo's normal verification workflow.

Initial verification confirmed a running canary with a verified domain,
matching public/container response digests, authenticated public API access,
unauthenticated API rejection, and recovery after a full guest stop/start.
After installing the domain-creation fix, a single `domain add` created and
verified `verify-live.valpo.dev` successfully. Both public canary hostnames
returned the same body digest as the container.

## Ruby 4 buildpack trial

The private `holamendi/sinatra-todos` repository includes `valpo.toml` for a
Sinatra web service with Postgres 18. Manifest application succeeded. The
Postgres and web services are running. The web app is available at
`https://sinatra-todos-web.valpo.dev`.

The worker builder setting in `/etc/valpo/valpo.yml` is now
`heroku/builder@sha256:e0d2453e68106a8000da70780f631e888ca61a515ea9921a26a1f7391964908a`
(Heroku 26), because the former pinned Paketo builder did not support Ruby 4.0.6.
Heroku 26 is now also the repository default; the Sinatra manifest declares its own pinned builder and ordered buildpacks.
The preceding configuration is saved as `/etc/valpo/valpo.before-heroku-builder.yml`.

Build attempts subsequently failed fetching Docker Hub lifecycle metadata over
unreachable IPv6 addresses; a GitHub fetch also timed out. Direct IPv4 GitHub
access succeeded. The VM interface now uses `dhcp6: false`, `accept-ra: false`, and
`link-local: []` in `/etc/netplan/10-lxc.yaml`. Its original configuration is
saved as `/etc/netplan/10-lxc.before-ipv4-only.yaml.backup`. The shared Incus
bridge and other VMs were not changed.

Docker Buildx (Ubuntu package `docker-buildx`) is installed. The Heroku run
image needed its layers materialized through BuildKit to work around
[moby/moby#52193](https://github.com/moby/moby/issues/52193). A one-line
`FROM heroku/heroku:26` build tagged `valpo-heroku-runtime-check` allowed
`docker save --platform linux/amd64 heroku/heroku:26` and the CNB exporter
to succeed. This is runtime-image preparation; the application build still
uses buildpacks. Valpo now detects and performs this preparation automatically for newly resolved run images.

The server also reported a separate storage-maintenance error,
`comparison of String with Time failed`, during this trial. The cache-retention query now loads a typed release timestamp instead of comparing SQLite aggregate text with a Ruby `Time`.


## Buildpack hardening verification (2026-09-05)

An isolated Ubuntu 26.04 VM, `valpo-buildpack-qa`, exercised the full source installer with dependencies. It installed Docker Buildx automatically. The new buildpack preflight reproduced and repaired the containerd run-image export failure before invoking the lifecycle. The packaged acceptance fixture uses Ruby 4.0.6, Sinatra, Postgres 18, an applied manifest, and the ordered `heroku/ruby`, `heroku/procfile` buildpacks. A stored HTTP-created item remained readable after container restarts and a complete QA VM reboot.

The acceptance fixture uses local source checkout and a private loopback URL so it needs no GitHub credentials or public domain. During development the harness needed corrections for bundle loading, fixture installation, and transient connection resets during startup; these are included in the checked-in harness. Docker export must redirect stdout to `/dev/null`; its `--output` option rejects character devices.


The full GitHub Actions run for `a63bac2` passed both normal checks and clean-install buildpack acceptance: https://github.com/holamendi/valpo/actions/runs/33972509955. That gate additionally caught inherited caller mise/XDG paths; installer commands now use Valpo-owned directories and a non-login shell.

The live manifest now stores its own pinned builder and ordered buildpacks. Deployment `job_01a0720206f473fca39fcdf83b3f2d64` succeeded as release 6 (application commit `46cb57a`), and maintenance dry run `job_01a07202dc86700ab15fb73baa8cb666` succeeded. The live Ruby archive download was slow across multiple S3 addresses but completed; the old release continued serving during the build. A temporary Mac-to-API timeout interrupted polling without stopping the server job. Job polling now retries transient reads with bounded backoff and retains its event cursor; deployment submissions are not automatically retried.

The control-plane database, configuration, and keyring were backed up to `/root/before-buildpack-hardening-669edd2` before upgrading to schema 6. Existing application containers remained running during the API/worker update.
