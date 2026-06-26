# frozen_string_literal: true

require "test_helper"

class ValpoJobsQueueTest < Minitest::Test
  include ValpoTestDatabase

  def test_running_job_is_not_locked_twice
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("system_check")

    first_lock = queue.lock_next("worker-1")
    second_lock = queue.lock_next("worker-2")

    assert_equal job[:id], first_lock[:id]
    assert_nil second_lock
  end

  def test_stale_locks_can_be_released
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("system_check")
    queue.lock_next("worker-1")

    assert_equal 1, queue.release_stale_locks(older_than: 0)
    relocked = queue.lock_next("worker-2")

    assert_equal job[:id], relocked[:id]
    assert_equal "worker-2", relocked[:locked_by]
  end

  def test_completion_requires_lock_owner
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("system_check")
    queue.lock_next("worker-1")

    assert_nil queue.succeed(job[:id], worker_id: "worker-2")
    assert_equal "running", queue.find(job[:id])[:status]
    assert_equal "worker-1", queue.find(job[:id])[:locked_by]

    assert_equal "succeeded", queue.succeed(job[:id], worker_id: "worker-1")[:status]
  end
end
