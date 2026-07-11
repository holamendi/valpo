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
    assert_includes db.tables, :jobs
    assert_includes db.tables, :job_events
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
