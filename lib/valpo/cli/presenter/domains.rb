# frozen_string_literal: true

module Valpo
  module CLI
    class Presenter
      module Domains
        def domains(value)
          return emit_json(value) if json?

          table(value, [
            ["HOSTNAME", -> { it["hostname"] }],
            ["TYPE", -> { it["kind"] }],
            ["STATUS", -> { it["status"] }],
            ["TARGET", -> { it["route_target"] }],
            ["ID", -> { it["id"] }]
          ], empty: "No domains found.")
        end

        def app_domain(value)
          return emit_json(value) if json?

          rows = [value["active"], value["candidate"]].compact
          table(rows, [
            ["HOSTNAME", -> { it["hostname"] }],
            ["STATUS", -> { it["status"] }],
            ["ACTIVE", -> { it["active"] }],
            ["VERIFIED", -> { it["verified_at"] }],
            ["ERROR", -> { it["verification_error"] }]
          ], empty: "No platform app domain configured.")
        end
      end
    end
  end
end
