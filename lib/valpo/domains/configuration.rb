# frozen_string_literal: true

require "securerandom"
require "time"

module Valpo
  module Domains
    module Configuration
      MAX_APP_DOMAIN_LENGTH = 125

      module_function

      def active
        Valpo::PlatformDomain.where(active: true, status: "verified").first
      end

      def stage(hostname)
        normalized = Valpo::Hostname.normalize(hostname)
        unless Valpo::Hostname.valid?(normalized)
          raise Valpo::ValidationError, "App domain must be a hostname such as apps.example.com (without *.)"
        end
        if normalized.length > MAX_APP_DOMAIN_LENGTH
          raise Valpo::ValidationError, "App domain must be at most #{MAX_APP_DOMAIN_LENGTH} characters"
        end

        current = active
        if current&.hostname == normalized
          unverified = Valpo::Domain.where(platform_domain_id: current.id).exclude(status: "verified").count.positive?
          return [current, unverified]
        end

        record = Valpo::PlatformDomain.where(hostname: normalized).first
        attributes = {
          status: "pending",
          active: false,
          verification_token: SecureRandom.hex(24),
          verification_error: nil,
          verified_at: nil
        }
        if record
          record.update(attributes)
        else
          record = Valpo::PlatformDomain.create(attributes.merge(hostname: normalized))
        end
        [record.refresh, true]
      end

      def activate!(record, verified_at: Time.now.utc)
        Valpo::Database.connection.transaction do
          Valpo::PlatformDomain.exclude(id: record.id).where(active: true).update(active: false)
          record.update(status: "verified", active: true, verification_error: nil, verified_at:)
          Valpo::Service.where(kind: "web").order(:created_at).each { reconcile_service(it, platform_domain: record) }
        end
        record.refresh
      end

      def reconcile_service(service, platform_domain: active)
        return nil unless service&.web? && platform_domain&.verified?

        hostname = Valpo::Domain.default_hostname(
          project_name: service.project.name,
          service_name: service.name,
          app_domain: platform_domain.hostname
        )
        domain = Valpo::Domain.where(service_id: service.id, hostname:).first
        if domain && domain.kind != "generated"
          raise Valpo::ConflictError, "Custom domain #{hostname} conflicts with the generated app domain"
        end
        domain || Valpo::Domain.create(
          service_id: service.id,
          platform_domain_id: platform_domain.id,
          hostname:,
          kind: "generated"
        )
      end

      def retire_stale_generated!(service, keep:)
        Valpo::Domain.where(service_id: service.id, kind: "generated").exclude(id: keep.id).destroy
      end
    end
  end
end
