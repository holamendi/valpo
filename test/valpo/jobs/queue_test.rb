# frozen_string_literal: true

require "test_helper"

class ValpoJobsQueueTest < Minitest::Test
  include ValpoTestDatabase

  def test_running_retryable_job_is_requeued_on_startup
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("system_check")
    assert_equal job.id, queue.lock_next("worker-1").id
    assert_nil queue.lock_next("worker-2")

    assert_equal 1, queue.recover_running_jobs
    recovered = queue.find(job.id)
    assert_equal "queued", recovered.status
    assert_equal "retry", recovered.recovery_action
    assert_nil recovered.locked_by
    assert_nil recovered.heartbeat_at
    assert_equal job.id, queue.lock_next("worker-2").id
    assert_equal 2, queue.find(job.id).attempt
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

  def test_service_operation_rolls_back_created_resource_when_job_cannot_be_saved
    service = create_app_service
    queue = Class.new(Valpo::Jobs::Queue) do
      private

      def create_job(*)
        raise Valpo::ValidationError, "job persistence failed"
      end
    end.new

    error = assert_raises Valpo::ValidationError do
      queue.enqueue_service_operation(
        "verify_domain", service_id: service.id, payload: {project_id: service.project_id}
      ) do
        domain = Valpo::Domain.create(service_id: service.id, hostname: "hello.example.com")
        it[:domain_id] = domain.id
      end
    end

    assert_equal "job persistence failed", error.message
    assert_equal 0, Valpo::Domain.count
    assert_equal 0, Valpo::Job.count
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

  def test_enqueue_unique_does_not_attach_a_new_key_to_unrelated_active_work
    queue = Valpo::Jobs::Queue.new
    first = queue.enqueue_unique("maintain_storage", dry_run: true)

    error = assert_raises(Valpo::ConflictError) do
      queue.enqueue_unique("maintain_storage", {dry_run: false}, idempotency_key: "maintenance-2")
    end
    assert_match first.id, error.message
    assert_nil first.refresh.idempotency_key
  end

  def test_idempotency_key_is_unique_across_terminal_jobs
    queue = Valpo::Jobs::Queue.new
    first = queue.enqueue("system_check", idempotency_key: "request-42")
    queue.lock_next("worker")
    queue.succeed(first.id, worker_id: "worker")

    second = queue.enqueue("system_check", idempotency_key: "request-42")
    assert_equal first.id, second.id
    assert_equal 1, Valpo::Job.where(idempotency_key: "request-42").count

    error = assert_raises(Valpo::ConflictError) do
      queue.enqueue("repair_system", idempotency_key: "request-42")
    end
    assert_match "already belongs", error.message

    mismatch = assert_raises(Valpo::ConflictError) do
      queue.enqueue("system_check", {different: true}, idempotency_key: "request-42")
    end
    assert_match "does not match the original request", mismatch.message
  end

  def test_scope_columns_and_generations_are_persisted
    project = create_project
    service = create_app_service(project:)
    dependency = create_managed_service(project:)
    queue = Valpo::Jobs::Queue.new
    first = queue.enqueue_service_operation(
      "bind_service", service_id: service.id,
      payload: {project_id: project.id, dependency_service_id: dependency.id}
    )
    queue.lock_next("worker")
    queue.succeed(first.id, worker_id: "worker")
    second = queue.enqueue_service_operation("restart_service", service_id: service.id, payload: {project_id: project.id})

    assert_equal project.id, first.project_id
    assert_equal service.id, first.service_id
    assert_equal dependency.id, first.related_service_id
    assert_equal 1, first.operation_generation
    assert_equal 2, second.operation_generation
    assert_equal "compensating", second.recovery_strategy
  end

  def test_completed_checkpoint_is_finalized_without_replaying_handler
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("system_check")
    queue.lock_next("old-worker")
    queue.checkpoint(job.id, "handler_completed")

    assert_equal 1, queue.recover_running_jobs
    assert_equal "succeeded", queue.find(job.id).status
    assert_equal 1, queue.find(job.id).attempt
  end

  def test_interrupted_nonconvergent_job_is_not_automatically_replayed
    service = create_app_service
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue_service_operation(
      "deploy_source", service_id: service.id,
      payload: {project_id: service.project_id, ref: "main"}
    )
    queue.lock_next("old-worker")
    queue.checkpoint(job.id, "handler_started")

    queue.recover_running_jobs
    recovered = queue.find(job.id)
    assert_equal "failed", recovered.status
    assert_equal "handler_started", recovered.checkpoint
    assert_equal "reconcile", recovered.recovery_action
  end

  def test_interrupted_compensating_job_requires_first_class_reconciliation
    project = create_project
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue_project_operation("delete_project", project_id: project.id)
    queue.lock_next("old-worker")
    queue.checkpoint(job.id, "handler_started")

    queue.recover_running_jobs
    interrupted = queue.find(job.id)
    assert_equal "failed", interrupted.status
    assert_equal "reconcile", interrupted.recovery_action
    assert_raises(Valpo::ConflictError) { queue.retry(job.id) }

    repair = queue.reconcile(job.id)
    assert_equal "repair_system", repair.type
    assert_equal repair.id, queue.reconcile(job.id).id
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
