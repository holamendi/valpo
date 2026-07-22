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

          On a host installed by `packaging/install.sh`, invoke the wrapper as `sudo valpo`; it drops privileges to the dedicated Valpo user. The examples below omit `sudo` so the command syntax is clear and can also be used from a development checkout.

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

          ## Domains And Web Activation

          Domain configuration happens after Valpo is installed. To use generated app hostnames, point a wildcard such as `*.apps.example.com` at the host, then set and verify its base name:

          ```bash
          valpo domain set-default apps.example.com
          valpo domain show-default
          ```

          A web service named `web` in project `acme` receives `web.acme.apps.example.com`. Setting or changing the default reconciles existing web services but never removes custom domains.

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

          `--ref` defaults to remote `HEAD`, `--dockerfile` defaults to `Dockerfile`, and `--context` defaults to `.`. The repository, ref, Dockerfile, and context are validated before any service configuration is created. Use `service update` to persist source, build, command, health-check, or port changes; `--deploy` validates, applies, and deploys the update as one operation.

          ```bash
          valpo service update web --project acme --ref release --deploy
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

          `--image` and `--ref` are mutually exclusive. Source builds run in the worker and stream Git fetch, Docker build, health-check, and release events through the normal job output.

          Authenticate GitHub locally with a non-echoing prompt:

          ```bash
          valpo auth login github
          valpo auth status github
          valpo auth logout github
          ```

          Interactive login links to GitHub's prefilled fine-grained-token form with read-only Contents permission, then validates the PAT with GitHub before storing it. This proves the token is recognized and identifies its account; repository selection is still verified by the Git fetch during deployment.

          `auth login` writes the configured private credential file directly after validation; it does not send the PAT to the Valpo API or put it in a job. For secret-manager automation, pipe one line with `--with-token`. There is intentionally no token-value option because command arguments can leak through shell history and process listings.

          ```bash
          op read op://vault/github-pat | valpo auth login github --with-token
          ```

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

          The API URL defaults to `#{DEFAULT_API_URL}` and can be set with `--api-url` or `VALPO_API_URL`. Use `--config PATH` or `VALPO_CONFIG` to load a Valpo configuration file. API authentication is read from `VALPO_API_TOKEN` first, then `api_token` in the configuration file.

          Global options may appear before or after the resource command:

          ```bash
          valpo --api-url http://127.0.0.1:7092 project list
          valpo project list --config /etc/valpo/valpo.yml
          ```

          `valpo version` is fully offline. `valpo system status` calls `/health` and reports whether the client and server versions match.

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
        arguments = command.arguments.map do |argument|
          argument_name = argument.description_name.to_s
          argument.required? ? argument_name : "[#{argument_name}]"
        end
        (["valpo", name] + arguments + [REQUIRED_OPTIONS[name]]).compact.join(" ")
      end
      private_class_method :command_line

      def service_type_table
        rows = Valpo::Services::Definitions::TYPES.map do |name, definition|
          versions = if definition[:versions]
            "#{definition.fetch(:versions).join(", ")} (default #{definition.fetch(:default_version)})"
          else
            "n/a"
          end
          "| `#{name}` | #{definition.fetch(:description)} | #{versions} |"
        end
        (["| Type | Purpose | Versions |", "| --- | --- | --- |"] + rows).join("\n")
      end
      private_class_method :service_type_table
    end
  end
end
