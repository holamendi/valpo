# frozen_string_literal: true

require "test_helper"

class ValpoManifestsPlannerTest < Minitest::Test
  include ValpoTestDatabase

  def test_call_previews_without_mutating
    manifest = Valpo::Manifests::ProjectManifest.parse(<<~TOML)
      schema = 1
      [project]
      name = "acme"
      [services.web]
      type = "web"
      port = 3000
    TOML

    preview = Valpo::Manifests::Planner.call(manifest)

    assert_equal "acme", preview.fetch("project")
    assert_equal "create", preview.fetch("actions").first.fetch("operation")
    assert_nil Valpo::Project.find_by_id_or_name("acme")
  end
end
