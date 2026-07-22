# frozen_string_literal: true

require "test_helper"

class ValpoJobsQueueTest < Minitest::Test
  include ValpoTestDatabase

  def test_running_job_is_not_locked_twice_and_stale_locks_requeue
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("system_check")
    assert_equal job.id, queue.lock_next("worker-1").id
    assert_nil queue.lock_next("worker-2")
    assert_equal 1, queue.release_stale_locks(older_than: 0)
    assert_equal job.id, queue.lock_next("worker-2").id
  end

  def test_completion_requires_lock_owner
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("system_check")
    queue.lock_next("worker-1")
    assert_nil queue.succeed(job.id, worker_id: "worker-2")
    assert_equal "succeeded", queue.succeed(job.id, worker_id: "worker-1").status
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
end
