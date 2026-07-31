# frozen_string_literal: true

require "json"
require "tempfile"
require "test_helper"

class ValpoReleaseMetadataTest < Minitest::Test
  include ValpoTestDatabase

  def test_current_metadata_matches_code_migrations_and_configuration
    metadata = Valpo::ReleaseMetadata.current

    assert_equal Valpo::VERSION, metadata.version
    assert_equal Valpo::API_VERSION, metadata.api_version
    assert_equal Valpo::SchemaInfo.latest, metadata.schema_target
    assert_equal Valpo::Config::CURRENT_SCHEMA, metadata.config_schema
    assert_equal Valpo::SchemaInfo.current, metadata.validate_database!
  end

  def test_load_rejects_unknown_keys_and_incompatible_versions
    unknown = metadata_hash.merge("unexpected" => true)
    assert_metadata_error(unknown, "unknown unexpected")

    wrong_version = metadata_hash.merge("version" => "9.9.9")
    assert_metadata_error(wrong_version, "does not match Valpo::VERSION")

    wrong_schema = metadata_hash.merge("schema_target" => 2, "schema_max" => 2)
    assert_metadata_error(wrong_schema, "does not match latest migration")
  end

  private

  def metadata_hash
    Valpo::ReleaseMetadata.current.to_h.transform_keys(&:to_s)
  end

  def assert_metadata_error(values, message)
    file = Tempfile.new(["valpo-release", ".json"])
    file.write(JSON.generate(values))
    file.close

    error = assert_raises(Valpo::ValidationError) { Valpo::ReleaseMetadata.load(path: file.path) }
    assert_match message, error.message
  ensure
    file&.unlink
  end
end

class ValpoInstallationMetadataTest < Minitest::Test
  def test_development_metadata_requires_no_installed_artifact
    metadata = Valpo::InstallationMetadata.development

    assert_equal Valpo::VERSION, metadata.version
    assert_equal "development", metadata.channel
    assert_nil metadata.artifact_digest
    assert_nil metadata.installed_at
  end

  def test_published_metadata_records_the_verified_artifact_and_install_time
    values = {
      "version" => Valpo::VERSION,
      "channel" => "preview",
      "artifact_digest" => "sha256:#{"a" * 64}",
      "installed_at" => "2026-07-31T12:30:00Z"
    }

    metadata = load_metadata(values)

    assert_equal "preview", metadata.channel
    assert_equal values.fetch("artifact_digest"), metadata.artifact_digest
    assert_equal "2026-07-31T12:30:00Z", metadata.installed_at.iso8601
  end

  def test_published_metadata_requires_a_digest_time_and_matching_version
    missing_identity = {
      "version" => Valpo::VERSION,
      "channel" => "stable",
      "artifact_digest" => nil,
      "installed_at" => nil
    }
    error = assert_raises(Valpo::ValidationError) { load_metadata(missing_identity) }
    assert_match "require artifact_digest and installed_at", error.message

    invalid_digest = missing_identity.merge("artifact_digest" => "latest")
    error = assert_raises(Valpo::ValidationError) { load_metadata(invalid_digest) }
    assert_match "must be null or a sha256 digest", error.message

    wrong_version = missing_identity.merge("version" => "9.9.9")
    error = assert_raises(Valpo::ValidationError) { load_metadata(wrong_version) }
    assert_match "does not match Valpo::VERSION", error.message
  end

  private

  def load_metadata(values)
    file = Tempfile.new(["valpo-installation", ".json"])
    file.write(JSON.generate(values))
    file.close
    Valpo::InstallationMetadata.load(path: file.path)
  ensure
    file&.unlink
  end
end
