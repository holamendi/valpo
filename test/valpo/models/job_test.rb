# frozen_string_literal: true

require "test_helper"

class ValpoJobTest < Minitest::Test
  include ValpoTestDatabase

  def test_job_parses_payload
    job = Valpo::Job.create(type: "system_check", payload_json: JSON.generate(source: "test"))

    assert_kind_of Sequel::Model, job
    assert_equal "queued", job.status
    assert_equal 0, job.progress
    assert_equal({ "source" => "test" }, job.payload)
  end
end
