# frozen_string_literal: true

module Valpo
  module GitHub
    module Manifest
      module_function

      def build(base_url)
        {
          url: base_url,
          redirect_url: "#{base_url}/callback",
          setup_url: "#{base_url}/installation",
          hook_attributes: {
            url: "#{base_url}/webhook",
            active: true
          },
          description: "Source deployments and push-triggered builds for this Valpo server",
          public: false,
          default_events: %w[push],
          default_permissions: {
            contents: "read"
          }
        }
      end
    end
  end
end
