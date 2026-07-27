# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "tempfile"

module Valpo
  module Secrets
    class Keyring
      KEY_BYTES = 32
      FORMAT_VERSION = 1

      def initialize(path)
        @path = path
      end

      def active_version
        data.fetch("active")
      end

      def key(version = active_version)
        encoded = data.fetch("keys").fetch(version.to_s) do
          raise Valpo::ValidationError, "Encryption key version is unavailable: #{version}"
        end
        decoded = decode_hex(encoded)
        raise Valpo::ValidationError, "Encryption key version is invalid: #{version}" unless decoded.bytesize == KEY_BYTES

        decoded
      end

      def rotate!
        values = JSON.parse(JSON.generate(data))
        version = values.fetch("keys").keys.map(&:to_i).max.to_i + 1
        values.fetch("keys")[version.to_s] = SecureRandom.hex(KEY_BYTES)
        values["active"] = version
        write(values)
        @data = values
        version
      end

      private

      attr_reader :path

      def data
        @data ||= load_or_create
      end

      def load_or_create
        create unless File.exist?(path)
        validate_permissions!
        parsed = JSON.parse(File.binread(path))
        unless parsed.is_a?(Hash) && parsed["version"] == FORMAT_VERSION &&
            parsed["active"].is_a?(Integer) && parsed["keys"].is_a?(Hash)
          raise Valpo::ValidationError, "Encryption key file is invalid"
        end

        parsed
      rescue JSON::ParserError
        raise Valpo::ValidationError, "Encryption key file is invalid"
      rescue SystemCallError => e
        raise Valpo::ValidationError, "Cannot read encryption key file: #{e.message}"
      end

      def create
        directory = File.dirname(path)
        FileUtils.mkdir_p(directory, mode: 0o700)
        values = {
          "version" => FORMAT_VERSION,
          "active" => 1,
          "keys" => {"1" => SecureRandom.hex(KEY_BYTES)}
        }
        write_exclusive(values)
      rescue Errno::EEXIST
        # Another Valpo process won the first-boot race.
      end

      def write_exclusive(values)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do
          it.write(JSON.generate(values))
          it.write("\n")
          it.flush
          it.fsync
        end
        File.chmod(0o600, path)
        fsync_directory
      end

      def write(values)
        directory = File.dirname(path)
        temporary = Tempfile.new(".valpo-keyring-", directory)
        temporary.chmod(0o600)
        temporary.write(JSON.generate(values))
        temporary.write("\n")
        temporary.flush
        temporary.fsync
        temporary.close
        File.rename(temporary.path, path)
        File.chmod(0o600, path)
        fsync_directory
      rescue SystemCallError => e
        raise Valpo::ValidationError, "Cannot write encryption key file: #{e.message}"
      ensure
        temporary&.close!
      end

      def validate_permissions!
        mode = File.stat(path).mode & 0o777
        return if (mode & 0o077).zero?

        raise Valpo::ValidationError, "Encryption key file permissions must not allow group or other access"
      end

      def fsync_directory
        File.open(File.dirname(path), File::RDONLY) { it.fsync }
      end

      def decode_hex(value)
        unless value.is_a?(String) && value.length.even? && value.match?(/\A[0-9a-f]+\z/)
          raise Valpo::ValidationError, "Encryption key is invalid"
        end

        [value].pack("H*")
      end
    end
  end
end
