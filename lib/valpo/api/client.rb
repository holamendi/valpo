# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module Valpo
  module API
    class Client
      class Error < StandardError; end

      def initialize(base_url:, api_token: nil, config_path: nil)
        @base_url = base_url
        @api_token = blank_to_nil(api_token)
        @config_path = config_path
      end

      def request(method, path, payload = nil)
        uri = URI.join(base_url, path)
        request = request_class(method).new(uri)
        request["Content-Type"] = "application/json"
        token = resolved_api_token
        request["Authorization"] = "Bearer #{token}" if token
        request.body = JSON.generate(payload) if payload

        response = perform(uri, request)
        parsed = parse_response(response)
        return parsed if response.code.to_i < 400

        body = response.body.to_s
        message = parsed.is_a?(Hash) ? parsed.fetch("message", body) : body
        raise Error, "#{response.code}: #{message}"
      end

      private

      attr_reader :base_url, :api_token, :config_path

      def perform(uri, request)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.request(request)
      rescue IOError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError, SocketError, SystemCallError => e
        raise Error, "API request failed: #{e.message}"
      end

      def parse_response(response)
        JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        return nil if response.code.to_i >= 400

        raise Error, "API returned invalid JSON: #{response.body}"
      end

      def resolved_api_token
        api_token || api_config.api_token
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
          delete: Net::HTTP::Delete
        }.fetch(method)
      end
    end
  end
end
