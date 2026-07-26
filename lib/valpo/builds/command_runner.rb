# frozen_string_literal: true

require "open3"

module Valpo
  module Builds
    class CommandRunner
      CHUNK_SIZE = 16 * 1024
      FAILURE_TAIL_SIZE = 16 * 1024
      TERMINATION_GRACE = 5
      SELECT_INTERVAL = 0.25

      def run(command, timeout:, queue:, job_id:)
        deadline = monotonic_time + timeout
        tails = {"stdout" => +"", "stderr" => +""}
        status = nil
        timed_out = false

        Open3.popen3(*command, pgroup: true) do |stdin, stdout, stderr, wait_thread|
          stdin.close
          streams = {stdout => "stdout", stderr => "stderr"}
          until streams.empty? && !wait_thread.alive?
            if monotonic_time >= deadline && wait_thread.alive?
              timed_out = true
              terminate(wait_thread)
            end
            drain_ready(streams, tails, queue:, job_id:)
          end
          status = wait_thread.value
        end

        if timed_out
          raise Valpo::ValidationError, "Build timed out after #{timeout} seconds"
        end

        {
          stdout: tails.fetch("stdout"),
          stderr: tails.fetch("stderr"),
          status: status.exitstatus,
          success: status.success?
        }
      rescue Errno::ENOENT => e
        raise Valpo::ValidationError, "Could not start build command: #{e.message}"
      end

      private

      def drain_ready(streams, tails, queue:, job_id:)
        ready = IO.select(streams.keys, nil, nil, SELECT_INTERVAL)&.first || []
        ready.each do
          output = it.read_nonblock(CHUNK_SIZE)
          emit(streams.fetch(it), output, tails, queue:, job_id:)
        rescue EOFError
          streams.delete(it)
          it.close
        end
      end

      def emit(stream, output, tails, queue:, job_id:)
        message = output.encode("UTF-8", invalid: :replace, undef: :replace)
        tails[stream] << message
        if tails[stream].bytesize > FAILURE_TAIL_SIZE
          tails[stream] = tails[stream].byteslice(-FAILURE_TAIL_SIZE, FAILURE_TAIL_SIZE).scrub
        end
        queue.event(job_id, stream, message) unless message.empty?
      end

      def terminate(wait_thread)
        signal("TERM", wait_thread.pid)
        grace_deadline = monotonic_time + TERMINATION_GRACE
        while wait_thread.alive? && monotonic_time < grace_deadline
          wait_thread.join(SELECT_INTERVAL)
        end
        signal("KILL", wait_thread.pid) if wait_thread.alive?
      end

      def signal(name, pid)
        Process.kill(name, -pid)
      rescue Errno::ESRCH
        nil
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
