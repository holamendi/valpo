# frozen_string_literal: true

module Valpo
  module CLI
    module Docs
      PATH = File.join(Valpo.root, "docs", "valpo-cli.md")
      REQUIRED_OPTIONS = {
        "service create" => "--type TYPE",
        "service delete" => "--force"
      }.freeze

      module_function

      def render
        <<~MARKDOWN
          # Valpo CLI

          This guide is generated from database-free CLI metadata. Run `rake cli:docs` after changing command registration, arguments, or service definitions.

          The Valpo CLI uses resource-first commands: choose a resource, then an action. Run `valpo --help`, `valpo RESOURCE --help`, or `valpo RESOURCE ACTION --help` for contextual help. The equivalent `valpo help RESOURCE ACTION` form is also supported.

          ## Command Hierarchy

          ```text
          #{public_command_lines.join("\n")}
          ```

          ## References

          Projects accept a name such as `acme` or a typed ID beginning with `prj_`. Services accept `PROJECT/NAME`, such as `acme/web`, or a typed ID beginning with `svc_`. The CLI resolves named service references through an exact project/service lookup and caches each result for the current invocation.

          New services must be named as `PROJECT/NAME`:

          ```bash
          valpo service create acme/web --type web --port 3000
          ```

          ## Service Types

          #{service_type_table}

          `command` is valid for `web` and `worker`. `port` and `healthcheck-path` are valid only for `web`. `version` is valid only for `postgres` and `redis`. Incompatible options are rejected rather than ignored. Managed service images are selected by Valpo and cannot be overridden.

          ## Deployments

          Deploy an app service's configured GitHub source at its manifest ref, or override it with a branch, tag, or commit SHA:

          ```bash
          valpo service deploy acme/web
          valpo service deploy acme/web --ref release
          ```

          Registry-image deployment remains available as an explicit alternative:

          ```bash
          valpo service deploy acme/web --image ghcr.io/acme/web:latest
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
          valpo service list acme --json
          valpo service show acme/web --json
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
