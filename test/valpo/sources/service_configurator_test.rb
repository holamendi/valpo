# frozen_string_literal: true

require "test_helper"

class ValpoSourcesServiceConfiguratorTest < Minitest::Test
  include ValpoTestDatabase

  def test_normalizes_omitted_source_build_options
    normalized = configurator.normalize_create(
      source: {provider: "github", repository: "acme/backend"},
      build: nil
    )

    assert_equal "HEAD", normalized.dig(:source, "ref")
    assert_equal "auto", normalized.dig(:build, "strategy")
    assert_nil normalized.dig(:build, "dockerfile")
    assert_equal ".", normalized.dig(:build, "context")
  end

  def test_dockerfile_input_selects_dockerfile_strategy
    normalized = configurator.normalize_create(
      source: {provider: "github", repository: "acme/backend"},
      build: {dockerfile: "ops/Dockerfile"}
    )

    assert_equal(
      {"strategy" => "dockerfile", "dockerfile" => "ops/Dockerfile", "context" => "."},
      normalized.fetch(:build)
    )
  end

  def test_rejects_dockerfile_with_an_incompatible_strategy
    error = assert_raises Valpo::ValidationError do
      configurator.normalize_create(
        source: {provider: "github", repository: "acme/backend"},
        build: {strategy: "buildpack", dockerfile: "Dockerfile"}
      )
    end

    assert_match "dockerfile is only valid", error.message
  end

  def test_create_rolls_back_service_source_and_build_together
    project = create_project

    assert_raises Sequel::ValidationFailed do
      configurator.create_service!(
        project:,
        service_attributes: {"name" => "web", "type" => "web"},
        source: {"provider" => "github", "repository" => "acme/backend", "ref" => "HEAD"},
        build: {"strategy" => "dockerfile", "dockerfile" => "Dockerfile", "context" => ".."}
      )
    end

    assert_equal 0, Valpo::Service.where(project_id: project.id).count
    assert_equal 0, Valpo::Source.where(project_id: project.id).count
    assert_equal 0, Valpo::BuildTarget.where(project_id: project.id).count
  end

  private

  def configurator
    @configurator ||= Valpo::Sources::ServiceConfigurator.new
  end
end
