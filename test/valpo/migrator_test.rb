# frozen_string_literal: true

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
    assert_includes db.tables, :jobs
    assert_includes db.tables, :job_events
  end

  def test_pre_release_schema_is_entirely_in_the_first_migration
    migrations = Dir[File.join(Valpo::Migrator::MIGRATIONS_PATH, "*.rb")].map { |path| File.basename(path) }

    assert_equal ["001_bootstrap.rb"], migrations
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

  def test_legacy_project_as_app_schema_is_rejected_without_data_loss
    legacy = Sequel.sqlite
    legacy.create_table(:projects) do
      String :id, primary_key: true
      String :type
    end

    error = assert_raises(Valpo::ValidationError) { Valpo::Migrator.run(db: legacy) }
    assert_match "retired project-as-app schema", error.message
    assert legacy.table_exists?(:projects)
  ensure
    legacy&.disconnect
  end
end
