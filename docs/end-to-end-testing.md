# End-to-End Testing

Valpo's canonical end-to-end environment runs on the `starbook` Linux host and
uses Incus for isolation. Connect explicitly as `pablo`; the local `starbook`
SSH alias may select a different user.

## Test Topology

```text
Internet client
  -> HTTPS at Cloudflare
  -> Cloudflare Tunnel in Incus container dev-ubuntu-01 (10.238.201.10)
  -> Nginx with verified HTTPS to the origin
  -> Caddy in Incus VM valpo (10.238.201.20)
  -> Valpo route target on 127.0.0.1:20000
  -> Valpo-managed application container
```

The persistent public canary is:

- URL: `https://valpo-e2e.siesta.cam/`
- Incus VM: `valpo`
- Valpo project: `public-e2e`
- Valpo service: `web`
- image: `nginx@sha256:db35bfc6b2951e7f8a72db5db120288c127ffaeeb4a6d4b95a26fead017d5913`

The Cloudflare Tunnel runs in `dev-ubuntu-01` and publishes
`*.siesta.cam` to Nginx on port 80. Nginx has an exact
`valpo-e2e.siesta.cam` virtual host. It forwards ACME HTTP-01 paths to Caddy
over HTTP and all application and Valpo-verification traffic to Caddy over
HTTPS with SNI and certificate verification. Cloudflare terminates client TLS,
while the second TLS hop verifies that Nginx is connected to the intended
Valpo origin. See Cloudflare's [Tunnel configuration](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/)
and Caddy's [automatic HTTPS behavior](https://caddyserver.com/docs/automatic-https).

### Tunnel Origin Route

The tunnel container stores the dedicated route at
`/etc/nginx/conf.d/valpo-e2e.conf`:

```nginx
upstream valpo_e2e_origin_http {
    server 10.238.201.20:80;
    keepalive 8;
}

upstream valpo_e2e_origin_https {
    server 10.238.201.20:443;
    keepalive 8;
}

server {
    listen 80;
    listen [::]:80;
    server_name valpo-e2e.siesta.cam;

    location ^~ /.well-known/acme-challenge/ {
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://valpo_e2e_origin_http;
    }

    location / {
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_ssl_server_name on;
        proxy_ssl_name $host;
        proxy_ssl_verify on;
        proxy_ssl_verify_depth 3;
        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
        proxy_pass https://valpo_e2e_origin_https;
    }
}
```

Validate before every reload:

```bash
ssh pablo@starbook 'incus exec dev-ubuntu-01 -- nginx -t'
ssh pablo@starbook \
  'incus exec dev-ubuntu-01 -- systemctl reload nginx.service'
```

Do not change the main tunnel ingress from HTTP to HTTPS: it terminates at
Nginx. The Nginx-to-Caddy hop is HTTPS because Valpo's generated hostname sites
use Caddy automatic HTTPS. Forwarding ordinary requests to Caddy over HTTP
causes a `308` redirect and prevents Valpo's reachability verifier from seeing
its challenge body. The dedicated HTTP ACME path lets Caddy issue and renew the
origin certificate through the same public tunnel.

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

1. Upgrade a schema-1 database and confirm schema target 2.
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
  'incus exec dev-ubuntu-01 -- systemctl is-active cloudflared nginx'
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
