# frozen_string_literal: true

require "fileutils"
require "valpo/caddy/renderer"

module Valpo
  module Caddy
    class Client
      def initialize(config_path:, binary: "caddy", renderer: Renderer.new)
        @config_path = config_path
        @binary = binary
        @renderer = renderer
      end

      def render(routes)
        renderer.render(routes)
      end

      def write_config(routes)
        FileUtils.mkdir_p(File.dirname(config_path))
        File.write(config_path, render(routes))
      end

      def reload_command
        [binary, "reload", "--config", config_path]
      end

      private

      attr_reader :config_path, :binary, :renderer
    end
  end
end
