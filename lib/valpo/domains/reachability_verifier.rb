# frozen_string_literal: true

require "net/http"
require "uri"

module Valpo
  module Domains
    class ReachabilityVerifier
      DEFAULT_TIMEOUT = 120
      DEFAULT_INTERVAL = 2
      CHALLENGE_PREFIX = "/.well-known/valpo-verification"

      def self.challenge_path(token)
        "#{CHALLENGE_PREFIX}/#{token}"
      end

      def initialize(requester: nil, sleeper: Kernel, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, timeout: DEFAULT_TIMEOUT, interval: DEFAULT_INTERVAL)
        @requester = requester || method(:https_get)
        @sleeper = sleeper
        @clock = clock
        @timeout = timeout
        @interval = interval
      end

      def verify!(hostname:, token:)
        url = "https://#{hostname}#{self.class.challenge_path(token)}"
        deadline = clock.call + timeout
        last_error = nil

        loop do
          begin
            response = requester.call(url)
            return true if response.fetch(:status).to_i == 200 && response.fetch(:body).to_s.strip == token

            last_error = "HTTP #{response.fetch(:status)} returned an unexpected response"
          rescue => e
            last_error = e.message
          end
          break if clock.call >= deadline

          sleeper.sleep(interval)
        end

        raise Valpo::ValidationError, "Domain verification failed for #{hostname}: #{last_error || "challenge was not reachable"}"
      end

      private

      attr_reader :requester, :sleeper, :clock, :timeout, :interval

      def https_get(url)
        uri = URI(url)
        response = Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: true,
          open_timeout: 5,
          read_timeout: 5
        ) { it.get(uri.request_uri) }
        {status: response.code.to_i, body: response.body}
      end
    end
  end
end
