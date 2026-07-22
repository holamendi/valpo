# frozen_string_literal: true

module Valpo
  module CLI
    class Presenter
      module Releases
        def releases(value)
          return emit_json(value) if json?

          table(value, [
            ["VERSION", -> { it["version"] }],
            ["STATUS", -> { it["status"] }],
            ["ARTIFACT", -> { it["artifact_ref"] }],
            ["CREATED", -> { it["created_at"] }]
          ], empty: "No releases found.")
        end
      end
    end
  end
end
