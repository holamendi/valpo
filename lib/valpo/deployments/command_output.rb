# frozen_string_literal: true

require "valpo"

module Valpo
  module Deployments
    module CommandOutput
      private

      def execute_command(client, command, failure_message:)
        result = client.execute(command)
        emit_command_output(result)
        raise_command_error(failure_message, result) unless result.fetch(:success)

        result
      end

      def emit_command_output(result)
        stdout = result.fetch(:stdout).to_s.strip
        stderr = result.fetch(:stderr).to_s.strip
        event("stdout", stdout) unless stdout.empty?
        event("stderr", stderr) unless stderr.empty?
      end

      def event(stream, message)
        return unless queue && job_id

        queue.event(job_id, stream, message)
      end

      def raise_command_error(prefix, result)
        detail = result.fetch(:stderr).to_s.strip
        detail = result.fetch(:stdout).to_s.strip if detail.empty?
        detail = "exit #{result.fetch(:status)}" if detail.empty?
        raise Valpo::ValidationError, "#{prefix}: #{detail}"
      end
    end
  end
end
