# frozen_string_literal: true

module Valpo
  module Jobs
    module RecoveryPolicy
      STRATEGIES = {
        "system_check" => "retryable",
        "repair_system" => "retryable",
        "maintain_storage" => "retryable",
        "verify_secrets" => "retryable",
        "rotate_secrets" => "resumable",
        "verify_platform_domain" => "retryable",
        "verify_domain" => "retryable",
        "apply_caddy_config" => "retryable",
        "deploy_registry_image" => "resumable",
        "deploy_source" => "resumable",
        "create_source_service" => "resumable",
        "update_app_service" => "resumable",
        "provision_service" => "resumable",
        "bind_service" => "resumable",
        "unbind_service" => "resumable",
        "stop_service" => "retryable",
        "restart_service" => "resumable",
        "reconcile_service_environment" => "resumable",
        "apply_project_manifest" => "resumable",
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
