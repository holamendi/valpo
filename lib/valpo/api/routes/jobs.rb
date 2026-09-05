# frozen_string_literal: true

module Valpo
  module API
    class App
      hash_branch("/v1", "jobs") do |r|
        # GET /v1/jobs — list jobs.
        r.get true do
          query = validate_query(V1::Jobs::ListQueryContract)
          jobs.list(limit: query.fetch(:limit, Valpo::Jobs::Queue::DEFAULT_JOB_LIMIT)).map { V1::Jobs.render(it) }
        end

        r.on String do |id|
          r.on "retry" do
            # POST /v1/jobs/{job}/retry — retry a failed retryable or resumable job.
            r.post true do
              validate_body(V1::Contract::EmptyBody)
              next not_found("Job not found") unless jobs.find(id)

              response.status = 202
              V1::Jobs.render(jobs.retry(id))
            end
          end

          r.on "reconcile" do
            # POST /v1/jobs/{job}/reconcile — reconcile an interrupted compensating job.
            r.post true do
              validate_body(V1::Contract::EmptyBody)
              next not_found("Job not found") unless jobs.find(id)

              response.status = 202
              V1::Jobs.render(jobs.reconcile(id))
            end
          end

          r.on "events" do
            # GET /v1/jobs/{job}/events — list a job's events.
            r.get true do
              query = validate_query(V1::Jobs::EventListQueryContract)
              next not_found("Job not found") unless jobs.find(id)

              jobs.events(
                id,
                after: query[:after],
                limit: query.fetch(:limit, Valpo::Jobs::Queue::DEFAULT_EVENT_LIMIT)
              ).map { V1::Jobs.render_event(it) }
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
