# frozen_string_literal: true

module Valpo
  module CLI
    module Docs
      PATH = File.join(Valpo.root, "docs", "valpo-cli.md")
      REQUIRED_OPTIONS = {
        "service create" => "--project PROJECT --type TYPE",
        "service delete" => "--force"
      }.freeze

      module_function

      def render
        <<~MARKDOWN
          # Valpo CLI

          This guide is generated from database-free CLI metadata. Run `rake cli:docs` after changing command registration, arguments, or service definitions.

          The Valpo CLI uses resource-first commands: choose a resource, then an action. Run `valpo --help`, `valpo RESOURCE --help`, or `valpo RESOURCE ACTION --help` for contextual help. The equivalent `valpo help RESOURCE ACTION` form is also supported.

          On an installed host, run the CLI as root; the wrapper drops privileges to the dedicated Valpo user. The examples below therefore use `valpo` directly and can also be used from a development checkout.

          ## Command Hierarchy

          ```text
          #{public_command_lines.join("\n")}
          ```

          ## References

          Projects accept a name such as `acme` or a typed ID beginning with `prj_`. Services accept a name such as `web` together with `--project acme`, or a typed ID beginning with `svc_`. Service IDs are globally unambiguous and do not require `--project`. The CLI resolves scoped names through an exact project/service lookup and caches each result for the current invocation.

          New services require an explicit project:

          ```bash
          valpo service create web --project acme --type web --port 3000
          ```

          ## Service Types

          #{service_type_table}

          `command` is valid for `web` and `worker`. `port` and `healthcheck-path` are valid only for `web`. `version` is valid only for `postgres` and `redis`. Incompatible options are rejected rather than ignored. Managed service images are selected by Valpo and cannot be overridden.

          ## Service Environment

          Custom environment variables belong to an app service and are encrypted in the Valpo database. Values are read from standard input so secrets do not appear in command arguments:

          ```bash
          printf %s "$DATABASE_URL" | valpo service env set web DATABASE_URL --project acme
          valpo service env list web --project acme
          valpo service env unset web DATABASE_URL --project acme
          ```

          Values are sensitive and redacted by default. Use `--plain` on `env set` for non-secret configuration and `--reveal` on `env list` when plaintext output is explicitly required. Revealing sensitive custom values and managed-service binding credentials requires an API credential with `admin` scope; a `read` credential receives `403 forbidden`. Managed-service bindings remain derived by Valpo and cannot be overridden by a custom variable; `PORT` is reserved for runtime port injection. Setting or removing a variable increments the service environment revision and reconciles a running release through the job queue.

          ## Domains And Web Activation

          Domain configuration happens after Valpo is installed. To use generated app hostnames, point a wildcard such as `*.apps.example.com` at the host, then set and verify its base name:

          ```bash
          valpo domain set-default apps.example.com
          valpo domain show-default
          ```

          A web service named `web` in project `acme` receives `acme-web.apps.example.com`. Each service receives a stable, unique slug; collisions get a random suffix. Slugs are limited to 63 characters and survive renames and default-domain changes. Setting or changing the default reconciles existing web services but never removes custom domains. For Cloudflare Universal SSL, use a zone root such as `example.com` as the default so generated names remain first-level subdomains.

          A custom domain can be used instead:

          ```bash
          valpo domain add web hello.example.com --project acme
          valpo domain verify web hello.example.com --project acme
          ```

          `domain set-default` and `domain add` verify a unique HTTPS challenge through Caddy. A web release without a verified domain remains private in the `ready` state; successful verification activates the latest ready release. Workers and managed services do not require domains.

          ## Source-Backed Services

          A GitHub-backed app service can be created and deployed without `valpo.toml`:

          ```bash
          valpo project create acme
          valpo service create web --project acme \\
            --type web \\
            --source github:acme/backend \\
            --deploy
          ```

          `--ref` defaults to remote `HEAD`, `--build-strategy` defaults to `auto`, and `--context` defaults to `.`. Auto builds use `<context>/Dockerfile` when present and otherwise use Cloud Native Buildpacks. Use `--build-strategy dockerfile` or `--dockerfile PATH` to require a Dockerfile, and `--build-strategy buildpack` to ignore one. The repository, ref, context, and selected build inputs are validated before any service configuration is created. No image is built unless deployment is requested. Use `service update` to persist source, build, command, health-check, or port changes; `--deploy` validates, applies, and deploys the update as one operation.

          ```bash
          valpo service update web --project acme --ref release --deploy
          valpo service update web --project acme --build-strategy buildpack --deploy
          valpo service update web --project acme --clear-command --clear-healthcheck --clear-port
          ```

          An omitted web port is resolved after the image is available: explicit configuration wins, then a sole TCP `EXPOSE`, then port `3000` for a source image with no exposed port. Ambiguous images and registry images without exactly one exposed TCP port require `--port`.

          ## Deployments

          Deploy an app service's configured GitHub source, or override it once with a branch, tag, or commit SHA:

          ```bash
          valpo service deploy web --project acme
          valpo service deploy web --project acme --ref release
          ```

          Registry-image deployment remains available as an explicit alternative:

          ```bash
          valpo service deploy web --project acme --image ghcr.io/acme/web:latest
          ```

          `--image` and `--ref` are mutually exclusive. Source builds run in the worker and stream Git fetch, Dockerfile or buildpack output, health-check, and release events through the normal job output. Buildpack workers require an explicit service command.

          Connect GitHub with a private, per-server GitHub App:

          ```bash
          valpo auth login github
          valpo auth status github
          valpo auth logout github
          ```

          `auth login` requires a verified default app domain and prints a one-time HTTPS setup URL. Open it, name the private GitHub App, create it from Valpo's manifest, and choose the repositories it may access. Valpo reserves `github.<app-domain>` for the manifest callback and signed push webhook. The App requests read-only Contents permission and the `push` event.

          A private GitHub App can only be installed on its owning account. Use `--organization ORG` when the repositories belong to an organization; omit it for repositories owned by your personal account.

          ```bash
          valpo auth login github --organization acme
          ```

          GitHub returns the App ID, private key, and webhook secret directly to the server callback. Valpo stores the private key and webhook secret encrypted in SQLite and retains only non-secret App identity as plaintext metadata. Source fetches mint short-lived installation tokens for the requested repository; private keys, webhook secrets, and installation tokens never enter manifests, API payloads, jobs, Git remotes, logs, or process arguments.

          A fine-grained PAT is available as a fallback when a GitHub App cannot be used. Pipe one token line explicitly with `--with-token`; there is intentionally no token-value option because command arguments can leak through shell history and process listings. The validated PAT is encrypted in the database.

          ```bash
          op read op://vault/github-pat | valpo auth login github --with-token
          ```

          `auth logout github` removes local credentials only. It does not uninstall or delete the GitHub App on GitHub.

          ## Output

          Commands print concise tables or detail views by default. Add `--json` for scripting; stdout then contains exactly one JSON document. Progress, warnings, streamed job events, and errors are written to stderr, so redirecting stdout remains safe.

          ```bash
          valpo service list --project acme --json
          valpo service show web --project acme --json
          ```

          ## Waiting

          Operations wait for their background job by default and stream each unseen job event to stderr. The default timeout is #{DEFAULT_TIMEOUT} seconds.

          - Use `--no-wait` to return the queued job immediately.
          - Use `--timeout SECONDS` to change the maximum wait.
          - The server API stays asynchronous; waiting is a CLI behavior.

          ## Exit Codes

          - `0`: command completed successfully.
          - `1`: API, background job, network, or runtime operation failed.
          - `2`: command usage, arguments, or options are invalid.

          ## Configuration

          ### Server Login

          `valpo login` authenticates this CLI to a Valpo server. It is separate from `valpo auth login github`, which configures the server's source-provider access. No user account or password is required: each computer uses a named API credential issued by an administrator.

          ```bash
          valpo login --server https://api.example.com --name live
          valpo system status
          valpo project list --server live
          valpo server list
          valpo server use live
          ```

          Login prompts for the API token without echoing it, validates it with `GET /v1/session`, saves it, and selects that server. The default profile name is `default`; pass `--name` to keep multiple servers. Failed login leaves saved credentials and the selected server unchanged. A name cannot silently move to a different URL; log out first or choose another name.

          For automation, pipe one token line explicitly with `--with-token`. There is no token-value command-line option. Remote URLs require HTTPS; HTTP is allowed only for `localhost`, `127.0.0.1`, and `::1`. Redirects are rejected.

          Profiles, including **plaintext API tokens**, are stored in `~/.config/valpo/cli.json` with mode `0600` inside a `0700` directory. `VALPO_CLI_CONFIG` overrides this client-only path; it is separate from the server's `VALPO_CONFIG`. Existing insecure files, directories, and symlinks are rejected. Keep this file out of Git and shared backups. `server list`, login output, and JSON output never display saved tokens. On an installed host, the wrapper runs as `valpo`, so its profile file lives below `/var/lib/valpo`.

          ### Environment Overrides

          `VALPO_API_TOKEN` overrides the selected profile's token. This supports credentials supplied by 1Password environments or another secret manager without persisting them through login. An explicitly empty token disables saved authentication.

          `--server NAME` selects a saved profile for one command and takes precedence over `VALPO_API_URL`. `--api-url URL` or, without an explicit server, `VALPO_API_URL` selects an explicit URL and uses **only** `VALPO_API_TOKEN`, never a saved token. This prevents sending a saved credential to a different endpoint. `--server` and `--api-url` cannot be combined. Without a saved selection or URL override, the CLI uses `#{DEFAULT_API_URL}`.

          Global options may appear before or after the command:

          ```bash
          valpo --server live project list
          valpo project list --server live --json
          ```

          ### Initial Setup And Logout

          The source installer creates the first admin credential before starting the API, saves it root-only at `/etc/valpo/bootstrap-token`, and never prints it in installation logs. Reinstalling does not replace credentials or reopen bootstrap. On the installed host, initialize its local CLI profile and issue a separate credential for your computer:

          ```bash
          valpo login --server http://127.0.0.1:7092 --name local --with-token < /etc/valpo/bootstrap-token
          valpo auth token create my-computer --scope=admin
          ```

          The second command prints the new token once. Enter that token into `valpo login` on your computer. For checkouts installed without the source installer, the first admin can still be created with `valpo auth token create initial-admin --scope=admin` through the local API. Bootstrap closes permanently after issuance, even if all credentials are later revoked or expire.

          ```bash
          valpo logout --server live
          valpo logout --server staging --revoke
          ```

          Ordinary logout removes the saved login locally and works offline; its server credential remains valid. `--revoke` revokes the saved credential itself before removing the profile. If revocation fails, the profile is retained. Logging out of the selected profile clears the selection instead of switching to another server. Every scope can inspect and revoke its own credential; only administrators can issue credentials, list all credentials, or revoke other credentials. The final active admin cannot be revoked.

          `valpo version` is fully offline. `valpo system status` calls `/health` and reports client/server versions, API compatibility, current and target database schemas, configuration schema, host profile, release channel, and artifact digest.

          ## Credential Recovery And Rotation

          Verify that the configured host keyring can decrypt every encrypted database record before trusting a backup or changing keys:

          ```bash
          valpo system secrets verify
          ```

          Back up the SQLite database and host keyring as one recovery set before rotation. Then rotate the active host key and re-encrypt every managed credential, custom environment value, and provider credential:

          ```bash
          valpo system secrets rotate
          ```

          Both commands require an admin API credential and run through the job worker. Rotation verifies all records before mutation, adds a new key version, re-encrypts the records in one SQLite transaction, and verifies them again. Old key versions remain readable; Valpo does not prune them automatically. A restored database and keyring should be tested together on a separate host with `system secrets verify` before being treated as recoverable.

          Roll API credentials without an authentication gap: create and save a replacement token, use it from a second shell to run `system status` and `auth token list`, then revoke the old credential by ID with `auth token revoke CREDENTIAL_ID`. Never revoke the old admin credential until the replacement has successfully authenticated.

          Valpo refuses to revoke the final active admin. If all admins expire or their tokens are lost, stop or network-isolate the API and use the host-local database recovery path:

          ```bash
          valpo auth token recover rescue-admin --confirm-offline-recovery
          ```

          Recovery works directly against the configured SQLite database, refuses to run while an active admin exists, and never reopens HTTP bootstrap. Save the returned token, restart the API if it was stopped, and verify it before resuming normal operation.

          ## Storage Maintenance

          Packaged hosts enqueue storage maintenance daily. Preview or run the same ownership-scoped operation manually:

          ```bash
          valpo system maintenance --dry-run
          valpo system maintenance
          ```

          Maintenance removes stale local build images beyond the configured rollback retention, unused buildpack cache volumes, orphaned Valpo-owned containers, and expired job/webhook history. It does not remove registry images, managed-service data volumes, unrelated Docker resources, or global Dockerfile build cache. Every newly created Valpo container uses bounded rotating logs.

          ## Advanced Job Inspection

          Jobs are an operational detail, so they are omitted from primary root help. They remain available for troubleshooting:

          ```text
          #{job_command_lines.join("\n")}
          ```

          Normal workflows should rely on default waiting or `--no-wait`; use the job commands when investigating queue or worker behavior.
        MARKDOWN
      end

      def write(path = PATH)
        File.write(path, render)
      end

      def public_command_lines
        Registry::COMMANDS.filter_map do |name, command, hidden|
          command_line(name, command) unless hidden
        end
      end
      private_class_method :public_command_lines

      def job_command_lines
        Registry::COMMANDS.filter_map do |name, command, hidden|
          command_line(name, command) if hidden
        end
      end
      private_class_method :job_command_lines

      def command_line(name, command)
        arguments = command.arguments.map do
          argument_name = it.description_name.to_s
          it.required? ? argument_name : "[#{argument_name}]"
        end
        (["valpo", name] + arguments + [REQUIRED_OPTIONS[name]]).compact.join(" ")
      end
      private_class_method :command_line

      def service_type_table
        rows = Valpo::Services::Registry.definitions.map do |name, definition|
          versions = if definition.versions.any?
            "#{definition.versions.join(", ")} (default #{definition.default_version})"
          else
            "n/a"
          end
          "| `#{name}` | #{definition.description} | #{versions} |"
        end
        (["| Type | Purpose | Versions |", "| --- | --- | --- |"] + rows).join("\n")
      end
      private_class_method :service_type_table
    end
  end
end
