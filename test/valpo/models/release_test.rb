# frozen_string_literal: true

require "test_helper"

class ValpoReleaseTest < Minitest::Test
  include ValpoTestDatabase

  def test_assigns_versions_per_service_and_finds_active_release
    service = create_app_service
    first = create_release(service: service, image: "example/hello:v1")
    second = create_release(service: service, image: "example/hello:v2")
    first.activate!
    second.activate!

    assert_equal 1, first.version
    assert_equal 2, second.version
    assert_equal "inactive", first.refresh.status
    assert_equal second.id, Valpo::Release.active_for_service(service.id).id
  end

  def test_previous_deployable_release_excludes_current
    service = create_app_service
    first = create_release(service: service)
    second = create_release(service: service, image: "example/hello:v2")
    first.activate!
    second.activate!
    assert_equal first.id, Valpo::Release.previous_deployable_for_service(service.id, excluding_release_id: second.id).id
  end

  def test_validates_runtime_fields
    service = create_app_service
    error = assert_raises Sequel::ValidationFailed do
      create_release(service: service, status: "mystery", internal_port: 0, healthcheck_path: "health")
    end
    assert_match "status", error.message
    assert_match "internal_port", error.message
    assert_match "healthcheck_path", error.message
  end
end
