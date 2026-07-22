# frozen_string_literal: true

require "json"
require "time"

module Valpo
  module Manifests
    class Reconciler
      def initialize(managed_lifecycle: nil, dependency_manager: nil, deployment_lifecycle: nil)
        @managed_lifecycle = managed_lifecycle
        @dependency_manager = dependency_manager
        @deployment_lifecycle = deployment_lifecycle
      end

      def apply(manifest, queue:, job_id:)
        project = Valpo::Project.where(name: manifest.dig("project", "name")).first ||
          Valpo::Project.create(name: manifest.dig("project", "name"))
        event(queue, job_id, "Applying project #{project.name}")
        sources = reconcile_sources(project, manifest.fetch("sources"), queue:, job_id:)
        builds = reconcile_builds(project, manifest.fetch("builds"), sources, queue:, job_id:)
        services, changed_apps = reconcile_services(project, manifest.fetch("services"), builds, queue:, job_id:)
        reconcile_dependencies(manifest.fetch("services"), services, queue:, job_id:)
        restart_changed_apps(changed_apps, queue:, job_id:)
        project.update(manifest_digest: manifest.fetch("digest"), last_applied_at: Time.now.utc)
        project.refresh
      end

      private

      attr_reader :managed_lifecycle, :dependency_manager, :deployment_lifecycle

      def reconcile_sources(project, declarations, queue:, job_id:)
        declarations.to_h do |name, config|
          source = Valpo::Source.where(project_id: project.id, name:).first
          attributes = {
            provider: config.fetch("provider"), repository: config.fetch("repository"), ref: config.fetch("ref"),
            auto_deploy: config.fetch("auto_deploy"), owner_service_id: nil
          }
          if source
            connection_changed = %i[provider repository ref].any? { source[it] != attributes.fetch(it) }
            attributes[:status] = "unconnected" if connection_changed
            source.update(attributes)
          else
            source = Valpo::Source.create(attributes.merge(project_id: project.id, name:))
          end
          event(queue, job_id, "Configured source #{name}")
          [name, source]
        end
      end

      def reconcile_builds(project, declarations, sources, queue:, job_id:)
        declarations.to_h do |name, config|
          build = Valpo::BuildTarget.where(project_id: project.id, name:).first
          attributes = {
            source_id: sources.fetch(config.fetch("source")).id,
            dockerfile: config.fetch("dockerfile"), context: config.fetch("context"), owner_service_id: nil
          }
          if build
            build.update(attributes)
          else
            build = Valpo::BuildTarget.create(attributes.merge(project_id: project.id, name:))
          end
          event(queue, job_id, "Configured build #{name}")
          [name, build]
        end
      end

      def reconcile_services(project, declarations, builds, queue:, job_id:)
        changed_apps = []
        services = declarations.to_h do |name, config|
          service = Valpo::Service.where(project_id: project.id, name:).first
          if service
            raise Valpo::ConflictError, "Service kind is immutable for #{name}" unless service.kind == config.fetch("type")
            changed_apps << service if update_service_config(service, config, builds)
          else
            service = create_service(project, name, config, builds)
            provision(service, queue:, job_id:) if service.managed?
          end
          event(queue, job_id, "Configured service #{name}")
          [name, service]
        end
        [services, changed_apps]
      end

      def create_service(project, name, config, builds)
        Valpo::Services::Creator.call(
          project_id: project.id,
          name:,
          type: config.fetch("type"),
          version: config["version"],
          command: config.fetch("command", []),
          internal_port: config["port"],
          healthcheck_path: config["healthcheck"],
          build_target_id: config["build"] && builds.fetch(config["build"]).id
        )
      end

      def update_service_config(service, config, builds)
        if service.managed?
          managed = Valpo::Services::Registry.managed_config(service)
          raise Valpo::ConflictError, "Managed service version is immutable for #{service.name}" unless managed.version == config.fetch("version")
          false
        else
          app = Valpo::AppServiceConfig[service.id]
          attributes = {
            build_target_id: config["build"] && builds.fetch(config["build"]).id,
            command_json: JSON.generate(config.fetch("command")),
            internal_port: config["port"],
            healthcheck_path: config["healthcheck"]
          }
          runtime_changed = attributes.any? { |key, value| key != :build_target_id && app[key] != value }
          app.update(attributes)
          runtime_changed
        end
      end

      def restart_changed_apps(services, queue:, job_id:)
        services.each do
          next unless it.status == "running"

          release = Valpo::Release.active_for_service(it.id)
          next unless release

          config = Valpo::AppServiceConfig[it.id]
          release.update(internal_port: config.internal_port, healthcheck_path: config.healthcheck_path)
          deployment.restart_service(service_id: it.id, queue:, job_id:)
        end
      end

      def reconcile_dependencies(declarations, services, queue:, job_id:)
        declarations.each do |name, config|
          next unless Valpo::Services::Registry.app_type?(config.fetch("type"))

          app = services.fetch(name)
          config.fetch("depends_on").each do
            managed = services.fetch(it)
            existing = Valpo::ServiceDependency.where(service_id: app.id, dependency_service_id: managed.id, status: "active").first
            next if existing

            dependencies.bind_service(service_id: app.id, dependency_service_id: managed.id, queue:, job_id:)
          end
        end
      end

      def provision(service, queue:, job_id:)
        managed_services.provision_service(service_id: service.id, queue:, job_id:)
      end

      def managed_services
        @managed_lifecycle ||= Valpo::Services::ManagedLifecycle.new
      end

      def dependencies
        @dependency_manager ||= Valpo::Services::DependencyManager.new(deployment_lifecycle: deployment)
      end

      def deployment
        @deployment_lifecycle ||= Valpo::Deployments::Lifecycle.new
      end

      def event(queue, job_id, message)
        queue.event(job_id, "system", message)
      end
    end
  end
end
