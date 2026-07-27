# frozen_string_literal: true

require "test_helper"

class ValpoBuildsCommandRunnerTest < Minitest::Test
  def test_streams_stdout_and_stderr_and_returns_status
    queue = FakeQueue.new
    result = Valpo::Builds::CommandRunner.new.run(
      [
        RbConfig.ruby,
        "-e",
        "$stdout.sync = true; $stderr.sync = true; puts 'out'; warn 'err'; exit 7"
      ],
      timeout: 5,
      queue:,
      job_id: "job_test"
    )

    refute result.fetch(:success)
    assert_equal 7, result.fetch(:status)
    assert_equal "out\n", result.fetch(:stdout)
    assert_equal "err\n", result.fetch(:stderr)
    assert_includes queue.events, ["job_test", "stdout", "out\n"]
    assert_includes queue.events, ["job_test", "stderr", "err\n"]
  end

  def test_terminates_a_build_after_the_timeout
    error = assert_raises Valpo::ValidationError do
      Valpo::Builds::CommandRunner.new.run(
        [RbConfig.ruby, "-e", "sleep 10"],
        timeout: 0.05,
        queue: FakeQueue.new,
        job_id: "job_test"
      )
    end

    assert_match "timed out", error.message
  end

  def test_caps_persisted_output_but_keeps_the_failure_tail
    queue = FakeQueue.new
    result = Valpo::Builds::CommandRunner.new(output_limit: 10).run(
      [RbConfig.ruby, "-e", "$stdout.write('x' * 100); exit 1"],
      timeout: 5,
      queue:,
      job_id: "job_test"
    )

    assert_equal 100, result.fetch(:stdout).bytesize
    persisted = queue.events.select { it.fetch(1) == "stdout" }.sum { it.fetch(2).bytesize }
    assert_equal 10, persisted
    assert queue.events.any? { it.fetch(1) == "system" && it.fetch(2).include?("further output was not stored") }
  end

  class FakeQueue
    attr_reader :events

    def initialize
      @events = []
    end

    def event(*arguments)
      events << arguments
    end
  end
end
