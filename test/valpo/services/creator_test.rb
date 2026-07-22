# frozen_string_literal: true

require "test_helper"

class ValpoServicesCreatorTest < Minitest::Test
  include ValpoTestDatabase

  def test_unsupported_type_and_version_are_rejected
    project = create_project
    assert_raises(Valpo::ValidationError) do
      Valpo::Services::Creator.call(project_id: project.id, name: "db", type: "mysql")
    end
    error = assert_raises(Valpo::ValidationError) do
      Valpo::Services::Creator.call(project_id: project.id, name: "db", type: "postgres", version: "13")
    end
    assert_match "Unsupported postgres version", error.message
  end

  def test_web_service_receives_generated_domain_when_platform_domain_is_active
    project = create_project(name: "hello")
    platform_domain = create_platform_domain
    service = Valpo::Services::Creator.call(project_id: project.id, name: "web", type: "web")

    domain = Valpo::Domain.where(service_id: service.id).first
    assert_equal "web.hello.apps.example.com", domain.hostname
    assert_equal "generated", domain.kind
    assert_equal "pending", domain.status
    assert_equal platform_domain.id, domain.platform_domain_id
  end

  def test_worker_does_not_receive_a_default_domain
    project = create_project
    create_platform_domain
    service = Valpo::Services::Creator.call(project_id: project.id, name: "worker", type: "worker")

    assert_empty Valpo::Domain.where(service_id: service.id)
  end
end
