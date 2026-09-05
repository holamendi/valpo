# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "test_helper"

class ValpoMigratorTest < Minitest::Test
  include ValpoTestDatabase

  def test_unified_service_tables_exist
    assert_includes db.tables, :projects
    assert_includes db.tables, :sources
    assert_includes db.tables, :build_targets
    assert_includes db.tables, :services
    assert_includes db.tables, :app_service_configs
    assert_includes db.tables, :managed_service_configs
    assert_includes db.tables, :service_dependencies
    assert_includes db.tables, :releases
    assert_includes db.tables, :domains
    assert_includes db.tables, :platform_domains
    assert_includes db.tables, :github_app_setups
    assert_includes db.tables, :github_webhook_deliveries
    assert_includes db.tables, :jobs
    assert_includes db.tables, :job_events
    assert_includes db.tables, :control_plane_states
  end

  def test_bootstrap_schema_is_frozen_and_migration_versions_are_contiguous
    bootstrap = File.join(Valpo::SchemaInfo::MIGRATIONS_PATH, Valpo::SchemaInfo::BOOTSTRAP_FILENAME)

    assert Valpo::SchemaInfo.validate_migrations!
    assert_equal [1, 2], Valpo::SchemaInfo.versions
    assert_equal 2, Valpo::SchemaInfo.latest
    assert_equal Valpo::SchemaInfo::BOOTSTRAP_SHA256, Digest::SHA256.file(bootstrap).hexdigest
    assert_includes db.schema(:sources).to_h, :owner_service_id
    assert_includes db.schema(:build_targets).to_h, :owner_service_id
    assert_includes db.schema(:domains).to_h, :kind
    assert_includes db.schema(:domains).to_h, :status

    project = create_project
    db[:sources].insert(
      id: Valpo::Identifier.generate(:source),
      project_id: project.id,
      name: "backend",
      provider: "github",
      repository: "acme/backend",
      created_at: Time.now.utc,
      updated_at: Time.now.utc
    )

    assert_equal "HEAD", db[:sources].where(project_id: project.id, name: "backend").get(:ref)
  end

  def test_incremental_migration_policy_accepts_new_contiguous_versions
    Dir.mktmpdir("valpo-migrations") do
      copy_bootstrap(it)
      File.write(File.join(it, "002_add_example.rb"), "# future migration\n")

      assert Valpo::SchemaInfo.validate_migrations!(path: it)
      assert_equal [1, 2], Valpo::SchemaInfo.versions(path: it)
      assert_equal 2, Valpo::SchemaInfo.latest(path: it)
    end
  end

  def test_control_plane_state_migration_closes_bootstrap_for_existing_credentials
    Dir.mktmpdir("valpo-bootstrap-state") do
      database = Sequel.sqlite(File.join(it, "valpo.sqlite3"))
      Valpo::Migrator.run(db: database, target: 1)
      timestamp = Time.now.utc
      database[:api_credentials].insert(
        id: Valpo::Identifier.generate(:api_credential),
        name: "existing-admin",
        token_prefix: "valpo_existing",
        token_digest: "a" * 64,
        scopes_json: JSON.generate(["admin"]),
        created_at: timestamp,
        updated_at: timestamp
      )

      Valpo::Migrator.run(db: database)

      state = database[:control_plane_states].where(id: 1).first
      assert_equal timestamp.to_i, state.fetch(:api_bootstrapped_at).to_i
    ensure
      database&.disconnect
    end
  end

  def test_incremental_migration_policy_rejects_bootstrap_edits_and_version_gaps
    Dir.mktmpdir("valpo-migrations") do |path|
      copy_bootstrap(path)
      File.write(File.join(path, "003_skip_version.rb"), "# invalid gap\n")

      gap = assert_raises(Valpo::ValidationError) { Valpo::SchemaInfo.validate_migrations!(path:) }
      assert_match "contiguous from 001", gap.message

      File.write(File.join(path, Valpo::SchemaInfo::BOOTSTRAP_FILENAME), "# changed\n")
      changed = assert_raises(Valpo::ValidationError) { Valpo::SchemaInfo.validate_migrations!(path:) }
      assert_match "is frozen", changed.message
    end
  end

  private

  def copy_bootstrap(path)
    FileUtils.cp(
      File.join(Valpo::SchemaInfo::MIGRATIONS_PATH, Valpo::SchemaInfo::BOOTSTRAP_FILENAME),
      path
    )
  end
end
