# frozen_string_literal: true

require "io/console"
require "json"

module Valpo
  module CLI
    module Commands
      class Login < BaseCommand
        desc "Validate and save an API token for a server"
        option :server, desc: "Server API URL (required)"
        option :name, default: "default", desc: "Saved server name"
        option :with_token, type: :boolean, default: false, desc: "Read one API token line from stdin"

        def call(api_url:, name:, with_token:, json: false, args: nil, **)
          raise UsageError, "Provide the token through the hidden prompt or --with-token stdin, not arguments" if args&.any?
          raise UsageError, "Use login --server URL, not --api-url" if api_url

          url = ServerAddress.normalize(required_option!(server, "--server"))
          Profiles.validate_name!(name)
          token = read_token(with_token:)
          result = CLI.sessions.login(name:, url:, token:)
          if json
            @out.puts JSON.generate(result)
          else
            @out.puts "Logged in to #{result.fetch("server")} (#{result.fetch("api_url")})"
            @out.puts "Token saved in your private CLI config. This server is now selected."
          end
        end

        private

        def read_token(with_token:)
          input = CLI.input
          if with_token
            raise UsageError, "--with-token requires piped stdin" if input.tty?

            return input.gets.to_s.strip
          end
          raise UsageError, "Use --with-token when reading a token from piped stdin" unless input.tty?

          @err.print "API token: "
          @err.flush
          begin
            input.noecho(&:gets).to_s.strip
          ensure
            @err.puts
          end
        end
      end
    end
  end
end
