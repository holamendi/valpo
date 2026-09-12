# frozen_string_literal: true

require "date"
require "time"

module Valpo
  module API
    module V1
      class Serializer
        class << self
          def inherited(subclass)
            super
            subclass.instance_variable_set(:@fields, (@fields || {}).dup)
          end

          def fields(*names)
            names.each { field(it) }
          end

          def field(name, **options, &block)
            @fields[name] = [block, options.fetch(:if, nil)]
          end

          def render(record)
            output = {}
            @fields.each do |name, (block, condition)|
              next if condition && !condition.call(record)

              output[name] = normalize(block ? block.call(record) : record[name])
            end
            output
          end

          def render_many(records)
            records.map { render(it) }
          end

          private

          def normalize(value)
            case value
            when String, NilClass, TrueClass, FalseClass, Numeric
              value
            when Time
              value.getutc.iso8601
            when DateTime
              value.new_offset(0).iso8601
            when Date
              value.iso8601
            when Hash
              value.transform_values { normalize(it) }
            when Array
              value.map { normalize(it) }
            else
              value
            end
          end
        end
      end
    end
  end
end
