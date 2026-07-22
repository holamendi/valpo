# frozen_string_literal: true

module Valpo
  module Services
    module Definitions
      class Web < Base
        def initialize
          super(
            name: "web",
            category: :app,
            description: "HTTP application routed through Caddy",
            supported_options: %i[command port internal_port healthcheck healthcheck_path]
          )
        end
      end
    end
  end
end
