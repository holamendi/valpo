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

  def test_project_operations_are_serialized_per_project
    project = Valpo::Project.create(name: "hello")
    other_project = Valpo::Project.create(name: "other")
    queue = Valpo::Jobs::Queue.new

    first = queue.enqueue_project_operation(
      "deploy_registry_image",
      project_id: project.id,
      payload: { image: "example/hello:v1", internal_port: 3000 }
    )

    error = assert_raises Valpo::ConflictError do
      queue.enqueue_project_operation(
        "delete_project",
        project_id: project.id,
        payload: {}
      )
    end

    assert_match "already has an active deploy_registry_image job", error.message

    other = queue.enqueue_project_operation(
      "deploy_registry_image",
      project_id: other_project.id,
      payload: { image: "example/other:v1", internal_port: 3000 }
    )

    assert_equal other_project.id, other.payload.fetch("project_id")

    locked = queue.lock_next("worker-1")
    assert_equal first.id, locked.id
    queue.succeed(first.id, worker_id: "worker-1")

    next_job = queue.enqueue_project_operation(
      "deploy_registry_image",
      project_id: project.id,
      payload: { image: "example/hello:v2", internal_port: 3000 }
    )

    assert_equal project.id, next_job.payload.fetch("project_id")
  end

  def test_project_operation_block_does_not_run_when_project_is_busy
    project = Valpo::Project.create(name: "hello")
    queue = Valpo::Jobs::Queue.new
    queue.enqueue_project_operation("deploy_registry_image", project_id: project.id, payload: { image: "example/hello:v1", internal_port: 3000 })

    assert_raises Valpo::ConflictError do
      queue.enqueue_project_operation("apply_caddy_config", project_id: project.id) do
        Valpo::Domain.create(project_id: project.id, hostname: "hello.example.com")
      end
    end

    assert_empty Valpo::Domain.where(project_id: project.id).all
  end
end
