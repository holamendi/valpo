# frozen_string_literal: true

require "json"
require "time"

module Valpo
  module Manifests
    class Reconciler
      def initialize(service_orchestrator: nil, deployment_orchestrator: nil)
        @service_orchestrator = service_orchestrator
        @deployment_orchestrator = deployment_orchestrator
      end

      def preview(manifest)
        project = Valpo::Project.where(name: manifest.dig("project", "name")).first
        actions = [action(project ? "noop" : "create", "project", manifest.dig("project", "name"))]
        preview_sources(actions, project, manifest.fetch("sources"))
        preview_builds(actions, project, manifest.fetch("builds"))
        preview_services(actions, project, manifest.fetch("services"))
        preview_dependencies(actions, project, manifest.fetch("services"))
        {"project" => manifest.dig("project", "name"), "digest" => manifest.fetch("digest"), "actions" => actions}
      end

      def apply(manifest, queue:, job_id:)
        project = Valpo::Project.where(name: manifest.dig("project", "name")).first ||
          Valpo::Project.create(name: manifest.dig("project", "name"))
        event(queue, job_id, "Applying project #{project.name}")
        sources = reconcile_sources(project, manifest.fetch("sources"), queue: queue, job_id: job_id)
        builds = reconcile_builds(project, manifest.fetch("builds"), sources, queue: queue, job_id: job_id)
        services, changed_apps = reconcile_services(project, manifest.fetch("services"), builds, queue: queue, job_id: job_id)
        reconcile_dependencies(manifest.fetch("services"), services, queue: queue, job_id: job_id)
        restart_changed_apps(changed_apps, queue: queue, job_id: job_id)
        project.update(manifest_digest: manifest.fetch("digest"), last_applied_at: Time.now.utc)
        project.refresh
      end

      private

      attr_reader :service_orchestrator, :deployment_orchestrator

      def preview_sources(actions, project, declarations)
        existing = project ? Valpo::Source.where(project_id: project.id).to_hash(:name) : {}
        declarations.each do |name, config|
          record = existing[name]
          matches = record && %w[provider repository ref auto_deploy].all? { |key| record[key.to_sym] == config.fetch(key) }
          actions << action(preview_operation(record, matches), "source", name)
        end
        retained_actions(actions, existing, declarations, "source")
      end

      def preview_builds(actions, project, declarations)
        existing = project ? Valpo::BuildTarget.where(project_id: project.id).to_hash(:name) : {}
        declarations.each do |name, config|
          record = existing[name]
          source_name = record && Valpo::Source[record.source_id]&.name
          matches = record && source_name == config.fetch("source") &&
            record.dockerfile == config.fetch("dockerfile") && record.context == config.fetch("context")
          actions << action(preview_operation(record, matches), "build", name)
        end
        retained_actions(actions, existing, declarations, "build")
      end

      def preview_services(actions, project, declarations)
        existing = project ? Valpo::Service.where(project_id: project.id).to_hash(:name) : {}
        declarations.each do |name, config|
          service = existing[name]
          unless service
            actions << action("create", "service", name)
            next
          end
          raise Valpo::ConflictError, "Service kind is immutable for #{name}" unless service.kind == config.fetch("type")

          matches = service.managed? ? managed_matches?(service, config) : app_matches?(service, config)
          actions << action(matches ? "noop" : "update", "service", name)
        end
        retained_actions(actions, existing, declarations, "service")
      end

      def preview_dependencies(actions, project, declarations)
        return unless project

        services = Valpo::Service.where(project_id: project.id).to_hash(:name)
        declared = declarations.flat_map do |name, config|
          config.fetch("depends_on", []).map { |dependency| [name, dependency] }
        end
        declared.each do |app_name, dependency_name|
          app = services[app_name]
          dependency = services[dependency_name]
          exists = app && dependency && Valpo::ServiceDependency.where(
            service_id: app.id, dependency_service_id: dependency.id
          ).first
          actions << action(exists ? "noop" : "create", "dependency", "#{app_name}->#{dependency_name}")
        end
        Valpo::ServiceDependency.where(service_id: services.values.map(&:id)).each do |dependency|
          app_name = Valpo::Service[dependency.service_id]&.name
          dependency_name = Valpo::Service[dependency.dependency_service_id]&.name
          pair = [app_name, dependency_name]
          actions << action("retain", "dependency", "#{app_name}->#{dependency_name}") unless declared.include?(pair)
        end
      end

      def managed_matches?(service, config)
        managed = Valpo::Services::Catalog.managed_config(service)
        raise Valpo::ConflictError, "Managed service version is immutable for #{service.name}" unless managed.version == config.fetch("version")
        true
      end

      def app_matches?(service, config)
        app = Valpo::AppServiceConfig[service.id]
        build_name = app.build_target_id && Valpo::BuildTarget[app.build_target_id]&.name
        build_name == config["build"] && app.command == config.fetch("command") &&
          app.internal_port == config["port"] && app.healthcheck_path == config["healthcheck"]
      end

      def retained_actions(actions, existing, declarations, type)
        (existing.keys - declarations.keys).sort.each { |name| actions << action("retain", type, name) }
      end

      def preview_operation(record, matches)
        return "create" unless record

        matches ? "noop" : "update"
      end

      def action(operation, type, name)
        {"operation" => operation, "type" => type, "name" => name}
      end

      def reconcile_sources(project, declarations, queue:, job_id:)
        declarations.to_h do |name, config|
          source = Valpo::Source.where(project_id: project.id, name: name).first
          attributes = {
            provider: config.fetch("provider"), repository: config.fetch("repository"), ref: config.fetch("ref"),
            auto_deploy: config.fetch("auto_deploy"), owner_service_id: nil
          }
          if source
            connection_changed = %i[provider repository ref].any? { |key| source[key] != attributes.fetch(key) }
            attributes[:status] = "unconnected" if connection_changed
            source.update(attributes)
          else
            source = Valpo::Source.create(attributes.merge(project_id: project.id, name: name))
          end
          event(queue, job_id, "Configured source #{name}")
          [name, source]
        end
      end

      def reconcile_builds(project, declarations, sources, queue:, job_id:)
        declarations.to_h do |name, config|
          build = Valpo::BuildTarget.where(project_id: project.id, name: name).first
          attributes = {
            source_id: sources.fetch(config.fetch("source")).id,
            dockerfile: config.fetch("dockerfile"), context: config.fetch("context"), owner_service_id: nil
          }
          if build
            build.update(attributes)
          else
            build = Valpo::BuildTarget.create(attributes.merge(project_id: project.id, name: name))
          end
          event(queue, job_id, "Configured build #{name}")
          [name, build]
        end
      end

      def reconcile_services(project, declarations, builds, queue:, job_id:)
        changed_apps = []
        services = declarations.to_h do |name, config|
          service = Valpo::Service.where(project_id: project.id, name: name).first
          if service
            raise Valpo::ConflictError, "Service kind is immutable for #{name}" unless service.kind == config.fetch("type")
            changed_apps << service if update_service_config(service, config, builds)
          else
            service = create_service(project, name, config, builds)
            provision(service, queue: queue, job_id: job_id) if service.managed?
          end
          event(queue, job_id, "Configured service #{name}")
          [name, service]
        end
        [services, changed_apps]
      end

      def create_service(project, name, config, builds)
        Valpo::Services::Catalog.create_service(
          project_id: project.id,
          name: name,
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
          managed = Valpo::Services::Catalog.managed_config(service)
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
        services.each do |service|
          next unless service.status == "running"

          release = Valpo::Release.active_for_service(service.id)
          next unless release

          config = Valpo::AppServiceConfig[service.id]
          release.update(internal_port: config.internal_port, healthcheck_path: config.healthcheck_path)
          deployment.restart_service(service_id: service.id, queue: queue, job_id: job_id)
        end
      end

      def reconcile_dependencies(declarations, services, queue:, job_id:)
        declarations.each do |name, config|
          next unless Valpo::Services::Catalog.app_type?(config.fetch("type"))

          app = services.fetch(name)
          config.fetch("depends_on").each do |dependency_name|
            managed = services.fetch(dependency_name)
            existing = Valpo::ServiceDependency.where(service_id: app.id, dependency_service_id: managed.id, status: "active").first
            next if existing

            orchestrator.bind_service(service_id: app.id, dependency_service_id: managed.id, queue: queue, job_id: job_id)
          end
        end
      end

      def provision(service, queue:, job_id:)
        orchestrator.provision_service(service_id: service.id, queue: queue, job_id: job_id)
      end

      def orchestrator
        @service_orchestrator ||= Valpo::Services::Orchestrator.new
      end

      def deployment
        @deployment_orchestrator ||= Valpo::Deployments::Orchestrator.new
      end

      def event(queue, job_id, message)
        queue.event(job_id, "system", message)
      end
    end
  end
end
