# frozen_string_literal: true

require "test_helper"

class ValpoJobsWorkerTest < Minitest::Test
  include ValpoTestDatabase

  def test_system_check_job_succeeds
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("system_check", source: "test")

    Valpo::Jobs::Worker.new(queue: queue, worker_id: "worker-1").run(once: true)

    finished = queue.find(job[:id])
    assert_equal "succeeded", finished[:status]
    assert_equal 100, finished[:progress]
    assert_nil finished[:locked_by]
    assert_includes queue.events(job[:id]).map { |event| event[:message] }, "Valpo worker executed system_check"
  end

  def test_unknown_job_type_fails
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("missing_handler")

    Valpo::Jobs::Worker.new(queue: queue, worker_id: "worker-1").run(once: true)

    finished = queue.find(job[:id])
    assert_equal "failed", finished[:status]
    assert_equal "Unknown job type: missing_handler", finished[:error]
  end

  def test_delete_project_handler_dispatches_to_orchestrator
    project = Valpo::Project.create(name: "hello")
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue_project_operation("delete_project", project_id: project.id)
    orchestrator = FakeDeleteOrchestrator.new

    Valpo::Jobs::Worker.new(
      queue: queue,
      handlers: { "delete_project" => Valpo::Jobs::DeleteProject.new(orchestrator: orchestrator) },
      worker_id: "worker-1"
    ).run(once: true)

    assert_equal "succeeded", queue.find(job[:id])[:status]
    assert_equal project.id, orchestrator.project_id
    assert_equal job.id, orchestrator.job_id
  end

  def test_worker_releases_stale_locks_before_claiming_work
    queue = Valpo::Jobs::Queue.new
    stale = queue.enqueue("system_check")
    queued = queue.enqueue("system_check")
    queue.lock_next("old-worker")

    Valpo::Jobs::Worker.new(queue: queue, worker_id: "new-worker", stale_lock_timeout: 0).run(once: true)

    assert_equal "succeeded", queue.find(stale[:id])[:status]
    assert_equal "queued", queue.find(queued[:id])[:status]
  end

  class FakeDeleteOrchestrator
    attr_reader :project_id, :job_id

    def delete_project(project_id:, queue:, job_id:)
      @project_id = project_id
      @job_id = job_id
      queue.event(job_id, "system", "fake delete")
    end
  end
end
