# frozen_string_literal: true

module Valpo
  module Storage
    class Maintainer
      def initialize(container_cleaner:, image_cleaner:, build_cache_cleaner:, history_cleaner:)
        @components = [container_cleaner, image_cleaner, build_cache_cleaner, history_cleaner]
      end

      def call(dry_run:, queue:, job_id:)
        queue.event(job_id, "system", dry_run ? "Previewing storage maintenance" : "Running storage maintenance")
        result = components.each_with_object({}) do |component, summary|
          summary.merge!(component.call(dry_run:, queue:, job_id:))
        end
        queue.event(job_id, "system", summary_message(result, dry_run:))
        result
      end

      private

      attr_reader :components

      def summary_message(result, dry_run:)
        prefix = dry_run ? "Storage maintenance preview" : "Storage maintenance complete"
        details = result.map { |name, count| "#{name}=#{count}" }.join(" ")
        "#{prefix}: #{details}"
      end
    end
  end
end
