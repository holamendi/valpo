# frozen_string_literal: true

module Valpo
  module API
    class App
      hash_branch("/v1", "jobs") do |r|
        # GET /v1/jobs — list jobs.
        r.get true do
          validate_query
          jobs.list.map { V1::Jobs.render(it) }
        end

        r.on String do |id|
          r.on "events" do
            # GET /v1/jobs/{job}/events — list a job's events.
            r.get true do
              validate_query
              next not_found("Job not found") unless jobs.find(id)

              jobs.events(id).map { V1::Jobs.render_event(it) }
            end
          end

          # GET /v1/jobs/{job} — show a job.
          r.get true do
            validate_query
            job = jobs.find(id)
            next not_found("Job not found") unless job

            V1::Jobs.render(job)
          end
        end
        not_found("Route not found")
      end
    end
  end
end
