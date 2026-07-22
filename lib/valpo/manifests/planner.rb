# frozen_string_literal: true

module Valpo
  module Manifests
    class Planner
      def self.call(manifest)
        new.call(manifest)
      end

      def call(manifest)
        project = Valpo::Project.where(name: manifest.dig("project", "name")).first
        actions = [action(project ? "noop" : "create", "project", manifest.dig("project", "name"))]
        preview_sources(actions, project, manifest.fetch("sources"))
        preview_builds(actions, project, manifest.fetch("builds"))
        preview_services(actions, project, manifest.fetch("services"))
        preview_dependencies(actions, project, manifest.fetch("services"))
        {"project" => manifest.dig("project", "name"), "digest" => manifest.fetch("digest"), "actions" => actions}
      end

      private

      def preview_sources(actions, project, declarations)
        existing = project ? Valpo::Source.where(project_id: project.id).to_hash(:name) : {}
        declarations.each do |name, config|
          record = existing[name]
          matches = record && %w[provider repository ref auto_deploy].all? { record[it.to_sym] == config.fetch(it) }
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
          config.fetch("depends_on", []).map { [name, it] }
        end
        declared.each do |app_name, dependency_name|
          app = services[app_name]
          dependency = services[dependency_name]
          exists = app && dependency && Valpo::ServiceDependency.where(
            service_id: app.id, dependency_service_id: dependency.id
          ).first
          actions << action(exists ? "noop" : "create", "dependency", "#{app_name}->#{dependency_name}")
        end
        Valpo::ServiceDependency.where(service_id: services.values.map(&:id)).each do
          app_name = Valpo::Service[it.service_id]&.name
          dependency_name = Valpo::Service[it.dependency_service_id]&.name
          pair = [app_name, dependency_name]
          actions << action("retain", "dependency", "#{app_name}->#{dependency_name}") unless declared.include?(pair)
        end
      end

      def managed_matches?(service, config)
        managed = Valpo::Services::Registry.managed_config(service)
        unless managed.version == config.fetch("version")
          raise Valpo::ConflictError, "Managed service version is immutable for #{service.name}"
        end
        true
      end

      def app_matches?(service, config)
        app = Valpo::AppServiceConfig[service.id]
        build_name = app.build_target_id && Valpo::BuildTarget[app.build_target_id]&.name
        build_name == config["build"] && app.command == config.fetch("command") &&
          app.internal_port == config["port"] && app.healthcheck_path == config["healthcheck"]
      end

      def retained_actions(actions, existing, declarations, type)
        (existing.keys - declarations.keys).sort.each { actions << action("retain", type, it) }
      end

      def preview_operation(record, matches)
        return "create" unless record

        matches ? "noop" : "update"
      end

      def action(operation, type, name)
        {"operation" => operation, "type" => type, "name" => name}
      end
    end
  end
end
