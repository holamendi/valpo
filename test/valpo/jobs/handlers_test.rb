# frozen_string_literal: true

require "test_helper"

class ValpoJobsHandlersTest < Minitest::Test
  include ValpoTestDatabase

  def test_simple_handlers_forward_exact_job_payloads
    queue = Valpo::Jobs::Queue.new
    cases = [
      [Valpo::Jobs::Handlers::AppOperation, {orchestrator: recorder, method: :rollback_service}, "rollback_release", {service_id: "svc_1"}, :rollback_service],
      [Valpo::Jobs::Handlers::ApplyCaddyConfig, {reconciler: recorder}, "apply_caddy_config", {}, :apply],
      [Valpo::Jobs::Handlers::ApplyProjectManifest, {reconciler: recorder}, "apply_project_manifest", {manifest: {"project" => {"name" => "hello"}}}, :apply],
      [Valpo::Jobs::Handlers::BindDependency, {orchestrator: recorder, method: :bind_service}, "bind_service", {service_id: "svc_1", dependency_service_id: "svc_2"}, :bind_service],
      [Valpo::Jobs::Handlers::DeleteProject, {orchestrator: recorder}, "delete_project", {project_id: "prj_1"}, :delete_project],
      [Valpo::Jobs::Handlers::DeployRegistryImage, {orchestrator: recorder}, "deploy_registry_image", {service_id: "svc_1", image: "example/app:v1", internal_port: "3000"}, :deploy_registry_image],
      [Valpo::Jobs::Handlers::DeploySource, {orchestrator: recorder}, "deploy_source", {service_id: "svc_1", ref: "main", internal_port: "3000"}, :deploy_source],
      [Valpo::Jobs::Handlers::MaintainStorage, {maintainer: recorder}, "maintain_storage", {dry_run: true}, :call],
      [Valpo::Jobs::Handlers::ProvisionManaged, {orchestrator: recorder}, "provision_service", {service_id: "svc_1"}, :provision_service],
      [Valpo::Jobs::Handlers::RepairSystem, {repairer: recorder}, "repair_system", {}, :repair],
      [Valpo::Jobs::Handlers::UpdateApp, {updater: recorder}, "update_app_service", {service_id: "svc_1", runtime: {"command" => []}, deploy: true}, :update],
      [Valpo::Jobs::Handlers::VerifyDomain, {orchestrator: recorder}, "verify_domain", {domain_id: "dom_1"}, :verify_domain],
      [Valpo::Jobs::Handlers::VerifyPlatformDomain, {orchestrator: recorder}, "verify_platform_domain", {platform_domain_id: "pdm_1"}, :configure_platform_domain]
    ]

    cases.each do |handler_class, dependencies, type, payload, expected_method|
      target = dependencies.values.find { it.is_a?(Recorder) }
      job = queue.enqueue(type, payload)
      handler_class.new(**dependencies).call(job, queue:)
      assert_equal expected_method, target.calls.last.fetch(:method), handler_class.name
      assert_equal job.id, target.calls.last.fetch(:kwargs).fetch(:job_id), handler_class.name
      assert_equal true, target.calls.last.fetch(:kwargs).fetch(:dry_run) if handler_class == Valpo::Jobs::Handlers::MaintainStorage
    end
  end

  def test_service_operation_selects_app_or_managed_lifecycle
    project = create_project
    app = create_app_service(project:)
    managed = create_managed_service(project:)
    app_lifecycle = recorder
    managed_lifecycle = recorder
    handler = Valpo::Jobs::Handlers::ServiceOperation.new(
      deployment_lifecycle: app_lifecycle,
      managed_lifecycle:,
      operation: :delete_service
    )
    queue = Valpo::Jobs::Queue.new

    handler.call(queue.enqueue("delete_service", service_id: app.id, force: true), queue:)
    handler.call(queue.enqueue("delete_service", service_id: managed.id, force: true), queue:)

    assert_equal :delete_app_service, app_lifecycle.calls.last.fetch(:method)
    assert_equal :delete_service, managed_lifecycle.calls.last.fetch(:method)
    assert_equal true, managed_lifecycle.calls.last.dig(:kwargs, :force)
  end

  def test_system_check_writes_an_event
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("system_check")

    Valpo::Jobs::Handlers::SystemCheck.new.call(job, queue:)

    assert_equal "Valpo worker executed system_check", queue.events(job.id).last.message
  end

  def test_secret_management_handlers_report_safe_counts
    queue = Valpo::Jobs::Queue.new
    manager = SecretManager.new
    verification = queue.enqueue("verify_secrets")
    rotation = queue.enqueue("rotate_secrets")

    Valpo::Jobs::Handlers::ManageSecrets.new(manager:, operation: :verify).call(verification, queue:)
    Valpo::Jobs::Handlers::ManageSecrets.new(manager:, operation: :rotate).call(rotation, queue:)

    assert_equal %i[verify rotate], manager.calls
    assert_match "Verified 3 encrypted records with host key version 1", queue.events(verification.id).last.message
    assert_match "Rotated host key from version 1 to 2", queue.events(rotation.id).last.message
    refute_match "secret-value", queue.events(rotation.id).last.message
  end

  private

  def recorder
    Recorder.new
  end

  class Recorder
    attr_reader :calls

    def initialize
      @calls = []
    end

    def method_missing(method, *arguments, **kwargs)
      calls << {method:, arguments:, kwargs:}
      true
    end

    def respond_to_missing?(_method, _include_private = false)
      true
    end
  end

  class SecretManager
    attr_reader :calls

    def initialize
      @calls = []
    end

    def verify
      calls << :verify
      report(active_key_version: 1)
    end

    def rotate
      calls << :rotate
      report(previous_key_version: 1, active_key_version: 2)
    end

    private

    def report(**versions)
      versions.merge(
        records: {
          "managed_service_credentials" => 1,
          "service_environment_variables" => 1,
          "provider_credentials" => 1
        },
        total: 3
      )
    end
  end
end
