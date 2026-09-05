# frozen_string_literal: true

require "test_helper"

class ValpoServiceTest < Minitest::Test
  include ValpoTestDatabase

  def test_service_has_project_scoped_name_and_typed_id
    project = create_project
    web = create_app_service(project:)
    other = create_project(name: "other")
    create_app_service(project: other)

    assert_match(/\Asvc_[0-9a-f]{32}\z/, web.id)
    assert web.app?
    assert web.web?
  end

  def test_service_validates_kind_status_and_name
    project = create_project
    error = assert_raises Sequel::ValidationFailed do
      Valpo::Service.create(project_id: project.id, name: "Main App", kind: "mysql", status: "lost")
    end

    assert_match "name must be a DNS-safe label", error.message
    assert_match "kind must be one of", error.message
    assert_match "status must be one of", error.message
  end

  def test_service_kind_and_managed_version_are_immutable
    service = create_managed_service
    assert_raises(Sequel::ValidationFailed) { service.update(kind: "redis") }
    managed = Valpo::Services::Registry.managed_config(service)
    error = assert_raises(Sequel::ValidationFailed) { managed.update(version: "17") }
    assert_match "version is immutable", error.message
  end

  def test_managed_service_schema_has_no_inert_plan_column
    columns = Valpo::Database.connection.schema(:managed_service_configs).map(&:first)

    refute_includes columns, :plan
  end

  def test_service_transitions_allow_operational_progression_and_reject_unknown_edges
    service = create_app_service

    assert_equal "provisioning", service.transition_to!("provisioning").status
    assert_equal "running", service.transition_to!("running").status
    assert_equal "stopped", service.transition_to!("stopped").status

    error = assert_raises(Valpo::ValidationError) { service.transition_to!("active") }
    assert_equal "Forbidden service transition from stopped to active", error.message
  end
end
