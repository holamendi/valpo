# frozen_string_literal: true

require "test_helper"

class ValpoJobEventTest < Minitest::Test
  include ValpoTestDatabase

  def test_job_event_assigns_defaults
    job = Valpo::Job.create(type: "system_check", payload_json: "{}")
    event = Valpo::JobEvent.create(job_id: job.id, stream: "system", message: "Job queued")

    assert_kind_of Sequel::Model, event
    assert_match(/\A[0-9a-f-]{36}\z/, event.id)
    assert_equal job.id, event.job_id
    assert_equal "system", event.stream
    assert_equal "Job queued", event.message
    assert event.created_at
  end
end
