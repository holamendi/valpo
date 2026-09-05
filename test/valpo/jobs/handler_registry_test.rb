# frozen_string_literal: true

require "test_helper"

class ValpoJobsHandlerRegistryTest < Minitest::Test
  include ValpoTestDatabase

  def test_registry_covers_exactly_every_queue_supported_type
    handlers = Valpo::Jobs::HandlerRegistry.build(config: VALPO_TEST_CONFIG)

    assert_equal Valpo::Jobs::Queue::SUPPORTED_TYPES.sort, handlers.keys.sort
    handlers.each_value { assert_respond_to it, :call }
    assert_equal Valpo::Jobs::Queue::SUPPORTED_TYPES.sort, Valpo::Jobs::RecoveryPolicy::STRATEGIES.keys.sort
  end

  def test_registry_uses_the_extracted_handler_classes
    handlers = Valpo::Jobs::HandlerRegistry.build(config: VALPO_TEST_CONFIG)
    expected = {
      "system_check" => Valpo::Jobs::Handlers::SystemCheck,
      "repair_system" => Valpo::Jobs::Handlers::RepairSystem,
      "maintain_storage" => Valpo::Jobs::Handlers::MaintainStorage,
      "verify_secrets" => Valpo::Jobs::Handlers::ManageSecrets,
      "rotate_secrets" => Valpo::Jobs::Handlers::ManageSecrets,
      "deploy_registry_image" => Valpo::Jobs::Handlers::DeployRegistryImage,
      "deploy_source" => Valpo::Jobs::Handlers::DeploySource,
      "create_source_service" => Valpo::Jobs::Handlers::CreateSource,
      "update_app_service" => Valpo::Jobs::Handlers::UpdateApp,
      "rollback_release" => Valpo::Jobs::Handlers::AppOperation,
      "verify_domain" => Valpo::Jobs::Handlers::VerifyDomain,
      "verify_platform_domain" => Valpo::Jobs::Handlers::VerifyPlatformDomain,
      "apply_caddy_config" => Valpo::Jobs::Handlers::ApplyCaddyConfig,
      "delete_project" => Valpo::Jobs::Handlers::DeleteProject,
      "provision_service" => Valpo::Jobs::Handlers::ProvisionManaged,
      "bind_service" => Valpo::Jobs::Handlers::BindDependency,
      "unbind_service" => Valpo::Jobs::Handlers::BindDependency,
      "stop_service" => Valpo::Jobs::Handlers::ServiceOperation,
      "restart_service" => Valpo::Jobs::Handlers::ServiceOperation,
      "reconcile_service_environment" => Valpo::Jobs::Handlers::ReconcileEnvironment,
      "delete_service" => Valpo::Jobs::Handlers::ServiceOperation,
      "apply_project_manifest" => Valpo::Jobs::Handlers::ApplyProjectManifest
    }

    assert_equal expected, handlers.transform_values(&:class)
  end

  def test_nonconvergent_handlers_require_compensation
    nonconvergent = %w[
      apply_project_manifest bind_service create_source_service delete_project delete_service deploy_registry_image
      deploy_source provision_service reconcile_service_environment restart_service rollback_release rotate_secrets
      unbind_service update_app_service verify_domain verify_platform_domain
    ]

    assert_equal ["compensating"], nonconvergent.map { Valpo::Jobs::RecoveryPolicy.fetch(it) }.uniq
    assert_empty Valpo::Jobs::RecoveryPolicy::STRATEGIES.values.grep("resumable")
  end
end
