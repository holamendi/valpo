# frozen_string_literal: true

require "test_helper"

class ValpoReleaseTest < Minitest::Test
  include ValpoTestDatabase

  def test_assigns_versions_per_project_and_finds_active_release
    project = Valpo::Project.create(name: "hello")

    first = Valpo::Release.create(project_id: project.id, source_type: "registry", source_ref: "example/hello:v1")
    second = Valpo::Release.create(project_id: project.id, source_type: "registry", source_ref: "example/hello:v2")

    assert_equal 1, first.version
    assert_equal 2, second.version

    first.activate!
    second.activate!

    assert_equal "inactive", first.refresh.status
    assert_equal "active", second.refresh.status
    assert_equal second.id, Valpo::Release.active_for_project(project.id).id
  end

  def test_previous_deployable_release_excludes_current_active
    project = Valpo::Project.create(name: "hello")
    first = Valpo::Release.create(project_id: project.id, source_type: "registry", source_ref: "example/hello:v1", container_name: "old")
    second = Valpo::Release.create(project_id: project.id, source_type: "registry", source_ref: "example/hello:v2", container_name: "new")
    first.activate!
    second.activate!

    previous = Valpo::Release.previous_deployable_for_project(project.id, excluding_release_id: second.id)

    assert_equal first.id, previous.id
  end

  def test_validates_status_source_type_and_healthcheck_path
    project = Valpo::Project.create(name: "hello")

    error = assert_raises Sequel::ValidationFailed do
      Valpo::Release.create(
        project_id: project.id,
        source_type: "git",
        source_ref: "example/hello:v1",
        status: "mystery",
        internal_port: 0,
        healthcheck_path: "health"
      )
    end

    assert_match "source_type", error.message
    assert_match "status", error.message
    assert_match "internal_port", error.message
    assert_match "healthcheck_path", error.message
  end
end
