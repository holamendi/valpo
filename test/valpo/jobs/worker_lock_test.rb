# frozen_string_literal: true

require "test_helper"

class ValpoJobsWorkerLockTest < Minitest::Test
  def test_lock_is_nonblocking_and_reusable
    database_path = File.join(VALPO_TEST_DIR, "worker-lock", "valpo.sqlite3")
    first = Valpo::Jobs::WorkerLock.new(database_path:)
    second = Valpo::Jobs::WorkerLock.new(database_path:)

    first.synchronize do
      error = assert_raises Valpo::ConflictError do
        second.synchronize { flunk "second worker must not acquire the lock" }
      end
      assert_equal "Another Valpo worker is already running", error.message
    end

    assert_equal :acquired, second.synchronize { :acquired }
    assert_equal "#{Process.pid}\n", File.read("#{database_path}.worker.lock")
    assert_equal 0o600, File.stat("#{database_path}.worker.lock").mode & 0o777
  end
end
