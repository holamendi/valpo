# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Service
        class Stop < Restart
          desc "Stop a service"

          def call(service:, wait:, timeout:, api_url:, project: nil, json: false, args: nil, **)
            operate(service, "stop", project:, wait:, timeout:, api_url:, json:, args:)
          end
        end
      end
    end
  end
end
