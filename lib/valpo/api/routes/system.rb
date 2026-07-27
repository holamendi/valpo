# frozen_string_literal: true

module Valpo
  module API
    class App
      hash_branch("/v1", "system") do |r|
        r.on "app-domain" do
          # GET /v1/system/app-domain — show active and staged platform domains.
          r.get true do
            validate_query
            active = Valpo::Domains::Configuration.active
            candidate = Valpo::PlatformDomain.where(active: false).reverse_order(:updated_at).first
            {
              active: V1::System.render_domain(active),
              candidate: V1::System.render_domain(candidate)
            }
          end

          if r.put?
            # PUT /v1/system/app-domain — stage and verify the platform app domain.
            r.is do
              validate_query
              payload = validate_body(V1::System::ConfigureAppDomainContract)
              record, changed = Valpo::Domains::Configuration.stage(payload.fetch(:hostname))
              next({app_domain: V1::System.render_domain(record), job: nil}) unless changed

              response.status = 202
              job = jobs.enqueue("verify_platform_domain", platform_domain_id: record.id)
              {app_domain: V1::System.render_domain(record), job: V1::Jobs.render(job)}
            end
          end
        end

        r.on "repair" do
          # POST /v1/system/repair — enqueue whole-system reconciliation.
          r.post true do
            validate_query
            response.status = 202
            V1::Jobs.render(jobs.enqueue("repair_system"))
          end
        end

        r.on "maintenance" do
          # POST /v1/system/maintenance — enqueue ownership-scoped storage maintenance.
          r.post true do
            validate_query
            payload = validate_body(V1::System::MaintainStorageContract)
            response.status = 202
            V1::Jobs.render(jobs.enqueue_unique("maintain_storage", dry_run: payload.fetch(:dry_run, false)))
          end
        end
        not_found("Route not found")
      end
    end
  end
end
