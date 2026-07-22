# frozen_string_literal: true

module Valpo
  module API
    class App
      hash_branch("", "system") do |r|
        r.on "app-domain" do
          r.get do
            active = Valpo::Domains::Configuration.active
            candidate = Valpo::PlatformDomain.where(active: false).reverse_order(:updated_at).first
            {active: Serializers.platform_domain(active), candidate: Serializers.platform_domain(candidate)}
          end
          if r.put?
            record, changed = Valpo::Domains::Configuration.stage(required_string(parse_json_body, "hostname"))
            next({app_domain: Serializers.platform_domain(record), job: nil}) unless changed

            response.status = 202
            job = jobs.enqueue("verify_platform_domain", platform_domain_id: record.id)
            {app_domain: Serializers.platform_domain(record), job: Serializers.job(job)}
          end
        end

        r.on "repair" do
          r.post do
            response.status = 202
            Serializers.job(jobs.enqueue("repair_system"))
          end
        end
      end
    end
  end
end
