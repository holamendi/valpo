# frozen_string_literal: true

module Valpo
  module CLI
    class Presenter
      module Jobs
        def jobs(value)
          return emit_json(value) if json?

          table(value, [
            ["ID", -> { it["id"] }],
            ["TYPE", -> { it["type"] }],
            ["STATUS", -> { it["status"] }],
            ["PROGRESS", -> { "#{it["progress"]}%" }],
            ["CREATED", -> { it["created_at"] }]
          ], empty: "No jobs found.")
        end

        def events(value)
          return emit_json(value) if json?

          table(value, [
            ["TIME", -> { it["created_at"] }],
            ["STREAM", -> { it["stream"] }],
            ["MESSAGE", -> { it["message"] }]
          ], empty: "No job events found.")
        end
      end
    end
  end
end
