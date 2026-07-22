# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module Valpo
  module API
    class Client
      DEFAULT_OPEN_TIMEOUT = 5
      DEFAULT_READ_TIMEOUT = 60
      MAX_ERROR_BODY_BYTES = 4096

      class Error < StandardError; end

      def initialize(base_url:, config_path: nil, http_factory: nil)
        @base_uri = parse_base_uri(base_url)
        @config_path = config_path
        @http_factory = http_factory || ->(uri) { Net::HTTP.new(uri.host, uri.port) }
      end

      def request(method, path, payload = nil, query: nil)
        uri = build_uri(path, query)
        request = request_class(method).new(uri)
        request["Content-Type"] = "application/json"
        token = resolved_api_token
        request["Authorization"] = "Bearer #{token}" if token
        request.body = JSON.generate(payload) if payload

        response = perform(uri, request)
        parsed = parse_response(response)
        return parsed if response.code.to_i < 400

        body = bounded_body(response.body)
        message = parsed.is_a?(Hash) ? bounded_body(parsed.fetch("message", body)) : body
        raise Error, "#{response.code}: #{message}"
      end

      private

      attr_reader :base_uri, :config_path, :http_factory

      def perform(uri, request)
        http = http_factory.call(uri)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = DEFAULT_OPEN_TIMEOUT
        http.read_timeout = DEFAULT_READ_TIMEOUT
        http.request(request)
      rescue IOError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError, SocketError, SystemCallError => e
        raise Error, "API request failed: #{e.message}"
      end

      def parse_response(response)
        JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        return nil if response.code.to_i >= 400

        raise Error, "API returned invalid JSON: #{bounded_body(response.body)}"
      end

      def resolved_api_token
        blank_to_nil(ENV["VALPO_API_TOKEN"]) || api_config.api_token
      end

      def api_config
        @api_config ||= Valpo::Config.load(path: config_path)
      end

      def blank_to_nil(value)
        (value.nil? || value.to_s.strip.empty?) ? nil : value.to_s
      end

      def request_class(method)
        {
          get: Net::HTTP::Get,
          post: Net::HTTP::Post,
          put: Net::HTTP::Put,
          patch: Net::HTTP::Patch,
          delete: Net::HTTP::Delete
        }.fetch(method.to_sym)
      rescue KeyError
        raise Error, "Unsupported HTTP method: #{method}"
      end

      def parse_base_uri(value)
        uri = URI.parse(value.to_s)
        unless %w[http https].include?(uri.scheme) && uri.host && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
          raise Error, "API URL must be an HTTP(S) URL without credentials, query, or fragment"
        end

        uri.path = "#{uri.path.sub(%r{/+\z}, "")}/"
        uri
      rescue URI::InvalidURIError
        raise Error, "API URL must be a valid HTTP(S) URL"
      end

      def build_uri(path, query)
        relative_path = path.to_s.sub(%r{\A/+}, "")
        uri = URI.join(base_uri.to_s, relative_path)
        uri.query = URI.encode_www_form(query.compact) if query && !query.compact.empty?
        uri
      rescue URI::InvalidURIError => e
        raise Error, "Invalid API path: #{e.message}"
      end

      def bounded_body(value)
        body = value.to_s
        return body if body.bytesize <= MAX_ERROR_BODY_BYTES

        "#{body.byteslice(0, MAX_ERROR_BODY_BYTES)}..."
      end
    end
  end
end
