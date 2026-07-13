# frozen_string_literal: true

module Valpo
  module API
    class App
      hash_branch("", "jobs") do |r|
        r.is { r.get { jobs.list.map { |job| Serializers.job(job) } } }
        r.on String do |id|
          r.on("events") do
            r.get do
              next not_found("Job not found") unless jobs.find(id)
              jobs.events(id).map { |event| Serializers.job_event(event) }
            end
          end
          r.is do
            r.get do
              job = jobs.find(id)
              next not_found("Job not found") unless job
              Serializers.job(job)
            end
          end
        end
      end
    end
  end
end
