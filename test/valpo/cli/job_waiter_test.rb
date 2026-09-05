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

  def test_retries_transient_reads_without_reprinting_events
    client = FakeClient.new([[event(1)], Valpo::API::Client::Error.new("timeout", retryable: true), {"status" => "succeeded"}, []])
    err = StringIO.new
    delays = []
    result = Valpo::CLI::JobWaiter.new(client:, err:, clock: -> { 0 }, sleeper: -> { delays << it }).wait("job_test", timeout: 30)
    assert_equal "succeeded", result.fetch("status")
    assert_equal [1], delays
    assert_equal 1, err.string.scan("event 1").length
    assert_match "retrying job polling", err.string
  end

  def test_does_not_retry_authentication_errors
    client = FakeClient.new([Valpo::API::Client::Error.new("401 unauthorized")])
    delays = []
    assert_raises(Valpo::CLI::OperationalError) do
      Valpo::CLI::JobWaiter.new(client:, err: StringIO.new, sleeper: -> { delays << it }).wait("job_test", timeout: 30)
    end
    assert_empty delays
  end

  def test_retry_respects_wait_deadline
    client = FakeClient.new([Valpo::API::Client::Error.new("timeout", retryable: true)])
    now = 0
    assert_raises(Valpo::CLI::OperationalError) do
      Valpo::CLI::JobWaiter.new(client:, err: StringIO.new, clock: -> { now }, sleeper: -> { now += it }).wait("job_test", timeout: 0.5)
    end
    assert_equal 0.5, now
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
      response = @responses.shift || raise("unexpected request")
      raise response if response.is_a?(Exception)

      response
    end
  end
end
