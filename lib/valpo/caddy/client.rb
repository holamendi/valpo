# frozen_string_literal: true

require "fileutils"
require "open3"
require "tempfile"

module Valpo
  module Caddy
    class Client
      Snapshot = Data.define(:contents, :mode, :existed)

      def initialize(config_path:, reload_config_path: nil, binary: "caddy", renderer: Renderer.new)
        @config_path = config_path
        @reload_config_path = reload_config_path || config_path
        @binary = binary
        @renderer = renderer
      end

      def render(routes)
        renderer.render(routes)
      end

      def write_config(routes)
        snapshot = snapshot_config
        atomic_write(render(routes), mode: snapshot.mode)
        snapshot
      rescue SystemCallError => e
        raise Valpo::ValidationError, "Cannot write Caddy config #{config_path}: #{e.message}"
      end

      def restore_config(snapshot)
        if snapshot.existed
          atomic_write(snapshot.contents, mode: snapshot.mode)
        else
          File.unlink(config_path)
          sync_directory
        end
        true
      rescue Errno::ENOENT
        true
      rescue SystemCallError => e
        raise Valpo::ValidationError, "Cannot restore Caddy config #{config_path}: #{e.message}"
      end

      def reload_command
        [binary, "reload", "--config", reload_config_path]
      end

      def execute(command)
        stdout, stderr, status = Open3.capture3(*command)
        {stdout:, stderr:, status: status.exitstatus, success: status.success?}
      end

      private

      attr_reader :config_path, :reload_config_path, :binary, :renderer

      def snapshot_config
        stat = File.stat(config_path)
        Snapshot.new(
          contents: File.binread(config_path),
          mode: stat.mode & 0o777,
          existed: true
        )
      rescue Errno::ENOENT
        Snapshot.new(contents: nil, mode: 0o644, existed: false)
      end

      def atomic_write(contents, mode:)
        directory = File.dirname(config_path)
        FileUtils.mkdir_p(directory)
        temporary = Tempfile.new(".valpo-caddy-", directory)
        temporary.binmode
        temporary.chmod(mode)
        temporary.write(contents)
        temporary.flush
        temporary.fsync
        temporary.close
        File.rename(temporary.path, config_path)
        sync_directory
      ensure
        temporary&.close!
      end

      def sync_directory
        File.open(File.dirname(config_path), File::RDONLY) { it.fsync }
      rescue Errno::EINVAL, Errno::ENOTSUP
        nil
      end
    end
  end
end
