# frozen_string_literal: true

module Valpo
  module CLI
    class Presenter
      module Projects
        def projects(value)
          return emit_json(value) if json?

          table(value, [
            ["NAME", -> { it["name"] }],
            ["SERVICES", -> { it["service_count"] }],
            ["SOURCES", -> { it["source_count"] }],
            ["UPDATED", -> { it["updated_at"] }]
          ], empty: "No projects found.")
        end

        def project(value)
          return emit_json(value) if json?

          details(value, %w[id name service_count source_count manifest_digest last_applied_at created_at updated_at])
        end
      end
    end
  end
end
