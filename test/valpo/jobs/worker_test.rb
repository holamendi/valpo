# frozen_string_literal: true

require "test_helper"

class ValpoJobsWorkerTest < Minitest::Test
  include ValpoTestDatabase

  def test_system_check_succeeds_and_unknown_job_fails
    queue = Valpo::Jobs::Queue.new
    success = queue.enqueue("system_check")
    Valpo::Jobs::Worker.new(queue: queue, worker_id: "worker-1").run(once: true)
    assert_equal "succeeded", queue.find(success.id).status

    failure = queue.enqueue("missing_handler")
    Valpo::Jobs::Worker.new(queue: queue, worker_id: "worker-1").run(once: true)
    assert_equal "failed", queue.find(failure.id).status
    assert_equal "Unknown job type: missing_handler", queue.find(failure.id).error
  end

  def test_deploy_handler_dispatches_service_id
    service = create_app_service
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue_service_operation(
      "deploy_registry_image", service_id: service.id,
      payload: {project_id: service.project_id, image: "example/app:v1", internal_port: 3000}
    )
    fake = FakeDeployment.new
    worker = Valpo::Jobs::Worker.new(
      queue: queue,
      handlers: {"deploy_registry_image" => Valpo::Jobs::DeployRegistryImage.new(orchestrator: fake)},
      worker_id: "worker-1"
    )
    worker.run(once: true)

    assert_equal service.id, fake.service_id
    assert_equal "succeeded", queue.find(job.id).status
  end

  def test_bind_handler_dispatches_both_service_ids
    project = create_project
    app = create_app_service(project: project)
    database = create_managed_service(project: project)
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue_service_operation(
      "bind_service", service_id: app.id,
      payload: {project_id: project.id, dependency_service_id: database.id}
    )
    fake = FakeManaged.new
    Valpo::Jobs::Worker.new(
      queue: queue,
      handlers: {"bind_service" => Valpo::Jobs::BindService.new(orchestrator: fake, method: :bind_service)},
      worker_id: "worker-1"
    ).run(once: true)

    assert_equal [app.id, database.id], fake.ids
    assert_equal "succeeded", queue.find(job.id).status
  end

  def test_manifest_handler_passes_normalized_manifest
    queue = Valpo::Jobs::Queue.new
    manifest = {"project" => {"name" => "hello"}}
    job = queue.enqueue("apply_project_manifest", manifest: manifest)
    fake = FakeReconciler.new
    Valpo::Jobs::Worker.new(
      queue: queue,
      handlers: {"apply_project_manifest" => Valpo::Jobs::ApplyProjectManifest.new(reconciler: fake)},
      worker_id: "worker-1"
    ).run(once: true)
    assert_equal manifest, fake.manifest
    assert_equal "succeeded", queue.find(job.id).status
  end

  class FakeDeployment
    attr_reader :service_id

    def deploy_registry_image(service_id:, **)
      @service_id = service_id
    end
  end

  class FakeManaged
    attr_reader :ids

    def bind_service(service_id:, dependency_service_id:, **)
      @ids = [service_id, dependency_service_id]
    end
  end

  class FakeReconciler
    attr_reader :manifest

    def apply(manifest, **)
      @manifest = manifest
    end
  end
end
