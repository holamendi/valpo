# frozen_string_literal: true

module Valpo
  module Services
    class RedisHostRequirements
      OVERCOMMIT_MEMORY_PATH = "/proc/sys/vm/overcommit_memory"
      REQUIRED_OVERCOMMIT_MEMORY = "1"

      def initialize(reader: File.method(:read))
        @reader = reader
      end

      def validate!
        value = reader.call(OVERCOMMIT_MEMORY_PATH).strip
        return true if value == REQUIRED_OVERCOMMIT_MEMORY

        raise Valpo::ValidationError,
          "Redis requires vm.overcommit_memory=1 on the host (current value: #{value.inspect}); " \
          "re-run the Valpo installer or apply the documented sysctl setting"
      rescue SystemCallError => e
        raise Valpo::ValidationError,
          "Redis cannot verify the host vm.overcommit_memory setting: #{e.message}"
      end

      private

      attr_reader :reader
    end
  end
end
