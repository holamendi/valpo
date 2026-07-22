# frozen_string_literal: true

require "uri"

module Valpo
  module CLI
    class JobWaiter
      POLL_INTERVAL = 1

      def initialize(client:, err:, clock: nil, sleeper: nil)
        @client = client
        @err = err
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @sleeper = sleeper || -> { sleep(it) }
      end

      def wait(id, timeout: DEFAULT_TIMEOUT)
        timeout = positive_timeout(timeout)
        deadline = clock.call + timeout
        seen_event_ids = {}

        loop do
          emit_events(id, seen_event_ids)
          job = client.request(:get, "/v1/jobs/#{segment(id)}")
          case job.fetch("status")
          when "succeeded"
            emit_events(id, seen_event_ids)
            return job
          when "failed"
            emit_events(id, seen_event_ids)
            detail = job["error"].to_s
            raise OperationalError, ["Job #{id} failed", detail].reject(&:empty?).join(": ")
          end

          remaining = deadline - clock.call
          raise OperationalError, "Timed out waiting for job #{id}" unless remaining.positive?

          sleeper.call([POLL_INTERVAL, remaining].min)
        end
      rescue Valpo::API::Client::Error => e
        raise OperationalError, e.message
      end

      private

      attr_reader :client, :err, :clock, :sleeper

      def emit_events(id, seen)
        client.request(:get, "/v1/jobs/#{segment(id)}/events").each do
          event_id = it.fetch("id")
          next if seen[event_id]

          seen[event_id] = true
          stream = it.fetch("stream", "system")
          err.puts "[#{stream}] #{it.fetch("message")}" unless stream == "system" && it.fetch("message").to_s.empty?
        end
      end

      def positive_timeout(value)
        timeout = Float(value)
        raise UsageError, "timeout must be greater than 0" unless timeout.positive?

        timeout
      rescue ArgumentError, TypeError
        raise UsageError, "timeout must be a number"
      end

      def segment(value)
        URI.encode_www_form_component(value.to_s)
      end
    end
  end
end
