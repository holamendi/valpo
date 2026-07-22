# frozen_string_literal: true

module Valpo
  module References
    module_function

    def project(value)
      Valpo::Project.find_by_id_or_name(value) || raise(Valpo::ValidationError, "Project not found: #{value}")
    end

    def service(value, project: nil)
      reference = value.to_s
      if reference.start_with?("svc_")
        raise Valpo::ValidationError, "Invalid service ID: #{reference}" unless Valpo::Identifier.valid?(reference, :service)

        return Valpo::Service[reference] || raise(Valpo::ValidationError, "Service not found: #{reference}")
      end

      raise Valpo::ValidationError, "Service names must not contain /; provide project separately" if reference.include?("/")
      raise Valpo::ValidationError, "Project is required when using a service name" if project.nil? || project.to_s.empty?

      owner = self.project(project)
      Valpo::Service.where(project_id: owner.id, name: reference).first ||
        raise(Valpo::ValidationError, "Service not found: #{reference}")
    end
  end
end
