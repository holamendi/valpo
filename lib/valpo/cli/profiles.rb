# frozen_string_literal: true

require "fileutils"
require "json"
require "tempfile"

module Valpo
  module CLI
    class Profiles
      MAX_BYTES = 1_048_576

      def initialize(path: ENV.fetch("VALPO_CLI_CONFIG") { File.join(Dir.home, ".config", "valpo", "cli.json") })
        @path = File.expand_path(path)
      end

      def read
        return empty unless File.exist?(path) || File.symlink?(path)

        validate_directory!
        File.open(path, File::RDONLY | File::NOFOLLOW) do
          validate_file!(it)
          raise OperationalError, "CLI config is too large" if it.stat.size > MAX_BYTES

          validate(JSON.parse(it.read))
        end
      rescue JSON::ParserError, KeyError, TypeError
        raise OperationalError, "Invalid CLI config; repair or remove #{path}"
      rescue SystemCallError => e
        raise OperationalError, "Cannot read CLI config: #{e.class}"
      end

      def update
        FileUtils.mkdir_p(directory, mode: 0o700)
        validate_directory!
        File.open("#{path}.lock", File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do
          validate_file!(it)
          it.flock(File::LOCK_EX)
          data = read
          yield data
          validate(data)
          Tempfile.create([".cli-", ".json"], directory) do
            it.chmod(0o600)
            it.write(JSON.pretty_generate(data) + "\n")
            it.flush
            it.fsync
            File.rename(it.path, path)
          end
        end
      rescue SystemCallError => e
        raise OperationalError, "Cannot save CLI config: #{e.class}"
      end

      def self.validate_name!(name)
        unless name.to_s.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/)
          raise UsageError, "Server name must be 1–64 letters, digits, underscores, or hyphens"
        end
      end

      private

      attr_reader :path

      def directory
        File.dirname(path)
      end

      def empty
        {"version" => 1, "current" => nil, "servers" => {}}
      end

      def validate_directory!
        stat = File.lstat(directory)
        unless stat.directory? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
          raise OperationalError, "CLI config directory must be owned by you with mode 0700: #{directory}"
        end
      end

      def validate_file!(file)
        stat = file.stat
        unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
          raise OperationalError, "CLI config and lock files must be owned by you with mode 0600"
        end
      end

      def validate(data)
        raise TypeError unless data.is_a?(Hash) && data["version"] == 1 && data["servers"].is_a?(Hash)
        raise TypeError unless data["current"].nil? || data["servers"].key?(data["current"])

        data["servers"].each do |name, profile|
          self.class.validate_name!(name)
          raise TypeError unless profile.is_a?(Hash) && profile["token"].is_a?(String) && !profile["token"].empty?
          raise TypeError unless profile["token"].match?(/\Avalpo_[A-Za-z0-9_-]+={0,2}\z/)
          raise TypeError unless profile["api_url"] == ServerAddress.normalize(profile["api_url"])
          raise TypeError unless profile["credential"].is_a?(Hash)
        end
        data
      rescue UsageError
        raise TypeError
      end
    end
  end
end
