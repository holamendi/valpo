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
          option :with_token, type: :boolean, default: false, desc: "Read one token line from stdin"

          def call(provider:, with_token:, api_url:, config: nil, json: false, args: nil, **)
            reject_secret_arguments!(args)
            provider = github!(provider)
            store, path = credential_store(config)
            token = read_token(with_token:)
            account = Valpo::CLI.github_validator.validate(token)
            store.write(token)
            render({"account" => account, "authenticated" => true, "provider" => provider, "path" => path}, json:)
          end

          private

          def reject_secret_arguments!(args)
            return if args.nil? || args.empty?

            raise UsageError, "Credentials must be provided through the hidden prompt or --with-token stdin, not as arguments"
          end

          def read_token(with_token:)
            input = Valpo::CLI.input
            value = if with_token
              if input.respond_to?(:tty?) && input.tty?
                raise UsageError, "--with-token requires piped stdin; omit it to use the hidden prompt"
              end
              input.gets
            elsif input.respond_to?(:tty?) && input.tty? && input.respond_to?(:noecho)
              @err.puts "Create a fine-grained PAT with read-only repository contents access:"
              @err.puts Valpo::Sources::GitHub::FINE_GRAINED_PAT_URL
              @err.puts "Select the resource owner and only the repositories this server should deploy."
              @err.print "GitHub PAT: "
              input.noecho(&:gets).tap { @err.puts }
            else
              raise UsageError, "Interactive terminal required; pipe the PAT with --with-token"
            end
            token = value.to_s.strip
            raise UsageError, "GitHub PAT is required" if token.empty?

            token
          end

          def render(result, json:)
            if json
              @out.puts JSON.generate(result)
            else
              @out.puts "Authenticated GitHub as @#{result.fetch("account")} for source deploys"
            end
          end
        end
      end
    end
  end
end
