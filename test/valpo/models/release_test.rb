# frozen_string_literal: true

require "test_helper"

class ValpoReleaseTest < Minitest::Test
  include ValpoTestDatabase

  def test_assigns_versions_per_service_and_finds_active_release
    service = create_app_service
    first = create_release(service:, image: "example/hello:v1")
    second = create_release(service:, image: "example/hello:v2")
    first.activate!
    second.activate!

    assert_equal 1, first.version
    assert_equal 2, second.version
    assert_equal "inactive", first.refresh.status
    assert_equal second.id, Valpo::Release.active_for_service(service.id).id
  end

  def test_previous_deployable_release_excludes_current
    service = create_app_service
    first = create_release(service:)
    second = create_release(service:, image: "example/hello:v2")
    first.activate!
    second.activate!
    assert_equal first.id, Valpo::Release.previous_deployable_for_service(service.id, excluding_release_id: second.id).id

    first.update(artifact_available: false)
    assert_nil Valpo::Release.previous_deployable_for_service(service.id, excluding_release_id: second.id)
  end

  def test_validates_runtime_fields
    service = create_app_service
    error = assert_raises Sequel::ValidationFailed do
      create_release(service:, status: "mystery", internal_port: 0, healthcheck_path: "health")
    end
    assert_match "status", error.message
    assert_match "internal_port", error.message
    assert_match "healthcheck_path", error.message
  end

  def test_parses_and_validates_build_metadata
    service = create_app_service
    release = create_release(
      service:,
      source_type: "git",
      build_strategy: "buildpack",
      build_metadata_json: JSON.generate(
        "builder" => "example/builder@sha256:abc",
        "processes" => [{"type" => "web", "default" => true}]
      )
    )

    assert_equal "example/builder@sha256:abc", release.build_metadata.fetch("builder")
    assert_raises Sequel::ValidationFailed do
      create_release(service:, build_strategy: "auto", build_metadata_json: "[]")
    end
  end

  def test_release_transitions_allow_documented_progression_and_reject_terminal_revival
    service = create_app_service
    release = create_release(service:)

    assert_equal "ready", release.transition_to!("ready").status
    assert_equal "active", release.transition_to!("active").status
    assert_equal "inactive", release.transition_to!("inactive").status
    assert_equal "failed", release.transition_to!("failed").status

    error = assert_raises(Valpo::ValidationError) { release.transition_to!("active") }
    assert_equal "Forbidden release transition from failed to active", error.message
  end
end
