# frozen_string_literal: true

require "fileutils"

module Valpo
  module Jobs
    class WorkerLock
      def initialize(database_path:)
        @path = "#{database_path}.worker.lock"
      end

      def synchronize
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        File.open(path, File::RDWR | File::CREAT, 0o600) do
          it.chmod(0o600)
          acquired = it.flock(File::LOCK_EX | File::LOCK_NB)
          raise Valpo::ConflictError, "Another Valpo worker is already running" unless acquired

          it.rewind
          it.truncate(0)
          it.write("#{Process.pid}\n")
          it.flush
          yield
        ensure
          it.flock(File::LOCK_UN) if acquired
        end
      end

      private

      attr_reader :path
    end
  end
end
