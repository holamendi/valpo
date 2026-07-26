# frozen_string_literal: true

require "json"
require "openssl"
require "uri"

module Valpo
  module GitHub
    class Client
      API_ROOT = "https://api.github.com"
      API_VERSION = "2026-03-10"

      def initialize(credentials:, requester: Requester.new, clock: -> { Time.now.to_i })
        @credentials = credentials
        @requester = requester
        @clock = clock
      end

      def convert_manifest(code)
        response = request(
          :post,
          "/app-manifests/#{escape_segment(code)}/conversions",
          authenticated: false
        )
        values = parse_success(response, "GitHub App creation")
        {
          "app_id" => values.fetch("id").to_s,
          "client_id" => values.fetch("client_id").to_s,
          "owner" => values.dig("owner", "login").to_s,
          "slug" => values.fetch("slug").to_s,
          "pem" => values.fetch("pem").to_s,
          "webhook_secret" => values.fetch("webhook_secret").to_s
        }
      rescue KeyError
        raise Valpo::ValidationError, "GitHub returned an incomplete App configuration"
      end

      def installation_token(repository)
        installation = parse_success(
          request(:get, "/repos/#{repository}/installation"),
          "GitHub App installation lookup"
        )
        installation_id = Integer(installation.fetch("id"))
        token = parse_success(
          request(
            :post,
            "/app/installations/#{installation_id}/access_tokens",
            body: {permissions: {contents: "read"}}
          ),
          "GitHub App installation token"
        ).fetch("token").to_s
        raise Valpo::ValidationError, "GitHub returned an invalid installation token" if token.empty?

        token
      rescue KeyError, ArgumentError
        raise Valpo::ValidationError, "GitHub returned an invalid App installation"
      end

      def installation(installation_id)
        parse_success(
          request(:get, "/app/installations/#{Integer(installation_id)}"),
          "GitHub App installation lookup"
        )
      rescue ArgumentError, TypeError
        raise Valpo::ValidationError, "GitHub installation ID is invalid"
      end

      private

      attr_reader :credentials, :requester, :clock

      def request(method, path, authenticated: true, body: nil)
        headers = {
          "Accept" => "application/vnd.github+json",
          "Content-Type" => "application/json",
          "User-Agent" => "valpo/#{Valpo::VERSION}",
          "X-GitHub-Api-Version" => API_VERSION
        }
        headers["Authorization"] = "Bearer #{jwt}" if authenticated
        requester.request(
          method,
          URI("#{API_ROOT}#{path}"),
          headers:,
          body: body && JSON.generate(body)
        )
      rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => e
        raise Valpo::ValidationError, "Could not reach GitHub: #{e.message}"
      end

      def parse_success(response, operation)
        status = response.fetch(:status)
        return JSON.parse(response.fetch(:body)) if status.between?(200, 299)

        message = case status
        when 401 then "GitHub rejected the App credentials"
        when 404 then "#{operation} was not found; install the GitHub App for the repository"
        when 422 then "#{operation} was rejected by GitHub"
        else "#{operation} failed with HTTP #{status}"
        end
        raise Valpo::ValidationError, message
      rescue JSON::ParserError
        raise Valpo::ValidationError, "GitHub returned an invalid response for #{operation}"
      end

      def jwt
        values = credentials.read
        issued_at = clock.call - 60
        header = encode_json(alg: "RS256", typ: "JWT")
        payload = encode_json(iat: issued_at, exp: issued_at + 600, iss: values.fetch("app_id"))
        signing_input = "#{header}.#{payload}"
        signature = OpenSSL::PKey::RSA.new(values.fetch("pem")).sign(OpenSSL::Digest.new("SHA256"), signing_input)
        "#{signing_input}.#{base64_url(signature)}"
      end

      def encode_json(value)
        base64_url(JSON.generate(value))
      end

      def base64_url(value)
        [value].pack("m0").tr("+/", "-_").delete("=")
      end

      def escape_segment(value)
        URI.encode_uri_component(value.to_s)
      end
    end
  end
end
