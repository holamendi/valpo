# frozen_string_literal: true

require "uri"

module Valpo
  module CLI
    module ServerAddress
      module_function

      def normalize(value)
        uri = URI.parse(value.to_s)
        unless %w[http https].include?(uri.scheme) && uri.host && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
          raise UsageError, "Server URL must be HTTP(S) without credentials, query, or fragment"
        end
        if uri.scheme == "http" && !%w[localhost 127.0.0.1 ::1].include?(uri.hostname.downcase)
          raise UsageError, "Remote servers require HTTPS; HTTP is allowed only on loopback"
        end
        if uri.path.split("/").any? { %w[. ..].include?(it) } || uri.path.include?("%")
          raise UsageError, "Server URL must not contain encoded or relative path segments"
        end
        uri.host = uri.host.downcase
        uri.path = uri.path.sub(%r{/+\z}, "")
        uri.to_s
      rescue URI::InvalidURIError
        raise UsageError, "Server URL must be a valid HTTP(S) URL"
      end
    end
  end
end
