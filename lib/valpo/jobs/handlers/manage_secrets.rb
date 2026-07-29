# frozen_string_literal: true

module Valpo
  module Jobs
    module Handlers
      class ManageSecrets
        OPERATIONS = %i[verify rotate].freeze

        def initialize(manager:, operation:)
          raise ArgumentError, "Unsupported secrets operation: #{operation}" unless OPERATIONS.include?(operation)

          @manager = manager
          @operation = operation
        end

        def call(job, queue:)
          result = manager.public_send(operation)
          queue.event(job.id, "system", message(result))
        end

        private

        attr_reader :manager, :operation

        def message(result)
          counts = result.fetch(:records).map { |name, count| "#{name}=#{count}" }.join(", ")
          if operation == :rotate
            "Rotated host key from version #{result.fetch(:previous_key_version)} to " \
              "#{result.fetch(:active_key_version)} and verified #{result.fetch(:total)} encrypted records (#{counts})"
          else
            "Verified #{result.fetch(:total)} encrypted records with host key version " \
              "#{result.fetch(:active_key_version)} (#{counts})"
          end
        end
      end
    end
  end
end
