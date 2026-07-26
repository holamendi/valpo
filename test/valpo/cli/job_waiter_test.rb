# frozen_string_literal: true

require "stringio"
require "test_helper"

class ValpoCLIJobWaiterTest < Minitest::Test
  def test_waiter_drains_every_event_page_with_a_cursor
    first_page = 500.times.map { event(it) }
    final_event = event(500)
    client = FakeClient.new([
      first_page,
      [final_event],
      {"id" => "job_test", "status" => "succeeded"},
      []
    ])
    err = StringIO.new
    waiter = Valpo::CLI::JobWaiter.new(
      client:,
      err:,
      clock: -> { 0 },
      sleeper: ->(_duration) {}
    )

    result = waiter.wait("job_test", timeout: 1)

    assert_equal "succeeded", result.fetch("status")
    assert_equal 501, err.string.lines.length
    assert_equal [
      {"limit" => 500},
      {"limit" => 500, "after" => "evt_499"},
      {"limit" => 500, "after" => "evt_500"}
    ], client.event_queries
  end

  private

  def event(index)
    {"id" => "evt_#{index}", "stream" => "stdout", "message" => "event #{index}"}
  end

  class FakeClient
    attr_reader :event_queries

    def initialize(responses)
      @responses = responses
      @event_queries = []
    end

    def request(_method, path, query: nil)
      event_queries << query if path.end_with?("/events")
      @responses.shift || raise("unexpected request")
    end
  end
end
