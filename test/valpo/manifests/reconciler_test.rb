# frozen_string_literal: true

require "test_helper"

class ValpoManifestReconcilerTest < Minitest::Test
  include ValpoTestDatabase

  def test_apply_is_idempotent
    manifest = parsed_manifest
    reconciler = build_reconciler
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
    reconciler = build_reconciler(deployment:)
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

  def test_failed_managed_service_is_repaired_on_identical_apply
    managed = FakeManaged.new
    reconciler = build_reconciler(managed:)
    manifest = parsed_manifest
    apply(reconciler, manifest)
    project = Valpo::Project.find_by_id_or_name("acme")
    service = Valpo::Service.where(project_id: project.id, name: "database").first
    service.update(status: "failed")
    project.update(manifest_digest: nil, last_applied_at: nil)

    apply(reconciler, manifest)

    assert_equal "running", service.refresh.status
    assert_equal manifest.fetch("digest"), project.refresh.manifest_digest
    assert_equal [service.id], managed.reconciled_ids
  end

  def test_failed_initial_managed_provision_is_retried_and_converges
    managed = FakeManaged.new(provision_failures: 1)
    reconciler = build_reconciler(managed:)
    manifest = parsed_manifest

    assert_raises(RuntimeError) { apply(reconciler, manifest) }
    project = Valpo::Project.find_by_id_or_name("acme")
    assert_nil project.manifest_digest
    assert_nil project.last_applied_at

    apply(reconciler, manifest)
    assert_equal manifest.fetch("digest"), project.refresh.manifest_digest
    assert_equal 2, managed.provisioned_ids.length
    assert_equal 1, managed.reconciled_ids.length

    apply(reconciler, manifest)
    assert_equal 1, managed.reconciled_ids.length
  end

  def test_failed_reconfigure_restores_only_app_and_retries
    deployment = FakeDeployment.new(failures: 1)
    managed = FakeManaged.new
    reconciler = build_reconciler(deployment:, managed:)
    manifest = parsed_manifest
    apply(reconciler, manifest)
    project = Valpo::Project.find_by_id_or_name("acme")
    app = Valpo::Service.where(project_id: project.id, name: "web").first
    app.update(status: "running")
    release = create_release(service: app, status: "active", container_name: "active", route_target: "127.0.0.1:20000")
    original = Valpo::AppServiceConfig[app.id].command_json
    changed = Marshal.load(Marshal.dump(manifest))
    changed.fetch("services").fetch("web")["command"] = ["bin/server"]

    assert_raises(RuntimeError) { apply(reconciler, changed) }
    assert_equal manifest.fetch("digest"), project.refresh.manifest_digest
    assert_equal original, Valpo::AppServiceConfig[app.id].command_json
    assert_nil release.refresh.internal_port

    apply(reconciler, changed)
    assert_equal changed.fetch("digest"), project.refresh.manifest_digest
    assert_equal 2, deployment.reconfigure_count
  end

  def test_failed_dependency_bind_retries_without_replaying_converged_app
    manifest = parsed_manifest
    apply(build_reconciler, manifest)
    project = Valpo::Project.find_by_id_or_name("acme")
    app = Valpo::Service.where(project_id: project.id, name: "web").first
    dependency = Valpo::ServiceDependency.where(service_id: app.id).first
    app.update(status: "running")
    create_release(service: app, status: "active", container_name: "active", route_target: "127.0.0.1:20000")
    dependency.transition_to!("failed")

    changed = Marshal.load(Marshal.dump(manifest))
    changed["digest"] = "changed-manifest-digest"
    changed.fetch("services").fetch("web")["command"] = ["bin/server"]
    deployment = FakeDeployment.new
    dependencies = FakeDependencies.new(failures: 1)
    reconciler = build_reconciler(deployment:, managed: FakeManaged.new, dependencies:)

    assert_raises(RuntimeError) { apply(reconciler, changed) }
    assert_equal manifest.fetch("digest"), project.refresh.manifest_digest
    assert_equal JSON.generate(["bin/server"]), Valpo::AppServiceConfig[app.id].command_json
    assert_equal 1, deployment.reconfigure_count
    assert_equal 1, dependencies.bind_count

    apply(reconciler, changed)
    assert_equal changed.fetch("digest"), project.refresh.manifest_digest
    assert_equal "active", dependency.refresh.status
    assert_equal 1, deployment.reconfigure_count
    assert_equal 2, dependencies.bind_count

    apply(reconciler, changed)
    assert_equal 1, deployment.reconfigure_count
    assert_equal 2, dependencies.bind_count
  end

  def test_source_connection_resets_when_repository_or_ref_changes
    reconciler = build_reconciler
    manifest = parsed_manifest
    apply(reconciler, manifest)
    source = Valpo::Source.first
    source.update(status: "connected")
    changed = Marshal.load(Marshal.dump(manifest))
    changed.fetch("sources").fetch("backend")["ref"] = "release"

    apply(reconciler, changed)

    assert_equal "unconnected", source.refresh.status
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

  def build_reconciler(deployment: FakeDeployment.new, managed: nil, dependencies: nil)
    dependencies ||= Valpo::Services::DependencyManager.new(
      config: VALPO_TEST_CONFIG,
      docker: ValpoTestSupport::FakeDocker.new,
      deployment_lifecycle: deployment
    )
    managed ||= Valpo::Services::ManagedLifecycle.new(
      config: VALPO_TEST_CONFIG,
      docker: ValpoTestSupport::FakeDocker.new,
      dependency_manager: dependencies,
      redis_host_requirements: Valpo::Services::RedisHostRequirements.new(
        reader: ->(_path) { "1" }
      )
    )
    Valpo::Manifests::Reconciler.new(
      managed_lifecycle: managed,
      dependency_manager: dependencies,
      deployment_lifecycle: deployment
    )
  end

  def apply(reconciler, manifest)
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("system_check")
    reconciler.apply(manifest, queue:, job_id: job.id)
  end

  class FakeDeployment
    attr_reader :service_id

    attr_reader :reconfigure_count

    def initialize(failures: 0)
      @failures = failures
      @reconfigure_count = 0
    end

    def reconfigure_service(service_id:, **)
      @service_id = service_id
      @reconfigure_count += 1
      if @failures.positive? && (@failures -= 1)
        release = Valpo::Release.active_for_service(service_id)
        release&.update(internal_port: nil, healthcheck_path: nil)
        raise "reconfigure failed"
      end
      true
    end

    def restart_service(service_id:, **)
      reconfigure_service(service_id:, **)
    end
  end

  class FakeManaged
    attr_reader :reconciled_ids

    attr_reader :provisioned_ids

    def initialize(provision_failures: 0)
      @reconciled_ids = []
      @provisioned_ids = []
      @provision_failures = provision_failures
    end

    def provision_service(service_id:, **)
      @provisioned_ids << service_id
      service = Valpo::Service[service_id]
      if @provision_failures.positive?
        @provision_failures -= 1
        service.transition_to!("failed")
        raise "provision failed"
      end
      service.transition_to!("running") unless service.status == "running"
    end

    def reconcile_service(service_id:, **)
      @reconciled_ids << service_id
      Valpo::Service[service_id].transition_to!("running")
    end
  end

  class FakeDependencies
    attr_reader :bind_count

    def initialize(failures: 0)
      @failures = failures
      @bind_count = 0
    end

    def bind_service(service_id:, dependency_service_id:, **)
      @bind_count += 1
      if @failures.positive?
        @failures -= 1
        raise "bind failed"
      end

      dependency = Valpo::ServiceDependency.where(service_id:, dependency_service_id:).first
      dependency ? dependency.transition_to!("active") : Valpo::ServiceDependency.create(
        service_id:, dependency_service_id:, status: "active"
      )
    end
  end
end
