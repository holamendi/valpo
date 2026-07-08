# frozen_string_literal: true

require "test_helper"

class ValpoProjectTest < Minitest::Test
  include ValpoTestDatabase

  def test_project_is_a_top_level_sequel_model
    project = Valpo::Project.create(name: "hello")

    assert_equal "hello", project.name
    assert_equal "container", project.type
    assert_equal "created", project.status
    assert_equal project.id, Valpo::Project.find_by_id_or_name("hello").id
    assert_equal project.id, Valpo::Project.find_by_id_or_name(project.id).id
  end

  def test_project_validation_lives_on_model
    error = assert_raises(Sequel::ValidationFailed) do
      Valpo::Project.create(name: "Hello")
    end

    assert_match "lowercase", error.message
  end

  def test_project_names_are_unique
    Valpo::Project.create(name: "hello")

    assert_raises(Sequel::UniqueConstraintViolation) do
      Valpo::Project.create(name: "hello")
    end
  end
end
