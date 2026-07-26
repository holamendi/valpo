# frozen_string_literal: true

require "io/console"
require "json"

module Valpo
  module CLI
    module Commands
      module Auth
        class Login < Base
          desc "Authenticate a source provider"
          argument :provider, required: true, desc: "Source provider (github)"
          option :organization, desc: "Create the GitHub App under this organization"
          option :with_token, type: :boolean, default: false, desc: "Read a temporary fallback PAT from stdin"

          def call(provider:, with_token:, api_url:, organization: nil, config: nil, json: false, args: nil, **)
            reject_secret_arguments!(args)
            provider = github!(provider)
            unless with_token
              result = context(api_url:, config:, json:).request(
                :post,
                "/v1/auth/github",
                {"organization" => organization}.compact
              )
              return render_setup(result.merge("provider" => provider), json:)
            end
            raise UsageError, "--organization cannot be used with --with-token" if organization

            store, path = credential_store(config)
            token = read_token
            account = Valpo::CLI.github_validator.validate(token)
            store.write(token)
            render({"account" => account, "authenticated" => true, "provider" => provider, "path" => path}, json:)
          end

          private

          def reject_secret_arguments!(args)
            return if args.nil? || args.empty?

            raise UsageError, "Credentials must be provided through the hidden prompt or --with-token stdin, not as arguments"
          end

          def read_token
            input = Valpo::CLI.input
            if input.respond_to?(:tty?) && input.tty?
              raise UsageError, "--with-token requires piped stdin"
            end
            value = input.gets
            token = value.to_s.strip
            raise UsageError, "GitHub PAT is required" if token.empty?

            token
          end

          def render_setup(result, json:)
            if json
              @out.puts JSON.generate(result)
            else
              @out.puts "Open this one-time URL to create and install the GitHub App:"
              @out.puts result.fetch("setup_url")
            end
          end

          def render(result, json:)
            if json
              @out.puts JSON.generate(result)
            else
              @out.puts "Authenticated GitHub as @#{result.fetch("account")} with the temporary PAT fallback"
            end
          end
        end
      end
    end
  end
end
