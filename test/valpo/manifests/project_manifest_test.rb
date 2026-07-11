# frozen_string_literal: true

require "test_helper"

class ValpoProjectManifestTest < Minitest::Test
  def test_normalizes_sources_builds_services_and_dependencies
    manifest = Valpo::Manifests::ProjectManifest.parse(full_manifest)
    assert_equal "acme/backend", manifest.dig("sources", "backend", "repository")
    assert_equal "Dockerfile", manifest.dig("builds", "backend", "dockerfile")
    assert_equal %w[cache database], manifest.dig("services", "web", "depends_on")
    assert_equal "18", manifest.dig("services", "database", "version")
    assert_match(/\A[0-9a-f]{64}\z/, manifest.fetch("digest"))
  end

  def test_rejects_unknown_keys_and_invalid_references
    error = assert_raises(Valpo::ValidationError) do
      Valpo::Manifests::ProjectManifest.parse("schema = 1\n[project]\nname = \"acme\"\nwat = true\n")
    end
    assert_match "Unknown project keys", error.message

    error = assert_raises(Valpo::ValidationError) do
      Valpo::Manifests::ProjectManifest.parse(<<~TOML)
        schema = 1
        [project]
        name = "acme"
        [services.web]
        type = "web"
        build = "missing"
      TOML
    end
    assert_match "unknown build", error.message
  end

  def test_rejects_app_dependencies_and_unsupported_versions
    error = assert_raises(Valpo::ValidationError) do
      Valpo::Manifests::ProjectManifest.parse(<<~TOML)
        schema = 1
        [project]
        name = "acme"
        [services.web]
        type = "web"
        depends_on = ["worker"]
        [services.worker]
        type = "worker"
      TOML
    end
    assert_match "only depend on managed", error.message

    assert_raises(Valpo::ValidationError) do
      Valpo::Manifests::ProjectManifest.parse(<<~TOML)
        schema = 1
        [project]
        name = "acme"
        [services.database]
        type = "postgres"
        version = "13"
      TOML
    end
  end

  def test_rejects_build_paths_that_escape_the_checkout
    error = assert_raises(Valpo::ValidationError) do
      Valpo::Manifests::ProjectManifest.parse(<<~TOML)
        schema = 1
        [project]
        name = "acme"
        [sources.backend]
        provider = "github"
        repository = "acme/backend"
        [builds.backend]
        source = "backend"
        context = "apps/../../../etc"
      TOML
    end
    assert_match "source checkout", error.message
  end

  private

  def full_manifest
    <<~TOML
      schema = 1
      [project]
      name = "acme"

      [sources.backend]
      provider = "github"
      repository = "acme/backend"

      [builds.backend]
      source = "backend"

      [services.web]
      type = "web"
      build = "backend"
      command = ["bundle", "exec", "puma"]
      port = 3000
      depends_on = ["database", "cache"]

      [services.database]
      type = "postgres"

      [services.cache]
      type = "redis"
    TOML
  end
end
