# frozen_string_literal: true

require "test_helper"

class ValpoBuildTargetTest < Minitest::Test
  include ValpoTestDatabase

  def test_defaults_to_auto_without_a_dockerfile
    target = create_target

    assert_equal "auto", target.strategy
    assert_nil target.dockerfile
    assert_equal ".", target.context
  end

  def test_dockerfile_input_selects_dockerfile_strategy
    target = create_target(dockerfile: "ops/Dockerfile")

    assert_equal "dockerfile", target.strategy
    assert_equal "ops/Dockerfile", target.dockerfile
  end

  def test_rejects_a_dockerfile_for_buildpack_strategy
    assert_raises Sequel::ValidationFailed do
      create_target(strategy: "buildpack", dockerfile: "Dockerfile")
    end
  end

  private

  def create_target(**attributes)
    project = create_project
    source = Valpo::Source.create(
      project_id: project.id,
      name: "backend",
      provider: "github",
      repository: "acme/backend"
    )
    Valpo::BuildTarget.create({
      project_id: project.id,
      source_id: source.id,
      name: "backend"
    }.merge(attributes))
  end
end
