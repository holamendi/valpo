# End-to-End Testing

Valpo's canonical end-to-end environment runs on the `starbook` Linux host and
uses Incus for isolation. Connect explicitly as `pablo`; the local `starbook`
SSH alias may select a different user.

## Test Topology

```text
Internet client
  -> HTTPS at Cloudflare
  -> Cloudflare Tunnel in Incus container dev-ubuntu-01 (10.238.201.10)
  -> HTTPS with request-host SNI to Caddy in Incus VM valpo (10.238.201.20)
  -> Valpo route target on 127.0.0.1:20000
  -> Valpo-managed application container
```

The persistent public canary is:

- URLs:
  - `https://valpo-e2e.siesta.cam/`
  - `https://api-valpo-e2e.siesta.cam/`
  - `https://web-valpo-e2e.siesta.cam/`
- Incus VM: `valpo`
- Valpo project: `public-e2e`
- Valpo service: `web`
- image: `nginx@sha256:db35bfc6b2951e7f8a72db5db120288c127ffaeeb4a6d4b95a26fead017d5913`

The Cloudflare Tunnel runs in `dev-ubuntu-01` and publishes `*.siesta.cam`
directly to Caddy. It forwards ACME HTTP-01 paths to Caddy over port 80 and all
other traffic over verified HTTPS. `matchSNItoHost` makes `cloudflared` use the
request hostname for origin SNI, so Caddy can select and prove the independently
managed certificate for every Valpo domain without per-domain Tunnel changes.
Cloudflare terminates client TLS, while the second TLS hop validates Caddy's
publicly trusted origin certificate. See Cloudflare's
[origin parameters](https://developers.cloudflare.com/tunnel/advanced/origin-parameters/)
and Caddy's [automatic HTTPS behavior](https://caddyserver.com/docs/automatic-https).

### Tunnel Origin Route

The tunnel container stores the route in `/etc/cloudflared/config.yml`:

```yaml
ingress:
  - hostname: "*.siesta.cam"
    path: "^/.well-known/acme-challenge/.*$"
    service: http://10.238.201.20:80
  - hostname: "*.siesta.cam"
    service: https://10.238.201.20:443
    originRequest:
      matchSNItoHost: true
  - service: http_status:404
```

Validate before every restart:

```bash
ssh pablo@starbook \
  'incus exec dev-ubuntu-01 -- cloudflared tunnel ingress validate'
ssh pablo@starbook \
  'incus exec dev-ubuntu-01 -- systemctl restart cloudflared.service'
```

Do not put an HTTP reverse proxy between the Tunnel and Caddy. Forwarding
ordinary requests to Caddy over HTTP causes an automatic-HTTPS `308` redirect
loop. The dedicated HTTP path exists only so Let's Encrypt can reach Caddy's
HTTP-01 handler before the new certificate exists. Application traffic and
Valpo's HTTPS domain-verification challenge go straight to Caddy over port 443.

## Safety Rules

- Treat `dev-ubuntu-01` and `valpo` as dedicated test infrastructure, but do not
  modify other Incus instances or Dokku routes on Starbook.
- Never run `vps-clean-install-smoke-test.sh` against Starbook itself. Run host
  installation commands only inside the `valpo` VM.
- Snapshot the VM before a destructive schema, authentication, installation, or
  recovery scenario. Restore it after the scenario unless the change is meant
  to become the new canary state.
- A concurrently running clone must receive a unique guest IP before it starts;
  the `valpo` guest uses the static address `10.238.201.20`.
- Keep the test API token root-owned with mode `0600`. Never print it, copy it
  into the repository, or place it in a command argument.
- Domain verification must go through the normal `valpo domain add` or
  `valpo domain verify` workflow. Do not mark domain records verified directly
  in SQLite.

## Install The Current Worktree

Stage the checkout on Starbook, copy it into the VM, and use the supported
schema-compatible update path:

```bash
rsync -az --delete \
  --exclude .git --exclude vendor/bundle --exclude tmp \
  ./ pablo@starbook:/tmp/valpo-e2e-src/

ssh pablo@starbook \
  'incus file push --quiet --recursive --uid 0 --gid 0 /tmp/valpo-e2e-src valpo/tmp/'

ssh pablo@starbook \
  'incus exec valpo -- env VALPO_INSTALL_SKIP_DEPS=1 /tmp/valpo-e2e-src/packaging/install.sh'
```

Use dependency skipping only because this VM is already prepared. A new Ubuntu
26.04 VM must run the full installer.

## Required Checks

Run focused control-plane scenarios before relying on the persistent canary:

1. Upgrade a schema-1 database and confirm it reaches the release's declared schema target.
2. Confirm every unauthenticated route is rejected except the exact local
   first-admin `POST /v1/api-credentials` request.
3. Bootstrap once and confirm bootstrap never reopens.
4. Create a replacement administrator, revoke the old one, and confirm the
   final active administrator cannot be revoked.
5. Stop the API and worker, simulate the loss or expiry of all administrators,
   use `valpo auth token recover --confirm-offline-recovery`, and confirm
   recovery is rejected while any active administrator exists.
6. Restart the services and VM, then confirm recovered authentication and
   permanent bootstrap state survive.
7. Deploy through Valpo, run normal public domain verification, and compare the
   public response with the active local route target.
8. Attach at least two custom domains to the same service without changing
   Cloudflare Tunnel or host proxy configuration. Confirm both become
   `verified`, reach the same release, and have distinct certificates in
   Caddy's storage.
9. Send the same mutating request twice with one `Idempotency-Key`; confirm both
   responses name the same job, including when the second request follows job
   completion.
10. Terminate the worker after `handler_started` during a source build, restart
    it, and confirm the job is not automatically replayed and instead requires
    reconciliation. During a normal `SIGTERM`, confirm the build drains and no
    second job is acquired.
11. Terminate the worker after `handler_completed` but before terminal status;
    restart it and confirm startup marks that job succeeded without repeating
    its Docker or Caddy effects.
12. Terminate a delete or rollback after `handler_started`; confirm restart
    marks it failed with `recovery_action=reconcile`, `retry` is rejected, and
    repeated reconciliation requests use the same `repair_system` job. Confirm
    repair failure leaves the original job actionable, retrying that repair
    does not create a new job, and repair success sets `resolved_at` on the
    interrupted job.

The production-like configuration-file path must be part of recovery testing;
setting only `VALPO_DATABASE_PATH` does not reproduce the installed wrapper.

## Verify The Persistent Canary

Check the public response from the development machine:

```bash
curl -fsS https://valpo-e2e.siesta.cam/
```

Check the infrastructure and Valpo state without exposing the token:

```bash
ssh pablo@starbook 'incus list valpo dev-ubuntu-01'
ssh pablo@starbook \
  'incus exec dev-ubuntu-01 -- systemctl is-active cloudflared'
ssh pablo@starbook \
  'incus exec valpo -- systemctl is-active valpo-api valpo-worker caddy'
ssh pablo@starbook \
  "incus exec valpo -- bash -lc 'VALPO_API_TOKEN=\$(cat /root/.config/valpo/test-api-token) valpo service show web --project public-e2e --json'"
```

For proof that the public route reaches the Valpo-managed workload, compare the
body digest returned through Cloudflare with the digest from the active local
route target:

```bash
curl -fsS https://valpo-e2e.siesta.cam/ | sha256sum
ssh pablo@starbook \
  'incus exec valpo -- curl -fsS http://127.0.0.1:20000/ | sha256sum'
```

Both digests must match. Also confirm the domain is `verified`, the release is
`active`, and the service is `running` through the Valpo CLI.

Verify that all persistent canary domains reach that same workload:

```bash
for hostname in valpo-e2e api-valpo-e2e web-valpo-e2e; do
  curl -fsS "https://${hostname}.siesta.cam/" | sha256sum
done
```

The three digests must match. Caddy's logs must record successful certificate
issuance for each newly attached hostname, and its certificate storage must
contain a separate certificate directory for each hostname. The browser-facing
certificate remains Cloudflare's edge certificate; origin certificate evidence
comes from Caddy's logs and storage and from the Tunnel's verified HTTPS hop.

## Direct Public VPS Coverage

The Starbook/Incus/Tunnel path is the default end-to-end environment. Keep the
existing direct-VPS harness for the narrower cases that specifically need a
publicly addressed origin, direct Caddy TLS termination, or clean installation
of host packages:

```bash
packaging/vps-smoke-test.sh root@HOST apps.example.com --reboot
```

That harness requires a disposable public host and must not be pointed at
Starbook or either Incus guest.
