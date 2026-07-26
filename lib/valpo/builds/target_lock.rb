# frozen_string_literal: true

require "fileutils"

module Valpo
  module Builds
    class TargetLock
      def initialize(database_path:)
        @directory = File.join(File.dirname(database_path), "build-locks")
      end

      def synchronize(build_target_id)
        FileUtils.mkdir_p(directory, mode: 0o700)
        File.open(File.join(directory, "#{build_target_id}.lock"), File::RDWR | File::CREAT, 0o600) do
          it.flock(File::LOCK_EX)
          yield
        ensure
          it.flock(File::LOCK_UN)
        end
      end

      private

      attr_reader :directory
    end
  end
end
