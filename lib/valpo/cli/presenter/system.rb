# frozen_string_literal: true

module Valpo
  module CLI
    class Presenter
      module System
        def system_status(value)
          return emit_json(value) if json?

          details(value, %w[status client_version server_version compatible])
        end

        def version(value)
          return emit_json(value) if json?

          out.puts "valpo #{value.fetch("version")}"
        end
      end
    end
  end
end
