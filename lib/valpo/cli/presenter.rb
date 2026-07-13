# frozen_string_literal: true

require "json"

module Valpo
  module CLI
    class Presenter
      attr_reader :err

      def initialize(out:, err:, json:)
        @out = out
        @err = err
        @json = json
      end

      def projects(value)
        return emit_json(value) if json?

        table(value, [
          ["NAME", ->(row) { row["name"] }],
          ["SERVICES", ->(row) { row["service_count"] }],
          ["SOURCES", ->(row) { row["source_count"] }],
          ["UPDATED", ->(row) { row["updated_at"] }]
        ], empty: "No projects found.")
      end

      def project(value)
        return emit_json(value) if json?

        details(value, %w[id name service_count source_count manifest_digest last_applied_at created_at updated_at])
      end

      def services(value)
        return emit_json(value) if json?

        table(value, [
          ["SERVICE", ->(row) { row["reference"] }],
          ["TYPE", ->(row) { row["kind"] }],
          ["STATUS", ->(row) { row["status"] }],
          ["VERSION/PORT", method(:service_version_or_port)]
        ], empty: "No services found.")
      end

      def service(value)
        return emit_json(value) if json?

        fields = {
          "id" => value["id"],
          "reference" => value["reference"],
          "type" => value["kind"],
          "status" => value["status"]
        }
        if value["app"]
          fields["command"] = Array(value.dig("app", "command")).join(" ")
          fields["port"] = value.dig("app", "internal_port")
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

      def domains(value)
        return emit_json(value) if json?

        table(value, [
          ["HOSTNAME", ->(row) { row["hostname"] }],
          ["TLS", ->(row) { row["tls_status"] }],
          ["TARGET", ->(row) { row["route_target"] }],
          ["ID", ->(row) { row["id"] }]
        ], empty: "No domains found.")
      end

      def releases(value)
        return emit_json(value) if json?

        table(value, [
          ["VERSION", ->(row) { row["version"] }],
          ["STATUS", ->(row) { row["status"] }],
          ["ARTIFACT", ->(row) { row["artifact_ref"] }],
          ["CREATED", ->(row) { row["created_at"] }]
        ], empty: "No releases found.")
      end

      def jobs(value)
        return emit_json(value) if json?

        table(value, [
          ["ID", ->(row) { row["id"] }],
          ["TYPE", ->(row) { row["type"] }],
          ["STATUS", ->(row) { row["status"] }],
          ["PROGRESS", ->(row) { "#{row["progress"]}%" }],
          ["CREATED", ->(row) { row["created_at"] }]
        ], empty: "No jobs found.")
      end

      def events(value)
        return emit_json(value) if json?

        table(value, [
          ["TIME", ->(row) { row["created_at"] }],
          ["STREAM", ->(row) { row["stream"] }],
          ["MESSAGE", ->(row) { row["message"] }]
        ], empty: "No job events found.")
      end

      def env(value)
        return emit_json(value) if json?

        table(value.fetch("env"), [
          ["NAME", ->(row) { row["name"] }],
          ["VALUE", ->(row) { row["value"] }],
          ["SOURCE", ->(row) { row["service_name"] }]
        ], empty: "No managed environment variables.")
      end

      def logs(value, aggregate: false)
        return emit_json(value) if json?

        if aggregate
          value.fetch("logs").each { |entry| emit_log_entry(entry, prefix: "[#{entry.fetch("service_name")}] ") }
        else
          emit_log_entry(value)
        end
      end

      def operation(value)
        return emit_json(value) if json?

        if value.is_a?(Hash) && value["service"] && !value["job"]
          service(value.fetch("service"))
        elsif value.is_a?(Hash) && value["job"]
          resource = value["service"] || value["domain"]
          details({"resource" => resource && (resource["reference"] || resource["hostname"] || resource["id"]), "job" => value.dig("job", "id"), "status" => value.dig("job", "status")}, %w[resource job status])
        elsif value.is_a?(Hash) && value["id"].to_s.start_with?("job_")
          details(value, %w[id type status progress error])
        elsif value.is_a?(Hash)
          details(value, value.keys.select { |key| scalar?(value[key]) })
        else
          @out.puts value
        end
      end

      def preview(value)
        return emit_json(value) if json?

        actions = value.fetch("actions", [])
        table(actions, [
          ["OPERATION", ->(row) { row["operation"] }],
          ["RESOURCE", ->(row) { row["resource"] || row["type"] }],
          ["NAME", ->(row) { row["name"] || row["reference"] }]
        ], empty: "No changes.")
      end

      def system_status(value)
        return emit_json(value) if json?

        details(value, %w[status client_version server_version compatible])
      end

      def version(value)
        return emit_json(value) if json?

        @out.puts "valpo #{value.fetch("version")}"
      end

      private

      attr_reader :out

      def json?
        @json
      end

      def emit_json(value)
        out.puts JSON.pretty_generate(value)
      end

      def details(value, keys)
        rows = keys.filter_map do |key|
          field = value[key]
          next if field.nil? || field == ""

          [key.tr("_", " "), display(field)]
        end
        width = rows.map { |key, _value| key.length }.max || 0
        rows.each { |key, field| out.puts "#{key.ljust(width)}  #{field}" }
      end

      def table(rows, columns, empty:)
        if rows.empty?
          out.puts empty
          return
        end

        values = rows.map { |row| columns.map { |_header, extractor| display(extractor.call(row)) } }
        widths = columns.each_index.map do |index|
          ([columns[index][0].length] + values.map { |row| row[index].length }).max
        end
        out.puts columns.each_with_index.map { |(header, _), index| header.ljust(widths[index]) }.join("  ").rstrip
        values.each { |row| out.puts row.each_with_index.map { |field, index| field.ljust(widths[index]) }.join("  ").rstrip }
      end

      def emit_log_entry(entry, prefix: "")
        if entry["error"]
          err.puts "#{prefix}#{entry.fetch("error")}"
          return
        end

        entry.fetch("stdout", "").each_line { |line| out.puts "#{prefix}#{line.chomp}" }
        entry.fetch("stderr", "").each_line { |line| err.puts "#{prefix}#{line.chomp}" }
      end

      def service_version_or_port(row)
        row.dig("managed", "version") || row.dig("app", "internal_port")
      end

      def display(value)
        case value
        when true then "yes"
        when false then "no"
        when Array then value.join(", ")
        else value.to_s
        end
      end

      def scalar?(value)
        value.nil? || value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
      end
    end
  end
end
