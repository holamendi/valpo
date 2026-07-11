# frozen_string_literal: true

require "test_helper"
require "valpo/manifests/project_manifest"
require "valpo/manifests/reconciler"

class ValpoManifestReconcilerTest < Minitest::Test
  include ValpoTestDatabase

  def test_preview_does_not_mutate_and_apply_is_idempotent
    manifest = parsed_manifest
    reconciler = build_reconciler
    preview = reconciler.preview(manifest)
    assert_equal "create", preview.fetch("actions").first.fetch("operation")
    assert_nil Valpo::Project.find_by_id_or_name("acme")

    apply(reconciler, manifest)
    project = Valpo::Project.find_by_id_or_name("acme")
    assert_equal 3, Valpo::Service.where(project_id: project.id).count
    assert_equal 1, Valpo::ServiceDependency.count
    assert_equal 1, Valpo::Source.where(project_id: project.id).count
    assert_equal manifest.fetch("digest"), project.manifest_digest

    apply(reconciler, manifest)
    assert_equal 3, Valpo::Service.where(project_id: project.id).count
    assert_equal 1, Valpo::ServiceDependency.count
  end

  def test_omitted_services_are_retained
    reconciler = build_reconciler
    manifest = parsed_manifest
    apply(reconciler, manifest)
    reduced = Marshal.load(Marshal.dump(manifest))
    reduced.fetch("services").delete("cache")
    reduced.fetch("services").fetch("web")["depends_on"] = []
    apply(reconciler, reduced)
    project = Valpo::Project.find_by_id_or_name("acme")
    assert Valpo::Service.where(project_id: project.id, name: "cache").first
  end

  def test_rejects_managed_version_change
    reconciler = build_reconciler
    manifest = parsed_manifest
    apply(reconciler, manifest)
    changed = Marshal.load(Marshal.dump(manifest))
    changed.fetch("services").fetch("database")["version"] = "17"
    assert_raises(Valpo::ConflictError) { apply(reconciler, changed) }
  end

  def test_runtime_config_change_restarts_running_app
    deployment = FakeDeployment.new
    reconciler = build_reconciler(deployment: deployment)
    manifest = parsed_manifest
    apply(reconciler, manifest)
    project = Valpo::Project.find_by_id_or_name("acme")
    app = Valpo::Service.where(project_id: project.id, name: "web").first
    app.update(status: "running")
    create_release(service: app, status: "active", container_name: "active", route_target: "127.0.0.1:20000")
    changed = Marshal.load(Marshal.dump(manifest))
    changed.fetch("services").fetch("web")["command"] = ["bin/server"]

    apply(reconciler, changed)

    assert_equal app.id, deployment.service_id
  end

  private

  def parsed_manifest
    Valpo::Manifests::ProjectManifest.parse(<<~TOML)
      schema = 1
      [project]
      name = "acme"
      [sources.backend]
      provider = "github"
      repository = "acme/backend"
      [builds.backend]
      source = "backend"
      [services.web]
      type = "web"
      build = "backend"
      port = 3000
      depends_on = ["database"]
      [services.database]
      type = "postgres"
      [services.cache]
      type = "redis"
    TOML
  end

  def build_reconciler(deployment: FakeDeployment.new)
    managed = Valpo::Services::Orchestrator.new(
      config: VALPO_TEST_CONFIG,
      docker: ValpoTestSupport::FakeDocker.new,
      deployment_orchestrator: deployment
    )
    Valpo::Manifests::Reconciler.new(service_orchestrator: managed, deployment_orchestrator: deployment)
  end

  def apply(reconciler, manifest)
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("test")
    reconciler.apply(manifest, queue: queue, job_id: job.id)
  end

  class FakeDeployment
    attr_reader :service_id

    def restart_service(service_id:, **)
      @service_id = service_id
      true
    end
  end
end
