# frozen_string_literal: true

require "net/http"

module Valpo
  module GitHub
    class Requester
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 15

      def request(method, uri, headers:, body: nil)
        request_class(method).new(uri.request_uri, headers).tap do
          it.body = body if body
        end.then do
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = OPEN_TIMEOUT
          http.read_timeout = READ_TIMEOUT
          response = http.request(it)
          {status: response.code.to_i, body: response.body.to_s}
        end
      end

      private

      def request_class(method)
        {get: Net::HTTP::Get, post: Net::HTTP::Post}.fetch(method.to_sym)
      end
    end
  end
end
