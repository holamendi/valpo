# frozen_string_literal: true

require "test_helper"

class ValpoMigratorTest < Minitest::Test
  include ValpoTestDatabase

  def test_phase0_tables_exist
    assert_includes db.tables, :projects
    assert_includes db.tables, :releases
    assert_includes db.tables, :domains
    assert_includes db.tables, :jobs
    assert_includes db.tables, :job_events
  end
end
