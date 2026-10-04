# frozen_string_literal: true

module Valpo
  module Services
    class AppStorage
      SENSITIVE_PATHS = %w[/proc /sys /dev /etc /run /var/run /var/lib/docker /var/lib/containerd /var/lib/valpo /root /boot /usr /bin /sbin /lib /lib64].freeze

      def self.volume_name(service)
        "valpo-#{service.id.tr("_", "-")}-data"
      end

      def self.validate_path!(path)
        return if path.nil?
        safe = path.is_a?(String) && path.match?(%r{\A/(?:[A-Za-z0-9_-]+)(?:/[A-Za-z0-9_.-]+)*\z}) &&
          path.split("/").none? { %w[. ..].include?(it) } &&
          SENSITIVE_PATHS.none? { path == it || path.start_with?("#{it}/") || it.start_with?("#{path}/") }
        raise Valpo::ValidationError, "storage_path must be an absolute normalized non-system directory" unless safe
      end
    end
  end
end
