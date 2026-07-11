# frozen_string_literal: true

require "test_helper"

class ValpoDatabaseTest < Minitest::Test
  include ValpoTestDatabase

  def test_sqlite_pragmas_are_set_for_valpo_runtime
    assert_equal "wal", pragma(:journal_mode)
    assert_equal 1, pragma(:foreign_keys)
    assert_equal 1, pragma(:synchronous)
    assert_equal 5000, pragma(:busy_timeout)
    assert_equal 1000, pragma(:wal_autocheckpoint)
    assert_equal :immediate, db.transaction_mode
  end

  def test_foreign_keys_are_enforced
    assert_raises(Sequel::ForeignKeyConstraintViolation) do
      db[:releases].insert(
        id: "rel_01900000000070008000000000000000",
        service_id: "svc_01900000000070008000000000000000",
        version: 1,
        source_type: "registry",
        status: "pending",
        created_at: Time.now.utc
      )
    end
  end

  private

  def pragma(name)
    row = db.fetch("PRAGMA #{name}").first
    row.values.fetch(0)
  end
end
