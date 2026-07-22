# frozen_string_literal: true

require "test_helper"

class ValpoServiceTest < Minitest::Test
  include ValpoTestDatabase

  def test_service_has_project_scoped_name_and_typed_id
    project = create_project
    web = create_app_service(project: project)
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
    managed = Valpo::Services::Catalog.managed_config(service)
    error = assert_raises(Sequel::ValidationFailed) { managed.update(version: "17") }
    assert_match "version is immutable", error.message
  end
end
