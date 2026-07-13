# frozen_string_literal: true

require "fileutils"
require "tempfile"

module Valpo
  module Credentials
    class FileStore
      def initialize(path)
        @path = path
      end

      def read
        value = File.binread(path).strip
        value unless value.empty?
      rescue Errno::ENOENT
        nil
      rescue SystemCallError => e
        raise Valpo::ValidationError, "Cannot read credential file #{path}: #{e.message}"
      end

      def write(value)
        credential = value.to_s.strip
        if credential.empty? || credential.match?(/\s/)
          raise Valpo::ValidationError, "Credential must be a single non-empty line"
        end

        directory = File.dirname(path)
        FileUtils.mkdir_p(directory, mode: 0o700)
        temporary = Tempfile.new(".valpo-credential-", directory)
        temporary.chmod(0o600)
        temporary.write("#{credential}\n")
        temporary.flush
        temporary.fsync
        temporary.close
        File.rename(temporary.path, path)
        File.chmod(0o600, path)
        credential
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
