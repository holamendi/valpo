# frozen_string_literal: true

require "fileutils"
require "tempfile"

module Valpo
  module Credentials
    class PrivateFileStore
      def initialize(path)
        @path = path
      end

      def read
        File.binread(path)
      rescue Errno::ENOENT
        nil
      rescue SystemCallError => e
        raise Valpo::ValidationError, "Cannot read credential file #{path}: #{e.message}"
      end

      def write(value)
        contents = value.to_s
        raise Valpo::ValidationError, "Credential file must not be empty" if contents.empty?

        directory = File.dirname(path)
        FileUtils.mkdir_p(directory, mode: 0o700)
        temporary = Tempfile.new(".valpo-credential-", directory)
        temporary.chmod(0o600)
        temporary.binmode
        temporary.write(contents)
        temporary.flush
        temporary.fsync
        temporary.close
        File.rename(temporary.path, path)
        File.chmod(0o600, path)
        contents
      rescue SystemCallError => e
        raise Valpo::ValidationError, "Cannot write credential file #{path}: #{e.message}"
      ensure
        temporary&.close!
      end

      def delete
        File.unlink(path)
        true
      rescue Errno::ENOENT
        false
      rescue SystemCallError => e
        raise Valpo::ValidationError, "Cannot delete credential file #{path}: #{e.message}"
      end

      private

      attr_reader :path
    end
  end
end
