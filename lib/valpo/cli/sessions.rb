# frozen_string_literal: true

module Valpo
  module CLI
    class Sessions
      def initialize(profiles: Profiles.new, client_factory: nil, environment: ENV)
        @profiles = profiles
        @client_factory = client_factory || ->(url, token) { Valpo::API::Client.new(base_url: url, token:) }
        @environment = environment
      end

      def client(api_url: nil, server: nil)
        raise UsageError, "Use --server or --api-url, not both" if server && api_url
        url = api_url || (environment["VALPO_API_URL"] unless server)
        token = environment["VALPO_API_TOKEN"]
        return build_client(ServerAddress.normalize(url), token) if url

        data = profiles.read
        name = server || data["current"]
        return build_client(DEFAULT_API_URL, token) unless name

        profile = fetch(data, name)
        build_client(profile.fetch("api_url"), token.nil? ? profile.fetch("token") : token)
      end

      def login(name:, url:, token:)
        Profiles.validate_name!(name)
        url = ServerAddress.normalize(url)
        unless token.is_a?(String) && token.match?(/\Avalpo_[A-Za-z0-9_-]+={0,2}\z/)
          raise UsageError, "A valid Valpo API token is required"
        end
        credential = build_client(url, token).request(:get, "/v1/session")
        unless credential.is_a?(Hash) && Valpo::Identifier.valid?(credential["id"], :api_credential) && credential["scopes"].is_a?(Array)
          raise OperationalError, "Server returned an invalid credential response"
        end
        metadata = credential.slice("id", "name", "scopes", "expires_at")
        profiles.update do
          existing = it["servers"][name]
          if existing && existing["api_url"] != url
            raise UsageError, "That server name belongs to another URL; use a new name or log out first"
          end
          it["servers"][name] = {"api_url" => url, "token" => token, "credential" => metadata}
          it["current"] = name
        end
        {"server" => name, "api_url" => url, "credential" => metadata}
      end

      def logout(name: nil, revoke: false)
        data = profiles.read
        name ||= data["current"]
        raise UsageError, "No server selected; pass --server NAME" unless name

        profile = fetch(data, name)
        build_client(profile.fetch("api_url"), profile.fetch("token")).request(:delete, "/v1/session") if revoke
        profiles.update do
          unless it["servers"][name] == profile
            raise OperationalError, "Saved login changed during logout; retry"
          end
          it["servers"].delete(name)
          it["current"] = nil if it["current"] == name
        end
        {"server" => name, "revoked" => revoke}
      end

      def list
        data = profiles.read
        data["servers"].sort.map do |name, profile|
          {"name" => name, "api_url" => profile.fetch("api_url"), "current" => name == data["current"], "credential" => profile.fetch("credential")}
        end
      end

      def use(name)
        profiles.update do
          fetch(it, name)
          it["current"] = name
        end
        {"server" => name}
      end

      private

      attr_reader :profiles, :client_factory, :environment

      def build_client(url, token)
        client_factory.call(url, token)
      end

      def fetch(data, name)
        data["servers"].fetch(name) { raise UsageError, "Unknown server; run valpo login --server URL --name NAME" }
      end
    end
  end
end
