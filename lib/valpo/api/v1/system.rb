# frozen_string_literal: true

module Valpo
  module API
    module V1
      module System
        class ConfigureAppDomainContract < Contract
          json do
            required(:hostname).filled(:string, format?: NONEMPTY)
          end
        end

        module_function

        def render_domain(domain)
          return nil unless domain

          Fields.call(
            domain, :id, :hostname, :status, :active, :verification_error, :verified_at, :created_at, :updated_at
          )
        end
      end
    end
  end
end
