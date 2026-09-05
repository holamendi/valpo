# frozen_string_literal: true

module Valpo
  module Jobs
    module RecoveryPolicy
      STRATEGIES = {
        "system_check" => "retryable",
        "repair_system" => "retryable",
        "maintain_storage" => "retryable",
        "verify_secrets" => "retryable",
        "rotate_secrets" => "compensating",
        "verify_platform_domain" => "compensating",
        "verify_domain" => "compensating",
        "apply_caddy_config" => "retryable",
        "deploy_registry_image" => "compensating",
        "deploy_source" => "compensating",
        "create_source_service" => "compensating",
        "update_app_service" => "compensating",
        "provision_service" => "compensating",
        "bind_service" => "compensating",
        "unbind_service" => "compensating",
        "stop_service" => "retryable",
        "restart_service" => "compensating",
        "reconcile_service_environment" => "compensating",
        "apply_project_manifest" => "compensating",
        "rollback_release" => "compensating",
        "delete_project" => "compensating",
        "delete_service" => "compensating"
      }.freeze

      module_function

      def fetch(type)
        STRATEGIES.fetch(type.to_s)
      end
    end
  end
end
