# frozen_string_literal: true

require "test_helper"

class ValpoProjectTest < Minitest::Test
  include ValpoTestDatabase

  def test_project_has_typed_id_and_resolves_by_name_or_id
    project = Valpo::Project.create(name: "hello")

    assert_match(/\Aprj_[0-9a-f]{32}\z/, project.id)
    assert_equal project.id, Valpo::Project.find_by_id_or_name("hello").id
    assert_equal project.id, Valpo::Project.find_by_id_or_name(project.id).id
  end

  def test_project_validates_unique_lowercase_name
    Valpo::Project.create(name: "hello")
    assert_raises(Sequel::UniqueConstraintViolation) { Valpo::Project.create(name: "hello") }
    error = assert_raises(Sequel::ValidationFailed) { Valpo::Project.create(name: "Hello") }
    assert_match "lowercase", error.message
  end
end
