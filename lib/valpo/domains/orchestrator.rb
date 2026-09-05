# frozen_string_literal: true

require "securerandom"
require "time"

module Valpo
  module Domains
    class Orchestrator
      def initialize(
        caddy_reconciler:,
        activator:,
        config: Valpo.config || Valpo::Config.load,
        docker: Valpo::Docker::Client.new,
        verifier: Valpo::Domains::ReachabilityVerifier.new,
        sleeper: Kernel
      )
        @caddy_reconciler = caddy_reconciler
        @activator = activator
        @config = config
        @docker = docker
        @verifier = verifier
        @sleeper = sleeper
      end

      def configure_platform_domain(platform_domain_id:, queue:, job_id:)
        record = Valpo::PlatformDomain[platform_domain_id]
        raise Valpo::ValidationError, "App domain not found: #{platform_domain_id}" unless record

        event(queue, job_id, "system", "Verifying wildcard DNS for *.#{record.hostname}")
        verify_challenge!(
          hostname: record.verification_hostname,
          token: record.verification_token,
          queue:,
          job_id:
        )
        Valpo::Domains::Configuration.activate!(record)
        failures = []
        Valpo::Domain.where(platform_domain_id: record.id).order(:hostname).each do
          if it.verified?
            Valpo::Domains::Configuration.retire_stale_generated!(it.service, keep: it)
            activator.activate_ready(
              service: it.service,
              runtime: runtime_for(queue:, job_id:),
              queue:,
              job_id:
            )
          else
            verify_domain_record(it, queue:, job_id:, activate_ready: true)
          end
        rescue Valpo::ValidationError => e
          failures << e.message
        end
        apply_routes(queue:, job_id:)
        raise Valpo::ValidationError, failures.join("; ") unless failures.empty?

        record.refresh
      rescue => e
        if record && !record.verified?
          record.transition_to!("failed", active: false, verification_error: e.message, verified_at: nil)
        end
        safely_apply_routes(queue:, job_id:)
        raise
      end

      def verify_domain(domain_id:, queue:, job_id:)
        domain = Valpo::Domain[domain_id]
        raise Valpo::ValidationError, "Domain not found: #{domain_id}" unless domain

        domain.transition_to!("pending",
          verification_token: SecureRandom.hex(24),
          verification_error: nil,
          verified_at: nil)
        verify_domain_record(domain, queue:, job_id:, activate_ready: true)
      end

      def verify_service_domains(service, queue:, job_id:)
        domains = Valpo::Domain.where(service_id: service.id).exclude(status: "verified").order(:hostname).all
        if domains.empty?
          event(queue, job_id, "system", "No domain is configured; the release will remain private")
          return
        end

        domains.each do
          verify_domain_record(it, queue:, job_id:, activate_ready: false)
        rescue Valpo::ValidationError => e
          event(queue, job_id, "stderr", e.message)
        end
      end

      def verified?(service)
        Valpo::Domain.where(service_id: service.id, status: "verified").count.positive?
      end

      def ensure_verified!(service)
        return unless service.web?
        return if verified?(service)

        raise Valpo::ValidationError, "A verified domain is required to activate a web release"
      end

      private

      attr_reader :caddy_reconciler, :activator, :config, :docker, :verifier, :sleeper

      def verify_domain_record(domain, queue:, job_id:, activate_ready:)
        event(queue, job_id, "system", "Verifying #{domain.hostname}")
        verify_challenge!(hostname: domain.hostname, token: domain.verification_token, queue:, job_id:)
        domain.transition_to!("verified", verification_error: nil, verified_at: Time.now.utc)
        active_platform = Valpo::Domains::Configuration.active
        if activate_ready
          activator.activate_ready(
            service: domain.service,
            runtime: runtime_for(queue:, job_id:),
            queue:,
            job_id:
          )
        else
          apply_routes(queue:, job_id:)
        end
        if domain.kind == "generated" && active_platform&.id == domain.platform_domain_id
          Valpo::Domains::Configuration.retire_stale_generated!(domain.service, keep: domain)
          apply_routes(queue:, job_id:)
        end
        domain.refresh
      rescue => e
        domain&.transition_to!("failed", verification_error: e.message, verified_at: nil)
        safely_apply_routes(queue:, job_id:)
        raise
      end

      def verify_challenge!(hostname:, token:, queue:, job_id:)
        route = {hostname:, kind: "verification", token:}
        apply_routes(queue:, job_id:, extra_routes: [route])
        verifier.verify!(hostname:, token:)
      end

      def apply_routes(queue:, job_id:, **options)
        caddy_reconciler.apply(queue:, job_id:, **options)
      end

      def safely_apply_routes(queue:, job_id:)
        apply_routes(queue:, job_id:)
      rescue => e
        event(queue, job_id, "stderr", "Could not restore Caddy config: #{e.message}")
      end

      def runtime_for(queue:, job_id:)
        Valpo::Deployments::Runtime.new(
          config:,
          docker:,
          queue:,
          job_id:,
          sleeper:
        )
      end

      def event(queue, job_id, stream, message)
        queue.event(job_id, stream, message)
      end
    end
  end
end
