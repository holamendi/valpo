# frozen_string_literal: true

module Valpo
  module Jobs
    class HandlerRegistry
      def self.build(config: Valpo.config || Valpo::Config.load)
        new(config:).build
      end

      def initialize(config:)
        @config = config
      end

      def build
        docker = Valpo::Docker::Client.new
        build_cache_manager = Valpo::Builds::CacheManager.new(docker:)
        image_cleaner = Valpo::Storage::ImageCleaner.new(
          docker:,
          retention_count: config.image_retention_count,
          grace_period: config.storage_cleanup_grace_period
        )
        caddy = Valpo::Caddy::Client.new(
          config_path: config.caddy_config_path,
          reload_config_path: config.caddy_reload_config_path
        )
        caddy_reconciler = Valpo::Caddy::Reconciler.new(caddy:, config:)
        activator = Valpo::Deployments::Activator.new(caddy_reconciler:)
        domains = Valpo::Domains::Orchestrator.new(
          caddy_reconciler:,
          activator:,
          config:,
          docker:
        )
        deployment = Valpo::Deployments::Lifecycle.new(
          config:,
          docker:,
          caddy:,
          caddy_reconciler:,
          activator:,
          domain_orchestrator: domains,
          build_cache_manager:,
          image_cleaner:
        )
        dependency_manager = Valpo::Services::DependencyManager.new(
          config:,
          docker:,
          deployment_lifecycle: deployment
        )
        managed = Valpo::Services::ManagedLifecycle.new(
          config:,
          docker:,
          dependency_manager:
        )
        github_authentication = Valpo::GitHub::Authentication.new
        source_fetcher = Valpo::Sources::Fetcher.new(
          adapters: {"github" => Valpo::Sources::GitHub.new(token: -> {
            github_authentication.token_for(it)
          })}
        )
        preflight = Valpo::Sources::Preflight.new(fetcher: source_fetcher)
        build_runner = Valpo::Builds::CommandRunner.new(output_limit: config.build_log_limit)
        builds = Valpo::Builds::Orchestrator.new(
          source_fetcher:,
          deployment_lifecycle: deployment,
          preflight:,
          builders: {
            "dockerfile" => Valpo::Builds::DockerfileBuilder.new(
              docker:,
              runner: build_runner,
              timeout: config.build_timeout
            ),
            "buildpack" => Valpo::Builds::BuildpackBuilder.new(
              client: Valpo::Builds::BuildpackClient.new,
              runner: build_runner,
              cache_manager: build_cache_manager,
              builder: config.buildpack_builder,
              timeout: config.build_timeout
            )
          },
          target_lock: Valpo::Builds::TargetLock.new(database_path: config.database_path)
        )
        configurator = Valpo::Sources::ServiceConfigurator.new
        updater = Valpo::Services::AppUpdater.new(
          preflight:,
          configurator:,
          builds:,
          deployment:
        )
        system_repairer = Valpo::System::Repairer.new(
          managed_lifecycle: managed,
          deployment_repairer: Valpo::Deployments::Repairer.new(config:, docker:),
          caddy_reconciler:
        )
        storage_maintainer = Valpo::Storage::Maintainer.new(
          container_cleaner: Valpo::Storage::ContainerCleaner.new(
            docker:,
            grace_period: config.storage_cleanup_grace_period
          ),
          image_cleaner:,
          build_cache_cleaner: Valpo::Storage::BuildCacheCleaner.new(
            docker:,
            cache_manager: build_cache_manager,
            retention: config.build_cache_retention
          ),
          history_cleaner: Valpo::Storage::HistoryCleaner.new(retention: config.job_retention)
        )
        secrets_manager = Valpo::Secrets::Manager.new

        handlers(
          deployment:,
          domains:,
          caddy_reconciler:,
          system_repairer:,
          managed:,
          dependency_manager:,
          preflight:,
          configurator:,
          builds:,
          updater:,
          storage_maintainer:,
          secrets_manager:
        )
      end

      private

      attr_reader :config

      def handlers(
        deployment:,
        domains:,
        caddy_reconciler:,
        system_repairer:,
        managed:,
        dependency_manager:,
        preflight:,
        configurator:,
        builds:,
        updater:,
        storage_maintainer:,
        secrets_manager:
      )
        {
          "system_check" => Handlers::SystemCheck.new,
          "repair_system" => Handlers::RepairSystem.new(repairer: system_repairer),
          "maintain_storage" => Handlers::MaintainStorage.new(maintainer: storage_maintainer),
          "verify_secrets" => Handlers::ManageSecrets.new(manager: secrets_manager, operation: :verify),
          "rotate_secrets" => Handlers::ManageSecrets.new(manager: secrets_manager, operation: :rotate),
          "deploy_registry_image" => Handlers::DeployRegistryImage.new(orchestrator: deployment),
          "deploy_source" => Handlers::DeploySource.new(orchestrator: builds),
          "create_source_service" => Handlers::CreateSource.new(
            preflight:,
            configurator:,
            builds:
          ),
          "update_app_service" => Handlers::UpdateApp.new(updater:),
          "rollback_release" => Handlers::AppOperation.new(
            orchestrator: deployment,
            method: :rollback_service
          ),
          "verify_domain" => Handlers::VerifyDomain.new(orchestrator: domains),
          "verify_platform_domain" => Handlers::VerifyPlatformDomain.new(orchestrator: domains),
          "apply_caddy_config" => Handlers::ApplyCaddyConfig.new(reconciler: caddy_reconciler),
          "delete_project" => Handlers::DeleteProject.new(orchestrator: deployment),
          "provision_service" => Handlers::ProvisionManaged.new(orchestrator: managed),
          "bind_service" => Handlers::BindDependency.new(
            orchestrator: dependency_manager,
            method: :bind_service
          ),
          "unbind_service" => Handlers::BindDependency.new(
            orchestrator: dependency_manager,
            method: :unbind_service
          ),
          "stop_service" => service_operation(deployment, managed, :stop_service),
          "restart_service" => service_operation(deployment, managed, :restart_service),
          "reconcile_service_environment" => Handlers::ReconcileEnvironment.new(
            manager: Valpo::Services::EnvironmentManager.new(deployment_lifecycle: deployment)
          ),
          "delete_service" => service_operation(deployment, managed, :delete_service),
          "apply_project_manifest" => Handlers::ApplyProjectManifest.new(
            reconciler: Valpo::Manifests::Reconciler.new(
              managed_lifecycle: managed,
              dependency_manager:,
              deployment_lifecycle: deployment,
              preflight:
            )
          )
        }
      end

      def service_operation(deployment, managed, operation)
        Handlers::ServiceOperation.new(
          deployment_lifecycle: deployment,
          managed_lifecycle: managed,
          operation:
        )
      end
    end
  end
end
