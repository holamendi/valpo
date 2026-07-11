# frozen_string_literal: true

module Valpo
  module References
    module_function

    def project(value)
      Valpo::Project.find_by_id_or_name(value) || raise(Valpo::ValidationError, "Project not found: #{value}")
    end

    def service(value)
      reference = value.to_s
      if reference.start_with?("svc_")
        raise Valpo::ValidationError, "Invalid service ID: #{reference}" unless Valpo::Identifier.valid?(reference, :service)

        return Valpo::Service[reference] || raise(Valpo::ValidationError, "Service not found: #{reference}")
      end

      project_name, service_name, extra = reference.split("/", 3)
      unless project_name && service_name && !project_name.empty? && !service_name.empty? && extra.nil?
        raise Valpo::ValidationError, "Service reference must be a svc_ ID or PROJECT/SERVICE"
      end

      owner = project(project_name)
      Valpo::Service.where(project_id: owner.id, name: service_name).first ||
        raise(Valpo::ValidationError, "Service not found: #{reference}")
    end
  end
end
