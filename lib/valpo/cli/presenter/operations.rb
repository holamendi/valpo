# frozen_string_literal: true

module Valpo
  module CLI
    class Presenter
      module Operations
        def operation(value)
          return emit_json(value) if json?

          if value.is_a?(Hash) && value["service"] && !value["job"]
            service(value.fetch("service"))
          elsif value.is_a?(Hash) && value["job"]
            resource = value["service"] || value["domain"] || value["app_domain"]
            details({
              "resource" => resource && (resource["name"] || resource["hostname"] || resource["id"]),
              "job" => value.dig("job", "id"),
              "status" => value.dig("job", "status")
            }, %w[resource job status])
          elsif value.is_a?(Hash) && value["id"].to_s.start_with?("job_")
            details(value, %w[id type status progress error])
          elsif value.is_a?(Hash)
            details(value, value.keys.select { scalar?(value[it]) })
          else
            out.puts value
          end
        end

        def preview(value)
          return emit_json(value) if json?

          actions = value.fetch("actions", [])
          table(actions, [
            ["OPERATION", -> { it["operation"] }],
            ["RESOURCE", -> { it["resource"] || it["type"] }],
            ["NAME", -> { it["name"] }]
          ], empty: "No changes.")
        end
      end
    end
  end
end
