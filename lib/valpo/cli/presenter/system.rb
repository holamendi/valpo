# frozen_string_literal: true

module Valpo
  module CLI
    class Presenter
      module System
        def system_status(value)
          return emit_json(value) if json?

          details(
            value,
            %w[
              status
              client_version
              server_version
              client_api_version
              server_api_version
              schema_version
              schema_target
              config_schema
              host_profile
              channel
              artifact_digest
              compatible
            ]
          )
        end

        def version(value)
          return emit_json(value) if json?

          out.puts "valpo #{value.fetch("version")}"
        end
      end
    end
  end
end
