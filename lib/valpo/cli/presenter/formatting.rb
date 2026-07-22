# frozen_string_literal: true

require "json"

module Valpo
  module CLI
    class Presenter
      module Formatting
        private

        attr_reader :out

        def json?
          @json
        end

        def emit_json(value)
          out.puts JSON.pretty_generate(value)
        end

        def details(value, keys)
          rows = keys.filter_map do
            field = value[it]
            next if field.nil? || field == ""

            [it.tr("_", " "), display(field)]
          end
          width = rows.map { |key, _value| key.length }.max || 0
          rows.each { |key, field| out.puts "#{key.ljust(width)}  #{field}" }
        end

        def table(rows, columns, empty:)
          if rows.empty?
            out.puts empty
            return
          end

          values = rows.map { table_values(it, columns) }
          widths = columns.each_index.map { table_width(it, columns, values) }
          out.puts columns.each_with_index.map { |(header, _), index| header.ljust(widths[index]) }.join("  ").rstrip
          values.each { out.puts table_row(it, widths) }
        end

        def table_values(row, columns)
          columns.map { |_header, extractor| display(extractor.call(row)) }
        end

        def table_width(index, columns, values)
          ([columns[index][0].length] + values.map { it[index].length }).max
        end

        def table_row(row, widths)
          row.each_with_index.map { |field, index| field.ljust(widths[index]) }.join("  ").rstrip
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
end
