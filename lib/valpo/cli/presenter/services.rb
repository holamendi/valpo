# frozen_string_literal: true

module Valpo
  module CLI
    class Presenter
      module Services
        def services(value)
          return emit_json(value) if json?

          table(value, [
            ["PROJECT", -> { it["project"] }],
            ["SERVICE", -> { it["name"] }],
            ["TYPE", -> { it["kind"] }],
            ["STATUS", -> { it["status"] }],
            ["VERSION/PORT", method(:service_version_or_port)]
          ], empty: "No services found.")
        end

        def service(value)
          return emit_json(value) if json?

          fields = {
            "id" => value["id"],
            "project" => value["project"],
            "name" => value["name"],
            "type" => value["kind"],
            "status" => value["status"]
          }
          if value["app"]
            fields["command"] = Array(value.dig("app", "command")).join(" ")
            source = value.dig("app", "source")
            build = value.dig("app", "build")
            fields["source"] = "#{source["provider"]}:#{source["repository"]}" if source
            fields["ref"] = source["ref"] if source
            fields["source status"] = source["status"] if source
            fields["build strategy"] = build["strategy"] if build
            fields["dockerfile"] = build["dockerfile"] if build
            fields["context"] = build["context"] if build
            fields["port policy"] = value.dig("app", "port_mode")
            fields["port"] = value.dig("app", "internal_port")
            fields["active port"] = value.dig("app", "resolved_internal_port")
            fields["healthcheck"] = value.dig("app", "healthcheck_path")
          elsif value["managed"]
            fields["version"] = value.dig("managed", "version")
            fields["image"] = value.dig("managed", "image")
            fields["host"] = value.dig("managed", "internal_host")
            fields["port"] = value.dig("managed", "internal_port")
          end
          fields["dependencies"] = Array(value["dependencies"]).length
          fields["created_at"] = value["created_at"]
          details(fields, fields.keys)
        end

        def env(value)
          return emit_json(value) if json?

          table(value.fetch("env"), [
            ["NAME", -> { it["name"] }],
            ["VALUE", -> { it["value"] }],
            ["SOURCE", -> { it["service_name"] }]
          ], empty: "No managed environment variables.")
        end

        def logs(value, aggregate: false)
          return emit_json(value) if json?

          if aggregate
            value.fetch("logs").each do
              emit_log_entry(it, prefix: "[#{it.fetch("service_name")}] ")
            end
          else
            emit_log_entry(value)
          end
        end

        private

        def emit_log_entry(entry, prefix: "")
          if entry["error"]
            err.puts "#{prefix}#{entry.fetch("error")}"
            return
          end

          entry.fetch("stdout", "").each_line { out.puts "#{prefix}#{it.chomp}" }
          entry.fetch("stderr", "").each_line { err.puts "#{prefix}#{it.chomp}" }
        end

        def service_version_or_port(row)
          row.dig("managed", "version") || row.dig("app", "internal_port")
        end
      end
    end
  end
end
