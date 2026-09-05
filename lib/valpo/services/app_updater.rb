# frozen_string_literal: true

require "json"

module Valpo
  module Services
    class AppUpdater
      def initialize(preflight:, configurator:, builds:, deployment:)
        @preflight = preflight
        @configurator = configurator
        @builds = builds
        @deployment = deployment
      end

      def update(service_id:, configuration:, runtime_changes:, deploy:, queue:, job_id:)
        service = Valpo::Service[service_id]
        raise Valpo::ValidationError, "Service not found" unless service
        raise Valpo::ValidationError, "Operation requires an app service" unless service.app?

        snapshot = snapshot(service)
        if configuration
          source = configuration.fetch("source")
          build = configuration.fetch("build")
          queue.event(job_id, "system", "Validating #{source.fetch("repository")}@#{source.fetch("ref")}")
          preflight.with_checkout(
            provider: source.fetch("provider"),
            repository: source.fetch("repository"),
            ref: source.fetch("ref"),
            strategy: build.fetch("strategy"),
            dockerfile: build.fetch("dockerfile"),
            context: build.fetch("context")
          ) do
            checkout = it
            apply_changes(service, configuration:, runtime_changes:)
            operate(service, checkout:, runtime_changed: !runtime_changes.empty?, deploy:, queue:, job_id:)
          end
        else
          apply_changes(service, configuration: nil, runtime_changes:)
          operate(service, checkout: nil, runtime_changed: !runtime_changes.empty?, deploy:, queue:, job_id:)
        end
        service.refresh
      rescue
        restore(service, snapshot) if service && snapshot
        raise
      end

      private

      attr_reader :preflight, :configurator, :builds, :deployment

      def apply_changes(service, configuration:, runtime_changes:)
        if configuration
          configurator.apply_owned_configuration!(
            service:,
            source: configuration.fetch("source"),
            build: configuration.fetch("build")
          )
        end

        attributes = {}
        attributes[:command_json] = JSON.generate(runtime_changes["command"]) if runtime_changes.key?("command")
        attributes[:internal_port] = runtime_changes["internal_port"] if runtime_changes.key?("internal_port")
        attributes[:healthcheck_path] = runtime_changes["healthcheck_path"] if runtime_changes.key?("healthcheck_path")
        Valpo::AppServiceConfig[service.id].update(attributes) unless attributes.empty?
      end

      def operate(service, checkout:, runtime_changed:, deploy:, queue:, job_id:)
        if deploy
          build_target = Valpo::AppServiceConfig[service.id].build_target
          raise Valpo::ValidationError, "Service has no configured build target" unless build_target

          if checkout
            builds.deploy_checkout(
              service_id: service.id,
              build_target:,
              checkout:,
              internal_port: nil,
              healthcheck_path: nil,
              queue:,
              job_id:
            )
          else
            builds.deploy_source(
              service_id: service.id,
              ref: nil,
              internal_port: nil,
              healthcheck_path: nil,
              queue:,
              job_id:
            )
          end
        elsif runtime_changed && service.status == "running" && Valpo::Release.active_for_service(service.id)
          deployment.reconfigure_service(service_id: service.id, queue:, job_id:)
        end
      end

      def snapshot(service)
        app = Valpo::AppServiceConfig[service.id]
        source = Valpo::Source.where(owner_service_id: service.id).first
        build = Valpo::BuildTarget.where(owner_service_id: service.id).first
        {
          service_status: service.status,
          app: app.values.slice(:build_target_id, :command_json, :internal_port, :healthcheck_path),
          source: source&.values&.slice(:id, :provider, :repository, :ref, :status),
          build: build&.values&.slice(:id, :source_id, :strategy, :dockerfile, :context)
        }
      end

      def restore(service, snapshot)
        Valpo::Database.connection.transaction do
          current_source = Valpo::Source.where(owner_service_id: service.id).first
          current_build = Valpo::BuildTarget.where(owner_service_id: service.id).first

          if snapshot[:source]
            current_source&.update(snapshot.fetch(:source).except(:id))
          else
            current_source&.destroy
            current_build = nil
          end
          current_build&.update(snapshot.fetch(:build).except(:id)) if snapshot[:build]
          Valpo::AppServiceConfig[service.id].update(snapshot.fetch(:app))
          service.transition_to!(snapshot.fetch(:service_status))
        end
      end
    end
  end
end
