# frozen_string_literal: true

module Valpo
  module Services
    module Definitions
      class Worker < Base
        def initialize
          super(
            name: "worker",
            category: :app,
            description: "Background process without a public route",
            supported_options: %i[command storage_path]
          )
        end
      end
    end
  end
end
