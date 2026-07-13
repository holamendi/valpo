# frozen_string_literal: true

require "open3"

module Valpo
  module Sources
    class GitCommandRunner
      def capture(environment, command)
        stdout, stderr, status = Open3.capture3(environment, *command)
        {stdout: stdout, stderr: stderr, status: status.exitstatus, success: status.success?}
      end
    end
  end
end
