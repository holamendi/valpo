# frozen_string_literal: true

require "test_helper"

class ValpoJobsQueueTest < Minitest::Test
  include ValpoTestDatabase

  def test_running_job_is_not_locked_twice_and_is_abandoned_on_startup
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("system_check")
    assert_equal job.id, queue.lock_next("worker-1").id
    assert_nil queue.lock_next("worker-2")

    assert_equal 1, queue.abandon_running_jobs
    abandoned = queue.find(job.id)
    assert_equal "failed", abandoned.status
    assert_equal Valpo::Jobs::Queue::ABANDONED_ERROR, abandoned.error
    assert_nil abandoned.locked_by
    assert abandoned.finished_at
    assert_equal Valpo::Jobs::Queue::ABANDONED_EVENT, queue.events(job.id).last.message
    assert_nil queue.lock_next("worker-2")
  end

  def test_completion_requires_lock_owner
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("system_check")
    queue.lock_next("worker-1")
    assert_nil queue.succeed(job.id, worker_id: "worker-2")
    assert_equal "succeeded", queue.succeed(job.id, worker_id: "worker-1").status
  end

  def test_job_transition_rejects_skipping_running_and_reopening_completion
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("system_check")
    assert_raises(Valpo::ValidationError) { job.transition_to!("succeeded") }

    queue.lock_next("worker")
    completed = queue.succeed(job.id, worker_id: "worker")
    assert_raises(Valpo::ValidationError) { completed.transition_to!("running") }
  end

  def test_service_operations_are_serialized_per_service
    project = create_project
    first_service = create_app_service(project:)
    second_service = create_managed_service(project:)
    queue = Valpo::Jobs::Queue.new
    first = queue.enqueue_service_operation("deploy_registry_image", service_id: first_service.id, payload: {project_id: project.id})

    error = assert_raises Valpo::ConflictError do
      queue.enqueue_service_operation("restart_service", service_id: first_service.id, payload: {project_id: project.id})
    end
    assert_match "already has an active deploy_registry_image", error.message

    other = queue.enqueue_service_operation("restart_service", service_id: second_service.id, payload: {project_id: project.id})
    assert_equal second_service.id, other.payload.fetch("service_id")
    assert_equal first.id, queue.lock_next("worker").id
  end

  def test_project_operation_conflicts_with_active_service_operation
    project = create_project
    service = create_app_service(project:)
    queue = Valpo::Jobs::Queue.new
    queue.enqueue_service_operation("deploy_registry_image", service_id: service.id, payload: {project_id: project.id})

    error = assert_raises Valpo::ConflictError do
      queue.enqueue_project_operation("delete_project", project_id: project.id)
    end
    assert_match "active deploy_registry_image", error.message
  end

  def test_enqueue_block_is_atomic_when_resource_is_busy
    project = create_project
    service = create_app_service(project:)
    queue = Valpo::Jobs::Queue.new
    queue.enqueue_service_operation("restart_service", service_id: service.id, payload: {project_id: project.id})
    called = false
    assert_raises Valpo::ConflictError do
      queue.enqueue_service_operation("stop_service", service_id: service.id, payload: {project_id: project.id}) { called = true }
    end
    refute called
  end

  def test_binding_locks_both_app_and_managed_service
    project = create_project
    app = create_app_service(project:)
    database = create_managed_service(project:)
    queue = Valpo::Jobs::Queue.new
    queue.enqueue_service_operation(
      "bind_service", service_id: app.id,
      payload: {project_id: project.id, dependency_service_id: database.id}
    )
    assert_raises(Valpo::ConflictError) do
      queue.enqueue_service_operation("delete_service", service_id: database.id, payload: {project_id: project.id})
    end
  end

  def test_manifest_job_remains_project_visible_after_project_is_created
    manifest = {"project" => {"name" => "acme"}}
    queue = Valpo::Jobs::Queue.new
    queue.enqueue_manifest_operation(project_name: "acme", manifest:)
    project = create_project(name: "acme")
    assert_equal "apply_project_manifest", queue.active_project_job(project.id).type
  end

  def test_enqueue_rejects_unsupported_job_types
    queue = Valpo::Jobs::Queue.new
    project = create_project
    service = create_app_service(project:)
    called = false

    error = assert_raises Valpo::ValidationError do
      queue.enqueue_service_operation(
        "missing_handler",
        service_id: service.id,
        payload: {project_id: project.id}
      ) { called = true }
    end

    assert_equal "Unsupported job type: missing_handler", error.message
    refute called
    assert_equal 0, Valpo::Job.count
  end

  def test_enqueue_unique_reuses_an_active_job
    queue = Valpo::Jobs::Queue.new
    first = queue.enqueue_unique("maintain_storage")
    second = queue.enqueue_unique("maintain_storage", dry_run: true)

    assert_equal first.id, second.id
    assert_equal 1, Valpo::Job.where(type: "maintain_storage").count

    queue.lock_next("worker")
    queue.succeed(first.id, worker_id: "worker")
    refute_equal first.id, queue.enqueue_unique("maintain_storage").id
  end

  def test_list_and_events_are_bounded_and_stably_cursor_ordered
    queue = Valpo::Jobs::Queue.new
    105.times { queue.enqueue("system_check") }

    assert_equal 100, queue.list.length
    assert_equal 3, queue.list(limit: 3).length

    job = queue.list(limit: 1).first
    timestamp = Time.utc(2099, 7, 26, 12)
    %w[evt_c evt_a evt_b].each do
      db[:job_events].insert(id: it, job_id: job.id, stream: "system", message: it, created_at: timestamp)
    end
    events = queue.events(job.id)
    cursor_index = events.index { it.id == "evt_a" }

    assert_equal %w[evt_a evt_b evt_c], events.slice(cursor_index, 3).map(&:id)
    assert_equal %w[evt_b evt_c], queue.events(job.id, after: "evt_a").map(&:id)
  end

  def test_event_cursor_must_belong_to_the_requested_job
    queue = Valpo::Jobs::Queue.new
    first = queue.enqueue("system_check")
    second = queue.enqueue("system_check")
    cursor = queue.events(first.id).first

    error = assert_raises Valpo::ValidationError do
      queue.events(second.id, after: cursor.id)
    end

    assert_equal "Event cursor does not belong to job", error.message
  end
end
